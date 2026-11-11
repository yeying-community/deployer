# deployer

用于沉淀部署、基础设施、中间件、运维脚本和社区协作规范的工具仓库。

这个仓库的目标不是只放单一项目代码，而是为社区成员提供一套可复用的部署资产、环境模板、脚本工具和提交流程。

## 目录说明

- `community/`
  社区开放能力、SDK 或 OpenAPI 相关内容

- `compliance/`
  合规、安全或认证相关材料

- `developer/`
  开发环境、语言工具链、操作系统和 Git 使用说明

- `infra/`
  基础设施相关内容，例如链节点、证书、容器运行环境

- `middleware/`
  常用中间件部署模板，例如 Redis、MySQL、PostgreSQL、MinIO、Kafka

- `operator/`
  运维脚本、升级脚本、监控和变更辅助工具

- `scripts/`
  通用辅助脚本，以及仓库协作流程脚本

- `specification/`
  社区提案、README、打包和 PR 流程等规范模板

## 开发与协作入口

新贡献者建议先看这里：

- [specification/README.md](./specification/README.md)
- [specification/DESIGN_PROPOSAL_TEMPLATE.md](./specification/DESIGN_PROPOSAL_TEMPLATE.md)
- [specification/GITHUB_FORK.md](./specification/GITHUB_FORK.md)
- [specification/GITHUB_PULL_REQUEST.md](./specification/GITHUB_PULL_REQUEST.md)
- [specification/LOGGING.md](./specification/LOGGING.md)

推荐流程：

1. 先在社区中认领需求或问题。
2. 使用设计模板输出详细方案，并完成评审。
3. 评审通过后再开发、联调和提 PR。
4. 使用仓库脚本同步 fork 并创建 PR。

## 常用脚本

- `./scripts/sync.sh`
  将当前分支同步到 `upstream/<current-branch>`，并推送到 `origin`

- `./scripts/merge.sh main`
  将当前分支推送到 fork，并基于 GitHub CLI 创建到 `upstream/main` 的 PR

## 中间件示例

`middleware/` 下每个子目录通常包含：

- `docker-compose.yml`
- `.env.template` 或其他配置模板
- `README.md`
- 启动、测试或验证脚本

例如 Redis 目录已提供密码模板和密码生成命令说明：

- [middleware/redis/.env.template](./middleware/redis/.env.template)

## 部署约定

- 所有编译后的二进制文件统一放到 `$HOME/.yeying/bin`
- 将该目录加入环境变量 `PATH`
- 脚本中直接使用二进制文件名启动，不写死绝对路径

示例：

```bash
export PATH="$PATH:$HOME/.yeying/bin"
```
