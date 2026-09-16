#!/usr/bin/env bash
export LC_ALL=C
shopt -s nullglob

RED='\033[31m'; GREEN='\033[32m'; CYAN='\033[36m'; YELLOW='\033[33m'; PURPLE='\033[35m'; PLAIN='\033[0m'

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
RULE_STATE=$SBM_DIR/rule_state.json
NET_CACHE=$SBM_DIR/net_cache
REAPPLY_LOCK=$SBM_DIR/reapply.lock
SELF=/root/s.sh
SHORTCUT=/usr/local/bin/s
CORE=/usr/local/bin/sing-box
SERVICE_UNIT=/etc/systemd/system/sing-box.service
DROPIN_DIR=/etc/systemd/system/sing-box.service.d
DROPIN=$DROPIN_DIR/sbm.conf
GH_API=https://api.github.com/repos/SagerNet/sing-box
TUN_IF=sbmtun
WG_IF=sbmwg
CERT_TAG=acme-cert
PREF_MAIN=100
PREF_DEST=99

NET_IPV4=""; NET_IPV6=""; NET_IF_V4=""; NET_IF_V6=""; NET_STACK=""; IPV6_OK=0; BIND_MODE=""
TMP_FILES=""
NODE_COUNT=0; NODE_FILES=()
PEER_COUNT=0; PEER_FILES=(); PEER_TAGS=(); PEER_TYPES=(); PEER_NAMES=(); PEER_PORTS=()
PICKED=""; CORE_VERSION=""; CORE_TAGS=""
URI_SCHEME=""; URI_USERINFO=""; URI_HOST=""; URI_PORT=""; URI_QUERY=""

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}[×] 权限不足: 请使用 root 用户运行${PLAIN}"; exit 0; }

cleanup_tmp(){ local f; for f in $TMP_FILES; do [ -e "$f" ] && rm -rf "$f"; done; TMP_FILES=""; }
trap cleanup_tmp EXIT INT TERM

read_line(){
  local v
  if [ -c /dev/tty ]; then IFS= read -r v </dev/tty || v=""
  else IFS= read -r v || v=""; fi
  printf '%s' "${v%$'\r'}"
}

prompt(){
  if [ -n "$2" ]; then printf "  ${CYAN}%s [%s]: ${PLAIN}" "$1" "$2" >&2
  else printf "  ${CYAN}%s: ${PLAIN}" "$1" >&2; fi
  local v; v=$(read_line); echo "${v:-$2}"
}

prompt_yes(){ local v; v=$(prompt "$1 (y/N)" "n"); [ "$v" = y ] || [ "$v" = Y ]; }
wait_key(){ printf "\n  ${CYAN}>> 按回车键继续...${PLAIN}" >&2; read_line >/dev/null; }
tell(){ echo -e "  $*"; }
tell_ok(){ echo -e "  ${GREEN}[√] $*${PLAIN}"; }
tell_warn(){ echo -e "  ${RED}[×] $*${PLAIN}"; }
tell_gap(){ echo ""; }

slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){ openssl rand -hex 8; }
random_uuid(){ cat /proc/sys/kernel/random/uuid; }
random_port(){ shuf -i 20000-60000 -n1; }
resolve_addresses(){ getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u; }
uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }
uri_decode(){ local s=${1//+/ }; s=${s//\\/\\\\}; printf '%b' "${s//%/\\x}"; }

json_write(){
  local dest=$1 tmp rc=0
  tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  cat >"$tmp" || rc=1
  [ -s "$tmp" ] || rc=1
  [ "$rc" = 0 ] && install -m600 "$tmp" "$dest" || rc=1
  rm -f "$tmp"; return "$rc"
}

json_save(){ [ -n "$2" ] && printf '%s\n' "$2" | json_write "$1"; }

json_edit(){
  local file=$1 expr=$2; shift 2
  local tmp rc=1
  tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  if jq "$@" "$expr" "$file" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    install -m600 "$tmp" "$file" && rc=0
  fi
  rm -f "$tmp"; return "$rc"
}

init_dirs(){
  mkdir -p "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box
  chmod 700 "$SBM_DIR" "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box
  [ -f "$STATE" ] || printf '%s\n' '{"exit":"direct","domain":"","email":"","challenge":"http","asset":""}' | json_write "$STATE"
  [ -f "$PKG_LOG" ] || : >"$PKG_LOG"
  [ -f "$RULE_STATE" ] || printf '%s\n' '{"ports4":[],"ports6":[],"dests4":[],"dests6":[]}' | json_write "$RULE_STATE"
}

state_get(){ jq -r --arg k "$1" '.[$k]//""' "$STATE" 2>/dev/null; }
state_set(){ json_edit "$STATE" '.[$k]=$v' --arg k "$1" --arg v "$2"; }

ensure_command(){
  local cmd=$1 pkg=${2:-$1} pre=0
  command -v "$cmd" >/dev/null 2>&1 && return 0
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed' && pre=1
  local g=0
  while command -v fuser >/dev/null 2>&1 && { fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; }; do
    sleep 1; g=$((g+1)); [ "$g" -gt 30 ] && break
  done
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" >/dev/null 2>&1 || return 1
  command -v "$cmd" >/dev/null 2>&1 || return 1
  [ "$pre" = 0 ] && ! grep -qE "^${pkg}\|owned$" "$PKG_LOG" 2>/dev/null && echo "${pkg}|owned" >>"$PKG_LOG"
  return 0
}

check_dependencies(){
  local item cmd pkg
  local deps=("bash:bash" "curl:curl" "tar:tar" "jq:jq" "openssl:openssl" "nft:nftables" "ss:iproute2" "ip:iproute2" "ping:iputils-ping" "ping6:iputils-ping" "flock:util-linux" "pkill:procps" "sysctl:procps" "getent:libc-bin" "clear:ncurses-bin" "awk:mawk" "grep:grep" "sed:sed" "find:findutils" "shuf:coreutils" "timeout:coreutils" "systemctl:systemd" "journalctl:systemd" "modprobe:kmod")
  local miss=0
  for item in "${deps[@]}"; do cmd=${item%%:*}; command -v "$cmd" >/dev/null 2>&1 || { miss=1; break; }; done
  [ "$miss" = 1 ] && { DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || { echo -e "${RED}[×] apt 更新失败${PLAIN}"; exit 0; }; }
  for item in "${deps[@]}"; do
    cmd=${item%%:*}; pkg=${item#*:}
    ensure_command "$cmd" "$pkg" || { echo -e "${RED}[×] 依赖 $cmd 安装失败${PLAIN}"; exit 0; }
  done
}

core_version(){
  [ -z "$CORE_VERSION" ] && [ -x "$CORE" ] && CORE_VERSION=$("$CORE" version 2>/dev/null | awk '/version/{print $3; exit}')
  printf '%s' "$CORE_VERSION"
}
core_tags(){
  [ -z "$CORE_TAGS" ] && [ -x "$CORE" ] && CORE_TAGS=$("$CORE" version 2>/dev/null | sed -n 's/^Tags: //p')
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

# ============ 网卡自适应探测 ============
default_iface_v4(){
  local i
  i=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(x=1;x<=NF;x++)if($x=="dev"){print $(x+1);exit}}')
  case "$i" in "$TUN_IF"|"$WG_IF") i="" ;; esac
  [ -z "$i" ] && i=$(ip -4 route show table main default 2>/dev/null | awk -v t="$TUN_IF" -v w="$WG_IF" '$5!=t && $5!=w {print $5; exit}')
  printf '%s' "$i"
}
default_iface_v6(){
  local i
  i=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(x=1;x<=NF;x++)if($x=="dev"){print $(x+1);exit}}')
  case "$i" in "$TUN_IF"|"$WG_IF") i="" ;; esac
  [ -z "$i" ] && i=$(ip -6 route show table main default 2>/dev/null | awk -v t="$TUN_IF" -v w="$WG_IF" '$5!=t && $5!=w {print $5; exit}')
  printf '%s' "$i"
}
is_private_v4(){
  case "$1" in
    ""|10.*|192.168.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    100.6[4-9].*|100.[7-9]*.*|100.1[0-2][0-9].*) return 0 ;;
    *) return 1 ;;
  esac
}
is_private_v6(){
  case "$1" in
    ""|fe80:*|fc*|fd*|::1) return 0 ;;
    *) return 1 ;;
  esac
}

probe_network_stack(){
  NET_IF_V4=$(default_iface_v4); NET_IF_V6=$(default_iface_v6)
  NET_IPV4=""; NET_IPV6=""
  if [ -n "$NET_IF_V4" ]; then
    NET_IPV4=$(curl -4 -s -m 3 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n ')
    is_private_v4 "$NET_IPV4" && NET_IPV4=""
  fi
  if [ -n "$NET_IF_V6" ]; then
    NET_IPV6=$(curl -6 -s -m 3 https://ipv6.icanhazip.com 2>/dev/null | tr -d '\n ')
    is_private_v6 "$NET_IPV6" && NET_IPV6=""
  fi
  if [ -n "$NET_IPV4" ] && [ -n "$NET_IPV6" ]; then NET_STACK=both
  elif [ -n "$NET_IPV4" ]; then NET_STACK=v4
  elif [ -n "$NET_IPV6" ]; then NET_STACK=v6
  else NET_STACK=none; fi
  IPV6_OK=0
  [ -n "$NET_IPV6" ] && curl -6 -s -m 3 https://ipv6.icanhazip.com >/dev/null 2>&1 && IPV6_OK=1
  if [ "$NET_STACK" = both ] && [ "$NET_IF_V4" = "$NET_IF_V6" ]; then BIND_MODE=single
  elif [ "$NET_STACK" = both ]; then BIND_MODE=dual
  else BIND_MODE=single; fi
}

probe_network_stack_async(){
  ( probe_network_stack
    local t; t=$(mktemp "${NET_CACHE}.XXXXXX") || exit 0
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" "$BIND_MODE" >"$t" && mv -f "$t" "$NET_CACHE" || rm -f "$t"
  ) </dev/null >/dev/null 2>&1 &
}

load_net_cache(){
  if [ -f "$NET_CACHE" ]; then
    { IFS= read -r NET_IPV4; IFS= read -r NET_IPV6; IFS= read -r NET_IF_V4; IFS= read -r NET_IF_V6; IFS= read -r NET_STACK; IFS= read -r IPV6_OK; IFS= read -r BIND_MODE; } <"$NET_CACHE"
  fi
  if [ -z "$NET_STACK" ]; then
    probe_network_stack
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" "$BIND_MODE" >"$NET_CACHE" 2>/dev/null
  fi
}

# ============ 核心配置生成（sing-box 1.14.1） ============
dns_strategy(){
  case "$NET_STACK" in
    both) [ "${IPV6_OK:-0}" = "1" ] && printf 'prefer_ipv4' || printf 'ipv4_only' ;;
    v4)   printf 'ipv4_only' ;;
    v6)   printf 'ipv6_only' ;;
    *)    printf 'ipv4_only' ;;
  esac
}

tun_addresses(){
  case "$NET_STACK" in
    both) printf '["172.19.0.1/30","fdfe:dcba:9876::1/126"]' ;;
    v4)   printf '["172.19.0.1/30"]' ;;
    v6)   printf '["fdfe:dcba:9876::1/126"]' ;;
    *)    printf '[]' ;;
  esac
}

tun_dns_addresses(){
  case "$NET_STACK" in
    both) printf '["172.19.0.2","fdfe:dcba:9876::2"]' ;;
    v4)   printf '["172.19.0.2"]' ;;
    v6)   printf '["fdfe:dcba:9876::2"]' ;;
    *)    printf '[]' ;;
  esac
}

# 构建 DNS 块 (1.14.1: 移除顶层 strategy，dns-bootstrap 不设 domain_resolver)
build_dns_block(){
  local strat="$1" final="$2" if4="$3" if6="$4"
  local bserver="1.1.1.1"
  [ "$strat" = "ipv6_only" ] && bserver="2606:4700:4700::1111"
  jq -n --arg strat "$strat" --arg final "$final" --arg bserver "$bserver" --arg if4 "$if4" --arg if6 "$if6" '{
    servers: [
      {
        type:"https", tag:"dns-bootstrap", server:$bserver, server_port:443,
        path:"/dns-query", tls:{server_name:"cloudflare-dns.com"}
      },
      {
        type:"https", tag:"dns-remote", server:"cloudflare-dns.com", server_port:443,
        path:"/dns-query", tls:{server_name:"cloudflare-dns.com"},
        domain_resolver:{server:"dns-bootstrap", strategy:$strat}
      }
    ],
    final: "dns-remote"
  } |
  if $if4 != "" then .servers |= map(. + {bind_interface:$if4}) else . end |
  if $if6 != "" then .servers |= map(. + {bind_interface:$if6}) else . end |
  if $final != "direct" then .servers |= map(if .tag=="dns-remote" then .detour=$final else . end) else . end'
}

# 构建路由规则 (1.14.1: 强制 sniff + hijack-dns)
build_route_rules(){
  local final="$1" icmp_out="$2" probe_target="$3"
  local rules
  rules=$(jq -n --arg final "$final" --arg icmp "$icmp_out" '[
    { action:"sniff" },
    { protocol:"dns", action:"hijack-dns" },
    { ip_is_private:true, action:"route", outbound:"direct" },
    { network:"icmp", action:"route", outbound:$icmp }
  ]')
  if [ -n "$probe_target" ] && [ "$probe_target" != direct ]; then
    rules=$(jq --argjson l "$rules" --arg t "$probe_target" \
      '[{inbound:["probe-in"],action:"route",outbound:$t}] + $l' <<<"$rules")
  fi
  printf '%s' "$rules"
}

