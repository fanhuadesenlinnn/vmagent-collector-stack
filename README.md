# vmagent-collector：远端 VictoriaMetrics 采集端

这个项目用于单独部署采集端：

```text
Caddy + vmagent + node-exporter + blackbox-exporter + snmp-exporter
```

它不部署 Grafana、Alertmanager、vmalert，也不部署本地 VictoriaMetrics。采集到的数据由本项目的 `vmagent` 通过 `remote_write` 写入远端 VictoriaMetrics。

## 一条命令启动

先确认远端 VictoriaMetrics 的写入地址。例如远端直接暴露 VictoriaMetrics：

```bash
REMOTE_WRITE_URL='http://远端服务器IP:8428/api/v1/write' ./ops.sh up
```

如果远端是主监控项目里预留的 `28087` 裸入口：

```bash
REMOTE_WRITE_URL='http://远端服务器IP:28087/api/v1/write' ./ops.sh up
```

如果远端走主监控项目 Caddy HTTPS 入口，并使用 `vm_remote` 认证：

```bash
REMOTE_WRITE_URL='https://远端服务器IP:28088/vm/api/v1/write' \
REMOTE_WRITE_USER='vm_remote' \
REMOTE_WRITE_PASSWORD='vm_remote_PASSWD' \
REMOTE_WRITE_TLS_INSECURE_SKIP_VERIFY=true \
./ops.sh up
```

启动后访问采集端 Web 入口：

```text
https://服务器IP:29088/
```

默认使用项目自带自签证书，浏览器提示“不安全”或“证书不受信任”时，继续访问即可。

默认账号：

```text
vm_admin / CAO-hengyuan89
```

## 目录结构

```text
.
├── docker-compose.yml
├── ops.sh
├── config
│   ├── Caddyfile
│   ├── vmagent.yml
│   ├── blackbox.yml
│   ├── snmp.yml
│   ├── .caddy-selfsigned.crt
│   └── .caddy-selfsigned.key
├── targets
│   ├── node
│   ├── blackbox
│   └── snmp
└── data
```

`data/` 是容器持久化目录，主要保存 vmagent 断连队列和 Caddy 数据。

## 访问路径

```text
https://服务器IP:29088/           采集端状态页
https://服务器IP:29088/vmagent/   vmagent
https://服务器IP:29088/blackbox/  Blackbox Exporter
https://服务器IP:29088/snmp/      SNMP Exporter
```

默认只开放 HTTPS `29088`。HTTP `29080` 已在 `docker-compose.yml` 中保留注释，需要时可取消注释。

## HTTPS 自签证书

`ops.sh up` 会优先自动生成：

```text
config/caddy-selfsigned.crt
config/caddy-selfsigned.key
```

这两个非隐藏文件是运行时生成文件，已加入 `.gitignore`，不会提交到仓库。

如果离线机器没有 `openssl`，或证书生成失败，可以手动使用项目内置隐藏备用证书：

```bash
cp config/.caddy-selfsigned.crt config/caddy-selfsigned.crt
cp config/.caddy-selfsigned.key config/caddy-selfsigned.key
```

浏览器提示证书不受信任是正常现象，继续访问即可。

## 常用命令

```bash
./ops.sh status
./ops.sh logs
./ops.sh logs vmagent
./ops.sh reload
./ops.sh restart all
./ops.sh restart vmagent
./ops.sh down --yes
```

`./ops.sh down` 必须显式追加 `--yes`，避免误停服务。

## 动态添加目标

```bash
./ops.sh add-node web01 10.0.0.11:9100 prod web
./ops.sh add-http api https://api.example.com prod
./ops.sh add-icmp dns 1.1.1.1 public
./ops.sh add-tcp mysql 10.0.0.20:3306 prod
./ops.sh add-dns public-dns 8.8.8.8:53 public
./ops.sh add-blackbox grpc-api grpc.example.com:443 grpc_tls prod
./ops.sh add-snmp sw01 192.168.1.10 if_mib public_v2 network
```

动态目标命令默认不会覆盖同名文件；如需覆盖已有目标，请加 `--force`。

## 远端写入说明

推荐远端 VictoriaMetrics 给采集端开放裸写入入口，例如：

```text
http://远端服务器IP:28087/api/v1/write
```

然后用防火墙、安全组或来源 IP 限制，只允许采集端访问。这样 vmagent 配置最简单，也避免自签 HTTPS 和 Basic Auth 对 remote_write 的额外影响。

如果走远端 Caddy HTTPS 入口，把 `REMOTE_WRITE_URL` 指向：

```text
https://远端服务器IP:28088/vm/api/v1/write
```

并设置：

```text
REMOTE_WRITE_USER='vm_remote'
REMOTE_WRITE_PASSWORD='vm_remote_PASSWD'
REMOTE_WRITE_TLS_INSECURE_SKIP_VERIFY=true
```

`REMOTE_WRITE_TLS_INSECURE_SKIP_VERIFY=true` 用于远端 Caddy 使用自签证书的场景。如果远端使用受信任证书，可以改成 `false` 或不设置。

## 非 root 部署

脚本会把容器运行用户设置为当前 UID/GID：

```bash
su - monitor
cd vmagent-collector-stack
REMOTE_WRITE_URL='http://远端服务器IP:28087/api/v1/write' ./ops.sh up
```

## 离线部署

离线机器需要提前导入本项目使用的 Docker 镜像。`./ops.sh up` 会先尝试拉取镜像，失败后继续使用本地已有镜像启动。
