# gincli

Gin 项目脚手架：一个脚本从 GitHub 拉取 [ginctl2](https://github.com/JCCGGKS/ginctl2) 骨架，替换占位符并初始化成新项目。

## 用法

```bash
./init.sh [options] <target-dir> [module-path] [service-name]
```

options：

| 选项 | 说明 |
|------|------|
| `--repo owner/name` | 模板 GitHub 仓库（默认 `JCCGGKS/ginctl2`） |
| `--ref ref` | 分支 / 标签 / 提交（默认 `master`） |
| `--no-git` | 不初始化 Git 仓库 |
| `--no-build` | 不执行 `go build ./...` |
| `--force` | 目标目录非空时先删除再重建（会删掉 `.git`，慎用） |
| `--keep-git` | 目标已是 Git 仓库时保留 `.git`/remote，只把生成文件合并进去 |
| `-h, --help` | 显示帮助 |

`module-path`、`service-name` 可省略，从目标目录名推导：

| 参数 | 默认值 |
|------|--------|
| module-path | 目标目录名 |
| service-name | module-path 最后一段 |

**数据库名不在脚本里处理**：模板中的 `gin_scaffold` 占位符会原样保留，请自行在 `etc/config_<env>.yaml` 里设置 `mysql.database`。

示例：

```bash
# 全部默认：module=order-svc service=order-svc
./init.sh ../order-service

# 显式指定
./init.sh ../order-service github.com/acme/order-service order-service

# 离线时跳过构建
./init.sh --no-build ../order-service

# 目标是从 GitHub 克隆下来的已有仓库：保留 .git 和 remote
./init.sh --keep-git ../llmgateway
```

## 脚本做了什么

1. 用 `curl`（或 `wget`）从 `https://codeload.github.com/<repo>/tar.gz/<ref>` 下载模板归档。
2. 解压、去掉归档顶层目录，用 `cp -a` 保留权限位复制到暂存目录。骨架自带的 `README.md` 和 `.gitignore` 不沿用：`.gitignore` 总是重新生成，README 仅在目标目录没有时新建（已有则保留）。
3. 用 `perl` 单次扫描替换占位符（插入的值不会被再次替换）：

   | 占位符 | Go 文件 | go.mod | 其它文本文件 |
   |--------|---------|--------|--------------|
   | `"gin-scaffold"` | 服务名（独立 ClientName） | — | — |
   | `gin-scaffold` | Go module 路径 | Go module 路径 | 服务名 |
   | `ginctl` | 服务名 | — | 服务名 |

   `gin_scaffold`（数据库名）**不替换**，留给你在配置里自己定义。`go.sum` 和二进制文件保持不变。
4. 可选执行 `git init`（只建空仓库，**不会** `git add` / `commit` / `push`，这些交给使用者自己决定）和 `go build ./...`（构建失败只告警）；最后把暂存目录移动到目标路径，失败时自动清理暂存目录。

依赖：bash、curl 或 wget、tar、perl、grep、find；git 和 go 可选。
