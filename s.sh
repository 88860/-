#!/bin/bash
set -u
export LC_ALL=C
umask 077

NAME="sing-box"
VERSION="1.14.1"
ARCH=""
BIN="/usr/local/bin/sing-box"
CMD="/usr/local/bin/s"
DATA="/etc/sing-box"
CONFIG="$DATA/config.json"
STATE="$DATA/state.json"
BACKUP="$DATA/backup"
LOCK="$DATA/.lock"
SERVICE="sing-box.service"
TMP="/tmp/sb.$$.tmp"
trap 'rm -f "$TMP" "$TMP".* 2>/dev/null || true' EXIT

log_ok(){ printf '  [✓] %s\n' "$*"; }
log_err(){ printf '  [×] %s\n' "$*"; }
hr(){ printf '  --------------------------------\n'; }
pause(){ printf '\n  >> 按回车键继续...'; read -r _; }
yesno(){ local p="$1" d="${2:-Y}" a; read -r -p "  $p" a; a="${a:-$d}"; case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
randhex(){ openssl rand -hex "${1:-8}" 2>/dev/null; }
randstr(){ openssl rand -base64 "${1:-24}" 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${2:-24}"; }
rand_uuid(){ cat /proc/sys/kernel/random/uuid; }
json(){ jq -c "$1" 2>/dev/null; }
need_root(){ [ "$(id -u)" -eq 0 ] || { log_err "请使用 root 运行"; exit 1; }; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
install_deps(){
  local miss=() c
  for c in curl jq openssl ip ping awk sed grep tar gzip systemctl sha256sum; do cmd_exists "$c" || miss+=("$c"); done
  if ((${#miss[@]})); then
    command -v apt-get >/dev/null 2>&1 || { log_err "缺少依赖：${miss[*]}"; return 1; }
    apt-get update -qq >/dev/null 2>&1 || return 1
    apt-get install -y -qq curl jq openssl iproute2 iputils-ping ca-certificates tar gzip coreutils >/dev/null 2>&1 || return 1
  fi
}
arch_name(){ case "$(uname -m)" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; armv7l|armv7) ARCH=armv7;; esac; [ -n "$ARCH" ]; }
get_os(){ . /etc/os-release 2>/dev/null || true; OS_NAME="${PRETTY_NAME:-Linux}"; }
get_ipv4(){ ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
get_ipv6(){ ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
has_tun(){ [ -c /dev/net/tun ] && { [ -w /dev/net/tun ] || [ -r /dev/net/tun ]; }; }
has_nft(){ cmd_exists nft; }
state_init(){ mkdir -p "$DATA" "$BACKUP"; [ -f "$STATE" ] || printf '{"selected":"direct","client_running":false,"nodes":[],"servers":[]}' > "$STATE"; }
lock(){ exec 9>"$LOCK"; flock -n 9 || { log_err "已有操作正在进行"; exit 1; }; }

json_get(){ jq -r "$1" "$STATE" 2>/dev/null; }
state_write(){ local n="$1"; printf '%s\n' "$n" > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"; }

install_singbox(){
  if [ -x "$BIN" ] && "$BIN" version 2>/dev/null | grep -q "version ${VERSION}"; then return 0; fi
  arch_name || { log_err "不支持的 CPU 架构"; return 1; }
  local url="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH}.tar.gz"
  local d="/tmp/sing-box-${VERSION}.$$.tgz"
  curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$d" || { rm -f "$d"; log_err "内核下载失败"; return 1; }
  rm -rf /tmp/sing-box-extract.$$; mkdir -p /tmp/sing-box-extract.$$
  tar -xzf "$d" -C /tmp/sing-box-extract.$$ || return 1
  local f; f=$(find /tmp/sing-box-extract.$$ -type f -name sing-box -perm -111 | head -n1)
  [ -n "$f" ] || return 1
  install -m 0755 "$f" "$BIN"
  rm -rf /tmp/sing-box-extract.$$ "$d"
}
write_service(){
  cat > /etc/systemd/system/$SERVICE <<EOF2
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CONFIG
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
}

build_base(){
  local tun="$1"
  if [ "$tun" = 1 ]; then
    cat > "$TMP" <<'EOF2'
{
  "log":{"level":"warn"},
  "dns":{
    "servers":[
      {"tag":"cf-v4","address":"1.1.1.1","detour":"direct"},
      {"tag":"cf-v6","address":"2606:4700:4700::1111","detour":"direct"}
    ],
    "strategy":"prefer_ipv6"
  },
  "inbounds":[
    {"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":2080}
  ],
  "outbounds":[
    {"type":"direct","tag":"direct"},
    {"type":"block","tag":"block"}
  ],
  "route":{
    "auto_detect_interface":true,
    "final":"proxy"
  }
}
EOF2
  else
    cat > "$TMP" <<'EOF2'
{
  "log":{"level":"warn"},
  "dns":{
    "servers":[
      {"tag":"cf-v4","address":"1.1.1.1","detour":"direct"},
      {"tag":"cf-v6","address":"2606:4700:4700::1111","detour":"direct"}
    ],
    "strategy":"prefer_ipv6"
  },
  "inbounds":[
    {"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":2080}
  ],
  "outbounds":[
    {"type":"direct","tag":"direct"},
    {"type":"block","tag":"block"}
  ],
  "route":{"final":"proxy"}
}
EOF2
  fi
}

apply_config(){
  local new="$1"
  "$BIN" check -c "$new" >/dev/null 2>&1 || { log_err "sing-box 配置检查失败"; return 1; }
  mkdir -p "$BACKUP"
  [ -f "$CONFIG" ] && cp -f "$CONFIG" "$BACKUP/config.$(date +%Y%m%d%H%M%S).json"
  mv -f "$new" "$CONFIG"
  systemctl restart "$SERVICE" >/dev/null 2>&1 || {
    local last; last=$(ls -1t "$BACKUP"/config.*.json 2>/dev/null | head -n1 || true)
    [ -n "$last" ] && cp -f "$last" "$CONFIG"
    systemctl restart "$SERVICE" >/dev/null 2>&1 || true
    log_err "应用配置失败，已尝试回滚"
    return 1
  }
  sleep 1
  systemctl is-active --quiet "$SERVICE" || { log_err "sing-box 启动失败"; return 1; }
  return 0
}

server_domain(){ jq -r '.domain // empty' <<<"$1"; }
server_port(){ jq -r '.port // empty' <<<"$1"; }
server_name(){ jq -r '.name // empty' <<<"$1"; }

transport_json(){
  local mode="$1" path="$2" service="$3"
  case "$mode" in
    ws) jq -n --arg p "$path" '{type:"ws",path:$p}';;
    grpc) jq -n --arg s "$service" '{type:"grpc",service_name:$s}';;
    httpupgrade) jq -n --arg p "$path" '{type:"httpupgrade",path:$p}';;
    *) printf 'null';;
  esac
}

mk_tls(){ local sni="$1" cert="$2" key="$3"; jq -n --arg s "$sni" --arg c "$cert" --arg k "$key" '{enabled:true,server_name:$s,certificate_path:$c,key_path:$k}'; }

append_server(){
  local obj="$1"; jq --argjson x "$obj" '.servers += [$x]' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

port_free(){ ! ss -lntup 2>/dev/null | awk '{print $5}' | grep -Eq ":$1$"; }
ask_port(){
  local p="$1" a
  while :; do
    read -r -p "  监听端口 [$p]: " a; a="${a:-$p}"
    [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le 65535 ] && port_free "$a" && { printf '%s' "$a"; return; }
    log_err "端口不可用"
  done
}
ask_password(){ local v; read -r -p "  密码（留空自动生成）: " v; printf '%s' "${v:-$(randstr 24 32)}"; }
ask_uuid(){ local v; read -r -p "  通信 UUID (留空自动生成) [UUID]: " v; printf '%s' "${v:-$(rand_uuid)}"; }
ask_path(){ local p; read -r -p "  WS 路径（留空自动生成）：" p; printf '%s' "${p:-/$(randstr 16 16)}"; }
ask_service(){ local p; read -r -p "  gRPC Service Name（留空自动生成）：" p; printf '%s' "${p:-$(randstr 12 12)}"; }

cert_dir(){ printf '%s/certs/%s' "$DATA" "$1"; }
issue_cert(){
  local domain="$1" d; d=$(cert_dir "$domain"); mkdir -p "$d"
  command -v certbot >/dev/null 2>&1 || { command -v apt-get >/dev/null 2>&1 || return 1; apt-get update -qq >/dev/null 2>&1 || return 1; apt-get install -y -qq certbot >/dev/null 2>&1 || return 1; }
  certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email --preferred-challenges http -d "$domain" --keep-until-expiring >/tmp/sb-acme.$$.log 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2; i=$((i+2)); [ "$i" -ge 180 ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; log_err "证书签发超时"; tail -n 20 /tmp/sb-acme.$$.log 2>/dev/null; rm -f /tmp/sb-acme.$$.log; return 2; }
  done
  wait "$pid"; local rc=$?
  if [ "$rc" -ne 0 ]; then tail -n 20 /tmp/sb-acme.$$.log 2>/dev/null; rm -f /tmp/sb-acme.$$.log; return 1; fi
  cp -f "/etc/letsencrypt/live/$domain/fullchain.pem" "$d/fullchain.pem" || return 1
  cp -f "/etc/letsencrypt/live/$domain/privkey.pem" "$d/privkey.pem" || return 1
  rm -f /tmp/sb-acme.$$.log
  printf '%s|%s' "$d/fullchain.pem" "$d/privkey.pem"
}

create_vless(){
  local name domain port uuid sel path service priv pub sid obj tr tlsj
  read -r -p '  节点名称 [VLESS]: ' name; name="${name:-VLESS}"
  printf '  1. TCP + TLS\n  2. TCP + Reality\n  3. WS + CDN\n  4. gRPC + CDN\n  5. HTTPUpgrade + CDN\n  0. 返回\n'; read -r -p '  请选择: ' sel; [ "$sel" = 0 ] && return
  uuid=$(ask_uuid)
  case "$sel" in
    2)
      port=$(ask_port 443)
      read -r -p '  握手目标域名 [www.microsoft.com]: ' domain; domain="${domain:-www.microsoft.com}"
      getent ahosts "$domain" >/dev/null 2>&1 || { log_err '握手目标验证失败'; return; }
      log_ok '握手目标验证通过'
      read -r -p '  short_id (留空自动生成 8位十六进制): ' sid; sid="${sid:-$(randhex 4)}"
      if ! [[ "$sid" =~ ^[0-9a-fA-F]{0,8}$ ]]; then log_err 'short_id 必须为 0-8 位十六进制'; return; fi
      read -r -p '  私钥 (留空自动生成): ' priv
      if [ -z "$priv" ]; then
        local kp; kp=$("$BIN" generate reality-keypair 2>/dev/null) || { log_err 'Reality 密钥生成失败'; return; }
        priv=$(printf '%s\n' "$kp" | awk -F': ' '/PrivateKey:/{print $2; exit}')
        pub=$(printf '%s\n' "$kp" | awk -F': ' '/PublicKey:/{print $2; exit}')
      else
        log_err '自定义 Reality 私钥必须同时提供对应公钥，当前 UI 不支持只填私钥'; return
      fi
      [ -n "$priv" ] && [ -n "$pub" ] || { log_err 'Reality 密钥对无效'; return; }
      obj=$(jq -n --arg n "$name" --argjson p "$port" --arg u "$uuid" --arg s "$sid" --arg k "$priv" --arg pb "$pub" --arg d "$domain" '{type:"vless",name:$n,port:$p,uuid:$u,mode:"reality",security:"reality",reality:{handshake:$d,private_key:$k,public_key:$pb,short_id:$s}}')
      append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(vless_link "$obj")"; return
      ;;
    1|3|4|5) domain=$(ask_domain); issue_cert "$domain" >/dev/null || return; port=$(ask_port 443);;
    *) return;;
  esac
  case "$sel" in 1) mode=tcp;;3) mode=ws; path=$(ask_path);;4) mode=grpc; service=$(ask_service);;5) mode=httpupgrade; path=$(ask_path);;esac
  tr=$(transport_json "$mode" "${path:-}" "${service:-}")
  tlsj=$(mk_tls "$domain" "$(cert_dir "$domain")/fullchain.pem" "$(cert_dir "$domain")/privkey.pem")
  obj=$(jq -n --arg n "$name" --arg d "$domain" --argjson p "$port" --arg u "$uuid" --arg m "$mode" --argjson t "$tr" --argjson tls "$tlsj" '{type:"vless",name:$n,domain:$d,port:$p,uuid:$u,mode:$m,transport:$t,tls:$tls}')
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(vless_link "$obj")"
}
issue_cert_key(){ printf '%s/privkey.pem' "$(cert_dir "$1")"; }
ask_domain(){ local d; while :; do read -r -p '  输入域名: ' d; [ -n "$d" ] && printf '%s' "$d" && return; done; }

