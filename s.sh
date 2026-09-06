#!/usr/bin/env bash
export LC_ALL=C
shopt -s nullglob

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
SELF=/root/s.sh
SHORTCUT=/usr/local/bin/s
CORE=/usr/local/bin/sing-box
SERVICE_UNIT=/etc/systemd/system/sing-box.service
DROPIN_DIR=/etc/systemd/system/sing-box.service.d
DROPIN=$DROPIN_DIR/sbm.conf
GH_API=https://api.github.com/repos/SagerNet/sing-box
TRACE_URL=https://www.cloudflare.com/cdn-cgi/trace
PROBE_URL=http://cp.cloudflare.com/generate_204
TUN_IF=sbmtun
WG_IF=sbmwg
CERT_TAG=acme-cert
BYPASS_PREF=90
HOP_TABLE=sbm_hop

REPORT=()
RETURN_MAIN=0
NODE_FILES=()
PEER_FILES=()
PICKED=""
CORE_VERSION=""
CORE_TAGS=""

[ "$(id -u)" = 0 ] || { echo "需要 root 运行"; exit 1; }

read_line(){
  local value
  if [ -c /dev/tty ]; then IFS= read -r value </dev/tty || value=""
  else IFS= read -r value || value=""; fi
  printf '%s' "$value"
}
prompt(){
  printf '  %s' "$1${2:+ [$2]}: " >&2
  local value; value=$(read_line)
  printf '%s' "${value:-$2}"
}
prompt_yes(){ local value; value=$(prompt "$1 (y/N)" n); [ "$value" = y ] || [ "$value" = Y ]; }
wait_key(){ printf '\n  回车返回' >&2; read_line >/dev/null; }
back_to_main(){ RETURN_MAIN=1; }

tell(){ printf '  %s\n' "$*" >&2; }
tell_ok(){ printf '  * %s\n' "$*" >&2; }
tell_warn(){ printf '  ! %s\n' "$*" >&2; }

out(){ REPORT+=("$*"); }
out_gap(){ REPORT+=(""); }
out_ok(){ REPORT+=("  * $*"); }
out_warn(){ REPORT+=("  ! $*"); }

