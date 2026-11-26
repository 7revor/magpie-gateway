# Magpie 透明网关

Oracle A1（ARM64）上用 Docker Compose 启动一个 Mihomo 和多个 Magpie。

| 服务 | LAN 地址 | 出口 |
| --- | --- | --- |
| Mihomo | `10.77.0.2` | 唯一接入 `wan` 的容器 |
| Magpie 01 | `10.77.0.11` | `EXIT-A` |
| Magpie 02 | `10.77.0.12` | `EXIT-B` |

内网是 `10.77.0.0/24`。`10.77.0.1` 是 Docker IPAM 保留地址，宿主机不持有；Magpie 的默认网关是 `10.77.0.2`。LAN 不做宿主机 NAT。这里不设 `internal: true`，以免 Docker 内部网桥的隔离规则拦截目的地址在子网外、但下一跳是 Mihomo 的包。Mihomo 用 Linux TPROXY 接管 TCP/UDP，网关禁用内核转发；不需要 TUN、特权容器或宿主网络。

## 部署

1. 使用常规 Linux Docker Engine（非 rootless，内核支持 IPv4 netfilter TPROXY，如 `xt_TPROXY` / `nf_tproxy_ipv4`）和 Docker Compose **2.36.0+**；确认 OCI VCN、VPN、宿主机和现有 Docker 网络未占用 `10.77.0.0/24`。如果网关日志报 TPROXY 不可用，先检查内核支持，不要改成直连转发。
2. 复制模板：

   ```sh
   cp .env.example .env
   cp mihomo/config.example.yaml mihomo/config.yaml
   ```

3. 在 `.env` 填实际的 ARM64 Magpie 镜像及容器内专用配置目录。在 `magpie/01/`、`magpie/02/` 各放一份实例配置。在 `mihomo/config.yaml` 中替换两个保留地址示例节点；需要 UDP（例如 QUIC）时使用支持 UDP 的节点，示例 HTTP 节点只支持 TCP。
4. 从本目录启动：

   ```sh
   docker compose config --quiet
   docker compose up -d --build --wait
   docker compose ps
   docker compose logs --tail=100 mihomo
   ```

## 维护

- Magpie 默认不发布端口。若镜像需要写配置、降权启动或持久化业务数据，请按镜像要求调整挂载、用户及权限；无需加外网网卡。`.env`、实配和凭据不会进 Git，请另行备份。
- Mihomo 状态保留在命名卷 `mihomo_state`。更新配置后可用 `docker compose up -d --force-recreate mihomo` 重新绑定配置文件。
- Magpie 的系统 DNS 指向 `10.77.0.2`，禁止使用 Docker 内置 DNS `127.0.0.11`。默认由 Mihomo 统一访问上游 DoH，**DNS 上游不按实例分流**。如需 DNS 也按实例隔离，要另行配置；应用自行发起的 DoH 属于普通应用出站流量。
- 新增实例时，复制一对 `magpie-net-02` 和 `magpie-02`，改服务名、网络命名空间引用、配置目录和固定 IP（如 `10.77.0.13`），并在 Mihomo 的 `MATCH,REJECT` 前增加对应源 IP 规则。固定出口不应配置 `DIRECT` 回退。
- `magpie-net-*` 持有各自实例的网络命名空间，负责设置默认路由和 DNS 限制。Magpie 本身没有 `NET_ADMIN`。重建网络容器时连同对应的 Magpie 一起重建，例如 `docker compose up -d --force-recreate magpie-net-01 magpie-01`。

验收时从每个实例发起 HTTPS 请求，核对公网出口和 Mihomo 日志中的源地址、命中规则。停掉对应出口或 Mihomo 后，请求应失败而非走宿主机直连。IPv6 不启用，ICMP 不走这套 TCP/UDP 透明代理，不要用 `ping` 当作验收标准。
