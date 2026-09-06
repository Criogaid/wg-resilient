# WG Resilient

一个同时支持服务端和客户端的 Docker 镜像：WireGuard UDP 流量经 `udp2raw` 封装为 FakeTCP，可选在两者之间启用 `UDPspeeder` 前向纠错。

```text
客户端 WireGuard -> [UDPspeeder] -> udp2raw === FakeTCP === udp2raw -> [UDPspeeder] -> 服务端 WireGuard
```

## 要求

- Linux Docker 主机，内核已支持 WireGuard
- Docker Compose v2
- 服务端开放 `${UDP2RAW_PORT:-4096}/tcp`
- 容器需要 `NET_ADMIN` 和 `NET_RAW`；Compose 文件已配置

## 配置

在服务端和客户端各自克隆一份项目，然后生成 WireGuard 密钥：

```sh
wg genkey | tee private.key | wg pubkey > public.key
```

服务端：

```sh
cp .env.example .env
cp config/server/wg0.conf.example config/server/wg0.conf
```

将服务端和客户端的密钥写入 `config/server/wg0.conf`。服务端 `.env` 至少修改 `UDP2RAW_PASSWORD`。

客户端：

```sh
cp .env.example .env
cp config/client/wg0.conf.example config/client/wg0.conf
```

将密钥写入 `config/client/wg0.conf`，并在 `.env` 设置服务端公网 IPv4 或域名：

```dotenv
UDP2RAW_REMOTE_HOST=203.0.113.10
UDP2RAW_PASSWORD=replace-with-the-same-random-secret
```

口令仅允许字母、数字和 `._~+-`。客户端 WireGuard 的 `Endpoint` 必须保持为 `127.0.0.1:51821`。

## 启动

服务端：

```sh
docker compose -f compose.server.yml up -d --build
```

客户端：

```sh
docker compose -f compose.client.yml up -d --build
```

查看状态：

```sh
docker compose -f compose.client.yml ps
docker compose -f compose.client.yml logs -f
```

客户端 WireGuard 网络位于容器命名空间。需要走隧道的其他容器可在同一 Compose 项目中使用：

```yaml
services:
  app:
    image: curlimages/curl
    network_mode: service:wireguard-client
    depends_on:
      wireguard-client:
        condition: service_healthy
```

## 启用 UDPspeeder

两端均设置 `SPEEDER_ENABLED=true`。以下为默认调优值，各端可独立调整发送方向：

```dotenv
SPEEDER_ENABLED=true
SPEEDER_FEC=20:10
SPEEDER_MTU=1250
```

`20:10` 表示每 20 个原始包增加 10 个冗余包。先保持默认值，只在实际丢包测试表明有收益时调整；UDPspeeder 会增加带宽占用。

## 变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `UDP2RAW_REMOTE_HOST` | 无 | 客户端必填，服务端公网 IPv4 或可解析域名 |
| `UDP2RAW_PORT` | `4096` | FakeTCP 监听端口 |
| `UDP2RAW_PASSWORD` | 无 | 两端相同口令 |
| `UDP2RAW_PASSWORD_FILE` | 无 | 容器内 secret 文件路径；设置后优先于密码环境变量 |
| `SPEEDER_ENABLED` | `false` | 两端均开启或均关闭 |
| `SPEEDER_FEC` | `20:10` | 高级项，本端发送 FEC 参数 |
| `SPEEDER_MTU` | `1250` | 高级项，本端 UDPspeeder 分片大小 |
| `SPEEDER_TIMEOUT` | `8` | 高级项，FEC 组包等待时间（毫秒） |

固定使用 FakeTCP、aes128cbc、hmac_sha1 和 UDPspeeder mode 0。接口固定为 `wg0`，配置固定挂载至 `/config/wg0.conf`，内部端口固定为 51820/51821/51822。不再支持旧的模式、算法、内部端口、配置路径环境变量和 `udp2raw-extra.conf`。

WireGuard 的密钥、Address、AllowedIPs、MTU、DNS、PersistentKeepalive 和转发/NAT 规则只在 `wg0.conf` 配置，不重复包装为环境变量。服务端 ListenPort 保持 51820，客户端 Endpoint 保持 127.0.0.1:51821。

两端示例显式设置 `MTU = 1280`，避免回环 Endpoint 导致自动 MTU 过大。这是保守起点，不是对所有路径的保证；按实际路径 MTU 调整。UDPspeeder MTU 与 WireGuard MTU 是不同层的设置。共享网络命名空间的应用容器仍需独立配置 DNS。

### 使用 Secret

默认 Compose 允许密码为空，由入口脚本验证必须提供密码或可读的 secret 文件。使用文件时，创建本地 `compose.secret.yml`：

```yaml
services:
  wireguard-client:
    environment:
      UDP2RAW_PASSWORD_FILE: /run/secrets/udp2raw_password
    secrets:
      - udp2raw_password
secrets:
  udp2raw_password:
    file: ./udp2raw-password.txt
```

运行 `docker compose -f compose.client.yml -f compose.secret.yml up -d --build`。服务端将服务名改为 `wireguard-server`，使用 `compose.server.yml`。口令文件两端内容相同，不提交到版本库；不需要在 `.env` 再填写密码。

复查依据：[UDPspeeder 固定版本参数说明](https://github.com/wangyu-/UDPspeeder/blob/61b24a369700c3d8248dd18fa9a524b778741454/README.md)、[wg-quick MTU 实现](https://git.zx2c4.com/wireguard-tools/tree/src/wg-quick/linux.bash)。

## 注意

- 客户端会在 WireGuard 启动前为服务端 IPv4 添加高优先级策略路由，避免全局隧道把 udp2raw 外层流量再次送入 WireGuard。
- 默认桥接网络用于隔离 WireGuard 路由，不会修改 Docker 主机的默认路由。
- udp2raw 的加密不是 WireGuard 的替代品；内层流量仍由 WireGuard 认证和加密。
- 镜像从固定提交构建，支持 Docker Buildx 原生构建的 `linux/amd64` 和 `linux/arm64`。

运行静态检查：

```sh
./tests/check.sh
```

构建镜像后运行端到端握手和停止测试：

```sh
./tests/e2e.sh
SPEEDER_ENABLED=true ./tests/e2e.sh
```