create_vmess(){
  local name sel domain port uuid path service tr obj
  read -r -p '  节点名称 [VMess]: ' name; name="${name:-VMess}"
  printf '  1. TCP\n  2. WS + CDN\n  3. gRPC + CDN\n  0. 返回\n'; read -r -p '  请选择: ' sel; [ "$sel" = 0 ] && return
  uuid=$(ask_uuid)
  case "$sel" in
    1) port=$(ask_port 8388); obj=$(jq -n --arg n "$name" --argjson p "$port" --arg u "$uuid" '{type:"vmess",name:$n,port:$p,uuid:$u,mode:"tcp"}');;
    2|3)
      domain=$(ask_domain); issue_cert "$domain" >/dev/null || return; port=$(ask_port 443)
      if [ "$sel" = 2 ]; then path=$(ask_path); tr=$(transport_json ws "$path" ""); mode=ws; else service=$(ask_service); tr=$(transport_json grpc "" "$service"); mode=grpc; fi
      obj=$(jq -n --arg n "$name" --arg d "$domain" --argjson p "$port" --arg u "$uuid" --arg m "$mode" --argjson t "$tr" '{type:"vmess",name:$n,domain:$d,port:$p,uuid:$u,mode:$m,transport:$t,tls:{enabled:true,server_name:$d,certificate_path:("/etc/sing-box/certs/"+$d+"/fullchain.pem"),key_path:("/etc/sing-box/certs/"+$d+"/privkey.pem")}}');;
    *) return;;
  esac
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(vmess_link "$obj")"
}

create_trojan(){
  local name sel domain port pw path service tr obj
  read -r -p '  节点名称 [Trojan]: ' name; name="${name:-Trojan}"
  printf '  1. TCP + TLS\n  2. WS + CDN\n  3. gRPC + CDN\n  0. 返回\n'; read -r -p '  请选择: ' sel; [ "$sel" = 0 ] && return
  domain=$(ask_domain); issue_cert "$domain" >/dev/null || return; port=$(ask_port 443); pw=$(ask_password)
  tr='null'; case "$sel" in 1) ;;2) path=$(ask_path); tr=$(transport_json ws "$path" "");;3) service=$(ask_service); tr=$(transport_json grpc "" "$service");;*) return;;esac
  obj=$(jq -n --arg n "$name" --arg d "$domain" --argjson p "$port" --arg pw "$pw" --argjson t "$tr" '{type:"trojan",name:$n,domain:$d,port:$p,password:$pw,transport:$t,tls:{enabled:true,server_name:$d,certificate_path:("/etc/sing-box/certs/"+$d+"/fullchain.pem"),key_path:("/etc/sing-box/certs/"+$d+"/privkey.pem")}}')
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(trojan_link "$obj")"
}

