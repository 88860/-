#!/usr/bin/env bash
export LC_ALL=C
shopt -s nullglob

RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
PURPLE='\033[35m'
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
tell_alert(){ echo -e "  ${YELLOW}[!] $*${PLAIN}"; }

uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }
uri_decode(){ local s=${1//+/ }; s=${s//\\/\\\\}; printf '%b' "${s//%/\\x}"; }
slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){ openssl rand -hex 8; }
random_uuid(){ cat /proc/sys/kernel/random/uuid; }
random_port(){ shuf -i 20000-60000 -n1; }

json_write(){
  local dest=$1 tmp
  tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  cat >"$tmp"
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  install -m600 "$tmp" "$dest"; rm -f "$tmp"
}

json_save(){
  local dest=$1 content=$2
  [ -n "$content" ] || return 1
  printf '%s\n' "$content" | json_write "$dest"
}

json_edit(){
  local file=$1 expr=$2; shift 2
  local tmp; tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  if jq "$@" "$expr" "$file" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    install -m600 "$tmp" "$file"; rm -f "$tmp"; return 0
  fi
  return 1
}

init_dirs(){
  mkdir -p "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box
  chmod 700 "$SBM_DIR" "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box
  [ -f "$STATE" ] || printf '%s\n' '{"exit":"direct","domain":"","email":"","challenge":"http","asset":""}' | json_write "$STATE"
  [ -f "$PKG_LOG" ] || : >"$PKG_LOG"
}

state_get(){ jq -r --arg k "$1" '.[$k]//""' "$STATE" 2>/dev/null; }
state_set(){ json_edit "$STATE" '.[$k]=$v' --arg k "$1" --arg v "$2"; }

ensure_command(){
  local cmd=$1 pkg=${2:-$1}
  command -v "$cmd" >/dev/null 2>&1 && return 0
  local guard=0
  while command -v fuser >/dev/null 2>&1 && { fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; }; do
    sleep 1; guard=$((guard+1)); [ "$guard" -gt 30 ] && break
  done
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" >/dev/null 2>&1
  command -v "$cmd" >/dev/null 2>&1 || return 1
  grep -qx "$pkg" "$PKG_LOG" 2>/dev/null || echo "$pkg" >>"$PKG_LOG"
}

check_dependencies(){
  local cmd pkg
  local deps=(
    "bash:bash" "curl:curl" "tar:tar" "jq:jq" "openssl:openssl"
    "nft:nftables" "ss:iproute2" "ip:iproute2" "flock:util-linux" "pkill:procps" "sysctl:procps"
    "uptime:procps" "getent:libc-bin" "clear:ncurses-bin" "awk:mawk"
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
      sleep 5
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
  found=$(find "$tmp" -type f -name sing-box | head -1)
  [ -n "$found" ] || { rm -rf "$tmp"; tell_warn "未找到二进制文件"; return 1; }
  install -m755 "$found" "$CORE"
  rm -rf "$tmp"
  core_cache_reset
  state_set asset "$asset"
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

sync_bypass_rules(){
  local port new_ports old_ports4 old_ports6
  new_ports=$(protected_ports)
  old_ports4=$(ip -4 rule show pref "$BYPASS_PREF" 2>/dev/null | grep 'sport' | sed -n 's/.*sport \([0-9]\+\).*/\1/p' | sort -u)
  old_ports6=$(ip -6 rule show pref "$BYPASS_PREF" 2>/dev/null | grep 'sport' | sed -n 's/.*sport \([0-9]\+\).*/\1/p' | sort -u)
  for port in $new_ports; do
    grep -qx "$port" <<<"$old_ports4" || ip -4 rule add pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null
    grep -qx "$port" <<<"$old_ports6" || ip -6 rule add pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null
  done
  for port in $old_ports4; do
    grep -qx "$port" <<<"$new_ports" || ip -4 rule del pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null
  done
  for port in $old_ports6; do
    grep -qx "$port" <<<"$new_ports" || ip -6 rule del pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null
  done
  ip -4 rule del pref "$BYPASS_PREF" fwmark 255 lookup main 2>/dev/null
  ip -4 rule add pref "$BYPASS_PREF" fwmark 255 lookup main 2>/dev/null
  ip -6 rule del pref "$BYPASS_PREF" fwmark 255 lookup main 2>/dev/null
  ip -6 rule add pref "$BYPASS_PREF" fwmark 255 lookup main 2>/dev/null
}

bypass_rules_present(){ [ -n "$(ip rule show pref "$BYPASS_PREF" 2>/dev/null)" ]; }

sync_hopping_rules(){
  nft delete table inet "$HOP_TABLE" 2>/dev/null
  local file range port
  file=$(hopping_node) || return 0
  range=$(jq -r '.hopping' "$file"); port=$(jq -r '.port' "$file")
  nft add table inet "$HOP_TABLE" 2>/dev/null || return 0
  nft add chain inet "$HOP_TABLE" prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null
  nft add rule inet "$HOP_TABLE" prerouting iifname != "lo" iifname != "$WG_IF" iifname != "$TUN_IF" udp dport "$range" redirect to :"$port" 2>/dev/null
}

clear_hopping_rules(){ nft delete table inet "$HOP_TABLE" 2>/dev/null; }

wg_server_nat_apply(){
  local prev4 prev6
  prev4=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  prev6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)
  if [ -f "$WG_CONF" ]; then
    if ! jq -e 'has("nat_prev_ipv4_forward") and has("nat_prev_ipv6_forward")' "$WG_CONF" >/dev/null 2>&1; then
      json_edit "$WG_CONF" '.nat_prev_ipv4_forward=$v4|.nat_prev_ipv6_forward=$v6' --argjson v4 "$prev4" --argjson v6 "$prev6" >/dev/null 2>&1 || true
    fi
  fi
  if [ -f /etc/sysctl.d/99-sbm-forward.conf ] && [ ! -f /etc/sysctl.d/99-sbm-forward.conf.sbm-backup ]; then
    cp -a /etc/sysctl.d/99-sbm-forward.conf /etc/sysctl.d/99-sbm-forward.conf.sbm-backup 2>/dev/null || true
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
  cat >/etc/sysctl.d/99-sbm-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  local out4 out6
  out4=$(default_iface_v4); out6=$(default_iface_v6)
  nft delete table ip sbm_nat 2>/dev/null
  nft add table ip sbm_nat 2>/dev/null
  nft add chain ip sbm_nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null
  [ -n "$out4" ] && nft add rule ip sbm_nat postrouting oifname "$out4" masquerade 2>/dev/null
  nft delete table ip6 sbm_nat 2>/dev/null
  nft add table ip6 sbm_nat 2>/dev/null
  nft add chain ip6 sbm_nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null
  [ -n "$out6" ] && nft add rule ip6 sbm_nat postrouting oifname "$out6" masquerade 2>/dev/null
}

wg_server_nat_remove(){
  local prev4 prev6
  nft delete table ip sbm_nat 2>/dev/null
  nft delete table ip6 sbm_nat 2>/dev/null
  if [ -f "$WG_CONF" ]; then
    prev4=$(jq -r '.nat_prev_ipv4_forward // empty' "$WG_CONF" 2>/dev/null)
    prev6=$(jq -r '.nat_prev_ipv6_forward // empty' "$WG_CONF" 2>/dev/null)
  fi
  [ "$prev4" = 0 ] || [ "$prev4" = 1 ] || prev4=0
  [ "$prev6" = 0 ] || [ "$prev6" = 1 ] || prev6=0
  sysctl -w net.ipv4.ip_forward="$prev4" >/dev/null 2>&1
  sysctl -w net.ipv6.conf.all.forwarding="$prev6" >/dev/null 2>&1
  if [ -f /etc/sysctl.d/99-sbm-forward.conf.sbm-backup ]; then
    mv -f /etc/sysctl.d/99-sbm-forward.conf.sbm-backup /etc/sysctl.d/99-sbm-forward.conf
  else
    rm -f /etc/sysctl.d/99-sbm-forward.conf
  fi
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

build_config(){
  local selected domain inbounds outbounds endpoints rules dns_block final use_tun
  local peer_host node_files tls_extra providers
  local dns_direct_tag dns_strategy auto_detect

  selected=$(state_get exit); domain=$(state_get domain)
  final=direct; use_tun=0; endpoints='[]'; peer_host=""; providers='[]'; tls_extra='{}'

  dns_direct_tag="dns-direct-v4"
  dns_strategy="prefer_ipv4"
  if [ "$NET_STACK" = "v6" ]; then
    dns_direct_tag="dns-direct-v6"
    dns_strategy="prefer_ipv6"
  elif [ "$NET_STACK" = "both" ] && [ "$IPV6_OK" = "1" ]; then
    dns_direct_tag="dns-direct-v6"
    dns_strategy="prefer_ipv6"
  fi

  node_files=("$NODE_DIR"/*.json)
  inbounds='[]'
  if [ ${#node_files[@]} -gt 0 ]; then
    if [ -n "$domain" ]; then
      providers=$(jq -n --arg t "$CERT_TAG" --argjson a "$(acme_options "$domain")" '[$a+{type:"acme",tag:$t}]')
      tls_extra=$(jq -n --arg t "$CERT_TAG" '{certificate_provider:$t}')
    fi
    inbounds=$(jq -s --arg d "$domain" --argjson x "$tls_extra" '
      [ .[] |
        (if .kind=="hysteria2" and ((.inbound.up_mbps//0)>0 or (.inbound.down_mbps//0)>0)
           then .meta = (.meta | del(.bbr_profile))
           else . end) |
        .inbound as $in |
        ($in | if .type=="hysteria2" and ((.up_mbps//0)>0 or (.down_mbps//0)>0)
                then del(.bbr_profile)
                else . end) as $in2 |
        if .tls_mode=="acme" then
          $in2 * {tls: ({enabled:true,server_name:$d}
                       + (if .alpn then {alpn:.alpn} else {} end)
                       + $x)}
        else $in2 end ]' "${node_files[@]}") || return 1
  fi

  outbounds='[{"type":"direct","tag":"direct"}]'

  if [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then
    if [ "$(jq -r .role "$WG_CONF")" = client ]; then
      if [ "$selected" = "direct" ] || [ "$selected" = "wireguard" ]; then
        endpoints=$(jq --arg resolver "$dns_direct_tag" '[.endpoint | .domain_resolver = $resolver]' "$WG_CONF")
        peer_host=$(jq -r '.peer_host//""' "$WG_CONF")
        final="wireguard"; use_tun=1
      fi
    else
      endpoints=$(jq --arg resolver "$dns_direct_tag" '[.endpoint | .domain_resolver = $resolver]' "$WG_CONF")
    fi
  fi

  if [ "$selected" != direct ] && [ "$selected" != wireguard ]; then
    if [ -f "$PEER_DIR/$selected.json" ]; then
      outbounds=$(jq -n --argjson base "$outbounds" --slurpfile peer "$PEER_DIR/$selected.json" \
        --arg resolver "$dns_direct_tag" '$base + [$peer[0].outbound + {domain_resolver:$resolver}]')
      final=$selected; use_tun=1
      peer_host=$(jq -r '.outbound.server//""' "$PEER_DIR/$selected.json")
    else
      tell_warn "出口节点 $selected 文件不存在，回退直连"; final=direct
    fi
  fi

  if [ "$use_tun" = 1 ]; then
    inbounds=$(jq -n --argjson list "$inbounds" --arg name "$TUN_IF" '
      [{type:"tun",tag:"tun-in",interface_name:$name,
        address:["172.19.0.1/30","fdfe:dcba:9876::1/126"],
        dns_mode:"hijack",
        dns_address:["172.19.0.2","fdfe:dcba:9876::2"],
        auto_route:true,auto_redirect:true,strict_route:true,
        stack:"mixed",mtu:1500}] + $list')
  fi

  rules=$(jq -n --arg host "$peer_host" '
    [{network:"icmp",action:"route",outbound:"direct"},
     {action:"sniff"},
     {protocol:"dns",action:"hijack-dns"}]
    + (if $host=="" then []
       elif ($host | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) then
         [{ip_cidr:[($host+"/32")],action:"route",outbound:"direct"}]
       elif ($host | test("^[0-9a-fA-F:]+$")) then
         [{ip_cidr:[($host+"/128")],action:"route",outbound:"direct"}]
       else
         [{domain:[$host],action:"route",outbound:"direct"}]
       end)')

  if [ "$use_tun" = 1 ]; then auto_detect="true"; else auto_detect="false"; fi

  dns_block=$(jq -n --arg direct_tag "$dns_direct_tag" --arg strategy "$dns_strategy" --arg detour "$final" '
    {servers:[
      {type:"https",tag:"dns-direct-v4",server:"1.1.1.1",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}},
      {type:"https",tag:"dns-direct-v6",server:"2606:4700:4700::1111",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}},
      {type:"https",tag:"dns-remote",server:"cloudflare-dns.com",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"},domain_resolver:$direct_tag}
    ]}
    | .servers[2] |= (if $detour != "direct" then . + {detour:$detour} else . end)
    | {servers:.servers,final:"dns-remote",strategy:$strategy}')

  jq -n --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" \
        --argjson endpoints "$endpoints" --argjson rules "$rules" \
        --argjson dns "$dns_block" --argjson providers "$providers" \
        --arg final "$final" --arg direct_tag "$dns_direct_tag" --argjson auto_detect "$auto_detect" '
    {log:{level:"warn",timestamp:true},
     dns:$dns,
     inbounds:$inbounds,
     outbounds:$outbounds,
     route:{rules:$rules,final:$final,
            default_domain_resolver:$direct_tag,
            auto_detect_interface:$auto_detect}}
    | if ($endpoints|length)>0 then .endpoints=$endpoints else . end
    | if ($providers|length)>0 then .certificate_providers=$providers else . end'
}

apply_config(){
  local tmp error line guard=0 prev_conf=""
  tmp=$(mktemp); TMP_FILES="$TMP_FILES $tmp"
  if [ -f "$CONFIG" ]; then
    prev_conf=$(mktemp); TMP_FILES="$TMP_FILES $prev_conf"; cp "$CONFIG" "$prev_conf"
  fi
  build_config >"$tmp" 2>/dev/null || { rm -f "$tmp"; tell_warn "配置生成失败"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; tell_warn "配置写入异常"; return 1; }
  if ! error=$("$CORE" check -c "$tmp" 2>&1); then
    tell_warn "配置校验未通过:"
    while IFS= read -r line; do tell "    $line"; done <<<"$(head -4 <<<"$error")"
    rm -f "$tmp"; return 1
  fi
  install -m600 "$tmp" "$CONFIG"; rm -f "$tmp"
  if ! timeout 15 systemctl reload-or-restart sing-box >/dev/null 2>&1; then
    tell_warn "sing-box 重载/重启失败，正在回滚配置"
    if [ -n "$prev_conf" ] && [ -s "$prev_conf" ]; then
      install -m600 "$prev_conf" "$CONFIG"; timeout 15 systemctl restart sing-box >/dev/null 2>&1
    else
      rm -f "$CONFIG"; timeout 15 systemctl stop sing-box >/dev/null 2>&1
    fi
    return 1
  fi
  while ! systemctl is-active --quiet sing-box; do
    sleep 0.2; guard=$((guard+1)); [ "$guard" -gt 15 ] && break
  done
  if ! systemctl is-active --quiet sing-box; then
    tell_warn "服务启动异常:"
    while IFS= read -r line; do tell "    $line"; done <<<"$(journalctl -u sing-box -n 5 --no-pager 2>/dev/null)"
    if [ -n "$prev_conf" ] && [ -s "$prev_conf" ]; then
      install -m600 "$prev_conf" "$CONFIG"; timeout 15 systemctl restart sing-box >/dev/null 2>&1
    fi
    return 1
  fi
  sync_bypass_rules; sync_hopping_rules
  bypass_rules_present || tell_warn "系统内核不支持 sport 路由规则，服务可能中断"
  return 0
}

apply_config_quiet(){ apply_config >/dev/null 2>&1; }

stop_watchdog(){ timeout 15 systemctl stop sbm-watchdog.service 2>/dev/null; systemctl reset-failed 'sbm-watchdog*' 2>/dev/null; }

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
  local target_exit="" current="" result="" i=0
  load_net_cache
  while [ "$i" -lt 60 ] && [ ! -d "/sys/class/net/$TUN_IF" ] && systemctl is-active --quiet sing-box; do sleep 1; i=$((i+1)); done
  sleep 3
  target_exit=$(state_get exit)
  while :; do
    current=$(state_get exit)
    if [ "$target_exit" = "direct" ]; then
      if curl -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL" || curl -s -o /dev/null --connect-timeout 4 -m 6 "$probe2"; then fail_count=0; else fail_count=$((fail_count+1)); fi
      sleep 120; continue
    fi
    if [ "$current" = "direct" ]; then
      result=$(mktemp) || { sleep 120; continue; }
      if probe_peer_latency "$PEER_DIR/$target_exit.json" "$result" && [ "$(cat "$result" 2>/dev/null)" = ok ]; then
        fail_count=0; state_set exit "$target_exit"
        apply_config_quiet || { state_set exit direct; }
      else
        fail_count=$((fail_count+1))
      fi
      rm -f "$result"
    else
      if curl -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL" || curl -s -o /dev/null --connect-timeout 4 -m 6 "$probe2"; then fail_count=0; else
        fail_count=$((fail_count+1))
        if [ "$fail_count" -ge 3 ]; then
          fail_count=0; state_set exit direct
          if ! apply_config_quiet; then state_set exit "$target_exit"; apply_config_quiet; fi
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
  ipv4=$NET_IPV4; ipv6=$NET_IPV6
  if ! { [ -n "$ipv4" ] && grep -qx "$ipv4" <<<"$resolved"; } && ! { [ -n "$ipv6" ] && grep -qx "$ipv6" <<<"$resolved"; }; then
    tell_warn "域名解析地址与本地 IP 不匹配"; return 1
  fi
  case $(state_get challenge) in
    http) grep -qx 80 <<<"$(listening_ports t)" && { tell_warn "本机 80 端口已被占用"; return 1; } ;;
    alpn) grep -qx 443 <<<"$(listening_ports t)" && { tell_warn "本机 443 端口已被占用"; return 1; } ;;
  esac
  tell_ok "解析记录正常"; return 0
}

certificate_ready(){
  local domain=$1 cert key cert_pub key_pub file
  [ -n "$domain" ] || return 1
  cert=""
  while IFS= read -r file; do
    if openssl x509 -in "$file" -noout -checkhost "$domain" >/dev/null 2>&1; then
      cert="$file"
      break
    fi
  done < <(find "$ACME_DIR" -type f \( -name '*.crt' -o -name '*.pem' \) 2>/dev/null)
  [ -n "$cert" ] || return 1
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
  while IFS= read -r key; do
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
    cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
    [ -n "$key_pub" ] && [ "$key_pub" = "$cert_pub" ] && return 0
  done < <(find "$ACME_DIR" -type f \( -name '*.key' -o -name '*.pem' \) 2>/dev/null)
  return 1
}

wait_for_certificate(){
  local domain=$1 start=$SECONDS
  tell "等待证书签发完成: $domain"
  while :; do
    if certificate_ready "$domain"; then
      tell_ok "证书已成功签发并完成校验"
      return 0
    fi
    if ! systemctl is-active --quiet sing-box; then
      tell_warn "sing-box 已停止，证书签发失败"
      return 1
    fi
    if [ $((SECONDS-start)) -ge 60 ]; then
      tell_warn "证书签发超时，已停止创建"
      return 1
    fi
    sleep 3
  done
}

setup_certificate(){
  local suggest=${1:-} domain email mode
  [ -n "$(state_get domain)" ] && [ -n "$(state_get email)" ] && return 0
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; return 1; }
  printf '\n  %b该协议需要绑定域名并签发证书%b\n' "${YELLOW}" "${PLAIN}"
  if [ -n "$suggest" ]; then
    domain="$suggest"; printf '  %b已指定域名: %s%b\n' "${GREEN}" "$domain" "${PLAIN}"
  else domain=$(prompt "输入域名"); [ -n "$domain" ] || return 1; fi
  email=$(prompt "ACME 通知邮箱" "admin@$domain"); [ -n "$email" ] || return 1
  printf '\n  %b选择域名证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
  echo "  1. HTTP         (推荐 需放行80端口)"
  echo "  2. TLS-ALPN     (推荐 需放行443端口)"
  echo "  3. Cloudflare API"
  echo "  4. 阿里云 DNS API"
  echo "  5. ACME-DNS API"
  while :; do
    case $(prompt "请选择方式" 1) in
      1) mode=http; break ;;
      2) mode=alpn; break ;;
      3) mode=dns_cloudflare; state_set cf_token "$(prompt 'Cloudflare API Token')"; break ;;
      4) mode=dns_alidns; state_set ali_key "$(prompt 'AccessKeyId')"; state_set ali_secret "$(prompt 'AccessKeySecret')"; break ;;
      5) mode=dns_acmedns
         state_set acmedns_url "$(prompt 'server_url')"; state_set acmedns_user "$(prompt 'username')"
         state_set acmedns_pass "$(prompt 'password')"; state_set acmedns_sub "$(prompt 'subdomain')"; break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
  state_set challenge "$mode"; state_set domain "$domain"; state_set email "$email"
  if ! validate_domain "$domain"; then
    prompt_yes "验证存在异常，是否强制继续" || { state_set domain ""; state_set email ""; return 1; }
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
  local file=$1 content=$2 old_state
  old_state=$(cat "$STATE")
  json_save "$file" "$content" || { tell_warn "数据写入失败"; wait_key; return 1; }
  if apply_config; then
    if [ "$(jq -r .tls_mode "$file" 2>/dev/null)" = acme ]; then
      if ! wait_for_certificate "$(state_get domain)"; then
        rm -f "$file"
        printf '%s\n' "$old_state" | json_write "$STATE"
        apply_config_quiet
        tell_warn "证书未成功签发，已回滚协议与域名状态"
        wait_key
        return 1
      fi
    fi
    tell_ok "协议应用成功"; printf "\n"; render_share_uri "$file"
  else
    rm -f "$file"; apply_config_quiet; tell_warn "配置应用失败，已回滚"; fi
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
          [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ] && break
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
  if [ "$kind" = "snell" ]; then tell_alert "Snell 分享链接可能不被所有客户端识别，请手动复制 PSK"; fi
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
  local was_acme old_json previous_exit
  was_acme=$(jq -r .tls_mode "$PICKED"); old_json=$(cat "$PICKED"); previous_exit=$(state_get exit)
  if [ "$(jq -r .tag "$PICKED")" = "$previous_exit" ]; then state_set exit direct; stop_watchdog; fi
  rm -f "$PICKED"
  if apply_config; then
    tell_ok "已删除"
    if [ "$was_acme" = "acme" ]; then
      local acme_count=0
      for f in "$NODE_DIR"/*.json; do [ "$(jq -r .tls_mode "$f")" = "acme" ] && acme_count=$((acme_count+1)); done
      if [ "$acme_count" -eq 0 ] && [ -n "$(state_get domain)" ]; then
        printf "\n"
        if prompt_yes "是否连同域名和证书一起清理"; then
          state_set domain ""; state_set email ""; state_set challenge "http"
          find "$ACME_DIR" -mindepth 1 -delete 2>/dev/null; tell_ok "相关配置已清理"
        fi
      fi
    fi
  else
    json_save "$PICKED" "$old_json"; state_set exit "$previous_exit"; apply_config_quiet; sync_watchdog; tell_warn "删除导致配置异常，已安全回滚"
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
                  [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ] && break
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
    if apply_config; then tell_ok "已生效"; printf "\n"; render_share_uri "$PICKED"
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
  local new_domain old_domain old_email old_challenge file count=0
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
  if prompt_yes "同步重置验证机制"; then
    state_set domain ""; state_set email ""
    if ! setup_certificate "$new_domain"; then
      state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"; return
    fi
  else
    validate_domain "$new_domain" || prompt_yes "验证未通过，强制写入" || return
    state_set domain "$new_domain"
  fi
  if apply_config; then
    if ! wait_for_certificate "$new_domain"; then
      state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"
      apply_config_quiet; tell_warn "证书未成功签发，域名配置已回滚"; wait_key
    else
      menu_server_info
    fi
  else
    state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"
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
         previous=$(state_get exit); state_set exit direct; stop_watchdog
         if timeout 15 systemctl stop sing-box 2>/dev/null; then
           if build_config | json_write "$CONFIG"; then tell_ok "已停止"; else tell_warn "服务已停止，但配置同步失败"; fi
         else state_set exit "$previous"; sync_watchdog; tell_warn "操作异常，已回滚"; fi
         wait_key ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

parse_uri(){
  local raw=$1 rest tail
  URI_SCHEME=${raw%%://*}; rest=${raw#*://}
  case $rest in *\#*) rest=${rest%%\#*} ;; esac
  URI_QUERY=""; case $rest in *\?*) URI_QUERY=${rest#*\?}; rest=${rest%%\?*} ;; esac
  rest=${rest%%/*}
  URI_USERINFO=""; case $rest in *@*) URI_USERINFO=$(uri_decode "${rest%@*}"); rest=${rest##*@} ;; esac
  URI_PORT=443
  case $rest in
    \[*\]*) URI_HOST=${rest%%\]*}; URI_HOST=${URI_HOST#\[}; tail=${rest##*\]}
            [ -n "${tail#:}" ] && URI_PORT=${tail#:} ;;
    *:*) URI_HOST=${rest%%:*}; URI_PORT=${rest##*:} ;;
    *) URI_HOST=$rest ;;
  esac
  if ! [[ "$URI_PORT" =~ ^[0-9]+$ ]] || [ "$URI_PORT" -lt 1 ] || [ "$URI_PORT" -gt 65535 ]; then URI_PORT=443; fi
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
  local name uri tag outbound probe ipv4 ipv6 domain port ip resolved_hosts
  clear; tell "${CYAN}========== 添加节点 ==========${PLAIN}"
  name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return
  uri=$(prompt "节点链接"); [ -n "$uri" ] || return
  parse_uri "$uri"
  ipv4=$NET_IPV4; ipv6=$NET_IPV6; domain=$(state_get domain)
  resolved_hosts=$(resolve_addresses "$URI_HOST")
  for port in $(node_ports); do
    if [ "$URI_PORT" = "$port" ]; then
      if [ "$URI_HOST" = "127.0.0.1" ] || [ "$URI_HOST" = "localhost" ] || [ "$URI_HOST" = "::1" ]; then tell_warn "禁止自环接入"; wait_key; return; fi
      for ip in $resolved_hosts; do
        if [ "$ip" = "$ipv4" ] || [ "$ip" = "$ipv6" ]; then tell_warn "禁止自环接入"; wait_key; return; fi
      done
      if [ -n "$domain" ] && [ "$URI_HOST" = "$domain" ]; then tell_warn "禁止自环接入"; wait_key; return; fi
    fi
  done
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag") || { tell_warn "无法解析"; wait_key; return; }
  probe=$(mktemp); TMP_FILES="$TMP_FILES $probe"
  jq -n --argjson ob "$outbound" '{log:{level:"error"},outbounds:[$ob,{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$probe"
  if "$CORE" check -c "$probe" >/dev/null 2>&1; then
    json_save "$PEER_DIR/$tag.json" "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" '{tag:$tag,name:$name,uri:$uri,outbound:$ob}')"
    tell_ok "挂载完成: $name"
  else
    tell_warn "校验拦截:"; "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2
  fi
  rm -f "$probe"; wait_key
}

probe_peer_latency(){
  local file=$1 result=$2 cfg port pid resolver node_tag
  node_tag=$(jq -r '.tag' "$file" 2>/dev/null) || { echo fail >"$result"; return; }
  if [ "$NET_STACK" = v6 ] && [ "$IPV6_OK" = 1 ]; then resolver=dns-direct-v6; else resolver=dns-direct-v4; fi
  port=""
  for _ in {1..10}; do
    port=$(random_port)
    ss -Hln 2>/dev/null | grep -qE ":${port}( |$)" || break
    port=""
  done
  [ -n "$port" ] || { echo fail >"$result"; return; }
  cfg=$(mktemp) || { echo fail >"$result"; return; }
  TMP_FILES="$TMP_FILES $cfg"
  jq -n --slurpfile peer "$file" --argjson port "$port" --arg tag "$node_tag" --arg resolver "$resolver" '
    {log:{level:"error"},
     dns:{servers:[
       {type:"https",tag:"dns-direct-v4",server:"1.1.1.1",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}},
       {type:"https",tag:"dns-direct-v6",server:"2606:4700:4700::1111",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}}
     ],final:$resolver,strategy:"prefer_ipv6"},
     inbounds:[{type:"mixed",tag:"probe",listen:"127.0.0.1",listen_port:$port}],
     outbounds:[($peer[0].outbound + {domain_resolver:$resolver}),{type:"direct",tag:"direct"}],
     route:{rules:[{inbound:["probe"],action:"route",outbound:$tag}],final:"direct",default_domain_resolver:$resolver}}' >"$cfg" 2>/dev/null || { rm -f "$cfg"; echo fail >"$result"; return; }
  "$CORE" check -c "$cfg" >/dev/null 2>&1 || { rm -f "$cfg"; echo fail >"$result"; return; }
  "$CORE" run -c "$cfg" >/dev/null 2>&1 &
  pid=$!
  for _ in {1..30}; do
    ss -Hln 2>/dev/null | grep -qE ":${port}( |$)" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null && curl -x "http://127.0.0.1:$port" -s -o /dev/null --connect-timeout 3 -m 6 "$PROBE_URL"; then
    echo ok >"$result"
  elif kill -0 "$pid" 2>/dev/null && curl -x "http://127.0.0.1:$port" -s -o /dev/null --connect-timeout 3 -m 6 "http://captive.apple.com/hotspot-detect.html"; then
    echo ok >"$result"
  else
    echo fail >"$result"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$cfg"
}

list_peers(){
  local current=$(state_get exit)
  local title=${1:-节点选择}
  PEER_COUNT=0; PEER_FILES=(); PEER_TAGS=(); PEER_TYPES=(); PEER_NAMES=(); PEER_PORTS=()
  set -- "$PEER_DIR"/*.json
  [ ! -e "$1" ] && { clear; tell "${CYAN}========== $title ==========${PLAIN}"; tell "  暂无外部节点"; return 0; }
  local tmp_dir; tmp_dir=$(mktemp -d); TMP_FILES="$TMP_FILES $tmp_dir"
  local idx=0 raw_data old_ifs test_pids=""
  raw_data=$(jq -r '"\(input_filename)|\(.tag//"-")|\(.outbound.type//"-")|\(.name//"-")|\(.outbound.server_port // (if .outbound.server_ports then (.outbound.server_ports[0]|gsub(":";"-")) else null end) // .outbound.listen_port // "-")"' "$@" 2>/dev/null)
  if [ -n "$raw_data" ]; then
    old_ifs="$IFS"; IFS="|"
    while read -r file tag type name port; do
      idx=$((idx+1)); PEER_FILES+=("$file"); PEER_TAGS+=("$tag"); PEER_TYPES+=("$type"); PEER_NAMES+=("$name"); PEER_PORTS+=("$port")
      ( probe_peer_latency "$file" "$tmp_dir/res_$idx" ) &
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
    if [ "$ms" = "ok" ]; then color="$GREEN"; status_text="[可用]"
    else color="$RED"; status_text="[不可用]"; fi
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

peer_select(){
  local tag previous target_name wg_was_active=0
  select_peer "接管/选择节点" || return
  tag=$(jq -r .tag "$PICKED"); target_name=$(jq -r '.name // .tag' "$PICKED"); previous=$(state_get exit)
  if wg_client_active; then
    prompt_yes "当前 WireGuard 客户端正在接管网络。
启动 ${target_name} 后，网络出口将切换至 ${target_name}。
是否切换" || return
    json_edit "$WG_CONF" '.enabled=false' || return
    wg_was_active=1
  fi
  state_set exit "$tag"; stop_watchdog
  if apply_config; then sync_watchdog; tell_ok "已接管: $target_name"
  else
    state_set exit "$previous"
    if [ "$wg_was_active" = 1 ]; then json_edit "$WG_CONF" '.enabled=true' || tell_warn "WireGuard 状态恢复失败，请手动检查"; fi
    apply_config_quiet; sync_watchdog; tell_warn "切换失败已回滚"
  fi
  wait_key
}

peer_delete(){
  while :; do
    select_peer "删除节点" || return
    local old_json previous_exit
    old_json=$(cat "$PICKED"); previous_exit=$(state_get exit)
    if [ "$(jq -r .tag "$PICKED")" = "$previous_exit" ]; then
      state_set exit direct; stop_watchdog; rm -f "$PICKED"
      if apply_config; then
        tell_ok "已删除当前生效节点，已恢复直连"
        if [ "$(jq -r '.enabled//false' "$WG_CONF" 2>/dev/null)" != "true" ]; then ip link del "$WG_IF" 2>/dev/null; fi
      else
        json_save "$PICKED" "$old_json"; state_set exit "$previous_exit"; apply_config_quiet; sync_watchdog
        tell_warn "删除导致配置异常，节点与网络出口已安全回滚"
        wait_key
      fi
    else
      rm -f "$PICKED"
      if apply_config; then tell_ok "已删除节点"
      else json_save "$PICKED" "$old_json"; apply_config_quiet; tell_warn "删除导致配置异常，已安全回滚"; wait_key; fi
    fi
  done
}

peer_stop(){
  clear; local previous; previous=$(state_get exit)
  state_set exit direct; stop_watchdog
  if apply_config; then tell_ok "已恢复直连"
  else state_set exit "$previous"; apply_config_quiet; sync_watchdog; tell_warn "恢复直连失败，已回滚"; fi
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
  local proxy_name="直连" protocol=""
  if [ "$exit_node" = "wireguard" ]; then
    proxy_name="WireGuard"
  elif [ "$exit_node" != "direct" ] && [ -f "$PEER_DIR/$exit_node.json" ]; then
    proxy_name=$(jq -r '.name // .tag // "未知"' "$PEER_DIR/$exit_node.json" 2>/dev/null)
    protocol=$(jq -r '.outbound.type // ""' "$PEER_DIR/$exit_node.json" 2>/dev/null)
    case "$protocol" in
      vless) protocol="VLESS" ;;
      vmess) protocol="VMess" ;;
      hysteria2) protocol="Hysteria2" ;;
      tuic) protocol="TUIC" ;;
      trojan) protocol="Trojan" ;;
      shadowsocks) protocol="Shadowsocks" ;;
      socks) protocol="SOCKS" ;;
      http) protocol="HTTP" ;;
      *) protocol="${protocol:-未知}" ;;
    esac
    proxy_name="$proxy_name $protocol"
  fi
  tell "  网络接管：${CYAN}${proxy_name}${PLAIN}"; tell ""
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
  local peer_ip4=$1 peer_ip6=$2
  [ -d "/sys/class/net/$WG_IF" ] || { echo down; return; }
  if curl --interface "$WG_IF" -4 -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL"; then echo up; return; fi
  if curl --interface "$WG_IF" -6 -s -o /dev/null --connect-timeout 4 -m 6 https://ipv6.icanhazip.com; then echo up; return; fi
  echo down
}

wg_keypair(){
  local keypair private public
  keypair=$("$CORE" generate wg-keypair 2>/dev/null) || return 1
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] && [ -n "$public" ] || return 1
  WG_PRIVATE="$private"
  WG_PUBLIC="$public"
}

wg_default_address(){
  local role=$1
  if [ "$role" = server ]; then
    WG_IPV4="10.7.0.1/24"
    WG_IPV6="fd00:7::1/64"
    WG_PEER_IPV4="10.7.0.2"
    WG_PEER_IPV6="fd00:7::2"
  else
    WG_IPV4="10.7.0.2/32"
    WG_IPV6="fd00:7::2/128"
    WG_PEER_IPV4="10.7.0.1"
    WG_PEER_IPV6="fd00:7::1"
  fi
}

wg_valid_address(){
  local value=$1 prefix ip octet
  [[ $value == */* ]] || return 1
  ip=${value%/*}; prefix=${value#*/}
  [[ $prefix =~ ^[0-9]+$ ]] || return 1
  if [[ $ip == *:* ]]; then
    [ "$prefix" -le 128 ] || return 1
    getent ahostsv6 "$ip" >/dev/null 2>&1
  else
    [ "$prefix" -le 32 ] || return 1
    IFS=. read -r -a octet <<<"$ip"
    [ "${#octet[@]}" -eq 4 ] || return 1
    for value in "${octet[@]}"; do
      [[ $value =~ ^[0-9]+$ ]] && [ "$value" -le 255 ] || return 1
    done
  fi
}

wg_prompt_address(){
local current4 current6 value
  current4=$(jq -r '.address[0] // ""' "$WG_CONF")
  current6=$(jq -r '.address[1] // ""' "$WG_CONF")
  while :; do
    value=$(prompt "IPv4" "$current4")
    wg_valid_address "$value" || { tell_warn "IPv4 地址无效"; continue; }
    WG_EDIT_IPV4="$value"
    break
  done
  while :; do
    value=$(prompt "IPv6" "$current6")
    [[ $value == *:*/* ]] || { tell_warn "IPv6 地址无效"; continue; }
    wg_valid_address "$value" || { tell_warn "IPv6 地址无效"; continue; }
    WG_EDIT_IPV6="$value"
    break
  done
}

wg_save(){
  json_save "$WG_CONF" "$1"
}

wg_status(){
  local file=$WG_CONF role state
  clear
  [ -f "$file" ] || { tell_warn "未配置 WireGuard"; wait_key; return; }
  role=$(jq -r '.role // ""' "$file")
  tell "${CYAN}========== WireGuard 状态 ==========${PLAIN}"
  if [ "$role" = server ]; then tell "  角色: 服务端"; else tell "  角色: 客户端"; fi
  local public ipv4 ipv6 listen_port peer_key peer_host peer_port
  public=$(jq -r '.public_key // empty' "$file")
  ipv4=$(jq -r '.address[0] // empty' "$file")
  ipv6=$(jq -r '.address[1] // empty' "$file")
  tell "  本机公钥: $public"
  tell "  IPv4: $ipv4"
  tell "  IPv6: $ipv6"
  if [ "$role" = server ]; then
    listen_port=$(jq -r '.listen_port // empty' "$file")
    peer_key=$(jq -r '.peer_public_key // empty' "$file")
    tell "  监听端口: $listen_port"
    tell "  客户端公钥: $peer_key"
  else
    peer_host=$(jq -r '.peer_host // empty' "$file")
    peer_port=$(jq -r '.peer_port // empty' "$file")
    peer_key=$(jq -r '.peer_public_key // empty' "$file")
    tell "  服务端: $peer_host"
    tell "  服务端端口: $peer_port"
    tell "  服务端公钥: $peer_key"
  fi
  if [ "$(jq -r '.enabled//false' "$file")" = true ]; then tell "  状态: ${GREEN}运行中${PLAIN}"; else tell "  状态: ${RED}已停止${PLAIN}"; fi
  if [ "$role" = client ] && [ "$(jq -r '.enabled//false' "$file")" = true ]; then
    local peer_ip4 peer_ip6
    peer_ip4=$(jq -r '.peer_ip // empty' "$file")
    peer_ip6=$(jq -r '.peer_ip6 // empty' "$file")
    state=$(wg_tunnel_state "$peer_ip4" "$peer_ip6")
    [ "$state" = up ] && tell_ok "连接正常" || tell_warn "连接失败"
  fi
  wait_key
}

wg_init_server(){
  local port peer_key body
  clear
  tell "${CYAN}========== WireGuard 服务端 ==========${PLAIN}"
  wg_keypair || { tell_warn "密钥生成失败"; wait_key; return; }
  tell "  本机公钥: $WG_PUBLIC"
  echo ""
  port=$(prompt_port u "51820") || return
  while :; do
    peer_key=$(prompt "客户端公钥")
    [ -n "$peer_key" ] && break
    tell_warn "客户端公钥不能为空"
  done
  wg_default_address server
  body=$(jq -n \
    --arg private "$WG_PRIVATE" --arg public "$WG_PUBLIC" \
    --arg a4 "$WG_IPV4" --arg a6 "$WG_IPV6" \
    --arg peer4 "$WG_PEER_IPV4" --arg peer6 "$WG_PEER_IPV6" \
    --arg peer_key "$peer_key" --arg iface "$WG_IF" --argjson port "$port" \
    '{role:"server",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:$port,
      peer_public_key:$peer_key,peer_ip:$peer4,peer_ip6:$peer6,peer_host:"",peer_port:0,
      endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1280,
        address:[$a4,$a6],private_key:$private,listen_port:$port,
        peers:[{public_key:$peer_key,allowed_ips:[($peer4+"/32"),($peer6+"/128")] }]}}')
  wg_save "$body" || { tell_warn "保存失败"; wait_key; return; }
  apply_config || { tell_warn "配置校验失败"; wait_key; return; }
  tell_ok "配置完成"
  wg_status
}

wg_init_client(){
  local host port peer_key body
  clear
  tell "${CYAN}========== WireGuard 客户端 ==========${PLAIN}"
  wg_keypair || { tell_warn "密钥生成失败"; wait_key; return; }
  tell "  本机公钥: $WG_PUBLIC"
  echo ""
  host=$(prompt "服务端地址")
  [ -n "$host" ] || { tell_warn "服务端地址不能为空"; wait_key; return; }
  port=$(prompt_port u "51820") || return
  while :; do
    peer_key=$(prompt "服务端公钥")
    [ -n "$peer_key" ] && break
    tell_warn "服务端公钥不能为空"
  done
  wg_default_address client
  body=$(jq -n \
    --arg private "$WG_PRIVATE" --arg public "$WG_PUBLIC" \
    --arg a4 "$WG_IPV4" --arg a6 "$WG_IPV6" \
    --arg peer4 "$WG_PEER_IPV4" --arg peer6 "$WG_PEER_IPV6" \
    --arg host "$host" --arg peer_key "$peer_key" --arg iface "$WG_IF" --argjson port "$port" \
    '{role:"client",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:0,
      peer_public_key:$peer_key,peer_ip:$peer4,peer_ip6:$peer6,peer_host:$host,peer_port:$port,
      endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1280,
        address:[$a4,$a6],private_key:$private,
        peers:[{address:$host,port:$port,public_key:$peer_key,
          allowed_ips:["0.0.0.0/0","::/0"]}]}}')
  wg_save "$body" || { tell_warn "保存失败"; wait_key; return; }
  apply_config || { tell_warn "配置校验失败"; wait_key; return; }
  tell_ok "配置完成"
  wg_status
}

wg_init(){
  clear
  tell "${CYAN}========== 初始化配置 ==========${PLAIN}"
  tell "  1. 服务端"
  tell "  2. 客户端"
  tell "  0. 返回"
  case $(prompt "请选择") in
    1) role=server; wg_init_server ;;
    2) role=client; wg_init_client ;;
    0) return ;;
    *) tell_warn "输入无效"; sleep 1 ;;
  esac
}

wg_edit_address(){
  local body
  clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  tell "${CYAN}========== 内网双栈地址 ==========${PLAIN}"
  tell "  IPv4: $(jq -r '.address[0] // ""' "$WG_CONF")"
  tell "  IPv6: $(jq -r '.address[1] // ""' "$WG_CONF")"
  echo ""
  wg_prompt_address
  body=$(jq --arg a4 "$WG_EDIT_IPV4" --arg a6 "$WG_EDIT_IPV6" '.address=[$a4,$a6]|.endpoint.address=[$a4,$a6]' "$WG_CONF") || { tell_warn "地址生成失败"; wait_key; return; }
  wg_save "$body" || { tell_warn "保存失败"; wait_key; return; }
  if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then
    apply_config || { tell_warn "应用失败"; wait_key; return; }
  fi
  tell_ok "已修改"
  wait_key
}

wg_edit_server(){
  local value body
  while :; do
    clear
    tell "${CYAN}========== 修改配置 ==========${PLAIN}"
    tell "  1. 监听端口"
    tell "  2. 客户端公钥"
    tell "  3. 内网双栈地址"
    tell "  0. 返回"
    case $(prompt "请选择") in
      1)
        value=$(prompt_port u "$(jq -r '.listen_port' "$WG_CONF")") || continue
        body=$(jq --argjson port "$value" '.listen_port=$port|.endpoint.listen_port=$port' "$WG_CONF") || continue
        if wg_save "$body"; then
          if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] && ! apply_config; then
            tell_warn "应用失败"
          else
            tell_ok "已修改"
          fi
        else
          tell_warn "保存失败"
        fi
        sleep 1
        ;;
      2)
        value=$(prompt "客户端公钥" "$(jq -r '.peer_public_key // ""' "$WG_CONF")")
        [ -n "$value" ] || { tell_warn "客户端公钥不能为空"; sleep 1; continue; }
        body=$(jq --arg key "$value" '.peer_public_key=$key|.endpoint.peers[0].public_key=$key' "$WG_CONF") || continue
        if wg_save "$body"; then
          if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] && ! apply_config; then
            tell_warn "应用失败"
          else
            tell_ok "已修改"
          fi
        else
          tell_warn "保存失败"
        fi
        sleep 1
        ;;
      3) wg_edit_address ;;
      0) return ;;
      *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
}

wg_edit_client(){
  local value body
  while :; do
    clear
    tell "${CYAN}========== 修改配置 ==========${PLAIN}"
    tell "  1. 服务端地址"
    tell "  2. 服务端端口"
    tell "  3. 服务端公钥"
    tell "  4. 内网双栈地址"
    tell "  0. 返回"
    case $(prompt "请选择") in
      1)
        value=$(prompt "服务端地址" "$(jq -r '.peer_host // ""' "$WG_CONF")")
        [ -n "$value" ] || { tell_warn "服务端地址不能为空"; sleep 1; continue; }
        body=$(jq --arg host "$value" '.peer_host=$host|.endpoint.peers[0].address=$host' "$WG_CONF") || continue
        if wg_save "$body"; then
          if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] && ! apply_config; then
            tell_warn "应用失败"
          else
            tell_ok "已修改"
          fi
        else
          tell_warn "保存失败"
        fi
        sleep 1
        ;;
      2)
        value=$(prompt_port u "$(jq -r '.peer_port' "$WG_CONF")") || continue
        body=$(jq --argjson port "$value" '.peer_port=$port|.endpoint.peers[0].port=$port' "$WG_CONF") || continue
        if wg_save "$body"; then
          if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] && ! apply_config; then
            tell_warn "应用失败"
          else
            tell_ok "已修改"
          fi
        else
          tell_warn "保存失败"
        fi
        sleep 1
        ;;
      3)
        value=$(prompt "服务端公钥" "$(jq -r '.peer_public_key // ""' "$WG_CONF")")
        [ -n "$value" ] || { tell_warn "服务端公钥不能为空"; sleep 1; continue; }
        body=$(jq --arg key "$value" '.peer_public_key=$key|.endpoint.peers[0].public_key=$key' "$WG_CONF") || continue
        if wg_save "$body"; then
          if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] && ! apply_config; then
            tell_warn "应用失败"
          else
            tell_ok "已修改"
          fi
        else
          tell_warn "保存失败"
        fi
        sleep 1
        ;;
      4) wg_edit_address ;;
      0) return ;;
      *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
}

wg_edit(){
  local role
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  role=$(jq -r '.role // ""' "$WG_CONF")
  case "$role" in
    server) wg_edit_server ;;
    client) wg_edit_client ;;
    *) tell_warn "WireGuard 配置无效"; wait_key ;;
  esac
}

wg_delete(){
  local role previous_exit tmp backup_wg backup_conf
  clear
  [ -f "$WG_CONF" ] || { tell_warn "未配置 WireGuard"; wait_key; return; }
  role=$(jq -r '.role // ""' "$WG_CONF" 2>/dev/null)
  prompt_yes "确认删除 WireGuard 配置" || return
  previous_exit=$(state_get exit)
  backup_wg=$(mktemp -d) || { tell_warn "临时目录创建失败"; wait_key; return; }
  backup_conf=$(mktemp) || { rm -rf "$backup_wg"; tell_warn "临时文件创建失败"; wait_key; return; }
  cp -a "$WG_DIR"/. "$backup_wg"/ 2>/dev/null || { rm -rf "$backup_wg" "$backup_conf"; tell_warn "WireGuard 配置备份失败"; wait_key; return; }
  [ -f "$CONFIG" ] && cp -f "$CONFIG" "$backup_conf"
  if [ "$role" = server ]; then wg_server_nat_remove; fi
  if [ "$previous_exit" = wireguard ]; then state_set exit direct; fi
  rm -rf "$WG_DIR"
  mkdir -p "$WG_DIR"
  chmod 700 "$WG_DIR"
  ip link del "$WG_IF" 2>/dev/null || true
  tmp=$(mktemp) || { rm -rf "$WG_DIR"; mkdir -p "$WG_DIR"; cp -a "$backup_wg"/. "$WG_DIR"/; [ "$role" = server ] && wg_server_nat_apply; state_set exit "$previous_exit"; rm -rf "$backup_wg" "$backup_conf"; tell_warn "临时文件创建失败，配置已恢复"; wait_key; return; }
  if build_config >"$tmp" 2>/dev/null && "$CORE" check -c "$tmp" >/dev/null 2>&1; then
    install -m600 "$tmp" "$CONFIG"
    if systemctl is-active --quiet sing-box; then
      if ! timeout 15 systemctl restart sing-box >/dev/null 2>&1; then
        [ -s "$backup_conf" ] && install -m600 "$backup_conf" "$CONFIG"
        rm -rf "$WG_DIR"
        mkdir -p "$WG_DIR"
        cp -a "$backup_wg"/. "$WG_DIR"/
        chmod 700 "$WG_DIR"
        state_set exit "$previous_exit"
        [ "$role" = server ] && wg_server_nat_apply
        timeout 15 systemctl restart sing-box >/dev/null 2>&1 || true
        rm -f "$tmp"; rm -rf "$backup_wg" "$backup_conf"
        tell_warn "删除失败，已恢复原配置"
        wait_key
        return
      fi
    fi
    rm -f "$tmp"; rm -rf "$backup_wg" "$backup_conf"
    sync_bypass_rules
    sync_hopping_rules
    tell_ok "配置已删除"
  else
    rm -f "$tmp"
    rm -rf "$WG_DIR"
    mkdir -p "$WG_DIR"
    cp -a "$backup_wg"/. "$WG_DIR"/
    chmod 700 "$WG_DIR"
    state_set exit "$previous_exit"
    [ "$role" = server ] && wg_server_nat_apply
    rm -rf "$backup_wg" "$backup_conf"
    tell_warn "新配置校验失败，WireGuard 配置已恢复"
  fi
  wait_key
}

wg_toggle(){
  local role previous previous_name
  clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  role=$(jq -r '.role' "$WG_CONF"); previous=$(state_get exit); previous_name=$(exit_label)
  modprobe wireguard 2>/dev/null || true
  if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then
    json_edit "$WG_CONF" '.enabled=false' || { tell_warn "保存失败"; wait_key; return; }
    if [ "$role" = server ]; then wg_server_nat_remove; fi
    if [ "$previous" = wireguard ]; then state_set exit direct; stop_watchdog; fi
    if apply_config; then tell_ok "已停止"; else tell_warn "配置应用失败"; fi
  else
    [ -n "$(jq -r '.peer_public_key // ""' "$WG_CONF")" ] || { tell_warn "缺少对端公钥"; wait_key; return; }
    if [ "$role" = client ] && [ "$previous" != direct ]; then
      prompt_yes "当前 ${previous_name} 正在接管网络。
启动 WireGuard 后，网络出口将切换至 WireGuard。
是否切换" || return
    fi
    json_edit "$WG_CONF" '.enabled=true' || { tell_warn "保存失败"; wait_key; return; }
    if [ "$role" = server ]; then wg_server_nat_apply; fi
    if [ "$role" = client ]; then state_set exit wireguard; stop_watchdog; fi
    if apply_config; then
      [ "$role" = client ] && sync_watchdog
      sleep 2
      tell_ok "已启动"
    else
      json_edit "$WG_CONF" '.enabled=false'
      state_set exit "$previous"
      if [ "$role" = server ]; then wg_server_nat_remove; fi
      apply_config_quiet; sync_watchdog
      tell_warn "启动失败，已回滚"
    fi
  fi
  wait_key
}

menu_wireguard(){
  while :; do
    clear
    tell "${CYAN}========== WireGuard ==========${PLAIN}"
    tell "  1. 初始化配置"
    tell "  2. 修改配置"
    tell "  3. 启动/停止"
    tell "  4. 状态信息"
    tell "  5. 删除配置"
    tell "  0. 退出"
    tell "${CYAN}===============================${PLAIN}"
    case $(prompt "请选择") in
      1) wg_init ;;
      2) wg_edit ;;
      3) wg_toggle ;;
      4) wg_status ;;
      5) wg_delete ;;
      0) return ;;
      *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
}

run_update(){
  local current latest script_url script_tmp
  clear
  tell "正在检测 sing-box 内核更新..."
  current=$(core_version); latest=$(remote_version)
  tell "本地版本: ${current:-未知}"; tell "目标版本: ${latest:-获取失败}"
  if [ -z "$latest" ]; then tell_warn "无法获取最新版本，请检查网络或 GitHub 访问"
  elif [ -z "$current" ]; then
    if prompt_yes "无法读取当前内核版本，是否重新下载并安装 sing-box v$latest"; then
      timeout 15 systemctl stop sing-box >/dev/null 2>&1
      if install_core; then
        if apply_config; then tell_ok "内核重新安装完成"; else tell_warn "内核已下载，但配置应用失败"; fi
      else apply_config_quiet; tell_warn "内核重新安装失败"; fi
    fi
  elif [ "$current" != "$latest" ]; then
    if prompt_yes "发现新版本 v$latest，是否立即更新"; then
      timeout 15 systemctl stop sing-box >/dev/null 2>&1
      if install_core; then
        if apply_config; then tell_ok "内核更新完成"; else tell_warn "内核更新完成，但配置应用失败"; fi
      else apply_config_quiet; tell_warn "内核更新失败"; fi
    fi
  else tell_ok "内核已是最新版本"; fi
  printf "\n"
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
  local packages guard=0
  clear
  tell_warn "警告: 卸载将清空所有配置"
  [ "$(prompt '输入 yes 确认')" = yes ] || return
  mapfile -t packages < <(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null)
  systemctl disable --now sing-box 2>/dev/null
  systemctl disable --now sbm-watchdog.service 2>/dev/null
  systemctl reset-failed 'sbm-watchdog*' 2>/dev/null
  stop_net_monitor
  rm -f "$SERVICE_UNIT" "$DROPIN"
  rm -f /etc/systemd/system/sbm-watchdog.service
  rmdir "$DROPIN_DIR" 2>/dev/null
  systemctl daemon-reload
  clear_hopping_rules
  wg_server_nat_remove
  while ip rule del pref "$BYPASS_PREF" 2>/dev/null; do guard=$((guard+1)); [ "$guard" -gt 64 ] && break; done
  guard=0
  while ip -6 rule del pref "$BYPASS_PREF" 2>/dev/null; do guard=$((guard+1)); [ "$guard" -gt 64 ] && break; done
  ip link del "$WG_IF" 2>/dev/null
  ip link del "$TUN_IF" 2>/dev/null
  rm -rf "$SB_DIR" "$SBM_DIR" /var/lib/sing-box "$CORE" "$SHORTCUT"
  if [ ${#packages[@]} -gt 0 ]; then
    tell "脚本曾安装过: [ ${packages[*]} ]"
    if prompt_yes "是否移除依赖组件 (仅执行 remove，不触碰系统核心包)"; then
      apt-get remove -y -q "${packages[@]}" >/dev/null 2>&1
      apt-get autoremove -y -q >/dev/null 2>&1
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
  [ -f "$SERVICE_UNIT" ] || write_service
  if [ ! -f "$DROPIN" ]; then
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
      printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" \
        > "$_cache_tmp" && mv -f "$_cache_tmp" "$NET_CACHE" || { rm -f "$_cache_tmp"; flock -u 9; exit 1; }
    fi
    _new_conf=$(mktemp); TMP_FILES="$TMP_FILES $_new_conf"
    build_config > "$_new_conf" 2>/dev/null || { flock -u 9; exit 1; }
    [ -s "$_new_conf" ] || { flock -u 9; exit 1; }
    if ! "$CORE" check -c "$_new_conf" >/dev/null 2>&1; then
      flock -u 9; exit 1
    fi
    if cmp -s "$_new_conf" "$CONFIG"; then
      flock -u 9; exit 0
    fi
    _prev_conf=""
    if [ -f "$CONFIG" ]; then
      _prev_conf=$(mktemp) || { flock -u 9; exit 1; }
      cp "$CONFIG" "$_prev_conf" || { rm -f "$_prev_conf"; flock -u 9; exit 1; }
    fi
    install -m600 "$_new_conf" "$CONFIG" || { rm -f "$_prev_conf"; flock -u 9; exit 1; }
    if ! timeout 15 systemctl reload-or-restart sing-box >/dev/null 2>&1; then
      if [ -n "$_prev_conf" ] && [ -s "$_prev_conf" ]; then
        install -m600 "$_prev_conf" "$CONFIG"
        timeout 15 systemctl restart sing-box >/dev/null 2>&1
      else
        rm -f "$CONFIG"
        timeout 15 systemctl stop sing-box >/dev/null 2>&1
      fi
      rm -f "$_prev_conf"; flock -u 9; exit 1
    fi
    if ! systemctl is-active --quiet sing-box; then
      if [ -n "$_prev_conf" ] && [ -s "$_prev_conf" ]; then
        install -m600 "$_prev_conf" "$CONFIG"
        timeout 15 systemctl restart sing-box >/dev/null 2>&1
      else
        rm -f "$CONFIG"
        timeout 15 systemctl stop sing-box >/dev/null 2>&1
      fi
      rm -f "$_prev_conf"; flock -u 9; exit 1
    fi
    rm -f "$_prev_conf"
    sync_bypass_rules
    sync_hopping_rules
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
  tell "  1. 服务端管理"
  tell "  2. 客户端管理"
  tell "  3. WireGuard 管理"
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