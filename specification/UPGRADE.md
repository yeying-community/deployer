# 升级操作说明

本文档说明 `operator/upgrade/` 目录下升级脚本的使用方式、配置项、执行流程、模块差异、验证与回退操作。

## 适用范围

- 升级脚本面向已按命名规范部署到 `/opt/deploy` 的服务模块。
- 主入口 `operator/upgrade/upgrade.sh` 会读取同脚本目录下的`operator/upgrade/modules.conf`来获取模块清单，检查 WebDAV 制品仓库中的最新安装包，并在远程版本高于本地当前版本时执行升级。
- 每个模块升级时会选取 WebDAV 制品仓库中对应版本号最大的文件 作为目标版本进行升级操作。
- 通用升级生命周期由 `operator/upgrade/upgrade.sh` 完成；参与统一升级流程的模块必须在安装包内提供 `scripts/upgrade.sh`，只实现项目特有的升级动作。
- 此操作并不适用于模块的首次部署操作，也就是说如果当前节点并没有对应的模块，需要先手动完成部署并验证项目的 `scripts/upgrade.sh`。
- 测试环境由定时任务调用`deployer/operator/upgrade/upgrade.sh` 依据`operator/upgrade/modules.conf`的配置来完成对应模块的升级。
- 生产环境的升级需要手动执行`deployer/operator/upgrade/upgrade.sh` 依据`operator/upgrade/modules.conf`的配置来完成对应模块的升级。

当前 `modules.conf` 仍只登记服务型部署单元：`chat`、`node`、`project`、`router`、`social`、
`warehouse` 和 `billing`；这不代表它们已通过新 manifest 契约验收。独立 static 单元通过可选的 `static-units.conf` 配置，不加入服务清单；desktop 制品不得由服务器升级器部署。完整跨项目现状见 [PACKAGING_AUDIT.md](./PACKAGING_AUDIT.md)。

模块名称必须与安装包前缀、部署目录前缀和升级脚本约定一致。例如模块 `chat` 对应：

- 安装包：`chat-v<version>-<commit>.tar.gz`
- 部署目录：`/opt/deploy/chat-v<version>-<commit>`
- 当前版本软链接：`/opt/deploy/chat`
- 项目升级脚本：`scripts/upgrade.sh`


## 前置条件

升级前确认以下条件已满足：

1. 操作节点可以访问 WebDAV 制品仓库。
2. `operator/upgrade/.env` 已正确配置。
3. `operator/upgrade/modules.conf` 已填写待升级模块。
4. 本地部署目录 `/opt/deploy` 下存在当前版本目录，且目录名符合 `模块名-v主版本.次版本.修订版本-7位commit` 格式。
5. 当前版本目录和目标安装包存在 `scripts/starter.sh` 与 `scripts/upgrade.sh`，且目标升级脚本支持 `copy-config` 阶段。
6. 如果目标安装包提供 `scripts/health-check.sh`，该脚本可在目标目录中执行；当前版本目录内存在项目升级脚本要求的配置文件。
7. 目标安装包内的顶层目录名与安装包文件名去掉 `.tar.gz` 后一致。
8. 操作用户具备读写 `/opt/package`、`/opt/deploy`、`/opt/logs` 以及启动/停止服务所需权限。

## 配置文件

### `.env`

`operator/upgrade/.env` 用于配置制品仓库、通知和校验行为：

```bash
WEBDAV_PACKAGE_BASE_URL="https://example.com/dav/package"
WEBDAV_PACKAGE_AK="access_key"
WEBDAV_PACKAGE_SK="secret_key"
WEBDAV_FLAG="all"
STOP_TIMEOUT_SECONDS="30"
FORCE_STOP_TIMEOUT_SECONDS="5"
HEALTH_CHECK_INITIAL_WAIT_SECONDS="0"
WAIT_SECONDS="2"
RETRY_TIMES="10"
NOTIFY_FROM=""
NOTIFY_SAME_VERSION="False"
NOTIFY_DINGDING="False"
NOTIFY_FEISHU="False"
FILE_VERIFY=""
```

