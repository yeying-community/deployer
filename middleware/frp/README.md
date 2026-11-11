
# FRP 配置说明

建议使用 `frp_0.64.0_linux_amd64.tar.gz` 以及以上版本（2025-09-06）。

## 术语说明

- `<通信端口>`：server 端与内网节点之间的通信端口
- `<代理端口>`：需要暴露/代理的内网节点端口

## 命名规范（统一）

- 目录：`/usr/local/frp-s<代理端口>` 或 `/usr/local/frp-c<代理端口>`
- 服务：`frp-s<代理端口>.service` 或 `frp-c<代理端口>.service`
(为了避免混乱，建议将/usr/local/frp-s<代理端口>目录下 frpc开头的文件删除，同理，也建议将/usr/local/frp-c<代理端口>目录下 frps开头的文件删除)

## server 端节点配置

### 1) 安装与目录

```bash
sudo tar -zxf frp_<version>_linux_amd64.tar.gz -C /usr/local/ && sudo mv /usr/local/frp_0.64.0_linux_amd64 /usr/local/frp-s<代理端口>
sudo rm /usr/local/frp-s<代理端口>/frpc*
```

### 2) frps.toml

路径：`/usr/local/frp-s<代理端口>/frps.toml`

```toml
bindPort = <通信端口>
```

### 3) frps systemd 服务

路径：`/etc/systemd/system/frp-s<代理端口>.service`

```ini
[Unit]
Description = frp server frp-s<代理端口>
After = network.target syslog.target
Wants = network.target

[Service]
Type = simple
ExecStart = /usr/local/frp-s<代理端口>/frps -c /usr/local/frp-s<代理端口>/frps.toml

[Install]
WantedBy = multi-user.target
```

### 4) server 端 visitor（frpc）安装与配置

```bash
sudo tar -zxf frp_<version>_linux_amd64.tar.gz -C /usr/local/ && sudo mv /usr/local/frp_0.64.0_linux_amd64 /usr/local/frp-c<代理端口>
sudo rm /usr/local/frp-c<代理端口>/frps*
```

路径：`/usr/local/frp-c<代理端口>/frpc.toml`

```toml
serverAddr = "127.0.0.1"
serverPort = <通信端口>

[[visitors]]
name = "secret_ssh_visitor"
type = "stcp"
serverName = "r730xd101"   # 根据实际情况进行修改
secretKey = "------------" # 使用 scripts/generate_password.sh 生成，长度不低于12
bindAddr = "127.0.0.1"
bindPort = <代理端口>
```

### 5) frpc systemd 服务

路径：`/etc/systemd/system/frp-c<代理端口>.service`

```ini
[Unit]
Description = frp client frp-c<代理端口>
After = network.target syslog.target
Wants = network.target

[Service]
Type = simple
ExecStart = /usr/local/frp-c<代理端口>/frpc -c /usr/local/frp-c<代理端口>/frpc.toml

[Install]
WantedBy = multi-user.target
```

## 内网节点配置

### 1) 安装与目录

```bash
sudo tar -zxf frp_<version>_linux_amd64.tar.gz -C /usr/local/ && sudo mv /usr/local/frp_0.64.0_linux_amd64 /usr/local/frp-c<代理端口>
```

### 2) frpc.toml

路径：`/usr/local/frp-c<代理端口>/frpc.toml`

```toml
serverAddr = "<server端的公网ip>"
serverPort = <通信端口>

[[proxies]]
name = "r730xd101" # 与 server 端配置的 serverName 保持一致
type = "stcp"
secretKey = "------------" # 与 server 端配置的 secretKey 保持一致
localIP = "127.0.0.1"
localPort = <代理端口>
```

### 3) frpc systemd 服务

路径：`/etc/systemd/system/frp-c<代理端口>.service`

```ini
[Unit]
Description = frp client frp-c<代理端口>
After = network.target syslog.target
Wants = network.target

[Service]
Type = simple
ExecStart = /usr/local/frp-c<代理端口>/frpc -c /usr/local/frp-c<代理端口>/frpc.toml

[Install]
WantedBy = multi-user.target
```

## 最后一步

将上述配置的服务启动、验证通过后配置开机启动。
