## 服务监控与清理脚本

首次配置：

```bash
cd /root/code/deployer/operator/monitor
cp monitor-modules.conf.template monitor-modules.conf
cp .env.template .env
chmod 600 .env
```

`monitor-modules.conf` 每行一个模块名。`.env` 可设置 `NOTIFY_DINGDING`、`NOTIFY_FEISHU`、`DINGTALK_NEED_AT`、`NOTIFY_FROM`；通知凭据分别放在对应通知目录的 `.env` 中。`NOTIFY_FEISHU` 仅控制服务日志监控 `monitor.sh` 的飞书通知。
已有 `modules.conf` 需改名为 `monitor-modules.conf`。

### `monitor.sh`

- 运行位置：服务部署节点
- 运行方式：通常配置为周期性任务执行
- 输入参数：无
- 配置文件：`monitor-modules.conf`、`.env`
- 作用：比较各模块当前部署目录中的错误日志增量，发现新增错误时发送钉钉/飞书告警，恢复后发送恢复通知
- 日志文件：`/opt/logs/monitor.log`

### `monitor-host.sh`

- 运行位置：服务部署节点
- 运行方式：通常配置为周期性任务执行
- 输入参数：无
- 配置文件：`.env`，主要使用 `DISK_USAGE_THRESHOLD`（大于 0 且小于 100 才启用）、`SSL_VALID_THRESHOLD`（大于 0 才启用，自动限制在 3 至 90 天）、`NOTIFY_FROM`
- 作用：检查根分区 `/` 使用率，超过有效磁盘阈值时发送飞书磁盘空间告警；证书监控启用时依次检查 `/opt/certbot/bin/certbot`、`/usr/local/bin/certbot`、`/usr/bin/certbot`，找到后检查证书有效期，临近到期或 certbot 标记为已过期时发送续签提醒；以上主机监控告警均使用 `default_notify` 场景，候选命令均不可用时也通过该场景发送 certbot 工具失效提醒。主机监控告警不受 `NOTIFY_FEISHU` 控制
- 日志文件：`/opt/logs/monitor-host.log`

### `cleanup-item.py`

- 运行位置：服务部署节点
- 运行方式：建议使用手动执行方式，也可配置为周期性任务执行
- 输入参数：无；配置文件固定读取同目录的 `cleanup_rules.yaml`
- 配置文件：`cleanup_rules.yaml`
- 作用：按 YAML 规则清理指定文件或目录，支持保留数量、排序方式、删除前确认和 `dry_run` 模式；依赖 PyYAML
- 日志文件：`/opt/logs/cleanup-item.log`

清理脚本依赖 PyYAML。先复制 `cleanup_rules.yaml.tempate` 为 `cleanup_rules.yaml`，确认规则中的 `type`、`path`、`prefix`、`suffix`、`keep_count` 和 `sort_by`，并先使用 `dry_run: true` 验证匹配结果；关闭 dry-run 后仍会逐项要求在 5 秒内输入 `y` 确认删除。