配置说明：

| 配置项 | 说明 |
| --- | --- |
| `WEBDAV_PACKAGE_BASE_URL` | WebDAV 制品目录地址，脚本会自动去掉末尾 `/` |
| `WEBDAV_DIR_URL` | 可选，指定后覆盖 `WEBDAV_PACKAGE_BASE_URL` 作为升级读取目录 |
| `WEBDAV_PACKAGE_AK` | WebDAV 访问账号 |
| `WEBDAV_PACKAGE_SK` | WebDAV 访问密钥 |
| `WEBDAV_FLAG` | `warehouse` 专用升级范围，可选 `all`、`backend`、`frontend`，默认 `all` |
| `STOP_TIMEOUT_SECONDS` | starter 优雅停止等待时间，默认 `30`；升级器会将该环境变量传给项目脚本 |
| `FORCE_STOP_TIMEOUT_SECONDS` | starter 强制终止后的退出确认时间，默认 `5`；升级器会将该环境变量传给项目脚本 |
| `HEALTH_CHECK_INITIAL_WAIT_SECONDS` | 启动目标服务后第一次健康检查前的等待时间，默认 `0` |
| `WAIT_SECONDS` | 健康检查失败后的重试间隔，默认 `2` |
| `RETRY_TIMES` | 健康检查失败后的重试次数，默认 `10`；总尝试次数为 `RETRY_TIMES + 1` |
| `NOTIFY_FROM` | 通知中的环境/来源标识，空值时使用主机名 |
| `NOTIFY_SAME_VERSION` | 远程版本未高于当前版本时是否发送通知 |
| `NOTIFY_DINGDING` | 是否发送钉钉通知 |
| `NOTIFY_FEISHU` | 是否发送飞书通知 |
| `DINGTALK_NEED_AT` | 钉钉通知是否按 `.env` 中接收人配置进行 @ |
| `FILE_VERIFY` | 安装包校验算法，可选空值、`sha256sum`、`md5sum` |
| `RELEASE_NOTES_CODEX_BIN` | 打包阶段生成 release notes 时可选指定 `codex` 路径 |

`FILE_VERIFY` 不为空时，打包脚本会生成并上传 `<package>.sha256sum` 或 `<package>.md5sum`，升级脚本会先下载校验文件，再校验安装包完整性。若校验失败，升级脚本会删除本地已下载安装包并中止该模块升级。

### `modules.conf`

`operator/upgrade/modules.conf` 每行填写一个模块名，空行和 `#` 开头的注释行会被忽略：

```text
chat
node
project
router
social
warehouse
billing
```

主升级脚本会按文件中的模块顺序逐个处理。某个模块失败时，脚本会记录失败状态并继续处理后续模块，最终以非零退出码结束。

## 制品命名与版本选择

`modules.conf` 目前仍使用服务模块名，兼容旧格式包。新发布制品统一按照
[`PACKAGING.md`](./PACKAGING.md) 中的 `release-manifest.json` 声明 artifact ID、类型、源 commit、文件和 SHA-256；升级器必须先验证清单和包校验，再按部署单元选择版本。未迁移到清单格式的旧包只能走明确的兼容期，不能据此接入新的 static 或多单元发布流程。

当前实现状态：`compile_packages.sh` 会在发布前校验 manifest、每个包的 SHA-256 和包结构，并上传版本化 manifest。
传统服务升级仍按 `modules.conf` 中的包名前缀选择版本，并使用可选 `FILE_VERIFY` sidecar；它尚未基于 manifest 选择服务 artifact。
另有独立静态流程：`static-units.conf` 中配置的站点会下载版本 manifest 及所列制品，用 `package_manifest.sh` 校验哈希和归档，再原子切换标准目录的 `current` 软链接；HTTP 健康检查失败时恢复原软链接。该流程仅在静态站点完成 vhost 迁移并配置健康 URL 后才会运行。跨 unit 独立版本选择、desktop 部署、真实站点升级和回滚演练仍未验收。

