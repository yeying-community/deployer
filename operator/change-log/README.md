## 版本变更说明脚本

### `release_notes.sh`

- 运行位置：代码编译节点
- 运行方式：通常手动执行，也可由 `upgrade/compile_packages.sh` 调用或配置为周期性任务执行
- 输入参数：无参数；`--module <模块名>` 仅处理指定模块
- 配置文件：`modules.conf`、`.env`
- 作用：比较模块 Git 仓库的版本标签与默认远程分支，生成提交和文件变更说明，写入临时/归档文件并发送飞书通知
- 日志文件：`/opt/logs/generate-release-notes.log`
