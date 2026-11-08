# README 模板说明

## 目标

统一项目 `README.md` 的基本结构，但控制文档边界。

项目 README 的重点应放在两件事上：

- 这个项目是做什么的
- 本地如何快速开始

对于生产部署、安装包交付、目标环境拷贝、回滚等内容，不建议继续堆在 README 里，应直接引用部署模板：

- [DEPLOYMENT_TEMPLATE.md](./DEPLOYMENT_TEMPLATE.md)

这样做的目的是避免 README 变成“大而全”的综合文档，最后既不利于新人快速理解项目，也不利于维护。

## 编写原则

- 先讲项目，再讲本地快速开始
- 所有命令尽量可直接执行
- 所有路径、脚本名、环境变量名必须与仓库实际一致
- README 只覆盖本地开发、调试和最短启动路径
- 生产部署内容只保留入口，不在 README 中展开
- 如果项目依赖中间件，README 必须引用 `middleware/` 下对应目录，确保开发者能先拉起依赖服务
- 不写空洞介绍，不写仓库里不存在的命令或能力

## README 应回答的问题

一个合格的 README，至少应让第一次进入目录的人快速回答：

- 这个项目解决什么问题
- 适合什么场景
- 本地依赖是什么
- 本地如何启动
- 本地如何验证已经跑起来
- 如果依赖中间件，本地应该先看哪个 `middleware/` 文档
- 项目的关键概念和术语应该去哪里查
- 生产部署应该去看哪份文档

## 必选章节

每个项目 README 至少应包含以下内容：

### 1. 项目名称

使用项目目录名或仓库名作为一级标题。

### 2. 项目简介

用 2 到 5 行说明：

- 项目用途
- 适用场景
- 核心依赖或运行形态

### 3. 目录说明

列出关键目录和文件，尤其是：

- `scripts/`
- `config/`
- `web/`
- `.env.template`
- `config.yaml.template`
- `config.js.template`

如果项目没有这些文件，不要硬写，按实际情况列出。

### 4. 本地环境要求

写清本地运行或开发所需依赖，例如：

- 操作系统
- Node.js / Go / Python / Java
- 数据库、中间件、浏览器或 CLI 工具

### 5. 本地快速开始

必须覆盖从零启动的最短路径，通常包括：

1. 克隆代码
2. 初始化本地配置
3. 安装依赖
4. 启动项目
5. 验证项目是否正常运行

如果项目依赖 Redis、PostgreSQL、MySQL、MinIO、Kafka 等中间件，必须在这里明确写出：

- 依赖哪些中间件
- 对应参考哪个仓库内文档，例如 `middleware/<name>/README.md`
- 本地是先启动中间件，还是项目启动时自动检查

### 6. 配置说明

只说明本地启动必须知道的配置，例如：

- 使用的是哪种配置文件
- 如何从模板生成本地配置
- 哪些配置必须修改
- 哪些配置可以使用默认值

### 7. 本地验证方式

README 必须告诉开发者如何确认项目真的跑起来，例如：

- 访问哪个 URL
- 执行哪个健康检查命令
- 查看哪个日志
- 检查哪个端口

### 8. 常见问题

至少列出 2 到 3 个最常见问题，例如：

- 依赖未安装
- 配置文件缺失
- 端口占用
- 权限问题

## 可选章节

按项目实际情况补充：

- 本地开发说明
- 调试方式
- 前端构建
- API 文档
- 测试命令
- 中间件依赖说明
- 社区贡献说明

如果项目涉及社区协作和 PR 流程，建议引用：

- [GITHUB_FORK.md](./GITHUB_FORK.md)
- [GITHUB_PULL_REQUEST.md](./GITHUB_PULL_REQUEST.md)

## 不建议放进 README 的内容

以下内容建议不要在 README 里展开：

- 生产环境部署步骤
- 安装包拷贝流程
- 正式环境回滚步骤
- 发布窗口和变更审批流程
- 长篇运维值班说明

这些内容应放到独立部署文档中，并在 README 里给出链接。

## 推荐结构

推荐按下面顺序组织 README：

1. 项目名称
2. 项目简介
3. 目录说明
4. 本地环境要求
5. 本地快速开始
6. 配置说明
7. 本地验证方式
8. 常见问题
9. 相关文档

