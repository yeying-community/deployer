# 设计与提案规范索引

本目录用于沉淀社区协作中的规范文档、提案模板与提交流程，帮助新贡献者快速进入可评审状态。

## 文档索引

- [DOCUMENTATION_GUIDELINES.md](./DOCUMENTATION_GUIDELINES.md)
  各项目文档职责、质量要求、维护方法和发布前检查；要求每个项目维护独立的关键概念文档

- [KEY_CONCEPTS_TEMPLATE.md](./KEY_CONCEPTS_TEMPLATE.md)
  项目关键概念文档模板，用于集中解释核心概念及其边界

- [DESIGN_PROPOSAL_TEMPLATE.md](./DESIGN_PROPOSAL_TEMPLATE.md)  
  社区评审使用的详细设计方案模板（含 AI 协作记录与提示词模板）

- [DEPLOYMENT_TEMPLATE.md](./DEPLOYMENT_TEMPLATE.md)  
  部署文档模板（含部署步骤、验证、回滚和 AI 编写约束）

- [NOTIFICATION_TEMPLATE.md](./NOTIFICATION_TEMPLATE.md)  
  通知模板（含发布通知、系统错误通知、重要事件通知和通用通知）

- [README_TEMPLATE.md](./README_TEMPLATE.md)  
  项目 README 编写模板与说明

- [GITHUB_FORK.md](./GITHUB_FORK.md)  
  Fork 协作流程说明

- [GITHUB_PULL_REQUEST.md](./GITHUB_PULL_REQUEST.md)  
  Pull Request 提交流程与规范

- [PACKAGING.md](./PACKAGING.md)  
  按可部署单元定义服务、静态资源和多产物仓库的打包契约

- [PACKAGING_AUDIT.md](./PACKAGING_AUDIT.md)
  node、warehouse、router、chat、homepage、project、social、knowledge、orchestrator、books、billing 的兼容性现状与接入缺口

- [UPGRADE.md](./UPGRADE.md)  
  升级操作说明（含打包上传、升级执行、模块差异、验证与回退）

- [LOGGING.md](./LOGGING.md)  
  社区后台服务日志规范（含 `ERROR`/`FATAL` 结构化错误事件契约、根因分析字段、日志文件职责与示例）

- [API_SPECIFICATION.md](./API_SPECIFICATION.md)  
  后端接口规范（含 `public`、`admin`、`internal` 分类、路径规则与兼容要求）

- [HEALTH_CHECK.md](./HEALTH_CHECK.md)
  项目健康检查脚本规范（含统一入口、检查层级、参数、退出码、JSON 输出与升级接入流程）

- [AUTOMATED_TESTING.md](./AUTOMATED_TESTING.md)
  项目自动化测试脚本规范（含测试分层、统一入口、报告格式、测试数据隔离与升级后 smoke 测试）

## 新人最短路径（建议）

1. 在社区 Issue/讨论中认领需求，补齐背景与目标。
2. 使用 `DESIGN_PROPOSAL_TEMPLATE.md` 输出详细设计方案。
3. 在方案中补全附录 `AI 协作记录`，明确人工最终判断。
4. 提交方案到社区评审，按意见迭代到 `Approved` 状态。
5. 评审通过后再进入开发、联调、测试与 PR 合并流程。

## 文件命名建议

方案文档建议放在具体项目目录下并采用固定命名，便于检索和追踪：

- `spec-<topic>-v0.1.md`
- `spec-<topic>-v0.2.md`
- `spec-<topic>-final.md`

示例：

- `spec-wallet-batch-transfer-v0.1.md`

## 提审最低要求

- 目标与非目标清晰
- 候选方案对比充分
- 接口与数据变更明确
- 测试与回滚方案可执行
- 风险清单与监测信号完整
- AI 产出可追溯、人工判断可解释