### 独立静态资源的统一部署目录

所有独立发布的前端站点统一部署在 `/opt/deploy/static/<site_id>`。`site_id` 全社区唯一，建议以前缀区分仓库；manifest 的目标路径只能是 `/opt/deploy/static/<site_id>`。目录布局和 Web 服务器 root 固定为：

```text
/opt/deploy/static/<site_id>/current -> releases/<package_root>
/opt/deploy/static/<site_id>/releases/<package_root>/...
```

Nginx 等静态服务器的 `root` 指向 `/opt/deploy/static/<site_id>/current`。部署器下载并验证包后，将文件解到对应的 `releases/<package_root>`，检查静态入口和 HTTP 资源，再原子切换 `current`；失败时保留旧版本指向，成功后至少保留一个旧版本用于人工回退。manifest 不得决定其他磁盘路径。与后端强耦合的 `service-with-assets` 继续随服务版本部署。

静态部署处理器已实现上述目录布局。站点必须先在 `static-units.conf` 声明仓库、unit、site 和 HTTP 健康 URL；已有站点仍需在相应 Nginx vhost 迁移、验证后才启用。例如 warehouse 当前使用 `/usr/share/nginx/html/webdav` 的流程属于旧路径，不能据此认定已迁移到标准目录。

升级脚本只识别 `.tar.gz` 安装包，命名格式为：

```text
<module>-v<major>.<minor>.<patch>-<7-char-commit>.tar.gz
```

示例：

```text
chat-v1.2.3-a1b2c3d.tar.gz
```

版本判断规则：

1. 远程目录中筛选 `${module}-*.tar.gz`。
2. 解析语义化版本 `major.minor.patch` 和 7 位 commit。
3. 优先选择版本号最大的包。
4. 版本号相同时，选择文件名排序更靠后的包。
5. 只有远程版本严格大于本地当前版本时才升级。

本地当前版本优先从 `/opt/deploy/<module>` 软链接解析；如果软链接不存在或不合法，则从 `/opt/deploy/<module>-*` 目录中选择最新版本。

## 打包与上传

在构建节点显式触发

`operator/upgrade/compile_packages.sh --publish` 的主要行为：

1. 读取 `operator/upgrade/package_modules.conf`（缺失时兼容回退到 `modules.conf`），要求每个仓库工作区干净、位于 `main` 且与 `origin/main` 完全一致。
2. 创建指向当前 commit 的临时 detached worktree 和空输出目录。
3. 要求 `scripts/package.sh` 声明安全 API，并传入明确的 `--ref`、`--version`、`--output-dir`。
4. 校验 manifest 的 repository、版本、commit、artifact ID、类型、归档路径、SHA-256 和包结构。
5. 校验并上传 manifest 声明的全部 service、static 或 desktop 制品；该仓库可产生多个独立 artifact，也可以只有 static/desktop artifact。
6. 将未改变的制品复制到 `/opt/package`，拒绝相同文件名下的不同内容；如启用 `FILE_VERIFY`，生成校验文件。
7. 调用 `transfer_packages.sh upload <filename>` 上传制品、校验文件和版本化 manifest，最多重试 3 次。
8. 尝试执行 `operator/change-log/release_notes.sh --module <module>` 生成发布说明。

注意事项：

- 不带 `--publish` 的调用仅报告自动打包已停用，不构建、不上传；CI 必须绑定人工批准的 release 事件，不能由普通代码 push 或周期扫描触发。
- 构建器和项目脚本不得对持久模块工作区执行 `git reset --hard` 或 `git clean -fd`。执行发布前检查 `main` 工作区干净且与 `origin/main` 一致；脏工作区或版本不同必须失败并提示修复，禁止清理用户数据。
- 模块仓库必须提供 `scripts/package.sh`，并逐步迁移到 `--ref`、`--version` 和 `release-manifest.json` 契约。
- 当前构建输出位于编译节点临时目录；不会写入模块仓库的 `output/`。
- 传统服务升级流程仍使用 legacy 包名选择，尚未消费 manifest 中的服务 artifact。static 流程只处理显式配置的站点；真实环境使用前应完成站点迁移和演练。
- 产物文件名必须包含当前代码的 7 位 commit。

