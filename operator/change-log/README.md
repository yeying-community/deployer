## 版本变更说明脚本

首次配置：

```bash
cd /root/code/deployer/operator/change-log
cp release-notes-modules.conf.example release-notes-modules.conf
cp .env.template .env
chmod 600 .env
```

每行填写一个待生成发布说明的源码仓库名。现有 `modules.conf` 需改名为
`release-notes-modules.conf`；脚本只读取新文件名，不再回退读取旧配置。

模块仓库默认位于 `/root/code/<模块名>`，默认比较 `origin` 默认分支与最新 `v<major>.<minor>.<patch>` 标签。可用 `RELEASE_NOTES_CODEX_BIN` 指定 Codex CLI；通知开关为 `NOTIFY_DINGDING`、`NOTIFY_FEISHU`。

### `release_notes.sh`

- 运行位置：代码编译节点
- 运行方式：通常手动执行，也可由 `package/compile_packages.sh` 调用或配置为周期性任务执行
- 输入参数：无参数处理全部模块；`--module <模块名>` 仅处理指定模块
- 配置文件：`release-notes-modules.conf`、`.env`
- 作用：比较模块 Git 仓库的版本标签与默认远程分支，生成提交和文件变更说明，写入临时/归档文件并发送飞书通知
- 日志文件：`/opt/logs/generate-release-notes.log`

输出先写入 `/tmp/release_notes_<模块名>.md`，随后尝试追加到 `/opt/package/release_notes_<模块名>.md`；相同版本范围不会重复追加。
