# OnlyOffice Docs

OnlyOffice Docs 是 Project 用于预览和编辑 Office 文件的独立文档服务。Project 前端通过它的 JavaScript API 初始化编辑器，OnlyOffice 服务再从 Project API 读取文件，并通过回调地址把编辑结果写回 Project。

当前目录提供基于 Docker Compose 的本地或内网部署模板，默认使用 OnlyOffice Docs Community Edition 镜像：

```text
onlyoffice/documentserver
```

## 快速启动

复制环境变量模板：

```bash
cp .env.template .env
```

修改 `.env`，至少替换 JWT 密钥：

```dotenv
# 使用 base64:<Base64 编码随机值> 格式的 JWT 密钥
ONLYOFFICE_JWT_SECRET=base64:xpNmD8Fm87v8CabmO1wfA4gvNVYa9aDmtQL8afQhPHY=
```

JWT 密钥可以使用 OpenSSL 生成。下面的命令会生成 32 个随机字节，并以
`base64:<Base64 编码值>` 格式输出：

```bash
printf 'base64:%s\n' "$(openssl rand -base64 32)"
```

将命令输出的完整内容（包括 `base64:` 前缀）写入 `.env` 的
`ONLYOFFICE_JWT_SECRET`。`base64:` 是格式前缀，后面的内容是 Base64 编码的
随机密钥；Project 侧必须配置完全相同的字符串。示例值仅用于说明格式，生产环境
请使用命令重新生成，并不要将真实密钥提交到 Git 仓库。

启动服务：

```bash
./start.sh
```

启动完成后访问：

```text
http://127.0.0.1:18088
```

验证 API 脚本：

```text
http://127.0.0.1:18088/web-apps/apps/api/documents/api.js
```

## 配置项

`.env` 支持以下配置：

```dotenv
# OnlyOffice Document Server 镜像版本
ONLYOFFICE_VERSION=8.2

# 宿主机监听地址和端口
ONLYOFFICE_BIND_ADDRESS=127.0.0.1
ONLYOFFICE_PORT=18088

# OnlyOffice JWT 配置，密钥必须使用 base64:<Base64 编码随机值> 格式，
# 且 Project 侧必须使用完全相同的字符串。
ONLYOFFICE_JWT_SECRET=base64:xpNmD8Fm87v8CabmO1wfA4gvNVYa9aDmtQL8afQhPHY=
ONLYOFFICE_JWT_HEADER=Authorization
ONLYOFFICE_JWT_IN_BODY=true
```

默认只监听 `127.0.0.1`。如果要给其他机器访问，可改为内网地址或 `0.0.0.0`，并配合防火墙或反向代理限制访问面。

## Project 接入

Project 里的 OnlyOffice 组件默认加载：

```text
/office/web-apps/apps/api/documents/api.js
```

因此部署时需要在 Project 的前置 nginx 或网关中把 `/office/` 代理到 OnlyOffice 服务。例如本机端口部署时：

```nginx
location /office/ {
    proxy_pass http://127.0.0.1:18088/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

如果 Project 和 OnlyOffice 都运行在 Docker 网络中，也可以把 `proxy_pass` 指向容器服务名或网络别名。

Project 后端还需要与 OnlyOffice 使用相同的 JWT 密钥。具体配置项以 Project 当前版本的 `.env.template` 和插件配置为准，核心要求是：

```text
OnlyOffice JWT Secret == Project Office JWT Secret
```

## 文件访问链路

Project 当前文件链路大致是：

```text
浏览器
  -> Project 页面
  -> /office/web-apps/apps/api/documents/api.js
  -> OnlyOffice 编辑器

OnlyOffice 服务
  -> http://nginx/api/file/content?... 读取文件
  -> http://nginx/api/file/content/office?... 回调保存
```

部署时必须保证 OnlyOffice 容器可以访问 Project 传入的文件下载 URL 和保存回调 URL。若 Project 传给 OnlyOffice 的 URL 使用 Docker 内部域名，例如 `http://nginx/api/...`，OnlyOffice 容器需要和该 `nginx` 服务处于可达网络，或者需要把 URL 改成 OnlyOffice 容器能访问的内网地址。

## CSV 和 Excel

Project 的 `xls`、`xlsx`、`ods`、`csv`、`tsv` 等文件会走 Office 文件预览/编辑链路。需要注意：

- Excel 文件通常可以直接预览和编辑。
- CSV/TSV 属于纯文本表格格式，OnlyOffice 可以打开，但保存时可能受到编码、分隔符、区域设置影响。
- 如果只需要稳定预览，建议先验证 CSV/TSV 预览链路；若要开放编辑，需要额外测试中文编码、逗号/制表符分隔、换行和大文件性能。

## 服务管理

```bash
./start.sh
./status.sh
./stop.sh
```

查看日志：

```bash
docker compose logs -f onlyoffice
```

停止服务但保留数据卷：

```bash
docker compose down
```

删除数据卷会清理 OnlyOffice 缓存、日志和内部数据：

```bash
docker compose down -v
```

## 常见问题

### 页面提示组件加载失败

先确认浏览器能访问：

```text
/office/web-apps/apps/api/documents/api.js
```

如果不能访问，通常是 `/office/` 反向代理未配置、OnlyOffice 服务未启动，或端口没有暴露。

### 文档打开失败

确认 OnlyOffice 容器能访问 Project 生成的文件下载地址。容器内可以执行类似命令排查：

```bash
docker exec -it onlyoffice-documentserver bash
curl -I "http://nginx/api/file/content?id=..."
```

### 保存失败

确认 OnlyOffice 容器能访问 Project 的保存回调地址：

```text
http://nginx/api/file/content/office
```

同时检查 Project 和 OnlyOffice 的 JWT 密钥是否一致。

### JWT 相关错误

OnlyOffice 当前模板默认开启 JWT。Project 侧必须用同一组密钥签发配置，否则编辑器初始化、文件下载或回调保存可能失败。