## 安装包传输

`transfer_packages.sh` 用于在 `/opt/package` 与 WebDAV 目录之间上传或下载单个文件：

```bash
cd operator/upgrade
bash transfer_packages.sh upload chat-v1.2.3-a1b2c3d.tar.gz
bash transfer_packages.sh download chat-v1.2.3-a1b2c3d.tar.gz
```

约束：

- 第二个参数只能是文件名，不能包含路径。
- 上传时本地文件必须位于 `/opt/package`。
- 下载成功后文件会落到 `/opt/package`。
- WebDAV 认证信息来自 `operator/upgrade/.env`。

## 执行升级

在目标部署节点执行

`operator/upgrade/upgrade.sh` 的执行流程：

1. 校验 `operator/upgrade/.env`的`FILE_VERIFY` 配置。
2. 读取 `operator/upgrade/modules.conf`。
3. 加载 WebDAV 配置并列出远程目录文件。
4. 为每个模块选择远程最新安装包。
5. 识别本地当前版本。
6. 如果远程版本未高于当前版本，则跳过该模块。
7. 下载目标安装包；启用校验时先下载校验文件。
8. 校验安装包完整性。
9. 解压安装包到 `/opt/deploy/<module>-v<version>-<commit>`。
10. 调用目标安装包的 `scripts/upgrade.sh prepare <current-dir> <target-dir>`；退出码 `10` 表示只执行项目定制动作，不执行通用服务切换。
11. 调用当前版本 `scripts/starter.sh stop`；只有脚本确认旧进程已退出后，才调用 `scripts/upgrade.sh copy-config <current-dir> <target-dir>` 迁移项目配置。
12. 调用 `scripts/upgrade.sh post-copy <current-dir> <target-dir>` 执行静态资源发布或其他项目定制动作。
13. 执行目标版本的 `scripts/starter.sh` 启动服务；启动前必须确认旧服务已经退出。升级器必须保留
    调用方的标准输入，使需要密码等交互输入的项目启动脚本可以从前台终端读取，同时将启动输出
    显示到终端并写入升级日志。非交互任务必须在执行前通过项目认可的安全方式准备所需凭据。
14. 如果目标版本存在 `scripts/health-check.sh`，立即执行第一次健康检查，失败后按 `HEALTH_CHECK_INITIAL_WAIT_SECONDS`、`WAIT_SECONDS` 和 `RETRY_TIMES` 配置重试。
15. 执行 `scripts/upgrade.sh finalize <current-dir> <target-dir>`，然后更新 `/opt/deploy/<module>` 软链接。
16. 发送升级完成或异常通知。

服务模块处理后，`upgrade.sh` 会检查可选 `static-units.conf`。对每个已配置站点，升级器选择该仓库最新 manifest，下载并校验所列制品，从中定位指定 static unit，部署到 `/opt/deploy/static/<site_id>/releases/<package_root>`，切换 `current` 并请求配置的健康 URL。HTTP 检查失败时会恢复切换前的 `current`；如果站点未配置或健康 URL 不可达，不会把它当作升级成功。

日志文件：

| 脚本 | 日志 |
| --- | --- |
| `compile_packages.sh` | `/opt/logs/check-code-status.log` |
| `transfer_packages.sh` | `/opt/logs/transfer-packages.log` |
| `upgrade.sh` | `/opt/logs/upgrade.log` |
| 项目 `scripts/upgrade.sh` | 输出合并到 `/opt/logs/upgrade.log` |


## 模块升级行为

### 通用行为

`operator/upgrade/upgrade.sh` 执行的通用行为：

