# 编译、制品传输与升级

本目录提供安装包编译、WebDAV 制品传输和服务升级脚本。服务节点的升级统一由
`upgrade.sh` 编排；项目安装包中的 `scripts/upgrade.sh` 只负责项目特有动作。
deployer 不再提供 `upgrade_<module>.sh` 这类项目级升级脚本。

当前已接入统一升级流程的模块是 `chat`、`node`、`project`、`router`、`social`、
`warehouse` 和 `billing`。所有模块的安装包都必须提供 `scripts/upgrade.sh` 和健康检查脚本；
接入前需要先按本 README 和
[`specification/PACKAGING.md`](../../specification/PACKAGING.md) 补齐安装包契约并完成验证。

## 脚本入口

| 脚本 | 运行位置 | 用途 | 配置 | 日志 |
| --- | --- | --- | --- | --- |
| `compile_packages.sh` | 编译节点 | 同步模块 `main`、打包、生成校验文件并上传制品 | `modules.conf`、`.env` | `/opt/logs/check-code-status.log` |
| `transfer_packages.sh` | 编译节点或服务节点 | 在 `/opt/package` 与 WebDAV 之间传输单个文件 | `.env` | `/opt/logs/transfer-packages.log` |
| `upgrade.sh` | 服务部署节点 | 选择目标版本并执行统一升级流程 | `modules.conf`、`.env` | `/opt/logs/upgrade.log` |

项目级 `scripts/upgrade.sh` 的输出也会合并到 `/opt/logs/upgrade.log`，日志按统一入口集中查看。

## 首次配置

在部署节点配置升级脚本：

```bash
cd /root/code/deployer/operator/upgrade
cp modules.conf.template modules.conf
cp .env.template .env
chmod 600 .env
```

编辑 `modules.conf`，每行填写一个模块名；空行和以 `#` 开头的行会被忽略。编辑
`.env` 时必须填写实际的 WebDAV 地址和凭据，不要把凭据提交到 Git。常用配置项：

- `WEBDAV_PACKAGE_BASE_URL`、`WEBDAV_PACKAGE_AK`、`WEBDAV_PACKAGE_SK`：制品目录和认证信息。
- `HEALTH_CHECK_INITIAL_WAIT_SECONDS`：首次启动后第一次健康检查前等待的秒数，默认 `0`；慢启动服务可按需配置。
- `WAIT_SECONDS`：健康检查失败后的重试间隔，默认 `2`；第一次健康检查默认立即执行。
- `RETRY_TIMES`：健康检查失败后的重试次数，默认 `10`；结合默认 2 秒间隔，首次检查立即执行后提供约 20 秒的快速轮询窗口。
- `FILE_VERIFY`：可选 `sha256sum` 或 `md5sum`；为空表示不校验。
- `WEBDAV_FLAG`：仅影响 `warehouse`，可选 `all`、`backend`、`frontend`。
- `NOTIFY_DINGDING`、`NOTIFY_FEISHU`、`NOTIFY_SAME_VERSION`：通知开关。

升级节点必须能访问 WebDAV，并对 `/opt/package`、`/opt/deploy`、`/opt/logs` 和
服务启停所需资源具有读写或执行权限。目标模块必须已经部署，且
`/opt/deploy/<module>` 或对应版本目录存在；本入口不负责首次部署。

## 日常操作

### 编译并上传制品

在编译节点确认模块仓库没有需要保留的本地改动后执行：

```bash
cd /root/code/deployer/operator/upgrade
./compile_packages.sh
```

编译脚本会把模块仓库同步到 `origin/main`，并可能执行
`git reset --hard origin/main` 和 `git clean -fd`。模块仓库必须提供
`scripts/package.sh`，产物应位于项目根目录的 `output/`，并符合：

```text
<module>-v<major>.<minor>.<patch>-<7-char-commit>.tar.gz
```

### 手动传输单个制品

第二个参数只能是文件名，不能包含路径；上传文件必须位于 `/opt/package`：

```bash
./transfer_packages.sh upload chat-v1.2.3-a1b2c3d.tar.gz
./transfer_packages.sh download chat-v1.2.3-a1b2c3d.tar.gz
```

### 执行升级

`upgrade.sh` 不接受位置参数，按 `modules.conf` 中的顺序处理模块：

```bash
./upgrade.sh
```

远程版本只有严格高于本地版本时才会升级。某个模块失败后脚本会继续处理后续模块，
最终以非零退出码结束；同一时刻重复运行会被锁跳过。升级结果和失败原因首先查看：

```bash
less /opt/logs/upgrade.log
```

