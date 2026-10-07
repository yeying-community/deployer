# ERROR 根因分析器

该目录提供一个无第三方依赖的 Python 编排器：读取指定模块当天的
`logs/error.log`，做脱敏、规范化、指纹去重和预算控制，然后使用已配置好的
Codex CLI 进行只读根因分析。它不修改 `operator/monitor`，也不会根据分析结果自动修复服务。

## 配置

```bash
cd /root/code/deployer/operator/analyer
cp analyzer.conf.example analyzer.conf
cp modules.conf.example modules.conf
chmod 700 /root/code/deployer/operator/analyer
chmod 600 /root/code/deployer/operator/analyer/analyzer.conf
```

确认 `analyzer.conf` 中的 `codex_command`、日志根目录、结果目录和模块列表后再运行。
状态库、结果和工作文件默认都放在本目录下，不需要额外创建运行环境。

## 演练

```bash
python3 /root/code/deployer/operator/analyer/analyze_errors.py \
  --config /root/code/deployer/operator/analyer/analyzer.conf \
  --dry-run
```

演练不会调用 Codex，只生成待分析分组和预算结果。指定历史日期可使用
`--date YYYY-MM-DD`；只分析某个模块可使用 `--module router`。

## Cron

`cron.example` 是 `/etc/crontab` 格式，默认每天 23:00 运行。安装前确认
`flock`、Python、Codex 的绝对路径和运行用户权限；不要同时把同一个任务写入
root 用户 crontab 和 `/etc/crontab`。

## 输出

- `state.db`：指纹、状态、次数、重试和结果路径
- `results/YYYY-MM-DD/<module>/<fingerprint>.json`：单组结构化结果
- `results/YYYY-MM-DD/summary.json` 和 `summary.md`：当天汇总
- `work/`：Codex 调用期间的临时文件，成功或失败后删除

Codex 非零退出、超时、非法 JSON 或结果字段不完整时不会标记成功，状态会保留
为 `failed`，下次达到退避时间后可重试。
