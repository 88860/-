#!/usr/bin/env bash
export LC_ALL=C
shopt -s nullglob

RED='\033[1;91m'
GREEN='\033[1;92m'
CYAN='\033[1;96m'
YELLOW='\033[1;93m'
PURPLE='\033[1;95m'
BLUE='\033[1;94m'
WHITE='\033[1;97m'
BROWN='\033[1;38;5;214m'
DIM='\033[2m'
BOLD='\033[1m'
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
REAPPLY_LOCK=$SBM_DIR/reapply.lock
CONFIG_LOCK=$SBM_DIR/config.lock
MANAGER_LOCK=/run/lock/sbm-manager.lock
SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SHORTCUT=/usr/local/bin/s
CORE=/usr/local/bin/sing-box
SERVICE_UNIT=/etc/systemd/system/sing-box.service
DROPIN_DIR=/etc/systemd/system/sing-box.service.d
DROPIN=$DROPIN_DIR/sbm.conf
GH_API=https://api.github.com/repos/SagerNet/sing-box
PROBE_URL=http://cp.cloudflare.com/generate_204
TUN_IF=sbmtun
WG_IF=sbmwg
WARP_DIR=$SBM_DIR/warp
WARP_CONF=$WARP_DIR/config.json
WARP_IF=warp
WARP_API=https://api.cloudflareclient.com/v0a2158/reg
WARP_TRACE=https://www.cloudflare.com/cdn-cgi/trace
CERT_TAG=acme-cert
HOP_TABLE=sbm_hop
read_line(){
  local value
  if [ -c /dev/tty ]; then
    IFS= read -r value </dev/tty || return 1
  else
    IFS= read -r value || return 1
  fi
  value="${value%$'\r'}"
  printf '%s' "$value"
}

prompt(){
  local msg="$1" def="$2" value out=/dev/stderr
  [ -c /dev/tty ] && out=/dev/tty
  if [[ "$msg" == 请选择* ]]; then
    printf "\n${DIM}${CYAN}....................${PLAIN}\n" >"$out"
  fi
  if [ -n "$def" ]; then
    printf "${BOLD}${YELLOW}. %s [%s]: ${PLAIN}" "$msg" "$def" >"$out"
  else
    printf "${BOLD}${YELLOW}. %s: ${PLAIN}" "$msg" >"$out"
  fi
  value=$(read_line "$def") || { kill -TERM "$$"; return 1; }
  echo "${value:-$def}"
}

prompt_yes(){
  local value def=${2:-n}; value=$(prompt "$1 (y/N)" "$def")
  [ "$value" = y ] || [ "$value" = Y ]
}

wait_key(){
  printf "\n${DIM}❯ 按回车键继续...${PLAIN}" >&2
  read_line >/dev/null
}

tell(){ local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; echo -e "${WHITE}$s${PLAIN}"; }
tell_ok(){ local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; echo -e "${BOLD}${GREEN}[✓] $s${PLAIN}"; }
tell_warn(){ local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; echo -e "${BOLD}${RED}[✗] $s${PLAIN}"; }
tell_alert(){ local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; echo -e "${BOLD}${YELLOW}[!] $s${PLAIN}"; }

ui_clear(){ clear 2>/dev/null || printf "\033[2J\033[H"; }
ui_title(){ ui_clear; printf "${BOLD}${CYAN}%s${PLAIN}\n${DIM}${CYAN}....................${PLAIN}\n" "$1"; }
menu_item(){ printf "${BOLD}${CYAN}%s.${PLAIN} ${BOLD}${WHITE}%s${PLAIN}\n" "$1" "$2"; }

uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }
uri_decode(){ local s=${1//\\/\\\\}; printf '%b' "${s//%/\\x}"; }
slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){
  local value
  value=$(openssl rand -hex 16 2>/dev/null) || value=""
  if [[ ! "$value" =~ ^[a-f0-9]{32}$ ]]; then
    value=$(tr -dc 'a-f0-9' </dev/urandom | head -c32)
  fi
  [[ "$value" =~ ^[a-f0-9]{32}$ ]] || return 1
  printf '%s\n' "$value"
}
random_uuid(){ cat /proc/sys/kernel/random/uuid; }
validate_uuid(){ [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
random_port(){ shuf -i 20000-60000 -n1; }
init_dirs(){
  mkdir -p "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box || return 1
  chmod 700 "$SBM_DIR" "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box || return 1
  state_init || return 1
  [ -f "$PKG_LOG" ] || : >"$PKG_LOG" || return 1
}
ensure_command(){
  local cmd=$1 pkg=${2:-$1}
  command -v "$cmd" >/dev/null 2>&1 && return 0
  local guard=0
  while command -v fuser >/dev/null 2>&1 && { fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; }; do
    sleep 1; guard=$((guard+1)); [ "$guard" -gt 30 ] && break
  done
  tell "${CYAN}安装依赖：$pkg${PLAIN}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$pkg" >/dev/null 2>&1 || return 1
  command -v "$cmd" >/dev/null 2>&1 || return 1
  grep -qx "$pkg" "$PKG_LOG" 2>/dev/null || echo "$pkg" >>"$PKG_LOG"
}
check_dependencies(){
  local cmd pkg
  local deps=(
    "curl:curl" "tar:tar" "jq:jq" "openssl:openssl" "nft:nftables"
    "ss:iproute2" "ip:iproute2" "flock:util-linux" "pkill:procps" "sysctl:procps"
    "grep:grep" "sed:sed" "find:findutils" "shuf:coreutils" "timeout:coreutils"
    "install:coreutils" "mkdir:coreutils" "chmod:coreutils" "cat:coreutils" "tr:coreutils"
    "cut:coreutils" "head:coreutils" "tail:coreutils" "sort:coreutils" "date:coreutils"
    "sleep:coreutils" "seq:coreutils" "mv:coreutils" "rm:coreutils" "cp:coreutils" "id:coreutils"
    "uname:coreutils" "mktemp:coreutils" "ln:coreutils" "rmdir:coreutils"
    "systemctl:systemd" "journalctl:systemd" "modprobe:kmod" "ping:iputils-ping" "fuser:psmisc" "cmp:diffutils"
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

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}[×] 权限不足: 请使用 root 用户运行${PLAIN}"; exit 1; }

menu_create_protocol(){
  while :; do
    ui_title "创建协议"
    menu_item 1 "VLESS"; menu_item 2 "Trojan"; menu_item 3 "Hysteria2"; menu_item 4 "TUIC"
    menu_item 5 "Shadowsocks"; menu_item 6 "VMess"; menu_item 7 "AnyTLS"; menu_item 8 "SOCKS5"; menu_item 9 "Snell"
    menu_item 0 "返回";     case $(prompt "请选择") in
      1) menu_create_vless ;; 2) menu_create_trojan ;; 3) create_hysteria2; break ;;
      4) create_tuic; break ;; 5) menu_create_shadowsocks ;; 6) menu_create_vmess ;;
      7) create_anytls; break ;; 8) create_socks; break ;; 9) create_snell; break ;; 0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

menu_create_vless(){
  while :; do
    ui_title "VLESS 搭配"
    menu_item 1 "Reality"; menu_item 2 "TLS"; menu_item 3 "WebSocket"; menu_item 4 "gRPC"; menu_item 0 "返回"
    case $(prompt "请选择") in
      1) create_vless_reality; return ;; 2) create_vless_tls; return ;;
      3) create_vless_transport ws; return ;; 4) create_vless_transport grpc; return ;;
      0) return ;; *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

menu_create_trojan(){
  while :; do
    ui_title "Trojan 搭配"
    menu_item 1 "TLS"; menu_item 2 "WebSocket"; menu_item 3 "gRPC"; menu_item 0 "返回"
    case $(prompt "请选择") in
      1) create_trojan; return ;; 2) create_trojan_transport ws; return ;;
      3) create_trojan_transport grpc; return ;; 0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

menu_create_shadowsocks(){
  while :; do
    ui_title "Shadowsocks 加密"
    menu_item 1 "2022 · AES-128-GCM"; menu_item 2 "2022 · AES-256-GCM"
    menu_item 3 "2022 · ChaCha20-Poly1305"; menu_item 4 "AES-128-GCM"; menu_item 5 "AES-192-GCM"
    menu_item 6 "AES-256-GCM"; menu_item 7 "ChaCha20-IETF-Poly1305"; menu_item 8 "XChaCha20-IETF-Poly1305"; menu_item 0 "返回"
    case $(prompt "请选择") in
      1) create_shadowsocks 2022-blake3-aes-128-gcm; return ;;
      2) create_shadowsocks 2022-blake3-aes-256-gcm; return ;;
      3) create_shadowsocks 2022-blake3-chacha20-poly1305; return ;;
      4) create_shadowsocks aes-128-gcm; return ;; 5) create_shadowsocks aes-192-gcm; return ;;
      6) create_shadowsocks aes-256-gcm; return ;; 7) create_shadowsocks chacha20-ietf-poly1305; return ;;
      8) create_shadowsocks xchacha20-ietf-poly1305; return ;;
      0) return ;; *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

menu_create_vmess(){
  while :; do
    ui_title "VMess 搭配"
    menu_item 1 "TLS"; menu_item 2 "WebSocket + TLS"; menu_item 3 "gRPC + TLS"; menu_item 4 "HTTP + TLS"; menu_item 0 "返回"
    case $(prompt "请选择") in
      1) create_vmess tls; return ;; 2) create_vmess ws; return ;;
      3) create_vmess grpc; return ;; 4) create_vmess http; return ;;
      0) return ;; *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

menu_delete_protocol(){
  local file was_acme status acme_cleanup_failed=0
  ui_title "删除协议"
  select_node file "删除协议" || return
  prompt_yes "确认删除 $(server_node_name "$file")" || return
  was_acme=$(server_node_tls_mode "$file") || return 1

  if server_delete_node_transaction "$file"; then
    tell_ok "已删除"
  else
    status=$?
    case $status in
      2) tell_warn "删除操作未完成，请检查文件权限"; wait_key; return ;;
      3) tell_warn "节点已删除，但 sing-box 配置应用失败，服务已停止" ;;
      4) tell_warn "节点已删除且配置已应用，但出口状态或 watchdog 同步失败，请检查状态与健康检测服务" ;;
    esac
  fi
  if [ "$was_acme" = "acme" ] && [ "$(server_acme_node_count)" -eq 0 ] && [ -n "$(state_get domain)" ]; then
    state_acme_clear_identity || acme_cleanup_failed=1
    rm -rf -- "$ACME_DIR" || acme_cleanup_failed=1
    [ ! -e "$ACME_DIR" ] || acme_cleanup_failed=1
    if [ "$acme_cleanup_failed" -eq 0 ]; then
      tell_ok "最后一个 ACME 节点已删除，域名、证书及验证凭据已清理"
    else
      tell_warn "ACME 节点已删除，但域名、证书或验证凭据清理不完整"
    fi
  fi
  wait_key
}

render_certificate_status(){
  local domain crt expiry days file
  domain=$(state_get domain) || return 1; [ -n "$domain" ] || return 0
  tell ""; tell "全局域名: $domain | 验证: $(state_get challenge)"
  crt=""
  while IFS= read -r file; do
    if openssl x509 -in "$file" -noout -checkhost "$domain" >/dev/null 2>&1; then crt="$file"; break; fi
  done < <(find "$ACME_DIR" -type f -name '*.crt' 2>/dev/null)
  [ -n "$crt" ] || { tell "${YELLOW}证书状态: 未找到匹配域名的证书${PLAIN}"; return 0; }
  expiry=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
  [ -n "$expiry" ] || { tell "${RED}证书状态: 无法读取${PLAIN}"; return 0; }
  days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  tell "到期时间: $expiry | 剩余: ${days} 天"
  systemctl is-active --quiet sing-box || tell_warn "服务离线，无法自动续期"
}

menu_server_info(){
  local file port transport status count=0 tcp_list udp_list tcp_ok udp_ok
  tcp_list=$(singbox_listening_ports t); udp_list=$(singbox_listening_ports u)
  ui_title "服务端信息"
  systemctl is-active --quiet sing-box && tell_ok "singbox: 运行中" || tell_warn "singbox: 未运行"
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    count=$((count+1)); port=$(jq -r '.port // ""' "$file" 2>/dev/null) || return 1
    transport=$(server_node_transport "$file") || return 1
    status=""
    if [[ "$transport" == *t* ]]; then
      tcp_ok=0; grep -qx "$port" <<<"$tcp_list" && tcp_ok=1
    fi
    if [[ "$transport" == *u* ]]; then
      udp_ok=0; grep -qx "$port" <<<"$udp_list" && udp_ok=1
    fi
    if [ "$transport" = tu ]; then
      if [ "$tcp_ok" = 1 ] && [ "$udp_ok" = 1 ]; then
        status="${GREEN}TCP/UDP正常监听${PLAIN}"
      elif [ "$tcp_ok" = 0 ] && [ "$udp_ok" = 0 ]; then
        status="${RED}TCP/UDP均异常${PLAIN}"
      else
        [ "$tcp_ok" = 1 ] && status="${GREEN}TCP正常监听${PLAIN}" || status="${RED}TCP异常${PLAIN}"
        status="$status "
        [ "$udp_ok" = 1 ] && status="${status}${GREEN}UDP正常监听${PLAIN}" || status="${status}${RED}UDP异常${PLAIN}"
      fi
    elif [ "$transport" = u ]; then
      [ "$udp_ok" = 1 ] && status="${GREEN}UDP正常监听${PLAIN}" || status="${RED}UDP异常${PLAIN}"
    else
      [ "$tcp_ok" = 1 ] && status="${GREEN}TCP正常监听${PLAIN}" || status="${RED}TCP异常${PLAIN}"
    fi
    tell ""; tell "$(server_node_name "$file") [$(server_node_kind "$file")] | 端口 $port $status"
    render_share_uri "$file"
  done
  [ "$count" = 0 ] && tell "\n暂无节点"
  render_certificate_status; wait_key
}

menu_change_domain(){
  local new_domain old_state file count=0 email mode had_new_assets=0
  ui_title "更换域名"
  tell "当前域名: $(state_get domain || true)"; tell "绑定节点:"
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    if [ "$(server_node_tls_mode "$file")" = acme ]; then tell "- $(server_node_name "$file") [$(server_node_kind "$file")]"; count=$((count+1)); fi
  done
  [ "$count" = 0 ] && tell "无"
  echo ""
  new_domain=$(prompt "新域名 (输入当前域名可修改证书验证设置，留空取消)"); [ -z "$new_domain" ] && return
  old_state=$(state_snapshot) || { tell_warn "状态读取失败，无法修改域名"; wait_key; return; }
  acme_domain_assets_exist "$new_domain" && had_new_assets=1
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; wait_key; return; }
  if prompt_yes "同步重置验证机制"; then
    email=$(prompt "ACME 通知邮箱" "admin@$new_domain"); [ -n "$email" ] || { wait_key; return; }
    printf '\n%b选择证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
    echo "1. HTTP         (推荐 需放行80端口)"
    echo "2. TLS-ALPN     (推荐 需放行443端口)"
    echo "3. Cloudflare API"
    echo "4. 阿里云 DNS API"
    echo "5. ACME-DNS API"
    while :; do
      case $(prompt "请选择方式" 1) in
        1) mode=http; break ;;
        2) mode=alpn; break ;;
        3) mode=dns_cloudflare
           state_set cf_token "$(prompt 'Cloudflare API Token')" || { state_restore "$old_state" || tell_warn "ACME 状态恢复失败"; tell_warn "Cloudflare 凭据保存失败"; wait_key; return 1; }
           break ;;
        4) mode=dns_alidns
           state_set ali_key "$(prompt 'AccessKeyId')" && state_set ali_secret "$(prompt 'AccessKeySecret')" || { state_restore "$old_state" || tell_warn "ACME 状态恢复失败"; tell_warn "阿里云凭据保存失败"; wait_key; return 1; }
           break ;;
        5) mode=dns_acmedns
           state_set acmedns_url "$(prompt 'server_url')" && state_set acmedns_user "$(prompt 'username')" &&
           state_set acmedns_pass "$(prompt 'password')" && state_set acmedns_sub "$(prompt 'subdomain')" || { state_restore "$old_state" || tell_warn "ACME 状态恢复失败"; tell_warn "ACME-DNS 凭据保存失败"; wait_key; return 1; }
           break ;;
        *) tell_warn "输入无效，请重新选择"; sleep 1
           ui_clear
           printf '\n%b选择证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
           echo "1. HTTP         (推荐 需放行80端口)"
           echo "2. TLS-ALPN     (推荐 需放行443端口)"
           echo "3. Cloudflare API"
           echo "4. 阿里云 DNS API"
           echo "5. ACME-DNS API" ;;
      esac
    done
    state_set challenge "$mode" && state_set email "$email" || { state_restore "$old_state" || tell_warn "ACME 状态恢复失败"; tell_warn "证书配置保存失败"; wait_key; return 1; }
  fi
  if ! validate_domain "$new_domain"; then
    if ! prompt_yes "解析验证存在异常，是否继续"; then
      state_restore "$old_state" || tell_warn "状态恢复失败，请手动检查域名验证配置"
      wait_key
      return
    fi
  fi
  if server_change_domain_transaction "$new_domain" "$old_state" "$had_new_assets"; then
    tell_ok "新域名证书已签发并完成校验"
    tell_ok "域名已正式切换为: $new_domain"
    tell_ok "所有已配置域名节点已同步使用新域名"
    menu_server_info
  else
    status=$?
    case $status in
      2) tell_warn "新域名 ACME 配置生成失败" ;;
      3) tell_warn "新域名 ACME 配置校验失败" ;;
      4) tell_warn "证书未成功签发，域名切换已回滚" ;;
      5) tell_warn "新域名正式切换失败，已恢复旧配置" ;;
      *) tell_warn "域名切换失败，已回滚" ;;
    esac
    wait_key
  fi
}

menu_server(){
  local previous
  while :; do
    ui_title "服务端管理"
    menu_item 1 "创建协议"; menu_item 2 "删除协议"; menu_item 3 "修改配置"; menu_item 4 "服务端信息"
    menu_item 5 "更换域名"; menu_item 6 "重启服务"; menu_item 7 "停止服务"; menu_item 0 "返回"
        case $(prompt "请选择") in
      1) menu_create_protocol ;; 2) menu_delete_protocol ;; 3) menu_modify_protocol ;;
      4) menu_server_info ;; 5) menu_change_domain ;;
      6)
         timeout 15 systemctl restart sing-box >/dev/null 2>&1
         if systemctl is-active --quiet sing-box; then
           local restart_rc=0
           sync_hopping_rules || restart_rc=1
           sync_watchdog || restart_rc=1
           if [ "$restart_rc" -eq 0 ]; then tell_ok "重启完成"; else tell_warn "服务已重启，但网络规则或看门狗同步失败"; fi
         else tell_warn "sing-box 已停止"; tell_warn "重启失败"; fi
         wait_key ;;
      7)
         previous=$(state_get exit) || { tell_warn "出口状态读取失败，未停止服务"; wait_key; continue; }
         state_set exit direct || { tell_warn "出口状态更新失败，未停止服务"; wait_key; continue; }
         if ! stop_watchdog; then
           if ! state_set exit "$previous" || ! sync_watchdog; then tell_warn "看门狗停止失败，且状态回滚未完成，请检查"; else tell_warn "看门狗停止失败，未停止服务"; fi
           wait_key; continue
         fi
         timeout 15 systemctl stop sing-box >/dev/null 2>&1 || true
         if ! systemctl is-active --quiet sing-box; then
           local stop_tmp stop_rc=0
           exec 8>"$CONFIG_LOCK" || stop_rc=1
           [ "$stop_rc" -eq 1 ] || flock -w 30 8 || stop_rc=1
           if [ "$stop_rc" -eq 0 ]; then
             stop_tmp=$(mktemp) || stop_rc=1
           fi
           if [ "$stop_rc" -eq 0 ] && build_config >"$stop_tmp" 2>/dev/null && [ -s "$stop_tmp" ] && "$CORE" check -c "$stop_tmp" >/dev/null 2>&1 && json_write "$CONFIG" <"$stop_tmp"; then
             rm -f -- "$stop_tmp"
             flock -u 8
             tell_ok "停止完成"
           else
             [ -n "${stop_tmp:-}" ] && rm -f -- "$stop_tmp"
             flock -u 8 2>/dev/null || true
             local restore_rc=0
             state_set exit "$previous" || restore_rc=1
             timeout 15 systemctl start sing-box >/dev/null 2>&1 || restore_rc=1
             systemctl is-active --quiet sing-box || restore_rc=1
             sync_watchdog || restore_rc=1
             if [ "$restore_rc" -eq 0 ]; then tell_warn "配置同步失败，服务已恢复运行"; else tell_warn "配置同步失败，且服务或出口恢复不完整，请立即检查"; fi
           fi
         else
           if ! state_set exit "$previous" || ! sync_watchdog; then tell_warn "操作异常，且状态回滚未完成，请检查"; else tell_warn "服务停止失败，原服务状态已保留"; fi
         fi
         wait_key ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

menu_wireguard(){
  while :; do
    ui_title "WireGuard"
    if ! wg_config_exists; then
      tell "模式：${DIM}未配置${PLAIN}"
    else
      local role enabled state ms color peer4 peer6
      role=$(wg_config_role)
      enabled=$(wg_config_enabled && printf 'true' || printf 'false')
      if [ "$role" = client ] && [ "$enabled" = true ]; then
        if [ ! -d "/sys/class/net/$WG_IF" ]; then
          tell "模式：客户端|${RED}异常${PLAIN}"
        else
          peer4=$(jq -r '.peer_ip // empty' "$WG_CONF" 2>/dev/null)
          peer6=$(jq -r '.peer_ip6 // empty' "$WG_CONF" 2>/dev/null)
          state=$(wg_tunnel_state "$peer4" "$peer6")
          ms=${state#*|}
          if [[ "$state" == ok\|* ]] && [[ "$ms" =~ ^[0-9]+$ ]]; then
            if [ "$ms" -lt 100 ]; then color="$GREEN"; elif [ "$ms" -lt 150 ]; then color="$YELLOW"; else color="$BROWN"; fi
            tell "模式：客户端|${GREEN}已连接${PLAIN}|${color}${ms} ms${PLAIN}"
          elif [ "$state" = up ]; then
            tell "模式：客户端|${GREEN}已连接${PLAIN}|${YELLOW}—${PLAIN}"
          else
            tell "模式：客户端|${YELLOW}未连接${PLAIN}"
          fi
        fi
      elif [ "$role" = server ]; then
        if [ "$enabled" = true ]; then
          if [ -d "/sys/class/net/$WG_IF" ]; then tell "模式：服务端|${GREEN}运行中${PLAIN}"; else tell "模式：服务端|${RED}异常${PLAIN}"; fi
        else
          tell "模式：服务端|${YELLOW}已停止${PLAIN}"
        fi
      else
        if [ "$enabled" = true ]; then
          if [ -d "/sys/class/net/$WG_IF" ]; then tell "模式：客户端|${GREEN}正常运行${PLAIN}"; else tell "模式：客户端|${RED}异常${PLAIN}"; fi
        else
          tell "模式：客户端|${YELLOW}已停止${PLAIN}"
        fi
      fi
    fi
    tell ""
    menu_item 1 "初始化配置"
    menu_item 2 "修改配置"
    menu_item 3 "启用/停用"
    menu_item 4 "状态信息"
    menu_item 5 "删除配置"
    menu_item 0 "返回"
        case $(prompt "请选择") in
      1) wg_init ;;
      2) wg_edit ;;
      3) wg_toggle "$(exit_label)" ;;
      4) wg_status ;;
      5) wg_delete ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

