#!/usr/bin/env bash
set -Eeuo pipefail

# 采集端单脚本入口：启动、停止、重载、添加动态目标。
# 默认 Web 入口：https://127.0.0.1:29088/

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

export MONITOR_UID="${MONITOR_UID:-$(id -u)}"
export MONITOR_GID="${MONITOR_GID:-$(id -g)}"

WEB_URL="${WEB_URL:-https://127.0.0.1:29088}"
BASIC_USER="${BASIC_USER:-vm_admin}"
BASIC_PASS="${BASIC_PASS:-CAO-hengyuan89}"
TARGET_FORCE=0

log() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    err "未找到 docker compose 或 docker-compose"
    exit 1
  fi
}

prepare_dirs() {
  mkdir -p \
    data/vmagent \
    data/caddy/data \
    data/caddy/config \
    targets/node \
    targets/blackbox \
    targets/snmp
  chmod -R u+rwX data targets || true
}

generate_selfsigned_cert() {
  local crt="config/caddy-selfsigned.crt" key="config/caddy-selfsigned.key"
  [[ -f "${crt}" && -f "${key}" ]] && return 0
  command -v openssl >/dev/null 2>&1 || {
    warn "未找到 openssl；可手动使用内置隐藏备用证书："
    warn "  cp config/.caddy-selfsigned.crt config/caddy-selfsigned.crt"
    warn "  cp config/.caddy-selfsigned.key config/caddy-selfsigned.key"
    return 1
  }
  if [[ ! -f "config/.caddy-selfsigned.crt" || ! -f "config/.caddy-selfsigned.key" ]]; then
    warn "未找到隐藏备用证书 config/.caddy-selfsigned.*；建议保留备用文件，方便离线机器初始化"
  fi
  log "生成自签证书（有效期 10 年）..."
  if ! openssl req -x509 -newkey rsa:2048 \
      -keyout "${key}" \
      -out "${crt}" \
      -days 3650 -nodes \
      -subj "/CN=vmagent-collector" \
      -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" \
      2>/dev/null; then
    warn "自签证书生成失败；可手动使用内置隐藏备用证书："
    warn "  cp config/.caddy-selfsigned.crt config/caddy-selfsigned.crt"
    warn "  cp config/.caddy-selfsigned.key config/caddy-selfsigned.key"
    return 1
  fi
  chmod 600 "${key}"
  ok "自签证书已生成：${crt}"
}

ensure_selfsigned_cert() {
  local crt="config/caddy-selfsigned.crt" key="config/caddy-selfsigned.key"
  [[ -f "${crt}" && -f "${key}" ]] && return 0
  if generate_selfsigned_cert; then
    return 0
  fi
  if [[ -f "config/.caddy-selfsigned.crt" && -f "config/.caddy-selfsigned.key" ]]; then
    cp config/.caddy-selfsigned.crt "${crt}"
    cp config/.caddy-selfsigned.key "${key}"
    chmod 600 "${key}"
    ok "已使用隐藏备用自签证书：config/.caddy-selfsigned.*"
    return 0
  fi
  err "缺少自签证书，且无法生成或使用隐藏备用证书"
  exit 1
}

http_post() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl --noproxy "*" -k -fsS -u "${BASIC_USER}:${BASIC_PASS}" -X POST "${url}" >/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate --user="${BASIC_USER}" --password="${BASIC_PASS}" --method=POST -qO- "${url}" >/dev/null
  else
    warn "未找到 curl/wget，无法 HTTP reload：${url}"
    return 1
  fi
}

valid_label_value() {
  [[ "$1" =~ ^[A-Za-z0-9_.:-]+$ ]]
}

valid_target_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

valid_plain_value() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

require_label_value() {
  local name="$1" value="$2"
  valid_label_value "${value}" || { err "${name} 只能包含字母、数字、下划线、点、冒号和短横线：${value}"; exit 1; }
}

require_target_name() {
  local value="$1"
  valid_target_name "${value}" || { err "目标名称只能包含字母、数字、下划线、点和短横线：${value}"; exit 1; }
}

require_plain_value() {
  local name="$1" value="$2"
  valid_plain_value "${value}" || { err "${name} 不能包含换行符"; exit 1; }
}

parse_force_arg() {
  TARGET_FORCE=0
  if [[ "${1:-}" == "--force" ]]; then
    TARGET_FORCE=1
    shift
  fi
  FORCE_REMAINING=("$@")
}

safe_name() {
  echo "$1" | tr -c 'A-Za-z0-9_.-' '_' | sed 's/^_*//;s/_*$//'
}