1. 查找当前版本目录和目标版本目录。
2. 检查当前版本和目标版本存在 `scripts/starter.sh`、`scripts/upgrade.sh`；目标版本的 `scripts/upgrade.sh` 在解压后单独检查。
3. 调用项目脚本的 `prepare` 阶段。
4. 在当前版本目录执行 `bash scripts/starter.sh stop`。脚本必须先发送 `SIGTERM`，等待进程退出；超时后才允许发送 `SIGKILL`，并在返回成功前再次确认进程已经退出。
   停止返回非零时，升级器必须停止该模块后续流程，不得复制配置或启动目标服务。
5. 调用目标版本的 `scripts/upgrade.sh copy-config <current-dir> <target-dir>` 将配置复制到目标版本。
6. 调用项目脚本的 `post-copy` 阶段。
7. 启动目标服务：`bash scripts/starter.sh`。调用时必须保留标准输入供项目脚本进行必要的交互提示，
   并关闭升级锁文件描述符，防止后台服务继承升级锁。如果启动失败，不得把端口监听或旧 PID 残留当作成功。
8. 如果目标版本存在 `scripts/health-check.sh`，立即执行第一次 `bash scripts/health-check.sh --level all`；失败后按 `WAIT_SECONDS` 间隔重试。需要为慢启动服务预留启动时间时，使用 `HEALTH_CHECK_INITIAL_WAIT_SECONDS`，不要依赖固定长时间等待。
9. 调用项目脚本的 `finalize` 阶段。



### warehouse

`scripts/upgrade.sh` 受 `.env` 中 `WEBDAV_FLAG` 控制：

- `all`：升级后端并发布前端。
- `backend`：只升级后端。
- `frontend`：只发布前端。

后端升级流程由 `operator/upgrade/upgrade.sh` 的通用流程完成。

以下是 warehouse 当前项目 hook 的旧静态发布实现；它仍写入 `/usr/share/nginx/html/webdav`，尚未迁移到统一静态目录。迁移需与 Nginx root 和静态 manifest handler 一起实施并验证。

前端发布流程：

1. 检查目标版本存在 `web/dist`。
2. 删除 `/usr/share/nginx/html/webdav`。
3. 将目标版本 `web/dist` 复制到 `/usr/share/nginx/html/webdav`。
4. 执行 `systemctl restart nginx`。

## 升级后验证

升级完成后至少执行以下检查：

1. 查看主日志和模块日志，确认没有 `ERROR!`。
2. 确认 `/opt/deploy/<module>` 软链接指向目标版本目录。
3. 确认目标版本服务进程已启动。
4. 对配置健康检查的模块，确认健康检查已通过或手动执行：

```bash
cd /opt/deploy/<module>
bash scripts/health-check.sh --level all
```

5. 对尚未迁移的 `warehouse` 前端旧流程，确认 nginx 已重启且静态目录 `/usr/share/nginx/html/webdav` 内容来自目标版本。迁移后应检查 `/opt/deploy/static/warehouse-web/current` 和对应 HTTP 资源。
6. 对目标版本进行测试。

## 回退操作

主脚本 `upgrade.sh` 只会在远程版本高于本地版本时升级，不负责自动降级。需要回退时，按通用停止、复制、启动和健康检查流程手动将服务切回旧版本，并更新当前版本软链接。项目如果有定制迁移或静态资源发布，还必须按项目自己的回退要求处理；主升级入口不会自动执行降级。

示例：将 `chat` 从 `1.2.3` 回退到 `1.2.2`：

```bash
cd /opt/deploy/chat-v1.2.3-a1b2c3d
bash scripts/starter.sh stop
# 按项目提供的 status/进程检查确认旧服务已退出；PID 文件位置不统一，不要写死路径。
bash scripts/upgrade.sh copy-config /opt/deploy/chat-v1.2.3-a1b2c3d /opt/deploy/chat-v1.2.2-a1b2c3d
cd /opt/deploy/chat-v1.2.2-a1b2c3d
bash scripts/starter.sh
ln -sfn chat-v1.2.2-a1b2c3d /opt/deploy/chat
```

回退注意事项：

