#!/usr/bin/env bash
export LC_ALL=C
shopt -s nullglob

RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
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

NODE_FILES=()
PEER_FILES=()
PICKED=""
CORE_VERSION=""
CORE_TAGS=""

[ "$(id -u)" = 0 ] || { echo -e "${RED}[×] 权限不足: 请使用 root 用户运行本程序${PLAIN}"; exit 1; }

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
    printf "  ${CYAN}%s [默认: %s]: ${PLAIN}" "$msg" "$def" >&2
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
out(){ echo -e "  $*"; }
out_gap(){ echo ""; }
out_ok(){ echo -e "  ${GREEN}[√] $*${PLAIN}"; }
out_warn(){ echo -e "  ${RED}[×] $*${PLAIN}"; }

uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }
uri_decode(){ local s=${1//+/ }; s=${s//\\/\\\\}; printf '%b' "${s//%/\\x}"; }
slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16; }
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
    ensure_command "$cmd" || { echo -e "${RED}[×] 依赖组件 $cmd 安装失败${PLAIN}"; exit 1; }
  done
  ensure_command ip iproute2 || { echo -e "${RED}[×] 系统缺少 iproute2 组件${PLAIN}"; exit 1; }
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
release_json(){ curl -fsSL -m 15 "$GH_API/releases/latest" 2>/dev/null; }
remote_version(){ release_json | jq -r '.tag_name//""' | sed 's/^v//'; }

local_ipv4(){ ip -4 -o addr show scope global 2>/dev/null | awk -v a="$TUN_IF" -v b="$WG_IF" '$2!=a&&$2!=b{split($4,x,"/");print x[1];exit}'; }
local_ipv6(){ ip -6 -o addr show scope global 2>/dev/null | awk -v a="$TUN_IF" -v b="$WG_IF" '$2!=a&&$2!=b{split($4,x,"/");print x[1];exit}'; }
resolve_addresses(){ getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u; }

install_core(){
  local json url asset candidate tmp found
  json=$(release_json)
  [ -n "$json" ] || { tell_warn "获取版本信息失败，请检查网络"; return 1; }
  for candidate in $(asset_candidates); do
    url=$(jq -r --arg s "$candidate.tar.gz" '.assets[]?|select(.name|endswith($s))|.browser_download_url' <<<"$json" | head -1)
    [ -n "$url" ] && { asset=$candidate; break; }
  done
  [ -n "$url" ] || { tell_warn "未找到匹配 $(uname -m) 架构的安装包"; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL -m 240 "$url" -o "$tmp/core.tar.gz" || { rm -rf "$tmp"; tell_warn "安装包下载失败"; return 1; }
  tar -xzf "$tmp/core.tar.gz" -C "$tmp" || { rm -rf "$tmp"; tell_warn "安装包解压失败"; return 1; }
  found=$(find "$tmp" -type f -name sing-box | head -1)
  [ -n "$found" ] || { rm -rf "$tmp"; tell_warn "解压结果中未找到二进制文件"; return 1; }
  rm -f "$CORE"; install -m755 "$found" "$CORE"; rm -rf "$tmp"
  core_cache_reset
  state_set asset "$asset"
  tell_ok "sing-box 内核安装成功: $(core_version) [$asset]"
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
  build_config >"$tmp" 2>/dev/null || { rm -f "$tmp"; out_warn "配置文件生成失败"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; out_warn "配置写入异常"; return 1; }
  if ! error=$("$CORE" check -c "$tmp" 2>&1); then
    out_warn "配置校验未通过:"
    while IFS= read -r line; do out "    $line"; done <<<"$(head -4 <<<"$error")"
    rm -f "$tmp"; return 1
  fi
  install -m600 "$tmp" "$CONFIG"; rm -f "$tmp"
  systemctl restart sing-box 2>/dev/null
  sleep 2
  if ! systemctl is-active --quiet sing-box; then
    out_warn "服务启动异常:"
    while IFS= read -r line; do out "    $line"; done <<<"$(journalctl -u sing-box -n 5 --no-pager 2>/dev/null)"
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
  systemctl stop sbm-watchdog.timer sbm-watchdog.service 2>/dev/null
  systemctl reset-failed 'sbm-watchdog*' 2>/dev/null
  systemd-run --collect --unit=sbm-watchdog --on-active=30 "$SELF" --watchdog >/dev/null 2>&1 \
    || out_warn "看门狗部署失败，请确认外网连通性"
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
  [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { tell_warn "端口格式无效，请输入 1-65535"; return 1; }
  [ "$port" = 80 ] && { tell_warn "端口 80 已被系统预留用于证书签发验证"; return 1; }
  [ "$port" = "$allow" ] && return 0
  grep -qx "$port" <<<"$(protected_ports)" && { tell_warn "该端口已被其它节点或 SSH 进程使用"; return 1; }
  grep -qx "$port" <<<"$(listening_ports "$proto")" && { tell_warn "检测到该端口正在被其它程序占用"; return 1; }
  return 0
}

prompt_port(){
  local proto=$1 current=$2 port def_port
  while :; do
    def_port=${current:-$(random_port)}
    port=$(prompt "指定监听端口 (输入 0 取消)" "$def_port")
    [ "$port" = "0" ] && return 1
    validate_port "$port" "$proto" "$current" && { printf '%s' "$port"; return 0; }
  done
}

validate_range(){
  local range=$1 low high port
  [[ $range =~ ^[0-9]+-[0-9]+$ ]] || { tell_warn "格式应为: 20000-30000"; return 1; }
  low=${range%-*}; high=${range#*-}
  [ "$low" -ge 1 ] && [ "$high" -le 65535 ] && [ "$low" -lt "$high" ] || { tell_warn "输入的端口范围不合法"; return 1; }
  for port in $(listening_ports u) $(protected_ports) 80 443; do
    [ "$port" -ge "$low" ] && [ "$port" -le "$high" ] && { tell_warn "设定范围内包含正在使用的保留端口: $port"; return 1; }
  done
  return 0
}

probe_handshake_target(){
  local target=$1 result
  command -v openssl >/dev/null || { tell_warn "检测工具未安装，跳过验证"; return 0; }
  result=$(echo | timeout 10 openssl s_client -connect "$target:443" -servername "$target" -alpn h2 -tls1_3 2>/dev/null)
  grep -q "TLSv1.3" <<<"$result" || { tell_warn "检测失败: 域名不支持 TLS 1.3 协议"; return 1; }
  grep -q "ALPN protocol: h2" <<<"$result" || { tell_warn "检测失败: 域名不支持 HTTP/2 协议"; return 1; }
  grep -qi "X25519" <<<"$result" || { tell_warn "检测异常: 域名未检测到 X25519 特性"; return 1; }
  tell_ok "域名特性匹配验证通过"
  return 0
}

validate_domain(){
  local domain=$1 resolved ipv4 ipv6
  resolved=$(resolve_addresses "$domain")
  [ -n "$resolved" ] || { tell_warn "域名无法解析到任何 IP"; return 1; }
  ipv4=$(local_ipv4); ipv6=$(local_ipv6)
  if ! { [ -n "$ipv4" ] && grep -qx "$ipv4" <<<"$resolved"; } \
     && ! { [ -n "$ipv6" ] && grep -qx "$ipv6" <<<"$resolved"; }; then
    tell_warn "域名解析地址 [ $(tr '\n' ' ' <<<"$resolved") ] 与本机 IP 不匹配"
    return 1
  fi
  case $(state_get challenge) in
    http) grep -qx 80 <<<"$(listening_ports t)" && { tell_warn "本机 80 端口已被占用，无法进行 HTTP-01 验证"; return 1; } ;;
    alpn) grep -qx 443 <<<"$(listening_ports t)" && { tell_warn "本机 443 端口已被占用，无法进行 TLS-ALPN-01 验证"; return 1; } ;;
  esac
  tell_ok "域名解析记录验证正常"
  return 0
}

setup_certificate(){
  local suggest=${1:-} domain email mode
  [ -n "$(state_get domain)" ] && [ -n "$(state_get email)" ] && return 0
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; return 1; }
  
  echo -e "\n  ${YELLOW}该项配置需要绑定域名并签发证书${PLAIN}"
  domain=$(prompt "请输入域名 (如 example.com, 留空取消)" "$suggest"); [ -n "$domain" ] || return 1
  email=$(prompt "请输入 ACME 注册通知邮箱" "admin@$domain"); [ -n "$email" ] || return 1
  
  echo -e "\n  ${CYAN}选择域名证书的获取验证方式:${PLAIN}"
  echo "  1. HTTP-01      (推荐，需放行 80 端口)"
  echo "  2. TLS-ALPN-01  (推荐，需放行 443 端口)"
  echo "  3. DNS-01       (Cloudflare API 验证)"
  echo "  4. DNS-01       (阿里云 DNS API 验证)"
  echo "  5. DNS-01       (ACME-DNS API 验证)"
  
  case $(prompt "请选择方式" 1) in
    2) mode=alpn ;;
    3) mode=dns_cloudflare; state_set cf_token "$(prompt 'Cloudflare API Token')" ;;
    4) mode=dns_alidns; state_set ali_key "$(prompt 'AccessKeyId')"; state_set ali_secret "$(prompt 'AccessKeySecret')" ;;
    5) mode=dns_acmedns
       state_set acmedns_url "$(prompt 'server_url')"
       state_set acmedns_user "$(prompt 'username')"
       state_set acmedns_pass "$(prompt 'password')"
       state_set acmedns_sub "$(prompt 'subdomain')" ;;
    *) mode=http ;;
  esac
  
  state_set challenge "$mode"; state_set domain "$domain"; state_set email "$email"
  
  if ! validate_domain "$domain"; then
    prompt_yes "验证存在异常，是否强制继续配置流程" || { state_set domain ""; state_set email ""; return 1; }
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
    out_ok "协议创建并应用成功"; out_gap; render_share_uri "$file"
  else
    rm -f "$file"; apply_config_quiet; out_warn "配置应用失败，当前状态已回滚"
  fi
  wait_key
}

