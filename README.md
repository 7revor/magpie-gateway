# Magpie 透明网关

Oracle A1（ARM64）上用 Docker Compose 启动一个 Mihomo 和多个 Magpie。

| 服务 | LAN 地址 | 出口 |
| --- | --- | --- |
| Mihomo | `10.77.0.2` | 唯一接入 `wan` 的容器 |
| Magpie 01 | `10.77.0.11` | `EXIT-A`，Web 管理端口 `3431` |
| Magpie 02 | `10.77.0.12` | `EXIT-B`，Web 管理端口 `3432` |

内网是 `10.77.0.0/24`。`10.77.0.1` 是 Docker IPAM 保留地址，宿主机不持有；Magpie 的默认网关是 `10.77.0.2`。LAN 不做宿主机 NAT。这里不设 `internal: true`，以免 Docker 内部网桥的隔离规则拦截目的地址在子网外、但下一跳是 Mihomo 的包。Mihomo 用 Linux TPROXY 接管 TCP/UDP，网关禁用内核转发；不需要 TUN、特权容器或宿主网络。

## 部署

1. 使用 Linux Docker Engine **28.0+**（非 rootless，内核支持 IPv4 netfilter TPROXY，如 `xt_TPROXY` / `nf_tproxy_ipv4`）和 Docker Compose **2.36.0+**；确认 OCI VCN、VPN、宿主机和现有 Docker 网络未占用 `10.77.0.0/24`。如果网关日志报 TPROXY 不可用，先检查内核支持，不要改成直连转发。
2. 复制模板：

   ```sh
   cp .env.example .env
   cp mihomo/config.example.yaml mihomo/config.yaml
   ```

3. 无需预设 API Key 或 Web 登录密钥。可用 `MAGPIE_TZ_01`、`MAGPIE_TZ_02` 分别设置容器时区，默认 `Asia/Shanghai`。在 `mihomo/config.yaml` 填入真实 Shadowsocks 节点的地址、端口、加密方法和密码。如果需要代理 UDP，保留 `udp: true`，并确认服务端和中转支持 UDP、节点端口放行 UDP。访问 IPv6-only HTTPS 目标时，Shadowsocks 节点须有可达的 IPv4 入口和可用的 IPv6 出口。不提交真实配置。
4. 从本目录启动：

   ```sh
   docker compose config --quiet
   docker compose up -d --build --wait
   docker compose ps
   docker compose logs --tail=100 mihomo
   ```

已有部署：不要用模板覆盖实际节点或规则。将模板里的 `dns:` 块合并到 `mihomo/config.yaml`，并将 `store-fake-ip: true` 合入 `profile:`；保留 `proxies:`、`rules:`、`tunnels:`，不要重复定义同名配置块。更新代码后执行 `docker compose up -d --build --force-recreate --wait`，重建后仍使用原有数据卷。

## IPv4 Fake IP 和节点 IPv6 出站

Magpie 和 Mihomo 都保持 IPv4-only。各实例的系统 DNS 统一指向 `10.77.0.2`；Mihomo 对使用 Fake IP 的域名返回 `198.18.0.0/16` 内的 IPv4 地址。Magpie 用 IPv4 连接该地址，TPROXY 接管后，Mihomo 恢复原域名，按实例源 IP 选择 Shadowsocks 出口。对 TCP 连接，节点可以在远端解析域名，并通过 IPv6 访问只有 `AAAA` 记录的目标，容器本身不需要 IPv6。

Docker 内置 DNS `127.0.0.11` 仍被阻止。现在系统 DNS 由 Mihomo 统一处理，不再按实例分别向 `1.1.1.1:53` 转发；Mihomo 需要实际做上游查询时，统一使用普通 DNS `1.1.1.1:53`，不使用 DoH。应用自己用 DoH、其它解析器或直接连接 IP 时，不能指望这套 Fake IP 映射。

可用下列命令验证（也可以换成你确认只有 `AAAA` 记录的 HTTPS 测试域名）：

```sh
docker compose exec magpie-01 getent ahostsv4 ipv6.icanhazip.com
docker compose exec magpie-01 curl -4 --noproxy '*' --max-time 15 https://ipv6.icanhazip.com
docker compose logs --tail=100 mihomo | grep -F 'ipv6.icanhazip.com'
```