- 手动回退时必须确认 `/opt/deploy/<module>-v<old_version>-<commit>` 目录仍存在。
- `ln -sfn` 的目标应使用实际旧版本目录名，不要照抄示例 commit。
- 回退后执行与升级后相同的日志、软链接、进程和健康检查验证。
- 尚未迁移的 `warehouse` 前端回退需要将旧版本 `web/dist` 重新复制到 `/usr/share/nginx/html/webdav` 并重启 nginx；统一目录迁移完成后改为切回 `/opt/deploy/static/warehouse-web/current` 指向的旧版本。
- 如果升级失败发生在模块脚本执行后、软链接更新前，服务可能已经运行在目标目录，但 `/opt/deploy/<module>` 仍指向旧目录，需结合进程和日志确认实际运行目录。
- `scripts/upgrade.sh` 的 `prepare` 返回 `10` 只跳过通用服务切换；`post-copy`、`finalize` 和软链接更新仍会继续执行。只有项目明确需要 custom-only 模式时才能使用该退出码。

## 常见故障处理

| 现象 | 可能原因 | 处理方式 |
| --- | --- | --- |
| `modules.conf` 缺失或模块列表为空 | 未从模板复制配置，或只写了注释 | 创建 `modules.conf` 并填写模块名 |
| WebDAV 认证失败 | `WEBDAV_PACKAGE_AK/SK` 错误 | 修正 `.env` 后重试 |
| 远程目录无安装包 | 制品未上传或模块名不匹配 | 执行打包上传，确认包名前缀与模块名一致 |
| 版本解析失败 | 包名不符合规范 | 重命名或重新生成安装包 |
| 当前版本目录不存在 | `/opt/deploy` 目录缺失或命名不规范 | 修正部署目录或软链接 |
| 解压失败或顶层目录不匹配 | 安装包结构不符合约定 | 重新打包，确保顶层目录与包名一致 |
| 项目升级脚本缺失或阶段不完整 | 目标安装包没有 `scripts/upgrade.sh` 或不支持 `copy-config` | 在项目中补齐标准阶段并重新打包 |
| 旧服务停止失败或无法确认进程退出 | 优雅停机超时、强制终止后仍有进程存活，或 PID 文件失效 | 查看模块日志和进程状态；不要启动目标版本，先处理残留进程或人工回退 |
| 重启后端口被占用 | 旧服务未完全退出，或存在未由 starter 管理的冲突进程 | 确认旧 PID、监听端口和进程命令；停止失败时不要反复执行 `restart` |
| 配置文件缺失 | 当前版本目录缺少 `.env`、`config.js` 或 `config.yaml` | 从备份或配置中心恢复后重试 |
| 健康检查失败 | 目标服务启动异常或依赖不可用 | 查看模块日志和健康检查输出，修复后重试或回退 |
| nginx 重启失败 | `warehouse` 前端发布权限或 nginx 配置异常 | 检查 systemd/nginx 日志，修复后重新发布前端 |

## 操作检查清单

升级前：

- [ ] 确认目标模块已写入 `operator/upgrade/modules.conf`。
- [ ] 确认 `.env` 中 WebDAV 地址和认证信息正确。
- [ ] 确认目标安装包和校验文件已上传到 WebDAV。
- [ ] 确认当前版本部署目录和配置文件存在。
- [ ] 确认当前版本 `scripts/starter.sh stop` 遵守优雅停机和退出确认约束。
- [ ] 确认已准备回退版本目录和回退命令。

升级中：

- [ ] 执行 `bash upgrade.sh`。
- [ ] 观察 `/opt/logs/upgrade.log`。
- [ ] 出现失败时查看对应模块日志。

升级后：

- [ ] 确认 `/opt/deploy/<module>` 软链接已更新。
- [ ] 确认服务进程和端口正常。
- [ ] 执行健康检查或 smoke test。
- [ ] 确认升级日志中没有停止失败、端口冲突或旧 PID 残留。
- [ ] 确认通知已发送或手动同步升级结果。
