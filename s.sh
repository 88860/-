#!/usr/bin/env bash
export LC_ALL=C
shopt -s nullglob

RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
PURPLE='\033[35m'
BLUE='\033[34m'
PLAIN='\033[0m'

SB_DIR=/etc/sing-box
CONFIG=$SB_DIR/config.json
SBM_DIR=/etc/sbm
NODE_DIR=$SBM_DIR/nodes
PEER_DIR=$SBM_DIR/peers
WG_DIR=$SBM_DIR/wg
WG_CONF=$WG_DIR/local.json
STATE=$SBM_DIR/state.json
ACME_DIR=$SBM_DIR/acme
PKG_LOG=$SBM_DIR/apt_installed
BYPASS_STATE=$SBM_DIR/bypass_state.json
WG_NAT_STATE=$WG_DIR/nat_state.json
NET_CACHE=$SBM_DIR/net_cache
NET_MONITOR_PID=/var/run/sbm_netmon.pid
REAPPLY_LOCK=$SBM_DIR/reapply.lock
SELF=/root/s.sh
SHORTCUT=/usr/local/bin/s
CORE=/usr/local/bin/sing-box
SERVICE_UNIT=/etc/systemd/system/sing-box.service
DROPIN_DIR=/etc/systemd/system/sing-box.service.d
DROPIN=$DROPIN_DIR/sbm.conf
GH_API=https://api.github.com/repos/SagerNet/sing-box
PROBE_URL=http://cp.cloudflare.com/generate_204
TUN_IF=sbmtun
WG_IF=sbmwg
CERT_TAG=acme-cert
BYPASS_PREF=90
HOP_TABLE=sbm_hop

NET_IPV4=""
NET_IPV6=""
NET_IF_V4=""
NET_IF_V6=""
NET_STACK=""
IPV6_OK=0

TMP_FILES=""

stop_net_monitor(){
  if [ -f "$NET_MONITOR_PID" ]; then
    local pid; pid=$(cat "$NET_MONITOR_PID" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      pkill -KILL -P "$pid" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null
      { wait "$pid"; } 2>/dev/null
    fi
    rm -f "$NET_MONITOR_PID"
  fi
}

cleanup_tmp(){
  if [ -n "$TMP_FILES" ]; then
    local f
    for f in $TMP_FILES; do
      [ -e "$f" ] && rm -rf "$f"
    done
  fi
  TMP_FILES=""
}

cleanup_on_exit(){ cleanup_tmp; }
trap cleanup_on_exit EXIT INT TERM

NODE_COUNT=0
NODE_FILES=()
PEER_COUNT=0
PEER_FILES=()
PEER_TAGS=()
PEER_TYPES=()
PEER_NAMES=()
PEER_PORTS=()
PICKED=""
CORE_VERSION=""
CORE_TAGS=""

IP_INFO_IP=""
IP_INFO_C=""
IP_INFO_ASN=""
IP_INFO_NAME=""

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}[×] 权限不足: 请使用 root 用户运行${PLAIN}"; exit 1; }

read_line(){
  local value
  if [ -c /dev/tty ]; then IFS= read -r value </dev/tty || value=""
  else IFS= read -r value || value=""; fi
  value="${value%$'\r'}"
  printf '%s' "$value"
}

prompt(){
  local msg="$1" def="$2"
  if [ -n "$def" ]; then
    printf "  ${CYAN}%s [%s]: ${PLAIN}" "$msg" "$def" >&2
  else
    printf "  ${CYAN}%s: ${PLAIN}" "$msg" >&2
  fi
  local value; value=$(read_line)
  echo "${value:-$def}"
}

prompt_yes(){
  local value; value=$(prompt "$1 (y/N)" "n")
  [ "$value" = y ] || [ "$value" = Y ]
}

wait_key(){
  printf "\n  ${CYAN}>> 按回车键继续...${PLAIN}" >&2
  read_line >/dev/null
}

tell(){ echo -e "  $*"; }
tell_ok(){ echo -e "  ${GREEN}[√] $*${PLAIN}"; }
tell_warn(){ echo -e "  ${RED}[×] $*${PLAIN}"; }
tell_gap(){ echo ""; }

uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }
uri_decode(){ local s=${1//+/ }; s=${s//\\/\\\\}; printf '%b' "${s//%/\\x}"; }
slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){ openssl rand -hex 8; }
random_uuid(){ cat /proc/sys/kernel/random/uuid; }
random_port(){ shuf -i 20000-60000 -n1; }

json_write(){
  local dest=$1 tmp rc=0
  tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  cat >"$tmp" || rc=1
  [ -s "$tmp" ] || rc=1
  if [ "$rc" = 0 ]; then
    install -m600 "$tmp" "$dest" || rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

json_save(){
  local dest=$1 content=$2
  [ -n "$content" ] || return 1
  printf '%s\n' "$content" | json_write "$dest"
}

json_edit(){
  local file=$1 expr=$2; shift 2
  local tmp rc=1
  tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  if jq "$@" "$expr" "$file" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if install -m600 "$tmp" "$file"; then rc=0; fi
  fi
  rm -f "$tmp"
  return "$rc"
}

init_dirs(){
  mkdir -p "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box
  chmod 700 "$SBM_DIR" "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box
  [ -f "$STATE" ] || printf '%s\n' '{"exit":"direct","domain":"","email":"","challenge":"http","asset":""}' | json_write "$STATE"
  [ -f "$PKG_LOG" ] || : >"$PKG_LOG"
  [ -f "$BYPASS_STATE" ] || printf '%s\n' '{"v4_ports":[],"v6_ports":[]}' | json_write "$BYPASS_STATE"
}

state_get(){ jq -r --arg k "$1" '.[$k]//""' "$STATE" 2>/dev/null; }
state_set(){ json_edit "$STATE" '.[$k]=$v' --arg k "$1" --arg v "$2"; }

ensure_command(){
  local cmd=$1 pkg=${2:-$1} preinstalled=0
  command -v "$cmd" >/dev/null 2>&1 && return 0
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then
    preinstalled=1
  fi
  local guard=0
  while command -v fuser >/dev/null 2>&1 && { fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; }; do
    sleep 1; guard=$((guard+1)); [ "$guard" -gt 30 ] && break
  done
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" >/dev/null 2>&1 || return 1
  command -v "$cmd" >/dev/null 2>&1 || return 1
  if [ "$preinstalled" = 0 ]; then
    grep -qE "^${pkg}\|owned$" "$PKG_LOG" 2>/dev/null || echo "${pkg}|owned" >>"$PKG_LOG"
  fi
}

check_dependencies(){
  local cmd pkg
  local deps=(
    "bash:bash" "curl:curl" "tar:tar" "jq:jq" "openssl:openssl"
    "nft:nftables" "ss:iproute2" "ip:iproute2" "ping:iputils-ping"
    "ping6:iputils-ping" "flock:util-linux" "pkill:procps" "sysctl:procps"
    "getent:libc-bin" "clear:ncurses-bin" "awk:mawk"
    "grep:grep" "sed:sed" "find:findutils" "shuf:coreutils" "timeout:coreutils"
    "systemctl:systemd" "journalctl:systemd" "modprobe:kmod"
  )
  local missing=0
  for item in "${deps[@]}"; do
    cmd=${item%%:*}
    if ! command -v "$cmd" >/dev/null 2>&1; then missing=1; break; fi
  done
  if [ "$missing" = 1 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || {
      echo -e "${RED}[×] apt 软件源更新失败${PLAIN}"; exit 1
    }
  fi
  for item in "${deps[@]}"; do
    cmd=${item%%:*}; pkg=${item#*:}
    ensure_command "$cmd" "$pkg" || {
      echo -e "${RED}[×] 依赖组件 $cmd 安装失败${PLAIN}"; exit 1
    }
  done
  return 0
}

core_version(){
  if [ -z "$CORE_VERSION" ] && [ -x "$CORE" ]; then
    CORE_VERSION=$("$CORE" version 2>/dev/null | awk '/version/{print $3; exit}')
  fi
  printf '%s' "$CORE_VERSION"
}
core_tags(){
  if [ -z "$CORE_TAGS" ] && [ -x "$CORE" ]; then
    CORE_TAGS=$("$CORE" version 2>/dev/null | sed -n 's/^Tags: //p')
  fi
  printf '%s' "$CORE_TAGS"
}
has_acme_support(){ [[ "$(core_tags)" == *with_acme* ]]; }
core_cache_reset(){ CORE_VERSION=""; CORE_TAGS=""; }

asset_candidates(){
  case $(uname -m) in
    x86_64|amd64) printf '%s\n' linux-amd64 linux-amd64-glibc linux-amd64-musl ;;
    aarch64|arm64) printf '%s\n' linux-arm64 linux-arm64-glibc linux-arm64-musl ;;
    armv7l|armv8l) printf '%s\n' linux-armv7 linux-armv7-glibc linux-armv7-musl ;;
    armv6l) printf '%s\n' linux-armv6 ;;
    armv5l) printf '%s\n' linux-armv5 ;;
    i386|i686) printf '%s\n' linux-386 linux-386-glibc ;;
    riscv64) printf '%s\n' linux-riscv64 linux-riscv64-glibc ;;
    loongarch64) printf '%s\n' linux-loong64 linux-loong64-glibc ;;
    ppc64le) printf '%s\n' linux-ppc64le ;;
    s390x) printf '%s\n' linux-s390x ;;
    mips64el) printf '%s\n' linux-mips64le ;;
    mipsel) printf '%s\n' linux-mipsle ;;
  esac
}

release_json(){ curl -fsSL -m 15 "$GH_API/releases/latest" 2>/dev/null; }
remote_version(){ release_json | jq -r '.tag_name//""' | sed 's/^v//'; }

default_iface_v4(){
  local iface
  iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  case "$iface" in "$TUN_IF"|"$WG_IF") iface="" ;; esac
  if [ -z "$iface" ]; then
    iface=$(ip -4 route show table main default 2>/dev/null | awk -v t="$TUN_IF" -v w="$WG_IF" '$5!=t && $5!=w {print $5; exit}')
  fi
  printf '%s' "$iface"
}
default_iface_v6(){
  local iface
  iface=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  case "$iface" in "$TUN_IF"|"$WG_IF") iface="" ;; esac
  if [ -z "$iface" ]; then
    iface=$(ip -6 route show table main default 2>/dev/null | awk -v t="$TUN_IF" -v w="$WG_IF" '$5!=t && $5!=w {print $5; exit}')
  fi
  printf '%s' "$iface"
}

local_ipv4(){ printf '%s' "$NET_IPV4"; }
local_ipv6(){ printf '%s' "$NET_IPV6"; }

resolve_addresses(){ getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u; }

is_cgnat_v4(){
  local ip=$1 a b
  IFS=. read -r a b _ <<<"$ip"
  [ "$a" = "100" ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]
}

probe_network_stack(){
  NET_IF_V4=$(default_iface_v4)
  NET_IF_V6=$(default_iface_v6)
  local local_v4="" local_v6=""
  [ -n "$NET_IF_V4" ] && local_v4=$(ip -4 addr show dev "$NET_IF_V4" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
  [ -n "$NET_IF_V6" ] && local_v6=$(ip -6 addr show dev "$NET_IF_V6" 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | grep -v '^fe80' | head -1)
  if [ -z "$local_v4" ] && [ -z "$local_v6" ]; then
    NET_IPV4=""; NET_IPV6=""; NET_STACK="none"; IPV6_OK=0; return
  fi
  local tmp4="" tmp6="" ip4="" ip6=""
  if [ -n "$local_v4" ]; then
    tmp4=$(mktemp); TMP_FILES="$TMP_FILES $tmp4"
    (curl -4 -s -m 2 https://ipv4.icanhazip.com 2>/dev/null > "$tmp4") &
  fi
  if [ -n "$local_v6" ]; then
    tmp6=$(mktemp); TMP_FILES="$TMP_FILES $tmp6"
    (curl -6 -s -m 2 https://ipv6.icanhazip.com 2>/dev/null > "$tmp6") &
  fi
  wait
  [ -n "$tmp4" ] && { ip4=$(tr -d '\n ' < "$tmp4"); rm -f "$tmp4"; }
  [ -n "$tmp6" ] && { ip6=$(tr -d '\n ' < "$tmp6"); rm -f "$tmp6"; }
  case "$ip4" in
    ""|10.*|192.168.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) ip4="" ;;
    *) if is_cgnat_v4 "$ip4"; then ip4=""; fi ;;
  esac
  case "$ip6" in ""|fe80:*|fc*|fd*|::1) ip6="" ;; esac
  NET_IPV4="$ip4"; NET_IPV6="$ip6"
  if [ -n "$ip4" ] && [ -n "$ip6" ]; then NET_STACK="both"
  elif [ -n "$ip4" ]; then NET_STACK="v4"
  elif [ -n "$ip6" ]; then NET_STACK="v6"
  else NET_STACK="none"; fi

  IPV6_OK=0
  if [ -n "$ip6" ]; then
    if curl -6 -s -m 3 https://ipv6.icanhazip.com >/dev/null 2>&1; then
      IPV6_OK=1
    fi
  fi
}

probe_network_stack_async(){
  (
    probe_network_stack
    local tmp
    tmp=$(mktemp "${NET_CACHE}.XXXXXX") || exit 0
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" > "$tmp" && mv -f "$tmp" "$NET_CACHE" || rm -f "$tmp"
  ) </dev/null >/dev/null 2>&1 &
}

load_net_cache(){
  if [ -f "$NET_CACHE" ]; then
    { IFS= read -r NET_IPV4; IFS= read -r NET_IPV6
      IFS= read -r NET_IF_V4; IFS= read -r NET_IF_V6
      IFS= read -r NET_STACK; IFS= read -r IPV6_OK; } < "$NET_CACHE"
  fi
  if [ -z "$NET_STACK" ]; then
    probe_network_stack
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" > "$NET_CACHE" 2>/dev/null
  fi
}

start_net_monitor(){
  stop_net_monitor
  (
    trap 'pkill -P $BASHPID 2>/dev/null; exit 0' TERM INT
    while :; do
      (
        last_trigger=0
        ip monitor link route address 2>/dev/null | while IFS= read -r line; do
          case "$line" in
            *" lo "*|*"lo:"*|*"docker"*|*"veth"*|*"br-"*|*"virbr"*|*"$TUN_IF"*|*"$WG_IF"*|*"tailscale"*|*"zt"*) continue ;;
          esac
          while IFS= read -r -t 2 _; do :; done
          now=$(date +%s)
          if [ $((now-last_trigger)) -ge 5 ]; then
            last_trigger=$now
            ("$SELF" --reapply >/dev/null 2>&1) &
          fi
        done
      ) &
      monitor_pid=$!
      for ((monitor_wait=0; monitor_wait<60; monitor_wait++)); do
        kill -0 "$monitor_pid" 2>/dev/null || break
        sleep 1
      done
      kill "$monitor_pid" 2>/dev/null || true
      wait "$monitor_pid" 2>/dev/null || true
      ("$SELF" --reapply >/dev/null 2>&1) &
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $! > "$NET_MONITOR_PID"
}

install_core(){
  local json url asset candidate tmp found
  json=$(release_json)
  if ! grep -q '"tag_name"' <<<"$json"; then tell_warn "获取版本信息失败或遭遇 API 限流"; return 1; fi
  for candidate in $(asset_candidates); do
    url=$(jq -r --arg s "$candidate.tar.gz" '.assets[]?|select(.name|endswith($s))|.browser_download_url' <<<"$json" | head -1)
    [ -n "$url" ] && { asset=$candidate; break; }
  done
  [ -n "$url" ] || { tell_warn "未找到匹配架构的安装包"; return 1; }
  tmp=$(mktemp -d)
  TMP_FILES="$TMP_FILES $tmp"
  if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 240 "$url" -o "$tmp/core.tar.gz" 2>/dev/null; then
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 240 "$url" -o "$tmp/core.tar.gz" 2>/dev/null; then
      rm -rf "$tmp"; tell_warn "安装包下载失败"; return 1
    fi
  fi
  tar -xzf "$tmp/core.tar.gz" -C "$tmp" || { rm -rf "$tmp"; tell_warn "安装包解压失败"; return 1; }
  found=$(find "$tmp" -type f -name sing-box -perm -u+x | head -1)
  [ -n "$found" ] || { rm -rf "$tmp"; tell_warn "未找到可执行二进制文件"; return 1; }
  "$found" version >/dev/null 2>&1 || { rm -rf "$tmp"; tell_warn "下载的 sing-box 二进制无法运行"; return 1; }
  candidate="$CORE.tmp.$$"
  if ! install -m755 "$found" "$candidate" || ! "$candidate" version >/dev/null 2>&1; then
    rm -f "$candidate"; rm -rf "$tmp"; tell_warn "sing-box 二进制校验失败"; return 1
  fi
  if ! mv -f "$candidate" "$CORE"; then
    rm -f "$candidate"; rm -rf "$tmp"; tell_warn "sing-box 二进制安装失败"; return 1
  fi
  rm -rf "$tmp"
  core_cache_reset
  if ! state_set asset "$asset"; then
    tell_warn "内核已安装，但资产状态写入失败"
    return 1
  fi
  tell_ok "sing-box 内核已安装: $(core_version) [$asset]"
}

write_service(){
  cat >"$SERVICE_UNIT" <<EOF
[Unit]
Description=sing-box
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$SB_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=$CORE -D /var/lib/sing-box -c $CONFIG run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  write_dropin
  systemctl daemon-reload
}

write_dropin(){
  mkdir -p "$DROPIN_DIR"
  cat >"$DROPIN" <<EOF
[Service]
ExecStartPost=-$SHORTCUT --sync
ExecStopPost=-$SHORTCUT --clear-hopping
EOF
}

