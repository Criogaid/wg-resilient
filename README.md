# WG Resilient

让两台 Linux 机器通过一条加密通道连接。遇到网络限制 UDP、或者网络容易丢包时，可以尝试用它连接 WireGuard。

你不需要自己生成密钥，也不需要从头编写配置文件。运行脚本、回答几个问题，就能得到服务器配置和客户端安装包。

**先注意：这不是安装后就能让整台电脑上网的软件。** 默认只有客户端的 Docker 容器使用这条通道，电脑上的浏览器等程序不会自动走它。本项目的部署脚本面向 Linux，不是 Windows、手机上的 WireGuard 一键安装器。

## 开始前要准备什么？

需要两台机器：

| 名称 | 是哪台机器？ | 需要准备什么？ |
| --- | --- | --- |
| 服务器（服务端） | 有公网 IPv4 地址、能够被外部访问的 Linux 机器，例如云服务器 | 安装 Docker Engine、Docker Compose、Git |
| 客户端 | 想连接这台服务器的另一台 Linux 机器 | 安装 Docker Engine、Docker Compose |

两台机器还需要支持 WireGuard 的 Linux 内核。部署会下载依赖并构建程序，因此两台机器都需要能访问 Debian 软件源、GitHub 和 WireGuard 的代码网站。

