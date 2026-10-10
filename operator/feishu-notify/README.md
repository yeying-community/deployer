## 飞书通知脚本

### `common.sh`

- 运行位置：代码编译节点或服务部署节点
- 运行方式：由其他 Bash 脚本 `source` 调用
- 输入参数：无独立命令行参数；提供 `send_feishu_message <场景> <消息>` 函数
- 配置文件：`.env`
- 作用：加载飞书场景配置并封装对 `feishu_reminder.py` 的调用
- 日志文件：由调用脚本记录到其 `/opt/logs/*.log`

### `feishu_reminder.py`

- 运行位置：代码编译节点或服务部署节点
- 运行方式：通常由 `feishu-notify/common.sh` 或其他脚本调用，也可手动执行
- 输入参数：`<场景> <消息>`；或使用 `--webhook`、`--secret`、`--prefix`、`--message`/`--file`、`--chunk-size`
- 配置文件：`.env`；按场景配置 `<场景大写>_WEBHOOK_URL`、`<场景大写>_SECRET`、`<场景大写>_PREFIX`
- 作用：向飞书机器人发送文本消息，支持按长度分块和从文件读取消息
- 日志文件：无独立日志文件；标准输出和错误输出由调用脚本重定向到其 `/opt/logs/*.log`