ssh_ports(){
  {
    [ -n "$SSH_CONNECTION" ] && awk '{print $4}' <<<"$SSH_CONNECTION"
    ss -Hlntp 2>/dev/null | awk '/sshd/{print $4}' | sed 's/.*://'
    sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config 2>/dev/null
    sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config.d/*.conf 2>/dev/null
    if command -v sshd >/dev/null 2>&1; then sshd -T 2>/dev/null | awk '/^port /{print $2}'; fi
  } | grep -E '^[1-9][0-9]*$' | sort -un
}

node_ports(){
  set -- "$NODE_DIR"/*.json
  [ -e "$1" ] && jq -r '.port' "$@" 2>/dev/null | grep -E '^[1-9][0-9]*$'
}

wg_listen_port(){ [ -f "$WG_CONF" ] && jq -r '.listen_port//0' "$WG_CONF" | grep -E '^[1-9][0-9]*$'; }
protected_ports(){ { ssh_ports; node_ports; wg_listen_port; } | grep -E '^[1-9][0-9]*$' | sort -un; }
listening_ports(){ ss -Hln"$1" 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u; }
hopping_node(){
  local file
  for file in "$NODE_DIR"/*.json; do
    [ -n "$(jq -r '.hopping//""' "$file")" ] && { printf '%s' "$file"; return 0; }
  done
  return 1
}

management_ssh_destinations(){
  local file host port ip
  for file in "$PEER_DIR"/*.json; do
    [ -f "$file" ] || continue
    host=$(jq -r '.outbound.server//""' "$file" 2>/dev/null)
    port=$(jq -r '.management_port // 22' "$file" 2>/dev/null)
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || port=22
    [ "$port" -le 65535 ] || port=22
    [ -n "$host" ] || continue
    if printf '%s' "$host" | grep -Eq '^[0-9]+(\.[0-9]+){3}$|^[0-9A-Fa-f:]+$'; then
      printf '%s|%s\n' "$host" "$port"
    else
      while IFS= read -r ip; do
        [ -n "$ip" ] && printf '%s|%s\n' "$ip" "$port"
      done < <(resolve_addresses "$host")
    fi
  done
  if [ -f "$WG_CONF" ]; then
    host=$(jq -r '.peer_host // ""' "$WG_CONF" 2>/dev/null)
    port=$(jq -r '.management_port // 22' "$WG_CONF" 2>/dev/null)
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || port=22
    [ "$port" -le 65535 ] || port=22
    if [ -n "$host" ]; then
      if printf '%s' "$host" | grep -Eq '^[0-9]+(\.[0-9]+){3}$|^[0-9A-Fa-f:]+$'; then
        printf '%s|%s\n' "$host" "$port"
      else
        while IFS= read -r ip; do
          [ -n "$ip" ] && printf '%s|%s\n' "$ip" "$port"
        done < <(resolve_addresses "$host")
      fi
    fi
  fi
}

restore_bypass_snapshot(){
  local old4="$1" old6="$2" oldd4="$3" oldd6="$4" p item ip
  while IFS= read -r p; do [ -n "$p" ] && ip -4 rule del pref "$BYPASS_PREF" sport "$p" lookup main 2>/dev/null || true; done < <(ip -4 rule show pref "$BYPASS_PREF" 2>/dev/null | sed -n 's/.*sport \([0-9]\+\).*/\1/p' | sort -un)
  while IFS= read -r p; do [ -n "$p" ] && ip -6 rule del pref "$BYPASS_PREF" sport "$p" lookup main 2>/dev/null || true; done < <(ip -6 rule show pref "$BYPASS_PREF" 2>/dev/null | sed -n 's/.*sport \([0-9]\+\).*/\1/p' | sort -un)
  while IFS= read -r item; do [ -n "$item" ] || continue; ip=${item%|*}; p=${item##*|}; ip -4 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$p" lookup main 2>/dev/null || true; done < <(ip -4 rule show pref "$((BYPASS_PREF-1))" 2>/dev/null | sed -n 's/.*to \([^ ]*\).*dport \([0-9]\+\).*/\1|\2/p' | sort -u)
  while IFS= read -r item; do [ -n "$item" ] || continue; ip=${item%|*}; p=${item##*|}; ip -6 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$p" lookup main 2>/dev/null || true; done < <(ip -6 rule show pref "$((BYPASS_PREF-1))" 2>/dev/null | sed -n 's/.*to \([^ ]*\).*dport \([0-9]\+\).*/\1|\2/p' | sort -u)
  for p in $old4; do ip -4 rule add pref "$BYPASS_PREF" sport "$p" lookup main 2>/dev/null || true; done
  for p in $old6; do ip -6 rule add pref "$BYPASS_PREF" sport "$p" lookup main 2>/dev/null || true; done
  for item in $oldd4; do ip=${item%|*}; p=${item##*|}; ip -4 rule add pref "$((BYPASS_PREF-1))" to "$ip" dport "$p" lookup main 2>/dev/null || true; done
  for item in $oldd6; do ip=${item%|*}; p=${item##*|}; ip -6 rule add pref "$((BYPASS_PREF-1))" to "$ip" dport "$p" lookup main 2>/dev/null || true; done
}

sync_bypass_rules(){
  local port ip item state_tmp new_ports
  local old4 old6 desired4 desired6 oldd4 oldd6 desiredd4 desiredd6
  local added4="" added6="" removed4="" removed6="" added_d4="" added_d6="" removed_d4="" removed_d6=""
  local changed=0
  new_ports=$(protected_ports)
  old4=$(ip -4 rule show pref "$BYPASS_PREF" 2>/dev/null | sed -n 's/.*sport \([0-9]\+\).*/\1/p' | sort -un)
  old6=$(ip -6 rule show pref "$BYPASS_PREF" 2>/dev/null | sed -n 's/.*sport \([0-9]\+\).*/\1/p' | sort -un)
  desired4=""; desired6=""
  [ -n "$NET_IF_V4" ] && desired4="$new_ports"
  [ -n "$NET_IF_V6" ] && desired6="$new_ports"
  oldd4=$(ip -4 rule show pref "$((BYPASS_PREF-1))" 2>/dev/null | sed -n 's/.*to \([^ ]*\).*dport \([0-9]\+\).*/\1|\2/p' | sort -u)
  oldd6=$(ip -6 rule show pref "$((BYPASS_PREF-1))" 2>/dev/null | sed -n 's/.*to \([^ ]*\).*dport \([0-9]\+\).*/\1|\2/p' | sort -u)
  desiredd4=""; desiredd6=""
  while IFS='|' read -r ip port; do
    [ -n "$ip" ] || continue
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || continue
    [ "$port" -le 65535 ] || continue
    if printf '%s' "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
      desiredd4=$(printf '%s\n%s\n' "$desiredd4" "$ip|$port")
    elif printf '%s' "$ip" | grep -Eq '^[0-9A-Fa-f:]+$'; then
      desiredd6=$(printf '%s\n%s\n' "$desiredd6" "$ip|$port")
    fi
  done < <(management_ssh_destinations)
  desiredd4=$(printf '%s\n' "$desiredd4" | grep -E '^[0-9]+(\.[0-9]+){3}\|[0-9]+$' | sort -u)
  desiredd6=$(printf '%s\n' "$desiredd6" | grep -E '^[0-9A-Fa-f:]+\|[0-9]+$' | sort -u)
  for item in $desiredd4; do
    if ! grep -Fqx "$item" <<<"$oldd4"; then
      ip=${item%|*}; port=${item##*|}
      if ip -4 rule add pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null; then
        added_d4=$(printf '%s\n%s\n' "$added_d4" "$item"); changed=1
      else
        for item in $added_d4; do ip=${item%|*}; port=${item##*|}; ip -4 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1
      fi
    fi
  done
  for item in $desiredd6; do
    if ! grep -Fqx "$item" <<<"$oldd6"; then
      ip=${item%|*}; port=${item##*|}
      if ip -6 rule add pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null; then
        added_d6=$(printf '%s\n%s\n' "$added_d6" "$item"); changed=1
      else
        for item in $added_d4; do ip=${item%|*}; port=${item##*|}; ip -4 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        for item in $added_d6; do ip=${item%|*}; port=${item##*|}; ip -6 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1
      fi
    fi
  done
  for item in $oldd4; do
    if ! grep -Fqx "$item" <<<"$desiredd4"; then
      ip=${item%|*}; port=${item##*|}
      if ip -4 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null; then
        removed_d4=$(printf '%s\n%s\n' "$removed_d4" "$item"); changed=1
      else
        for item in $added_d4; do ip=${item%|*}; port=${item##*|}; ip -4 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        for item in $added_d6; do ip=${item%|*}; port=${item##*|}; ip -6 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        for item in $removed_d4; do ip=${item%|*}; port=${item##*|}; ip -4 rule add pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1
      fi
    fi
  done
  for item in $oldd6; do
    if ! grep -Fqx "$item" <<<"$desiredd6"; then
      ip=${item%|*}; port=${item##*|}
      if ip -6 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null; then
        removed_d6=$(printf '%s\n%s\n' "$removed_d6" "$item"); changed=1
      else
        for item in $added_d4; do ip=${item%|*}; port=${item##*|}; ip -4 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        for item in $added_d6; do ip=${item%|*}; port=${item##*|}; ip -6 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        for item in $removed_d4; do ip=${item%|*}; port=${item##*|}; ip -4 rule add pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        for item in $removed_d6; do ip=${item%|*}; port=${item##*|}; ip -6 rule add pref "$((BYPASS_PREF-1))" to "$ip" dport "$port" lookup main 2>/dev/null || true; done
        restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1
      fi
    fi
  done
  for port in $desired4; do
    if ! grep -qx "$port" <<<"$old4"; then
      if ! ip -4 rule add pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null; then restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1; fi
      added4=$(printf '%s\n%s\n' "$added4" "$port"); changed=1
    fi
  done
  for port in $desired6; do
    if ! grep -qx "$port" <<<"$old6"; then
      if ! ip -6 rule add pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null; then restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1; fi
      added6=$(printf '%s\n%s\n' "$added6" "$port"); changed=1
    fi
  done
  for port in $old4; do
    if ! grep -qx "$port" <<<"$desired4"; then if ! ip -4 rule del pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null; then restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1; fi; removed4=$(printf '%s\n%s\n' "$removed4" "$port"); changed=1; fi
  done
  for port in $old6; do
    if ! grep -qx "$port" <<<"$desired6"; then if ! ip -6 rule del pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null; then restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1; fi; removed6=$(printf '%s\n%s\n' "$removed6" "$port"); changed=1; fi
  done
  if [ "$changed" = 1 ] || jq -e 'has("v4_dests") or has("v6_dests") or has("v4_fwmark") or has("v6_fwmark")' "$BYPASS_STATE" >/dev/null 2>&1; then
    state_tmp=$(mktemp) || { restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1; }
    if ! jq -n --argjson v4 "$(printf '%s\n' "$desired4" | jq -Rsc 'split("\n")|map(select(length>0)|tonumber)')" \
      --argjson v6 "$(printf '%s\n' "$desired6" | jq -Rsc 'split("\n")|map(select(length>0)|tonumber)')" \
      --argjson d4 "$(printf '%s\n' "$desiredd4" | jq -Rsc 'split("\n")|map(select(length>0))')" \
      --argjson d6 "$(printf '%s\n' "$desiredd6" | jq -Rsc 'split("\n")|map(select(length>0))')" \
      '{v4_ports:$v4,v6_ports:$v6,v4_dests:$d4,v6_dests:$d6}' >"$state_tmp" || ! install -m600 "$state_tmp" "$BYPASS_STATE"; then
      rm -f "$state_tmp"
      restore_bypass_snapshot "$old4" "$old6" "$oldd4" "$oldd6"; return 1
    fi
    rm -f "$state_tmp"
  fi
  return 0
}

bypass_rules_present(){
  local p item found=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    found=1
    ip -4 rule show pref "$BYPASS_PREF" 2>/dev/null | grep -qE "sport $p( |$)" || return 1
  done < <(jq -r '.v4_ports[]? // empty' "$BYPASS_STATE" 2>/dev/null)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    found=1
    ip -6 rule show pref "$BYPASS_PREF" 2>/dev/null | grep -qE "sport $p( |$)" || return 1
  done < <(jq -r '.v6_ports[]? // empty' "$BYPASS_STATE" 2>/dev/null)
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    found=1
    ip=${item%|*}; p=${item##*|}
    ip -4 rule show pref "$((BYPASS_PREF-1))" 2>/dev/null | grep -qE "to $ip .*dport $p( |$)" || return 1
  done < <(jq -r '.v4_dests[]? // empty' "$BYPASS_STATE" 2>/dev/null)
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    found=1
    ip=${item%|*}; p=${item##*|}
    ip -6 rule show pref "$((BYPASS_PREF-1))" 2>/dev/null | grep -qE "to $ip .*dport $p( |$)" || return 1
  done < <(jq -r '.v6_dests[]? // empty' "$BYPASS_STATE" 2>/dev/null)
  [ "$found" = 0 ] || return 0
}

clear_bypass_rules(){
  local p item ip
  if [ -f "$BYPASS_STATE" ]; then
    while IFS= read -r p; do [ -n "$p" ] && ip -4 rule del pref "$BYPASS_PREF" sport "$p" lookup main 2>/dev/null || true; done < <(jq -r '.v4_ports[]? // empty' "$BYPASS_STATE" 2>/dev/null)
    while IFS= read -r p; do [ -n "$p" ] && ip -6 rule del pref "$BYPASS_PREF" sport "$p" lookup main 2>/dev/null || true; done < <(jq -r '.v6_ports[]? // empty' "$BYPASS_STATE" 2>/dev/null)
    while IFS= read -r item; do
      [ -n "$item" ] || continue; ip=${item%|*}; p=${item##*|}
      ip -4 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$p" lookup main 2>/dev/null || true
    done < <(jq -r '.v4_dests[]? // empty' "$BYPASS_STATE" 2>/dev/null)
    while IFS= read -r item; do
      [ -n "$item" ] || continue; ip=${item%|*}; p=${item##*|}
      ip -6 rule del pref "$((BYPASS_PREF-1))" to "$ip" dport "$p" lookup main 2>/dev/null || true
    done < <(jq -r '.v6_dests[]? // empty' "$BYPASS_STATE" 2>/dev/null)
  fi
  printf '%s\n' '{"v4_ports":[],"v6_ports":[],"v4_dests":[],"v6_dests":[]}' | json_write "$BYPASS_STATE" >/dev/null 2>&1 || true
}

sync_hopping_rules(){
  local file range port tmp exists=0
  if nft list table inet "$HOP_TABLE" >/dev/null 2>&1; then exists=1; fi
  if ! file=$(hopping_node); then
    [ "$exists" = 0 ] && return 0
    tmp=$(mktemp) || return 1
    printf 'delete table inet %s\n' "$HOP_TABLE" >"$tmp"
    if ! nft -f "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
    return 0
  fi
  range=$(jq -r '.hopping//empty' "$file" 2>/dev/null)
  port=$(jq -r '.port//empty' "$file" 2>/dev/null)
  [ -n "$range" ] && [ -n "$port" ] || return 1
  tmp=$(mktemp) || return 1
  if [ "$exists" = 1 ]; then printf 'delete table inet %s\n' "$HOP_TABLE" >"$tmp"; fi
  {
    printf 'add table inet %s\n' "$HOP_TABLE"
    printf 'add chain inet %s prerouting { type nat hook prerouting priority dstnat; policy accept; }\n' "$HOP_TABLE"
    printf 'add rule inet %s prerouting iifname != "lo" iifname != "%s" iifname != "%s" udp dport %s redirect to :%s\n' "$HOP_TABLE" "$WG_IF" "$TUN_IF" "$range" "$port"
  } >>"$tmp"
  if ! nft -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

clear_hopping_rules(){
  if nft list table inet "$HOP_TABLE" >/dev/null 2>&1; then
    nft delete table inet "$HOP_TABLE" 2>/dev/null || return 1
  fi
  return 0
}

wg_server_nat_apply(){
  local prev4 prev6 file_exists file_content state_json out4 out6
  prev4=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  prev6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)
  if [ ! -f "$WG_NAT_STATE" ]; then
    file_exists=0; file_content=""
    if [ -f /etc/sysctl.d/99-sbm-forward.conf ]; then
      file_exists=1
      file_content=$(cat /etc/sysctl.d/99-sbm-forward.conf 2>/dev/null || true)
    fi
    state_json=$(jq -n --argjson v4 "$prev4" --argjson v6 "$prev6" --argjson exists "$file_exists" --arg content "$file_content" '{prev_ipv4_forward:$v4,prev_ipv6_forward:$v6,applied_ipv4_forward:1,applied_ipv6_forward:1,sysctl_file_exists:$exists,sysctl_file_content:$content}')
    printf '%s\n' "$state_json" | json_write "$WG_NAT_STATE" >/dev/null 2>&1 || return 1
  fi
  if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || ! sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1; then
    wg_server_nat_remove
    return 1
  fi
  if ! printf '%s\n' 'net.ipv4.ip_forward=1' 'net.ipv6.conf.all.forwarding=1' > /etc/sysctl.d/99-sbm-forward.conf; then
    wg_server_nat_remove
    return 1
  fi
  out4=$(default_iface_v4); out6=$(default_iface_v6)
  nft delete table ip sbm_nat 2>/dev/null || true
  nft add table ip sbm_nat 2>/dev/null || { wg_server_nat_remove; return 1; }
  nft add chain ip sbm_nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || { wg_server_nat_remove; return 1; }
  if [ -n "$out4" ]; then nft add rule ip sbm_nat postrouting oifname "$out4" masquerade 2>/dev/null || { wg_server_nat_remove; return 1; }; fi
  nft delete table ip6 sbm_nat 2>/dev/null || true
  nft add table ip6 sbm_nat 2>/dev/null || { wg_server_nat_remove; return 1; }
  nft add chain ip6 sbm_nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || { wg_server_nat_remove; return 1; }
  if [ -n "$out6" ]; then nft add rule ip6 sbm_nat postrouting oifname "$out6" masquerade 2>/dev/null || { wg_server_nat_remove; return 1; }; fi
  return 0
}

wg_server_nat_remove(){
  local prev4 prev6 applied4 applied6 exists content current current4 current6 rc=0
  if nft list table ip sbm_nat >/dev/null 2>&1; then
    nft delete table ip sbm_nat >/dev/null 2>&1 || rc=1
  fi
  if nft list table ip6 sbm_nat >/dev/null 2>&1; then
    nft delete table ip6 sbm_nat >/dev/null 2>&1 || rc=1
  fi
  if [ -f "$WG_NAT_STATE" ]; then
    prev4=$(jq -r '.prev_ipv4_forward // 0' "$WG_NAT_STATE" 2>/dev/null)
    prev6=$(jq -r '.prev_ipv6_forward // 0' "$WG_NAT_STATE" 2>/dev/null)
    applied4=$(jq -r '.applied_ipv4_forward // 1' "$WG_NAT_STATE" 2>/dev/null)
    applied6=$(jq -r '.applied_ipv6_forward // 1' "$WG_NAT_STATE" 2>/dev/null)
    exists=$(jq -r '.sysctl_file_exists // 0' "$WG_NAT_STATE" 2>/dev/null)
    content=$(jq -r '.sysctl_file_content // ""' "$WG_NAT_STATE" 2>/dev/null)
    [ "$prev4" = 0 ] || [ "$prev4" = 1 ] || prev4=0
    [ "$prev6" = 0 ] || [ "$prev6" = 1 ] || prev6=0
    [ "$applied4" = 0 ] || [ "$applied4" = 1 ] || applied4=1
    [ "$applied6" = 0 ] || [ "$applied6" = 1 ] || applied6=1
    current=""; [ -f /etc/sysctl.d/99-sbm-forward.conf ] && current=$(cat /etc/sysctl.d/99-sbm-forward.conf 2>/dev/null || true)
    current4=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "")
    current6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "")
    if [ "$current4" = "$applied4" ]; then
      sysctl -w net.ipv4.ip_forward="$prev4" >/dev/null 2>&1 || rc=1
    fi
    if [ "$current6" = "$applied6" ]; then
      sysctl -w net.ipv6.conf.all.forwarding="$prev6" >/dev/null 2>&1 || rc=1
    fi
    if [ "$current" = $'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1' ]; then
      if [ "$exists" = 1 ]; then
        printf '%s\n' "$content" > /etc/sysctl.d/99-sbm-forward.conf || rc=1
      else
        rm -f /etc/sysctl.d/99-sbm-forward.conf || rc=1
      fi
    fi
    if [ "$rc" = 0 ]; then
      rm -f "$WG_NAT_STATE" || rc=1
    fi
    return "$rc"
  fi
  if [ -f "$WG_CONF" ]; then
    prev4=$(jq -r '.nat_prev_ipv4_forward // empty' "$WG_CONF" 2>/dev/null)
    prev6=$(jq -r '.nat_prev_ipv6_forward // empty' "$WG_CONF" 2>/dev/null)
    [ "$prev4" = 0 ] || [ "$prev4" = 1 ] || prev4=0
    [ "$prev6" = 0 ] || [ "$prev6" = 1 ] || prev6=0
    sysctl -w net.ipv4.ip_forward="$prev4" >/dev/null 2>&1 || rc=1
    sysctl -w net.ipv6.conf.all.forwarding="$prev6" >/dev/null 2>&1 || rc=1
  fi
  return "$rc"
}

acme_options(){
  local domain=$1 body
  body=$(jq -n --arg d "$domain" --arg e "$(state_get email)" --arg dir "$ACME_DIR" \
    '{domain:[$d],email:$e,data_directory:$dir,provider:"letsencrypt"}')
  body=$(jq '.key_type="p256"' <<<"$body")
  case $(state_get challenge) in
    alpn) body=$(jq '.disable_http_challenge=true' <<<"$body") ;;
    dns_cloudflare) body=$(jq --arg t "$(state_get cf_token)" '.dns01_challenge={provider:"cloudflare",api_token:$t}' <<<"$body") ;;
    dns_alidns) body=$(jq --arg k "$(state_get ali_key)" --arg s "$(state_get ali_secret)" '.dns01_challenge={provider:"alidns",access_key_id:$k,access_key_secret:$s}' <<<"$body") ;;
    dns_acmedns) body=$(jq --arg u "$(state_get acmedns_user)" --arg p "$(state_get acmedns_pass)" --arg s "$(state_get acmedns_sub)" --arg r "$(state_get acmedns_url)" '.dns01_challenge={provider:"acmedns",username:$u,password:$p,subdomain:$s,server_url:$r}' <<<"$body") ;;
    *) body=$(jq '.disable_tls_alpn_challenge=true' <<<"$body") ;;
  esac
  printf '%s' "$body"
}

wg_endpoint_route_excludes(){
  local host=$1 raw a family iface
  local v4_iface="$NET_IF_V4" v6_iface="$NET_IF_V6"
  wg_endpoint_valid_ip(){
    local x=$1
    [[ "$x" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && {
      local o; IFS=. read -r -a o <<<"$x"
      [ "${o[0]}" -le 255 ] && [ "${o[1]}" -le 255 ] && [ "${o[2]}" -le 255 ] && [ "${o[3]}" -le 255 ]
      return
    }
    [[ "$x" == *:* ]] && [[ "$x" =~ ^[0-9A-Fa-f:]+$ ]]
  }
  wg_route_ok(){
    local x=$1
    if [[ "$x" == *:* ]]; then
      [ -n "$v6_iface" ] || return 1
      ip -6 addr show 2>/dev/null | awk '{print $2}' | cut -d/ -f1 | grep -Fxq "$x" && return 1
      ip -6 route get "$x" 2>/dev/null | grep -Eq "(^| )dev $v6_iface( |$)" || return 1
      ip -6 route get "$x" 2>/dev/null | grep -Eq 'dev (sbmwg|sbmtun)( |$)' && return 1
    else
      [ -n "$v4_iface" ] || return 1
      ip -4 addr show 2>/dev/null | awk '{print $2}' | cut -d/ -f1 | grep -Fxq "$x" && return 1
      ip -4 route get "$x" 2>/dev/null | grep -Eq "(^| )dev $v4_iface( |$)" || return 1
      ip -4 route get "$x" 2>/dev/null | grep -Eq 'dev (sbmwg|sbmtun)( |$)' && return 1
    fi
    return 0
  }
  if wg_endpoint_valid_ip "$host"; then
    wg_route_ok "$host" || return 1
    [[ "$host" == *:* ]] && printf '%s/128\n' "$host" || printf '%s/32\n' "$host"
    return 0
  fi
  [ -n "$host" ] || return 1
  case "$NET_STACK" in
    v4)
      while IFS= read -r a; do
        [[ "$a" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
        wg_route_ok "$a" && printf '%s/32\n' "$a"
      done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
      ;;
    v6)
      while IFS= read -r a; do
        [[ "$a" =~ ^[0-9A-Fa-f:]+$ ]] || continue
        wg_route_ok "$a" && printf '%s/128\n' "$a"
      done < <(getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
      ;;
    both)
      while IFS= read -r a; do
        [[ "$a" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
        wg_route_ok "$a" && printf '%s/32\n' "$a"
      done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
      while IFS= read -r a; do
        [[ "$a" =~ ^[0-9A-Fa-f:]+$ ]] || continue
        wg_route_ok "$a" && printf '%s/128\n' "$a"
      done < <(getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
      ;;
    *) return 1 ;;
  esac
}


build_config(){
  local selected domain probe_target
  local inbounds outbounds endpoints rules dns_block providers
  local final use_tun peer_host icmp_out
  local dns_strategy bootstrap_dns bootstrap_server
  local tun_addresses tun_dns_addresses
  local listen_addr
  local acme_json
  local probe_enabled=0
  local wg_role wg_endpoint
  local node_files=()
  local selected_outbound probe_outbound
  local bindv6only=0
  local mgmt_bind_v4 mgmt_bind_v6

  selected=$(state_get exit)
  domain=$(state_get domain)
  probe_target=${WATCHDOG_PROBE:-}

  final="direct"
  use_tun=0
  peer_host=""
  endpoints='[]'
  providers='[]'
  inbounds='[]'
  tun_addresses='[]'
  tun_dns_addresses='[]'
  wg_exclude_addresses='[]'

  mgmt_bind_v4=""
  mgmt_bind_v6=""
  [ -n "$NET_IF_V4" ] && mgmt_bind_v4=$(ip -4 addr show dev "$NET_IF_V4" scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
  [ -n "$NET_IF_V6" ] && mgmt_bind_v6=$(ip -6 addr show dev "$NET_IF_V6" scope global 2>/dev/null | awk '/inet6 /{print $2}' | grep -v '^fe80:' | cut -d/ -f1 | head -1)

  if [ -r /proc/sys/net/ipv6/bindv6only ]; then
    bindv6only=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null)
    case "$bindv6only" in
      0|1) ;;
      *) bindv6only=0 ;;
    esac
  fi

  case "$NET_STACK" in
    v6)
      dns_strategy="ipv6_only"
      bootstrap_dns="dns-bootstrap-v6"
      bootstrap_server="2606:4700:4700::1111"
      listen_addr="::"
      tun_addresses='["fdfe:dcba:9876::1/126"]'
      tun_dns_addresses='["fdfe:dcba:9876::2"]'
      ;;
    both)
      if [ "${IPV6_OK:-0}" = "1" ]; then
        dns_strategy="prefer_ipv4"
        bootstrap_dns="dns-bootstrap-v4"
        bootstrap_server="1.1.1.1"
        tun_addresses='["172.19.0.1/30","fdfe:dcba:9876::1/126"]'
        tun_dns_addresses='["172.19.0.2","fdfe:dcba:9876::2"]'
        if [ "$bindv6only" = "1" ]; then
          listen_addr="0.0.0.0"
        else
          listen_addr="::"
        fi
      else
        dns_strategy="ipv4_only"
        bootstrap_dns="dns-bootstrap-v4"
        bootstrap_server="1.1.1.1"
        listen_addr="0.0.0.0"
        tun_addresses='["172.19.0.1/30"]'
        tun_dns_addresses='["172.19.0.2"]'
      fi
      ;;
    *)
      dns_strategy="ipv4_only"
      bootstrap_dns="dns-bootstrap-v4"
      bootstrap_server="1.1.1.1"
      listen_addr="0.0.0.0"
      tun_addresses='["172.19.0.1/30"]'
      tun_dns_addresses='["172.19.0.2"]'
      ;;
  esac

  if compgen -G "$NODE_DIR/*.json" > /dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      node_files+=("$f")
    done < <(
      find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' -print0 | sort -z
    )
  fi

  if [ ${#node_files[@]} -gt 0 ]; then
    if [ -n "$domain" ]; then
      acme_json=$(acme_options "$domain") || return 1
      jq -e . >/dev/null 2>&1 <<<"$acme_json" || return 1
      providers=$(
        jq -n \
          --arg tag "$CERT_TAG" \
          --argjson options "$acme_json" \
          '[$options + {type:"acme",tag:$tag}]'
      ) || return 1
    fi

    inbounds=$(
      jq -s \
        --arg domain "$domain" \
        --arg cert "$CERT_TAG" \
        --arg listen "$listen_addr" \
        '
        [
          .[] |
          if .kind=="hysteria2" and
             ((.inbound.up_mbps//0)>0 or (.inbound.down_mbps//0)>0)
          then
            del(.inbound.bbr_profile)
          else
            .
          end |
          .inbound as $in |
          (
            $in
            | .listen=$listen
            | if .type=="hysteria2" and
                 ((.up_mbps//0)>0 or (.down_mbps//0)>0)
              then
                del(.bbr_profile)
              else
                .
              end
          ) as $inbound |
          if .tls_mode=="acme" then
            $inbound * {
              tls: (
                {enabled:true}
                + (if $domain!="" then {server_name:$domain} else {} end)
                + (if .alpn then {alpn:.alpn} else {} end)
                + {certificate_provider:$cert}
              )
            }
          else
            $inbound
          end
        ]
        ' "${node_files[@]}"
    ) || return 1
  fi

  outbounds='[
    {
      "type":"direct",
      "tag":"direct"
    }
  ]'

  if [ -f "$WG_CONF" ] &&
     [ "$(jq -r '.enabled//false' "$WG_CONF" 2>/dev/null)" = "true" ]; then

    wg_role=$(jq -r '.role//""' "$WG_CONF" 2>/dev/null)
    wg_endpoint=$(jq -r 'if .endpoint then "yes" else "no" end' "$WG_CONF" 2>/dev/null)

    if [ "$wg_role" = "client" ]; then
      if [ "$selected" = "direct" ] || [ "$selected" = "wireguard" ]; then
        if [ "$wg_endpoint" = "yes" ]; then

          endpoints=$(
            jq '
              if .endpoint then [.endpoint] else [] end
            ' "$WG_CONF"
          ) || return 1

          peer_host=$(jq -r '.peer_host // ""' "$WG_CONF") || return 1
          if [ -n "$peer_host" ]; then
            wg_exclude_addresses=$(wg_endpoint_route_excludes "$peer_host" | sort -u | jq -Rsc 'split("\n")|map(select(length>0))') || {
              tell_warn "WireGuard 服务端地址解析或物理路由检查失败，保留当前运行配置"
              return 1
            }
            [ "$(jq 'length' <<<"$wg_exclude_addresses")" -gt 0 ] || {
              tell_warn "WireGuard 服务端没有可用的物理路由地址"
              return 1
            }
          fi
          final="wireguard"
          use_tun=1

          if [ -n "$peer_host" ] &&
             ! printf '%s' "$peer_host" |
             grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^[0-9A-Fa-f:]+$'; then

            endpoints=$(
              jq \
                --arg resolver "$bootstrap_dns" \
                '
                map(
                  if .type=="wireguard"
                  then .domain_resolver=$resolver
                  else .
                  end
                )
                ' <<<"$endpoints"
            ) || return 1
          fi

        else
          final="direct"
          use_tun=0
          peer_host=""
        fi
      fi

    elif [ "$wg_role" = "server" ]; then
      if [ "$wg_endpoint" = "yes" ]; then
        endpoints=$(
          jq '
            if .endpoint then [.endpoint] else [] end
          ' "$WG_CONF"
        ) || return 1
      fi
    fi
  fi

  if [ "$selected" != "direct" ] &&
     [ "$selected" != "wireguard" ]; then

    if [ -f "$PEER_DIR/$selected.json" ]; then

      selected_outbound=$(
        jq -c \
          --arg tag "$selected" \
          --arg resolver "$bootstrap_dns" \
          '
          .outbound
          | .tag=$tag
          | .domain_resolver=$resolver
          ' "$PEER_DIR/$selected.json"
      ) || return 1

      if [ -z "$selected_outbound" ] ||
         [ "$selected_outbound" = "null" ]; then

        tell_warn "出口节点 $selected 配置无效，回退直连"
        final="direct"
        use_tun=0
        peer_host=""

      else

        outbounds=$(
          jq \
            --argjson outbound "$selected_outbound" \
            '. + [$outbound]'
            <<<"$outbounds"
        ) || return 1

        final="$selected"
        use_tun=1

        peer_host=$(
          jq -r '.outbound.server//""' "$PEER_DIR/$selected.json"
        ) || return 1
      fi

    else

      tell_warn "出口节点 $selected 文件不存在，回退直连"
      final="direct"
      use_tun=0
      peer_host=""
    fi
  fi

  if [ -n "$probe_target" ] &&
     [ "$probe_target" != "direct" ] &&
     [ "$probe_target" != "wireguard" ]; then

    if [ "$probe_target" = "$final" ]; then

      probe_enabled=1

    elif [ -f "$PEER_DIR/$probe_target.json" ]; then

      probe_outbound=$(
        jq -c \
          --arg tag "$probe_target" \
          --arg resolver "$bootstrap_dns" \
          '
          .outbound
          | .tag=$tag
          | .domain_resolver=$resolver
          ' "$PEER_DIR/$probe_target.json"
      ) || return 1

      if [ -n "$probe_outbound" ] &&
         [ "$probe_outbound" != "null" ]; then

        outbounds=$(
          jq \
            --argjson outbound "$probe_outbound" \
            '. + [$outbound]'
            <<<"$outbounds"
        ) || return 1

        probe_enabled=1
      fi
    fi
  fi

  outbounds=$(
    jq -c \
      --arg v4 "$mgmt_bind_v4" \
      --arg v6 "$mgmt_bind_v6" \
      'map(. | if $v4 != "" then .inet4_bind_address=$v4 else . end | if $v6 != "" then .inet6_bind_address=$v6 else . end)' \
      <<<"$outbounds"
  ) || return 1

  endpoints=$(
    jq -c \
      --arg v4 "$mgmt_bind_v4" \
      --arg v6 "$mgmt_bind_v6" \
      'map(. | if $v4 != "" then .inet4_bind_address=$v4 else . end | if $v6 != "" then .inet6_bind_address=$v6 else . end)' \
      <<<"$endpoints"
  ) || return 1

  if [ "$use_tun" = "1" ]; then
    local _ssh_bypass="" _ssh_bypass_json=""
    [ -n "$NET_IF_V4" ] && _ssh_bypass=$(ip -4 addr show dev "$NET_IF_V4" scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
    [ -n "$NET_IF_V6" ] && _ssh_bypass=$(printf '%s\n%s\n' "$_ssh_bypass" "$(ip -6 addr show dev "$NET_IF_V6" scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | grep -v '^fe80:')")
    if [ -n "$_ssh_bypass" ]; then
      _ssh_bypass_json=$(printf '%s\n' "$_ssh_bypass" | awk 'NF' | while read -r _a; do
        if [[ "$_a" == *:* ]]; then printf '%s/128\n' "$_a"; else printf '%s/32\n' "$_a"; fi
      done | sort -u | jq -Rsc 'split("\n")|map(select(length>0))')
      wg_exclude_addresses=$(jq -n --argjson a "$wg_exclude_addresses" --argjson b "$_ssh_bypass_json" '$a + $b | unique')
    fi
  fi

  if [ "$use_tun" = "1" ]; then

    inbounds=$(
      jq \
        --arg name "$TUN_IF" \
        --argjson address "$tun_addresses" \
        --argjson dns_address "$tun_dns_addresses" \
        --argjson exclude "$wg_exclude_addresses" \
        --argjson list "$inbounds" \
        '
        [
          {
            type:"tun",
            tag:"tun-in",
            interface_name:$name,
            address:$address,
            auto_route:true,
            strict_route:true,
            dns_mode:"hijack",
            dns_address:$dns_address,
            route_exclude_address:$exclude
          }
        ] + $list
        '
    ) || return 1
  fi

  if [ "$final" = "wireguard" ]; then
    icmp_out="wireguard"
  else
    icmp_out="direct"
  fi

  rules=$(
    jq -n \
      --arg icmp "$icmp_out" \
      '
      [
        {action:"sniff"},
        {protocol:"dns",action:"hijack-dns"},
        {ip_is_private:true,action:"route",outbound:"direct"},
        {network:"icmp",action:"route",outbound:$icmp}
      ]
      '
  ) || return 1

  if [ "$probe_enabled" = "1" ]; then

    inbounds=$(
      jq \
        --argjson list "$inbounds" \
        '
        [
          {
            type:"mixed",
            tag:"probe-in",
            listen:"127.0.0.1",
            listen_port:2081
          }
        ] + $list
        '
    ) || return 1

    rules=$(
      jq \
        --argjson list "$rules" \
        --arg target "$probe_target" \
        '
        [
          {
            inbound:["probe-in"],
            action:"route",
            outbound:$target
          }
        ] + $list
        '
    ) || return 1
  fi

  dns_block=$(
    jq -n \
      --arg strategy "$dns_strategy" \
      --arg bootstrap "$bootstrap_dns" \
      --arg bootstrap_server "$bootstrap_server" \
      --arg final "$final" \
      --arg v4 "$mgmt_bind_v4" \
      --arg v6 "$mgmt_bind_v6" \
      '
      {
        servers:[
          {
            type:"https",
            tag:$bootstrap,
            server:$bootstrap_server,
            server_port:443,
            path:"/dns-query",
            tls:{
              server_name:"cloudflare-dns.com"
            }
          },
          {
            type:"https",
            tag:"dns-remote",
            server:"cloudflare-dns.com",
            server_port:443,
            path:"/dns-query",
            tls:{
              server_name:"cloudflare-dns.com"
            },
            domain_resolver:{
              server:$bootstrap,
              strategy:$strategy
            }
          }
        ],
        strategy:$strategy,
        final:"dns-remote"
      }
      |
      .servers |= map(
        .
        | if $v4 != "" then .inet4_bind_address=$v4 else . end
        | if $v6 != "" then .inet6_bind_address=$v6 else . end
      )
      | if $final!="direct"
      then
        .servers |= map(
          if .tag=="dns-remote"
          then .detour=$final
          else .
          end
        )
      else
        .
      end
      '
  ) || return 1

  jq -n \
    --argjson inbounds "$inbounds" \
    --argjson outbounds "$outbounds" \
    --argjson endpoints "$endpoints" \
    --argjson rules "$rules" \
    --argjson dns "$dns_block" \
    --argjson providers "$providers" \
    --arg final "$final" \
    --arg bootstrap "$bootstrap_dns" \
    --argjson use_tun "$use_tun" \
    '
    {
      log:{
        level:"warn",
        timestamp:true
      },
      dns:$dns,
      inbounds:$inbounds,
      outbounds:$outbounds,
      route:{
        rules:$rules,
        final:$final,
        default_domain_resolver:$bootstrap
      }
    }
    |
    if $use_tun==1
    then
      .route.auto_detect_interface=true
    else
      .
    end
    |
    if ($endpoints|length)>0
    then
      .endpoints=$endpoints
    else
      .
    end
    |
    if ($providers|length)>0
    then
      .certificate_providers=$providers
    else
      .
    end
    '
}

restore_config_runtime(){
  local prev_conf=$1 prev_active=${2:-0} prev_exists=${3:-0}
  if [ "$prev_exists" = "1" ] && [ -n "$prev_conf" ] && [ -s "$prev_conf" ]; then
    install -m600 "$prev_conf" "$CONFIG" || return 1
  else
    rm -f "$CONFIG" || return 1
  fi
  if [ "$prev_active" = "1" ]; then
    timeout 15 systemctl reload sing-box >/dev/null 2>&1 || return 1
    systemctl is-active --quiet sing-box || return 1
  else
    timeout 15 systemctl stop sing-box >/dev/null 2>&1 || return 1
    systemctl is-active --quiet sing-box && return 1
  fi
  sync_bypass_rules || return 1
  sync_hopping_rules || return 1
  return 0
}

rollback_config_failure(){
  local prev_conf=$1 prev_active=$2 prev_exists=$3 message=$4
  tell_warn "$message"
  if ! restore_config_runtime "$prev_conf" "$prev_active" "$prev_exists"; then
    tell_warn "配置回滚失败，当前服务状态需要人工检查"
    return 1
  fi
  return 0
}

_apply_config_locked(){
  local tmp error line prev_conf="" prev_active=0 prev_exists=0
  tmp=$(mktemp) || { tell_warn "无法创建临时配置"; return 1; }
  TMP_FILES="$TMP_FILES $tmp"
  if [ -f "$CONFIG" ]; then
    prev_exists=1
    prev_conf=$(mktemp) || { rm -f "$tmp"; tell_warn "无法备份旧配置"; return 1; }
    TMP_FILES="$TMP_FILES $prev_conf"
    cp "$CONFIG" "$prev_conf" || { rm -f "$tmp" "$prev_conf"; tell_warn "无法备份旧配置"; return 1; }
  fi
  if systemctl is-active --quiet sing-box; then prev_active=1; fi
  if ! build_config >"$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp"; tell_warn "配置生成失败"; return 1
  fi
  if ! error=$("$CORE" check -c "$tmp" 2>&1); then
    tell_warn "配置校验未通过:"
    while IFS= read -r line; do tell "    $line"; done <<<"$(head -4 <<<"$error")"
    rm -f "$tmp"; return 1
  fi
  if ! install -m600 "$tmp" "$CONFIG"; then
    rm -f "$tmp"; tell_warn "新配置写入失败"; return 1
  fi
  rm -f "$tmp"
  if [ "$prev_active" = "1" ]; then
    if ! timeout 15 systemctl reload sing-box >/dev/null 2>&1 || ! systemctl is-active --quiet sing-box; then
      rollback_config_failure "$prev_conf" "$prev_active" "$prev_exists" "sing-box 重载失败，正在回滚配置"
      return 1
    fi
  else
    if systemctl is-active --quiet sing-box; then
      rollback_config_failure "$prev_conf" "$prev_active" "$prev_exists" "服务状态异常，正在回滚配置"
      return 1
    fi
  fi
  if ! sync_bypass_rules || ! sync_hopping_rules; then
    rollback_config_failure "$prev_conf" "$prev_active" "$prev_exists" "网络规则同步失败，正在回滚配置"
    return 1
  fi
  if [ "$prev_active" = "1" ] && ! systemctl is-active --quiet sing-box; then
    rollback_config_failure "$prev_conf" "$prev_active" "$prev_exists" "sing-box 状态异常，正在回滚配置"
    return 1
  fi
  bypass_rules_present || tell_warn "系统内核不支持管理面策略路由规则，管理连接可能受影响"
  return 0
}

apply_config(){
  local lock_fd
  exec {lock_fd}>"$REAPPLY_LOCK" || return 1
  flock -w 10 "$lock_fd" || { eval "exec ${lock_fd}>&-"; return 1; }
  _apply_config_locked
  local rc=$?
  flock -u "$lock_fd" 2>/dev/null || true
  eval "exec ${lock_fd}>&-"
  return "$rc"
}

apply_config_quiet(){ apply_config >/dev/null 2>&1; }

stop_watchdog(){
  local rc=0
  if systemctl is-active --quiet sbm-watchdog.service 2>/dev/null; then
    timeout 15 systemctl stop sbm-watchdog.service >/dev/null 2>&1 || rc=1
  fi
  if systemctl is-active --quiet sbm-watchdog.service 2>/dev/null; then
    rc=1
  fi
  systemctl reset-failed 'sbm-watchdog*' >/dev/null 2>&1 || true
  return "$rc"
}

restart_watchdog(){
  local wd_service="/etc/systemd/system/sbm-watchdog.service"
  if [ ! -f "$wd_service" ]; then
    cat >"$wd_service" <<EOF
[Unit]
Description=SBM Watchdog Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $SELF --watchdog
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
  systemctl enable sbm-watchdog.service >/dev/null 2>&1
  if ! systemctl restart sbm-watchdog.service >/dev/null 2>&1; then
    systemctl start sbm-watchdog.service >/dev/null 2>&1 || tell_warn "看门狗启动失败"
  fi
}

watchdog_needed(){ local exit_node; exit_node=$(state_get exit); [ "$exit_node" != "direct" ]; }
sync_watchdog(){ if watchdog_needed; then restart_watchdog; else stop_watchdog; fi; }

run_watchdog(){
  trap 'exit 0' TERM INT
  local fail_count=0 probe2="http://captive.apple.com/hotspot-detect.html"
  local current="" lock_fd
  local i=0
  while [ "$i" -lt 60 ] && [ ! -d "/sys/class/net/$TUN_IF" ] && systemctl is-active --quiet sing-box; do sleep 1; i=$((i+1)); done
  sleep 3
  while :; do
    current=$(state_get exit)
    if [ "$current" = "direct" ]; then
      if curl -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL" || curl -s -o /dev/null --connect-timeout 4 -m 6 "$probe2"; then
        fail_count=0
      else
        fail_count=$((fail_count+1))
      fi
    else
      if curl -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL"; then
        fail_count=0
      else
        fail_count=$((fail_count+1))
        if [ "$fail_count" -ge 3 ]; then
          fail_count=0
          exec {lock_fd}>"$REAPPLY_LOCK" || { sleep 30; continue; }
          if flock -w 5 "$lock_fd"; then
            current=$(state_get exit)
            if [ "$current" != "direct" ]; then
              _apply_config_locked >/dev/null 2>&1 || true
            fi
            flock -u "$lock_fd" 2>/dev/null || true
          fi
          eval "exec ${lock_fd}>&-"
        fi
      fi
    fi
    sleep 120
  done
}

validate_port(){
  local port=$1 proto=$2 allow=${3:-}
  [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { tell_warn "端口格式无效"; return 1; }
  [ "$port" = 80 ] && { tell_warn "端口 80 已保留给证书签发"; return 1; }
  [ "$port" = 443 ] && [ "$(state_get challenge)" = "alpn" ] && { tell_warn "端口 443 已保留给 ALPN 证书签发"; return 1; }
  [ "$port" = "$allow" ] && return 0
  grep -qx "$port" <<<"$(protected_ports)" && { tell_warn "已被节点或 SSH 占用"; return 1; }
  grep -qx "$port" <<<"$(listening_ports "$proto")" && { tell_warn "端口被占用"; return 1; }
  return 0
}

prompt_port(){
  local proto=$1 current=$2 port def_port
  while :; do
    def_port=${current:-$(random_port)}
    port=$(prompt "监听端口" "$def_port")
    validate_port "$port" "$proto" "$current" && { printf '%s' "$port"; return 0; }
  done
}

validate_range(){
  local range=$1 low high port
  [[ $range =~ ^[0-9]+-[0-9]+$ ]] || { tell_warn "格式应为 20000-30000"; return 1; }
  low=${range%-*}; high=${range#*-}
  [ "$low" -ge 1 ] && [ "$high" -le 65535 ] && [ "$low" -lt "$high" ] || { tell_warn "端口范围不合法"; return 1; }
  for port in $(listening_ports u) $(protected_ports) 80 443; do
    [ "$port" -ge "$low" ] && [ "$port" -le "$high" ] && { tell_warn "范围内包含系统保留端口: $port"; return 1; }
  done
  return 0
}

probe_handshake_target(){
  local target=$1 result
  command -v openssl >/dev/null || { tell_warn "openssl 未安装，无法验证"; return 1; }
  result=$(echo | timeout 10 openssl s_client -connect "$target:443" -servername "$target" -alpn h2 -tls1_3 2>/dev/null)
  grep -q "TLSv1.3" <<<"$result" || { tell_warn "不支持 TLS 1.3 协议"; return 1; }
  grep -q "ALPN protocol: h2" <<<"$result" || { tell_warn "不支持 HTTP/2 协议"; return 1; }
  grep -qi "X25519" <<<"$result" || { tell_warn "未检测到 X25519 特性"; return 1; }
  tell_ok "验证通过"; return 0
}

validate_domain(){
  local domain=$1 resolved ipv4 ipv6
  resolved=$(resolve_addresses "$domain")
  [ -n "$resolved" ] || { tell_warn "无法解析该域名"; return 1; }
  ipv4=$(local_ipv4); ipv6=$(local_ipv6)
  if ! { [ -n "$ipv4" ] && grep -qx "$ipv4" <<<"$resolved"; } && ! { [ -n "$ipv6" ] && grep -qx "$ipv6" <<<"$resolved"; }; then
    tell_warn "域名解析地址与本地 IP 不匹配"; return 1
  fi
  case $(state_get challenge) in
    http) grep -qx 80 <<<"$(listening_ports t)" && { tell_warn "本机 80 端口已被占用"; return 1; } ;;
    alpn) grep -qx 443 <<<"$(listening_ports t)" && { tell_warn "本机 443 端口已被占用"; return 1; } ;;
  esac
  tell_ok "解析记录正常"; return 0
}

setup_certificate(){
  local suggest=${1:-} domain email mode
  local old_domain old_email old_challenge old_cf old_ali_key old_ali_secret old_ad_url old_ad_user old_ad_pass old_ad_sub
  old_domain=$(state_get domain); old_email=$(state_get email); old_challenge=$(state_get challenge)
  old_cf=$(state_get cf_token); old_ali_key=$(state_get ali_key); old_ali_secret=$(state_get ali_secret)
  old_ad_url=$(state_get acmedns_url); old_ad_user=$(state_get acmedns_user); old_ad_pass=$(state_get acmedns_pass); old_ad_sub=$(state_get acmedns_sub)
  [ -n "$old_domain" ] && [ -n "$old_email" ] && return 0
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; return 1; }
  printf '\n  %b该协议需要绑定域名并签发证书%b\n' "${YELLOW}" "${PLAIN}"
  if [ -n "$suggest" ]; then
    domain="$suggest"; printf '  %b已指定域名: %s%b\n' "${GREEN}" "$domain" "${PLAIN}"
  else domain=$(prompt "输入域名"); [ -n "$domain" ] || return 1; fi
  email=$(prompt "ACME 通知邮箱" "admin@$domain"); [ -n "$email" ] || return 1
  printf '\n  %b选择域名证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
  echo "  1. HTTP-01      (推荐，需放行 80 端口)"
  echo "  2. TLS-ALPN-01  (推荐，需放行 443 端口)"
  echo "  3. DNS-01       (Cloudflare API)"
  echo "  4. DNS-01       (阿里云 DNS API)"
  echo "  5. DNS-01       (ACME-DNS API)"
  while :; do
    case $(prompt "请选择方式" 1) in
      1) mode=http; break ;;
      2) mode=alpn; break ;;
      3) mode=dns_cloudflare
         if ! state_set cf_token "$(prompt 'Cloudflare API Token')"; then tell_warn "Cloudflare API Token 写入失败"; return 1; fi
         break ;;
      4) mode=dns_alidns
         if ! state_set ali_key "$(prompt 'AccessKeyId')" || ! state_set ali_secret "$(prompt 'AccessKeySecret')"; then
           tell_warn "阿里云 DNS 凭据写入失败"
           state_set ali_key "$old_ali_key" || true; state_set ali_secret "$old_ali_secret" || true
           return 1
         fi
         break ;;
      5) mode=dns_acmedns
         if ! state_set acmedns_url "$(prompt 'server_url')" || ! state_set acmedns_user "$(prompt 'username')" || ! state_set acmedns_pass "$(prompt 'password')" || ! state_set acmedns_sub "$(prompt 'subdomain')"; then
           tell_warn "ACME-DNS 凭据写入失败"
           state_set acmedns_url "$old_ad_url" || true; state_set acmedns_user "$old_ad_user" || true
           state_set acmedns_pass "$old_ad_pass" || true; state_set acmedns_sub "$old_ad_sub" || true
           return 1
         fi
         break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
  if ! state_set challenge "$mode" || ! state_set domain "$domain" || ! state_set email "$email"; then
    tell_warn "证书状态写入失败，正在回滚"
    state_set domain "$old_domain" || true; state_set email "$old_email" || true; state_set challenge "$old_challenge" || true
    state_set cf_token "$old_cf" || true; state_set ali_key "$old_ali_key" || true; state_set ali_secret "$old_ali_secret" || true
    state_set acmedns_url "$old_ad_url" || true; state_set acmedns_user "$old_ad_user" || true; state_set acmedns_pass "$old_ad_pass" || true; state_set acmedns_sub "$old_ad_sub" || true
    return 1
  fi
  if ! validate_domain "$domain"; then
    prompt_yes "验证存在异常，是否强制继续" || {
      state_set domain "$old_domain" || true; state_set email "$old_email" || true; state_set challenge "$old_challenge" || true
      state_set cf_token "$old_cf" || true; state_set ali_key "$old_ali_key" || true; state_set ali_secret "$old_ali_secret" || true
      state_set acmedns_url "$old_ad_url" || true; state_set acmedns_user "$old_ad_user" || true; state_set acmedns_pass "$old_ad_pass" || true; state_set acmedns_sub "$old_ad_sub" || true
      return 1
    }
  fi
  return 0
}

unique_tag(){
  local base tag index=1
  base=$(slugify "$1"); [ -n "$base" ] || base=node
  tag="$2$base"
  while [ -e "$3/$tag.json" ]; do tag="$2$base$index"; index=$((index+1)); done
  printf '%s' "$tag"
}

save_node(){
  local file=$1 content=$2
  json_save "$file" "$content" || { tell_warn "数据写入失败"; wait_key; return 1; }
  if apply_config; then tell_ok "协议应用成功"; tell_gap; render_share_uri "$file"
  else rm -f "$file"; apply_config_quiet; tell_warn "配置应用失败，已回滚"; fi
  wait_key
}

create_vless_reality(){
  local name port uuid target keypair private public short_id tag body default_sid
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "VLESS-Reality")
  port=$(prompt_port t "")
  uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
  while :; do
    target=$(prompt "握手目标域名" "www.microsoft.com")
    probe_handshake_target "$target" && break
    prompt_yes "是否强制使用此域名" && break
  done
  keypair=$("$CORE" generate reality-keypair)
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] || { tell_warn "密钥生成失败"; wait_key; return; }
  default_sid=$(openssl rand -hex 4 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c8)
  while :; do
    short_id=$(prompt "short_id (留空自动生成 8位十六进制)" "$default_sid")
    [ -z "$short_id" ] && short_id="$default_sid"
    if [[ $short_id =~ ^[0-9a-fA-F]{1,8}$ ]]; then break; fi
    tell_warn "short_id 必须为 1-8 位十六进制字符"
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" \
        --arg target "$target" --arg private "$private" --arg public "$public" --arg sid "$short_id" '
   {tag:$tag,name:$name,kind:"vless-reality",port:$port,proto:"t",hopping:"",
    tls_mode:"reality",alpn:null,
    meta:{uuid:$uuid,target:$target,public_key:$public,short_id:$sid},
    inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,
      users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],
      tls:{enabled:true,server_name:$target,
        reality:{enabled:true,handshake:{server:$target,server_port:443},
                 private_key:$private,short_id:[$sid]}}}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vless_tls(){
  local name port uuid tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "VLESS-TLS")
  setup_certificate || return
  port=$(prompt_port t "")
  uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" '
   {tag:$tag,name:$name,kind:"vless-tls",port:$port,proto:"t",hopping:"",
    tls_mode:"acme",alpn:null,
    meta:{uuid:$uuid},
    inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,
      users:[{uuid:$uuid,flow:"xtls-rprx-vision"}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_hysteria2(){
  local name port password hopping tag body up_mbps down_mbps obfs_type obfs_password bbr_profile
  local min_pkt max_pkt cc_choice
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Hysteria2")
  setup_certificate || return
  port=$(prompt_port u "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  bbr_profile=""; up_mbps=0; down_mbps=0
  tell "  拥塞控制:"
  tell "    1. BBR conservative"
  tell "    2. BBR standard"
  tell "    3. BBR aggressive"
  tell "    4. Brutal (需手动设置带宽)"
  while :; do
    cc_choice=$(prompt "请选择拥塞控制" 2)
    case "$cc_choice" in
      1) bbr_profile="conservative"; up_mbps=0; down_mbps=0; break ;;
      2) bbr_profile="standard";     up_mbps=0; down_mbps=0; break ;;
      3) bbr_profile="aggressive";   up_mbps=0; down_mbps=0; break ;;
      4)
        bbr_profile=""
        while :; do
          up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" "0")
          [[ $up_mbps =~ ^[0-9]+$ ]] || { tell_warn "输入无效"; continue; }
          down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "0")
          [[ $down_mbps =~ ^[0-9]+$ ]] || { tell_warn "输入无效"; continue; }
          if [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ]; then break; fi
          tell_warn "Brutal 模式至少需要设置一个方向的带宽"
        done
        break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
  obfs_type=""; obfs_password=""; min_pkt=""; max_pkt=""
  if prompt_yes "是否配置协议混淆"; then
    tell "  1. Salamander"; tell "  2. Gecko"
    while :; do
      case $(prompt "请选择混淆算法" 2) in
        1) obfs_type="salamander"; break ;;
        2) obfs_type="gecko"; break ;;
        *) tell_warn "输入无效"; sleep 1 ;;
      esac
    done
    obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$password")
    if [ "$obfs_type" = "gecko" ]; then
      min_pkt=$(prompt "最小包大小 (字节, 留空默认512)" "512")
      max_pkt=$(prompt "最大包大小 (字节, 留空默认1200)" "1200")
      [[ $min_pkt =~ ^[0-9]+$ ]] || min_pkt=512
      [[ $max_pkt =~ ^[0-9]+$ ]] || max_pkt=1200
    fi
  fi
  hopping=""
  if prompt_yes "是否配置并开启端口跳跃防封锁机制"; then
    if hopping_node >/dev/null; then tell_warn "当前已有其它节点开启了跳跃规则"
    else
      while :; do
        hopping=$(prompt "设置跳跃端口范围 (例如 20000-30000，留空跳过)")
        [ -z "$hopping" ] && break
        validate_range "$hopping" && break
      done
    fi
  fi
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" \
        --arg password "$password" --arg hopping "$hopping" \
        --argjson up "$up_mbps" --argjson down "$down_mbps" \
        --arg obfs_type "$obfs_type" --arg obfs_pw "$obfs_password" \
        --arg bbr "$bbr_profile" --arg min_pkt "$min_pkt" --arg max_pkt "$max_pkt" '
   {tag:$tag,name:$name,kind:"hysteria2",port:$port,proto:"u",hopping:$hopping,
    tls_mode:"acme",alpn:["h3"],
    meta:({password:$password, up_mbps:$up, down_mbps:$down, obfs_type:$obfs_type, obfs_password:$obfs_pw}
      | if $bbr != "" then .bbr_profile=$bbr else . end
      | if $obfs_type == "gecko" and $min_pkt != "" then .min_packet_size=($min_pkt|tonumber) else . end
      | if $obfs_type == "gecko" and $max_pkt != "" then .max_packet_size=($max_pkt|tonumber) else . end),
    inbound:({type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,
      users:[{password:$password}]}
      | if $up > 0 then .up_mbps=$up else . end
      | if $down > 0 then .down_mbps=$down else . end
      | if $bbr != "" then .bbr_profile=$bbr else . end
      | if $obfs_type != "" then .obfs={type:$obfs_type, password:$obfs_pw} else . end
      | if $obfs_type == "gecko" and $min_pkt != "" then .obfs.min_packet_size=($min_pkt|tonumber) else . end
      | if $obfs_type == "gecko" and $max_pkt != "" then .obfs.max_packet_size=($max_pkt|tonumber) else . end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_tuic(){
  local name port uuid password tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "TUIC")
  setup_certificate || return
  port=$(prompt_port u "")
  uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" \
        --arg uuid "$uuid" --arg password "$password" '
   {tag:$tag,name:$name,kind:"tuic",port:$port,proto:"u",hopping:"",
    tls_mode:"acme",alpn:["h3"],
    meta:{uuid:$uuid,password:$password},
    inbound:{type:"tuic",tag:$tag,listen:"::",listen_port:$port,
      users:[{uuid:$uuid,password:$password}],congestion_control:"bbr"}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_trojan(){
  local name port password tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Trojan")
  setup_certificate || return
  port=$(prompt_port t "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" '
   {tag:$tag,name:$name,kind:"trojan",port:$port,proto:"t",hopping:"",
    tls_mode:"acme",alpn:null,
    meta:{password:$password},
    inbound:{type:"trojan",tag:$tag,listen:"::",listen_port:$port,
      users:[{password:$password}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_anytls(){
  local name port password tag body client_meta
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "AnyTLS")
  setup_certificate || return
  port=$(prompt_port t "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  client_meta=$(prompt "客户端元数据 (留空则为空)" "")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" --arg meta "$client_meta" '
   {tag:$tag,name:$name,kind:"anytls",port:$port,proto:"t",hopping:"",
    tls_mode:"acme",alpn:null,
    meta:({password:$password}
      | if $meta != "" then .client_metadata=$meta else . end),
    inbound:{type:"anytls",tag:$tag,listen:"::",listen_port:$port,
      users:[{password:$password}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_socks(){
  local name username password port tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Socks5")
  username=$(prompt "鉴权账号" "admin")
  password=$(prompt "鉴权密码 (留空自动生成)" "$(random_password)")
  [ -n "$username" ] && [ -n "$password" ] || { tell_warn "必填项为空"; wait_key; return; }
  port=$(prompt_port t "")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" \
        --arg username "$username" --arg password "$password" '
   {tag:$tag,name:$name,kind:"socks",port:$port,proto:"t",hopping:"",
    tls_mode:"none",alpn:null,
    meta:{username:$username,password:$password},
    inbound:{type:"socks",tag:$tag,listen:"::",listen_port:$port,
      users:[{username:$username,password:$password}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_snell(){
  local name port psk mode tag body len
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Snell")
  port=$(prompt_port t "")
  while :; do
    psk=$(prompt "预共享密钥 (PSK, 12-255 字节)" "$(random_password)")
    len=${#psk}
    if [ "$len" -ge 12 ] && [ "$len" -le 255 ]; then break; fi
    tell_warn "PSK 长度必须为 12-255 字节，当前 ${len} 字节"
  done
  tell "  1. default"; tell "  2. unshaped"; tell "  3. unsafe-raw"
  while :; do
    case $(prompt "流量整形模式" 1) in
      1) mode="default"; break ;;
      2) mode="unshaped"; break ;;
      3) mode="unsafe-raw"; break ;;
      *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" \
        --arg psk "$psk" --arg mode "$mode" '
   {tag:$tag,name:$name,kind:"snell",port:$port,proto:"t",hopping:"",
    tls_mode:"none",alpn:null,
    meta:{psk:$psk,mode:$mode},
    inbound:{type:"snell",tag:$tag,listen:"::",listen_port:$port,
      version:6,psk:$psk,mode:$mode}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

build_uri(){
  local kind=$1 name=$2 port=$3 meta=$4 hopping=$5 host=$6 uri=""
  case $kind in
    vless-reality)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(jq -r .target <<<"$meta")&fp=chrome&pbk=$(jq -r .public_key <<<"$meta")&sid=$(jq -r .short_id <<<"$meta")&spx=%2F&type=tcp#$(uri_encode "$name")" ;;
    vless-tls)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$host&fp=chrome&type=tcp&allowInsecure=0#$(uri_encode "$name")" ;;
    hysteria2)
      local obfs_type obfs_pw obfs_str bbr bbr_str min_pkt max_pkt pkt_str
      obfs_type=$(jq -r '.obfs_type//""' <<<"$meta"); obfs_pw=$(jq -r '.obfs_password//""' <<<"$meta")
      bbr=$(jq -r '.bbr_profile//""' <<<"$meta"); min_pkt=$(jq -r '.min_packet_size//""' <<<"$meta"); max_pkt=$(jq -r '.max_packet_size//""' <<<"$meta")
      obfs_str=""; [ -n "$obfs_type" ] && obfs_str="&obfs=${obfs_type}&obfs-password=$(uri_encode "$obfs_pw")"
      bbr_str=""; [ -n "$bbr" ] && bbr_str="&bbr_profile=$(uri_encode "$bbr")"
      pkt_str=""; [ -n "$min_pkt" ] && pkt_str="${pkt_str}&min_packet_size=${min_pkt}"; [ -n "$max_pkt" ] && pkt_str="${pkt_str}&max_packet_size=${max_pkt}"
      uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?sni=$host&alpn=h3${bbr_str}${hopping:+&mport=$hopping}${obfs_str}${pkt_str}#$(uri_encode "$name")" ;;
    tuic)
      uri="tuic://$(jq -r .uuid <<<"$meta"):$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni=$host&allow_insecure=0#$(uri_encode "$name")" ;;
    trojan)
      uri="trojan://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?security=tls&sni=$host&type=tcp&allowInsecure=0#$(uri_encode "$name")" ;;
    anytls)
      local a_pw a_meta
      a_pw=$(jq -r .password <<<"$meta")
      a_meta=$(jq -r '.client_metadata//""' <<<"$meta")
      uri="anytls://$(uri_encode "$a_pw")@$host:$port?sni=$host&insecure=0"
      [ -n "$a_meta" ] && uri="${uri}&client_metadata=$(uri_encode "$a_meta")"
      uri="${uri}#$(uri_encode "$name")" ;;
    socks)
      uri="socks://$(uri_encode "$(jq -r .username <<<"$meta")"):$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port#$(uri_encode "$name")" ;;
    snell)
      local s_psk s_mode
      s_psk=$(uri_encode "$(jq -r .psk <<<"$meta")"); s_mode=$(jq -r '.mode//"default"' <<<"$meta")
      uri="snell://${s_psk}@$host:$port?version=6&mode=${s_mode}#$(uri_encode "$name")" ;;
  esac
  printf '%s' "$uri"
}

render_share_uri(){
  local file=$1 kind name port meta hopping mode host uri
  kind=$(jq -r .kind "$file"); name=$(jq -r .name "$file"); port=$(jq -r .port "$file")
  meta=$(jq -c .meta "$file"); hopping=$(jq -r '.hopping//""' "$file"); mode=$(jq -r .tls_mode "$file")
  if [ "$mode" = acme ]; then
    host=$(state_get domain)
    [ -n "$host" ] || { tell_warn "未识别到可用证书域名，生成链接失败"; return; }
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "$hopping" "$host")
    tell "${GREEN}$uri${PLAIN}"
    [ -n "$hopping" ] && tell "跳跃配置: $hopping"
    return
  fi
  if [ -n "$NET_IPV4" ]; then
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "$hopping" "$NET_IPV4")
    tell "${GREEN}$uri${PLAIN}"
  fi
  if [ -n "$NET_IPV6" ]; then
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "$hopping" "[$NET_IPV6]")
    tell "${GREEN}$uri${PLAIN}"
  fi
  if [ -z "$NET_IPV4$NET_IPV6" ]; then tell_warn "未识别到本机公网 IP，生成链接失败"; return; fi
  [ -n "$hopping" ] && tell "跳跃配置: $hopping"
  if [ "$kind" = "snell" ]; then tell_warn "Snell 分享链接可能不被所有客户端识别，请手动复制 PSK"; fi
}

list_nodes(){
  local index=0 raw_data old_ifs tcp_list udp_list
  NODE_COUNT=0; NODE_FILES=()
  set -- "$NODE_DIR"/*.json
  [ ! -e "$1" ] && { tell "  系统内暂无节点"; return 0; }
  tcp_list=$(listening_ports t); udp_list=$(listening_ports u)
  raw_data=$(jq -r '"\(input_filename)|\(.kind//"-")|\(.port//"-")|\(.name//"-")|\(.proto//"-")"' "$@" 2>/dev/null)
  if [ -n "$raw_data" ]; then
    old_ifs="$IFS"; IFS="|"
    while read -r file kind port name proto; do
      index=$((index+1)); NODE_FILES+=("$file")
      local status_text color
      if [ "$proto" = "u" ]; then
        grep -qx "$port" <<<"$udp_list" && { color="$GREEN"; status_text="[正常]"; } || { color="$RED"; status_text="[异常]"; }
      else
        grep -qx "$port" <<<"$tcp_list" && { color="$GREEN"; status_text="[正常]"; } || { color="$RED"; status_text="[异常]"; }
      fi
      printf "  %b%2d. [%-13s] %s:%s %b%s%b\n" "$GREEN" "$index" "$kind" "$name" "$port" "$color" "$status_text" "$PLAIN"
    done <<<"$raw_data"
    IFS="$old_ifs"
  fi
  NODE_COUNT=$index
  return 0
}

select_node(){
  local index
  list_nodes
  [ "$NODE_COUNT" = 0 ] && { wait_key; return 1; }
  tell "  0. 返回"
  while :; do
    index=$(prompt "请输入序号")
    [ -z "$index" ] && return 1
    [ "$index" = 0 ] && return 1
    if [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$NODE_COUNT" ]; then
      PICKED="${NODE_FILES[$((index-1))]}"; return 0
    else tell_warn "序号无效，请重新输入"; fi
  done
}

menu_create_protocol(){
  while :; do
    clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
    tell "  1. VLESS REALITY"; tell "  2. VLESS Vision+TCP+TLS"; tell "  3. Hysteria2"
    tell "  4. TUIC"; tell "  5. Trojan"; tell "  6. AnyTLS"; tell "  7. SOCKS5"; tell "  8. Snell"
    tell "  0. 返回"; tell "${CYAN}==============================${PLAIN}"
    case $(prompt "请选择") in
      1) create_vless_reality; break ;; 2) create_vless_tls; break ;; 3) create_hysteria2; break ;;
      4) create_tuic; break ;; 5) create_trojan; break ;; 6) create_anytls; break ;;
      7) create_socks; break ;; 8) create_snell; break ;; 0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

menu_delete_protocol(){
  clear; tell "${CYAN}========== 删除协议 ==========${PLAIN}"
  select_node || return
  prompt_yes "确认删除 $(jq -r .name "$PICKED")" || return
  local was_acme old_json
  was_acme=$(jq -r .tls_mode "$PICKED"); old_json=$(cat "$PICKED"); rm -f "$PICKED"
  if apply_config; then
    tell_ok "已删除"
    if [ "$was_acme" = "acme" ]; then
      local acme_count=0
      for f in "$NODE_DIR"/*.json; do [ "$(jq -r .tls_mode "$f")" = "acme" ] && acme_count=$((acme_count+1)); done
      if [ "$acme_count" -eq 0 ] && [ -n "$(state_get domain)" ]; then
        tell_gap
        if prompt_yes "是否连同域名和证书一起清理"; then
          state_set domain ""; state_set email ""; state_set challenge "http"
          find "$ACME_DIR" -mindepth 1 -delete 2>/dev/null; tell_ok "相关配置已清理"
        fi
      fi
    fi
  else
    json_save "$PICKED" "$old_json"; apply_config_quiet; tell_warn "删除导致配置异常，已安全回滚"
  fi
  wait_key
}

menu_modify_protocol(){
  local kind value other current_hop up_mbps down_mbps obfs_type obfs_password old_json bbr_profile min_pkt max_pkt
  clear; tell "${CYAN}========== 修改配置 ==========${PLAIN}"
  select_node || return
  while :; do
    kind=$(jq -r .kind "$PICKED")
    clear; tell "${CYAN}========== $(jq -r .name "$PICKED") [$kind] ==========${PLAIN}"
    tell "  1. 识别名称"; tell "  2. 监听端口"
    case $kind in
      vless-reality|vless-tls) tell "  3. 通信 UUID" ;;
      tuic) tell "  3. 通信 UUID"; tell "  4. 连接密码" ;;
      socks) tell "  3. 鉴权密码"; tell "  4. 鉴权账号" ;;
      snell) tell "  3. 预共享密钥"; tell "  4. 流量整形模式" ;;
      anytls) tell "  3. 连接密码"; tell "  4. 客户端元数据" ;;
      hysteria2) tell "  3. 连接密码"; tell "  4. 端口跳跃机制"; tell "  5. 拥塞控制"; tell "  6. 混淆设置" ;;
      *) tell "  3. 连接密码" ;;
    esac
    [ "$kind" = vless-reality ] && tell "  5. 握手目标域名"
    [ "$kind" = vless-reality ] && tell "  6. short_id"
    tell "  0. 返回"; tell "${CYAN}==============================${PLAIN}"
    old_json=$(cat "$PICKED")
    case $(prompt "请选择") in
      1)
        value=$(prompt "新识别名称" "$(jq -r .name "$PICKED")"); [ -n "$value" ] || continue
        json_edit "$PICKED" '.name=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      2)
        value=$(prompt_port "$(jq -r .proto "$PICKED")" "$(jq -r .port "$PICKED")") || continue
        json_edit "$PICKED" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      3)
        if [ "$kind" = vless-reality ] || [ "$kind" = vless-tls ] || [ "$kind" = tuic ]; then
          value=$(prompt "新通信 UUID (留空自动生成)"); [ -z "$value" ] && value=$(random_uuid)
          json_edit "$PICKED" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value"
        elif [ "$kind" = snell ]; then
          while :; do
            value=$(prompt "新 PSK (留空自动生成, 12-255字节)" "$(jq -r .meta.psk "$PICKED")")
            [ -z "$value" ] && value=$(random_password)
            local len=${#value}
            if [ "$len" -ge 12 ] && [ "$len" -le 255 ]; then break; fi
            tell_warn "PSK 长度必须为 12-255 字节，当前 ${len} 字节"
          done
          json_edit "$PICKED" '.meta.psk=$v|.inbound.psk=$v' --arg v "$value"
        else
          value=$(prompt "新连接密码 (留空自动生成)"); [ -z "$value" ] && value=$(random_password)
          json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value"
        fi || { tell_warn 失败; wait_key; continue; } ;;
      4)
        if [ "$kind" = socks ]; then
          value=$(prompt "鉴权账号" "$(jq -r .meta.username "$PICKED")"); [ -n "$value" ] || continue
          json_edit "$PICKED" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = tuic ]; then
          value=$(prompt "新连接密码 (留空自动生成)"); [ -z "$value" ] && value=$(random_password)
          json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = snell ]; then
          tell "  1. default"; tell "  2. unshaped"; tell "  3. unsafe-raw"
          while :; do
            case $(prompt "流量整形模式 (当前: $(jq -r '.meta.mode//"default"' "$PICKED"))" 1) in
              1) value="default"; break ;; 2) value="unshaped"; break ;; 3) value="unsafe-raw"; break ;;
              *) tell_warn "输入无效"; sleep 1 ;;
            esac
          done
          json_edit "$PICKED" '.meta.mode=$v|.inbound.mode=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = anytls ]; then
          value=$(prompt "客户端元数据 (留空则为空)" "$(jq -r '.meta.client_metadata//""' "$PICKED")")
          if [ -z "$value" ]; then
            json_edit "$PICKED" 'del(.meta.client_metadata)' || { tell_warn 失败; wait_key; continue; }
          else
            json_edit "$PICKED" '.meta.client_metadata=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
          fi
        elif [ "$kind" = hysteria2 ]; then
          current_hop=$(jq -r '.hopping//""' "$PICKED")
          value=$(prompt "跳跃范围 (当前: ${current_hop:-未开启}, 0 关闭)")
          if [ -z "$value" ]; then tell_ok "保持不变"; wait_key; continue; fi
          if [ "$value" = "0" ]; then value=""; else
            validate_range "$value" || { wait_key; continue; }
            other=$(hopping_node) && [ "$other" != "$PICKED" ] && { tell_warn "已有节点开启跳跃"; wait_key; continue; }
          fi
          json_edit "$PICKED" '.hopping=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        else tell_warn "输入无效"; sleep 1; continue; fi ;;
      5)
        if [ "$kind" = vless-reality ]; then
          while :; do
            value=$(prompt "新握手目标域名 (留空取消)")
            [ -n "$value" ] || break
            probe_handshake_target "$value" && break
            prompt_yes "检测异常，强制加载" && break
          done
          [ -n "$value" ] || continue
          json_edit "$PICKED" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = hysteria2 ]; then
          tell "  1. BBR conservative"
          tell "  2. BBR standard"
          tell "  3. BBR aggressive"
          tell "  4. Brutal (需手动设置带宽)"
          while :; do
            case $(prompt "请选择拥塞控制" 2) in
              1) bbr_profile="conservative"; up_mbps=0; down_mbps=0; break ;;
              2) bbr_profile="standard";     up_mbps=0; down_mbps=0; break ;;
              3) bbr_profile="aggressive";   up_mbps=0; down_mbps=0; break ;;
              4)
                bbr_profile=""
                while :; do
                  up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.up_mbps//0' "$PICKED")")
                  [[ $up_mbps =~ ^[0-9]+$ ]] || { tell_warn "输入无效"; continue; }
                  down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.down_mbps//0' "$PICKED")")
                  [[ $down_mbps =~ ^[0-9]+$ ]] || { tell_warn "输入无效"; continue; }
                  if [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ]; then break; fi
                  tell_warn "Brutal 模式至少需要设置一个方向的带宽"
                done
                break ;;
              *) tell_warn "输入无效"; sleep 1 ;;
            esac
          done

          if [ "$bbr_profile" != "" ]; then
            json_edit "$PICKED" '
              .meta.up_mbps=0 | .meta.down_mbps=0 | .meta.bbr_profile=$b |
              del(.inbound.up_mbps,.inbound.down_mbps) |
              .inbound.bbr_profile=$b
            ' --arg b "$bbr_profile" || { tell_warn 失败; wait_key; continue; }
          else
            json_edit "$PICKED" '
              .meta.up_mbps=$up | .meta.down_mbps=$down | .meta.bbr_profile="" |
              if $up > 0 then .inbound.up_mbps=$up else del(.inbound.up_mbps) end |
              if $down > 0 then .inbound.down_mbps=$down else del(.inbound.down_mbps) end |
              del(.inbound.bbr_profile)
            ' --argjson up "$up_mbps" --argjson down "$down_mbps" || { tell_warn 失败; wait_key; continue; }
          fi
        else tell_warn "输入无效"; sleep 1; continue; fi ;;
      6)
        if [ "$kind" = vless-reality ]; then
          value=$(prompt "新 short_id (留空自动生成 8位十六进制)" "$(jq -r '.meta.short_id//""' "$PICKED")")
          [ -z "$value" ] && value=$(openssl rand -hex 4 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c8)
          if ! [[ $value =~ ^[0-9a-fA-F]{1,8}$ ]]; then tell_warn "short_id 必须为 1-8 位十六进制字符"; wait_key; continue; fi
          json_edit "$PICKED" '.meta.short_id=$v|.inbound.tls.reality.short_id=[$v]' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = hysteria2 ]; then
          if prompt_yes "是否配置并开启协议混淆 (选择 N 则关闭混淆)"; then
            tell "  1. Salamander"; tell "  2. Gecko"
            while :; do
              case $(prompt "请选择混淆算法 (当前: $(jq -r '.meta.obfs_type//""' "$PICKED"))" 2) in
                1) obfs_type="salamander"; break ;; 2) obfs_type="gecko"; break ;;
                *) tell_warn "输入无效"; sleep 1 ;;
              esac
            done
            obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$(jq -r '.meta.obfs_password//""' "$PICKED")")
            [ -z "$obfs_password" ] && obfs_password=$(jq -r '.meta.password' "$PICKED")
            if [ "$obfs_type" = "gecko" ]; then
              min_pkt=$(prompt "最小包大小 (字节, 留空默认512)" "$(jq -r '.meta.min_packet_size//512' "$PICKED")")
              max_pkt=$(prompt "最大包大小 (字节, 留空默认1200)" "$(jq -r '.meta.max_packet_size//1200' "$PICKED")")
              [[ $min_pkt =~ ^[0-9]+$ ]] || min_pkt=512; [[ $max_pkt =~ ^[0-9]+$ ]] || max_pkt=1200
              json_edit "$PICKED" '.meta.obfs_type=$t | .meta.obfs_password=$p | .meta.min_packet_size=($mn|tonumber) | .meta.max_packet_size=($mx|tonumber) | .inbound.obfs={type:$t, password:$p, min_packet_size:($mn|tonumber), max_packet_size:($mx|tonumber)}' \
                --arg t "$obfs_type" --arg p "$obfs_password" --arg mn "$min_pkt" --arg mx "$max_pkt" || { tell_warn 失败; wait_key; continue; }
            else
              json_edit "$PICKED" '.meta.obfs_type=$t | .meta.obfs_password=$p | del(.meta.min_packet_size,.meta.max_packet_size) | .inbound.obfs={type:$t, password:$p}' \
                --arg t "$obfs_type" --arg p "$obfs_password" || { tell_warn 失败; wait_key; continue; }
            fi
          else
            json_edit "$PICKED" '.meta.obfs_type="" | .meta.obfs_password="" | del(.meta.min_packet_size,.meta.max_packet_size) | del(.inbound.obfs)' || { tell_warn 失败; wait_key; continue; }
          fi
        else tell_warn "输入无效"; sleep 1; continue; fi ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1; continue ;;
    esac
    if apply_config; then tell_ok "已生效"; tell_gap; render_share_uri "$PICKED"
    else printf '%s\n' "$old_json" | json_write "$PICKED"; apply_config_quiet; tell_warn "配置冲突或校验失败，已回滚"; fi
    wait_key
  done
}

render_certificate_status(){
  local domain crt expiry days file
  domain=$(state_get domain); [ -n "$domain" ] || return 0
  tell ""; tell "  全局域名: $domain | 验证: $(state_get challenge)"
  crt=""
  while IFS= read -r file; do
    if openssl x509 -in "$file" -noout -checkhost "$domain" >/dev/null 2>&1; then crt="$file"; break; fi
  done < <(find "$ACME_DIR" -type f -name '*.crt' 2>/dev/null)
  [ -n "$crt" ] || { tell "  ${YELLOW}证书状态: 未找到匹配域名的证书${PLAIN}"; return 0; }
  expiry=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
  [ -n "$expiry" ] || { tell "  ${RED}证书状态: 无法读取${PLAIN}"; return 0; }
  days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  tell "  到期时间: $expiry | 剩余: ${days} 天"
  systemctl is-active --quiet sing-box || tell_warn "服务离线，无法自动续期"
}

menu_server_info(){
  local file port proto status count=0 tcp_list udp_list
  tcp_list=$(listening_ports t); udp_list=$(listening_ports u)
  clear; tell "${CYAN}========== 服务端信息 ==========${PLAIN}"
  systemctl is-active --quiet sing-box && tell_ok "singbox: 运行中" || tell_warn "singbox: 未运行"
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    count=$((count+1)); port=$(jq -r .port "$file"); proto=$(jq -r .proto "$file")
    if [ "$proto" = u ]; then
      grep -qx "$port" <<<"$udp_list" && status="${GREEN}正常监听${PLAIN}" || status="${RED}未在监听${PLAIN}"
    else
      grep -qx "$port" <<<"$tcp_list" && status="${GREEN}正常监听${PLAIN}" || status="${RED}未在监听${PLAIN}"
    fi
    tell ""; tell "── $(jq -r .name "$file") [$(jq -r .kind "$file")] | 端口 $port $status"
    render_share_uri "$file"
  done
  [ "$count" = 0 ] && tell "\n  暂无节点"
  render_certificate_status; wait_key
}

menu_change_domain(){
  local new_domain old_domain old_email old_challenge file count=0 acme_backup="" acme_old=0
  clear; tell "${CYAN}========== 更换域名 ==========${PLAIN}"
  old_domain=$(state_get domain); old_email=$(state_get email); old_challenge=$(state_get challenge)
  tell "  当前域名: ${old_domain:-未设置}"; tell "  绑定节点:"
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    if [ "$(jq -r .tls_mode "$file")" = acme ]; then tell "  - $(jq -r .name "$file") [$(jq -r .kind "$file")]"; count=$((count+1)); fi
  done
  [ "$count" = 0 ] && tell "  无"
  echo ""
  new_domain=$(prompt "新域名 (留空取消)"); [ -z "$new_domain" ] && return
  if [ "$new_domain" != "$old_domain" ]; then
    acme_backup=$(mktemp -d "$SBM_DIR/acme-backup.XXXXXX") || { tell_warn "无法创建证书回滚备份"; wait_key; return; }
    if [ -d "$ACME_DIR" ]; then
      mv "$ACME_DIR" "$acme_backup/old" || { rm -rf "$acme_backup"; tell_warn "无法备份旧证书目录"; wait_key; return; }
      acme_old=1
    fi
    mkdir -p "$ACME_DIR" && chmod 700 "$ACME_DIR" || { [ "$acme_old" = 1 ] && { rm -rf "$ACME_DIR"; mv "$acme_backup/old" "$ACME_DIR"; }; rm -rf "$acme_backup"; tell_warn "无法准备新证书目录"; wait_key; return; }
  fi
  if prompt_yes "同步重置验证机制"; then
    if ! state_set domain "" || ! state_set email ""; then
      tell_warn "旧域名状态清理失败，未继续更换"
      rm -rf "$ACME_DIR"
      [ "$acme_old" = 1 ] && mv "$acme_backup/old" "$ACME_DIR"
      rm -rf "$acme_backup"
      wait_key; return
    fi
    if ! setup_certificate "$new_domain"; then
      if ! state_set domain "$old_domain" || ! state_set email "$old_email" || ! state_set challenge "$old_challenge"; then
        tell_warn "域名状态回滚失败，请立即检查 state.json"
      fi
      rm -rf "$ACME_DIR"
      [ "$acme_old" = 1 ] && mv "$acme_backup/old" "$ACME_DIR"
      rm -rf "$acme_backup"
      wait_key; return
    fi
  else
    validate_domain "$new_domain" || prompt_yes "验证未通过，强制写入" || {
      if ! state_set domain "$old_domain" || ! state_set email "$old_email" || ! state_set challenge "$old_challenge"; then
        tell_warn "域名状态回滚失败，请立即检查 state.json"
      fi
      rm -rf "$ACME_DIR"
      [ "$acme_old" = 1 ] && mv "$acme_backup/old" "$ACME_DIR"
      rm -rf "$acme_backup"
      return
    }
    if ! state_set domain "$new_domain"; then
      tell_warn "域名状态写入失败"
      return
    fi
  fi
  if apply_config; then
    [ -n "$acme_backup" ] && rm -rf "$acme_backup"
    menu_server_info
  else
    if ! state_set domain "$old_domain" || ! state_set email "$old_email" || ! state_set challenge "$old_challenge"; then
      tell_warn "域名状态回滚失败，请立即检查 state.json"
    fi
    rm -rf "$ACME_DIR"
    [ "$acme_old" = 1 ] && mv "$acme_backup/old" "$ACME_DIR"
    [ -d "$ACME_DIR" ] || mkdir -p "$ACME_DIR"
    rm -rf "$acme_backup"
    apply_config_quiet; tell_warn "部署异常已回滚"; wait_key
  fi
}

menu_server(){
  local previous
  while :; do
    clear; tell "${CYAN}========== 服务端管理 ==========${PLAIN}"
    tell "  1. 创建协议"; tell "  2. 删除协议"; tell "  3. 修改配置"; tell "  4. 服务端信息"
    tell "  5. 更换域名"; tell "  6. 重启服务"; tell "  7. 停止服务"; tell "  0. 返回"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) menu_create_protocol ;; 2) menu_delete_protocol ;; 3) menu_modify_protocol ;;
      4) menu_server_info ;; 5) menu_change_domain ;;
      6)
         timeout 15 systemctl restart sing-box >/dev/null 2>&1
         if systemctl is-active --quiet sing-box; then sync_bypass_rules; sync_hopping_rules; tell_ok "已重启"
         else tell_warn "singbox 未运行"; tell_warn "重启失败"; fi
         wait_key ;;
      7)
         previous=$(state_get exit)
         if ! state_set exit direct; then tell_warn "出口状态写入失败，未停止服务"; wait_key; continue; fi
         stop_watchdog
         if timeout 15 systemctl stop sing-box 2>/dev/null; then
           if build_config | json_write "$CONFIG"; then tell_ok "已停止"; else tell_warn "服务已停止，但配置同步失败"; fi
         else
           if ! state_set exit "$previous"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi
           sync_watchdog
           tell_warn "操作异常，已回滚"
         fi
         wait_key ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

parse_uri(){
  local raw=$1 rest tail explicit_port=0
  URI_SCHEME=${raw%%://*}; rest=${raw#*://}
  case $rest in *\#*) rest=${rest%%\#*} ;; esac
  URI_QUERY=""; case $rest in *\?*) URI_QUERY=${rest#*\?}; rest=${rest%%\?*} ;; esac
  rest=${rest%%/*}
  URI_USERINFO=""; case $rest in *@*) URI_USERINFO=$(uri_decode "${rest%@*}"); rest=${rest##*@} ;; esac
  URI_PORT=443
  case $rest in
    \[*\]*)
      URI_HOST=${rest%%\]*}; URI_HOST=${URI_HOST#\[}; tail=${rest##*\]}
      if [ -n "$tail" ]; then
        [[ "$tail" == :* ]] || return 1
        URI_PORT=${tail#:}; explicit_port=1
      fi ;;
    *:*) URI_HOST=${rest%%:*}; URI_PORT=${rest##*:}; explicit_port=1 ;;
    *) URI_HOST=$rest ;;
  esac
  if [ "$explicit_port" = 1 ] && { ! [[ "$URI_PORT" =~ ^[0-9]+$ ]] || [ "$URI_PORT" -lt 1 ] || [ "$URI_PORT" -gt 65535 ]; }; then
    tell_warn "URI 端口无效"; return 1
  fi
  [ -n "$URI_HOST" ] || { tell_warn "URI 主机为空"; return 1; }
  return 0
}

query_value(){
  local pair pairs
  IFS='&' read -ra pairs <<<"$URI_QUERY"
  for pair in "${pairs[@]}"; do
    [ "${pair%%=*}" = "$1" ] && { uri_decode "${pair#*=}"; return; }
  done
}

uri_to_outbound(){
  local tag=$1 outbound sni fingerprint insecure security network path vhost service
  local username password congestion alpn obfs_type obfs_pw hop_range flow udp_mode
  local bbr_profile disable_parrot s_mode client_meta min_pkt max_pkt
  sni=$(query_value sni); [ -n "$sni" ] || sni=$(query_value peer); [ -n "$sni" ] || sni=$URI_HOST
  fingerprint=$(query_value fp); [ -n "$fingerprint" ] || fingerprint=chrome
  insecure=$(query_value insecure); [ -n "$insecure" ] || insecure=$(query_value allowInsecure)
  case $URI_SCHEME in
    vless)
      security=$(query_value security); network=$(query_value type)
      path=$(query_value path); vhost=$(query_value host); service=$(query_value serviceName)
      flow=$(query_value flow)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg uuid "$URI_USERINFO" \
        '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,packet_encoding:"xudp"}')
      [ -n "$flow" ] && outbound=$(jq --arg f "$flow" '.flow=$f' <<<"$outbound")
      if [ "$security" = reality ]; then
        outbound=$(jq --arg sni "$sni" --arg fp "$fingerprint" --arg pbk "$(query_value pbk)" --arg sid "$(query_value sid)" \
          '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp},reality:{enabled:true,public_key:$pbk,short_id:$sid}}' <<<"$outbound")
      elif [ "$security" = tls ] || [ "$security" = xtls ]; then
        outbound=$(jq --arg sni "$sni" --arg fp "$fingerprint" \
          '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp}}' <<<"$outbound")
      fi
      case $network in
        ws) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" \
              '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound") ;;
        grpc) outbound=$(jq --arg svc "$service" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
        httpupgrade) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport={type:"httpupgrade",path:$path,host:$host}' <<<"$outbound") ;;
      esac ;;
    hysteria2|hy2)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" \
        '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      obfs_pw=$(query_value obfs-password); obfs_type=$(query_value obfs)
      if [ -n "$obfs_pw" ]; then
        [ -z "$obfs_type" ] && obfs_type="salamander"
        outbound=$(jq --arg type "$obfs_type" --arg pw "$obfs_pw" '.obfs={type:$type,password:$pw}' <<<"$outbound")
      fi
      bbr_profile=$(query_value bbr_profile); [ -n "$bbr_profile" ] || bbr_profile=standard
      outbound=$(jq --arg bbr "$bbr_profile" '.bbr_profile=$bbr' <<<"$outbound")
      disable_parrot=$(query_value disable_chrome_parrot)
      if [ "$disable_parrot" = "1" ] || [ "$disable_parrot" = "true" ]; then outbound=$(jq '.disable_chrome_parrot=true' <<<"$outbound"); fi
      hop_range=$(query_value mport); [ -z "$hop_range" ] && hop_range=$(query_value ports)
      [ -n "$hop_range" ] && outbound=$(jq --arg r "${hop_range//-/:}" '.server_ports=[$r]|del(.server_port)|.hop_interval="30s"' <<<"$outbound")
      min_pkt=$(query_value min_packet_size); max_pkt=$(query_value max_packet_size)
      if [ -n "$min_pkt" ] || [ -n "$max_pkt" ]; then
        outbound=$(jq --arg mn "${min_pkt:-512}" --arg mx "${max_pkt:-1200}" \
          '.obfs.min_packet_size=($mn|tonumber) | .obfs.max_packet_size=($mx|tonumber)' <<<"$outbound")
      fi ;;
    tuic)
      username=${URI_USERINFO%%:*}; password=${URI_USERINFO#*:}
      [ "$password" = "$URI_USERINFO" ] && password=""
      congestion=$(query_value congestion_control); [ -n "$congestion" ] || congestion=bbr
      alpn=$(query_value alpn); [ -n "$alpn" ] || alpn=h3
      udp_mode=$(query_value udp_relay_mode); [ -n "$udp_mode" ] || udp_mode=native
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg uuid "$username" --arg password "$password" --arg cc "$congestion" \
                       --arg sni "$sni" --arg alpn "$alpn" --arg udp_mode "$udp_mode" \
        '{type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$password,
          congestion_control:$cc,udp_relay_mode:$udp_mode,
          tls:{enabled:true,server_name:$sni,alpn:($alpn|split(","))}}') ;;
    trojan)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" \
        '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni}}')
      if [ "$(query_value type)" = ws ]; then
        outbound=$(jq --arg path "$(query_value path)" --arg host "$(query_value host)" \
          '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound")
      fi ;;
    anytls)
      client_meta=$(query_value client_metadata)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" --arg meta "$client_meta" \
        '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni}}
         | if $meta != "" then .client_metadata=$meta else . end') ;;
    socks5|socks)
      username=${URI_USERINFO%%:*}; password=${URI_USERINFO#*:}
      [ "$password" = "$URI_USERINFO" ] && password=""
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg user "$username" --arg pass "$password" \
        '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}
         |(if $user!="" then .username=$user else . end)
         |(if $pass!="" then .password=$pass else . end)') ;;
    snell)
      s_mode=$(query_value mode); [ -n "$s_mode" ] || s_mode=default
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg psk "$URI_USERINFO" --arg mode "$s_mode" \
        '{type:"snell",tag:$tag,server:$server,server_port:$port,version:6,psk:$psk,mode:$mode}') ;;
    *) return 1 ;;
  esac
  if [ "$insecure" = 1 ] || [ "$insecure" = true ]; then outbound=$(jq 'if .tls then .tls.insecure=true else . end' <<<"$outbound"); fi
  printf '%s' "$outbound"
}

peer_add(){
  local name uri tag outbound probe management_port
  clear; tell "${CYAN}========== 添加节点 ==========${PLAIN}"
  name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return
  uri=$(prompt "节点链接"); [ -n "$uri" ] || return
  parse_uri "$uri" || { wait_key; return; }
  if peer_target_address_is_local "$URI_HOST" "$URI_PORT"; then
    tell_warn "禁止自环接入：目标命中本机物理地址且端口命中本机节点监听端口"
    wait_key
    return
  fi
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag") || { tell_warn "无法解析"; wait_key; return; }
  probe=$(mktemp); TMP_FILES="$TMP_FILES $probe"
  jq -n --argjson ob "$outbound" '{log:{level:"error"},outbounds:[$ob,{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$probe"
  if "$CORE" check -c "$probe" >/dev/null 2>&1; then
    management_port=$(prompt "对端 SSH 端口" "22")
    [[ "$management_port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$management_port" -le 65535 ] || { tell_warn "SSH 端口无效"; rm -f "$probe"; wait_key; return; }
    if json_save "$PEER_DIR/$tag.json" "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" --argjson mp "$management_port" '{tag:$tag,name:$name,uri:$uri,management_port:$mp,outbound:$ob}')"; then
      tell_ok "挂载完成: $name"
    else
      tell_warn "节点保存失败，未完成挂载"
    fi
  else
    tell_warn "校验拦截:"; "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2
  fi
  rm -f "$probe"; wait_key
}

list_peers(){
  local current=$(state_get exit)
  local title=${1:-节点选择}
  PEER_COUNT=0; PEER_FILES=(); PEER_TAGS=(); PEER_TYPES=(); PEER_NAMES=(); PEER_PORTS=()
  set -- "$PEER_DIR"/*.json
  [ ! -e "$1" ] && { clear; tell "${CYAN}========== $title ==========${PLAIN}"; tell "  暂无外部节点"; return 0; }
  local tmp_dir; tmp_dir=$(mktemp -d); TMP_FILES="$TMP_FILES $tmp_dir"
  local idx=0 raw_data old_ifs test_pids=""
  raw_data=$(jq -r '"\(input_filename)|\(.tag//"-")|\(.outbound.type//"-")|\(.name//"-")|\(.outbound.server_port // (if .outbound.server_ports then (.outbound.server_ports[0]|gsub(":";"-")) else null end) // .outbound.listen_port // "-")|\(.outbound.server//"-")"' "$@" 2>/dev/null)
  if [ -n "$raw_data" ]; then
    old_ifs="$IFS"; IFS="|"
    while read -r file tag type name port host; do
      idx=$((idx+1)); PEER_FILES+=("$file"); PEER_TAGS+=("$tag"); PEER_TYPES+=("$type"); PEER_NAMES+=("$name"); PEER_PORTS+=("$port")
      (
        local ms="" ping_res iface cmd
        if [[ "$host" =~ : ]]; then iface="$NET_IF_V6"; cmd=ping6; else iface="$NET_IF_V4"; cmd=ping; fi
        if [ -n "$iface" ]; then
          ping_res=$(timeout 2 $cmd -I "$iface" -c 1 -W 1 -m 255 "$host" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{print $5}')
        fi
        if [ -n "$ping_res" ]; then ms=$(awk "BEGIN {print int($ping_res)}"); else ms="fail"; fi
        echo "$ms" > "$tmp_dir/res_$idx"
      ) &
      test_pids="$test_pids $!"
    done <<<"$raw_data"
    IFS="$old_ifs"
  fi
  PEER_COUNT=$idx
  [ -n "$test_pids" ] && wait $test_pids 2>/dev/null
  clear; tell "${CYAN}========== $title ==========${PLAIN}"
  for i in $(seq 1 $PEER_COUNT); do
    local tag="${PEER_TAGS[$((i-1))]}"; local type="${PEER_TYPES[$((i-1))]}"
    local name="${PEER_NAMES[$((i-1))]}"; local port="${PEER_PORTS[$((i-1))]}"
    local mark="" ms color status_text
    ms=$(cat "$tmp_dir/res_$i" 2>/dev/null)
    if [ "$ms" = "fail" ] || [ -z "$ms" ]; then color="$RED"; status_text="[不可用]"
    elif [ "$ms" -le 150 ]; then color="$GREEN"; status_text="[${ms}ms]"
    else color="$YELLOW"; status_text="[${ms}ms]"; fi
    [ "$tag" = "$current" ] && mark=" ${CYAN}<=当前${color}"
    printf "  %b%2d. [%-7s] %s:%s %b %s%b\n" "$color" "$i" "$type" "$name" "$port" "$mark" "$status_text" "$PLAIN"
  done
  rm -rf "$tmp_dir"; return 0
}

select_peer(){
  local title=${1:-节点选择} index
  while :; do
    list_peers "$title"
    [ "$PEER_COUNT" = 0 ] && { wait_key; return 1; }
    tell "  0. 返回"
    index=$(prompt "请选择 [回车刷新]")
    [ -z "$index" ] && continue
    [ "$index" = 0 ] && return 1
    if [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$PEER_COUNT" ]; then PICKED="${PEER_FILES[$((index-1))]}"; return 0
    else tell_warn "序号无效，请重新输入"; sleep 1; fi
  done
}

wg_client_active(){
  [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] && [ "$(jq -r .role "$WG_CONF")" = client ]
}

peer_target_address_is_local(){
  local host=$1 port=$2 ip p local4 local6
  [ -n "$host" ] || return 1
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  [ "$port" -le 65535 ] || return 1
  if [ "$host" = "127.0.0.1" ] || [ "$host" = "::1" ] || [ "$host" = "localhost" ]; then
    while IFS= read -r p; do
      [ "$port" = "$p" ] && return 0
    done < <(node_ports)
  fi
  for ip in $(resolve_addresses "$host"); do
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [ -n "$NET_IF_V4" ]; then
      while IFS= read -r local4; do
        [ "$ip" = "$local4" ] || continue
        while IFS= read -r p; do
          [ "$port" = "$p" ] && return 0
        done < <(node_ports)
      done < <(ip -4 addr show dev "$NET_IF_V4" scope global 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2}')
    elif [[ "$ip" == *:* ]] && [ -n "$NET_IF_V6" ]; then
      while IFS= read -r local6; do
        [ "$ip" = "$local6" ] || continue
        while IFS= read -r p; do
          [ "$port" = "$p" ] && return 0
        done < <(node_ports)
      done < <(ip -6 addr show dev "$NET_IF_V6" scope global 2>/dev/null | awk '/inet6 /{sub(/\/.*/,"",$2); print $2}')
    fi
  done
  return 1
}

peer_target_is_local(){
  local file=$1 host port
  [ -f "$file" ] || return 1
  host=$(jq -r '.outbound.server//""' "$file" 2>/dev/null)
  port=$(jq -r '.outbound.server_port//0' "$file" 2>/dev/null)
  peer_target_address_is_local "$host" "$port"
}

peer_select(){
  local tag previous wg_was_active=0
  select_peer "接管/选择节点" || return
  tag=$(jq -r .tag "$PICKED"); previous=$(state_get exit)
  if peer_target_is_local "$PICKED"; then
    tell_warn "节点目标指向本机服务端地址，拒绝形成本机环路"
    wait_key
    return
  fi
  if wg_client_active; then
    prompt_yes "WireGuard 隧道运行中，是否断开" || return
    if ! json_edit "$WG_CONF" '.enabled=false'; then
      tell_warn "WireGuard 关闭状态写入失败，未切换节点"
      wait_key
      return
    fi
    wg_was_active=1
  fi
  if ! state_set exit "$tag"; then
    if [ "$wg_was_active" = 1 ]; then json_edit "$WG_CONF" '.enabled=true' || true; fi
    tell_warn "出口状态写入失败，未切换"
    wait_key
    return
  fi
  stop_watchdog
  if apply_config; then sync_watchdog; tell_ok "已接管: $(jq -r .name "$PICKED")"
  else
    if ! state_set exit "$previous"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi
    if [ "$wg_was_active" = 1 ]; then json_edit "$WG_CONF" '.enabled=true' || tell_warn "WireGuard 状态恢复失败，请手动检查"; fi
    apply_config_quiet; sync_watchdog; tell_warn "切换失败已回滚"
  fi
  wait_key
}

peer_delete(){
  select_peer "删除节点" || return
  local old_json previous_exit
  old_json=$(cat "$PICKED"); previous_exit=$(state_get exit)
  if [ "$(jq -r .tag "$PICKED")" = "$previous_exit" ]; then
    if ! state_set exit direct; then tell_warn "出口状态写入失败，未删除当前节点"; wait_key; return; fi
    stop_watchdog; rm -f "$PICKED"
    if apply_config; then
      tell_ok "已删除当前生效节点，已恢复直连"
      if [ "$(jq -r '.enabled//false' "$WG_CONF" 2>/dev/null)" != "true" ]; then ip link del "$WG_IF" 2>/dev/null; fi
    else
      json_save "$PICKED" "$old_json"; if ! state_set exit "$previous_exit"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi; apply_config_quiet; sync_watchdog
      tell_warn "删除导致配置异常，节点与网络出口已安全回滚"
    fi
  else
    rm -f "$PICKED"
    if apply_config; then tell_ok "已删除节点"
    else json_save "$PICKED" "$old_json"; apply_config_quiet; tell_warn "删除导致配置异常，已安全回滚"; fi
  fi
  wait_key
}

peer_stop(){
  clear; local previous; previous=$(state_get exit)
  if ! state_set exit direct; then tell_warn "出口状态写入失败，未恢复直连"; wait_key; return; fi
  stop_watchdog
  if apply_config; then tell_ok "已恢复直连"
  else
    if ! state_set exit "$previous"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi
    apply_config_quiet; sync_watchdog; tell_warn "恢复直连失败，已回滚"
  fi
  wait_key
}

exit_label(){
  local selected; selected=$(state_get exit)
  case $selected in
    direct) echo "直连" ;;
    wireguard) echo "WireGuard 专线" ;;
    *) [ -f "$PEER_DIR/$selected.json" ] && jq -r .name "$PEER_DIR/$selected.json" || echo "$selected" ;;
  esac
}

get_ip_info(){
  local mode=$1 res ip country asn name
  res=$(curl -s -${mode} -m 5 https://ipwho.is/ 2>/dev/null)
  ip=$(jq -r '.ip // empty' <<<"$res" 2>/dev/null)
  if [ -n "$ip" ]; then
    country=$(jq -r '.country // empty' <<<"$res" 2>/dev/null)
    asn=$(jq -r '.connection.asn // empty' <<<"$res" 2>/dev/null)
    [ -n "$asn" ] && asn="AS$asn"
    name=$(jq -r '.connection.org // empty' <<<"$res" 2>/dev/null)
    IP_INFO_IP="$ip"; IP_INFO_C="$country"; IP_INFO_ASN="$asn"; IP_INFO_NAME="$name"
  else IP_INFO_IP=""; IP_INFO_C=""; IP_INFO_ASN=""; IP_INFO_NAME=""; fi
}

render_client_ip_status(){
  get_ip_info 4
  if [ -n "$IP_INFO_IP" ]; then
    tell "  IPv4: ${GREEN}${IP_INFO_IP}${PLAIN} | 地区: ${YELLOW}${IP_INFO_C}${PLAIN}"
    tell "  所属: ${CYAN}${IP_INFO_NAME}${PLAIN} | ASN: ${PURPLE}${IP_INFO_ASN}${PLAIN}"
  else tell "  IPv4: ${RED}无或不可用${PLAIN}"; fi
  get_ip_info 6
  if [ -n "$IP_INFO_IP" ]; then
    tell "  IPv6: ${GREEN}${IP_INFO_IP}${PLAIN} | 地区: ${YELLOW}${IP_INFO_C}${PLAIN}"
    tell "  所属: ${CYAN}${IP_INFO_NAME}${PLAIN} | ASN: ${PURPLE}${IP_INFO_ASN}${PLAIN}"
  else tell "  IPv6: ${RED}无或不可用${PLAIN}"; fi
}

menu_client_status(){
  clear; tell "${CYAN}========== 客户端状态 ==========${PLAIN}"
  local exit_node=$(state_get exit)
  local proxy_name="直连"
  if [ "$exit_node" != "direct" ]; then
    if [ "$exit_node" = "wireguard" ]; then proxy_name="WireGuard"
    else
      [ -f "$PEER_DIR/$exit_node.json" ] && proxy_name="$(jq -r .outbound.type "$PEER_DIR/$exit_node.json" 2>/dev/null)"
      proxy_name="${proxy_name:-未知}"
    fi
  fi
  tell "  当前出口: ${CYAN}${proxy_name}${PLAIN}"; tell ""
  render_client_ip_status; wait_key
}

menu_client(){
  while :; do
    clear; tell "${CYAN}========== 客户端管理 ==========${PLAIN}"
    tell "  当前出口: ${YELLOW}$(exit_label)${PLAIN}"; tell ""
    tell "  1. 添加节点"; tell "  2. 节点选择"; tell "  3. 删除节点"; tell "  4. 停止代理"; tell "  5. 客户端状态"; tell "  0. 返回"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) peer_add ;; 2) peer_select ;; 3) peer_delete ;; 4) peer_stop ;; 5) menu_client_status ;;
      0) break ;; *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

