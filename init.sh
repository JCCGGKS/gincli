#!/usr/bin/env bash
#
# 从 GitHub 拉取 Gin 骨架（ginctl2），替换占位符并初始化一个新项目。
#
# Usage:
#   ./init.sh [--repo owner/name] [--ref ref] [--no-git] [--no-build] \
#       [--force | --keep-git] <target-dir> [module-path] [service-name]
#
# 只有 bash / curl(或 wget) / tar / git / perl / grep / find 这些常见工具依赖。

set -euo pipefail

log_info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*" >&2; }
log_warn() { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2; }
log_ok()   { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*" >&2; }
die()      { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./init.sh [options] <target-dir> [module-path] [service-name]

Options:
  --repo owner/name  模板 GitHub 仓库（默认 JCCGGKS/ginctl2）
  --ref ref          分支 / 标签 / 提交（默认 master）
  --no-git           不初始化 Git 仓库
  --no-build         不执行 go build ./...
  --force            目标目录非空时先删除再重建
  --keep-git         目标已是 Git 仓库时保留 .git/remote，只覆盖工作区文件
  -h, --help         显示帮助

Defaults:
  module-path   目标目录名
  service-name  module-path 的最后一段

Note:
  Database names are NOT rewritten; set them yourself in etc/config_<env>.yaml.

Example:
  ./init.sh ../order-service
  ./init.sh ../order-service github.com/acme/order-service order-service
EOF
}

REPO='JCCGGKS/ginctl2'
REF='master'
GIT_INIT=1
DO_BUILD=1
FORCE=0
KEEP_GIT=0
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a value"; REPO=$2; shift 2 ;;
    --ref) [[ $# -ge 2 ]] || die "--ref needs a value"; REF=$2; shift 2 ;;
    --no-git) GIT_INIT=0; shift ;;
    --no-build) DO_BUILD=0; shift ;;
    --force) FORCE=1; shift ;;
    --keep-git) KEEP_GIT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ARGS+=("$@"); break ;;
    -*) die "unknown option: $1" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

