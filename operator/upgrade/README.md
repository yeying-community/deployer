# 统一升级

本目录只负责服务节点上的运行时升级，包括服务模块切换、静态站点部署、升级配置和项目升级钩子。打包、WebDAV 制品传输和 manifest 校验由 [`../package/README.md`](../package/README.md) 负责。

跨项目安装包契约见 [`../../specification/PACKAGING.md`](../../specification/PACKAGING.md)，升级流程见 [`../../specification/UPGRADE.md`](../../specification/UPGRADE.md)。当前统一升级的服务模块为 `chat`、`node`、`project`、`router`、`social`、`warehouse` 和 `billing`。静态站点只会在 `static-units.conf` 配置后参与升级；desktop artifact 当前不会由升级器部署。

静态站点统一部署到 `/opt/deploy/static/<site_id>`，Web 服务器 root 指向 `current`，版本包保存在 `releases/`。启用站点前，先将 vhost root 迁移至标准 `current` 目录；warehouse 的 `/usr/share/nginx/html/webdav` 仍需单独迁移。

## 首次配置

在服务部署节点执行：

```bash
cd /root/code/deployer/operator/upgrade
cp upgrade-modules.conf.template upgrade-modules.conf
cp static-units.conf.template static-units.conf
cp .env.template .env
chmod 600 .env
```

`upgrade-modules.conf` 是已有服务的升级名单，只能填写已经部署且允许参与本轮升级检查的模块。纯静态升级可以不创建该文件，但 `static-units.conf` 必须至少有一条有效站点配置。配置了服务名单时，`upgrade.sh` 仍会检查名单中的每个服务。

`static-units.conf` 每行使用 `repository unit_id site_id health_base_url` 格式。只有在 vhost 已指向 `/opt/deploy/static/<site_id>/current` 且健康 URL 能从该节点访问后，才启用对应行。

`.env` 保存本机 WebDAV 凭据和升级行为配置，不要提交到 Git。常用配置项：

- `WEBDAV_PACKAGE_BASE_URL`、`WEBDAV_PACKAGE_AK`、`WEBDAV_PACKAGE_SK`：制品目录和凭据。
- `HEALTH_CHECK_INITIAL_WAIT_SECONDS`：启动后第一次健康检查前等待的秒数，默认 `0`。
- `WAIT_SECONDS`、`RETRY_TIMES`：健康检查失败后的重试间隔和次数，默认 `2` 秒和 `10` 次。
- `FILE_VERIFY`：可选 `sha256sum` 或 `md5sum`；为空时不使用 sidecar 校验文件。
- `NOTIFY_DINGDING`、`NOTIFY_FEISHU`、`NOTIFY_SAME_VERSION`：通知开关。

升级节点必须能访问 WebDAV，并能读写 `/opt/package`、`/opt/deploy`、`/opt/logs` 及服务启停所需资源。目标模块必须已部署；本入口不负责首次安装。

部署仓库时，`operator/package/transfer_packages.sh` 和 `operator/package/package_manifest.sh` 必须与本目录一同存在。升级脚本会把本机 `upgrade/.env` 路径传给共享传输脚本，因此升级节点无需另配打包目录的凭据文件。

## 执行升级

升级前确认目标制品已由打包流程发布到 WebDAV，并且本机配置名单正确：

```bash
cd /root/code/deployer/operator/upgrade
./upgrade.sh
```

远程服务包版本只有严格高于本地版本时才会升级。静态 artifact 按 `static-units.conf` 中的站点选择，manifest 与归档校验通过后原子切换 `current`；HTTP 健康检查失败时会恢复旧链接。升级结果查看：

```bash
less /opt/logs/upgrade.log
readlink -f /opt/deploy/<module>
cd /opt/deploy/<module>
bash scripts/health-check.sh --level all
```

如果同一升级任务已经运行，脚本会跳过本轮。可用以下命令判断锁当前是否可获取：