write_target_file() {
  local file="$1" content="$2"
  if [[ -e "${file}" && "${TARGET_FORCE}" != "1" ]]; then
    err "目标文件已存在：${file}"
    err "如需覆盖，请在命令中添加 --force"
    exit 1
  fi
  printf '%s\n' "${content}" > "${file}"
  ok "已写入 ${file}"
}

validate_caddyfile() {
  docker run --rm \
    -v "${PROJECT_DIR}/config/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "${PROJECT_DIR}/config/caddy-selfsigned.crt:/etc/caddy/caddy-selfsigned.crt:ro" \
    -v "${PROJECT_DIR}/config/caddy-selfsigned.key:/etc/caddy/caddy-selfsigned.key:ro" \
    caddy:2.11.4-alpine \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
}

reload_all() {
  log "重载 vmagent/Blackbox/Caddy 配置"
  http_post "${WEB_URL}/vmagent/-/reload" || warn "vmagent reload 失败，请看日志"
  http_post "${WEB_URL}/blackbox/-/reload" || warn "Blackbox reload 失败，请看日志"
  compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || warn "Caddy 热重载失败，可执行 ./ops.sh restart caddy"
  # snmp_exporter 对每次请求读取配置的支持依版本/配置而异；保险起见轻量重启。
  compose restart snmp-exporter >/dev/null 2>&1 || warn "SNMP Exporter 重启失败，请看日志"
  ok "reload 完成"
}

add_node() {
  parse_force_arg "$@"
  set -- "${FORCE_REMAINING[@]}"
  local name="${1:?用法：./ops.sh add-node [--force] <name> <host:port> [group] [role]}"
  local target="${2:?用法：./ops.sh add-node [--force] <name> <host:port> [group] [role]}"
  local group="${3:-default}"
  local role="${4:-node}"
  local file="targets/node/$(safe_name "$name").yml"
  require_target_name "${name}"
  require_plain_value "target" "${target}"
  require_label_value "group" "${group}"
  require_label_value "role" "${role}"
  write_target_file "${file}" "$(cat <<YAML
# 由 ops.sh add-node 生成。
- targets:
    - ${target}
  labels:
    group: ${group}
    role: ${role}
YAML
)"
  reload_all
}

add_blackbox() {
  parse_force_arg "$@"
  set -- "${FORCE_REMAINING[@]}"
  local name="${1:?用法：./ops.sh add-blackbox [--force] <name> <target> [module] [group]}"
  local target="${2:?用法：./ops.sh add-blackbox [--force] <name> <target> [module] [group]}"
  local module="${3:-http_2xx}"
  local group="${4:-default}"
  local file="targets/blackbox/$(safe_name "$name").yml"
  require_target_name "${name}"
  require_plain_value "target" "${target}"
  require_label_value "module" "${module}"
  require_label_value "group" "${group}"
  write_target_file "${file}" "$(cat <<YAML
# 由 ops.sh add-blackbox 生成。
- targets:
    - ${target}
  labels:
    group: ${group}
    module: ${module}
YAML
)"
  reload_all
}

add_http() {
  parse_force_arg "$@"
  set -- "${FORCE_REMAINING[@]}"
  local name="${1:?用法：./ops.sh add-http [--force] <name> <url> [group]}"
  local target="${2:?用法：./ops.sh add-http [--force] <name> <url> [group]}"
  local group="${3:-default}"
  [[ "${TARGET_FORCE}" == "1" ]] && add_blackbox --force "$name" "$target" "http_2xx" "$group" || add_blackbox "$name" "$target" "http_2xx" "$group"
}

add_icmp() {
  parse_force_arg "$@"
  set -- "${FORCE_REMAINING[@]}"
  local name="${1:?用法：./ops.sh add-icmp [--force] <name> <ip-or-domain> [group]}"
  local target="${2:?用法：./ops.sh add-icmp [--force] <name> <ip-or-domain> [group]}"
  local group="${3:-default}"
  [[ "${TARGET_FORCE}" == "1" ]] && add_blackbox --force "$name" "$target" "icmp" "$group" || add_blackbox "$name" "$target" "icmp" "$group"
}

add_tcp() {
  parse_force_arg "$@"
  set -- "${FORCE_REMAINING[@]}"
  local name="${1:?用法：./ops.sh add-tcp [--force] <name> <host:port> [group]}"
  local target="${2:?用法：./ops.sh add-tcp [--force] <name> <host:port> [group]}"
  local group="${3:-default}"
  [[ "${TARGET_FORCE}" == "1" ]] && add_blackbox --force "$name" "$target" "tcp_connect" "$group" || add_blackbox "$name" "$target" "tcp_connect" "$group"
}