[[ $# -ge 1 && $# -le 3 ]] || { usage; exit 2; }

command -v perl >/dev/null 2>&1 || die "perl is required for rewriting"
command -v tar >/dev/null 2>&1 || die "tar is required"

TARGET=$1
[[ -n "$TARGET" ]] || die "target directory is required"
TARGET_PARENT=$(cd "$(dirname "$TARGET")" 2>/dev/null && pwd) || die "target parent directory does not exist: $(dirname "$TARGET")"
TARGET="$TARGET_PARENT/$(basename "$TARGET")"

MODULE=${2:-}
SERVICE=${3:-}
MODULE=${MODULE%/}

[[ -z "$MODULE" ]] && MODULE=$(basename "$TARGET")
[[ -z "$SERVICE" ]] && SERVICE=$(basename "$MODULE")

[[ "$FORCE" -eq 0 || "$KEEP_GIT" -eq 0 ]] || die "--force and --keep-git cannot be used together"
[[ "$KEEP_GIT" -eq 0 || -d "$TARGET/.git" ]] || die "--keep-git requires an existing Git repository at $TARGET"

[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "invalid repo: $REPO"
[[ "$REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$REF" != *'..'* && "$REF" != *'//'* ]] || die "invalid ref: $REF"
[[ "$MODULE" =~ ^[A-Za-z0-9][A-Za-z0-9._~/-]*$ && "$MODULE" != *'//'* ]] || die "invalid module path: $MODULE"
[[ "$SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid service name: $SERVICE"

if [[ -e "$TARGET" ]]; then
  [[ -d "$TARGET" ]] || die "target exists and is not a directory: $TARGET"
  if [[ -n "$(find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      log_warn "--force: removing existing directory $TARGET"
      rm -rf "$TARGET"
    elif [[ "$KEEP_GIT" -eq 1 ]]; then
      log_info "keeping existing Git repository at $TARGET"
    else
      die "target directory is not empty: $TARGET (use --force to replace it, or --keep-git to fill an existing repo)"
    fi
  fi
fi

# 在目标父目录暂存，失败时不会留下半成品，最后用 mv 原子发布。
STAGE=$(mktemp -d "$TARGET_PARENT/.gincli.XXXXXX") || die "cannot create staging directory"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

log_info "fetching template $REPO@$REF"
URL="https://codeload.github.com/$REPO/tar.gz/$REF"
ARCHIVE="$STAGE/template.tar.gz"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --max-time 120 "$URL" -o "$ARCHIVE" || die "failed to download $URL"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$ARCHIVE" "$URL" || die "failed to download $URL"
else
  die "curl or wget is required"
fi

mkdir -p "$STAGE/src"
tar -xzf "$ARCHIVE" -C "$STAGE/src" || die "failed to extract template archive"
SRC_ROOT=$(find "$STAGE/src" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$SRC_ROOT" && -f "$SRC_ROOT/go.mod" ]] || die "template archive has no go.mod at its root"

PROJECT="$STAGE/project"
mkdir -p "$PROJECT"
cp -a "$SRC_ROOT/." "$PROJECT/"   # -a 保留权限位

log_info "rewriting module=$MODULE service=$SERVICE"

# 单次扫描替换，插入的值不会被二次扫描（避免 ginctl 碰撞）。
# 数据库名不在这里处理，gin_scaffold 占位符保留，由使用者自行配置。
rewrite_file() {
  local file=$1 kind=$2
  KIND="$kind" MODULE="$MODULE" SERVICE="$SERVICE" perl -pi -e '
    BEGIN {
      if ($ENV{KIND} eq "go") {
        %m = ("\"gin-scaffold\"" => "\"$ENV{SERVICE}\"",
              "gin-scaffold"    => $ENV{MODULE},
              "ginctl"          => $ENV{SERVICE});
        $re = qr/("gin-scaffold"|gin-scaffold|ginctl)/;
      } elsif ($ENV{KIND} eq "mod") {
        %m = ("gin-scaffold" => $ENV{MODULE});
        $re = qr/(gin-scaffold)/;
      } else {
        %m = ("gin-scaffold" => $ENV{SERVICE},
              "ginctl"       => $ENV{SERVICE});
        $re = qr/(gin-scaffold|ginctl)/;
      }
    }
    s#$re#$m{$1}#g;
  ' "$file"
}

while IFS= read -r -d '' file; do
  rel=${file#"$PROJECT/"}
  case "$rel" in
    go.sum|*/go.sum) continue ;;
    go.mod|*/go.mod) kind=mod ;;
    *.go) kind=go ;;
    *) LC_ALL=C grep -Iq . "$file" 2>/dev/null || continue; kind=text ;;
  esac
  rewrite_file "$file" "$kind"
done < <(find "$PROJECT" -type f -print0)

if [[ "$GIT_INIT" -eq 1 && "$KEEP_GIT" -eq 0 ]]; then
  command -v git >/dev/null 2>&1 || die "git is required (use --no-git to skip)"
  git init -q -b master "$PROJECT" 2>/dev/null || git init -q "$PROJECT"
  git -C "$PROJECT" add -A
  log_ok "initialized Git repository"
fi

if [[ "$DO_BUILD" -eq 1 ]] && command -v go >/dev/null 2>&1; then
  if (cd "$PROJECT" && GOWORK=off go build ./...); then
    log_ok "go build ./... passed"
  else
    log_warn "go build ./... failed; inspect the generated project before using it"
  fi
fi

if [[ "$KEEP_GIT" -eq 1 ]]; then
  # 合并进已有仓库，保留 .git 与 remote，不清空用户已有文件。
  cp -a "$PROJECT/." "$TARGET/"
  if [[ "$GIT_INIT" -eq 1 ]]; then
    git -C "$TARGET" add -A
    log_ok "staged generated files in existing Git repository"
  fi
else
  if [[ -d "$TARGET" ]]; then
    rmdir "$TARGET" 2>/dev/null || die "cannot replace target directory: $TARGET"
  fi
  mv "$PROJECT" "$TARGET"
fi

log_ok "project created: $TARGET"
printf '  module:   %s\n  service:  %s\n  template: %s@%s\n' \
  "$MODULE" "$SERVICE" "$REPO" "$REF"
printf '\nNext steps:\n  cd %s\n  set mysql.database in etc/config_<env>.yaml\n  edit migrations/ and README.md\n  go run .\n' "$TARGET"
if [[ "$KEEP_GIT" -eq 1 && "$GIT_INIT" -eq 1 ]]; then
  printf '  git commit -m "feat: initialize from ginctl2 skeleton" && git push\n'
fi