```bash
flock -n /tmp/operator-upgrade.lock -c true
```

退出码 `0` 表示锁当前空闲；否则可用 `fuser -v /tmp/operator-upgrade.lock` 查找打开文件的进程，并核实其运行目录。`fuser` 只能显示打开文件的进程，不能单独证明进程持有锁；锁文件中的 PID 也不能作为锁状态依据。

`upgrade.sh` 启动目标服务时保留当前终端的标准输入，并将输出同时写入终端和 `/opt/logs/upgrade.log`。如果启动脚本需要交互输入（例如 node 的 secrets vault 密码），必须从前台交互终端升级；非交互定时任务不能完成这类提示。

## 项目升级钩子

纳入统一升级流程的每个安装包必须包含可执行的 `scripts/upgrade.sh`，接口固定为：

```bash
bash scripts/upgrade.sh <prepare|copy-config|post-copy|finalize> <current-dir> <target-dir>
```

四个阶段均由目标版本安装包中的脚本执行：

1. `prepare`：停止服务前执行项目定制准备动作。
2. `copy-config`：停止旧服务后、通用启动前迁移项目配置。
3. `post-copy`：配置迁移后、启动服务前执行静态资源发布或其他动作。
4. `finalize`：健康检查后、更新 `/opt/deploy/<module>` 软链接前执行收尾动作。

正常情况下每个阶段返回 `0`。只有 `prepare` 可以返回 `10`，表示本次只执行项目定制动作，跳过通用的停止服务、配置迁移、启动服务和健康检查；之后仍会调用 `post-copy`、`finalize`，并更新模块软链接。其他非零退出码都会使该模块升级失败。

通用服务流程依次为：下载并校验制品、解压到 `/opt/deploy/<module>-v...`、执行 `prepare`、优雅停止旧服务并确认进程退出、执行 `copy-config`、执行 `post-copy`、启动新服务、执行 `health-check.sh --level all`（如果目标包提供）、执行 `finalize`、更新软链接，最后尝试备份和上传配置。

当前项目定制行为如下：

- `chat`、`project`、`router`：在 `copy-config` 复制环境或 YAML 配置。
- `node`：在 `copy-config` 迁移 `config.js` 和加密 secrets vault，但不复制 `secrets.passwordFile`。如果目标环境没有有效密码文件，目标 `starter.sh` 会在当前终端安全提示输入密码；密码不会回显，也不会写入升级日志。无人值守升级必须由 node 自身提供安全的非交互凭据来源。
- `billing`：在 `copy-config` 复制 `config.yaml`。
- `social`：在 `copy-config` 复制 `config/`，在 `post-copy` 发布 `web/dist` 并重启 Nginx。
- `warehouse`：在 `copy-config` 复制 `config.yaml`。WebDAV 前端是独立 `warehouse-web` 静态单元，由 `static-units.conf` 控制，与 warehouse 后端服务互不影响。

## 回退和验证

服务升级失败后先查看日志、当前软链接和进程状态，再决定重试或手动回退；服务模块不会自动降级。若失败发生在新服务启动之后、软链接更新之前，实际运行目录可能已经是目标版本，而 `/opt/deploy/<module>` 仍指向旧目录。静态站点在 HTTP 检查失败时会自动恢复之前的 `current` 指向。

升级后检查 `/opt/logs/upgrade.log`、进程、端口和核心功能。静态站点还应确认 `readlink -f /opt/deploy/static/<site_id>/current` 指向目标版本，并通过 `static-units.conf` 中的健康 URL 检查入口。warehouse WebDAV 前端迁移到标准静态目录后，也通过此流程部署；迁移前不要启用 warehouse 的静态配置行。

升级目标配置和静态部署回归测试：

```bash
bash operator/upgrade/tests/test_upgrade_target_config.sh
bash operator/upgrade/tests/test_deploy_static_artifact.sh
```
