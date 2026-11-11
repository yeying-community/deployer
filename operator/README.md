# 运维脚本

此目录用于存放社区项目的编译、升级、监控、备份、通知、错误分析和变更辅助脚本。

打包和升级分别由 [`package/README.md`](./package/README.md) 与
[`upgrade/README.md`](./upgrade/README.md) 说明：前者负责创建、校验和发布制品；后者负责在服务节点部署制品。
跨项目的正式规范见
[`../specification/UPGRADE.md`](../specification/UPGRADE.md) 和
[`../specification/PACKAGING.md`](../specification/PACKAGING.md)。

## 目录说明

### `common/`

规划为公共函数、可复用脚本放在该目录下。

### `upgrade/`

提供统一的 `upgrade.sh`、静态制品部署器和升级配置。项目定制升级逻辑不放在本目录；
纳入统一升级流程的模块必须在安装包中提供 `scripts/upgrade.sh`，由统一入口按标准钩子调用。

### `package/`

提供 `compile_packages.sh`、自动打包、manifest 校验、WebDAV 制品传输和打包配置；
运行说明见该目录 README。升级入口会调用这里的传输脚本和 manifest 校验器。

### `monitor/`

服务监控的相关脚本统一放在该目录下。

### `change-log/`

版本变更说明相关脚本统一放在该目录下。

### `dingtalk-notify/`

钉钉通知相关的脚本统一放在该目录下。

### `feishu-notify/`

飞书通知相关的脚本统一放在该目录下。

### `backup-config/`

配置文件备份相关的脚本统一放在该目录下。

### `backup-database/`

数据库备份相关的脚本统一放在该目录下。

### `analyer/`

按模块读取当天 `logs/error.log`，对错误脱敏、去重并调用 Codex CLI 生成只读根因分析报告。
目录名沿用现有仓库命名（`analyer`），入口和配置说明见其 README。

## 通用约定

- 运行前先阅读对应子目录 README，并从 `.env.template`、`*.template` 创建本地配置；模板文件名以目录实际内容为准。
- 凭据只保存在部署节点的未纳入 Git 的配置文件中，不写入脚本、示例或日志。
- 脚本默认将运行日志写入 `/opt/logs`；具体文件名以子目录 README 和脚本实现为准。通知脚本本身通常只写标准输出。
- 需要定时运行的脚本应使用 `flock` 避免并发执行，并在部署节点验证权限、路径和通知配置。