build_config(){
  local selected domain final=direct use_tun=0 peer_host="" route_excl='[]'
  local inbounds='[]' outbounds='[]' endpoints='[]' rules='[]' providers='[]'
  local node_files=() probe_target="${WATCHDOG_PROBE:-}"
  local strat boot_if4="" boot_if6=""

  selected=$(state_get exit); domain=$(state_get domain); strat=$(dns_strategy)

  case "$BIND_MODE" in
    dual)   boot_if4="$NET_IF_V4"; boot_if6="$NET_IF_V6" ;;
    single) boot_if4="$NET_IF_V4"; boot_if6="$NET_IF_V4" ;;
    *)      boot_if4="$NET_IF_V4"; boot_if6="$NET_IF_V6" ;;
  esac

  if compgen -G "$NODE_DIR/*.json" >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do node_files+=("$f"); done \
      < <(find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)
  fi

  # ACME certificate_providers (1.14.1: 内联 ACME 已废弃)
  if [ ${#node_files[@]} -gt 0 ] && [ -n "$domain" ]; then
    providers=$(jq -n --arg d "$domain" --arg e "$(state_get email)" --arg dir "$ACME_DIR" '[{
      type:"acme", tag:$CERT_TAG, domain:[$d], email:$e,
      data_directory:$dir, provider:"letsencrypt"
    }]')
  fi

  # 服务端入站 (1.14.1: tls.certificate_provider 替代 tls.acme)
  if [ ${#node_files[@]} -gt 0 ]; then
    inbounds=$(jq -s 'map(
      .inbound |
      if .tls then del(.tls.acme) | .tls.certificate_provider = "acme-cert" else . end
    )' "${node_files[@]}" 2>/dev/null) || return 1
  fi

  outbounds='[{"type":"direct","tag":"direct"}]'

  # WireGuard endpoint (1.11+: endpoints[] 数组，非 outbound)
  if [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = "true" ]; then
    local wg_role; wg_role=$(jq -r '.role//""' "$WG_CONF")
    if [ "$wg_role" = client ]; then
      endpoints=$(jq '[.endpoint | .domain_resolver={server:"dns-bootstrap"}]' "$WG_CONF")
      final=wireguard; use_tun=1
      peer_host=$(jq -r '.peer_host//""' "$WG_CONF")
      route_excl=$(wg_endpoint_route_excludes "$peer_host")
      [ -n "$route_excl" ] || route_excl='[]'
    fi
  fi

  # 代理出口 (1.14.1: domain_resolver 对象格式)
  if [ "$selected" != direct ] && [ "$selected" != wireguard ]; then
    if [ -f "$PEER_DIR/$selected.json" ]; then
      local out
      out=$(jq -c --arg tag "$selected" \
        '.outbound | .tag=$tag | .domain_resolver={server:"dns-bootstrap"}' \
        "$PEER_DIR/$selected.json") || return 1
      outbounds=$(jq --argjson o "$out" '. + [$o]' <<<"$outbounds")
      final="$selected"; use_tun=1
      peer_host=$(jq -r '.outbound.server//""' "$PEER_DIR/$selected.json")
    fi
  fi

  # bind_interface (1.14.1: 替代 inet4/6_bind_address)
  if [ "$BIND_MODE" = "single" ] && [ -n "$NET_IF_V4" ]; then
    outbounds=$(jq --arg b "$NET_IF_V4" 'map(. + {bind_interface:$b})' <<<"$outbounds")
    endpoints=$(jq --arg b "$NET_IF_V4" 'map(. + {bind_interface:$b})' <<<"$endpoints")
  fi

  # TUN inbound (1.14.1: dns_mode=hijack + dns_address)
  if [ "$use_tun" = "1" ]; then
    local tun_addr tun_dns
    tun_addr=$(tun_addresses); tun_dns=$(tun_dns_addresses)
    inbounds=$(jq -n --argjson addr "$tun_addr" --argjson dns "$tun_dns" \
      --argjson excl "$route_excl" --argjson list "$inbounds" \
      '[{ type:"tun", tag:"tun-in", interface_name:"sbmtun",
         address:$addr, auto_route:true, strict_route:true,
         dns_mode:"hijack", dns_address:$dns,
         route_exclude_address:$excl }] + $list')
  fi

  local icmp_out=direct
  [ "$final" = wireguard ] && icmp_out=wireguard
  rules=$(build_route_rules "$final" "$icmp_out" "$probe_target")

  if [ -n "$probe_target" ] && [ "$probe_target" != direct ]; then
    inbounds=$(jq --argjson l "$inbounds" \
      '[{type:"mixed",tag:"probe-in",listen:"127.0.0.1",listen_port:2081}] + $l')
  fi

  local dns_block
  dns_block=$(build_dns_block "$strat" "$final" "$boot_if4" "$boot_if6")

  jq -n \
    --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" \
    --argjson endpoints "$endpoints" --argjson rules "$rules" \
    --argjson dns "$dns_block" --argjson providers "$providers" \
    --arg final "$final" --argjson use_tun "$use_tun" '{
      log:{level:"warn",timestamp:true},
      dns:$dns,
      inbounds:$inbounds,
      outbounds:$outbounds,
      route:{
        rules:$rules,
        final:$final,
        default_domain_resolver:{server:"dns-bootstrap"}
      }
    } |
    if $use_tun==1 then .route.auto_detect_interface=true else . end |
    if ($endpoints|length)>0 then .endpoints=$endpoints else . end |
    if ($providers|length)>0 then .certificate_providers=$providers else . end'
}

# ============ 策略路由（SSH/测速保活，优先级修正） ============
ssh_ports(){
  {
    [ -n "$SSH_CONNECTION" ] && awk '{print $4}' <<<"$SSH_CONNECTION"
    ss -Hlntp 2>/dev/null | awk '/sshd/{print $4}' | sed 's/.*://'
    sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config 2>/dev/null
    sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config.d/*.conf 2>/dev/null
    command -v sshd >/dev/null 2>&1 && sshd -T 2>/dev/null | awk '/^port /{print $2}'
  } | grep -E '^[1-9][0-9]*$' | sort -un
}
node_ports(){ set -- "$NODE_DIR"/*.json; [ -e "$1" ] && jq -r '.port' "$@" 2>/dev/null | grep -E '^[1-9][0-9]*$'; }
wg_listen_port(){ [ -f "$WG_CONF" ] && jq -r '.listen_port//0' "$WG_CONF" | grep -E '^[1-9][0-9]*$'; }
protected_ports(){ { ssh_ports; node_ports; wg_listen_port; } | grep -E '^[1-9][0-9]*$' | sort -un; }
listening_ports(){ ss -Hln"$1" 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u; }

collect_mgmt_dests(){
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
      while IFS= read -r ip; do [ -n "$ip" ] && printf '%s|%s\n' "$ip" "$port"; done < <(resolve_addresses "$host")
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
        while IFS= read -r ip; do [ -n "$ip" ] && printf '%s|%s\n' "$ip" "$port"; done < <(resolve_addresses "$host")
      fi
    fi
  fi
}

clear_rules(){
  local p item ip
  while IFS= read -r p; do [ -n "$p" ] && ip -4 rule del pref "$PREF_MAIN" sport "$p" lookup main 2>/dev/null || true; done < <(ip -4 rule show pref "$PREF_MAIN" 2>/dev/null | sed -n 's/.*sport \([0-9]\+\).*/\1/p')
  while IFS= read -r p; do [ -n "$p" ] && ip -6 rule del pref "$PREF_MAIN" sport "$p" lookup main 2>/dev/null || true; done < <(ip -6 rule show pref "$PREF_MAIN" 2>/dev/null | sed -n 's/.*sport \([0-9]\+\).*/\1/p')
  while IFS= read -r item; do
    [ -n "$item" ] || continue; ip=${item%|*}; p=${item##*|}
    ip -4 rule del pref "$PREF_DEST" to "$ip" dport "$p" lookup main 2>/dev/null || true
  done < <(ip -4 rule show pref "$PREF_DEST" 2>/dev/null | sed -n 's/.*to \([^ ]*\).*dport \([0-9]\+\).*/\1|\2/p')
  while IFS= read -r item; do
    [ -n "$item" ] || continue; ip=${item%|*}; p=${item##*|}
    ip -6 rule del pref "$PREF_DEST" to "$ip" dport "$p" lookup main 2>/dev/null || true
  done < <(ip -6 rule show pref "$PREF_DEST" 2>/dev/null | sed -n 's/.*to \([^ ]*\).*dport \([0-9]\+\).*/\1|\2/p')
}

sync_mgmt_rules(){
  local p ip item new_ports state_tmp
  new_ports=$(protected_ports)
  clear_rules
  [ -n "$NET_IF_V4" ] && for p in $new_ports; do ip -4 rule add pref "$PREF_MAIN" sport "$p" lookup main 2>/dev/null || true; done
  [ -n "$NET_IF_V6" ] && for p in $new_ports; do ip -6 rule add pref "$PREF_MAIN" sport "$p" lookup main 2>/dev/null || true; done
  while IFS='|' read -r ip p; do
    [ -n "$ip" ] || continue
    [[ "$p" =~ ^[1-9][0-9]{0,4}$ ]] || continue
    [ "$p" -le 65535 ] || continue
    if printf '%s' "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
      ip -4 rule add pref "$PREF_DEST" to "$ip" dport "$p" lookup main 2>/dev/null || true
    elif printf '%s' "$ip" | grep -Eq '^[0-9A-Fa-f:]+$'; then
      ip -6 rule add pref "$PREF_DEST" to "$ip" dport "$p" lookup main 2>/dev/null || true
    fi
  done < <(collect_mgmt_dests)
  state_tmp=$(mktemp)
  jq -n --argjson p4 "$(printf '%s\n' "$new_ports" | jq -Rsc 'split("\n")|map(select(length>0)|tonumber)')" \
        --argjson p6 "$(printf '%s\n' "$new_ports" | jq -Rsc 'split("\n")|map(select(length>0)|tonumber)')" \
        '{ports4:$p4,ports6:$p6,dests4:[],dests6:[]}' >"$state_tmp" 2>/dev/null
  install -m600 "$state_tmp" "$RULE_STATE" 2>/dev/null || true
  rm -f "$state_tmp"
}

# ============ 配置应用 ============
_apply_config_locked(){
  local tmp prev_conf="" prev_active=0 prev_exists=0 error line
  tmp=$(mktemp) || { tell_warn "无法创建临时配置"; return 1; }
  TMP_FILES="$TMP_FILES $tmp"
  if [ -f "$CONFIG" ]; then
    prev_exists=1
    prev_conf=$(mktemp) || { rm -f "$tmp"; tell_warn "无法备份旧配置"; return 1; }
    TMP_FILES="$TMP_FILES $prev_conf"
    cp "$CONFIG" "$prev_conf" || { rm -f "$tmp" "$prev_conf"; tell_warn "备份失败"; return 1; }
  fi
  systemctl is-active --quiet sing-box && prev_active=1
  if ! build_config >"$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then rm -f "$tmp"; tell_warn "配置生成失败"; return 1; fi
  if ! error=$("$CORE" check -c "$tmp" 2>&1); then
    tell_warn "配置校验未通过:"
    while IFS= read -r line; do tell "    $line"; done <<<"$(head -4 <<<"$error")"
    rm -f "$tmp"; return 1
  fi
  if ! install -m600 "$tmp" "$CONFIG"; then rm -f "$tmp"; tell_warn "新配置写入失败"; return 1; fi
  rm -f "$tmp"
  if [ "$prev_active" = "1" ]; then
    if ! timeout 15 systemctl reload sing-box >/dev/null 2>&1 || ! systemctl is-active --quiet sing-box; then
      [ "$prev_exists" = "1" ] && install -m600 "$prev_conf" "$CONFIG" || rm -f "$CONFIG"
      timeout 15 systemctl reload sing-box >/dev/null 2>&1 || systemctl stop sing-box >/dev/null 2>&1
      tell_warn "sing-box 重载失败，已回滚"; return 1
    fi
  fi
  sync_mgmt_rules || { tell_warn "网络规则同步失败"; return 1; }
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

# ============ WireGuard 路由排除 ============
wg_endpoint_route_excludes(){
  local host=$1 a v4i="$NET_IF_V4" v6i="$NET_IF_V6"
  [ -n "$host" ] || return 1
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s/32\n' "$host"; return 0; fi
  if [[ "$host" == *:* ]] && [[ "$host" =~ ^[0-9A-Fa-f:]+$ ]]; then printf '%s/128\n' "$host"; return 0; fi
  case "$NET_STACK" in
    v4|both) while IFS= read -r a; do
      [[ "$a" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
      printf '%s/32\n' "$a"
    done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u) ;;
  esac
  case "$NET_STACK" in
    v6|both) while IFS= read -r a; do
      [[ "$a" == *:* ]] || continue
      printf '%s/128\n' "$a"
    done < <(getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | sort -u) ;;
  esac
}

# ============ 域名验证与证书 ============
validate_domain(){
  local d=$1 resolved ipv4 ipv6
  resolved=$(resolve_addresses "$d")
  [ -n "$resolved" ] || { tell_warn "无法解析域名"; return 1; }
  ipv4=$(local_ipv4); ipv6=$(local_ipv6)
  if ! { [ -n "$ipv4" ] && grep -qx "$ipv4" <<<"$resolved"; } && ! { [ -n "$ipv6" ] && grep -qx "$ipv6" <<<"$resolved"; }; then
    tell_warn "域名解析与本地 IP 不匹配"; return 1
  fi
  case $(state_get challenge) in
    http) grep -qx 80 <<<"$(listening_ports t)" && { tell_warn "80 被占用"; return 1; } ;;
    alpn) grep -qx 443 <<<"$(listening_ports t)" && { tell_warn "443 被占用"; return 1; } ;;
  esac
  tell_ok "解析记录正常"; return 0
}

local_ipv4(){ printf '%s' "$NET_IPV4"; }
local_ipv6(){ printf '%s' "$NET_IPV6"; }

setup_certificate(){
  local suggest=${1:-} domain email mode
  local od oe oc ocf oak oas oau oap oasub
  od=$(state_get domain); oe=$(state_get email); oc=$(state_get challenge)
  ocf=$(state_get cf_token); oak=$(state_get ali_key); oas=$(state_get ali_secret)
  oau=$(state_get acmedns_user); oap=$(state_get acmedns_pass); oasub=$(state_get acmedns_sub)
  [ -n "$od" ] && [ -n "$oe" ] && return 0
  has_acme_support || { tell_warn "组件缺失，无法自动签发"; return 1; }
  printf '\n  %b该协议需绑定域名并签发证书%b\n' "${YELLOW}" "${PLAIN}"
  if [ -n "$suggest" ]; then domain="$suggest"; printf '  %b已指定域名: %s%b\n' "${GREEN}" "$domain" "${PLAIN}"
  else domain=$(prompt "输入域名"); [ -n "$domain" ] || return 1; fi
  email=$(prompt "ACME 邮箱" "admin@$domain"); [ -n "$email" ] || return 1
  printf '\n  %b选择验证方式:%b\n' "${CYAN}" "${PLAIN}"
  echo "  1. HTTP-01      (需放行 80)"
  echo "  2. TLS-ALPN-01  (需放行 443)"
  echo "  3. DNS-01       (Cloudflare)"
  echo "  4. DNS-01       (阿里云)"
  echo "  5. DNS-01       (ACME-DNS)"
  while :; do
    case $(prompt "请选择" 1) in
      1) mode=http; break ;;
      2) mode=alpn; break ;;
      3) mode=dns_cloudflare; state_set cf_token "$(prompt 'Cloudflare API Token')" || { tell_warn "写入失败"; return 1; }; break ;;
      4) mode=dns_alidns
         if ! state_set ali_key "$(prompt 'AccessKeyId')" || ! state_set ali_secret "$(prompt 'AccessKeySecret')"; then
           tell_warn "凭据写入失败"; state_set ali_key "$oak" || true; state_set ali_secret "$oas" || true; return 1
         fi; break ;;
      5) mode=dns_acmedns
         if ! state_set acmedns_url "$(prompt 'server_url')" || ! state_set acmedns_user "$(prompt 'username')" || ! state_set acmedns_pass "$(prompt 'password')" || ! state_set acmedns_sub "$(prompt 'subdomain')"; then
           tell_warn "凭据写入失败"; state_set acmedns_user "$oau" || true; state_set acmedns_pass "$oap" || true; state_set acmedns_sub "$oasub" || true; return 1
         fi; break ;;
      *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
  if ! state_set challenge "$mode" || ! state_set domain "$domain" || ! state_set email "$email"; then
    tell_warn "状态写入失败，回滚"
    state_set domain "$od" || true; state_set email "$oe" || true; state_set challenge "$oc" || true
    state_set cf_token "$ocf" || true; state_set ali_key "$oak" || true; state_set ali_secret "$oas" || true
    state_set acmedns_user "$oau" || true; state_set acmedns_pass "$oap" || true; state_set acmedns_sub "$oasub" || true
    return 1
  fi
  if ! validate_domain "$domain"; then
    prompt_yes "验证异常，强制继续" || {
      state_set domain "$od" || true; state_set email "$oe" || true; state_set challenge "$oc" || true
      state_set cf_token "$ocf" || true; state_set ali_key "$oak" || true; state_set ali_secret "$oas" || true
      state_set acmedns_user "$oau" || true; state_set acmedns_pass "$oap" || true; state_set acmedns_sub "$oasub" || true
      return 1
    }
  fi
  return 0
}

