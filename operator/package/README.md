# 安装包构建与发布

本目录专门负责创建、校验、传输和发布安装包。服务节点上的安装和升级由 [`../upgrade/README.md`](../upgrade/README.md) 负责。跨项目包格式见 [`../../specification/PACKAGING.md`](../../specification/PACKAGING.md)。

## 入口与配置

| 文件 | 用途 | 本地配置或日志 |
| --- | --- | --- |
| `compile_packages.sh` | 从 `main` 创建 release tag，构建、校验并上传所选仓库的制品 | `package-modules.conf`、`.env`；`/opt/logs/check-code-status.log` |
| `auto_package.sh` | 定时检查白名单路径变化，调用编译器发布受影响仓库 | `auto-package-paths.conf`；`/opt/logs/auto-package.log` |
| `package_manifest.sh` | 校验 manifest、制品摘要和归档结构 | 无 |
| `transfer_packages.sh` | 在 `/opt/package` 和 WebDAV 目录之间传输单个制品 | `.env`；`/opt/logs/transfer-packages.log` |
| `package-modules.conf` | 人工打包允许处理的源码仓库名单 | 每行一个仓库名 |
| `auto-package-paths.conf` | 自动打包仓库及其构建输入路径白名单 | 每行 `仓库 pathspec` |

在打包机配置：

```bash
cd /root/code/deployer/operator/package
cp package-modules.conf.template package-modules.conf
cp .env.template .env
chmod 600 .env
vi .env
```

`.env` 需填写 WebDAV 上传地址和凭据。可配置 `FILE_VERIFY` 为 `sha256sum` 或 `md5sum` 来上传校验 sidecar；`NOTIFY_FROM`、`NOTIFY_DINGDING` 和 `NOTIFY_FEISHU` 控制打包通知。凭据只保存在打包机，不要提交到 Git。显式发布需要 `jq`、`tar`、`git`、`curl` 以及 `sha256sum` 或 `shasum`。

`package-modules.conf` 列出可由编译器发布的仓库。每个仓库需要提供 `scripts/package.sh` 和符合规范的 `scripts/package-api.json`。配置名单与服务升级名单无关：静态或 desktop 制品仓库可以只出现在打包名单中。

从旧版目录迁移时，先暂停旧 timer，再更新 deployer。保留原有 WebDAV 凭据，并把打包配置迁到新目录：

```bash
systemctl disable --now deployer-auto-package.timer
cd /root/code/deployer
git fetch origin main
git status --short
git switch main
git merge --ff-only origin/main
cd /root/code/deployer/operator
if [[ ! -e package/package-modules.conf && -e upgrade/package-modules.conf ]]; then mv upgrade/package-modules.conf package/package-modules.conf; fi
if [[ ! -e package/auto-package-paths.conf && -e upgrade/auto-package-paths.conf ]]; then mv upgrade/auto-package-paths.conf package/auto-package-paths.conf; fi
if [[ ! -e package/.env && -e upgrade/.env ]]; then install -m 600 upgrade/.env package/.env; fi
install -m 0644 package/systemd/deployer-auto-package.service /etc/systemd/system/
install -m 0644 package/systemd/deployer-auto-package.timer /etc/systemd/system/
chmod 700 package/auto_package.sh
systemctl daemon-reload
cd /root/code/deployer/operator/package
./auto_package.sh --check
systemctl enable --now deployer-auto-package.timer
```

这里复制旧 `.env` 而不是移动它，因为打包器从 `package/.env` 读取发布凭据，升级器仍从 `upgrade/.env` 读取凭据和升级参数。若两边凭据不同，可分别维护。已有自动打包检查点保存在 `/var/lib/deployer-auto-package`，目录调整后不要重新初始化；检查通过后直接启用 timer。

## 人工打包

```bash
cd /root/code/deployer/operator/package
./compile_packages.sh --publish
```

