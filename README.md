# gincli

Gin 项目脚手架：一个脚本从 GitHub 拉取 [ginctl2](https://github.com/JCCGGKS/ginctl2) 骨架，替换占位符并初始化成新项目。

## 用法

```bash
./init.sh [options] <target-dir> [module-path] [service-name] [db-name]
```

options：

| 选项 | 说明 |
|------|------|
| `--repo owner/name` | 模板 GitHub 仓库（默认 `JCCGGKS/ginctl2`） |
| `--ref ref` | 分支 / 标签 / 提交（默认 `master`） |
| `--no-git` | 不初始化 Git 仓库 |
| `--no-build` | 不执行 `go build ./...` |
| `--force` | 目标目录非空时先删除再重建 |
| `-h, --help` | 显示帮助 |

`module-path`、`service-name`、`db-name` 可省略，从目标目录名推导：

| 参数 | 默认值 |
|------|--------|
| module-path | 目标目录名 |
| service-name | module-path 最后一段 |
| db-name | service-name 的 `.`/`-` 转为 `_` 并小写 |

示例：

```bash
# 全部默认：module=order-svc service=order-svc db=order_svc
./init.sh ../order-service

# 显式指定
./init.sh ../order-service github.com/acme/order-service order-service order_service

# 离线时跳过构建
./init.sh --no-build ../order-service
```

## 脚本做了什么

1. 用 `curl`（或 `wget`）从 `https://codeload.github.com/<repo>/tar.gz/<ref>` 下载模板归档。
2. 解压、去掉归档顶层目录，用 `cp -a` 保留权限位复制到暂存目录。
3. 用 `perl` 单次扫描替换占位符（插入的值不会被再次替换）：

   | 占位符 | Go 文件 | go.mod | 其它文本文件 |
   |--------|---------|--------|--------------|
   | `"gin-scaffold"` | 服务名（独立 ClientName） | — | — |
   | `gin-scaffold` | Go module 路径 | Go module 路径 | 服务名 |
   | `ginctl` | 服务名 | — | 服务名 |
   | `gin_scaffold` | 数据库名 | — | 数据库名 |

   `go.sum` 和二进制文件保持不变。
4. 可选执行 `git init` + `git add -A` 和 `go build ./...`（构建失败只告警）；最后把暂存目录移动到目标路径，失败时自动清理暂存目录。

依赖：bash、curl 或 wget、tar、perl、grep、find；git 和 go 可选。
