# 编译、制品传输与升级

本目录提供安装包编译、WebDAV 制品传输和服务升级脚本。服务节点的升级统一由
`upgrade.sh` 编排；项目安装包中的 `scripts/upgrade.sh` 只负责项目特有动作。
deployer 不再提供 `upgrade_<module>.sh` 这类项目级升级脚本。

当前服务型统一升级模块是 `chat`、`node`、`project`、`router`、`social`、
`warehouse` 和 `billing`。新接入服务单元前必须按本 README 和
[`specification/PACKAGING.md`](../../specification/PACKAGING.md) 补齐安装包契约并完成验证。
纯静态与 desktop 单元不属于当前模块清单；跨项目现状见
[`specification/PACKAGING_AUDIT.md`](../../specification/PACKAGING_AUDIT.md)。

发布端用 `package_manifest.sh`（POSIX shell + `jq`）校验清单、SHA-256、归档结构和静态入口；显式发布环境需安装 `jq`、`tar` 和 `sha256sum` 或 `shasum`。配置文件按用途命名：`package-modules.conf` 列出待构建源码仓库，`upgrade-modules.conf` 列出服务升级单元，`static-units.conf` 列出独立静态站点。各脚本只读取对应文件，不回退读取旧名称。
编译器接受 manifest 中一个或多个 `service`、`service-with-assets`、`static` 或 `desktop` artifact，并校验、上传清单声明的全部制品。升级器对传统服务包仍使用兼容流程；配置后的静态单元会消费 manifest、校验制品并执行部署。清单驱动的服务选择仍未完成，desktop 单元不会由服务器升级器部署。

独立发布的前端静态单元统一使用 `/opt/deploy/static/<site_id>`，Web 服务器 root 指向该目录下的 `current`，
版本包保存在 `releases/`。manifest 的静态路径固定为 `/opt/deploy/static/<site_id>`，由校验器按全社区唯一的 `site_id` 检查。配置后的静态单元由 `deploy_static_artifact.sh` 解包、校验入口、原子切换软链接，并在 HTTP 健康检查失败时恢复旧指向。启用站点前必须先将 vhost root 迁移至标准 `current` 目录；warehouse 的
`/usr/share/nginx/html/webdav` 仍是待迁移的旧路径。

## 脚本入口

| 脚本 | 运行位置 | 用途 | 配置 | 日志 |
| --- | --- | --- | --- | --- |
| `compile_packages.sh` | 编译节点 | 仅通过显式 `--publish` 事件构建、校验并上传制品 | `package-modules.conf`、`.env` | `/opt/logs/check-code-status.log` |
| `transfer_packages.sh` | 编译节点或服务节点 | 在 `/opt/package` 与 WebDAV 之间传输单个文件 | `.env` | `/opt/logs/transfer-packages.log` |
| `upgrade.sh` | 服务部署节点 | 选择目标版本并执行统一升级流程，可选部署静态 unit | `upgrade-modules.conf`、可选 `static-units.conf`、`.env` | `/opt/logs/upgrade.log` |

项目级 `scripts/upgrade.sh` 的输出也会合并到 `/opt/logs/upgrade.log`，日志按统一入口集中查看。

## 首次配置

在部署节点配置升级脚本：

```bash
cd /root/code/deployer/operator/upgrade
cp upgrade-modules.conf.template upgrade-modules.conf
cp package-modules.conf.template package-modules.conf
cp static-units.conf.template static-units.conf
cp .env.template .env
chmod 600 .env
```

`upgrade-modules.conf` 是服务升级名单，只放已有服务部署目录的模块。`package-modules.conf` 是源码仓库的打包名单，可以包含只发布静态或桌面 artifact 的仓库，两者不要求相同。每行填写一个仓库名；空行和以 `#` 开头的行会被忽略。`static-units.conf` 每行使用 `repository unit_id site_id health_base_url` 格式；只有在相应 vhost 已指向 `/opt/deploy/static/<site_id>/current` 且健康 URL 可从部署节点访问后，才启用对应行。

现有机器需迁移配置名：旧 `modules.conf` 的服务升级名单移至 `upgrade-modules.conf`；如果打包曾依赖回退读取 `modules.conf`，需把源码仓库清单单独写入 `package-modules.conf`；旧 `package_modules.conf` 改名为 `package-modules.conf`。脚本只读取新名称，不再兼容旧文件名。
编辑
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

自动打包已停用。无参数调用为空操作退出以兼容旧定时项；人工或受控 release workflow 必须显式执行：

```bash
cd /root/code/deployer/operator/upgrade
./compile_packages.sh --publish
```

默认对每个仓库的最大语义版本递增 patch。需要递增 minor 或 major 时执行
`./compile_packages.sh --publish --bump minor` 或 `--bump major`。单个仓库内某个制品需要独立版本时，可以在命令中传入
`--unit-version REPOSITORY:UNIT=VERSION`，例如 `--unit-version homepage:homepage-wallet=2.1.0`；也可以把长期版本覆盖提交到该仓库的 `scripts/artifact-versions.conf`。
发布中断后如需重建已有 tag，可传入 `--tag 仓库:v版本`，例如 `--tag router:v0.0.163`；该仓库将按该 tag 的 commit 重建，不会再递增版本。

发布前仓库必须是干净的 `main`。脚本会 fetch `origin/main`，并仅在可安全快进时自动同步；存在未提交改动、本地独有提交或分叉时会停止，不会用
`git reset --hard` 或 `git clean -fd` 清理工作区。模块仓库必须提供 `scripts/package.sh` 和
声明标准参数/无 Git 写入能力的 `scripts/package-api.json`。构建在临时 detached worktree 和空输出目录中运行，
输出目录不会写入模块仓库。manifest 可以包含一个或多个服务、静态、桌面 artifact；当前 `upgrade.sh` 仍只升级 `upgrade-modules.conf` 中配置且包名前缀匹配的 legacy 服务单元。已填入 `static-units.conf` 的静态 artifact 会经 manifest 校验和独立静态处理器部署；未配置的静态单元与所有 desktop artifact 只会被校验和上传。服务单元包名为：

```text
<unit-id>-v<major>.<minor>.<patch>-<7-char-commit>.tar.gz
```

### 手动传输单个制品

第二个参数只能是文件名，不能包含路径；上传文件必须位于 `/opt/package`：

```bash
./transfer_packages.sh upload chat-v1.2.3-a1b2c3d.tar.gz
./transfer_packages.sh download chat-v1.2.3-a1b2c3d.tar.gz
```

### 执行升级

`upgrade.sh` 不接受位置参数，按 `upgrade-modules.conf` 中的顺序处理模块：

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

manifest 校验回归测试可在 deployer 仓库运行：

```bash
bash operator/upgrade/tests/test_package_manifest.sh
```

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

服务升级完成后至少确认：

```bash
readlink -f /opt/deploy/<module>
cd /opt/deploy/<module>
bash scripts/health-check.sh --level all
```

同时检查 `/opt/logs/upgrade.log`、服务进程、端口和核心功能。静态站点升级后确认 `readlink -f /opt/deploy/static/<site_id>/current` 指向目标版本，并通过 `static-units.conf` 中的 URL 检查入口。尚未迁移的 warehouse 旧 hook 仍需确认 `/usr/share/nginx/html/webdav` 内容已更新且 Nginx 重启成功。

## 失败与回退

服务单元仍不执行自动降级。静态单元在 HTTP 检查失败时会自动恢复之前的 `current` 指向。其他失败后先查看日志和当前软链接，再决定重试或手动回退；
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
