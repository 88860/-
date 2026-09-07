#!/bin/sh
export LC_ALL=C

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
PKG_LOG=$SBM_DIR/apk_installed
SELF=/root/s.sh
SHORTCUT=/usr/local/bin/s
CORE=/usr/local/bin/sing-box
SERVICE_FILE=/etc/init.d/sing-box
PROBE_URL=http://cp.cloudflare.com/generate_204
TUN_IF=sbmtun
WG_IF=sbmwg
CERT_TAG=acme-cert
BYPASS_PREF=90
HOP_TABLE=sbm_hop

NODE_COUNT=0
PEER_COUNT=0
PICKED=""
CORE_VERSION=""
CORE_TAGS=""

IP_INFO_IP=""
IP_INFO_C=""
IP_INFO_ASN=""
IP_INFO_NAME=""

[ "$(id -u)" = 0 ] || { printf '%b[×] 权限不足: 请使用 root 用户运行%b\n' "${RED}" "${PLAIN}"; exit 1; }

read_line(){
  local value
  if [ -c /dev/tty ]; then IFS= read -r value </dev/tty || value=""
  else IFS= read -r value || value=""; fi
  printf '%s' "$value"
}

prompt(){
  local msg="$1"
  local def="$2"
  if [ -n "$def" ]; then
    printf "  %b%s [%s]: %b" "${CYAN}" "$msg" "$def" "${PLAIN}" >&2
  else
    printf "  %b%s: %b" "${CYAN}" "$msg" "${PLAIN}" >&2
  fi
  local value; value=$(read_line)
  echo "${value:-$def}"
}

prompt_yes(){
  local value; value=$(prompt "$1 (y/N)" "n")
  [ "$value" = y ] || [ "$value" = Y ]
}

wait_key(){ 
  printf '\n  %b>> 按回车键继续...%b' "${CYAN}" "${PLAIN}" >&2
  read_line >/dev/null
}

tell(){ printf '  %b\n' "$*"; }
tell_ok(){ printf '  %b[√] %b%b\n' "${GREEN}" "$*" "${PLAIN}"; }
tell_warn(){ printf '  %b[×] %b%b\n' "${RED}" "$*" "${PLAIN}"; }
out(){ printf '  %b\n' "$*"; }
out_gap(){ echo ""; }
out_ok(){ printf '  %b[√] %b%b\n' "${GREEN}" "$*" "${PLAIN}"; }
out_warn(){ printf '  %b[×] %b%b\n' "${RED}" "$*" "${PLAIN}"; }

uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }
uri_decode(){
  local s="$1"
  s=$(echo "$s" | sed 's/+/ /g' | sed 's/\\/\\\\/g' | sed 's/%/\\x/g')
  printf '%b' "$s"
}
slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16; }
random_uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || (tr -dc 'a-f0-9' </dev/urandom | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'); }
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
  mkdir -p "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box /usr/local/bin
  chmod 700 "$SBM_DIR" "$ACME_DIR"
  [ -f "$STATE" ] || printf '%s\n' '{"exit":"direct","domain":"","email":"","challenge":"http","asset":""}' | json_write "$STATE"
  [ -f "$PKG_LOG" ] || : >"$PKG_LOG"
}

state_get(){ jq -r --arg k "$1" '.[$k]//""' "$STATE" 2>/dev/null; }
state_set(){ json_edit "$STATE" '.[$k]=$v' --arg k "$1" --arg v "$2"; }

ensure_command(){
  local cmd=$1 pkg=${2:-$1}
  command -v "$cmd" >/dev/null 2>&1 && return 0
  apk add --quiet --no-cache "$pkg" >/dev/null 2>&1
  command -v "$cmd" >/dev/null 2>&1 || return 1
  grep -qx "$pkg" "$PKG_LOG" 2>/dev/null || echo "$pkg" >>"$PKG_LOG"
}

check_dependencies(){
  if ! ip -V 2>/dev/null | grep -qi "iproute2"; then
    apk add --quiet --no-cache iproute2 >/dev/null 2>&1
    grep -qx "iproute2" "$PKG_LOG" 2>/dev/null || echo "iproute2" >> "$PKG_LOG"
  fi
  
  if ! ss -v 2>/dev/null | grep -qi "iproute2"; then
    apk add --quiet --no-cache iproute2-ss >/dev/null 2>&1
    grep -qx "iproute2-ss" "$PKG_LOG" 2>/dev/null || echo "iproute2-ss" >> "$PKG_LOG"
  fi
  
  if ! ping -V 2>/dev/null | grep -qi "iputils"; then
    apk add --quiet --no-cache iputils >/dev/null 2>&1
    grep -qx "iputils" "$PKG_LOG" 2>/dev/null || echo "iputils" >> "$PKG_LOG"
  fi

  local cmd missing=0
  for cmd in curl tar jq openssl nft ss ip ping; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done
  [ "$missing" = 1 ] && apk update -q >/dev/null 2>&1
  
  for cmd in curl tar jq; do
    ensure_command "$cmd" || { tell_warn "依赖组件 $cmd 安装失败"; exit 1; }
  done
  
  ensure_command openssl openssl || { tell_warn "系统缺少 openssl 组件"; exit 1; }
  ensure_command nft nftables || { tell_warn "系统缺少 nftables 组件"; exit 1; }
  
  if ! date -d "now" >/dev/null 2>&1; then
    ensure_command date coreutils || { tell_warn "系统缺少 coreutils 组件"; exit 1; }
  fi
  return 0
}

core_version(){ [ -n "$CORE_VERSION" ] || CORE_VERSION=$([ -x "$CORE" ] && "$CORE" version 2>/dev/null | awk '/version/{print $3; exit}'); printf '%s' "$CORE_VERSION"; }
core_tags(){ [ -n "$CORE_TAGS" ] || CORE_TAGS=$([ -x "$CORE" ] && "$CORE" version 2>/dev/null | sed -n 's/^Tags: //p'); printf '%s' "$CORE_TAGS"; }
has_acme_support(){ case "$(core_tags)" in *with_acme*) return 0 ;; *) return 1 ;; esac; }
use_cert_provider(){ version_ge "$(core_version)" 1.14.0; }
core_cache_reset(){ CORE_VERSION=""; CORE_TAGS=""; }

install_core(){
  printf '  %b正在从 Alpine 全球官方 CDN 源拉取 sing-box...%b\n' "${CYAN}" "${PLAIN}"
  apk add --no-cache sing-box --repository="https://dl-cdn.alpinelinux.org/alpine/edge/main" --repository="https://dl-cdn.alpinelinux.org/alpine/edge/community" >/dev/null 2>&1 || { tell_warn "原生 sing-box 安装失败，请检查容器的外网连通性或 DNS"; return 1; }
  grep -qx "sing-box" "$PKG_LOG" 2>/dev/null || echo "sing-box" >> "$PKG_LOG"
  if [ -f /usr/bin/sing-box ]; then
    ln -sf /usr/bin/sing-box /usr/local/bin/sing-box
  fi
  core_cache_reset
  state_set asset "alpine-native"
  tell_ok "sing-box 内核已安装: $(core_version) [全球 CDN 源]"
}

write_service(){
  cat >"$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box universal proxy platform"

supervisor="supervise-daemon"
command="$CORE"
command_args="-D /var/lib/sing-box -c $CONFIG run"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

respawn_delay=2
respawn_max=0

depend() {
    need net
    after firewall
}

start_post() {
    $SELF --sync >/dev/null 2>&1 || true
}

stop_post() {
    $SELF --clear-hopping >/dev/null 2>&1 || true
}
EOF
  chmod +x "$SERVICE_FILE"
  rc-update add sing-box default >/dev/null 2>&1
}