wg_tunnel_state(){
  local peer_ip=${1:-} peer_host=${2:-}
  [ -d "/sys/class/net/$WG_IF" ] || { echo down; return; }
  [ -d "/sys/class/net/$TUN_IF" ] || { echo down; return; }
  if [ -n "$peer_host" ]; then
    if ! wg_endpoint_route_excludes "$peer_host" >/dev/null 2>&1; then echo down; return; fi
  fi
  if [ -n "$peer_ip" ] && ping -I "$WG_IF" -c1 -W3 "$peer_ip" >/dev/null 2>&1; then
    if curl --interface "$WG_IF" -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL"; then echo up; return; fi
  fi
  if curl --interface "$WG_IF" -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL"; then echo up; return; fi
  echo down
}

render_wg_info(){
  local file=$1 role
  role=$(jq -r .role "$file")
  tell "${CYAN}========== 隧道状态信息 ==========${PLAIN}"
  if [ "$role" = server ]; then tell "  角色: 服务端"; else tell "  角色: 客户端"; fi
  tell "  引擎: $([ "$(jq -r .enabled "$file")" = true ] && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${RED}已挂起${PLAIN}")"
  echo ""
  tell "  本地公钥: $(jq -r .public_key "$file")"
  tell "  本地 IP:  $(jq -r '.address|join(", ")' "$file")"
  [ "$role" = server ] && tell "  监听端口: $(jq -r .listen_port "$file")"
  [ "$role" = client ] && tell "  远端地址: $(jq -r .peer_host "$file"):$(jq -r .peer_port "$file")"
  tell "  远端公钥: $(jq -r '.peer_public_key // "" | if .=="" then "<待补录>" else . end' "$file")"
  tell "  远端 IP:  $(jq -r .peer_ip "$file")"
  if [ "$role" = client ]; then
    if [ "$(jq -r .enabled "$file")" = true ]; then
      if [ "$(wg_tunnel_state "$(jq -r .peer_ip "$file")" "$(jq -r .peer_host // "" "$file")")" = up ]; then tell_ok "连接成功"; else tell_warn "连接中断"; fi
    fi
  else
    echo ""; tell "  ${YELLOW}请在客户端填入:${PLAIN}"
    local endpoint_host
    case "$NET_STACK" in
      v6) endpoint_host="[$(local_ipv6)]" ;;
      *) endpoint_host="$(local_ipv4)" ;;
    esac
    tell "  服务端: ${endpoint_host}:$(jq -r .listen_port "$file")"
    tell "  公钥: $(jq -r .public_key "$file")"
    if [ "$NET_STACK" != "v6" ]; then tell "  前缀: $(jq -r '.address[0]' "$file" | cut -d. -f1-3);"; fi
  fi
}

