## 服务监控与清理脚本

### `monitor.sh`

- 运行位置：服务部署节点
- 运行方式：通常配置为周期性任务执行
- 输入参数：无
- 配置文件：`modules.conf`、`.env`
- 作用：比较各模块当前部署目录中的错误日志增量，发现新增错误时发送钉钉/飞书告警，恢复后发送恢复通知
- 日志文件：`/opt/logs/monitor.log`

### `monitor-host.sh`

- 运行位置：服务部署节点
- 运行方式：通常配置为周期性任务执行
- 输入参数：无
- 配置文件：`.env`，主要使用 `DISK_USAGE_THRESHOLD`、`NOTIFY_FEISHU`
- 作用：检查根分区 `/` 使用率，超过阈值时发送飞书磁盘空间告警
- 日志文件：`/opt/logs/monitor-host.log`

### `cleanup-item.py`

- 运行位置：服务部署节点
- 运行方式：建议使用手动执行方式，也可配置为周期性任务执行
- 输入参数：无
- 配置文件：`cleanup_rules.yaml`
- 作用：按 YAML 规则清理指定文件或目录，支持保留数量、排序方式、删除前确认和 `dry_run` 模式；依赖 PyYAML
- 日志文件：`/opt/logs/cleanup-item.log`
