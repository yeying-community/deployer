## 数据库备份上传脚本

### `upload_database_backup.sh`

- 运行位置：服务部署节点
- 运行方式：通常配置为周期性任务执行；也可手动执行上传或下载
- 输入参数：无参数或 `upload` 上传最新备份；`download <本地目录>` 下载远端备份
- 配置文件：`backup.conf`、`.env`；无独立 `.env` 时回退使用 `common/.env`
- 作用：按模块查找最新 PostgreSQL `.sql.gz` 备份并上传到 WebDAV，或将远端备份下载到指定目录，并发送飞书结果通知
- 日志文件：`/opt/logs/upload-database-backup.log`