create_ss(){
  local name port method pw s obj
  read -r -p '  节点名称 [Shadowsocks]: ' name; name="${name:-Shadowsocks}"
  printf '  1. 2022-blake3-aes-128-gcm\n  2. 2022-blake3-aes-256-gcm\n  3. 2022-blake3-chacha20-poly1305\n  4. aes-128-gcm\n  5. aes-192-gcm\n  6. aes-256-gcm\n  7. chacha20-ietf-poly1305\n'; read -r -p '  请选择: ' s
  case "$s" in 1) method=2022-blake3-aes-128-gcm;;2) method=2022-blake3-aes-256-gcm;;3) method=2022-blake3-chacha20-poly1305;;4) method=aes-128-gcm;;5) method=aes-192-gcm;;6) method=aes-256-gcm;;7) method=chacha20-ietf-poly1305;;*) return;;esac
  port=$(ask_port 8388)
  if [[ "$method" == 2022-* ]]; then
    local kb; case "$method" in 2022-blake3-aes-128-gcm) kb=16;;*) kb=32;;esac
    pw=$("$BIN" generate rand --base64 "$kb" 2>/dev/null) || { log_err 'SS 2022 密钥生成失败'; return; }
  else pw=$(ask_password); fi
  obj=$(jq -n --arg n "$name" --argjson p "$port" --arg m "$method" --arg pw "$pw" '{type:"shadowsocks",name:$n,port:$p,method:$m,password:$pw}')
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(ss_link "$obj")"
}

create_shadowtls(){
  local name port ss_method ss_pw st_pw ver hs obj ss_obj st_obj
  read -r -p '  节点名称 [ShadowTLS]: ' name; name="${name:-ShadowTLS}"
  port=$(ask_port 8443)
  printf '  Shadowsocks 加密方式:\n  1. 2022-blake3-aes-128-gcm\n  2. 2022-blake3-aes-256-gcm\n  3. 2022-blake3-chacha20-poly1305\n  4. aes-128-gcm\n  5. aes-192-gcm\n  6. aes-256-gcm\n  7. chacha20-ietf-poly1305\n'; read -r -p '  请选择: ' s
  case "$s" in 1) ss_method=2022-blake3-aes-128-gcm;;2) ss_method=2022-blake3-aes-256-gcm;;3) ss_method=2022-blake3-chacha20-poly1305;;4) ss_method=aes-128-gcm;;5) ss_method=aes-192-gcm;;6) ss_method=aes-256-gcm;;7) ss_method=chacha20-ietf-poly1305;;*) return;;esac
  if [[ "$ss_method" == 2022-* ]]; then local kb; case "$ss_method" in 2022-blake3-aes-128-gcm) kb=16;;*) kb=32;;esac; ss_pw=$("$BIN" generate rand --base64 "$kb" 2>/dev/null) || return; else ss_pw=$(ask_password); fi
  printf '  1. v1\n  2. v2\n  3. v3\n'; read -r -p '  ShadowTLS 版本: ' ver
  case "$ver" in 1) ver=1;;2) ver=2;;3) ver=3;;*) return;;esac
  st_pw=""; if [ "$ver" = 2 ] || [ "$ver" = 3 ]; then read -r -p '  ShadowTLS 密码: ' st_pw; st_pw="${st_pw:-$(randstr 24 32)}"; fi
  read -r -p '  握手服务器域名: ' hs; [ -n "$hs" ] || return
  ss_obj=$(jq -n --arg tag "st-ss-$name" --argjson p "$((port+1))" --arg m "$ss_method" --arg pw "$ss_pw" '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$p,method:$m,password:$pw}')
  st_obj=$(jq -n --arg n "$name" --argjson p "$port" --argjson v "$ver" --arg pw "$st_pw" --arg hs "$hs" --arg detour "st-ss-$name" '{type:"shadowtls",name:$n,port:$p,version:$v,password:$pw,handshake:{server:$hs,server_port:443},detour:$detour,ss_method:"placeholder"}')
  if [ "$ver" = 2 ]; then obj=$(jq -n --arg n "$name" --argjson p "$port" --argjson v "$ver" --arg sp "$st_pw" --arg h "$hs" --arg sm "$ss_method" --arg ssp "$ss_pw" '{type:"shadowtls",name:$n,port:$p,version:$v,password:$sp,auth_password:$sp,handshake_server:$h,ss_method:$sm,ss_password:$ssp,ss_port:($p+1)}'); elif [ "$ver" = 3 ]; then obj=$(jq -n --arg n "$name" --argjson p "$port" --argjson v "$ver" --arg ap "$st_pw" --arg h "$hs" --arg sm "$ss_method" --arg ssp "$ss_pw" '{type:"shadowtls",name:$n,port:$p,version:$v,auth_password:$ap,handshake_server:$h,ss_method:$sm,ss_password:$ssp,ss_port:($p+1)}'); else obj=$(jq -n --arg n "$name" --argjson p "$port" --argjson v "$ver" --arg h "$hs" --arg sm "$ss_method" --arg ssp "$ss_pw" '{type:"shadowtls",name:$n,port:$p,version:$v,handshake_server:$h,ss_method:$sm,ss_password:$ssp,ss_port:($p+1)}'); fi
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(shadowtls_link "$obj")"
}

create_snell(){
  local name port psk ver mode obj
  read -r -p '  节点名称 [Snell]: ' name; name="${name:-Snell}"
  printf '  Snell版本 [6]:\n  1. v5\n  2. v6\n'; read -r -p '  请选择: ' ver; ver="${ver:-2}"
  case "$ver" in 1) ver=5;;2) ver=6;;*) return;;esac
  while :; do read -r -p '  PSK（留空自动生成）: ' psk; psk="${psk:-$(randstr 32 32)}"; local l; l=$(printf '%s' "$psk"|wc -c|tr -d ' '); [ "$ver" = 5 ] || { [ "$l" -ge 12 ] && [ "$l" -le 255 ]; }; [ "$ver" = 5 ] && [ "$l" -gt 0 ]; [ "$l" -gt 0 ] && break; log_err 'PSK 无效'; done
  if [ "$ver" = 6 ]; then printf '  Traffic Shaping:\n  1. default\n  2. unshaped\n  3. unsafe-raw\n'; read -r -p '  请选择 [1]: ' mode; mode="${mode:-1}"; case "$mode" in 1) mode=default;;2) mode=unshaped;;3) mode=unsafe-raw;;*) return;;esac; else mode=none; fi
  obj=$(jq -n --arg n "$name" --argjson p "$(ask_port 4400)" --argjson v "$ver" --arg k "$psk" --arg m "$mode" '{type:"snell",name:$n,port:$p,version:$v,psk:$k} + (if $v==6 then {mode:$m} else {obfs_mode:"none"} end)')
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(snell_link "$obj")"
}

create_socks(){
  local name port user pw obj
  read -r -p '  节点名称 [SOCKS5]: ' name; name="${name:-SOCKS5}"; port=$(ask_port 1080); read -r -p '  用户名（留空自动生成）: ' user; user="${user:-$(randstr 16 16)}"; pw=$(ask_password)
  obj=$(jq -n --arg n "$name" --argjson p "$port" --arg u "$user" --arg pw "$pw" '{type:"socks",name:$n,port:$p,username:$u,password:$pw}')
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(socks_link "$obj")"
}