系统解析应返回 Fake IP，`curl` 应显示节点出口的 IPv6，Mihomo 日志应显示 `10.77.0.11` 命中 `EXIT-A`。`curl -4` 限制的是容器侧连接，不限制节点访问目标时的 IP 版本。如果节点没有 IPv6 出口，IPv6-only 目标应连接失败，不会回退到宿主机；双栈域名最终使用 IPv4 还是 IPv6 取决于节点的地址选择。不要用 Fake IP 作为 UDP/QUIC 能走 IPv6 的保证。

## Web 管理

官方 `ghcr.io/yetone/magpie:stable` 以非 root 用户运行（UID `65532`）。Compose 只把上游默认命令 `serve` 换成 `web --addr 0.0.0.0:3430 --no-open`，保留原入口 `/magpie`。两个实例在各自的网络里都监听 `3430`。Mihomo 的两个 TCP 转发分别指向 `10.77.0.11:3430`、`10.77.0.12:3430`；对应的宿主机端口只绑在 `127.0.0.1`，无需在 OCI 放行 `3431` / `3432`。这里的 `DIRECT` 只用于访问这两个固定的内网目标，不改变 Magpie 的出站策略。

在自己的电脑执行：

```sh
ssh -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:3431:127.0.0.1:3431 \
  -L 127.0.0.1:3432:127.0.0.1:3432 用户名@Oracle公网IP
```

Magpie 每次启动会生成临时 Web 登录密钥。在宿主机运行 `docker compose logs --tail=50 magpie-01 magpie-02`，分别从两个实例最新的启动日志复制 `?k=...`。在本机浏览器打开 `http://magpie-01.localhost:3431/?k=<实例01临时密钥>` 和 `http://magpie-02.localhost:3432/?k=<实例02临时密钥>`。用不同的主机名，避免浏览器在两个端口间共用登录 Cookie。如果设备不解析 `*.localhost`，可分别用独立的浏览器配置访问 `127.0.0.1:3431` 和 `127.0.0.1:3432`。不要分享带密钥的链接或启动日志。

Web 登录密钥只用于打开管理界面，不是调用 API 的密钥。登录以后，在各实例的 **Gateway → Gateway keys** 自行创建 API Key；供应商凭据也可以在 **Providers** 中配置。你在 UI 创建的网关密钥随该实例的 `/config` 卷持久化，不受临时 Web 登录密钥轮换影响。

关闭 SSH 就关闭本机访问通道，不会停服务。要关停单个实例，在宿主机运行 `docker compose stop magpie-01`；重新开启用 `docker compose start magpie-01`。Web UI 不作为 Docker 停机控制面。排障可用 `docker compose exec magpie-01 sh`，无需开放通用代理。

## 维护

- 账号登录、Provider、密钥和缓存等状态都保存在 `/config`。两个实例分别使用命名卷 `magpie_01_state` 和 `magpie_02_state`，不要混用，也不要用 `docker compose down -v` 来做普通停机。请备份卷、`.env` 和 Mihomo 实配；它们可能含敏感凭据。若从旧方案已有业务配置，迁移进对应的卷后再启动，不会自动读取旧的 `magpie/01/`、`magpie/02/`。
- Mihomo 状态保留在命名卷 `mihomo_state`。更新配置后可用 `docker compose up -d --force-recreate mihomo` 重新绑定配置文件。
- 新增实例时，复制一对 `magpie-net-02` 和 `magpie-02`，改服务名、网络命名空间引用、命名卷、环境变量和固定 IP（如 `10.77.0.13`）。在 Mihomo 的 `MATCH,REJECT` 前增加对应源 IP 规则，在 `tunnels:` 和 Compose 的 `mihomo.ports` 增加管理端口（如 `3433`）。固定出口不应配置 `DIRECT` 回退。
- `magpie-net-*` 持有各自实例的网络命名空间，负责设置默认路由和 DNS 限制。Magpie 本身没有 `NET_ADMIN`。重建网络容器时连同对应的 Magpie 一起重建，例如 `docker compose up -d --force-recreate magpie-net-01 magpie-01`。

验收时从每个实例发起 HTTPS 请求，核对公网出口和 Mihomo 日志中的源地址、命中规则。停掉对应出口或 Mihomo 后，请求应失败而非走宿主机直连。容器不启用 IPv6，ICMP 不走这套 TCP/UDP 透明代理，不要用 `ping` 当作验收标准。

## 许可证

本仓库的部署配置和脚本采用 [MIT 许可证](LICENSE)；Magpie、Mihomo 和其他上游依赖沿用各自的许可证。