Docker 可以理解为运行本项目的工具。还没安装的话，先按 [Docker 官方安装说明](https://docs.docker.com/engine/install/) 选择自己的 Linux 系统进行安装，并安装 Compose 插件。

在**两台机器各自的终端**执行：

```sh
docker info
docker compose version
```

第一条应该能显示 Docker 的信息，第二条应该能显示 Compose 的版本。如果报错，先解决 Docker 安装、启动或权限问题，再往下操作。需要使用较新的 Compose v2 或更新版本，支持 `up --wait`。

脚本还会用到 Bash 和 tar，大多数 Linux 系统已经自带。服务器不用提前安装 `wg`：没有这个命令时，脚本会通过 Docker 生成密钥。

## 第一步：在服务器上运行脚本

以下命令都在**服务器**的终端执行。

先下载本项目并进入文件夹：

```sh
git clone https://github.com/Criogaid/wg-resilient.git
cd wg-resilient
```

启动配置向导：

```sh
bash quickstart.sh
```

脚本目前显示英文提示，可以对照下面的表填写。**方括号里是默认值，不知道怎么选时，大部分问题直接按回车即可。**

| 屏幕上的提示 | 它在问什么？ | 第一次使用怎么填？ |
| --- | --- | --- |
| `Server public IPv4 or DNS name` | 服务器的公网 IP 地址或域名 | 填你自己的服务器地址，这是必填项。不要加 `https://`，也不要加端口 |
| `FakeTCP port` | 用哪个端口接收客户端连接？ | 直接回车，使用 `4096` |
| `Tunnel /24 network` | 通道内部使用哪一段地址？ | 直接回车，使用 `10.66.66.0`；如果现有网络已经在用这一段，请换一段私有地址，例如 `10.77.77.0` |
| `WireGuard MTU` | 每个数据包的大小设置 | 直接回车，使用 `1280` |
| `Client DNS IPv4` | 客户端通过哪个 DNS 查询网站地址？ | 直接回车，使用 `1.1.1.1` |
| `Client routes: full or tunnel` | 哪些流量走通道？ | 直接回车选 `full`：客户端容器内所有 IPv4 流量走通道。`tunnel` 只连接通道内部网段 |
| `Enable UDPspeeder` | 是否开启丢包补偿？ | 先直接回车选 `false`。以后确实需要时再启用，它会多消耗一些带宽 |
| `Deploy server now? y/N` | 现在启动服务器吗？ | 输入 `y`，然后回车 |

脚本会自动生成两端的密钥和共同使用的随机口令，并把它们填入配置。**不用自己编密码，也不用手动交换密钥。**

第一次运行可能需要下载和编译，花几分钟或更久。请等命令执行完，不要看到一段时间没有新输出就直接关掉终端。

如果最后没有选 `y`，之后仍然可以在项目文件夹内运行：

```sh
bash quickstart-output/server/deploy.sh
```

### 别忘了放行服务器端口

如果上面使用默认值，需要允许外部访问服务器的 **TCP 4096 端口**。如果改了端口，就放行你填的那个。

云服务器通常需要在控制台的“安全组”或“防火墙”里添加入站规则。服务器系统自己的防火墙如果开启，也要允许这个端口。只允许需要连接的客户端来源地址会更安全。

这里放行的是 **TCP**，不是 UDP。脚本不会替你修改云平台安全组。

## 第二步：把客户端安装包传过去

脚本会生成 `quickstart-output/client.tar.gz`。这就是客户端需要的安装包，客户端不必再下载整个项目。

**只传这一个压缩包，不要把整个 `quickstart-output` 文件夹发出去。** 整个文件夹还包含服务器的私钥。

可以使用支持 SSH 的文件传输工具，把这个压缩包上传到客户端用户的主目录，也就是登录客户端后 `~` 所代表的位置。

如果服务器可以通过 SSH 登录客户端，也可以在**服务器的项目文件夹**里执行下面的命令。先把 `user` 换成客户端的登录用户名，把 `client-host` 换成客户端的地址：

```sh
scp quickstart-output/client.tar.gz user@client-host:~/
```

如果客户端在家里、没有可以从外部连接的地址，不要直接照抄这条命令。可以先把文件下载到自己电脑，再通过 SSH 文件传输工具上传到客户端。

**这个压缩包相当于连接凭证：不要公开上传，不要发到群里，也不要给多台客户端共用。** 当前向导一次配置一台服务器和一台客户端。

## 第三步：在客户端一键启动

接下来切换到**客户端**的终端。确认安装包已经放在 `~/client.tar.gz`，再执行：

```sh
umask 077; mkdir ~/wg-client && tar -xzf ~/client.tar.gz -C ~/wg-client && bash ~/wg-client/client/deploy.sh
```

这条命令会新建 `wg-client` 文件夹、解压安装包，然后构建并启动客户端。`umask 077` 是为了让新文件默认只允许当前用户访问。

第一次启动也可能需要下载和编译。脚本会等待程序的健康检查通过；如果失败，会报错退出。

如果提示 `wg-client` 已存在，不要急着删除。它可能就是你之前的配置。已经解压过的话，直接运行：

```sh
bash ~/wg-client/client/deploy.sh
```

## 第四步：确认真的连上了

“程序启动了”和“已经连上服务器”是两回事。请在**客户端**执行：

```sh
cd ~/wg-client/client
docker compose -p wg-resilient-client -f compose.yml exec wireguard-client wg show
```

找到输出中的 `latest handshake`，它表示最近一次成功连接确认的时间。

- 如果能看到类似 `latest handshake: 30 seconds ago`，说明两端已经成功连接过。
- 如果一直没有这一项，等待约一分钟再查。仍然没有时，按下面的“连不上怎么办？”排查。

查看程序状态：

```sh
docker compose -p wg-resilient-client -f compose.yml ps
```

查看最近的运行记录：

```sh
docker compose -p wg-resilient-client -f compose.yml logs --tail 100
```

运行记录可能包含口令等敏感信息。请先打码，再发给别人帮忙排查。

## 连不上怎么办？

按这个顺序检查：

1. **地址对不对？** 应该填写服务器的公网 IPv4 或能解析到 IPv4 的域名，不能填写示例地址、带 `https://` 的网址或服务器的内网地址。
2. **端口放行了吗？** 默认是 TCP 4096。检查云平台安全组和服务器自己的防火墙。
3. **两端都启动了吗？** 服务器和客户端都要运行各自的 `deploy.sh`。只有客户端启动是不够的。
4. **安装包是不是配套的？** 重新生成整套配置后，两端的密钥都会变。不能拿新客户端去连接仍使用旧配置的服务器。
5. **是否手动改过设置？** 两端的口令、端口和 UDPspeeder 开关必须匹配。
6. **Docker 下载或构建失败了吗？** 先确认网络能访问依赖来源。解决后重新执行对应的 `deploy.sh`，不需要重新生成密钥。

如果是 Docker 权限不足，请使用有 Docker 操作权限的账户。需要管理员权限时，可以执行 `sudo bash .../deploy.sh`，其中路径要换成你实际的部署脚本路径。

如果已经成功握手，但电脑上的浏览器没有变化，这是正常的：**默认只有客户端容器使用通道，不会改变整台机器的网络。** 需要让其他 Docker 程序使用通道时，见后面的进阶说明。

## 以后怎么管理？

### 查看服务器的运行情况

在**服务器的项目文件夹**内执行：

```sh
cd quickstart-output/server
docker compose -p wg-resilient-server -f compose.yml ps
docker compose -p wg-resilient-server -f compose.yml logs --tail 100
```

### 停止服务

客户端，在 `~/wg-client/client` 文件夹执行：

```sh
docker compose -p wg-resilient-client -f compose.yml down
```

服务器，在项目的 `quickstart-output/server` 文件夹执行：

```sh
docker compose -p wg-resilient-server -f compose.yml down
```

停止不会删除本地配置和密钥。需要再启动时，运行该文件夹里的 `bash deploy.sh` 即可。

### 配置文件放在哪里？

下面的路径以服务器上的项目文件夹为起点：

| 文件 | 用途 |
| --- | --- |
| `quickstart-output/server/config/server/wg0.conf` | 服务器的 WireGuard 地址、密钥等设置 |
| `quickstart-output/server/.env` | 服务器的端口、随机口令和 UDPspeeder 开关 |
| `quickstart-output/client/config/client/wg0.conf` | 客户端的 WireGuard 设置 |
| `quickstart-output/client/.env` | 客户端的服务器地址、端口、随机口令等设置 |
| `quickstart-output/client.tar.gz` | 发给客户端的安装包 |

客户端解压后，对应的文件在 `~/wg-client/client/` 下。`.env` 是隐藏文件，有些文件管理器需要打开“显示隐藏文件”才能看到。

修改配置后，在修改的那一端重新运行 `bash deploy.sh`。**如果改了 `wg0.conf`，还要执行一次重启，程序才会重新读取它：**

```sh
# 在客户端的部署文件夹执行
docker compose -p wg-resilient-client -f compose.yml restart
```

服务器将上面命令中的 `wg-resilient-client` 换成 `wg-resilient-server`。两端需要一致的设置，请分别修改并重新启动；只改服务器上的客户端文件，不会自动更新远端客户端或已经生成的压缩包。

### 想重新生成一套配置？

向导不会覆盖已有的输出文件夹，防止误删正在使用的密钥。需要重新生成时，在项目文件夹执行下面的命令，指定一个尚不存在的新目录：

```sh
bash quickstart.sh "$HOME/wg-new-setup"
```

请把自定义目录放在项目之外，避免不小心提交密钥。新生成的客户端包需要重新传到客户端。

部署脚本固定使用 `wg-resilient-server` 和 `wg-resilient-client` 这两个 Docker Compose 项目名。同一台机器重复部署同一角色会更新原来的服务，不会自动新增第二套。

## 进阶设置

第一次使用可以先跳过这一节。

### 开启丢包补偿

UDPspeeder 会多发一些备用数据，尝试减少丢包的影响，但会增加带宽消耗，不保证一定更快。

使用向导时，两端会自动使用相同的开关。之后手动启用，需要在**两端各自的 `.env` 文件**中都设置：

```dotenv
SPEEDER_ENABLED=true
```

保存后，在两端各自的部署文件夹重新运行 `bash deploy.sh`。高级参数默认如下，没测出实际问题前不必修改：

```dotenv
SPEEDER_FEC=20:10
SPEEDER_MTU=1250
SPEEDER_TIMEOUT=8
```

`20:10` 表示每 20 个原始数据包增加 10 个备用数据包。高级参数控制本端发出的数据，可以在两端分别调整。

### 让其他 Docker 程序使用通道

在客户端的 `compose.yml` 中，把需要使用通道的服务加入已有的 `services:` 下。例如下面的 `app` 和 `wireguard-client` 应处于同一级：

```yaml
services:
  # 保留原有 wireguard-client 配置，在它旁边添加 app
  app:
    image: curlimages/curl
    network_mode: service:wireguard-client
    depends_on:
      wireguard-client:
        condition: service_healthy
    command: ["--dns-servers", "1.1.1.1", "https://example.com"]
```

这个例子启动后请求一次网站，然后退出。实际应用请换成自己的镜像和启动命令。共享网络不等于共享 DNS 配置，应用仍需要设置自己使用的 DNS。

### 不用向导，手动配置

**这是另一种安装方法，已经按上面的向导部署就不必再做。** 手动方法在项目根目录使用 `compose.server.yml`、`compose.client.yml`，不要与向导生成的 `compose.yml` 混用。

在两台机器各自下载项目，然后各自生成一对 WireGuard 密钥（需要先安装 `wireguard-tools`）：

```sh
umask 077
wg genkey | tee private.key | wg pubkey > public.key
cp .env.example .env
```

`private.key` 是私钥，只能留在对应机器上；`public.key` 是公钥，需要填给另一端。不要把这两个文件提交到代码仓库。

服务器复制配置模板：

```sh
cp config/server/wg0.conf.example config/server/wg0.conf
```

客户端复制配置模板：

```sh
cp config/client/wg0.conf.example config/client/wg0.conf
```

把模板中的 `SERVER_PRIVATE_KEY` 等占位文字替换成对应密钥。在两端的 `.env` 中填写同一个足够长的随机 `UDP2RAW_PASSWORD`，客户端另外填写 `UDP2RAW_REMOTE_HOST`。口令只允许字母、数字和 `._~+-`。

服务器启动：

```sh
docker compose -f compose.server.yml up -d --build
```

客户端启动：

```sh
docker compose -f compose.client.yml up -d --build
```

### 环境变量参考

这些设置写在对应部署目录的 `.env` 文件中。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `UDP2RAW_REMOTE_HOST` | 无 | 客户端必填，服务器公网 IPv4 或能解析到 IPv4 的域名 |
| `UDP2RAW_PORT` | `4096` | 对外连接端口，两端填写相同值 |
| `UDP2RAW_PASSWORD` | 无 | 两端相同的口令，向导自动生成 |
| `UDP2RAW_PASSWORD_FILE` | 无 | 容器内的口令文件路径，设置后优先使用文件中的口令 |
| `SPEEDER_ENABLED` | `false` | 两端都开启或都关闭 UDPspeeder |
| `SPEEDER_FEC` | `20:10` | 本端发送数据的冗余比例 |
| `SPEEDER_MTU` | `1250` | UDPspeeder 分片大小 |
| `SPEEDER_TIMEOUT` | `8` | 等待一组数据的时间，单位为毫秒 |

WireGuard 的密钥、地址、路由、MTU、DNS 和转发规则写在 `wg0.conf`，不是 `.env`。不要改动以下内部连接设置：

- 服务器：`ListenPort = 51820`。
- 客户端：`Endpoint = 127.0.0.1:51821`，这里不是填写公网 IP 的地方。

默认 WireGuard MTU 为 `1280`，是保守起点，不保证适合所有网络。它和 UDPspeeder 的 MTU 不是同一层的设置。

### 使用单独的口令文件

以下例子使用**手动部署目录**。创建 `udp2raw-password.txt`，填入共同口令，并限制文件权限：

```sh
chmod 600 udp2raw-password.txt
```

再创建 `compose.secret.yml`：

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
docker compose -f compose.client.yml -f compose.secret.yml up -d --build
```

服务器将服务名换成 `wireguard-server`，Compose 文件换成 `compose.server.yml`。两端口令文件的内容必须相同，不要提交到代码仓库；使用文件后可以删除 `.env` 中的口令。

## 技术说明与开发测试

这一节面向需要了解实现或修改项目的人，普通使用者可以跳过。

连接过程：

```text
客户端 WireGuard -> [UDPspeeder] -> udp2raw === FakeTCP === udp2raw -> [UDPspeeder] -> 服务端 WireGuard
```

- WireGuard 负责内层流量的认证和加密，udp2raw 的加密不能替代它。
- 固定使用 FakeTCP、aes128cbc、hmac_sha1 和 UDPspeeder mode 0。
- 接口为 `wg0`，配置挂载至 `/config/wg0.conf`，内部端口为 51820/51821/51822。
- 客户端在 `wg-quick up` 之后、udp2raw 启动之前添加服务器 IPv4 的优先路由，避免外层流量再次进入隧道。
- Compose 默认使用桥接网络，不修改宿主机的默认路由；已设置 `NET_ADMIN`、`NET_RAW` 权限。
- 快速向导只生成 IPv4 配置，不提供整机 IPv6 隧道。
- 不支持旧的模式、算法、内部端口、配置路径环境变量及 `udp2raw-extra.conf`。
- 发布镜像支持 `linux/amd64`、`linux/arm64`、`linux/arm/v7`。

参数参考：[UDPspeeder 参数说明](https://github.com/wangyu-/UDPspeeder/blob/61b24a369700c3d8248dd18fa9a524b778741454/README.md)、[wg-quick MTU 实现](https://git.zx2c4.com/wireguard-tools/tree/src/wg-quick/linux.bash)。

静态检查：

```sh
sh tests/check.sh
```

快速启动配置生成测试（有 `wg` 时无需 Docker，否则会构建镜像）：

```sh
bash tests/quickstart.sh
```

构建镜像后，测试握手和正常停止：

```sh
docker build -t wg-resilient:local .
sh tests/e2e.sh
SPEEDER_ENABLED=true sh tests/e2e.sh
```

测试完整的生成、打包、部署流程：

```sh
bash tests/quickstart.sh --e2e
```

完整部署测试会实际构建和启停容器，通过本机 TCP 24096 映射端口检查两种模式的握手、健康状态和路由顺序。已有快速启动容器时会拒绝运行。请在测试机器上执行，防火墙需要允许测试网桥之间的转发。

### 发布镜像（维护者使用）

在 GitHub 仓库中设置 Actions secrets：

- `DOCKERHUB_USERNAME`：Docker Hub 用户名或组织名。
- `DOCKERHUB_TOKEN`：有目标仓库写入权限的 Docker Hub access token。

每周一自动检查 `wireguard-tools` 官方 tag。发现新版本后，绑定对应 commit，完成三种架构的构建和测试，再发布 `wireguard-tools-<版本>` 和 `latest`。已验证版本通过 GitHub 证据标签及 Docker manifest/镜像标签识别，不重复构建。

amd64、arm64 使用原生 runner 测试两种隧道模式。armv7 使用 QEMU 检查构建、架构、密钥运算及用户态程序；QEMU 不支持测试 WireGuard netlink。

手动发布项目版本：

```sh
git tag v1.0.0
git push origin v1.0.0
```

版本标签发布 `${DOCKERHUB_USERNAME}/wg-resilient:1.0.0` 和 `latest`。每个平台保留 `run-<workflow run>-<attempt>-<architecture>` 追踪标签。普通 `main` 推送和 pull request 只进行 amd64 构建及两种模式测试。
