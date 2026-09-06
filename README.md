# WG Resilient

让两台 Linux 机器通过加密隧道访问对方的服务，适合 UDP 受限或容易丢包的网络。

默认地址：**服务器 `10.66.66.1`，客户端 `10.66.66.2`**。例如服务器有一个 SOCKS5 服务，客户端就可以连接 `10.66.66.1:8848`。

**只连接两台机器，不接管整机上网。** 普通网站仍走原来的网络，默认路由和 DNS 不变，不需要额外配置 NAT 或 DNAT。当前只支持 tunnel，不提供 full 全流量模式。

## 准备

- 两台支持 WireGuard 内核的 Linux 机器，服务器需要公网 IPv4 或指向它的域名。
- 两端安装 [Docker Engine 和 Compose 插件](https://docs.docker.com/engine/install/)，支持 `docker compose up --wait`。服务器还需要 Git，两端需要 Bash 和 tar。
- 两端能拉取 `criogaid/wg-resilient:latest`，**不用本地编译，也不用手动生成密钥**。支持 amd64、arm64、arm/v7。
- 在服务器的云安全组和系统防火墙放行 **TCP 4096**，最好只允许客户端来源。无需额外开放 UDP 51820/51821/51822。

先在两端确认 Docker 可用：

```sh
docker info
docker compose version
```

## 1. 部署服务器

在**服务器**执行：

```sh
git clone https://github.com/Criogaid/wg-resilient.git ~/wg-resilient
cd ~/wg-resilient
bash quickstart.sh
```

按提示填写：

| 提示 | 怎么填 |
| --- | --- |
| `Server public IPv4 or DNS name` | 服务器公网 IP 或域名，不加 `https://` 或端口 |
| `FakeTCP port` | 回车，默认 `4096`；改了就放行对应的 TCP 端口 |
| `Tunnel /24 network` | 回车，默认 `10.66.66.0`；与现有网络冲突时换成如 `10.77.77.0` |
| `WireGuard MTU` | 回车，默认 `1280` |
| `Enable UDPspeeder` | 回车，先不开启丢包补偿 |
| `Deploy server now? y/N` | 输入 `y` 启动 |

脚本会生成配套密钥、服务器配置和客户端安装包。如果最后没选启动，之后执行：

```sh
bash ~/wg-resilient/quickstart-output/server/deploy.sh
```

接口默认叫 `wg0`。想换名字，在运行向导时改用 `WG_INTERFACE=wg-link bash quickstart.sh`；已有同名接口时会拒绝启动，不会覆盖它。

## 2. 传客户端安装包

把服务器上的 `~/wg-resilient/quickstart-output/client.tar.gz` 上传到客户端的主目录，文件位置应为 `~/client.tar.gz`。

可以用 SSH 文件传输工具。服务器能通过 SSH 登录客户端的话，也可以在**服务器**执行，替换用户名和客户端地址：

```sh
scp ~/wg-resilient/quickstart-output/client.tar.gz user@client-host:~/
```

**只传这个压缩包，不要传整个输出目录。包内有客户端私钥，不要公开，也不要给多台客户端共用。**

## 3. 启动客户端

在**客户端**执行：

```sh
umask 077
mkdir ~/wg-client && \
  tar -xzf ~/client.tar.gz -C ~/wg-client && \
  bash ~/wg-client/client/deploy.sh
```

脚本会拉取镜像、启动并等待健康检查。已经解压过就直接运行 `bash ~/wg-client/client/deploy.sh`，不用再次解压。下载失败时先解决网络问题，不会自动改成本地编译。

## 4. 确认连接并使用

在**客户端**执行：

```sh
cd ~/wg-client/client
docker compose -p wg-resilient-client -f compose.yml exec wireguard-client wg show
```

看到近期的 `latest handshake`，说明两端成功连接过。**容器显示 healthy 不等于已经握手。**

之后应用直接填写对方的隧道地址：

- 客户端访问服务器：`10.66.66.1:服务端口`。
- 服务器访问客户端：`10.66.66.2:服务端口`。
- 例如使用服务器的 SOCKS5：在应用里选择 SOCKS5，填写 `10.66.66.1:8848` 和代理账号密码。应用经代理访问网站，无需启用 full。

如果向导中换了网段，以上地址也要跟着换。对端服务必须监听隧道地址或所有地址，不能只监听 `127.0.0.1`；防火墙也要允许隧道上的服务访问。

本项目使用 `network_mode: host`，接口直接建在宿主机。你的应用如果也在 Docker 中，可以同样使用 host 网络，移除该应用的 `ports:` 和 `networks:`。它会直接占用宿主机端口，注意监听范围和端口冲突；保留桥接网络则要自行确认转发和返回路由。

## 常用操作

### 查看状态和日志

客户端执行：

```sh
cd ~/wg-client/client
docker compose -p wg-resilient-client -f compose.yml ps
docker compose -p wg-resilient-client -f compose.yml logs --tail 100
```

服务器先进入 `~/wg-resilient/quickstart-output/server`，把命令中的 `wg-resilient-client` 换成 `wg-resilient-server`。分享日志前遮住口令等敏感信息。

连不上时先查：**公网地址、TCP 端口放行、两端是否启动、安装包是否配套**。有握手但服务不通，再查服务监听地址、防火墙和应用的 Docker 网络模式。

### 修改配置

在需要修改的机器上，进入它自己的部署目录：服务器为 `~/wg-resilient/quickstart-output/server`，客户端为 `~/wg-client/client`。

- 修改接口名：在 `.env` 中设置 `WG_INTERFACE=wg-link`。最多 15 个字符，首字符用字母或数字，其余允许字母、数字、下划线、点、连字符；两端名称可以不同，配置文件仍叫 `wg0.conf`。
- 开启丢包补偿：两端 `.env` 都设置 `SPEEDER_ENABLED=true`，会多消耗带宽，不保证更快。
- 改完 `.env` 后，在该目录执行 `bash deploy.sh`。
- 改了 `config/server/wg0.conf` 或 `config/client/wg0.conf`，还要重启。客户端执行 `docker compose -p wg-resilient-client -f compose.yml restart`；服务器把项目名换成 `wg-resilient-server`。

不要改动服务端 `ListenPort = 51820` 和客户端 `Endpoint = 127.0.0.1:51821`。修改服务器目录里的客户端文件，不会自动更新远端客户端或已有压缩包。

### 停止或删除

**服务器停止：**

```sh
cd ~/wg-resilient/quickstart-output/server && \
  docker compose -p wg-resilient-server -f compose.yml down
```

**客户端停止：**

```sh
cd ~/wg-client/client && \
  docker compose -p wg-resilient-client -f compose.yml down
```

正常停止会清理本项目创建的接口和防 RST 规则，配置和密钥仍保留。要再启动，运行对应目录的 `bash deploy.sh`。

**彻底删除时，先确认两端都已停止，再删除配置。下面的操作会删除密钥，无法恢复原来的配对。**

服务器：

```sh
rm -rf ~/wg-resilient/quickstart-output
```

客户端：

```sh
rm -rf ~/wg-client
rm -f ~/client.tar.gz
```

你自己额外添加的宿主机防火墙规则不会自动删除，不要直接清空整个防火墙。

需要全新配置时，在服务器项目目录重新运行 `bash quickstart.sh`，再把新包传给客户端。向导不会覆盖已有输出目录；想保留旧配置，可以指定新目录：`bash quickstart.sh "$HOME/wg-new-setup"`。每台机器同一角色默认只部署一套，更换接口名不能解决端口冲突。

## 更多设置

[参数、手动配置和开发测试](docs/reference.md)。普通部署不需要阅读这一部分。