wg_subnet_conflict(){
  local prefix=$1
  case "$NET_STACK" in
    v4|both)
      if ip -4 addr show 2>/dev/null | awk -v p="$prefix." 'index($2,p)==1 {found=1} END{exit !found}'; then return 0; fi
      if ip -4 route show table all 2>/dev/null | awk -v p="$prefix." 'index($1,p)==1 {found=1} END{exit !found}'; then return 0; fi
      ;;
  esac
  case "$NET_STACK" in
    v6|both)
      if ip -6 addr show 2>/dev/null | awk '$2 ~ /^fd00:7:/ {found=1} END{exit !found}'; then return 0; fi
      if ip -6 route show table all 2>/dev/null | awk '$1 ~ /^fd00:7:/ {found=1} END{exit !found}'; then return 0; fi
      ;;
  esac
  return 1
}

wg_setup(){
  local role keypair private public prefix address4 address6 peer_ip4 peer_ip6
  local listen_port peer_host peer_port peer_key body
  while :; do
    clear; tell "${CYAN}========= 初始化 WireGuard =========${PLAIN}"
    tell "  1. 部署为 服务端"; tell "  2. 部署为 客户端"; tell "  0. 返回"
    tell "${CYAN}====================================${PLAIN}"
    case $(prompt "请选择" "1") in
      1) role=server; break ;; 2) role=client; break ;; 0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
  modprobe wireguard 2>/dev/null || true
  keypair=$("$CORE" generate wg-keypair)
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] || { tell_warn "密钥生成失败"; wait_key; return; }
  local ipv6_prefix="fd00:7"
  prefix="10.7.0"
  case "$NET_STACK" in
    v4|both)
      while :; do
        prefix=$(prompt "自定义网段 (IPv4前三段)" "10.7.0")
        if [[ $prefix =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] && [ "${BASH_REMATCH[3]}" -le 255 ]; then break; fi
        tell_warn "网段前三段必须为 0-255 的数字"
      done
      ;;
    v6) ;;
    *) tell_warn "当前网络无可用 IPv4/IPv6 出口"; wait_key; return ;;
  esac
  if wg_subnet_conflict "$prefix"; then
    tell_warn "WireGuard 网段 $prefix.0/24 或 fd00:7::/64 与现有地址/路由冲突"
    wait_key; return
  fi
  if [ "$role" = server ]; then
    local wg_addr_json wg_peer_allowed_json
    case "$NET_STACK" in
      v4)
        address4="$prefix.1/24"; address6=""; peer_ip4="$prefix.2"; peer_ip6=""; wg_addr_json='["'"$address4"'"]'; wg_peer_allowed_json='["'"$peer_ip4/32"'"]' ;;
      v6)
        address4=""; address6="$ipv6_prefix::1/64"; peer_ip4=""; peer_ip6="$ipv6_prefix::2"; wg_addr_json='["'"$address6"'"]'; wg_peer_allowed_json='["'"$peer_ip6/128"'"]' ;;
      both)
        address4="$prefix.1/24"; address6="$ipv6_prefix::1/64"; peer_ip4="$prefix.2"; peer_ip6="$ipv6_prefix::2"; wg_addr_json='["'"$address4"'","'"$address6"'"]'; wg_peer_allowed_json='["'"$peer_ip4/32"'","'"$peer_ip6/128"'"]' ;;
      *) tell_warn "当前网络无可用 IPv4/IPv6 出口"; wait_key; return ;;
    esac
    while :; do listen_port=$(prompt_port "u" "") || return; break; done
    peer_key=$(prompt "客户端公钥 (留空稍后回填)")
    body=$(jq -n --arg private "$private" --arg public "$public" --argjson port "$listen_port" --arg peer_key "$peer_key" --arg peer4 "$peer_ip4" --arg iface "$WG_IF" \
          --argjson addresses "$wg_addr_json" --argjson allowed "$wg_peer_allowed_json" \
          '{role:"server",enabled:false,private_key:$private,public_key:$public,address:$addresses,listen_port:$port,
            peer_public_key:$peer_key,peer_ip:$peer4,peer_host:"",peer_port:0,
            endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1408,address:$addresses,private_key:$private,listen_port:$port,
              peers:[{public_key:$peer_key,allowed_ips:$allowed,persistent_keepalive_interval:25}]}}')
  else
    peer_ip4="$prefix.1"
    peer_host=$(prompt "服务端地址（IP或域名）" "1.1.1.1")
    peer_port=$(prompt "服务端监听端口" "$(random_port)")
    peer_key=$(prompt "服务端公钥")
    [[ $peer_port =~ ^[0-9]+$ ]] && [ "$peer_port" -ge 1 ] && [ "$peer_port" -le 65535 ] || { tell_warn "端口必须为 1-65535"; wait_key; return; }
    if [ -z "$peer_key" ]; then
      tell_warn "服务端公钥不能为空，请先填写或稍后通过回填功能补录"
      wait_key; return
    fi
    local wg_addr_json wg_allowed_json
    case "$NET_STACK" in
      v4)
        address4="$prefix.2/32"; address6=""; peer_ip4="$prefix.1"; wg_addr_json='["'"$address4"'"]'; wg_allowed_json='["0.0.0.0/0"]' ;;
      v6)
        address4=""; address6="$ipv6_prefix::2/128"; peer_ip4="$ipv6_prefix::1"; wg_addr_json='["'"$address6"'"]'; wg_allowed_json='["::/0"]' ;;
      both)
        address4="$prefix.2/32"; address6="$ipv6_prefix::2/128"; peer_ip4="$prefix.1"; wg_addr_json='["'"$address4"'","'"$address6"'"]'; wg_allowed_json='["0.0.0.0/0","::/0"]' ;;
      *) tell_warn "当前网络无可用 IPv4/IPv6 出口"; wait_key; return ;;
    esac
    body=$(jq -n --arg private "$private" --arg public "$public" --arg host "$peer_host" --argjson port "$peer_port" --arg peer_key "$peer_key" \
          --arg peer4 "$peer_ip4" --arg iface "$WG_IF" \
          --argjson addresses "$wg_addr_json" --argjson allowed "$wg_allowed_json" \
          '{role:"client",enabled:false,private_key:$private,public_key:$public,address:$addresses,listen_port:0,
            peer_public_key:$peer_key,peer_ip:$peer4,peer_host:$host,peer_port:$port,
            endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1408,address:$addresses,private_key:$private,
              peers:[{address:$host,port:$port,public_key:$peer_key,allowed_ips:$allowed,persistent_keepalive_interval:25}]}}')
  fi
  json_save "$WG_CONF" "$body" || { tell_warn "写入失败"; wait_key; return; }
  render_wg_info "$WG_CONF"; wait_key
}

