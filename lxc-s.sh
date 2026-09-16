#!/bin/sh
export LC_ALL=C
export GOMEMLIMIT=15MiB
export GOGC=20

RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
PURPLE='\033[35m'
BLUE='\033[34m'
PLAIN='\033[0m'

clear(){ printf '\033[H\033[2J\033[3J'; }

SB_DIR=/etc/sing-box
CONFIG=$SB_DIR/config.json
SBM_DIR=/etc/sbm

mkdir -p "$SBM_DIR/tmp"
export TMPDIR="$SBM_DIR/tmp"

NODE_DIR=$SBM_DIR/nodes
PEER_DIR=$SBM_DIR/peers
WG_DIR=$SBM_DIR/wg
WG_CONF=$WG_DIR/local.json
STATE=$SBM_DIR/state.json
ACME_DIR=$SBM_DIR/acme
PKG_LOG=$SBM_DIR/apk_installed
SELF=$(readlink -f "$0" 2>/dev/null || echo "$PWD/${0#./}")
SHORTCUT=/usr/local/bin/s
CORE=/usr/local/bin/sing-box
SERVICE_FILE=/etc/init.d/sing-box
PROBE_URL=http://cp.cloudflare.com/generate_204
WG_IF=sbmwg
CERT_TAG=acme-cert
WATCHDOG_PID=/var/run/sbm_watchdog.pid

NODE_COUNT=0
PEER_COUNT=0
PICKED=""
CORE_VERSION=""
CORE_TAGS=""
TMP_FILES=""

IP_INFO_IP=""
IP_INFO_C=""
IP_INFO_ASN=""
IP_INFO_NAME=""

[ "$(id -u)" = 0 ] || { printf '%b[×] 权限不足: 请使用 root 用户运行%b\n' "${RED}" "${PLAIN}"; exit 1; }

cleanup_tmp() {
  [ -n "$TMP_FILES" ] && rm -rf $TMP_FILES
}
trap cleanup_tmp EXIT INT TERM

read_line(){
  local value
  if [ -c /dev/tty ]; then IFS= read -r value </dev/tty || value=""
  else IFS= read -r value || value=""; fi
  value=$(printf '%s' "$value" | tr -d '\r')
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
tell_gap(){ echo ""; }
out(){ printf '  %b\n' "$*"; }
out_gap(){ echo ""; }
out_ok(){ printf '  %b[√] %b%b\n' "${GREEN}" "$*" "${PLAIN}"; }
out_warn(){ printf '  %b[×] %b%b\n' "${RED}" "$*" "${PLAIN}"; }

uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }

uri_decode(){
  echo "$1" | awk 'BEGIN{for(i=0;i<16;i++){hex[sprintf("%X",i)]=i;hex[sprintf("%x",i)]=i}}
  {
    gsub(/\+/," "); res=""; i=1;
    while(i<=length($0)){
      c=substr($0,i,1);
      if(c=="%" && i+2<=length($0)){
        res=res sprintf("%c",hex[substr($0,i+1,1)]*16+hex[substr($0,i+2,1)]); i+=3;
      }else{
        res=res c; i++;
      }
    }
    print res
  }' 2>/dev/null || echo "$1"
}

slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16; }
random_uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || (tr -dc 'a-f0-9' </dev/urandom | head -c 32 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'); }

random_port(){
  awk 'BEGIN{srand(); print int(rand()*40001)+20000}'
}

validate_port(){
  local port=$1 proto=$2 allow=${3:-}
  case "$port" in
    ''|*[!0-9]*) tell_warn "端口格式无效"; return 1 ;;
  esac
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || { tell_warn "端口格式无效"; return 1; }
  [ "$port" = 80 ] && { tell_warn "端口 80 已保留给证书签发"; return 1; }
  [ "$port" = 443 ] && [ "$(state_get challenge)" = alpn ] && { tell_warn "端口 443 已保留给 ALPN 证书签发"; return 1; }
  [ "$port" = "$allow" ] && return 0
  grep -qx "$port" <<EOF
$(protected_ports)
EOF
  [ $? -eq 0 ] && { tell_warn "已被节点或 SSH 占用"; return 1; }
  grep -qx "$port" <<EOF
$(listening_ports "$proto")
EOF
  [ $? -eq 0 ] && { tell_warn "端口被占用"; return 1; }
  return 0
}

prompt_port(){
  local proto=$1 current=$2 port def_port
  while :; do
    def_port=${current:-$(random_port)}
    port=$(prompt "监听端口" "$def_port")
    if validate_port "$port" "$proto" "$current"; then
      printf '%s' "$port"
      return 0
    fi
  done
}

version_ge(){
  echo | awk -v v1="$1" -v v2="$2" 'BEGIN {
    split(v1, a, "."); split(v2, b, ".");
    for (i=1; i<=3; i++) {
      if (a[i]+0 > b[i]+0) exit 0;
      if (a[i]+0 < b[i]+0) exit 1;
    }
    exit 0;
  }'
}

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
  mkdir -p "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box /usr/local/bin
  chmod 700 "$SBM_DIR" "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box
  [ -f "$STATE" ] || printf '%s\n' '{"exit":"direct","domain":"","email":"","challenge":"http","asset":""}' | json_write "$STATE"
  [ -f "$PKG_LOG" ] || : >"$PKG_LOG"
}

state_get(){ jq -r --arg k "$1" '.[$k]//""' "$STATE" 2>/dev/null; }
state_set(){ json_edit "$STATE" '.[$k]=$v' --arg k "$1" --arg v "$2"; }

