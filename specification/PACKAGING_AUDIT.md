# 社区项目打包兼容性审计

本审计对应统一的[社区项目打包规范](./PACKAGING.md)。基线来自 2026-11-04 对 11 个仓库的文件静态检查，本轮另将独立 Wallet 扩展仓库纳入，目标覆盖 12 个仓库。为 Wallet 新增 v1 安全 package API 和 tag/version 配置；8 个旧服务包脚本已改为显式 `--ref`、`--version`、`--output-dir` 并生成 manifest。Homepage 的完整静态打包和 Billing 的 Go service 打包均已在干净 detached worktree 中通过；静态安装、版本切换、HTTP 检查和失败回滚已在本机临时部署目录中执行。其余产品完整构建、真实服务器升级和外部定时任务仍未验收。`scripts/upgrade.sh` 表示存在项目级 hook，不等于已经完成统一升级验收。

本轮发布流程调整中：每个项目新增 `scripts/tag.sh`，由显式打包操作自动递增 patch/minor/major、同步 `version-files.conf` 中的项目 JSON 版本、按需提交 artifact 版本覆盖、创建并推送社区 main/tag。编译器随后按 tag commit 构建。支持 `--unit-version` 设置不同 artifact 版本、`--tag` 重建已有版本。该实现尚待社区仓库 PR 合并和打包机实际执行验收；操作规则见 [PACKAGING.md 的 Git tag 说明](./PACKAGING.md#git-tag-何时创建)。

这里的“安全 package API”是 `scripts/package.sh` 的命令行契约，不是 HTTP API。`scripts/package-api.json` 是每个源码仓库的调用方式/副作用声明，供发布器执行前做 fail-closed 检查；它不同于每次构建输出的 `release-manifest.json`，后者记录本次实际产物。该 JSON 不是沙箱或安全证明，必须与 detached worktree、临时输出目录、发布器校验和代码审查配合使用。完整四种制品的打包、部署和升级示例见 [PACKAGING.md 的完整流程示例](./PACKAGING.md#打包部署和升级完整流程)。

对 node、warehouse、router、chat、homepage、project、social、knowledge、orchestrator、books、billing、wallet 的 12 份文件做了逐项比较，当前内容完全相同：都声明 v1、三个公共参数、不由 `package.sh` 创建或推送 Git ref、使用隔离 checkout，并输出 `release-manifest.json`。仍将文件放在各仓库，是为了让该仓库明确 opt in，并使声明与对应 `package.sh` 一起随 commit 评审；发布器可在运行项目代码前检查目标仓库版本是否符合契约。它不是存项目构建差异的配置文件；构建技术栈和制品类型的差异放在 `package.sh` 与每次构建的 manifest 中。未来新增字段必须同步更新规范、发布器校验及调用行为；当前未识别的字段不会自动生效。字段逐项解释和新项目复制模板、验证声明的操作步骤见 [PACKAGING.md 的 package-api.json 说明](./PACKAGING.md#package-apijson-字段逐项说明)。

| 项目 | 当前交付单元 | `package.sh` | package API / manifest | starter / health / smoke | upgrade hook | 必须补齐或确认的项目缺口 |
| --- | --- | --- | --- | --- | --- | --- |
| node | Node API + web 组合服务 | 有；v1 CLI | 有 / 有（service-with-assets） | 有 / 有 / 有（已随包脚本声明，未做产品包验收） | 有 | 已迁移显式 ref/version/output-dir，前后端使用 `npm install` 构建，生产依赖随包交付；npm 依赖解析随 registry 和打包时间变化；仍需验证 secrets vault 交互、真实构建及包外运行。 |
| warehouse | 后端服务 + web（原 all/backend/frontend 能力） | 有；v1 CLI | 有 / 有（warehouse service-with-assets + warehouse-web static） | 有 / 有 / 有（已随服务包，未做产品包验收） | 有 | 新包同时输出组合服务和静态 web 单元；仍需确认两个单元的版本/回滚边界，把 hook 和 Nginx root 从 `/usr/share/nginx/html/webdav` 迁至标准目录，并验证 `npm install` 构建与实际 HTTP 回滚。 |
| router | Go + web 组合服务 | 有；v1 CLI | 有 / 有（service-with-assets） | 有 / 有 / 有（已随包脚本声明，未做产品包验收） | 有 | 已将 Go 与 web 按组合单元打包、移除 TAG 和远端同步行为；仍需运行干净构建、确认嵌入/外置静态资源边界并完成测试环境验收。 |
| chat | standalone、export、desktop app、app-release | 有；v1 CLI（当前覆盖 standalone） | 有 / 有（chat service；export/desktop 尚未纳入） | 有 / 有 / 有（standalone 包入口） | 有 | v1 package API 仅构建 standalone 服务；export、desktop app 和需签名的 app-release 仍需独立制品类型与发布流程，不能加入服务器升级。需确认既有按模式调用者的迁移。 |
| homepage | 三个独立静态站点：`yeying`、`tidukongjian`、`wallet` | 有；按显式 ref 构建 | 有 / 有（3 个 static artifact；完整打包及 manifest 校验通过） | 不适用 / 不适用 / 静态入口待验收 | 不适用 | 打包流程使用 `npm install` 构建两个前端并生成三个 artifact；npm 依赖解析随 registry 和打包时间变化。Next 字体 CSS/字体通过 `fonts.googleapis.cn`、`fonts.gstatic.cn` 镜像进入构建，字体随静态产物自托管。本机临时 HTTP 部署已验证 `current` 从 `v0.0.0` 切到 `v0.0.1`、HTTP 200 和故意失败后的回滚。真实 `upgrade.sh` 服务器轮询、vhost 和外部 URL 仍需测试环境确认。 |
| project | PHP 服务 + web / Electron 客户端 | 有；v1 CLI | 有 / 有（service-with-assets） | 有 / 有 / 有（已随包脚本声明，未做产品包验收） | 有 | PHP 依赖使用 `composer.lock` 锁定，前端使用 `npm install` 且不跟踪 npm 锁文件；Electron 仍是独立发布单元，不包含在服务包。需按仓库 README 的人工构建限制完成真实构建、包外运行和回滚验收。 |
| social | 多个 Java 服务、web、uniapp | 有；v1 CLI | 有 / 有（现有四个 Java 服务 + web 组合包） | 有 / 有 / 有（组合服务包，未做产品包验收） | 有 | 先按现有 starter 的共同启停边界提供组合服务 artifact；尚无证据证明各 Java 服务能独立部署回滚，web 静态和 uniapp 也未独立发布。需先确认所有权边界，再决定是否拆包。 |
| knowledge | API + web + worker | 有；v1 CLI | 有 / 有（service-with-assets） | 有 / 有 / 有（已随包声明；锁定 Python 依赖并随包提供虚拟环境，未做产品包验收） | 缺 | API、worker 和 web 当前按一个服务单元打包；有 health/smoke 入口并明确不自动纳入统一升级。仍需验证目标 Python/OS 对随包虚拟环境的兼容性，并决定是否接入统一升级。 |
| orchestrator | backend、web、agent/runtime 资源 | 有；v1 CLI | 有 / 有（backend + web + agents 组合服务） | 有 / 有 / 有（smoke 覆盖 readiness、版本 API、控制台首页和未认证访问拒绝；未覆盖需测试身份的业务闭环） | 缺 | `test.sh` 保留是因为获批服务包契约要求独立 smoke 入口，不能与 readiness 健康检查合并；脚本已改为执行实际只读 HTTP 检查，不再只是转调 health-check。仍需确认 agent/runtime 是否应独立版本化，验证目标运行环境，并决定是否纳入统一升级。 |
| books | 社区文档、reader、payment 应用等候选单元 | 有；reader 静态站显式 ref 构建 | 有 / 有（books-reader static；本轮 fixture 验证） | reader 不适用 / 不适用 / 静态入口待验收；`saas-mvp` 是否部署待确认 | 不适用 | 已按 README 确认 VitePress reader 是静态站并新增打包入口/API；`output/` 已忽略。Payment `saas-mvp` 是另一个 FastAPI 候选应用，但仓库未提供部署证据，尚未纳入制品或增加运行服务契约。 |
| billing | Go 后端服务 | 有；v1 CLI | 有 / 有（service；clean package 验证） | 有 / 有 / 有 | 有 | 已在干净 worktree 编译 Linux amd64 服务包，manifest、SHA-256、归档结构和必需服务入口通过校验；包外运行、smoke 和目标服务器升级仍待验收。 |
| wallet | 浏览器扩展 | 已迁移 v1 CLI | 有 / 有（desktop ZIP） | 不适用 | 不适用 | `manifest.json.version` 作为项目版本源；ZIP 扩展包由 manifest 清单记录并校验。需在打包机验证 zip/zipinfo 工具、扩展加载和签名/商店发布流程。 |

**npm 依赖策略：** node、warehouse、router、chat、homepage、project、social、knowledge、orchestrator 和 books 不跟踪 `package-lock.json`，打包脚本统一使用 `npm install`。因此 npm 依赖版本由打包时 registry 的解析结果决定，不能保证不同日期的构建得到完全相同的依赖树。该规则只针对 npm 锁文件；`composer.lock`、`uv.lock` 等其他生态的锁文件继续按各项目原有规则使用。

表中“package API / manifest”分别表示源码中的 `scripts/package-api.json` 声明和构建输出的 `release-manifest.json`。前者是一份每仓库一份、发布前读取的 v1 CLI 契约；后者是一份每次构建一份、记录真实制品的版本清单。所有仓库的 package API 与包脚本已迁移到统一参数；脚本语法/API 和 manifest fixture 已验证，Homepage、Billing 的完整打包及本地静态升级已通过。其他产品构建、服务包外运行和真实服务器升级仍未验收。纯静态、桌面和文档单元不应为填表而增加空服务 hook。

## 每项目必须完成的通用迁移项

8 个历史服务包脚本（node、warehouse、router、chat、project、social、knowledge、orchestrator）现已接收明确的 `--ref`、`--version`、`--output-dir`，校验当前 commit 和工作区，并输出 manifest；脚本不再 fetch/switch、创建或推送 TAG、上传制品或清理传入输出目录。homepage、books、billing 也有安全 API 声明。项目完整构建、包外运行和依赖兼容仍需逐一验收。

所有 12 个仓库都有 `scripts/package-api.json`，声明支持参数、无 Git 写入能力、隔离构建和 manifest 文件名。所有实际运行服务必须随包提供符合 [PACKAGING.md](./PACKAGING.md) 的 `starter.sh`、`health-check.sh` 和 `test.sh --suite smoke`；独立静态或 desktop 单元不要求服务脚本。12 个仓库的 `output/` 均已通过 `git check-ignore` 验收。

## 跨项目共性

- 12 个仓库现在都有仓库级 `scripts/package.sh` 和 package API；`compile_packages.sh` 可从独立 `package-modules.conf` 接收与升级名单不同的仓库清单，并校验/上传多 artifact 和 static-only manifest。该配置文件需在发布节点从模板创建。
- 8 个旧服务包脚本已迁移到新 API；node、router、chat、project、orchestrator 的 smoke 入口和 knowledge、orchestrator 的 health check 会进入服务包。Homepage 静态包和 Billing Go 服务包已完成干净构建；其他产品的生产构建、服务运行环境和服务器升级验收仍未执行。静态单元不要求服务型 `starter.sh`。
- 统一升级清单当前仅含 chat、node、project、router、social、warehouse、billing；knowledge 和 orchestrator 尚未接入。静态资源与桌面产物不能直接塞入当前服务升级清单。
- 统一升级器的服务单元选择仍使用 legacy 包名，尚未按 manifest 选择服务 artifact；static 单元已有独立处理器，可从 `static-units.conf` 读取站点、消费 manifest、校验 SHA-256 和归档、原子切换 `current`，并在 HTTP 检查失败时恢复旧指向。Homepage 已完成本机版本切换和回滚演练；Homepage、Books 和 warehouse 的真实站点部署仍待 vhost 迁移与环境演练；desktop 暂无服务器部署处理器。
- chat 的 export/desktop/app-release、project 的 Electron、social 的 uniapp 和 knowledge/orchestrator 的运行时边界仍需独立发布决策，不能由当前单一服务包契约代替。
- warehouse、router、chat、homepage、project、social、knowledge、orchestrator、books 有未提交改动（包括本轮新增文件）。后续适配必须继续保留各仓库已有的用户改动，逐文件检查后再编辑。

## 接入顺序

1. 完成 unit 所有权与版本边界确认，给每个仓库补充 `release-manifest.json` 生成能力。
2. 迁移 package scripts 到显式 ref/version、确定性依赖安装、隔离 worktree 和无 Git/网络发布副作用。
3. 补齐每个运行服务的 starter、health 和 smoke 契约；静态单元验证站点目标与回滚。
4. 逐个单元运行干净构建、manifest/hash 验证、包外解压、测试环境升级和回滚演练。
5. 仅将已通过完整接入验收的 service 单元加入统一升级清单；static 与 desktop 使用对应发布处理器。

## 外部调度状态

仓库没有测试/生产服务器或 CI 的 cron、systemd、GitHub Actions 配置，因而不能仅凭本审计声称“自动打包已关闭”或“测试环境轮询已生效”。环境负责人需要检查并记录：禁用 `compile_packages.sh` 的定时/代码变更触发；保留测试环境 `upgrade.sh` 的轮询；生产环境 `upgrade.sh` 只由人工审批触发。实际调度的禁用和运行验证是部署环境验收项。

## Deployer 实施状态

当前仓库提供 `package_manifest.sh`（POSIX shell + `jq`）进行 manifest、摘要、归档结构和静态入口校验；显式发布需安装 `jq`、`tar` 和 `sha256sum` 或 `shasum`。`compile_packages.sh` 无参数时不再加载运行环境；显式发布要求项目声明安全 package API，并在临时 detached worktree 中生成和校验制品。打包仓库名单可通过独立的 `package-modules.conf` 配置，因此静态-only 仓库也能进入发布构建，而无需加入服务升级清单。

所有 12 个仓库均已迁移包脚本 API。`upgrade.sh` 已增加可选静态单元处理：从 `static-units.conf` 读取已配置站点，消费版本 manifest，校验制品 SHA-256 和归档，部署到标准静态目录并执行 HTTP 检查；检查失败会恢复原 `current` 软链接。desktop 尚无服务器部署处理器。各服务的产品构建、包外运行、测试/生产升级演练、站点 vhost 迁移，以及外部调度核验仍未完成，不能据此启用新发布链路。

## Homepage 静态单元

仓库有三个可独立发布的网站，manifest 分别定义三个 `static` artifact。独立部署的前端静态资源统一使用 `/opt/deploy/static/<site_id>`，`site_id` 全社区唯一并以前缀区分仓库，因此不再由各项目选择 `/var/www`、`/usr/share/nginx/html` 等不同根目录：

| unit ID | 构建输入 | 制品内容 | 站点/部署目标 |
| --- | --- | --- | --- |
| `homepage-yeying` | `yeying/`；执行 `npm install`，再运行 `npm run build`；Vite `build.outDir` 为 `output` | `yeying/output/` | 最终制品：`output/homepage-yeying-v<version>-<commit>.tar.gz`；`site_id: homepage-yeying`；部署根目录 `/opt/deploy/static/homepage-yeying` |
| `homepage-tidukongjian` | `tidukongjian/`；执行 `npm install`，再运行 `npm run build`；Next 静态导出配置 `distDir: "output"` | `tidukongjian/output/` | 最终制品：`output/homepage-tidukongjian-v<version>-<commit>.tar.gz`；`site_id: homepage-tidukongjian`；部署根目录 `/opt/deploy/static/homepage-tidukongjian`，现有 Nginx root 需要迁移 |
| `homepage-wallet` | 直接收集 `wallet/`，无需前端构建 | `index.html`、`main.js`、`assets/`、`docs/`、`robots.txt`、`sitemap.xml` 等完整静态目录 | 最终制品：`output/homepage-wallet-v<version>-<commit>.tar.gz`；`site_id: homepage-wallet`；域名为 `wallet.yeying.pub`，部署根目录 `/opt/deploy/static/homepage-wallet` |

`homepage/scripts/package.sh` 与 `scripts/package-api.json` 已实现上述三个单元：两个应用站执行 `npm install` 构建，并直接收集 wallet 静态文件；两个前端的构建产物分别写入 `yeying/output/` 和 `tidukongjian/output/`。npm 锁文件不纳入版本控制，因此依赖解析版本由打包时 registry 提供的元数据决定，构建结果可能随时间变化。完整 `package.sh` 曾在干净 detached worktree 中成功执行，生成三个静态归档，`package_manifest.sh` 对 repository、source commit、version、摘要和归档结构的检查通过。`tidukongjian` 使用 `next/font/google`，Next.js 默认会请求 `fonts.googleapis.com`；打包脚本调用 `prepare_google_fonts_mirror.sh` 从 `fonts.googleapis.cn` 获取 CSS 响应映射，字体文件从 `fonts.gstatic.cn` 下载后由 Next.js 写入静态产物。该构建使用 Next.js 的 `NEXT_FONT_GOOGLE_MOCKED_RESPONSES` 钩子；修改字体名称/字重或升级 Next.js 时，必须同步更新并重新验证镜像映射。每个内容目录放入 `<unit-id>-v<version>-<7-char-commit>/`，计算 tarball SHA-256，并在同一份 manifest 中记录三个 artifact。直接在项目工作区打包时，统一传入 `--output-dir output`，最终归档和 `release-manifest.json` 写入仓库根目录的 `output/`；编译器在隔离 worktree 中构建时传入独立临时目录。静态仓库通过独立的 `package-modules.conf` 接入发布；部署前仍需将 vhost 迁移并填入、验证 `static-units.conf`。

静态制品部署在 `/opt/deploy/static/<site_id>/releases/<package_root>`，站点稳定目录 `/opt/deploy/static/<site_id>/current` 通过原子软链接指向当前版本。部署器使用 GNU/BSD 对应的 `mv` 参数替换已有 `current`，并在 HTTP 检查前确认链接确实指向目标 release；检查失败会恢复旧指向，旧版本目录保留供人工回退。本机临时 HTTP 演练已验证从 `v0.0.0` 升至 `v0.0.1`、目标页面返回 200，以及 `v0.0.2` 健康检查失败后仍指回 `v0.0.1`。`tidukongjian` 需要把现有 Nginx root 迁移至 `/opt/deploy/static/homepage-tidukongjian/current`；`yeying` 和 `wallet` 仍需确认实际 Nginx/静态宿主和 vhost。实际部署服务器的 `upgrade.sh` 轮询、线上 URL、vhost 和升级仍未验证。

## Books 静态单元

`books/README.md` 将 `reader/` 定义为基于 VitePress 的静态阅读站，正文通过符号链接读取 `payment/`、`agent/`、`yeying/` 等原始 Markdown。`books/scripts/package.sh` 使用 `npm install` 构建该站，并生成 `books-reader` static artifact，目标为 `/opt/deploy/static/books-reader`；不需要仓库级 service starter。npm 锁文件不纳入版本控制，依赖解析版本由打包时 registry 提供的元数据决定。`scripts/package-api.json` 已声明安全参数契约，合成 fixture 已通过 manifest、SHA-256 和 tar 结构检查，真实依赖构建尚未运行。

`payment/saas-mvp` 含独立 FastAPI 代码和 Dockerfile，但当前 README 将其描述为设计伙伴验证/咨询交付的 MVP，仓库没有部署或运行环境证据。本轮不将它标记成生产部署单元；如后续决定接入，需要单独确认部署所有权、运行方式、静态/服务边界及回滚责任，再补服务入口。