wg_fill_peer_key(){
  local key old_json
  clear; tell "${CYAN}========== 回填对端公钥 ==========${PLAIN}"
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化"; wait_key; return; }
  key=$(prompt "对端公钥" "$(jq -r .peer_public_key "$WG_CONF")")
  [ -n "$key" ] || return
  old_json=$(cat "$WG_CONF") || { tell_warn "无法读取当前配置"; wait_key; return; }
  local peer_host peer_port
  peer_host=$(jq -r '.peer_host//""' "$WG_CONF")
  peer_port=$(jq -r '.peer_port//0' "$WG_CONF")
  json_edit "$WG_CONF" \
    '.peer_public_key=$k | .endpoint.peers[0].public_key=$k |
     .endpoint.peers[0].address=$h | .endpoint.peers[0].port=$p' \
    --arg k "$key" --arg h "$peer_host" --argjson p "$peer_port" || { tell_warn "覆盖失败"; wait_key; return; }
  if [ "$(jq -r .enabled "$WG_CONF")" = true ]; then
    if apply_config; then
      if [ "$(jq -r .role "$WG_CONF")" = client ] && [ "$(wg_tunnel_state "$(jq -r .peer_ip "$WG_CONF")" "$(jq -r .peer_host // "" "$WG_CONF")")" != up ]; then
        printf '%s\n' "$old_json" | json_write "$WG_CONF"
        apply_config_quiet
        tell_warn "新公钥应用后健康检查失败，已回滚"
      else
        tell_ok "已生效"
      fi
    else
      printf '%s\n' "$old_json" | json_write "$WG_CONF"
      apply_config_quiet
      tell_warn "应用失败，已回滚"
    fi
  else
    tell_ok "已补录"
  fi
  wait_key
}

wg_toggle(){
  local role previous old_json
  clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化"; wait_key; return; }
  role=$(jq -r .role "$WG_CONF"); previous=$(state_get exit); old_json=$(cat "$WG_CONF") || { tell_warn "无法读取配置"; wait_key; return; }
  modprobe wireguard 2>/dev/null || true
  if [ "$(jq -r .enabled "$WG_CONF")" = true ]; then
    json_edit "$WG_CONF" '.enabled=false' || { tell_warn "关闭状态写入失败"; wait_key; return; }
    if [ "$role" = server ]; then
      if ! wg_server_nat_remove; then
        printf '%s\n' "$old_json" | json_write "$WG_CONF" >/dev/null 2>&1 || true
        tell_warn "WireGuard NAT 清理失败，关闭操作已中止"
        wait_key
        return
      fi
    fi
    if [ "$role" = client ] && [ "$previous" = wireguard ]; then
      if ! state_set exit direct; then
        printf '%s\n' "$old_json" | json_write "$WG_CONF" >/dev/null 2>&1 || true
        tell_warn "出口状态写入失败，关闭操作已中止"
        wait_key
        return
      fi
      stop_watchdog
    fi
    if apply_config; then
      tell_ok "已关闭隧道"
    else
      printf '%s\n' "$old_json" | json_write "$WG_CONF"
      if ! state_set exit "$previous"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi
      if [ "$role" = server ]; then wg_server_nat_apply; fi
      apply_config_quiet; sync_watchdog
      tell_warn "关闭失败，已回滚"
    fi
  else
    [ -n "$(jq -r .peer_public_key "$WG_CONF")" ] || { tell_warn "缺少公钥"; wait_key; return; }
    if [ "$role" = client ] && [ "$previous" != direct ]; then prompt_yes "隧道将接管网络，确定" || return; fi
    if [ "$role" = client ]; then
      wg_endpoint_route_excludes "$(jq -r .peer_host // "" "$WG_CONF")" >/dev/null 2>&1 || { tell_warn "服务端地址解析或物理路由检查失败"; wait_key; return; }
      if ! state_set exit wireguard; then tell_warn "出口状态写入失败，未启用 WireGuard"; wait_key; return; fi
      if ! stop_watchdog; then
        tell_warn "watchdog 停止失败，未启用 WireGuard"
        if ! state_set exit "$previous"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi
        wait_key
        return
      fi
    fi
    if ! json_edit "$WG_CONF" '.enabled=true'; then
      if ! state_set exit "$previous"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi
      tell_warn "启用状态写入失败"
      wait_key
      return
    fi
    if [ "$role" = server ]; then
      if ! wg_server_nat_apply; then
        printf '%s\n' "$old_json" | json_write "$WG_CONF"
        if ! state_set exit "$previous"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi
        wg_server_nat_remove
        tell_warn "NAT 初始化失败，已回滚"
        wait_key
        return
      fi
    fi
    if apply_config; then
      if [ "$role" = client ]; then
        sleep 2
        if [ "$(wg_tunnel_state "$(jq -r .peer_ip "$WG_CONF")" "$(jq -r .peer_host // "" "$WG_CONF")")" != up ]; then
          printf '%s\n' "$old_json" | json_write "$WG_CONF"
          if ! state_set exit "$previous"; then
            tell_warn "出口状态回滚失败，请立即检查 state.json"
          fi
          apply_config_quiet
          tell_warn "WireGuard 启用后健康检查失败，已自动回滚"
        else
          sync_watchdog; render_wg_info "$WG_CONF"
        fi
      else
        sync_watchdog; render_wg_info "$WG_CONF"
      fi
    else
      printf '%s\n' "$old_json" | json_write "$WG_CONF"
      if ! state_set exit "$previous"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi
      if [ "$role" = server ]; then wg_server_nat_remove; fi
      apply_config_quiet; sync_watchdog; tell_warn "启用失败，已回滚"
    fi
  fi
  wait_key
}

menu_wireguard(){
  local role_label tunnel_label
  while :; do
    clear; tell "${CYAN}======== WireGuard 管理 ========${PLAIN}"
    if [ -f "$WG_CONF" ]; then
      [ "$(jq -r .role "$WG_CONF")" = server ] && role_label="服务端" || role_label="客户端"
      [ "$(jq -r .enabled "$WG_CONF")" = true ] && tunnel_label="${GREEN}运行中${PLAIN}" || tunnel_label="${RED}已挂起${PLAIN}"
      tell "  角色: ${role_label} | 隧道: ${tunnel_label}"
    else tell "  未配置"; fi
    tell ""; tell "  1. 初始化配置"; tell "  2. 回填对端公钥"; tell "  3. 切换运行状态"; tell "  4. 隧道状态信息"; tell "  5. 删除配置"; tell "  0. 返回"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) wg_setup ;; 2) wg_fill_peer_key ;; 3) wg_toggle ;;
      4) clear
         if [ -f "$WG_CONF" ]; then render_wg_info "$WG_CONF"; wait_key
         else tell_warn "数据为空"; wait_key; fi ;;
      5) clear
         if [ ! -f "$WG_CONF" ]; then tell_warn "未配置 WireGuard，无需删除"; wait_key; continue; fi
         if prompt_yes "确认删除配置"; then
           local wg_backup prev_exit wg_enabled wg_role
           wg_backup=$(cat "$WG_CONF"); prev_exit=$(state_get exit)
           wg_enabled=$(jq -r '.enabled//false' <<<"$wg_backup")
           wg_role=$(jq -r '.role//""' <<<"$wg_backup")
           rm -f "$WG_CONF"
           [ "$wg_role" = server ] && wg_server_nat_remove
           if [ "$prev_exit" = wireguard ]; then
             if ! state_set exit direct; then
               printf '%s\n' "$wg_backup" | json_write "$WG_CONF" >/dev/null 2>&1 || true
               tell_warn "出口状态写入失败，未删除 WireGuard 配置"
               wait_key
               continue
             fi
             stop_watchdog
           fi
           if apply_config; then
             tell_ok "已清除"; ip link del "$WG_IF" 2>/dev/null
           else
             printf '%s\n' "$wg_backup" | json_write "$WG_CONF"
             if ! state_set exit "$prev_exit"; then tell_warn "出口状态回滚失败，请立即检查 state.json"; fi
             if [ "$wg_role" = server ] && [ "$wg_enabled" = true ]; then wg_server_nat_apply; fi
             apply_config_quiet; sync_watchdog
             tell_warn "删除失败，已回滚"
           fi
           wait_key
         fi ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