# ============ 节点管理 ============
unique_tag(){
  local base tag i=1
  base=$(slugify "$1"); [ -n "$base" ] || base=node
  tag="$2$base"
  while [ -e "$3/$tag.json" ]; do tag="$2$base$i"; i=$((i+1)); done
  printf '%s' "$tag"
}

save_node(){
  local file=$1 content=$2
  json_save "$file" "$content" || { tell_warn "写入失败"; wait_key; return 1; }
  if apply_config; then tell_ok "协议应用成功"; tell_gap; render_share_uri "$file"
  else rm -f "$file"; apply_config_quiet; tell_warn "应用失败，已回滚"; fi
  wait_key
}

# ============ 端口校验 ============
validate_port(){
  local p=$1 proto=$2 allow=${3:-}
  [[ $p =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { tell_warn "端口格式无效"; return 1; }
  [ "$p" = 80 ] && { tell_warn "80 保留给证书"; return 1; }
  [ "$p" = 443 ] && [ "$(state_get challenge)" = alpn ] && { tell_warn "443 保留给 ALPN"; return 1; }
  [ "$p" = "$allow" ] && return 0
  grep -qx "$p" <<<"$(protected_ports)" && { tell_warn "被占用"; return 1; }
  grep -qx "$p" <<<"$(listening_ports "$proto")" && { tell_warn "端口占用"; return 1; }
  return 0
}

prompt_port(){
  local proto=$1 cur=$2 port def
  while :; do
    def=${cur:-$(random_port)}
    port=$(prompt "监听端口" "$def")
    validate_port "$port" "$proto" "$cur" && { printf '%s' "$port"; return 0; }
  done
}

# ============ 分享链接 ============
build_uri(){
  local kind=$1 name=$2 port=$3 meta=$4 hopping=$5 host=$6 uri=""
  case $kind in
    vless-reality)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(jq -r .target <<<"$meta")&fp=chrome&pbk=$(jq -r .public_key <<<"$meta")&sid=$(jq -r .short_id <<<"$meta")&spx=%2F&type=tcp#$(uri_encode "$name")" ;;
    vless-tls)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$host&fp=chrome&type=tcp&allowInsecure=0#$(uri_encode "$name")" ;;
    hysteria2)
      local ot op os bs mp pk ps
      ot=$(jq -r '.obfs_type//""' <<<"$meta"); op=$(jq -r '.obfs_password//""' <<<"$meta")
      bs=$(jq -r '.bbr_profile//""' <<<"$meta"); mp=$(jq -r '.min_packet_size//""' <<<"$meta"); pk=$(jq -r '.max_packet_size//""' <<<"$meta")
      os=""; [ -n "$ot" ] && os="&obfs=${ot}&obfs-password=$(uri_encode "$op")"
      local bbs=""; [ -n "$bs" ] && bbs="&bbr_profile=$(uri_encode "$bs")"
      ps=""; [ -n "$mp" ] && ps="${ps}&min_packet_size=${mp}"; [ -n "$pk" ] && ps="${ps}&max_packet_size=${pk}"
      uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?sni=$host&alpn=h3${bbs}${hopping:+&mport=$hopping}${os}${ps}#$(uri_encode "$name")" ;;
    tuic)
      uri="tuic://$(jq -r .uuid <<<"$meta"):$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni=$host&allow_insecure=0#$(uri_encode "$name")" ;;
    trojan)
      uri="trojan://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?security=tls&sni=$host&type=tcp&allowInsecure=0#$(uri_encode "$name")" ;;
    anytls)
      local ap am
      ap=$(jq -r .password <<<"$meta"); am=$(jq -r '.client_metadata//""' <<<"$meta")
      uri="anytls://$(uri_encode "$ap")@$host:$port?sni=$host&insecure=0"
      [ -n "$am" ] && uri="${uri}&client_metadata=$(uri_encode "$am")"
      uri="${uri}#$(uri_encode "$name")" ;;
    socks)
      uri="socks://$(uri_encode "$(jq -r .username <<<"$meta")"):$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port#$(uri_encode "$name")" ;;
    snell)
      uri="snell://$(uri_encode "$(jq -r .psk <<<"$meta")")@$host:$port?version=6&mode=$(jq -r '.mode//"default"' <<<"$meta")#$(uri_encode "$name")" ;;
  esac
  printf '%s' "$uri"
}

render_share_uri(){
  local file=$1 kind name port meta hopping mode host uri
  kind=$(jq -r .kind "$file"); name=$(jq -r .name "$file"); port=$(jq -r .port "$file")
  meta=$(jq -c .meta "$file"); hopping=$(jq -r '.hopping//""' "$file"); mode=$(jq -r .tls_mode "$file")
  if [ "$mode" = acme ]; then
    host=$(state_get domain)
    [ -n "$host" ] || { tell_warn "无可用域名，无法生成链接"; return; }
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "$hopping" "$host")
    tell "${GREEN}$uri${PLAIN}"
    [ -n "$hopping" ] && tell "跳跃配置: $hopping"
    return
  fi
  [ -n "$NET_IPV4" ] && { uri=$(build_uri "$kind" "$name" "$port" "$meta" "$hopping" "$NET_IPV4"); tell "${GREEN}$uri${PLAIN}"; }
  [ -n "$NET_IPV6" ] && { uri=$(build_uri "$kind" "$name" "$port" "$meta" "$hopping" "[$NET_IPV6]"); tell "${GREEN}$uri${PLAIN}"; }
  [ -z "$NET_IPV4$NET_IPV6" ] && { tell_warn "无公网 IP"; return; }
  [ -n "$hopping" ] && tell "跳跃配置: $hopping"
  [ "$kind" = snell ] && tell_warn "Snell 链接可能不被所有客户端识别"
}