ssh_ports(){
  {
    [ -n "$SSH_CONNECTION" ] && echo "$SSH_CONNECTION" | awk '{print $4}'
    sshd -T 2>/dev/null | awk '/^port /{print $2}'
    [ -f /etc/ssh/sshd_config ] && sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config 2>/dev/null
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -e "$f" ] && sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' "$f" 2>/dev/null
    done
    ss -Hlntp 2>/dev/null | awk '/sshd/{print $4}' | sed 's/.*://'
  } | grep -E '^[1-9][0-9]*$' | sort -un
}
node_ports(){ local file; for file in "$NODE_DIR"/*.json; do [ -e "$file" ] && jq -r '.port' "$file"; done | grep -E '^[1-9][0-9]*$'; }
wg_listen_port(){ [ -f "$WG_CONF" ] && jq -r '.listen_port//0' "$WG_CONF" | grep -E '^[1-9][0-9]*$'; }
protected_ports(){ { ssh_ports; node_ports; wg_listen_port; } | grep -E '^[1-9][0-9]*$' | sort -un; }
listening_ports(){ ss -Hln"$1" 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u; }
hopping_node(){
  local file
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
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

check_tun_support() {
  if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 666 /dev/net/tun 2>/dev/null || true
  fi
  if ! [ -w /dev/net/tun ]; then
    return 1
  fi
  if ip tuntap add mode tun name sbmtest 2>/dev/null; then
    ip link del sbmtest 2>/dev/null
    return 0
  elif ip link add sbmtest type tun 2>/dev/null; then
    ip link del sbmtest 2>/dev/null
    return 0
  else
    return 1
  fi
}

acme_options(){
  local domain=$1 body
  body=$(jq -n --arg d "$domain" --arg e "$(state_get email)" --arg dir "$ACME_DIR" \
    '{domain:[$d],email:$e,data_directory:$dir}')
  use_cert_provider && body=$(echo "$body" | jq '.key_type="p256"')
  case $(state_get challenge) in
    alpn) body=$(echo "$body" | jq '.disable_http_challenge=true') ;;
    dns_cloudflare) body=$(echo "$body" | jq --arg t "$(state_get cf_token)" '.dns01_challenge={provider:"cloudflare",api_token:$t}') ;;
    *) body=$(echo "$body" | jq '.disable_tls_alpn_challenge=true') ;;
  esac
  printf '%s' "$body"
}

build_config(){
  local selected domain inbounds outbounds endpoints rules dns_block final use_tun
  local peer_host tls_extra providers strategy ipv6 node_exists
  
  selected=$(state_get exit); domain=$(state_get domain)
  final=direct; use_tun=0; endpoints='[]'; peer_host=""; providers='[]'; tls_extra='{}'
  
  ipv6=$(local_ipv6); strategy=ipv4_only; [ -n "$ipv6" ] && strategy=prefer_ipv4
  inbounds='[]'
  
  node_exists=0
  for f in "$NODE_DIR"/*.json; do
    [ -e "$f" ] && { node_exists=1; break; }
  done
  
  if [ "$node_exists" = 1 ]; then
    if [ -n "$domain" ]; then
      if use_cert_provider; then
        providers=$(jq -n --arg t "$CERT_TAG" --argjson a "$(acme_options "$domain")" '[$a+{type:"acme",tag:$t}]')
        tls_extra=$(jq -n --arg t "$CERT_TAG" '{certificate_provider:$t}')
      else
        tls_extra=$(jq -n --argjson a "$(acme_options "$domain")" '{acme:$a}')
      fi
    fi
    set -- "$NODE_DIR"/*.json
    inbounds=$(jq -s --arg d "$domain" --argjson x "$tls_extra" '
      [ .[] | .inbound as $in |
        if .tls_mode=="acme" then
          $in * {tls: ({enabled:true,server_name:$d}
                       + (if .alpn then {alpn:.alpn} else {} end)
                       + $x)}
        else $in end ]' "$@") || return 1
  fi
  
  outbounds='[{"type":"direct","tag":"direct"}]'

  if [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then
    endpoints=$(jq '[.endpoint]' "$WG_CONF")
    if [ "$(jq -r .role "$WG_CONF")" = client ]; then
      peer_host=$(jq -r '.peer_host//""' "$WG_CONF")
      outbounds=$(jq -n --argjson base "$outbounds" --arg wg "$WG_IF" '
        $base + [{"type":"direct","tag":"wg-direct","bind_interface":$wg}]')
      [ "$selected" = wireguard ] && { final="wg-direct"; use_tun=1; }
    fi
  fi
  
  if [ "$selected" != direct ] && [ "$selected" != wireguard ] && [ -f "$PEER_DIR/$selected.json" ]; then
    outbounds=$(jq -n --argjson base "$outbounds" --slurpfile peer "$PEER_DIR/$selected.json" '$base + [$peer[0].outbound]')
    final=$selected; use_tun=1
  fi
  
  if [ "$use_tun" = 1 ]; then
    if check_tun_support; then
      inbounds=$(jq -n --argjson list "$inbounds" --arg name "$TUN_IF" '
        [{type:"tun",tag:"tun-in",interface_name:$name,
          address:["172.19.0.1/30","fdfe:dcba:9876::1/126"],
          auto_route:true,strict_route:false,stack:"mixed",mtu:9000}] + $list')
    else
      use_tun=0
      printf '\n  %b[警告] 当前 LXC 容器缺失宿主 TUN 底层权限，透明代理网卡已降级关闭！%b\n' "${YELLOW}" "${PLAIN}" >&2
      printf '  %b       已切换为纯代理节点模式。如需支持 TUN 全局接管，请修改宿主机容器配置。%b\n' "${YELLOW}" "${PLAIN}" >&2
    fi
  fi
      
  rules=$(jq -n --arg host "$peer_host" '
    [{action:"sniff"},
     {protocol:"dns",action:"hijack-dns"},
     {port:53,action:"hijack-dns"}]
    + (if $host=="" then [] 
       elif ($host | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) then 
         [{ip_cidr:[($host+"/32")],action:"route",outbound:"direct"}]
       elif ($host | test("^[0-9a-fA-F:]+$")) then 
         [{ip_cidr:[($host+"/128")],action:"route",outbound:"direct"}]
       else 
         [{domain:[$host],action:"route",outbound:"direct"}] 
       end)
    + [{ip_is_private:true,action:"route",outbound:"direct"}]')
    
  dns_block=$(jq -n --arg detour "$final" --arg strategy "$strategy" '
    {servers:[{type:"local",tag:"dns-local"},
              (if $detour == "direct" then {type:"udp",tag:"dns-remote",server:"1.1.1.1"}
               else {type:"udp",tag:"dns-remote",server:"1.1.1.1",detour:$detour} end)],
     final:"dns-remote"}
    | if $detour=="direct" then . else .strategy=$strategy end')
     
  jq -n --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" \
        --argjson endpoints "$endpoints" --argjson rules "$rules" \
        --argjson dns "$dns_block" --argjson providers "$providers" \
        --arg final "$final" --arg use_tun "$use_tun" '
    {log:{level:"warn",timestamp:true},
     dns:$dns,
     inbounds:$inbounds,
     outbounds:$outbounds,
     route:{rules:$rules,final:$final,
            auto_detect_interface:(if $use_tun=="1" then true else false end),
            default_domain_resolver:"dns-local"}}
    | if ($endpoints|length)>0 then .endpoints=$endpoints else . end
    | if ($providers|length)>0 then .certificate_providers=$providers else . end'
}

apply_config(){
  local tmp error
  tmp=$(mktemp)
  build_config >"$tmp" || { rm -f "$tmp"; out_warn "配置生成失败"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; out_warn "配置写入异常"; return 1; }
  
  if ! error=$("$CORE" check -c "$tmp" 2>&1); then
    out_warn "配置校验未通过:"
    echo "$error" | head -4 | sed 's/^/    /' >&2
    rm -f "$tmp"; return 1
  fi
  install -m600 "$tmp" "$CONFIG"; rm -f "$tmp"
  rc-service sing-box restart >/dev/null 2>&1
  sleep 2
  
  if ! rc-service sing-box status >/dev/null 2>&1; then
    out_warn "服务启动异常:"
    tail -n 5 /var/log/sing-box.log 2>/dev/null | sed 's/^/    /' >&2
    return 1
  fi
  
  sync_bypass_rules
  sync_hopping_rules
  
  bypass_rules_present || out_warn "系统内核不支持 sport 路由规则，服务可能中断"
  return 0
}

apply_config_quiet(){
  apply_config >/dev/null 2>&1
}

arm_watchdog(){
  pkill -f "s.sh --watchdog" 2>/dev/null || true
  (
    sleep 30
    /bin/sh "$SELF" --watchdog
  ) </dev/null >/dev/null 2>&1 &
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
  build_config | json_write "$CONFIG" && rc-service sing-box restart
  sync_bypass_rules; sync_hopping_rules
  exit 0
}

validate_port(){
  local port=$1 proto=$2 allow=${3:-}
  if ! echo "$port" | grep -Eq '^[0-9]+$'; then tell_warn "端口格式无效"; return 1; fi
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then tell_warn "端口无效"; return 1; fi
  if [ "$port" = 80 ]; then tell_warn "端口 80 已保留给证书签发"; return 1; fi
  if [ "$port" = "$allow" ]; then return 0; fi
  if echo "$(protected_ports)" | grep -qx "$port"; then tell_warn "已被节点或 SSH 占用"; return 1; fi
  if echo "$(listening_ports "$proto")" | grep -qx "$port"; then tell_warn "端口被占用"; return 1; fi
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
  if ! echo "$range" | grep -Eq '^[0-9]+-[0-9]+$'; then tell_warn "格式应为 20000-30000"; return 1; fi
  low=${range%-*}
  high=${range#*-}
  if [ "$low" -lt 1 ] || [ "$high" -gt 65535 ] || [ "$low" -ge "$high" ]; then tell_warn "端口范围不合法"; return 1; fi
  for port in $(listening_ports u) $(protected_ports) 80 443; do
    if [ "$port" -ge "$low" ] && [ "$port" -le "$high" ]; then tell_warn "范围内包含系统保留端口: $port"; return 1; fi
  done
  return 0
}

probe_handshake_target(){
  local target=$1 result
  command -v openssl >/dev/null || { tell_warn "跳过域名验证"; return 0; }
  result=$(echo | timeout 10 openssl s_client -connect "$target:443" -servername "$target" -alpn h2 -tls1_3 2>/dev/null)
  if ! echo "$result" | grep -q "TLSv1.3"; then tell_warn "不支持 TLS 1.3 协议"; return 1; fi
  if ! echo "$result" | grep -q "ALPN protocol: h2"; then tell_warn "不支持 HTTP/2 协议"; return 1; fi
  if ! echo "$result" | grep -qi "X25519"; then tell_warn "未检测到 X25519 特性"; return 1; fi
  tell_ok "验证通过"
  return 0
}

validate_domain(){
  local domain=$1 resolved ipv4 ipv6
  resolved=$(resolve_addresses "$domain")
  [ -n "$resolved" ] || { tell_warn "无法解析该域名"; return 1; }
  ipv4=$(local_ipv4); ipv6=$(local_ipv6)
  if ! { [ -n "$ipv4" ] && echo "$resolved" | grep -qx "$ipv4"; } \
     && ! { [ -n "$ipv6" ] && echo "$resolved" | grep -qx "$ipv6"; }; then
    tell_warn "域名解析地址与本机 IP 不匹配"
    return 1
  fi
  case $(state_get challenge) in
    http) echo "$(listening_ports t)" | grep -qx 80 && { tell_warn "本机 80 端口已被占用"; return 1; } ;;
    alpn) echo "$(listening_ports t)" | grep -qx 443 && { tell_warn "本机 443 端口已被占用"; return 1; } ;;
  esac
  tell_ok "解析记录正常"
  return 0
}

setup_certificate(){
  local suggest=${1:-} domain email mode
  [ -n "$(state_get domain)" ] && [ -n "$(state_get email)" ] && return 0
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; return 1; }
  
  printf '\n  %b该协议需要绑定域名并签发证书%b\n' "${YELLOW}" "${PLAIN}"
  domain=$(prompt "输入域名" "$suggest"); [ -n "$domain" ] || return 1
  email=$(prompt "ACME 通知邮箱" "admin@$domain"); [ -n "$email" ] || return 1
  
  printf '\n  %b选择域名证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
  echo "  1. HTTP-01      (推荐，需放行 80 端口)"
  echo "  2. TLS-ALPN-01  (推荐，需放行 443 端口)"
  echo "  3. DNS-01       (Cloudflare API)"
  
  while :; do
    case $(prompt "请选择方式" 1) in
      1) mode=http; break ;;
      2) mode=alpn; break ;;
      3) mode=dns_cloudflare; state_set cf_token "$(prompt 'Cloudflare API Token')"; break ;;
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
  local file=$1 content=$2
  json_save "$file" "$content" || { tell_warn "数据写入失败"; wait_key; return 1; }
  if apply_config; then
    out_ok "协议应用成功"; out_gap; render_share_uri "$file"
  else
    rm -f "$file"; apply_config_quiet; out_warn "配置应用失败，已回滚"
  fi
  wait_key
}

create_vless_reality(){
  local name port uuid target keypair private public short_id tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "VLESS-Reality")
  port=$(prompt_port t "")
  uuid=$(prompt "通讯 UUID (留空自动生成)" "$(random_uuid)")
  while :; do
    target=$(prompt "握手目标域名" "www.microsoft.com")
    probe_handshake_target "$target" && break
    prompt_yes "是否强制使用此域名" && break
  done
  keypair=$("$CORE" generate reality-keypair)
  private=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
  public=$(echo "$keypair" | awk '/PublicKey/{print $2}')
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
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "VLESS-TLS")
  setup_certificate || return
  port=$(prompt_port t "")
  uuid=$(prompt "通讯 UUID (留空自动生成)" "$(random_uuid)")
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
  local name port password hopping tag body up_mbps down_mbps
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Hysteria2")
  setup_certificate || return
  port=$(prompt_port u "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  
  while :; do
    up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" "0")
    if echo "$up_mbps" | grep -Eq '^[0-9]+$'; then break; else tell_warn "输入无效，请重新输入数字"; fi
  done
  while :; do
    down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "0")
    if echo "$down_mbps" | grep -Eq '^[0-9]+$'; then break; else tell_warn "输入无效，请重新输入数字"; fi
  done

  hopping=""
  if prompt_yes "是否配置并开启端口跳跃防封锁机制"; then
    if hopping_node >/dev/null; then
      tell_warn "当前已有其它节点开启了跳跃规则"
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
        --argjson up "$up_mbps" --argjson down "$down_mbps" '
   {tag:$tag,name:$name,kind:"hysteria2",port:$port,proto:"u",hopping:$hopping,
    tls_mode:"acme",alpn:["h3"],
    meta:{password:$password, up_mbps:$up, down_mbps:$down},
    inbound:({type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,
      users:[{password:$password}]}
      | if $up > 0 then .up_mbps=$up else . end
      | if $down > 0 then .down_mbps=$down else . end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_tuic(){
  local name port uuid password tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "TUIC")
  setup_certificate || return
  port=$(prompt_port u "")
  uuid=$(prompt "通讯 UUID (留空自动生成)" "$(random_uuid)")
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
  local name port password tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "AnyTLS")
  setup_certificate || return
  port=$(prompt_port t "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
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

render_share_uri(){
  local file=$1 kind name port meta hopping host uri ipv6 mode
  kind=$(jq -r .kind "$file"); name=$(jq -r .name "$file"); port=$(jq -r .port "$file")
  meta=$(jq -c .meta "$file"); hopping=$(jq -r '.hopping//""' "$file"); mode=$(jq -r .tls_mode "$file")
  if [ "$mode" = acme ]; then
    host=$(state_get domain)
    [ -n "$host" ] || { out_warn "未识别到可用证书域名，生成链接失败"; return; }
  else
    host=$(local_ipv4)
    [ -n "$host" ] || { out_warn "未识别到本机公网 IPv4，生成链接失败"; return; }
  fi
  case $kind in
    vless-reality) uri="vless://$(echo "$meta" | jq -r .uuid)@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(echo "$meta" | jq -r .target)&fp=chrome&pbk=$(echo "$meta" | jq -r .public_key)&sid=$(echo "$meta" | jq -r .short_id)&type=tcp#$(uri_encode "$name")" ;;
    vless-tls) uri="vless://$(echo "$meta" | jq -r .uuid)@$host:$port?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$host&fp=chrome&type=tcp#$(uri_encode "$name")" ;;
    hysteria2) uri="hysteria2://$(uri_encode "$(echo "$meta" | jq -r .password)")@$host:$port/?sni=$host&alpn=h3${hopping:+&mport=$hopping}#$(uri_encode "$name")" ;;
    tuic) uri="tuic://$(echo "$meta" | jq -r .uuid):$(uri_encode "$(echo "$meta" | jq -r .password)")@$host:$port?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni=$host#$(uri_encode "$name")" ;;
    trojan) uri="trojan://$(uri_encode "$(echo "$meta" | jq -r .password)")@$host:$port?security=tls&sni=$host&type=tcp#$(uri_encode "$name")" ;;
    anytls) uri="anytls://$(uri_encode "$(echo "$meta" | jq -r .password)")@$host:$port/?sni=$host#$(uri_encode "$name")" ;;
    socks) uri="socks5://$(uri_encode "$(echo "$meta" | jq -r .username)"):$(uri_encode "$(echo "$meta" | jq -r .password)")@$host:$port#$(uri_encode "$name")" ;;
  esac
  out "${GREEN}$uri${PLAIN}"
  [ -n "$hopping" ] && out "跳跃配置: $hopping"
  if [ "$mode" != acme ]; then
    ipv6=$(local_ipv6)
    [ -n "$ipv6" ] && out "${GREEN}$(echo "$uri" | sed "s/@$host:/@[${ipv6}]:/")${PLAIN}"
  fi
}

list_nodes(){
  local file index=0 proto
  NODE_COUNT=0
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    index=$((index+1))
    eval "NODE_FILE_${index}=\"$file\""
    proto=$(jq -r .proto "$file")
    [ "$proto" = u ] && proto=UDP || proto=TCP
    printf '  %2d. [%-14s] 端口: %-5s | %s\n' "$index" "$(jq -r .kind "$file")" "$(jq -r .port "$file")" "$(jq -r .name "$file")"
  done
  NODE_COUNT=$index
  [ "$index" = 0 ] && tell "  系统内暂无节点"
  return 0
}

select_node(){
  local index
  list_nodes; tell "  0. 返回"
  [ "$NODE_COUNT" = 0 ] && { wait_key; return 1; }
  while :; do
    index=$(prompt "请输入序号")
    [ -z "$index" ] && return 1
    [ "$index" = 0 ] && return 1
    if echo "$index" | grep -Eq '^[0-9]+$' && [ "$index" -ge 1 ] && [ "$index" -le "$NODE_COUNT" ]; then
      break
    else
      tell_warn "序号无效，请重新输入"
    fi
  done
  eval "PICKED=\$NODE_FILE_${index}"
  return 0
}

menu_create_protocol(){
  while :; do
    clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
    tell "  1. VLESS REALITY"
    tell "  2. VLESS Vision+TCP+TLS"
    tell "  3. Hysteria2"
    tell "  4. TUIC"
    tell "  5. Trojan"
    tell "  6. AnyTLS"
    tell "  7. SOCKS5"
    tell "  0. 返回"
    tell "${CYAN}==============================${PLAIN}"
    case $(prompt "请选择") in
      1) create_vless_reality; break ;;
      2) create_vless_tls; break ;;
      3) create_hysteria2; break ;;
      4) create_tuic; break ;;
      5) create_trojan; break ;;
      6) create_anytls; break ;;
      7) create_socks; break ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

menu_delete_protocol(){
  clear; tell "${CYAN}========== 删除协议 ==========${PLAIN}"
  select_node || return
  prompt_yes "确认删除 $(jq -r .name "$PICKED")" || return
  
  local was_acme
  was_acme=$(jq -r .tls_mode "$PICKED")
  rm -f "$PICKED"
  
  if [ "$was_acme" = "acme" ]; then
    local acme_count=0
    for f in "$NODE_DIR"/*.json; do
      [ -e "$f" ] || continue
      [ "$(jq -r .tls_mode "$f")" = "acme" ] && acme_count=$((acme_count+1))
    done
    if [ "$acme_count" -eq 0 ] && [ -n "$(state_get domain)" ]; then
      out_gap
      if prompt_yes "是否连同域名和证书一起清理"; then
        state_set domain ""; state_set email ""; state_set challenge "http"
        rm -rf "$ACME_DIR"/*
        tell_ok "相关配置已清理"
      fi
    fi
  fi
  apply_config && tell_ok "已删除"; wait_key
}

menu_modify_protocol(){
  local kind value other current_hop up_mbps down_mbps
  clear; tell "${CYAN}========== 修改配置 ==========${PLAIN}"
  select_node || return
  while :; do
    kind=$(jq -r .kind "$PICKED")
    clear
    tell "${CYAN}========== $(jq -r .name "$PICKED") [$kind] ==========${PLAIN}"
    tell "  1. 识别名称"
    tell "  2. 监听端口"
    case $kind in
      vless-reality|vless-tls) tell "  3. 通讯 UUID" ;;
      socks) tell "  3. 鉴权密码"; tell "  4. 鉴权账号" ;;
      *) tell "  3. 连接密码" ;;
    esac
    [ "$kind" = vless-reality ] && tell "  5. 握手目标域名"
    [ "$kind" = hysteria2 ] && tell "  6. 端口跳跃机制"
    [ "$kind" = hysteria2 ] && tell "  7. 带宽限制"
    tell "  0. 返回"
    tell "${CYAN}==============================${PLAIN}"
    
    case $(prompt "请选择") in
      1)
        value=$(prompt "新识别名称" "$(jq -r .name "$PICKED")"); [ -n "$value" ] || continue
        json_edit "$PICKED" '.name=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      2)
        value=$(prompt_port "$(jq -r .proto "$PICKED")" "$(jq -r .port "$PICKED")") || continue
        json_edit "$PICKED" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      3)
        if [ "$kind" = vless-reality ] || [ "$kind" = vless-tls ]; then
          value=$(prompt "新通讯 UUID (留空自动生成)")
          [ -z "$value" ] && value=$(random_uuid)
          json_edit "$PICKED" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value"
        else
          value=$(prompt "新连接密码 (留空自动生成)")
          [ -z "$value" ] && value=$(random_password)
          json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value"
        fi || { tell_warn 失败; wait_key; continue; } ;;
      4)
        [ "$kind" = socks ] || { tell_warn "输入无效"; sleep 1; continue; }
        value=$(prompt "鉴权账号" "$(jq -r .meta.username "$PICKED")"); [ -n "$value" ] || continue
        json_edit "$PICKED" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      5)
        [ "$kind" = vless-reality ] || { tell_warn "输入无效"; sleep 1; continue; }
        while :; do
          value=$(prompt "新握手目标域名 (留空取消)")
          [ -n "$value" ] || break
          probe_handshake_target "$value" && break
          prompt_yes "检测异常，强制加载" && break
        done
        [ -n "$value" ] || continue
        json_edit "$PICKED" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      6)
        [ "$kind" = hysteria2 ] || { tell_warn "输入无效"; sleep 1; continue; }
        current_hop=$(jq -r '.hopping//""' "$PICKED")
        value=$(prompt "跳跃范围 (当前: ${current_hop:-未开启}, 0 关闭)")
        if [ -z "$value" ]; then tell_ok "保持不变"; wait_key; continue; fi
        if [ "$value" = "0" ]; then value=""
        else
          validate_range "$value" || { wait_key; continue; }
          other=$(hopping_node) && [ "$other" != "$PICKED" ] && { tell_warn "已有节点开启跳跃"; wait_key; continue; }
        fi
        json_edit "$PICKED" '.hopping=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      7)
        [ "$kind" = hysteria2 ] || { tell_warn "输入无效"; sleep 1; continue; }
        while :; do
          up_mbps=$(prompt "上行带宽 (Mbps, 0为关闭限制)" "$(jq -r '.meta.up_mbps//0' "$PICKED")")
          if echo "$up_mbps" | grep -Eq '^[0-9]+$'; then break; else tell_warn "输入无效，请重新输入"; fi
        done
        while :; do
          down_mbps=$(prompt "下行带宽 (Mbps, 0为关闭限制)" "$(jq -r '.meta.down_mbps//0' "$PICKED")")
          if echo "$down_mbps" | grep -Eq '^[0-9]+$'; then break; else tell_warn "输入无效，请重新输入"; fi
        done
        json_edit "$PICKED" '.meta.up_mbps=$up | .meta.down_mbps=$down |
          if $up > 0 then .inbound.up_mbps=$up else del(.inbound.up_mbps) end |
          if $down > 0 then .inbound.down_mbps=$down else del(.inbound.down_mbps) end' \
          --argjson up "$up_mbps" --argjson down "$down_mbps" || { tell_warn 失败; wait_key; continue; } ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1; continue ;;
    esac
    
    if apply_config; then tell_ok "已生效"; out_gap; render_share_uri "$PICKED"; fi
    wait_key
  done
}

render_certificate_status(){
  local domain crt expiry days
  domain=$(state_get domain); [ -n "$domain" ] || return 0
  tell ""
  tell "  全局域名: $domain | 验证: $(state_get challenge)"
  crt=$(find "$ACME_DIR" -type f -name "$domain.crt" 2>/dev/null | head -1)
  [ -n "$crt" ] || crt=$(find "$ACME_DIR" -type f -name '*.crt' 2>/dev/null | head -1)
  [ -n "$crt" ] || { tell "  ${YELLOW}证书状态: 未签发${PLAIN}"; return 0; }
  expiry=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
  [ -n "$expiry" ] || { tell "  ${RED}证书状态: 无法读取${PLAIN}"; return 0; }
  days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  tell "  到期时间: $expiry | 剩余: ${days} 天"
  rc-service sing-box status >/dev/null 2>&1 || tell_warn "服务离线，无法自动续期"
}

menu_server_info(){
  local file port proto status count=0 tcp_list udp_list
  tcp_list=$(listening_ports t); udp_list=$(listening_ports u)
  clear
  tell "${CYAN}========== 服务端信息 ==========${PLAIN}"
  rc-service sing-box status >/dev/null 2>&1 && tell_ok "singbox: 运行中 (受 supervise-daemon 保护)" || tell_warn "singbox: 未运行"
  
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    count=$((count+1))
    port=$(jq -r .port "$file"); proto=$(jq -r .proto "$file")
    if [ "$proto" = u ]; then
      if echo "$udp_list" | grep -qx "$port"; then status="${GREEN}正常监听${PLAIN}"; else status="${RED}未在监听${PLAIN}"; fi
    else
      if echo "$tcp_list" | grep -qx "$port"; then status="${GREEN}正常监听${PLAIN}"; else status="${RED}未在监听${PLAIN}"; fi
    fi
    tell ""
    tell "── $(jq -r .name "$file") [$(jq -r .kind "$file")] | 端口 $port $status"
    render_share_uri "$file"
  done
  [ "$count" = 0 ] && tell "\n  暂无搭建好的节点"
  render_certificate_status
  wait_key
}

menu_change_domain(){
  local new_domain old_domain old_email old_challenge file count=0
  clear; tell "${CYAN}========== 更换域名 ==========${PLAIN}"
  old_domain=$(state_get domain); old_email=$(state_get email); old_challenge=$(state_get challenge)
  tell "  当前域名: ${old_domain:-未设置}"
  tell "  绑定节点:"
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    if [ "$(jq -r .tls_mode "$file")" = acme ]; then
      tell "  - $(jq -r .name "$file") [$(jq -r .kind "$file")]"
      count=$((count+1))
    fi
  done
  [ "$count" = 0 ] && tell "  无"
  echo ""
  new_domain=$(prompt "新域名 (留空取消)"); [ -z "$new_domain" ] && return
  validate_domain "$new_domain" || prompt_yes "验证未通过，强制写入" || return
  
  if prompt_yes "同步重置验证机制"; then
    state_set domain ""; state_set email ""
    if ! setup_certificate "$new_domain"; then
      state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"
      return
    fi
  else
    state_set domain "$new_domain"
  fi
  
  if [ "$new_domain" != "$old_domain" ]; then rm -rf "$ACME_DIR"/*; fi
  
  if apply_config; then menu_server_info
  else
    tell_warn "部署异常已回滚"
    state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"
    apply_config_quiet; wait_key
  fi
}

menu_server(){
  while :; do
    clear
    tell "${CYAN}========== 服务端管理 ==========${PLAIN}"
    tell "  1. 创建协议"
    tell "  2. 删除协议"
    tell "  3. 修改配置"
    tell "  4. 服务端信息"
    tell "  5. 更换域名"
    tell "  6. 重启服务"
    tell "  7. 停止服务"
    tell "  0. 返回"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) menu_create_protocol ;;
      2) menu_delete_protocol ;;
      3) menu_modify_protocol ;;
      4) menu_server_info ;;
      5) menu_change_domain ;;
      6) 
         rc-service sing-box restart >/dev/null 2>&1
         if rc-service sing-box status >/dev/null 2>&1; then
           sync_bypass_rules
           sync_hopping_rules
           tell_ok "已重启"
         else
           tell_warn "singbox 未运行"
           tell_warn "重启失败"
         fi
         wait_key
         ;;
      7) if rc-service sing-box stop >/dev/null 2>&1; then tell_ok "已停止"; else tell_warn "操作异常"; fi; wait_key ;;
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
  if ! echo "$URI_PORT" | grep -Eq '^[0-9]+$'; then URI_PORT=443; fi
}

query_value(){
  local key="$1"
  local pair
  local old_ifs="$IFS"
  IFS='&'
  for pair in $URI_QUERY; do
    if [ "${pair%%=*}" = "$key" ]; then
      IFS="$old_ifs"
      uri_decode "${pair#*=}"
      return
    fi
  done
  IFS="$old_ifs"
}

uri_to_outbound(){
  local tag=$1 outbound sni fingerprint insecure security network path vhost service
  local username password congestion alpn obfs hop_range flow
  sni=$(query_value sni); [ -n "$sni" ] || sni=$(query_value peer); [ -n "$sni" ] || sni=$URI_HOST
  fingerprint=$(query_value fp); [ -n "$fingerprint" ] || fingerprint=chrome
  insecure=$(query_value insecure); [ -n "$insecure" ] || insecure=$(query_value allowInsecure)
  case $URI_SCHEME in
    vless)
      security=$(query_value security)
      network=$(query_value type)
      path=$(query_value path)
      vhost=$(query_value host)
      service=$(query_value serviceName)
      flow=$(query_value flow)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg uuid "$URI_USERINFO" \
        '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,packet_encoding:"xudp"}')
      [ -n "$flow" ] && outbound=$(echo "$outbound" | jq --arg f "$flow" '.flow=$f')
      if [ "$security" = reality ]; then
        outbound=$(echo "$outbound" | jq --arg sni "$sni" --arg fp "$fingerprint" --arg pbk "$(query_value pbk)" --arg sid "$(query_value sid)" \
          '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp},reality:{enabled:true,public_key:$pbk,short_id:$sid}}')
      elif [ "$security" = tls ] || [ "$security" = xtls ]; then
        outbound=$(echo "$outbound" | jq --arg sni "$sni" --arg fp "$fingerprint" \
          '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp}}')
      fi
      case $network in
        ws) outbound=$(echo "$outbound" | jq --arg path "${path:-/}" --arg host "$vhost" \
              '.transport=({type:"ws",path:$path}+(if $host=="" then {} else {headers:{Host:$host}} end))') ;;
        grpc) outbound=$(echo "$outbound" | jq --arg svc "$service" '.transport={type:"grpc",service_name:$svc}') ;;
        httpupgrade) outbound=$(echo "$outbound" | jq --arg path "${path:-/}" --arg host "$vhost" \
              '.transport={type:"httpupgrade",path:$path,host:$host}') ;;
      esac ;;
    hysteria2|hy2)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" \
        '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      obfs=$(query_value obfs-password)
      [ -n "$obfs" ] && outbound=$(echo "$outbound" | jq --arg pw "$obfs" '.obfs={type:"salamander",password:$pw}')
      hop_range=$(query_value mport); [ -z "$hop_range" ] && hop_range=$(query_value ports)
      if [ -n "$hop_range" ]; then
        local r=$(echo "$hop_range" | tr '-' ':')
        outbound=$(echo "$outbound" | jq --arg r "$r" '.server_ports=[$r]|del(.server_port)|.hop_interval="30s"')
      fi ;;
    tuic)
      username=${URI_USERINFO%%:*}
      password=${URI_USERINFO#*:}
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
        outbound=$(echo "$outbound" | jq --arg path "$(query_value path)" --arg host "$(query_value host)" \
          '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}
                       +(if $host=="" then {} else {headers:{Host:$host}} end))')
      fi ;;
    anytls)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" \
        '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni}}') ;;
    socks5|socks)
      username=${URI_USERINFO%%:*}
      password=${URI_USERINFO#*:}
      [ "$password" = "$URI_USERINFO" ] && password=""
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg user "$username" --arg pass "$password" \
        '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}
         |(if $user!="" then .username=$user else . end)
         |(if $pass!="" then .password=$pass else . end)') ;;
    *) return 1 ;;
  esac
  if [ "$insecure" = 1 ] || [ "$insecure" = true ]; then
    outbound=$(echo "$outbound" | jq 'if .tls then .tls.insecure=true else . end')
  fi
  printf '%s' "$outbound"
}

peer_add(){
  local name uri tag outbound probe ipv4 ipv6 domain port
  clear; tell "${CYAN}========== 添加节点 ==========${PLAIN}"
  name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return
  uri=$(prompt "节点链接"); [ -n "$uri" ] || return
  parse_uri "$uri"
  ipv4=$(local_ipv4); ipv6=$(local_ipv6); domain=$(state_get domain)
  for port in $(node_ports); do
    if [ "$URI_PORT" = "$port" ] && { { [ -n "$ipv4" ] && [ "$URI_HOST" = "$ipv4" ]; } \
       || { [ -n "$ipv6" ] && [ "$URI_HOST" = "$ipv6" ]; } \
       || { [ -n "$domain" ] && [ "$URI_HOST" = "$domain" ]; }; }; then
      tell_warn "禁止自环接入"; wait_key; return
    fi
  done
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag") || { tell_warn "无法解析"; wait_key; return; }
  probe=$(mktemp)
  jq -n --argjson ob "$outbound" \
    '{log:{level:"error"},
      dns:{servers:[{type:"local",tag:"probe-dns"}]},
      outbounds:[$ob,{type:"direct",tag:"direct"}],
      route:{final:"direct"}}' >"$probe"
  if "$CORE" check -c "$probe" >/dev/null 2>&1; then
    json_save "$PEER_DIR/$tag.json" \
      "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" \
         '{tag:$tag,name:$name,uri:$uri,outbound:$ob}')"
    tell_ok "挂载完成: $name"
  else
    tell_warn "校验拦截:"
    "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2
  fi
  rm -f "$probe"; wait_key
}

list_peers(){
  local file index=0 current mark port
  current=$(state_get exit)
  PEER_COUNT=0
  for file in "$PEER_DIR"/*.json; do
    [ -e "$file" ] || continue
    index=$((index+1))
    eval "PEER_FILE_${index}=\"$file\""
    [ "$(jq -r .tag "$file")" = "$current" ] && mark="${GREEN}<= 当前生效${PLAIN}" || mark=""
    port=$(jq -r '.outbound.server_port // .outbound.listen_port // "-"' "$file")
    printf '  %2d. [%-10s] %b | %s (端口: %s)\n' "$index" "$(jq -r .outbound.type "$file")" "$mark" "$(jq -r .name "$file")" "$port"
  done
  PEER_COUNT=$index
  [ "$index" = 0 ] && tell "  暂无外部节点"
}

select_peer(){
  local index
  list_peers; tell "  0. 返回"
  [ "$PEER_COUNT" = 0 ] && { wait_key; return 1; }
  while :; do
    index=$(prompt "请选择")
    [ -z "$index" ] && return 1
    [ "$index" = 0 ] && return 1
    if echo "$index" | grep -Eq '^[0-9]+$' && [ "$index" -ge 1 ] && [ "$index" -le "$PEER_COUNT" ]; then
      break
    else
      tell_warn "序号无效，请重新输入"
    fi
  done
  eval "PICKED=\$PEER_FILE_${index}"
  return 0
}

wg_client_active(){
  [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] \
    && [ "$(jq -r .role "$WG_CONF")" = client ]
}

peer_select(){
  local tag previous
  clear; tell "${CYAN}========== 节点选择 ==========${PLAIN}"
  select_peer || return
  tag=$(jq -r .tag "$PICKED"); previous=$(state_get exit)
  if wg_client_active; then
    prompt_yes "WireGuard 隧道运行中，是否断开" || return
    json_edit "$WG_CONF" '.enabled=false'
  fi
  arm_watchdog; state_set exit "$tag"
  if apply_config; then
    tell_ok "已接管: $(jq -r .name "$PICKED")"
  else
    state_set exit "$previous"; apply_config_quiet; tell_warn "切换失败已回滚"
  fi
  wait_key
}

peer_delete(){
  clear; tell "${CYAN}========== 删除节点 ==========${PLAIN}"
  select_peer || return
  [ "$(jq -r .tag "$PICKED")" = "$(state_get exit)" ] && state_set exit direct
  rm -f "$PICKED"
  apply_config && tell_ok "已删除"
  ip link del "$WG_IF" 2>/dev/null
  wait_key
}

peer_stop(){
  clear
  state_set exit direct
  apply_config && tell_ok "已恢复直连"
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
  ip=$(echo "$res" | jq -r '.ip // empty' 2>/dev/null)
  if [ -n "$ip" ]; then
    country=$(echo "$res" | jq -r '.country // empty' 2>/dev/null)
    asn=$(echo "$res" | jq -r '.connection.asn // empty' 2>/dev/null)
    [ -n "$asn" ] && asn="AS$asn"
    name=$(echo "$res" | jq -r '.connection.org // empty' 2>/dev/null)
    IP_INFO_IP="$ip"
    IP_INFO_C="$country"
    IP_INFO_ASN="$asn"
    IP_INFO_NAME="$name"
  else
    IP_INFO_IP=""
    IP_INFO_C=""
    IP_INFO_ASN=""
    IP_INFO_NAME=""
  fi
}

render_client_ip_status() {
  get_ip_info 4
  if [ -n "$IP_INFO_IP" ]; then
    tell "  IPv4: ${GREEN}${IP_INFO_IP}${PLAIN} | 地区: ${YELLOW}${IP_INFO_C}${PLAIN}"
    tell "  所属: ${CYAN}${IP_INFO_NAME}${PLAIN} | ASN: ${PURPLE}${IP_INFO_ASN}${PLAIN}"
  else
    tell "  IPv4: ${RED}无或不可用${PLAIN}"
  fi
  
  get_ip_info 6
  if [ -n "$IP_INFO_IP" ]; then
    tell "  IPv6: ${GREEN}${IP_INFO_IP}${PLAIN} | 地区: ${YELLOW}${IP_INFO_C}${PLAIN}"
    tell "  所属: ${CYAN}${IP_INFO_NAME}${PLAIN} | ASN: ${PURPLE}${IP_INFO_ASN}${PLAIN}"
  else
    tell "  IPv6: ${RED}无或不可用${PLAIN}"
  fi
}

menu_client_status(){
  clear
  tell "${CYAN}========== 客户端状态 ==========${PLAIN}"
  local exit_node=$(state_get exit)
  local proxy_name="直连"
  if [ "$exit_node" != "direct" ]; then
    if [ "$exit_node" = "wireguard" ]; then
      proxy_name="WireGuard"
    else
      if [ -e "$PEER_DIR/$exit_node.json" ]; then
        proxy_name=$(jq -r .outbound.type "$PEER_DIR/$exit_node.json" 2>/dev/null || echo '未知')
      else
        proxy_name='未知'
      fi
    fi
  fi
  tell "  当前出口: ${CYAN}${proxy_name}${PLAIN}"
  tell ""
  render_client_ip_status
  wait_key
}

menu_client(){
  while :; do
    clear
    tell "${CYAN}========== 客户端管理 ==========${PLAIN}"
    tell "  当前出口: ${YELLOW}$(exit_label)${PLAIN}"
    tell ""
    tell "  1. 添加节点"
    tell "  2. 节点选择"
    tell "  3. 删除节点"
    tell "  4. 停止代理"
    tell "  5. 客户端状态"
    tell "  0. 返回"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) peer_add ;;
      2) peer_select ;;
      3) peer_delete ;;
      4) peer_stop ;;
      5) menu_client_status ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
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
  tell "${CYAN}========== 隧道状态信息 ==========${PLAIN}"
  if [ "$role" = server ]; then tell "  角色: 服务端"
  else tell "  角色: 客户端"
  fi
  tell "  引擎: $([ "$(jq -r .enabled "$file")" = true ] && printf '%b运行中%b' "${GREEN}" "${PLAIN}" || printf '%b已挂起%b' "${RED}" "${PLAIN}")"
  echo ""
  tell "  本地公钥: $(jq -r .public_key "$file")"
  tell "  本地 IP:  $(jq -r '.address|join(", ")' "$file")"
  [ "$role" = server ] && tell "  监听端口: $(jq -r .listen_port "$file")"
  [ "$role" = client ] && tell "  远端地址: $(jq -r .peer_host "$file"):$(jq -r .peer_port "$file")"
  tell "  远端公钥: $(jq -r '.peer_public_key|if .=="" then "<待补录>" else . end' "$file")"
  tell "  远端 IP:  $(jq -r .peer_ip "$file")"
  
  if [ "$role" = client ]; then
    if [ "$(jq -r .enabled "$file")" = true ]; then
      if [ "$(wg_tunnel_state "$(jq -r .peer_ip "$file")")" = up ]; then tell_ok "连接成功"
      else tell_warn "连接中断"; fi
    fi
  else
    echo ""
    tell "  ${YELLOW}请在客户端填入:${PLAIN}"
    tell "  服务端: $(local_ipv4):$(jq -r .listen_port "$file")"
    tell "  公钥: $(jq -r .public_key "$file")"
    tell "  前缀: $(jq -r '.address[0]' "$file" | cut -d. -f1-3)"
  fi
}

wg_setup(){
  local role keypair private public prefix address4 address6 peer_ip4 peer_ip6
  local listen_port peer_host peer_port peer_key body
  
  while :; do
    clear
    tell "${CYAN}========= 初始化 WireGuard =========${PLAIN}"
    tell "  1. 部署为 服务端"
    tell "  2. 部署为 客户端"
    tell "  0. 返回"
    tell "${CYAN}====================================${PLAIN}"
    case $(prompt "请选择" "1") in
      1) role=server; break ;;
      2) role=client; break ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
  
  keypair=$("$CORE" generate wg-keypair)
  private=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
  public=$(echo "$keypair" | awk '/PublicKey/{print $2}')
  [ -n "$private" ] || { tell_warn "密钥生成失败"; wait_key; return; }
  
  while :; do
    prefix=$(prompt "自定义网段" "10.7.0")
    if echo "$prefix" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then break; fi
    tell_warn "格式不规范"
  done
  
  if [ "$role" = server ]; then
    address4="$prefix.1/24"; address6="fd00:7::1/64"
    peer_ip4="$prefix.2"; peer_ip6="fd00:7::2"
    while :; do
      listen_port=$(prompt_port "u" "") || return
      break
    done
    peer_key=$(prompt "客户端公钥 (留空稍后回填)")
    
    body=$(jq -n --arg private "$private" --arg public "$public" --arg a4 "$address4" --arg a6 "$address6" \
          --argjson port "$listen_port" --arg peer_key "$peer_key" \
          --arg peer4 "$peer_ip4" --arg peer6 "$peer_ip6" --arg iface "$WG_IF" '
     {role:"server",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:$port,
      peer_public_key:$peer_key,peer_ip:$peer4,peer_host:"",peer_port:0,
      endpoint:{type:"wireguard",tag:"wireguard",system:false,name:$iface,mtu:1408,
        address:[$a4,$a6],private_key:$private,listen_port:$port,
        peers:[{public_key:$peer_key,allowed_ips:[($peer4+"/32"),($peer6+"/128")]}]}}')
  else
    address4="$prefix.2/32"; address6="fd00:7::2/128"; peer_ip4="$prefix.1"
    peer_host=$(prompt "服务端 IP" "1.1.1.1")
    peer_port=$(prompt "服务端监听端口" "$(random_port)")
    peer_key=$(prompt "服务端公钥")
    
    if ! echo "$peer_port" | grep -Eq '^[0-9]+$'; then tell_warn "端口无效"; wait_key; return; fi
    
    body=$(jq -n --arg private "$private" --arg public "$public" --arg a4 "$address4" --arg a6 "$address6" \
          --arg host "$peer_host" --argjson port "$peer_port" --arg peer_key "$peer_key" \
          --arg peer4 "$peer_ip4" --arg iface "$WG_IF" '
     {role:"client",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:0,
      peer_public_key:$peer_key,peer_ip:$peer4,peer_host:$host,peer_port:$port,
      endpoint:{type:"wireguard",tag:"wireguard",system:false,name:$iface,mtu:1408,
        address:[$a4,$a6],private_key:$private,
        peers:[{address:$host,port:$port,public_key:$peer_key,
                allowed_ips:["0.0.0.0/0","::/0"],persistent_keepalive_interval:25}]}}')
  fi
  json_save "$WG_CONF" "$body" || { tell_warn "写入失败"; wait_key; return; }
  render_wg_info "$WG_CONF"; wait_key
}

wg_fill_peer_key(){
  local key role
  clear; tell "${CYAN}========== 回填对端公钥 ==========${PLAIN}"
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化"; wait_key; return; }
  key=$(prompt "对端公钥" "$(jq -r .peer_public_key "$WG_CONF")")
  [ -n "$key" ] || return
  role=$(jq -r .role "$WG_CONF")
  json_edit "$WG_CONF" '.peer_public_key=$k|.endpoint.peers[0].public_key=$k' --arg k "$key" \
    || { tell_warn "覆写失败"; wait_key; return; }
  if [ "$(jq -r .enabled "$WG_CONF")" = true ]; then
    apply_config && tell_ok "已生效"
  else
    tell_ok "已补录"
  fi
  wait_key
}

wg_toggle(){
  local role previous
  clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化"; wait_key; return; }
  role=$(jq -r .role "$WG_CONF"); previous=$(state_get exit)
  if [ "$(jq -r .enabled "$WG_CONF")" = true ]; then
    json_edit "$WG_CONF" '.enabled=false'
    [ "$previous" = wireguard ] && state_set exit direct
    apply_config && tell_ok "已关闭隧道"
  else
    [ -n "$(jq -r .peer_public_key "$WG_CONF")" ] || { tell_warn "缺少公钥"; wait_key; return; }
    if [ "$role" = client ] && [ "$previous" != direct ]; then
      prompt_yes "隧道将接管网络，确定" || return
    fi
    json_edit "$WG_CONF" '.enabled=true'
    if [ "$role" = client ]; then arm_watchdog; state_set exit wireguard; fi
    if apply_config; then
      sleep 3; render_wg_info "$WG_CONF"
    else
      json_edit "$WG_CONF" '.enabled=false'; state_set exit "$previous"
      apply_config_quiet; tell_warn "冲突拦截"
    fi
  fi
  wait_key
}

menu_wireguard(){
  local role_label tunnel_label
  while :; do
    clear
    tell "${CYAN}======== WireGuard 管理 ========${PLAIN}"
    if [ -f "$WG_CONF" ]; then
      [ "$(jq -r .role "$WG_CONF")" = server ] && role_label="服务端" || role_label="客户端"
      [ "$(jq -r .enabled "$WG_CONF")" = true ] && tunnel_label="${GREEN}运行中${PLAIN}" || tunnel_label="${RED}已挂起${PLAIN}"
      tell "  角色: ${role_label} | 隧道: ${tunnel_label}"
    else
      tell "  未配置"
    fi
    tell ""
    tell "  1. 初始化配置"
    tell "  2. 回填对端公钥"
    tell "  3. 切换运行状态"
    tell "  4. 隧道状态信息"
    tell "  5. 删除配置"
    tell "  0. 返回"
    tell "${CYAN}================================${PLAIN}"
    case $(prompt "请选择") in
      1) wg_setup ;;
      2) wg_fill_peer_key ;;
      3) wg_toggle ;;
      4) clear
         if [ -f "$WG_CONF" ]; then render_wg_info "$WG_CONF"; wait_key
         else tell_warn "数据为空"; wait_key; fi ;;
      5) clear
         if prompt_yes "确认删除配置"; then
           rm -f "$WG_CONF"
           [ "$(state_get exit)" = wireguard ] && state_set exit direct
           apply_config && tell_ok "已清除"
           ip link del "$WG_IF" 2>/dev/null
           wait_key
         fi ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

run_update(){
  clear
  tell "正在通过 Alpine 包管理器检测并更新 sing-box..."
  sed -i 's/^#//g' /etc/apk/repositories
  apk update >/dev/null 2>&1
  apk upgrade --no-cache sing-box >/dev/null 2>&1
  apply_config && tell_ok "更新流程执行完成 (包管理器已确保最新版)"
  wait_key
}

run_uninstall(){
  local packages="" guard=0
  clear
  tell_warn "警告: 卸载将清空所有配置"
  [ "$(prompt '输入 yes 确认')" = yes ] || return
  
  if [ -f "$PKG_LOG" ]; then
    packages=$(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null | tr '\n' ' ')
  fi
  
  rc-service sing-box stop 2>/dev/null
  rc-update del sing-box default 2>/dev/null
  pkill -f "$SELF --watchdog" 2>/dev/null || true
  
  rm -f "$SERVICE_FILE"
  
  clear_hopping_rules
  while ip rule del pref "$BYPASS_PREF" 2>/dev/null; do guard=$((guard+1)); [ "$guard" -gt 64 ] && break; done
  guard=0
  while ip -6 rule del pref "$BYPASS_PREF" 2>/dev/null; do guard=$((guard+1)); [ "$guard" -gt 64 ] && break; done
  ip link del "$WG_IF" 2>/dev/null
  ip link del "$TUN_IF" 2>/dev/null
  
  rm -rf "$SB_DIR" "$SBM_DIR" /var/lib/sing-box "$CORE" "$SHORTCUT"
  
  if [ -n "$packages" ]; then
    tell "脚本曾安装过: [ $packages ]"
    if prompt_yes "是否剥离依赖"; then
      apk del -q $packages >/dev/null 2>&1
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
    
    local up_seconds=$(cut -d. -f1 /proc/uptime)
    local up_days=$((up_seconds / 86400))
    local up_hours=$(( (up_seconds % 86400) / 3600 ))
    local up_mins=$(( (up_seconds % 3600) / 60 ))
    local up="${up_days}天 ${up_hours}小时 ${up_mins}分钟"
    
    local sb_ver=$(core_version)
    local sb_asset=$(state_get asset)
    local s_state="${RED}未运行${PLAIN}"
    rc-service sing-box status >/dev/null 2>&1 && s_state="${GREEN}正常运行 (守护状态生效)${PLAIN}"
    
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
  
  if [ ! -x "$CORE" ]; then
    printf '  %b首次运行，安装 sing-box...%b\n' "${CYAN}" "${PLAIN}"
    install_core || exit 1
    write_service
    rc-update add sing-box default >/dev/null 2>&1
  fi
  [ -f "$SERVICE_FILE" ] || write_service
  [ -f "$CONFIG" ] || build_config | json_write "$CONFIG"
}

case $1 in
  --sync) init_dirs; sync_bypass_rules; sync_hopping_rules; exit 0 ;;
  --clear-hopping) clear_hopping_rules; exit 0 ;;
  --watchdog) run_watchdog ;;
esac

bootstrap

while :; do
  clear
  tell "${CYAN}================================${PLAIN}"
  tell "${CYAN}            s管理               ${PLAIN}"
  tell "${CYAN}  [ lxc Alpine适配版 ]          ${PLAIN}"
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