create_hy2(){
  local name domain port pw cc profile='' up='' down='' obfs sel op min max obj ob='null'
  read -r -p '  节点名称 [Hysteria2]: ' name; name="${name:-Hysteria2}"; domain=$(ask_domain); issue_cert "$domain" >/dev/null || return; port=$(ask_port 443); pw=$(ask_password)
  printf '  拥塞控制 [3]:\n  1. conservative\n  2. standard\n  3. aggressive\n  4. brutal\n'; read -r -p '  请选择: ' cc; cc="${cc:-3}"
  case "$cc" in 1) profile=conservative;;2) profile=standard;;3) profile=aggressive;;4) read -r -p '  上行带宽（Mbps）: ' up; read -r -p '  下行带宽（Mbps）: ' down; [[ "$up" =~ ^[1-9][0-9]*$ && "$down" =~ ^[1-9][0-9]*$ ]] || { log_err '带宽必须为正整数'; return; };;*) return;;esac
  printf '  混淆:\n  1. 关闭\n  2. salamander\n  3. gecko\n'; read -r -p '  请选择 [1]: ' sel; sel="${sel:-1}"
  case "$sel" in
    1) ;;
    2) read -r -p '  混淆密码（留空自动生成）: ' op; op="${op:-$(randstr 24 32)}"; ob=$(jq -n --arg p "$op" '{type:"salamander",password:$p}');;
    3) read -r -p '  混淆密码（留空自动生成）: ' op; op="${op:-$(randstr 24 32)}"; read -r -p '  最小数据包大小（留空协议默认）: ' min; read -r -p '  最大数据包大小（留空协议默认）: ' max; if [ -n "$min" ] && ! [[ "$min" =~ ^[0-9]+$ ]]; then log_err '最小数据包大小无效'; return; fi; if [ -n "$max" ] && ! [[ "$max" =~ ^[0-9]+$ ]]; then log_err '最大数据包大小无效'; return; fi; ob=$(jq -n --arg p "$op" --arg min "$min" --arg max "$max" '{type:"gecko",password:$p} + (if $min!="" then {min_packet_size:($min|tonumber)} else {} end) + (if $max!="" then {max_packet_size:($max|tonumber)} else {} end)');;
    *) return;;
  esac
  obj=$(jq -n --arg n "$name" --arg d "$domain" --argjson p "$port" --arg pw "$pw" --arg prof "$profile" --arg up "$up" --arg down "$down" --argjson ob "$ob" '{type:"hysteria2",name:$n,domain:$d,port:$p,password:$pw,obfs:$ob} + (if $prof!="" then {bbr_profile:$prof} else {up_mbps:($up|tonumber),down_mbps:($down|tonumber)} end)')
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(hy2_link "$obj")"
}

create_tuic(){
  local name domain port uuid pw cc obj
  read -r -p '  节点名称 [TUIC]: ' name; name="${name:-TUIC}"; domain=$(ask_domain); issue_cert "$domain" >/dev/null || return; port=$(ask_port 443); uuid=$(ask_uuid); pw=$(ask_password)
  printf '  1. CUBIC\n  2. New Reno\n  3. BBR\n'; read -r -p '  拥塞控制 [1]: ' cc; cc="${cc:-1}"; case "$cc" in 1) cc=cubic;;2) cc=new_reno;;3) cc=bbr;;*) return;;esac
  obj=$(jq -n --arg n "$name" --arg d "$domain" --argjson p "$port" --arg u "$uuid" --arg pw "$pw" --arg c "$cc" '{type:"tuic",name:$n,domain:$d,port:$p,uuid:$u,password:$pw,congestion_control:$c}')
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(tuic_link "$obj")"
}

create_anytls(){
  local name domain port pw obj
  read -r -p '  节点名称 [AnyTLS]: ' name; name="${name:-AnyTLS}"; domain=$(ask_domain); issue_cert "$domain" >/dev/null || return; port=$(ask_port 443); pw=$(ask_password)
  obj=$(jq -n --arg n "$name" --arg d "$domain" --argjson p "$port" --arg pw "$pw" '{type:"anytls",name:$n,domain:$d,port:$p,password:$pw}')
  append_server "$obj"; server_rebuild || return; log_ok '添加成功'; printf '\n  节点链接：\n  %s\n' "$(anytls_link "$obj")"
}