# ============ 节点列表与选择 ============
list_nodes(){
  local index=0 raw old_ifs tcp udp
  NODE_COUNT=0; NODE_FILES=()
  set -- "$NODE_DIR"/*.json
  [ ! -e "$1" ] && { tell "  系统内暂无节点"; return 0; }
  tcp=$(listening_ports t); udp=$(listening_ports u)
  raw=$(jq -r '"\(input_filename)|\(.kind//"-")|\(.port//"-")|\(.name//"-")|\(.proto//"-")"' "$@" 2>/dev/null)
  if [ -n "$raw" ]; then
    old_ifs="$IFS"; IFS="|"
    while read -r file kind port name proto; do
      index=$((index+1)); NODE_FILES+=("$file")
      local st c
      if [ "$proto" = u ]; then grep -qx "$port" <<<"$udp" && { c="$GREEN"; st="[正常]"; } || { c="$RED"; st="[异常]"; }
      else grep -qx "$port" <<<"$tcp" && { c="$GREEN"; st="[正常]"; } || { c="$RED"; st="[异常]"; }; fi
      printf "  %b%2d. [%-13s] %s:%s %b%s%b\n" "$GREEN" "$index" "$kind" "$name" "$port" "$c" "$st" "$PLAIN"
    done <<<"$raw"
    IFS="$old_ifs"
  fi
  NODE_COUNT=$index
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
    else tell_warn "序号无效"; fi
  done
}

# ============ 创建协议 ============
create_vless_reality(){
  local name port uuid target keypair private public sid tag body dsid
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "VLESS-Reality")
  port=$(prompt_port t "")
  uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
  while :; do
    target=$(prompt "握手目标域名" "www.microsoft.com")
    command -v openssl >/dev/null || { tell_warn "openssl 缺失"; wait_key; return; }
    local res
    res=$(echo | timeout 10 openssl s_client -connect "$target:443" -servername "$target" -alpn h2 -tls1_3 2>/dev/null)
    grep -q "TLSv1.3" <<<"$res" && grep -q "ALPN protocol: h2" <<<"$res" && { tell_ok "验证通过"; break; }
    tell_warn "握手验证失败"; prompt_yes "强制使用" && break
  done
  keypair=$("$CORE" generate reality-keypair)
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] || { tell_warn "密钥生成失败"; wait_key; return; }
  dsid=$(openssl rand -hex 4 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c8)
  while :; do
    sid=$(prompt "short_id (留空自动生成)" "$dsid")
    [ -z "$sid" ] && sid="$dsid"
    [[ $sid =~ ^[0-9a-fA-F]{1,8}$ ]] && break
    tell_warn "short_id 必须 1-8 位十六进制"
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg target "$target" --arg private "$private" --arg public "$public" --arg sid "$sid" '
   {tag:$tag,name:$name,kind:"vless-reality",port:$port,proto:"t",hopping:"",tls_mode:"reality",alpn:null,
    meta:{uuid:$uuid,target:$target,public_key:$public,short_id:$sid},
    inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,
      users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],
      tls:{enabled:true,server_name:$target,reality:{enabled:true,handshake:{server:$target,server_port:443},private_key:$private,short_id:[$sid]}}}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vless_tls(){
  local name port uuid tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "VLESS-TLS"); setup_certificate || return
  port=$(prompt_port t ""); uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" '
   {tag:$tag,name:$name,kind:"vless-tls",port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,
    meta:{uuid:$uuid},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_hysteria2(){
  local name port pw hop tag body up down ot op bbr mp pk cc
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Hysteria2"); setup_certificate || return
  port=$(prompt_port u ""); pw=$(prompt "连接密码 (留空自动生成)" "$(random_password)")

  # ===== 拥塞控制方案 =====
  bbr=""; up=0; down=0
  tell "  1. BBR"
  tell "  2. Brutal"
  while :; do
    cc=$(prompt "请选择拥塞控制方案" 1)
    case "$cc" in
      1)
        tell "  1. conservative"; tell "  2. standard"; tell "  3. aggressive"
        while :; do
          case $(prompt "请选择 BBR profile" 2) in
            1) bbr=conservative; break ;;
            2) bbr=standard; break ;;
            3) bbr=aggressive; break ;;
            *) tell_warn "输入无效"; sleep 1 ;;
          esac
        done
        break ;;
      2)
        bbr=""
        while :; do
          up=$(prompt "上行 Mbps" "0"); [[ $up =~ ^[0-9]+$ ]] || { tell_warn "无效"; continue; }
          down=$(prompt "下行 Mbps" "0"); [[ $down =~ ^[0-9]+$ ]] || { tell_warn "无效"; continue; }
          { [ "$up" -gt 0 ] || [ "$down" -gt 0 ]; } && break
          tell_warn "至少设置一个方向"
        done
        break ;;
      *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done

  # ===== 混淆 =====
  ot=""; op=""; mp=""; pk=""
  if prompt_yes "是否配置协议混淆"; then
    tell "  1. Salamander"; tell "  2. Gecko"
    while :; do case $(prompt "请选择" 2) in 1) ot=salamander; break ;; 2) ot=gecko; break ;; *) tell_warn "无效"; sleep 1 ;; esac; done
    op=$(prompt "混淆密码 (留空同连接密码)" "$pw")
    if [ "$ot" = gecko ]; then
      mp=$(prompt "最小包大小" "512"); pk=$(prompt "最大包大小" "1200")
      [[ $mp =~ ^[0-9]+$ ]] || mp=512; [[ $pk =~ ^[0-9]+$ ]] || pk=1200
    fi
  fi

  # ===== 端口跳跃 =====
  hop=""
  if prompt_yes "是否配置端口跳跃"; then
    while :; do
      hop=$(prompt "跳跃范围 (如 20000-30000, 留空跳过)")
      [ -z "$hop" ] && break
      [[ $hop =~ ^[0-9]+-[0-9]+$ ]] && { local lo=${hop%-*} hi=${hop#*-}; [ "$lo" -ge 1 ] && [ "$hi" -le 65535 ] && [ "$lo" -lt "$hi" ] && break; }
      tell_warn "范围不合法"
    done
  fi

  # ===== 构建节点文件 =====
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg pw "$pw" --arg hop "$hop" \
        --argjson up "$up" --argjson down "$down" --arg ot "$ot" --arg op "$op" --arg bbr "$bbr" --arg mp "$mp" --arg pk "$pk" '
   {tag:$tag,name:$name,kind:"hysteria2",port:$port,proto:"u",hopping:$hop,tls_mode:"acme",alpn:["h3"],
    meta:({password:$pw,up_mbps:$up,down_mbps:$down,obfs_type:$ot,obfs_password:$op}
      | if $bbr!="" then .bbr_profile=$bbr else . end
      | if $ot=="gecko" and $mp!="" then .min_packet_size=($mp|tonumber) else . end
      | if $ot=="gecko" and $pk!="" then .max_packet_size=($pk|tonumber) else . end),
    inbound:({type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pw}]}
      | if $ot!="" then .obfs={type:$ot,password:$op} else . end
      | if $ot=="gecko" and $mp!="" then .obfs.min_packet_size=($mp|tonumber) else . end
      | if $ot=="gecko" and $pk!="" then .obfs.max_packet_size=($pk|tonumber) else . end
      | if $bbr!="" then .bbr_profile=$bbr else . end
      | if $up>0 then .up_mbps=$up else . end
      | if $down>0 then .down_mbps=$down else . end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_tuic(){
  local name port uuid pw tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "TUIC"); setup_certificate || return
  port=$(prompt_port u ""); uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
  pw=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg pw "$pw" '
   {tag:$tag,name:$name,kind:"tuic",port:$port,proto:"u",hopping:"",tls_mode:"acme",alpn:["h3"],
    meta:{uuid:$uuid,password:$pw},
    inbound:{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$pw}],congestion_control:"bbr"}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_trojan(){
  local name port pw tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Trojan"); setup_certificate || return
  port=$(prompt_port t ""); pw=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg pw "$pw" '
   {tag:$tag,name:$name,kind:"trojan",port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,
    meta:{password:$pw},inbound:{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pw}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_anytls(){
  local name port pw cm tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "AnyTLS"); setup_certificate || return
  port=$(prompt_port t ""); pw=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  cm=$(prompt "客户端元数据 (留空为空)" "")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg pw "$pw" --arg cm "$cm" '
   {tag:$tag,name:$name,kind:"anytls",port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,
    meta:({password:$pw} | if $cm!="" then .client_metadata=$cm else . end),
    inbound:{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pw}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_socks(){
  local name user pw port tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Socks5"); user=$(prompt "鉴权账号" "admin")
  pw=$(prompt "鉴权密码 (留空自动生成)" "$(random_password)")
  [ -n "$user" ] && [ -n "$pw" ] || { tell_warn "必填为空"; wait_key; return; }
  port=$(prompt_port t "")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg user "$user" --arg pw "$pw" '
   {tag:$tag,name:$name,kind:"socks",port:$port,proto:"t",hopping:"",tls_mode:"none",alpn:null,
    meta:{username:$user,password:$pw},
    inbound:{type:"socks",tag:$tag,listen:"::",listen_port:$port,users:[{username:$user,password:$pw}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_snell(){
  local name port psk mode tag body len
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Snell"); port=$(prompt_port t "")
  while :; do
    psk=$(prompt "预共享密钥 (12-255 字节)" "$(random_password)")
    len=${#psk}
    { [ "$len" -ge 12 ] && [ "$len" -le 255 ]; } && break
    tell_warn "PSK 长度需 12-255 字节，当前 $len"
  done
  tell "  1. default"; tell "  2. unshaped"; tell "  3. unsafe-raw"
  while :; do case $(prompt "流量整形模式" 1) in 1) mode=default; break ;; 2) mode=unshaped; break ;; 3) mode=unsafe-raw; break ;; *) tell_warn "无效"; sleep 1 ;; esac; done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg psk "$psk" --arg mode "$mode" '
   {tag:$tag,name:$name,kind:"snell",port:$port,proto:"t",hopping:"",tls_mode:"none",alpn:null,
    meta:{psk:$psk,mode:$mode},
    inbound:{type:"snell",tag:$tag,listen:"::",listen_port:$port,version:6,psk:$psk,mode:$mode}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

# ============ 菜单 ============
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
      *) tell_warn "无效"; sleep 1 ;;
    esac
  done
}

menu_delete_protocol(){
  clear; tell "${CYAN}========== 删除协议 ==========${PLAIN}"
  select_node || return
  prompt_yes "确认删除 $(jq -r .name "$PICKED")" || return
  local was old_json; was=$(jq -r .tls_mode "$PICKED"); old_json=$(cat "$PICKED"); rm -f "$PICKED"
  if apply_config; then
    tell_ok "已删除"
    if [ "$was" = acme ]; then
      local c=0
      for f in "$NODE_DIR"/*.json; do [ "$(jq -r .tls_mode "$f")" = acme ] && c=$((c+1)); done
      if [ "$c" -eq 0 ] && [ -n "$(state_get domain)" ]; then
        tell_gap
        prompt_yes "是否连同域名和证书一起清理" && { state_set domain ""; state_set email ""; state_set challenge http; find "$ACME_DIR" -mindepth 1 -delete 2>/dev/null; tell_ok "已清理"; }
      fi
    fi
  else json_save "$PICKED" "$old_json"; apply_config_quiet; tell_warn "回滚"; fi
  wait_key
}

menu_modify_protocol(){
  local kind value other cur_hop up down ot op old_json bbr mp pk
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
      hysteria2) tell "  3. 连接密码"; tell "  4. 端口跳跃"; tell "  5. 拥塞控制"; tell "  6. 混淆设置" ;;
      *) tell "  3. 连接密码" ;;
    esac
    [ "$kind" = vless-reality ] && tell "  5. 握手目标域名"
    [ "$kind" = vless-reality ] && tell "  6. short_id"
    tell "  0. 返回"; tell "${CYAN}==============================${PLAIN}"
    old_json=$(cat "$PICKED")
    case $(prompt "请选择") in
      1) value=$(prompt "新名称" "$(jq -r .name "$PICKED")"); [ -n "$value" ] || continue; json_edit "$PICKED" '.name=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      2) value=$(prompt_port "$(jq -r .proto "$PICKED")" "$(jq -r .port "$PICKED")") || continue; json_edit "$PICKED" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      3)
        if [ "$kind" = vless-reality ] || [ "$kind" = vless-tls ] || [ "$kind" = tuic ]; then
          value=$(prompt "新 UUID (留空自动生成)"); [ -z "$value" ] && value=$(random_uuid)
          json_edit "$PICKED" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value"
        elif [ "$kind" = snell ]; then
          while :; do
            value=$(prompt "新 PSK (留空自动生成)" "$(jq -r .meta.psk "$PICKED")")
            [ -z "$value" ] && value=$(random_password)
            local len=${#value}
            { [ "$len" -ge 12 ] && [ "$len" -le 255 ]; } && break
            tell_warn "PSK 12-255 字节"
          done
          json_edit "$PICKED" '.meta.psk=$v|.inbound.psk=$v' --arg v "$value"
        else
          value=$(prompt "新密码 (留空自动生成)"); [ -z "$value" ] && value=$(random_password)
          json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value"
        fi || { tell_warn 失败; wait_key; continue; } ;;
      4)
        if [ "$kind" = socks ]; then
          value=$(prompt "鉴权账号" "$(jq -r .meta.username "$PICKED")"); [ -n "$value" ] || continue
          json_edit "$PICKED" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = tuic ]; then
          value=$(prompt "新密码 (留空自动生成)"); [ -z "$value" ] && value=$(random_password)
          json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = snell ]; then
          tell "  1. default"; tell "  2. unshaped"; tell "  3. unsafe-raw"
          while :; do case $(prompt "模式" 1) in 1) value=default; break ;; 2) value=unshaped; break ;; 3) value=unsafe-raw; break ;; *) tell_warn 无效; sleep 1 ;; esac; done
          json_edit "$PICKED" '.meta.mode=$v|.inbound.mode=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = anytls ]; then
          value=$(prompt "客户端元数据" "$(jq -r '.meta.client_metadata//""' "$PICKED")")
          if [ -z "$value" ]; then json_edit "$PICKED" 'del(.meta.client_metadata)' || { tell_warn 失败; wait_key; continue; }
          else json_edit "$PICKED" '.meta.client_metadata=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }; fi
        elif [ "$kind" = hysteria2 ]; then
  tell "        elif [ "$kind" = hysteria2 ]; then
  tell "  1. BBR conservative"; tell "  2. BBR standard"; tell "  3. BBR aggressive"; tell "  4. Brutal"
  while :; do
    case $(prompt "请选择" 2) in
      1) bbr=conservative; up=0; down=0; break ;;
      2) bbr=standard; up=0; down=0; break ;;
      3) bbr=aggressive; up=0; down=0; break ;;
      4) bbr=""
         while :; do
           up=$(prompt "上行 Mbps" "$(jq -r '.meta.up_mbps//0' "$PICKED")"); [[ $up =~ ^[0-9]+$ ]] || { tell_warn 无效; continue; }
           down=$(prompt "下行 Mbps" "$(jq -r '.meta.down_mbps//0' "$PICKED")"); [[ $down =~ ^[0-9]+$ ]] || { tell_warn 无效; continue; }
           { [ "$up" -gt 0 ] || [ "$down" -gt 0 ]; } && break
           tell_warn "至少一个方向"
         done; break ;;
      *) tell_warn 无效; sleep 1 ;;
    esac
  done
  if [ "$bbr" != "" ]; then
  json_edit "$PICKED" '.meta.up_mbps=0|.meta.down_mbps=0|.meta.bbr_profile=$b|del(.inbound.up_mbps,.inbound.down_mbps,.inbound.bbr_profile)' --arg b "$bbr" || { tell_warn 失败; wait_key; continue; }
else
  json_edit "$PICKED" '.meta.up_mbps=$u|.meta.down_mbps=$d|.meta.bbr_profile=""|del(.inbound.up_mbps,.inbound.down_mbps,.inbound.bbr_profile)' --argjson u "$up" --argjson d "$down" || { tell_warn 失败; wait_key; continue; }
fi
else tell_warn 无效; sleep 1; continue; fi ;;
      5)
        if [ "$kind" = vless-reality ]; then
          while :; do
            value=$(prompt "新握手目标域名 (留空取消)")
            [ -n "$value" ] || break
            local r; r=$(echo | timeout 10 openssl s_client -connect "$value:443" -servername "$value" -alpn h2 -tls1_3 2>/dev/null)
            grep -q "TLSv1.3" <<<"$r" && { tell_ok 验证通过; break; }
            prompt_yes "强制加载" && break
          done
          [ -n "$value" ] || continue
          json_edit "$PICKED" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = hysteria2 ]; then
          tell "  1. BBR conservative"; tell "  2. BBR standard"; tell "  3. BBR aggressive"; tell "  4. Brutal"
          while :; do
            case $(prompt "请选择" 2) in
              1) bbr=conservative; up=0; down=0; break ;;
              2) bbr=standard; up=0; down=0; break ;;
              3) bbr=aggressive; up=0; down=0; break ;;
              4) bbr=""
                 while :; do
                   up=$(prompt "上行 Mbps" "$(jq -r '.meta.up_mbps//0' "$PICKED")"); [[ $up =~ ^[0-9]+$ ]] || { tell_warn 无效; continue; }
                   down=$(prompt "下行 Mbps" "$(jq -r '.meta.down_mbps//0' "$PICKED")"); [[ $down =~ ^[0-9]+$ ]] || { tell_warn 无效; continue; }
                   { [ "$up" -gt 0 ] || [ "$down" -gt 0 ]; } && break
                   tell_warn "至少一个方向"
                 done; break ;;
              *) tell_warn 无效; sleep 1 ;;
            esac
          done
          if [ "$bbr" != "" ]; then
            json_edit "$PICKED" '.meta.up_mbps=0|.meta.down_mbps=0|.meta.bbr_profile=$b|del(.inbound.up_mbps,.inbound.down_mbps)|.inbound.bbr_profile=$b' --arg b "$bbr" || { tell_warn 失败; wait_key; continue; }
          else
            json_edit "$PICKED" '.meta.up_mbps=$u|.meta.down_mbps=$d|.meta.bbr_profile=""|if $u>0 then .inbound.up_mbps=$u else del(.inbound.up_mbps) end|if $d>0 then .inbound.down_mbps=$d else del(.inbound.down_mbps) end|del(.inbound.bbr_profile)' --argjson u "$up" --argjson d "$down" || { tell_warn 失败; wait_key; continue; }
          fi
        else tell_warn 无效; sleep 1; continue; fi ;;
      6)
        if [ "$kind" = vless-reality ]; then
          value=$(prompt "新 short_id" "$(jq -r '.meta.short_id//""' "$PICKED")")
          [ -z "$value" ] && value=$(openssl rand -hex 4 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c8)
          [[ $value =~ ^[0-9a-fA-F]{1,8}$ ]] || { tell_warn "必须 1-8 位十六进制"; wait_key; continue; }
          json_edit "$PICKED" '.meta.short_id=$v|.inbound.tls.reality.short_id=[$v]' --arg v "$value" || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = hysteria2 ]; then
          if prompt_yes "是否配置协议混淆"; then
            tell "  1. Salamander"; tell "  2. Gecko"
            while :; do case $(prompt "算法" 2) in 1) ot=salamander; break ;; 2) ot=gecko; break ;; *) tell_warn 无效; sleep 1 ;; esac; done
            op=$(prompt "混淆密码" "$(jq -r '.meta.obfs_password//""' "$PICKED")")
            [ -z "$op" ] && op=$(jq -r '.meta.password' "$PICKED")
            if [ "$ot" = gecko ]; then
              mp=$(prompt "最小包大小" "$(jq -r '.meta.min_packet_size//512' "$PICKED")")
              pk=$(prompt "最大包大小" "$(jq -r '.meta.max_packet_size//1200' "$PICKED")")
              [[ $mp =~ ^[0-9]+$ ]] || mp=512; [[ $pk =~ ^[0-9]+$ ]] || pk=1200
              json_edit "$PICKED" '.meta.obfs_type=$t|.meta.obfs_password=$p|.meta.min_packet_size=($mn|tonumber)|.meta.max_packet_size=($mx|tonumber)|.inbound.obfs={type:$t,password:$p,min_packet_size:($mn|tonumber),max_packet_size:($mx|tonumber)}' --arg t "$ot" --arg p "$op" --arg mn "$mp" --arg mx "$pk" || { tell_warn 失败; wait_key; continue; }
            else
              json_edit "$PICKED" '.meta.obfs_type=$t|.meta.obfs_password=$p|del(.meta.min_packet_size,.meta.max_packet_size)|.inbound.obfs={type:$t,password:$p}' --arg t "$ot" --arg p "$op" || { tell_warn 失败; wait_key; continue; }
            fi
          else
            json_edit "$PICKED" '.meta.obfs_type=""|.meta.obfs_password=""|del(.meta.min_packet_size,.meta.max_packet_size)|del(.inbound.obfs)' || { tell_warn 失败; wait_key; continue; }
          fi
        else tell_warn 无效; sleep 1; continue; fi ;;
      0) return ;;
      *) tell_warn 无效; sleep 1; continue ;;
    esac
    if apply_config; then tell_ok "已生效"; tell_gap; render_share_uri "$PICKED"
    else printf '%s\n' "$old_json" | json_write "$PICKED"; apply_config_quiet; tell_warn "回滚"; fi
    wait_key
  done
}

# ============ 客户端管理 ============
parse_uri(){
  local raw=$1 rest tail ep=0
  URI_SCHEME=${raw%%://*}; rest=${raw#*://}
  case $rest in *\#*) rest=${rest%%\#*} ;; esac
  URI_QUERY=""; case $rest in *\?*) URI_QUERY=${rest#*\?}; rest=${rest%%\?*} ;; esac
  rest=${rest%%/*}
  URI_USERINFO=""; case $rest in *@*) URI_USERINFO=$(uri_decode "${rest%@*}"); rest=${rest##*@} ;; esac
  URI_PORT=443
  case $rest in
    \[*\]*)
      URI_HOST=${rest%%\]*}; URI_HOST=${URI_HOST#\[}; tail=${rest##*\]}
      if [ -n "$tail" ]; then [[ "$tail" == :* ]] || return 1; URI_PORT=${tail#:}; ep=1; fi ;;
    *:*) URI_HOST=${rest%%:*}; URI_PORT=${rest##*:}; ep=1 ;;
    *) URI_HOST=$rest ;;
  esac
  if [ "$ep" = 1 ] && { ! [[ "$URI_PORT" =~ ^[0-9]+$ ]] || [ "$URI_PORT" -lt 1 ] || [ "$URI_PORT" -gt 65535 ]; }; then
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
  local tag=$1 outbound sni fp insecure sec net path vhost svc user pw cc alpn obfs op hop flow udp_mode
  local bbr dp sm cm mp pk
  sni=$(query_value sni); [ -n "$sni" ] || sni=$(query_value peer); [ -n "$sni" ] || sni=$URI_HOST
  fp=$(query_value fp); [ -n "$fp" ] || fp=chrome
  insecure=$(query_value insecure); [ -n "$insecure" ] || insecure=$(query_value allowInsecure)
  case $URI_SCHEME in
    vless)
      sec=$(query_value security); net=$(query_value type); path=$(query_value path); vhost=$(query_value host); svc=$(query_value serviceName); flow=$(query_value flow)
      outbound=$(jq -n --arg tag "$tag" --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg u "$URI_USERINFO" '{type:"vless",tag:$tag,server:$s,server_port:$p,uuid:$u,packet_encoding:"xudp"}')
      [ -n "$flow" ] && outbound=$(jq --arg f "$flow" '.flow=$f' <<<"$outbound")
      if [ "$sec" = reality ]; then
        outbound=$(jq --arg sni "$sni" --arg fp "$fp" --arg pbk "$(query_value pbk)" --arg sid "$(query_value sid)" '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp},reality:{enabled:true,public_key:$pbk,short_id:$sid}}' <<<"$outbound")
      elif [ "$sec" = tls ] || [ "$sec" = xtls ]; then
        outbound=$(jq --arg sni "$sni" --arg fp "$fp" '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp}}' <<<"$outbound")
      fi
      case $net in
        ws) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound") ;;
        grpc) outbound=$(jq --arg svc "$svc" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
        httpupgrade) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport={type:"httpupgrade",path:$path,host:$host}' <<<"$outbound") ;;
      esac ;;
    hysteria2|hy2)
      outbound=$(jq -n --arg tag "$tag" --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg pw "$URI_USERINFO" --arg sni "$sni" '{type:"hysteria2",tag:$tag,server:$s,server_port:$p,password:$pw,tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      op=$(query_value obfs-password); obfs=$(query_value obfs)
      if [ -n "$op" ]; then [ -z "$obfs" ] && obfs=salamander; outbound=$(jq --arg t "$obfs" --arg p "$op" '.obfs={type:$t,password:$p}' <<<"$outbound"); fi
      bbr=$(query_value bbr_profile); [ -n "$bbr" ] || bbr=standard
      outbound=$(jq --arg b "$bbr" '.bbr_profile=$b' <<<"$outbound")
      dp=$(query_value disable_chrome_parrot)
      [ "$dp" = "1" ] || [ "$dp" = "true" ] && outbound=$(jq '.disable_chrome_parrot=true' <<<"$outbound")
      hop=$(query_value mport); [ -z "$hop" ] && hop=$(query_value ports)
      [ -n "$hop" ] && outbound=$(jq --arg r "${hop//-/:}" '.server_ports=[$r]|del(.server_port)|.hop_interval="30s"' <<<"$outbound")
      mp=$(query_value min_packet_size); pk=$(query_value max_packet_size)
      if [ -n "$mp" ] || [ -n "$pk" ]; then
        outbound=$(jq --arg mn "${mp:-512}" --arg mx "${pk:-1200}" '.obfs.min_packet_size=($mn|tonumber)|.obfs.max_packet_size=($mx|tonumber)' <<<"$outbound")
      fi ;;
    tuic)
      user=${URI_USERINFO%%:*}; pw=${URI_USERINFO#*:}
      [ "$pw" = "$URI_USERINFO" ] && pw=""
      cc=$(query_value congestion_control); [ -n "$cc" ] || cc=bbr
      alpn=$(query_value alpn); [ -n "$alpn" ] || alpn=h3
      udp_mode=$(query_value udp_relay_mode); [ -n "$udp_mode" ] || udp_mode=native
      outbound=$(jq -n --arg tag "$tag" --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg u "$user" --arg pw "$pw" --arg cc "$cc" --arg sni "$sni" --arg alpn "$alpn" --arg um "$udp_mode" '{type:"tuic",tag:$tag,server:$s,server_port:$p,uuid:$u,password:$pw,congestion_control:$cc,udp_relay_mode:$um,tls:{enabled:true,server_name:$sni,alpn:($alpn|split(","))}}') ;;
    trojan)
      outbound=$(jq -n --arg tag "$tag" --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg pw "$URI_USERINFO" --arg sni "$sni" '{type:"trojan",tag:$tag,server:$s,server_port:$p,password:$pw,tls:{enabled:true,server_name:$sni}}')
      if [ "$(query_value type)" = ws ]; then
        outbound=$(jq --arg path "$(query_value path)" --arg host "$(query_value host)" '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound")
      fi ;;
    anytls)
      cm=$(query_value client_metadata)
      outbound=$(jq -n --arg tag "$tag" --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg pw "$URI_USERINFO" --arg sni "$sni" --arg cm "$cm" '{type:"anytls",tag:$tag,server:$s,server_port:$p,password:$pw,tls:{enabled:true,server_name:$sni}}|if $cm!="" then .client_metadata=$cm else . end') ;;
    socks5|socks)
      user=${URI_USERINFO%%:*}; pw=${URI_USERINFO#*:}
      [ "$pw" = "$URI_USERINFO" ] && pw=""
      outbound=$(jq -n --arg tag "$tag" --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg u "$user" --arg pw "$pw" '{type:"socks",tag:$tag,server:$s,server_port:$p,version:"5"}|(if $u!="" then .username=$u else . end)|(if $pw!="" then .password=$pw else . end)') ;;
    snell)
      sm=$(query_value mode); [ -n "$sm" ] || sm=default
      outbound=$(jq -n --arg tag "$tag" --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg psk "$URI_USERINFO" --arg mode "$sm" '{type:"snell",tag:$tag,server:$s,server_port:$p,version:6,psk:$psk,mode:$mode}') ;;
    *) return 1 ;;
  esac
  { [ "$insecure" = 1 ] || [ "$insecure" = true ]; } && outbound=$(jq 'if .tls then .tls.insecure=true else . end' <<<"$outbound")
  printf '%s' "$outbound"
}

peer_add(){
  local name uri tag outbound probe mp
  clear; tell "${CYAN}========== 添加节点 ==========${PLAIN}"
  name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return
  uri=$(prompt "节点链接"); [ -n "$uri" ] || return
  parse_uri "$uri" || { wait_key; return; }
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag") || { tell_warn "无法解析"; wait_key; return; }
  probe=$(mktemp); TMP_FILES="$TMP_FILES $probe"
  jq -n --argjson o "$outbound" '{log:{level:"error"},outbounds:[$o,{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$probe"
  if "$CORE" check -c "$probe" >/dev/null 2>&1; then
    mp=22
    if prompt_yes "是否需要为对端保留 SSH 应急通道"; then
      mp=$(prompt "对端 SSH 端口" "22")
      [[ "$mp" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$mp" -le 65535 ] || { tell_warn "SSH 端口无效"; rm -f "$probe"; wait_key; return; }
    fi
    if json_save "$PEER_DIR/$tag.json" "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson o "$outbound" --argjson mp "$mp" '{tag:$tag,name:$name,uri:$uri,management_port:$mp,outbound:$o}')"; then
      tell_ok "挂载完成: $name"
    else tell_warn "保存失败"; fi
  else
    tell_warn "校验拦截:"; "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2
  fi
  rm -f "$probe"; wait_key
}

list_peers(){
  local cur=$(state_get exit)
  local title=${1:-节点选择}
  PEER_COUNT=0; PEER_FILES=(); PEER_TAGS=(); PEER_TYPES=(); PEER_NAMES=(); PEER_PORTS=()
  set -- "$PEER_DIR"/*.json
  [ ! -e "$1" ] && { clear; tell "${CYAN}========== $title ==========${PLAIN}"; tell "  暂无外部节点"; return 0; }
  local tmp; tmp=$(mktemp -d); TMP_FILES="$TMP_FILES $tmp"
  local idx=0 raw old_ifs pids=""
  raw=$(jq -r '"\(input_filename)|\(.tag//"-")|\(.outbound.type//"-")|\(.name//"-")|\(.outbound.server_port // (if .outbound.server_ports then (.outbound.server_ports[0]|gsub(":";"-")) else null end) // .outbound.listen_port // "-")|\(.outbound.server//"-")"' "$@" 2>/dev/null)
  if [ -n "$raw" ]; then
    old_ifs="$IFS"; IFS="|"
    while read -r file tag type name port host; do
      idx=$((idx+1)); PEER_FILES+=("$file"); PEER_TAGS+=("$tag"); PEER_TYPES+=("$type"); PEER_NAMES+=("$name"); PEER_PORTS+=("$port")
      (
        local ms="" pr iface cmd
        if [[ "$host" =~ : ]]; then iface="$NET_IF_V6"; cmd=ping6; else iface="$NET_IF_V4"; cmd=ping; fi
        [ -n "$iface" ] && pr=$(timeout 2 $cmd -I "$iface" -c 1 -W 1 -m 255 "$host" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{print $5}')
        [ -n "$pr" ] && ms=$(awk "BEGIN{print int($pr)}") || ms=fail
        echo "$ms" >"$tmp/res_$idx"
      ) &
      pids="$pids $!"
    done <<<"$raw"
    IFS="$old_ifs"
  fi
  PEER_COUNT=$idx
  [ -n "$pids" ] && wait $pids 2>/dev/null
  clear; tell "${CYAN}========== $title ==========${PLAIN}"
  for i in $(seq 1 $PEER_COUNT); do
    local tag="${PEER_TAGS[$((i-1))]}"; local type="${PEER_TYPES[$((i-1))]}"
    local name="${PEER_NAMES[$((i-1))]}"; local port="${PEER_PORTS[$((i-1))]}"
    local mark="" ms c st
    ms=$(cat "$tmp/res_$i" 2>/dev/null)
    if [ "$ms" = fail ] || [ -z "$ms" ]; then c="$RED"; st="[不可用]"
    elif [ "$ms" -le 150 ]; then c="$GREEN"; st="[${ms}ms]"
    else c="$YELLOW"; st="[${ms}ms]"; fi
    [ "$tag" = "$cur" ] && mark=" ${CYAN}<=当前${c}"
    printf "  %b%2d. [%-7s] %s:%s %b %s%b\n" "$c" "$i" "$type" "$name" "$port" "$mark" "$st" "$PLAIN"
  done
  rm -rf "$tmp"; return 0
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
    else tell_warn "序号无效"; sleep 1; fi
  done
}

peer_target_address_is_local(){
  local host=$1 port=$2 ip p l4 l6
  [ -n "$host" ] || return 1
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  [ "$port" -le 65535 ] || return 1
  if [ "$host" = 127.0.0.1 ] || [ "$host" = ::1 ] || [ "$host" = localhost ]; then
    while IFS= read -r p; do [ "$port" = "$p" ] && return 0; done < <(node_ports)
  fi
  for ip in $(resolve_addresses "$host"); do
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [ -n "$NET_IF_V4" ]; then
      while IFS= read -r l4; do
        [ "$ip" = "$l4" ] || continue
        while IFS= read -r p; do [ "$port" = "$p" ] && return 0; done < <(node_ports)
      done < <(ip -4 addr show dev "$NET_IF_V4" scope global 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2}')
    elif [[ "$ip" == *:* ]] && [ -n "$NET_IF_V6" ]; then
      while IFS= read -r l6; do
        [ "$ip" = "$l6" ] || continue
        while IFS= read -r p; do [ "$port" = "$p" ] && return 0; done < <(node_ports)
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
  local tag prev wg_was=0
  select_peer "接管/选择节点" || return
  tag=$(jq -r .tag "$PICKED"); prev=$(state_get exit)
  if peer_target_is_local "$PICKED"; then tell_warn "节点指向本机，拒绝环路"; wait_key; return; fi
  if wg_client_active; then
    prompt_yes "WireGuard 隧道运行中，是否断开" || return
    json_edit "$WG_CONF" '.enabled=false' || { tell_warn "关闭失败"; wait_key; return; }
    wg_was=1
  fi
  if ! state_set exit "$tag"; then
    [ "$wg_was" = 1 ] && json_edit "$WG_CONF" '.enabled=true' || true
    tell_warn "状态写入失败"; wait_key; return
  fi
  if apply_config; then tell_ok "已接管: $(jq -r .name "$PICKED")"
  else
    state_set exit "$prev" || true
    [ "$wg_was" = 1 ] && json_edit "$WG_CONF" '.enabled=true' || true
    apply_config_quiet; tell_warn "回滚"
  fi
  wait_key
}

peer_delete(){
  select_peer "删除节点" || return
  local old prev_exit
  old=$(cat "$PICKED"); prev_exit=$(state_get exit)
  if [ "$(jq -r .tag "$PICKED")" = "$prev_exit" ]; then
    state_set exit direct || { tell_warn "写入失败"; wait_key; return; }
    rm -f "$PICKED"
    if apply_config; then
      tell_ok "已删除当前节点，恢复直连"
      [ "$(jq -r '.enabled//false' "$WG_CONF" 2>/dev/null)" != true ] && ip link del "$WG_IF" 2>/dev/null
    else
      json_save "$PICKED" "$old"; state_set exit "$prev_exit" || true; apply_config_quiet; tell_warn "回滚"
    fi
  else
    rm -f "$PICKED"
    if apply_config; then tell_ok "已删除"
    else json_save "$PICKED" "$old"; apply_config_quiet; tell_warn "回滚"; fi
  fi
  wait_key
}

peer_stop(){
  clear; local prev; prev=$(state_get exit)
  state_set exit direct || { tell_warn "写入失败"; wait_key; return; }
  if apply_config; then tell_ok "已恢复直连"
  else state_set exit "$prev" || true; apply_config_quiet; tell_warn "回滚"; fi
  wait_key
}

wg_client_active(){
  [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] && [ "$(jq -r .role "$WG_CONF")" = client ]
}

exit_label(){
  local s; s=$(state_get exit)
  case $s in direct) echo "直连" ;; wireguard) echo "WireGuard 专线" ;; *) [ -f "$PEER_DIR/$s.json" ] && jq -r .name "$PEER_DIR/$s.json" || echo "$s" ;; esac
}

# ============ 客户端状态 ============
get_ip_info(){
  local m=$1 res ip c asn nm
  res=$(curl -s -${m} -m 5 https://ipwho.is/ 2>/dev/null)
  ip=$(jq -r '.ip // empty' <<<"$res" 2>/dev/null)
  if [ -n "$ip" ]; then
    c=$(jq -r '.country // empty' <<<"$res" 2>/dev/null)
    asn=$(jq -r '.connection.asn // empty' <<<"$res" 2>/dev/null); [ -n "$asn" ] && asn="AS$asn"
    nm=$(jq -r '.connection.org // empty' <<<"$res" 2>/dev/null)
    IP_INFO_IP="$ip"; IP_INFO_C="$c"; IP_INFO_ASN="$asn"; IP_INFO_NAME="$nm"
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
  local ex=$(state_get exit) pn="直连"
  if [ "$ex" != direct ]; then
    if [ "$ex" = wireguard ]; then pn="WireGuard"
    else
      [ -f "$PEER_DIR/$ex.json" ] && pn=$(jq -r .outbound.type "$PEER_DIR/$ex.json" 2>/dev/null)
      pn="${pn:-未知}"
    fi
  fi
  tell "  当前出口: ${CYAN}${pn}${PLAIN}"; tell ""
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
      0) break ;; *) tell_warn "无效"; sleep 1 ;;
    esac
  done
}

# ============ WireGuard 管理 ============
wg_gen_keypair(){
  local kp
  kp=$("$CORE" generate wg-keypair 2>/dev/null)
  WG_PRIV=$(awk '/PrivateKey/{print $2}' <<<"$kp")
  WG_PUB=$(awk '/PublicKey/{print $2}' <<<"$kp")
  [ -n "$WG_PRIV" ] && [ -n "$WG_PUB" ]
}

wg_parse_dual(){
  local raw=$1
  WG_P4=$(printf '%s' "$raw" | tr ',' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | head -1)
  WG_P6=$(printf '%s' "$raw" | tr ',' '\n' | grep ':' | grep -E '/[0-9]+$' | head -1)
  [ -n "$WG_P4" ] || WG_P4="10.7.0.1/24"
  [ -n "$WG_P6" ] || WG_P6="fd00:7::1/64"
}

wg_derive_peer4(){
  local ip=$1
  if [[ "$ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+ ]]; then
    printf '%s.2/32' "${BASH_REMATCH[1]}"
  else
    printf '10.7.0.2/32'
  fi
}

wg_derive_peer6(){
  local ip=$1
  ip=${ip%%/*}
  if [[ "$ip" =~ ^([0-9a-fA-F:]+)::[0-9a-fA-F]+$ ]]; then
    printf '%s::2/128' "${BASH_REMATCH[1]}"
  else
    printf 'fd00:7::2/128'
  fi
}

menu_wireguard(){
  local rl tl
  while :; do
    clear
    tell "${CYAN}======== WireGuard 管理 ========${PLAIN}"
    if [ -f "$WG_CONF" ]; then
      [ "$(jq -r '.role//""' "$WG_CONF" 2>/dev/null)" = server ] && rl="服务端" || rl="客户端"
      [ "$(jq -r '.enabled//false' "$WG_CONF" 2>/dev/null)" = true ] \
        && tl="${GREEN}运行中${PLAIN}" \
        || tl="${RED}已挂起${PLAIN}"
      tell "  角色: ${CYAN}${rl}${PLAIN} | 隧道: ${tl}"
    else
      tell "  未配置"
    fi
    tell ""
    tell "  1. 初始化配置"
    tell "  2. 修改配置信息"
    tell "  3. 切换运行状态"
    tell "  4. 隧道状态信息"
    tell "  5. 删除隧道配置"
    tell "  6. 退出"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) wg_init_config ;;
      2) wg_modify_config ;;
      3) wg_toggle_state ;;
      4) wg_show_info ;;
      5) wg_delete_config ;;
      6) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

wg_init_config(){
  while :; do
    clear
    tell "${CYAN}======== 初始化 WireGuard ========${PLAIN}"
    tell "  1. 部署为服务端"
    tell "  2. 部署为客户端"
    tell "  3. 退出"
    tell "${CYAN}=================================${PLAIN}"
    case $(prompt "请选择" "1") in
      1) wg_setup_server; break ;;
      2) wg_setup_client; break ;;
      3) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

wg_setup_server(){
  local s4 s6 c4 c6 port client_pub body
  clear
  wg_gen_keypair || { tell_warn "密钥生成失败"; wait_key; return; }
  tell "${CYAN}════════════════════════════════${PLAIN}"
  tell "${GREEN}  本机公钥: ${WG_PUB}${PLAIN}"
  tell "${CYAN}────────────────────────────────${PLAIN}"
  tell ""
  local raw_ip
  raw_ip=$(prompt "内网双栈IP" "10.7.0.1/24,fd00:7::1/64")
  wg_parse_dual "$raw_ip"
  s4="$WG_P4"; s6="$WG_P6"
  c4=$(wg_derive_peer4 "$s4"); c6=$(wg_derive_peer6 "$s6")
  port=$(prompt "监听端口" "$(random_port)")
  while ! validate_port "$port" u ""; do
    port=$(prompt "监听端口" "$(random_port)")
  done
  client_pub=$(prompt "客户端公钥 (留空稍后回填)")
  body=$(jq -n \
    --arg priv "$WG_PRIV" --arg pub "$WG_PUB" \
    --argjson port "$port" \
    --arg s4 "$s4" --arg s6 "$s6" \
    --arg c4 "$c4" --arg c6 "$c6" \
    --arg cp "$client_pub" \
    --arg iface "$WG_IF" '
    {
      role:"server",
      enabled:false,
      private_key:$priv,
      public_key:$pub,
      listen_port:$port,
      peer_public_key:$cp,
      peer_ip:($c4|split("/")[0]),
      peer_host:"",
      peer_port:0,
      address:[$s4,$s6],
      client_address:[$c4,$c6],
      endpoint:{
        type:"wireguard",
        tag:"wireguard",
        system:true,
        name:$iface,
        mtu:1408,
        address:[$s4,$s6],
        private_key:$priv,
        listen_port:$port,
        peers:[{public_key:$cp,allowed_ips:[$c4,$c6]}]
      }
    }')
  json_save "$WG_CONF" "$body" || { tell_warn "配置写入失败"; wait_key; return; }
  clear
  tell "${GREEN}[√] 配置成功${PLAIN}"
  tell ""
  tell "  模式: ${CYAN}服务端${PLAIN}"
  tell "  隧道内网双栈IP: ${GREEN}$c4, $c6${PLAIN}"
  tell "  服务端双栈IP:   ${GREEN}$s4, $s6${PLAIN}"
  tell "  监听端口:       ${GREEN}$port${PLAIN}"
  tell "  本机公钥:       ${GREEN}$WG_PUB${PLAIN}"
  tell ""
  tell "${YELLOW}>> 按回车键开启隧道...${PLAIN}"
  read_line >/dev/null
  wg_start_tunnel
}

wg_setup_client(){
  local host port raw_ip spub c4 c6 s4 s6 body
  clear
  wg_gen_keypair || { tell_warn "密钥生成失败"; wait_key; return; }
  tell "${CYAN}════════════════════════════════${PLAIN}"
  tell "${GREEN}  本机公钥: ${WG_PUB}${PLAIN}"
  tell "${CYAN}────────────────────────────────${PLAIN}"
  tell ""
  host=$(prompt "服务端 IP 或域名")
  [ -n "$host" ] || { tell_warn "服务端地址不能为空"; wait_key; return; }
  port=$(prompt "服务端监听端口")
  while ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; do
    tell_warn "端口无效 (1-65535)"
    port=$(prompt "服务端监听端口")
  done
  raw_ip=$(prompt "内网双栈IP" "10.7.0.2/32,fd00:7::2/128")
  wg_parse_dual "$raw_ip"
  c4="$WG_P4"; c6="$WG_P6"
  s4=$(wg_derive_peer4 "$c4"); s6=$(wg_derive_peer6 "$c6")
  spub=$(prompt "服务端公钥")
  [ -n "$spub" ] || { tell_warn "服务端公钥不能为空"; wait_key; return; }
  body=$(jq -n \
    --arg priv "$WG_PRIV" --arg pub "$WG_PUB" \
    --arg host "$host" --argjson port "$port" \
    --arg sp "$spub" \
    --arg c4 "$c4" --arg c6 "$c6" \
    --arg s4 "$s4" --arg s6 "$s6" \
    --arg iface "$WG_IF" '
    {
      role:"client",
      enabled:false,
      private_key:$priv,
      public_key:$pub,
      listen_port:0,
      peer_public_key:$sp,
      peer_ip:($s4|split("/")[0]),
      peer_host:$host,
      peer_port:$port,
      address:[$c4,$c6],
      server_address:[$s4,$s6],
      endpoint:{
        type:"wireguard",
        tag:"wireguard",
        system:true,
        name:$iface,
        mtu:1408,
        address:[$c4,$c6],
        private_key:$priv,
        peers:[{
          address:$host,
          port:$port,
          public_key:$sp,
          allowed_ips:["0.0.0.0/0","::/0"]
        }]
      }
    }')
  json_save "$WG_CONF" "$body" || { tell_warn "配置写入失败"; wait_key; return; }
  clear
  tell "${GREEN}[√] 配置成功${PLAIN}"
  tell ""
  tell "  模式: ${CYAN}客户端${PLAIN}"
  tell "  隧道内网双栈IP: ${GREEN}$c4, $c6${PLAIN}"
  tell "  服务端双栈IP:   ${GREEN}$s4, $s6${PLAIN}"
  tell "  服务端地址:     ${GREEN}$host:$port${PLAIN}"
  tell "  本机公钥:       ${GREEN}$WG_PUB${PLAIN}"
  tell ""
  tell "${YELLOW}>> 按回车键开启隧道...${PLAIN}"
  read_line >/dev/null
  wg_start_tunnel
}

wg_show_info(){
  clear
  if [ ! -f "$WG_CONF" ]; then tell_warn "未配置 WireGuard"; wait_key; return; fi
  local role pub addr enabled c_addr s_addr host port spub
  role=$(jq -r '.role//""' "$WG_CONF")
  pub=$(jq -r '.public_key//""' "$WG_CONF")
  addr=$(jq -r '.address|join(", ")' "$WG_CONF")
  enabled=$(jq -r '.enabled//false' "$WG_CONF")
  if [ "$role" = "server" ]; then
    c_addr=$(jq -r '.client_address|join(", ")' "$WG_CONF")
    port=$(jq -r '.listen_port//0' "$WG_CONF")
    tell "${CYAN}========== 服务端隧道信息 ==========${PLAIN}"
    tell "  运行状态: $([ "$enabled" = true ] && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${RED}已挂起${PLAIN}")"
    tell ""
    tell "  模式:           ${CYAN}服务端${PLAIN}"
    tell "  隧道内网双栈IP: ${GREEN}$c_addr${PLAIN}"
    tell "  服务端双栈IP:   ${GREEN}$addr${PLAIN}"
    tell "  监听端口:       ${GREEN}$port${PLAIN}"
    tell "  本机公钥:       ${GREEN}$pub${PLAIN}"
    local cp; cp=$(jq -r '.peer_public_key//""' "$WG_CONF")
    if [ -n "$cp" ]; then tell "  客户端公钥:     ${GREEN}$cp${PLAIN}"
    else tell "  客户端公钥:     ${YELLOW}<待回填>${PLAIN}"; fi
  else
    host=$(jq -r '.peer_host//""' "$WG_CONF")
    port=$(jq -r '.peer_port//0' "$WG_CONF")
    s_addr=$(jq -r '.server_address|join(", ")' "$WG_CONF")
    spub=$(jq -r '.peer_public_key//""' "$WG_CONF")
    tell "${CYAN}========== 客户端隧道信息 ==========${PLAIN}"
    tell "  运行状态: $([ "$enabled" = true ] && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${RED}已挂起${PLAIN}")"
    tell ""
    tell "  模式:           ${CYAN}客户端${PLAIN}"
    tell "  隧道内网双栈IP: ${GREEN}$addr${PLAIN}"
    tell "  服务端双栈IP:   ${GREEN}$s_addr${PLAIN}"
    tell "  服务端地址:     ${GREEN}$host:$port${PLAIN}"
    tell "  本机公钥:       ${GREEN}$pub${PLAIN}"
    [ -n "$spub" ] && tell "  服务端公钥:     ${GREEN}$spub${PLAIN}" || tell "  服务端公钥:     ${YELLOW}<待回填>${PLAIN}"
  fi
  wait_key
}

wg_modify_config(){
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  local role; role=$(jq -r '.role//""' "$WG_CONF")
  if [ "$role" = "server" ]; then wg_modify_server; else wg_modify_client; fi
}

wg_modify_server(){
  local cur_port cur_addr cur_caddr cur_cpub
  while :; do
    cur_port=$(jq -r '.listen_port//0' "$WG_CONF")
    cur_addr=$(jq -r '.address|join(", ")' "$WG_CONF")
    cur_caddr=$(jq -r '.client_address|join(", ")' "$WG_CONF")
    cur_cpub=$(jq -r '.peer_public_key//""' "$WG_CONF")
    clear
    tell "${CYAN}========== 修改服务端配置 ==========${PLAIN}"
    tell "  1. 监听端口        [当前: $cur_port]"
    tell "  2. 服务端双栈IP    [当前: $cur_addr]"
    tell "  3. 客户端双栈IP    [当前: $cur_caddr]"
    tell "  4. 客户端公钥      [当前: ${cur_cpub:-未设置}]"
    tell "  5. 重新生成密钥对"
    tell "  0. 返回"
    tell "${CYAN}===================================${PLAIN}"
    local choice; choice=$(prompt "请选择")
    case "$choice" in
      0) return ;;
      1) local np; np=$(prompt "新监听端口" "$cur_port")
         while ! validate_port "$np" u "$cur_port"; do np=$(prompt "新监听端口" "$cur_port"); done
         json_edit "$WG_CONF" '.listen_port=$v|.endpoint.listen_port=$v' --argjson v "$np" || { tell_warn "写入失败"; wait_key; continue; }
         wg_apply_config_or_warn ;;
      2) local ns; ns=$(prompt "新服务端双栈IP" "$cur_addr"); wg_parse_dual "$ns"
         json_edit "$WG_CONF" '.address=[$a,$b]|.endpoint.address=[$a,$b]' --arg a "$WG_P4" --arg b "$WG_P6" || { tell_warn "写入失败"; wait_key; continue; }
         wg_apply_config_or_warn ;;
      3) local nc; nc=$(prompt "新客户端双栈IP" "$cur_caddr"); wg_parse_dual "$nc"
         local d4 d6; d4="$WG_P4"; d6="$WG_P6"
         json_edit "$WG_CONF" '.client_address=[$a,$b]|.endpoint.peers[0].allowed_ips=[$a,$b]' --arg a "$d4" --arg b "$d6" || { tell_warn "写入失败"; wait_key; continue; }
         wg_apply_config_or_warn ;;
      4) local nk; nk=$(prompt "新客户端公钥" "$cur_cpub")
         [ -n "$nk" ] || { tell_warn "公钥不能为空"; wait_key; continue; }
         json_edit "$WG_CONF" '.peer_public_key=$k|.endpoint.peers[0].public_key=$k' --arg k "$nk" || { tell_warn "写入失败"; wait_key; continue; }
         wg_apply_config_or_warn ;;
      5) wg_gen_keypair || { tell_warn "生成失败"; wait_key; continue; }
         json_edit "$WG_CONF" '.private_key=$p|.public_key=$u|.endpoint.private_key=$p' --arg p "$WG_PRIV" --arg u "$WG_PUB" || { tell_warn "写入失败"; wait_key; continue; }
         tell_ok "已重新生成密钥对"; tell "  新本机公钥: ${GREEN}$WG_PUB${PLAIN}"; wait_key ;;
      *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
}

wg_modify_client(){
  local cur_host cur_port cur_saddr cur_caddr cur_spub
  while :; do
    cur_host=$(jq -r '.peer_host//""' "$WG_CONF")
    cur_port=$(jq -r '.peer_port//0' "$WG_CONF")
    cur_saddr=$(jq -r '.server_address|join(", ")' "$WG_CONF")
    cur_caddr=$(jq -r '.address|join(", ")' "$WG_CONF")
    cur_spub=$(jq -r '.peer_public_key//""' "$WG_CONF")
    clear
    tell "${CYAN}========== 修改客户端配置 ==========${PLAIN}"
    tell "  1. 服务端地址      [当前: $cur_host]"
    tell "  2. 服务端端口      [当前: $cur_port]"
    tell "  3. 客户端双栈IP    [当前: $cur_caddr]"
    tell "  4. 服务端公钥      [当前: ${cur_spub:-未设置}]"
    tell "  5. 重新生成密钥对"
    tell "  0. 返回"
    tell "${CYAN}===================================${PLAIN}"
    local choice; choice=$(prompt "请选择")
    case "$choice" in
      0) return ;;
      1) local nh; nh=$(prompt "新服务端地址" "$cur_host")
         [ -n "$nh" ] || { tell_warn "不能为空"; wait_key; continue; }
         json_edit "$WG_CONF" '.peer_host=$h|.endpoint.peers[0].address=$h' --arg h "$nh" || { tell_warn "写入失败"; wait_key; continue; }
         wg_apply_config_or_warn ;;
      2) local np; np=$(prompt "新服务端端口" "$cur_port")
         while ! [[ "$np" =~ ^[0-9]+$ ]] || [ "$np" -lt 1 ] || [ "$np" -gt 65535 ]; do tell_warn "端口无效"; np=$(prompt "新服务端端口" "$cur_port"); done
         json_edit "$WG_CONF" '.peer_port=$p|.endpoint.peers[0].port=$p' --argjson p "$np" || { tell_warn "写入失败"; wait_key; continue; }
         wg_apply_config_or_warn ;;
      3) local nc; nc=$(prompt "新客户端双栈IP" "$cur_caddr"); wg_parse_dual "$nc"
         json_edit "$WG_CONF" '.address=[$a,$b]|.endpoint.address=[$a,$b]' --arg a "$WG_P4" --arg b "$WG_P6" || { tell_warn "写入失败"; wait_key; continue; }
         wg_apply_config_or_warn ;;
      4) local nk; nk=$(prompt "新服务端公钥" "$cur_spub")
         [ -n "$nk" ] || { tell_warn "不能为空"; wait_key; continue; }
         json_edit "$WG_CONF" '.peer_public_key=$k|.endpoint.peers[0].public_key=$k' --arg k "$nk" || { tell_warn "写入失败"; wait_key; continue; }
         wg_apply_config_or_warn ;;
      5) wg_gen_keypair || { tell_warn "生成失败"; wait_key; continue; }
         json_edit "$WG_CONF" '.private_key=$p|.public_key=$u|.endpoint.private_key=$p' --arg p "$WG_PRIV" --arg u "$WG_PUB" || { tell_warn "写入失败"; wait_key; continue; }
         tell_ok "已重新生成密钥对"; tell "  新本机公钥: ${GREEN}$WG_PUB${PLAIN}"; wait_key ;;
      *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
}

wg_apply_config_or_warn(){
  if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then
    if apply_config; then tell_ok "已生效"; else tell_warn "应用失败，请检查配置"; fi
  else tell_ok "已保存"; fi
  wait_key
}

wg_toggle_state(){
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  local en; en=$(jq -r '.enabled//false' "$WG_CONF")
  if [ "$en" = "true" ]; then wg_stop_tunnel; else wg_start_tunnel; fi
}

wg_start_tunnel(){
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化"; wait_key; return; }
  local role prev old
  role=$(jq -r '.role//""' "$WG_CONF")
  prev=$(state_get exit)
  old=$(cat "$WG_CONF")
  if [ -z "$(jq -r '.peer_public_key//""' "$WG_CONF")" ]; then
    tell_warn "缺少对端公钥，请先回填"; wait_key; return
  fi
  if [ "$role" = "client" ]; then
    if [ "$prev" != "direct" ] && [ "$prev" != "wireguard" ]; then
      tell_warn "当前已有代理出口 ($prev)，请先停止"; wait_key; return
    fi
    wg_endpoint_route_excludes "$(jq -r '.peer_host // ""' "$WG_CONF")" >/dev/null 2>&1 \
      || { tell_warn "服务端地址解析或物理路由异常"; wait_key; return; }
    state_set exit wireguard || { tell_warn "状态写入失败"; wait_key; return; }
  fi
  if [ "$role" = "server" ]; then
    wg_nat_apply || { printf '%s\n' "$old" | json_write "$WG_CONF"; [ "$role" = "client" ] && state_set exit "$prev"; tell_warn "NAT 初始化失败"; wait_key; return; }
  fi
  json_edit "$WG_CONF" '.enabled=true' || {
    [ "$role" = "server" ] && wg_nat_remove
    [ "$role" = "client" ] && state_set exit "$prev"
    tell_warn "启用失败"; wait_key; return
  }
  if apply_config; then tell_ok "隧道已开启"
  else
    printf '%s\n' "$old" | json_write "$WG_CONF"
    [ "$role" = "client" ] && state_set exit "$prev"
    [ "$role" = "server" ] && wg_nat_remove
    apply_config_quiet; tell_warn "开启失败，已回滚"
  fi
  wait_key
}

wg_stop_tunnel(){
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化"; wait_key; return; }
  local role prev old
  role=$(jq -r '.role//""' "$WG_CONF")
  prev=$(state_get exit)
  old=$(cat "$WG_CONF")
  json_edit "$WG_CONF" '.enabled=false' || { tell_warn "写入失败"; wait_key; return; }
  if [ "$role" = "server" ]; then
    wg_nat_remove || { printf '%s\n' "$old" | json_write "$WG_CONF"; tell_warn "NAT 清理失败"; wait_key; return; }
  fi
  if [ "$role" = "client" ] && [ "$prev" = "wireguard" ]; then
    state_set exit direct || { printf '%s\n' "$old" | json_write "$WG_CONF"; tell_warn "状态写入失败"; wait_key; return; }
  fi
  if apply_config; then tell_ok "隧道已关闭"
  else
    printf '%s\n' "$old" | json_write "$WG_CONF"
    state_set exit "$prev" || true
    [ "$role" = "server" ] && wg_nat_apply
    apply_config_quiet; tell_warn "关闭失败，已回滚"
  fi
  wait_key
}

wg_delete_config(){
  clear
  if [ ! -f "$WG_CONF" ]; then tell_warn "未配置 WireGuard，无需删除"; wait_key; return; fi
  prompt_yes "确认删除 WireGuard 配置" || return
  local bak pe we wr
  bak=$(cat "$WG_CONF"); pe=$(state_get exit)
  we=$(jq -r '.enabled//false' <<<"$bak"); wr=$(jq -r '.role//""' <<<"$bak")
  rm -f "$WG_CONF"
  [ "$wr" = "server" ] && wg_nat_remove
  if [ "$pe" = "wireguard" ]; then
    if ! state_set exit direct; then
      printf '%s\n' "$bak" | json_write "$WG_CONF" >/dev/null 2>&1 || true
      tell_warn "状态写入失败，未删除配置"; wait_key; return
    fi
  fi
  if apply_config; then
    tell_ok "已清除 WireGuard 配置"
    ip link del "$WG_IF" 2>/dev/null || true
  else
    printf '%s\n' "$bak" | json_write "$WG_CONF"
    state_set exit "$pe" || true
    [ "$wr" = "server" ] && [ "$we" = "true" ] && wg_nat_apply
    apply_config_quiet; tell_warn "删除失败，已回滚"
  fi
  wait_key
}

wg_nat_apply(){
  local p4 p6 fe fc so4 so6
  p4=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  p6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)
  fe=0; fc=""
  [ -f /etc/sysctl.d/99-sbm-forward.conf ] && { fe=1; fc=$(cat /etc/sysctl.d/99-sbm-forward.conf 2>/dev/null || true); }
  jq -n --argjson v4 "$p4" --argjson v6 "$p6" --argjson fe "$fe" --arg fc "$fc" '{prev4:$v4,prev6:$v6,applied4:1,applied6:1,fe:$fe,fc:$fc}' >"$SBM_DIR/nat_state.json.tmp" 2>/dev/null
  install -m600 "$SBM_DIR/nat_state.json.tmp" "$SBM_DIR/nat_state.json" 2>/dev/null
  rm -f "$SBM_DIR/nat_state.json.tmp"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 && sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || { wg_nat_remove; return 1; }
  printf '%s\n' 'net.ipv4.ip_forward=1' 'net.ipv6.conf.all.forwarding=1' > /etc/sysctl.d/99-sbm-forward.conf
  so4=$(default_iface_v4); so6=$(default_iface_v6)
  nft delete table ip sbm_nat 2>/dev/null || true
  nft add table ip sbm_nat 2>/dev/null || { wg_nat_remove; return 1; }
  nft add chain ip sbm_nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || { wg_nat_remove; return 1; }
  [ -n "$so4" ] && { nft add rule ip sbm_nat postrouting oifname "$so4" masquerade 2>/dev/null || { wg_nat_remove; return 1; }; }
  nft delete table ip6 sbm_nat 2>/dev/null || true
  nft add table ip6 sbm_nat 2>/dev/null || { wg_nat_remove; return 1; }
  nft add chain ip6 sbm_nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || { wg_nat_remove; return 1; }
  [ -n "$so6" ] && { nft add rule ip6 sbm_nat postrouting oifname "$so6" masquerade 2>/dev/null || { wg_nat_remove; return 1; }; }
  return 0
}

wg_nat_remove(){
  local p4 p6 a4 a6 fe fc cc c4 c6 rc=0
  nft list table ip sbm_nat >/dev/null 2>&1 && nft delete table ip sbm_nat >/dev/null 2>&1 || true
  nft list table ip6 sbm_nat >/dev/null 2>&1 && nft delete table ip6 sbm_nat >/dev/null 2>&1 || true
  [ -f "$SBM_DIR/nat_state.json" ] || return 0
  p4=$(jq -r '.prev4 // 0' "$SBM_DIR/nat_state.json"); p6=$(jq -r '.prev6 // 0' "$SBM_DIR/nat_state.json")
  a4=$(jq -r '.applied4 // 1' "$SBM_DIR/nat_state.json"); a6=$(jq -r '.applied6 // 1' "$SBM_DIR/nat_state.json")
  fe=$(jq -r '.fe // 0' "$SBM_DIR/nat_state.json"); fc=$(jq -r '.fc // ""' "$SBM_DIR/nat_state.json")
  [ "$p4" = 0 ] || [ "$p4" = 1 ] || p4=0; [ "$p6" = 0 ] || [ "$p6" = 1 ] || p6=0
  [ "$a4" = 0 ] || [ "$a4" = 1 ] || a4=1; [ "$a6" = 0 ] || [ "$a6" = 1 ] || a6=1
  cc=""; [ -f /etc/sysctl.d/99-sbm-forward.conf ] && cc=$(cat /etc/sysctl.d/99-sbm-forward.conf 2>/dev/null || true)
  c4=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "")
  c6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "")
  [ "$c4" = "$a4" ] && sysctl -w net.ipv4.ip_forward="$p4" >/dev/null 2>&1 || rc=1
  [ "$c6" = "$a6" ] && sysctl -w net.ipv6.conf.all.forwarding="$p6" >/dev/null 2>&1 || rc=1
  if [ "$cc" = $'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1' ]; then
    [ "$fe" = 1 ] && printf '%s\n' "$fc" > /etc/sysctl.d/99-sbm-forward.conf || rm -f /etc/sysctl.d/99-sbm-forward.conf
  fi
  [ "$rc" = 0 ] && rm -f "$SBM_DIR/nat_state.json"
  return "$rc"
}

# ============ 内核安装与服务 ============
install_core(){
  local json url asset cand tmp found
  json=$(release_json)
  grep -q '"tag_name"' <<<"$json" || { tell_warn "获取版本信息失败或 API 限流"; return 1; }
  for cand in $(asset_candidates); do
    url=$(jq -r --arg s "$cand.tar.gz" '.assets[]?|select(.name|endswith($s))|.browser_download_url' <<<"$json" | head -1)
    [ -n "$url" ] && { asset=$cand; break; }
  done
  [ -n "$url" ] || { tell_warn "未找到匹配架构"; return 1; }
  tmp=$(mktemp -d); TMP_FILES="$TMP_FILES $tmp"
  if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 240 "$url" -o "$tmp/c.tar.gz" 2>/dev/null; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 240 "$url" -o "$tmp/c.tar.gz" 2>/dev/null || { rm -rf "$tmp"; tell_warn "下载失败"; return 1; }
  fi
  tar -xzf "$tmp/c.tar.gz" -C "$tmp" || { rm -rf "$tmp"; tell_warn "解压失败"; return 1; }
  found=$(find "$tmp" -type f -name sing-box -perm -u+x | head -1)
  [ -n "$found" ] || { rm -rf "$tmp"; tell_warn "未找到二进制"; return 1; }
  "$found" version >/dev/null 2>&1 || { rm -rf "$tmp"; tell_warn "二进制无法运行"; return 1; }
  cand="$CORE.tmp.$$"
  if ! install -m755 "$found" "$cand" || ! "$cand" version >/dev/null 2>&1; then
    rm -f "$cand"; rm -rf "$tmp"; tell_warn "校验失败"; return 1
  fi
  mv -f "$cand" "$CORE" || { rm -f "$cand"; rm -rf "$tmp"; tell_warn "安装失败"; return 1; }
  rm -rf "$tmp"; core_cache_reset
  state_set asset "$asset" || { tell_warn "资产状态写入失败"; return 1; }
  tell_ok "sing-box 已安装: $(core_version) [$asset]"
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
  mkdir -p "$DROPIN_DIR"
  cat >"$DROPIN" <<EOF
[Service]
ExecStartPost=-$SHORTCUT --sync
ExecStopPost=-$SHORTCUT --clear-tun
EOF
  systemctl daemon-reload
}

# ============ 服务端菜单 ============
render_certificate_status(){
  local domain crt expiry days f
  domain=$(state_get domain); [ -n "$domain" ] || return 0
  tell ""; tell "  全局域名: $domain | 验证: $(state_get challenge)"
  crt=""
  while IFS= read -r f; do
    openssl x509 -in "$f" -noout -checkhost "$domain" >/dev/null 2>&1 && { crt="$f"; break; }
  done < <(find "$ACME_DIR" -type f -name '*.crt' 2>/dev/null)
  [ -n "$crt" ] || { tell "  ${YELLOW}证书状态: 未找到匹配域名的证书${PLAIN}"; return 0; }
  expiry=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
  [ -n "$expiry" ] || { tell "  ${RED}证书状态: 无法读取${PLAIN}"; return 0; }
  days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  tell "  到期时间: $expiry | 剩余: ${days} 天"
  systemctl is-active --quiet sing-box || tell_warn "服务离线，无法自动续期"
}

menu_server_info(){
  local file port proto status count=0 tcp udp
  tcp=$(listening_ports t); udp=$(listening_ports u)
  clear; tell "${CYAN}========== 服务端信息 ==========${PLAIN}"
  systemctl is-active --quiet sing-box && tell_ok "singbox: 运行中" || tell_warn "singbox: 未运行"
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    count=$((count+1)); port=$(jq -r .port "$file"); proto=$(jq -r .proto "$file")
    if [ "$proto" = u ]; then grep -qx "$port" <<<"$udp" && status="${GREEN}正常监听${PLAIN}" || status="${RED}未在监听${PLAIN}"
    else grep -qx "$port" <<<"$tcp" && status="${GREEN}正常监听${PLAIN}" || status="${RED}未在监听${PLAIN}"; fi
    tell ""; tell "── $(jq -r .name "$file") [$(jq -r .kind "$file")] | 端口 $port $status"
    render_share_uri "$file"
  done
  [ "$count" = 0 ] && tell "\n  暂无节点"
  render_certificate_status; wait_key
}

menu_change_domain(){
  local nd od oe oc file count=0 acme_bak="" acme_old=0
  clear; tell "${CYAN}========== 更换域名 ==========${PLAIN}"
  od=$(state_get domain); oe=$(state_get email); oc=$(state_get challenge)
  tell "  当前域名: ${od:-未设置}"; tell "  绑定节点:"
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    [ "$(jq -r .tls_mode "$file")" = acme ] && { tell "  - $(jq -r .name "$file") [$(jq -r .kind "$file")]"; count=$((count+1)); }
  done
  [ "$count" = 0 ] && tell "  无"
  echo ""
  nd=$(prompt "新域名 (留空取消)"); [ -z "$nd" ] && return
  if [ "$nd" != "$od" ]; then
    acme_bak=$(mktemp -d "$SBM_DIR/acme-backup.XXXXXX") || { tell_warn "无法创建备份"; wait_key; return; }
    if [ -d "$ACME_DIR" ]; then
      mv "$ACME_DIR" "$acme_bak/old" || { rm -rf "$acme_bak"; tell_warn "备份失败"; wait_key; return; }
      acme_old=1
    fi
    mkdir -p "$ACME_DIR" && chmod 700 "$ACME_DIR" || { [ "$acme_old" = 1 ] && { rm -rf "$ACME_DIR"; mv "$acme_bak/old" "$ACME_DIR"; }; rm -rf "$acme_bak"; tell_warn "准备失败"; wait_key; return; }
  fi
  if prompt_yes "同步重置验证机制"; then
    if ! state_set domain "" || ! state_set email ""; then
      tell_warn "清理失败"; rm -rf "$ACME_DIR"; [ "$acme_old" = 1 ] && mv "$acme_bak/old" "$ACME_DIR"; rm -rf "$acme_bak"; wait_key; return
    fi
    if ! setup_certificate "$nd"; then
      state_set domain "$od" || true; state_set email "$oe" || true; state_set challenge "$oc" || true
      rm -rf "$ACME_DIR"; [ "$acme_old" = 1 ] && mv "$acme_bak/old" "$ACME_DIR"; rm -rf "$acme_bak"; wait_key; return
    fi
  else
    validate_domain "$nd" || prompt_yes "验证未通过，强制写入" || {
      state_set domain "$od" || true; state_set email "$oe" || true; state_set challenge "$oc" || true
      rm -rf "$ACME_DIR"; [ "$acme_old" = 1 ] && mv "$acme_bak/old" "$ACME_DIR"; rm -rf "$acme_bak"; return
    }
    state_set domain "$nd" || { tell_warn "写入失败"; return; }
  fi
  if apply_config; then
    [ -n "$acme_bak" ] && rm -rf "$acme_bak"
    menu_server_info
  else
    state_set domain "$od" || true; state_set email "$oe" || true; state_set challenge "$oc" || true
    rm -rf "$ACME_DIR"; [ "$acme_old" = 1 ] && mv "$acme_bak/old" "$ACME_DIR"
    [ -d "$ACME_DIR" ] || mkdir -p "$ACME_DIR"
    rm -rf "$acme_bak"; apply_config_quiet; tell_warn "已回滚"; wait_key
  fi
}

menu_server(){
  local prev
  while :; do
    clear; tell "${CYAN}========== 服务端管理 ==========${PLAIN}"
    tell "  1. 创建协议"; tell "  2. 删除协议"; tell "  3. 修改配置"; tell "  4. 服务端信息"
    tell "  5. 更换域名"; tell "  6. 重启服务"; tell "  7. 停止服务"; tell "  0. 返回"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) menu_create_protocol ;; 2) menu_delete_protocol ;; 3) menu_modify_protocol ;;
      4) menu_server_info ;; 5) menu_change_domain ;;
      6) timeout 15 systemctl restart sing-box >/dev/null 2>&1
         if systemctl is-active --quiet sing-box; then sync_mgmt_rules; tell_ok "已重启"
         else tell_warn "重启失败"; fi
         wait_key ;;
      7) timeout 15 systemctl stop sing-box 2>/dev/null && tell_ok "已停止" || tell_warn "停止失败"
         wait_key ;;
      0) break ;;
      *) tell_warn "无效"; sleep 1 ;;
    esac
  done
}

# ============ 状态与更新 ============
update_core_transaction(){
  local cb oa ok=0 sa=0
  cb=$(mktemp) || { tell_warn "无法创建备份"; return 1; }
  if [ -x "$CORE" ] && ! cp -p "$CORE" "$cb"; then rm -f "$cb"; tell_warn "备份失败"; return 1; fi
  oa=$(state_get asset)
  systemctl is-active --quiet sing-box && sa=1
  if [ "$sa" = 1 ]; then
    timeout 15 systemctl stop sing-box >/dev/null 2>&1 || systemctl is-active --quiet sing-box && { rm -f "$cb"; tell_warn "无法停止服务"; return 1; }
  fi
  if install_core && apply_config; then
    if [ "$sa" = 1 ]; then
      systemctl is-active --quiet sing-box && ok=1
      [ "$ok" = 0 ] && systemctl start sing-box >/dev/null 2>&1 && systemctl is-active --quiet sing-box && ok=1
    else ok=1; fi
  fi
  if [ "$ok" = 0 ]; then
    [ -s "$cb" ] && install -m755 "$cb" "$CORE" >/dev/null 2>&1 || rm -f "$CORE"
    [ -n "$oa" ] && state_set asset "$oa" || state_set asset "" || true
    apply_config_quiet || tell_warn "旧内核配置重新应用失败"
    if [ "$sa" = 1 ] && ! systemctl is-active --quiet sing-box; then
      systemctl start sing-box >/dev/null 2>&1 || tell_warn "原服务恢复失败"
    fi
  fi
  rm -f "$cb"
  [ "$ok" = 1 ]
}

run_update(){
  local cur latest url tmp
  clear
  tell "正在检测 sing-box 内核更新..."
  cur=$(core_version); latest=$(remote_version)
  tell "本地版本: ${cur:-未知}"; tell "目标版本: ${latest:-获取失败}"
  if [ -z "$latest" ]; then tell_warn "无法获取最新版本"
  elif [ -z "$cur" ]; then
    prompt_yes "无法读取当前版本，是否重新安装 sing-box v$latest" && { update_core_transaction && tell_ok "重新安装完成" || tell_warn "失败"; }
  elif [ "$cur" != "$latest" ]; then
    prompt_yes "发现新版本 v$latest，是否立即更新" && { update_core_transaction && tell_ok "更新完成" || tell_warn "失败"; }
  else tell_ok "内核已是最新版本"; fi
  tell_gap
  tell "正在检测 s 脚本更新..."
  url="https://raw.githubusercontent.com/88860/-/main/s.sh"
  tmp=$(mktemp); TMP_FILES="$TMP_FILES $tmp"
  if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$url" -o "$tmp" 2>/dev/null; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$url" -o "$tmp" 2>/dev/null || { tell_warn "脚本下载失败"; wait_key; return; }
  fi
  if [ ! -s "$tmp" ]; then tell_warn "脚本为空"
  elif bash -n "$tmp" 2>/dev/null; then
    if cmp -s "$tmp" "$SELF"; then tell_ok "脚本已是最新版本"
    else install -m700 "$tmp" "$SELF" && { tell_ok "脚本更新成功，请重新运行"; exit 0; } || tell_warn "写入失败"; fi
  else tell_warn "脚本语法错误"; fi
  wait_key
}

run_uninstall(){
  local pkgs=() sa=0 wa=0
  clear
  tell_warn "警告: 卸载将清空所有配置"
  [ "$(prompt '输入 yes 确认')" = yes ] || return
  mapfile -t pkgs < <(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null)
  systemctl is-active --quiet sing-box && sa=1
  [ "$sa" = 1 ] && { systemctl stop sing-box >/dev/null 2>&1 || { tell_warn "停止失败"; return 1; }; }
  pgrep -x sing-box >/dev/null 2>&1 && { tell_warn "检测到独立 sing-box 进程"; return 1; }
  clear_rules
  nft delete table inet sbm_hop 2>/dev/null || true
  wg_nat_remove || { tell_warn "NAT 清理失败"; return 1; }
  ip link del "$WG_IF" 2>/dev/null || true
  ip link del "$TUN_IF" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "$SERVICE_UNIT" "$DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$SB_DIR" "$SBM_DIR" /var/lib/sing-box "$CORE" "$SHORTCUT"
  if [ ${#pkgs[@]} -gt 0 ]; then
    tell "脚本曾安装: [ ${pkgs[*]} ]"
    if prompt_yes "是否移除依赖组件"; then
      local owned=() p
      for p in "${pkgs[@]}"; do case "$p" in *'|owned') owned+=("${p%|owned}") ;; esac; done
      [ ${#owned[@]} -gt 0 ] && apt-get remove -y -q "${owned[@]}" >/dev/null 2>&1 || true
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
    local krnl=$(uname -r)
    local arch=$(uname -m)
    local mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}/MemFree/{f=$2}/Buffers/{b=$2}/^Cached/{c=$2}END{if(a=="")a=f+b+c; printf "%d / %d MB",(t-a)/1024,t/1024}' /proc/meminfo)
    local us=$(cut -d. -f1 /proc/uptime)
    local ud=$((us/86400)) uh=$(((us%86400)/3600)) um=$(((us%3600)/60)) up=""
    [ "$ud" -gt 0 ] && up="${ud}天"
    [ "$uh" -gt 0 ] && up="${up}${uh}小时"
    [ "$um" -gt 0 ] && up="${up}${um}分钟"
    [ -z "$up" ] && up="不足1分钟"
    local sv=$(core_version) sasset=$(state_get asset) ss="${RED}未运行${PLAIN}"
    systemctl is-active --quiet sing-box && ss="${GREEN}正常运行${PLAIN}"
    tell "  系统版本: ${os}"
    tell "  内核架构: ${krnl} (${arch})"
    tell "  内存状态: ${mem}"
    tell "  运行时间: ${up}"
    tell "  singbox : ${ss}"
    tell "  singbox版本: ${sv:-无} (${sasset:-未知})"
    tell ""
    render_client_ip_status
    tell ""
    tell "  1. 检测更新"
    tell "  2. 彻底卸载"
    tell "  0. 返回"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) run_update ;; 2) run_uninstall ;; 0) break ;;
      *) tell_warn "无效"; sleep 1 ;;
    esac
  done
}

# ============ 启动 ============
bootstrap(){
  init_dirs
  check_dependencies
  chmod 700 "$SELF" 2>/dev/null
  ln -sf "$SELF" "$SHORTCUT" 2>/dev/null
  load_net_cache
  probe_network_stack_async
  if [ ! -x "$CORE" ]; then
    echo -e "  ${CYAN}首次运行，安装 sing-box...${PLAIN}"
    install_core || exit 0
  fi
  if [ ! -f "$SERVICE_UNIT" ]; then write_service
  elif [ ! -f "$DROPIN" ]; then mkdir -p "$DROPIN_DIR"
    cat >"$DROPIN" <<EOF
[Service]
ExecStartPost=-$SHORTCUT --sync
ExecStopPost=-$SHORTCUT --clear-tun
EOF
    systemctl daemon-reload
  fi
  systemctl enable sing-box >/dev/null 2>&1
  [ ! -f "$CONFIG" ] && { build_config | json_write "$CONFIG" || exit 0; }
  "$CORE" check -c "$CONFIG" >/dev/null 2>&1 && systemctl enable --now sing-box >/dev/null 2>&1 || true
  sync_mgmt_rules
}

case $1 in
  --sync) init_dirs; load_net_cache; sync_mgmt_rules; exit 0 ;;
  --clear-tun) exit 0 ;;
  --reapply)
    exec 9>"$REAPPLY_LOCK"
    flock -w 5 9 || exit 0
    init_dirs
    load_net_cache
    p4="$NET_IF_V4"; p6="$NET_IF_V6"
    NET_IF_V4=$(default_iface_v4); NET_IF_V6=$(default_iface_v6)
    [ -n "$NET_IF_V4" ] || NET_IF_V4="$p4"
    [ -n "$NET_IF_V6" ] || NET_IF_V6="$p6"
    if [ "$NET_IF_V4" != "$p4" ] || [ "$NET_IF_V6" != "$p6" ]; then
      probe_network_stack
      [ -n "$NET_IF_V4" ] || NET_IF_V4="$p4"
      [ -n "$NET_IF_V6" ] || NET_IF_V6="$p6"
      tc=$(mktemp "${NET_CACHE}.XXXXXX") || { flock -u 9; exit 0; }
      printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" "$BIND_MODE" >"$tc" && mv -f "$tc" "$NET_CACHE" || rm -f "$tc"
    fi
    nc=$(mktemp); TMP_FILES="$TMP_FILES $nc"
    if ! build_config >"$nc" 2>/dev/null || [ ! -s "$nc" ]; then rm -f "$nc"; flock -u 9; exit 0; fi
    "$CORE" check -c "$nc" >/dev/null 2>&1 || { rm -f "$nc"; flock -u 9; exit 0; }
    if cmp -s "$nc" "$CONFIG"; then rm -f "$nc"; flock -u 9; exit 0; fi
    rm -f "$nc"
    _apply_config_locked >/dev/null 2>&1 || { flock -u 9; exit 0; }
    flock -u 9; exit 0 ;;
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
    *) tell_warn "无效"; sleep 1 ;;
  esac
done