run_update(){
  local current latest script_url script_tmp script_api script_sha script_ref blob_sha
  ui_clear
  tell "正在检测 sing-box 内核更新..."
  current=$(core_version); latest=$(remote_version)
  tell "本地版本: ${current:-未知}"; tell "目标版本: ${latest:-获取失败}"
  if [ -z "$latest" ]; then tell_warn "无法获取最新版本，请检查网络或 GitHub 访问"
  elif [ -z "$current" ]; then
    if prompt_yes "无法读取当前内核版本，是否重新下载并安装 sing-box v$latest"; then
      run_core_reinstall "内核重新安装完成" "内核已下载，但配置应用失败" "内核重新安装失败"
    fi
  elif [ "$current" != "$latest" ]; then
    if prompt_yes "发现新版本 v$latest，是否立即更新"; then
      run_core_reinstall "内核更新完成" "内核更新完成，但配置应用失败" "内核更新失败"
    fi
  else tell_ok "内核已是最新版本"; fi
  printf "\n"
  tell "正在检测 s 脚本更新..."
  local ref_api="https://api.github.com/repos/88860/-/git/ref/heads/main"
  local file_api
  if ! script_ref=$(curl -4 -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$ref_api" 2>/dev/null | jq -er '.object.sha // empty'); then
    if ! script_ref=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$ref_api" 2>/dev/null | jq -er '.object.sha // empty'); then
      tell_warn "无法获取脚本版本校验信息，请检查 GitHub 访问"; wait_key; return
    fi
  fi
  file_api="https://api.github.com/repos/88860/-/contents/s.sh?ref=$script_ref"
  if ! script_sha=$(curl -4 -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$file_api" 2>/dev/null | jq -er '.sha // empty'); then
    if ! script_sha=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$file_api" 2>/dev/null | jq -er '.sha // empty'); then
      tell_warn "无法获取脚本文件校验信息，放弃更新"; wait_key; return
    fi
  fi
  script_url="https://raw.githubusercontent.com/88860/-/$script_ref/s.sh"
  script_tmp=$(mktemp) || { tell_warn "无法创建临时文件"; wait_key; return; }
  if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$script_url" -o "$script_tmp" 2>/dev/null; then
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$script_url" -o "$script_tmp" 2>/dev/null; then
      tell_warn "脚本下载失败，请检查 GitHub 访问"; rm -f "$script_tmp"; wait_key; return
    fi
  fi
  blob_sha=$(printf 'blob %s\0' "$(wc -c <"$script_tmp")" | cat - "$script_tmp" | sha1sum | awk '{print $1}')
  if [ "$blob_sha" != "$script_sha" ]; then
    tell_warn "脚本完整性校验失败，放弃更新"; rm -f "$script_tmp"; wait_key; return
  fi
  if [ ! -s "$script_tmp" ]; then tell_warn "下载的脚本为空，放弃更新"
  elif bash -n "$script_tmp" 2>/dev/null; then
    if cmp -s "$script_tmp" "$SELF"; then tell_ok "脚本已是最新版本"
    else
      if install -m700 "$script_tmp" "$SELF"; then
        rm -f "$script_tmp"; tell_ok "脚本更新完成，请重新运行本脚本生效"; exit 0
      else tell_warn "脚本写入失败，原脚本未修改"; fi
    fi
  else tell_warn "下载的脚本存在语法错误，放弃更新"; fi
  rm -f "$script_tmp"
  wait_key
}

run_uninstall(){
  local packages rc=0 item service_active=0 watchdog_active=0 network_cleanup_rc=0
  ui_clear
  tell_warn "警告: 卸载将清空所有配置"
  [ "$(prompt '输入 yes 确认')" = yes ] || return
  mapfile -t packages < <(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null)
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  systemctl disable --now sbm-watchdog.service >/dev/null 2>&1 || true
  systemctl reset-failed 'sbm-watchdog*' >/dev/null 2>&1 || true
  systemctl is-active --quiet sing-box 2>/dev/null && service_active=1
  systemctl is-active --quiet sbm-watchdog.service 2>/dev/null && watchdog_active=1
  [ "$service_active" -eq 0 ] || rc=1
  [ "$watchdog_active" -eq 0 ] || rc=1
  if [ "$service_active" -eq 0 ]; then
    wg_server_nat_remove || { rc=1; network_cleanup_rc=1; }
    clear_hopping_rules || { rc=1; network_cleanup_rc=1; }
    clear_legacy_bypass_rules || { rc=1; network_cleanup_rc=1; }
    ip link del "$WG_IF" >/dev/null 2>&1 || { ip link show "$WG_IF" >/dev/null 2>&1 && { rc=1; network_cleanup_rc=1; }; }
    ip link del "$TUN_IF" >/dev/null 2>&1 || { ip link show "$TUN_IF" >/dev/null 2>&1 && { rc=1; network_cleanup_rc=1; }; }
    ip link del "$WARP_IF" >/dev/null 2>&1 || { ip link show "$WARP_IF" >/dev/null 2>&1 && { rc=1; network_cleanup_rc=1; }; }
  else
    network_cleanup_rc=1
  fi
  if [ "$service_active" -eq 0 ] && [ "$watchdog_active" -eq 0 ]; then
    rm -f -- "$SERVICE_UNIT" "$DROPIN" /etc/systemd/system/sbm-watchdog.service || rc=1
    rmdir "$DROPIN_DIR" 2>/dev/null || [ ! -d "$DROPIN_DIR" ] || rc=1
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    systemctl is-enabled --quiet sing-box 2>/dev/null && rc=1
    systemctl is-enabled --quiet sbm-watchdog.service 2>/dev/null && rc=1
    rm -rf -- "$SB_DIR" /var/lib/sing-box "$CORE" || rc=1
    [ "$network_cleanup_rc" -eq 1 ] || rm -rf -- "$SBM_DIR" || rc=1
  fi
  rm -f -- "$SHORTCUT" || rc=1
  if [ "$rc" -eq 0 ] && [ ${#packages[@]} -gt 0 ] && prompt_yes "是否移除依赖组件"; then
    apt-get remove -y -q "${packages[@]}" >/dev/null 2>&1 || rc=1
    apt-get autoremove -y -q >/dev/null 2>&1 || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$SELF" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    tell_ok "卸载清理完成"
  else
    tell_warn "卸载未能安全完成；仍运行的服务、未清理网络规则或状态记录已保留，请检查后重试"
  fi
  exit "$rc"
}

menu_status(){
  while :; do
    ui_title "状态与更新"
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
    tell "系统版本: ${os}"
    tell "内核架构: ${core} (${arch})"
    tell "内存状态: ${mem}"
    tell "运行时间: ${up}"
    tell "singbox : ${s_state}"
    tell "singbox版本: ${sb_ver:-无} (${sb_asset:-未知})"
    tell ""
    render_client_ip_status
    tell ""
    menu_item 1 "检测更新"
    menu_item 2 "彻底卸载"
    menu_item 0 "返回"
        case $(prompt "请选择") in
      1) run_update ;;
      2) run_uninstall ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

json_write(){
  local dest=$1 tmp
  tmp=$(mktemp) || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  install -m600 "$tmp" "$dest"; local rc=$?; rm -f "$tmp"; return $rc
}

json_save(){
  local dest=$1 content=$2
  [ -n "$content" ] || return 1
  json_write "$dest" <<<"$content"
}

json_edit(){
  local file=$1 expr=$2; shift 2
  local tmp; tmp=$(mktemp) || return 1
  if jq "$@" "$expr" "$file" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    install -m600 "$tmp" "$file"; local rc=$?; rm -f "$tmp"; return $rc
  fi
  rm -f "$tmp"
  return 1
}

core_tags(){
  [ -x "$CORE" ] || return 0
  "$CORE" version 2>/dev/null | sed -n 's/^Tags: //p'
}

has_acme_support(){ [[ "$(core_tags)" == *with_acme* ]]; }

default_iface(){
  local family=$1 target iface
  if [ "$family" = 4 ]; then target=1.1.1.1; else target=2606:4700:4700::1111; fi
  iface=$(ip -"$family" route get "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  case "$iface" in "$TUN_IF"|"$WG_IF"|"$WARP_IF") iface="" ;; esac
  [ -n "$iface" ] || iface=$(ip -"$family" route show table main default 2>/dev/null | awk -v t="$TUN_IF" -v w="$WG_IF" -v p="$WARP_IF" '{for(i=1;i<NF;i++) if($i=="dev" && $(i+1)!=t && $(i+1)!=w && $(i+1)!=p){print $(i+1); exit}}')
  printf '%s' "$iface"
}
resolve_addresses(){
  local host=$1 encoded out
  if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || [[ "$host" =~ ^[0-9A-Fa-f:]+$ ]]; then
    printf '%s\n' "$host"
    return 0
  fi
  encoded=$(uri_encode "$host")
  if [ -n "$NET_IF_V4" ]; then
    out=$(curl -4 -fsS --connect-timeout 2 -m 4 --interface "$NET_IF_V4" --resolve cloudflare-dns.com:443:1.1.1.1 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$encoded&type=A" 2>/dev/null)
    jq -r '.Answer[]?.data // empty' <<<"$out" 2>/dev/null
  fi
  if [ -n "$NET_IF_V6" ]; then
    out=$(curl -6 -fsS --connect-timeout 2 -m 4 --interface "$NET_IF_V6" --resolve 'cloudflare-dns.com:443:[2606:4700:4700::1111]' -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$encoded&type=AAAA" 2>/dev/null)
    jq -r '.Answer[]?.data // empty' <<<"$out" 2>/dev/null
  fi
}
is_cgnat_v4(){
  local ip=$1 a b
  IFS=. read -r a b _ <<<"$ip"
  [ "$a" = "100" ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]
}
probe_network_stack(){
  NET_IF_V4=$(default_iface 4)
  NET_IF_V6=$(default_iface 6)
  local local_v4="" local_v6=""
  [ -n "$NET_IF_V4" ] && local_v4=$(ip -4 addr show dev "$NET_IF_V4" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
  [ -n "$NET_IF_V6" ] && local_v6=$(ip -6 addr show dev "$NET_IF_V6" 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | grep -v '^fe80' | head -1)
  if [ -z "$local_v4" ] && [ -z "$local_v6" ]; then
    NET_IPV4=""; NET_IPV6=""; NET_STACK="none"; IPV6_OK=0; return
  fi
  local tmp4="" tmp6="" ip4="" ip6="" p4="" p6="" rc=0
  if [ -n "$local_v4" ]; then
    tmp4=$(mktemp) || return 1
    (local pref=1000
     while ip rule show 2>/dev/null | awk '{print $1}' | grep -qx "${pref}:"; do pref=$((pref+1)); [ "$pref" -lt 9000 ] || exit 1; done
     ip rule add pref "$pref" from "$local_v4" lookup main 2>/dev/null || exit 1
     trap 'ip rule del pref "$pref" from "$local_v4" lookup main 2>/dev/null' EXIT
     curl -4 -s -m 2 --interface "$NET_IF_V4" https://ipv4.icanhazip.com 2>/dev/null > "$tmp4") & p4=$!
  fi
  if [ -n "$local_v6" ]; then
    tmp6=$(mktemp) || { [ -n "$tmp4" ] && rm -f "$tmp4"; return 1; }
    (local pref=1000
     while ip -6 rule show 2>/dev/null | awk '{print $1}' | grep -qx "${pref}:"; do pref=$((pref+1)); [ "$pref" -lt 9000 ] || exit 1; done
     ip -6 rule add pref "$pref" from "$local_v6" lookup main 2>/dev/null || exit 1
     trap 'ip -6 rule del pref "$pref" from "$local_v6" lookup main 2>/dev/null' EXIT
     curl -6 -s -m 2 --interface "$NET_IF_V6" https://ipv6.icanhazip.com 2>/dev/null > "$tmp6") & p6=$!
  fi
  if [ -n "$p4" ]; then wait "$p4" || rc=1; fi
  if [ -n "$p6" ]; then wait "$p6" || rc=1; fi
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
  [ -n "$ip6" ] && [ -n "$NET_IF_V6" ] && IPV6_OK=1
  [ "$NET_STACK" != none ] && return 0
  return "$rc"
}
probe_network_stack_async(){
  (
    exec 7>"${NET_CACHE}.lock" || exit 0
    flock -n 7 || exit 0
    probe_network_stack || exit 1
    local tmp
    tmp=$(mktemp "${NET_CACHE}.XXXXXX") || exit 0
    if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" > "$tmp" || ! mv -f "$tmp" "$NET_CACHE"; then
      rm -f "$tmp"
      exit 1
    fi
  ) </dev/null >/dev/null 2>&1 &
}
load_net_cache(){
  if [ -f "$NET_CACHE" ]; then
    if ! { IFS= read -r NET_IPV4; IFS= read -r NET_IPV6
      IFS= read -r NET_IF_V4; IFS= read -r NET_IF_V6
      IFS= read -r NET_STACK; IFS= read -r IPV6_OK; } < "$NET_CACHE"; then
      NET_STACK=""
    fi
  fi
  if [ -z "$NET_STACK" ]; then
    probe_network_stack || return 1
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" > "$NET_CACHE" 2>/dev/null || return 1
  fi
}
render_share_uri(){
  local file=$1 kind name port meta hopping mode host uri
  [ -n "$file" ] && [ -f "$file" ] || { tell_warn "节点文件不存在，无法生成分享链接"; return 1; }
  kind=$(jq -er '.kind // empty' "$file" 2>/dev/null) || { tell_warn "节点配置读取失败，无法生成分享链接"; return 1; }
  name=$(jq -er '.name // .tag // empty' "$file" 2>/dev/null) || return 1
  port=$(jq -er '.port // empty' "$file" 2>/dev/null) || return 1
  meta=$(jq -ec '.meta // {}' "$file" 2>/dev/null) || return 1
  hopping=$(jq -r '.hopping // ""' "$file" 2>/dev/null) || return 1
  mode=$(jq -r '.tls_mode // ""' "$file" 2>/dev/null) || return 1
  if [ "$mode" = acme ]; then
    host=$(state_get domain) || { tell_warn "证书域名状态读取失败，生成链接失败"; return 1; }
    [ -n "$host" ] || { tell_warn "未识别到可用证书域名，生成链接失败"; return 1; }
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "$hopping" "$host")
    tell "${GREEN}$uri${PLAIN}"
    [ -n "$hopping" ] && tell "跳跃配置: $hopping"
    return
  fi
  local physical_v4 physical_v6
  physical_v4=""; physical_v6=""
  physical_v4="$NET_IPV4"
  if [[ "$NET_IPV6" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$NET_IPV6" == *:* ]] && [ "$NET_IPV6" != "::" ]; then
    physical_v6="$NET_IPV6"
  elif [ -n "$NET_IF_V6" ]; then
    physical_v6=$(ip -6 addr show dev "$NET_IF_V6" scope global 2>/dev/null |
      awk '/inet6 / && $2 !~ /^fe80:/ && $2 !~ /^fc/ && $2 !~ /^fd/ {print $2;exit}' | cut -d/ -f1)
  fi
  if [ -n "$physical_v4" ]; then
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "$hopping" "$physical_v4")
    tell "${GREEN}$uri${PLAIN}"
  fi
  if [ -n "$physical_v6" ]; then
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "$hopping" "[$physical_v6]")
    tell "${GREEN}$uri${PLAIN}"
  fi
  if [ -z "$physical_v4$physical_v6" ]; then tell_warn "未识别到物理网卡公网 IP，生成链接失败"; return; fi
  [ -n "$hopping" ] && tell "跳跃配置: $hopping"
  if [ "$kind" = "snell" ]; then tell_alert "Snell 分享链接可能不被所有客户端识别，请手动复制 PSK"; fi
}

NET_IPV4=""
NET_IPV6=""
NET_IF_V4=""
NET_IF_V6=""
NET_STACK=""
IPV6_OK=0

network_ipv6_ok(){ printf '%s' "$IPV6_OK"; }
network_cache_write(){
  local tmp
  tmp=$(mktemp "${NET_CACHE}.XXXXXX") || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" \
    > "$tmp" && mv -f "$tmp" "$NET_CACHE" || { rm -f "$tmp"; return 1; }
}

validate_port(){
  local port=$1 proto=$2 allow=${3:-}
  [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { tell_warn "端口格式无效"; return 1; }
  [ "$port" = 80 ] && { tell_warn "端口 80 已保留给证书签发"; return 1; }
  [ "$port" = 443 ] && [ "$(state_get challenge)" = "alpn" ] && { tell_warn "端口 443 已保留给 ALPN 证书签发"; return 1; }
  [ "$port" = "$allow" ] && return 0
  grep -qx "$port" <<<"$(protected_ports)" && { tell_warn "已被节点或 SSH 占用"; return 1; }
  if [ "$proto" = "tu" ]; then
    { grep -qx "$port" <<<"$(listening_ports t)" || grep -qx "$port" <<<"$(listening_ports u)"; } && { tell_warn "端口被占用"; return 1; }
  else
    grep -qx "$port" <<<"$(listening_ports "$proto")" && { tell_warn "端口被占用"; return 1; }
  fi
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

probe_target_latency(){
  local server=$1 result=$2 latency_file=${3:-} type=${4:-} port=${5:-} iface families out ms targets target start_ns end_ns
  targets=$server
  if ! [[ "$server" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && ! [[ "$server" =~ ^[0-9A-Fa-f:]+$ ]]; then
    targets=$(resolve_addresses "$server")
  fi
  [ -n "$targets" ] || { echo fail >"$result"; return 1; }
  local targets4="" targets6="" ordered_targets
  while IFS= read -r target; do
    if [[ "$target" =~ ^[0-9A-Fa-f:]+$ ]]; then targets6+="$target"$'\n'
    elif [[ "$target" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then targets4+="$target"$'\n'; fi
  done <<<"$targets"
  if [ -n "$NET_IF_V6" ] && [ "$IPV6_OK" = 1 ]; then ordered_targets="${targets6}${targets4}"; else ordered_targets="${targets4}${targets6}"; fi
  local deadline=$((SECONDS+4))
  for target in $ordered_targets; do
    if [[ "$target" == *:* ]]; then families=6; else families=4; fi
    if command -v ping >/dev/null 2>&1; then
      if [ "$families" = 6 ]; then iface=$NET_IF_V6; else iface=$NET_IF_V4; fi
      if [ -n "$iface" ]; then
        local left=$((deadline-SECONDS))
        if [ "$left" -gt 0 ]; then
          out=$(timeout "${left}s" ping -"$families" -I "$iface" -c 1 -W "$left" "$target" 2>/dev/null)
          if [ $? -eq 0 ]; then
            ms=$(awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}' <<<"$out")
            if [[ "$ms" =~ ^[0-9]+$ ]]; then
              if [ "$ms" -gt 3000 ]; then echo timeout >"$result"; [ -n "$latency_file" ] && printf '%s\n' "$ms" >"$latency_file"; return 0; fi
              echo icmp >"$result"; [ -n "$latency_file" ] && printf '%s\n' "$ms" >"$latency_file"; return 0
            fi
          fi
        fi
      fi
    fi
    case "$type" in vless|vmess|trojan|shadowsocks|socks|http|anytls|snell) ;; *) continue ;; esac
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || continue
    start_ns=$(date +%s%N 2>/dev/null)
    if timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$target" "$port" 2>/dev/null; then
      end_ns=$(date +%s%N 2>/dev/null)
      ms=$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{if(a~/^[0-9]+$/&&b~/^[0-9]+$/)printf "%.0f",(b-a)/1000000;else print 0}')
      [[ "$ms" =~ ^[0-9]+$ ]] || ms=0
      if [ "$ms" -gt 3000 ]; then echo timeout >"$result"; else echo tcp >"$result"; fi
      [ -n "$latency_file" ] && printf '%s\n' "$ms" >"$latency_file"; return 0
    fi
  done
  case "$type" in hysteria2|tuic) echo unknown >"$result"; return 0 ;; esac
  echo fail >"$result"
  return 1
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
  done < <(find "$ACME_DIR/certificates" -type f -path "*/$domain/$domain.crt" 2>/dev/null)
  [ -n "$cert" ] || return 1
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
  [ -n "$cert_pub" ] || return 1
  key="${cert%.crt}.key"
  [ -f "$key" ] || return 1
  key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
  [ -n "$key_pub" ] && [ "$key_pub" = "$cert_pub" ] || return 1
  return 0
}

wait_for_certificate(){
  local domain=$1 pid=${2:-} log_file=${3:-} log timeout=${SBM_CERT_TIMEOUT:-600} started=$SECONDS
  [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || timeout=600
  tell "等待证书签发完成: $domain"
  while :; do
    if certificate_ready "$domain"; then
      tell_ok "证书已成功签发并完成校验"
      return 0
    fi
    if [ -n "$pid" ] && { ! kill -0 "$pid" 2>/dev/null || [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" == Z* ]]; }; then
      tell_warn "证书签发进程已退出，证书签发失败"
      if [ -n "$log_file" ] && [ -s "$log_file" ]; then tell "$(tail -n 12 "$log_file" 2>/dev/null)"; fi
      return 1
    fi
    if [ -z "$pid" ] && ! systemctl is-active --quiet sing-box; then
      tell_warn "sing-box 已停止，证书签发失败"
      log=$(journalctl -u sing-box -n 8 --no-pager 2>/dev/null)
      [ -n "$log" ] && tell "$log"
      return 1
    fi
    if [ "$((SECONDS-started))" -ge "$timeout" ]; then
      tell_warn "证书签发等待超时 (${timeout} 秒)"
      if [ -n "$log_file" ] && [ -s "$log_file" ]; then tell "$(tail -n 12 "$log_file" 2>/dev/null)"; fi
      return 1
    fi
    sleep 1
  done
}

setup_certificate(){
  local suggest=${1:-} domain email mode old_state
  [ -n "$(state_get domain)" ] && [ -n "$(state_get email)" ] && certificate_ready "$(state_get domain)" && return 0
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; return 1; }
  old_state=$(state_snapshot) || return 1
  printf '\n%b该协议需要绑定域名并签发证书%b\n' "${YELLOW}" "${PLAIN}"
  if [ -n "$suggest" ]; then
    domain="$suggest"; printf '%b已指定域名: %s%b\n' "${GREEN}" "$domain" "${PLAIN}"
  else domain=$(prompt "输入域名"); [ -n "$domain" ] || return 1; fi
  email=$(prompt "ACME 通知邮箱" "admin@$domain"); [ -n "$email" ] || return 1
  printf '\n%b选择域名证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
  echo "1. HTTP         (推荐 需放行80端口)"
  echo "2. TLS-ALPN     (推荐 需放行443端口)"
  echo "3. Cloudflare API"
  echo "4. 阿里云 DNS API"
  echo "5. ACME-DNS API"
  while :; do
    case $(prompt "请选择方式" 1) in
      1) mode=http; break ;;
      2) mode=alpn; break ;;
      3) mode=dns_cloudflare; state_set cf_token "$(prompt 'Cloudflare API Token')" || { state_restore "$old_state" || tell_warn "ACME 状态恢复失败"; return 1; }; break ;;
      4) mode=dns_alidns
         state_set ali_key "$(prompt 'AccessKeyId')" && state_set ali_secret "$(prompt 'AccessKeySecret')" || { state_restore "$old_state" || tell_warn "ACME 状态恢复失败"; return 1; }
         break ;;
      5) mode=dns_acmedns
         state_set acmedns_url "$(prompt 'server_url')" && state_set acmedns_user "$(prompt 'username')" &&
         state_set acmedns_pass "$(prompt 'password')" && state_set acmedns_sub "$(prompt 'subdomain')" || { state_restore "$old_state" || tell_warn "ACME 状态恢复失败"; return 1; }
         break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1
         ui_clear
         printf '\n%b选择域名证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
         echo "1. HTTP         (推荐 需放行80端口)"
         echo "2. TLS-ALPN     (推荐 需放行443端口)"
         echo "3. Cloudflare API"
         echo "4. 阿里云 DNS API"
         echo "5. ACME-DNS API" ;;
    esac
  done
  if ! state_set challenge "$mode" || ! state_set domain "$domain" || ! state_set email "$email"; then
    state_restore "$old_state" || tell_warn "ACME 状态恢复失败"
    return 1
  fi
  if ! validate_domain "$domain"; then
    if ! prompt_yes "验证存在异常，是否强制继续"; then
      state_restore "$old_state" || tell_warn "ACME 状态恢复失败"
      return 1
    fi
  fi
  return 0
}

ssh_ports(){
  {
    [ -n "$SSH_CONNECTION" ] && awk '{print $4}' <<<"$SSH_CONNECTION"
    ss -Hlntp 2>/dev/null | awk '/users:\(\("(sshd|dropbear)"/{print $4}' | sed 's/.*://'
    [ -f /etc/ssh/sshd_config ] && sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config
    if [ -d /etc/ssh/sshd_config.d ]; then
      for _ssh_conf in /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$_ssh_conf" ] || continue
        sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' "$_ssh_conf"
      done
    fi
    command -v sshd >/dev/null 2>&1 && sshd -T 2>/dev/null | awk '/^port /{print $2}'
  } | grep -E '^[1-9][0-9]*$' | sort -un || true
}

node_ports(){
  set -- "$NODE_DIR"/*.json
  [ -e "$1" ] && jq -r '.port' "$@" 2>/dev/null | grep -E '^[1-9][0-9]*$'
}
protected_ports(){
  { ssh_ports; node_ports; wg_config_listen_port; } | grep -E '^[1-9][0-9]*$' | sort -un
}
listening_ports(){ ss -Hln"$1" 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u; }
singbox_listening_ports(){
  local proto=$1 pid
  pid=$(systemctl show -p MainPID --value sing-box 2>/dev/null)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  case "$proto" in
    t) ss -H -ltnp 2>/dev/null ;;
    u) ss -H -lunp 2>/dev/null ;;
    *) return 2 ;;
  esac | awk -v pid="$pid" 'match($0,"pid=" pid "[,)]") {address=$4; sub(/^.*:/,"",address); if (address ~ /^[0-9]+$/) print address}' | sort -u
}
server_node_transport(){
  local file=$1 kind proto
  kind=$(jq -r '.kind // ""' "$file" 2>/dev/null)
  proto=$(jq -r '.proto // ""' "$file" 2>/dev/null)
  case "$proto" in
    t|u|tu) printf '%s' "$proto" ;;
    *) case "$kind" in shadowsocks) printf 'tu' ;; hysteria2|tuic) printf 'u' ;; *) printf 't' ;; esac ;;
  esac
}
hopping_node(){
  local file value
  for file in "$NODE_DIR"/*.json; do
    value=$(jq -r '.hopping//""' "$file" 2>/dev/null) || return 2
    [ -n "$value" ] && { printf '%s' "$file"; return 0; }
  done
  return 1
}
clear_legacy_bypass_rules(){
  local state="$SBM_DIR/bypass_rules" family selector value rc=0 rules
  [ -f "$state" ] || return 0
  while read -r family selector value; do
    case "$family:$selector:$value" in
      4:sport:*)
        rules=$(ip -4 rule show pref 90 2>/dev/null) || { rc=1; continue; }
        if grep -Eq "sport[[:space:]]+$value([[:space:]]|$)" <<<"$rules"; then
          ip -4 rule del pref 90 sport "$value" lookup main 2>/dev/null || {
            rules=$(ip -4 rule show pref 90 2>/dev/null) || { rc=1; continue; }
            grep -Eq "sport[[:space:]]+$value([[:space:]]|$)" <<<"$rules" && rc=1
          }
        fi ;;
      6:sport:*)
        rules=$(ip -6 rule show pref 90 2>/dev/null) || { rc=1; continue; }
        if grep -Eq "sport[[:space:]]+$value([[:space:]]|$)" <<<"$rules"; then
          ip -6 rule del pref 90 sport "$value" lookup main 2>/dev/null || {
            rules=$(ip -6 rule show pref 90 2>/dev/null) || { rc=1; continue; }
            grep -Eq "sport[[:space:]]+$value([[:space:]]|$)" <<<"$rules" && rc=1
          }
        fi ;;
      4:fwmark:fwmark)
        rules=$(ip -4 rule show pref 90 2>/dev/null) || { rc=1; continue; }
        if grep -Eq 'fwmark[[:space:]]+(0x0*ff|255)(/[^[:space:]]+)?([[:space:]]|$)' <<<"$rules"; then
          ip -4 rule del pref 90 fwmark 255 lookup main 2>/dev/null || {
            rules=$(ip -4 rule show pref 90 2>/dev/null) || { rc=1; continue; }
            grep -Eq 'fwmark[[:space:]]+(0x0*ff|255)(/[^[:space:]]+)?([[:space:]]|$)' <<<"$rules" && rc=1
          }
        fi ;;
      6:fwmark:fwmark)
        rules=$(ip -6 rule show pref 90 2>/dev/null) || { rc=1; continue; }
        if grep -Eq 'fwmark[[:space:]]+(0x0*ff|255)(/[^[:space:]]+)?([[:space:]]|$)' <<<"$rules"; then
          ip -6 rule del pref 90 fwmark 255 lookup main 2>/dev/null || {
            rules=$(ip -6 rule show pref 90 2>/dev/null) || { rc=1; continue; }
            grep -Eq 'fwmark[[:space:]]+(0x0*ff|255)(/[^[:space:]]+)?([[:space:]]|$)' <<<"$rules" && rc=1
          }
        fi ;;
      *) rc=1 ;;
    esac
  done < "$state"
  [ "$rc" -eq 0 ] && rm -f -- "$state" || rc=1
  return "$rc"
}
sync_hopping_rules(){
  local file range port first last hop_rc script='' tables
  command -v nft >/dev/null 2>&1 || return 1
  file=$(hopping_node); hop_rc=$?
  [ "$hop_rc" -eq 1 ] && {
    tables=$(nft list tables 2>/dev/null) || return 1
    if grep -Fqx "table inet $HOP_TABLE" <<<"$tables"; then
      nft delete table inet "$HOP_TABLE" >/dev/null 2>&1 || return 1
      tables=$(nft list tables 2>/dev/null) || return 1
      ! grep -Fqx "table inet $HOP_TABLE" <<<"$tables"
    else
      return 0
    fi
    return $?
  }
  [ "$hop_rc" -eq 0 ] || return 1
  range=$(jq -r '.hopping // empty' "$file") || return 1
  port=$(jq -r '.port // empty' "$file") || return 1
  [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  first=${BASH_REMATCH[1]}; last=${BASH_REMATCH[2]}
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  [ "$first" -le "$last" ] && [ "$last" -le 65535 ] || return 1
  tables=$(nft list tables 2>/dev/null) || return 1
  grep -Fqx "table inet $HOP_TABLE" <<<"$tables" && script+="delete table inet $HOP_TABLE\n"
  script+="add table inet $HOP_TABLE\nadd chain inet $HOP_TABLE prerouting { type nat hook prerouting priority dstnat; policy accept; }\nadd rule inet $HOP_TABLE prerouting iifname != \"lo\" iifname != \"$WG_IF\" iifname != \"$TUN_IF\" udp dport $range redirect to :$port\n"
  nft -f <(printf '%b' "$script") >/dev/null 2>&1
}
clear_hopping_rules(){
  local tables
  command -v nft >/dev/null 2>&1 || return 1
  tables=$(nft list tables 2>/dev/null) || return 1
  grep -Fqx "table inet $HOP_TABLE" <<<"$tables" || return 0
  nft delete table inet "$HOP_TABLE" >/dev/null 2>&1 || return 1
  tables=$(nft list tables 2>/dev/null) || return 1
  ! grep -Fqx "table inet $HOP_TABLE" <<<"$tables"
}

acme_options(){
  local domain=$1 body email challenge token key secret user pass sub url
  email=$(state_get email) || return 1
  challenge=$(state_get challenge) || return 1
  body=$(jq -n --arg d "$domain" --arg e "$email" --arg dir "$ACME_DIR" \
    '{domain:[$d],default_server_name:$d,email:$e,data_directory:$dir,provider:"letsencrypt"}') || return 1
  body=$(jq '.key_type="p256"' <<<"$body") || return 1
  case "$challenge" in
    alpn) body=$(jq '.disable_http_challenge=true' <<<"$body") || return 1 ;;
    dns_cloudflare)
      token=$(state_get cf_token) || return 1
      body=$(jq --arg t "$token" '.dns01_challenge={provider:"cloudflare",api_token:$t}' <<<"$body") || return 1 ;;
    dns_alidns)
      key=$(state_get ali_key) || return 1; secret=$(state_get ali_secret) || return 1
      body=$(jq --arg k "$key" --arg s "$secret" '.dns01_challenge={provider:"alidns",access_key_id:$k,access_key_secret:$s}' <<<"$body") || return 1 ;;
    dns_acmedns)
      user=$(state_get acmedns_user) || return 1; pass=$(state_get acmedns_pass) || return 1
      sub=$(state_get acmedns_sub) || return 1; url=$(state_get acmedns_url) || return 1
      body=$(jq --arg u "$user" --arg p "$pass" --arg s "$sub" --arg r "$url" '.dns01_challenge={provider:"acmedns",username:$u,password:$p,subdomain:$s,server_url:$r}' <<<"$body") || return 1 ;;
    *) body=$(jq '.disable_tls_alpn_challenge=true' <<<"$body") || return 1 ;;
  esac
  printf '%s' "$body"
}

config_build_inbounds(){
  local domain=$1 node_files tls_extra='{}' providers='[]'
  local inbounds='[]'
  node_files=()
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    node_files+=("$file")
  done
  if [ ${#node_files[@]} -gt 0 ]; then
    if [ -n "$domain" ]; then
      providers=$(jq -n --arg t "$CERT_TAG" --argjson a "$(acme_options "$domain")" '[$a+{type:"acme",tag:$t}]') || return 1
      tls_extra=$(jq -n --arg t "$CERT_TAG" '{certificate_provider:$t}') || return 1
    fi
    inbounds=$(jq -s --arg d "$domain" --argjson x "$tls_extra" '
      [ .[] |
        .inbound as $in |
        ($in | if .type=="hysteria2" and ((.up_mbps//0)>0 or (.down_mbps//0)>0)
                then del(.bbr_profile)
                else . end) as $in2 |
        (if .kind=="shadowsocks" then ($in2 | del(.network) | .multiplex={enabled:true}) else $in2 end) as $in3 |
        if .tls_mode=="acme" then
          $in3 * {tls: ({enabled:true,server_name:$d}
                       + (if .alpn then {alpn:.alpn} else {} end)
                       + $x)}
        else $in3 end ]' "${node_files[@]}") || return 1
  fi
  jq -n --argjson inbounds "$inbounds" --argjson providers "$providers" \
    '{inbounds:$inbounds,providers:$providers}'
}

config_build_exit(){
  local selected=$1 dns_direct_tag=$2
  local outbounds='[{"type":"direct","tag":"direct"}]'
  local endpoints='[]' peer_host='' final='direct' use_tun=0

  if wg_config_enabled; then
    if [ "$(wg_config_role)" = client ]; then
      if [ "$selected" = "direct" ] || [ "$selected" = "wireguard" ]; then
        endpoints=$(wg_config_endpoint "$dns_direct_tag") || return 1
        peer_host=$(wg_config_peer_host)
        final="wireguard"; use_tun=1
      fi
    else
      endpoints=$(wg_config_endpoint "$dns_direct_tag")
    fi
  fi

  if [ "$selected" = warp ]; then
    local warp_endpoint_json
    warp_endpoint_json=$(warp_endpoint "$dns_direct_tag") || { tell_warn "WARP 配置不完整" >&2; return 1; }
    endpoints=$(jq -n --argjson base "$endpoints" --argjson warp "$warp_endpoint_json" '$base + [$warp]') || return 1
    peer_host=$(jq -r '.peers[0].address' <<<"$warp_endpoint_json")
    final="warp"; use_tun=1
  fi

  if [ "$selected" = wireguard ] && ! wg_client_active; then
    tell_warn "WireGuard 客户端未启用，拒绝回退直连" >&2
    return 1
  fi

  if [ "$selected" != direct ] && [ "$selected" != wireguard ] && [ "$selected" != warp ]; then
    [ -s "$PEER_DIR/$selected.json" ] || { tell_warn "出口节点 $selected 文件不存在，拒绝回退直连" >&2; return 1; }
    jq -e '.outbound as $o | ((["shadowsocks","vmess","vless","hysteria2","tuic","trojan","anytls","http","socks","snell"]|index($o.type))!=null and ($o.server|type)=="string" and ($o.server|length)>0 and (if $o.type=="hysteria2" and ($o.server_ports|type)=="array" then (($o.server_ports|length)>0 and (($o|has("server_port"))|not) and all($o.server_ports[]; type=="string" and (split(":") as $p | if ($p|length)==1 then ($p[0]|test("^[1-9][0-9]*$")) and (($p[0]|tonumber)<=65535) elif ($p|length)==2 then ($p[0]|test("^[1-9][0-9]*$")) and ($p[1]|test("^[1-9][0-9]*$")) and (($p[0]|tonumber)<=65535) and (($p[1]|tonumber)<=65535) and (($p[0]|tonumber)<=($p[1]|tonumber)) else false end))) else (($o.server_port|type)=="number" and $o.server_port>=1 and $o.server_port<=65535) end))' "$PEER_DIR/$selected.json" >/dev/null 2>&1 || { tell_warn "出口节点 $selected 配置无效，拒绝回退直连" >&2; return 1; }
    outbounds=$(jq -n --argjson base "$outbounds" --slurpfile peer "$PEER_DIR/$selected.json" \
      --arg resolver "$dns_direct_tag" '$base + [($peer[0].outbound + {domain_resolver:$resolver} | if .type=="shadowsocks" then del(.network) | .multiplex={enabled:true} else . end)]') || return 1
    final=$selected; use_tun=1
    peer_host=$(client_peer_server "$PEER_DIR/$selected.json")
  fi

  jq -n --argjson outbounds "$outbounds" --argjson endpoints "$endpoints" \
    --arg host "$peer_host" --arg final "$final" --argjson tun "$use_tun" \
    '{outbounds:$outbounds,endpoints:$endpoints,peer_host:$host,final:$final,use_tun:$tun}'
}

config_build_tun_inbounds(){
  local inbounds=$1 name=$TUN_IF mode=${2:-dual} preserve_management=${3:-0} strict_override=${4:-} endpoint_host=${5:-} route='[]' exclude='[]'
  case "$mode" in
    ipv4) route='["0.0.0.0/0"]'; exclude='["::/0"]' ;;
    ipv6) route='["::/0"]'; exclude='["0.0.0.0/0"]' ;;
    dual) route='["0.0.0.0/0","::/0"]' ;;
    *) return 1 ;;
  esac
  local strict_route_value=true
  [ "$route" = '["0.0.0.0/0","::/0"]' ] || strict_route_value=false
  [ -n "$strict_override" ] && strict_route_value=$strict_override

  if [ -n "$endpoint_host" ]; then
    local endpoint_cidr=""
    if [[ "$endpoint_host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      endpoint_cidr="${endpoint_host}/32"
    elif [[ "$endpoint_host" == *:* ]]; then
      endpoint_cidr="${endpoint_host}/128"
    fi
    if [ -n "$endpoint_cidr" ]; then
      exclude=$(jq -c --arg x "$endpoint_cidr" '. + [$x] | unique' <<<"$exclude") || return 1
    fi
  fi

  if [ "$preserve_management" = 1 ] && [ -n "$SSH_CONNECTION" ]; then
    local ssh_peer ssh_cidr
    ssh_peer=$(awk '{print $1}' <<<"$SSH_CONNECTION")
    if [[ "$ssh_peer" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      ssh_cidr="${ssh_peer}/32"
    elif [[ "$ssh_peer" == *:* ]]; then
      ssh_cidr="${ssh_peer}/128"
    else
      ssh_cidr=""
    fi
    if [ -n "$ssh_cidr" ]; then
      exclude=$(jq -c --arg x "$ssh_cidr" '. + [$x] | unique' <<<"$exclude") || return 1
    fi
  fi

  jq -n --argjson list "$inbounds" --arg name "$name" --argjson route "$route" --argjson exclude "$exclude" --argjson strict "$strict_route_value" '
    [{type:"tun",tag:"tun-in",interface_name:$name,
      address:["172.19.0.1/30","fdfe:dcba:9876::1/126"],
      dns_mode:"hijack",
      dns_address:["172.19.0.2","fdfe:dcba:9876::2"],
      auto_route:true,auto_redirect:true,
      strict_route:$strict,
      mtu:1500}
      + (if ($route|length)>0 then {route_address:$route} else {} end)
      + (if ($exclude|length)>0 then {route_exclude_address:$exclude} else {} end)
    ] + $list'
}

config_build_rules(){
  local peer_host=$1 mode=${2:-} selected=${3:-direct} tun_enabled=${4:-0} direct_action=route
  [ "$tun_enabled" = 1 ] && core_supports_bypass && direct_action=bypass
  if [ "$selected" = warp ]; then
    jq -n --arg host "$peer_host" --arg mode "$mode" --arg action "$direct_action" '
      (if $mode=="ipv4" then [{ip_version:6,action:$action,outbound:"direct"}]
       elif $mode=="ipv6" then [{ip_version:4,action:$action,outbound:"direct"}]
       else [] end)
      + [{action:"sniff"},{protocol:"dns",action:"hijack-dns"}]
      + (if $host=="" then []
         elif ($host | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) then [{ip_cidr:[($host+"/32")],action:$action,outbound:"direct"}]
         elif ($host | test("^[0-9a-fA-F:]+$")) then [{ip_cidr:[($host+"/128")],action:$action,outbound:"direct"}]
         else [{domain:[$host],action:$action,outbound:"direct"}] end)'
    return
  fi
  local ssh_rule_ports ssh_client_ips
  ssh_rule_ports=$(ssh_ports | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')
  ssh_client_ips=$(if [ -n "$SSH_CONNECTION" ]; then printf '%s\n' "$SSH_CONNECTION" | awk '{print $1}'; fi | jq -Rsc 'split("\n") | map(select(test("^[0-9]+(\\.[0-9]+){3}$") or test("^[0-9A-Fa-f:]+$"))) | map(if contains(":") then .+"/128" else .+"/32" end)')
  jq -n --arg host "$peer_host" --arg action "$direct_action" --argjson ssh_ports "$ssh_rule_ports" --argjson ssh_client_ips "$ssh_client_ips" '
    (if ($ssh_client_ips|length)>0 then [{ip_cidr:$ssh_client_ips,action:$action,outbound:"direct"}] else [] end)
    + (if ($ssh_ports|length)>0 then
         [{network:"tcp",source_port:$ssh_ports,action:$action,outbound:"direct"},
          {network:"tcp",port:$ssh_ports,action:$action,outbound:"direct"}]
       else [] end)
    + [{action:"sniff"},{protocol:"dns",action:"hijack-dns"}]
    + (if $host=="" then []
       elif ($host | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) then [{ip_cidr:[($host+"/32")],action:$action,outbound:"direct"}]
       elif ($host | test("^[0-9a-fA-F:]+$")) then [{ip_cidr:[($host+"/128")],action:$action,outbound:"direct"}]
       else [{domain:[$host],action:$action,outbound:"direct"}] end)'
}
config_build_dns(){
  local dns_strategy=$2 final=$3 remote_tag=${4:-$1}
  jq -n --arg remote_tag "$remote_tag" --arg strategy "$dns_strategy" --arg detour "$final" '
    (if $remote_tag == "dns-direct-v6" then "2606:4700:4700::1111" else "1.1.1.1" end) as $remote_server |
    {servers:[
      {type:"https",tag:"dns-direct-v4",server:"1.1.1.1",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}},
      {type:"https",tag:"dns-direct-v6",server:"2606:4700:4700::1111",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}},
      {type:"https",tag:"dns-remote",server:$remote_server,server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}}
    ]}
    | .servers[2] |= (if $detour != "direct" then . + {detour:$detour} else . end)
    | {servers:.servers,final:"dns-remote",strategy:$strategy}'
}

build_config(){
  local selected domain inbounds outbounds endpoints rules dns_block final use_tun peer_host
  local node_block exit_block dns_direct_tag dns_remote_tag dns_strategy auto_detect providers warp_mode

  selected=$(state_get exit) || return 1
  domain=$(state_get domain) || return 1
  dns_direct_tag="dns-direct-v4"
  dns_remote_tag="dns-direct-v4"
  dns_strategy="prefer_ipv4"
  if [ -n "$NET_IF_V6" ] && [ "$(network_ipv6_ok)" = 1 ]; then
    dns_direct_tag="dns-direct-v6"
    dns_remote_tag="dns-direct-v6"
    dns_strategy="prefer_ipv6"
  fi
  if [ "$selected" = warp ]; then
    warp_mode=$(warp_mode_get)
    case "$warp_mode" in
      ipv4) dns_direct_tag="dns-direct-v4"; dns_remote_tag="dns-direct-v4"; dns_strategy="prefer_ipv4" ;;
      ipv6) dns_direct_tag="dns-direct-v6"; dns_remote_tag="dns-direct-v6"; dns_strategy="prefer_ipv6" ;;
      dual)
        if [ -n "$NET_IF_V4" ]; then
          dns_direct_tag="dns-direct-v4"; dns_remote_tag="dns-direct-v4"; dns_strategy="prefer_ipv4"
        elif [ -n "$NET_IF_V6" ]; then
          dns_direct_tag="dns-direct-v6"; dns_remote_tag="dns-direct-v6"; dns_strategy="prefer_ipv6"
        else
          return 1
        fi
        ;;
      *) return 1 ;;
    esac
  fi

  node_block=$(config_build_inbounds "$domain") || return 1
  inbounds=$(jq -c '.inbounds' <<<"$node_block") || return 1
  providers=$(jq -c '.providers' <<<"$node_block") || return 1

  exit_block=$(config_build_exit "$selected" "$dns_direct_tag") || return 1
  outbounds=$(jq -c '.outbounds' <<<"$exit_block") || return 1
  endpoints=$(jq -c '.endpoints' <<<"$exit_block") || return 1
  peer_host=$(jq -r '.peer_host' <<<"$exit_block") || return 1
  final=$(jq -r '.final' <<<"$exit_block") || return 1
  use_tun=$(jq -r '.use_tun' <<<"$exit_block") || return 1

  if [ "$use_tun" = 1 ]; then
    if [ "$selected" = warp ]; then
      inbounds=$(config_build_tun_inbounds "$inbounds" "$(warp_mode_get)" 1 false "$peer_host") || return 1
    else
      inbounds=$(config_build_tun_inbounds "$inbounds") || return 1
    fi
  fi

  rules=$(config_build_rules "$peer_host" "$( [ "$selected" = warp ] && warp_mode_get || printf dual )" "$selected" "$use_tun") || return 1
  if [ "$use_tun" = 1 ]; then auto_detect="true"; else auto_detect="false"; fi
  dns_block=$(config_build_dns "$dns_direct_tag" "$dns_strategy" "$final" "$dns_remote_tag") || return 1

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

build_uri(){
  local kind=$1 name=$2 port=$3 meta=$4 hopping=$5 host=$6 uri="" sni_host
  sni_host=${host#[}; sni_host=${sni_host%]}
  case $kind in
    shadowsocks)
      local ss_method ss_password ss_userinfo ss_b64
      ss_method=$(jq -r .method <<<"$meta"); ss_password=$(jq -r .password <<<"$meta")
      if [[ "$ss_method" == 2022-* ]]; then
        ss_userinfo="$(uri_encode "$ss_method"):$(uri_encode "$ss_password")"
        uri="ss://${ss_userinfo}@${host}:${port}"
      else
        ss_b64=$(printf '%s:%s' "$ss_method" "$ss_password" | base64 -w0 2>/dev/null || printf '%s:%s' "$ss_method" "$ss_password" | base64 | tr -d '\n')
        ss_b64=$(printf '%s' "$ss_b64" | tr '+/' '-_' | tr -d '=')
        uri="ss://${ss_b64}@${host}:${port}"
      fi
      uri="${uri}#$(uri_encode "$name")" ;;
    vmess-tls|vmess-ws|vmess-grpc|vmess-http)
      local vmess_net vmess_security vmess_json vmess_b64 vmess_path vmess_service
      case "$kind" in
        vmess-tls) vmess_net=tcp ;;
        vmess-ws) vmess_net=ws ;;
        vmess-grpc) vmess_net=grpc ;;
        vmess-http) vmess_net=http ;;
        *) vmess_net=tcp ;;
      esac
      vmess_security=$(jq -r '.security//"auto"' <<<"$meta")
      vmess_path=$(jq -r '.path//""' <<<"$meta")
      vmess_service=$(jq -r '.service_name//""' <<<"$meta")
      vmess_json=$(jq -cn --arg name "$name" --arg server "$host" --arg port "$port" --arg uuid "$(jq -r .uuid <<<"$meta")" \
        --arg security "$vmess_security" --arg net "$vmess_net" --arg path "$vmess_path" --arg service "$vmess_service" --arg sni "$sni_host" \
        '{v:"2",ps:$name,add:$server,port:$port,id:$uuid,aid:"0",scy:$security,net:$net,type:"none",host:"",path:(if $net=="grpc" then $service else $path end),tls:"tls",sni:$sni}
         | if $net=="grpc" then .serviceName=$service else . end') || return 1
      vmess_b64=$(printf '%s' "$vmess_json" | base64 -w0 2>/dev/null || printf '%s' "$vmess_json" | base64 | tr -d '\n')
      uri="vmess://${vmess_b64}#$(uri_encode "$name")" ;;
    vless-reality)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(uri_encode "$(jq -r .target <<<"$meta")")&fp=chrome&pbk=$(uri_encode "$(jq -r .public_key <<<"$meta")")&sid=$(uri_encode "$(jq -r .short_id <<<"$meta")")&spx=%2F&type=tcp#$(uri_encode "$name")" ;;
    vless-tls)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$(uri_encode "$sni_host")&type=tcp#$(uri_encode "$name")" ;;
    vless-ws)
      local vless_path
      vless_path=$(jq -r '.path//"/ws"' <<<"$meta")
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&security=tls&sni=$(uri_encode "$sni_host")&type=ws&path=$(uri_encode "$vless_path")&host=$(uri_encode "$host")#$(uri_encode "$name")" ;;
    vless-grpc)
      local vless_service
      vless_service=$(jq -r '.service_name//"TunService"' <<<"$meta")
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&security=tls&sni=$(uri_encode "$sni_host")&type=grpc&serviceName=$(uri_encode "$vless_service")#$(uri_encode "$name")" ;;
    hysteria2)
      local obfs_type obfs_pw obfs_str
      obfs_type=$(jq -r '.obfs_type//""' <<<"$meta"); obfs_pw=$(jq -r '.obfs_password//""' <<<"$meta")
      obfs_str=""
      if [ -n "$obfs_type" ]; then
        obfs_str="&obfs=$(uri_encode "$obfs_type")&obfs-password=$(uri_encode "$obfs_pw")"
        if [ "$obfs_type" = gecko ]; then
          obfs_str+="&min_packet_size=$(jq -r '.min_packet_size//512' <<<"$meta")&max_packet_size=$(jq -r '.max_packet_size//1200' <<<"$meta")"
        fi
      fi
      if [ -n "$hopping" ]; then
        uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$hopping/?sni=$(uri_encode "$sni_host")${obfs_str}#$(uri_encode "$name")"
      else
        uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port/?sni=$(uri_encode "$sni_host")${obfs_str}#$(uri_encode "$name")"
      fi ;;
    tuic)
      local tuic_cc
      tuic_cc=$(jq -r '.congestion_control//"bbr"' <<<"$meta")
      uri="tuic://$(jq -r .uuid <<<"$meta"):$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?congestion_control=$tuic_cc&alpn=h3&udp_relay_mode=native&sni=$(uri_encode "$sni_host")&allow_insecure=0#$(uri_encode "$name")" ;;
    trojan)
      uri="trojan://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port#$(uri_encode "$name")" ;;
    trojan-ws)
      local trojan_path
      trojan_path=$(jq -r '.path//"/ws"' <<<"$meta")
      uri="trojan://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?security=tls&sni=$(uri_encode "$sni_host")&type=ws&path=$(uri_encode "$trojan_path")&host=$(uri_encode "$host")#$(uri_encode "$name")" ;;
    trojan-grpc)
      local trojan_service
      trojan_service=$(jq -r '.service_name//"TunService"' <<<"$meta")
      uri="trojan://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?security=tls&sni=$(uri_encode "$sni_host")&type=grpc&serviceName=$(uri_encode "$trojan_service")#$(uri_encode "$name")" ;;
    anytls)
      local a_pw
      a_pw=$(jq -r .password <<<"$meta")
      uri="anytls://$(uri_encode "$a_pw")@$host:$port/?sni=$(uri_encode "$sni_host")&insecure=0#$(uri_encode "$name")" ;;
    socks)
      uri="socks5://$(uri_encode "$(jq -r .username <<<"$meta")"):$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port#$(uri_encode "$name")" ;;
    snell)
      local s_psk s_mode
      s_psk=$(uri_encode "$(jq -r .psk <<<"$meta")"); s_mode=$(jq -r '.mode//"default"' <<<"$meta")
      uri="snell://${s_psk}@$host:$port?version=6&mode=${s_mode}#$(uri_encode "$name")" ;;
  esac
  printf '%s' "$uri"
}

parse_uri(){
  local raw=$1 rest tail authority port_spec token low high uri_path="" vmess_raw=""
  local scheme query userinfo userinfo_raw host port ports
  [[ "$raw" == *://* ]] || return 1
  scheme=${raw%%://*}; scheme=${scheme,,}; rest=${raw#*://}
  case $rest in *\#*) rest=${rest%%\#*} ;; esac
  query=""; case $rest in *\?*) query=${rest#*\?}; rest=${rest%%\?*} ;; esac
  case "$scheme" in
    http|https)
      if [[ "$rest" == */* ]]; then uri_path="/${rest#*/}"; rest=${rest%%/*}; fi
      ;;
    vmess|ss|shadowsocks) ;;
    *) rest=${rest%%/*} ;;
  esac
  if { [ "$scheme" = ss ] || [ "$scheme" = shadowsocks ]; } && [[ "$rest" != *@* ]]; then
    local legacy_ss legacy_decoded legacy_pad
    legacy_ss=$rest
    legacy_ss=${legacy_ss//-/+}; legacy_ss=${legacy_ss//_/\/}
    legacy_pad=$(( (4 - ${#legacy_ss}%4) % 4 ))
    legacy_ss="${legacy_ss}$(printf '=%.0s' $(seq 1 "$legacy_pad"))"
    legacy_decoded=$(printf '%s' "$legacy_ss" | base64 -d 2>/dev/null || true)
    if [[ "$legacy_decoded" == *:*@*:* ]]; then rest=$legacy_decoded; fi
  fi
  userinfo=""; userinfo_raw=""; case $rest in *@*) userinfo_raw=${rest%@*}; userinfo=$(uri_decode "$userinfo_raw"); rest=${rest##*@} ;; esac
  case "$scheme" in
    http) port=80 ;;
    https) port=443 ;;
    socks|socks5) port=1080 ;;
    vmess) [ "$rest" != "" ] && [[ "$rest" != *@* ]] && port=443 || port="" ;;
    *) port="" ;;
  esac
  ports=""
  if [[ "$rest" == \[*\]* ]]; then
    host=${rest%%\]*}; host=${host#\[}
    tail=${rest##*\]}
    [ -n "$tail" ] && { [[ "$tail" == :* ]] || return 1; port_spec=${tail#:}; }
  else
    case "$rest" in
      *:*) host=${rest%%:*}; port_spec=${rest#*:} ;;
      *) host=$rest; port_spec="" ;;
    esac
  fi
  if [ -n "$port_spec" ] && { [ "$scheme" != hysteria2 ] && [ "$scheme" != hy2 ]; }; then
    [[ "$port_spec" =~ ^[0-9]+$ ]] && [ "$port_spec" -ge 1 ] && [ "$port_spec" -le 65535 ] || return 1
    port=$port_spec
  fi
  if [ "$scheme" = vmess ] && [ -z "$userinfo" ]; then
    vmess_raw=$host
    local vmess_decoded vmess_pad vmess_host vmess_port
    vmess_decoded=$(printf '%s' "$vmess_raw" | tr '_-' '/+')
    vmess_pad=$(( (4 - ${#vmess_decoded}%4) % 4 ))
    vmess_decoded="${vmess_decoded}$(printf '=%.0s' $(seq 1 "$vmess_pad"))"
    vmess_decoded=$(printf '%s' "$vmess_decoded" | base64 -d 2>/dev/null || true)
    jq -e 'type=="object"' <<<"$vmess_decoded" >/dev/null 2>&1 || return 1
    vmess_host=$(jq -r '.add // empty' <<<"$vmess_decoded")
    vmess_port=$(jq -r '.port // 443' <<<"$vmess_decoded")
    [ -n "$vmess_host" ] || return 1
    [[ "$vmess_port" =~ ^[0-9]+$ ]] && [ "$vmess_port" -ge 1 ] && [ "$vmess_port" -le 65535 ] || return 1
    host=$vmess_host
    port=$vmess_port
  fi
  if [ "$scheme" = hysteria2 ] || [ "$scheme" = hy2 ]; then
    if [ -n "$port_spec" ]; then
      IFS=',' read -ra authority <<<"$port_spec"
      [ "${#authority[@]}" -gt 0 ] || return 1
      for token in "${authority[@]}"; do
        if [[ "$token" =~ ^[0-9]+$ ]]; then
          [ "$token" -ge 1 ] && [ "$token" -le 65535 ] || return 1
        elif [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
          low=${token%-*}; high=${token#*-}
          [ "$low" -ge 1 ] && [ "$high" -le 65535 ] && [ "$low" -le "$high" ] || return 1
        else
          return 1
        fi
      done
      if [[ "$port_spec" == *-* || "$port_spec" == *,* ]]; then
        ports="$port_spec"
      else
        port="$port_spec"
      fi
    fi
  else
    if [ -n "$port_spec" ]; then
      port=$port_spec
    fi
  fi
  [ -n "$host" ] || return 1
  case "$scheme" in
    hysteria2|hy2) [ -n "$ports" ] || { [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || return 1 ;;
    vmess) if [ -n "$userinfo" ]; then [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1; fi ;;
    http|https|socks|socks5) ;;
    *) [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1 ;;
  esac
  [ -n "$port" ] || port=0
  jq -n --arg scheme "$scheme" --arg query "$query" --arg userinfo "$userinfo" --arg userinfo_raw "$userinfo_raw" \
        --arg host "$host" --argjson port "$port" --arg ports "$ports" --arg path "$uri_path" --arg vmess_raw "$vmess_raw" \
        '{scheme:$scheme,query:$query,userinfo:$userinfo,userinfo_raw:$userinfo_raw,host:$host,port:$port,ports:$ports,path:$path} | if $vmess_raw!="" then .vmess_raw=$vmess_raw else . end'
}

query_value(){
  local context=$1 key=$2 pair pairs query
  query=$(jq -r '.query//""' <<<"$context")
  IFS='&' read -ra pairs <<<"$query"
  for pair in "${pairs[@]}"; do
    [ "${pair%%=*}" = "$key" ] && { uri_decode "${pair#*=}"; return 0; }
  done
  if [ "$key" = path ]; then jq -r '.path // empty' <<<"$context"; fi
  return 0
}

uri_to_outbound(){
  local tag=$1 context=$2 outbound sni fingerprint insecure security network path vhost service
  local username password congestion alpn obfs_type obfs_pw hop_range flow udp_mode tls_alpn
  local disable_parrot s_mode min_pkt max_pkt
  sni=$(query_value "$context" sni); [ -n "$sni" ] || sni=$(query_value "$context" peer); [ -n "$sni" ] || sni=$(jq -r .host <<<"$context")
  fingerprint=$(query_value "$context" fp)
  case "$fingerprint" in chrome_psk|chrome_psk_shuffle|chrome_padding_psk_shuffle|chrome_pq|chrome_pq_psk) fingerprint=chrome ;; esac
  insecure=$(query_value "$context" insecure); [ -n "$insecure" ] || insecure=$(query_value "$context" allowInsecure); [ -n "$insecure" ] || insecure=$(query_value "$context" allow_insecure)
  tls_alpn=$(query_value "$context" alpn)
  if [ -n "$fingerprint" ]; then
    case "$fingerprint" in chrome|firefox|edge|safari|360|qq|ios|android|random|randomized) ;; *) return 1 ;; esac
  fi
  case $(jq -r .scheme <<<"$context") in
    ss|shadowsocks)
      local ss_method ss_password plugin plugin_opts ss_userinfo ss_plain ss_decoded ss_pad
      ss_userinfo=$(jq -r .userinfo <<<"$context")
      ss_plain=$ss_userinfo
      if [[ "$ss_plain" == *:* ]]; then
        ss_method=${ss_plain%%:*}
        ss_password=${ss_plain#*:}
      else
        ss_decoded=$(printf '%s' "$ss_userinfo" | tr '_-' '/+')
        ss_pad=$(( (4 - ${#ss_decoded}%4) % 4 )); ss_decoded="${ss_decoded}$(printf '=%.0s' $(seq 1 "$ss_pad"))"
        ss_decoded=$(printf '%s' "$ss_decoded" | base64 -d 2>/dev/null || true)
        [[ "$ss_decoded" == *:* ]] || return 1
        ss_method=${ss_decoded%%:*}; ss_password=${ss_decoded#*:}
      fi
      [ -n "$ss_method" ] && [ -n "$ss_password" ] || return 1
      ss_validate_password "$ss_method" "$ss_password" || return 1
      plugin=$(query_value "$context" plugin); plugin_opts=$(query_value "$context" plugin_opts)
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
        --arg method "$ss_method" --arg password "$ss_password" --arg plugin "$plugin" --arg plugin_opts "$plugin_opts" \
        '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:$method,password:$password,multiplex:{enabled:true}}
         | if $plugin!="" then .plugin=$plugin else . end
         | if $plugin_opts!="" then .plugin_opts=$plugin_opts else . end') ;;
    vmess)
      local vmess_security vmess_net vmess_path vmess_host vmess_service vmess_raw vmess_json vmess_server vmess_port vmess_uuid vmess_pad vmess_sni vmess_fp vmess_encryption vmess_alpn vmess_insecure vmess_alter_id vmess_packet_encoding
      if [ -n "$(jq -r .userinfo <<<"$context")" ]; then
        vmess_server=$(jq -r .host <<<"$context"); vmess_port=$(jq -r .port <<<"$context"); vmess_uuid=$(jq -r .userinfo <<<"$context")
        vmess_net=$(query_value "$context" type); [ -n "$vmess_net" ] || vmess_net=tcp
        [ "$vmess_net" = h2 ] && vmess_net=http
        vmess_encryption=$(query_value "$context" encryption); [ -n "$vmess_encryption" ] || vmess_encryption=auto
        vmess_security=$(query_value "$context" security); [ -n "$vmess_security" ] || vmess_security=$(query_value "$context" tls); [ -n "$vmess_security" ] || vmess_security=none
        vmess_path=$(query_value "$context" path); vmess_host=$(query_value "$context" host); vmess_service=$(query_value "$context" serviceName)
        vmess_sni=$(query_value "$context" sni); [ -n "$vmess_sni" ] || vmess_sni="$vmess_server"
        vmess_fp=$(query_value "$context" fp); vmess_alpn=$(query_value "$context" alpn); vmess_insecure=$(query_value "$context" allowInsecure)
        vmess_alter_id=$(query_value "$context" alterId); [ -n "$vmess_alter_id" ] || vmess_alter_id=$(query_value "$context" aid); [ -n "$vmess_alter_id" ] || vmess_alter_id=0
        vmess_packet_encoding=$(query_value "$context" packetEncoding); [ -n "$vmess_packet_encoding" ] || vmess_packet_encoding=$(query_value "$context" packet_encoding)
      else
        vmess_raw=$(jq -r '.vmess_raw // .host' <<<"$context")
        vmess_raw=$(printf '%s' "$vmess_raw" | tr '_-' '/+')
        vmess_pad=$(( (4 - ${#vmess_raw}%4) % 4 )); vmess_raw="${vmess_raw}$(printf '=%.0s' $(seq 1 "$vmess_pad"))"
        vmess_json=$(printf '%s' "$vmess_raw" | base64 -d 2>/dev/null || true)
        jq -e 'type=="object"' <<<"$vmess_json" >/dev/null 2>&1 || return 1
        vmess_server=$(jq -r '.add // empty' <<<"$vmess_json"); vmess_port=$(jq -r '.port // 443' <<<"$vmess_json"); vmess_uuid=$(jq -r '.id // empty' <<<"$vmess_json")
        vmess_sni=$(jq -r '.sni // (if (.tls|type)=="object" then .tls.server_name else empty end) // .host // .add // empty' <<<"$vmess_json")
        vmess_security=$(jq -r '.tls // "" | if type=="object" then (if .enabled==false then "none" else "tls" end) elif .==true or .=="tls" then "tls" else "none" end' <<<"$vmess_json")
        vmess_encryption=$(jq -r '.scy // "auto"' <<<"$vmess_json")
        vmess_net=$(jq -r '.net // "tcp"' <<<"$vmess_json"); [ "$vmess_net" = h2 ] && vmess_net=http
        vmess_path=$(jq -r '.path // ""' <<<"$vmess_json")
        vmess_host=$(jq -r '.host // "" | if type=="array" then join(",") else tostring end' <<<"$vmess_json")
        vmess_service=$(jq -r '.serviceName // (if .net=="grpc" then .path else "" end) // ""' <<<"$vmess_json")
        vmess_fp=$(jq -r '.fp // (if (.tls|type)=="object" then .tls.utls.fingerprint // "" else "" end)' <<<"$vmess_json")
        case "$vmess_fp" in chrome_psk|chrome_psk_shuffle|chrome_padding_psk_shuffle|chrome_pq|chrome_pq_psk) vmess_fp=chrome ;; esac
        vmess_alpn=$(jq -r '.alpn // (if (.tls|type)=="object" then .tls.alpn // "" else "" end) | if type=="array" then join(",") else tostring end' <<<"$vmess_json")
        vmess_insecure=$(jq -r '(.allowInsecure // "") as $a | .tls as $t | if $a!="" then $a elif ($t|type)=="object" then ($t.insecure // "") else "" end' <<<"$vmess_json")
        vmess_alter_id=$(jq -r '.aid // .alterId // 0' <<<"$vmess_json")
        vmess_packet_encoding=$(jq -r '.packetEncoding // .packet_encoding // ""' <<<"$vmess_json")
      fi
      case "$vmess_fp" in chrome_psk|chrome_psk_shuffle|chrome_padding_psk_shuffle|chrome_pq|chrome_pq_psk) vmess_fp=chrome ;; esac
      [ -n "$vmess_server" ] && [ -n "$vmess_uuid" ] || return 1
      [[ "$vmess_port" =~ ^[0-9]+$ ]] && [ "$vmess_port" -ge 1 ] && [ "$vmess_port" -le 65535 ] || return 1
      case "$vmess_encryption" in auto|none|zero|aes-128-gcm|chacha20-poly1305|aes-128-ctr) ;; *) return 1 ;; esac
      [[ "$vmess_alter_id" =~ ^[0-9]+$ ]] || return 1
      case "$vmess_net" in tcp|ws|grpc|http|quic|httpupgrade) ;; *) return 1 ;; esac
      case "$vmess_security" in ""|none|tls|true) ;; *) return 1 ;; esac
      case "$vmess_packet_encoding" in
        ""|none) vmess_packet_encoding="" ;;
        xudp|packetaddr) ;;
        *) return 1 ;;
      esac
      outbound=$(jq -n --arg tag "$tag" --arg server "$vmess_server" --argjson port "$vmess_port" \
        --arg uuid "$vmess_uuid" --arg encryption "$vmess_encryption" --argjson alter_id "$vmess_alter_id" \
        --arg packet_encoding "$vmess_packet_encoding" \
        '{type:"vmess",tag:$tag,server:$server,server_port:$port,uuid:$uuid,security:$encryption,alter_id:$alter_id} | if $packet_encoding!="" then .packet_encoding=$packet_encoding else . end')
      case "$vmess_net" in
        ws) outbound=$(jq --arg path "${vmess_path:-/}" --arg host "$vmess_host" '.transport=({type:"ws",path:$path}+(if $host!="" then {headers:{Host:$host}} else {} end))' <<<"$outbound") ;;
        grpc) [ -n "$vmess_service" ] || vmess_service=TunService; outbound=$(jq --arg svc "$vmess_service" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
        http) outbound=$(jq --arg path "${vmess_path:-/}" --arg host "$vmess_host" '.transport={type:"http",path:$path} | if $host!="" then .transport.host=($host|split(",")) else . end' <<<"$outbound") ;;
        quic) outbound=$(jq '.transport={type:"quic"}' <<<"$outbound") ;;
        httpupgrade) outbound=$(jq --arg path "${vmess_path:-/}" --arg host "$vmess_host" '.transport={type:"httpupgrade",path:$path} | if $host!="" then .transport.host=$host else . end' <<<"$outbound") ;;
      esac
      if [ "$vmess_security" = tls ] || [ "$vmess_security" = true ]; then
        outbound=$(jq --arg sni "$vmess_sni" --arg alpn "$vmess_alpn" --arg fp "$vmess_fp" --arg insecure "$vmess_insecure" \
          '.tls={enabled:true,server_name:$sni} | if $alpn!="" then .tls.alpn=($alpn|split(",")) else . end | if $fp!="" then .tls.utls={enabled:true,fingerprint:$fp} else . end | if ($insecure=="1" or $insecure=="true") then .tls.insecure=true else . end' <<<"$outbound")
      fi
      ;;
    vless)
      security=$(query_value "$context" security); network=$(query_value "$context" type)
      path=$(query_value "$context" path); vhost=$(query_value "$context" host); service=$(query_value "$context" serviceName)
      flow=$(query_value "$context" flow)
      [ -z "$flow" ] || [ "$flow" = "xtls-rprx-vision" ] || return 1
      case "$security" in ""|none|tls|reality) ;; *) return 1 ;; esac
      case "$network" in ""|tcp|none|ws|grpc|http|quic|httpupgrade) ;; *) return 1 ;; esac
      [ -n "$network" ] || network=tcp
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" --arg uuid "$(jq -r .userinfo <<<"$context")" \
        '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,packet_encoding:"xudp"}')
      [ -n "$flow" ] && outbound=$(jq --arg f "$flow" '.flow=$f' <<<"$outbound")
      if [ "$security" = reality ]; then
        [ -n "$fingerprint" ] || fingerprint=chrome
        outbound=$(jq --arg sni "$sni" --arg pbk "$(query_value "$context" pbk)" --arg sid "$(query_value "$context" sid)" --arg fp "$fingerprint" \
          '.tls={enabled:true,server_name:$sni,reality:{enabled:true,public_key:$pbk,short_id:$sid},utls:{enabled:true,fingerprint:$fp}}' <<<"$outbound")
      elif [ "$security" = tls ]; then
        outbound=$(jq --arg sni "$sni" '.tls={enabled:true,server_name:$sni}' <<<"$outbound")
        [ -z "$fingerprint" ] || outbound=$(jq --arg fp "$fingerprint" '.tls.utls={enabled:true,fingerprint:$fp}' <<<"$outbound")
      fi
      case $network in
        ws) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" \
              '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound") ;;
        grpc) outbound=$(jq --arg svc "$service" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
        http) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport={type:"http",path:$path,host:(if $host=="" then [] else ($host|split(",")) end)}' <<<"$outbound") ;;
        quic) outbound=$(jq '.transport={type:"quic"}' <<<"$outbound") ;;
        httpupgrade) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport={type:"httpupgrade",path:$path} | if $host!="" then .transport.host=$host else . end' <<<"$outbound") ;;
      esac ;;
    hysteria2|hy2)
      if [ -n "$(jq -r .ports <<<"$context")" ]; then
        local server_ports=() token
        IFS=',' read -ra port_tokens <<<"$(jq -r .ports <<<"$context")"
        for token in "${port_tokens[@]}"; do server_ports+=("${token//-/:}"); done
        outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --arg password "$(jq -r .userinfo <<<"$context")" --arg sni "$sni" --args \
          '{type:"hysteria2",tag:$tag,server:$server,password:$password,server_ports:$ARGS.positional,tls:{enabled:true,server_name:$sni,alpn:["h3"]}}' -- "${server_ports[@]}")
      else
        outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
                         --arg password "$(jq -r .userinfo <<<"$context")" --arg sni "$sni" \
          '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,
            tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      fi
      obfs_pw=$(query_value "$context" obfs-password); obfs_type=$(query_value "$context" obfs)
      if [ -n "$obfs_pw" ]; then
        [ -z "$obfs_type" ] && obfs_type="salamander"
      fi
      if [ -n "$obfs_type" ]; then
        [ "$obfs_type" = salamander ] || [ "$obfs_type" = gecko ] || return 1
        [ -n "$obfs_pw" ] || return 1
        outbound=$(jq --arg type "$obfs_type" --arg pw "$obfs_pw" '.obfs={type:$type,password:$pw}' <<<"$outbound")
      fi
      up_mbps=$(query_value "$context" up_mbps); down_mbps=$(query_value "$context" down_mbps)
      if [ -n "$up_mbps" ] || [ -n "$down_mbps" ]; then
        [[ "${up_mbps:-0}" =~ ^[0-9]+$ ]] && [[ "${down_mbps:-0}" =~ ^[0-9]+$ ]] || return 1
        [ "${up_mbps:-0}" -gt 0 ] && outbound=$(jq --argjson n "$up_mbps" '.up_mbps=$n' <<<"$outbound")
        [ "${down_mbps:-0}" -gt 0 ] && outbound=$(jq --argjson n "$down_mbps" '.down_mbps=$n' <<<"$outbound")
      fi
      disable_parrot=$(query_value "$context" disable_chrome_parrot)
      if [ "$disable_parrot" = "1" ] || [ "$disable_parrot" = "true" ]; then outbound=$(jq '.disable_chrome_parrot=true' <<<"$outbound"); fi
      hop_range=$(query_value "$context" mport); [ -z "$hop_range" ] && hop_range=$(query_value "$context" ports)
      if [ -z "$(jq -r .ports <<<"$context")" ] && [ -n "$hop_range" ]; then
        IFS=',' read -ra legacy_ports <<<"$hop_range"
        local legacy_server_ports=() token low high
        for token in "${legacy_ports[@]}"; do
          if [[ "$token" =~ ^[0-9]+$ ]]; then
            [ "$token" -ge 1 ] && [ "$token" -le 65535 ] || return 1
            legacy_server_ports+=("$token")
          elif [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
            low=${token%-*}; high=${token#*-}
            [ "$low" -ge 1 ] && [ "$high" -le 65535 ] && [ "$low" -le "$high" ] || return 1
            legacy_server_ports+=("${token//-/:}")
          else
            return 1
          fi
        done
        outbound=$(jq --args --argjson ports '[]' '.server_ports=$ARGS.positional|del(.server_port)|.hop_interval="30s"' <<<"$outbound" -- "${legacy_server_ports[@]}")
      elif [ -n "$(jq -r .ports <<<"$context")" ]; then
        outbound=$(jq '.hop_interval="30s"' <<<"$outbound")
      fi
      min_pkt=$(query_value "$context" min_packet_size); max_pkt=$(query_value "$context" max_packet_size)
      if [ -n "$min_pkt" ] || [ -n "$max_pkt" ]; then
        [ "$obfs_type" = gecko ] || return 1
        min_pkt=${min_pkt:-512}; max_pkt=${max_pkt:-1200}
        [[ "$min_pkt" =~ ^[0-9]+$ ]] && [[ "$max_pkt" =~ ^[0-9]+$ ]] || return 1
        [ "$min_pkt" -ge 512 ] && [ "$max_pkt" -le 2048 ] && [ "$max_pkt" -ge "$min_pkt" ] || return 1
        outbound=$(jq --arg mn "$min_pkt" --arg mx "$max_pkt" \
          '.obfs.min_packet_size=($mn|tonumber) | .obfs.max_packet_size=($mx|tonumber)' <<<"$outbound")
      fi ;;
    tuic)
      local uri_userinfo; uri_userinfo=$(jq -r .userinfo <<<"$context"); username=${uri_userinfo%%:*}; password=${uri_userinfo#*:}
      [ "$password" = "$(jq -r .userinfo <<<"$context")" ] && password=""
      congestion=$(query_value "$context" congestion_control); [ -n "$congestion" ] || congestion=bbr
      case "$congestion" in cubic|new_reno|bbr) ;; *) return 1 ;; esac
      alpn=$(query_value "$context" alpn); [ -n "$alpn" ] || alpn=h3
      udp_mode=$(query_value "$context" udp_relay_mode); [ -n "$udp_mode" ] || udp_mode=native
      case "$udp_mode" in native|quic) ;; *) return 1 ;; esac
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
                       --arg uuid "$username" --arg password "$password" --arg cc "$congestion" \
                       --arg sni "$sni" --arg alpn "$alpn" --arg udp_mode "$udp_mode" \
        '{type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$password,
          congestion_control:$cc,udp_relay_mode:$udp_mode,
          tls:{enabled:true,server_name:$sni,alpn:($alpn|split(","))}}') ;;
    trojan)
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
                       --arg password "$(jq -r .userinfo <<<"$context")" --arg sni "$sni" \
        '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni}}')
      network=$(query_value "$context" type); [ -n "$network" ] || network=tcp
      path=$(query_value "$context" path); vhost=$(query_value "$context" host); service=$(query_value "$context" serviceName)
      case "$network" in tcp|none) ;; ws|grpc|http|quic|httpupgrade) ;; *) return 1 ;; esac
      case "$network" in
        ws) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" \
          '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound") ;;
        grpc) outbound=$(jq --arg svc "$service" '.transport={type:"grpc",service_name:(if $svc=="" then "TunService" else $svc end)}' <<<"$outbound") ;;
        http) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport={type:"http",path:$path,host:(if $host=="" then [] else ($host|split(",")) end)}' <<<"$outbound") ;;
        quic) outbound=$(jq '.transport={type:"quic"}' <<<"$outbound") ;;
        httpupgrade) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport={type:"httpupgrade",path:$path} | if $host!="" then .transport.host=$host else . end' <<<"$outbound") ;;
      esac ;;
    anytls)
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
                       --arg password "$(jq -r .userinfo <<<"$context")" --arg sni "$sni" --arg metadata "$(query_value "$context" client_metadata)" \
        '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni}} | if $metadata!="" then .client_metadata=$metadata else . end') ;;
    http|https)
      local proxy_userinfo proxy_username proxy_password
      proxy_userinfo=$(jq -r '.userinfo_raw // .userinfo // ""' <<<"$context")
      proxy_username=${proxy_userinfo%%:*}; proxy_password=${proxy_userinfo#*:}
      [ "$proxy_password" = "$proxy_userinfo" ] && proxy_password=""
      proxy_username=$(uri_decode "$proxy_username")
      proxy_password=$(uri_decode "$proxy_password")
      local proxy_path proxy_host proxy_headers
      proxy_path=$(query_value "$context" path)
      proxy_host=$(query_value "$context" host)
      proxy_headers=$(query_value "$context" headers)
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
        --arg user "$proxy_username" --arg pass "$proxy_password" --arg path "$proxy_path" --arg host "$proxy_host" --arg headers "$proxy_headers" \
        '{type:"http",tag:$tag,server:$server,server_port:$port} | if $user!="" then .username=$user else . end | if $pass!="" then .password=$pass else . end
         | if $path!="" then .path=$path else . end
         | if $host!="" then .headers=((.headers//{})+{Host:$host}) else . end
         | if $headers!="" then ($headers|fromjson) as $h | if ($h|type)!="object" then error("headers must be a JSON object") else .headers=((.headers//{})+$h) end else . end') || return 1
      if [ "$(jq -r .scheme <<<"$context")" = https ]; then
        outbound=$(jq --arg sni "$sni" '.tls={enabled:true,server_name:$sni}' <<<"$outbound")
      fi ;;
    socks5|socks)
      local uri_userinfo; uri_userinfo=$(jq -r '.userinfo_raw // .userinfo // ""' <<<"$context"); username=${uri_userinfo%%:*}; password=${uri_userinfo#*:}
      [ "$password" = "$uri_userinfo" ] && password=""
      username=$(uri_decode "$username"); password=$(uri_decode "$password")
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
                       --arg user "$username" --arg pass "$password" \
        '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}
         |(if $user!="" then .username=$user else . end)
         |(if $pass!="" then .password=$pass else . end)') ;;
    snell)
      local snell_version snell_obfs snell_obfs_host snell_psk
      snell_version=$(query_value "$context" version)
      [ -n "$snell_version" ] || snell_version=4
      snell_psk=$(jq -r .userinfo <<<"$context")
      case "$snell_version" in
        4|5)
          snell_obfs=$(query_value "$context" obfs_mode); [ -n "$snell_obfs" ] || snell_obfs=$(query_value "$context" obfs); [ -n "$snell_obfs" ] || snell_obfs=none
          snell_obfs_host=$(query_value "$context" obfs_host); [ -n "$snell_obfs_host" ] || snell_obfs_host=$(query_value "$context" obfs-host)
          case "$snell_obfs" in none|http) ;; *) return 1 ;; esac
          outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
            --arg psk "$snell_psk" --arg obfs "$snell_obfs" --arg host "$snell_obfs_host" \
            '{type:"snell",tag:$tag,server:$server,server_port:$port,version:4,psk:$psk,obfs_mode:$obfs,obfs_host:(if $host=="" then "bing.com" else $host end)}') || return 1 ;;
        6)
          s_mode=$(query_value "$context" mode); [ -n "$s_mode" ] || s_mode=default
          case "$s_mode" in default|unshaped|unsafe-raw) ;; *) return 1 ;; esac
          [ "${#snell_psk}" -ge 12 ] && [ "${#snell_psk}" -le 255 ] || return 1
          outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
            --arg psk "$snell_psk" --arg mode "$s_mode" \
            '{type:"snell",tag:$tag,server:$server,server_port:$port,version:6,psk:$psk,mode:$mode}') || return 1 ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
  if [ "$insecure" = 1 ] || [ "$insecure" = true ]; then outbound=$(jq 'if .tls then .tls.insecure=true else . end' <<<"$outbound"); fi
  if [ -n "$tls_alpn" ]; then outbound=$(jq --arg alpn "$tls_alpn" 'if .tls.enabled==true then .tls.alpn=($alpn|split(",")) else . end' <<<"$outbound"); fi
  if [ -n "$fingerprint" ]; then outbound=$(jq --arg fp "$fingerprint" 'if .tls.enabled==true and (.tls.utls|not) then .tls.utls={enabled:true,fingerprint:$fp} else . end' <<<"$outbound"); fi
  printf '%s' "$outbound"
}

wg_nat_state_file(){ printf '%s/nat-state.json' "$WG_DIR"; }

wg_nat_state_write(){
  local prev4=$1 prev6=$2 file
  file=$(wg_nat_state_file)
  json_save "$file" "$(jq -n --argjson v4 "$prev4" --argjson v6 "$prev6" '{ipv4_forward:$v4,ipv6_forward:$v6}')" || return 1
}

wg_nat_state_read(){
  local key=$1 file
  file=$(wg_nat_state_file)
  [ -f "$file" ] || return 1
  jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null
}

wg_nat_table_remove(){
  local family=$1 tables
  tables=$(nft list tables 2>/dev/null) || return 1
  if grep -Fqx "table $family sbm_nat" <<<"$tables"; then
    nft delete table "$family" sbm_nat >/dev/null 2>&1 || return 1
    tables=$(nft list tables 2>/dev/null) || return 1
  fi
  ! grep -Fqx "table $family sbm_nat" <<<"$tables"
}

wg_server_nat_rollback(){
  local had_state=${1:-0} created4=${2:-0} created6=${3:-0} file4 file6 rc=0 prev4 prev6
  file4=$(wg_nat_state_file).nft4
  file6=$(wg_nat_state_file).nft6
  prev4=$(wg_nat_state_read ipv4_forward 2>/dev/null)
  prev6=$(wg_nat_state_read ipv6_forward 2>/dev/null)
  if [ "$had_state" = 1 ] || [ "$created4" = 1 ]; then wg_nat_table_remove ip || rc=1; fi
  if [ "$had_state" = 1 ] || [ "$created6" = 1 ]; then wg_nat_table_remove ip6 || rc=1; fi
  if [ "$rc" -eq 0 ]; then
    if [ -s "$file4" ]; then nft -f "$file4" >/dev/null 2>&1 || rc=1; fi
    if [ -s "$file6" ]; then nft -f "$file6" >/dev/null 2>&1 || rc=1; fi
  fi
  if [ "$had_state" = 1 ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || rc=1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || rc=1
    printf '%s\n' 'net.ipv4.ip_forward=1' 'net.ipv6.conf.all.forwarding=1' > /etc/sysctl.d/99-sbm-forward.conf || rc=1
  else
    [[ "$prev4" =~ ^[01]$ ]] && sysctl -w net.ipv4.ip_forward="$prev4" >/dev/null 2>&1 || rc=1
    [[ "$prev6" =~ ^[01]$ ]] && sysctl -w net.ipv6.conf.all.forwarding="$prev6" >/dev/null 2>&1 || rc=1
    if [ -f /etc/sysctl.d/99-sbm-forward.conf.sbm-backup ]; then
      mv -f /etc/sysctl.d/99-sbm-forward.conf.sbm-backup /etc/sysctl.d/99-sbm-forward.conf 2>/dev/null || rc=1
    else
      rm -f /etc/sysctl.d/99-sbm-forward.conf 2>/dev/null || rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    [ "$had_state" = 1 ] || rm -f -- "$(wg_nat_state_file)"
    rm -f -- "$file4" "$file6"
  fi
  return "$rc"
}

wg_server_nat_apply(){
  local prev4 prev6 legacy4 legacy6 nat_state had_state=0 rollback_rc=1 file4 file6 out4 out6 created4=0 created6=0
  file4=$(wg_nat_state_file).nft4
  file6=$(wg_nat_state_file).nft6
  nat_state=$(wg_nat_state_file)
  rm -f -- "$file4" "$file6"
  legacy4=$(jq -r '.nat_prev_ipv4_forward // empty' "$WG_CONF" 2>/dev/null)
  legacy6=$(jq -r '.nat_prev_ipv6_forward // empty' "$WG_CONF" 2>/dev/null)
  if [ -f "$nat_state" ]; then
    had_state=1
    prev4=$(wg_nat_state_read ipv4_forward 2>/dev/null)
    prev6=$(wg_nat_state_read ipv6_forward 2>/dev/null)
    [[ "$prev4" =~ ^[01]$ ]] && [[ "$prev6" =~ ^[01]$ ]] || return 1
  elif [[ "$legacy4" =~ ^[01]$ ]] && [[ "$legacy6" =~ ^[01]$ ]]; then
    had_state=1
    prev4=$legacy4
    prev6=$legacy6
    wg_nat_state_write "$prev4" "$prev6" >/dev/null 2>&1 || return 1
  elif [ -n "$legacy4$legacy6" ]; then
    return 1
  else
    if nft list table ip sbm_nat >/dev/null 2>&1 || nft list table ip6 sbm_nat >/dev/null 2>&1; then return 1; fi
    prev4=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || return 1
    prev6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null) || return 1
    [[ "$prev4" =~ ^[01]$ ]] && [[ "$prev6" =~ ^[01]$ ]] || return 1
    wg_nat_state_write "$prev4" "$prev6" >/dev/null 2>&1 || return 1
  fi
  if [ "$had_state" = 1 ]; then
    if nft list table ip sbm_nat > "$file4" 2>/dev/null; then :; else : >"$file4"; fi
    if nft list table ip6 sbm_nat > "$file6" 2>/dev/null; then :; else : >"$file6"; fi
  fi
  if [ -f /etc/sysctl.d/99-sbm-forward.conf ] && [ ! -f /etc/sysctl.d/99-sbm-forward.conf.sbm-backup ]; then
    cp -a /etc/sysctl.d/99-sbm-forward.conf /etc/sysctl.d/99-sbm-forward.conf.sbm-backup 2>/dev/null || { rm -f -- "$file4" "$file6"; [ "$had_state" = 1 ] || rm -f -- "$nat_state"; return 1; }
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }
  printf '%s\n' 'net.ipv4.ip_forward=1' 'net.ipv6.conf.all.forwarding=1' > /etc/sysctl.d/99-sbm-forward.conf || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }
  out4=$(default_iface 4); out6=$(default_iface 6)
  if [ "$had_state" = 1 ]; then
    wg_nat_table_remove ip || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }
    wg_nat_table_remove ip6 || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }
  fi
  nft add table ip sbm_nat 2>/dev/null || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }
  created4=1
  nft add chain ip sbm_nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }
  if [ -n "$out4" ]; then nft add rule ip sbm_nat postrouting oifname "$out4" masquerade 2>/dev/null || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }; fi
  nft add table ip6 sbm_nat 2>/dev/null || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }
  created6=1
  nft add chain ip6 sbm_nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }
  if [ -n "$out6" ]; then nft add rule ip6 sbm_nat postrouting oifname "$out6" masquerade 2>/dev/null || { wg_server_nat_rollback "$had_state" "$created4" "$created6" || rollback_rc=2; return "$rollback_rc"; }; fi
  rm -f -- "$file4" "$file6"
}

wg_server_nat_remove(){
  local prev4 prev6 nat_state legacy4 legacy6 rc=0 owned=0 backup=/etc/sysctl.d/99-sbm-forward.conf.sbm-backup managed=/etc/sysctl.d/99-sbm-forward.conf expected
  nat_state=$(wg_nat_state_file)
  legacy4=$(jq -r '.nat_prev_ipv4_forward // empty' "$WG_CONF" 2>/dev/null)
  legacy6=$(jq -r '.nat_prev_ipv6_forward // empty' "$WG_CONF" 2>/dev/null)
  if [ -f "$nat_state" ]; then
    owned=1
    prev4=$(wg_nat_state_read ipv4_forward 2>/dev/null)
    prev6=$(wg_nat_state_read ipv6_forward 2>/dev/null)
  else
    prev4=$legacy4
    prev6=$legacy6
    [[ "$prev4" =~ ^[01]$ && "$prev6" =~ ^[01]$ ]] && owned=1
  fi
  [ -f "$backup" ] && owned=1
  if [ "$owned" -eq 0 ]; then
    local tables
    tables=$(nft list tables 2>/dev/null) || return 1
    { grep -Fqx 'table ip sbm_nat' <<<"$tables" || grep -Fqx 'table ip6 sbm_nat' <<<"$tables"; } && return 1
    return 0
  fi
  [[ "$prev4" =~ ^[01]$ && "$prev6" =~ ^[01]$ ]] || rc=1
  wg_nat_table_remove ip || rc=1
  wg_nat_table_remove ip6 || rc=1
  if [[ "$prev4" =~ ^[01]$ ]]; then sysctl -w net.ipv4.ip_forward="$prev4" >/dev/null 2>&1 || rc=1; fi
  if [[ "$prev6" =~ ^[01]$ ]]; then sysctl -w net.ipv6.conf.all.forwarding="$prev6" >/dev/null 2>&1 || rc=1; fi
  if [ -f "$backup" ]; then
    if [ "$rc" -eq 0 ]; then
      mv -f -- "$backup" "$managed" 2>/dev/null || rc=1
    fi
  elif [ -f "$managed" ]; then
    expected=$(printf '%s\n' 'net.ipv4.ip_forward=1' 'net.ipv6.conf.all.forwarding=1')
    if [ "$(cat "$managed" 2>/dev/null)" = "$expected" ]; then
      rm -f -- "$managed" || rc=1
    else
      rc=1
    fi
  fi
  if [ "$rc" -eq 0 ] && [ -f "$WG_CONF" ]; then
    json_edit "$WG_CONF" 'del(.nat_prev_ipv4_forward,.nat_prev_ipv6_forward)' >/dev/null 2>&1 || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f -- "${nat_state}.nft4" "${nat_state}.nft6" || rc=1
    [ "$rc" -eq 0 ] && rm -f -- "$nat_state" || rc=1
  fi
  return "$rc"
}

wg_config_exists(){
  [ -f "$WG_CONF" ]
}

wg_config_enabled(){
  [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]
}

wg_config_role(){
  [ -f "$WG_CONF" ] || return 0
  jq -r '.role // empty' "$WG_CONF" 2>/dev/null
}

wg_config_endpoint(){
  local resolver=$1
  [ -f "$WG_CONF" ] || { printf '%s' '[]'; return 0; }
  jq --arg resolver "$resolver" '[.endpoint | .domain_resolver = $resolver]' "$WG_CONF"
}

wg_config_peer_host(){
  [ -f "$WG_CONF" ] || return 0
  jq -r '.peer_host // empty' "$WG_CONF" 2>/dev/null
}

wg_set_enabled(){
  local enabled=$1
  case "$enabled" in
    true|false) ;;
    *) return 2 ;;
  esac
  [ -f "$WG_CONF" ] || return 1
  json_edit "$WG_CONF" ".enabled=$enabled"
}

wg_config_listen_port(){
  [ -f "$WG_CONF" ] || return 0
  jq -r '.listen_port // 0' "$WG_CONF" 2>/dev/null | grep -E '^[1-9][0-9]*$'
}

wg_client_active(){
  wg_config_enabled && [ "$(wg_config_role)" = client ]
}

wg_tunnel_state(){
  local peer_ip4=$1 peer_ip6=$2 out ms elapsed family
  [ -d "/sys/class/net/$WG_IF" ] || { echo disconnected; return; }
  if [ -n "$peer_ip6" ]; then
    out=$(ping -6 -I "$WG_IF" -c 1 -W 2 "$peer_ip6" 2>/dev/null)
    if [ $? -eq 0 ]; then
      ms=$(awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}' <<<"$out")
      [[ "$ms" =~ ^[0-9]+$ ]] && { printf 'ok|%s\n' "$ms"; return; }
    fi
  fi
  if [ -n "$peer_ip4" ]; then
    out=$(ping -4 -I "$WG_IF" -c 1 -W 2 "$peer_ip4" 2>/dev/null)
    if [ $? -eq 0 ]; then
      ms=$(awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}' <<<"$out")
      [[ "$ms" =~ ^[0-9]+$ ]] && { printf 'ok|%s\n' "$ms"; return; }
    fi
  fi
  for family in 4 6; do
    [ "$family" = 4 ] && [ -z "$(ip -4 addr show dev "$WG_IF" 2>/dev/null | awk '/inet /{print;exit}')" ] && continue
    [ "$family" = 6 ] && [ -z "$(ip -6 addr show dev "$WG_IF" 2>/dev/null | awk '/inet6 / && $2 !~ /^fe80/{print;exit}')" ] && continue
    elapsed=$(curl -"$family" -fsS -o /dev/null -w '%{time_total}' --interface "$WG_IF" --connect-timeout 3 --max-time 5 "$WARP_TRACE" 2>/dev/null) || continue
    ms=$(awk -v t="$elapsed" 'BEGIN{if(t ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0f",t*1000}')
    [[ "$ms" =~ ^[0-9]+$ ]] && { printf 'ok|%s\n' "$ms"; return; }
  done
  echo disconnected
}

wg_actual_listen_port(){
  local configured=${1:-}
  [ -d "/sys/class/net/$WG_IF" ] || { printf '%s' ""; return; }
  [[ "$configured" =~ ^[1-9][0-9]*$ ]] || return 0
  ss -Hlunp 2>/dev/null | awk -v p=":$configured" '$4 ~ (p"$") && /users:\(\("sing-box"/ {found=1} END{if(found) print p}' | sed 's/^://'
}

validate_wireguard_key(){
  local key=$1 actual tmp canonical
  [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  tmp=$(mktemp) || return 1
  if ! printf '%s' "$key" | base64 -d >"$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  actual=$(wc -c <"$tmp" | tr -d ' ')
  canonical=$(base64 -w0 "$tmp" 2>/dev/null || base64 "$tmp" | tr -d '\n')
  rm -f "$tmp"
  [ "$actual" -eq 32 ] && [ "$canonical" = "$key" ]
}

wg_keypair(){
  local keypair private public
  keypair=$("$CORE" generate wg-keypair 2>/dev/null) || return 1
  private=$(awk -F: '/^[[:space:]]*PrivateKey:/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' <<<"$keypair")
  public=$(awk -F: '/^[[:space:]]*PublicKey:/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' <<<"$keypair")
  validate_wireguard_key "$private" && validate_wireguard_key "$public" || return 1
  printf '%s|%s\n' "$private" "$public"
}

wg_default_address(){
  if [ "$1" = server ]; then
    printf '%s|%s|%s|%s\n' '10.10.0.1/24' 'fd00:10::1/64' '10.10.0.2' 'fd00:10::2'
  else
    printf '%s|%s|%s|%s\n' '10.10.0.2/24' 'fd00:10::2/64' '10.10.0.1' 'fd00:10::1'
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
local current4 current6 value edit4 edit6
  current4=$(jq -r '.address[0] // ""' "$WG_CONF")
  current6=$(jq -r '.address[1] // ""' "$WG_CONF")
  while :; do
    value=$(prompt "IPv4" "$current4")
    wg_valid_address "$value" || { tell_warn "IPv4 地址无效"; continue; }
    [[ "$value" != *:*/* ]] || { tell_warn "IPv4 地址无效"; continue; }
    edit4="$value"
    break
  done
  while :; do
    value=$(prompt "IPv6" "$current6")
    [[ $value == *:*/* ]] || { tell_warn "IPv6 地址无效"; continue; }
    wg_valid_address "$value" || { tell_warn "IPv6 地址无效"; continue; }
    edit6="$value"
    break
  done
  printf '%s|%s\n' "$edit4" "$edit6"
}

wg_backup_create(){
  local backup
  backup=$(mktemp -d) || return 1
  if [ -d "$WG_DIR" ] && ! cp -a "$WG_DIR"/. "$backup"/ 2>/dev/null; then
    rm -rf "$backup"
    return 1
  fi
  chmod 700 "$backup" || { rm -rf "$backup"; return 1; }
  printf '%s\n' "$backup"
}


wg_reinit_prepare(){
  local role enabled previous
  [ -f "$WG_CONF" ] || return 0
  role=$(wg_config_role) || return 1
  enabled=$(wg_config_enabled && printf true || printf false) || return 1
  previous=$(state_get exit) || return 1
  ip link del "$WG_IF" 2>/dev/null || true
  [ ! -d "/sys/class/net/$WG_IF" ] || return 1
  if [ "$role" = server ] && [ "$enabled" = true ]; then
    wg_server_nat_remove || return 1
  fi
  if [ "$previous" = wireguard ]; then
    state_set exit direct || return 1
    stop_watchdog || { state_set exit "$previous" || true; sync_watchdog; return 1; }
  fi
  return 0
}

wg_restore_backup(){
  local backup=$1
  rm -rf "$WG_DIR" || return 1
  mkdir -p "$WG_DIR" || return 1
  if [ -n "$(find "$backup" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    cp -a "$backup"/. "$WG_DIR"/ || return 1
  fi
  chmod 700 "$WG_DIR" || return 1
}

wg_reinit_rollback(){
  local backup=$1 previous=$2
  wg_restore_backup "$backup" || return 1
  state_set exit "$previous" || return 1
  if wg_config_enabled && [ "$(wg_config_role)" = server ]; then
    wg_server_nat_apply || return 1
  fi
  apply_config_quiet || return 1
  if [ "$previous" = wireguard ]; then
    sync_watchdog || return 1
  fi
  return 0
}

wg_status(){
  local file=$WG_CONF role enabled public ipv4 ipv6 peer_host peer_port peer_key endpoint_ips
  ui_clear
  if [ ! -f "$file" ]; then
    tell "${DIM}WireGuard 尚未配置，请先初始化。${PLAIN}"
    wait_key
    return
  fi
  role=$(jq -r '.role // ""' "$file" 2>/dev/null)
  enabled=$(jq -r '.enabled // false' "$file" 2>/dev/null)
  public=$(jq -r '.public_key // empty' "$file" 2>/dev/null)
  ipv4=$(jq -r '.address[0] // empty' "$file" 2>/dev/null)
  ipv6=$(jq -r '.address[1] // empty' "$file" 2>/dev/null)
  case "$role" in
    client)
      local state ms color
      ui_title "WireGuard 状态信息"
      state="disconnected"
      if [ "$enabled" = true ] && [ -d "/sys/class/net/$WG_IF" ]; then
        state=$(wg_tunnel_state "$(jq -r '.peer_ip // empty' "$file" 2>/dev/null)" "$(jq -r '.peer_ip6 // empty' "$file" 2>/dev/null)")
        if [[ "$state" == ok\|* || "$state" = up ]]; then
          tell "运行模式：客户端 状态：${GREEN}已连接${PLAIN}"
        else
          tell "运行模式：客户端 状态：${YELLOW}未连接${PLAIN}"
        fi
      elif [ "$enabled" = true ]; then
        tell "运行模式：客户端 状态：${RED}异常${PLAIN}"
      else
        tell "运行模式：客户端 状态：${YELLOW}已停止${PLAIN}"
      fi
      tell "wireguard接口：$WG_IF"
      tell "隧道ipv4：$ipv4"
      tell "隧道IPv6：$ipv6"
      tell ""
      peer_host=$(jq -r '.peer_host // empty' "$file" 2>/dev/null)
      peer_port=$(jq -r '.peer_port // empty' "$file" 2>/dev/null)
      peer_key=$(jq -r '.peer_public_key // empty' "$file" 2>/dev/null)
      tell "服务器：${peer_host}:${peer_port}"
      ms=${state#*|}
      if [[ "$state" == ok\|* ]] && [[ "$ms" =~ ^[0-9]+$ ]]; then
        if [ "$ms" -lt 100 ]; then color="$GREEN"; elif [ "$ms" -lt 150 ]; then color="$YELLOW"; else color="$BROWN"; fi
        tell "服务器延迟：${color}${ms}ms${PLAIN}"
      else
        if [ "$state" = up ]; then
          tell "服务器延迟：${YELLOW}—${PLAIN}"
        else
          tell "服务器延迟：${YELLOW}未连接${PLAIN}"
        fi
      fi
      tell "服务器公钥：$peer_key"
      tell "本机公钥：$public"
      tell ""
      tell "Endpoint："
      endpoint_ips=$(resolve_addresses "$peer_host" 2>/dev/null || true)
      if grep -q ':' <<<"$endpoint_ips"; then tell "IPv6：${GREEN}正常${PLAIN}"; else tell "IPv6：${YELLOW}不可用${PLAIN}"; fi
      if grep -Eq '^[0-9]+(\.[0-9]+){3}$' <<<"$endpoint_ips"; then tell "IPv4：${GREEN}正常${PLAIN}"; else tell "IPv4：${YELLOW}不可用${PLAIN}"; fi
      tell ""
            ;;
    server)
      local peer_count peer_index peer_name peer_ipv4 peer_ipv6 peer_pub
      ui_title "WireGuard 状态信息"
      if [ "$enabled" = true ] && [ -d "/sys/class/net/$WG_IF" ]; then
        tell "运行模式：服务端 状态：${GREEN}运行中${PLAIN}"
      elif [ "$enabled" = true ]; then
        tell "运行模式：服务端 状态：${RED}异常${PLAIN}"
      else
        tell "运行模式：服务端 状态：${YELLOW}已停止${PLAIN}"
      fi
      tell "wireguard接口：$WG_IF"
      tell "隧道ipv4：$ipv4"
      tell "隧道IPv6：$ipv6"
      tell ""
      local actual_port configured_port
      configured_port=$(jq -r '.listen_port // 0' "$file" 2>/dev/null)
      actual_port=$(wg_actual_listen_port "$configured_port")
      if [ "$enabled" = true ] && [ -n "$actual_port" ]; then
        tell "监听端口：$actual_port ${GREEN}已监听${PLAIN}"
      elif [ "$configured_port" -gt 0 ] 2>/dev/null; then
        tell "监听端口：$configured_port  ${RED}未监听${PLAIN}"
      fi
      tell "本机公钥：$public"
      tell ""
      peer_count=$(jq '.endpoint.peers | length' "$file" 2>/dev/null); peer_count=${peer_count:-0}
      tell "客户端数量：$peer_count"
      for ((peer_index=0; peer_index<peer_count; peer_index++)); do
        peer_name=$(jq -r ".clients[$peer_index].name // \"客户端 $((peer_index+1))\"" "$file" 2>/dev/null)
        peer_ipv4=$(jq -r ".endpoint.peers[$peer_index].allowed_ips[0] // \"\"" "$file" 2>/dev/null)
        peer_ipv6=$(jq -r ".endpoint.peers[$peer_index].allowed_ips[1] // \"\"" "$file" 2>/dev/null)
        peer_pub=$(jq -r ".endpoint.peers[$peer_index].public_key // \"\"" "$file" 2>/dev/null)
        tell ""
        tell "客户端 $((peer_index+1))：$peer_name"
        tell "IPv4：$peer_ipv4"
        tell "IPv6：$peer_ipv6"
        tell "公钥：$peer_pub"
      done
      tell ""
            ;;
    *)
      tell "${DIM}WireGuard 尚未配置，请先初始化。${PLAIN}"
      ;;
  esac
  wait_key
}

wg_build_server_config(){
  local private=$1 public=$2 ipv4=$3 ipv6=$4 port=$5
  jq -n \
    --arg private "$private" --arg public "$public" \
    --arg a4 "$ipv4" --arg a6 "$ipv6" \
    --arg iface "$WG_IF" --argjson port "$port" \
    '{role:"server",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:$port,clients:[],
      endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1280,
        address:[$a4,$a6],private_key:$private,listen_port:$port,peers:[]}}'
}

wg_build_client_config(){
  local private=$1 public=$2 ipv4=$3 ipv6=$4 peer4=$5 peer6=$6 host=$7 peer_key=$8 port=$9
  jq -n \
    --arg private "$private" --arg public "$public" \
    --arg a4 "$ipv4" --arg a6 "$ipv6" \
    --arg peer4 "$peer4" --arg peer6 "$peer6" \
    --arg host "$host" --arg peer_key "$peer_key" --arg iface "$WG_IF" --argjson port "$port" \
    '{role:"client",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:0,
      peer_public_key:$peer_key,peer_ip:$peer4,peer_ip6:$peer6,peer_host:$host,peer_port:$port,
      endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1280,
        address:[$a4,$a6],private_key:$private,
        peers:[{address:$host,port:$port,public_key:$peer_key,
          allowed_ips:["0.0.0.0/0","::/0"]}]}}'
}

wg_init_server(){
  local port body backup_wg previous_exit value private public ipv4 ipv6
  ui_title "WireGuard 服务端引导配置"
  local keypair
  keypair=$(wg_keypair) || { tell_warn "密钥生成失败"; wait_key; return; }
  private=${keypair%%|*}; public=${keypair#*|}
  port=$(prompt_port u "51820") || return
  IFS='|' read -r ipv4 ipv6 _ _ <<<"$(wg_default_address server)"
  while :; do
    value=$(prompt "隧道 IPv4" "$ipv4")
    { wg_valid_address "$value" && [[ "$value" != *:*/* ]]; } || { tell_warn "IPv4 地址无效"; continue; }
    ipv4="$value"
    break
  done
  while :; do
    value=$(prompt "隧道 IPv6" "$ipv6")
    { wg_valid_address "$value" && [[ "$value" == *:*/* ]]; } || { tell_warn "IPv6 地址无效"; continue; }
    ipv6="$value"
    break
  done
  body=$(wg_build_server_config "$private" "$public" "$ipv4" "$ipv6" "$port") || { tell_warn "配置生成失败"; wait_key; return; }
  backup_wg=$(wg_backup_create) || { tell_warn "旧配置备份失败"; wait_key; return; }
  previous_exit=$(state_get exit) || { rm -rf "$backup_wg"; tell_warn "出口状态读取失败"; wait_key; return; }
  if ! wg_reinit_prepare; then
    rm -rf "$backup_wg"
    tell_warn "旧 WireGuard 接口清理失败"
    wait_key
    return
  fi
  if ! json_save "$WG_CONF" "$body"; then
    wg_reinit_rollback "$backup_wg" "$previous_exit"
    rm -rf "$backup_wg"
    tell_warn "保存失败，已恢复旧配置"
    wait_key
    return
  fi
  printf "\n${CYAN}配置完成（回车启动服务端）${PLAIN}\n" >&2
  read_line >/dev/null
  body=$(jq '.enabled=true' "$WG_CONF") || {
    wg_reinit_rollback "$backup_wg" "$previous_exit" || true
    rm -rf "$backup_wg"
    tell_warn "启动配置生成失败，已恢复旧配置"
    wait_key
    return
  }
  if ! wg_server_nat_apply; then
    wg_reinit_rollback "$backup_wg" "$previous_exit" || true
    rm -rf "$backup_wg"
    tell_warn "NAT 配置失败，已恢复旧配置"
    wait_key
    return
  fi
  if ! wg_config_apply_transaction "$body" restart; then
    wg_reinit_rollback "$backup_wg" "$previous_exit" || true
    rm -rf "$backup_wg"
    tell_warn "服务端启动失败，已恢复旧配置"
    wait_key
    return
  fi
  rm -rf "$backup_wg"
  wg_status
}

wg_init_client(){
  local host port peer_key body private public ipv4 ipv6 peer4 peer6
  ui_title "WireGuard 客户端"
  local keypair
  keypair=$(wg_keypair) || { tell_warn "密钥生成失败"; wait_key; return; }
  private=${keypair%%|*}; public=${keypair#*|}
  tell "本机公钥: $public"
  echo ""
  host=$(prompt "服务端地址")
  [ -n "$host" ] || { tell_warn "服务端地址不能为空"; wait_key; return; }
  port=$(prompt_port u "51820") || return
  while :; do
    peer_key=$(prompt "服务端公钥")
    [ -n "$peer_key" ] && break
    tell_warn "服务端公钥不能为空"
  done
  IFS='|' read -r ipv4 ipv6 peer4 peer6 <<<"$(wg_default_address client)"
  while :; do
    ipv4=$(prompt "隧道内网 IPv4" "$ipv4")
    { wg_valid_address "$ipv4" && [[ "$ipv4" != *:*/* ]]; } && break
    tell_warn "IPv4 地址无效"
  done
  while :; do
    ipv6=$(prompt "隧道内网 IPv6" "$ipv6")
    { wg_valid_address "$ipv6" && [[ "$ipv6" == *:*/* ]]; } && break
    tell_warn "IPv6 地址无效"
  done
  body=$(wg_build_client_config "$private" "$public" "$ipv4" "$ipv6" "$peer4" "$peer6" "$host" "$peer_key" "$port") || { tell_warn "配置生成失败"; wait_key; return; }
  local backup_wg previous_exit
  backup_wg=$(wg_backup_create) || { tell_warn "旧配置备份失败"; wait_key; return; }
  previous_exit=$(state_get exit) || { rm -rf "$backup_wg"; tell_warn "出口状态读取失败"; wait_key; return; }
  if ! wg_reinit_prepare; then
    rm -rf "$backup_wg"
    tell_warn "旧 WireGuard 接口清理失败"
    wait_key
    return
  fi
  if ! wg_config_apply_transaction "$body"; then
    wg_reinit_rollback "$backup_wg" "$previous_exit" || true
    rm -rf "$backup_wg"
    tell_warn "配置应用失败，已恢复旧配置"
    wait_key
    return
  fi
  rm -rf "$backup_wg"
  tell_ok "配置完成"
  wg_status
}

wg_init(){
  ui_title "初始化配置"
  menu_item 1 "服务端"
  menu_item 2 "客户端"
  menu_item 0 "返回"
  case $(prompt "请选择") in
    1) wg_init_server ;;
    2) wg_init_client ;;
    0) return ;;
    *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
  esac
}

wg_edit_address(){
  local body
  ui_clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  ui_title "内网双栈地址"
  tell "IPv4: $(jq -r '.address[0] // ""' "$WG_CONF")"
  tell "IPv6: $(jq -r '.address[1] // ""' "$WG_CONF")"
  echo ""
  local edit4 edit6
  IFS='|' read -r edit4 edit6 <<<"$(wg_prompt_address)"
  body=$(jq --arg a4 "$edit4" --arg a6 "$edit6" '.address=[$a4,$a6]|.endpoint.address=[$a4,$a6]' "$WG_CONF") || { tell_warn "地址生成失败"; wait_key; return; }
  if ! wg_config_apply_transaction "$body"; then
    tell_warn "保存或应用失败，已恢复旧配置"
    wait_key
    return
  fi
  tell_ok "修改完成"
  wait_key
}

wg_config_apply_transaction(){
  local body=$1 mode=${2:-} force_apply=${3:-false} old_body rollback_rc=1 had_old=0
  if [ -f "$WG_CONF" ]; then
    old_body=$(cat "$WG_CONF") || return 1
    had_old=1
  fi
  json_save "$WG_CONF" "$body" || return 1
  if wg_config_enabled || [ "$force_apply" = true ]; then
    if [ -n "$mode" ]; then
      apply_config "$mode" || {
        if [ "$had_old" = 1 ]; then
          printf '%s\n' "$old_body" | json_write "$WG_CONF" || return 2
        else
          rm -f "$WG_CONF" || return 2
        fi
        apply_config_quiet || rollback_rc=2
        return "$rollback_rc"
      }
    else
      apply_config || {
        if [ "$had_old" = 1 ]; then
          printf '%s\n' "$old_body" | json_write "$WG_CONF" || return 2
        else
          rm -f "$WG_CONF" || return 2
        fi
        apply_config_quiet || rollback_rc=2
        return "$rollback_rc"
      }
    fi
  fi
  return 0
}

wg_server_client_apply(){
  local body=$1
  if ! wg_config_apply_transaction "$body" restart; then
    tell_warn "保存或应用失败，已恢复旧配置"
    return 1
  fi
  return 0
}

wg_server_client_delete_apply(){
  local body=$1
  json_save "$WG_CONF" "$body" || return 1
  if wg_config_enabled && ! apply_config restart; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    return 2
  fi
  return 0
}

wg_next_client_address(){
  local server4 server6 base4 base6 n used4 used6
  server4=$(jq -r '.address[0] // "10.10.0.1/24"' "$WG_CONF" 2>/dev/null)
  server6=$(jq -r '.address[1] // "fd00:10::1/64"' "$WG_CONF" 2>/dev/null)
  base4=${server4%/*}; base4=${base4%.*}
  base6=${server6%/*}; base6=${base6%:*}
  for n in $(seq 2 254); do
    used4=$(jq -r --arg ip "$base4.$n" '.clients[]?.ipv4 // empty' "$WG_CONF" 2>/dev/null | awk -F/ -v ip="$base4.$n" '$1==ip{found=1} END{print found+0}')
    used6=$(jq -r --arg ip "$base6:$n" '.clients[]?.ipv6 // empty' "$WG_CONF" 2>/dev/null | awk -F/ -v ip="$base6:$n" '$1==ip{found=1} END{print found+0}')
    if [ "$used4" = 0 ] && [ "$used6" = 0 ]; then
      printf '%s|%s\n' "$base4.$n/24" "$base6:$n/64"
      return 0
    fi
  done
  return 1
}

wg_client_address_conflict(){
  local index=$1 ipv4=$2 ipv6=$3 ip4=${ipv4%/*} ip6=${ipv6%/*} conflict4 conflict6
  conflict4=$(jq -r --arg ip "$ip4" --argjson i "$index" '.clients | to_entries[] | select(.key != $i) | .value.ipv4 // empty' "$WG_CONF" 2>/dev/null | awk -F/ -v ip="$ip4" '$1==ip{found=1} END{print found+0}')
  conflict6=$(jq -r --arg ip "$ip6" --argjson i "$index" '.clients | to_entries[] | select(.key != $i) | .value.ipv6 // empty' "$WG_CONF" 2>/dev/null | awk -F/ -v ip="$ip6" '$1==ip{found=1} END{print found+0}')
  [ "$conflict4" = 0 ] && [ "$conflict6" = 0 ]
}

wg_client_add(){
  local name ipv4 ipv6 pub body allowed4 allowed6 ip4 ip6
  ui_title "添加客户端"
  name=$(prompt "客户端名称")
  [ -n "$name" ] || { tell_warn "客户端名称不能为空"; wait_key; return; }
  local next_ipv4 next_ipv6
  IFS='|' read -r next_ipv4 next_ipv6 <<<"$(wg_next_client_address)" || { tell_warn "没有可用的客户端隧道地址"; wait_key; return; }
  while :; do
    ipv4=$(prompt "隧道 IPv4" "$next_ipv4")
    { wg_valid_address "$ipv4" && [[ "$ipv4" != *:*/* ]]; } || { tell_warn "IPv4 地址无效"; continue; }
    ip4=${ipv4%/*}
    if jq -e --arg ip "$ip4" 'any(.clients[]?; ((.ipv4 // "") | split("/")[0]) == $ip)' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "IPv4 地址已被其他客户端使用"
      continue
    fi
    break
  done
  while :; do
    ipv6=$(prompt "隧道 IPv6" "$next_ipv6")
    { wg_valid_address "$ipv6" && [[ "$ipv6" == *:*/* ]]; } || { tell_warn "IPv6 地址无效"; continue; }
    ip6=${ipv6%/*}
    if jq -e --arg ip "$ip6" 'any(.clients[]?; ((.ipv6 // "") | split("/")[0]) == $ip)' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "IPv6 地址已被其他客户端使用"
      continue
    fi
    break
  done
  while :; do
    pub=$(prompt "客户端公钥")
    [ -n "$pub" ] || { tell_warn "客户端公钥不能为空"; continue; }
    if jq -e --arg k "$pub" '.endpoint.peers[]? | select(.public_key==$k)' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "客户端公钥已存在"
      continue
    fi
    break
  done
  allowed4="${ipv4%/*}/32"
  allowed6="${ipv6%/*}/128"
  body=$(jq --arg name "$name" --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" --arg pub "$pub" --arg allowed4 "$allowed4" --arg allowed6 "$allowed6" \
    '.clients += [{name:$name,ipv4:$ipv4,ipv6:$ipv6,public_key:$pub}] |
     .endpoint.peers += [{public_key:$pub,allowed_ips:[$allowed4,$allowed6]}]' "$WG_CONF") || { tell_warn "配置生成失败"; wait_key; return; }
  wg_server_client_apply "$body" || { wait_key; return; }
  tell_ok "客户端已添加"
  wait_key
}

wg_client_edit(){
  local index count name ipv4 ipv6 pub body allowed4 allowed6 ip4 ip6
  count=$(jq '.endpoint.peers | length' "$WG_CONF" 2>/dev/null); count=${count:-0}
  [ "$count" -gt 0 ] || { tell_warn "暂无客户端"; wait_key; return; }
  ui_title "修改客户端"
  jq -r '.clients | to_entries[] | "\(.key+1). \(.value.name) | \(.value.ipv4) | \(.value.ipv6)"' "$WG_CONF" 2>/dev/null
  menu_item 0 "返回"
  index=$(prompt "请选择")
  [ "$index" = 0 ] && return
  [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$count" ] || { tell_warn "输入无效，请重新选择"; wait_key; return; }
  index=$((index-1))
  name=$(prompt "客户端名称" "$(jq -r ".clients[$index].name // \"\"" "$WG_CONF")")
  ipv4=$(prompt "隧道 IPv4" "$(jq -r ".clients[$index].ipv4 // \"\"" "$WG_CONF")")
  { wg_valid_address "$ipv4" && [[ "$ipv4" != *:*/* ]]; } || { tell_warn "IPv4 地址无效"; wait_key; return; }
  if ! wg_client_address_conflict "$index" "$ipv4" "$(jq -r ".clients[$index].ipv6 // \"\"" "$WG_CONF")"; then
    tell_warn "IPv4 地址已被其他客户端使用"
    wait_key
    return
  fi
  ipv6=$(prompt "隧道 IPv6" "$(jq -r ".clients[$index].ipv6 // \"\"" "$WG_CONF")")
  { wg_valid_address "$ipv6" && [[ "$ipv6" == *:*/* ]]; } || { tell_warn "IPv6 地址无效"; wait_key; return; }
  if ! wg_client_address_conflict "$index" "$ipv4" "$ipv6"; then
    ip4=${ipv4%/*}; ip6=${ipv6%/*}
    if jq -e --arg ip "$ip4" --argjson i "$index" '.clients | to_entries[] | select(.key != $i) | .value.ipv4 | split("/")[0] == $ip' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "IPv4 地址已被其他客户端使用"
    else
      tell_warn "IPv6 地址已被其他客户端使用"
    fi
    wait_key
    return
  fi
  pub=$(prompt "客户端公钥" "$(jq -r ".clients[$index].public_key // \"\"" "$WG_CONF")")
  [ -n "$pub" ] || { tell_warn "客户端公钥不能为空"; wait_key; return; }
  body=$(jq --argjson i "$index" --arg name "$name" --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" --arg pub "$pub" --arg allowed4 "${ipv4%/*}/32" --arg allowed6 "${ipv6%/*}/128" \
    '.clients[$i]={name:$name,ipv4:$ipv4,ipv6:$ipv6,public_key:$pub} |
     .endpoint.peers[$i]={public_key:$pub,allowed_ips:[$allowed4,$allowed6]}' "$WG_CONF") || { tell_warn "配置生成失败"; wait_key; return; }
  wg_server_client_apply "$body" || { wait_key; return; }
  tell_ok "客户端修改完成"
  wait_key
}

wg_client_delete(){
  local index count body
  count=$(jq '.endpoint.peers | length' "$WG_CONF" 2>/dev/null); count=${count:-0}
  [ "$count" -gt 0 ] || { tell_warn "暂无客户端"; wait_key; return; }
  ui_title "删除客户端"
  jq -r '.clients | to_entries[] | "\(.key+1). \(.value.name) | \(.value.ipv4) | \(.value.ipv6)"' "$WG_CONF" 2>/dev/null
  menu_item 0 "返回"
  index=$(prompt "请选择")
  [ "$index" = 0 ] && return
  [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$count" ] || { tell_warn "输入无效，请重新选择"; wait_key; return; }
  index=$((index-1))
  prompt_yes "确认删除客户端 $(jq -r ".clients[$index].name" "$WG_CONF")" || return
  body=$(jq --argjson i "$index" 'del(.clients[$i]) | del(.endpoint.peers[$i])' "$WG_CONF") || { tell_warn "配置生成失败"; wait_key; return; }
  if wg_server_client_delete_apply "$body"; then
    tell_ok "客户端删除完成"
  else
    tell_warn "客户端已从配置删除，但 WireGuard 服务应用失败，请检查服务状态"
  fi
  wait_key
}

wg_client_list(){
  local count
  ui_title "客户端列表"
  count=$(jq '.endpoint.peers | length' "$WG_CONF" 2>/dev/null); count=${count:-0}
  if [ "$count" -eq 0 ]; then
    tell "暂无客户端"
  else
    jq -r '.clients | to_entries[] | "\(.key+1). \(.value.name)\nIPv4：\(.value.ipv4)\nIPv6：\(.value.ipv6)\n公钥：\(.value.public_key)"' "$WG_CONF" 2>/dev/null
  fi
  wait_key
}

wg_server_clients(){
  while :; do
    ui_title "客户端管理"
    menu_item 1 "添加客户端"
    menu_item 2 "修改客户端"
    menu_item 3 "删除客户端"
    menu_item 4 "查看客户端"
    menu_item 0 "返回"
    case $(prompt "请选择") in
      1) wg_client_add ;;
      2) wg_client_edit ;;
      3) wg_client_delete ;;
      4) wg_client_list ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

wg_edit_server(){
  local value body
  while :; do
    ui_title "修改配置"
    menu_item 1 "客户端管理"
    menu_item 2 "监听端口"
    menu_item 3 "隧道内网地址"
    menu_item 0 "返回"
    case $(prompt "请选择") in
      2)
        value=$(prompt_port u "$(jq -r '.listen_port' "$WG_CONF")") || continue
        body=$(jq --argjson port "$value" '.listen_port=$port|.endpoint.listen_port=$port' "$WG_CONF") || continue
        if wg_server_client_apply "$body"; then tell_ok "修改完成"; fi
        sleep 1
        ;;
      1) wg_server_clients ;;
      3) wg_edit_address ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

wg_client_edit_apply(){
  local body=$1
  if wg_config_apply_transaction "$body"; then
    tell_ok "修改完成"
  else
    tell_warn "保存或应用失败，已恢复旧配置"
  fi
  sleep 1
}

wg_edit_client(){
  local value body
  while :; do
    ui_title "修改配置"
    menu_item 1 "服务端地址"
    menu_item 2 "服务端端口"
    menu_item 3 "服务端公钥"
    menu_item 4 "内网双栈地址"
    menu_item 0 "返回"
    case $(prompt "请选择") in
      1)
        value=$(prompt "服务端地址" "$(jq -r '.peer_host // ""' "$WG_CONF")")
        [ -n "$value" ] || { tell_warn "服务端地址不能为空"; sleep 1; continue; }
        body=$(jq --arg host "$value" '.peer_host=$host|.endpoint.peers[0].address=$host' "$WG_CONF") || continue
        wg_client_edit_apply "$body"
        ;;
      2)
        value=$(prompt_port u "$(jq -r '.peer_port' "$WG_CONF")") || continue
        body=$(jq --argjson port "$value" '.peer_port=$port|.endpoint.peers[0].port=$port' "$WG_CONF") || continue
        wg_client_edit_apply "$body"
        ;;
      3)
        value=$(prompt "服务端公钥" "$(jq -r '.peer_public_key // ""' "$WG_CONF")")
        [ -n "$value" ] || { tell_warn "服务端公钥不能为空"; sleep 1; continue; }
        body=$(jq --arg key "$value" '.peer_public_key=$key|.endpoint.peers[0].public_key=$key' "$WG_CONF") || continue
        wg_client_edit_apply "$body"
        ;;
      4) wg_edit_address ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
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
  local role previous_exit nat_failed=0 apply_failed=0 watchdog_failed=0 file_failed=0
  ui_clear
  [ -f "$WG_CONF" ] || { tell_warn "未配置 WireGuard"; wait_key; return; }
  role=$(jq -r '.role // ""' "$WG_CONF" 2>/dev/null)
  prompt_yes "确认删除 WireGuard 配置" || return
  previous_exit=$(state_get exit) || previous_exit=direct
  wg_server_nat_remove || nat_failed=1
  if [ "$previous_exit" = wireguard ]; then state_set exit direct || file_failed=1; stop_watchdog || watchdog_failed=1; fi
  ip link del "$WG_IF" >/dev/null 2>&1 || { ip link show "$WG_IF" >/dev/null 2>&1 && file_failed=1; }
  rm -rf -- "$WG_DIR" || file_failed=1
  [ ! -e "$WG_DIR" ] || file_failed=1
  if ! apply_config restart; then
    apply_failed=1
    systemctl stop sing-box >/dev/null 2>&1 || true
  fi
  sync_watchdog || watchdog_failed=1
  if [ "$nat_failed" -eq 1 ] || [ "$file_failed" -eq 1 ] || [ "$apply_failed" -eq 1 ] || [ "$watchdog_failed" -eq 1 ]; then
    tell_warn "WireGuard 删除已执行，但仍有清理或配置应用失败；请检查 NAT、状态文件、网络接口及服务状态"
  else
    tell_ok "WireGuard 配置、状态及关联资源已删除"
  fi
  wait_key
}

wg_toggle_transaction(){
  local role=$1 previous=$2 enabled=$3 body old_body
  old_body=$(cat "$WG_CONF") || return 1
  body=$(printf '%s\n' "$old_body" | jq --argjson enabled "$enabled" '.enabled=$enabled') || return 1
  if [ "$enabled" = true ]; then
    if [ "$role" = server ] && ! wg_server_nat_apply; then
      local restore_rc=0
      state_set exit "$previous" || restore_rc=2
      sync_watchdog || restore_rc=2
      return "$([ "$restore_rc" -ne 0 ] && echo 2 || echo 1)"
    fi
    if [ "$role" = client ]; then
      state_set exit wireguard || return 1
      stop_watchdog || { state_set exit "$previous" || true; sync_watchdog; return 1; }
    fi
    if wg_config_apply_transaction "$body"; then
      if [ "$role" = client ] && ! sync_watchdog; then
        local restore_rc=0
        json_write "$WG_CONF" <<<"$old_body" || restore_rc=2
        state_set exit "$previous" || restore_rc=2
        apply_config_quiet || restore_rc=2
        sync_watchdog || restore_rc=2
        return "$([ "$restore_rc" -ne 0 ] && echo 2 || echo 1)"
      fi
      return 0
    fi
    state_set exit "$previous" || return 2
    if [ "$role" = server ] && ! wg_server_nat_remove; then return 2; fi
    sync_watchdog || return 2
    return 1
  fi
  if [ "$role" = server ] && ! wg_server_nat_remove; then
    local restore_rc=0
    state_set exit "$previous" || restore_rc=2
    sync_watchdog || restore_rc=2
    return "$([ "$restore_rc" -ne 0 ] && echo 2 || echo 1)"
  fi
  if [ "$previous" = wireguard ]; then
    state_set exit direct || { sync_watchdog; return 1; }
    stop_watchdog || { state_set exit "$previous" || true; sync_watchdog; return 1; }
  fi
  if wg_config_apply_transaction "$body" "" true; then
    if [ "$role" = client ] && ! sync_watchdog; then
      local restore_rc=0
      json_write "$WG_CONF" <<<"$old_body" || restore_rc=2
      state_set exit "$previous" || restore_rc=2
      apply_config_quiet || restore_rc=2
      sync_watchdog || restore_rc=2
      return "$([ "$restore_rc" -ne 0 ] && echo 2 || echo 1)"
    fi
    return 0
  fi
  local restore_rc=0
  state_set exit "$previous" || restore_rc=2
  if [ "$role" = server ] && wg_config_enabled; then
    wg_server_nat_apply || restore_rc=2
  fi
  sync_watchdog || restore_rc=2
  return "$([ "$restore_rc" -ne 0 ] && echo 2 || echo 1)"
}

wg_toggle(){
  local role previous previous_name=${1:-} enabled
  ui_clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  role=$(jq -r '.role' "$WG_CONF") || { tell_warn "WireGuard 配置读取失败"; wait_key; return; }; previous=$(state_get exit) || { tell_warn "出口状态读取失败"; wait_key; return; }
  if [ -z "$previous_name" ]; then
    case $previous in
      direct) previous_name="直连" ;;
      wireguard) previous_name="WireGuard 专线" ;;
      *) previous_name="$previous" ;;
    esac
  fi
  modprobe wireguard 2>/dev/null || true
  enabled=$(wg_config_enabled && printf true || printf false)
  if [ "$enabled" = true ]; then
    if wg_toggle_transaction "$role" "$previous" false; then
      tell_ok "停止完成"
    else
      local status=$?
      if [ "$status" -eq 2 ]; then tell_warn "停止失败，WireGuard 配置或出口恢复不完整，请检查服务状态"; else tell_warn "配置应用失败，已恢复旧配置"; fi
    fi
  else
    if [ "$role" = client ] && [ -z "$(jq -r '.peer_public_key // ""' "$WG_CONF")" ]; then
      tell_warn "缺少服务端公钥"
      wait_key
      return
    fi
    if [ "$role" = client ] && [ "$previous" != direct ]; then
      case "$previous" in
        warp) prompt_yes $'当前 WARP 正在接管网络。\n启动 WireGuard 后，网络出口将切换至 WireGuard，并停止 WARP。\n是否切换' || return ;;
        *) prompt_yes "当前 ${previous_name} 正在接管网络。
启动 WireGuard 后，网络出口将切换至 WireGuard。
是否切换" || return ;;
      esac
    fi
    local restore_warp=0
    if [ "$role" = client ] && [ "$previous" = warp ]; then
      warp_stop quiet || { tell_warn "WARP 停止失败，未启动 WireGuard"; wait_key; return; }
      restore_warp=1
      previous=direct
    fi
    if wg_toggle_transaction "$role" "$previous" true; then
      sleep 2
      tell_ok "启动完成"
    else
      if [ "$restore_warp" = 1 ]; then
        if warp_start force quiet; then tell_warn "WireGuard 启动失败，已恢复原 WARP 出口"; else tell_warn "WireGuard 启动失败，且 WARP 恢复失败，请立即检查网络出口"; fi
      else
        tell_warn "启动失败，已回滚"
      fi
    fi
  fi
  wait_key
}

protocol_set(){
  local file=$1 expr=$2
  shift 2
  json_edit "$file" "$expr" "$@"
}

protocol_set_hysteria2_bbr(){
  local file=$1 profile=$2 up_mbps=$3 down_mbps=$4
  if [ -n "$profile" ]; then
    json_edit "$file" '
      .meta.up_mbps=0 | .meta.down_mbps=0 | .meta.bbr_profile=$b |
      del(.inbound.up_mbps,.inbound.down_mbps) |
      .inbound.bbr_profile=$b
    ' --arg b "$profile"
  else
    json_edit "$file" '
      .meta.up_mbps=$up | .meta.down_mbps=$down | .meta.bbr_profile="" |
      if $up > 0 then .inbound.up_mbps=$up else del(.inbound.up_mbps) end |
      if $down > 0 then .inbound.down_mbps=$down else del(.inbound.down_mbps) end |
      del(.inbound.bbr_profile)
    ' --argjson up "$up_mbps" --argjson down "$down_mbps"
  fi
}

protocol_set_hysteria2_obfs(){
  local file=$1 type=$2 password=$3 min_pkt=${4:-} max_pkt=${5:-}
  if [ "$type" = gecko ]; then
    json_edit "$file" \
      '.meta.obfs_type=$t | .meta.obfs_password=$p | .meta.min_packet_size=($mn|tonumber) | .meta.max_packet_size=($mx|tonumber) | .inbound.obfs={type:$t, password:$p, min_packet_size:($mn|tonumber), max_packet_size:($mx|tonumber)}' \
      --arg t "$type" --arg p "$password" --arg mn "$min_pkt" --arg mx "$max_pkt"
  elif [ -n "$type" ]; then
    json_edit "$file" \
      '.meta.obfs_type=$t | .meta.obfs_password=$p | del(.meta.min_packet_size,.meta.max_packet_size) | .inbound.obfs={type:$t, password:$p}' \
      --arg t "$type" --arg p "$password"
  else
    json_edit "$file" \
      'del(.meta.obfs_type,.meta.obfs_password,.meta.min_packet_size,.meta.max_packet_size,.inbound.obfs)' 
  fi
}

protocol_commit(){
  local file=$1 old_json=$2 rc=1
  if apply_config; then
    return 0
  fi
  printf '%s\n' "$old_json" | json_write "$file" || rc=2
  apply_config_quiet || rc=2
  return "$rc"
}

protocol_edit_name(){
  local file=$1 value
  [ -n "$file" ] && [ -f "$file" ] || return 1
  value=$(prompt "新识别名称" "$(jq -r .name "$file" 2>/dev/null)")
  [ -n "$value" ] || return 1
  protocol_set "$file" '.name=$v' --arg v "$value" || { tell_warn 失败; wait_key; return 1; }
}

protocol_edit_port(){
  local file=$1 value
  [ -n "$file" ] && [ -f "$file" ] || return 1
  value=$(prompt_port "$(jq -r .proto "$file" 2>/dev/null)" "$(jq -r .port "$file" 2>/dev/null)") || return 1
  protocol_set "$file" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" || { tell_warn 失败; wait_key; return 1; }
}

protocol_edit_option3(){
  local file=$1 kind=$2 value len
  [ -n "$file" ] && [ -f "$file" ] || return 1
  case $kind in
    socks)
      value=$(prompt "鉴权账号" "$(jq -r '.meta.username//.inbound.users[0].username//""' "$file")")
      [ -n "$value" ] || return 1
      protocol_set "$file" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    vless-reality|vless-tls|vless-ws|vless-grpc|vmess-tls|vmess-ws|vmess-grpc|vmess-http|tuic)
      while :; do
        value=$(prompt "新通信 UUID（回车保留当前，输入 random 自动生成）" "$(jq -r '.meta.uuid//""' "$file")")
        [[ "${value,,}" == random ]] && value=$(random_uuid)
        validate_uuid "$value" && break
        tell_warn "UUID 格式无效，请输入标准 UUID"
      done
      protocol_set "$file" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    snell)
      while :; do
        value=$(prompt "新 PSK（回车保留当前，输入 random 自动生成，12-255字节）" "$(jq -r .meta.psk "$file")")
        [[ "${value,,}" == random ]] && value=$(random_password)
        len=$(LC_ALL=C printf '%s' "$value" | wc -c | tr -d ' ')
        if [ "$len" -ge 12 ] && [ "$len" -le 255 ]; then break; fi
        tell_warn "PSK 长度必须为 12-255 字节，当前 ${len} 字节"
      done
      protocol_set "$file" '.meta.psk=$v|.inbound.psk=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    hysteria2)
      local old_password
      old_password=$(jq -r '.meta.password//.inbound.users[0].password//""' "$file")
      value=$(prompt "新连接密码（回车保留当前，输入 random 自动生成）" "$old_password")
      [[ "${value,,}" == random ]] && value=$(random_password)
      [ -n "$value" ] || { tell_warn "密码不能为空"; wait_key; return 1; }
      protocol_set "$file" '.meta.password=$v | .inbound.users[0].password=$v | if .meta.obfs_password==$old then .meta.obfs_password=$v | .inbound.obfs.password=$v else . end' --arg v "$value" --arg old "$old_password" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    *)
      value=$(prompt "新连接密码（回车保留当前，输入 random 自动生成）" "$(jq -r '.meta.password//""' "$file")")
      [[ "${value,,}" == random ]] && value=$(random_password)
      [ -n "$value" ] || { tell_warn "密码不能为空"; wait_key; return 1; }
      protocol_set "$file" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
  esac
}

protocol_edit_option4(){
  local file=$1 kind=$2 value current_hop other security method current_method default_method current_security default_security current_bbr default_cc
  [ -n "$file" ] && [ -f "$file" ] || return 1
  case $kind in
    shadowsocks)
      current_method=$(jq -r '.meta.method//""' "$file")
      case "$current_method" in 2022-blake3-aes-128-gcm) default_method=1;; 2022-blake3-aes-256-gcm) default_method=2;; 2022-blake3-chacha20-poly1305) default_method=3;; aes-128-gcm) default_method=4;; aes-192-gcm) default_method=5;; aes-256-gcm) default_method=6;; chacha20-ietf-poly1305) default_method=7;; xchacha20-ietf-poly1305) default_method=8;; *) default_method=2;; esac
      while :; do
        ui_clear; menu_item 1 "2022-blake3-aes-128-gcm"; menu_item 2 "2022-blake3-aes-256-gcm"; menu_item 3 "2022-blake3-chacha20-poly1305"; menu_item 4 "aes-128-gcm"; menu_item 5 "aes-192-gcm"; menu_item 6 "aes-256-gcm"; menu_item 7 "chacha20-ietf-poly1305"; menu_item 8 "xchacha20-ietf-poly1305"
        case $(prompt "加密方式" "$default_method") in
          1) value=2022-blake3-aes-128-gcm; break ;; 2) value=2022-blake3-aes-256-gcm; break ;;
          3) value=2022-blake3-chacha20-poly1305; break ;; 4) value=aes-128-gcm; break ;;
          5) value=aes-192-gcm; break ;; 6) value=aes-256-gcm; break ;; 7) value=chacha20-ietf-poly1305; break ;; 8) value=xchacha20-ietf-poly1305; break ;;
          *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
        esac
      done
      case "$value" in
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|aes-128-gcm|aes-192-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305) ;;
        *) tell_warn "当前加密方式不受支持"; wait_key; return 1 ;;
      esac
      method=$(jq -r '.meta.method//""' "$file")
      local new_password=""
      if [[ "$value" == 2022-* ]]; then
        if [ "$method" != "$value" ] || ! ss_validate_password "$value" "$(jq -r '.meta.password//""' "$file")"; then
          new_password=$(ss_generate_key "$value")
          ss_validate_password "$value" "$new_password" || { tell_warn "新加密方式的密钥生成失败或长度无效"; wait_key; return 1; }
        fi
      elif [[ "$method" == 2022-* ]] && [ "$method" != "$value" ]; then
        new_password=$(ss_generate_key "$value")
        [ -n "$new_password" ] || { tell_warn "新密码生成失败"; wait_key; return 1; }
      fi
      protocol_set "$file" '.meta.method=$m|.inbound.method=$m|if $p!="" then .meta.password=$p|.inbound.password=$p else . end' --arg m "$value" --arg p "$new_password" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    vless-ws|vless-grpc|trojan-ws|trojan-grpc|vmess-tls|vmess-ws|vmess-grpc|vmess-http)
      case $kind in
        *-ws) value=$(prompt "WebSocket Path" "$(jq -r '.meta.path//"/ws"' "$file")"); protocol_set "$file" '.meta.path=$v|.inbound.transport.path=$v' --arg v "$value" || return 1 ;;
        *-grpc) value=$(prompt "gRPC Service Name" "$(jq -r '.meta.service_name//"TunService"' "$file")"); protocol_set "$file" '.meta.service_name=$v|.inbound.transport.service_name=$v' --arg v "$value" || return 1 ;;
        vmess-http) value=$(prompt "HTTP Path" "$(jq -r '.meta.path//"/"' "$file")"); protocol_set "$file" '.meta.path=$v|.inbound.transport.path=$v' --arg v "$value" || return 1 ;;
        vmess-tls) menu_item 1 "Auto"; menu_item 2 "AES-128-GCM"; menu_item 3 "ChaCha20-Poly1305"
          current_security=$(jq -r '.meta.security//"auto"' "$file")
          case "$current_security" in auto) default_security=1;; aes-128-gcm) default_security=2;; chacha20-poly1305) default_security=3;; *) default_security=1;; esac
          while :; do
            ui_clear; menu_item 1 "Auto"; menu_item 2 "AES-128-GCM"; menu_item 3 "ChaCha20-Poly1305"
            case $(prompt "请选择" "$default_security") in
              1) security=auto; break;; 2) security=aes-128-gcm; break;; 3) security=chacha20-poly1305; break;;
              *) tell_warn "输入无效，请重新选择"; sleep 1;;
            esac
          done
          protocol_set "$file" '.meta.security=$v' --arg v "$security" || return 1 ;;
      esac
      ;;
    tuic)
      value=$(prompt "连接密码（回车保留当前，输入 random 自动生成）" "$(jq -r '.meta.password//""' "$file")")
      [[ "${value,,}" == random ]] && value=$(random_password)
      [ -n "$value" ] || { tell_warn "密码不能为空"; wait_key; return 1; }
      protocol_set "$file" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    socks)
      value=$(prompt "鉴权密码（回车保留当前，输入 random 自动生成）" "$(jq -r '.meta.password//""' "$file")")
      [[ "${value,,}" == random ]] && value=$(random_password)
      [ -n "$value" ] || return 1
      protocol_set "$file" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    snell)
      while :; do
        ui_clear
        menu_item 1 "Default"; menu_item 2 "Unshaped"; menu_item 3 "Unsafe Raw"
        case $(prompt "流量整形模式" "$(jq -r '.meta.mode//"default"' "$file")") in
          1|default) value=default; break ;; 2|unshaped) value=unshaped; break ;; 3|unsafe-raw) value=unsafe-raw; break ;;
          *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
        esac
      done
      protocol_set "$file" '.meta.mode=$v|.inbound.mode=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    hysteria2)
      current_hop=$(jq -r '.hopping//""' "$file")
      value=$(prompt "跳跃范围 (当前: ${current_hop:-未开启}, 0 关闭)" "$current_hop")
      if [ "$value" = 0 ]; then value=""; elif [ -n "$value" ]; then validate_range "$value" || return 1; else return 1; fi
      if [ -n "$value" ]; then other=$(hopping_node) && [ "$other" != "$file" ] && { tell_warn "已有节点开启跳跃"; wait_key; return 1; }; fi
      protocol_set "$file" '.hopping=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    *)
      tell_warn "当前协议不支持该配置项"; sleep 1; return 1 ;;
  esac
}

protocol_edit_option5(){
  local file=$1 kind=$2 value security bbr_profile up_mbps down_mbps current_security default_security default_cc current_cc
  [ -n "$file" ] && [ -f "$file" ] || return 1
  case $kind in
    vless-reality)
      while :; do
        value=$(prompt "新握手目标域名（回车保留当前，输入 - 取消）" "$(jq -r '.meta.target//""' "$file")")
        [ "$value" != - ] || return 1
        probe_handshake_target "$value" && break
        prompt_yes "检测异常，强制加载" && break
      done
      protocol_set "$file" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    vmess)
      current_security=$(jq -r '.meta.security//"auto"' "$file")
      case "$current_security" in auto) default_security=1;; aes-128-gcm) default_security=2;; chacha20-poly1305) default_security=3;; *) default_security=1;; esac
      while :; do
        ui_clear; menu_item 1 "Auto"; menu_item 2 "AES-128-GCM"; menu_item 3 "ChaCha20-Poly1305"
        case $(prompt "请选择" "$default_security") in
          1|auto) security=auto; break;; 2|aes-128-gcm) security=aes-128-gcm; break;; 3|chacha20-poly1305) security=chacha20-poly1305; break;;
          *) tell_warn "输入无效，请重新选择"; sleep 1;;
        esac
      done
      protocol_set "$file" '.meta.security=$v' --arg v "$security" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    tuic)
      current_cc=$(jq -r '.meta.congestion_control//"bbr"' "$file")
      case "$current_cc" in cubic) default_cc=1;; new_reno) default_cc=2;; bbr) default_cc=3;; *) default_cc=3;; esac
      while :; do
        ui_clear; menu_item 1 "cubic"; menu_item 2 "New Reno"; menu_item 3 "bbr"
        case $(prompt "请选择" "$default_cc") in
          1|cubic) value=cubic; break;; 2|new_reno) value=new_reno; break;; 3|bbr) value=bbr; break;;
          *) tell_warn "输入无效，请重新选择"; sleep 1;;
        esac
      done
      protocol_set "$file" '.meta.congestion_control=$v|.inbound.congestion_control=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; } ;;
    hysteria2)
      current_bbr=$(jq -r '.meta.bbr_profile//""' "$file")
      case "$current_bbr" in conservative) default_cc=1;; standard) default_cc=2;; aggressive) default_cc=3;; *) default_cc=4;; esac
      while :; do
        ui_clear; menu_item 1 "BBR Conservative"; menu_item 2 "BBR Standard"; menu_item 3 "BBR Aggressive"; menu_item 4 "Brutal（手动带宽）"
        case $(prompt "请选择拥塞控制" "$default_cc") in
          1) bbr_profile=conservative; up_mbps=0; down_mbps=0; break ;;
          2) bbr_profile=standard; up_mbps=0; down_mbps=0; break ;;
          3) bbr_profile=aggressive; up_mbps=0; down_mbps=0; break ;;
          4) bbr_profile=""; while :; do
            up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.up_mbps//0' "$file")"); [[ $up_mbps =~ ^[0-9]+$ ]] || { tell_warn "输入无效，请重新输入"; continue; }
            down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.down_mbps//0' "$file")"); [[ $down_mbps =~ ^[0-9]+$ ]] || { tell_warn "输入无效，请重新输入"; continue; }
            if [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ]; then break; fi
            tell_warn "Brutal 模式至少需要设置一个方向的带宽"
          done; break ;;
          *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
        esac
      done
      if [ -n "$bbr_profile" ]; then protocol_set_hysteria2_bbr "$file" "$bbr_profile" 0 0; else protocol_set_hysteria2_bbr "$file" "" "$up_mbps" "$down_mbps"; fi || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    *) tell_warn "当前协议不支持该配置项"; sleep 1; return 1 ;;
  esac
}

protocol_edit_option6(){
  local file=$1 kind=$2 value obfs_type obfs_password min_pkt max_pkt current_obfs default_obfs
  [ -n "$file" ] && [ -f "$file" ] || return 1
  if [ "$kind" = vless-reality ]; then
    value=$(prompt "新 short_id（回车保留当前，输入 random 自动生成 8位十六进制）" "$(jq -r '.meta.short_id//""' "$file")")
    [[ "${value,,}" == random ]] && value=$(openssl rand -hex 4 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c8)
    [[ $value =~ ^[0-9a-fA-F]{1,8}$ ]] || { tell_warn "short_id 必须为 1-8 位十六进制字符"; wait_key; return 1; }
    protocol_set "$file" '.meta.short_id=$v|.inbound.tls.reality.short_id=[$v]' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
  elif [ "$kind" = hysteria2 ]; then
    if prompt_yes "是否配置并开启协议混淆 (选择 N 则关闭混淆)" "$( [ -n "$(jq -r '.meta.obfs_type//""' "$file")" ] && printf y || printf n )"; then
      while :; do
        ui_clear; menu_item 1 "Salamander"; menu_item 2 "Gecko"
        current_obfs=$(jq -r '.meta.obfs_type//""' "$file")
        case "$current_obfs" in salamander) default_obfs=1;; gecko) default_obfs=2;; *) default_obfs=2;; esac
        case $(prompt "请选择混淆算法 (当前: $current_obfs)" "$default_obfs") in
          1) obfs_type=salamander; break ;; 2) obfs_type=gecko; break ;; *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
        esac
      done
      obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$(jq -r '.meta.obfs_password//.meta.password//""' "$file")")
      [ -n "$obfs_password" ] || obfs_password=$(jq -r '.meta.password' "$file")
      if [ "$obfs_type" = gecko ]; then
        min_pkt=$(prompt "最小包大小 (字节, 512-2048)" "$(jq -r '.meta.min_packet_size//512' "$file")")
        max_pkt=$(prompt "最大包大小 (字节, 512-2048)" "$(jq -r '.meta.max_packet_size//1200' "$file")")
        [[ $min_pkt =~ ^[0-9]+$ ]] && [ "$min_pkt" -ge 512 ] && [ "$min_pkt" -le 2048 ] || { tell_warn "最小包大小必须为 512-2048"; wait_key; return 1; }
        [[ $max_pkt =~ ^[0-9]+$ ]] && [ "$max_pkt" -ge "$min_pkt" ] && [ "$max_pkt" -le 2048 ] || { tell_warn "最大包大小必须为 512-2048 且不小于最小包大小"; wait_key; return 1; }
        protocol_set_hysteria2_obfs "$file" "$obfs_type" "$obfs_password" "$min_pkt" "$max_pkt"
      else
        protocol_set_hysteria2_obfs "$file" "$obfs_type" "$obfs_password"
      fi
    else
      protocol_set_hysteria2_obfs "$file" "" "" "" ""
    fi || { tell_warn "修改失败"; wait_key; return 1; }
  else
    tell_warn "当前协议不支持该配置项"; sleep 1; return 1
  fi
}

protocol_edit_option7(){
  local file=$1 kind=$2 value
  [ -n "$file" ] && [ -f "$file" ] || return 1
  case $kind in
    shadowsocks)
      local ss_method
      ss_method=$(jq -r '.meta.method' "$file")
      while :; do
        value=$(prompt "连接密码（回车保留当前，输入 random 自动生成）" "$(jq -r '.meta.password//""' "$file")")
        [[ "${value,,}" == random ]] && value=$(ss_generate_key "$ss_method")
        ss_validate_password "$ss_method" "$value" && break
        tell_warn "Shadowsocks 2022 密钥必须是有效 Base64，且解码后长度必须符合所选算法"
      done
      protocol_set "$file" '.meta.password=$v|.inbound.password=$v' --arg v "$value" || return 1 ;;
    *) tell_warn "当前协议不支持该配置项"; sleep 1; return 1 ;;
  esac
}

protocol_edit_transport(){
  local file=$1 kind=$2 family mode choice default_choice target_kind uuid password security transport path service target keypair private public short_id default_sid old_state
  old_state=$(state_snapshot) || return 1
  family=${kind%%-*}
  case "$family" in
    vless)
      case "$kind" in vless-reality) default_choice=1;; vless-tls) default_choice=2;; vless-ws) default_choice=3;; vless-grpc) default_choice=4;; esac
      ui_clear
      menu_item 1 "Reality"; menu_item 2 "TLS"; menu_item 3 "WebSocket"; menu_item 4 "gRPC"
      choice=$(prompt "请选择连接模式" "$default_choice")
      case "$choice" in 1) mode=reality;; 2) mode=tls;; 3) mode=ws;; 4) mode=grpc;; *) tell_warn "输入无效"; return 1;; esac
      [ "vless-$mode" != "$kind" ] || { tell_alert "连接模式未改变"; return 1; }
      uuid=$(jq -r '.meta.uuid//.inbound.users[0].uuid//""' "$file")
      validate_uuid "$uuid" || { tell_warn "当前节点 UUID 无效，无法切换连接模式"; return 1; }
      if [ "$mode" = reality ]; then
        while :; do
          target=$(prompt "握手目标域名" "$(jq -r '.meta.target//"www.microsoft.com"' "$file")")
          probe_handshake_target "$target" && break
          prompt_yes "检测异常，强制使用此域名" && break
        done
        keypair=$(reality_keypair) || { tell_warn "Reality 密钥对生成失败或格式无效"; return 1; }
        private=${keypair%%|*}
        public=${keypair#*|}
        default_sid=$(openssl rand -hex 4 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c8)
        short_id=$(prompt "short_id（1-8位十六进制）" "$default_sid")
        [[ "$short_id" =~ ^[0-9a-fA-F]{1,8}$ ]] || { tell_warn "short_id 必须为 1-8 位十六进制字符"; return 1; }
        protocol_set "$file" '
          .kind="vless-reality" | .tls_mode="reality" | .alpn=null |
          .meta={uuid:$uuid,target:$target,public_key:$public,short_id:$sid} |
          .inbound=(.inbound | .type="vless" | .users=[{uuid:$uuid,flow:"xtls-rprx-vision"}] | del(.tls,.transport) |
            .tls={enabled:true,server_name:$target,reality:{enabled:true,handshake:{server:$target,server_port:443},private_key:$private,short_id:[$sid]}})
        ' --arg uuid "$uuid" --arg target "$target" --arg public "$public" --arg private "$private" --arg sid "$short_id" || return 1
      else
        path=""; service=""
        case "$mode" in
          ws) path=$(prompt "WebSocket Path" "$(jq -r '.meta.path//"/ws"' "$file")") ;;
          grpc) service=$(prompt "gRPC Service Name" "$(jq -r '.meta.service_name//"TunService"' "$file")") ;;
        esac
        setup_certificate || return 1
        protocol_set "$file" '
          .kind=("vless-"+$mode) | .tls_mode="acme" | .alpn=null |
          .meta=(if $mode=="ws" then {uuid:$uuid,transport:"ws",path:$path,service_name:""}
                 elif $mode=="grpc" then {uuid:$uuid,transport:"grpc",path:"",service_name:$service}
                 else {uuid:$uuid} end) |
          .inbound=(.inbound | .type="vless" | .users=[{uuid:$uuid}] | del(.tls,.transport) |
            if $mode=="tls" then .users[0].flow="xtls-rprx-vision"
            else .tls={enabled:true} | .transport=(if $mode=="ws" then {type:"ws",path:$path} else {type:"grpc",service_name:$service} end) end)
        ' --arg mode "$mode" --arg uuid "$uuid" --arg path "$path" --arg service "$service" || { state_restore "$old_state" || tell_warn "证书状态恢复失败"; return 1; }
      fi
      ;;
    trojan)
      case "$kind" in trojan) default_choice=1;; trojan-ws) default_choice=2;; trojan-grpc) default_choice=3;; esac
      ui_clear
      menu_item 1 "TLS"; menu_item 2 "WebSocket"; menu_item 3 "gRPC"
      choice=$(prompt "请选择连接模式" "$default_choice")
      case "$choice" in 1) mode=tls;; 2) mode=ws;; 3) mode=grpc;; *) tell_warn "输入无效"; return 1;; esac
      if [ "$mode" = tls ]; then target_kind=trojan; else target_kind="trojan-$mode"; fi
      [ "$target_kind" != "$kind" ] || { tell_alert "连接模式未改变"; return 1; }
      password=$(jq -r '.meta.password//.inbound.users[0].password//""' "$file")
      [ -n "$password" ] || { tell_warn "当前节点密码为空，无法切换连接模式"; return 1; }
      path=""; service=""
      case "$mode" in
        ws) path=$(prompt "WebSocket Path" "$(jq -r '.meta.path//"/ws"' "$file")") ;;
        grpc) service=$(prompt "gRPC Service Name" "$(jq -r '.meta.service_name//"TunService"' "$file")") ;;
      esac
      setup_certificate || return 1
      protocol_set "$file" '
        .kind=(if $mode=="tls" then "trojan" else "trojan-"+$mode end) | .tls_mode="acme" | .alpn=null |
        .meta=(if $mode=="tls" then {password:$password}
               elif $mode=="ws" then {password:$password,transport:"ws",path:$path,service_name:""}
               else {password:$password,transport:"grpc",path:"",service_name:$service} end) |
        .inbound=(.inbound | .type="trojan" | .users=[{password:$password}] | del(.tls,.transport) |
          if $mode=="tls" then . else .tls={enabled:true} | .transport=(if $mode=="ws" then {type:"ws",path:$path} else {type:"grpc",service_name:$service} end) end)
      ' --arg mode "$mode" --arg password "$password" --arg path "$path" --arg service "$service" || { state_restore "$old_state" || tell_warn "证书状态恢复失败"; return 1; }
      ;;
    vmess)
      case "$kind" in vmess-tls) default_choice=1;; vmess-ws) default_choice=2;; vmess-grpc) default_choice=3;; vmess-http) default_choice=4;; esac
      ui_clear
      menu_item 1 "TLS"; menu_item 2 "WebSocket + TLS"; menu_item 3 "gRPC + TLS"; menu_item 4 "HTTP + TLS"
      choice=$(prompt "请选择连接模式" "$default_choice")
      case "$choice" in 1) mode=tls;; 2) mode=ws;; 3) mode=grpc;; 4) mode=http;; *) tell_warn "输入无效"; return 1;; esac
      [ "vmess-$mode" != "$kind" ] || { tell_alert "连接模式未改变"; return 1; }
      uuid=$(jq -r '.meta.uuid//.inbound.users[0].uuid//""' "$file")
      validate_uuid "$uuid" || { tell_warn "当前节点 UUID 无效，无法切换连接模式"; return 1; }
      security=$(jq -r '.meta.security//"auto"' "$file")
      path=""; service=""
      case "$mode" in
        ws) path=$(prompt "WebSocket Path" "$(jq -r '.meta.path//"/ws"' "$file")") ;;
        grpc) service=$(prompt "gRPC Service Name" "$(jq -r '.meta.service_name//"TunService"' "$file")") ;;
        http) path=$(prompt "HTTP Path" "$(jq -r '.meta.path//"/"' "$file")") ;;
      esac
      setup_certificate || return 1
      protocol_set "$file" '
        .kind=("vmess-"+$mode) | .tls_mode="acme" | .alpn=null |
        .meta={uuid:$uuid,security:$security,transport:$mode,path:$path,service_name:$service} |
        .inbound=(.inbound | .type="vmess" | .users=[{uuid:$uuid,alterId:0}] | .tls={enabled:true} |
          if $mode=="tls" then del(.transport)
          elif $mode=="ws" then .transport={type:"ws",path:$path}
          elif $mode=="grpc" then .transport={type:"grpc",service_name:$service}
          else .transport={type:"http",path:$path} end)
      ' --arg mode "$mode" --arg uuid "$uuid" --arg security "$security" --arg path "$path" --arg service "$service" || { state_restore "$old_state" || tell_warn "证书状态恢复失败"; return 1; }
      ;;
    *) tell_warn "当前协议不支持切换连接模式"; return 1 ;;
  esac
}

menu_modify_protocol(){
  local choice kind name old_json old_state file
  ui_title "修改配置"
  select_node file "修改配置" || return
  while :; do
    [ -n "$file" ] && [ -f "$file" ] || { tell_warn "节点文件不存在，无法修改"; wait_key; return 1; }
    kind=$(jq -er '.kind // empty' "$file" 2>/dev/null) || { tell_warn "节点配置读取失败"; wait_key; return 1; }
    name=$(jq -er '.name // .tag // empty' "$file" 2>/dev/null) || { tell_warn "节点名称读取失败"; wait_key; return 1; }
    ui_title "$name"
    menu_item 1 "节点名称"; menu_item 2 "监听端口"
    case $kind in
      shadowsocks) menu_item 3 "加密方式"; menu_item 4 "连接密码" ;;
      vless-reality) menu_item 3 "通信 UUID"; menu_item 4 "握手目标域名"; menu_item 5 "short_id"; menu_item 6 "连接模式/传输方式" ;;
      vless-tls) menu_item 3 "通信 UUID"; menu_item 4 "连接模式/传输方式" ;;
      vless-ws) menu_item 3 "通信 UUID"; menu_item 4 "WebSocket Path"; menu_item 5 "连接模式/传输方式" ;;
      vless-grpc) menu_item 3 "通信 UUID"; menu_item 4 "gRPC Service Name"; menu_item 5 "连接模式/传输方式" ;;
      vmess-tls) menu_item 3 "通信 UUID"; menu_item 4 "加密方式"; menu_item 5 "连接模式/传输方式" ;;
      vmess-ws) menu_item 3 "通信 UUID"; menu_item 4 "WebSocket Path"; menu_item 5 "加密方式"; menu_item 6 "连接模式/传输方式" ;;
      vmess-grpc) menu_item 3 "通信 UUID"; menu_item 4 "gRPC Service Name"; menu_item 5 "加密方式"; menu_item 6 "连接模式/传输方式" ;;
      vmess-http) menu_item 3 "通信 UUID"; menu_item 4 "HTTP Path"; menu_item 5 "加密方式"; menu_item 6 "连接模式/传输方式" ;;
      trojan) menu_item 3 "连接密码"; menu_item 4 "连接模式/传输方式" ;;
      trojan-ws) menu_item 3 "连接密码"; menu_item 4 "WebSocket Path"; menu_item 5 "连接模式/传输方式" ;;
      trojan-grpc) menu_item 3 "连接密码"; menu_item 4 "gRPC Service Name"; menu_item 5 "连接模式/传输方式" ;;
      tuic) menu_item 3 "通信 UUID"; menu_item 4 "连接密码"; menu_item 5 "拥塞控制" ;;
      socks) menu_item 3 "鉴权账号"; menu_item 4 "鉴权密码" ;;
      snell) menu_item 3 "预共享密钥"; menu_item 4 "流量整形模式" ;;
      anytls) menu_item 3 "连接密码" ;;
      hysteria2) menu_item 3 "连接密码"; menu_item 4 "端口跳跃机制"; menu_item 5 "拥塞控制"; menu_item 6 "混淆设置" ;;
      *) menu_item 3 "连接密码" ;;
    esac
    menu_item 0 "返回"
    choice=$(prompt "请选择")
    [ "$choice" = 0 ] && return
    old_json=$(cat "$file") || { tell_warn "节点文件读取失败"; wait_key; return 1; }
    old_state=""
    case "$kind:$choice" in
      vless-reality:6|vless-tls:4|vless-ws:5|vless-grpc:5|trojan:4|trojan-ws:5|trojan-grpc:5|vmess-tls:5|vmess-ws:6|vmess-grpc:6|vmess-http:6)
        old_state=$(state_snapshot) || { tell_warn "证书状态读取失败"; wait_key; return 1; } ;;
    esac
    case "$kind:$choice" in
      *:1) protocol_edit_name "$file" || continue ;;
      *:2) protocol_edit_port "$file" || continue ;;
      shadowsocks:3) protocol_edit_option4 "$file" "$kind" || continue ;;
      shadowsocks:4) protocol_edit_option7 "$file" "$kind" || continue ;;
      *:3) protocol_edit_option3 "$file" "$kind" || continue ;;
      vless-reality:4) protocol_edit_option5 "$file" "$kind" || continue ;;
      vless-reality:5) protocol_edit_option6 "$file" "$kind" || continue ;;
      vless-ws:4|vless-grpc:4|vmess-tls:4|vmess-ws:4|vmess-grpc:4|vmess-http:4|trojan-ws:4|trojan-grpc:4) protocol_edit_option4 "$file" "$kind" || continue ;;
      vmess-ws:5|vmess-grpc:5|vmess-http:5) protocol_edit_option5 "$file" vmess || continue ;;
      tuic:4|socks:4|snell:4|hysteria2:4) protocol_edit_option4 "$file" "$kind" || continue ;;
      tuic:5|hysteria2:5) protocol_edit_option5 "$file" "$kind" || continue ;;
      hysteria2:6) protocol_edit_option6 "$file" "$kind" || continue ;;
      trojan:3|vless-tls:3|vmess-tls:3) protocol_edit_option3 "$file" "$kind" || continue ;;
      vless-reality:6|vless-tls:4|vless-ws:5|vless-grpc:5|trojan:4|trojan-ws:5|trojan-grpc:5|vmess-tls:5|vmess-ws:6|vmess-grpc:6|vmess-http:6) protocol_edit_transport "$file" "$kind" || continue ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1; continue ;;
    esac
    if protocol_commit "$file" "$old_json"; then
      tell_ok "修改完成"; printf "\n"; render_share_uri "$file"
    else
      local status=$?
      if [ -n "$old_state" ]; then
        if ! state_restore "$old_state" || ! apply_config_quiet; then tell_warn "证书状态回滚或配置重新应用失败，请立即检查"; fi
      fi
      if [ "$status" -eq 2 ]; then tell_warn "配置应用失败，节点文件或服务回滚不完整，请立即检查"; else tell_warn "配置冲突或校验失败，已回滚"; fi
    fi
    wait_key
  done
}

core_version(){
  if [ -z "$CORE_VERSION" ] && [ -x "$CORE" ]; then
    CORE_VERSION=$("$CORE" version 2>/dev/null | awk '/version/{print $3; exit}')
  fi
  printf '%s' "$CORE_VERSION"
}

core_version_at_least(){
  local current required
  current=$(core_version)
  required=$1
  [[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([-+].*)?$ ]] || return 1
  local cmajor=${BASH_REMATCH[1]} cminor=${BASH_REMATCH[2]} cpatch=${BASH_REMATCH[3]} csuffix=${BASH_REMATCH[4]:-}
  [[ "$required" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  local rmajor=${BASH_REMATCH[1]} rminor=${BASH_REMATCH[2]} rpatch=${BASH_REMATCH[3]}
  if (( cmajor > rmajor )); then return 0; fi
  if (( cmajor < rmajor )); then return 1; fi
  if (( cminor > rminor )); then return 0; fi
  if (( cminor < rminor )); then return 1; fi
  if (( cpatch > rpatch )); then return 0; fi
  if (( cpatch < rpatch )); then return 1; fi
  [ -z "$csuffix" ]
}

core_supports_bypass(){
  core_version_at_least 1.13.0
}

core_cache_reset(){ CORE_VERSION=""; }

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

remote_version(){
  local json tag
  json=$(release_json) || return 1
  tag=$(jq -er '.tag_name // empty' <<<"$json" 2>/dev/null) || return 1
  printf '%s\n' "${tag#v}"
}

install_core(){
  local json url asset candidate tmp found digest
  json=$(release_json) || { tell_warn "获取版本信息失败或遭遇 API 限流"; return 1; }
  jq -e . >/dev/null 2>&1 <<<"$json" || { tell_warn "获取版本信息失败或遭遇 API 限流"; return 1; }
  for candidate in $(asset_candidates); do
    url=$(jq -er --arg s "$candidate.tar.gz" '.assets[]?|select(.name|endswith($s))|.browser_download_url' <<<"$json" 2>/dev/null | head -1) || url=
    digest=$(jq -er --arg s "$candidate.tar.gz" '.assets[]?|select(.name|endswith($s))|.digest // empty' <<<"$json" 2>/dev/null | head -1) || digest=
    [ -n "$url" ] && { asset=$candidate; break; }
  done
  [ -n "$url" ] || { tell_warn "未找到匹配架构的安装包"; return 1; }
  tmp=$(mktemp -d) || { tell_warn "临时目录创建失败"; return 1; }
  if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 240 "$url" -o "$tmp/core.tar.gz" 2>/dev/null; then
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 240 "$url" -o "$tmp/core.tar.gz" 2>/dev/null; then
      rm -rf "$tmp"; tell_warn "安装包下载失败"; return 1
    fi
  fi
  if [ -z "$digest" ]; then
    rm -rf "$tmp"; tell_warn "发布元数据未提供安装包 SHA-256，拒绝安装"; return 1
  fi
  local expected actual
  expected=${digest#sha256:}
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { rm -rf "$tmp"; tell_warn "安装包 SHA-256 格式无效"; return 1; }
  actual=$(sha256sum "$tmp/core.tar.gz" | awk '{print $1}')
  [ "$actual" = "$expected" ] || { rm -rf "$tmp"; tell_warn "安装包 SHA-256 校验失败"; return 1; }
  tar -xzf "$tmp/core.tar.gz" -C "$tmp" || { rm -rf "$tmp"; tell_warn "安装包解压失败"; return 1; }
  found=$(find "$tmp" -type f -name sing-box | head -1)
  [ -n "$found" ] || { rm -rf "$tmp"; tell_warn "未找到二进制文件"; return 1; }
  if ! install -m755 "$found" "$CORE"; then
    rm -rf "$tmp"
    tell_warn "sing-box 二进制安装失败"
    return 1
  fi
  rm -rf "$tmp" || return 1
  core_cache_reset
  state_set asset "$asset" || return 1
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
  write_dropin || return 1
  systemctl daemon-reload || return 1
}

write_dropin(){
  mkdir -p "$DROPIN_DIR" || return 1
  cat >"$DROPIN" <<EOF
[Service]
ExecStartPost=-$SHORTCUT --sync
ExecStopPost=-$SHORTCUT --clear-hopping
EOF
}

run_core_reinstall(){
  local success_msg=$1 apply_fail_msg=$2 install_fail_msg=$3
  if ! timeout 15 systemctl stop sing-box >/dev/null 2>&1; then
    tell_warn "sing-box 停止失败，取消内核更新"
    return 1
  fi
  if install_core; then
    if apply_config; then
      tell_ok "$success_msg"
    else
      tell_warn "$apply_fail_msg"
    fi
  else
    apply_config_quiet
    tell_warn "$install_fail_msg"
  fi
}

state_init(){
  [ -f "$STATE" ] || json_write "$STATE" <<<'{"exit":"direct","domain":"","email":"","challenge":"http","asset":""}' || return 1
}

state_get(){
  jq -e . "$STATE" >/dev/null 2>&1 || return 1
  jq -r --arg k "$1" '.[$k]//""' "$STATE" 2>/dev/null
}

state_set(){
  json_edit "$STATE" '.[$k]=$v' --arg k "$1" --arg v "$2"
}

state_acme_clear_identity(){
  json_edit "$STATE" '.domain="" | .email="" | .challenge="http" | del(.cf_token,.ali_key,.ali_secret,.acmedns_url,.acmedns_user,.acmedns_pass,.acmedns_sub)'
}

state_snapshot(){
  jq -e . "$STATE" >/dev/null 2>&1 || return 1
  cat "$STATE"
}

state_restore(){
  local snapshot=$1
  jq -e . >/dev/null 2>&1 <<<"$snapshot" || return 1
  json_write "$STATE" <<<"$snapshot"
}

warp_registered(){
  [ -s "$WARP_CONF" ] && jq -e '.id and .token and .private_key and .config.peers[0].public_key and .config.peers[0].endpoint.host and (.config.interface.addresses.v4 or .config.interface.addresses.v6)' "$WARP_CONF" >/dev/null 2>&1
}

warp_normalize_endpoint(){
  local file=$1 tmp
  [ -s "$file" ] || return 1
  tmp="${file}.norm"
  jq 'if (.config.peers[0].endpoint.host // "") != "" and (.config.peers[0].endpoint.port // null) == null and (.config.peers[0].endpoint.host|test(":\\d+$")) then
        .config.peers[0].endpoint as $e |
        ($e.host | capture("^(?<host>.*):(?<port>[0-9]+)$")) as $hp |
        .config.peers[0].endpoint.host=$hp.host |
        .config.peers[0].endpoint.port=($hp.port|tonumber)
      else . end' "$file" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"
}

WARP_HTTP_CODE=000
WARP_API_INTERFACE=""
WARP_API_FAMILY=""
WARP_TUNNEL_INTERFACE=""
WARP_TUNNEL_FAMILY=""
WARP_TUNNEL_ADDRESS=""

warp_transport_select(){
  probe_network_stack || true
  WARP_API_INTERFACE=""
  WARP_API_FAMILY=""
  if [ -n "$NET_IPV4" ] && [ -n "$NET_IF_V4" ]; then
    WARP_API_FAMILY=4
    WARP_API_INTERFACE="$NET_IF_V4"
  elif [ -n "$NET_IPV6" ] && [ -n "$NET_IF_V6" ]; then
    WARP_API_FAMILY=6
    WARP_API_INTERFACE="$NET_IF_V6"
  else
    return 1
  fi
  return 0
}

warp_api_alternate_transport(){
  if [ "$WARP_API_FAMILY" = 4 ] && [ -n "$NET_IPV6" ] && [ -n "$NET_IF_V6" ]; then
    WARP_API_FAMILY=6
    WARP_API_INTERFACE="$NET_IF_V6"
    return 0
  fi
  if [ "$WARP_API_FAMILY" = 6 ] && [ -n "$NET_IPV4" ] && [ -n "$NET_IF_V4" ]; then
    WARP_API_FAMILY=4
    WARP_API_INTERFACE="$NET_IF_V4"
    return 0
  fi
  return 1
}

warp_tunnel_select(){
  local host=$1 resolved4 resolved6
  WARP_TUNNEL_INTERFACE=""
  WARP_TUNNEL_FAMILY=""
  WARP_TUNNEL_ADDRESS=""
  if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    [ -n "$NET_IPV4" ] && [ -n "$NET_IF_V4" ] || return 1
    WARP_TUNNEL_FAMILY=4
    WARP_TUNNEL_INTERFACE="$NET_IF_V4"
    WARP_TUNNEL_ADDRESS="$host"
  elif [[ "$host" == *:* ]]; then
    [ -n "$NET_IPV6" ] && [ -n "$NET_IF_V6" ] || return 1
    WARP_TUNNEL_FAMILY=6
    WARP_TUNNEL_INTERFACE="$NET_IF_V6"
    WARP_TUNNEL_ADDRESS="$host"
  else
    resolved4=$(resolve_addresses "$host" 2>/dev/null | awk '/^[0-9]+(\.[0-9]+){3}$/{print;exit}')
    resolved6=$(resolve_addresses "$host" 2>/dev/null | awk '/:/{print;exit}')
    if [ -n "$resolved4" ] && [ -n "$NET_IPV4" ] && [ -n "$NET_IF_V4" ]; then
      WARP_TUNNEL_FAMILY=4
      WARP_TUNNEL_INTERFACE="$NET_IF_V4"
      WARP_TUNNEL_ADDRESS="$resolved4"
      return 0
    elif [ -n "$resolved6" ] && [ -n "$NET_IPV6" ] && [ -n "$NET_IF_V6" ]; then
      WARP_TUNNEL_FAMILY=6
      WARP_TUNNEL_INTERFACE="$NET_IF_V6"
      WARP_TUNNEL_ADDRESS="$resolved6"
      return 0
    else
      return 1
    fi
  fi
  [ -n "$WARP_TUNNEL_INTERFACE" ] && [ -n "$WARP_TUNNEL_ADDRESS" ] || return 1
}

warp_api_request_once(){
  local method=$1 url=$2 token=${3:-} body=${4:-} out=$5 code curl_rc
  WARP_HTTP_CODE=000
  [ -n "$out" ] || return 2
  if [ "$method" = POST ]; then
    local args=(-sS --location --tlsv1.3 --connect-timeout 8 --max-time 20 -o "$out" -w '%{http_code}' -X POST "$url" \
      -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.10-2158' \
      -H 'Content-Type: application/json' --data "$body")
    [ -n "$WARP_API_FAMILY" ] && args=("-$WARP_API_FAMILY" "${args[@]}")
    [ -n "$WARP_API_INTERFACE" ] && args+=( --interface "$WARP_API_INTERFACE" )
    code=$(curl "${args[@]}" 2>/dev/null); curl_rc=$?
  else
    local args=(-sS --location --tlsv1.3 --connect-timeout 8 --max-time 15 -o "$out" -w '%{http_code}' -X "$method" "$url" \
      -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.10-2158')
    [ -n "$token" ] && args+=( -H "Authorization: Bearer $token" )
    [ -n "$WARP_API_FAMILY" ] && args=("-$WARP_API_FAMILY" "${args[@]}")
    [ -n "$WARP_API_INTERFACE" ] && args+=( --interface "$WARP_API_INTERFACE" )
    code=$(curl "${args[@]}" 2>/dev/null); curl_rc=$?
  fi
  [ "$curl_rc" -eq 0 ] || { WARP_HTTP_CODE=000; return 1; }
  WARP_HTTP_CODE=$code
  [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

warp_api_request(){
  local saved_family=$WARP_API_FAMILY saved_interface=$WARP_API_INTERFACE
  if warp_api_request_once "$@"; then return 0; fi
  if warp_api_alternate_transport; then
    if warp_api_request_once "$@"; then return 0; fi
  fi
  WARP_API_FAMILY=$saved_family
  WARP_API_INTERFACE=$saved_interface
  return 1
}

warp_keypair(){
  local keypair private public
  keypair=$(wg_keypair) || return 1
  private=${keypair%%|*}
  public=${keypair#*|}
  printf '%s\t%s\n' "$private" "$public"
}

warp_make_body(){
  local public=$1 install_id fcm tos
  install_id=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
  [ "${#install_id}" -eq 22 ] || return 1
  fcm="${install_id}:APA91b$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134)"
  tos=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  WARP_INSTALL_ID=$install_id
  jq -n --arg key "$public" --arg iid "$install_id" --arg fcm "$fcm" --arg tos "$tos" \
    '{key:$key,install_id:$iid,fcm_token:$fcm,tos:$tos,model:"PC",serial_number:$iid,locale:"zh_CN"}'
}

warp_refresh(){
  warp_registered || return 1
  local id token tmp current mode registered_at private public iid
  mode=$(warp_mode_get)
  warp_transport_select || return 1
  id=$(warp_config_get '.id'); token=$(warp_config_get '.token')
  [ -n "$id" ] && [ -n "$token" ] || return 1
  tmp=$(mktemp) || return 1
  if ! warp_api_request GET "$WARP_API/$id" "$token" '' "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  warp_normalize_endpoint "$tmp" || true
  jq -e --arg id "$id" '.id==$id and .config.peers[0].public_key and .config.peers[0].endpoint.host and (.config.peers[0].endpoint.port|tonumber) and (.config.interface.addresses.v4 or .config.interface.addresses.v6)' "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  current=$(cat "$WARP_CONF") || { rm -f "$tmp"; return 1; }
  registered_at=$(jq -r '.registered_at // empty' <<<"$current")
  private=$(jq -r '.private_key // empty' <<<"$current")
  public=$(jq -r '.public_key // empty' <<<"$current")
  iid=$(jq -r '.install_id // empty' <<<"$current")
  jq --arg pk "$private" --arg pub "$public" --arg iid "$iid" --arg mode "$mode" --arg registered "$registered_at" --arg token "$token" \
    '. + {token:$token,private_key:$pk,public_key:$pub,install_id:$iid,warp_mode:$mode,registered_at:$registered}' "$tmp" >"$tmp.new" 2>/dev/null || { rm -f "$tmp" "$tmp.new"; return 1; }
  install -m600 "$tmp.new" "$WARP_CONF" || { rm -f "$tmp" "$tmp.new"; return 1; }
  rm -f "$tmp" "$tmp.new"
}

warp_mode_get(){
  local mode; mode=$(warp_config_get '.warp_mode // "dual"')
  case "$mode" in ipv4|ipv6|dual) printf '%s' "$mode" ;; *) printf '%s' dual ;; esac
}
warp_mode_set(){ case "$1" in ipv4|ipv6|dual) json_edit "$WARP_CONF" '.warp_mode=$mode' --arg mode "$1" ;; *) return 1 ;; esac; }
warp_mode_label(){ case "$(warp_mode_get)" in ipv4) printf 'IPv4' ;; ipv6) printf 'IPv6' ;; *) printf '双栈' ;; esac; }
warp_config_get(){ jq -r "$1" "$WARP_CONF" 2>/dev/null; }

warp_endpoint(){
  local resolver=$1 mode private peer addr4 addr6 host endpoint_host port allowed addresses
  mode=$(warp_mode_get)
  private=$(warp_config_get '.private_key')
  peer=$(warp_config_get '.config.peers[0].public_key')
  addr4=$(warp_config_get '.config.interface.addresses.v4')
  addr6=$(warp_config_get '.config.interface.addresses.v6')
  host=$(warp_config_get '.config.peers[0].endpoint.host')
  port=$(warp_config_get '.config.peers[0].endpoint.port')
  if ! [[ "$port" =~ ^[0-9]+$ ]] && [[ "$host" =~ ^(.+):([0-9]+)$ ]]; then
    port=${BASH_REMATCH[2]}; host=${BASH_REMATCH[1]}
  fi
  [ -n "$private" ] && [ -n "$peer" ] && [ -n "$host" ] && [[ "$port" =~ ^[0-9]+$ ]] || return 1
  warp_tunnel_select "$host" || return 1
  endpoint_host="$WARP_TUNNEL_ADDRESS"
  [ -n "$endpoint_host" ] || return 1
  case "$mode" in
    ipv4) [ -n "$addr4" ] || return 1; addresses=$(jq -n --arg a "$addr4/32" '[$a]'); allowed='["0.0.0.0/0"]' ;;
    ipv6) [ -n "$addr6" ] || return 1; addresses=$(jq -n --arg a "$addr6/128" '[$a]'); allowed='["::/0"]' ;;
    dual) [ -n "$addr4" ] && [ -n "$addr6" ] || return 1; addresses=$(jq -n --arg a4 "$addr4/32" --arg a6 "$addr6/128" '[$a4,$a6]'); allowed='["0.0.0.0/0","::/0"]' ;;
    *) return 1 ;;
  esac
  jq -n --arg resolver "$resolver" --arg host "$endpoint_host" --argjson port "$port" --arg private "$private" --arg peer "$peer" \
    --arg bind "$WARP_TUNNEL_INTERFACE" --argjson addresses "$addresses" --argjson allowed "$allowed" \
    '{type:"wireguard",tag:"warp",system:true,name:"warp",mtu:1280,address:$addresses,private_key:$private,
      peers:[{address:$host,port:$port,public_key:$peer,allowed_ips:$allowed,persistent_keepalive_interval:25,reserved:[0,0,0]}],
      domain_resolver:$resolver} | if $bind != "" then . + {bind_interface:$bind} else . end'
}

warp_status(){
  if ! warp_registered; then echo unconfigured; return; fi
  if [ "$(state_get exit 2>/dev/null)" = warp ] && systemctl is-active --quiet sing-box 2>/dev/null && ip link show "$TUN_IF" >/dev/null 2>&1 && ip link show "$WARP_IF" >/dev/null 2>&1; then
    echo running
  else
    echo stopped
  fi
}

warp_register(){
  local new_ip_target=${1:-}
  case "$new_ip_target" in ipv4|ipv6|dual) ;; *) return 1 ;; esac
  warp_transport_select || { tell_warn "没有可用的 WARP 上游网络"; wait_key; return 1; }
  local old_id old_token keypair private public body response_file refresh_file registration_id registration_token api_error
  local register_ok=0 attempt=1
  mkdir -p "$WARP_DIR" || { tell_warn "目录创建失败"; return 1; }
  old_id=$(warp_config_get '.id'); old_token=$(warp_config_get '.token')
  keypair=$(warp_keypair) || { tell_warn "WireGuard 密钥生成失败"; wait_key; return 1; }
  private=${keypair%%$'\t'*}; public=${keypair#*$'\t'}
  response_file=$(mktemp) || { tell_warn "临时文件创建失败"; wait_key; return 1; }
  while [ "$attempt" -le 8 ]; do
    body=$(warp_make_body "$public") || { attempt=$((attempt+1)); continue; }
    : >"$response_file"
    tell "注册 ${attempt}/8 ..."
    if warp_api_request POST "$WARP_API" '' "$body" "$response_file"; then
      registration_id=$(jq -r '.id // empty' "$response_file" 2>/dev/null)
      registration_token=$(jq -r '.token // empty' "$response_file" 2>/dev/null)
      if [ -n "$registration_id" ] && [ -n "$registration_token" ]; then
        warp_normalize_endpoint "$response_file" || true
        if ! jq -e '.config.peers[0].public_key and .config.peers[0].endpoint.host and (.config.peers[0].endpoint.port|tonumber) and (.config.interface.addresses.v4 or .config.interface.addresses.v6)' "$response_file" >/dev/null 2>&1; then
          refresh_file=$(mktemp)
          if warp_api_request GET "$WARP_API/$registration_id" "$registration_token" '' "$refresh_file"; then
            warp_normalize_endpoint "$refresh_file" || true
            if jq -e --arg id "$registration_id" '.id==$id and .config.peers[0].public_key and .config.peers[0].endpoint.host and (.config.peers[0].endpoint.port|tonumber) and (.config.interface.addresses.v4 or .config.interface.addresses.v6)' "$refresh_file" >/dev/null 2>&1; then
              jq --arg token "$registration_token" '.token=$token' "$refresh_file" >"$response_file.new" 2>/dev/null && mv -f "$response_file.new" "$response_file"
            fi
          fi
          rm -f "$refresh_file" "$response_file.new"
        fi
        if jq -e '.account and .id and .token and .config.peers[0].public_key and .config.peers[0].endpoint.host and (.config.peers[0].endpoint.port|tonumber) and (.config.interface.addresses.v4 or .config.interface.addresses.v6)' "$response_file" >/dev/null 2>&1; then
          register_ok=1
          break
        fi
      fi
    fi
    if [ "$attempt" -lt 8 ]; then sleep $((attempt < 4 ? attempt : 3)); fi
    attempt=$((attempt+1))
  done
  if [ "$register_ok" != 1 ]; then
    api_error=$(jq -r 'if .error.message then .error.message elif .errors and (.errors|type=="array") then ([.errors[]? | if .message then ((.code|tostring)+" "+.message) else tostring end] | join("; ")) elif .message then .message else empty end' "$response_file" 2>/dev/null)
    rm -f "$response_file"
    if [ "$WARP_HTTP_CODE" = 000 ]; then
      tell_warn "注册失败：无法连接 Cloudflare"
    elif [ -n "$api_error" ]; then
      tell_warn "注册失败：HTTP $WARP_HTTP_CODE $api_error"
    else
      tell_warn "注册失败：HTTP $WARP_HTTP_CODE"
    fi
    wait_key
    return 1
  fi
  if ! jq --arg pk "$private" --arg pub "$public" --arg iid "$WARP_INSTALL_ID" --arg mode "$new_ip_target" '{id:.id,token:.token,private_key:$pk,public_key:$pub,install_id:$iid,account:.account,config:.config,warp_mode:$mode,registered_at:(now|todateiso8601)}' "$response_file" | json_write "$WARP_CONF"; then
    rm -f "$response_file"; tell_warn "配置保存失败"; wait_key; return 1
  fi
  rm -f "$response_file"; chmod 700 "$WARP_DIR"; chmod 600 "$WARP_CONF"
  if [ -n "$old_id" ] && [ -n "$old_token" ] && [ "$old_id" != "$(warp_config_get '.id')" ]; then
    local old_response
    old_response=$(mktemp) || old_response=
    if [ -n "$old_response" ]; then warp_api_request DELETE "$WARP_API/$old_id" "$old_token" '' "$old_response" || true; rm -f "$old_response"; fi
  fi
  tell_ok "注册成功"
  warp_mode_set "$new_ip_target" || { tell_warn "WARP 出口模式保存失败"; return 1; }
  warp_start force quiet || return 1
}

warp_trace(){
  local family=$1 res ip loc colo warp
  case "$family" in
    4) res=$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$WARP_TRACE" 2>/dev/null) || return 1 ;;
    6) res=$(curl -6 -fsS --connect-timeout 5 --max-time 8 "$WARP_TRACE" 2>/dev/null) || return 1 ;;
    *) return 2 ;;
  esac
  ip=$(awk -F= '$1=="ip"{print $2;exit}' <<<"$res"); loc=$(awk -F= '$1=="loc"{print $2;exit}' <<<"$res"); colo=$(awk -F= '$1=="colo"{print $2;exit}' <<<"$res"); warp=$(awk -F= '$1=="warp"{print $2;exit}' <<<"$res")
  [ -n "$ip" ] || return 1; printf '%s\t%s\t%s\t%s\n' "$ip" "$loc" "$colo" "$warp"
}

warp_exit_ok(){
  local mode=${1:-$(warp_mode_get)} info4 info6 attempt=0
  while [ "$attempt" -lt 5 ]; do
    case "$mode" in
      ipv4) info4=$(warp_trace 4) || info4=; [ "$(cut -f4 <<<"$info4")" = on ] && return 0 ;;
      ipv6) info6=$(warp_trace 6) || info6=; [ "$(cut -f4 <<<"$info6")" = on ] && return 0 ;;
      dual)
        info4=$(warp_trace 4) || info4=
        info6=$(warp_trace 6) || info6=
        [ "$(cut -f4 <<<"$info4")" = on ] && [ "$(cut -f4 <<<"$info6")" = on ] && return 0
        ;;
      *) return 1 ;;
    esac
    attempt=$((attempt+1))
    [ "$attempt" -lt 5 ] && sleep 2
  done
  return 1
}

warp_show_exit(){
  local mode info4 info6 ip4 ip6 loc4 loc6 colo4 colo6 warp4 warp6
  mode=$(warp_mode_get)
  info4=$(warp_trace 4) || info4=
  info6=$(warp_trace 6) || info6=
  ip4=$(cut -f1 <<<"$info4"); loc4=$(cut -f2 <<<"$info4"); colo4=$(cut -f3 <<<"$info4"); warp4=$(cut -f4 <<<"$info4")
  ip6=$(cut -f1 <<<"$info6"); loc6=$(cut -f2 <<<"$info6"); colo6=$(cut -f3 <<<"$info6"); warp6=$(cut -f4 <<<"$info6")
  tell "当前出口：$(warp_mode_label)"
  case "$mode" in
    ipv4) tell "IPv4：${ip4:-获取失败} | ${loc4:-??} | ${colo4:-未知} | CF WARP=${warp4:-off}"; tell "IPv6：${ip6:-获取失败} | ${loc6:-??} | ${colo6:-未知} | 本机直连" ;;
    ipv6) tell "IPv4：${ip4:-获取失败} | ${loc4:-??} | ${colo4:-未知} | 本机直连"; tell "IPv6：${ip6:-获取失败} | ${loc6:-??} | ${colo6:-未知} | CF WARP=${warp6:-off}" ;;
    dual) tell "IPv4：${ip4:-获取失败} | ${loc4:-??} | ${colo4:-未知} | CF WARP=${warp4:-off}"; tell "IPv6：${ip6:-获取失败} | ${loc6:-??} | ${colo6:-未知} | CF WARP=${warp6:-off}" ;;
  esac
  if [ -n "$ip4$ip6" ]; then tell_ok "已获取出口 IP"; else tell_warn "出口 IP 获取失败"; fi
}

warp_fetch_exit(){
  ui_title "WARP 出口"
  local again choice mode
  if ! warp_registered; then
    tell "当前状态：${DIM}未注册${PLAIN}"
    tell ""
    local register_confirm
    register_confirm=$(prompt "开始注册 (Y/n)" "y")
    [[ "$register_confirm" =~ ^[yY]$ ]] || { wait_key; return; }
  else
    if [ "$(warp_status)" = running ]; then
      warp_show_exit
      tell ""
      again=$(prompt "是否重新获取出口 (y/N)" "n")
      [[ "$again" =~ ^[yY]$ ]] || { wait_key; return; }
    else
      tell "当前状态：${YELLOW}未启用${PLAIN}"
      tell ""
    fi
  fi
  menu_item 1 "IPv4"
  menu_item 2 "IPv6"
  menu_item 3 "双栈"
  menu_item 0 "返回"
  tell ""
  while :; do
    choice=$(prompt "请选择")
    case "$choice" in
      1) mode=ipv4; break ;;
      2) mode=ipv6; break ;;
      3) mode=dual; break ;;
      0) return 0 ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1
         ui_clear
         ui_title "WARP 出口"
         menu_item 1 "IPv4"
         menu_item 2 "IPv6"
         menu_item 3 "双栈"
         menu_item 0 "返回"
         tell "" ;;
    esac
  done
  tell "正在获取新的 WARP $(case "$mode" in ipv4) printf 'IPv4';; ipv6) printf 'IPv6';; dual) printf '双栈';; esac) 出口..."
  if warp_register "$mode"; then
    ui_title "WARP 出口"; tell ""
    tell_ok "已获取新的 WARP $(warp_mode_label) 出口 IP"
    tell ""; warp_show_exit
  else
    tell_warn "获取新的 WARP 出口 IP 失败"
  fi
  wait_key
}

warp_stop(){
  local quiet=${1:-} previous
  if [ "$quiet" != quiet ]; then ui_title "WARP"; tell "正在停止..."; fi
  previous=$(state_get exit) || previous=direct
  if [ "$previous" = warp ]; then
    state_set exit direct || { [ "$quiet" = quiet ] || tell_warn "出口状态更新失败"; [ "$quiet" = quiet ] || wait_key; return 1; }
    if ! stop_watchdog; then
      state_set exit warp || true
      sync_watchdog || true
      [ "$quiet" = quiet ] || tell_warn "看门狗停止失败，WARP 状态未改变"
      [ "$quiet" = quiet ] || wait_key
      return 1
    fi
    if ! apply_config_quiet; then
      state_set exit warp || true
      sync_watchdog || true
      apply_config_quiet || true
      [ "$quiet" = quiet ] || tell_warn "sing-box 停止 WARP 失败，已恢复状态"
      [ "$quiet" = quiet ] || wait_key
      return 1
    fi
    if ! sync_watchdog; then
      state_set exit warp || true
      apply_config_quiet || true
      sync_watchdog || true
      [ "$quiet" = quiet ] || tell_warn "WARP 停止后的监控状态同步失败，已恢复 WARP 出口"
      [ "$quiet" = quiet ] || wait_key
      return 1
    fi
  else
    apply_config_quiet || true
  fi
  warp_registered && json_edit "$WARP_CONF" 'del(.started_at)' || true
  if [ "$quiet" != quiet ]; then tell_ok "已停止"; wait_key; fi
}

warp_start(){
  local force=${1:-} quiet=${2:-} previous effective_previous mode previous_wg=0 restore_rc=0
  if [ "$quiet" != quiet ]; then ui_title "WARP"; tell "正在启动..."; fi
  warp_registered || { [ "$quiet" = quiet ] || { tell_warn "请先注册 WARP"; wait_key; }; return 1; }
  if [ "$force" != force ] && [ "$(warp_status)" = running ]; then
    if warp_exit_ok; then
      if [ "$quiet" != quiet ]; then tell_ok "已在运行，WARP 出口正常"; warp_show_exit; wait_key; fi
      return 0
    fi
  fi
  if ! warp_refresh; then [ "$quiet" = quiet ] || { tell_warn "WARP 注册信息刷新失败，已停止启动（拒绝使用过期配置）"; wait_key; }; return 1; fi
  mode=$(warp_mode_get)
  warp_transport_select || { [ "$quiet" = quiet ] || { tell_warn "没有可用的 WARP 上游网络，无法启用 WARP"; wait_key; }; return 1; }
  previous=$(state_get exit) || { [ "$quiet" = quiet ] || { tell_warn "出口状态读取失败"; wait_key; }; return 1; }
  effective_previous=$previous
  if [ "$effective_previous" = direct ] && wg_client_active; then effective_previous=wireguard; fi
  if [ "$effective_previous" != direct ] && [ "$effective_previous" != warp ]; then
    prompt_yes "当前 $( [ "$effective_previous" = wireguard ] && printf 'WireGuard 专线' || printf '%s' "$effective_previous" ) 正在接管网络。
启动 WARP 后，网络出口将切换至 WARP。
是否切换" || return 1
  fi
  if [ "$effective_previous" = wireguard ] && wg_client_active; then
    if ! wg_toggle_transaction client "$previous" false; then
      [ "$quiet" = quiet ] || { tell_warn "WireGuard 停止失败，未启动 WARP"; wait_key; }
      return 1
    fi
    previous_wg=1
  fi
  if ! state_set exit warp; then
    restore_rc=2
  elif ! stop_watchdog; then
    restore_rc=1
  elif ! apply_config; then
    restore_rc=1
  else
    sleep 1
    warp_exit_ok "$mode" && restore_rc=0 || restore_rc=1
  fi
  if [ "$restore_rc" -ne 0 ]; then
    local rollback_rc=0
    state_set exit "$previous" || rollback_rc=2
    if [ "$previous_wg" = 1 ]; then wg_set_enabled true || rollback_rc=2; fi
    apply_config_quiet || rollback_rc=2
    sync_watchdog || rollback_rc=2
    if [ "$rollback_rc" -ne 0 ]; then
      [ "$quiet" = quiet ] || { tell_warn "WARP 启动失败，且恢复原出口失败，请立即检查配置与服务状态"; wait_key; }
      return 2
    fi
    [ "$quiet" = quiet ] || { tell_warn "WARP 启动或出口验证失败，已恢复原出口"; wait_key; }
    return 1
  fi
  json_edit "$WARP_CONF" '.started_at=$started' --arg started "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || true
  if [ "$quiet" != quiet ]; then
    tell_ok "启动成功，当前为 WARP $(case "$(warp_mode_get)" in ipv4) echo "单 IPv4 出口";; ipv6) echo "单 IPv6 出口";; dual) echo "双栈出口";; esac)"
    warp_show_exit
  fi
  return 0
}

warp_status_view(){
  ui_title "WARP 状态"
  case "$(warp_status)" in unconfigured) tell "状态：${DIM}未配置${PLAIN}"; wait_key; return;; stopped) tell "状态：${YELLOW}未启用${PLAIN}"; wait_key; return;; esac
  local mode info4 info6 ip4 ip6 loc4 loc6 colo4 colo6 warp4 warp6 started now created up_secs up_h up_m
  mode=$(warp_mode_get); warp_exit_ok && tell "WARP：${GREEN}Cloudflare 已确认${PLAIN}" || tell "WARP：${YELLOW}尚未确认${PLAIN}"
  info4=$(warp_trace 4) || info4=
  info6=$(warp_trace 6) || info6=
  ip4=$(cut -f1 <<<"$info4"); loc4=$(cut -f2 <<<"$info4"); colo4=$(cut -f3 <<<"$info4"); warp4=$(cut -f4 <<<"$info4")
  ip6=$(cut -f1 <<<"$info6"); loc6=$(cut -f2 <<<"$info6"); colo6=$(cut -f3 <<<"$info6"); warp6=$(cut -f4 <<<"$info6")
  tell "状态：${GREEN}已启用${PLAIN}"; tell "接管：$(warp_mode_label)"; tell ""
  tell "IPv4：${ip4:-获取失败} | ${loc4:-??} | ${colo4:-未知} | WARP=${warp4:-off}"
  tell "IPv6：${ip6:-获取失败} | ${loc6:-??} | ${colo6:-未知} | WARP=${warp6:-off}"
  tell "WARP 公钥：$(warp_config_get '.public_key')"; tell "账户状态：${GREEN}已注册${PLAIN}"
  started=$(warp_config_get '.started_at'); if [ -n "$started" ]; then now=$(date +%s); created=$(date -d "$started" +%s 2>/dev/null || echo 0); up_secs=$((now-created)); [ "$up_secs" -lt 0 ] && up_secs=0; up_h=$((up_secs/3600)); up_m=$(((up_secs%3600)/60)); tell "运行时间：${up_h}h ${up_m}m"; fi
  wait_key
}

warp_delete(){
  ui_title "删除 WARP 配置"
  tell "当前状态：$(case "$(warp_status)" in running) echo -e "${GREEN}已启用${PLAIN}";; stopped) echo -e "${YELLOW}未启用${PLAIN}";; *) echo -e "${DIM}未配置${PLAIN}";; esac)"
  tell ""; tell "${YELLOW}⚠ 将删除本地 WARP 配置及注册信息${PLAIN}"; tell ""; prompt_yes "确认删除" || return
  local id token response_file previous remote_delete_ok=1 apply_failed=0 watchdog_failed=0
  previous=$(state_get exit) || previous=direct
  id=$(warp_config_get '.id'); token=$(warp_config_get '.token')
  if [ -n "$id" ] && [ -n "$token" ]; then
    if warp_transport_select; then
      response_file=$(mktemp) || response_file=
      if [ -n "$response_file" ]; then
        warp_api_request DELETE "$WARP_API/$id" "$token" '' "$response_file" || remote_delete_ok=0
        rm -f "$response_file"
      else
        remote_delete_ok=0
      fi
    else
      remote_delete_ok=0
    fi
  fi
  if [ "$previous" = warp ]; then
    state_set exit direct || apply_failed=1
    stop_watchdog || watchdog_failed=1
  fi
  rm -rf -- "$WARP_DIR" || apply_failed=1
  [ ! -e "$WARP_DIR" ] || apply_failed=1
  if [ "$previous" = warp ] && ! apply_config; then
    apply_failed=1
    systemctl stop sing-box >/dev/null 2>&1 || true
  fi
  sync_watchdog || watchdog_failed=1
  if [ "$remote_delete_ok" -eq 1 ]; then
    if [ "$apply_failed" -eq 1 ]; then tell_warn "WARP 本地及远端配置已删除，但 sing-box 配置应用失败，服务已停止"
    elif [ "$watchdog_failed" -eq 1 ]; then tell_warn "WARP 已删除，但 watchdog 同步失败；请检查当前代理出口的健康检测服务"
    else tell_ok "WARP 配置及本地注册信息已删除"; fi
  else
    if [ "$apply_failed" -eq 1 ]; then tell_warn "WARP 本地配置已删除，远端注销失败，sing-box 配置应用失败且服务已停止"
    elif [ "$watchdog_failed" -eq 1 ]; then tell_warn "WARP 本地配置已删除，远端注销失败，watchdog 同步也失败"
    else tell_warn "WARP 本地配置已删除，但 Cloudflare 远端注销失败"; fi
  fi
  wait_key
}

menu_warp(){
  while :; do
    ui_title "WARP 管理"
    tell ""
    tell "当前状态：$(case "$(warp_status)" in unconfigured) echo -e "${DIM}未配置${PLAIN}";; stopped) echo -e "${YELLOW}未启用${PLAIN}";; running) echo -e "${GREEN}已启用${PLAIN}";; esac)"
    tell ""
    menu_item 1 "获取出口 IP"
    menu_item 2 "查看 WARP 配置"
    menu_item 3 "启用/停用 WARP"
    menu_item 4 "删除配置"
    menu_item 0 "返回"
    case $(prompt "请选择") in
      1) warp_fetch_exit ;;
      2) warp_status_view ;;
      3) if [ "$(warp_status)" = running ]; then warp_stop; else warp_start; fi ;;
      4) warp_delete ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

restore_config(){
  local backup=$1
  if [ -n "$backup" ] && [ -s "$backup" ]; then
    install -m600 "$backup" "$CONFIG" || return 1
    timeout 15 systemctl restart sing-box >/dev/null 2>&1 || return 1
    systemctl is-active --quiet sing-box || return 1
  else
    rm -f "$CONFIG" || return 1
    timeout 15 systemctl stop sing-box >/dev/null 2>&1 || return 1
    systemctl is-active --quiet sing-box && return 1 || true
  fi
}

apply_config(){
  local tmp error line guard=0 prev_conf="" action=${1:-reload-or-restart}
  case "$action" in reload-or-restart|restart) ;; *) return 2 ;; esac
  exec 8>"$CONFIG_LOCK" || { tell_warn "配置锁创建失败"; return 1; }
  flock -w 30 8 || { tell_warn "配置正在被其他任务修改"; return 1; }
  tmp=$(mktemp) || { flock -u 8; return 1; }
  if [ -f "$CONFIG" ]; then
    prev_conf=$(mktemp) || { rm -f "$tmp"; flock -u 8; tell_warn "配置备份文件创建失败"; return 1; }
    cp "$CONFIG" "$prev_conf" || { rm -f "$tmp" "$prev_conf"; flock -u 8; tell_warn "配置备份失败"; return 1; }
  fi
  build_config >"$tmp" 2>/dev/null || { rm -f "$tmp" "$prev_conf"; flock -u 8; tell_warn "配置生成失败"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp" "$prev_conf"; flock -u 8; tell_warn "配置写入异常"; return 1; }
  if ! error=$("$CORE" check -c "$tmp" 2>&1); then
    tell_warn "配置校验未通过:"
    while IFS= read -r line; do tell "$line"; done <<<"$(head -4 <<<"$error")"
    rm -f "$tmp" "$prev_conf"; flock -u 8; return 1
  fi
  if ! install -m600 "$tmp" "$CONFIG"; then
    rm -f "$tmp" "$prev_conf"; flock -u 8
    tell_warn "配置安装失败"
    return 1
  fi
  rm -f "$tmp"
  if ! timeout 15 systemctl "$action" sing-box >/dev/null 2>&1; then
    tell_warn "sing-box 重载/重启失败，正在回滚配置"
    if ! restore_config "$prev_conf"; then
      rm -f "$prev_conf"; flock -u 8; return 2
    fi
    rm -f "$prev_conf"
    sync_hopping_rules || { flock -u 8; return 2; }
    flock -u 8; return 1
  fi
  while ! systemctl is-active --quiet sing-box; do
    sleep 0.2; guard=$((guard+1)); [ "$guard" -gt 15 ] && break
  done
  if ! systemctl is-active --quiet sing-box; then
    tell_warn "服务启动异常:"
    while IFS= read -r line; do tell "$line"; done <<<"$(journalctl -u sing-box -n 5 --no-pager 2>/dev/null)"
    if ! restore_config "$prev_conf"; then
      rm -f "$prev_conf"; flock -u 8; return 2
    fi
    rm -f "$prev_conf"
    sync_hopping_rules || { flock -u 8; return 2; }
    flock -u 8; return 1
  fi
  if ! sync_hopping_rules; then
    tell_warn "跳跃规则同步失败，正在回滚配置"
    if [ -n "$prev_conf" ] && [ -s "$prev_conf" ]; then
      if ! restore_config "$prev_conf"; then
        rm -f "$prev_conf"; flock -u 8; return 2
      fi
    else
      rm -f "$CONFIG" || { rm -f "$prev_conf"; flock -u 8; return 1; }
      timeout 15 systemctl stop sing-box >/dev/null 2>&1 || { rm -f "$prev_conf"; flock -u 8; return 1; }
    fi
    rm -f "$prev_conf"
    sync_hopping_rules || { flock -u 8; return 2; }
    flock -u 8; return 1
  fi
  rm -f "$prev_conf"
  flock -u 8
  return 0
}

apply_config_quiet(){ apply_config >/dev/null 2>&1; }

stop_watchdog(){
  if ! systemctl is-active --quiet sbm-watchdog.service; then
    systemctl reset-failed 'sbm-watchdog*' 2>/dev/null || true
    return 0
  fi
  timeout 15 systemctl stop sbm-watchdog.service 2>/dev/null || return 1
  systemctl reset-failed 'sbm-watchdog*' 2>/dev/null || return 1
  systemctl is-active --quiet sbm-watchdog.service && return 1
  return 0
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
    systemctl daemon-reload || { tell_warn "看门狗服务配置重载失败"; return 1; }
  fi
  systemctl enable sbm-watchdog.service >/dev/null 2>&1 || return 1
  if ! systemctl restart sbm-watchdog.service >/dev/null 2>&1; then
    systemctl start sbm-watchdog.service >/dev/null 2>&1 || { tell_warn "看门狗启动失败"; return 1; }
  fi
  systemctl is-active --quiet sbm-watchdog.service || return 1
}

watchdog_needed(){
  local exit_node
  exit_node=$(state_get exit) || return 2
  if [ "$exit_node" = wireguard ]; then
    wg_client_active
    return $?
  fi
  if [ "$exit_node" = direct ] && wg_client_active; then return 0; fi
  [ "$exit_node" != direct ] && [ "$exit_node" != warp ]
}
sync_watchdog(){ watchdog_needed; case $? in 0) restart_watchdog;; 1) stop_watchdog;; *) return 1;; esac; }

run_watchdog(){
  trap 'exit 0' TERM INT
  local current wg_state
  while :; do
    current=$(state_get exit) || exit 1
    if wg_client_active && { [ "$current" = direct ] || [ "$current" = wireguard ]; }; then
      wg_state=$(wg_tunnel_state "$(jq -r '.peer_ip // empty' "$WG_CONF" 2>/dev/null)" "$(jq -r '.peer_ip6 // empty' "$WG_CONF" 2>/dev/null)")
      logger -t sbm-watchdog "WireGuard client state: $wg_state" 2>/dev/null || true
    elif [ "$current" != direct ] && [ "$current" != warp ]; then
      if [ ! -s "$PEER_DIR/$current.json" ]; then
        logger -t sbm-watchdog "Selected proxy node $current is missing; keeping selected route unchanged" 2>/dev/null || true
      elif curl -fsS -o /dev/null --connect-timeout 4 -m 6 "$PROBE_URL" || curl -fsS -o /dev/null --connect-timeout 4 -m 6 "http://captive.apple.com/hotspot-detect.html"; then
        logger -t sbm-watchdog "Selected proxy node $current probe succeeded" 2>/dev/null || true
      else
        logger -t sbm-watchdog "Selected proxy node $current probe failed; keeping selected route unchanged" 2>/dev/null || true
      fi
    fi
    sleep 120
  done
}

server_node_name(){ jq -r '.name // .tag // ""' "$1" 2>/dev/null; }
server_node_kind(){ jq -r '.kind // ""' "$1" 2>/dev/null; }
server_node_tls_mode(){ jq -r '.tls_mode // ""' "$1" 2>/dev/null; }
server_acme_node_count(){
  local file count=0
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    [ "$(server_node_tls_mode "$file")" = acme ] && count=$((count+1))
  done
  printf '%s' "$count"
}

select_node(){
  local index target=$1 title=${2:-选择节点} count raw_data node_file kind port name proto
  local -a files
  [ -n "$target" ] || return 2
  while :; do
    ui_title "$title"
    count=0; files=()
    set -- "$NODE_DIR"/*.json
    [ "$#" -gt 0 ] || { tell "系统内暂无节点"; wait_key; return 1; }
    local tcp_list udp_list
    tcp_list=$(singbox_listening_ports t 2>/dev/null) || tcp_list=""
    udp_list=$(singbox_listening_ports u 2>/dev/null) || udp_list=""
    if ! raw_data=$(jq -c '"\(input_filename)" as $f | {file:$f,kind:(.kind//"-"),port:(.port//"-"),name:(.name//"-"),proto:(.proto//"-")}' "$@" 2>/dev/null); then
      tell_warn "节点数据读取失败"; return 1
    fi
    if [ -n "$raw_data" ]; then
      while IFS= read -r row; do
        node_file=$(jq -r '.file' <<<"$row")
        kind=$(jq -r '.kind' <<<"$row")
        port=$(jq -r '.port' <<<"$row")
        name=$(jq -r '.name' <<<"$row")
        proto=$(jq -r '.proto' <<<"$row")
        count=$((count+1)); files+=("$node_file")
        local status_text color display_kind name_display
        if [ "$proto" = "tu" ] || [ "$kind" = "shadowsocks" ]; then
          local ss_tcp_ok=0 ss_udp_ok=0
          grep -qx "$port" <<<"$tcp_list" && ss_tcp_ok=1
          grep -qx "$port" <<<"$udp_list" && ss_udp_ok=1
          status_text="TCP监听:$([ "$ss_tcp_ok" = 1 ] && echo 正常 || echo 异常) UDP监听:$([ "$ss_udp_ok" = 1 ] && echo 正常 || echo 异常)"
          color="$([ "$ss_tcp_ok" = 1 ] && [ "$ss_udp_ok" = 1 ] && printf '%s' "$GREEN" || printf '%s' "$RED")"
        elif [ "$proto" = "u" ]; then
          grep -qx "$port" <<<"$udp_list" && { color="$GREEN"; status_text="正常"; } || { color="$RED"; status_text="异常"; }
        else
          grep -qx "$port" <<<"$tcp_list" && { color="$GREEN"; status_text="正常"; } || { color="$RED"; status_text="异常"; }
        fi
        case "$kind" in
          vless-reality|vless-tls|vless-ws|vless-grpc) display_kind="VLESS" ;;
          trojan|trojan-ws|trojan-grpc) display_kind="Trojan" ;;
          hysteria2) display_kind="Hysteria2" ;;
          tuic) display_kind="TUIC" ;;
          shadowsocks) display_kind="Shadowsocks" ;;
          vmess) display_kind="VMess" ;;
          anytls) display_kind="AnyTLS" ;;
          socks) display_kind="SOCKS5" ;;
          snell) display_kind="Snell" ;;
          *) display_kind="$kind" ;;
        esac
        name_display=$(LC_ALL=C.UTF-8 printf '%s' "$name" | cut -c1-20)
        [ "$name_display" != "$name" ] && name_display="${name_display}…"
        if [ "$proto" = "tu" ] || [ "$kind" = "shadowsocks" ]; then
          printf '%b%d.%b %b%s-%s-%s-%bTCP监听:%s%b %bUDP监听:%s%b\n' \
            "$BOLD$CYAN" "$count" "$PLAIN" "$BOLD$WHITE" "$display_kind" "$name_display" "$port" \
            "$BOLD$([ "$ss_tcp_ok" = 1 ] && printf '%s' "$GREEN" || printf '%s' "$RED")" "$([ "$ss_tcp_ok" = 1 ] && echo 正常 || echo 异常)" "$PLAIN" \
            "$BOLD$([ "$ss_udp_ok" = 1 ] && printf '%s' "$GREEN" || printf '%s' "$RED")" "$([ "$ss_udp_ok" = 1 ] && echo 正常 || echo 异常)" "$PLAIN"
        else
          printf '%b%d.%b %b%s-%s-%s-%b%s%b\n' \
            "$BOLD$CYAN" "$count" "$PLAIN" "$BOLD$WHITE" "$display_kind" "$name_display" "$port" \
            "$BOLD$color" "$status_text" "$PLAIN"
        fi
      done <<<"$raw_data"
    fi
    [ "$count" = 0 ] && { wait_key; return 1; }
    menu_item 0 "返回"
    index=$(prompt "请选择")
    [ -z "$index" ] && return 1
    [ "$index" = 0 ] && return 1
    if [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$count" ]; then
      printf -v "$target" '%s' "${files[$((index-1))]}"
      return 0
    fi
    tell_warn "输入无效，请重新选择"
    sleep 1
  done
}

cleanup_old_domain_assets(){
  local domain=$1 dir rc=0
  [ -n "$domain" ] || return 0
  for dir in "$ACME_DIR"/certificates/*/"$domain"; do
    [ -d "$dir" ] || continue
    rm -rf -- "$dir" || rc=1
  done
  return "$rc"
}

acme_domain_assets_exist(){
  local domain=$1 dir
  [ -n "$domain" ] || return 1
  for dir in "$ACME_DIR"/certificates/*/"$domain"; do
    [ -d "$dir" ] && return 0
  done
  return 1
}

server_change_domain_rollback(){
  local old_state=$1 new_domain=$2 had_new_assets=${3:-0} rc=0
  state_restore "$old_state" || rc=1
  if [ "$had_new_assets" != 1 ]; then cleanup_old_domain_assets "$new_domain" || rc=1; fi
  return "$rc"
}

server_change_domain_process_cleanup(){
  local pid=${1:-} tmp=${2:-} log_file=${3:-}
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  [ -n "$tmp" ] && rm -f -- "$tmp"
  [ -n "$log_file" ] && rm -f -- "$log_file"
}

server_change_domain_transaction(){
  local new_domain=$1 old_state=$2 had_new_assets=${3:-0}
  local tmp log_file pid old_domain
  old_domain=$(jq -er '.domain // empty' <<<"$old_state") || return 2

  state_set domain "$new_domain" || return 2
  tmp=$(mktemp) || { state_restore "$old_state" || tell_warn "状态回滚失败，请手动检查"; return 2; }
  if ! jq -n --argjson p "$(acme_options "$new_domain")" '{log:{level:"warn",timestamp:true},certificate_providers:[($p+{type:"acme",tag:"acme-temporary"})]}' >"$tmp" 2>/dev/null; then
    server_change_domain_process_cleanup "" "$tmp" ""
    state_restore "$old_state" || tell_warn "状态回滚失败，请手动检查"
    return 2
  fi
  if ! "$CORE" check -c "$tmp" >/dev/null 2>&1; then
    server_change_domain_process_cleanup "" "$tmp" ""
    state_restore "$old_state" || tell_warn "状态回滚失败，请手动检查"
    return 3
  fi
  log_file=$(mktemp) || {
    server_change_domain_process_cleanup "" "$tmp" ""
    state_restore "$old_state" || tell_warn "状态回滚失败，请手动检查"
    return 4
  }
  "$CORE" run -c "$tmp" >"$log_file" 2>&1 &
  pid=$!
  if wait_for_certificate "$new_domain" "$pid" "$log_file"; then
    server_change_domain_process_cleanup "$pid" "$tmp" "$log_file"
    if apply_config; then
      if [ "$old_domain" != "$new_domain" ] && ! cleanup_old_domain_assets "$old_domain"; then
        tell_warn "旧域名证书清理失败，但新域名已成功切换；请稍后手动清理旧证书"
      fi
      return 0
    fi
    if ! server_change_domain_rollback "$old_state" "$new_domain" "$had_new_assets"; then
      apply_config_quiet || true
      return 5
    fi
    apply_config_quiet || return 5
    return 5
  fi

  server_change_domain_process_cleanup "$pid" "$tmp" "$log_file"
  if ! server_change_domain_rollback "$old_state" "$new_domain" "$had_new_assets"; then
    return 5
  fi
  return 4
}


server_delete_node_transaction(){
  local file=$1 previous_exit was_exit=0 rc=0
  [ -f "$file" ] || return 2
  previous_exit=$(state_get exit) || previous_exit=direct
  [ "$(jq -r '.tag // ""' "$file" 2>/dev/null)" = "$previous_exit" ] && was_exit=1
  if [ "$was_exit" = 1 ]; then
    state_set exit direct || rc=1
    stop_watchdog || rc=1
  fi
  rm -f -- "$file" || return 2
  if ! apply_config; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    stop_watchdog || true
    return 3
  fi
  sync_watchdog || rc=1
  [ "$rc" -eq 0 ] || return 4
  return 0
}
server_node_rollback(){
  local file=$1 old_state=$2 rc=0
  rm -f "$file" || rc=1
  state_restore "$old_state" || rc=1
  apply_config_quiet || rc=1
  return "$rc"
}

server_node_wait_for_certificate(){
  local file=$1 tls_mode domain
  tls_mode=$(jq -r .tls_mode "$file" 2>/dev/null)
  [ "$tls_mode" = acme ] || return 0
  domain=$(state_get domain) || return 1
  [ -n "$domain" ] || return 1
  wait_for_certificate "$domain"
}

server_node_transaction(){
  local file=$1 content=$2 old_state
  old_state=$(state_snapshot) || return 2
  json_save "$file" "$content" || return 2
  if apply_config; then
    if ! server_node_wait_for_certificate "$file"; then
      server_node_rollback "$file" "$old_state" || return 4
      return 3
    fi
    return 0
  fi
  server_node_rollback "$file" "$old_state" || return 4
  return 1
}

save_node(){
  local file=$1 content=$2 status
  if server_node_transaction "$file" "$content"; then
    tell_ok "协议应用完成"; printf "\n"; render_share_uri "$file"
  else
    status=$?
    case $status in
      2) tell_warn "数据写入失败" ;;
      3) tell_warn "证书未成功签发，已回滚协议与域名状态" ;;
      4) tell_warn "配置失败且回滚未完成，请立即检查配置与服务状态" ;;
      1) tell_warn "配置应用失败，已回滚" ;;
    esac
  fi
  wait_key
}

ss_key_length(){
  case "$1" in
    2022-blake3-aes-128-gcm) echo 16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) echo 32 ;;
    *) echo 0 ;;
  esac
}

ss_validate_password(){
  local method=$1 password=$2 expected actual canonical tmp
  expected=$(ss_key_length "$method")
  [ "$expected" -gt 0 ] || { [ -n "$password" ]; return $?; }
  [[ "$password" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
  tmp=$(mktemp) || return 1
  if ! printf '%s' "$password" | base64 -d >"$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  actual=$(wc -c <"$tmp" | tr -d ' ')
  if [ "$actual" -ne "$expected" ]; then rm -f "$tmp"; return 1; fi
  canonical=$(base64 -w0 "$tmp" 2>/dev/null || base64 "$tmp" | tr -d '\n')
  rm -f "$tmp"
  [ "${canonical%=}" = "${password%=}" ]
}

validate_reality_key(){
  local key=$1 normalized provided actual tmp canonical
  [[ "$key" =~ ^[A-Za-z0-9_-]{43}$ || "$key" =~ ^[A-Za-z0-9+/]{43}=?$ ]] || return 1
  normalized=$(printf '%s' "$key" | tr '_-' '/+')
  while [ $(( ${#normalized} % 4 )) -ne 0 ]; do normalized+='='; done
  tmp=$(mktemp) || return 1
  if ! printf '%s' "$normalized" | base64 -d >"$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  actual=$(wc -c <"$tmp" | tr -d ' ')
  canonical=$(base64 -w0 "$tmp" 2>/dev/null || base64 "$tmp" | tr -d '\n')
  rm -f "$tmp"
  provided=$(printf '%s' "$key" | tr '/+' '_-' | tr -d '=')
  canonical=$(printf '%s' "$canonical" | tr '/+' '_-' | tr -d '=')
  [ "$actual" -eq 32 ] && [ "$canonical" = "$provided" ]
}

reality_keypair(){
  local output private public
  output=$("$CORE" generate reality-keypair 2>/dev/null) || return 1
  [ -n "$output" ] || return 1
  private=$(awk -F: '/^[[:space:]]*PrivateKey:/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' <<<"$output")
  public=$(awk -F: '/^[[:space:]]*PublicKey:/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' <<<"$output")
  validate_reality_key "$private" && validate_reality_key "$public" || return 1
  printf '%s|%s\n' "$private" "$public"
}

ss_generate_key(){
  local method=$1 len value
  len=$(ss_key_length "$method")
  if [ "$len" -gt 0 ]; then
    value=$(openssl rand -base64 "$len" 2>/dev/null) || return 1
    ss_validate_password "$method" "$value" || return 1
    printf '%s' "$value"
  else
    random_password
  fi
}

create_shadowsocks(){
  local method=${1:-2022-blake3-aes-256-gcm} name port password tag body generated
  ui_title "创建 Shadowsocks"
  name=$(prompt "节点名称" "Shadowsocks")
  port=$(prompt_port tu "")
  generated=$(ss_generate_key "$method") || { tell_warn "Shadowsocks 密钥自动生成失败"; wait_key; return; }
  while :; do
    password=$(prompt "密码/密钥 (留空自动生成)" "$generated")
    [ -n "$password" ] || { tell_warn "密码不能为空"; wait_key; return; }
    ss_validate_password "$method" "$password" && break
    tell_warn "Shadowsocks 2022 密钥必须是有效 Base64，且解码后长度必须符合所选算法"
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg method "$method" --arg password "$password" --argjson port "$port" '
    {tag:$tag,name:$name,kind:"shadowsocks",port:$port,proto:"tu",hopping:"",tls_mode:"none",alpn:null,
     meta:{method:$method,password:$password},
     inbound:{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:$method,password:$password,
       multiplex:{enabled:true}}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vless_transport(){
  local transport=$1 name port uuid tag body path service
  ui_title "创建 VLESS"
  name=$(prompt "节点名称" "VLESS-${transport^^}")
  setup_certificate || return
  port=$(prompt_port t "")
  while :; do
    uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
    [ -n "$uuid" ] || uuid=$(random_uuid)
    validate_uuid "$uuid" && break
    tell_warn "UUID 格式无效，请输入标准 UUID"
  done
  case "$transport" in
    ws) path=$(prompt "WebSocket Path" "/ws"); service="" ;;
    grpc) service=$(prompt "gRPC Service Name" "TunService"); path="" ;;
    *) return 1 ;;
  esac
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" \
        --arg transport "$transport" --arg path "$path" --arg service "$service" '
   {tag:$tag,name:$name,kind:("vless-"+$transport),port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,
    meta:{uuid:$uuid,transport:$transport,path:$path,service_name:$service},
    inbound:({type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid}],
      tls:{enabled:true},transport:{type:(if $transport=="ws" then "ws" else "grpc" end)}}
      | if $transport=="ws" then .transport.path=$path else .transport.service_name=$service end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_trojan_transport(){
  local transport=$1 name port password tag body path service
  ui_title "创建 Trojan"
  name=$(prompt "节点名称" "Trojan-${transport^^}")
  setup_certificate || return
  port=$(prompt_port t "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  case "$transport" in
    ws) path=$(prompt "WebSocket Path" "/ws"); service="" ;;
    grpc) service=$(prompt "gRPC Service Name" "TunService"); path="" ;;
    *) return 1 ;;
  esac
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" \
        --arg transport "$transport" --arg path "$path" --arg service "$service" '
   {tag:$tag,name:$name,kind:("trojan-"+$transport),port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,
    meta:{password:$password,transport:$transport,path:$path,service_name:$service},
    inbound:({type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}],tls:{enabled:true},
      transport:{type:(if $transport=="ws" then "ws" else "grpc" end)}}
      | if $transport=="ws" then .transport.path=$path else .transport.service_name=$service end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vmess(){
  local transport=${1:-tls} name port uuid tag body path service security
  ui_title "创建 VMess"
  name=$(prompt "节点名称" "VMess")
  setup_certificate || return
  port=$(prompt_port t "")
  while :; do
    uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
    [ -n "$uuid" ] || uuid=$(random_uuid)
    validate_uuid "$uuid" && break
    tell_warn "UUID 格式无效，请输入标准 UUID"
  done
  menu_item 1 "Auto"; menu_item 2 "AES-128-GCM"; menu_item 3 "ChaCha20-Poly1305"
  while :; do
    case $(prompt "加密方式" 1) in
      1) security=auto; break ;; 2) security=aes-128-gcm; break ;; 3) security=chacha20-poly1305; break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1
         ui_clear
         ui_title "创建 VMess"
         menu_item 1 "Auto"; menu_item 2 "AES-128-GCM"; menu_item 3 "ChaCha20-Poly1305" ;;
    esac
  done
  path=""; service=""
  case "$transport" in
    ws) path=$(prompt "WebSocket Path" "/ws") ;;
    grpc) service=$(prompt "gRPC Service Name" "TunService") ;;
    http) path=$(prompt "HTTP Path" "/") ;;
    tls) ;;
    *) return 1 ;;
  esac
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg security "$security" \
        --arg transport "$transport" --arg path "$path" --arg service "$service" '
   {tag:$tag,name:$name,kind:("vmess-"+$transport),port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,
    meta:{uuid:$uuid,security:$security,transport:$transport,path:$path,service_name:$service},
    inbound:({type:"vmess",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,alterId:0}],tls:{enabled:true},transport:{}}
      | if $transport=="ws" then .transport={type:"ws",path:$path}
        elif $transport=="grpc" then .transport={type:"grpc",service_name:$service}
        elif $transport=="http" then .transport={type:"http",path:$path}
        else del(.transport) end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vless_reality(){
  local name port uuid target keypair private public short_id tag body default_sid
  ui_title "创建协议"
  name=$(prompt "节点名称" "VLESS-Reality")
  port=$(prompt_port t "")
  while :; do
    uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
    [ -n "$uuid" ] || uuid=$(random_uuid)
    validate_uuid "$uuid" && break
    tell_warn "UUID 格式无效，请输入标准 UUID"
  done
  while :; do
    target=$(prompt "握手目标域名" "www.microsoft.com")
    probe_handshake_target "$target" && break
    prompt_yes "是否强制使用此域名" && break
  done
  keypair=$(reality_keypair) || { tell_warn "Reality 密钥对生成失败或格式无效"; wait_key; return; }
  private=${keypair%%|*}
  public=${keypair#*|}
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
  ui_title "创建协议"
  name=$(prompt "节点名称" "VLESS-TLS")
  setup_certificate || return
  port=$(prompt_port t "")
  while :; do
    uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
    [ -n "$uuid" ] || uuid=$(random_uuid)
    validate_uuid "$uuid" && break
    tell_warn "UUID 格式无效，请输入标准 UUID"
  done
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
  ui_title "创建协议"
  name=$(prompt "节点名称" "Hysteria2")
  setup_certificate || return
  port=$(prompt_port u "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  bbr_profile=""; up_mbps=0; down_mbps=0
  tell "拥塞控制:"
  tell "1. BBR conservative"
  tell "2. BBR standard"
  tell "3. BBR aggressive"
  tell "4. Brutal (需手动设置带宽)"
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
          [[ $up_mbps =~ ^[0-9]+$ ]] || { tell_warn "输入无效，请重新输入"; continue; }
          down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "0")
          [[ $down_mbps =~ ^[0-9]+$ ]] || { tell_warn "输入无效，请重新输入"; continue; }
          if [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ]; then break; fi
          tell_warn "Brutal 模式至少需要设置一个方向的带宽"
        done
        break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
  obfs_type=""; obfs_password=""; min_pkt=""; max_pkt=""
  if prompt_yes "是否配置协议混淆"; then
    menu_item 1 "Salamander"; menu_item 2 "Gecko"
    while :; do
      case $(prompt "请选择混淆算法" 2) in
        1) obfs_type="salamander"; break ;;
        2) obfs_type="gecko"; break ;;
        *) tell_warn "输入无效，请重新选择"; sleep 1
           ui_clear
           ui_title "创建协议"
           menu_item 1 "Salamander"; menu_item 2 "Gecko" ;;
      esac
    done
    obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$password")
    if [ "$obfs_type" = "gecko" ]; then
      while :; do
        min_pkt=$(prompt "最小包大小 (字节, 512-2048)" "512")
        [[ $min_pkt =~ ^[0-9]+$ ]] && [ "$min_pkt" -ge 512 ] && [ "$min_pkt" -le 2048 ] && break
        tell_warn "最小包大小必须为 512-2048"
      done
      while :; do
        max_pkt=$(prompt "最大包大小 (字节, 512-2048)" "1200")
        [[ $max_pkt =~ ^[0-9]+$ ]] && [ "$max_pkt" -ge 512 ] && [ "$max_pkt" -le 2048 ] && [ "$max_pkt" -ge "$min_pkt" ] && break
        tell_warn "最大包大小必须为 512-2048 且不小于最小包大小"
      done
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
  local name port uuid password tag body congestion
  ui_title "创建协议"
  name=$(prompt "节点名称" "TUIC")
  setup_certificate || return
  port=$(prompt_port u "")
  while :; do
    uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
    [ -n "$uuid" ] || uuid=$(random_uuid)
    validate_uuid "$uuid" && break
    tell_warn "UUID 格式无效，请输入标准 UUID"
  done
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  menu_item 1 "cubic"; menu_item 2 "New Reno"; menu_item 3 "bbr"
  while :; do
    case $(prompt "拥塞控制" 3) in
      1) congestion=cubic; break ;; 2) congestion=new_reno; break ;; 3) congestion=bbr; break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1
         ui_clear
         ui_title "创建协议"
         menu_item 1 "cubic"; menu_item 2 "New Reno"; menu_item 3 "bbr" ;;
    esac
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" \
        --arg uuid "$uuid" --arg password "$password" --arg congestion "$congestion" '
   {tag:$tag,name:$name,kind:"tuic",port:$port,proto:"u",hopping:"",
    tls_mode:"acme",alpn:["h3"],
    meta:{uuid:$uuid,password:$password,congestion_control:$congestion},
    inbound:{type:"tuic",tag:$tag,listen:"::",listen_port:$port,
      users:[{uuid:$uuid,password:$password}],congestion_control:$congestion}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_trojan(){
  local name port password tag body
  ui_title "创建协议"
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
  ui_title "创建协议"
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
  ui_title "创建协议"
  name=$(prompt "节点名称" "Socks5")
  port=$(prompt_port t "")
  username=$(prompt "鉴权账号" "admin")
  password=$(prompt "鉴权密码 (留空自动生成)" "$(random_password)")
  [ -n "$username" ] && [ -n "$password" ] || { tell_warn "必填项为空"; wait_key; return; }
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
  ui_title "创建协议"
  name=$(prompt "节点名称" "Snell")
  port=$(prompt_port t "")
  while :; do
    psk=$(prompt "预共享密钥 (PSK, 12-255 字节)" "$(random_password)")
    len=${#psk}
    if [ "$len" -ge 12 ] && [ "$len" -le 255 ]; then break; fi
    tell_warn "PSK 长度必须为 12-255 字节，当前 ${len} 字节"
  done
  menu_item 1 "Default"; menu_item 2 "Unshaped"; menu_item 3 "Unsafe Raw"
  while :; do
    case $(prompt "流量整形模式" 1) in
      1) mode="default"; break ;;
      2) mode="unshaped"; break ;;
      3) mode="unsafe-raw"; break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1
         ui_clear
         ui_title "创建协议"
         menu_item 1 "Default"; menu_item 2 "Unshaped"; menu_item 3 "Unsafe Raw" ;;
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

unique_tag(){
  local base tag index=1
  base=$(slugify "$1"); [ -n "$base" ] || base=node
  tag="$2$base"
  while [ -e "$3/$tag.json" ]; do tag="$2$base$index"; index=$((index+1)); done
  printf '%s' "$tag"
}

client_peer_tag(){ jq -r '.tag // ""' "$1" 2>/dev/null; }
client_peer_name(){ jq -r '.name // .tag // ""' "$1" 2>/dev/null; }
client_peer_server(){ jq -r '.outbound.server // ""' "$1" 2>/dev/null; }


peer_delete_transaction(){
  local file=$1 previous_exit was_exit=0 rc=0
  [ -f "$file" ] || return 2
  previous_exit=$(state_get exit) || previous_exit=direct
  [ "$(client_peer_tag "$file")" = "$previous_exit" ] && was_exit=1
  if [ "$was_exit" = 1 ]; then
    state_set exit direct || rc=1
    stop_watchdog || rc=1
  fi
  rm -f -- "$file" || return 2
  if ! apply_config restart; then
    systemctl stop sing-box >/dev/null 2>&1 || true
    stop_watchdog || true
    return 3
  fi
  sync_watchdog || rc=1
  [ "$rc" -eq 0 ] || return 4
  return 0
}

peer_select_transaction(){
  local file=$1 tag target_name previous previous_wg=0 restore_rc=0
  tag=$(client_peer_tag "$file") || return 1
  target_name=$(client_peer_name "$file") || return 1
  previous=$(state_get exit) || return 1
  if [ "$previous" = warp ]; then
    prompt_yes "当前 WARP 正在接管网络。
选择 ${target_name} 后，网络出口将切换至 ${target_name}，并停止 WARP。
是否切换" || return 1
  elif [ "$previous" = wireguard ] || { [ "$previous" = direct ] && wg_client_active; }; then
    prompt_yes "当前 WireGuard 正在接管网络。
选择 ${target_name} 后，网络出口将切换至 ${target_name}。
是否切换" || return 1
  fi
  if wg_client_active; then
    wg_set_enabled false || return 1
    previous_wg=1
  fi
  state_set exit "$tag" || {
    [ "$previous_wg" = 1 ] && wg_set_enabled true || true
    return 1
  }
  stop_watchdog || restore_rc=1
  if [ "$restore_rc" -eq 0 ] && apply_config; then
    if sync_watchdog; then
      [ "$previous" = warp ] && json_edit "$WARP_CONF" 'del(.started_at)' >/dev/null 2>&1 || true
      tell_ok "已接管: $target_name"
      return 0
    fi
  fi
  restore_rc=0
  state_set exit "$previous" || restore_rc=2
  if [ "$previous_wg" = 1 ]; then wg_set_enabled true || restore_rc=2; fi
  apply_config_quiet || restore_rc=2
  sync_watchdog || restore_rc=2
  [ "$restore_rc" -eq 0 ] && return 1
  tell_warn "节点切换失败，原出口恢复不完整，请检查 WireGuard/WARP 与服务状态"
  return 2
}

peer_stop_transaction(){
  local previous restore_rc=0
  previous=$(state_get exit) || return 1
  state_set exit direct || return 1
  stop_watchdog || {
    state_set exit "$previous" || true
    sync_watchdog || true
    return 1
  }
  if apply_config && sync_watchdog; then return 0; fi
  state_set exit "$previous" || restore_rc=2
  apply_config_quiet || restore_rc=2
  sync_watchdog || restore_rc=2
  [ "$restore_rc" -eq 0 ] && return 1
  return 2
}

peer_add(){
  local name uri tag outbound probe port ip resolved_hosts local_ipv4 local_ipv6
  ui_title "添加节点"
  name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return
  uri=$(prompt "节点链接"); [ -n "$uri" ] || return
  local uri_context
  uri_context=$(parse_uri "$uri") || { tell_warn "节点链接格式无效"; wait_key; return; }
  local uri_host uri_port
  uri_host=$(jq -r .host <<<"$uri_context")
  uri_port=$(jq -r .port <<<"$uri_context")
  resolved_hosts=$(resolve_addresses "$uri_host")
  local_ipv4=$(ip -4 -o addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')
  local_ipv6=$(ip -6 -o addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')
  if [ "$uri_host" = "127.0.0.1" ] || [ "$uri_host" = "localhost" ] || [ "$uri_host" = "::1" ]; then
    tell_warn "禁止自环接入"; wait_key; return
  fi
  for ip in $resolved_hosts; do
    if grep -Fqx "$ip" <<<"$local_ipv4" || grep -Fqx "$ip" <<<"$local_ipv6"; then tell_warn "禁止自环接入"; wait_key; return; fi
  done
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag" "$uri_context") || { tell_warn "无法解析"; wait_key; return; }
  probe=$(mktemp) || { tell_warn "无法创建临时文件"; wait_key; return; }
  if ! jq -n --argjson ob "$outbound" '{log:{level:"error"},outbounds:[$ob,{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$probe"; then
    tell_warn "探测配置生成失败"
  elif "$CORE" check -c "$probe" >/dev/null 2>&1; then
    if ! json_save "$PEER_DIR/$tag.json" "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" --arg hosts "$resolved_hosts" '{tag:$tag,name:$name,uri:$uri,outbound:$ob,probe_addresses:($hosts|split("\n")|map(select(length>0)))}')"; then
      tell_warn "节点保存失败"
    else
      tell_ok "节点挂载完成: $name"
    fi
  else
    tell_warn "校验拦截:"; "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2
  fi
  rm -f "$probe"; wait_key
}

probe_peer_latency(){
  local file=$1 result=$2 latency_file=${3:-} server type port
  server=$(client_peer_server "$file") || { echo fail >"$result"; return; }
  [ -n "$server" ] || { echo fail >"$result"; return; }
  type=$(jq -r '.outbound.type // ""' "$file" 2>/dev/null)
  port=$(jq -r '.outbound.server_port // empty' "$file" 2>/dev/null)
  probe_target_latency "$server" "$result" "$latency_file" "$type" "$port"
}
list_peers(){
  local current; current=$(state_get exit) || return 1
  local title=${1:-节点选择}
  local -a peer_files=() peer_tags=() peer_types=() peer_names=() peer_ports=()
  set -- "$PEER_DIR"/*.json
  [ ! -e "$1" ] && { ui_title "$title"; tell "暂无外部节点"; return 0; }
  peer_files=("$@")
  local tmp_dir; tmp_dir=$(mktemp -d) || { tell_warn "无法创建临时目录"; return 1; }
  local idx=0 raw_data test_pids="" file tag type name port
  if ! raw_data=$(jq -c '"\(input_filename)" as $f | {file:$f,tag:(.tag//"-"),type:(.outbound.type//"-"),name:(.name//"-"),port:(.outbound.server_port // (if .outbound.server_ports then (.outbound.server_ports[0]|gsub(":";"-")) else null end) // .outbound.listen_port // "-")}' "${peer_files[@]}" 2>/dev/null); then
    rm -rf "$tmp_dir"; tell_warn "节点数据读取失败"; return 1
  fi
  if [ -n "$raw_data" ]; then
    while IFS= read -r row; do
      file=$(jq -r '.file' <<<"$row"); tag=$(jq -r '.tag' <<<"$row"); type=$(jq -r '.type' <<<"$row"); name=$(jq -r '.name' <<<"$row"); port=$(jq -r '.port' <<<"$row")
      idx=$((idx+1)); peer_files[$((idx-1))]="$file"; peer_tags[$((idx-1))]="$tag"; peer_types[$((idx-1))]="$type"; peer_names[$((idx-1))]="$name"; peer_ports[$((idx-1))]="$port"
      ( probe_peer_latency "$file" "$tmp_dir/res_$idx" "$tmp_dir/lat_$idx" ) &
      test_pids="$test_pids $!"
    done <<<"$raw_data"
  fi
  [ -n "$test_pids" ] && wait $test_pids 2>/dev/null || true
  ui_title "$title"
  printf '\n'
  for i in $(seq 1 $idx); do
    local type="${peer_types[$((i-1))]}" name="${peer_names[$((i-1))]}" port="${peer_ports[$((i-1))]}"
    local display_type name_display ms color status_text current_text=""
    case "$type" in
      vless) display_type="VLESS" ;; trojan) display_type="Trojan" ;; hysteria2) display_type="Hysteria2" ;;
      tuic) display_type="TUIC" ;; shadowsocks) display_type="Shadowsocks" ;; vmess) display_type="VMess" ;;
      anytls) display_type="AnyTLS" ;; socks) display_type="SOCKS5" ;; snell) display_type="Snell" ;; *) display_type="$type" ;;
    esac
    name_display=$(LC_ALL=C.UTF-8 printf '%s' "$name" | cut -c1-20)
    [ "$name_display" != "$name" ] && name_display="${name_display}…"
    ms=$(cat "$tmp_dir/lat_$i" 2>/dev/null)
    local probe_result
    probe_result=$(cat "$tmp_dir/res_$i" 2>/dev/null)
    if { [ "$probe_result" = tcp ] || [ "$probe_result" = icmp ]; } && [[ "$ms" =~ ^[0-9]+$ ]]; then
      if [ "$ms" -le 100 ]; then color="$GREEN"
      elif [ "$ms" -le 150 ]; then color="$YELLOW"
      elif [ "$ms" -le 300 ]; then color="$BROWN"
      else color="$RED"; fi
      [ "$probe_result" = icmp ] && status_text="ICMP ${ms}ms" || status_text="TCP ${ms}ms"
    elif [ "$probe_result" = unknown ]; then
      color="$YELLOW"; status_text="未验证"
    else
      color="$RED"; status_text="超时"
    fi
    [ "$title" != "删除节点" ] && [ "${peer_tags[$((i-1))]}" = "$current" ] && current_text="<=当前"
    printf '%b%d.%b %b%s-%s-%s-%b%s%b%b\n' "$BOLD$CYAN" "$i" "$PLAIN" "$BOLD$WHITE" "$display_type" "$name_display" "$port" "$BOLD$color" "$status_text" "$PLAIN" "$([ -n "$current_text" ] && printf '%s' "$current_text" || true)"
  done
  rm -rf "$tmp_dir"
  return 0
}
select_peer(){
  local title=${1:-节点选择} index target=$2
  [ -n "$target" ] || return 2
  local -a peer_files=()
  while :; do
    set -- "$PEER_DIR"/*.json
    [ ! -e "$1" ] && { ui_title "$title"; tell "暂无外部节点"; wait_key; return 1; }
    peer_files=("$@")
    list_peers "$title" || return 1
    [ "${#peer_files[@]}" = 0 ] && { wait_key; return 1; }
    menu_item 0 "返回"
    printf '\n'
    index=$(prompt "请选择")
    [ -z "$index" ] && continue
    [ "$index" = 0 ] && return 1
    if [[ $index =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "${#peer_files[@]}" ]; then
      printf -v "$target" '%s' "${peer_files[$((index-1))]}"
      return 0
    else tell_warn "输入无效，请重新选择"; sleep 1; fi
  done
}

peer_select(){
  local file
  select_peer "接管/选择节点" file || return
  if peer_select_transaction "$file"; then
    :
  else
    local status=$?
    if [ "$status" -eq 2 ]; then tell_warn "节点切换失败，原出口恢复不完整，请检查服务状态"; else tell_warn "节点切换失败，已恢复原出口"; fi
  fi
  wait_key
}

peer_delete(){
  while :; do
    local file
    select_peer "删除节点" file || return
    if peer_delete_transaction "$file"; then
      tell_ok "节点删除完成"
    else
      status=$?
      case $status in
        2) tell_warn "删除操作未完成，请检查文件权限或出口状态" ;;
        3) tell_warn "节点已删除，但 sing-box 配置应用失败，服务已停止" ;;
        4) tell_warn "节点已删除且配置已应用，但出口状态或 watchdog 同步失败，请检查状态与健康检测服务" ;;
      esac
      wait_key
    fi
  done
}

peer_stop(){
  ui_clear
  if peer_stop_transaction; then
    if wg_client_active; then tell_ok "代理已停止，当前出口为 WireGuard 专线"; else tell_ok "直连恢复完成"; fi
  else
    tell_warn "停止代理失败，原出口已恢复或需要检查状态"
  fi
  wait_key
}

exit_label(){
  local selected; selected=$(state_get exit) || { echo "状态异常"; return 1; }
  case $selected in
    direct) if wg_client_active; then echo "WireGuard 专线"; else echo "直连"; fi ;;
    wireguard) echo "WireGuard 专线" ;;
    warp) echo "WARP" ;;
    *) [ -f "$PEER_DIR/$selected.json" ] && jq -r .name "$PEER_DIR/$selected.json" || echo "$selected" ;;
  esac
}

get_ip_info(){
  local mode=$1 res ip country asn name
  case "$mode" in 4|6) ;; *) return 2 ;; esac
  res=$(curl -sS -"$mode" -m 5 https://ipwho.is/ 2>/dev/null) || return 1
  ip=$(jq -r '.ip // empty' <<<"$res" 2>/dev/null)
  [ -n "$ip" ] || return 1
  country=$(jq -r '.country // empty' <<<"$res" 2>/dev/null)
  asn=$(jq -r '.connection.asn // empty' <<<"$res" 2>/dev/null)
  [ -n "$asn" ] && asn="AS$asn"
  name=$(jq -r '.connection.org // empty' <<<"$res" 2>/dev/null)
  printf '%s\t%s\t%s\t%s\n' "$ip" "$country" "$asn" "$name"
}

render_client_ip_status(){
  local info ip country asn name
  info=$(get_ip_info 4)
  if [ -n "$info" ]; then
    IFS=$'\t' read -r ip country asn name <<<"$info"
    tell "IPv4: ${GREEN}${ip}${PLAIN} | 地区: ${YELLOW}${country}${PLAIN}"
    tell "所属: ${CYAN}${name}${PLAIN} | ASN: ${PURPLE}${asn}${PLAIN}"
  else tell "IPv4: ${RED}无或不可用${PLAIN}"; fi
  info=$(get_ip_info 6)
  if [ -n "$info" ]; then
    IFS=$'\t' read -r ip country asn name <<<"$info"
    tell "IPv6: ${GREEN}${ip}${PLAIN} | 地区: ${YELLOW}${country}${PLAIN}"
    tell "所属: ${CYAN}${name}${PLAIN} | ASN: ${PURPLE}${asn}${PLAIN}"
  else tell "IPv6: ${RED}无或不可用${PLAIN}"; fi
}

menu_client_status(){
  ui_title "客户端状态"
  local exit_node; exit_node=$(state_get exit) || { tell_warn "出口状态读取失败"; return 1; }
  local proxy_name="直连" protocol=""
  if [ "$exit_node" = "direct" ] && wg_client_active; then
    proxy_name="WireGuard"
  elif [ "$exit_node" = "wireguard" ]; then
    proxy_name="WireGuard"
  elif [ "$exit_node" = "warp" ]; then
    proxy_name="WARP"
  elif [ "$exit_node" != "direct" ] && [ -f "$PEER_DIR/$exit_node.json" ]; then
    proxy_name=$(client_peer_name "$PEER_DIR/$exit_node.json")
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
  tell "网络接管：${YELLOW}${proxy_name}${PLAIN}"; tell ""
  render_client_ip_status; wait_key
}

menu_client(){
  while :; do
    ui_title "客户端管理"
    tell "当前出口：${YELLOW}$(exit_label)${PLAIN}"; tell ""
    menu_item 1 "添加节点"; menu_item 2 "节点选择"; menu_item 3 "删除节点"; menu_item 4 "停止代理"; menu_item 5 "客户端状态"; menu_item 0 "返回"
        case $(prompt "请选择") in
      1) peer_add ;; 2) peer_select ;; 3) peer_delete ;; 4) peer_stop ;; 5) menu_client_status ;;
      0) break ;; *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

bootstrap(){
  init_dirs || exit 1
  clear_legacy_bypass_rules || exit 1
  check_dependencies || exit 1
  chmod 700 "$SELF" 2>/dev/null
  ln -sf "$SELF" "$SHORTCUT" 2>/dev/null
  local had_net_cache=0
  [ -f "$NET_CACHE" ] && had_net_cache=1
  load_net_cache
  [ "$had_net_cache" = 1 ] && probe_network_stack_async
  if [ ! -x "$CORE" ] || ! core_version_at_least 1.14.0; then
    install_core || exit 1
    core_version_at_least 1.14.0 || { tell_warn "sing-box 核心准备失败，无法启动"; exit 1; }
  fi
  if [ ! -f "$SERVICE_UNIT" ]; then
    write_service || exit 1
  fi
  if [ ! -f "$DROPIN" ]; then
    write_dropin || exit 1
    systemctl daemon-reload || exit 1
  fi
  systemctl enable sing-box >/dev/null 2>&1 || exit 1
  if [ ! -f "$CONFIG" ]; then
    _bootstrap_conf=$(mktemp) || exit 1
    if ! build_config >"$_bootstrap_conf" 2>/dev/null || [ ! -s "$_bootstrap_conf" ] || ! json_write "$CONFIG" <"$_bootstrap_conf"; then
      rm -f "$_bootstrap_conf"
      exit 1
    fi
    rm -f "$_bootstrap_conf"
  fi
  if ! "$CORE" check -c "$CONFIG" >/dev/null 2>&1; then
    tell_warn "sing-box 配置检查失败，未启动服务"
    return 1
  fi
  systemctl enable --now sing-box >/dev/null 2>&1 || exit 1
  sync_hopping_rules || return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case $1 in
      --sync) init_dirs || exit 1; clear_legacy_bypass_rules || exit 1; sync_hopping_rules || exit 1; exit 0 ;;
    --clear-hopping) clear_hopping_rules; exit 0 ;;
    --reapply)
      exec 9>"$REAPPLY_LOCK"
      flock -w 5 9 || exit 0
      init_dirs || { flock -u 9; exit 1; }
      load_net_cache || { flock -u 9; exit 1; }
      prev_if4=$NET_IF_V4; prev_if6=$NET_IF_V6
      NET_IF_V4=$(default_iface 4)
      NET_IF_V6=$(default_iface 6)
      if [ "$NET_IF_V4" != "$prev_if4" ] || [ "$NET_IF_V6" != "$prev_if6" ]; then
        probe_network_stack || { flock -u 9; exit 1; }
        network_cache_write || { flock -u 9; exit 1; }
      fi
      exec 8>"$CONFIG_LOCK" || { flock -u 9; exit 1; }
      flock -w 30 8 || { flock -u 9; exit 1; }
      _new_conf=$(mktemp) || { flock -u 9; exit 1; }
      build_config > "$_new_conf" 2>/dev/null || { rm -f "$_new_conf"; flock -u 9; exit 1; }
      [ -s "$_new_conf" ] || { rm -f "$_new_conf"; flock -u 9; exit 1; }
      if ! "$CORE" check -c "$_new_conf" >/dev/null 2>&1; then
        rm -f "$_new_conf"; flock -u 9; exit 1
      fi
      if cmp -s "$_new_conf" "$CONFIG"; then
        rm -f "$_new_conf"; flock -u 9; exit 0
      fi
      _prev_conf=""
      if [ -f "$CONFIG" ]; then
        _prev_conf=$(mktemp) || { rm -f "$_new_conf"; flock -u 9; exit 1; }
        cp "$CONFIG" "$_prev_conf" || { rm -f "$_new_conf" "$_prev_conf"; flock -u 9; exit 1; }
      fi
      install -m600 "$_new_conf" "$CONFIG" || { rm -f "$_new_conf" "$_prev_conf"; flock -u 9; exit 1; }
      if ! timeout 15 systemctl reload-or-restart sing-box >/dev/null 2>&1; then
        if ! restore_config "$_prev_conf"; then
          rm -f "$_new_conf" "$_prev_conf"; flock -u 9; exit 2
        fi
        rm -f "$_new_conf" "$_prev_conf"; flock -u 9; exit 1
      fi
      if ! systemctl is-active --quiet sing-box; then
        if ! restore_config "$_prev_conf"; then
          rm -f "$_new_conf" "$_prev_conf"; flock -u 9; exit 2
        fi
        rm -f "$_new_conf" "$_prev_conf"; flock -u 9; exit 1
      fi
      rm -f "$_new_conf"
      if ! sync_hopping_rules; then
        restore_config "$_prev_conf" || { rm -f "$_prev_conf"; flock -u 9; exit 2; }
        rm -f "$_prev_conf"
        sync_hopping_rules || { flock -u 9; exit 2; }
        flock -u 9; exit 1
      fi
      rm -f "$_prev_conf"
      flock -u 9
      exit 0 ;;
    --watchdog) run_watchdog; exit 0 ;;
  esac

  exec 7>"$MANAGER_LOCK" || exit 1
  flock -n 7 || { tell_warn "管理器已在其他窗口运行，请勿同时操作"; exit 1; }
  bootstrap || exit $?

  while :; do
    ui_title "s 管理器"
        menu_item 1 "服务端管理"
    menu_item 2 "客户端管理"
    menu_item 3 "WireGuard 管理"
    menu_item 4 "WARP 管理"
    menu_item 5 "状态与更新"
    menu_item 0 "退出"
        case $(prompt "请选择") in
      1) menu_server ;;
      2) menu_client ;;
      3) menu_wireguard ;;
      4) menu_warp ;;
      5) menu_status ;;
      0) ui_clear; exit 0 ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
fi