check_dependencies(){
  local to_install=""
  command -v jq >/dev/null 2>&1 || to_install="$to_install jq"
  [ -f /etc/ssl/certs/ca-certificates.crt ] || to_install="$to_install ca-certificates"
  command -v openssl >/dev/null 2>&1 || to_install="$to_install openssl"

  if [ -n "$to_install" ]; then
    for pkg in $to_install; do
      apk add --quiet --no-cache "$pkg" >/dev/null 2>&1 || { tell_warn "组件 $pkg 安装失败，请检查网络"; exit 1; }
      grep -qx "$pkg" "$PKG_LOG" 2>/dev/null || echo "$pkg" >>"$PKG_LOG"
    done
    rm -rf /var/cache/apk/* 2>/dev/null
    sync
    sleep 1
  fi
  return 0
}

core_version(){
  if [ -z "$CORE_VERSION" ] && [ -x "$CORE" ]; then
    CORE_VERSION=$(
      { "$CORE" version 2>/dev/null; } 2>/dev/null |
        awk '/version/{print $3; exit}'
    )
  fi
  printf '%s' "$CORE_VERSION"
}

core_tags(){
  if [ -z "$CORE_TAGS" ] && [ -x "$CORE" ]; then
    CORE_TAGS=$(
      { "$CORE" version 2>/dev/null; } 2>/dev/null |
        sed -n 's/^Tags: //p'
    )
  fi
  printf '%s' "$CORE_TAGS"
}

has_acme_support(){ case "$(core_tags)" in *with_acme*) return 0 ;; *) return 1 ;; esac; }
use_cert_provider(){ version_ge "$(core_version)" 1.14.0; }
core_cache_reset(){ CORE_VERSION=""; CORE_TAGS=""; }

acme_options(){
  local domain=$1 body
  body=$(jq -n --arg d "$domain" --arg e "$(state_get email)" --arg dir "$ACME_DIR" \
    '{domain:[$d],email:$e,data_directory:$dir}') || return 1
  use_cert_provider && body=$(echo "$body" | jq '.key_type="p256"') || true
  case $(state_get challenge) in
    alpn)
      body=$(echo "$body" | jq '.disable_http_challenge=true') || return 1 ;;
    dns_cloudflare)
      body=$(echo "$body" | jq --arg t "$(state_get cf_token)" \
        '.dns01_challenge={provider:"cloudflare",api_token:$t}') || return 1 ;;
    dns_alidns)
      body=$(echo "$body" | jq --arg k "$(state_get ali_key)" --arg s "$(state_get ali_secret)" \
        '.dns01_challenge={provider:"alidns",access_key_id:$k,access_key_secret:$s}') || return 1 ;;
    dns_acmedns)
      body=$(echo "$body" | jq --arg u "$(state_get acmedns_user)" --arg p "$(state_get acmedns_pass)" \
        --arg s "$(state_get acmedns_sub)" --arg r "$(state_get acmedns_url)" \
        '.dns01_challenge={provider:"acmedns",username:$u,password:$p,subdomain:$s,server_url:$r}') || return 1 ;;
    *)
      body=$(echo "$body" | jq '.disable_tls_alpn_challenge=true') || return 1 ;;
  esac
  printf '%s' "$body"
}

remote_version(){
  wget -qO- -T 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//'
}

local_ipv4(){ wget -qO- -T 5 http://ipv4.icanhazip.com 2>/dev/null | tr -d '\n '; }
local_ipv6(){ wget -qO- -T 5 http://ipv6.icanhazip.com 2>/dev/null | tr -d '\n '; }

resolve_addresses(){
  if command -v getent >/dev/null 2>&1; then
    { getent ahostsv4 "$1"; getent ahostsv6 "$1"; getent hosts "$1"; } 2>/dev/null | awk '{print $1}' | sort -u
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$1" 2>/dev/null | awk '/^Name:/{f=1} f && /^Address/{print $NF}' | sort -u
  fi
}

install_core(){
  local version arch url success=0 tmpdir

  version=$(remote_version)
  [ -n "$version" ] || { tell_warn "获取版本信息失败，请检查网络"; return 1; }

  case $(uname -m) in
    x86_64|amd64) arch="linux-amd64-musl" ;;
    aarch64|arm64) arch="linux-arm64-musl" ;;
    armv7l|armv8l) arch="linux-armv7-musl" ;;
    armv6l) arch="linux-armv6" ;;
    i386|i686) arch="linux-386-musl" ;;
    *) tell_warn "未找到匹配架构的安装包: $(uname -m)"; return 1 ;;
  esac

  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-${arch}.tar.gz"

  rc-service sing-box stop >/dev/null 2>&1 || true
  sync; sleep 1

  tmpdir=$(mktemp -d)
  TMP_FILES="$TMP_FILES $tmpdir"

  if wget -qO- -T 120 "$url" 2>/dev/null | tar -xzf - -C "$tmpdir" 2>/dev/null; then
    if [ -f "$tmpdir/sing-box-${version}-${arch}/sing-box" ]; then
      rm -f "$CORE"
      install -m755 "$tmpdir/sing-box-${version}-${arch}/sing-box" "$CORE"
      if "$CORE" version >/dev/null 2>&1; then
        core_cache_reset
        if ! state_set asset "$arch"; then
          tell_warn "内核资产状态写入失败"
          return 1
        fi
        tell_ok "sing-box 内核已安装: $(core_version) [$arch]"
        success=1
        sync
      else
        tell_warn "二进制执行异常，请检查架构"
      fi
    else
      tell_warn "安装包内容不符"
    fi
  else
    tell_warn "安装包下载或解压失败"
  fi

  rm -rf "$tmpdir"
  [ "$success" = 1 ] && return 0 || return 1
}

write_service(){
  cat >"$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box universal proxy platform"

supervisor="supervise-daemon"
command="/usr/bin/env"
command_args="GOMEMLIMIT=15MiB GOGC=20 $CORE -D /var/lib/sing-box -c $CONFIG run"
output_log="/dev/null"
error_log="/dev/null"

respawn_delay=2
respawn_max=0

depend() {
    need net-online
    after firewall
}

start_post() {
    $SHORTCUT --sync >/dev/null 2>&1 || true
}
EOF
  chmod +x "$SERVICE_FILE"
  rc-update add sing-box default >/dev/null 2>&1
}

ssh_ports(){
  {
    [ -n "$SSH_CONNECTION" ] && echo "$SSH_CONNECTION" | awk '{print $4}'
    netstat -tlnp 2>/dev/null | awk 'NR>2 && /sshd/{print $4}' | awk -F':' '{print $NF}'
    [ -f /etc/ssh/sshd_config ] && sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config 2>/dev/null
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -e "$f" ] && sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' "$f" 2>/dev/null
    done
    sshd -T 2>/dev/null | awk '/^port /{print $2}'
  } | grep -E '^[1-9][0-9]*$' | sort -un
}

node_ports(){
  set -- "$NODE_DIR"/*.json
  [ -e "$1" ] && jq -r '.port' "$@" 2>/dev/null | grep -E '^[1-9][0-9]*$'
}

wg_listen_port(){ [ -f "$WG_CONF" ] && jq -r '.listen_port//0' "$WG_CONF" | grep -E '^[1-9][0-9]*$'; }
protected_ports(){ { ssh_ports; node_ports; wg_listen_port; } | grep -E '^[1-9][0-9]*$' | sort -un; }

listening_ports(){
  case "$1" in
    t) netstat -tln 2>/dev/null | awk 'NR>2 {print $4}' | awk -F':' '{print $NF}' | grep -E '^[0-9]+$' | sort -u ;;
    u) netstat -uln 2>/dev/null | awk 'NR>2 {print $4}' | awk -F':' '{print $NF}' | grep -E '^[0-9]+$' | sort -u ;;
    *) netstat -tuln 2>/dev/null | awk 'NR>2 {print $4}' | awk -F':' '{print $NF}' | grep -E '^[0-9]+$' | sort -u ;;
  esac
}

probe_handshake_target(){
  local target=$1 result
  command -v openssl >/dev/null 2>&1 || { tell_warn "openssl 未安装，无法验证"; return 1; }
  result=$(echo | timeout 10 openssl s_client -connect "$target:443" -servername "$target" -alpn h2 -tls1_3 2>/dev/null)
  echo "$result" | grep -q "TLSv1.3" || { tell_warn "不支持 TLS 1.3 协议"; return 1; }
  echo "$result" | grep -q "ALPN protocol: h2" || { tell_warn "不支持 HTTP/2 协议"; return 1; }
  echo "$result" | grep -qi "X25519" || { tell_warn "未检测到 X25519 特性"; return 1; }
  tell_ok "握手目标验证通过"; return 0
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
  local file=$1 content=$2 was_active=0
  rc-service sing-box status >/dev/null 2>&1 && was_active=1
  json_save "$file" "$content" || { tell_warn "数据写入失败"; wait_key; return 1; }
  if apply_config; then
    if [ "$was_active" = 0 ]; then
      if ! rc-service sing-box start >/dev/null 2>&1 || ! rc-service sing-box status >/dev/null 2>&1; then
        rm -f "$file"
        apply_config_quiet
        tell_warn "协议已写入，但 sing-box 启动失败，已回滚"
        wait_key
        return 1
      fi
    fi
    tell_ok "协议应用成功"; tell_gap; render_share_uri "$file"
  else
    rm -f "$file"; apply_config_quiet; tell_warn "配置应用失败，已回滚"
  fi
  wait_key
}

create_vless_reality(){
  local name port uuid target keypair private public short_id tag body default_sid
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
  name=$(prompt "节点名称" "VLESS-Reality"); port=$(prompt_port t "")
  uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
  while :; do target=$(prompt "握手目标域名" "www.microsoft.com"); probe_handshake_target "$target" && break; prompt_yes "是否强制使用此域名" && break; done
  keypair=$("$CORE" generate reality-keypair); private=$(echo "$keypair" | awk '/PrivateKey/{print $2}'); public=$(echo "$keypair" | awk '/PublicKey/{print $2}')
  [ -n "$private" ] || { tell_warn "密钥生成失败"; wait_key; return; }
  default_sid=$(openssl rand -hex 4)
  while :; do
    short_id=$(prompt "short_id (留空自动生成 8位十六进制)" "$default_sid"); [ -z "$short_id" ] && short_id="$default_sid"
    echo "$short_id" | grep -Eq '^[0-9a-fA-F]{1,8}$' && break; tell_warn "short_id 必须为 1-8 位十六进制字符"
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg target "$target" --arg private "$private" --arg public "$public" --arg sid "$short_id" '
   {tag:$tag,name:$name,kind:"vless-reality",port:$port,proto:"t",hopping:"",tls_mode:"reality",alpn:null,meta:{uuid:$uuid,target:$target,public_key:$public,short_id:$sid},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$target,reality:{enabled:true,handshake:{server:$target,server_port:443},private_key:$private,short_id:[$sid]}}}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vless_tls(){
  local name port uuid tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"; name=$(prompt "节点名称" "VLESS-TLS"); setup_certificate || return; port=$(prompt_port t ""); uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)"); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" '{tag:$tag,name:$name,kind:"vless-tls",port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,meta:{uuid:$uuid},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_hysteria2(){
  local name port password hopping tag body up_mbps down_mbps obfs_type obfs_password bbr_profile min_pkt max_pkt cc_choice
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"; name=$(prompt "节点名称" "Hysteria2"); setup_certificate || return; port=$(prompt_port u ""); password=$(prompt "连接密码 (留空自动生成)" "$(random_password)"); bbr_profile=""; up_mbps=0; down_mbps=0
  tell "  拥塞控制:"; tell "    1. BBR conservative"; tell "    2. BBR standard"; tell "    3. BBR aggressive"; tell "    4. Brutal (需手动设置带宽)"
  while :; do
    cc_choice=$(prompt "请选择拥塞控制" 2); case "$cc_choice" in
      1) bbr_profile=conservative; break;; 2) bbr_profile=standard; break;; 3) bbr_profile=aggressive; break;;
      4) bbr_profile=""; while :; do up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" 0); echo "$up_mbps"|grep -Eq '^[0-9]+$' || { tell_warn "输入无效"; continue; }; down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" 0); echo "$down_mbps"|grep -Eq '^[0-9]+$' || { tell_warn "输入无效"; continue; }; [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ] && break; tell_warn "Brutal 模式至少需要设置一个方向的带宽"; done; break;;
      *) tell_warn "输入无效";; esac
  done
  obfs_type=""; obfs_password=""; min_pkt=""; max_pkt=""
  if prompt_yes "是否配置协议混淆"; then
    tell "  1. Salamander"; tell "  2. Gecko"; while :; do case $(prompt "请选择混淆算法" 2) in 1) obfs_type=salamander; break;; 2) obfs_type=gecko; break;; *) tell_warn "输入无效";; esac; done
    obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$password")
    if [ "$obfs_type" = gecko ]; then min_pkt=$(prompt "最小包大小 (字节, 留空默认512)" 512); max_pkt=$(prompt "最大包大小 (字节, 留空默认1200)" 1200); echo "$min_pkt"|grep -Eq '^[0-9]+$' || min_pkt=512; echo "$max_pkt"|grep -Eq '^[0-9]+$' || max_pkt=1200; fi
  fi
  hopping=""
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" --argjson up "$up_mbps" --argjson down "$down_mbps" --arg obfs_type "$obfs_type" --arg obfs_pw "$obfs_password" --arg bbr "$bbr_profile" --arg min_pkt "$min_pkt" --arg max_pkt "$max_pkt" '
   {tag:$tag,name:$name,kind:"hysteria2",port:$port,proto:"u",hopping:"",tls_mode:"acme",alpn:["h3"],meta:({password:$password,up_mbps:$up,down_mbps:$down,obfs_type:$obfs_type,obfs_password:$obfs_pw}|if $bbr!="" then .bbr_profile=$bbr else . end|if $obfs_type=="gecko" and $min_pkt!="" then .min_packet_size=($min_pkt|tonumber) else . end|if $obfs_type=="gecko" and $max_pkt!="" then .max_packet_size=($max_pkt|tonumber) else . end),inbound:({type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}]}|if $up>0 then .up_mbps=$up else . end|if $down>0 then .down_mbps=$down else . end|if $bbr!="" then .bbr_profile=$bbr else . end|if $obfs_type!="" then .obfs={type:$obfs_type,password:$obfs_pw} else . end|if $obfs_type=="gecko" and $min_pkt!="" then .obfs.min_packet_size=($min_pkt|tonumber) else . end|if $obfs_type=="gecko" and $max_pkt!="" then .obfs.max_packet_size=($max_pkt|tonumber) else . end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_tuic(){
  local name port uuid password tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"; name=$(prompt "节点名称" "TUIC"); setup_certificate || return; port=$(prompt_port u ""); uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)"); password=$(prompt "连接密码 (留空自动生成)" "$(random_password)"); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" '{tag:$tag,name:$name,kind:"tuic",port:$port,proto:"u",hopping:"",tls_mode:"acme",alpn:["h3"],meta:{uuid:$uuid,password:$password},inbound:{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$password}],congestion_control:"bbr"}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

create_trojan(){
  local name port password tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"; name=$(prompt "节点名称" "Trojan"); setup_certificate || return; port=$(prompt_port t ""); password=$(prompt "连接密码 (留空自动生成)" "$(random_password)"); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" '{tag:$tag,name:$name,kind:"trojan",port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,meta:{password:$password},inbound:{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}]}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

create_anytls(){
  local name port password tag body client_meta
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"; name=$(prompt "节点名称" "AnyTLS"); setup_certificate || return; port=$(prompt_port t ""); password=$(prompt "连接密码 (留空自动生成)" "$(random_password)"); client_meta=$(prompt "客户端元数据 (留空则为空)" ""); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" --arg meta "$client_meta" '{tag:$tag,name:$name,kind:"anytls",port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,meta:({password:$password}|if $meta!="" then .client_metadata=$meta else . end),inbound:{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}]}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

create_socks(){
  local name username password port tag body
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"; name=$(prompt "节点名称" "Socks5"); username=$(prompt "鉴权账号" "admin"); password=$(prompt "鉴权密码 (留空自动生成)" "$(random_password)"); [ -n "$username" ] && [ -n "$password" ] || { tell_warn "必填项为空"; wait_key; return; }; port=$(prompt_port t ""); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg username "$username" --arg password "$password" '{tag:$tag,name:$name,kind:"socks",port:$port,proto:"t",hopping:"",tls_mode:"none",alpn:null,meta:{username:$username,password:$password},inbound:{type:"socks",tag:$tag,listen:"::",listen_port:$port,users:[{username:$username,password:$password}]}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

create_snell(){
  local name port psk mode tag body len
  clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"; name=$(prompt "节点名称" "Snell"); port=$(prompt_port t "")
  while :; do psk=$(prompt "预共享密钥 (PSK, 12-255 字节)" "$(random_password)"); len=$(printf '%s' "$psk" | wc -c | tr -d ' '); [ "$len" -ge 12 ] && [ "$len" -le 255 ] && break; tell_warn "PSK 长度必须为 12-255 字节，当前 ${len} 字节"; done
  tell "  1. default"; tell "  2. unshaped"; tell "  3. unsafe-raw"; while :; do case $(prompt "流量整形模式" 1) in 1) mode=default; break;; 2) mode=unshaped; break;; 3) mode=unsafe-raw; break;; *) tell_warn "输入无效";; esac; done
  tag=$(unique_tag "$name" in- "$NODE_DIR"); body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg psk "$psk" --arg mode "$mode" '{tag:$tag,name:$name,kind:"snell",port:$port,proto:"t",hopping:"",tls_mode:"none",alpn:null,meta:{psk:$psk,mode:$mode},inbound:{type:"snell",tag:$tag,listen:"::",listen_port:$port,version:6,psk:$psk,mode:$mode}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

default_iface_v4(){ ip -4 route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
default_iface_v6(){ ip -6 route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
local_bind_v4(){ local i; i=$(default_iface_v4); [ -n "$i" ] && ip -4 addr show dev "$i" scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1; }
local_bind_v6(){ local i; i=$(default_iface_v6); [ -n "$i" ] && ip -6 addr show dev "$i" scope global 2>/dev/null | awk '/inet6 /{print $2}' | grep -v '^fe80:' | cut -d/ -f1 | head -1; }

build_config(){
  local selected domain listen_addr dns_strategy bootstrap_tag bootstrap_server final='direct'
  local inbounds outbounds endpoints dns rules providers='[]' mgmt4 mgmt6 selected_outbound tls_extra='{}'
  selected=$(state_get exit)
  domain=$(state_get domain)
  mgmt4=$(local_bind_v4)
  mgmt6=$(local_bind_v6)
  listen_addr='0.0.0.0'
  dns_strategy='ipv4_only'
  bootstrap_tag='dns-bootstrap-v4'
  bootstrap_server='1.1.1.1'
  if [ -n "$mgmt6" ] && [ -n "$(default_iface_v6)" ]; then
    dns_strategy='prefer_ipv4'
  fi
  inbounds='[]'
  endpoints='[]'
  outbounds='[{"type":"direct","tag":"direct"}]'

  if [ -n "$domain" ]; then
    local acme_json
    acme_json=$(acme_options "$domain") || return 1
    if use_cert_provider; then
      providers=$(jq -n --arg tag "$CERT_TAG" --argjson options "$acme_json" '[$options+{type:"acme",tag:$tag}]') || return 1
      tls_extra=$(jq -n --arg cert "$CERT_TAG" '{certificate_provider:$cert}') || return 1
    else
      tls_extra=$(jq -n --argjson options "$acme_json" '{acme:$options}') || return 1
    fi
  fi

  if find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null | grep -q .; then
    inbounds=$(for f in "$NODE_DIR"/*.json; do [ -e "$f" ] || continue; cat "$f"; done | jq -s \
      --arg domain "$domain" --arg listen "$listen_addr" --argjson extra "$tls_extra" '
      map(
        . as $node |
        $node.inbound
        | .listen=$listen
        | if $node.tls_mode=="acme" then
            .tls=({enabled:true} + (if $domain!="" then {server_name:$domain} else {} end) + (if $node.alpn then {alpn:$node.alpn} else {} end) + $extra)
          else . end
      )
    ') || return 1
    [ -n "$inbounds" ] || inbounds='[]'
  fi

  if [ "$selected" != direct ] && [ "$selected" != wireguard ] && [ -f "$PEER_DIR/$selected.json" ]; then
    selected_outbound=$(jq -c --arg tag "$selected" --arg resolver "$bootstrap_tag" '.outbound | .tag=$tag | .domain_resolver=$resolver' "$PEER_DIR/$selected.json") || return 1
    [ -n "$selected_outbound" ] && [ "$selected_outbound" != null ] || return 1
    outbounds=$(jq -c --argjson ob "$selected_outbound" '.+[$ob]' <<EOF
$outbounds
EOF
) || return 1
    final=$selected
    # No-TUN LXC uses an explicit local mixed proxy. Applications must send business TCP through it.
    inbounds=$(jq -cn --argjson list "$inbounds" '$list + [{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}]') || return 1
  elif [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then
    local wgob wgrole
    wgob=$(jq -c '.endpoint' "$WG_CONF") || return 1
    wgrole=$(jq -r '.role//""' "$WG_CONF")
    [ "$wgrole" = client ] || [ "$wgrole" = server ] || return 1
    endpoints=$(jq -c --argjson ep "$wgob" '.+[$ep]' <<EOF
$endpoints
EOF
) || return 1
    if [ "$wgrole" = client ] && [ "$selected" = wireguard ]; then
      final=wireguard
      inbounds=$(jq -cn --argjson list "$inbounds" '$list + [{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}]') || return 1
    fi
  fi

  outbounds=$(jq -c --arg v4 "$mgmt4" --arg v6 "$mgmt6" 'map(. | if $v4!="" then .inet4_bind_address=$v4 else . end | if $v6!="" then .inet6_bind_address=$v6 else . end)' <<EOF
$outbounds
EOF
) || return 1

  dns=$(jq -n --arg strategy "$dns_strategy" --arg bootstrap "$bootstrap_tag" --arg server "$bootstrap_server" --arg final "$final" --arg v4 "$mgmt4" --arg v6 "$mgmt6" '
    {servers:[
      {type:"https",tag:$bootstrap,server:$server,server_port:443,path:"/dns-query",tls:{server_name:"cloudflare-dns.com"}},
      {type:"https",tag:"dns-remote",server:"cloudflare-dns.com",server_port:443,path:"/dns-query",tls:{server_name:"cloudflare-dns.com"},domain_resolver:{server:$bootstrap,strategy:$strategy}}
    ],strategy:$strategy,final:"dns-remote"}
    | .servers |= map(. | if $v4!="" then .inet4_bind_address=$v4 else . end | if $v6!="" then .inet6_bind_address=$v6 else . end)
    | if $final!="direct" then .servers |= map(if .tag=="dns-remote" then .detour=$final else . end) else . end
  ') || return 1

  rules=$(jq -n --arg final "$final" '[{action:"sniff"},{ip_is_private:true,action:"route",outbound:"direct"},{inbound:["mixed-in"],action:"route",outbound:$final}]') || return 1
  if [ "$final" = direct ]; then
    rules=$(jq -n '[{action:"sniff"},{ip_is_private:true,action:"route",outbound:"direct"}]') || return 1
  elif [ "$final" = wireguard ]; then
    rules=$(jq -n '[{action:"sniff"},{ip_is_private:true,action:"route",outbound:"direct"},{inbound:["mixed-in"],action:"route",outbound:"wireguard"}]') || return 1
  fi
  local target_resolver="$bootstrap_tag"
  [ "$final" = direct ] || [ "$final" = wireguard ] || target_resolver=dns-remote
  jq -n --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" --argjson endpoints "$endpoints" --argjson dns "$dns" --argjson rules "$rules" --argjson providers "$providers" --arg final "$final" --arg resolver "$target_resolver" '
    {log:{level:"warn",timestamp:true},dns:$dns,inbounds:$inbounds,outbounds:$outbounds,endpoints:$endpoints,route:{rules:$rules,final:(if $final=="wireguard" then "direct" else $final end),default_domain_resolver:$resolver}}
    | if ($providers|length)>0 then .certificate_providers=$providers else . end
  '
}

apply_config(){
  local old_exists=0 old_active=0 tmp old_backup
  if [ -f "$CONFIG" ]; then
    old_exists=1
    old_backup=$(mktemp) || return 1
    if ! cp "$CONFIG" "$old_backup"; then
      rm -f "$old_backup"
      return 1
    fi
  fi
  rc-service sing-box status >/dev/null 2>&1 && old_active=1
  tmp=$(mktemp) || { [ -n "$old_backup" ] && rm -f "$old_backup"; return 1; }
  if ! build_config >"$tmp" || ! jq -e . "$tmp" >/dev/null 2>&1 || ! "$CORE" check -c "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp" "$old_backup"
    return 1
  fi
  if ! install -m600 "$tmp" "$CONFIG"; then
    rm -f "$tmp" "$old_backup"
    return 1
  fi
  rm -f "$tmp"
  if [ "$old_active" = 1 ]; then
    if ! rc-service sing-box restart >/dev/null 2>&1 || ! rc-service sing-box status >/dev/null 2>&1; then
      if [ "$old_exists" = 1 ]; then
        install -m600 "$old_backup" "$CONFIG" >/dev/null 2>&1 || true
        rc-service sing-box restart >/dev/null 2>&1 || true
      else
        rm -f "$CONFIG"
        rc-service sing-box restart >/dev/null 2>&1 || true
      fi
      rm -f "$old_backup"
      return 1
    fi
  fi
  rm -f "$old_backup"
  return 0
}
apply_config_quiet(){ apply_config >/dev/null 2>&1; }

sync_proxy_env(){
  local selected
  selected=$(state_get exit)
  if [ "$selected" != direct ] && [ -n "$selected" ] && [ -f "$PEER_DIR/$selected.json" ]; then
    cat > /etc/profile.d/sbm_proxy.sh <<EOF
export http_proxy="http://127.0.0.1:2080"
export https_proxy="http://127.0.0.1:2080"
export HTTP_PROXY="http://127.0.0.1:2080"
export HTTPS_PROXY="http://127.0.0.1:2080"
export all_proxy="socks5h://127.0.0.1:2080"
export ALL_PROXY="socks5h://127.0.0.1:2080"
export NO_PROXY="127.0.0.1,localhost,::1,localaddress,.localdomain.com"
export no_proxy="127.0.0.1,localhost,::1,localaddress,.localdomain.com"
EOF
    chmod 644 /etc/profile.d/sbm_proxy.sh
  else
    rm -f /etc/profile.d/sbm_proxy.sh
  fi
  return 0
}
watchdog_needed(){ [ "$(state_get exit)" != direct ] && rc-service sing-box status >/dev/null 2>&1; }
stop_watchdog(){
  if [ -f "$WATCHDOG_PID" ]; then
    local pid; pid=$(cat "$WATCHDOG_PID" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$WATCHDOG_PID"
  fi
}
run_watchdog(){
  while :; do
    sleep 60 || exit 0
    [ "$(state_get exit)" != direct ] || exit 0
    if ! wget -qO /dev/null -T 8 -e use_proxy=yes -e http_proxy=127.0.0.1:2080 "$PROBE_URL" >/dev/null 2>&1; then
      rc-service sing-box restart >/dev/null 2>&1 || true
    fi
  done
}
arm_watchdog(){
  stop_watchdog
  ( "$SELF" --watchdog >/dev/null 2>&1 & echo $! >"$WATCHDOG_PID" )
}
sync_watchdog(){ if watchdog_needed; then arm_watchdog; else stop_watchdog; fi; }

build_uri(){
  local kind=$1 name=$2 port=$3 meta=$4 hopping=$5 host=$6 uri=""
  case $kind in
    vless-reality) uri="vless://$(echo "$meta"|jq -r .uuid)@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(echo "$meta"|jq -r .target)&fp=chrome&pbk=$(echo "$meta"|jq -r .public_key)&sid=$(echo "$meta"|jq -r .short_id)&spx=%2F&type=tcp#$(uri_encode "$name")";;
    vless-tls) uri="vless://$(echo "$meta"|jq -r .uuid)@$host:$port?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$host&fp=chrome&type=tcp&allowInsecure=0#$(uri_encode "$name")";;
    hysteria2)
      local obfs_type obfs_pw obfs_str bbr bbr_str min_pkt max_pkt pkt_str; obfs_type=$(echo "$meta"|jq -r '.obfs_type//""'); obfs_pw=$(echo "$meta"|jq -r '.obfs_password//""'); bbr=$(echo "$meta"|jq -r '.bbr_profile//""'); min_pkt=$(echo "$meta"|jq -r '.min_packet_size//""'); max_pkt=$(echo "$meta"|jq -r '.max_packet_size//""'); obfs_str=""; [ -n "$obfs_type" ] && obfs_str="&obfs=$obfs_type&obfs-password=$(uri_encode "$obfs_pw")"; bbr_str=""; [ -n "$bbr" ] && bbr_str="&bbr_profile=$(uri_encode "$bbr")"; pkt_str=""; [ -n "$min_pkt" ] && pkt_str="$pkt_str&min_packet_size=$min_pkt"; [ -n "$max_pkt" ] && pkt_str="$pkt_str&max_packet_size=$max_pkt"; uri="hysteria2://$(uri_encode "$(echo "$meta"|jq -r .password)")@$host:$port?sni=$host&alpn=h3${bbr_str}${obfs_str}${pkt_str}#$(uri_encode "$name")";;
    tuic) uri="tuic://$(echo "$meta"|jq -r .uuid):$(uri_encode "$(echo "$meta"|jq -r .password)")@$host:$port?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni=$host&allow_insecure=0#$(uri_encode "$name")";;
    trojan) uri="trojan://$(uri_encode "$(echo "$meta"|jq -r .password)")@$host:$port?security=tls&sni=$host&type=tcp&allowInsecure=0#$(uri_encode "$name")";;
    anytls) uri="anytls://$(uri_encode "$(echo "$meta"|jq -r .password)")@$host:$port?sni=$host&insecure=0"; local a_meta=$(echo "$meta"|jq -r '.client_metadata//""'); [ -n "$a_meta" ] && uri="$uri&client_metadata=$(uri_encode "$a_meta")"; uri="$uri#$(uri_encode "$name")";;
    socks) uri="socks://$(uri_encode "$(echo "$meta"|jq -r .username)"):$(uri_encode "$(echo "$meta"|jq -r .password)")@$host:$port#$(uri_encode "$name")";;
    snell) uri="snell://$(uri_encode "$(echo "$meta"|jq -r .psk)")@$host:$port?version=6&mode=$(echo "$meta"|jq -r '.mode//"default"')#$(uri_encode "$name")";;
  esac
  printf '%s' "$uri"
}


render_share_uri(){
  local file=$1 kind name port meta tls_mode host uri raw_ip found=0
  kind=$(jq -r '.kind // ""' "$file" 2>/dev/null) || return 1
  name=$(jq -r '.name // ""' "$file" 2>/dev/null) || return 1
  port=$(jq -r '.port // ""' "$file" 2>/dev/null) || return 1
  meta=$(jq -c '.meta // {}' "$file" 2>/dev/null) || return 1
  tls_mode=$(jq -r '.tls_mode // ""' "$file" 2>/dev/null) || return 1

  if [ "$tls_mode" = acme ]; then
    host=$(state_get domain)
    [ -n "$host" ] || { tell_warn "未识别到可用的证书域名，生成链接失败"; return 1; }
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "" "$host") || return 1
    [ -n "$uri" ] || { tell_warn "生成分享链接失败"; return 1; }
    tell "${GREEN}$uri${PLAIN}"
    return 0
  fi

  raw_ip=$(env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= wget -qO- -T 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n ')
  if [ -n "$raw_ip" ]; then
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "" "$raw_ip")
    if [ -n "$uri" ]; then tell "${GREEN}$uri${PLAIN}"; found=1; fi
  fi

  raw_ip=$(env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= wget -qO- -T 5 https://ipv6.icanhazip.com 2>/dev/null | tr -d '\r\n ')
  if [ -n "$raw_ip" ]; then
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "" "[$raw_ip]")
    if [ -n "$uri" ]; then tell "${GREEN}$uri${PLAIN}"; found=1; fi
  fi

  [ "$found" = 1 ] || { tell_warn "未识别到本机公网 IP，生成链接失败"; return 1; }
  [ "$kind" = snell ] && tell_warn "Snell 分享链接可能不被所有客户端识别，请手动复制 PSK"
  return 0
}

list_nodes(){
  local index=0 proto raw_data old_ifs tcp_list udp_list
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
        if echo "$udp_list" | grep -qx "$port"; then color="$GREEN"; status_text="[正常]"; else color="$RED"; status_text="[异常]"; fi
      else
        if echo "$tcp_list" | grep -qx "$port"; then color="$GREEN"; status_text="[正常]"; else color="$RED"; status_text="[异常]"; fi
      fi

      printf "  %b%2d. [%-13s] %s:%s %b%s%b\n" "$GREEN" "$index" "$kind" "$name" "$port" "$color" "$status_text" "$PLAIN"
    done <<EOF
$raw_data
EOF
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
    if echo "$index" | grep -Eq '^[0-9]+$' && [ "$index" -ge 1 ] && [ "$index" -le "$NODE_COUNT" ]; then
      eval "PICKED=\"\$NODE_FILE_${index}\""
      return 0
    else
      tell_warn "序号无效，请重新输入"
    fi
  done
}

menu_create_protocol(){
  while :; do
    clear; tell "${CYAN}========== 创建协议 ==========${PLAIN}"
    tell "  1. VLESS REALITY"; tell "  2. VLESS Vision+TCP+TLS"; tell "  3. Hysteria2"; tell "  4. TUIC"; tell "  5. Trojan"; tell "  6. AnyTLS"; tell "  7. SOCKS5"; tell "  8. Snell"; tell "  0. 返回"; tell "${CYAN}==============================${PLAIN}"
    case $(prompt "请选择") in
      1) create_vless_reality; break;; 2) create_vless_tls; break;; 3) create_hysteria2; break;; 4) create_tuic; break;; 5) create_trojan; break;; 6) create_anytls; break;; 7) create_socks; break;; 8) create_snell; break;; 0) return;; *) tell_warn "输入无效，请重新选择"; sleep 1;;
    esac
  done
}

menu_delete_protocol(){
  clear; tell "${CYAN}========== 删除协议 ==========${PLAIN}"
  select_node || return
  prompt_yes "确认删除 $(jq -r .name "$PICKED")" || return

  local was_acme old_json acme_count=0
  was_acme=$(jq -r .tls_mode "$PICKED")
  old_json=$(cat "$PICKED")

  rm -f "$PICKED"

  if apply_config; then
    tell_ok "已删除"
    if [ "$was_acme" = "acme" ]; then
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
  else
    json_save "$PICKED" "$old_json"
    apply_config_quiet
    tell_warn "删除导致配置异常，已安全回滚"
  fi
  wait_key
}

menu_modify_protocol(){
  local kind value other current_hop up_mbps down_mbps obfs_type obfs_password old_json bbr_profile min_pkt max_pkt len
  clear; tell "${CYAN}========== 修改配置 ==========${PLAIN}"; select_node || return
  while :; do
    kind=$(jq -r .kind "$PICKED"); clear; tell "${CYAN}========== $(jq -r .name "$PICKED") [$kind] ==========${PLAIN}"
    tell "  1. 识别名称"; tell "  2. 监听端口"
    case $kind in vless-reality|vless-tls) tell "  3. 通信 UUID";; tuic) tell "  3. 通信 UUID"; tell "  4. 连接密码";; socks) tell "  3. 鉴权密码"; tell "  4. 鉴权账号";; snell) tell "  3. 预共享密钥"; tell "  4. 流量整形模式";; anytls) tell "  3. 连接密码"; tell "  4. 客户端元数据";; hysteria2) tell "  3. 连接密码"; tell "  4. 拥塞控制"; tell "  5. 混淆设置";; *) tell "  3. 连接密码";; esac
    [ "$kind" = vless-reality ] && tell "  5. 握手目标域名"; [ "$kind" = vless-reality ] && tell "  6. short_id"; tell "  0. 返回"; tell "${CYAN}==============================${PLAIN}"; old_json=$(cat "$PICKED")
    case $(prompt "请选择") in
      1) value=$(prompt "新识别名称" "$(jq -r .name "$PICKED")"); [ -n "$value" ] || continue; json_edit "$PICKED" '.name=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; };;
      2) value=$(prompt_port "$(jq -r .proto "$PICKED")" "$(jq -r .port "$PICKED")") || continue; json_edit "$PICKED" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" || { tell_warn 失败; wait_key; continue; };;
      3) if [ "$kind" = vless-reality ] || [ "$kind" = vless-tls ] || [ "$kind" = tuic ]; then value=$(prompt "新通信 UUID (留空自动生成)"); [ -z "$value" ] && value=$(random_uuid); json_edit "$PICKED" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value"; elif [ "$kind" = snell ]; then while :; do value=$(prompt "新 PSK (留空自动生成, 12-255字节)" "$(jq -r .meta.psk "$PICKED")"); [ -z "$value" ] && value=$(random_password); len=$(printf '%s' "$value"|wc -c|tr -d ' '); [ "$len" -ge 12 ] && [ "$len" -le 255 ] && break; tell_warn "PSK 长度必须为 12-255 字节，当前 ${len} 字节"; done; json_edit "$PICKED" '.meta.psk=$v|.inbound.psk=$v' --arg v "$value"; else value=$(prompt "新连接密码 (留空自动生成)"); [ -z "$value" ] && value=$(random_password); json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value"; fi || { tell_warn 失败; wait_key; continue; };;
      4) if [ "$kind" = socks ]; then value=$(prompt "鉴权账号" "$(jq -r .meta.username "$PICKED")"); [ -n "$value" ] || continue; json_edit "$PICKED" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }; elif [ "$kind" = tuic ]; then value=$(prompt "新连接密码 (留空自动生成)"); [ -z "$value" ] && value=$(random_password); json_edit "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }; elif [ "$kind" = snell ]; then tell "  1. default"; tell "  2. unshaped"; tell "  3. unsafe-raw"; while :; do case $(prompt "流量整形模式" 1) in 1) value=default; break;; 2) value=unshaped; break;; 3) value=unsafe-raw; break;; *) tell_warn "输入无效";; esac; done; json_edit "$PICKED" '.meta.mode=$v|.inbound.mode=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }; elif [ "$kind" = anytls ]; then value=$(prompt "客户端元数据 (留空则为空)" "$(jq -r '.meta.client_metadata//""' "$PICKED")"); if [ -n "$value" ]; then json_edit "$PICKED" '.meta.client_metadata=$v' --arg v "$value"; else json_edit "$PICKED" 'del(.meta.client_metadata)'; fi || { tell_warn 失败; wait_key; continue; }; elif [ "$kind" = hysteria2 ]; then tell "  1. BBR conservative"; tell "  2. BBR standard"; tell "  3. BBR aggressive"; tell "  4. Brutal (需手动设置带宽)"; while :; do case $(prompt "请选择拥塞控制" 2) in 1) bbr_profile=conservative; up_mbps=0; down_mbps=0; break;; 2) bbr_profile=standard; up_mbps=0; down_mbps=0; break;; 3) bbr_profile=aggressive; up_mbps=0; down_mbps=0; break;; 4) bbr_profile=""; while :; do up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.up_mbps//0' "$PICKED")"); echo "$up_mbps"|grep -Eq '^[0-9]+$' || { tell_warn "输入无效"; continue; }; down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.down_mbps//0' "$PICKED")"); echo "$down_mbps"|grep -Eq '^[0-9]+$' || { tell_warn "输入无效"; continue; }; [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ] && break; tell_warn "Brutal 模式至少需要设置一个方向的带宽"; done; break;; *) tell_warn "输入无效";; esac; done; if [ -n "$bbr_profile" ]; then json_edit "$PICKED" '.meta.up_mbps=0|.meta.down_mbps=0|.meta.bbr_profile=$b|del(.inbound.up_mbps,.inbound.down_mbps)|.inbound.bbr_profile=$b' --arg b "$bbr_profile"; else json_edit "$PICKED" '.meta.up_mbps=$up|.meta.down_mbps=$down|.meta.bbr_profile=""|if $up>0 then .inbound.up_mbps=$up else del(.inbound.up_mbps) end|if $down>0 then .inbound.down_mbps=$down else del(.inbound.down_mbps) end|del(.inbound.bbr_profile)' --argjson up "$up_mbps" --argjson down "$down_mbps"; fi || { tell_warn 失败; wait_key; continue; }; else tell_warn "输入无效"; continue; fi;;
      5) if [ "$kind" = vless-reality ]; then while :; do value=$(prompt "新握手目标域名 (留空取消)"); [ -n "$value" ] || break; probe_handshake_target "$value" && break; prompt_yes "检测异常，强制加载" && break; done; [ -n "$value" ] || continue; json_edit "$PICKED" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v' --arg v "$value" || { tell_warn 失败; wait_key; continue; }; elif [ "$kind" = hysteria2 ]; then if prompt_yes "是否配置并开启协议混淆 (选择 N 则关闭混淆)"; then tell "  1. Salamander"; tell "  2. Gecko"; while :; do case $(prompt "请选择混淆算法" 2) in 1) obfs_type=salamander; break;; 2) obfs_type=gecko; break;; *) tell_warn "输入无效";; esac; done; obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$(jq -r '.meta.obfs_password//""' "$PICKED")"); [ -z "$obfs_password" ] && obfs_password=$(jq -r .meta.password "$PICKED"); if [ "$obfs_type" = gecko ]; then min_pkt=$(prompt "最小包大小 (字节, 留空默认512)" "$(jq -r '.meta.min_packet_size//512' "$PICKED")"); max_pkt=$(prompt "最大包大小 (字节, 留空默认1200)" "$(jq -r '.meta.max_packet_size//1200' "$PICKED")"); echo "$min_pkt"|grep -Eq '^[0-9]+$' || min_pkt=512; echo "$max_pkt"|grep -Eq '^[0-9]+$' || max_pkt=1200; json_edit "$PICKED" '.meta.obfs_type=$t|.meta.obfs_password=$p|.meta.min_packet_size=($mn|tonumber)|.meta.max_packet_size=($mx|tonumber)|.inbound.obfs={type:$t,password:$p,min_packet_size:($mn|tonumber),max_packet_size:($mx|tonumber)}' --arg t "$obfs_type" --arg p "$obfs_password" --arg mn "$min_pkt" --arg mx "$max_pkt"; else json_edit "$PICKED" '.meta.obfs_type=$t|.meta.obfs_password=$p|del(.meta.min_packet_size,.meta.max_packet_size)|.inbound.obfs={type:$t,password:$p}' --arg t "$obfs_type" --arg p "$obfs_password"; fi; else json_edit "$PICKED" '.meta.obfs_type=""|.meta.obfs_password=""|del(.meta.min_packet_size,.meta.max_packet_size)|del(.inbound.obfs)'; fi || { tell_warn 失败; wait_key; continue; }; else tell_warn "输入无效"; continue; fi;;
      6) if [ "$kind" = vless-reality ]; then value=$(prompt "新 short_id (留空自动生成 8位十六进制)" "$(jq -r '.meta.short_id//""' "$PICKED")"); [ -n "$value" ] || value=$(openssl rand -hex 4); echo "$value"|grep -Eq '^[0-9a-fA-F]{1,8}$' || { tell_warn "short_id 必须为 1-8 位十六进制字符"; wait_key; continue; }; json_edit "$PICKED" '.meta.short_id=$v|.inbound.tls.reality.short_id=[$v]' --arg v "$value" || { tell_warn 失败; wait_key; continue; } else tell_warn "输入无效"; continue; fi;;
      0) return;; *) tell_warn "输入无效，请重新选择"; sleep 1;;
    esac
    if apply_config; then tell_ok "已生效"; tell_gap; render_share_uri "$PICKED"; else printf '%s\n' "$old_json"|json_write "$PICKED"; apply_config_quiet; tell_warn "配置冲突或校验失败，已回滚"; fi
    wait_key
  done
}

render_certificate_status(){
  local domain crt expiry days mtime
  domain=$(state_get domain); [ -n "$domain" ] || return 0
  tell ""
  tell "  全局域名: $domain | 验证: $(state_get challenge)"
  crt=$(find "$ACME_DIR" -type f -name "$domain.crt" 2>/dev/null | head -1)
  [ -n "$crt" ] || crt=$(find "$ACME_DIR" -type f -name '*.crt' 2>/dev/null | head -1)
  [ -n "$crt" ] || { tell "  ${YELLOW}证书状态: 未签发${PLAIN}"; return 0; }

  mtime=$(stat -c %Y "$crt" 2>/dev/null || echo 0)
  [ "$mtime" -gt 0 ] || { tell "  ${RED}证书状态: 无法读取${PLAIN}"; return 0; }

  expiry=$(date -d "@$((mtime+7776000))" 2>/dev/null || echo "unknown")
  days=$(( (mtime + 7776000 - $(date +%s)) / 86400 ))

  tell "  到期时间: $expiry | 剩余: ${days} 天"
  rc-service sing-box status >/dev/null 2>&1 || tell_warn "服务离线，无法自动续期"
}

menu_server_info(){
  local file port proto status count=0 tcp_list udp_list
  tcp_list=$(listening_ports t); udp_list=$(listening_ports u)
  clear
  tell "${CYAN}========== 服务端信息 ==========${PLAIN}"
  rc-service sing-box status >/dev/null 2>&1 && tell_ok "singbox: 运行中" || tell_warn "singbox: 未运行"

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
    [ -e "$file" ] || continue
    if [ "$(jq -r .tls_mode "$file")" = acme ]; then
      tell "  - $(jq -r .name "$file") [$(jq -r .kind "$file")]"
      count=$((count+1))
    fi
  done
  [ "$count" = 0 ] && tell "  无"
  echo ""
  new_domain=$(prompt "新域名 (留空取消)"); [ -z "$new_domain" ] && return

  if prompt_yes "同步重置验证机制"; then
    state_set domain ""; state_set email ""
    if ! setup_certificate "$new_domain"; then
      state_set domain "$old_domain"; state_set email "$old_email"; state_set challenge "$old_challenge"
      return
    fi
  else
    validate_domain "$new_domain" || prompt_yes "验证未通过，强制写入" || return
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
         rc-service sing-box restart >/dev/null 2>&1
         if rc-service sing-box status >/dev/null 2>&1; then
           tell_ok "已重启"
         else
           tell_warn "singbox 未运行"
           tell_warn "重启失败"
         fi
         wait_key
         ;;
      7)
         local previous; previous=$(state_get exit)
         state_set exit direct
         stop_watchdog
         if rc-service sing-box stop >/dev/null 2>&1; then
           if build_config | json_write "$CONFIG"; then
             tell_ok "已停止"
           else
             state_set exit "$previous"
             sync_watchdog
             tell_warn "服务已停止，但配置同步失败，状态已回滚"
           fi
         else
           state_set exit "$previous"
           sync_watchdog
           tell_warn "操作异常，已回滚"
         fi
         wait_key
         ;;
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
  if ! echo "$URI_PORT" | grep -Eq '^[0-9]+$' || [ "$URI_PORT" -lt 1 ] || [ "$URI_PORT" -gt 65535 ]; then
    URI_PORT=443
  fi
}

query_value(){
  local key="$1"
  local pair
  local old_ifs="$IFS"
  IFS='&'
  set -f
  for pair in $URI_QUERY; do
    if [ "${pair%%=*}" = "$key" ]; then
      IFS="$old_ifs"
      set +f
      uri_decode "${pair#*=}"
      return
    fi
  done
  IFS="$old_ifs"
  set +f
}

uri_to_outbound(){
  local tag=$1 outbound sni fingerprint insecure security network path vhost service
  local username password congestion alpn obfs_type obfs_pw flow udp_mode
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
      obfs_pw=$(query_value obfs-password)
      obfs_type=$(query_value obfs)
      if [ -n "$obfs_pw" ]; then
        [ -z "$obfs_type" ] && obfs_type="salamander"
        outbound=$(echo "$outbound" | jq --arg type "$obfs_type" --arg pw "$obfs_pw" \
          '.obfs={type:$type,password:$pw}')
      fi
      local bbr_profile min_pkt max_pkt
      bbr_profile=$(query_value bbr_profile)
      [ -n "$bbr_profile" ] && outbound=$(echo "$outbound" | jq --arg b "$bbr_profile" '.bbr_profile=$b')
      min_pkt=$(query_value min_packet_size); max_pkt=$(query_value max_packet_size)
      if echo "$min_pkt" | grep -Eq '^[0-9]+$' && echo "$max_pkt" | grep -Eq '^[0-9]+$'; then
        outbound=$(echo "$outbound" | jq --argjson mn "$min_pkt" --argjson mx "$max_pkt" '.obfs.min_packet_size=$mn|.obfs.max_packet_size=$mx')
      fi ;;
    tuic)
      username=${URI_USERINFO%%:*}
      password=${URI_USERINFO#*:}
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
        outbound=$(echo "$outbound" | jq --arg path "$(query_value path)" --arg host "$(query_value host)" \
          '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}
                       +(if $host=="" then {} else {headers:{Host:$host}} end))')
      fi ;;
    anytls)
      local client_metadata
      client_metadata=$(query_value client_metadata)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg password "$URI_USERINFO" --arg sni "$sni" --arg meta "$client_metadata" \
        '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni} | if $meta!="" then .client_metadata=$meta else . end}') ;;
    snell)
      local smode sver
      smode=$(query_value mode); [ -n "$smode" ] || smode=default
      sver=$(query_value version); [ -n "$sver" ] || sver=6
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg psk "$URI_USERINFO" --argjson version "$sver" --arg mode "$smode" '{type:"snell",tag:$tag,server:$server,server_port:$port,psk:$psk,version:$version,mode:$mode}') ;;
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
    outbound=$(echo "$outbound" | jq 'if .tls then .tls.insecure=true else . end')
  fi

  printf '%s' "$outbound"
}

peer_add(){
  local name uri tag outbound probe port
  clear; tell "${CYAN}========== 添加节点 ==========${PLAIN}"; name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return; uri=$(prompt "节点链接"); [ -n "$uri" ] || return; parse_uri "$uri"
  if peer_target_is_local_uri "$URI_HOST" "$URI_PORT"; then tell_warn "节点目标指向本机服务端地址，拒绝形成本机环路"; wait_key; return; fi
  tag=$(unique_tag "$name" out- "$PEER_DIR"); outbound=$(uri_to_outbound "$tag") || { tell_warn "无法解析"; wait_key; return; }; probe=$(mktemp); TMP_FILES="$TMP_FILES $probe"
  jq -n --argjson ob "$outbound" '{log:{level:"error"},outbounds:[$ob,{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$probe"
  if "$CORE" check -c "$probe" >/dev/null 2>&1; then
    if json_save "$PEER_DIR/$tag.json" "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" '{tag:$tag,name:$name,uri:$uri,outbound:$ob}')"; then tell_ok "挂载完成: $name"; else tell_warn "节点保存失败"; fi
  else tell_warn "校验拦截:"; "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2; fi
  rm -f "$probe"; wait_key
}

local_physical_addresses(){
  local family iface
  family=$1
  if [ "$family" = 4 ]; then
    for iface in $(ip -4 route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);break}}' | sort -u); do
      ip -4 addr show dev "$iface" scope global 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2);print $2}'
    done
  else
    for iface in $(ip -6 route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);break}}' | sort -u); do
      ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6 /{sub(/\/.*/,"",$2);print $2}'
    done
  fi
}