term_rows(){ local r; r=$(tput lines 2>/dev/null); { [ -n "$r" ] && [ "$r" -ge 10 ]; } 2>/dev/null && echo "$r" || echo 24; }
term_cols(){ local c; c=$(tput cols 2>/dev/null); { [ -n "$c" ] && [ "$c" -ge 40 ]; } 2>/dev/null && echo "$c" || echo 80; }
render(){
  local rows cols limit used=0 line width
  rows=$(term_rows); cols=$(term_cols); limit=$((rows-3))
  clear
  for line in "${REPORT[@]}"; do
    width=$(( (${#line} + cols - 1) / cols )); [ "$width" -lt 1 ] && width=1
    if [ $((used+width)) -gt "$limit" ]; then
      printf '\n  -- 回车继续 --'; read_line >/dev/null; clear; used=0
    fi
    printf '%s\n' "$line"
    used=$((used+width))
  done
  REPORT=()
}
render_wait(){ render; wait_key; }

uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }
uri_decode(){ local s=${1//+/ }; s=${s//\\/\\\\}; printf '%b' "${s//%/\\x}"; }
slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18; }
random_uuid(){ cat /proc/sys/kernel/random/uuid; }
random_port(){ shuf -i 20000-60000 -n1; }
version_ge(){ [ -n "$1" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

json_write(){
  local dest=$1 tmp
  tmp=$(mktemp) || return 1
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
  if jq "$@" "$expr" "$file" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    install -m600 "$tmp" "$file"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

init_dirs(){
  mkdir -p "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box
  chmod 700 "$SBM_DIR" "$ACME_DIR"
  [ -f "$STATE" ] || printf '%s\n' '{"exit":"direct","domain":"","email":"","challenge":"http","asset":""}' | json_write "$STATE"
  [ -f "$PKG_LOG" ] || : >"$PKG_LOG"
}
state_get(){ jq -r --arg k "$1" '.[$k]//""' "$STATE" 2>/dev/null; }
state_set(){ json_edit "$STATE" '.[$k]=$v' --arg k "$1" --arg v "$2"; }

ensure_command(){
  local cmd=$1 pkg=${2:-$1}
  command -v "$cmd" >/dev/null 2>&1 && return 0
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" >/dev/null 2>&1
  command -v "$cmd" >/dev/null 2>&1 || return 1
  grep -qx "$pkg" "$PKG_LOG" 2>/dev/null || echo "$pkg" >>"$PKG_LOG"
}
check_dependencies(){
  local cmd missing=0
  for cmd in curl tar jq openssl nft ss ip ping; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done
  [ "$missing" = 1 ] && DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1
  for cmd in curl tar jq; do
    ensure_command "$cmd" || { tell_warn "$cmd 安装失败"; exit 1; }
  done
  ensure_command ip iproute2 || { tell_warn "iproute2 缺失"; exit 1; }
  ensure_command ss iproute2
  ensure_command openssl
  ensure_command nft nftables
  ensure_command ping iputils-ping
  return 0
}

core_version(){ [ -n "$CORE_VERSION" ] || CORE_VERSION=$([ -x "$CORE" ] && "$CORE" version 2>/dev/null | awk '/version/{print $3; exit}'); printf '%s' "$CORE_VERSION"; }
core_tags(){ [ -n "$CORE_TAGS" ] || CORE_TAGS=$([ -x "$CORE" ] && "$CORE" version 2>/dev/null | sed -n 's/^Tags: //p'); printf '%s' "$CORE_TAGS"; }
has_acme_support(){ [[ "$(core_tags)" == *with_acme* ]]; }
use_cert_provider(){ version_ge "$(core_version)" 1.14.0; }
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
release_json(){ curl -fsSL -m 20 "$GH_API/releases/latest" 2>/dev/null; }
remote_version(){ release_json | jq -r '.tag_name//""' | sed 's/^v//'; }

local_ipv4(){ ip -4 -o addr show scope global 2>/dev/null | awk -v a="$TUN_IF" -v b="$WG_IF" '$2!=a&&$2!=b{split($4,x,"/");print x[1];exit}'; }
local_ipv6(){ ip -6 -o addr show scope global 2>/dev/null | awk -v a="$TUN_IF" -v b="$WG_IF" '$2!=a&&$2!=b{split($4,x,"/");print x[1];exit}'; }
resolve_addresses(){ getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u; }

install_core(){
  local json url asset candidate tmp found
  json=$(release_json)
  [ -n "$json" ] || { tell_warn "无法访问 GitHub"; return 1; }
  for candidate in $(asset_candidates); do
    url=$(jq -r --arg s "$candidate.tar.gz" '.assets[]?|select(.name|endswith($s))|.browser_download_url' <<<"$json" | head -1)
    [ -n "$url" ] && { asset=$candidate; break; }
  done
  [ -n "$url" ] || { tell_warn "未找到匹配 $(uname -m) 的官方资产"; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL -m 240 "$url" -o "$tmp/core.tar.gz" || { rm -rf "$tmp"; tell_warn "下载失败"; return 1; }
  tar -xzf "$tmp/core.tar.gz" -C "$tmp" || { rm -rf "$tmp"; tell_warn "解压失败"; return 1; }
  found=$(find "$tmp" -type f -name sing-box | head -1)
  [ -n "$found" ] || { rm -rf "$tmp"; tell_warn "压缩包内未找到二进制"; return 1; }
  rm -f "$CORE"; install -m755 "$found" "$CORE"; rm -rf "$tmp"
  core_cache_reset
  state_set asset "$asset"
  tell_ok "sing-box $(core_version)  [$asset]"
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
ExecStart=$CORE -D /var/lib/sing-box -c $CONFIG run
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p "$DROPIN_DIR"
  cat >"$DROPIN" <<EOF
[Service]
ExecStartPost=$SELF --sync
ExecStopPost=$SELF --clear-hopping
EOF
  systemctl daemon-reload
}

ssh_ports(){
  {
    [ -n "$SSH_CONNECTION" ] && awk '{print $4}' <<<"$SSH_CONNECTION"
    sshd -T 2>/dev/null | awk '/^port /{print $2}'
    sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config 2>/dev/null
    sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config.d/*.conf 2>/dev/null
    ss -Hlntp 2>/dev/null | awk '/sshd/{print $4}' | sed 's/.*://'
  } | grep -E '^[1-9][0-9]*$' | sort -un
}
node_ports(){ local file; for file in "$NODE_DIR"/*.json; do jq -r '.port' "$file"; done | grep -E '^[1-9][0-9]*$'; }
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
  local guard=0 port
  while ip rule del pref "$BYPASS_PREF" 2>/dev/null; do guard=$((guard+1)); [ "$guard" -gt 64 ] && break; done
  guard=0
  while ip -6 rule del pref "$BYPASS_PREF" 2>/dev/null; do guard=$((guard+1)); [ "$guard" -gt 64 ] && break; done
  for port in $(protected_ports); do
    ip rule add pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null
    ip -6 rule add pref "$BYPASS_PREF" sport "$port" lookup main 2>/dev/null
  done
}
bypass_rules_present(){ [ -n "$(ip rule show pref "$BYPASS_PREF" 2>/dev/null)" ]; }
sync_hopping_rules(){
  nft delete table inet "$HOP_TABLE" 2>/dev/null
  local file range port
  file=$(hopping_node) || return 0
  range=$(jq -r '.hopping' "$file"); port=$(jq -r '.port' "$file")
  nft add table inet "$HOP_TABLE" 2>/dev/null || return 0
  nft add chain inet "$HOP_TABLE" prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null
  nft add rule inet "$HOP_TABLE" prerouting iifname != lo udp dport "$range" redirect to :"$port" 2>/dev/null
}
clear_hopping_rules(){ nft delete table inet "$HOP_TABLE" 2>/dev/null; }

acme_options(){
  local domain=$1 body
  body=$(jq -n --arg d "$domain" --arg e "$(state_get email)" --arg dir "$ACME_DIR" \
    '{domain:[$d],email:$e,data_directory:$dir}')
  use_cert_provider && body=$(jq '.key_type="p256"' <<<"$body")
  case $(state_get challenge) in
    alpn)
      body=$(jq '.disable_http_challenge=true' <<<"$body") ;;
    dns_cloudflare)
      body=$(jq --arg t "$(state_get cf_token)" \
        '.dns01_challenge={provider:"cloudflare",api_token:$t}' <<<"$body") ;;
    dns_alidns)
      body=$(jq --arg k "$(state_get ali_key)" --arg s "$(state_get ali_secret)" \
        '.dns01_challenge={provider:"alidns",access_key_id:$k,access_key_secret:$s}' <<<"$body") ;;
    dns_acmedns)
      body=$(jq --arg u "$(state_get acmedns_user)" --arg p "$(state_get acmedns_pass)" \
                --arg s "$(state_get acmedns_sub)" --arg r "$(state_get acmedns_url)" \
        '.dns01_challenge={provider:"acmedns",username:$u,password:$p,subdomain:$s,server_url:$r}' <<<"$body") ;;
    *)
      body=$(jq '.disable_tls_alpn_challenge=true' <<<"$body") ;;
  esac
  printf '%s' "$body"
}

build_config(){
  local selected domain inbounds outbounds endpoints rules dns_block final use_tun
  local peer_host node_files tls_extra providers strategy ipv6
  selected=$(state_get exit); domain=$(state_get domain)
  final=direct; use_tun=0; endpoints='[]'; peer_host=""; providers='[]'; tls_extra='{}'
  ipv6=$(local_ipv6); strategy=ipv4_only; [ -n "$ipv6" ] && strategy=prefer_ipv4
  node_files=("$NODE_DIR"/*.json)
  inbounds='[]'
  if [ ${#node_files[@]} -gt 0 ]; then
    if [ -n "$domain" ]; then
      if use_cert_provider; then
        providers=$(jq -n --arg t "$CERT_TAG" --argjson a "$(acme_options "$domain")" '[$a+{type:"acme",tag:$t}]')
        tls_extra=$(jq -n --arg t "$CERT_TAG" '{certificate_provider:$t}')
      else
        tls_extra=$(jq -n --argjson a "$(acme_options "$domain")" '{acme:$a}')
      fi
    fi
    inbounds=$(jq -s --arg d "$domain" --argjson x "$tls_extra" '
      [ .[] | .inbound as $in |
        if .tls_mode=="acme" then
          $in * {tls: ({enabled:true,server_name:$d}
                       + (if .alpn then {alpn:.alpn} else {} end)
                       + $x)}
        else $in end ]' "${node_files[@]}") || return 1
  fi
  outbounds='[{"type":"direct","tag":"direct"}]'
  if [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then
    endpoints=$(jq '[.endpoint]' "$WG_CONF")
    if [ "$(jq -r .role "$WG_CONF")" = client ]; then
      peer_host=$(jq -r '.peer_host//""' "$WG_CONF")
      [ "$selected" = wireguard ] && { final=wireguard; use_tun=1; }
    fi
  fi
  if [ "$selected" != direct ] && [ "$selected" != wireguard ] && [ -f "$PEER_DIR/$selected.json" ]; then
    outbounds=$(jq -n --argjson base "$outbounds" --slurpfile peer "$PEER_DIR/$selected.json" '$base + [$peer[0].outbound]')
    final=$selected; use_tun=1
  fi
  [ "$use_tun" = 1 ] && inbounds=$(jq -n --argjson list "$inbounds" --arg name "$TUN_IF" '
    [{type:"tun",tag:"tun-in",interface_name:$name,
      address:["172.19.0.1/30","fdfe:dcba:9876::1/126"],
      auto_route:true,strict_route:false,stack:"system",mtu:9000}] + $list')
  rules=$(jq -n --arg host "$peer_host" '
    [{action:"sniff"},
     {protocol:"dns",action:"hijack-dns"},
     {port:53,action:"hijack-dns"}]
    + (if $host=="" then [] else [{ip_cidr:[($host+"/32")],action:"route",outbound:"direct"}] end)
    + [{ip_is_private:true,action:"route",outbound:"direct"}]')
  dns_block=$(jq -n --arg detour "$final" --arg strategy "$strategy" '
    {servers:[{type:"local",tag:"dns-local"},
              {type:"udp",tag:"dns-remote",server:"1.1.1.1",detour:$detour}],
     final:"dns-remote",strategy:$strategy}')
  jq -n --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" \
        --argjson endpoints "$endpoints" --argjson rules "$rules" \
        --argjson dns "$dns_block" --argjson providers "$providers" --arg final "$final" '
    {log:{level:"warn",timestamp:true},
     dns:$dns,
     inbounds:$inbounds,
     outbounds:$outbounds,
     route:{rules:$rules,final:$final,auto_detect_interface:true,
            default_domain_resolver:{server:"dns-local"}}}
    | if ($endpoints|length)>0 then .endpoints=$endpoints else . end
    | if ($providers|length)>0 then .certificate_providers=$providers else . end'
}

apply_config(){
  local tmp error line
  tmp=$(mktemp)
  build_config >"$tmp" 2>/dev/null || { rm -f "$tmp"; out_warn "配置生成失败"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; out_warn "配置生成结果为空"; return 1; }
  if ! error=$("$CORE" check -c "$tmp" 2>&1); then
    out_warn "配置校验失败"
    while IFS= read -r line; do out "    $line"; done <<<"$(head -4 <<<"$error")"
    rm -f "$tmp"; return 1
  fi
  install -m600 "$tmp" "$CONFIG"; rm -f "$tmp"
  systemctl restart sing-box 2>/dev/null
  sleep 2
  if ! systemctl is-active --quiet sing-box; then
    out_warn "服务启动失败"
    while IFS= read -r line; do out "    $line"; done <<<"$(journalctl -u sing-box -n 5 --no-pager 2>/dev/null)"
    return 1
  fi
  sync_bypass_rules; sync_hopping_rules
  bypass_rules_present || out_warn "内核不支持 sport 策略路由，启用代理后 SSH 与节点端口可能中断"
  return 0
}
apply_config_quiet(){
  local saved=("${REPORT[@]}")
  apply_config >/dev/null 2>&1
  REPORT=("${saved[@]}")
}

arm_watchdog(){
  systemctl stop sbm-watchdog.timer sbm-watchdog.service 2>/dev/null
  systemctl reset-failed 'sbm-watchdog*' 2>/dev/null
  systemd-run --collect --unit=sbm-watchdog --on-active=30 "$SELF" --watchdog >/dev/null 2>&1 \
    || out_warn "看门狗布置失败，切换后请自行确认连通性"
}
run_watchdog(){
  local attempt previous
  for attempt in 1 2 3 4 5; do
    curl -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL" && exit 0
    sleep 2
  done
  previous=$(state_get exit)
  state_set exit direct
  [ "$previous" = wireguard ] && [ -f "$WG_CONF" ] && json_edit "$WG_CONF" '.enabled=false'
  build_config | json_write "$CONFIG" && systemctl restart sing-box
  sync_bypass_rules; sync_hopping_rules
  exit 0
}

validate_port(){
  local port=$1 proto=$2 allow=${3:-}
  [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { tell_warn "端口无效"; return 1; }
  [ "$port" = 80 ] && { tell_warn "80 保留给证书签发"; return 1; }
  [ "$port" = "$allow" ] && return 0
  grep -qx "$port" <<<"$(protected_ports)" && { tell_warn "与 SSH 或已有节点端口冲突"; return 1; }
  grep -qx "$port" <<<"$(listening_ports "$proto")" && { tell_warn "该端口已被占用"; return 1; }
  return 0
}
prompt_port(){
  local proto=$1 port
  while :; do
    port=$(prompt "端口，0 取消" "$(random_port)")
    [ "$port" = 0 ] && return 1
    validate_port "$port" "$proto" && { printf '%s' "$port"; return 0; }
  done
}
validate_range(){
  local range=$1 low high port
  [[ $range =~ ^[0-9]+-[0-9]+$ ]] || { tell_warn "格式应为 起始-结束"; return 1; }
  low=${range%-*}; high=${range#*-}
  [ "$low" -ge 1 ] && [ "$high" -le 65535 ] && [ "$low" -lt "$high" ] || { tell_warn "范围无效"; return 1; }
  for port in $(listening_ports u) $(protected_ports) 80 443; do
    [ "$port" -ge "$low" ] && [ "$port" -le "$high" ] && { tell_warn "范围内 $port 已被占用或受保护"; return 1; }
  done
  return 0
}
probe_handshake_target(){
  local target=$1 result
  command -v openssl >/dev/null || { tell_warn "无 openssl，跳过检测"; return 0; }
  result=$(echo | timeout 10 openssl s_client -connect "$target:443" -servername "$target" -alpn h2 -tls1_3 2>/dev/null)
  grep -q "TLSv1.3" <<<"$result" || { tell_warn "$target 不支持 TLS 1.3"; return 1; }
  grep -q "ALPN protocol: h2" <<<"$result" || { tell_warn "$target 不支持 HTTP/2"; return 1; }
  grep -qi "X25519" <<<"$result" || { tell_warn "$target 未协商 X25519，REALITY 可能不兼容"; return 1; }
  tell_ok "$target 可用"
  return 0
}
validate_domain(){
  local domain=$1 resolved ipv4 ipv6
  resolved=$(resolve_addresses "$domain")
  [ -n "$resolved" ] || { tell_warn "$domain 无法解析"; return 1; }
  ipv4=$(local_ipv4); ipv6=$(local_ipv6)
  if ! { [ -n "$ipv4" ] && grep -qx "$ipv4" <<<"$resolved"; } \
     && ! { [ -n "$ipv6" ] && grep -qx "$ipv6" <<<"$resolved"; }; then
    tell_warn "$domain 解析到 $(tr '\n' ' ' <<<"$resolved")，未指向本机"
    tell "若使用 Cloudflare 需关闭代理，QUIC 类协议无法经 CDN 转发"
    return 1
  fi
  case $(state_get challenge) in
    http) grep -qx 80 <<<"$(listening_ports t)" && { tell_warn "80 被占用，HTTP-01 无法签发"; return 1; } ;;
    alpn) grep -qx 443 <<<"$(listening_ports t)" && { tell_warn "443 被占用，TLS-ALPN-01 无法签发"; return 1; } ;;
  esac
  tell_ok "$domain 解析正常"
  return 0
}

setup_certificate(){
  local suggest=${1:-} domain email mode
  [ -n "$(state_get domain)" ] && [ -n "$(state_get email)" ] && return 0
  has_acme_support || { tell_warn "当前二进制不含 with_acme，无法自动签发"; return 1; }
  tell "该协议需要域名证书"
  domain=$(prompt "域名，留空取消" "$suggest"); [ -n "$domain" ] || return 1
  email=$(prompt "ACME 通知邮箱"); [ -n "$email" ] || return 1
  tell "1) HTTP-01      占用 80"
  tell "2) TLS-ALPN-01  占用 443"
  tell "3) DNS-01       Cloudflare"
  tell "4) DNS-01       阿里云 DNS"
  tell "5) DNS-01       ACME-DNS"
  case $(prompt "验证方式" 1) in
    2) mode=alpn ;;
    3) mode=dns_cloudflare; state_set cf_token "$(prompt 'Cloudflare API Token')" ;;
    4) mode=dns_alidns; state_set ali_key "$(prompt AccessKeyId)"; state_set ali_secret "$(prompt AccessKeySecret)" ;;
    5) mode=dns_acmedns
       state_set acmedns_url "$(prompt server_url)"
       state_set acmedns_user "$(prompt username)"
       state_set acmedns_pass "$(prompt password)"
       state_set acmedns_sub "$(prompt subdomain)" ;;
    *) mode=http ;;
  esac
  state_set challenge "$mode"; state_set domain "$domain"; state_set email "$email"
  if ! validate_domain "$domain"; then
    prompt_yes "仍然继续" || { state_set domain ""; state_set email ""; return 1; }
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
  json_save "$file" "$content" || { tell_warn "写入失败"; wait_key; return 1; }
  if apply_config; then
    out_ok "创建成功"; out_gap; render_share_uri "$file"
  else
    rm -f "$file"; apply_config_quiet; out_warn "已回滚，节点未创建"
  fi
  render_wait
}

create_vless_reality(){
  local name port uuid target keypair private public short_id tag body
  clear; tell "== 新建 VLESS REALITY =="
  name=$(prompt "节点名称，0 取消" reality); [ "$name" = 0 ] && return
  port=$(prompt_port t) || return
  uuid=$(prompt UUID "$(random_uuid)")
  while :; do
    target=$(prompt "握手目标域名" www.cloudflare.com)
    probe_handshake_target "$target" && break
    prompt_yes "仍然使用" && break
  done
  keypair=$("$CORE" generate reality-keypair)
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] || { tell_warn "密钥生成失败"; wait_key; return; }
  short_id=$(openssl rand -hex 4 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c8)
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
  clear; tell "== 新建 VLESS Vision + TCP + TLS =="
  setup_certificate || return
  name=$(prompt "节点名称，0 取消" vless-tls); [ "$name" = 0 ] && return
  port=$(prompt_port t) || return
  uuid=$(prompt UUID "$(random_uuid)")
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
  local name port password hopping tag body
  clear; tell "== 新建 Hysteria2 =="
  setup_certificate || return
  name=$(prompt "节点名称，0 取消" hysteria2); [ "$name" = 0 ] && return
  port=$(prompt_port u) || return
  password=$(prompt 密码 "$(random_password)")
  hopping=""
  if prompt_yes "启用端口跳跃"; then
    if hopping_node >/dev/null; then
      tell_warn "已有节点启用跳跃，仅允许一个"
    else
      while :; do
        hopping=$(prompt "跳跃范围 如 20000-30000，留空跳过")
        [ -z "$hopping" ] && break
        validate_range "$hopping" && break
      done
    fi
  fi
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" \
        --arg password "$password" --arg hopping "$hopping" '
   {tag:$tag,name:$name,kind:"hysteria2",port:$port,proto:"u",hopping:$hopping,
    tls_mode:"acme",alpn:["h3"],
    meta:{password:$password},
    inbound:{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,
      users:[{password:$password}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}
create_tuic(){
  local name port uuid password tag body
  clear; tell "== 新建 TUIC =="
  setup_certificate || return
  name=$(prompt "节点名称，0 取消" tuic); [ "$name" = 0 ] && return
  port=$(prompt_port u) || return
  uuid=$(prompt UUID "$(random_uuid)")
  password=$(prompt 密码 "$(random_password)")
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
  clear; tell "== 新建 Trojan =="
  setup_certificate || return
  name=$(prompt "节点名称，0 取消" trojan); [ "$name" = 0 ] && return
  port=$(prompt_port t) || return
  password=$(prompt 密码 "$(random_password)")
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
  local name port password tag body
  clear; tell "== 新建 AnyTLS =="
  setup_certificate || return
  name=$(prompt "节点名称，0 取消" anytls); [ "$name" = 0 ] && return
  port=$(prompt_port t) || return
  password=$(prompt 密码 "$(random_password)")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" '
   {tag:$tag,name:$name,kind:"anytls",port:$port,proto:"t",hopping:"",
    tls_mode:"acme",alpn:null,
    meta:{password:$password},
    inbound:{type:"anytls",tag:$tag,listen:"::",listen_port:$port,
      users:[{password:$password}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}
create_socks(){
  local name username password port tag body
  clear; tell "== 新建 SOCKS5 =="
  tell_warn "无加密无伪装，公网监听可能被扫描滥用"
  name=$(prompt "节点名称，0 取消" socks5); [ "$name" = 0 ] && return
  username=$(prompt 账号 user)
  password=$(prompt 密码 "$(random_password)")
  [ -n "$username" ] && [ -n "$password" ] || { tell_warn "账号密码不能为空"; wait_key; return; }
  port=$(prompt_port t) || return
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

render_share_uri(){
  local file=$1 kind name port meta hopping host uri ipv6 mode
  kind=$(jq -r .kind "$file"); name=$(jq -r .name "$file"); port=$(jq -r .port "$file")
  meta=$(jq -c .meta "$file"); hopping=$(jq -r '.hopping//""' "$file"); mode=$(jq -r .tls_mode "$file")
  if [ "$mode" = acme ]; then
    host=$(state_get domain)
    [ -n "$host" ] || { out_warn "证书域名未设置，无法生成链接"; return; }
  else
    host=$(local_ipv4)
    [ -n "$host" ] || { out_warn "未检测到本机公网 IPv4，无法生成链接"; return; }
  fi
  case $kind in
    vless-reality)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(jq -r .target <<<"$meta")&fp=chrome&pbk=$(jq -r .public_key <<<"$meta")&sid=$(jq -r .short_id <<<"$meta")&type=tcp#$(uri_encode "$name")" ;;
    vless-tls)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$host&fp=chrome&type=tcp#$(uri_encode "$name")" ;;
    hysteria2)
      uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port/?sni=$host&alpn=h3${hopping:+&mport=$hopping}#$(uri_encode "$name")" ;;
    tuic)
      uri="tuic://$(jq -r .uuid <<<"$meta"):$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni=$host#$(uri_encode "$name")" ;;
    trojan)
      uri="trojan://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?security=tls&sni=$host&type=tcp#$(uri_encode "$name")" ;;
    anytls)
      uri="anytls://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port/?sni=$host#$(uri_encode "$name")" ;;
    socks)
      uri="socks5://$(uri_encode "$(jq -r .username <<<"$meta")"):$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port#$(uri_encode "$name")" ;;
  esac
  out "$uri"
  [ -n "$hopping" ] && out "跳跃范围 $hopping"
  if [ "$mode" != acme ]; then
    ipv6=$(local_ipv6)
    [ -n "$ipv6" ] && out "${uri/@$host:/@[$ipv6]:}"
  fi
}

list_nodes(){
  local file index=0 proto
  NODE_FILES=()
  for file in "$NODE_DIR"/*.json; do
    index=$((index+1)); NODE_FILES+=("$file")
    [ "$(jq -r .proto "$file")" = u ] && proto=udp || proto=tcp
    tell "$(printf '%2d) %-16s %-14s %s/%s' "$index" "$(jq -r .name "$file")" \
      "$(jq -r .kind "$file")" "$(jq -r .port "$file")" "$proto")"
  done
  [ "$index" = 0 ] && tell " 暂无节点"
  return 0
}
select_node(){
  local index
  list_nodes; tell " 0) 返回主菜单"
  [ ${#NODE_FILES[@]} = 0 ] && { wait_key; return 1; }
  index=$(prompt 序号)
  [ -z "$index" ] && return 1
  [ "$index" = 0 ] && { back_to_main; return 1; }
  [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#NODE_FILES[@]} ] \
    || { tell_warn "序号无效"; wait_key; return 1; }
  PICKED=${NODE_FILES[$((index-1))]}
  return 0
}

menu_create_protocol(){
  clear
  tell "== 创建协议 =="
  tell " 1) VLESS  REALITY"
  tell " 2) VLESS  Vision + TCP + TLS"
  tell " 3) Hysteria2"
  tell " 4) TUIC"
  tell " 5) Trojan"
  tell " 6) AnyTLS"
  tell " 7) SOCKS5"
  tell " 0) 返回主菜单"
  case $(prompt 选择) in
    1) create_vless_reality ;;
    2) create_vless_tls ;;
    3) create_hysteria2 ;;
    4) create_tuic ;;
    5) create_trojan ;;
    6) create_anytls ;;
    7) create_socks ;;
    0) back_to_main ;;
  esac
}
menu_delete_protocol(){
  clear; tell "== 删除协议 =="
  select_node || return
  prompt_yes "删除 $(jq -r .name "$PICKED")" || return
  rm -f "$PICKED"
  apply_config && out_ok "已删除"
  render_wait
}
menu_modify_protocol(){
  local kind value other
  clear; tell "== 修改配置 =="
  select_node || return
  kind=$(jq -r .kind "$PICKED")
  clear
  tell "== $(jq -r .name "$PICKED")  [$kind] =="
  tell " 1) 名称"
  tell " 2) 端口"
  case $kind in
    vless-reality|vless-tls) tell " 3) UUID" ;;
    socks) tell " 3) 密码"; tell " 4) 账号" ;;
    *) tell " 3) 密码" ;;
  esac
  [ "$kind" = vless-reality ] && tell " 5) 握手目标域名"
  [ "$kind" = hysteria2 ] && tell " 6) 端口跳跃"
  tell " 0) 返回主菜单"
  case $(prompt 选择) in
    1)
      value=$(prompt "新名称"); [ -n "$value" ] || return
      json_edit "$PICKED" '.name=$v' --arg v "$value" || { tell_warn 失败; wait_key; return; } ;;
    2)
      value=$(prompt "新端口")
      validate_port "$value" "$(jq -r .proto "$PICKED")" "$(jq -r .port "$PICKED")" || { wait_key; return; }
      json_edit "$PICKED" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" \
        || { tell_warn 失败; wait_key; return; } ;;
    3)
      if [ "$kind" = vless-reality ] || [ "$kind" = vless-tls ]; then
        value=$(prompt "新 UUID" "$(random_uuid)")
        json_edit "$PICKED" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value"
      else
        value=$(prompt "新密码" "$(random_password)")
        json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value"
      fi || { tell_warn 失败; wait_key; return; } ;;
    4)
      [ "$kind" = socks ] || return
      value=$(prompt "新账号"); [ -n "$value" ] || return
      json_edit "$PICKED" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value" \
        || { tell_warn 失败; wait_key; return; } ;;
    5)
      [ "$kind" = vless-reality ] || return
      while :; do
        value=$(prompt "新握手目标域名，留空取消"); [ -n "$value" ] || return
        probe_handshake_target "$value" && break
        prompt_yes "仍然使用" && break
      done
      json_edit "$PICKED" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v' \
        --arg v "$value" || { tell_warn 失败; wait_key; return; } ;;
    6)
      [ "$kind" = hysteria2 ] || return
      value=$(prompt "跳跃范围，留空关闭")
      if [ -n "$value" ]; then
        validate_range "$value" || { wait_key; return; }
        other=$(hopping_node) && [ "$other" != "$PICKED" ] && { tell_warn "已有节点启用跳跃"; wait_key; return; }
      fi
      json_edit "$PICKED" '.hopping=$v' --arg v "$value" || { tell_warn 失败; wait_key; return; } ;;
    0) back_to_main; return ;;
    *) return ;;
  esac
  if apply_config; then
    out_ok "已生效"; out_gap; render_share_uri "$PICKED"
  fi
  render_wait
}

render_certificate_status(){
  local domain crt expiry days
  domain=$(state_get domain); [ -n "$domain" ] || return 0
  out_gap
  out "证书域名 $domain    验证方式 $(state_get challenge)    邮箱 $(state_get email)"
  crt=$(find "$ACME_DIR" -type f -name "$domain.crt" 2>/dev/null | head -1)
  [ -n "$crt" ] || crt=$(find "$ACME_DIR" -type f -name '*.crt' 2>/dev/null | head -1)
  [ -n "$crt" ] || { out "证书状态 尚未签发"; return 0; }
  expiry=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
  [ -n "$expiry" ] || { out "证书状态 无法读取"; return 0; }
  days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  out "到期时间 $expiry    剩余 ${days} 天"
  systemctl is-active --quiet sing-box || out_warn "服务未运行，自动续期不会执行"
}
menu_server_info(){
  local file port proto status count=0 tcp_list udp_list
  tcp_list=$(listening_ports t); udp_list=$(listening_ports u)
  out "== 服务端信息 =="
  systemctl is-active --quiet sing-box && out_ok "sing-box 运行中" || out_warn "sing-box 未运行"
  out "当前出口 $(exit_label)"
  for file in "$NODE_DIR"/*.json; do
    count=$((count+1))
    port=$(jq -r .port "$file"); proto=$(jq -r .proto "$file")
    if [ "$proto" = u ]; then
      grep -qx "$port" <<<"$udp_list" && status="监听正常" || status="未在监听"
    else
      grep -qx "$port" <<<"$tcp_list" && status="监听正常" || status="未在监听"
    fi
    out_gap
    out "── $(jq -r .name "$file")  [$(jq -r .kind "$file")]  端口 $port  $status"
    render_share_uri "$file"
  done
  [ "$count" = 0 ] && out " 暂无节点"
  render_certificate_status
  render_wait
}
menu_change_domain(){
  local new_domain old_domain old_email old_challenge file count=0
  clear; tell "== 更换域名 =="
  old_domain=$(state_get domain); old_email=$(state_get email); old_challenge=$(state_get challenge)
  tell "当前证书域名 ${old_domain:-未设置}"
  tell "使用该域名的协议:"
  for file in "$NODE_DIR"/*.json; do
    if [ "$(jq -r .tls_mode "$file")" = acme ]; then
      tell "  - $(jq -r .name "$file")  [$(jq -r .kind "$file")]"
      count=$((count+1))
    fi
  done
  [ "$count" = 0 ] && tell "  无"
  new_domain=$(prompt "新域名，留空取消"); [ -n "$new_domain" ] || return
  validate_domain "$new_domain" || prompt_yes "仍然继续" || return
  if prompt_yes "同时重新配置验证方式"; then
    state_set domain ""; state_set email ""
    if ! setup_certificate "$new_domain"; then
      state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"
      return
    fi
  else
    state_set domain "$new_domain"
  fi
  if apply_config; then
    render; menu_server_info
  else
    out_warn "更换失败，已还原为 ${old_domain:-未设置}"
    state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"
    apply_config_quiet; render_wait
  fi
}
menu_server(){
  while :; do
    [ "$RETURN_MAIN" = 1 ] && return
    clear
    tell "== 服务端管理 =="
    tell " 1) 创建协议"
    tell " 2) 删除协议"
    tell " 3) 修改配置"
    tell " 4) 服务端信息"
    tell " 5) 更换域名"
    tell " 6) 重启服务"
    tell " 7) 停止服务"
    tell " 0) 返回主菜单"
    case $(prompt 选择) in
      1) menu_create_protocol ;;
      2) menu_delete_protocol ;;
      3) menu_modify_protocol ;;
      4) menu_server_info ;;
      5) menu_change_domain ;;
      6) if systemctl restart sing-box; then sync_bypass_rules; sync_hopping_rules; tell_ok 已重启
         else tell_warn 重启失败; fi; wait_key ;;
      7) systemctl stop sing-box && tell_ok 已停止 || tell_warn 停止失败; wait_key ;;
      0) return ;;
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
  [[ $URI_PORT =~ ^[0-9]+$ ]] || URI_PORT=443
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
  local username password congestion alpn obfs hop_range flow
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
          '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp},
                 reality:{enabled:true,public_key:$pbk,short_id:$sid}}' <<<"$outbound")
      elif [ "$security" = tls ] || [ "$security" = xtls ]; then
        outbound=$(jq --arg sni "$sni" --arg fp "$fingerprint" \
          '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp}}' <<<"$outbound")
      fi
      case $network in
        ws) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" \
              '.transport=({type:"ws",path:$path}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound") ;;
        grpc) outbound=$(jq --arg svc "$service" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
        httpupgrade) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" \
              '.transport={type:"httpupgrade",path:$path,host:$host}' <<<"$outbound") ;;
      esac ;;
    hysteria2|hy2)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" \
        '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      obfs=$(query_value obfs-password)
      [ -n "$obfs" ] && outbound=$(jq --arg pw "$obfs" '.obfs={type:"salamander",password:$pw}' <<<"$outbound")
      hop_range=$(query_value mport); [ -z "$hop_range" ] && hop_range=$(query_value ports)
      [ -n "$hop_range" ] && outbound=$(jq --arg r "${hop_range//-/:}" \
        '.server_ports=[$r]|del(.server_port)|.hop_interval="30s"' <<<"$outbound") ;;
    tuic)
      username=${URI_USERINFO%%:*}; password=${URI_USERINFO#*:}
      [ "$password" = "$URI_USERINFO" ] && password=""
      congestion=$(query_value congestion_control); [ -n "$congestion" ] || congestion=bbr
      alpn=$(query_value alpn); [ -n "$alpn" ] || alpn=h3
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg uuid "$username" --arg password "$password" --arg cc "$congestion" \
                       --arg sni "$sni" --arg alpn "$alpn" \
        '{type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$password,
          congestion_control:$cc,udp_relay_mode:"native",
          tls:{enabled:true,server_name:$sni,alpn:($alpn|split(","))}}') ;;
    trojan)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" \
        '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni}}')
      if [ "$(query_value type)" = ws ]; then
        outbound=$(jq --arg path "$(query_value path)" --arg host "$(query_value host)" \
          '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}
                       +(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound")
      fi ;;
    anytls)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" \
        '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni}}') ;;
    socks5|socks)
      username=${URI_USERINFO%%:*}; password=${URI_USERINFO#*:}
      [ "$password" = "$URI_USERINFO" ] && password=""
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg user "$username" --arg pass "$password" \
        '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}
         |(if $user!="" then .username=$user else . end)
         |(if $pass!="" then .password=$pass else . end)') ;;
    *) return 1 ;;
  esac
  if [ "$insecure" = 1 ] || [ "$insecure" = true ]; then
    outbound=$(jq 'if .tls then .tls.insecure=true else . end' <<<"$outbound")
  fi
  printf '%s' "$outbound"
}

peer_add(){
  local name uri tag outbound probe ipv4 ipv6 domain port
  clear; tell "== 添加节点 =="
  name=$(prompt "节点名称，留空取消"); [ -n "$name" ] || return
  uri=$(prompt "节点链接"); [ -n "$uri" ] || return
  parse_uri "$uri"
  ipv4=$(local_ipv4); ipv6=$(local_ipv6); domain=$(state_get domain)
  for port in $(node_ports); do
    if [ "$URI_PORT" = "$port" ] && { { [ -n "$ipv4" ] && [ "$URI_HOST" = "$ipv4" ]; } \
       || { [ -n "$ipv6" ] && [ "$URI_HOST" = "$ipv6" ]; } \
       || { [ -n "$domain" ] && [ "$URI_HOST" = "$domain" ]; }; }; then
      tell_warn "不能将本机自身的节点添加为出口，会形成环路"; wait_key; return
    fi
  done
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag") || { tell_warn "无法识别协议 $URI_SCHEME"; wait_key; return; }
  probe=$(mktemp)
  jq -n --argjson ob "$outbound" \
    '{log:{level:"error"},
      dns:{servers:[{type:"local",tag:"probe-dns"}]},
      outbounds:[$ob,{type:"direct",tag:"direct"}],
      route:{final:"direct",default_domain_resolver:{server:"probe-dns"}}}' >"$probe"
  if "$CORE" check -c "$probe" >/dev/null 2>&1; then
    json_save "$PEER_DIR/$tag.json" \
      "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" \
         '{tag:$tag,name:$name,uri:$uri,outbound:$ob}')"
    tell_ok "已保存 $name"
  else
    tell_warn "链接校验失败，未保存"
    "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2
  fi
  rm -f "$probe"; wait_key
}
list_peers(){
  local file index=0 current mark
  current=$(state_get exit); PEER_FILES=()
  for file in "$PEER_DIR"/*.json; do
    index=$((index+1)); PEER_FILES+=("$file")
    [ "$(jq -r .tag "$file")" = "$current" ] && mark="<= 使用中" || mark=""
    tell "$(printf '%2d) %-20s %-10s %s' "$index" "$(jq -r .name "$file")" \
      "$(jq -r .outbound.type "$file")" "$mark")"
  done
  [ "$index" = 0 ] && tell " 暂无节点"
}
select_peer(){
  local index
  list_peers; tell " 0) 返回主菜单"
  [ ${#PEER_FILES[@]} = 0 ] && { wait_key; return 1; }
  index=$(prompt 序号)
  [ -z "$index" ] && return 1
  [ "$index" = 0 ] && { back_to_main; return 1; }
  [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#PEER_FILES[@]} ] \
    || { tell_warn "序号无效"; wait_key; return 1; }
  PICKED=${PEER_FILES[$((index-1))]}
  return 0
}
wg_client_active(){
  [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] \
    && [ "$(jq -r .role "$WG_CONF")" = client ]
}
peer_select(){
  local tag previous
  clear; tell "== 节点选择 =="
  select_peer || return
  tag=$(jq -r .tag "$PICKED"); previous=$(state_get exit)
  if wg_client_active; then
    prompt_yes "WireGuard 隧道正在作为出口，切换将断开它" || return
    json_edit "$WG_CONF" '.enabled=false'
  fi
  arm_watchdog; state_set exit "$tag"
  if apply_config; then
    out_ok "已启用出口 $(jq -r .name "$PICKED")"
  else
    state_set exit "$previous"; apply_config_quiet; out_warn "已回滚"
  fi
  render_wait
}
peer_delete(){
  clear; tell "== 删除节点 =="
  select_peer || return
  [ "$(jq -r .tag "$PICKED")" = "$(state_get exit)" ] && state_set exit direct
  rm -f "$PICKED"
  apply_config && out_ok "已删除"
  render_wait
}
peer_stop(){
  clear
  state_set exit direct
  apply_config && out_ok "已停止代理，出站恢复直连"
  render_wait
}
exit_label(){
  local selected; selected=$(state_get exit)
  case $selected in
    direct) echo "直连" ;;
    wireguard) echo "WireGuard 隧道" ;;
    *) [ -f "$PEER_DIR/$selected.json" ] && jq -r .name "$PEER_DIR/$selected.json" || echo "$selected 缺失" ;;
  esac
}

stun_probe(){
  local host=$1 port=$2 packet attr_type attr_len attr_value index mapped_port mapped_ip byte octet
  local magic=2112a442
  exec 3<>"/dev/udp/$host/$port" 2>/dev/null || return 1
  printf '\x00\x01\x00\x00\x21\x12\xa4\x42\x53\x42\x4d\x50\x52\x4f\x42\x45\x30\x30\x31\x32' >&3
  packet=$(timeout 3 dd bs=2048 count=1 <&3 2>/dev/null | od -An -tx1 | tr -d ' \n')
  exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
  [ ${#packet} -ge 40 ] || return 1
  [ "${packet:0:4}" = 0101 ] || return 1
  index=40
  while [ $((index+8)) -le ${#packet} ]; do
    attr_type=${packet:$index:4}
    attr_len=$((16#${packet:$((index+4)):4}))
    attr_value=${packet:$((index+8)):$((attr_len*2))}
    if [ "$attr_type" = 0020 ] && [ "${attr_value:2:2}" = 01 ] && [ ${#attr_value} -ge 16 ]; then
      mapped_port=$(( 16#${attr_value:4:4} ^ 0x2112 ))
      mapped_ip=""
      for byte in 0 1 2 3; do
        octet=$(( 16#${attr_value:$((8+byte*2)):2} ^ 16#${magic:$((byte*2)):2} ))
        mapped_ip="$mapped_ip${mapped_ip:+.}$octet"
      done
      printf '%s:%s' "$mapped_ip" "$mapped_port"; return 0
    fi
    index=$(( index + 8 + attr_len*2 + ((4 - attr_len%4) % 4)*2 ))
  done
  return 1
}
menu_client_status(){
  local trace4 trace6 server result
  out "== 客户端状态 =="
  if [ "$(state_get exit)" = direct ]; then
    out "代理方式 直连"
  else
    out "代理方式 TUN 全局透明代理 -> $(exit_label)"
  fi
  trace4=$(curl -s4 --connect-timeout 4 -m 8 "$TRACE_URL" 2>/dev/null)
  trace6=$(curl -s6 --connect-timeout 4 -m 8 "$TRACE_URL" 2>/dev/null)
  if [ -n "$trace4" ]; then
    out "IPv4 出口 $(sed -n 's/^ip=//p' <<<"$trace4")    国家 $(sed -n 's/^loc=//p' <<<"$trace4")"
    out "TCP      可用"
  else
    out "IPv4 出口 不可用"
    out_warn "TCP 不可用"
  fi
  if [ -n "$trace6" ]; then
    out "IPv6 出口 $(sed -n 's/^ip=//p' <<<"$trace6")    国家 $(sed -n 's/^loc=//p' <<<"$trace6")"
  else
    out "IPv6 出口 无"
  fi
  for server in stun.l.google.com:19302 stun.cloudflare.com:3478 stun1.l.google.com:19302; do
    result=$(stun_probe "${server%%:*}" "${server##*:}") && {
      out "UDP      可用    出口 ${result%%:*}"; render_wait; return; }
  done
  out_warn "UDP 不可用"
  render_wait
}
menu_client(){
  while :; do
    [ "$RETURN_MAIN" = 1 ] && return
    clear
    tell "== 客户端管理 =="
    tell "当前出口 $(exit_label)"
    tell " 1) 添加节点"
    tell " 2) 节点选择"
    tell " 3) 删除节点"
    tell " 4) 停止代理"
    tell " 5) 客户端状态"
    tell " 0) 返回主菜单"
    case $(prompt 选择) in
      1) peer_add ;;
      2) peer_select ;;
      3) peer_delete ;;
      4) peer_stop ;;
      5) menu_client_status ;;
      0) return ;;
    esac
  done
}

wg_tunnel_state(){
  local peer_ip=$1 received
  [ -d "/sys/class/net/$WG_IF" ] || { echo down; return; }
  if command -v ping >/dev/null 2>&1 && ping -c1 -W3 "$peer_ip" >/dev/null 2>&1; then echo up; return; fi
  received=$(cat "/sys/class/net/$WG_IF/statistics/rx_bytes" 2>/dev/null || echo 0)
  [ "$received" -gt 0 ] && echo up || echo down
}
render_wg_info(){
  local file=$1 role
  role=$(jq -r .role "$file")
  out "== WireGuard 隧道信息 =="
  if [ "$role" = server ]; then
    out "本机角色 出口端，被动监听"
  else
    out "本机角色 接入端，出站经隧道送至出口端"
  fi
  out "隧道状态 $([ "$(jq -r .enabled "$file")" = true ] && echo 已启用 || echo 未启用)"
  out_gap
  out "本机公钥     $(jq -r .public_key "$file")"
  out "本机隧道地址 $(jq -r '.address|join(", ")' "$file")"
  [ "$role" = server ] && out "监听端口     $(jq -r .listen_port "$file")"
  [ "$role" = client ] && out "对端地址     $(jq -r .peer_host "$file"):$(jq -r .peer_port "$file")"
  out "对端公钥     $(jq -r '.peer_public_key|if .=="" then "待填写" else . end' "$file")"
  out "对端隧道 IP  $(jq -r .peer_ip "$file")"
  out "MTU          1408"
  if [ "$role" = client ]; then
    if [ "$(jq -r .enabled "$file")" = true ]; then
      if [ "$(wg_tunnel_state "$(jq -r .peer_ip "$file")")" = up ]; then
        out_ok "已建立通道连接"
      else
        out_warn "通道未建立，请核对双方公钥、地址与端口"
      fi
    fi
  else
    out_gap
    out "在接入端填入:"
    out "  出口端地址   $(local_ipv4):$(jq -r .listen_port "$file")"
    out "  出口端公钥   $(jq -r .public_key "$file")"
    out "  隧道网段前缀 $(jq -r '.address[0]' "$file" | cut -d. -f1-3)"
  fi
}
wg_setup(){
  local role keypair private public prefix address4 address6 peer_ip4 peer_ip6
  local listen_port peer_host peer_port peer_key body
  clear
  tell "== 初始化 WireGuard =="
  tell " 1) 出口端    本机被动监听，流量在本机出网"
  tell " 2) 接入端    本机出站经隧道送至出口端"
  tell " 0) 返回主菜单"
  case $(prompt "本机角色") in
    1) role=server ;;
    2) role=client ;;
    0) back_to_main; return ;;
    *) return ;;
  esac
  keypair=$("$CORE" generate wg-keypair)
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] || { tell_warn "密钥生成失败"; wait_key; return; }
  while :; do
    prefix=$(prompt "隧道网段前缀" 10.7.0)
    [[ $prefix =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    tell_warn "格式应为 10.7.0"
  done
  if [ "$role" = server ]; then
    address4="$prefix.1/24"; address6="fd00:7::1/64"
    peer_ip4="$prefix.2"; peer_ip6="fd00:7::2"
    while :; do
      listen_port=$(prompt "监听端口，0 取消" "$(random_port)")
      [ "$listen_port" = 0 ] && return
      validate_port "$listen_port" u && break
    done
    peer_key=$(prompt "接入端公钥，可留空稍后回填")
    body=$(jq -n --arg private "$private" --arg public "$public" --arg a4 "$address4" --arg a6 "$address6" \
          --argjson port "$listen_port" --arg peer_key "$peer_key" \
          --arg peer4 "$peer_ip4" --arg peer6 "$peer_ip6" --arg iface "$WG_IF" '
     {role:"server",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:$port,
      peer_public_key:$peer_key,peer_ip:$peer4,peer_host:"",peer_port:0,
      endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1408,
        address:[$a4,$a6],private_key:$private,listen_port:$port,
        peers:[{public_key:$peer_key,allowed_ips:[($peer4+"/32"),($peer6+"/128")]}]}}')
  else
    address4="$prefix.2/32"; address6="fd00:7::2/128"; peer_ip4="$prefix.1"
    peer_host=$(prompt "出口端公网 IP")
    peer_port=$(prompt "出口端监听端口")
    peer_key=$(prompt "出口端公钥")
    [ -n "$peer_host" ] && [ -n "$peer_port" ] && [ -n "$peer_key" ] \
      || { tell_warn "信息不完整"; wait_key; return; }
    [[ $peer_port =~ ^[0-9]+$ ]] || { tell_warn "端口无效"; wait_key; return; }
    body=$(jq -n --arg private "$private" --arg public "$public" --arg a4 "$address4" --arg a6 "$address6" \
          --arg host "$peer_host" --argjson port "$peer_port" --arg peer_key "$peer_key" \
          --arg peer4 "$peer_ip4" --arg iface "$WG_IF" '
     {role:"client",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:0,
      peer_public_key:$peer_key,peer_ip:$peer4,peer_host:$host,peer_port:$port,
      endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1408,
        address:[$a4,$a6],private_key:$private,detour:"direct",
        peers:[{address:$host,port:$port,public_key:$peer_key,
                allowed_ips:["0.0.0.0/0","::/0"],persistent_keepalive_interval:25}]}}')
  fi
  json_save "$WG_CONF" "$body" || { tell_warn "写入失败"; wait_key; return; }
  render_wg_info "$WG_CONF"; render_wait
}
wg_fill_peer_key(){
  local key
  clear; tell "== 回填对端公钥 =="
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化"; wait_key; return; }
  key=$(prompt "对端公钥" "$(jq -r .peer_public_key "$WG_CONF")")
  [ -n "$key" ] || return
  json_edit "$WG_CONF" '.peer_public_key=$k|.endpoint.peers[0].public_key=$k' --arg k "$key" \
    || { tell_warn "回填失败"; wait_key; return; }
  if [ "$(jq -r .enabled "$WG_CONF")" = true ]; then
    apply_config && out_ok "已回填并生效"
  else
    out_ok "已回填"
  fi
  render_wait
}
wg_toggle(){
  local role previous
  clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化"; wait_key; return; }
  role=$(jq -r .role "$WG_CONF"); previous=$(state_get exit)
  if [ "$(jq -r .enabled "$WG_CONF")" = true ]; then
    json_edit "$WG_CONF" '.enabled=false'
    [ "$previous" = wireguard ] && state_set exit direct
    apply_config && out_ok "已关闭隧道"
  else
    [ -n "$(jq -r .peer_public_key "$WG_CONF")" ] || { tell_warn "请先回填对端公钥"; wait_key; return; }
    if [ "$role" = client ] && [ "$previous" != direct ]; then
      prompt_yes "客户端节点正在作为出口，切换到 WireGuard 会断开它" || return
    fi
    json_edit "$WG_CONF" '.enabled=true'
    if [ "$role" = client ]; then arm_watchdog; state_set exit wireguard; fi
    if apply_config; then
      render; sleep 3; render_wg_info "$WG_CONF"
    else
      json_edit "$WG_CONF" '.enabled=false'; state_set exit "$previous"
      apply_config_quiet; out_warn "已回滚"
    fi
  fi
  render_wait
}
menu_wireguard(){
  local role_label tunnel_label
  while :; do
    [ "$RETURN_MAIN" = 1 ] && return
    clear
    tell "== WireGuard 管理 =="
    if [ -f "$WG_CONF" ]; then
      [ "$(jq -r .role "$WG_CONF")" = server ] && role_label=出口端 || role_label=接入端
      [ "$(jq -r .enabled "$WG_CONF")" = true ] && tunnel_label=已启用 || tunnel_label=未启用
      tell "角色 $role_label    隧道 $tunnel_label"
    else
      tell "尚未初始化"
    fi
    tell " 1) 初始化或重建本机配置"
    tell " 2) 回填对端公钥"
    tell " 3) 启用或关闭隧道"
    tell " 4) 查看密钥与隧道信息"
    tell " 5) 删除配置"
    tell " 0) 返回主菜单"
    case $(prompt 选择) in
      1) wg_setup ;;
      2) wg_fill_peer_key ;;
      3) wg_toggle ;;
      4) clear
         if [ -f "$WG_CONF" ]; then render_wg_info "$WG_CONF"; render_wait
         else tell_warn "尚未初始化"; wait_key; fi ;;
      5) clear
         if prompt_yes "删除 WireGuard 配置"; then
           rm -f "$WG_CONF"
           [ "$(state_get exit)" = wireguard ] && state_set exit direct
           apply_config && out_ok "已删除"
           render_wait
         fi ;;
      0) return ;;
    esac
  done
}

render_system_info(){
  local ipv6
  ipv6=$(local_ipv6)
  out "== 状态与更新 =="
  out "系统     $(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)"
  out "内核     $(uname -r)"
  out "架构     $(uname -m)"
  out "CPU      $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')  x$(nproc)"
  out "内存     $(awk '/MemTotal/{total=$2}/MemAvailable/{avail=$2}END{printf "%d / %d MB",(total-avail)/1024,total/1024}' /proc/meminfo)"
  out "sing-box $(core_version)   $(state_get asset)"
  out "本机地址 $(local_ipv4)${ipv6:+   $ipv6}"
  systemctl is-active --quiet sing-box && out "服务     运行中" || out "服务     已停止"
}
run_update(){
  local current latest
  clear
  current=$(core_version); latest=$(remote_version)
  tell "当前版本 $current"
  tell "最新版本 ${latest:-获取失败}"
  [ -n "$latest" ] || { wait_key; return; }
  [ "$current" = "$latest" ] && { tell_ok "已是最新版本"; wait_key; return; }
  prompt_yes "更新到 $latest" || return
  install_core && apply_config && out_ok "更新完成"
  render_wait
}
run_uninstall(){
  local packages guard=0
  clear
  tell_warn "将删除脚本安装的全部内容，恢复到安装前状态"
  [ "$(prompt '输入 yes 确认')" = yes ] || return
  mapfile -t packages < <(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null)
  systemctl disable --now sing-box 2>/dev/null
  systemctl stop sbm-watchdog.timer sbm-watchdog.service 2>/dev/null
  systemctl reset-failed 'sbm-watchdog*' 2>/dev/null
  rm -f "$SERVICE_UNIT" "$DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null
  systemctl daemon-reload
  clear_hopping_rules
  while ip rule del pref "$BYPASS_PREF" 2>/dev/null; do guard=$((guard+1)); [ "$guard" -gt 64 ] && break; done
  guard=0
  while ip -6 rule del pref "$BYPASS_PREF" 2>/dev/null; do guard=$((guard+1)); [ "$guard" -gt 64 ] && break; done
  ip link del "$WG_IF" 2>/dev/null
  ip link del "$TUN_IF" 2>/dev/null
  rm -rf "$SB_DIR" "$SBM_DIR" /var/lib/sing-box "$CORE" "$SHORTCUT"
  if [ ${#packages[@]} -gt 0 ]; then
    tell "脚本安装过 ${packages[*]}"
    if prompt_yes "一并卸载"; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${packages[@]}" >/dev/null 2>&1
      apt-get autoremove -y -q >/dev/null 2>&1
    fi
  fi
  rm -f "$SELF"
  tell_ok "已完全卸载"
  exit 0
}
menu_status(){
  while :; do
    [ "$RETURN_MAIN" = 1 ] && return
    render_system_info
    out_gap
    out " 1) 检测更新"
    out " 2) 卸载"
    out " 0) 返回主菜单"
    render
    case $(prompt 选择) in
      1) run_update ;;
      2) run_uninstall ;;
      0) return ;;
    esac
  done
}

bootstrap(){
  init_dirs
  check_dependencies
  if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$SELF" ]; then install -m700 "$0" "$SELF"; fi
  [ -f "$SELF" ] && ln -sf "$SELF" "$SHORTCUT"
  if [ ! -x "$CORE" ]; then
    echo "  首次运行，正在安装 sing-box"
    install_core || exit 1
    write_service
    systemctl enable sing-box >/dev/null 2>&1
  fi
  [ -f "$SERVICE_UNIT" ] || write_service
  [ -f "$CONFIG" ] || build_config | json_write "$CONFIG"
}

case $1 in
  --sync) init_dirs; sync_bypass_rules; sync_hopping_rules; exit 0 ;;
  --clear-hopping) clear_hopping_rules; exit 0 ;;
  --watchdog) run_watchdog ;;
esac

bootstrap
while :; do
  RETURN_MAIN=0
  clear
  tell "================================"
  tell "      sing-box 管理脚本   s"
  tell "================================"
  tell " 1) 服务端管理"
  tell " 2) 客户端管理"
  tell " 3) WireGuard 管理"
  tell " 4) 状态与更新"
  tell " 0) 退出"
  case $(prompt 选择) in
    1) menu_server ;;
    2) menu_client ;;
    3) menu_wireguard ;;
    4) menu_status ;;
    0) clear; exit 0 ;;
  esac
done