create_vless_reality(){
  local name port uuid target keypair private public short_id tag body
  clear; tell "${CYAN}== 创建 VLESS REALITY ==${PLAIN}"
  name=$(prompt "指定节点名称 (输入 0 取消)" "VLESS-Reality"); [ "$name" = "0" ] && return
  port=$(prompt_port t "") || return
  uuid=$(prompt "指定通讯 UUID (留空自动生成)" "$(random_uuid)")
  while :; do
    target=$(prompt "设置握手目标域名" "www.microsoft.com")
    probe_handshake_target "$target" && break
    prompt_yes "是否继续使用此域名" && break
  done
  keypair=$("$CORE" generate reality-keypair)
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] || { tell_warn "核心组件运算失败，无法生成密钥"; wait_key; return; }
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
  clear; tell "${CYAN}== 创建 VLESS Vision + TCP + TLS ==${PLAIN}"
  name=$(prompt "指定节点名称 (输入 0 取消)" "VLESS-TLS"); [ "$name" = "0" ] && return
  setup_certificate || return
  port=$(prompt_port t "") || return
  uuid=$(prompt "指定通讯 UUID (留空自动生成)" "$(random_uuid)")
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
  clear; tell "${CYAN}== 创建 Hysteria2 ==${PLAIN}"
  name=$(prompt "指定节点名称 (输入 0 取消)" "Hysteria2"); [ "$name" = "0" ] && return
  setup_certificate || return
  port=$(prompt_port u "") || return
  password=$(prompt "设置连接密码" "$(random_password)")
  hopping=""
  if prompt_yes "是否配置并开启端口跳跃防封锁机制"; then
    if hopping_node >/dev/null; then
      tell_warn "当前已有其它节点开启了跳跃规则，暂不支持开启多个"
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
  clear; tell "${CYAN}== 创建 TUIC ==${PLAIN}"
  name=$(prompt "指定节点名称 (输入 0 取消)" "TUIC"); [ "$name" = "0" ] && return
  setup_certificate || return
  port=$(prompt_port u "") || return
  uuid=$(prompt "指定通讯 UUID (留空自动生成)" "$(random_uuid)")
  password=$(prompt "设置连接密码" "$(random_password)")
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
  clear; tell "${CYAN}== 创建 Trojan ==${PLAIN}"
  name=$(prompt "指定节点名称 (输入 0 取消)" "Trojan"); [ "$name" = "0" ] && return
  setup_certificate || return
  port=$(prompt_port t "") || return
  password=$(prompt "设置连接密码" "$(random_password)")
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
  clear; tell "${CYAN}== 创建 AnyTLS ==${PLAIN}"
  name=$(prompt "指定节点名称 (输入 0 取消)" "AnyTLS"); [ "$name" = "0" ] && return
  setup_certificate || return
  port=$(prompt_port t "") || return
  password=$(prompt "设置连接密码" "$(random_password)")
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
  clear; tell "${CYAN}== 创建 SOCKS5 ==${PLAIN}"
  name=$(prompt "指定节点名称 (输入 0 取消)" "Socks5"); [ "$name" = "0" ] && return
  username=$(prompt "设置鉴权账号" "admin")
  password=$(prompt "设置鉴权密码" "$(random_password)")
  [ -n "$username" ] && [ -n "$password" ] || { tell_warn "账号和密码均为必填项"; wait_key; return; }
  port=$(prompt_port t "") || return
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
  out "${GREEN}$uri${PLAIN}"
  [ -n "$hopping" ] && out "跳跃配置: $hopping"
  if [ "$mode" != acme ]; then
    ipv6=$(local_ipv6)
    [ -n "$ipv6" ] && out "${GREEN}${uri/@$host:/@[$ipv6]:}${PLAIN}"
  fi
}