update_core_transaction(){
  local core_backup old_asset update_ok=0 service_active=0
  core_backup=$(mktemp) || { tell_warn "无法创建内核回滚备份"; return 1; }
  if [ -x "$CORE" ] && ! cp -p "$CORE" "$core_backup"; then
    rm -f "$core_backup"
    tell_warn "无法备份当前内核"
    return 1
  fi
  old_asset=$(state_get asset)
  systemctl is-active --quiet sing-box && service_active=1
  if [ "$service_active" = 1 ]; then
    if ! timeout 15 systemctl stop sing-box >/dev/null 2>&1 || systemctl is-active --quiet sing-box; then
      rm -f "$core_backup"
      tell_warn "无法安全停止 sing-box，取消内核更新"
      return 1
    fi
  fi
  if install_core && apply_config; then
    if [ "$service_active" = 1 ]; then
      if systemctl is-active --quiet sing-box; then
        update_ok=1
      elif systemctl start sing-box >/dev/null 2>&1 && systemctl is-active --quiet sing-box; then
        update_ok=1
      else
        tell_warn "新内核配置应用成功，但原运行服务无法恢复启动"
      fi
    else
      update_ok=1
    fi
  fi
  if [ "$update_ok" = 0 ]; then
    if [ -s "$core_backup" ]; then
      if ! install -m755 "$core_backup" "$CORE" >/dev/null 2>&1; then
        tell_warn "旧内核恢复失败"
      fi
    else
      rm -f "$CORE"
    fi
    if [ -n "$old_asset" ]; then
      state_set asset "$old_asset" || tell_warn "旧内核资产状态恢复失败"
    else
      state_set asset "" || true
    fi
    if ! apply_config_quiet; then
      tell_warn "旧内核恢复后配置重新应用失败"
    fi
    if [ "$service_active" = 1 ] && ! systemctl is-active --quiet sing-box; then
      if ! systemctl start sing-box >/dev/null 2>&1 || ! systemctl is-active --quiet sing-box; then
        tell_warn "原运行服务恢复启动失败"
      fi
    fi
  fi
  rm -f "$core_backup"
  [ "$update_ok" = 1 ]
}

