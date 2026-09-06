# 参数与开发参考

[返回安装说明](../README.md)

## 环境变量

设置写在本机部署目录的 `.env` 中，修改后运行该目录的 `bash deploy.sh`。部署脚本以文件为准，会清除终端里同名的环境变量。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `WG_RESILIENT_IMAGE` | `criogaid/wg-resilient:latest` | 发布镜像，可指定版本或可信镜像仓库 |
| `WG_INTERFACE` | `wg0` | 本机接口名，最多 15 个字符，两端可以不同 |
| `UDP2RAW_REMOTE_HOST` | 无 | 客户端必填，服务器公网 IPv4 或指向 IPv4 的域名 |
| `UDP2RAW_PORT` | `4096` | 对外 TCP 端口，两端相同 |
| `UDP2RAW_PASSWORD` | 无 | 两端相同的口令，向导自动生成 |
| `UDP2RAW_PASSWORD_FILE` | 无 | 容器内口令文件路径，优先于直接填写的口令 |
| `SPEEDER_ENABLED` | `false` | 两端都开启或都关闭 UDPspeeder |
| `SPEEDER_FEC` | `20:10` | 本端每 20 个原始数据包增加 10 个备用数据包 |
| `SPEEDER_MTU` | `1250` | UDPspeeder 分片大小 |
| `SPEEDER_TIMEOUT` | `8` | 等待一组数据的时间，毫秒 |

UDPspeeder 的 FEC、MTU、超时参数控制本端发出的数据，可以分别调整。WireGuard 的 MTU 默认 `1280`，与 UDPspeeder 的 MTU 不是同一层的设置；默认值是保守起点，不保证适合所有网络。

WireGuard 密钥、地址、隧道路由和 MTU 写在 `config/server/wg0.conf` 或 `config/client/wg0.conf`。即使修改接口名，配置文件名也不变。

## 手动配置

这是向导以外的安装方式，**已经用向导部署就不用再做**。以下操作使用项目根目录的 Compose 文件，不是生成包里的 `compose.yml`。

在两端分别下载项目、安装 `wireguard-tools`，进入项目目录后执行：

```sh
umask 077
wg genkey | tee private.key | wg pubkey > public.key
cp .env.example .env
```

私钥只留在本机，公钥填给对端。服务器复制模板：

```sh
cp config/server/wg0.conf.example config/server/wg0.conf
```

客户端复制模板：

```sh
cp config/client/wg0.conf.example config/client/wg0.conf
```

替换模板中的密钥占位符。两端 `.env` 填写同一个足够长的随机 `UDP2RAW_PASSWORD`，只允许字母、数字和 `._~+-`；客户端还需填写 `UDP2RAW_REMOTE_HOST`。不要把密钥或口令提交到仓库。

服务器启动：

```sh
docker compose -f compose.server.yml up -d --pull always --no-build
```

客户端启动：

```sh
docker compose -f compose.client.yml up -d --pull always --no-build
```

这套手动部署停止时，使用本机对应的 `docker compose -f compose.server.yml down` 或 `docker compose -f compose.client.yml down`，不要混用向导的项目名。

## 使用口令文件

以下例子用于手动部署。在项目目录创建 `udp2raw-password.txt`，填入口令，并限制权限：

```sh
chmod 600 udp2raw-password.txt
```

创建 `compose.secret.yml`：

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

启动客户端：

```sh
docker compose -f compose.client.yml -f compose.secret.yml up -d --pull always --no-build
```

服务器把服务名改成 `wireguard-server`，主 Compose 文件改成 `compose.server.yml`。两端口令文件内容必须相同，文件不要提交到仓库；设置后可以删除 `.env` 中的明文口令。

## 网络行为

```text
客户端 WireGuard -> [UDPspeeder] -> udp2raw === FakeTCP === udp2raw -> [UDPspeeder] -> 服务端 WireGuard
```

- WireGuard 负责内层认证和加密。udp2raw 固定使用 FakeTCP、aes128cbc、hmac_sha1，UDPspeeder 使用 mode 0。
- Compose 使用 host 网络及 `NET_ADMIN`、`NET_RAW`，没有端口映射和容器级网络 sysctl。接口和端口直接占用宿主机资源。
- 默认只配置接口和隧道网段路由，不启用 IP 转发，不添加 NAT 或额外策略路由。入口拒绝 `AllowedIPs` 中的 `0.0.0.0/0` 和 `::/0`。
- udp2raw 的 `-a` 自动管理 FakeTCP 必需的防 RST 规则，正常停止时清理。
- 源配置挂载至 `/config/wg0.conf`，运行时复制到容器内权限受限的 `/run/wireguard/<接口名>.conf`，供 `wg-quick` 启停。
- 内部连接固定：服务器 WireGuard 监听 `51820`，客户端 Endpoint 为 `127.0.0.1:51821`，UDPspeeder 中继端口为 `51822`。
- 向导生成 IPv4 配置。入口脚本和健康检查包含在镜像内，部署只挂载配置文件。

参数参考：[UDPspeeder](https://github.com/wangyu-/UDPspeeder/blob/61b24a369700c3d8248dd18fa9a524b778741454/README.md)、[wg-quick MTU 实现](https://git.zx2c4.com/wireguard-tools/tree/src/wg-quick/linux.bash)。

## 开发测试

以下命令在项目根目录执行。普通部署不用构建镜像。

静态检查和配置生成测试；生成测试有本机 `wg` 时无需 Docker，否则使用发布镜像：

```sh
sh tests/check.sh
bash tests/quickstart.sh
```

构建后测试默认及自定义接口名、两种传输模式握手、健康检查和正常停止：

```sh
docker build -t wg-resilient:local .
sh tests/e2e.sh
SPEEDER_ENABLED=true sh tests/e2e.sh
```

完整生成、打包、部署测试：

```sh
bash tests/quickstart.sh --e2e
```

完整测试拉取发布镜像，用两个隔离网络空间模拟两台宿主机，不改真实宿主机接口。检查双向服务访问、接口保护和清理，以及默认路由、策略规则、NAT 和 IP 转发设置未变。有现存快速启动部署时拒绝运行；测试网桥内需要允许 TCP 24096 通信。

## 发布镜像

GitHub Actions 需要仓库 secrets：`DOCKERHUB_USERNAME` 和具有仓库写权限的 `DOCKERHUB_TOKEN`。

每周一检查 WireGuard 官方 tag，绑定对应 commit。未发布的版本经过构建和测试后，发布 `wireguard-tools-<版本>` 和 `latest`。已验证版本通过 GitHub 证据标签及镜像元数据识别，不重复构建；缺少镜像时重新构建。

amd64、arm64 使用原生 runner 测试两种模式握手及停止。arm/v7 使用 QEMU 测试构建、架构、密钥运算和用户态程序，不测试 WireGuard netlink。每个平台保留 `run-<workflow run>-<attempt>-<architecture>` 追踪标签。

普通 `main` 推送和 pull request 只做 amd64 构建及测试，不更新发布镜像。需要发布项目新版本时，使用一个尚未发布的版本标签，例如：

```sh
git tag v1.0.0
git push origin v1.0.0
```

该示例发布 `${DOCKERHUB_USERNAME}/wg-resilient:1.0.0` 和 `latest`。也可从 Actions 手动运行 Container 工作流并启用 `publish`；它会检查上游版本和已有发布状态，已有验证版本时可能跳过，并不是强制重建。