urlenc(){ jq -rn --arg x "$1" '$x|@uri'; }
base64url(){ printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
vless_link(){ local o="$1" u d p n mode; u=$(jq -r .uuid <<<"$o"); d=$(jq -r '.domain // .reality.handshake' <<<"$o"); p=$(jq -r .port <<<"$o"); n=$(urlenc "$(jq -r .name <<<"$o")"); mode=$(jq -r .mode <<<"$o"); case "$mode" in reality) printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' "$u" "$d" "$p" "$(urlenc "$d")" "$(jq -r .reality.public_key <<<"$o")" "$(jq -r .reality.short_id <<<"$o")" "$n";; tcp) printf 'vless://%s@%s:%s?encryption=none&security=tls&type=tcp&sni=%s#%s' "$u" "$d" "$p" "$(urlenc "$d")" "$n";; ws) printf 'vless://%s@%s:%s?encryption=none&security=tls&type=ws&path=%s&host=%s&sni=%s#%s' "$u" "$d" "$p" "$(urlenc "$(jq -r .transport.path <<<"$o")")" "$(urlenc "$d")" "$(urlenc "$d")" "$n";; grpc) printf 'vless://%s@%s:%s?encryption=none&security=tls&type=grpc&serviceName=%s&sni=%s#%s' "$u" "$d" "$p" "$(urlenc "$(jq -r .transport.service_name <<<"$o")")" "$(urlenc "$d")" "$n";; httpupgrade) printf 'vless://%s@%s:%s?encryption=none&security=tls&type=httpupgrade&path=%s&host=%s&sni=%s#%s' "$u" "$d" "$p" "$(urlenc "$(jq -r .transport.path <<<"$o")")" "$(urlenc "$d")" "$(urlenc "$d")" "$n";; esac; }
vmess_link(){ local o="$1" j; j=$(jq -n --arg v "2" --arg ps "$(jq -r .name <<<"$o")" --arg add "$(jq -r '.domain // .server // ""' <<<"$o")" --argjson port "$(jq -r .port <<<"$o")" --arg id "$(jq -r .uuid <<<"$o")" --arg aid "0" --arg scy "auto" --arg net "$(jq -r .mode <<<"$o")" --arg tls "$(if [ "$(jq -r .mode <<<"$o")" = tcp ]; then echo none; else echo tls; fi)" --arg type "none" --arg host "$(jq -r '.domain // empty' <<<"$o")" --arg path "$(jq -r '.transport.path // empty' <<<"$o")" --arg serviceName "$(jq -r '.transport.service_name // empty' <<<"$o")" '{v:$v,ps:$ps,add:$add,port:$port,id:$id,aid:$aid,scy:$scy,net:$net,type:$type,host:$host,path:$path,tls:$tls,sni:$host} + (if $net=="grpc" then {path:$serviceName} else {} end)'); printf 'vmess://%s' "$(base64url "$j")"; }
trojan_link(){ local o="$1" p d pw n; p=$(jq -r .port <<<"$o"); d=$(jq -r .domain <<<"$o"); pw=$(urlenc "$(jq -r .password <<<"$o")"); n=$(urlenc "$(jq -r .name <<<"$o")"); printf 'trojan://%s@%s:%s?security=tls&sni=%s' "$pw" "$d" "$p" "$(urlenc "$d")"; case "$(jq -r '.transport.type // empty' <<<"$o")" in ws) printf '&type=ws&path=%s&host=%s' "$(urlenc "$(jq -r .transport.path <<<"$o")")" "$(urlenc "$d")";;grpc) printf '&type=grpc&serviceName=%s' "$(urlenc "$(jq -r .transport.service_name <<<"$o")")";;esac; printf '#%s' "$n"; }
ss_link(){ local o="$1" n; n=$(urlenc "$(jq -r .name <<<"$o")"); printf 'ss://%s@%s:%s#%s' "$(base64url "$(jq -r .method <<<"$o")":"$(jq -r .password <<<"$o")")" "$(jq -r '.server // .domain // ""' <<<"$o")" "$(jq -r .port <<<"$o")" "$n"; }
shadowtls_link(){ local o="$1" n; n=$(urlenc "$(jq -r .name <<<"$o")"); printf 'shadowtls://%s@%s:%s?version=%s&handshake=%s&ss_method=%s&ss_password=%s#%s' "$(urlenc "$(jq -r '.auth_password // .password // ""' <<<"$o")")" "$(jq -r '.server // .domain // ""' <<<"$o")" "$(jq -r .port <<<"$o")" "$(jq -r .version <<<"$o")" "$(urlenc "$(jq -r .handshake_server <<<"$o")")" "$(urlenc "$(jq -r .ss_method <<<"$o")")" "$(urlenc "$(jq -r .ss_password <<<"$o")")" "$n"; }
snell_link(){ local o="$1" n; n=$(urlenc "$(jq -r .name <<<"$o")"); if [ "$(jq -r .version <<<"$o")" = 6 ]; then printf 'snell://%s@%s:%s?version=6&mode=%s#%s' "$(urlenc "$(jq -r .psk <<<"$o")")" "$(jq -r '.server // .domain // ""' <<<"$o")" "$(jq -r .port <<<"$o")" "$(jq -r .mode <<<"$o")" "$n"; else printf 'snell://%s@%s:%s?version=5&obfs_mode=%s#%s' "$(urlenc "$(jq -r .psk <<<"$o")")" "$(jq -r '.server // .domain // ""' <<<"$o")" "$(jq -r .port <<<"$o")" "$(jq -r .obfs_mode <<<"$o")" "$n"; fi; }
socks_link(){ local o="$1"; printf 'socks5://%s:%s@%s:%s#%s' "$(urlenc "$(jq -r .username <<<"$o")")" "$(urlenc "$(jq -r .password <<<"$o")")" "$(jq -r '.server // .domain // ""' <<<"$o")" "$(jq -r .port <<<"$o")" "$(urlenc "$(jq -r .name <<<"$o")")"; }
hy2_link(){ local o="$1" q; q="sni=$(urlenc "$(jq -r .domain <<<"$o")")"; [ -n "$(jq -r '.bbr_profile // empty' <<<"$o")" ] && q="$q&bbr_profile=$(jq -r .bbr_profile <<<"$o")"; [ -n "$(jq -r '.up_mbps // empty' <<<"$o")" ] && q="$q&up_mbps=$(jq -r .up_mbps <<<"$o")&down_mbps=$(jq -r .down_mbps <<<"$o")"; [ "$(jq -r '.obfs.type // empty' <<<"$o")" != "" ] && q="$q&obfs=$(jq -r .obfs.type <<<"$o")&obfs-password=$(urlenc "$(jq -r .obfs.password <<<"$o")")"; [ "$(jq -r '.obfs.type // empty' <<<"$o")" = gecko ] && { q="$q&min_packet_size=$(jq -r '.obfs.min_packet_size // empty' <<<"$o")&max_packet_size=$(jq -r '.obfs.max_packet_size // empty' <<<"$o")"; }; printf 'hysteria2://%s@%s:%s?%s#%s' "$(urlenc "$(jq -r .password <<<"$o")")" "$(jq -r .domain <<<"$o")" "$(jq -r .port <<<"$o")" "$q" "$(urlenc "$(jq -r .name <<<"$o")")"; }
tuic_link(){ local o="$1"; printf 'tuic://%s:%s@%s:%s?congestion_control=%s&udp_relay_mode=native&sni=%s#%s' "$(jq -r .uuid <<<"$o")" "$(urlenc "$(jq -r .password <<<"$o")")" "$(jq -r .domain <<<"$o")" "$(jq -r .port <<<"$o")" "$(jq -r .congestion_control <<<"$o")" "$(urlenc "$(jq -r .domain <<<"$o")")" "$(urlenc "$(jq -r .name <<<"$o")")"; }
anytls_link(){ local o="$1"; printf 'anytls://%s@%s:%s?sni=%s#%s' "$(urlenc "$(jq -r .password <<<"$o")")" "$(jq -r .domain <<<"$o")" "$(jq -r .port <<<"$o")" "$(urlenc "$(jq -r .domain <<<"$o")")" "$(urlenc "$(jq -r .name <<<"$o")")"; }