run_update(){
  local current latest script_url script_tmp
  clear
  tell "正在检测 sing-box 内核更新..."
  current=$(core_version); latest=$(remote_version)
  tell "本地版本: ${current:-未知}"; tell "目标版本: ${latest:-获取失败}"
  if [ -z "$latest" ]; then
    tell_warn "无法获取最新版本，请检查网络或 GitHub 访问"
  elif [ -z "$current" ]; then
    if prompt_yes "无法读取当前内核版本，是否重新下载并安装 sing-box v$latest"; then
      if update_core_transaction; then
        tell_ok "内核重新安装完成"
      else
        tell_warn "内核重新安装失败"
      fi
    fi
  elif [ "$current" != "$latest" ]; then
    if prompt_yes "发现新版本 v$latest，是否立即更新"; then
      if update_core_transaction; then
        tell_ok "内核更新完成"
      else
        tell_warn "内核更新失败或回滚未完全成功"
      fi
    fi
  else
    tell_ok "内核已是最新版本"
  fi
  tell_gap
  tell "正在检测 s 脚本更新..."
  script_url="https://raw.githubusercontent.com/88860/-/main/s.sh"
  script_tmp=$(mktemp) || { tell_warn "无法创建临时文件"; wait_key; return; }
  TMP_FILES="$TMP_FILES $script_tmp"
  if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$script_url" -o "$script_tmp" 2>/dev/null; then
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$script_url" -o "$script_tmp" 2>/dev/null; then
      tell_warn "脚本下载失败，请检查 GitHub 访问"; wait_key; return
    fi
  fi
  if [ ! -s "$script_tmp" ]; then tell_warn "下载的脚本为空，放弃更新"
  elif bash -n "$script_tmp" 2>/dev/null; then
    if cmp -s "$script_tmp" "$SELF"; then tell_ok "脚本已是最新版本"
    else
      if install -m700 "$script_tmp" "$SELF"; then
        tell_ok "脚本更新成功，请重新运行本脚本生效"; exit 0
      else tell_warn "脚本写入失败，原脚本未修改"; fi
    fi
  else tell_warn "下载的脚本存在语法错误，放弃更新"; fi
  wait_key
}