list_nodes(){
  local file index=0 proto
  NODE_FILES=()
  for file in "$NODE_DIR"/*.json; do
    index=$((index+1)); NODE_FILES+=("$file")
    [ "$(jq -r .proto "$file")" = u ] && proto=UDP || proto=TCP
    printf '  %2d. [%-14s] 端口: %-5s/%-3s | %s\n' "$index" "$(jq -r .kind "$file")" "$(jq -r .port "$file")" "$proto" "$(jq -r .name "$file")"
  done
  [ "$index" = 0 ] && tell "  系统内暂未配置任何节点数据"
  return 0
}

select_node(){
  local index
  list_nodes; tell "   0. 放弃选择并返回"
  [ ${#NODE_FILES[@]} = 0 ] && { wait_key; return 1; }
  index=$(prompt "请输入所需操作的列表序号")
  [ -z "$index" ] && return 1
  [ "$index" = 0 ] && return 1
  [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#NODE_FILES[@]} ] \
    || { tell_warn "列表序号输入不规范"; wait_key; return 1; }
  PICKED=${NODE_FILES[$((index-1))]}
  return 0
}

menu_create_protocol(){
  clear
  tell "${CYAN}== 代理协议创建向导 ==${PLAIN}"
  tell "  1. VLESS REALITY"
  tell "  2. VLESS Vision + TCP + TLS"
  tell "  3. Hysteria2"
  tell "  4. TUIC"
  tell "  5. Trojan"
  tell "  6. AnyTLS"
  tell "  7. SOCKS5"
  tell "  0. 放弃当前操作并返回"
  case $(prompt "请输入需部署的协议代号") in
    1) create_vless_reality ;;
    2) create_vless_tls ;;
    3) create_hysteria2 ;;
    4) create_tuic ;;
    5) create_trojan ;;
    6) create_anytls ;;
    7) create_socks ;;
    0) return ;;
  esac
}

menu_delete_protocol(){
  clear; tell "${CYAN}== 删除现有协议配置 ==${PLAIN}"
  select_node || return
  prompt_yes "危险操作警告: 是否确认删除节点 $(jq -r .name "$PICKED")" || return
  
  local was_acme
  was_acme=$(jq -r .tls_mode "$PICKED")
  rm -f "$PICKED"
  
  if [ "$was_acme" = "acme" ]; then
    local acme_count=0
    for f in "$NODE_DIR"/*.json; do
      [ "$(jq -r .tls_mode "$f")" = "acme" ] && acme_count=$((acme_count+1))
    done
    if [ "$acme_count" -eq 0 ] && [ -n "$(state_get domain)" ]; then
      out_gap
      if prompt_yes "系统检测到这是最后一个使用域名的节点，是否连同域名配置和证书文件一起清理"; then
        state_set domain ""
        state_set email ""
        state_set challenge "http"
        rm -rf "$ACME_DIR"/*
        tell_ok "域名配置和系统残留证书已清理完成"
      fi
    fi
  fi

  apply_config && tell_ok "所选配置及相关底层规则已注销生效"
  wait_key
}

menu_modify_reality_domain() {
  clear; tell "${CYAN}== 管理 REALITY 握手域名 ==${PLAIN}"
  local file index=0 r_files=() count=0 target
  for file in "$NODE_DIR"/*.json; do
    if [ "$(jq -r .kind "$file")" = "vless-reality" ]; then
      index=$((index+1)); r_files+=("$file"); count=$((count+1))
      target=$(jq -r .meta.target "$file")
      printf '  %2d. [%s] | %s\n' "$index" "${GREEN}${target}${PLAIN}" "$(jq -r .name "$file")"
    fi
  done
  [ "$count" = 0 ] && { tell_warn "系统中暂未发现 REALITY 节点"; wait_key; return; }
  tell "   0. 返回上级菜单"
  
  index=$(prompt "请输入需要管理的列表序号")
  [ "$index" = 0 ] && return
  [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#r_files[@]} ] \
    || { tell_warn "列表序号输入不规范"; wait_key; return; }
  
  local pick="${r_files[$((index-1))]}"
  local old_target=$(jq -r .meta.target "$pick")
  local new_target
  
  while :; do
    new_target=$(prompt "设置新的握手目标域名" "www.apple.com")
    [ -n "$new_target" ] || return
    [ "$new_target" = "$old_target" ] && { tell_warn "与当前配置一致，未作更改"; return; }
    probe_handshake_target "$new_target" && break
    prompt_yes "域名检测异常，是否依然强制加载该配置" && break
  done
  
  json_edit "$pick" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v' \
    --arg v "$new_target" || { tell_warn "底层配置覆写失败"; wait_key; return; }
  
  if apply_config; then
    tell_ok "握手域名已更新并生效"; out_gap; render_share_uri "$pick"
  fi
  wait_key
}

menu_modify_protocol(){
  local kind value other current_hop
  clear; tell "${CYAN}== 修改节点运行参数 ==${PLAIN}"
  select_node || return
  kind=$(jq -r .kind "$PICKED")
  clear
  tell "${CYAN}== 配置修改栏目: $(jq -r .name "$PICKED") [$kind] ==${PLAIN}"
  tell "  1. 节点识别名称"
  tell "  2. 节点监听端口"
  case $kind in
    vless-reality|vless-tls) tell "  3. 节点通讯 UUID" ;;
    socks) tell "  3. 连接鉴权密码"; tell "  4. 连接鉴权账号" ;;
    *) tell "  3. 节点连接密码" ;;
  esac
  [ "$kind" = hysteria2 ] && tell "  6. 端口跳跃机制"
  tell "  0. 返回上级菜单"
  
  case $(prompt "请输入需修改的配置项代号") in
    1)
      value=$(prompt "请设定新的识别名称" "$(jq -r .name "$PICKED")"); [ -n "$value" ] || return
      json_edit "$PICKED" '.name=$v' --arg v "$value" || { tell_warn 覆写流程异常; wait_key; return; } ;;
    2)
      value=$(prompt_port "$(jq -r .proto "$PICKED")" "$(jq -r .port "$PICKED")") || return
      json_edit "$PICKED" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" \
        || { tell_warn 覆写流程异常; wait_key; return; } ;;
    3)
      if [ "$kind" = vless-reality ] || [ "$kind" = vless-tls ]; then
        value=$(prompt "输入新的通讯 UUID (留空则随机自动签发)")
        [ -z "$value" ] && value=$(random_uuid)
        json_edit "$PICKED" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value"
      else
        value=$(prompt "输入新的连接密码 (留空则随机自动签发)")
        [ -z "$value" ] && value=$(random_password)
        json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value"
      fi || { tell_warn 覆写流程异常; wait_key; return; } ;;
    4)
      [ "$kind" = socks ] || return
      value=$(prompt "输入新的连接账号" "$(jq -r .meta.username "$PICKED")"); [ -n "$value" ] || return
      json_edit "$PICKED" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value" \
        || { tell_warn 覆写流程异常; wait_key; return; } ;;
    6)
      [ "$kind" = hysteria2 ] || return
      current_hop=$(jq -r '.hopping//""' "$PICKED")
      value=$(prompt "配置新的端口跳跃范围 (当前规则: ${current_hop:-未部署}, 输入 0 关闭此机制, 留空保持现状)")
      if [ -z "$value" ]; then
        tell_ok "现有机制保持不变"; wait_key; return;
      fi
      if [ "$value" = "0" ]; then
        value=""
      else
        validate_range "$value" || { wait_key; return; }
        other=$(hopping_node) && [ "$other" != "$PICKED" ] && { tell_warn "跳跃规则冲突，其它节点正在独占使用该机制"; wait_key; return; }
      fi
      json_edit "$PICKED" '.hopping=$v' --arg v "$value" || { tell_warn 覆写流程异常; wait_key; return; } ;;
    0) return ;;
    *) return ;;
  esac
  
  if apply_config; then
    tell_ok "修改参数已应用并实时生效"; out_gap; render_share_uri "$PICKED"
  fi
  wait_key
}

render_certificate_status(){
  local domain crt expiry days
  domain=$(state_get domain); [ -n "$domain" ] || return 0
  tell ""
  tell "全局绑定域名: $domain | 签发验证通道: $(state_get challenge)"
  crt=$(find "$ACME_DIR" -type f -name "$domain.crt" 2>/dev/null | head -1)
  [ -n "$crt" ] || crt=$(find "$ACME_DIR" -type f -name '*.crt' 2>/dev/null | head -1)
  [ -n "$crt" ] || { tell "${YELLOW}系统证书状态: 暂未识别到签发数据${PLAIN}"; return 0; }
  expiry=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
  [ -n "$expiry" ] || { tell "${RED}系统证书状态: 无法解析配置数据${PLAIN}"; return 0; }
  days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  tell "证书到期时间: $expiry | 可用安全期: ${days} 天"
  systemctl is-active --quiet sing-box || tell_warn "核心引擎已离线，自动化证书续期将处于停滞状态"
}

menu_server_info(){
  local file port proto status count=0 tcp_list udp_list
  tcp_list=$(listening_ports t); udp_list=$(listening_ports u)
  clear
  tell "${CYAN}== 服务端运行总览 ==${PLAIN}"
  systemctl is-active --quiet sing-box && tell_ok "底层协议引擎: 健康运行" || tell_warn "底层协议引擎: 离线挂起"
  tell "当前透明出口: $(exit_label)"
  for file in "$NODE_DIR"/*.json; do
    count=$((count+1))
    port=$(jq -r .port "$file"); proto=$(jq -r .proto "$file")
    if [ "$proto" = u ]; then
      grep -qx "$port" <<<"$udp_list" && status="${GREEN}正常监听中${PLAIN}" || status="${RED}接口无响应${PLAIN}"
    else
      grep -qx "$port" <<<"$tcp_list" && status="${GREEN}正常监听中${PLAIN}" || status="${RED}接口无响应${PLAIN}"
    fi
    tell ""
    tell "── $(jq -r .name "$file") [$(jq -r .kind "$file")] | 分配端口 $port $status"
    render_share_uri "$file"
  done
  [ "$count" = 0 ] && tell "\n  系统内暂未配置任何节点数据"
  render_certificate_status
  wait_key
}

menu_change_domain(){
  local new_domain old_domain old_email old_challenge file count=0
  clear; tell "${CYAN}== 全局域名管理中心 ==${PLAIN}"
  old_domain=$(state_get domain); old_email=$(state_get email); old_challenge=$(state_get challenge)
  tell "当前配置域名: ${old_domain:-未部署数据}"
  tell "以下协议栈将关联该变动:"
  for file in "$NODE_DIR"/*.json; do
    if [ "$(jq -r .tls_mode "$file")" = acme ]; then
      tell "  - $(jq -r .name "$file") [$(jq -r .kind "$file")]"
      count=$((count+1))
    fi
  done
  [ "$count" = 0 ] && tell "  数据为空"
  echo ""
  new_domain=$(prompt "请输入新域名规则 (留空则取消操作)"); [ -z "$new_domain" ] && return
  validate_domain "$new_domain" || prompt_yes "验证未通过，是否依然强行写入系统配置？(y/N)" || return
  
  if prompt_yes "是否同步重置当前域名的签发验证机制？(y/N)"; then
    state_set domain ""; state_set email ""
    if ! setup_certificate "$new_domain"; then
      state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"
      return
    fi
  else
    state_set domain "$new_domain"
  fi
  
  if [ "$new_domain" != "$old_domain" ]; then
    rm -rf "$ACME_DIR"/*
  fi
  
  if apply_config; then
    menu_server_info
  else
    tell_warn "部署链路异常，系统配置已实施紧急回滚: ${old_domain:-未部署数据}"
    state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"
    apply_config_quiet; wait_key
  fi
}

menu_server(){
  while :; do
    clear
    tell "${CYAN}== 服务端协议管理中心 ==${PLAIN}"
    tell "  1. 搭建节点协议"
    tell "  2. 卸载节点协议"
    tell "  3. 修改节点运行参数"
    tell "  4. 配置 REALITY 握手规则"
    tell "  5. 查看当前服务端明细"
    tell "  6. 执行全局更换域名"
    tell "  7. 强力重启底层组件"
    tell "  8. 挂起并关闭服务进程"
    tell "  0. 退出至主界面"
    case $(prompt "请输入需执行的操作代号") in
      1) menu_create_protocol ;;
      2) menu_delete_protocol ;;
      3) menu_modify_protocol ;;
      4) menu_modify_reality_domain ;;
      5) menu_server_info ;;
      6) menu_change_domain ;;
      7) if systemctl restart sing-box; then sync_bypass_rules; sync_hopping_rules; tell_ok "底层组件重启完毕"; else tell_warn "核心引擎启动失败"; fi; wait_key ;;
      8) if systemctl stop sing-box; then tell_ok "服务进程已挂起"; else tell_warn "操作遇到异常拦截"; fi; wait_key ;;
      0) break ;;
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
  clear; tell "${CYAN}== 新增订阅节点 ==${PLAIN}"
  name=$(prompt "设置远端节点识别名称" "RemoteNode"); [ -n "$name" ] || return
  uri=$(prompt "输入节点标准链接"); [ -n "$uri" ] || return
  parse_uri "$uri"
  ipv4=$(local_ipv4); ipv6=$(local_ipv6); domain=$(state_get domain)
  for port in $(node_ports); do
    if [ "$URI_PORT" = "$port" ] && { { [ -n "$ipv4" ] && [ "$URI_HOST" = "$ipv4" ]; } \
       || { [ -n "$ipv6" ] && [ "$URI_HOST" = "$ipv6" ]; } \
       || { [ -n "$domain" ] && [ "$URI_HOST" = "$domain" ]; }; }; then
      tell_warn "拦截操作: 本机节点禁止自循环接入，将引发路由崩溃"; wait_key; return
    fi
  done
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag") || { tell_warn "引擎无法解析并建立该协议格式"; wait_key; return; }
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
    tell_ok "远端节点数据挂载完成: $name"
  else
    tell_warn "链接转译未通过配置校验拦截:"
    "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2
  fi
  rm -f "$probe"; wait_key
}

list_peers(){
  local file index=0 current mark
  current=$(state_get exit); PEER_FILES=()
  for file in "$PEER_DIR"/*.json; do
    index=$((index+1)); PEER_FILES+=("$file")
    [ "$(jq -r .tag "$file")" = "$current" ] && mark="${GREEN}<= 全局生效中${PLAIN}" || mark=""
    printf '  %2d. [%-10s] %b | %s\n' "$index" "$(jq -r .outbound.type "$file")" "$mark" "$(jq -r .name "$file")"
  done
  [ "$index" = 0 ] && tell "  未检索到有效的外部节点数据"
}

select_peer(){
  local index
  list_peers; tell "   0. 放弃选择并返回"
  [ ${#PEER_FILES[@]} = 0 ] && { wait_key; return 1; }
  index=$(prompt "请输入指令对应的序号")
  [ -z "$index" ] && return 1
  [ "$index" = 0 ] && return 1
  [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#PEER_FILES[@]} ] \
    || { tell_warn "操作失败: 指令不在预期范围内"; wait_key; return 1; }
  PICKED=${PEER_FILES[$((index-1))]}
  return 0
}

wg_client_active(){
  [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] \
    && [ "$(jq -r .role "$WG_CONF")" = client ]
}

peer_select(){
  local tag previous
  clear; tell "${CYAN}== 全局透明代理配置 ==${PLAIN}"
  select_peer || return
  tag=$(jq -r .tag "$PICKED"); previous=$(state_get exit)
  if wg_client_active; then
    prompt_yes "拦截提示: 当前正位于 WireGuard 通信环境下，是否强制断开原有隧道" || return
    json_edit "$WG_CONF" '.enabled=false'
  fi
  arm_watchdog; state_set exit "$tag"
  if apply_config; then
    tell_ok "网卡劫持配置完成，本机流量现已发往: $(jq -r .name "$PICKED")"
  else
    state_set exit "$previous"; apply_config_quiet; tell_warn "网卡切换失败，原流量环境已安全回滚"
  fi
  wait_key
}

peer_delete(){
  clear; tell "${CYAN}== 移除外部节点 ==${PLAIN}"
  select_peer || return
  [ "$(jq -r .tag "$PICKED")" = "$(state_get exit)" ] && state_set exit direct
  rm -f "$PICKED"
  apply_config && tell_ok "所选外部节点已剥离并释放"
  wait_key
}

peer_stop(){
  clear
  state_set exit direct
  apply_config && tell_ok "引擎代理进程已中断，网卡接管权限释放为物理直连状态"
  wait_key
}

exit_label(){
  local selected; selected=$(state_get exit)
  case $selected in
    direct) echo "物理直连" ;;
    wireguard) echo "WireGuard 加密专线" ;;
    *) [ -f "$PEER_DIR/$selected.json" ] && jq -r .name "$PEER_DIR/$selected.json" || echo "$selected 配置文件遗失" ;;
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

render_client_ip_status() {
  local exit_node=$(state_get exit)
  local proxy_name="物理直连"
  if [ "$exit_node" != "direct" ]; then
    if [ "$exit_node" = "wireguard" ]; then
      proxy_name="WireGuard"
    else
      proxy_name="$(jq -r .outbound.type "$PEER_DIR/$exit_node.json" 2>/dev/null || echo '未知环境协议')"
    fi
  fi
  
  local ip4=$(curl -s4 --max-time 3 http://ip-api.com/json/?lang=zh-CN 2>/dev/null)
  local ip6=$(curl -s6 --max-time 3 http://ip-api.com/json/?lang=zh-CN 2>/dev/null)
  
  local v4_str="-"
  local v6_str="-"
  if [ -n "$ip4" ] && [ "$(jq -r .status <<< "$ip4")" = "success" ]; then
    v4_str="$(jq -r .query <<< "$ip4") ($(jq -r .country <<< "$ip4"))"
  fi
  if [ -n "$ip6" ] && [ "$(jq -r .status <<< "$ip6")" = "success" ]; then
    v6_str="$(jq -r .query <<< "$ip6") ($(jq -r .country <<< "$ip6"))"
  fi
  
  echo -e "  --- 本机出口 IP 解析 (${CYAN}${proxy_name}${PLAIN}) ---"
  echo -e "  IPv4 通道: ${v4_str}"
  echo -e "  IPv6 通道: ${v6_str}"
}

menu_client_status(){
  clear
  echo -e "${CYAN}== 网络通信状态分析 ==${PLAIN}"
  if [ "$(state_get exit)" = direct ]; then
    echo -e "  工作模式: 物理路由网关直接出网"
  else
    echo -e "  工作模式: TUN 虚拟路由劫持 -> 投递至 $(exit_label)"
  fi
  echo ""
  render_client_ip_status
  echo ""
  
  local udp_res="${RED}[×] 链路受阻不通${PLAIN}"
  for server in stun.cloudflare.com:3478 stun.l.google.com:19302 stun.qq.com:3478; do
    result=$(stun_probe "${server%%:*}" "${server##*:}") && {
      udp_res="${GREEN}[√] 穿透畅通 (端点端口: ${result%%:*})${PLAIN}"
      break
    }
  done
  echo -e "  UDP 端口穿透: ${udp_res}"
  wait_key
}

menu_client(){
  while :; do
    clear
    tell "${CYAN}== 客户端管理中心 ==${PLAIN}"
    tell "当前流量出口接管状态: ${YELLOW}$(exit_label)${PLAIN}"
    tell "  1. 挂载远端节点链接"
    tell "  2. 切换当前接管节点"
    tell "  3. 删除已挂载节点"
    tell "  4. 恢复本地直连网络"
    tell "  5. 获取当前出站 IP 状态报告"
    tell "  0. 退回至系统主界面"
    case $(prompt "请输入需执行的操作代号") in
      1) peer_add ;;
      2) peer_select ;;
      3) peer_delete ;;
      4) peer_stop ;;
      5) menu_client_status ;;
      0) break ;;
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
  tell "${CYAN}== WireGuard 安全内网状态报告 ==${PLAIN}"
  if [ "$role" = server ]; then
    tell "部署角色: 出口端服务器 (本机监听握手响应)"
  else
    tell "部署角色: 接入端设备 (本机流量强制穿透隧道)"
  fi
  tell "隧道引擎状态: $([ "$(jq -r .enabled "$file")" = true ] && echo -e "${GREEN}活跃调度中${PLAIN}" || echo -e "${RED}配置被挂起${PLAIN}")"
  echo ""
  tell "本地核心公钥: $(jq -r .public_key "$file")"
  tell "本地虚拟 IP:  $(jq -r '.address|join(", ")' "$file")"
  [ "$role" = server ] && tell "监听响应端口: $(jq -r .listen_port "$file")"
  [ "$role" = client ] && tell "远端服务器 IP: $(jq -r .peer_host "$file"):$(jq -r .peer_port "$file")"
  tell "远端验证公钥: $(jq -r '.peer_public_key|if .=="" then "<核心阻断: 数据需人工补录>" else . end' "$file")"
  tell "远端虚拟 IP:  $(jq -r .peer_ip "$file")"
  tell "链路 MTU 值:  1408"
  
  if [ "$role" = client ]; then
    if [ "$(jq -r .enabled "$file")" = true ]; then
      if [ "$(wg_tunnel_state "$(jq -r .peer_ip "$file")")" = up ]; then
        tell_ok "握手协议达成，隧道桥接连通成功"
      else
        tell_warn "核心链路握手中断，请检查远端防火墙或双向公钥鉴权"
      fi
    fi
  else
    echo ""
    tell "${YELLOW}请将以下信息部署至接入端配置文件:${PLAIN}"
    tell "  桥接远端地址: $(local_ipv4):$(jq -r .listen_port "$file")"
    tell "  桥接验证公钥: $(jq -r .public_key "$file")"
    tell "  分配内网前缀: $(jq -r '.address[0]' "$file" | cut -d. -f1-3)"
  fi
}

wg_setup(){
  local role keypair private public prefix address4 address6 peer_ip4 peer_ip6
  local listen_port peer_host peer_port peer_key body
  clear
  tell "${CYAN}== WireGuard 环境初始化向导 ==${PLAIN}"
  tell "  1. 部署为出口端服务器 (承载对端流量发出)"
  tell "  2. 部署为接入端设备 (流量交由出口端代理)"
  tell "  0. 撤销指令"
  case $(prompt "请选择本机的路由角色定位") in
    1) role=server ;;
    2) role=client ;;
    0) return ;;
    *) return ;;
  esac
  
  keypair=$("$CORE" generate wg-keypair)
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] || { tell_warn "核心组件运算终止"; wait_key; return; }
  
  while :; do
    prefix=$(prompt "自定义此隧道的私有网段分配" "10.7.0")
    [[ $prefix =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    tell_warn "网段分配输入不规范"
  done
  
  if [ "$role" = server ]; then
    address4="$prefix.1/24"; address6="fd00:7::1/64"
    peer_ip4="$prefix.2"; peer_ip6="fd00:7::2"
    while :; do
      listen_port=$(prompt_port "u" "") || return
      break
    done
    peer_key=$(prompt "若已获取接入端的公钥请在此记录 (留空稍后配置)")
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
    peer_host=$(prompt "配置出口端机器的公网 IP")
    peer_port=$(prompt "配置出口端响应的连接端口")
    peer_key=$(prompt "填写对应的通信验证公钥")
    [ -n "$peer_host" ] && [ -n "$peer_port" ] && [ -n "$peer_key" ] \
      || { tell_warn "核心配置数据不完整拦截保存"; wait_key; return; }
    [[ $peer_port =~ ^[0-9]+$ ]] || { tell_warn "端口解析格式报错"; wait_key; return; }
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
  json_save "$WG_CONF" "$body" || { tell_warn "配置文件序列化写入失败"; wait_key; return; }
  render_wg_info "$WG_CONF"; wait_key
}

wg_fill_peer_key(){
  local key
  clear; tell "${CYAN}== 补录远端通信公钥 ==${PLAIN}"
  [ -f "$WG_CONF" ] || { tell_warn "系统未获取到环境初始化数据"; wait_key; return; }
  key=$(prompt "在此处补充正确的远端公钥" "$(jq -r .peer_public_key "$WG_CONF")")
  [ -n "$key" ] || return
  json_edit "$WG_CONF" '.peer_public_key=$k|.endpoint.peers[0].public_key=$k' --arg k "$key" \
    || { tell_warn "JSON 文件结构覆写失败"; wait_key; return; }
  if [ "$(jq -r .enabled "$WG_CONF")" = true ]; then
    apply_config && tell_ok "引擎配置热更新成功"
  else
    tell_ok "通信数据已补录至预载文件中"
  fi
  wait_key
}

wg_toggle(){
  local role previous
  clear
  [ -f "$WG_CONF" ] || { tell_warn "系统未获取到环境初始化数据"; wait_key; return; }
  role=$(jq -r .role "$WG_CONF"); previous=$(state_get exit)
  if [ "$(jq -r .enabled "$WG_CONF")" = true ]; then
    json_edit "$WG_CONF" '.enabled=false'
    [ "$previous" = wireguard ] && state_set exit direct
    apply_config && tell_ok "隧道虚拟链路已断开终止"
  else
    [ -n "$(jq -r .peer_public_key "$WG_CONF")" ] || { tell_warn "启动阻断: 环境中缺失公钥鉴权参数"; wait_key; return; }
    if [ "$role" = client ] && [ "$previous" != direct ]; then
      prompt_yes "拦截提示: 确定挂起当前的代理节点，转为使用隧道引擎接管网络" || return
    fi
    json_edit "$WG_CONF" '.enabled=true'
    if [ "$role" = client ]; then arm_watchdog; state_set exit wireguard; fi
    if apply_config; then
      sleep 3; render_wg_info "$WG_CONF"
    else
      json_edit "$WG_CONF" '.enabled=false'; state_set exit "$previous"
      apply_config_quiet; tell_warn "进程加载配置存在冲突拦截"
    fi
  fi
  wait_key
}

menu_wireguard(){
  local role_label tunnel_label
  while :; do
    clear
    tell "${CYAN}== WireGuard 内网构建中心 ==${PLAIN}"
    if [ -f "$WG_CONF" ]; then
      [ "$(jq -r .role "$WG_CONF")" = server ] && role_label="出口端模式" || role_label="接入端模式"
      [ "$(jq -r .enabled "$WG_CONF")" = true ] && tunnel_label="${GREEN}进程已驻留${PLAIN}" || tunnel_label="${RED}线程挂起中${PLAIN}"
      tell "当前部署规范: ${role_label} | 隧道引擎: ${tunnel_label}"
    else
      tell "数据提示: 本机暂无相关通信环境记录"
    fi
    tell "  1. 执行环境初始化构建"
    tell "  2. 手动补充远端通信公钥"
    tell "  3. 切换底层隧道引擎运行状态"
    tell "  4. 拉取本机环境及配置报告"
    tell "  5. 卸载清除全部底层相关参数"
    tell "  0. 退出至主界面"
    case $(prompt "请输入指令对应的序号") in
      1) wg_setup ;;
      2) wg_fill_peer_key ;;
      3) wg_toggle ;;
      4) clear
         if [ -f "$WG_CONF" ]; then render_wg_info "$WG_CONF"; wait_key
         else tell_warn "数据为空"; wait_key; fi ;;
      5) clear
         if prompt_yes "严重警告: 此操作将抹除网络内网所有数据配置"; then
           rm -f "$WG_CONF"
           [ "$(state_get exit)" = wireguard ] && state_set exit direct
           apply_config && tell_ok "规则注销并清除完成"
           wait_key
         fi ;;
      0) break ;;
    esac
  done
}

run_update(){
  local current latest
  clear
  current=$(core_version); latest=$(remote_version)
  tell "本地组件内核版本: $current"
  tell "远端前沿开源版本: ${latest:-资源获取连接超时}"
  [ -n "$latest" ] || { wait_key; return; }
  [ "$current" = "$latest" ] && { tell_ok "系统依赖版本匹配，状态正常"; wait_key; return; }
  prompt_yes "确定执行系统底层内核更迭操作" || return
  install_core && apply_config && tell_ok "内核编译重启及业务组件替换完成"
  wait_key
}

run_uninstall(){
  local packages guard=0
  clear
  tell_warn "卸载操作不可逆转，将彻底清空系统防火墙挂载规则、底层协议服务进程与运行核心"
  [ "$(prompt '确认进行格式化级操作，请输入 yes 确认')" = yes ] || return
  mapfile -t packages < <(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null)
  
  systemctl disable --now sing-box 2>/dev/null
  systemctl stop sbm-watchdog.timer sbm-watchdog.service 2>/dev/null
  systemctl reset-failed 'sbm-watchdog*' 2>/dev/null
  
  rm -f "$SERVICE_UNIT" "$DROPIN"
  rm -f /etc/systemd/system/sbm-watchdog.*
  rm -f /run/systemd/transient/sbm-watchdog.* 2>/dev/null
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
    tell "系统记录提示: 引擎曾在服务器加载时注册过 [ ${packages[*]} ] 依赖项包"
    if prompt_yes "是否将以上系统依赖环境执行还原剥离回收"; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${packages[@]}" >/dev/null 2>&1
      apt-get autoremove -y -q >/dev/null 2>&1
    fi
  fi
  rm -f "$SELF"
  tell_ok "系统清理完成，本机操作环境与运行痕迹已不留残存"
  exit 0
}

menu_status(){
  while :; do
    clear
    echo -e "${CYAN}== 系统状态信息 ==${PLAIN}"
    local os=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)
    local core=$(uname -r)
    local arch=$(uname -m)
    local mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}/MemFree/{f=$2}/Buffers/{b=$2}/^Cached/{c=$2}END{if(a=="")a=f+b+c; printf "%d / %d MB",(t-a)/1024,t/1024}' /proc/meminfo)
    local up=$(uptime -p 2>/dev/null | sed 's/up //;s/days/天/;s/day/天/;s/hours/小时/;s/hour/小时/;s/minutes/分钟/;s/minute/分钟/')
    local sb_ver=$(core_version)
    local sb_asset=$(state_get asset)
    local s_state="${RED}未运行${PLAIN}"
    systemctl is-active --quiet sing-box && s_state="${GREEN}正常运行${PLAIN}"
    
    local net_in="${RED}[×]${PLAIN}"
    curl -sI -m 3 http://www.baidu.com >/dev/null 2>&1 && net_in="${GREEN}[√]${PLAIN}"
    local net_out="${RED}[×]${PLAIN}"
    curl -sI -m 3 http://cp.cloudflare.com/generate_204 >/dev/null 2>&1 && net_out="${GREEN}[√]${PLAIN}"
    
    echo -e "  操作系统: ${os} | 系统内核: ${core} | 指令架构: ${arch}"
    echo -e "  内存占用: ${mem} | 运行时间: ${up:-未能提取}"
    echo -e "  服务引擎: ${s_state} | 核心版本: ${sb_ver:-缺少核心文件} (${sb_asset:-分支不明})"
    echo -e "  连通测试: 大陆直连 ${net_in} | 海外解析 ${net_out}"
    echo ""
    render_client_ip_status
    echo ""
    echo -e "  1. 检测系统内核更新"
    echo -e "  2. 执行清理销毁卸载"
    echo -e "  0. 返回上级系统界面"
    case $(prompt "请输入需执行的操作代号") in
      1) run_update ;;
      2) run_uninstall ;;
      0) break ;;
    esac
  done
}

bootstrap(){
  init_dirs
  check_dependencies
  local s_path
  if [ -n "${BASH_SOURCE[0]}" ] && [ -r "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "bash" ]; then
    s_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
  elif [ -r "$0" ] && [ "$0" != "bash" ] && [ "$0" != "sh" ]; then
    s_path=$(readlink -f "$0" 2>/dev/null)
  fi
  if [ -n "$s_path" ] && [ -f "$s_path" ] && [ "$s_path" != "$SELF" ]; then
    cp -f "$s_path" "$SELF" 2>/dev/null
    chmod 700 "$SELF"
  fi
  if [ -f "$SELF" ]; then
    if [ ! -L "$SHORTCUT" ] || [ "$(readlink "$SHORTCUT")" != "$SELF" ]; then
      ln -sf "$SELF" "$SHORTCUT" 2>/dev/null
    fi
  fi
  if [ ! -x "$CORE" ]; then
    echo -e "  ${CYAN}核心架构拉取中，正在执行初次安装编译...${PLAIN}"
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
  clear
  tell "${CYAN}================================${PLAIN}"
  tell "${CYAN}         s 管 理 系 统          ${PLAIN}"
  tell "${CYAN}================================${PLAIN}"
  tell "  1. 服务端运行管理"
  tell "  2. 客户端出境配置"
  tell "  3. WireGuard 引擎"
  tell "  4. 系统状态及更新"
  tell "  0. 退出管理控制台"
  case $(prompt "请输入需操作的指令序号") in
    1) menu_server ;;
    2) menu_client ;;
    3) menu_wireguard ;;
    4) menu_status ;;
    0) clear; exit 0 ;;
  esac
done