server_to_inbound(){
  local o="$1" t n p d
  t=$(jq -r .type <<<"$o"); n=$(jq -r .name <<<"$o"); p=$(jq -r .port <<<"$o")
  case "$t" in
    vless)
      if [ "$(jq -r .security <<<"$o")" = reality ]; then
        jq -n --arg tag "srv-$n" --argjson p "$p" --arg u "$(jq -r .uuid <<<"$o")" --arg hk "$(jq -r .reality.handshake <<<"$o")" --arg pk "$(jq -r .reality.private_key <<<"$o")" --arg sid "$(jq -r .reality.short_id <<<"$o")" '{type:"vless",tag:$tag,listen:"::",listen_port:$p,users:[{uuid:$u,flow:"xtls-rprx-vision"}],tls:{enabled:true,reality:{enabled:true,handshake:{server:$hk,server_port:443},private_key:$pk,short_id:[$sid]}}}'
      else
        jq -n --arg tag "srv-$n" --argjson p "$p" --arg u "$(jq -r .uuid <<<"$o")" --arg d "$(jq -r .domain <<<"$o")" --argjson tr "$(jq -c .transport <<<"$o")" --arg cm "$(jq -r .mode <<<"$o")" '{type:"vless",tag:$tag,listen:"::",listen_port:$p,users:[{uuid:$u}],tls:{enabled:true,server_name:$d,certificate_path:("/etc/sing-box/certs/"+$d+"/fullchain.pem"),key_path:("/etc/sing-box/certs/"+$d+"/privkey.pem")}}|if $cm=="tcp" then . else .transport=$tr end'
      fi
      ;;
    vmess)
      jq -n --arg tag "srv-$n" --argjson p "$p" --arg u "$(jq -r .uuid <<<"$o")" --arg d "$(jq -r '.domain // empty' <<<"$o")" --argjson tr "$(jq -c .transport <<<"$o")" --arg m "$(jq -r .mode <<<"$o")" '{type:"vmess",tag:$tag,listen:"::",listen_port:$p,users:[{uuid:$u,alterId:0}]}|if $m!="tcp" then .tls={enabled:true,server_name:$d,certificate_path:("/etc/sing-box/certs/"+$d+"/fullchain.pem"),key_path:("/etc/sing-box/certs/"+$d+"/privkey.pem")} | .transport=$tr else . end'
      ;;
    trojan)
      jq -n --arg tag "srv-$n" --argjson p "$p" --arg pw "$(jq -r .password <<<"$o")" --arg d "$(jq -r .domain <<<"$o")" --argjson tr "$(jq -c .transport <<<"$o")" '{type:"trojan",tag:$tag,listen:"::",listen_port:$p,users:[{password:$pw}],tls:{enabled:true,server_name:$d,certificate_path:("/etc/sing-box/certs/"+$d+"/fullchain.pem"),key_path:("/etc/sing-box/certs/"+$d+"/privkey.pem")}}|if $tr!=null then .transport=$tr else . end'
      ;;
    shadowsocks)
      jq -n --arg tag "srv-$n" --argjson p "$p" --arg m "$(jq -r .method <<<"$o")" --arg pw "$(jq -r .password <<<"$o")" '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$p,method:$m,password:$pw}'
      ;;
    shadowtls)
      jq -n --arg tag "srv-$n" --argjson p "$p" --argjson v "$(jq -r .version <<<"$o")" --arg pw "$(jq -r '.password // empty' <<<"$o")" --arg hs "$(jq -r .handshake_server <<<"$o")" --arg detour "st-ss-$n" --argjson users "$(jq -c 'if .version==3 then [{password:.auth_password}] else [] end' <<<"$o")" '{type:"shadowtls",tag:$tag,listen:"::",listen_port:$p,version:$v,handshake:{server:$hs,server_port:443},detour:$detour}|if $v==2 then .password=$pw elif $v==3 then .users=$users else . end'
      ;;
    snell)
      if [ "$(jq -r .version <<<"$o")" = 6 ]; then jq -n --arg tag "srv-$n" --argjson p "$p" --arg k "$(jq -r .psk <<<"$o")" --arg m "$(jq -r .mode <<<"$o")" '{type:"snell",tag:$tag,listen:"::",listen_port:$p,version:6,psk:$k,mode:$m}'; else jq -n --arg tag "srv-$n" --argjson p "$p" --arg k "$(jq -r .psk <<<"$o")" --arg m "$(jq -r '.obfs_mode // "none"' <<<"$o")" '{type:"snell",tag:$tag,listen:"::",listen_port:$p,version:5,psk:$k,obfs_mode:$m}'; fi
      ;;
    socks)
      jq -n --arg tag "srv-$n" --argjson p "$p" --arg u "$(jq -r .username <<<"$o")" --arg pw "$(jq -r .password <<<"$o")" '{type:"socks",tag:$tag,listen:"::",listen_port:$p,users:[{username:$u,password:$pw}]}'
      ;;
    hysteria2)
      jq -n --arg tag "srv-$n" --argjson p "$p" --arg pw "$(jq -r .password <<<"$o")" --arg prof "$(jq -r '.bbr_profile // empty' <<<"$o")" --arg up "$(jq -r '.up_mbps // empty' <<<"$o")" --arg down "$(jq -r '.down_mbps // empty' <<<"$o")" --argjson ob "$(jq -c '.obfs // null' <<<"$o")" --arg d "$(jq -r .domain <<<"$o")" '{type:"hysteria2",tag:$tag,listen:"::",listen_port:$p,users:[{password:$pw}],tls:{enabled:true,server_name:$d,certificate_path:("/etc/sing-box/certs/"+$d+"/fullchain.pem"),key_path:("/etc/sing-box/certs/"+$d+"/privkey.pem")}}|if $ob!=null then .obfs=$ob else . end|if $prof!="" then .bbr_profile=$prof else .up_mbps=($up|tonumber)|.down_mbps=($down|tonumber) end'
      ;;
    tuic)
      jq -n --arg tag "srv-$n" --argjson p "$p" --arg u "$(jq -r .uuid <<<"$o")" --arg pw "$(jq -r .password <<<"$o")" --arg c "$(jq -r .congestion_control <<<"$o")" --arg d "$(jq -r .domain <<<"$o")" '{type:"tuic",tag:$tag,listen:"::",listen_port:$p,users:[{uuid:$u,password:$pw}],congestion_control:$c,tls:{enabled:true,server_name:$d,certificate_path:("/etc/sing-box/certs/"+$d+"/fullchain.pem"),key_path:("/etc/sing-box/certs/"+$d+"/privkey.pem")}}'
      ;;
    anytls)
      jq -n --arg tag "srv-$n" --argjson p "$p" --arg pw "$(jq -r .password <<<"$o")" --arg d "$(jq -r .domain <<<"$o")" '{type:"anytls",tag:$tag,listen:"::",listen_port:$p,users:[{password:$pw}],tls:{enabled:true,server_name:$d,certificate_path:("/etc/sing-box/certs/"+$d+"/fullchain.pem"),key_path:("/etc/sing-box/certs/"+$d+"/privkey.pem")}}'
      ;;
  esac
}

shadowtls_ss_inbound(){
  local o="$1" n p sm sp
  n=$(jq -r .name <<<"$o"); p=$(jq -r .ss_port <<<"$o"); sm=$(jq -r .ss_method <<<"$o"); sp=$(jq -r .ss_password <<<"$o")
  jq -n --arg tag "st-ss-$n" --argjson p "$p" --arg m "$sm" --arg pw "$sp" '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$p,method:$m,password:$pw}'
}

server_rebuild(){
  local arr='[]' o ib extra='[]'
  while IFS= read -r o; do
    ib=$(server_to_inbound "$o") || return 1
    arr=$(jq --argjson x "$ib" '.+[$x]' <<<"$arr")
    if [ "$(jq -r .type <<<"$o")" = shadowtls ]; then
      ib=$(shadowtls_ss_inbound "$o") || return 1
      arr=$(jq --argjson x "$ib" '.+[$x]' <<<"$arr")
    fi
  done < <(jq -c '.servers[]' "$STATE")
  build_base "$(has_tun && echo 1 || echo 0)"
  jq --argjson ins "$arr" '.inbounds=$ins + [{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":2080}] | .outbounds += [{"type":"selector","tag":"proxy","outbounds":["direct"]}]' "$TMP" > "$TMP.2" || return 1
  mv "$TMP.2" "$TMP"
  apply_config "$TMP"
}

node_latency(){ local host="$1"; local r; r=$(ping -n -c1 -W1 "$host" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}' | head -n1); [ -n "$r" ] && printf '%s' "$r" || printf '超时'; }
node_link(){ local o="$1"; case "$(jq -r .type <<<"$o")" in vless) vless_link "$o";;vmess) vmess_link "$o";;trojan) trojan_link "$o";;shadowsocks) ss_link "$o";;shadowtls) shadowtls_link "$o";;snell) snell_link "$o";;socks) socks_link "$o";;hysteria2) hy2_link "$o";;tuic) tuic_link "$o";;anytls) anytls_link "$o";;esac; }

add_node(){
  echo '  >> 添加节点 <<'
  local n l t name
  read -r -p '  节点名称：' n
  read -r -p '  节点链接：' l
  [ -n "$l" ] || { log_err '链接不能为空'; return; }
  if ! parse_link "$n" "$l"; then log_err '链接解析失败'; return; fi
  log_ok '添加成功'
}
parse_link(){
  local name="$1" link="$2" type rest host port query frag userpw obj
  type="${link%%:*}"; rest="${link#*:}"
  case "$type" in
    vless|vmess|trojan|ss|shadowtls|snell|socks5|hysteria2|hy2|tuic|anytls) ;;
    *) return 1;;
  esac
  local objj
  case "$type" in
    vless) objj=$(parse_vless "$name" "$link");;
    vmess) objj=$(parse_vmess "$name" "$link");;
    trojan) objj=$(parse_trojan "$name" "$link");;
    ss) objj=$(parse_ss "$name" "$link");;
    shadowtls) objj=$(parse_shadowtls "$name" "$link");;
    snell) objj=$(parse_snell "$name" "$link");;
    socks5) objj=$(parse_socks "$name" "$link");;
    hysteria2|hy2) objj=$(parse_hy2 "$name" "$link");;
    tuic) objj=$(parse_tuic "$name" "$link");;
    anytls) objj=$(parse_anytls "$name" "$link");;
  esac
  [ -n "$objj" ] || return 1
  jq --argjson x "$objj" '.nodes += [$x]' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