默认从仓库最大语义版本递增 patch。需要递增 minor 或 major 时传入 `--bump minor` 或 `--bump major`。版本文件变更只存在于 tag 指向的 release commit，不推送到社区 `main`；tag 父提交为打包时最新的 `main` commit，制品名和 manifest 使用该 `main` commit 的短哈希。单个 artifact 可通过 `--unit-version REPOSITORY:UNIT=VERSION` 覆盖版本。

tag 创建后若构建、校验或上传失败，重试时复用同一 tag，例如：

```bash
./compile_packages.sh --publish --tag router:v0.0.163
```

编译器在临时 detached worktree 和空输出目录中构建，拒绝不干净或无法安全快进的仓库，不会把构建输出写入项目工作区。上传 manifest 前会校验清单和所有 artifact。成功上传表示制品已发布；是否升级由 `upgrade/upgrade.sh` 单独控制。

手动传输单个制品时，第二个参数必须只是文件名，不能包含目录：

```bash
./transfer_packages.sh upload router-v1.2.3-a1b2c3d.tar.gz
./transfer_packages.sh download router-v1.2.3-a1b2c3d.tar.gz
```

## 定时自动打包

自动任务每 15 分钟检查 `auto-package-paths.conf` 中列出的仓库。仓库必须同时列在 `package-modules.conf`。pathspec 应覆盖 `scripts/package.sh` 实际使用的全部输入，例如源码、依赖清单、静态资源、版本配置和打包脚本；配置 `.` 表示仓库任意变更都会触发打包。先检查各项目构建脚本，再启用相应行：

```bash
cd /root/code/deployer/operator/package
cp auto-package-paths.conf.template auto-package-paths.conf
vi auto-package-paths.conf
chmod 600 auto-package-paths.conf
```

首次安装时先建立所有白名单仓库的检查点。初始化只记录当前 `origin/main`，不会创建 tag 或发布：

```bash
./auto_package.sh --initialize
./auto_package.sh --check
```

之后新增仓库时，先把它加入 `package-modules.conf` 和 `auto-package-paths.conf`，再只初始化该仓库，例如 `./auto_package.sh --initialize router`。

检查无误后安装定时器：

```bash
systemd-analyze verify systemd/deployer-auto-package.service systemd/deployer-auto-package.timer
chmod 700 auto_package.sh
install -m 0644 systemd/deployer-auto-package.service /etc/systemd/system/
install -m 0644 systemd/deployer-auto-package.timer /etc/systemd/system/
systemctl daemon-reload
./auto_package.sh --check
systemctl enable --now deployer-auto-package.timer
```

部署后查看状态和日志：

```bash
systemctl list-timers deployer-auto-package.timer
systemctl start deployer-auto-package.service
systemctl status deployer-auto-package.service
journalctl -u deployer-auto-package.service -n 100 --no-pager
tail -n 100 /opt/logs/auto-package.log
```

自动任务与人工发布共用编译锁，避免并发。无相关变更时只推进该仓库检查点；有相关变更时只发布受影响仓库。成功上传 manifest 后才推进检查点。失败 tag 保存在 `/var/lib/deployer-auto-package/<repository>.pending` 并在下轮复用；若进程在创建 tag 后退出，下一轮会根据 tag 的 `Source-Commit` 恢复重试。

该任务只构建、校验并上传制品，不运行 `upgrade.sh`。若测试环境有轮询升级任务，上传后测试环境可能自动升级；生产升级仍需在部署节点独立执行。暂停定时发布：

```bash
systemctl disable --now deployer-auto-package.timer
```

GitHub 的 `main` 应继续受 PR 和状态检查规则保护，打包凭据不应进入绕过名单；通过 tag ruleset 禁止删除或移动 `v*` 发布 tag。systemd 服务以 root 运行以兼容 `/root/code`、凭据和 `/opt` 目录权限。

## 回归测试

```bash
bash operator/package/tests/test_package_manifest.sh
bash operator/package/tests/test_package_api_common.sh
bash operator/package/tests/test_compile_packages_sync.sh
bash operator/package/tests/test_compile_manifest_filename.sh
bash operator/package/tests/test_auto_package.sh
bash operator/package/tests/test_auto_package_state.sh
```
