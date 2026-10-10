## 配置备份上传脚本

### `upload_config_backup.sh`

- 运行位置：服务部署节点
- 运行方式：通常配置为周期性任务执行，也可手动指定模块执行
- 输入参数：`[模块名 ...]`；不传参数时读取 `backup.conf`
- 配置文件：`backup.conf`、`.env`；各模块的 `/data/<模块名>/backup.conf`
- 作用：查找当天或昨天最新的配置备份文件，通过 `common/transfer_file.sh` 上传到 WebDAV，并发送飞书结果通知
- 日志文件：`/opt/logs/upload-config-backup.log`