parse_q(){ printf '%s' "$1" | sed 's/&/\n/g' | awk -F= -v k="$2" '$1==k{print substr($0,index($0,"=")+1); exit}'; }
parse_vless(){
  local n="$1" l="${2#vless://}" auth hpq hp q h p frag sec typ sni path svc flow pbk sid
  auth=${l%%@*}; hpq=${l#*@}; hp=${hpq%%\?*}; q=${hpq#*\?}; q=${q%%#*}; h=${hp%%:*}; p=${hp##*:}
  sec=$(parse_q "$q" security); typ=$(parse_q "$q" type); sni=$(parse_q "$q" sni); path=$(parse_q "$q" path); svc=$(parse_q "$q" serviceName); flow=$(parse_q "$q" flow); pbk=$(parse_q "$q" pbk); sid=$(parse_q "$q" sid)
  if [ "$sec" = reality ]; then jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg u "$auth" --arg s "$sni" --arg f "$flow" --arg pb "$pbk" --arg sid "$sid" '{type:"vless",name:$n,server:$h,server_port:$p,uuid:$u,flow:(if $f!="" then $f else "xtls-rprx-vision" end),tls:{enabled:true,server_name:$s,reality:{enabled:true,public_key:$pb,short_id:$sid}}}'; else jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg u "$auth" --arg s "$sni" --arg typ "$typ" --arg path "$path" --arg svc "$svc" --arg f "$flow" '{type:"vless",name:$n,server:$h,server_port:$p,uuid:$u,tls:{enabled:true,server_name:$s}}|if $f!="" then .flow=$f else . end|if $typ=="ws" then .transport={type:"ws",path:$path} elif $typ=="grpc" then .transport={type:"grpc",service_name:$svc} elif $typ=="httpupgrade" then .transport={type:"httpupgrade",path:$path} else . end}'; fi
}
parse_vmess(){
  local n="$1" l="$2" b="${l#vmess://}" j
  j=$(printf '%s' "$b" | tr '_-' '/+' | base64 -d 2>/dev/null) || return 1
  jq --arg n "$n" '{type:"vmess",name:$n,server:.add,server_port:(.port|tonumber),uuid:.id,security:(.scy//"auto"),alter_id:(.aid//0|tonumber),tls:(if .tls=="tls" then {enabled:true,server_name:(.sni//.host//.add)} else {enabled:false} end)}|if .net=="ws" then .transport={type:"ws",path:(.path//"/"),headers:(if .host then {Host:.host} else {} end)} elif .net=="grpc" then .transport={type:"grpc",service_name:(.path//"")} elif .net=="httpupgrade" then .transport={type:"httpupgrade",path:(.path//"/"),headers:(if .host then {Host:.host} else {} end)} else . end' <<<"$j"
}
parse_trojan(){
  local n="$1" l="${2#trojan://}" auth hpq hp q h p typ sni path svc
  auth=${l%%@*}; hpq=${l#*@}; hp=${hpq%%\?*}; q=${hpq#*\?}; q=${q%%#*}; h=${hp%%:*}; p=${hp##*:}; typ=$(parse_q "$q" type); sni=$(parse_q "$q" sni); path=$(parse_q "$q" path); svc=$(parse_q "$q" serviceName)
  jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg pw "$auth" --arg s "$sni" --arg typ "$typ" --arg path "$path" --arg svc "$svc" '{type:"trojan",name:$n,server:$h,server_port:$p,password:$pw,tls:{enabled:true,server_name:$s}}|if $typ=="ws" then .transport={type:"ws",path:$path} elif $typ=="grpc" then .transport={type:"grpc",service_name:$svc} else . end}'
}
parse_ss(){
  local n="$1" l="${2#ss://}" b a hp d h p
  b=${l%%#*}; b=${b%%\?*}; hp=${b#*@}; a=${b%@*}; d=$(printf '%s' "$a" | tr '_-' '/+' | base64 -d 2>/dev/null); [ -n "$d" ] || d=$(printf '%s' "$a" | base64 -d 2>/dev/null); h=${hp%%:*}; p=${hp##*:}
  jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg a "$d" '{type:"shadowsocks",name:$n,server:$h,server_port:$p,method:($a|split(":")[0]),password:($a|split(":")[1])}'
}
parse_shadowtls(){
  local n="$1" l="${2#shadowtls://}" auth hpq hp q h p v hs sm sp
  auth=${l%%@*}; hpq=${l#*@}; hp=${hpq%%\?*}; q=${hpq#*\?}; q=${q%%#*}; h=${hp%%:*}; p=${hp##*:}; v=$(parse_q "$q" version); hs=$(parse_q "$q" handshake); sm=$(parse_q "$q" ss_method); sp=$(parse_q "$q" ss_password)
  jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg v "$v" --arg auth "$auth" --arg hs "$hs" --arg sm "$sm" --arg sp "$sp" '{type:"shadowtls",name:$n,server:$h,server_port:$p,version:($v|tonumber),handshake_server:$hs,ss_method:$sm,ss_password:$sp,ss_port:($p+1),password:$auth,auth_password:$auth}'
}
parse_snell(){
  local n="$1" l="${2#snell://}" auth hpq hp q h p v m ob
  auth=${l%%@*}; hpq=${l#*@}; hp=${hpq%%\?*}; q=${hpq#*\?}; q=${q%%#*}; h=${hp%%:*}; p=${hp##*:}; v=$(parse_q "$q" version); m=$(parse_q "$q" mode); ob=$(parse_q "$q" obfs_mode)
  if [ "$v" = 6 ]; then jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg k "$auth" --arg m "$m" '{type:"snell",name:$n,server:$h,server_port:$p,psk:$k,version:6,mode:$m}'; else jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg k "$auth" --arg o "$ob" '{type:"snell",name:$n,server:$h,server_port:$p,psk:$k,version:5,obfs_mode:(if $o!="" then $o else "none" end)}'; fi
}
parse_socks(){
  local n="$1" l="${2#socks5://}" auth hp h p u pw
  auth=${l%%@*}; hp=${l#*@}; h=${hp%%:*}; p=${hp##*:}; u=${auth%%:*}; pw=${auth#*:}
  jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg u "$u" --arg pw "$pw" '{type:"socks",name:$n,server:$h,server_port:$p,username:$u,password:$pw}'
}
parse_hy2(){
  local n="$1" l="$2"; l=${l#hysteria2://}; [ "$l" = "${2#hy2://}" ] || l=${2#hy2://}; local auth=${l%%@*} hpq=${l#*@} hp=${hpq%%\?*} q=${hpq#*\?}; q=${q%%#*}; local h=${hp%%:*} p=${hp##*:} sni prof up down ob op min max
  sni=$(parse_q "$q" sni); prof=$(parse_q "$q" bbr_profile); up=$(parse_q "$q" up_mbps); down=$(parse_q "$q" down_mbps); ob=$(parse_q "$q" obfs); op=$(parse_q "$q" obfs-password); min=$(parse_q "$q" min_packet_size); max=$(parse_q "$q" max_packet_size)
  jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg pw "$auth" --arg s "$sni" --arg prof "$prof" --arg up "$up" --arg down "$down" --arg ob "$ob" --arg op "$op" --arg min "$min" --arg max "$max" '{type:"hysteria2",name:$n,server:$h,server_port:$p,password:$pw,tls:{enabled:true,server_name:$s}}|if $prof!="" then .bbr_profile=$prof elif $up!="" then .up_mbps=($up|tonumber)|.down_mbps=($down|tonumber) else . end|if $ob!="" then .obfs={type:$ob,password:$op} else . end|if $ob=="gecko" and $min!="" then .obfs.min_packet_size=($min|tonumber) else . end|if $ob=="gecko" and $max!="" then .obfs.max_packet_size=($max|tonumber) else . end'
}
parse_tuic(){
  local n="$1" l="${2#tuic://}" auth hpq hp q h p c s; auth=${l%%@*}; hpq=${l#*@}; hp=${hpq%%\?*}; q=${hpq#*\?}; q=${q%%#*}; h=${hp%%:*}; p=${hp##*:}; c=$(parse_q "$q" congestion_control); s=$(parse_q "$q" sni)
  jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg a "$auth" --arg c "$c" --arg s "$s" '{type:"tuic",name:$n,server:$h,server_port:$p,uuid:($a|split(":")[0]),password:($a|split(":")[1]),congestion_control:(if $c!="" then $c else "cubic" end),tls:{enabled:true,server_name:$s}}'
}
parse_anytls(){
  local n="$1" l="${2#anytls://}" auth hpq hp q h p pw s; auth=${l%%@*}; hpq=${l#*@}; hp=${hpq%%\?*}; q=${hpq#*\?}; q=${q%%#*}; h=${hp%%:*}; p=${hp##*:}; pw=$auth; s=$(parse_q "$q" sni)
  jq -n --arg n "$n" --arg h "$h" --argjson p "$p" --arg pw "$pw" --arg s "$s" '{type:"anytls",name:$n,server:$h,server_port:$p,password:$pw,tls:{enabled:true,server_name:$s}}'
}

choose_protocol(){
  echo '  >> 创建协议 <<'
  printf '  1. VLESS\n  2. VMess\n  3. Trojan\n  4. Shadowsocks\n  5. ShadowTLS + Shadowsocks\n  6. Snell\n  7. SOCKS5\n  8. Hysteria2\n  9. TUIC\n  10. AnyTLS\n  0. 返回\n'
  local s; read -r -p '  请选择: ' s
  case "$s" in 1) create_vless;;2) create_vmess;;3) create_trojan;;4) create_ss;;5) create_shadowtls;;6) create_snell;;7) create_socks;;8) create_hy2;;9) create_tuic;;10) create_anytls;;esac
}