## README 模板

下面是一份建议模板，可直接作为项目 `README.md` 的起点：

~~~~markdown
# <project-name>

## 项目简介

简要说明项目的用途、场景和运行方式。

示例：

- 提供什么能力
- 适合什么场景
- 依赖哪些关键组件

## 目录说明

```text
.
├── scripts/                # 启动、停止、调试等脚本
├── config/                 # 配置文件目录（如有）
├── web/                    # 前端目录（如有）
├── .env.template           # 环境变量模板（如有）
├── config.yaml.template    # YAML 配置模板（如有）
├── config.js.template      # JS 配置模板（如有）
└── README.md
```

## 本地环境要求

- Node.js 20.x
- PostgreSQL 16
- 其他依赖

## 本地快速开始

### 1. 克隆代码

```bash
git clone <repo-url>
cd <project-name>
```

### 2. 初始化本地配置

如果项目使用 `.env.template`：

```bash
cp .env.template .env
```

如果项目使用 `config.yaml.template`：

```bash
cp config.yaml.template config.yaml
```

如果项目使用 `config.js.template`：

```bash
cp config.js.template config.js
```

### 3. 安装依赖

如果项目有前端：

```bash
cd web
npm install
cd ..
```

如果项目有后端依赖，也应在这里补充安装命令。

### 4. 启动项目

```bash
./scripts/starter.sh
```

### 4.1 停止和重启

```bash
./scripts/starter.sh stop
./scripts/starter.sh restart
```

`stop` 必须先等待服务优雅退出，超时后才允许强制终止；`restart` 只有在确认旧进程退出后才会启动新进程。停止等待时间可通过项目文档定义的
`STOP_TIMEOUT_SECONDS` 和 `FORCE_STOP_TIMEOUT_SECONDS` 调整，停止失败时应先处理残留进程，不要继续重复重启。

### 5. 验证项目

```bash
curl http://127.0.0.1:8080/health
```

或：

- 访问本地页面
- 查看启动日志
- 检查端口监听

## 配置说明

说明本地启动必须修改的配置：

- 使用的配置文件：
- 必填配置项：
- 默认可保留的配置项：

如果依赖中间件，也应说明本地连接配置如何对应 `middleware/` 下的默认端口、账号或访问地址。

## 本地验证方式

```bash
<填写实际验证命令>
```

## 中间件依赖

如果项目依赖中间件，请明确写出本地启动入口，例如：

- Redis：参考 `middleware/redis/README.md`
- PostgreSQL：参考 `middleware/postgresql/README.md`
- MinIO：参考 `middleware/minio/README.md`

并说明：

- 本地启动项目前需要先拉起哪些依赖服务
- 项目配置如何连接这些本地中间件
- 如果依赖未启动，项目会出现什么现象

## 常见问题

### 配置文件不存在

先根据项目实际模板初始化配置，例如：

```bash
cp .env.template .env
```

### 端口已占用

修改本地配置中的端口，或停止占用进程。

### 依赖安装失败

确认网络、代理和依赖版本满足要求后重新执行安装命令。

## 相关文档

- 项目关键概念：必须链接项目维护的核心概念文档，参考 `specification/KEY_CONCEPTS_TEMPLATE.md`
- 生产部署文档：参考 `DEPLOYMENT.md` 或基于 `specification/DEPLOYMENT_TEMPLATE.md` 编写的部署文档
- 社区协作流程：参考 `specification/GITHUB_FORK.md` 和 `specification/GITHUB_PULL_REQUEST.md`
- 中间件依赖：参考仓库 `middleware/` 下对应组件文档
~~~~

## 不推荐的写法

- README 只有项目介绍，没有本地启动命令
- README 写了很多生产部署步骤，导致本地开发入口被淹没
- README 同时塞满开发、部署、打包、回滚、发布审批等所有内容
- README 写了仓库里不存在的脚本或配置文件
- README 没有告诉开发者本地启动后如何验证结果
- README 依赖 Redis、PostgreSQL、MinIO 等中间件，但没有告诉开发者去 `middleware/` 哪里拉起依赖服务