peer_target_address_is_local(){
  local host=$1 ip localaddr
  [ -n "$host" ] || return 1
  case "$host" in 127.*|localhost|::1) return 0;; esac
  for ip in $(resolve_addresses "$host"); do
    if echo "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
      while IFS= read -r localaddr; do [ "$ip" = "$localaddr" ] && return 0; done <<EOF
$(local_physical_addresses 4)
EOF
    else
      while IFS= read -r localaddr; do [ "$ip" = "$localaddr" ] && return 0; done <<EOF
$(local_physical_addresses 6)
EOF
    fi
  done
  return 1
}

peer_target_is_local(){
  local file host port p
  [ -f "$file" ] || return 1; host=$(jq -r '.outbound.server//""' "$file" 2>/dev/null); port=$(jq -r '.outbound.server_port//0' "$file" 2>/dev/null)
  peer_target_address_is_local_uri "$host" "$port"
}

peer_target_address_is_local_uri(){
  local host=$1 port=$2 p
  [ -n "$host" ] || return 1; echo "$port"|grep -Eq '^[1-9][0-9]{0,4}$' || return 1; [ "$port" -le 65535 ] || return 1
  case "$host" in 127.*|localhost|::1) ;; *) peer_target_address_is_local "$host" || return 1;; esac
  for p in $(node_ports); do [ "$p" = "$port" ] && return 0; done
  return 1
}

