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

TMP_FILES=""
cleanup_tmp(){
  [ -n "$TMP_FILES" ] && rm -rf $TMP_FILES
}
trap cleanup_tmp EXIT INT TERM

NODE_COUNT=0
PEER_COUNT=0
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
  local msg="$1"
  local def="$2"
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
out(){ echo -e "  $*"; }
out_gap(){ echo ""; }
out_ok(){ echo -e "  ${GREEN}[√] $*${PLAIN}"; }
out_warn(){ echo -e "  ${RED}[×] $*${PLAIN}"; }

uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }
uri_decode(){ local s=${1//+/ }; s=${s//\\/\\\\}; printf '%b' "${s//%/\\x}"; }
slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){ openssl rand -hex 8; }
random_uuid(){ cat /proc/sys/kernel/random/uuid; }
random_port(){ shuf -i 20000-60000 -n1; }
version_ge(){ [ -n "$1" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

json_write(){
  local dest=$1 tmp
  tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  cat >"$tmp"
  [ -s "$tmp" ] || return 1
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
  chmod 700 "$SBM_DIR" "$ACME_DIR"
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
    sleep 1
    guard=$((guard+1))
    [ "$guard" -gt 30 ] && break
  done
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
  ensure_command wg wireguard-tools
  return 0
}

core_version(){
  if [ -z "$CORE_VERSION" ] && [ -x "$CORE" ]; then
    CORE_VERSION=$( { "$CORE" version 2>/dev/null; } 2>/dev/null | awk '/version/{print $3; exit}' )
  fi
  printf '%s' "$CORE_VERSION"
}
core_tags(){
  if [ -z "$CORE_TAGS" ] && [ -x "$CORE" ]; then
    CORE_TAGS=$( { "$CORE" version 2>/dev/null; } 2>/dev/null | sed -n 's/^Tags: //p' )
  fi
  printf '%s' "$CORE_TAGS"
}
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

local_ipv4(){ ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'; }
local_ipv6(){ ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'; }
resolve_addresses(){ getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u; }

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
  rm -f "$CORE"; install -m755 "$found" "$CORE"; rm -rf "$tmp"
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
ExecStartPost=$SHORTCUT --sync
ExecStopPost=$SHORTCUT --clear-hopping
EOF
  systemctl daemon-reload
}

ssh_ports(){
  {
    [ -n "$SSH_CONNECTION" ] && awk '{print $4}' <<<"$SSH_CONNECTION"
    ss -Hlntp 2>/dev/null | awk '/sshd/{print $4}' | sed 's/.*://'
    sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config 2>/dev/null
    sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config.d/*.conf 2>/dev/null
    sshd -T 2>/dev/null | awk '/^port /{print $2}'
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
  local peer_host node_files tls_extra providers strategy ipv6 probe_target
  
  selected=$(state_get exit); domain=$(state_get domain)
  probe_target=${WATCHDOG_PROBE:-}
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
      outbounds=$(jq -n --argjson base "$outbounds" --arg wg "$WG_IF" \
        '$base + [{"type":"direct","tag":"wg-direct","bind_interface":$wg}]')
      [ "$selected" = wireguard ] && { final="wg-direct"; use_tun=1; }
    fi
  fi
  
  if [ "$selected" != direct ] && [ "$selected" != wireguard ] && [ -f "$PEER_DIR/$selected.json" ]; then
    outbounds=$(jq -n --argjson base "$outbounds" --slurpfile peer "$PEER_DIR/$selected.json" '$base + [$peer[0].outbound]')
    final=$selected; use_tun=1
    peer_host=$(jq -r '.outbound.server//""' "$PEER_DIR/$selected.json")
  fi
  
  if [ -n "$probe_target" ] && [ "$probe_target" != "direct" ] && [ "$probe_target" != "wireguard" ] && [ -f "$PEER_DIR/$probe_target.json" ]; then
    outbounds=$(jq -n --argjson base "$outbounds" --slurpfile peer "$PEER_DIR/$probe_target.json" '$base + [$peer[0].outbound]')
  fi
  
  [ "$use_tun" = 1 ] && inbounds=$(jq -n --argjson list "$inbounds" --arg name "$TUN_IF" '
    [{type:"tun",tag:"tun-in",interface_name:$name,
      address:["172.19.0.1/30","fdfe:dcba:9876::1/126"],
      auto_route:true,strict_route:true,dns_mode:"auto",stack:"mixed",mtu:9000}] + $list')
      
  local dns_direct_server="1.1.1.1"
  local dns_remote_server="8.8.8.8"
  if [ -z "$(local_ipv4)" ] && [ -n "$(local_ipv6)" ]; then
    dns_direct_server="2606:4700:4700::1111"
    dns_remote_server="2001:4860:4860::8888"
  fi

  rules=$(jq -n --arg host "$peer_host" --arg dds "$dns_direct_server" '
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
    + [{ip_cidr:[(if ($dds | contains(":")) then ($dds+"/128") else ($dds+"/32") end)],action:"route",outbound:"direct"}]
    + [{ip_is_private:true,action:"route",outbound:"direct"}]')

  if [ -n "$probe_target" ]; then
    inbounds=$(jq -n --argjson list "$inbounds" '
      [{type:"mixed",tag:"probe-in",listen:"127.0.0.1",listen_port:2081}] + $list')
    rules=$(jq -n --argjson list "$rules" --arg target "$probe_target" '
      [{inbound:["probe-in"],action:"route",outbound:$target}] + $list')
  fi

  dns_block=$(jq -n --arg detour "$final" --arg host "$peer_host" --arg strategy "$strategy" \
                    --arg direct_srv "$dns_direct_server" --arg remote_srv "$dns_remote_server" '
    {
      servers: [
        {
          type: "udp",
          tag: "dns-direct",
          server: $direct_srv
        },
        (if $detour == "direct" then
          { type: "udp", tag: "dns-remote", server: $remote_srv }
        else
          { type: "udp", tag: "dns-remote", server: $remote_srv, detour: $detour }
        end)
      ],
      rules: [
        (if $host != "" and ($host | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") | not) and ($host | test("^[0-9a-fA-F:]+$") | not) then
          {domain: [$host], server: "dns-direct"}
        else empty end)
      ],
      final: "dns-remote"
    }
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
            default_domain_resolver:"dns-direct"}}
    | if ($endpoints|length)>0 then .endpoints=$endpoints else . end
    | if ($providers|length)>0 then .certificate_providers=$providers else . end'
}

apply_config(){
  local tmp error line guard=0
  tmp=$(mktemp)
  TMP_FILES="$TMP_FILES $tmp"
  build_config >"$tmp" 2>/dev/null || { rm -f "$tmp"; out_warn "配置生成失败"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; out_warn "配置写入异常"; return 1; }
  
  if ! error=$("$CORE" check -c "$tmp" 2>&1); then
    out_warn "配置校验未通过:"
    while IFS= read -r line; do out "    $line"; done <<<"$(head -4 <<<"$error")"
    rm -f "$tmp"; return 1
  fi
  install -m600 "$tmp" "$CONFIG"; rm -f "$tmp"
  
  systemctl reload-or-restart sing-box >/dev/null 2>&1
  
  while ! systemctl is-active --quiet sing-box; do
    sleep 0.2
    guard=$((guard+1))
    [ "$guard" -gt 15 ] && break
  done
  
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
stop_watchdog(){
  if [ -f "$WATCHDOG_PID" ]; then
    kill -9 "$(cat "$WATCHDOG_PID")" 2>/dev/null || true
    rm -f "$WATCHDOG_PID"
  fi
}
arm_watchdog(){
  stop_watchdog
  run_watchdog </dev/null >/dev/null 2>&1 &
  echo $! > "$WATCHDOG_PID"
}

run_watchdog(){
  local fail_count=0 probe2="http://captive.apple.com/hotspot-detect.html"
  local target_exit; target_exit=$(state_get exit)
  
  while :; do
    sleep 120
    local proxy_env=""
    
    if [ "$(state_get exit)" = "direct" ] && [ "$target_exit" != "direct" ]; then
      proxy_env="http://127.0.0.1:2081"
    fi
    
    if [ -n "$proxy_env" ]; then
      if env http_proxy="$proxy_env" curl -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL" || \
         env http_proxy="$proxy_env" curl -s -o /dev/null --connect-timeout 4 -m 6 "$probe2"; then
        fail_count=0
        if [ "$(state_get exit)" = "direct" ] && [ "$target_exit" != "direct" ]; then
          state_set exit "$target_exit"
          build_config | json_write "$CONFIG" && systemctl restart sing-box
          sync_bypass_rules
          sync_hopping_rules
        fi
      else
        fail_count=$((fail_count+1))
      fi
    else
      if curl -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL" || \
         curl -s -o /dev/null --connect-timeout 4 -m 6 "$probe2"; then
        fail_count=0
      else
        fail_count=$((fail_count+1))
        if [ "$fail_count" -ge 3 ] && [ "$(state_get exit)" != "direct" ]; then
          state_set exit direct
          WATCHDOG_PROBE="$target_exit" build_config | json_write "$CONFIG" && systemctl restart sing-box
          sync_bypass_rules
          sync_hopping_rules
        fi
      fi
    fi
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
  command -v openssl >/dev/null || { tell_warn "跳过域名验证"; return 0; }
  result=$(echo | timeout 10 openssl s_client -connect "$target:443" -servername "$target" -alpn h2 -tls1_3 2>/dev/null)
  grep -q "TLSv1.3" <<<"$result" || { tell_warn "不支持 TLS 1.3 协议"; return 1; }
  grep -q "ALPN protocol: h2" <<<"$result" || { tell_warn "不支持 HTTP/2 协议"; return 1; }
  grep -qi "X25519" <<<"$result" || { tell_warn "未检测到 X25519 特性"; return 1; }
  tell_ok "验证通过"
  return 0
}

validate_domain(){
  local domain=$1 resolved ipv4 ipv6
  resolved=$(resolve_addresses "$domain")
  [ -n "$resolved" ] || { tell_warn "无法解析该域名"; return 1; }
  ipv4=$(local_ipv4); ipv6=$(local_ipv6)
  if ! { [ -n "$ipv4" ] && grep -qx "$ipv4" <<<"$resolved"; } \
     && ! { [ -n "$ipv6" ] && grep -qx "$ipv6" <<<"$resolved"; }; then
    tell_warn "域名解析地址与本机 IP 不匹配"
    return 1
  fi
  case $(state_get challenge) in
    http) grep -qx 80 <<<"$(listening_ports t)" && { tell_warn "本机 80 端口已被占用"; return 1; } ;;
    alpn) grep -qx 443 <<<"$(listening_ports t)" && { tell_warn "本机 443 端口已被占用"; return 1; } ;;
  esac
  tell_ok "解析记录正常"
  return 0
}

setup_certificate(){
  local suggest=${1:-} domain email mode
  [ -n "$(state_get domain)" ] && [ -n "$(state_get email)" ] && return 0
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; return 1; }
  
  printf '\n  %b该协议需要绑定域名并签发证书%b\n' "${YELLOW}" "${PLAIN}"
  
  if [ -n "$suggest" ]; then
    domain="$suggest"
    printf '  %b已指定域名: %s%b\n' "${GREEN}" "$domain" "${PLAIN}"
  else
    domain=$(prompt "输入域名"); [ -n "$domain" ] || return 1
  fi
  
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
      3) mode=dns_cloudflare; state_set cf_token "$(prompt 'Cloudflare API Token')"; break ;;
      4) mode=dns_alidns; state_set ali_key "$(prompt 'AccessKeyId')"; state_set ali_secret "$(prompt 'AccessKeySecret')"; break ;;
      5) mode=dns_acmedns
         state_set acmedns_url "$(prompt 'server_url')"
         state_set acmedns_user "$(prompt 'username')"
         state_set acmedns_pass "$(prompt 'password')"
         state_set acmedns_sub "$(prompt 'subdomain')"; break ;;
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
  local name port password hopping tag body up_mbps down_mbps obfs_type obfs_password
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "Hysteria2")
  setup_certificate || return
  port=$(prompt_port u "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  
  while :; do
    up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" "0")
    [[ $up_mbps =~ ^[0-9]+$ ]] && break || tell_warn "输入无效，请重新输入数字"
  done
  while :; do
    down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "0")
    [[ $down_mbps =~ ^[0-9]+$ ]] && break || tell_warn "输入无效，请重新输入数字"
  done

  obfs_type=""
  obfs_password=""
  if prompt_yes "是否配置协议混淆"; then
    tell "  1. Salamander"
    tell "  2. Gecko"
    while :; do
      case $(prompt "请选择混淆算法" 2) in
        1) obfs_type="salamander"; break ;;
        2) obfs_type="gecko"; break ;;
        *) tell_warn "输入无效"; sleep 1 ;;
      esac
    done
    obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$password")
  fi

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
        --argjson up "$up_mbps" --argjson down "$down_mbps" \
        --arg obfs_type "$obfs_type" --arg obfs_pw "$obfs_password" '
   {tag:$tag,name:$name,kind:"hysteria2",port:$port,proto:"u",hopping:$hopping,
    tls_mode:"acme",alpn:["h3"],
    meta:{password:$password, up_mbps:$up, down_mbps:$down, obfs_type:$obfs_type, obfs_password:$obfs_pw},
    inbound:({type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,
      users:[{password:$password}]}
      | if $up > 0 then .up_mbps=$up else . end
      | if $down > 0 then .down_mbps=$down else . end
      | if $obfs_type != "" then .obfs={type:$obfs_type, password:$obfs_pw} else . end)}')
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
    vless-reality)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(jq -r .target <<<"$meta")&fp=chrome&pbk=$(jq -r .public_key <<<"$meta")&sid=$(jq -r .short_id <<<"$meta")&type=tcp#$(uri_encode "$name")" ;;
    vless-tls)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$host&fp=chrome&type=tcp#$(uri_encode "$name")" ;;
    hysteria2)
      local obfs_type obfs_pw obfs_str
      obfs_type=$(jq -r '.obfs_type//""' <<<"$meta")
      obfs_pw=$(jq -r '.obfs_password//""' <<<"$meta")
      obfs_str=""
      [ -n "$obfs_type" ] && obfs_str="&obfs=${obfs_type}&obfs-password=$(uri_encode "$obfs_pw")"
      uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port/?sni=$host&alpn=h3${hopping:+&mport=$hopping}${obfs_str}#$(uri_encode "$name")" ;;
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
  local index=0 raw_data old_ifs tcp_list udp_list
  NODE_COUNT=0
  set -- "$NODE_DIR"/*.json
  [ ! -e "$1" ] && { tell "  系统内暂无节点"; return 0; }
  
  tcp_list=$(listening_ports t)
  udp_list=$(listening_ports u)
  
  raw_data=$(jq -r '"\(input_filename)|\(.kind//"-")|\(.port//"-")|\(.name//"-")|\(.proto//"-")"' "$@" 2>/dev/null)
  if [ -n "$raw_data" ]; then
    old_ifs="$IFS"
    IFS="|"
    while read -r file kind port name proto; do
      index=$((index+1))
      eval "NODE_FILE_${index}=\"$file\""
      
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
      eval "PICKED=\"\$NODE_FILE_${index}\""
      return 0
    else
      tell_warn "序号无效，请重新输入"
    fi
  done
}

menu_create_protocol(){
  while :; do
    clear
    tell "${CYAN}========== 创建协议 ==========${PLAIN}"
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
  
  local was_acme old_json
  was_acme=$(jq -r .tls_mode "$PICKED")
  old_json=$(cat "$PICKED")
  
  rm -f "$PICKED"
  
  if apply_config; then
    tell_ok "已删除"
    
    if [ "$was_acme" = "acme" ]; then
      local acme_count=0
      for f in "$NODE_DIR"/*.json; do
        [ "$(jq -r .tls_mode "$f")" = "acme" ] && acme_count=$((acme_count+1))
      done
      if [ "$acme_count" -eq 0 ] && [ -n "$(state_get domain)" ]; then
        out_gap
        if prompt_yes "是否连同域名和证书一起清理"; then
          state_set domain ""
          state_set email ""
          state_set challenge "http"
          rm -rf "$ACME_DIR"/*
          tell_ok "相关配置已清理"
        fi
      fi
    fi
  else
    json_save "$PICKED" "$old_json"
    apply_config_quiet
    tell_warn "删除导致配置异常，已安全回滚"
  fi
  wait_key
}

menu_modify_protocol(){
  local kind value other current_hop up_mbps down_mbps obfs_type obfs_password
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
      tuic) tell "  3. 通讯 UUID"; tell "  4. 连接密码" ;;
      socks) tell "  3. 鉴权密码"; tell "  4. 鉴权账号" ;;
      *) tell "  3. 连接密码" ;;
    esac
    [ "$kind" = vless-reality ] && tell "  5. 握手目标域名"
    [ "$kind" = hysteria2 ] && tell "  6. 端口跳跃机制"
    [ "$kind" = hysteria2 ] && tell "  7. 带宽限制"
    [ "$kind" = hysteria2 ] && tell "  8. 混淆设置"
    tell "  0. 返回"
    tell "${CYAN}==============================${PLAIN}"
    
    case $(prompt "请选择") in
      1)
        value=$(prompt "新识别名称" "$(jq -r .name "$PICKED")"); [ -n "$value" ] || continue
        json_edit "$PICKED" '.name=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      2)
        value=$(prompt_port "$(jq -r .proto "$PICKED")" "$(jq -r .port "$PICKED")") || continue
        json_edit "$PICKED" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" \
          || { tell_warn 失败; wait_key; continue; } ;;
      3)
        if [ "$kind" = vless-reality ] || [ "$kind" = vless-tls ] || [ "$kind" = tuic ]; then
          value=$(prompt "新通讯 UUID (留空自动生成)")
          [ -z "$value" ] && value=$(random_uuid)
          json_edit "$PICKED" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value"
        else
          value=$(prompt "新连接密码 (留空自动生成)")
          [ -z "$value" ] && value=$(random_password)
          json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value"
        fi || { tell_warn 失败; wait_key; continue; } ;;
      4)
        if [ "$kind" = socks ]; then
          value=$(prompt "鉴权账号" "$(jq -r .meta.username "$PICKED")"); [ -n "$value" ] || continue
          json_edit "$PICKED" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value" \
            || { tell_warn 失败; wait_key; continue; }
        elif [ "$kind" = tuic ]; then
          value=$(prompt "新连接密码 (留空自动生成)")
          [ -z "$value" ] && value=$(random_password)
          json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" \
            || { tell_warn 失败; wait_key; continue; }
        else
          tell_warn "输入无效"; sleep 1; continue;
        fi
        ;;
      5)
        [ "$kind" = vless-reality ] || { tell_warn "输入无效"; sleep 1; continue; }
        while :; do
          value=$(prompt "新握手目标域名 (留空取消)")
          [ -n "$value" ] || break
          probe_handshake_target "$value" && break
          prompt_yes "检测异常，强制加载" && break
        done
        [ -n "$value" ] || continue
        json_edit "$PICKED" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v' \
          --arg v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      6)
        [ "$kind" = hysteria2 ] || { tell_warn "输入无效"; sleep 1; continue; }
        current_hop=$(jq -r '.hopping//""' "$PICKED")
        value=$(prompt "跳跃范围 (当前: ${current_hop:-未开启}, 0 关闭)")
        if [ -z "$value" ]; then
          tell_ok "保持不变"; wait_key; continue;
        fi
        if [ "$value" = "0" ]; then
          value=""
        else
          validate_range "$value" || { wait_key; continue; }
          other=$(hopping_node) && [ "$other" != "$PICKED" ] && { tell_warn "已有节点开启跳跃"; wait_key; continue; }
        fi
        json_edit "$PICKED" '.hopping=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; } ;;
      7)
        [ "$kind" = hysteria2 ] || { tell_warn "输入无效"; sleep 1; continue; }
        while :; do
          up_mbps=$(prompt "上行带宽 (Mbps, 0为关闭限制)" "$(jq -r '.meta.up_mbps//0' "$PICKED")")
          [[ $up_mbps =~ ^[0-9]+$ ]] && break || tell_warn "输入无效，请重新输入"
        done
        while :; do
          down_mbps=$(prompt "下行带宽 (Mbps, 0为关闭限制)" "$(jq -r '.meta.down_mbps//0' "$PICKED")")
          [[ $down_mbps =~ ^[0-9]+$ ]] && break || tell_warn "输入无效，请重新输入"
        done
        json_edit "$PICKED" '.meta.up_mbps=$up | .meta.down_mbps=$down |
          if $up > 0 then .inbound.up_mbps=$up else del(.inbound.up_mbps) end |
          if $down > 0 then .inbound.down_mbps=$down else del(.inbound.down_mbps) end' \
          --argjson up "$up_mbps" --argjson down "$down_mbps" || { tell_warn 失败; wait_key; continue; } ;;
      8)
        [ "$kind" = hysteria2 ] || { tell_warn "输入无效"; sleep 1; continue; }
        if prompt_yes "是否配置并开启协议混淆 (选择 N 则关闭混淆)"; then
          tell "  1. Salamander"
          tell "  2. Gecko"
          while :; do
            case $(prompt "请选择混淆算法 (当前: $(jq -r '.meta.obfs_type//""' "$PICKED"))" 2) in
              1) obfs_type="salamander"; break ;;
              2) obfs_type="gecko"; break ;;
              *) tell_warn "输入无效"; sleep 1 ;;
            esac
          done
          obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$(jq -r '.meta.obfs_password//""' "$PICKED")")
          [ -z "$obfs_password" ] && obfs_password=$(jq -r '.meta.password' "$PICKED")
          
          json_edit "$PICKED" '.meta.obfs_type=$t | .meta.obfs_password=$p | .inbound.obfs={type:$t, password:$p}' \
            --arg t "$obfs_type" --arg p "$obfs_password" || { tell_warn 失败; wait_key; continue; }
        else
          json_edit "$PICKED" '.meta.obfs_type="" | .meta.obfs_password="" | del(.inbound.obfs)' || { tell_warn 失败; wait_key; continue; }
        fi
        ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1; continue ;;
    esac
    
    if apply_config; then
      tell_ok "已生效"; out_gap; render_share_uri "$PICKED"
    fi
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
  systemctl is-active --quiet sing-box || tell_warn "服务离线，无法自动续期"
}

menu_server_info(){
  local file port proto status count=0 tcp_list udp_list
  tcp_list=$(listening_ports t); udp_list=$(listening_ports u)
  clear
  tell "${CYAN}========== 服务端信息 ==========${PLAIN}"
  systemctl is-active --quiet sing-box && tell_ok "singbox: 运行中" || tell_warn "singbox: 未运行"
  
  for file in "$NODE_DIR"/*.json; do
    count=$((count+1))
    port=$(jq -r .port "$file"); proto=$(jq -r .proto "$file")
    if [ "$proto" = u ]; then
      grep -qx "$port" <<<"$udp_list" && status="${GREEN}正常监听${PLAIN}" || status="${RED}未在监听${PLAIN}"
    else
      grep -qx "$port" <<<"$tcp_list" && status="${GREEN}正常监听${PLAIN}" || status="${RED}未在监听${PLAIN}"
    fi
    tell ""
    tell "── $(jq -r .name "$file") [$(jq -r .kind "$file")] | 端口 $port $status"
    render_share_uri "$file"
  done
  [ "$count" = 0 ] && tell "\n  暂无节点"
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
  
  if [ "$new_domain" != "$old_domain" ]; then
    rm -rf "$ACME_DIR"/*
  fi
  
  if apply_config; then
    menu_server_info
  else
    state_set domain "$old_domain"
    state_set email "$old_email"
    state_set challenge "$old_challenge"
    apply_config_quiet
    tell_warn "部署异常已回滚"
    wait_key
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
         systemctl restart sing-box >/dev/null 2>&1
         if systemctl is-active --quiet sing-box; then
           sync_bypass_rules
           sync_hopping_rules
           tell_ok "已重启"
         else
           tell_warn "singbox 未运行"
           tell_warn "重启失败"
         fi
         wait_key
         ;;
      7) if systemctl stop sing-box; then tell_ok "已停止"; else tell_warn "操作异常"; fi; wait_key ;;
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
  [[ $URI_PORT =~ ^[0-9]+$ ]] && [ "$URI_PORT" -ge 1 ] && [ "$URI_PORT" -le 65535 ] || URI_PORT=443
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
              '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound") ;;
        grpc) outbound=$(jq --arg svc "$service" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
        httpupgrade) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" \
              '.transport={type:"httpupgrade",path:$path,host:$host}' <<<"$outbound") ;;
      esac ;;
    hysteria2|hy2)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" \
        '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      
      obfs_pw=$(query_value obfs-password)
      obfs_type=$(query_value obfs)
      
      if [ -n "$obfs_pw" ]; then
        [ -z "$obfs_type" ] && obfs_type="salamander"
        outbound=$(jq --arg type "$obfs_type" --arg pw "$obfs_pw" \
          '.obfs={type:$type,password:$pw}' <<<"$outbound")
      fi

      hop_range=$(query_value mport); [ -z "$hop_range" ] && hop_range=$(query_value ports)
      [ -n "$hop_range" ] && outbound=$(jq --arg r "${hop_range//-/:}" \
        '.server_ports=[$r]|del(.server_port)|.hop_interval="30s"' <<<"$outbound") ;;
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
  local name uri tag outbound probe ipv4 ipv6 domain port ip resolved_hosts
  clear; tell "${CYAN}========== 添加节点 ==========${PLAIN}"
  name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return
  uri=$(prompt "节点链接"); [ -n "$uri" ] || return
  parse_uri "$uri"
  ipv4=$(local_ipv4); ipv6=$(local_ipv6); domain=$(state_get domain)
  resolved_hosts=$(resolve_addresses "$URI_HOST")
  for port in $(node_ports); do
    if [ "$URI_PORT" = "$port" ]; then
      if [ "$URI_HOST" = "127.0.0.1" ] || [ "$URI_HOST" = "localhost" ] || [ "$URI_HOST" = "::1" ]; then
        tell_warn "禁止自环接入"; wait_key; return
      fi
      for ip in $resolved_hosts; do
        if [ "$ip" = "$ipv4" ] || [ "$ip" = "$ipv6" ]; then
          tell_warn "禁止自环接入"; wait_key; return
        fi
      done
      if [ -n "$domain" ] && [ "$URI_HOST" = "$domain" ]; then
        tell_warn "禁止自环接入"; wait_key; return
      fi
    fi
  done
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag") || { tell_warn "无法解析"; wait_key; return; }
  probe=$(mktemp)
  TMP_FILES="$TMP_FILES $probe"
  jq -n --argjson ob "$outbound" \
    '{log:{level:"error"},
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
  wait_key
}

list_peers(){
  local current=$(state_get exit)
  local title=${1:-节点选择}
  PEER_COUNT=0
  set -- "$PEER_DIR"/*.json
  [ ! -e "$1" ] && { clear; tell "${CYAN}========== $title ==========${PLAIN}"; tell "  暂无外部节点"; return 0; }
  
  local tmp_dir
  tmp_dir=$(mktemp -d)
  
  local idx=0 raw_data old_ifs test_pids=""
  raw_data=$(jq -r '"\(input_filename)|\(.tag//"-")|\(.outbound.type//"-")|\(.name//"-")|\(.outbound.server_port // (if .outbound.server_ports then (.outbound.server_ports[0]|gsub(":";"-")) else null end) // .outbound.listen_port // "-")|\(.outbound.server//"-")"' "$@" 2>/dev/null)
  
  if [ -n "$raw_data" ]; then
    old_ifs="$IFS"
    IFS="|"
    while read -r file tag type name port host; do
      idx=$((idx+1))
      eval "PEER_FILE_${idx}=\"$file\""; eval "PEER_TAG_${idx}=\"$tag\""
      eval "PEER_TYPE_${idx}=\"$type\""; eval "PEER_NAME_${idx}=\"$name\""; eval "PEER_PORT_${idx}=\"$port\""
      
      (
        local ms="" ping_res iface
        iface=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
        if [[ "$host" =~ : ]]; then
          if [ -n "$iface" ]; then
            ping_res=$(timeout 1 ping6 -I "$iface" -c 1 -W 1 -m 255 "$host" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{print $5}')
          else
            ping_res=$(timeout 1 ping6 -c 1 -W 1 -m 255 "$host" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{print $5}')
          fi
        else
          if [ -n "$iface" ]; then
            ping_res=$(timeout 1 ping -I "$iface" -c 1 -W 1 -m 255 "$host" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{print $5}')
          else
            ping_res=$(timeout 1 ping -c 1 -W 1 -m 255 "$host" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{print $5}')
          fi
        fi

        if [ -n "$ping_res" ]; then
          ms=$(awk "BEGIN {print int($ping_res)}")
        else
          ms="fail"
        fi
        echo "$ms" > "$tmp_dir/res_$idx"
      ) &
      test_pids="$test_pids $!"
    done <<<"$raw_data"
    IFS="$old_ifs"
  fi
  PEER_COUNT=$idx
  
  [ -n "$test_pids" ] && wait $test_pids 2>/dev/null
  
  clear
  tell "${CYAN}========== $title ==========${PLAIN}"
  
  for i in $(seq 1 $PEER_COUNT); do
    local tag type name port mark ms color status_text
    eval "tag=\"\$PEER_TAG_${i}\""; eval "type=\"\$PEER_TYPE_${i}\""
    eval "name=\"\$PEER_NAME_${i}\""; eval "port=\"\$PEER_PORT_${i}\""
    
    ms=$(cat "$tmp_dir/res_$i" 2>/dev/null)
    
    if [ "$ms" = "fail" ] || [ -z "$ms" ]; then
      color="$RED"; status_text="[不可用]"
    elif [ "$ms" -le 150 ]; then
      color="$GREEN"; status_text="[${ms}ms]"
    else
      color="$YELLOW"; status_text="[${ms}ms]"
    fi
    
        [ "$tag" = "$current" ] && mark=" ${CYAN}<=当前${color}" || mark=""

    
        printf "  %b%2d. [%-7s] %s:%s %b %s%b\n" "$color" "$i" "$type" "$name" "$port" "$mark" "$status_text" "$PLAIN"

  done
  rm -rf "$tmp_dir"
  return 0
}

select_peer(){
  local title=${1:-节点选择}
  local index
  while :; do
    list_peers "$title"
    [ "$PEER_COUNT" = 0 ] && { wait_key; return 1; }
    
    tell "  0. 返回"
    index=$(prompt "请选择 [回车刷新]")
    
    [ -z "$index" ] && continue 
    
    [ "$index" = 0 ] && return 1
    if [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$PEER_COUNT" ]; then
      eval "PICKED=\"\$PEER_FILE_${index}\""
      return 0
    else
      tell_warn "序号无效，请重新输入"
      sleep 1
    fi
  done
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
  state_set exit "$tag"
  if apply_config; then
    arm_watchdog
    tell_ok "已接管: $(jq -r .name "$PICKED")"
  else
    state_set exit "$previous"
    apply_config_quiet
    tell_warn "切换失败已回滚"
  fi
  wait_key
}

peer_delete(){
  clear; tell "${CYAN}========== 删除节点 ==========${PLAIN}"
  select_peer || return
  
  local old_json previous_exit
  old_json=$(cat "$PICKED")
  previous_exit=$(state_get exit)
  
  if [ "$(jq -r .tag "$PICKED")" = "$previous_exit" ]; then
    stop_watchdog
    state_set exit direct
    rm -f "$PICKED"
    if apply_config; then
      tell_ok "已删除当前生效节点，已恢复直连"
    else
      json_save "$PICKED" "$old_json"
      state_set exit "$previous_exit"
      apply_config_quiet
      tell_warn "删除导致配置异常，节点与网络出口已安全回滚"
    fi
  else
    rm -f "$PICKED"
    if apply_config; then
      tell_ok "已删除节点"
    else
      json_save "$PICKED" "$old_json"
      apply_config_quiet
      tell_warn "删除导致配置异常，已安全回滚"
    fi
  fi
  wait_key
}

peer_stop(){
  clear
  stop_watchdog
  state_set exit direct
  if apply_config; then
    tell_ok "已恢复直连"
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
      [ -f "$PEER_DIR/$exit_node.json" ] && proxy_name="$(jq -r .outbound.type "$PEER_DIR/$exit_node.json" 2>/dev/null)"
      proxy_name="${proxy_name:-未知}"
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
  local peer_ip=$1
  
  [ -d "/sys/class/net/$WG_IF" ] || { echo down; return; }
  
  if command -v ping >/dev/null 2>&1 && ping -c1 -W3 "$peer_ip" >/dev/null 2>&1; then 
    echo up; return; 
  fi
  
  if curl --interface "$WG_IF" -s -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL"; then
    echo up; return;
  fi
  
  echo down
}

render_wg_info(){
  local file=$1 role
  role=$(jq -r .role "$file")
  tell "${CYAN}========== 隧道状态信息 ==========${PLAIN}"
  if [ "$role" = server ]; then
    tell "  角色: 服务端"
  else
    tell "  角色: 客户端"
  fi
  tell "  引擎: $([ "$(jq -r .enabled "$file")" = true ] && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${RED}已挂起${PLAIN}")"
  echo ""
  tell "  本地公钥: $(jq -r .public_key "$file")"
  tell "  本地 IP:  $(jq -r '.address|join(", ")' "$file")"
  [ "$role" = server ] && tell "  监听端口: $(jq -r .listen_port "$file")"
  [ "$role" = client ] && tell "  远端地址: $(jq -r .peer_host "$file"):$(jq -r .peer_port "$file")"
  tell "  远端公钥: $(jq -r '.peer_public_key|if .=="" then "<待补录>" else . end' "$file")"
  tell "  远端 IP:  $(jq -r .peer_ip "$file")"
  
  if [ "$role" = client ]; then
    if [ "$(jq -r .enabled "$file")" = true ]; then
      if [ "$(wg_tunnel_state "$(jq -r .peer_ip "$file")")" = up ]; then
        tell_ok "连接成功"
      else
        tell_warn "连接中断"
      fi
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
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] || { tell_warn "密钥生成失败"; wait_key; return; }
  
  while :; do
    prefix=$(prompt "自定义网段" "10.7.0")
    [[ $prefix =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
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
      endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1408,
        address:[$a4,$a6],private_key:$private,listen_port:$port,
        peers:[{public_key:$peer_key,allowed_ips:[($peer4+"/32"),($peer6+"/128")]}]}}')
  else
    address4="$prefix.2/32"; address6="fd00:7::2/128"; peer_ip4="$prefix.1"
    peer_host=$(prompt "服务端 IP" "1.1.1.1")
    peer_port=$(prompt "服务端监听端口" "$(random_port)")
    peer_key=$(prompt "服务端公钥")
    
    [[ $peer_port =~ ^[0-9]+$ ]] || { tell_warn "端口无效"; wait_key; return; }
    
    body=$(jq -n --arg private "$private" --arg public "$public" --arg a4 "$address4" --arg a6 "$address6" \
          --arg host "$peer_host" --argjson port "$peer_port" --arg peer_key "$peer_key" \
          --arg peer4 "$peer_ip4" --arg iface "$WG_IF" '
     {role:"client",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:0,
      peer_public_key:$peer_key,peer_ip:$peer4,peer_host:$host,peer_port:$port,
      endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1408,
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
    if [ "$previous" = wireguard ]; then
      state_set exit direct
      stop_watchdog
    fi
    if apply_config; then
      tell_ok "已关闭隧道"
    fi
  else
    [ -n "$(jq -r .peer_public_key "$WG_CONF")" ] || { tell_warn "缺少公钥"; wait_key; return; }
    if [ "$role" = client ] && [ "$previous" != direct ]; then
      prompt_yes "隧道将接管网络，确定" || return
    fi
    json_edit "$WG_CONF" '.enabled=true'
    if [ "$role" = client ]; then state_set exit wireguard; fi
    if apply_config; then
      if [ "$role" = client ]; then arm_watchdog; fi
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
  local current latest script_url script_tmp
  clear
  tell "正在检测 sing-box 内核更新..."
  current=$(core_version)
  latest=$(remote_version)
  tell "本地版本: ${current:-未知}"
  tell "最新版本: ${latest:-获取失败}"

  if [ -z "$latest" ]; then
    tell_warn "无法获取最新版本，请检查网络或 GitHub 访问"
  elif [ -z "$current" ]; then
    if prompt_yes "无法读取当前内核版本，是否重新下载并安装最新版 v$latest"; then
      systemctl stop sing-box >/dev/null 2>&1
      if install_core; then
        if apply_config; then
          tell_ok "内核重新安装完成"
        else
          tell_warn "内核已下载，但配置应用失败"
        fi
      else
        apply_config_quiet
        tell_warn "内核重新安装失败"
      fi
    fi
  elif [ "$current" != "$latest" ]; then
    if prompt_yes "发现新版本 v$latest，是否立即更新"; then
      systemctl stop sing-box >/dev/null 2>&1
      if install_core; then
        if apply_config; then
          tell_ok "内核更新完成"
        else
          tell_warn "内核更新完成，但配置应用失败"
        fi
      else
        apply_config_quiet
        tell_warn "内核更新失败"
      fi
    fi
  else
    tell_ok "内核已是最新版本"
  fi
  out_gap

  tell "正在检测 s 脚本更新..."
  script_url="https://raw.githubusercontent.com/88860/-/main/s.sh"
  script_tmp=$(mktemp) || { tell_warn "无法创建临时文件"; wait_key; return; }
  TMP_FILES="$TMP_FILES $script_tmp"

  if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$script_url" -o "$script_tmp" 2>/dev/null; then
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$script_url" -o "$script_tmp" 2>/dev/null; then
      tell_warn "脚本下载失败，请检查 GitHub 访问"
      wait_key
      return
    fi
  fi

  if [ ! -s "$script_tmp" ]; then
    tell_warn "下载的脚本为空，放弃更新"
  elif bash -n "$script_tmp" 2>/dev/null; then
    if cmp -s "$script_tmp" "$SELF"; then
      tell_ok "脚本已是最新版本"
    else
      if install -m700 "$script_tmp" "$SELF"; then
        tell_ok "脚本更新成功，请重新运行本脚本生效"
        exit 0
      else
        tell_warn "脚本写入失败，原脚本未修改"
      fi
    fi
  else
    tell_warn "下载的脚本存在语法错误，放弃更新"
  fi
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
  
  rm -f "$SERVICE_UNIT" "$DROPIN"
  rm -f /etc/systemd/system/sbm-watchdog.service
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
    tell "脚本曾安装过: [ ${packages[*]} ]"
    if prompt_yes "是否剥离依赖"; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${packages[@]}" >/dev/null 2>&1
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
    local up=$(uptime -p 2>/dev/null | sed 's/up //;s/days/天/;s/day/天/;s/hours/小时/;s/hour/小时/;s/minutes/分钟/;s/minute/分钟/')
    local sb_ver=$(core_version)
    local sb_asset=$(state_get asset)
    local s_state="${RED}未运行${PLAIN}"
    systemctl is-active --quiet sing-box && s_state="${GREEN}正常运行${PLAIN}"
    
    tell "  系统版本: ${os}"
    tell "  内核架构: ${core} (${arch})"
    tell "  内存状态: ${mem}"
    tell "  运行时间: ${up:-未知}"
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
    echo -e "  ${CYAN}首次运行，安装 sing-box...${PLAIN}"
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
  tell "${CYAN}             s管理              ${PLAIN}"
  tell "${CYAN}      [ 仅适配 Systemd 版 ]      ${PLAIN}"
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
