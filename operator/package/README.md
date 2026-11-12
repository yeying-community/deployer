# 安装包构建与发布

本目录专门负责创建、校验、传输和发布安装包。服务节点上的安装和升级由 [`../upgrade/README.md`](../upgrade/README.md) 负责。跨项目包格式见 [`../../specification/PACKAGING.md`](../../specification/PACKAGING.md)。

## 入口与配置

| 文件 | 用途 | 本地配置或日志 |
| --- | --- | --- |
| `compile_packages.sh` | 从 `main` 创建 release tag，构建、校验并上传所选仓库的制品 | `manual-package.conf`、`.env`；`/opt/logs/check-code-status.log` |
| `auto_package.sh` | 定时检查自动名单中的路径变化，发布受影响仓库 | `auto-package.conf`；`/opt/logs/auto-package.log` |
| `package_manifest.sh` | 校验 manifest、制品摘要和归档结构 | 无 |
| `transfer_packages.sh` | 在 `/opt/package` 和 WebDAV 目录之间传输单个制品 | `.env`；`/opt/logs/transfer-packages.log` |
| `manual-package.conf` | 手动打包默认处理的源码仓库名单 | 每行一个仓库名 |
| `auto-package.conf` | 自动打包仓库及其构建输入路径白名单 | INI 风格的 `[仓库名]` 分节和 `path=...` 项 |

在打包机配置：

```bash
cd /root/code/deployer/operator/package
cp manual-package.conf.template manual-package.conf
cp .env.template .env
chmod 600 .env
vi .env
```

`.env` 需填写 WebDAV 上传地址和凭据。可配置 `FILE_VERIFY` 为 `sha256sum` 或 `md5sum` 来上传校验 sidecar；`NOTIFY_FROM`、`NOTIFY_DINGDING` 和 `NOTIFY_FEISHU` 控制打包通知。凭据只保存在打包机，不要提交到 Git。显式发布需要 `jq`、`tar`、`git`、`curl` 以及 `sha256sum` 或 `shasum`。

`manual-package.conf` 只控制手动运行 `compile_packages.sh --publish` 时默认处理哪些仓库。每个仓库需要提供 `scripts/package.sh` 和符合规范的 `scripts/package-api.json`。这份手动名单与自动打包和服务升级名单相互独立；静态或 desktop 制品仓库也可以只出现在手动名单中。

手动默认名单包含多个仓库、但本次只打包其中一个时，可通过临时仓库名单选择目标，不必修改常驻配置：

```bash
printf 'router\n' > /tmp/router-repositories.conf
./compile_packages.sh --publish --repositories-file /tmp/router-repositories.conf
rm /tmp/router-repositories.conf
```

从旧版目录迁移时，先暂停旧 timer，再更新 deployer。保留原有 WebDAV 凭据。旧的手动仓库名单 `package-modules.conf` 或 `manual-package-repositories.conf` 可改名为 `manual-package.conf`，不要把自动仓库再复制进这份手动名单。旧自动配置 `auto-package-paths.conf` 使用“仓库 路径”格式，不能直接改名；请按下方新格式转换后保存为 `auto-package.conf`：

```ini
[router]
path=:(glob)internal/**/*.go
path=:(top,literal)go.mod
path=scripts/

[homepage]
path=wallet/
```

自动配置的每个仓库必须有一个 section；同一仓库可重复写 `path=`。当前仅支持 `path`，尚未实现的键会报错。

```bash
systemctl disable --now deployer-auto-package.timer
cd /root/code/deployer
git fetch origin main
git status --short
git switch main
git merge --ff-only origin/main
cd /root/code/deployer/operator
if [[ ! -e package/manual-package.conf && -e package/manual-package-repositories.conf ]]; then mv package/manual-package-repositories.conf package/manual-package.conf; fi
if [[ ! -e package/manual-package.conf && -e package/package-modules.conf ]]; then mv package/package-modules.conf package/manual-package.conf; fi
if [[ ! -e package/manual-package.conf && -e upgrade/package-modules.conf ]]; then mv upgrade/package-modules.conf package/manual-package.conf; fi
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

默认从仓库最大语义版本递增 patch。需要递增 minor 或 major 时传入 `--bump minor` 或 `--bump major`。版本文件变更只存在于 tag 指向的 release commit，不推送到社区 `main`；tag 记录打包时的 `main` 源码提交，制品名和 manifest 使用该 `main` commit 的短哈希。脚本会比较 `origin/main` 与最新 release tag 记录的源码提交：相同则跳过，不创建新 tag、不构建也不上传。需要重新生成已有版本的制品时，显式传入 `--tag REPOSITORY:vVERSION` 可重建该 tag。单个 artifact 可通过 `--unit-version REPOSITORY:UNIT=VERSION` 覆盖版本。

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

自动任务每 15 分钟检查 `auto-package.conf`。用 `[仓库名]` 声明仓库，并为每个需要监控的路径写一条 `path=`。例如：

```ini
[router]
path=:(glob)internal/**/*.go
path=:(top,literal)go.mod
path=scripts/

[homepage]
path=wallet/

[tester]
path=.
```

路径值使用 Git 的路径匹配规则：`path=scripts/` 匹配该仓库 `scripts/` 目录下的文件；`path=:(glob)internal/**/*.go` 匹配 `internal/` 下各层目录中的 Go 文件；`path=:(top,literal)go.mod` 只匹配仓库根目录的 `go.mod`。同一仓库可以写多条 `path=`，任意一条路径有变化都会触发该仓库打包。分节名必须是小写字母、数字或连字符组成的仓库名。配置解析器当前只接受 `path` 键；将来新增键时，需要先实现并验证其行为，再写入配置。

`tester` 的 `path=.` 表示仓库根目录下的所有路径，因此 tester 的任意已提交文件变更都会触发打包，包括文档和测试变更。只有项目确实需要每次提交都生成新包时才使用 `.`；否则应只列出会影响制品的源码、依赖清单、静态资源、版本配置和打包脚本。自动任务只检查 `main` 上的已提交变更，不会因本地未提交文件触发。自动名单完全独立于 `manual-package.conf`：加入自动配置的仓库不需要再加入手动名单。

模板中的示例以 `#` 注释，不会生效。复制模板后，先检查项目 `scripts/package.sh` 实际使用的输入，再启用并调整对应路径：

```bash
cd /root/code/deployer/operator/package
cp auto-package.conf.template auto-package.conf
vi auto-package.conf
chmod 600 auto-package.conf
```

首次安装时先建立所有白名单仓库的检查点。初始化只记录当前 `origin/main`，不会创建 tag 或发布：

```bash
./auto_package.sh --initialize
./auto_package.sh --check
```

之后新增自动打包仓库时，只需把它加入 `auto-package.conf`，再初始化该仓库，例如 `./auto_package.sh --initialize router`。这不会改变手动打包名单。若还希望普通手动打包命令默认包含它，再单独加入 `manual-package.conf`。

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
bash operator/package/tests/test_compile_profile.sh
bash operator/package/tests/test_auto_package.sh
bash operator/package/tests/test_auto_package_state.sh
```