run_uninstall(){
  local packages service_active watchdog_active
  clear
  tell_warn "警告: 卸载将清空所有配置"
  [ "$(prompt '输入 yes 确认')" = yes ] || return
  mapfile -t packages < <(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null)
  service_active=0; watchdog_active=0
  systemctl is-active --quiet sing-box && service_active=1
  systemctl is-active --quiet sbm-watchdog.service && watchdog_active=1
  if [ "$service_active" = 1 ]; then
    systemctl stop sing-box >/dev/null 2>&1 || { tell_warn "sing-box 停止失败，取消卸载"; return 1; }
    systemctl is-active --quiet sing-box && { tell_warn "sing-box 仍在运行，取消卸载"; return 1; }
  fi
  if [ "$watchdog_active" = 1 ]; then
    systemctl stop sbm-watchdog.service >/dev/null 2>&1 || { tell_warn "watchdog 停止失败，取消卸载"; return 1; }
    systemctl is-active --quiet sbm-watchdog.service && { tell_warn "watchdog 仍在运行，取消卸载"; return 1; }
  fi
  if pgrep -x sing-box >/dev/null 2>&1; then
    tell_warn "检测到独立 sing-box 进程，取消卸载"
    return 1
  fi
  stop_net_monitor
  clear_hopping_rules || { tell_warn "hopping 规则清理失败，取消卸载"; return 1; }
  wg_server_nat_remove || { tell_warn "NAT 清理失败，取消卸载"; return 1; }
  clear_bypass_rules || { tell_warn "bypass 规则清理失败，取消卸载"; return 1; }
  if ip -4 rule show pref "$BYPASS_PREF" 2>/dev/null | grep -q 'sport ' || ip -6 rule show pref "$BYPASS_PREF" 2>/dev/null | grep -q 'sport ' || ip -4 rule show pref "$((BYPASS_PREF-1))" 2>/dev/null | grep -qE 'to .*dport ' || ip -6 rule show pref "$((BYPASS_PREF-1))" 2>/dev/null | grep -qE 'to .*dport '; then
    tell_warn "检测到 bypass 路由规则残留，取消卸载"
    return 1
  fi
  ip link show "$WG_IF" >/dev/null 2>&1 && { ip link del "$WG_IF" >/dev/null 2>&1 || { tell_warn "WireGuard 接口清理失败，取消卸载"; return 1; }; }
  ip link show "$TUN_IF" >/dev/null 2>&1 && { ip link del "$TUN_IF" >/dev/null 2>&1 || { tell_warn "TUN 接口清理失败，取消卸载"; return 1; }; }
  if nft list table inet "$HOP_TABLE" >/dev/null 2>&1 || nft list table ip6 sbm_nat >/dev/null 2>&1 || nft list table ip sbm_nat >/dev/null 2>&1; then
    tell_warn "检测到 nft 残留，取消卸载"
    return 1
  fi
  if ip link show "$WG_IF" >/dev/null 2>&1 || ip link show "$TUN_IF" >/dev/null 2>&1; then
    tell_warn "检测到网络接口残留，取消卸载"
    return 1
  fi
  systemctl daemon-reload >/dev/null 2>&1 || { tell_warn "systemd daemon-reload 失败，取消卸载"; return 1; }
  rm -f "$SERVICE_UNIT" "$DROPIN" /etc/systemd/system/sbm-watchdog.service
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || { tell_warn "删除 service 后 daemon-reload 失败，取消卸载"; return 1; }
  rm -rf "$SB_DIR" "$SBM_DIR" /var/lib/sing-box "$CORE" "$SHORTCUT"
  if [ ${#packages[@]} -gt 0 ]; then
    tell "脚本曾安装过: [ ${packages[*]} ]"
    if prompt_yes "是否移除依赖组件 (仅执行 remove，不触碰系统核心包)"; then
      local owned_packages=() pkg
      for pkg in "${packages[@]}"; do
        case "$pkg" in
          *'|owned') owned_packages+=("${pkg%|owned}") ;;
        esac
      done
      if [ ${#owned_packages[@]} -gt 0 ]; then
        apt-get remove -y -q "${owned_packages[@]}" >/dev/null 2>&1 || true
      fi
    fi
  fi
  rm -f "$SELF"
  tell_ok "清理完成"
  exit 0
}

menu_status(){
  while :; do
    clear
    tell "${CYAN}========== 状态与更新 ==========${PLAIN}"
    local os=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)
    local core=$(uname -r)
    local arch=$(uname -m)
    local mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}/MemFree/{f=$2}/Buffers/{b=$2}/^Cached/{c=$2}END{if(a=="")a=f+b+c; printf "%d / %d MB",(t-a)/1024,t/1024}' /proc/meminfo)
    local up_secs=$(cut -d. -f1 /proc/uptime)
    local up_days=$((up_secs / 86400))
    local up_hours=$(((up_secs % 86400) / 3600))
    local up_mins=$(((up_secs % 3600) / 60))
    local up=""
    [ "$up_days" -gt 0 ] && up="${up_days}天"
    [ "$up_hours" -gt 0 ] && up="${up}${up_hours}小时"
    [ "$up_mins" -gt 0 ] && up="${up}${up_mins}分钟"
    [ -z "$up" ] && up="不足1分钟"
    local sb_ver=$(core_version)
    local sb_asset=$(state_get asset)
    local s_state="${RED}未运行${PLAIN}"
    systemctl is-active --quiet sing-box && s_state="${GREEN}正常运行${PLAIN}"
    tell "  系统版本: ${os}"
    tell "  内核架构: ${core} (${arch})"
    tell "  内存状态: ${mem}"
    tell "  运行时间: ${up}"
    tell "  singbox : ${s_state}"
    tell "  singbox版本: ${sb_ver:-无} (${sb_asset:-未知})"
    tell ""
    render_client_ip_status
    tell ""
    tell "  1. 检测更新"
    tell "  2. 彻底卸载"
    tell "  0. 返回"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) run_update ;;
      2) run_uninstall ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

bootstrap(){
  init_dirs
  check_dependencies
  chmod 700 "$SELF" 2>/dev/null
  ln -sf "$SELF" "$SHORTCUT" 2>/dev/null
  load_net_cache
  probe_network_stack_async
  if [ ! -x "$CORE" ]; then
    echo -e "  ${CYAN}首次运行，安装 sing-box...${PLAIN}"
    install_core || exit 1
  fi
  if [ ! -f "$SERVICE_UNIT" ]; then
    write_service
  elif [ ! -f "$DROPIN" ]; then
    write_dropin
    systemctl daemon-reload
  fi
  systemctl enable sing-box >/dev/null 2>&1
  if [ ! -f "$CONFIG" ]; then
    build_config | json_write "$CONFIG" || exit 1
  fi
  if "$CORE" check -c "$CONFIG" >/dev/null 2>&1; then
    systemctl enable --now sing-box >/dev/null 2>&1 || true
  fi
  sync_bypass_rules
  sync_hopping_rules
  start_net_monitor
}

case $1 in
  --sync) init_dirs; sync_bypass_rules; sync_hopping_rules; exit 0 ;;
  --clear-hopping) clear_hopping_rules; exit 0 ;;
  --reapply)
    exec 9>"$REAPPLY_LOCK"
    flock -w 5 9 || exit 0
    init_dirs
    load_net_cache
    prev_if4="$NET_IF_V4"; prev_if6="$NET_IF_V6"
    NET_IF_V4=$(default_iface_v4)
    NET_IF_V6=$(default_iface_v6)
    [ -n "$NET_IF_V4" ] || NET_IF_V4="$prev_if4"
    [ -n "$NET_IF_V6" ] || NET_IF_V6="$prev_if6"
    if [ "$NET_IF_V4" != "$prev_if4" ] || [ "$NET_IF_V6" != "$prev_if6" ]; then
      probe_network_stack
      [ -n "$NET_IF_V4" ] || NET_IF_V4="$prev_if4"
      [ -n "$NET_IF_V6" ] || NET_IF_V6="$prev_if6"
      _cache_tmp=$(mktemp "${NET_CACHE}.XXXXXX") || { flock -u 9; exit 1; }
      if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" >"$_cache_tmp" || ! mv -f "$_cache_tmp" "$NET_CACHE"; then
        rm -f "$_cache_tmp"; flock -u 9; exit 1
      fi
    fi
    _new_conf=$(mktemp); TMP_FILES="$TMP_FILES $_new_conf"
    if ! build_config >"$_new_conf" 2>/dev/null || [ ! -s "$_new_conf" ]; then
      rm -f "$_new_conf"; flock -u 9; exit 1
    fi
    if ! "$CORE" check -c "$_new_conf" >/dev/null 2>&1; then
      rm -f "$_new_conf"; flock -u 9; exit 1
    fi
    if cmp -s "$_new_conf" "$CONFIG"; then
      rm -f "$_new_conf"
      flock -u 9
      exit 0
    fi
    rm -f "$_new_conf"
    if ! _apply_config_locked >/dev/null 2>&1; then
      flock -u 9
      exit 1
    fi
    flock -u 9
    exit 0 ;;
  --watchdog) run_watchdog; exit 0 ;;
esac

bootstrap

while :; do
  clear
  tell "${CYAN}================================${PLAIN}"
  tell "${CYAN}             s管理              ${PLAIN}"
  tell "${CYAN}      [ 仅适配 Systemd ]        ${PLAIN}"
  tell "${CYAN}================================${PLAIN}"
  tell "  1. 服务端"
  tell "  2. 客户端"
  tell "  3. WireGuard"
  tell "  4. 状态与更新"
  tell "  0. 退出"
  tell "${CYAN}================================${PLAIN}"
  case $(prompt "请选择") in
    1) menu_server ;;
    2) menu_client ;;
    3) menu_wireguard ;;
    4) menu_status ;;
    0) clear; exit 0 ;;
    *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
  esac
done
