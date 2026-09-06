# WG Resilient

通过 Docker 部署的 WireGuard 点对点隧道，适用于 UDP 受限或存在丢包的网络。使用 udp2raw 将 WireGuard 流量封装为 FakeTCP，可选 UDPspeeder 提供前向纠错（FEC）。

两端应用通过隧道 IP 访问对方服务。默认只路由隧道网段，不接管宿主机默认路由或 DNS，不提供全局代理、出口 NAT 或客户端管理面板。FakeTCP 不是普通 TCP 连接，不能通过 HTTP 反向代理转发，也不保证穿透所有网络限制。

- **镜像**：[criogaid/wg-resilient](https://hub.docker.com/r/criogaid/wg-resilient)
- **平台**：Linux amd64、arm64、arm/v7
- **部署方式**：在服务器生成配套配置，将客户端安装包传到另一台机器启动，无需本地构建镜像。

## 部署条件

准备两台 Linux 主机，两端均需：

- 内核支持 WireGuard，已安装 Docker Engine、Compose v2、Bash 和 tar；Compose 支持 `up --wait`。
- 能拉取 Docker Hub 镜像；服务器另需 Git。
- 允许容器使用 host 网络及 `NET_ADMIN`、`NET_RAW` 权限。WireGuard 接口直接创建在宿主机上，默认名称 `wg0` 必须未被占用。

服务器需有可从客户端访问的公网 IPv4，或解析到该 IPv4 的域名。在云安全组和宿主机防火墙放行 **TCP 4096**，建议限制客户端来源；有上游 NAT 时需要对应的端口转发。内部 UDP 端口 `51820`、`51821`、`51822` 不应对公网开放。

默认隧道网段为 `10.66.66.0/24`，须与两端现有网络不冲突。同一宿主机同一角色默认只运行一套，更换接口名不能避免内部端口冲突。

## 快速部署

### 1. 生成并启动服务器

在服务器执行：

```sh
git clone https://github.com/Criogaid/wg-resilient.git ~/wg-resilient
cd ~/wg-resilient
bash quickstart.sh
```

按向导填写服务器公网 IP 或域名，不带协议和端口。其余参数可先使用默认值：

| 参数 | 默认值 |
| --- | --- |
| FakeTCP 端口 | `4096` |
| 隧道网段 | `10.66.66.0`（不填写 `/24`） |
| WireGuard MTU | `1280` |
| UDPspeeder | `false` |

最后在 `Deploy server now? y/N` 输入 `y`。若暂不启动，之后执行：

```sh
bash ~/wg-resilient/quickstart-output/server/deploy.sh
```

向导自动生成两端 WireGuard 密钥、预共享密钥和 udp2raw 口令，不覆盖已有输出目录。需要指定接口名或新目录时，使用：

```sh
WG_INTERFACE=wg-link bash quickstart.sh "$HOME/wg-new-setup"
```

使用自定义目录时，后续命令中的服务器路径和安装包路径需相应调整。

### 2. 传输客户端安装包

将服务器上的 `~/wg-resilient/quickstart-output/client.tar.gz` 安全传输至客户端的 `~/client.tar.gz`。例如在服务器执行，替换 SSH 用户和地址：

```sh
scp ~/wg-resilient/quickstart-output/client.tar.gz user@client-host:~/
```

**安装包含客户端私钥和共享口令，只能供一台客户端使用。不要公开，不要传输整个服务器输出目录。**

### 3. 启动客户端

在客户端执行：

```sh
umask 077
mkdir ~/wg-client && \
  tar -xzf ~/client.tar.gz -C ~/wg-client && \
  bash ~/wg-client/client/deploy.sh
```

部署脚本拉取镜像、启动容器并等待本地健康检查。再次部署时直接运行 `bash ~/wg-client/client/deploy.sh`，无需重新解压。

## 验证与使用

在客户端检查 WireGuard：

```sh
cd ~/wg-client/client
docker compose -p wg-resilient-client -f compose.yml exec wireguard-client wg show
```

确认存在近期的 `latest handshake`，再测试实际服务访问。**`healthy` 只表示本地接口和进程正常，不代表远端连通。**

| 访问方向 | 默认目标 |
| --- | --- |
| 客户端访问服务器 | `10.66.66.1:服务端口` |
| 服务器访问客户端 | `10.66.66.2:服务端口` |

例如，服务器已有 SOCKS5 服务监听 `10.66.66.1:8848`，客户端应用即可使用该地址及服务自身的认证信息。本项目不内置 SOCKS5 服务。

服务须监听隧道 IP 或适当的所有地址，不能仅监听 `127.0.0.1`；防火墙须允许所需的隧道访问。使用所有地址监听时，同时限制公网入口。应用容器可使用 host 网络；若保留 Docker 桥接网络，需自行配置并验证转发和返回路由。

## 日常维护

以下命令在客户端部署目录 `~/wg-client/client` 执行。服务器使用 `~/wg-resilient/quickstart-output/server`，将项目名改为 `wg-resilient-server`。

```sh
# 状态与日志
docker compose -p wg-resilient-client -f compose.yml ps
docker compose -p wg-resilient-client -f compose.yml logs --tail 100

# 拉取镜像并重新部署
bash deploy.sh

# 修改 WireGuard 配置后重启
docker compose -p wg-resilient-client -f compose.yml restart

# 停止并移除容器，保留配置与密钥
docker compose -p wg-resilient-client -f compose.yml down
```

- **配置位置**：本机部署目录的 `.env` 和 `config/<角色>/wg0.conf`。修改 `.env` 后运行 `bash deploy.sh`；仅修改 WireGuard 配置后执行重启。
- **开启 FEC**：两端 `.env` 均设置 `SPEEDER_ENABLED=true` 并重新部署。FEC 增加带宽开销，是否改善体验需按实际链路测试。
- **固定镜像**：在 `.env` 中设置 `WG_RESILIENT_IMAGE`，使用 Docker Hub 上已有的版本标签或镜像 digest。`latest` 会变化；升级前备份配置并记录原镜像。
- **更换接口名**：设置 `WG_INTERFACE`，长度 1–15，首字符为字母或数字，其余允许字母、数字、下划线、点和连字符。两端名称可不同，配置文件仍为 `wg0.conf`。
- **端口约束**：保持服务器 `ListenPort = 51820` 和客户端 `Endpoint = 127.0.0.1:51821`。调整公网端口时，两端 `.env` 和服务器防火墙需同步修改。

正常停止会清理本项目创建的接口和 udp2raw 防 RST 规则，不删除配置，也不清理用户自行添加的防火墙规则。卸载前先在两端执行 `down`，确认无需恢复后再删除部署目录及安装包。

输出目录包含两端密钥，应限制访问。重新生成配置后需重新分发客户端安装包；修改服务器上的客户端文件不会更新远端机器或已有压缩包。分享日志前应检查并遮盖口令等敏感信息。

## 排障

| 现象 | 优先检查 |
| --- | --- |
| 镜像拉取失败 | Docker Hub 访问、镜像标签、Docker 服务状态 |
| 启动提示接口已存在 | 停止原接口所属服务，或设置未占用的 `WG_INTERFACE` |
| 容器正常但没有握手 | 公网 IPv4、TCP 端口放行、两端口令和密钥配套、UDPspeeder 开关一致 |
| 已握手但服务不通 | 目标端口、监听地址、隧道防火墙、应用容器网络及返回路由 |
| 大包或长连接异常 | 路径 MTU、丢包情况；逐步调整 WireGuard MTU，必要时测试 FEC |

客户端域名在启动时解析为 IPv4；服务器地址变化后需重启客户端。

## 参考

- [环境变量、手动部署、口令文件与网络行为](docs/reference.md)
- [测试与镜像发布](docs/reference.md#开发测试)