三个入口脚本都带有可执行权限和 Bash shebang，因此也可以继续使用
`bash ./upgrade.sh`、`bash ./compile_packages.sh` 或 `bash ./transfer_packages.sh`。推荐使用
`./upgrade.sh`，以便及早发现文件权限或 shebang 配置问题。

`upgrade.sh` 启动目标服务时保留当前终端的标准输入，并同时把启动输出显示在终端和写入
`/opt/logs/upgrade.log`。如果模块启动脚本需要交互输入（例如 node 的 secrets vault 密码），
必须从前台交互终端执行升级；定时任务或重定向了标准输入的非交互调用无法完成这类提示。
如果提示 `upgrade task is already running`，不要只根据锁文件中的 PID 判断。使用
`flock -n /tmp/operator-upgrade.lock -c true` 检查锁是否可获取：退出码为 `0` 表示锁当前空闲；
否则可用 `fuser -v /tmp/operator-upgrade.lock` 查找打开该文件的进程，并确认其实际运行目录后再处理。
`fuser` 只能列出打开文件的进程，不能单独证明进程持有锁；锁文件中记录的 PID 也不能作为锁状态依据。

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

正常情况下每个阶段返回 `0`。只有 `prepare` 可以返回 `10`，表示本次只执行项目
定制动作，跳过通用的停止服务、配置迁移、启动服务和健康检查；之后仍会调用
`post-copy`、`finalize`，并更新模块软链接。其他非零退出码都会使该模块升级失败。

通用流程依次为：下载并校验制品、解压到 `/opt/deploy/<module>-v...`、执行
`prepare`、优雅停止旧服务并确认进程退出、执行 `copy-config`、执行 `post-copy`、启动新服务、执行
`health-check.sh --level all`（如果目标包提供；第一次检查默认立即执行，失败后按配置重试）、执行 `finalize`、更新软链接，
最后尝试执行配置备份和上传。

当前项目的定制行为如下：

- `chat`、`project`、`router`：在 `copy-config` 复制环境或 YAML 配置。
- `node`：在 `copy-config` 迁移 `config.js` 和加密 secrets vault，但不复制 `secrets.passwordFile`。
  手动升级时，如果目标环境没有有效密码文件，目标 `starter.sh` 会在当前终端安全提示输入密码；
  密码不会回显，也不会写入升级日志。无人值守升级必须由 node 自身提供安全的非交互凭据来源。
- `billing`：在 `copy-config` 复制 `config.yaml`。
- `social`：在 `copy-config` 复制 `config/`，在 `post-copy` 发布 `web/dist` 并重启 Nginx。
- `warehouse`：在 `copy-config` 复制 `config.yaml`；`all` 同时执行后端通用升级和前端发布，`backend` 只升级后端，
  `frontend` 只发布前端并通过退出码 `10` 跳过后端服务切换。

## 升级后检查

升级完成后至少确认：

```bash
readlink -f /opt/deploy/<module>
cd /opt/deploy/<module>
bash scripts/health-check.sh --level all
```

同时检查 `/opt/logs/upgrade.log`、服务进程、端口和核心功能。`warehouse` 前端升级
还要确认 `/usr/share/nginx/html/webdav` 内容已更新且 Nginx 重启成功。

## 失败与回退

`upgrade.sh` 不执行自动降级。失败后先查看日志和当前软链接，再决定重试或手动回退；
不要仅以进程存在判断升级成功。如果失败发生在目标服务已启动但软链接更新之前，
实际运行目录可能已经是目标目录，而 `/opt/deploy/<module>` 仍指向旧目录。

### 重试失败的升级

修复故障原因后，可以直接再次执行：

```bash
cd /root/code/deployer/operator/upgrade
./upgrade.sh
```

升级锁只在单次 `upgrade.sh` 进程存活期间持有，并会在成功或失败退出时释放；因此上一次
执行返回非零后不需要删除锁文件，也不应通过删除锁文件强行重试。若日志仍提示已有任务在运行，
应先确认该进程确实仍在执行，再等待其结束。

重试会复用已下载、校验通过且已解压的同一版本制品，并从该模块的 `prepare` 阶段重新执行。
在“新服务已启动但软链接尚未更新”的中间状态下，目标版本的启动脚本应识别到已有进程，随后
继续健康检查和软链接切换。项目级 `scripts/upgrade.sh` 的四个阶段必须保持可重入：配置迁移
不应重复破坏数据，数据库迁移应使用自身的幂等机制。

回退时需要使用实际存在的旧版本目录，按项目钩子约定执行必要的定制动作，再完成
停止旧目录服务、配置复制、启动旧版本、健康检查和软链接更新。`warehouse` 前端
回退还要重新复制旧版本 `web/dist` 并重启 Nginx。完整流程和故障表见
[`specification/UPGRADE.md`](../../specification/UPGRADE.md)。