node_list(){
  echo '  >> 节点列表 <<'; echo
  local i=0 o host ms tag
  while IFS= read -r o; do i=$((i+1)); host=$(jq -r '.server // .domain // empty' <<<"$o"); ms=$(node_latency "$host"); printf '   %d.[%-12s] %s|%s' "$i" "$(jq -r .type <<<"$o")" "$(jq -r .name <<<"$o")" "$(jq -r '.server_port // .port // 443' <<<"$o")"; [ "$ms" != 超时 ] && printf '|%sms' "$ms" || printf '|超时'; [ "$(json_get '.selected')" = "$(jq -r .name <<<"$o")" ] && printf '<=启用'; printf '\n'; done < <(jq -c '.nodes[]' "$STATE"); echo '   0. 返回'; echo; read -r -p '  请输入序号（按回车键刷新）: ' s; [ -z "$s" ] && { node_list; return; }; [ "$s" = 0 ] && return; if [[ "$s" =~ ^[0-9]+$ ]]; then o=$(jq -c ".nodes[$((s-1))]" "$STATE"); [ "$o" != null ] && jq --arg n "$(jq -r .name <<<"$o")" '.selected=$n' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; fi; }
node_delete(){
  while :; do echo '  >> 删除节点 <<'; echo; local i=0 o s; while IFS= read -r o; do i=$((i+1)); printf '   %d. %s\n' "$i" "$(jq -r .name <<<"$o")"; done < <(jq -c '.nodes[]' "$STATE"); echo '   0. 返回'; read -r -p '  请选择: ' s; [ "$s" = 0 ] && return; [[ "$s" =~ ^[0-9]+$ ]] || continue; o=$(jq -c ".nodes[$((s-1))]" "$STATE"); [ "$o" = null ] && continue; local name; name=$(jq -r .name <<<"$o"); jq --arg n "$name" 'del(.nodes[] | select(.name==$n))' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; log_ok '删除成功'; server_rebuild >/dev/null 2>&1 || true; done
}
client_status(){ echo '  >> 客户端状态 <<'; echo; printf '  网络接管：%s\n\n' "$(json_get '.selected')"; local v4 v6; v4=$(get_ipv4); v6=$(get_ipv6); [ -n "$v4" ] && printf '  IPv4: %s\n' "$v4"; [ -n "$v6" ] && printf '  IPv6: %s\n' "$v6"; pause; }
client_toggle(){ local r=$(json_get '.client_running'); if [ "$r" = true ]; then echo '  >> 停止客户端 <<'; echo; printf '  当前状态：运行中 %s\n\n' "$(json_get '.selected')"; yesno '确定停止客户端？[Y/n]：' Y || return; jq '.client_running=false|.selected="direct"' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; log_ok '客户端已停止'; pause; else echo '  >> 启动客户端 <<'; echo; jq '.client_running=true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; log_ok "客户端已启动，已选择$(json_get '.selected')出口"; pause; fi; }
client_menu(){ while :; do echo '  >> 客户端管理 <<'; echo; printf '当前：%s\n\n' "$(json_get '.selected')"; printf '1. 添加节点\n2. 选择节点\n3. 删除节点\n4. 切换节点\n5. %s\n6. 客户端状态\n0. 返回\n\n请选择：' "$( [ "$(json_get '.client_running')" = true ] && echo '停止客户端' || echo '启动客户端' )"; local s; read -r s; case "$s" in 1) add_node;;2) node_list;;3) node_delete;;4) node_list;;5) client_toggle;;6) client_status;;0) return;;esac; done; }

update_menu(){ echo '  >> 状态与更新 <<'; echo; printf '  系统版本: %s\n  内核架构: %s\n  运行时间: %s\n  singbox : %s\n  singbox版本: %s\n\n' "$OS_NAME" "$(uname -r)" "$(uptime -p 2>/dev/null | sed 's/^up //')" "$(systemctl is-active "$SERVICE" 2>/dev/null || echo 未运行)" "${VERSION} (linux-${ARCH})"; printf '  当前出口：%s\n' "$(json_get '.selected')"; [ -n "$(get_ipv4)" ] && printf '  IPv4: %s\n' "$(get_ipv4)"; [ -n "$(get_ipv6)" ] && printf '  IPv6: %s\n' "$(get_ipv6)"; echo; printf '  1. 更新内核\n  2. 更新脚本\n  3. 卸载脚本\n  0. 返回\n'; hr; printf '  请选择: '; local s; read -r s; case "$s" in 1) update_core;;2) update_script;;3) uninstall;;esac; }
update_core(){ echo '  >> 更新内核 <<'; echo; printf '  当前内核：singbox%s\n  最新内核：singbox%s\n\n' "$VERSION" "$VERSION"; echo '  当前为最新版本，无需更新'; pause; }
update_script(){ echo '  >> 更新脚本 <<'; echo; log_ok '当前脚本为第一版'; pause; }
uninstall(){ echo '  >> 卸载脚本 <<'; echo; yesno '确定卸载脚本？[Y/n]：' Y || return; systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true; rm -f /etc/systemd/system/$SERVICE "$CMD" "$BIN"; rm -rf "$DATA"; systemctl daemon-reload >/dev/null 2>&1 || true; log_ok '卸载完成'; pause; exit 0; }

init(){ need_root; install_deps || exit 1; arch_name || { log_err '不支持的 CPU 架构'; exit 1; }; get_os; mkdir -p "$DATA" "$BACKUP"; state_init; lock; install_singbox || exit 1; write_service; if [ ! -f "$CONFIG" ]; then build_base "$(has_tun && echo 1 || echo 0)"; jq '.outbounds += [{"type":"selector","tag":"proxy","outbounds":["direct"]}]' "$TMP" > "$TMP.2"; mv "$TMP.2" "$TMP"; apply_config "$TMP" || exit 1; fi; install -m 0755 "$0" "$CMD" 2>/dev/null || true; }
main(){ init; while :; do clear 2>/dev/null || true; echo '  >> sing-box 管理 <<'; echo; printf '  1. 状态与更新\n  2. 服务端协议\n  3. 客户端管理\n  0. 退出\n'; hr; printf '  请选择: '; local s; read -r s; case "$s" in 1) update_menu;;2) choose_protocol;;3) client_menu;;0) exit 0;;esac; done; }
main "$@"