list_peers(){
  local current=$(state_get exit)
  local title=${1:-节点选择}
  PEER_COUNT=0
  set -- "$PEER_DIR"/*.json
  [ ! -e "$1" ] && { clear; tell "${CYAN}========== $title ==========${PLAIN}"; tell "  暂无外部节点"; return 0; }

  local tmp_dir
  tmp_dir=$(mktemp -d)
  TMP_FILES="$TMP_FILES $tmp_dir"

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
        local ms="" ping_res
        if echo "$host" | grep -q ":"; then
          ping_res=$(timeout 1 ping6 -c 1 -W 1 "$host" 2>/dev/null | awk '/^rtt|^round-trip/{split($4, a, "/"); print a[2]}')
        else
          ping_res=$(timeout 1 ping -c 1 -W 1 "$host" 2>/dev/null | awk '/^rtt|^round-trip/{split($4, a, "/"); print a[2]}')
        fi

        if [ -n "$ping_res" ]; then
          ms=$(awk "BEGIN {print int($ping_res)}")
        else
          ms="fail"
        fi

        echo "$ms" > "$tmp_dir/res_$idx"
      ) &
      test_pids="$test_pids $!"
    done <<EOF
$raw_data
EOF
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
    if echo "$index" | grep -Eq '^[0-9]+$' && [ "$index" -ge 1 ] && [ "$index" -le "$PEER_COUNT" ]; then
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
  local tag previous wg_was_active=0
  clear; tell "${CYAN}========== 节点选择 ==========${PLAIN}"; select_peer || return; tag=$(jq -r .tag "$PICKED"); previous=$(state_get exit)
  if peer_target_is_local "$PICKED"; then tell_warn "节点目标指向本机服务端地址，拒绝形成本机环路"; wait_key; return; fi
  if wg_client_active; then prompt_yes "WireGuard 隧道运行中，是否断开" || return; if ! json_edit "$WG_CONF" '.enabled=false'; then tell_warn "WireGuard 关闭状态写入失败，未切换节点"; wait_key; return; fi; wg_was_active=1; fi
  if ! state_set exit "$tag"; then [ "$wg_was_active" = 1 ] && json_edit "$WG_CONF" '.enabled=true' >/dev/null 2>&1 || true; tell_warn "出口状态写入失败，未切换"; wait_key; return; fi
  stop_watchdog
  if apply_config; then sync_watchdog; tell_ok "已接管: $(jq -r .name "$PICKED")"; else state_set exit "$previous" || true; [ "$wg_was_active" = 1 ] && json_edit "$WG_CONF" '.enabled=true' || tell_warn "WireGuard 状态恢复失败，请手动检查"; apply_config_quiet; sync_watchdog; tell_warn "切换失败已回滚"; fi
  wait_key
}

peer_delete(){
  clear; tell "${CYAN}========== 删除节点 ==========${PLAIN}"
  select_peer || return

  local old_json previous_exit
  old_json=$(cat "$PICKED")
  previous_exit=$(state_get exit)

  if [ "$(jq -r .tag "$PICKED")" = "$previous_exit" ]; then
    state_set exit direct
    stop_watchdog
    rm -f "$PICKED"
    if apply_config; then
      tell_ok "已删除当前生效节点，已恢复直连"
    else
      json_save "$PICKED" "$old_json"
      state_set exit "$previous_exit"
      apply_config_quiet
      sync_watchdog
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
  local previous; previous=$(state_get exit)
  if ! state_set exit direct; then tell_warn "出口状态写入失败，未恢复直连"; wait_key; return; fi
  stop_watchdog
  if apply_config; then
    tell_ok "已恢复直连"
  else
    state_set exit "$previous"
    apply_config_quiet
    sync_watchdog
    tell_warn "恢复直连失败，已回滚"
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
  local mode=$1 res ip country asn name proxy_env=""

  if [ "$(state_get exit)" != "direct" ]; then
    proxy_env="http://127.0.0.1:2080"
  fi

  local raw_ip
  if [ "$mode" = 6 ]; then
  raw_ip=$(env http_proxy="$proxy_env" https_proxy="$proxy_env" wget -qO- -T 5 https://ipv6.icanhazip.com 2>/dev/null | tr -d '\n ')
else
  raw_ip=$(env http_proxy="$proxy_env" https_proxy="$proxy_env" wget -qO- -T 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n ')
fi

if [ -n "$raw_ip" ]; then
  res=$(env http_proxy="$proxy_env" https_proxy="$proxy_env" wget -qO- -T 5 "https://ipwho.is/${raw_ip}" 2>/dev/null)
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
      return
    fi
  fi

  IP_INFO_IP=""
  IP_INFO_C=""
  IP_INFO_ASN=""
  IP_INFO_NAME=""
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
  tell "  提示: 容器环境仅支持 TCP (HTTP/SOCKS5) 接管"
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
  local proxy_env=""
  if [ "$(state_get exit)" != "direct" ]; then
    proxy_env="http://127.0.0.1:2080"
  fi
  if env http_proxy="$proxy_env" wget -q -O /dev/null -T 3 "$PROBE_URL" >/dev/null 2>&1; then echo up; else echo down; fi
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
  tell "  远端公钥: $(jq -r '.peer_public_key // "" | if .=="" then "<待补录>" else . end' "$file")"
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
  local role previous old_active=0
  clear; [ -f "$WG_CONF" ] || { tell_warn "请先初始化"; wait_key; return; }; role=$(jq -r .role "$WG_CONF"); previous=$(state_get exit)
  rc-service sing-box status >/dev/null 2>&1 && old_active=1
  if [ "$(jq -r .enabled "$WG_CONF")" = true ]; then
    if ! json_edit "$WG_CONF" '.enabled=false'; then tell_warn "WireGuard 状态写入失败"; wait_key; return; fi
    if [ "$previous" = wireguard ]; then if ! state_set exit direct; then json_edit "$WG_CONF" '.enabled=true' || true; tell_warn "出口状态写入失败，未关闭隧道"; wait_key; return; fi; stop_watchdog; fi
    if apply_config; then tell_ok "已关闭隧道"; else json_edit "$WG_CONF" '.enabled=true' || true; state_set exit "$previous" || true; apply_config_quiet; sync_watchdog; tell_warn "配置应用失败，已回滚"; fi
  else
    [ -n "$(jq -r .peer_public_key "$WG_CONF")" ] || { tell_warn "缺少公钥"; wait_key; return; }
    if [ "$role" = client ] && [ "$previous" != direct ]; then prompt_yes "隧道将接管网络，确定" || return; fi
    if ! json_edit "$WG_CONF" '.enabled=true'; then tell_warn "WireGuard 状态写入失败"; wait_key; return; fi
    if [ "$role" = client ]; then if ! state_set exit wireguard; then json_edit "$WG_CONF" '.enabled=false' || true; tell_warn "出口状态写入失败，未启用隧道"; wait_key; return; fi; stop_watchdog; fi
    if apply_config; then
      if [ "$old_active" = 0 ]; then
        if ! rc-service sing-box start >/dev/null 2>&1 || ! rc-service sing-box status >/dev/null 2>&1; then
          json_edit "$WG_CONF" '.enabled=false' || true
          state_set exit "$previous" || true
          apply_config_quiet
          tell_warn "WireGuard 已写入，但 sing-box 启动失败，已回滚"
          wait_key
          return
        fi
      fi
      [ "$role" = client ] && sync_watchdog
      sleep 1
      render_wg_info "$WG_CONF"
    else
      json_edit "$WG_CONF" '.enabled=false' || true
      state_set exit "$previous" || true
      apply_config_quiet
      sync_watchdog
      tell_warn "WireGuard 配置应用失败，已回滚"
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
         if [ ! -f "$WG_CONF" ]; then
           tell_warn "未配置 WireGuard，无需删除"
           wait_key
           continue
         fi
         if prompt_yes "确认删除配置"; then
           local wg_backup prev_exit
           wg_backup=$(cat "$WG_CONF")
           prev_exit=$(state_get exit)
           rm -f "$WG_CONF"
           if [ "$prev_exit" = wireguard ]; then
             state_set exit direct
             stop_watchdog
           fi
           if apply_config; then
             tell_ok "已清除"
           else
             printf '%s\n' "$wg_backup" | json_write "$WG_CONF"
             state_set exit "$prev_exit"
             apply_config_quiet
             sync_watchdog
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
  local core_backup old_asset service_active=0 update_ok=0
  core_backup=$(mktemp) || { tell_warn "无法创建内核回滚备份"; return 1; }
  if [ -x "$CORE" ] && ! cp -p "$CORE" "$core_backup"; then rm -f "$core_backup"; tell_warn "无法备份当前内核"; return 1; fi
  old_asset=$(state_get asset); rc-service sing-box status >/dev/null 2>&1 && service_active=1
  if [ "$service_active" = 1 ]; then rc-service sing-box stop >/dev/null 2>&1 || { rm -f "$core_backup"; tell_warn "无法安全停止 sing-box，取消内核更新"; return 1; }; fi
  if install_core && apply_config; then
    if [ "$service_active" = 1 ]; then rc-service sing-box status >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1; rc-service sing-box status >/dev/null 2>&1 && update_ok=1; else update_ok=1; fi
  fi
  if [ "$update_ok" = 0 ]; then
    if [ -s "$core_backup" ]; then install -m755 "$core_backup" "$CORE" >/dev/null 2>&1 || tell_warn "旧内核恢复失败"; else rm -f "$CORE"; fi
    state_set asset "$old_asset" || true
    apply_config_quiet || tell_warn "旧内核恢复后配置重新应用失败"
    if [ "$service_active" = 1 ] && ! rc-service sing-box status >/dev/null 2>&1; then rc-service sing-box start >/dev/null 2>&1 || tell_warn "原运行服务恢复启动失败"; fi
    rm -f "$core_backup"; return 1
  fi
  rm -f "$core_backup"; return 0
}

run_update(){
  local current latest script_url script_tmp
  clear; tell "正在检测 sing-box 内核更新..."; current=$(core_version); latest=$(remote_version); tell "本地版本: ${current:-未知}"; tell "最新版本: ${latest:-获取失败}"
  if [ -z "$latest" ]; then tell_warn "无法获取最新版本，请检查网络或 GitHub 访问"; elif [ -z "$current" ]; then if prompt_yes "无法读取当前内核版本，是否重新下载并安装最新版 v$latest"; then if update_core_transaction; then tell_ok "内核更新完成"; else tell_warn "内核更新失败，已回滚"; fi; fi; elif [ "$current" != "$latest" ]; then if prompt_yes "发现新版本 v$latest，是否立即更新"; then if update_core_transaction; then tell_ok "内核更新完成"; else tell_warn "内核更新失败，已回滚"; fi; fi; else tell_ok "内核已是最新版本"; fi
  tell_gap; tell "正在检测 s 脚本更新..."; script_url="https://raw.githubusercontent.com/88860/-/main/lxc-s.sh"; script_tmp=$(mktemp); TMP_FILES="$TMP_FILES $script_tmp"
  if wget -q -O "$script_tmp" -T 15 "$script_url"; then if sh -n "$script_tmp" 2>/dev/null; then if cmp -s "$script_tmp" "$SELF"; then tell_ok "脚本已是最新版本"; else mv -f "$script_tmp" "$SELF"; chmod 700 "$SELF"; tell_ok "脚本更新成功，请重新运行本脚本生效"; exit 0; fi; else tell_warn "下载的脚本存在语法错误，放弃更新"; fi; else tell_warn "脚本下载失败，请检查 GitHub 访问"; fi
  wait_key
}

run_uninstall(){
  local packages=""
  clear
  tell_warn "警告: 卸载将清空所有配置"
  [ "$(prompt '输入 yes 确认')" = yes ] || return

  if [ -f "$PKG_LOG" ]; then
    packages=$(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null | tr '\n' ' ')
  fi

  rc-service sing-box stop 2>/dev/null
  rc-update del sing-box default 2>/dev/null

  stop_watchdog

  rm -f "$SERVICE_FILE"
  rm -f /etc/profile.d/sbm_proxy.sh

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
    local os=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null || echo "Alpine Linux")
    local core=$(uname -r)
    local arch=$(uname -m)
    local mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}/MemFree/{f=$2}/Buffers/{b=$2}/^Cached/{c=$2}END{if(a=="")a=f+b+c; printf "%d / %d MB",(t-a)/1024,t/1024}' /proc/meminfo)

    local up_seconds=$(cut -d. -f1 /proc/uptime)
    local up_days=$((up_seconds / 86400))
    local up_hours=$(( (up_seconds % 86400) / 3600 ))
    local up_mins=$(( (up_seconds % 3600) / 60 ))
    local up=""
    [ "$up_days" -gt 0 ] && up="${up_days}天"
    [ "$up_hours" -gt 0 ] && up="${up}${up_hours}小时"
    [ "$up_mins" -gt 0 ] && up="${up}${up_mins}分钟"
    [ -n "$up" ] || up="不足1分钟"

    local sb_ver=$(core_version)
    local sb_asset=$(state_get asset)
    local s_state="${RED}未运行${PLAIN}"
    rc-service sing-box status >/dev/null 2>&1 && s_state="${GREEN}正常运行${PLAIN}"

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
  fi
  if [ ! -f "$SERVICE_FILE" ]; then
    write_service || { tell_warn "OpenRC 服务文件创建失败"; exit 1; }
  fi
  [ -x "$SERVICE_FILE" ] || { tell_warn "OpenRC 服务文件不可执行"; exit 1; }
  rc-update add sing-box default >/dev/null 2>&1 || { tell_warn "无法加入 OpenRC 默认启动项"; exit 1; }
  if [ ! -f "$CONFIG" ]; then
    build_config | json_write "$CONFIG" || { tell_warn "初始 sing-box 配置生成失败"; exit 1; }
  fi
  sync_proxy_env

  if watchdog_needed; then
    arm_watchdog
  fi
}

case $1 in
  --sync) init_dirs; sync_proxy_env; exit 0 ;;
  --watchdog) run_watchdog ;;
esac

bootstrap

while :; do
  clear
  tell "${CYAN}================================${PLAIN}"
  tell "${CYAN}             s管理              ${PLAIN}"
  tell "${CYAN}      [ 仅适配 OpenRC 版 ]      ${PLAIN}"
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