add_dns() {
  parse_force_arg "$@"
  set -- "${FORCE_REMAINING[@]}"
  local name="${1:?用法：./ops.sh add-dns [--force] <name> <dns-server:53> [group]}"
  local target="${2:?用法：./ops.sh add-dns [--force] <name> <dns-server:53> [group]}"
  local group="${3:-default}"
  [[ "${TARGET_FORCE}" == "1" ]] && add_blackbox --force "$name" "$target" "dns_udp" "$group" || add_blackbox "$name" "$target" "dns_udp" "$group"
}

add_snmp() {
  parse_force_arg "$@"
  set -- "${FORCE_REMAINING[@]}"
  local name="${1:?用法：./ops.sh add-snmp [--force] <name> <ip> [module] [auth] [group]}"
  local target="${2:?用法：./ops.sh add-snmp [--force] <name> <ip> [module] [auth] [group]}"
  local module="${3:-if_mib}"
  local auth="${4:-public_v2}"
  local group="${5:-network}"
  local file="targets/snmp/$(safe_name "$name").yml"
  require_target_name "${name}"
  require_plain_value "target" "${target}"
  require_label_value "module" "${module}"
  require_label_value "auth" "${auth}"
  require_label_value "group" "${group}"
  write_target_file "${file}" "$(cat <<YAML
# 由 ops.sh add-snmp 生成。
- targets:
    - ${target}
  labels:
    group: ${group}
    module: ${module}
    auth: ${auth}
YAML
)"
  reload_all
}

restart_usage() {
  cat <<'EOF'
用法：
  ./ops.sh restart all
  ./ops.sh restart <service>

说明：
  restart 默认不执行动作，避免误重启全部服务。
EOF
}

usage() {
  cat <<'EOF'
用法：./ops.sh <命令>

常用命令：
  up                         创建目录、启动采集端服务
  down --yes                 停止并删除容器，保留 ./data 数据
  restart                    显示重启用法
  restart all                重启全部服务
  restart <service>          重启某个服务
  status                     查看容器状态
  logs [service]             查看日志
  reload                     动态重载 vmagent/Blackbox/Caddy，轻量重启 snmp-exporter
  check                      检查 docker-compose.yml 和 Caddyfile
  pull                       拉取镜像

动态目标：
  add-node [--force] <name> <host:port> [group] [role]
  add-http [--force] <name> <url> [group]
  add-icmp [--force] <name> <ip-or-domain> [group]
  add-tcp [--force] <name> <host:port> [group]
  add-dns [--force] <name> <dns-server:53> [group]
  add-blackbox [--force] <name> <target> [module] [group]
  add-snmp [--force] <name> <ip> [module] [auth] [group]

示例：
  先在 docker-compose.yml 中修改 -remoteWrite.url，然后执行：
  ./ops.sh up
  ./ops.sh add-node web01 10.0.0.11:9100 prod web
  ./ops.sh add-http api https://api.example.com prod
EOF
}

cmd="${1:-usage}"
shift || true
case "${cmd}" in
  up)
    prepare_dirs
    ensure_selfsigned_cert
    log "拉取镜像；离线环境会自动使用本地已有镜像继续启动"
    compose pull || warn "镜像拉取失败，继续尝试使用本地已有镜像启动"
    log "启动采集端服务"
    compose up -d
    ok "启动完成：${WEB_URL}/  默认 Basic Auth：vm_admin/CAO-hengyuan89"
    ;;
  down)
    [[ "${1:-}" == "--yes" ]] || { err "停止并删除容器需要确认：./ops.sh down --yes"; exit 1; }
    compose down
    ok "已停止；数据仍保留在 ./data"
    ;;
  restart)
    if [[ $# -eq 0 ]]; then
      restart_usage
      exit 0
    fi
    if [[ "${1}" == "all" ]]; then
      compose restart
    else
      compose restart "$@"
    fi
    ;;
  status)
    compose ps
    ;;
  logs)
    compose logs -f --tail=200 "$@"
    ;;
  reload)
    reload_all
    ;;
  check)
    compose config >/dev/null
    validate_caddyfile
    ok "配置检查通过"
    ;;
  pull)
    compose pull
    ;;
  add-node)
    add_node "$@"
    ;;
  add-http)
    add_http "$@"
    ;;
  add-icmp)
    add_icmp "$@"
    ;;
  add-tcp)
    add_tcp "$@"
    ;;
  add-dns)
    add_dns "$@"
    ;;
  add-blackbox)
    add_blackbox "$@"
    ;;
  add-snmp)
    add_snmp "$@"
    ;;
  help|-h|--help|usage)
    usage
    ;;
  *)
    err "未知命令：${cmd}"
    usage
    exit 1
    ;;
esac
