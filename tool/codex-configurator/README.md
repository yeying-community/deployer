# 夜莺 Codex 配置器

Windows 本机小工具。中转地址固定为 `https://router.yeying.pub/v1`，API Key 由使用者自己填写，模型可下拉选择或直接输入。双击 EXE 即可使用，不需要安装 Python。

## 使用

1. 打开 `Yeying-Codex-Setup.exe`，默认选择 **Codex App**。
2. 粘贴自己的夜莺 Router API Key。
3. 从模型下拉框选择模型；也可以直接填写模型名。
4. 工具会自动定位配置，直接点击 **应用配置**，无需选择文件。
5. 完全退出 Codex，重新打开并新建对话。

已有配置时显示并保留当前模型；没有配置时默认 `gpt-6.1-sol`。内置以下五个模型名称，无需联网获取：

- `gpt-6.1-sol`
- `gpt-6.1-terra`
- `gpt-6-astra`
- `gpt-6-luna`
- `gpt-6-sol`

列表依据 [OpenAI 当前 Codex 模型说明](https://learn.chatgpt.com/docs/models)，核对于 2026-11-01。这是预置名称，不代表夜莺 Router 或当前 Key 已开通全部模型；其他模型或中转站别名可直接手填。

点击右上角“夜莺 Router ↗”可打开夜莺 Router 网站。路径区域会显示自动定位的配置位置；首次保存时会自动创建文件。需要更改位置时可展开“高级设置”。App、CLI 和 Codex VS Code 插件在同一 Windows 用户及相同 `CODEX_HOME` 下共用此配置。

## 保存和恢复

- 优先使用 `CODEX_HOME/config.toml`；未设置时，通过 Windows 系统 API 获取当前用户目录并使用 `.codex/config.toml`。
- 使用 TOML 解析器修改顶层 `model`、`model_provider` 及 `model_providers.yeying`，保留其他提供商、MCP、偏好、注释与会话文件。夜莺提供商的冲突认证字段会被移除。
- 已有 `auth.json` 保持原样。缺少该文件、且未选择仅钥匙串或临时凭据时，补建同一 Key 的本地 API 登录文件，便于首次使用。已有系统钥匙串与企业强制登录限制不自动修改。
- 当前旧式内联 profile 中已有的模型覆盖会同步到夜莺；独立 profile 文件若覆盖模型则提示处理，避免保存后无效。启动参数、其他工具的 profile 选择及管理员策略仍可能覆盖默认值。
- 每次实际修改前，在配置目录的 `.yeying-configurator` 中创建 **Windows DPAPI 加密备份**，可由同一 Windows 账号用于故障恢复。
- 写入前再次比较文件，使用同目录临时文件加替换；第二个文件失败时撤销第一处修改。系统断电等异常情况下保留加密恢复文件供检查。它不是跨多个文件的操作系统事务。
- 不主动关闭 Codex，不读改聊天记录，不修改系统环境变量。模型列表和配置保存均离线完成。Key 只写入必要的本地配置，不显示在日志或错误原文中。实际配置中的 Key 是明文，应保留在用户自己的受保护目录中；备份为当前 Windows 账号加密。

“保存成功”只表示本地配置写入并校验完成，不代表 Key 的权限、额度或模型可用性已通过验证。

## 开发与构建

Python 3.11+，Windows 10/11 x64。

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-build.txt
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
.\build.ps1
```

在本目录执行以上命令，生成 `dist/Yeying-Codex-Setup.exe`。也可运行 `.\.venv\Scripts\python.exe app.py` 直接启动。首次打开 EXE 时会解压运行库，可能等待几秒。

可复现的隔离 GUI 检查（必须提供尚未使用的新目录，不触碰用户真实配置）：

```powershell
.\dist\Yeying-Codex-Setup.exe --self-test (Join-Path $env:TEMP ('codex-check-' + [guid]::NewGuid()))
```

目录内生成 `self-test.json`，记录自动定位、首次新建、默认收起高级设置、恢复自动定位，以及五个预置模型逐一保存、手动输入、已有模型保留、原设置保留、重复保存和恢复的结果。检查通过独立的临时 `CODEX_HOME` 走真实自动定位路径，使用假 Key，不请求中转站或模型。

## 配置依据

- [OpenAI 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)：本版沿用社区现有教程的 `experimental_bearer_token`。官方仍列出此字段，同时推荐环境变量认证；本版为满足桌面用户输入一次且不改环境变量而使用直接 Token。
- [OpenAI 认证说明](https://learn.chatgpt.com/docs/auth)。
- [Codex 环境变量与目录](https://learn.chatgpt.com/docs/config-file/environment-variables)。
