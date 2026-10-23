# ERROR 根因分析与问题审计生产适配器

该目录是 `yeying-ops` 在生产环境中的部署入口。根因分析、日志游标、问题审计协议和 Project 对账逻辑由 Marketplace 发布的 `yeying-ops` Skill 提供；deployer 只保留生产配置、模块清单、cron 入口、兼容命令和通知适配。

完整流程：

```text
cron
  -> 已安装的 yeying-ops
  -> 增量日志收集和脱敏根因分析
  -> yeying-project 创建或更新问题审计任务
  -> 等待人工结构化审计结论
  -> 审计批准时创建独立修复任务
  -> 修复任务走标准研发、验证和 PR 流程
  -> 部署后再次观察并提供关闭证据
```

定时任务不会直接修改代码、生产配置、数据库或服务，也不会推送 GitHub、创建修复 PR、部署或重启服务。

## Skill 安装

生产运行用户需要安装：

```text
/root/.codex/skills/yeying-ops
/root/.codex/skills/yeying-project
```

也可以设置：

```bash
export YEYING_OPS_HOME=/custom/path/yeying-ops
```

`run_analyzer.sh` 默认通过 `command -v bash` 查找 Bash。生产环境如需固定解释器路径，可以设置：

```bash
export BASH_COMMAND_PATH=/usr/bin/bash
```

脚本使用交互式 Bash 加载现有环境，因此应确保所选 Bash 的启动配置不会输出无关内容，也不会阻塞非人工执行。

`run_analyzer.sh` 调用：

```text
${YEYING_OPS_HOME}/scripts/ops_workflow.py
```

`analyze_errors.py` 是兼容入口，只执行 Skill 的 `analyze` 子命令。完整生产流程应使用 `run_analyzer.sh` 或直接运行 `ops_workflow.py run`。

## 配置

```bash
cd /root/code/deployer/operator/analyer
cp analyzer.conf.example analyzer.conf
cp modules.conf.example modules.conf
chmod 700 /root/code/deployer/operator/analyer
chmod 600 analyzer.conf modules.conf
```

`analyzer.conf` 是 JSON。主要配置包括：

- `deploy_root`：生产模块部署根目录。
- `modules_file`：每行一个模块名。
- `state_db`：日志游标、每日观测、finding 状态和 Project 任务关联。
- `results_dir`：结构化 finding 和日报。
- `work_dir`：Codex 临时结果。
- `lock_file`：完整流程的内部互斥锁。
- `codex_command`：生产 Codex CLI 的绝对路径。
- `model`：建议明确填写实际批处理模型；留空时结果会记录模型信息缺失。
- `project`：问题审计任务和修复任务配置。

Project AK/SK 不放在 `analyzer.conf`，继续由 `yeying-project` 从以下位置读取：

```text
/root/.yeying/skills/project/config.toml
```

示例：

```toml
[project]
url = "https://project.example.com"
access_key = "your-access-key"
secret_key = "your-secret-key"
```

配置权限应为 `0600`。Project 令牌需要读取任务和讨论、创建任务、追加评论等权限。

`project.enabled=true` 时启用审计闭环。`project.required=false` 表示 Project 暂时不可用时保留本地 finding，后续 cron 自动重试，而不是丢失分析结果。

`allowed_auditor_ids` 必须只包含有权审核生产问题的 Project 用户 ID。审计决定中的 `approved_by.user_id` 必须和实际评论发送人一致。

## 演练

演练不会调用 Codex、不会推进日志游标、不会写 Project：

```bash
YEYING_OPS_HOME=/root/.codex/skills/yeying-ops \
  /usr/bin/python3 /root/.codex/skills/yeying-ops/scripts/ops_workflow.py \
  run --config /root/code/deployer/operator/analyer/analyzer.conf --dry-run
```

只分析某个模块：

```bash
./run_analyzer.sh --module router --dry-run
```

处理历史日期：

```bash
./run_analyzer.sh --date 2026-10-22 --dry-run
```

## Cron

`cron.example` 使用 `/etc/crontab` 格式，默认每天 23:00 运行：

```text
0 23 * * * root /usr/bin/flock -n /run/lock/deployer-error-analyzer.lock /root/code/deployer/operator/analyer/run_analyzer.sh >> /opt/logs/error-analyzer.log 2>&1
```

外层 `flock` 防止调度器重复启动，Skill 内部 `lock_file` 保护分析和 Project 对账的完整事务。不要同时在 root crontab 和 `/etc/crontab` 安装同一个任务。

生产包装脚本会加载 root 的交互 shell 环境，以兼容已有 Codex 凭证配置；随后执行完整 workflow，并复用 `monitor_service` 飞书场景发送日报。

## 输出和状态

- `state.db`：日志游标、每日观测、finding、重试状态、审计任务和修复任务关联。
- `state.db-wal`、`state.db-shm`：SQLite WAL 文件。
- `results/YYYY-MM-DD/<module>/<finding-id>.json`：单个结构化 finding。
- `results/YYYY-MM-DD/summary.json`：机器可读日报。
- `results/YYYY-MM-DD/summary.md`：人工日报。
- `work/`：模型调用的临时输出，调用结束后删除。

这些文件以及 `analyzer.conf`、`modules.conf` 都不得提交 Git。

## 问题审计

分析成功后，`yeying-ops` 会为每个 eligible finding 创建或复用一个 `[生产问题审计]` 任务。再次发生的同类错误更新原任务，不会每天重复创建。

人工审计必须提交 `yeying.ops.audit-decision.v1` JSON。支持：

- `remediate`：创建独立修复任务。
- `monitor`：继续观察。
- `false_positive`：记录误报。
- `needs_more_evidence`：补充证据后重新分析。

完整 JSON 示例和字段说明位于已安装 Skill 的 `README_CN.md`。

审计结论只允许创建修复任务。修复任务仍必须由 Agent 使用 `yeying-project` 完成分析、方案确认、实现、验证和执行归档，并使用 `yeying-github` 提交 PR。

## 路径兼容

历史目录名称是 `operator/analyer`。虽然正确拼写应为 `analyzer`，当前版本保留旧路径，避免破坏已有 cron、配置和生产脚本。后续迁移应先增加兼容入口，再逐步修改生产引用。

## 验证

```bash
python3 -m unittest discover -s operator/analyer/tests -p 'test_*.py' -v
python3 -m py_compile operator/analyer/analyze_errors.py
bash -n operator/analyer/run_analyzer.sh
python3 -m json.tool operator/analyer/analyzer.conf.example >/dev/null
```
