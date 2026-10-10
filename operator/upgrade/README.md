## 编译、制品传输与升级脚本

### `compile_packages.sh`

- 运行位置：代码编译节点
- 运行方式：通常配置为周期性任务执行
- 输入参数：无
- 配置文件：`modules.conf`、`.env`
- 作用：检查模块代码更新，执行打包、校验和 WebDAV 上传，并生成版本变更说明和通知
- 日志文件：`/opt/logs/check-code-status.log`

### `transfer_packages.sh`

- 运行位置：代码编译节点或服务部署节点
- 运行方式：通常由编译/升级脚本调用，也可手动执行
- 输入参数：`upload <文件名>` 或 `download <文件名>`
- 配置文件：`.env`，使用 `WEBDAV_PACKAGE_BASE_URL`、`WEBDAV_PACKAGE_AK`、`WEBDAV_PACKAGE_SK`
- 作用：在本地 `/opt/package` 与 WebDAV 制品目录之间上传或下载单个版本包
- 日志文件：`/opt/logs/transfer-packages.log`

### `upgrade.sh`

- 运行位置：服务部署节点
- 运行方式：通常配置为周期性任务执行
- 输入参数：无
- 配置文件：`modules.conf`、`.env`
- 作用：读取模块列表，比较远端和当前版本，下载并校验新制品，调用对应模块升级脚本完成升级
- 日志文件：`/opt/logs/upgrade.log`

### `upgrade_chat.sh`

- 运行位置：`chat` 服务部署节点
- 运行方式：通常由 `upgrade.sh` 调用，也可手动执行
- 输入参数：`<当前版本> <目标版本>`
- 配置文件：`.env`，可配置 `WAIT_SECONDS`、`RETRY_TIMES`
- 作用：停止旧版本 chat，复制升级所需文件，启动目标版本并执行健康检查
- 日志文件：`/opt/logs/upgrade-chat.log`

### `upgrade_node.sh`

- 运行位置：`node` 服务部署节点
- 运行方式：通常由 `upgrade.sh` 调用，也可手动执行
- 输入参数：`<当前版本> <目标版本>`
- 配置文件：`.env`，可配置 `WAIT_SECONDS`、`RETRY_TIMES`
- 作用：升级 node 服务，调整目标版本启动脚本的密码文件处理逻辑，启动并健康检查
- 日志文件：`/opt/logs/upgrade-node.log`

### `upgrade_project.sh`

- 运行位置：`project` 服务部署节点
- 运行方式：通常由 `upgrade.sh` 调用，也可手动执行
- 输入参数：`<当前版本> <目标版本>`
- 配置文件：`.env`，可配置 `WAIT_SECONDS`、`RETRY_TIMES`
- 作用：停止旧版本 project，执行升级文件复制，启动目标版本并健康检查
- 日志文件：`/opt/logs/upgrade-project.log`

### `upgrade_router.sh`

- 运行位置：`router` 服务部署节点
- 运行方式：通常由 `upgrade.sh` 调用，也可手动执行
- 输入参数：`<当前版本> <目标版本>`
- 配置文件：`.env`，可配置 `WAIT_SECONDS`、`RETRY_TIMES`
- 作用：停止旧版本 router，执行升级文件复制，启动目标版本并健康检查
- 日志文件：`/opt/logs/upgrade-router.log`

### `upgrade_social.sh`

- 运行位置：`social` 服务部署节点
- 运行方式：通常由 `upgrade.sh` 调用，也可手动执行
- 输入参数：`<当前版本> <目标版本>`
- 配置文件：`.env`，可配置 `WAIT_SECONDS`、`RETRY_TIMES`
- 作用：升级 social 后端，同时发布前端静态文件并重启 Nginx，最后执行健康检查
- 日志文件：`/opt/logs/upgrade-social.log`

### `upgrade_warehouse.sh`

- 运行位置：`warehouse` 服务部署节点
- 运行方式：通常由 `upgrade.sh` 调用，也可手动执行
- 输入参数：`<当前版本> <目标版本>`
- 配置文件：`.env`，可配置 `WEBDAV_FLAG`、`WAIT_SECONDS`、`RETRY_TIMES`
- 作用：按 `WEBDAV_FLAG` 升级 warehouse 后端、前端或全部组件，并执行健康检查/重启 Nginx
- 日志文件：`/opt/logs/upgrade-warehouse.log`
