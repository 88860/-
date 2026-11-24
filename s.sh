#!/usr/bin/env bash
export LC_ALL=C
shopt -s nullglob
CERT_BG_PID=""
CERT_PENDING_NODE=""
CERT_PENDING_APPLIED=0
APPLY_CONFIG_INSTALLED=0
WARP_ROLLBACK_ACTIVE=0
WARP_ROLLBACK_APPLIED=0
WARP_ROLLBACK_PREV=""
WARP_ROLLBACK_WG=0
WARP_ROLLBACK_STARTED=""
WARP_ROLLBACK_TF=""
INSTALL_TMP_DIR=""
CERT_PRE_STATE=""
WG_BACKUP_DIR=""
WARP_PRE_REG_BAK=""
RELEASE_JSON_CACHE=""
SERVICE_UNIT_CHANGED=0
PEER_LIST_CACHE=""
PEER_FILES_CACHE=()
CLEANUP_PATHS=()
CLEANUP_PIDS=()

register_cleanup(){ [ -n "$1" ] && CLEANUP_PATHS+=("$1"); }
unregister_cleanup(){
  local target=$1 item
  local -a next=()
  for item in "${CLEANUP_PATHS[@]}"; do
    [ "$item" = "$target" ] || next+=("$item")
  done
  CLEANUP_PATHS=("${next[@]}")
}
cleanup_release(){
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    rm -rf -- "$p" 2>/dev/null || true
    unregister_cleanup "$p"
  done
}
register_pid(){ [ -n "$1" ] && CLEANUP_PIDS+=("$1"); }
unregister_pid(){
  local target=$1 item
  local -a next=()
  for item in "${CLEANUP_PIDS[@]}"; do
    [ "$item" = "$target" ] || next+=("$item")
  done
  CLEANUP_PIDS=("${next[@]}")
}
kill_tree(){
  local pid=$1 child
  local -a children=()
  [ -n "$pid" ] || return 0
  mapfile -t children < <(pgrep -P "$pid" 2>/dev/null)
  kill -TERM "$pid" 2>/dev/null || true
  for child in "${children[@]}"; do
    [ -n "$child" ] && kill_tree "$child"
  done
}
stop_pid_graceful(){
  local pid=$1 guard=0 stat
  [ -n "$pid" ] || return 0
  kill_tree "$pid"
  while [ "$guard" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || break
    stat=$(ps -o stat= -p "$pid" 2>/dev/null)
    [ -z "$stat" ] || [[ "$stat" == Z* ]] && break
    sleep 0.1; guard=$((guard+1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    stat=$(ps -o stat= -p "$pid" 2>/dev/null)
    [ -n "$stat" ] && [[ "$stat" != Z* ]] && kill -9 "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}
cleanup_on_exit(){
  local p pid guard=0 alive stat
  if [ -n "$CERT_BG_PID" ]; then
    stop_pid_graceful "$CERT_BG_PID"
    CERT_BG_PID=""
  fi
  if [ "${#CLEANUP_PIDS[@]}" -gt 0 ]; then
    for pid in "${CLEANUP_PIDS[@]}"; do kill_tree "$pid"; done
    while [ "$guard" -lt 20 ]; do
      alive=0
      for pid in "${CLEANUP_PIDS[@]}"; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
        stat=$(ps -o stat= -p "$pid" 2>/dev/null)
        if [ -n "$stat" ] && [[ "$stat" != Z* ]]; then alive=1; break; fi
      done
      [ "$alive" = 0 ] && break
      sleep 0.1; guard=$((guard+1))
    done
    for pid in "${CLEANUP_PIDS[@]}"; do
      [ -n "$pid" ] || continue
      stat=$(ps -o stat= -p "$pid" 2>/dev/null)
      if [ -z "$stat" ] || [[ "$stat" == Z* ]]; then wait "$pid" 2>/dev/null || true; fi
    done
    CLEANUP_PIDS=()
  fi
  if [ "$WARP_ROLLBACK_ACTIVE" = 1 ]; then
    local wb_prev=$WARP_ROLLBACK_PREV wb_wg=$WARP_ROLLBACK_WG wb_started=$WARP_ROLLBACK_STARTED wb_tf=$WARP_ROLLBACK_TF wb_applied=$WARP_ROLLBACK_APPLIED installed=$APPLY_CONFIG_INSTALLED had_bak=0
    WARP_ROLLBACK_ACTIVE=0; WARP_ROLLBACK_APPLIED=0; APPLY_CONFIG_INSTALLED=0
    WARP_ROLLBACK_PREV=""; WARP_ROLLBACK_WG=0; WARP_ROLLBACK_STARTED=""; WARP_ROLLBACK_TF=""
    if [ -n "$WARP_PRE_REG_BAK" ] && [ -f "$WARP_PRE_REG_BAK" ]; then
      cp -p "$WARP_PRE_REG_BAK" "$WARP_CONF" 2>/dev/null || true
      rm -f -- "$WARP_PRE_REG_BAK" 2>/dev/null || true
      WARP_PRE_REG_BAK=""
      had_bak=1
    fi
    if [ "$had_bak" = 0 ] && [ -f "$WARP_CONF" ]; then
      if [ -n "$wb_tf" ]; then json_edit "$WARP_CONF" '.tunnel_family=$tf' --arg tf "$wb_tf" 2>/dev/null || true; else json_edit "$WARP_CONF" 'del(.tunnel_family)' 2>/dev/null || true; fi
      if [ -n "$wb_started" ]; then json_edit "$WARP_CONF" '.started_at=$s' --arg s "$wb_started" 2>/dev/null || true; else json_edit "$WARP_CONF" 'del(.started_at)' 2>/dev/null || true; fi
    fi
    [ -n "$wb_prev" ] && { state_set exit "$wb_prev" 2>/dev/null || true; }
    [ "$wb_wg" = 1 ] && { wg_set_enabled true 2>/dev/null || true; }
    if [ "$wb_applied" = 1 ] || [ "$installed" = 1 ]; then
      exec 8>&- 2>/dev/null || true
      apply_config_quiet || true
    fi
  fi
  if [ -n "$CERT_PENDING_NODE" ]; then
    local pending_node=$CERT_PENDING_NODE pending_applied=$CERT_PENDING_APPLIED pending_state=$CERT_PRE_STATE installed=$APPLY_CONFIG_INSTALLED
    CERT_PENDING_NODE=""; CERT_PENDING_APPLIED=0; CERT_PRE_STATE=""; APPLY_CONFIG_INSTALLED=0
    rm -f -- "$pending_node" 2>/dev/null || true
    [ -n "$pending_state" ] && { state_restore "$pending_state" 2>/dev/null || true; }
    if [ "$pending_applied" = 1 ] || [ "$installed" = 1 ]; then
      exec 8>&- 2>/dev/null || true
      apply_config_quiet || true
    fi
  elif [ -n "$CERT_PRE_STATE" ]; then
    local pending_state=$CERT_PRE_STATE
    CERT_PRE_STATE=""
    state_restore "$pending_state" 2>/dev/null || true
  fi
  for p in "${CLEANUP_PATHS[@]}"; do
    [ -n "$p" ] && [ -e "$p" ] && rm -rf -- "$p" 2>/dev/null || true
  done
  CLEANUP_PATHS=()
  if [ -n "$INSTALL_TMP_DIR" ] && [ -d "$INSTALL_TMP_DIR" ]; then rm -rf -- "$INSTALL_TMP_DIR"; fi
  INSTALL_TMP_DIR=""
  if [ -n "$WG_BACKUP_DIR" ] && [ -d "$WG_BACKUP_DIR" ]; then rm -rf -- "$WG_BACKUP_DIR"; fi
  WG_BACKUP_DIR=""
  if [ -n "$WARP_PRE_REG_BAK" ] && [ -f "$WARP_PRE_REG_BAK" ]; then
    cp -p "$WARP_PRE_REG_BAK" "$WARP_CONF" 2>/dev/null || true
    rm -f -- "$WARP_PRE_REG_BAK" 2>/dev/null || true
  fi
  WARP_PRE_REG_BAK=""
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

RED='\033[1;91m'
GREEN='\033[1;92m'
CYAN='\033[1;96m'
YELLOW='\033[1;93m'
PURPLE='\033[1;95m'
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
CONFIG_LOCK=$SBM_DIR/config.lock
SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SHORTCUT=/usr/local/bin/s
CORE=/usr/local/bin/sing-box
SERVICE_UNIT=/etc/systemd/system/sing-box.service
DROPIN_DIR=/etc/systemd/system/sing-box.service.d
DROPIN=$DROPIN_DIR/sbm.conf
GH_API=https://api.github.com/repos/SagerNet/sing-box
TUN_IF=sbmtun
WG_IF=sbmwg
WARP_DIR=$SBM_DIR/warp
WARP_CONF=$WARP_DIR/config.json
WARP_IF=warp
WARP_API=https://api.cloudflareclient.com/v0a2158/reg
WARP_TRACE=https://www.cloudflare.com/cdn-cgi/trace
CERT_TAG=acme-cert
HOP_TABLE=sbm_hop
has_tty(){ (: </dev/tty) 2>/dev/null; }
is_pos_int(){ [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_uint(){ [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }
sanitize_domain(){
  local d=$1
  d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
  d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d%%:*}
  printf '%s' "$d"
}
read_line(){
  local value
  if has_tty; then
    IFS= read -r value </dev/tty || return 1
  else
    IFS= read -r value || return 1
  fi
  value="${value%$'\r'}"
  printf '%s' "$value"
}

prompt(){
  local msg="$1" def="$2" value out=/dev/stderr
  has_tty && out=/dev/tty
  if [[ "$msg" == 请选择* ]]; then
    printf "\n${DIM}${CYAN}....................${PLAIN}\n" >"$out"
  fi
  if [ -n "$def" ]; then
    printf "${BOLD}${YELLOW}. %s [%s]: ${PLAIN}" "$msg" "$def" >"$out"
  else
    printf "${BOLD}${YELLOW}. %s: ${PLAIN}" "$msg" >"$out"
  fi
  value=$(read_line) || { tell_warn "输入被中断" >&2; kill -TERM "$$" 2>/dev/null; exit 1; }
  printf '%s\n' "${value:-$def}"
}

prompt_yes(){
  local value def=${2:-n} hint="(y/N)"
  case "$def" in y|Y|yes|YES) hint="(Y/n)" ;; esac
  value=$(prompt "$1 $hint" "$def")
  case "$value" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
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
uri_decode(){
  local s=$1 out="" ch hex
  while [[ "$s" == *%* ]]; do
    out+="${s%%[%]*}"
    s="${s#*[%]}"; hex="${s:0:2}"
    if [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]]; then
      printf -v ch '%b' "\\x$hex"
      out+="$ch"
      s="${s:2}"
    else
      out+="%"
    fi
  done
  printf '%s%s' "$out" "$s"
}

trim_host(){
  local h=$1
  h="${h#"${h%%[![:space:]]*}"}"; h="${h%"${h##*[![:space:]]}"}"
  h=${h#\[}; h=${h%\]}
  printf '%s' "$h"
}
slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }
random_password(){ openssl rand -hex 8; }
random_uuid(){ cat /proc/sys/kernel/random/uuid; }
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
    "ss:iproute2" "ip:iproute2" "flock:util-linux" "sysctl:procps" "pgrep:procps"
    "grep:grep" "sed:sed" "find:findutils" "shuf:coreutils" "timeout:coreutils"
    "install:coreutils" "mkdir:coreutils" "chmod:coreutils" "cat:coreutils" "tr:coreutils"
    "cut:coreutils" "head:coreutils" "tail:coreutils" "sort:coreutils" "date:coreutils"
    "sleep:coreutils" "seq:coreutils" "mv:coreutils" "rm:coreutils" "cp:coreutils" "id:coreutils"
    "uname:coreutils" "mktemp:coreutils" "ln:coreutils" "rmdir:coreutils"
    "systemctl:systemd" "journalctl:systemd" "ping:iputils-ping" "fuser:psmisc" "cmp:diffutils" "awk:gawk"
  )
  local missing=0
  for item in "${deps[@]}"; do
    cmd=${item%%:*}
    if ! command -v "$cmd" >/dev/null 2>&1; then missing=1; break; fi
  done
  if [ "$missing" = 1 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || {
      echo -e "${RED}[✗] apt 软件源更新失败${PLAIN}"; exit 1
    }
  fi
  for item in "${deps[@]}"; do
    cmd=${item%%:*}; pkg=${item#*:}
    ensure_command "$cmd" "$pkg" || {
      echo -e "${RED}[✗] 依赖组件 $cmd 安装失败${PLAIN}"; exit 1
    }
  done
  return 0
}

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}[✗] 权限不足: 请使用 root 用户运行${PLAIN}"; exit 1; }

menu_create_protocol(){
  while :; do
    ui_title "创建协议"
    menu_item 1 "VLESS"; menu_item 2 "Trojan"; menu_item 3 "Hysteria2"; menu_item 4 "TUIC"
    menu_item 5 "Shadowsocks"; menu_item 6 "VMess"; menu_item 7 "AnyTLS"; menu_item 8 "SOCKS5"; menu_item 9 "Snell"
    menu_item 0 "返回";     case $(prompt "请选择") in
      1) menu_create_vless ;; 2) menu_create_trojan ;; 3) create_hysteria2 ;;
      4) create_tuic ;; 5) menu_create_shadowsocks ;; 6) menu_create_vmess ;;
      7) create_anytls ;; 8) create_socks ;; 9) create_snell ;; 0) return ;;
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
    menu_item 3 "2022 · ChaCha20-Poly1305"; menu_item 4 "AES-128-GCM"; menu_item 5 "AES-256-GCM"
    menu_item 6 "ChaCha20-IETF-Poly1305"; menu_item 7 "XChaCha20-IETF-Poly1305"; menu_item 0 "返回"
        case $(prompt "请选择") in
      1) create_shadowsocks 2022-blake3-aes-128-gcm; return ;;
      2) create_shadowsocks 2022-blake3-aes-256-gcm; return ;;
      3) create_shadowsocks 2022-blake3-chacha20-poly1305; return ;;
      4) create_shadowsocks aes-128-gcm; return ;; 5) create_shadowsocks aes-256-gcm; return ;;
      6) create_shadowsocks chacha20-ietf-poly1305; return ;; 7) create_shadowsocks xchacha20-ietf-poly1305; return ;;
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
  while :; do
    local file was_acme status deleted=0
    select_node file "删除协议" || return
    local del_name; del_name=$(server_node_name "$file"); [ -n "$del_name" ] || del_name=$(basename "$file"); prompt_yes "确认删除 $del_name" || continue
    was_acme=$(server_node_tls_mode "$file") || was_acme=""
    if server_delete_node "$file"; then
      deleted=1
      tell_ok "已删除"
    else
      status=$?
      case $status in
        2) tell_warn "协议文件删除失败" ;;
        4) deleted=1; tell_warn "协议已删除，但 sing-box 配置应用失败，请检查服务状态" ;;
        *) tell_warn "协议删除失败，请检查状态文件和权限" ;;
      esac
    fi
    if [ "$deleted" = 1 ] && [ "$was_acme" = "acme" ]; then
      local acme_count
      acme_count=$(server_acme_node_count)
      if [ "$acme_count" -eq 0 ] && [ -n "$(state_get domain)" ]; then
        printf "\n"
        if prompt_yes "是否连同域名和证书一起清理"; then
          state_set domain "" || true
          state_set email "" || true
          state_set challenge "http" || true
          state_set cf_token "" || true
          state_set ali_key "" || true
          state_set ali_secret "" || true
          state_set acmedns_url "" || true
          state_set acmedns_user "" || true
          state_set acmedns_pass "" || true
          state_set acmedns_sub "" || true
          find "$ACME_DIR" -mindepth 1 -delete 2>/dev/null
          tell_ok "相关配置已清理"
        fi
      fi
    fi
    wait_key
    set -- "$NODE_DIR"/*.json
    [ ! -e "$1" ] && break
  done
}

render_certificate_status(){
  local domain crt="" fallback_crt="" expiry days file
  domain=$(state_get domain) || return 1; [ -n "$domain" ] || return 0
  tell ""; tell "全局域名: $domain | 验证: $(state_get challenge)"
  while IFS= read -r file; do
    if openssl x509 -in "$file" -noout -checkhost "$domain" >/dev/null 2>&1; then
      [ -z "$fallback_crt" ] && fallback_crt="$file"
      if openssl x509 -in "$file" -noout -checkend 0 >/dev/null 2>&1; then
        crt="$file"; break
      fi
    fi
  done < <(find "$ACME_DIR" -type f -name '*.crt' 2>/dev/null)
  [ -n "$crt" ] || crt="$fallback_crt"
  [ -n "$crt" ] || { tell "${YELLOW}证书状态: 未找到匹配域名的证书${PLAIN}"; return 0; }
  expiry=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
  [ -n "$expiry" ] || { tell "${RED}证书状态: 无法读取${PLAIN}"; return 0; }
  days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  tell "到期时间: $expiry | 剩余: ${days} 天"
  systemctl is-active --quiet sing-box || tell_warn "服务离线，无法自动续期"
}

menu_server_info(){
  local file port proto status count=0 tcp_list udp_list exit_txt
  reload_net_cache
  tcp_list=$(listening_ports t); udp_list=$(listening_ports u)
  exit_txt=$(exit_label)
  ui_title "服务端信息"
  if systemctl is-active --quiet sing-box; then
    tell_ok "sing-box: 运行中 | 当前出口: ${YELLOW}${exit_txt}${PLAIN}"
  else
    tell_warn "sing-box: 未运行 | 当前出口: ${YELLOW}${exit_txt}${PLAIN}"
  fi
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    count=$((count+1)); port=$(jq -r '.port // ""' "$file" 2>/dev/null) || { tell_warn "节点配置读取失败: $file"; continue; }; proto=$(jq -r '.proto // ""' "$file" 2>/dev/null) || { tell_warn "节点配置读取失败: $file"; continue; }
    if [ "$(server_node_kind "$file")" = shadowsocks ]; then
      { grep -qx "$port" <<<"$tcp_list" || grep -qx "$port" <<<"$udp_list"; } && status="${GREEN}正常监听${PLAIN}" || status="${RED}未在监听${PLAIN}"
    elif [ "$proto" = u ]; then
      grep -qx "$port" <<<"$udp_list" && status="${GREEN}正常监听${PLAIN}" || status="${RED}未在监听${PLAIN}"
    else
      grep -qx "$port" <<<"$tcp_list" && status="${GREEN}正常监听${PLAIN}" || status="${RED}未在监听${PLAIN}"
    fi
    tell ""; tell "$(server_node_name "$file") [$(server_node_kind "$file")] | 端口 $port $status"
    render_share_uri "$file"
  done
  [ "$count" = 0 ] && tell "\n暂无节点"
  render_certificate_status; wait_key
}

menu_change_domain(){
  local new_domain old_domain old_state file count=0 email mode had_new_assets=0 status v1 v2 v3 v4 reset_challenge=0
  ui_title "更换域名"
  old_domain=$(state_get domain || true)
  tell "当前域名: ${old_domain:-无}"; tell "绑定节点:"
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    if [ "$(server_node_tls_mode "$file")" = acme ]; then tell "- $(server_node_name "$file") [$(server_node_kind "$file")]"; count=$((count+1)); fi
  done
  [ "$count" = 0 ] && { tell "当前没有绑定域名的协议节点，请先创建需要证书的协议"; wait_key; return; }
  echo ""
  new_domain=$(sanitize_domain "$(prompt '新域名 (留空取消)')"); [ -z "$new_domain" ] && return
  old_state=$(state_snapshot) || { tell_warn "状态读取失败，无法修改域名"; wait_key; return; }
  CERT_PRE_STATE="$old_state"
  acme_domain_assets_exist "$new_domain" && had_new_assets=1
  has_acme_support || { CERT_PRE_STATE=""; tell_warn "系统组件缺失，无法进行自动签发"; wait_key; return; }
  if prompt_yes "同步重置验证机制"; then
    reset_challenge=1
    email=$(prompt "ACME 通知邮箱" "admin@$new_domain"); [ -n "$email" ] || { CERT_PRE_STATE=""; return; }
    while :; do
      printf '\n%b选择证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
      menu_item 1 "HTTP         (推荐 需放行80端口)"
      menu_item 2 "TLS-ALPN     (推荐 需放行443端口)"
      menu_item 3 "Cloudflare API"
      menu_item 4 "阿里云 DNS API"
      menu_item 5 "ACME-DNS API"
      case $(prompt "请选择方式" 1) in
        1) mode=http; break ;;
        2) mode=alpn; break ;;
        3) v1=$(prompt "Cloudflare API Token")
           [ -n "$v1" ] || { tell_warn "API Token 不能为空"; sleep 1; continue; }
           mode=dns_cloudflare; state_set cf_token "$v1" || { state_restore "$old_state" || true; CERT_PRE_STATE=""; wait_key; return; }; break ;;
        4) v1=$(prompt "AccessKeyId"); v2=$(prompt "AccessKeySecret")
           [ -n "$v1" ] && [ -n "$v2" ] || { tell_warn "AccessKey 不能为空"; sleep 1; continue; }
           mode=dns_alidns; { state_set ali_key "$v1" && state_set ali_secret "$v2"; } || { state_restore "$old_state" || true; CERT_PRE_STATE=""; wait_key; return; }; break ;;
        5) v1=$(prompt "server_url"); v2=$(prompt "username"); v3=$(prompt "password"); v4=$(prompt "subdomain")
           [ -n "$v1" ] && [ -n "$v2" ] && [ -n "$v3" ] && [ -n "$v4" ] || { tell_warn "ACME-DNS 参数不能为空"; sleep 1; continue; }
           mode=dns_acmedns; { state_set acmedns_url "$v1" && state_set acmedns_user "$v2" && state_set acmedns_pass "$v3" && state_set acmedns_sub "$v4"; } || { state_restore "$old_state" || true; CERT_PRE_STATE=""; wait_key; return; }; break ;;
        *) tell_warn "输入无效，请重新选择"; sleep 1; ui_clear ;;
      esac
    done
    state_set challenge "$mode" || { state_restore "$old_state" || true; CERT_PRE_STATE=""; wait_key; return; }
    state_set email "$email" || { state_restore "$old_state" || true; CERT_PRE_STATE=""; wait_key; return; }
  fi
  if [ -z "$(state_get email || true)" ]; then
    reset_challenge=1
    email=$(prompt "ACME 通知邮箱" "admin@$new_domain"); [ -n "$email" ] || { state_restore "$old_state" || true; CERT_PRE_STATE=""; return; }
    state_set email "$email" || { state_restore "$old_state" || true; CERT_PRE_STATE=""; wait_key; return; }
  fi
  if [ "$reset_challenge" = 0 ] && [ -n "$old_domain" ] && [ "${old_domain,,}" = "${new_domain,,}" ] && certificate_ready "$new_domain"; then
    CERT_PRE_STATE=""
    tell_ok "域名与验证方式未变更"
    wait_key
    return
  fi
  if ! validate_domain "$new_domain"; then
    prompt_yes "解析验证存在异常，是否继续" || { state_restore "$old_state" || { tell_warn "状态恢复失败，已停止域名切换"; wait_key; }; CERT_PRE_STATE=""; return; }
  fi
  if [ -n "$old_domain" ] && [ "${old_domain,,}" = "${new_domain,,}" ] && certificate_ready "$new_domain"; then
    state_set domain "$new_domain" || { state_restore "$old_state" || true; CERT_PRE_STATE=""; tell_warn "域名状态写入失败"; wait_key; return; }
    if apply_config; then
      CERT_PRE_STATE=""
      tell_ok "验证方式已更新（当前证书仍有效，新验证方式将在下次自动续期时生效）"
      wait_key
      menu_server_info
    else
      state_restore "$old_state" || true
      CERT_PRE_STATE=""
      tell_warn "配置更新失败，已恢复旧配置"
      wait_key
    fi
    return
  fi
  if server_change_domain_transaction "$new_domain" "$old_state" "$had_new_assets"; then
    CERT_PRE_STATE=""
    tell_ok "新域名证书已签发并完成校验"
    tell_ok "域名已正式切换为: $new_domain"
    tell_ok "所有已配置域名节点已同步使用新域名"
    wait_key
    menu_server_info
  else
    status=$?
    CERT_PRE_STATE=""
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
         sleep 1
         if ! systemctl is-failed --quiet sing-box 2>/dev/null && systemctl is-active --quiet sing-box; then
           sync_resolved_dns_route
           if sync_hopping_rules; then tell_ok "重启完成"; else tell_warn "服务已重启，但跳跃规则同步失败"; fi
         else
           sync_resolved_dns_route
           tell_warn "sing-box 已停止"; tell_warn "重启失败"
         fi
         wait_key ;;
      7)
         previous=$(state_get exit) || { tell_warn "出口状态读取失败，未停止服务"; wait_key; continue; }
          if [ "$previous" != direct ]; then
            prompt_yes "当前 $(exit_label) 正在接管网络，停止服务将断开代理并恢复直连，是否继续" || continue
          else
            prompt_yes "确认停止 sing-box 服务" || continue
          fi
         local wg_was_active=0
         if wg_client_active; then
           wg_set_enabled false || { tell_warn "WireGuard 客户端停用失败，未停止服务"; wait_key; continue; }
           wg_was_active=1
         fi
         state_set exit direct || {
           [ "$wg_was_active" = 1 ] && wg_set_enabled true || true
           tell_warn "出口状态更新失败，未停止服务"; wait_key; continue
         }
         if timeout 15 systemctl stop sing-box 2>/dev/null; then
           local stop_tmp
           stop_tmp=$(mktemp) || {
              state_set exit "$previous" || true
              [ "$wg_was_active" = 1 ] && wg_set_enabled true || true
               timeout 15 systemctl start sing-box >/dev/null 2>&1 || true
             tell_warn "临时配置文件创建失败，已恢复出口状态"
             wait_key; continue
           }
           register_cleanup "$stop_tmp"
           if build_config >"$stop_tmp" 2>/dev/null && [ -s "$stop_tmp" ] && json_write "$CONFIG" <"$stop_tmp"; then
             cleanup_release "$stop_tmp"
             tell_ok "停止完成"
              warp_registered && json_edit "$WARP_CONF" 'del(.started_at)' || true
              sync_resolved_dns_route
           else
             cleanup_release "$stop_tmp"
              state_set exit "$previous" || true
              [ "$wg_was_active" = 1 ] && wg_set_enabled true || true
               timeout 15 systemctl start sing-box >/dev/null 2>&1 || true
             tell_warn "配置同步失败，已恢复出口状态"
           fi
         else
           state_set exit "$previous" || true
           [ "$wg_was_active" = 1 ] && wg_set_enabled true || true
           tell_warn "服务停止失败，已恢复出口状态"
         fi
         wait_key ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

menu_wireguard(){
  local refresh=1 wg_status_line=""
  while :; do
    if [ "$refresh" = 1 ]; then
      wg_status_line=""
      if ! wg_config_exists; then
        wg_status_line+="模式：${DIM}未配置${PLAIN}
"
      else
        local role enabled state ms color peer4 peer6
        role=$(wg_config_role)
        enabled=$(wg_config_enabled && printf 'true' || printf 'false')
        if [ "$role" = client ] && [ "$enabled" = true ]; then
          if ! { systemctl is-active --quiet sing-box && ip link show "$TUN_IF" >/dev/null 2>&1 && jq -e '.endpoints[]? | select(.tag=="wireguard")' "$CONFIG" >/dev/null 2>&1; }; then
            wg_status_line+="模式：客户端|${RED}异常${PLAIN}
"
          else
            peer4=$(jq -r '.peer_ip // empty' "$WG_CONF" 2>/dev/null)
            peer6=$(jq -r '.peer_ip6 // empty' "$WG_CONF" 2>/dev/null)
            state=$(wg_tunnel_state "$peer4" "$peer6")
            ms=${state#*|}
            if [[ "$state" == ok\|* ]] && [[ "$ms" =~ ^[0-9]+$ ]]; then
              if [ "$ms" -lt 100 ]; then color="$GREEN"; elif [ "$ms" -lt 150 ]; then color="$YELLOW"; else color="$BROWN"; fi
              wg_status_line+="模式：客户端|${GREEN}已连接${PLAIN}|${color}${ms} ms${PLAIN}
"
            elif [ "$state" = unknown ]; then
              wg_status_line+="模式：客户端|${YELLOW}无法探测${PLAIN}
"
            else
              wg_status_line+="模式：客户端|${YELLOW}探测失败${PLAIN}
"
            fi
          fi
        elif [ "$role" = server ]; then
          if [ "$enabled" = true ]; then
            if systemctl is-active --quiet sing-box && [ -n "$(wg_actual_listen_port "$(jq -r '.listen_port // 0' "$WG_CONF" 2>/dev/null)")" ]; then wg_status_line+="模式：服务端|${GREEN}运行中${PLAIN}
"; else wg_status_line+="模式：服务端|${RED}异常${PLAIN}
"; fi
          else
            wg_status_line+="模式：服务端|${YELLOW}已停止${PLAIN}
"
          fi
        else
          wg_status_line+="模式：客户端|${YELLOW}已停止${PLAIN}
"
        fi
      fi
      wg_status_line="${wg_status_line%$'\n'}"
      refresh=0
    fi
    ui_title "WireGuard"
    tell "$wg_status_line"
    tell ""
    menu_item 1 "初始化配置"
    menu_item 2 "修改配置"
    menu_item 3 "启用/停用"
    menu_item 4 "状态信息"
    menu_item 5 "删除配置"
    menu_item 0 "返回"
        case $(prompt "请选择 (回车刷新)") in
      1) wg_init ; refresh=1 ;;
      2) wg_edit ; refresh=1 ;;
      3) wg_toggle ; refresh=1 ;;
      4) wg_status ; refresh=1 ;;
      5) wg_delete ; refresh=1 ;;
      "") refresh=1 ;;
      0) return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

run_update(){
  local current latest script_url script_tmp script_sha script_ref blob_sha
  RELEASE_JSON_CACHE=""
  reload_net_cache
  release_json_load || true
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
  [ -f "$SELF" ] && [ -w "$(dirname "$SELF")" ] || { tell_warn "当前脚本路径不可写，无法自更新"; wait_key; return; }
  local ref_api="https://api.github.com/repos/88860/-/git/ref/heads/main"
  local file_api
  if [ -n "$NET_IPV4" ]; then
    if ! script_ref=$(curl -4 -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$ref_api" 2>/dev/null | jq -er '.object.sha // empty'); then
      if ! script_ref=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$ref_api" 2>/dev/null | jq -er '.object.sha // empty'); then
        tell_warn "无法获取脚本版本校验信息，请检查 GitHub 访问"; wait_key; return
      fi
    fi
  else
    if ! script_ref=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$ref_api" 2>/dev/null | jq -er '.object.sha // empty'); then
      tell_warn "无法获取脚本版本校验信息，请检查 GitHub 访问"; wait_key; return
    fi
  fi
  file_api="https://api.github.com/repos/88860/-/contents/s.sh?ref=$script_ref"
  if [ -n "$NET_IPV4" ]; then
    if ! script_sha=$(curl -4 -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$file_api" 2>/dev/null | jq -er '.sha // empty'); then
      if ! script_sha=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$file_api" 2>/dev/null | jq -er '.sha // empty'); then
        tell_warn "无法获取脚本文件校验信息，放弃更新"; wait_key; return
      fi
    fi
  else
    if ! script_sha=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$file_api" 2>/dev/null | jq -er '.sha // empty'); then
      tell_warn "无法获取脚本文件校验信息，放弃更新"; wait_key; return
    fi
  fi
  script_url="https://raw.githubusercontent.com/88860/-/$script_ref/s.sh"
  script_tmp=$(mktemp "$(dirname "$SELF")/.sbm-self.XXXXXX") || { tell_warn "无法创建临时文件"; wait_key; return; }
  register_cleanup "$script_tmp"
  if [ -n "$NET_IPV4" ]; then
    if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$script_url" -o "$script_tmp" 2>/dev/null; then
      if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$script_url" -o "$script_tmp" 2>/dev/null; then
        tell_warn "脚本下载失败，请检查 GitHub 访问"; cleanup_release "$script_tmp"; wait_key; return
      fi
    fi
  else
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "$script_url" -o "$script_tmp" 2>/dev/null; then
      tell_warn "脚本下载失败，请检查 GitHub 访问"; cleanup_release "$script_tmp"; wait_key; return
    fi
  fi
  blob_sha=$(printf 'blob %s\0' "$(wc -c <"$script_tmp" | tr -d '[:space:]')" | cat - "$script_tmp" | sha1sum | awk '{print $1}')
  if [ "$blob_sha" != "$script_sha" ]; then
    tell_warn "脚本完整性校验失败，放弃更新"; cleanup_release "$script_tmp"; wait_key; return
  fi
  if [ ! -s "$script_tmp" ]; then tell_warn "下载的脚本为空，放弃更新"
  elif bash -n "$script_tmp" 2>/dev/null; then
    if cmp -s "$script_tmp" "$SELF"; then tell_ok "脚本已是最新版本"
    else
      if chmod 700 "$script_tmp" && mv -f "$script_tmp" "$SELF"; then
        unregister_cleanup "$script_tmp"; tell_ok "脚本更新完成，请重新运行本脚本生效"; exit 0
      else tell_warn "脚本写入失败，原脚本未修改"; fi
    fi
  else tell_warn "下载的脚本存在语法错误，放弃更新"; fi
  cleanup_release "$script_tmp"
  wait_key
}

run_uninstall(){
  local packages
  ui_clear
  tell_warn "警告: 卸载将清空所有配置"
  [ "$(prompt '输入 yes 确认')" = yes ] || return
  mapfile -t packages < <(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null)
  systemctl disable --now sing-box 2>/dev/null
  rm -f "$SERVICE_UNIT" "$DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null
  systemctl daemon-reload
  clear_hopping_rules
  wg_server_nat_remove
  clear_legacy_bypass_rules
  ip link del "$WG_IF" 2>/dev/null
  ip link del "$TUN_IF" 2>/dev/null
  sync_resolved_dns_route
  ip link del "$WARP_IF" 2>/dev/null
  rm -rf "$SB_DIR" "$SBM_DIR" /var/lib/sing-box "$CORE" "${CORE}.bak" "${CORE}.new" "$SHORTCUT"
  if [ ${#packages[@]} -gt 0 ]; then
    tell "脚本曾安装过: [ ${packages[*]} ]"
    if prompt_yes "是否移除依赖组件"; then
      DEBIAN_FRONTEND=noninteractive apt-get remove -y -q "${packages[@]}" >/dev/null 2>&1
    fi
  fi
  rm -f "$SELF"
  tell_ok "清理完成"
  exit 0
}

menu_status(){
  local os core arch mem up_secs up_days up_hours up_mins up sb_ver sb_asset s_state ip_block="" refresh=1 choice
  while :; do
    if [ "$refresh" = 1 ]; then
      os=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)
      core=$(uname -r)
      arch=$(uname -m)
      mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}/MemFree/{f=$2}/Buffers/{b=$2}/^Cached/{c=$2}END{if(a=="")a=f+b+c; printf "%d / %d MB",(t-a)/1024,t/1024}' /proc/meminfo)
      up_secs=$(cut -d. -f1 /proc/uptime)
      up_days=$((up_secs / 86400)); up_hours=$(((up_secs % 86400) / 3600)); up_mins=$(((up_secs % 3600) / 60))
      up=""
      [ "$up_days" -gt 0 ] && up="${up_days}天"
      [ "$up_hours" -gt 0 ] && up="${up}${up_hours}小时"
      [ "$up_mins" -gt 0 ] && up="${up}${up_mins}分钟"
      [ -z "$up" ] && up="不足1分钟"
      sb_ver=$(core_version)
      sb_asset=$(state_get asset)
      s_state="${RED}未运行${PLAIN}"
      systemctl is-active --quiet sing-box && s_state="${GREEN}正常运行${PLAIN}"
      ui_title "状态与更新"
      tell "系统版本: ${os}"
      tell "内核架构: ${core} (${arch})"
      tell "内存状态: ${mem}"
      tell "运行时间: ${up}"
      tell "sing-box: ${s_state}"
      tell "sing-box 版本: ${sb_ver:-无} (${sb_asset:-未知})"
      tell ""
      tell "${DIM}正在检测出口 IP...${PLAIN}"
      ip_block=$(render_client_ip_status)
      refresh=0
    fi
    ui_title "状态与更新"
    tell "系统版本: ${os}"
    tell "内核架构: ${core} (${arch})"
    tell "内存状态: ${mem}"
    tell "运行时间: ${up}"
    tell "sing-box: ${s_state}"
    tell "sing-box 版本: ${sb_ver:-无} (${sb_asset:-未知})"
    tell ""
    [ -n "$ip_block" ] && printf '%s\n' "$ip_block"
    tell ""
    menu_item 1 "检测更新"
    menu_item 2 "彻底卸载"
    menu_item 0 "返回"
    choice=$(prompt "请选择 (回车刷新)")
    case "$choice" in
      "") refresh=1 ;;
      1) run_update; refresh=1 ;;
      2) run_uninstall ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

json_write(){
  local dest=$1 dir tmp
  dir=$(dirname "$dest"); [ -d "$dir" ] || return 1
  tmp=$(mktemp "$dir/.sbm.XXXXXX") || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

json_save(){
  local dest=$1 content=$2
  [ -n "$content" ] || return 1
  json_write "$dest" <<<"$content"
}

json_edit(){
  local file=$1 expr=$2 dir tmp; shift 2
  dir=$(dirname "$file"); [ -d "$dir" ] || return 1
  tmp=$(mktemp "$dir/.sbm.XXXXXX") || return 1
  if jq "$@" "$expr" "$file" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    chmod 600 "$tmp" && mv -f "$tmp" "$file" && return 0
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
  local host=$1 encoded qtype out if4 if6 v4_dead=0 dst
  if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || [[ "$host" =~ ^[0-9A-Fa-f:]+$ && "$host" == *:* ]]; then
    printf '%s\n' "$host"
    return 0
  fi
  if4=${NET_IF_V4:-$(default_iface 4)}
  if6=${NET_IF_V6:-$(default_iface 6)}
  encoded=$(uri_encode "$host")
  {
    for qtype in A AAAA; do
      out=""
      if [ "$v4_dead" = 0 ] && [ -n "$if4" ]; then
        for dst in 1.1.1.1 1.0.0.1; do
          if out=$(curl -4 -fsS --connect-timeout 2 -m 3 --interface "$if4" --resolve "one.one.one.one:443:${dst}" -H 'accept: application/dns-json' "https://one.one.one.one/dns-query?name=$encoded&type=$qtype" 2>/dev/null) && [ -n "$out" ]; then
            break
          fi
          out=""
        done
        [ -n "$out" ] || v4_dead=1
      fi
      if [ -z "$out" ] && [ -n "$if6" ]; then
        for dst in 2606:4700:4700::1111 2606:4700:4700::1001; do
          if out=$(curl -6 -fsS --connect-timeout 2 -m 3 --interface "$if6" --resolve "one.one.one.one:443:[${dst}]" -H 'accept: application/dns-json' "https://one.one.one.one/dns-query?name=$encoded&type=$qtype" 2>/dev/null) && [ -n "$out" ]; then
            break
          fi
          out=""
        done
      fi
      [ -n "$out" ] && jq -r '.Answer[]? | select(.type==1 or .type==28) | .data // empty' <<<"$out" 2>/dev/null
    done
  } | grep -v '^[[:space:]]*$' | sort -u
}
is_cgnat_v4(){
  local ip=$1 a b
  IFS=. read -r a b _ <<<"$ip"
  [ "$a" = "100" ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]
}
is_public_v4(){
  local ip=$1
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  case "$ip" in
    0.*|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|198.18.*|198.19.*|104.18.0.0) return 1 ;;
    *) is_cgnat_v4 "$ip" && return 1 ;;
  esac
  return 0
}
is_public_v6(){
  local ip=$1
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$ip" == *:* ]] || return 1
  case "${ip,,}" in
    ::|::1|fe80:*|fc*|fd*|ff*|::ffff:*) return 1 ;;
  esac
  return 0
}
probe_network_stack(){
  local prev_v4=$NET_IPV4 prev_v6=$NET_IPV6
  NET_IF_V4=$(default_iface 4)
  NET_IF_V6=$(default_iface 6)
  local local_v4="" local_v6="" nic_v4_list="" nic_v6_list="" nic_pub_v4="" _ip
  if [ -n "$NET_IF_V4" ]; then
    nic_v4_list=$(ip -4 addr show dev "$NET_IF_V4" scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
    local_v4=$(head -1 <<<"$nic_v4_list")
    while IFS= read -r _ip; do
      if is_public_v4 "$_ip"; then nic_pub_v4="$_ip"; break; fi
    done <<<"$nic_v4_list"
  fi
  if [ -n "$NET_IF_V6" ]; then
    nic_v6_list=$(ip -6 addr show dev "$NET_IF_V6" scope global 2>/dev/null | awk '/inet6 / && !/tentative|dadfailed/ && tolower($2) !~ /^(fe80:|fc|fd|ff|::ffff:)/{print tolower($2)}' | cut -d/ -f1)
    local_v6=$(head -1 <<<"$nic_v6_list")
  fi
  if [ -z "$local_v4" ] && [ -z "$local_v6" ]; then
    NET_IPV4=""; NET_IPV6=""; NET_STACK="none"; IPV6_OK=0; return 1
  fi
  local ip4="" ip6="" tun_active=0
  if ip link show "$TUN_IF" >/dev/null 2>&1; then
    tun_active=1
  else
    local tmp4="" tmp6="" p4="" p6=""
    if [ -n "$local_v4" ]; then
      tmp4=$(mktemp) || return 1
      register_cleanup "$tmp4"
      (
        local pref=$((1000 + (BASHPID % 6000))) resp cur_ip="" dst ip warp
        trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
        trap '[ -n "$cur_ip" ] && ip rule del pref "$pref" oif "$NET_IF_V4" to "$cur_ip/32" lookup main 2>/dev/null || true' EXIT
        while ip rule show 2>/dev/null | awk '{print $1}' | grep -qx "${pref}:"; do pref=$((pref+1)); [ "$pref" -lt 9000 ] || exit 1; done
        for dst in 1.1.1.1 1.0.0.1; do
          cur_ip="$dst"
          ip rule add pref "$pref" oif "$NET_IF_V4" to "$dst/32" lookup main 2>/dev/null || { cur_ip=""; continue; }
          resp=$(curl -4 -fsS --connect-timeout 2 -m 3 --interface "$NET_IF_V4" --resolve "one.one.one.one:443:${dst}" "https://one.one.one.one/cdn-cgi/trace" 2>/dev/null) || resp=""
          ip rule del pref "$pref" oif "$NET_IF_V4" to "$dst/32" lookup main 2>/dev/null || true
          cur_ip=""
          warp=$(awk -F= '$1=="warp"{gsub(/\r/,"",$2); print $2; exit}' <<<"$resp")
          case "$warp" in on|plus) continue ;; esac
          ip=$(awk -F= '$1=="ip"{gsub(/\r/,"",$2); print $2; exit}' <<<"$resp")
          if is_public_v4 "$ip"; then
            printf '%s\n' "$ip" > "$tmp4"
            exit 0
          fi
        done
        exit 1
      ) & p4=$!
      register_pid "$p4"
    fi
    if [ -n "$local_v6" ]; then
      tmp6=$(mktemp) || { [ -n "$p4" ] && { kill_tree "$p4"; wait "$p4" 2>/dev/null || true; unregister_pid "$p4"; }; cleanup_release "$tmp4"; return 1; }
      register_cleanup "$tmp6"
      (
        local pref=$((1000 + (BASHPID % 6000))) resp cur_ip="" dst ip warp
        trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
        trap '[ -n "$cur_ip" ] && ip -6 rule del pref "$pref" oif "$NET_IF_V6" to "$cur_ip/128" lookup main 2>/dev/null || true' EXIT
        while ip -6 rule show 2>/dev/null | awk '{print $1}' | grep -qx "${pref}:"; do pref=$((pref+1)); [ "$pref" -lt 9000 ] || exit 1; done
        for dst in 2606:4700:4700::1111 2606:4700:4700::1001; do
          cur_ip="$dst"
          ip -6 rule add pref "$pref" oif "$NET_IF_V6" to "$dst/128" lookup main 2>/dev/null || { cur_ip=""; continue; }
          resp=$(curl -6 -fsS --connect-timeout 2 -m 3 --interface "$NET_IF_V6" --resolve "one.one.one.one:443:[${dst}]" "https://one.one.one.one/cdn-cgi/trace" 2>/dev/null) || resp=""
          ip -6 rule del pref "$pref" oif "$NET_IF_V6" to "$dst/128" lookup main 2>/dev/null || true
          cur_ip=""
          warp=$(awk -F= '$1=="warp"{gsub(/\r/,"",$2); print $2; exit}' <<<"$resp")
          case "$warp" in on|plus) continue ;; esac
          ip=$(awk -F= '$1=="ip"{gsub(/\r/,"",$2); print $2; exit}' <<<"$resp")
          if is_public_v6 "$ip"; then
            printf '%s\n' "$ip" > "$tmp6"
            exit 0
          fi
        done
        exit 1
      ) & p6=$!
      register_pid "$p6"
    fi
    [ -n "$p4" ] && { wait "$p4" 2>/dev/null || true; unregister_pid "$p4"; }
    [ -n "$p6" ] && { wait "$p6" 2>/dev/null || true; unregister_pid "$p6"; }
    if [ -n "$tmp4" ]; then ip4=$(tr -d '\n ' < "$tmp4" 2>/dev/null); cleanup_release "$tmp4"; fi
    if [ -n "$tmp6" ]; then ip6=$(tr -d '\n ' < "$tmp6" 2>/dev/null); cleanup_release "$tmp6"; fi
    if ip link show "$TUN_IF" >/dev/null 2>&1; then
      tun_active=1; ip4=""; ip6=""
    fi
  fi
  if [ "$tun_active" = 1 ]; then
    local c_v4="" c_v6="" c_if4="" c_if6="" c_stack="" c_v6ok=""
    if [ -f "$NET_CACHE" ]; then
      { IFS= read -r c_v4; IFS= read -r c_v6; IFS= read -r c_if4; IFS= read -r c_if6; IFS= read -r c_stack; IFS= read -r c_v6ok; } < "$NET_CACHE" 2>/dev/null || true
    fi
    [ -n "$c_v4" ] || c_v4="$prev_v4"
    [ -n "$c_v6" ] || c_v6="$prev_v6"
    if [ -n "$local_v4" ]; then
      if [ -n "$nic_pub_v4" ]; then
        if is_public_v4 "$c_v4" && grep -Fqx "$c_v4" <<<"$nic_v4_list"; then
          ip4="$c_v4"
        else
          ip4="$nic_pub_v4"
        fi
      elif is_public_v4 "$c_v4"; then
        ip4="$c_v4"
      fi
    fi
    if [ -n "$local_v6" ]; then
      if is_public_v6 "$c_v6" && grep -Fqx "${c_v6,,}" <<<"$nic_v6_list"; then
        ip6="$c_v6"
      elif [ "$c_v6ok" = 0 ] && [ -z "$c_v6" ] && [ -n "$c_stack" ] && [ "$c_stack" != none ]; then
        ip6=""
      elif (
        local pref=$((1000 + (BASHPID % 6000))) dst cur_ip=""
        trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
        trap '[ -n "$cur_ip" ] && ip -6 rule del pref "$pref" oif "$NET_IF_V6" to "$cur_ip/128" lookup main 2>/dev/null || true' EXIT
        while ip -6 rule show 2>/dev/null | awk '{print $1}' | grep -qx "${pref}:"; do pref=$((pref+1)); [ "$pref" -lt 9000 ] || exit 1; done
        for dst in 2606:4700:4700::1111 2606:4700:4700::1001; do
          cur_ip="$dst"
          ip -6 rule add pref "$pref" oif "$NET_IF_V6" to "$dst/128" lookup main 2>/dev/null || { cur_ip=""; continue; }
          if timeout 2s ping -6 -I "$NET_IF_V6" -c 1 -W 2 "$dst" >/dev/null 2>&1; then
            ip -6 rule del pref "$pref" oif "$NET_IF_V6" to "$dst/128" lookup main 2>/dev/null || true
            cur_ip=""
            exit 0
          fi
          ip -6 rule del pref "$pref" oif "$NET_IF_V6" to "$dst/128" lookup main 2>/dev/null || true
          cur_ip=""
        done
        exit 1
      ); then
        ip6="$local_v6"
      fi
    fi
  fi
  is_public_v4 "$ip4" || ip4=""
  is_public_v6 "$ip6" || ip6=""
  NET_IPV4="$ip4"; NET_IPV6="$ip6"
  if [ -n "$ip4" ] && [ -n "$ip6" ]; then NET_STACK="both"
  elif [ -n "$ip4" ]; then NET_STACK="v4"
  elif [ -n "$ip6" ]; then NET_STACK="v6"
  else NET_STACK="none"; fi

  IPV6_OK=0
  [ -n "$ip6" ] && [ -n "$NET_IF_V6" ] && IPV6_OK=1
  [ "$NET_STACK" != none ] && return 0
  return 1
}

save_net_cache(){
  [ -n "$NET_STACK" ] && [ "$NET_STACK" != none ] || return 1
  local tmp
  tmp=$(mktemp "${NET_CACHE}.XXXXXX") || return 1
  register_cleanup "$tmp"
  if ! printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$NET_IPV4" "$NET_IPV6" "$NET_IF_V4" "$NET_IF_V6" "$NET_STACK" "$IPV6_OK" > "$tmp" || ! mv -f "$tmp" "$NET_CACHE"; then
    cleanup_release "$tmp"; return 1
  fi
  unregister_cleanup "$tmp"
}

probe_network_stack_async(){
  (
    CLEANUP_PATHS=(); CLEANUP_PIDS=(); CERT_BG_PID=""; CERT_PENDING_NODE=""; CERT_PENDING_APPLIED=0
    APPLY_CONFIG_INSTALLED=0; WARP_ROLLBACK_ACTIVE=0; WARP_ROLLBACK_APPLIED=0
    INSTALL_TMP_DIR=""; WG_BACKUP_DIR=""; WARP_PRE_REG_BAK=""; CERT_PRE_STATE=""
    trap cleanup_on_exit EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    exec 7>"${NET_CACHE}.lock" || exit 0
    flock -n 7 || exit 0
    probe_network_stack || exit 1
    save_net_cache || exit 1
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
  if [ -z "$NET_STACK" ] || [ "$NET_STACK" = none ]; then
    probe_network_stack || return 1
    save_net_cache || return 1
  fi
}
reload_net_cache(){
  [ -f "$NET_CACHE" ] || return 0
  local v4 v6 if4 if6 st v6ok
  if { IFS= read -r v4; IFS= read -r v6; IFS= read -r if4; IFS= read -r if6; IFS= read -r st; IFS= read -r v6ok; } < "$NET_CACHE" && [ -n "$st" ] && [ "$st" != none ]; then
    NET_IPV4="$v4"; NET_IPV6="$v6"; NET_IF_V4="$if4"; NET_IF_V6="$if6"; NET_STACK="$st"; IPV6_OK="$v6ok"
  fi
}
render_share_uri(){
  local file=$1 kind name port meta hopping mode host uri
  reload_net_cache
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
  local physical_v4="" physical_v6="" if4 if6 nic_v4_list="" nic_pub_v4="" nic_v6_list="" _ip
  if4=$(default_iface 4)
  if6=$(default_iface 6)
  if [ -n "$if4" ]; then
    nic_v4_list=$(ip -4 addr show dev "$if4" scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
    while IFS= read -r _ip; do
      if is_public_v4 "$_ip"; then nic_pub_v4="$_ip"; break; fi
    done <<<"$nic_v4_list"
    if [ -n "$nic_pub_v4" ]; then
      if is_public_v4 "$NET_IPV4" && grep -Fqx "$NET_IPV4" <<<"$nic_v4_list"; then
        physical_v4="$NET_IPV4"
      else
        physical_v4="$nic_pub_v4"
      fi
    elif is_public_v4 "$NET_IPV4"; then
      physical_v4="$NET_IPV4"
    fi
  fi
  if [ -n "$if6" ]; then
    nic_v6_list=$(ip -6 addr show dev "$if6" scope global 2>/dev/null | awk '/inet6 / && !/tentative|dadfailed/ && tolower($2) !~ /^(fe80:|fc|fd|ff|::ffff:)/{print tolower($2)}' | cut -d/ -f1)
    if [ -n "$nic_v6_list" ]; then
      if is_public_v6 "$NET_IPV6" && grep -Fqx "${NET_IPV6,,}" <<<"$nic_v6_list"; then
        physical_v6="$NET_IPV6"
      elif [ "$IPV6_OK" = 1 ] || [ -n "$NET_IPV6" ] || [ -z "$NET_STACK" ] || [ "$NET_STACK" = none ]; then
        physical_v6=$(head -1 <<<"$nic_v6_list")
      fi
    fi
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

# 内核是否启用了 IPv6 协议栈（与是否已获公网 IPv6 无关，用于入站 listen 地址判断）
kernel_ipv6_enabled(){ [ -f /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != 1 ]; }

validate_port(){
  local port=$1 proto=$2 allow=${3:-}
  is_pos_int "$port" && [ "$port" -le 65535 ] || { tell_warn "端口格式无效" >&2; return 1; }
  [ "$port" = 80 ] && { tell_warn "端口 80 已保留给证书签发" >&2; return 1; }
  [ "$port" = 443 ] && [ "$proto" != "u" ] && [ "$(state_get challenge)" = "alpn" ] && { tell_warn "端口 443 已保留给 ALPN 证书签发" >&2; return 1; }
  [ "$port" = "$allow" ] && return 0
  grep -qx "$port" <<<"$(protected_ports)" && { tell_warn "已被节点或 SSH 占用" >&2; return 1; }
  if [ "$proto" = "u" ] || [ "$proto" = "tu" ]; then
    local hf hop_range hop_low hop_high
    for hf in "$NODE_DIR"/*.json; do
      [ -e "$hf" ] || continue
      [ "$(jq -r '.kind' "$hf" 2>/dev/null)" = "hysteria2" ] || continue
      hop_range=$(jq -r '.hopping//""' "$hf" 2>/dev/null)
      [ -n "$hop_range" ] || continue
      [[ "$hop_range" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]] || continue
      hop_low=${hop_range%-*}; hop_high=${hop_range#*-}
      [ "$port" -ge "$hop_low" ] && [ "$port" -le "$hop_high" ] && { tell_warn "端口 $port 落入已有 Hysteria2 跳跃范围 $hop_range" >&2; return 1; }
    done
  fi
  if [ "$proto" = "tu" ]; then
    { grep -qx "$port" <<<"$(listening_ports t)" || grep -qx "$port" <<<"$(listening_ports u)"; } && { tell_warn "端口被占用" >&2; return 1; }
  else
    grep -qx "$port" <<<"$(listening_ports "$proto")" && { tell_warn "端口被占用" >&2; return 1; }
  fi
  return 0
}

prompt_port(){
  local proto=$1 allow=${2:-} def_override=${3:-} port def_port
  while :; do
    def_port=${def_override:-${allow:-$(random_port)}}
    port=$(prompt "监听端口" "$def_port")
    validate_port "$port" "$proto" "$allow" && { printf '%s' "$port"; return 0; }
  done
}

validate_range(){
  local range=$1 extra_port=${2:-} low high port
  [[ $range =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]] || { tell_warn "格式应为 20000-30000"; return 1; }
  low=${range%-*}; high=${range#*-}
  [ "$low" -ge 1 ] && [ "$high" -le 65535 ] && [ "$low" -lt "$high" ] || { tell_warn "端口范围不合法"; return 1; }
  for port in $(listening_ports u) $(protected_ports) $extra_port 80 443; do
    [ "$port" -ge "$low" ] && [ "$port" -le "$high" ] && { tell_warn "范围内包含系统保留或节点端口: $port"; return 1; }
  done
  return 0
}

probe_target_latency(){
  local server=$1 result=$2 latency_file=${3:-} iface family out ms deadline left step_t targets target
  command -v ping >/dev/null 2>&1 || { echo fail >"$result"; return 1; }
  if [[ "$server" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || [[ "$server" =~ ^[0-9A-Fa-f:]+$ && "$server" == *:* ]]; then
    targets=$server
  else
    targets=$(resolve_addresses "$server")
  fi
  [ -n "$targets" ] || { echo fail >"$result"; return 1; }
  local -a list4=() list6=() ordered=()
  while IFS= read -r target; do
    if [[ "$target" =~ ^[0-9A-Fa-f:]+$ && "$target" == *:* ]]; then
      [ "${#list6[@]}" -lt 2 ] && list6+=("$target")
    elif [[ "$target" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      [ "${#list4[@]}" -lt 2 ] && list4+=("$target")
    fi
  done <<<"$targets"
  if [ -n "$NET_IF_V6" ] && [ "$IPV6_OK" = 1 ]; then
    [ -n "${list6[0]:-}" ] && ordered+=("${list6[0]}")
    [ -n "${list4[0]:-}" ] && ordered+=("${list4[0]}")
    [ -n "${list6[1]:-}" ] && ordered+=("${list6[1]}")
    [ -n "${list4[1]:-}" ] && ordered+=("${list4[1]}")
  else
    [ -n "${list4[0]:-}" ] && ordered+=("${list4[0]}")
    [ -n "${list6[0]:-}" ] && ordered+=("${list6[0]}")
    [ -n "${list4[1]:-}" ] && ordered+=("${list4[1]}")
    [ -n "${list6[1]:-}" ] && ordered+=("${list6[1]}")
  fi
  deadline=$((SECONDS+4))
  for target in "${ordered[@]}"; do
    [ -n "$target" ] || continue
    left=$((deadline-SECONDS)); [ "$left" -gt 0 ] || break
    step_t=$((left > 1 ? 1 : left))
    if [[ "$target" =~ ^[0-9A-Fa-f:]+$ && "$target" == *:* ]]; then
      [ -n "$NET_IF_V6" ] || continue; iface=$NET_IF_V6; family=6
    else
      [ -n "$NET_IF_V4" ] || continue; iface=$NET_IF_V4; family=4
    fi
    out=$(timeout "${step_t}s" ping -"$family" -I "$iface" -c 1 -W "$step_t" "$target" 2>/dev/null)
    if [ $? -eq 0 ]; then
      ms=$(awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}' <<<"$out")
      if [[ "$ms" =~ ^[0-9]+$ ]]; then
        echo ok >"$result"
        [ -n "$latency_file" ] && printf '%s\n' "$ms" >"$latency_file"
        return 0
      fi
    fi
  done
  echo fail >"$result"
  return 1
}

probe_handshake_target(){
  local target=$1 ips ip4 ip6 conn result=""
  command -v openssl >/dev/null || { tell_warn "openssl 未安装，无法验证"; return 1; }
  reload_net_cache
  ips=$(resolve_addresses "$target" 2>/dev/null || true)
  ip4=$(awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print;exit}' <<<"$ips")
  ip6=$(awk '/:/{print;exit}' <<<"$ips")
  local -a candidates=()
  if [ -z "$NET_IPV4" ] && [ "$IPV6_OK" = 1 ]; then
    [ -n "$ip6" ] && candidates+=("[$ip6]:443")
    [ -n "$ip4" ] && candidates+=("$ip4:443")
  else
    [ -n "$ip4" ] && candidates+=("$ip4:443")
    [ -n "$ip6" ] && candidates+=("[$ip6]:443")
  fi
  candidates+=("$target:443")
  for conn in "${candidates[@]}"; do
    result=$(echo | timeout 10 openssl s_client -connect "$conn" -servername "$target" -alpn h2 -tls1_3 2>/dev/null)
    grep -q "TLSv1.3" <<<"$result" && break
  done
  grep -q "TLSv1.3" <<<"$result" || { tell_warn "不支持 TLS 1.3 协议"; return 1; }
  grep -q "ALPN protocol: h2" <<<"$result" || { tell_warn "不支持 HTTP/2 协议"; return 1; }
  grep -qi "X25519" <<<"$result" || { tell_warn "未检测到 X25519 特性"; return 1; }
  tell_ok "验证通过"; return 0
}

validate_domain(){
  local domain=$1 resolved resolved_l ipv4 ipv6_l
  reload_net_cache
  resolved=$(resolve_addresses "$domain")
  [ -n "$resolved" ] || { tell_warn "无法解析该域名"; return 1; }
  resolved_l=$(printf '%s\n' "$resolved" | tr '[:upper:]' '[:lower:]')
  ipv4=$NET_IPV4
  ipv6_l=$(printf '%s' "$NET_IPV6" | tr '[:upper:]' '[:lower:]')
  if ! { [ -n "$ipv4" ] && grep -Fqx "$ipv4" <<<"$resolved_l"; } && ! { [ -n "$ipv6_l" ] && grep -Fqx "$ipv6_l" <<<"$resolved_l"; }; then
    tell_warn "域名解析地址与本地 IP 不匹配"; return 1
  fi
  case $(state_get challenge) in
    http) grep -qx 80 <<<"$(listening_ports t)" && { tell_warn "本机 80 端口已被占用"; return 1; } ;;
    alpn) grep -qx 443 <<<"$(listening_ports t)" && { tell_warn "本机 443 端口已被占用"; return 1; } ;;
  esac
  tell_ok "解析记录正常"; return 0
}

certificate_ready(){
  local domain=$1 key cert_pub key_pub file domain_lower
  [ -n "$domain" ] || return 1
  domain_lower=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r file; do
    openssl x509 -in "$file" -noout -checkhost "$domain" >/dev/null 2>&1 || continue
    openssl x509 -in "$file" -noout -checkend 0 >/dev/null 2>&1 || continue
    cert_pub=$(openssl x509 -in "$file" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
    [ -n "$cert_pub" ] || continue
    key="${file%.crt}.key"
    [ -f "$key" ] || continue
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
    if [ -n "$key_pub" ] && [ "$key_pub" = "$cert_pub" ]; then
      return 0
    fi
  done < <(find "$ACME_DIR/certificates" -type f -path "*/${domain_lower}/${domain_lower}.crt" 2>/dev/null)
  return 1
}

wait_for_certificate(){
  local domain=$1 pid=${2:-} log_file=${3:-} log elapsed=0
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
    elapsed=$((elapsed+1))
    if [ "$elapsed" -gt 300 ]; then
      tell_warn "证书签发超时（5分钟），请检查网络和 DNS 配置"
      return 1
    fi
    sleep 1
  done
}

setup_certificate(){
  local domain email mode old_state v1 v2 v3 v4
  [ -n "$(state_get domain)" ] && [ -n "$(state_get email)" ] && certificate_ready "$(state_get domain)" && { CERT_PRE_STATE=""; return 0; }
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; wait_key; return 1; }
  old_state=$(state_snapshot) || return 1
  CERT_PRE_STATE="$old_state"
  printf '\n%b该协议需要绑定域名并签发证书%b\n' "${YELLOW}" "${PLAIN}"
  domain=$(sanitize_domain "$(prompt '输入域名')")
  [ -n "$domain" ] || { CERT_PRE_STATE=""; return 1; }
  email=$(prompt "ACME 通知邮箱" "admin@$domain"); [ -n "$email" ] || { CERT_PRE_STATE=""; return 1; }
  while :; do
    printf '\n%b选择域名证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
    menu_item 1 "HTTP         (推荐 需放行80端口)"
    menu_item 2 "TLS-ALPN     (推荐 需放行443端口)"
    menu_item 3 "Cloudflare API"
    menu_item 4 "阿里云 DNS API"
    menu_item 5 "ACME-DNS API"
    case $(prompt "请选择方式" 1) in
      1) mode=http; break ;;
      2) mode=alpn; break ;;
      3) v1=$(prompt "Cloudflare API Token")
         [ -n "$v1" ] || { tell_warn "API Token 不能为空"; sleep 1; continue; }
         mode=dns_cloudflare; state_set cf_token "$v1" || { state_restore "$old_state" || true; CERT_PRE_STATE=""; return 1; }; break ;;
      4) v1=$(prompt "AccessKeyId"); v2=$(prompt "AccessKeySecret")
         [ -n "$v1" ] && [ -n "$v2" ] || { tell_warn "AccessKey 不能为空"; sleep 1; continue; }
         mode=dns_alidns; { state_set ali_key "$v1" && state_set ali_secret "$v2"; } || { state_restore "$old_state" || true; CERT_PRE_STATE=""; return 1; }; break ;;
      5) v1=$(prompt "server_url"); v2=$(prompt "username"); v3=$(prompt "password"); v4=$(prompt "subdomain")
         [ -n "$v1" ] && [ -n "$v2" ] && [ -n "$v3" ] && [ -n "$v4" ] || { tell_warn "ACME-DNS 参数不能为空"; sleep 1; continue; }
         mode=dns_acmedns; { state_set acmedns_url "$v1" && state_set acmedns_user "$v2" && state_set acmedns_pass "$v3" && state_set acmedns_sub "$v4"; } || { state_restore "$old_state" || true; CERT_PRE_STATE=""; return 1; }; break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1; ui_clear ;;
    esac
  done
  state_set challenge "$mode" && state_set domain "$domain" && state_set email "$email" || { state_restore "$old_state" || true; CERT_PRE_STATE=""; return 1; }
  if ! validate_domain "$domain"; then
    prompt_yes "验证存在异常，是否强制继续" || { state_restore "$old_state" || true; CERT_PRE_STATE=""; return 1; }
  fi
  return 0
}

ssh_ports(){
  local _ssh_conf
  {
    [ -n "$SSH_CONNECTION" ] && awk '{print $4}' <<<"$SSH_CONNECTION"
    ss -Hlntp 2>/dev/null | awk '/users:\(\("(sshd|sshd-session|dropbear)"/{print $4}' | sed 's/.*://'
    systemctl show -p Listen --value ssh.socket sshd.socket 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/ || $i ~ /^[0-9]+$/){sub(/.*:/,"",$i); print $i}}'
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
  local file
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    jq -r '.port // empty' "$file" 2>/dev/null || true
  done | grep -E '^[1-9][0-9]*$'
}
protected_ports(){
  { ssh_ports; node_ports; wg_config_listen_port; } | grep -E '^[1-9][0-9]*$' | sort -un
}
listening_ports(){ ss -Hln"$1" 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u; }
hopping_node(){
  local file value
  for file in "$NODE_DIR"/*.json; do
    value=$(jq -r '.hopping//""' "$file" 2>/dev/null) || return 2
    [ -n "$value" ] && { printf '%s' "$file"; return 0; }
  done
  return 1
}
clear_legacy_bypass_rules(){
  local state="$SBM_DIR/bypass_rules" family selector value rc=0
  [ -f "$state" ] || return 0
  while read -r family selector value; do
    case "$family:$selector:$value" in
      4:sport:*) ip -4 rule del pref 90 sport "$value" lookup main 2>/dev/null || true ;;
      6:sport:*) ip -6 rule del pref 90 sport "$value" lookup main 2>/dev/null || true ;;
      4:fwmark:fwmark) ip -4 rule del pref 90 fwmark 255 lookup main 2>/dev/null || true ;;
      6:fwmark:fwmark) ip -6 rule del pref 90 fwmark 255 lookup main 2>/dev/null || true ;;
    esac
  done < "$state"
  rm -f "$state" || rc=1
  return "$rc"
}
sync_hopping_rules(){
  local file range port first last hop_rc script=''
  file=$(hopping_node); hop_rc=$?
  [ "$hop_rc" -eq 1 ] && { nft list table inet "$HOP_TABLE" >/dev/null 2>&1 && nft delete table inet "$HOP_TABLE" >/dev/null 2>&1 || true; return 0; }
  [ "$hop_rc" -eq 0 ] || return 1
  range=$(jq -r '.hopping // empty' "$file") || return 1
  port=$(jq -r '.port // empty' "$file") || return 1
  [[ "$range" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]] || return 1
  first=${BASH_REMATCH[1]}; last=${BASH_REMATCH[2]}
  is_pos_int "$port" && [ "$port" -le 65535 ] || return 1
  [ "$first" -le "$last" ] && [ "$last" -le 65535 ] || return 1
  script="add table inet $HOP_TABLE\nflush table inet $HOP_TABLE\nadd chain inet $HOP_TABLE prerouting { type nat hook prerouting priority dstnat; policy accept; }\nadd rule inet $HOP_TABLE prerouting iifname != \"lo\" iifname != \"$WG_IF\" iifname != \"$TUN_IF\" udp dport $range redirect to :$port\n"
  nft -f <(printf '%b' "$script") >/dev/null 2>&1
}
clear_hopping_rules(){ nft delete table inet "$HOP_TABLE" 2>/dev/null || true; }

sync_resolved_dns_route(){
  command -v resolvectl >/dev/null 2>&1 || return 0
  systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
  local mode="true" iface if4 if6
  if4=${NET_IF_V4:-$(default_iface 4)}
  if6=${NET_IF_V6:-$(default_iface 6)}
  ip link show "$TUN_IF" >/dev/null 2>&1 && mode="false"
  for iface in $(printf '%s\n%s\n' "$if4" "$if6" | grep -v '^[[:space:]]*$' | sort -u); do
    resolvectl default-route "$iface" "$mode" 2>/dev/null || true
  done
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
  local domain=$1 node_files tls_extra='{}' providers='[]' file
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  local inbounds='[]'
  node_files=()
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    node_files+=("$file")
  done
  if [ ${#node_files[@]} -gt 0 ]; then
    if jq -se 'any(.[]; .tls_mode == "acme")' "${node_files[@]}" >/dev/null 2>&1; then
      [ -n "$domain" ] || return 1
      providers=$(jq -n --arg t "$CERT_TAG" --argjson a "$(acme_options "$domain")" '[$a+{type:"acme",tag:$t}]') || return 1
      tls_extra=$(jq -n --arg t "$CERT_TAG" '{certificate_provider:$t}') || return 1
    fi
    inbounds=$(jq -s --arg d "$domain" --arg listen "$listen_addr" --argjson x "$tls_extra" '
      [ .[] |
        (.inbound + {listen:$listen}) as $in |
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
      if [ "$selected" = "wireguard" ]; then
        endpoints=$(wg_config_endpoint "$dns_direct_tag")
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

  if [ "$selected" != direct ] && [ "$selected" != wireguard ] && [ "$selected" != warp ]; then
    if [ -f "$PEER_DIR/$selected.json" ]; then
      outbounds=$(jq -n --argjson base "$outbounds" --slurpfile peer "$PEER_DIR/$selected.json" \
        --arg resolver "$dns_direct_tag" '$base + [($peer[0].outbound + {domain_resolver:$resolver} | if .type=="shadowsocks" then del(.network) else . end)]') || return 1
      final=$selected; use_tun=1
      peer_host=$(client_peer_server "$PEER_DIR/$selected.json")
    else
      tell_warn "出口节点 $selected 文件不存在，回退直连" >&2
    fi
  fi

  jq -n --argjson outbounds "$outbounds" --argjson endpoints "$endpoints" \
    --arg host "$peer_host" --arg final "$final" --argjson tun "$use_tun" \
    '{outbounds:$outbounds,endpoints:$endpoints,peer_host:$host,final:$final,use_tun:$tun}'
}

config_build_tun_inbounds(){
  local inbounds=$1 mode=${2:-dual} endpoint_host=${3:-} route exclude='[]' lip
  local tun_addr='["172.19.0.1/30","fdfe:dcba:9876::1/126"]'
  local tun_family="both"
  case "$mode" in
    ipv4|ipv6|dual) route='["0.0.0.0/0","::/0"]' ;;
    *) return 1 ;;
  esac
  if ! kernel_ipv6_enabled; then
    [ "$mode" = ipv6 ] && return 1
    tun_family="v4"
    route='["0.0.0.0/0"]'
    tun_addr='["172.19.0.1/30"]'
  fi


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


  if [ -n "$SSH_CONNECTION" ]; then
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


  exclude=$(jq -c --argjson x '["127.0.0.0/8","::1/128"]' '. + $x | unique' <<<"$exclude") || return 1


  local local_ips
  local_ips=$(ip -o addr show 2>/dev/null | awk -v t="$TUN_IF" -v w="$WARP_IF" '$2!=t && $2!=w {print $4}' | cut -d/ -f1 | grep -v '^127\.' | grep -v '^::1$' | grep -v '^fe80:' || true)
  if [ -n "$local_ips" ]; then
    local local_cidrs='[]'
    while IFS= read -r lip; do
      [ -z "$lip" ] && continue
      if [[ "$lip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local_cidrs=$(jq -c --arg x "${lip}/32" '. + [$x] | unique' <<<"$local_cidrs") || continue
      elif [[ "$lip" == *:* ]]; then
        local_cidrs=$(jq -c --arg x "${lip}/128" '. + [$x] | unique' <<<"$local_cidrs") || continue
      fi
    done <<<"$local_ips"
    exclude=$(jq -c --argjson x "$local_cidrs" '. + $x | unique' <<<"$exclude") || return 1
  fi


  if [ "$tun_family" = v4 ]; then
    exclude=$(jq -c 'map(select(contains(":") | not))' <<<"$exclude") || return 1
  fi


  jq -n --argjson list "$inbounds" --arg name "$TUN_IF" --argjson addr "$tun_addr" --argjson route "$route" --argjson exclude "$exclude" '
    [{type:"tun",tag:"tun-in",interface_name:$name,
      address:$addr,
      dns_mode:"hijack",
      auto_route:true,auto_redirect:true,
      strict_route:false,
      mtu:1500,
      route_address:$route,
      route_exclude_address:$exclude}
    ] + $list'
}

config_build_rules(){
  local peer_host=$1 mode=${2:-dual} use_tun=${3:-0} final=${4:-direct}
  local ssh_rule_ports='[]' ssh_client_ips='[]'
  local wg_client_peer_cidrs='[]' wg_server_self_cidrs='[]'
  if wg_config_enabled && [ "$(wg_config_role)" = server ] && [ -f "$WG_CONF" ]; then
    wg_server_self_cidrs=$(jq -c '[(.address[0] // empty), (.address[1] // empty)] | map(split("/")[0] | select(length > 0) | if contains(":") then .+"/128" else .+"/32" end)' "$WG_CONF" 2>/dev/null || printf '[]')
  fi
  if [ "$use_tun" != 1 ]; then
    jq -n --argjson wg_srv "$wg_server_self_cidrs" '
      if ($wg_srv|length)>0 then
        [{inbound:["wireguard"],network:"icmp",ip_cidr:$wg_srv,action:"reject",method:"reply",no_drop:true},
         {inbound:["wireguard"],port:53,action:"hijack-dns"}]
      else [] end'
    return 0
  fi
  ssh_rule_ports=$(ssh_ports | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')
  ssh_client_ips=$(if [ -n "$SSH_CONNECTION" ]; then printf '%s\n' "$SSH_CONNECTION" | awk '{print $1}'; fi | jq -Rsc 'split("\n") | map(select((test("^[0-9]+(\\.[0-9]+){3}$") or (test("^[0-9A-Fa-f:]+$") and contains(":"))))) | map(if contains(":") then .+"/128" else .+"/32" end)')
  if [ "$final" = wireguard ] && [ -f "$WG_CONF" ]; then
    wg_client_peer_cidrs=$(jq -c '[(.peer_ip // empty), (.peer_ip6 // empty)] | map(select(length > 0) | if contains(":") then .+"/128" else .+"/32" end)' "$WG_CONF" 2>/dev/null || printf '[]')
  fi
  jq -n --arg host "$peer_host" --arg mode "$mode" --arg final "$final" \
    --argjson ssh_ports "$ssh_rule_ports" --argjson ssh_client_ips "$ssh_client_ips" \
    --argjson wg_peer "$wg_client_peer_cidrs" --argjson wg_srv "$wg_server_self_cidrs" '
    (if ($wg_peer|length)>0 then
       [{inbound:["tun-in"],network:"icmp",ip_cidr:$wg_peer,action:"route",outbound:"wireguard"}]
    else [] end)
    + [{inbound:["tun-in"],network:"icmp",action:"bypass",outbound:"direct"}]
    + (if ($ssh_ports|length)>0 then
         [{inbound:["tun-in"],network:"tcp",source_port:$ssh_ports,action:"bypass",outbound:"direct"}]
       else [] end)
    + [{inbound:["tun-in"],network:"tcp",source_port:[80,443],action:"bypass",outbound:"direct"}]
    + [{inbound:["tun-in"],process_name:["ssh","sshd","sshd-session","sshd-auth","dropbear"],action:"bypass",outbound:"direct"}]
    + (if ($ssh_client_ips|length)>0 then
         [{inbound:["tun-in"],ip_cidr:$ssh_client_ips,action:"bypass",outbound:"direct"}]
       else [] end)
    + (if $host=="" then []
       elif ($host | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) then [{inbound:["tun-in"],ip_cidr:[($host+"/32")],action:"bypass",outbound:"direct"}]
       elif ($host | (test("^[0-9a-fA-F:]+$") and contains(":"))) then [{inbound:["tun-in"],ip_cidr:[($host+"/128")],action:"bypass",outbound:"direct"}]
       else [] end)
    + [{inbound:["tun-in"],network:"udp",port:53,action:"hijack-dns"},
       {inbound:["tun-in"],action:"sniff"},
       {inbound:["tun-in"],protocol:"ssh",action:"route",outbound:"direct"},
       {inbound:["tun-in"],protocol:"dns",action:"hijack-dns"},
       {inbound:["tun-in"],port:53,action:"hijack-dns"}]
    + (if $host!="" and (($host | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) | not) and ((($host | test("^[0-9a-fA-F:]+$")) and ($host | contains(":"))) | not) then
         [{inbound:["tun-in"],domain:[($host|ascii_downcase)],action:"resolve",server:"dns-direct"},
          {inbound:["tun-in"],domain:[($host|ascii_downcase)],action:"route",outbound:"direct"}]
       else [] end)
    + (if ($wg_srv|length)>0 then
         [{inbound:["wireguard"],network:"icmp",ip_cidr:$wg_srv,action:"reject",method:"reply",no_drop:true},
          {inbound:["wireguard"],port:53,action:"hijack-dns"}]
       else [] end)
    + (if $final=="warp" and $mode=="ipv4" then [
         {port:53,action:"hijack-dns"},
         {ip_cidr:["::/0"],action:"route",outbound:"direct"},
         {ip_cidr:["0.0.0.0/0"],action:"route",outbound:"warp"},
         {action:"resolve",server:"dns-remote"},
         {ip_cidr:["0.0.0.0/0"],action:"route",outbound:"warp"},
         {ip_cidr:["::/0"],action:"route",outbound:"direct"}
       ]
       elif $final=="warp" and $mode=="ipv6" then [
         {port:53,action:"hijack-dns"},
         {ip_cidr:["::/0"],action:"route",outbound:"warp"},
         {ip_cidr:["0.0.0.0/0"],action:"route",outbound:"direct"},
         {action:"resolve",server:"dns-remote"},
         {ip_cidr:["::/0"],action:"route",outbound:"warp"},
         {ip_cidr:["0.0.0.0/0"],action:"route",outbound:"direct"}
       ]
       elif $final=="wireguard" or ($final=="warp" and $mode=="dual") then [
         {action:"resolve",server:"dns-remote"}
       ]
       else [] end)'
}

config_build_dns(){
  local dns_strategy=$1 final=$2 warp_mode=${3:-} v6_kernel=${4:-1}
  jq -n --arg strategy "$dns_strategy" --arg detour "$final" --arg warp_mode "$warp_mode" --argjson v6 "$v6_kernel" '
    (if $v6 == 1 then ["1.1.1.1","2606:4700:4700::1111"] else ["1.1.1.1"] end) as $cf_ips |
    {type:"hosts",tag:"dns-bootstrap",path:[],predefined:{"cloudflare-dns.com":$cf_ips}} as $bootstrap |
    {type:"https",tag:"dns-direct",server:"cloudflare-dns.com",server_port:443,path:"/dns-query",
     domain_resolver:"dns-bootstrap",tls:{enabled:true,server_name:"cloudflare-dns.com"}} as $direct |
    (if $detour == "direct" then
       {servers:[$bootstrap,$direct],final:"dns-direct",strategy:$strategy}
     else
       (if $detour == "warp" and $warp_mode == "ipv6" then
          {type:"udp",tag:"dns-remote",server:"2606:4700:4700::1111",server_port:53,detour:"warp"}
        elif $detour == "warp" or $detour == "wireguard" then
          {type:"udp",tag:"dns-remote",server:"1.1.1.1",server_port:53,detour:$detour}
        else
          {type:"https",tag:"dns-remote",server:"cloudflare-dns.com",server_port:443,path:"/dns-query",
           detour:$detour,tls:{enabled:true,server_name:"cloudflare-dns.com"}}
        end) as $remote |
       {servers:[$bootstrap,$direct,$remote],final:"dns-remote",strategy:$strategy}
     end)'
}

build_config(){
  local selected domain inbounds outbounds endpoints rules dns_block final use_tun peer_host
  local node_block exit_block dns_direct_tag route_resolver dns_strategy auto_detect providers warp_mode v6_kernel
  reload_net_cache
  selected=$(state_get exit) || return 1
  domain=$(state_get domain) || return 1
  v6_kernel=1
  ! kernel_ipv6_enabled && v6_kernel=0
  dns_direct_tag="dns-direct"
  dns_strategy="prefer_ipv4"
  if [ "$v6_kernel" = 0 ]; then
    dns_strategy="ipv4_only"
  elif [ -z "$NET_IPV4" ] && [ -n "$NET_IF_V6" ] && [ "$IPV6_OK" = 1 ]; then
    dns_strategy="prefer_ipv6"
  fi
  if [ "$selected" = warp ]; then
    warp_mode=$(warp_mode_get)
    case "$warp_mode" in
      ipv4) [ "$v6_kernel" = 0 ] && dns_strategy="ipv4_only" || dns_strategy="prefer_ipv4" ;;
      ipv6) dns_strategy="prefer_ipv6" ;;
      dual)
        if [ "$v6_kernel" = 0 ]; then dns_strategy="ipv4_only"
        elif [ -n "$NET_IPV4" ] || [ -n "$NET_IF_V4" ]; then dns_strategy="prefer_ipv4"
        elif [ -n "$NET_IF_V6" ]; then dns_strategy="prefer_ipv6"
        else return 1; fi ;;
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
    inbounds=$(config_build_tun_inbounds "$inbounds" "$( [ "$selected" = warp ] && warp_mode_get || printf dual )" "$peer_host") || return 1
  fi

  rules=$(config_build_rules "$peer_host" "$( [ "$selected" = warp ] && warp_mode_get || printf dual )" "$use_tun" "$final") || return 1
  if [ "$use_tun" = 1 ]; then auto_detect="true"; else auto_detect="false"; fi
  if [ "$final" = direct ]; then route_resolver="dns-direct"; else route_resolver="dns-remote"; fi
  dns_block=$(config_build_dns "$dns_strategy" "$final" "${warp_mode:-}" "$v6_kernel") || return 1

  jq -n --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" \
        --argjson endpoints "$endpoints" --argjson rules "$rules" \
        --argjson dns "$dns_block" --argjson providers "$providers" \
        --arg final "$final" --arg direct_tag "$route_resolver" --argjson auto_detect "$auto_detect" '
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
      local vmess_net vmess_security vmess_path vmess_host_meta
      case "$kind" in
        vmess-tls) vmess_net=tcp ;;
        vmess-ws) vmess_net=ws ;;
        vmess-grpc) vmess_net=grpc ;;
        vmess-http) vmess_net=h2 ;;
      esac
      vmess_security=$(jq -r '.security//"auto"' <<<"$meta")
      vmess_path=$(jq -r '.path//""' <<<"$meta")
      # gRPC 模式下 host 字段使用服务器地址，service_name 单独写入 serviceName 字段
      vmess_host_meta="$sni_host"
      local vmess_service_name
      vmess_service_name=$(jq -r '.service_name//""' <<<"$meta")
      local vmess_json vmess_b64
      vmess_json=$(jq -n \
        --arg ps "$name" \
        --arg add "$sni_host" \
        --arg port "$port" \
        --arg id "$(jq -r .uuid <<<"$meta")" \
        --argjson aid 0 \
        --arg scy "$vmess_security" \
        --arg net "$vmess_net" \
        --arg type "none" \
        --arg host "$vmess_host_meta" \
        --arg path "$vmess_path" \
        --arg service_name "$vmess_service_name" \
        --arg tls "tls" \
        --arg sni "$sni_host" \
        --arg alpn "" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:$aid,scy:$scy,net:$net,type:$type,host:$host,path:(if $net=="grpc" and $path=="" then $service_name else $path end),tls:$tls,sni:$sni,alpn:$alpn}
        | if $service_name != "" then . + {serviceName:$service_name} else . end')
      vmess_b64=$(printf '%s' "$vmess_json" | base64 -w0 2>/dev/null)
      uri="vmess://${vmess_b64}" ;;
    vless-reality)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(uri_encode "$(jq -r .target <<<"$meta")")&fp=chrome&pbk=$(uri_encode "$(jq -r .public_key <<<"$meta")")&sid=$(uri_encode "$(jq -r .short_id <<<"$meta")")&spx=%2F&type=tcp#$(uri_encode "$name")" ;;
    vless-tls)
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$(uri_encode "$sni_host")&fp=chrome&type=tcp#$(uri_encode "$name")" ;;
    vless-ws)
      local vless_path
      vless_path=$(jq -r '.path//"/ws"' <<<"$meta")
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&security=tls&sni=$(uri_encode "$sni_host")&fp=chrome&type=ws&path=$(uri_encode "$vless_path")&host=$(uri_encode "$host")#$(uri_encode "$name")" ;;
    vless-grpc)
      local vless_service
      vless_service=$(jq -r '.service_name//"TunService"' <<<"$meta")
      uri="vless://$(jq -r .uuid <<<"$meta")@$host:$port?encryption=none&security=tls&sni=$(uri_encode "$sni_host")&fp=chrome&type=grpc&serviceName=$(uri_encode "$vless_service")#$(uri_encode "$name")" ;;
    hysteria2)
      local obfs_type obfs_pw obfs_str min_pkt max_pkt pkt_str
      obfs_type=$(jq -r '.obfs_type//""' <<<"$meta"); obfs_pw=$(jq -r '.obfs_password//""' <<<"$meta")
      min_pkt=$(jq -r '.min_packet_size//empty' <<<"$meta"); max_pkt=$(jq -r '.max_packet_size//empty' <<<"$meta")
      obfs_str=""; [ -n "$obfs_type" ] && obfs_str="&obfs=$(uri_encode "$obfs_type")&obfs-password=$(uri_encode "$obfs_pw")"
      pkt_str=""; [ -n "$min_pkt" ] && pkt_str="${pkt_str}&min_packet_size=${min_pkt}"
      [ -n "$max_pkt" ] && pkt_str="${pkt_str}&max_packet_size=${max_pkt}"
      if [ -n "$hopping" ]; then
        uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$hopping/?sni=$(uri_encode "$sni_host")${obfs_str}${pkt_str}#$(uri_encode "$name")"
      else
        uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port/?sni=$(uri_encode "$sni_host")${obfs_str}${pkt_str}#$(uri_encode "$name")"
      fi ;;
    tuic)
      local tuic_cc
      tuic_cc=$(jq -r '.congestion_control//"bbr"' <<<"$meta")
      uri="tuic://$(jq -r .uuid <<<"$meta"):$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?congestion_control=$tuic_cc&alpn=h3&udp_relay_mode=native&sni=$(uri_encode "$sni_host")&allow_insecure=0#$(uri_encode "$name")" ;;
    trojan)
      uri="trojan://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?security=tls&sni=$(uri_encode "$sni_host")#$(uri_encode "$name")" ;;
    trojan-ws)
      local trojan_path
      trojan_path=$(jq -r '.path//"/ws"' <<<"$meta")
      uri="trojan://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?security=tls&sni=$(uri_encode "$sni_host")&type=ws&path=$(uri_encode "$trojan_path")&host=$(uri_encode "$host")#$(uri_encode "$name")" ;;
    trojan-grpc)
      local trojan_service
      trojan_service=$(jq -r '.service_name//"TunService"' <<<"$meta")
      uri="trojan://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?security=tls&sni=$(uri_encode "$sni_host")&type=grpc&serviceName=$(uri_encode "$trojan_service")#$(uri_encode "$name")" ;;
    anytls)
      local a_pw a_meta
      a_pw=$(jq -r .password <<<"$meta")
      a_meta=$(jq -r '.client_metadata//empty' <<<"$meta")
      uri="anytls://$(uri_encode "$a_pw")@$host:$port/?sni=$(uri_encode "$sni_host")&insecure=0"
      [ -n "$a_meta" ] && uri="${uri}&client_metadata=$(uri_encode "$a_meta")"
      uri="${uri}#$(uri_encode "$name")" ;;
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
  local raw=$1 rest tail authority port_spec token low high
  local scheme query userinfo host port ports decoded_ss ss_pad
  raw="${raw#"${raw%%[![:space:]]*}"}"; raw="${raw%"${raw##*[![:space:]]}"}"
  [[ "$raw" == *://* ]] || return 1
  scheme=$(printf '%s' "${raw%%://*}" | tr '[:upper:]' '[:lower:]')
  rest=${raw#*://}
  case $rest in *\#*) rest=${rest%%\#*} ;; esac
  query=""; case $rest in *\?*) query=${rest#*\?}; rest=${rest%%\?*} ;; esac
  if { [ "$scheme" = ss ] || [ "$scheme" = shadowsocks ]; } && [[ "$rest" != *@* ]]; then
    decoded_ss=$(printf '%s' "${rest%/}" | tr '_-' '/+')
    ss_pad=$(( (4 - ${#decoded_ss}%4) % 4 ))
    [ "$ss_pad" -gt 0 ] && decoded_ss="${decoded_ss}$(printf '%*s' "$ss_pad" '' | tr ' ' '=')"
    decoded_ss=$(printf '%s' "$decoded_ss" | base64 -d 2>/dev/null || true)
    [[ "$decoded_ss" == *@* ]] || return 1
    rest="$decoded_ss"
  fi
  userinfo=""
  if [[ "$rest" == *@* ]]; then
    userinfo="${rest%@*}"
    rest="${rest##*@}"
    rest="${rest%%/*}"
  elif [ "$scheme" != vmess ]; then
    rest="${rest%%/*}"
  fi
  port=443; ports=""
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
  [ -n "$host" ] || return 1
  if [ -n "$port_spec" ] && [ "$scheme" != hysteria2 ] && [ "$scheme" != hy2 ]; then
    is_pos_int "$port_spec" && [ "$port_spec" -le 65535 ] || return 1
    port=$port_spec
  elif [ "$scheme" = hysteria2 ] || [ "$scheme" = hy2 ]; then
    if [ -n "$port_spec" ]; then
      IFS=',' read -ra authority <<<"$port_spec"
      [ "${#authority[@]}" -gt 0 ] || return 1
      for token in "${authority[@]}"; do
        if is_pos_int "$token"; then
          [ "$token" -le 65535 ] || return 1
        elif [[ "$token" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]; then
          low=${token%-*}; high=${token#*-}
          [ "$low" -ge 1 ] && [ "$high" -le 65535 ] && [ "$low" -le "$high" ] || return 1
        else
          return 1
        fi
      done
      if [[ "$port_spec" == *-* || "$port_spec" == *,* ]]; then ports="$port_spec"; else port="$port_spec"; fi
    fi
  fi
  jq -n --arg scheme "$scheme" --arg query "$query" --arg userinfo "$userinfo" \
        --arg host "$host" --argjson port "$port" --arg ports "$ports" \
        '{scheme:$scheme,query:$query,userinfo:$userinfo,host:$host,port:$port,ports:$ports}'
}

query_value(){
  local context=$1 key=$2 pair pairs query
  query=$(jq -r '.query//""' <<<"$context")
  IFS='&' read -ra pairs <<<"$query"
  for pair in "${pairs[@]}"; do
    [[ "$pair" == *=* ]] && [ "${pair%%=*}" = "$key" ] && { uri_decode "${pair#*=}"; return 0; }
  done
  return 0
}

uri_to_outbound(){
  local tag=$1 context=$2 outbound sni fingerprint insecure security network path vhost service
  local username password congestion alpn obfs_type obfs_pw hop_range flow udp_mode
  local disable_parrot s_mode min_pkt max_pkt raw_userinfo decoded_userinfo s_ver
  sni=$(query_value "$context" sni); [ -n "$sni" ] || sni=$(query_value "$context" peer); [ -n "$sni" ] || sni=$(jq -r .host <<<"$context")
  fingerprint=$(query_value "$context" fp); [ -n "$fingerprint" ] || fingerprint=chrome
  insecure=$(query_value "$context" insecure); [ -n "$insecure" ] || insecure=$(query_value "$context" allowInsecure); [ -n "$insecure" ] || insecure=$(query_value "$context" allow_insecure)
  raw_userinfo=$(jq -r .userinfo <<<"$context")
  case $(jq -r .scheme <<<"$context") in
    ss|shadowsocks)
      local ss_method ss_password plugin_opts ss_plain ss_decoded ss_pad plugin_raw plugin_name
      ss_plain="$raw_userinfo"
      if [[ "$ss_plain" == *:* ]]; then
        ss_method=$(uri_decode "${ss_plain%%:*}")
        ss_password=$(uri_decode "${ss_plain#*:}")
      else
        ss_decoded=$(uri_decode "$ss_plain"); ss_decoded=$(printf '%s' "$ss_decoded" | tr '_-' '/+')
        ss_pad=$(( (4 - ${#ss_decoded}%4) % 4 ))
        [ "$ss_pad" -gt 0 ] && ss_decoded="${ss_decoded}$(printf '%*s' "$ss_pad" '' | tr ' ' '=')"
        ss_decoded=$(printf '%s' "$ss_decoded" | base64 -d 2>/dev/null || true)
        [[ "$ss_decoded" == *:* ]] || return 1
        ss_method=${ss_decoded%%:*}; ss_password=${ss_decoded#*:}
      fi
      [ -n "$ss_method" ] && [ -n "$ss_password" ] || return 1
      plugin_raw=$(query_value "$context" plugin)
      plugin_name=""; plugin_opts=""
      if [ -n "$plugin_raw" ]; then
        plugin_name=${plugin_raw%%;*}
        plugin_opts=${plugin_raw#*;}
        [ "$plugin_name" = "$plugin_opts" ] && plugin_opts=""
      fi
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")"         --arg method "$ss_method" --arg password "$ss_password" --arg plugin "$plugin_name" --arg plugin_opts "$plugin_opts"         '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:$method,password:$password}
         | if $plugin!="" then .plugin=$plugin else . end
         | if $plugin_opts!="" then .plugin_opts=$plugin_opts else . end') ;;
    vmess)
      local vmess_security vmess_net vmess_path vmess_host vmess_service vmess_raw vmess_json vmess_server vmess_port vmess_uuid vmess_pad vmess_sni vmess_fp vmess_encryption vmess_aid vmess_fp_json vmess_alpn vmess_insecure vmess_tls_value
      if [ -n "$raw_userinfo" ]; then
        vmess_server=$(jq -r .host <<<"$context"); vmess_port=$(jq -r .port <<<"$context"); vmess_uuid=$(uri_decode "$raw_userinfo")
        vmess_net=$(query_value "$context" type); [ -n "$vmess_net" ] || vmess_net=tcp
        vmess_encryption=$(query_value "$context" encryption); [ -n "$vmess_encryption" ] || vmess_encryption=auto
        vmess_security=$(query_value "$context" security); [ -n "$vmess_security" ] || vmess_security=none
        vmess_path=$(query_value "$context" path); vmess_host=$(query_value "$context" host); vmess_service=$(query_value "$context" serviceName)
        vmess_sni=$(query_value "$context" sni); [ -n "$vmess_sni" ] || vmess_sni="$vmess_server"
        vmess_fp=$(query_value "$context" fp); [ -n "$vmess_fp" ] || vmess_fp=chrome
        case "$vmess_encryption" in auto|aes-128-gcm|chacha20-poly1305|none|zero) ;; *) return 1 ;; esac
        case "$vmess_net" in tcp|ws|grpc|http|h2) ;; *) return 1 ;; esac
        outbound=$(jq -n --arg tag "$tag" --arg server "$vmess_server" --argjson port "$vmess_port"           --arg uuid "$vmess_uuid" --arg encryption "$vmess_encryption"           '{type:"vmess",tag:$tag,server:$server,server_port:$port,uuid:$uuid,security:$encryption,alter_id:0,packet_encoding:"xudp"}')
        case "$vmess_net" in
          ws) outbound=$(jq --arg path "${vmess_path:-/}" --arg host "$vmess_host" '.transport=({type:"ws",path:$path}+(if $host!="" then {headers:{Host:$host}} else {} end))' <<<"$outbound") ;;
          grpc) outbound=$(jq --arg svc "$vmess_service" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
          http|h2) outbound=$(jq --arg path "${vmess_path:-/}" --arg host "$vmess_host" '.transport={type:"http",path:$path} | if $host!="" then .transport.host=[$host] else . end' <<<"$outbound") ;;
        esac
        if [ "$vmess_security" = tls ]; then
          outbound=$(jq --arg sni "$vmess_sni" --arg fp "$vmess_fp" '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp}}' <<<"$outbound")
        elif [ "$vmess_security" != none ]; then
          return 1
        fi
      else
        vmess_raw=$(jq -r .host <<<"$context")
        vmess_raw=$(printf '%s' "$vmess_raw" | tr '_-' '/+')
        vmess_pad=$(( (4 - ${#vmess_raw}%4) % 4 ))
        [ "$vmess_pad" -gt 0 ] && vmess_raw="${vmess_raw}$(printf '%*s' "$vmess_pad" '' | tr ' ' '=')"
        vmess_json=$(printf '%s' "$vmess_raw" | base64 -d 2>/dev/null || true)
        jq -e 'type=="object"' <<<"$vmess_json" >/dev/null 2>&1 || return 1
        vmess_server=$(trim_host "$(jq -r '.add // empty' <<<"$vmess_json")"); vmess_port=$(jq -r '.port // 443' <<<"$vmess_json"); vmess_uuid=$(jq -r '.id // empty' <<<"$vmess_json")
        is_pos_int "$vmess_port" && [ "$vmess_port" -le 65535 ] || return 1
        sni=$(trim_host "$(jq -r 'if (.sni // "") != "" then .sni elif (.host // "") != "" then .host else "" end' <<<"$vmess_json")"); [ -z "$sni" ] && sni="$vmess_server"
        [ -n "$vmess_server" ] && [ -n "$vmess_uuid" ] || return 1
        vmess_security=$(jq -r '.scy // "auto"' <<<"$vmess_json"); [ -z "$vmess_security" ] && vmess_security="auto"; case "$vmess_security" in auto|none|zero|aes-128-gcm|chacha20-poly1305|aes-128-ctr) ;; *) return 1 ;; esac
        vmess_net=$(jq -r 'if (.net // "") == "" then "tcp" else .net end' <<<"$vmess_json"); vmess_path=$(jq -r '.path // ""' <<<"$vmess_json"); vmess_host=$(jq -r '.host // ""' <<<"$vmess_json"); vmess_service=$(jq -r 'if (.serviceName // "") != "" then .serviceName else (.path // "") end' <<<"$vmess_json")
        case "$vmess_net" in tcp|ws|grpc|http|h2) ;; *) return 1 ;; esac
        vmess_aid=$(jq -r '((.aid // .alterId // 0) | if . == "" or . == null then 0 else (try tonumber catch 0) end | floor | if . < 0 then 0 else . end)' <<<"$vmess_json" 2>/dev/null)
is_uint "$vmess_aid" || vmess_aid=0
         vmess_fp_json=$(jq -r '(.tls | if type == "object" then .fingerprint else null end) // .fp // empty' <<<"$vmess_json")
         vmess_alpn=$(jq -r '((.tls | if type == "object" then .alpn else null end) // .alpn // empty) | if type == "array" then join(",") else tostring end' <<<"$vmess_json")
         vmess_insecure=$(jq -r '(.tls | if type == "object" then .insecure else null end) // .insecure // false' <<<"$vmess_json")
        case "$vmess_insecure" in true|1) vmess_insecure=true ;; *) vmess_insecure=false ;; esac
        outbound=$(jq -n --arg tag "$tag" --arg server "$vmess_server" --argjson port "$vmess_port"           --arg uuid "$vmess_uuid" --arg security "$vmess_security"           --argjson aid "$vmess_aid"           '{type:"vmess",tag:$tag,server:$server,server_port:$port,uuid:$uuid,security:$security,alter_id:$aid,packet_encoding:"xudp"}')
        case "$vmess_net" in
          ws) outbound=$(jq --arg path "${vmess_path:-/}" --arg host "$vmess_host" '.transport=({type:"ws",path:$path}+(if $host!="" then {headers:{Host:$host}} else {} end))' <<<"$outbound") ;;
          grpc) outbound=$(jq --arg svc "$vmess_service" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
          http|h2) outbound=$(jq --arg path "${vmess_path:-/}" --arg host "$vmess_host" '.transport={type:"http",path:$path} | if $host!="" then .transport.host=[$host] else . end' <<<"$outbound") ;;
        esac
        vmess_tls_value=$(jq -r 'if (.tls|type)=="object" then (if .tls.enabled==false then "" else "tls" end) else (.tls // "") end' <<<"$vmess_json")
        case "$vmess_tls_value" in
          tls|true)
            outbound=$(jq --arg sni "$sni" --arg fp "$vmess_fp_json" --argjson insecure "$vmess_insecure"               '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:(if $fp != "" then $fp else "chrome" end)},insecure:$insecure}' <<<"$outbound")
            [ -n "$vmess_alpn" ] && outbound=$(jq --arg alpn "$vmess_alpn" '($alpn|split(",")|map(select(length>0))) as $a | if ($a|length)>0 then .tls.alpn=$a else . end' <<<"$outbound") 2>/dev/null || true
            ;;
        esac
      fi
      ;;
    vless)
      security=$(query_value "$context" security); network=$(query_value "$context" type)
      path=$(query_value "$context" path); vhost=$(query_value "$context" host); service=$(query_value "$context" serviceName)
      flow=$(query_value "$context" flow)
      [ "$flow" = "xtls-rprx-vision-udp443" ] && flow="xtls-rprx-vision"
      [ -z "$flow" ] || [ "$flow" = "xtls-rprx-vision" ] || return 1
      if [ -n "$flow" ] && [ -n "$network" ] && [ "$network" != "tcp" ]; then
        tell_warn "flow=xtls-rprx-vision 仅支持 TCP 传输，不支持 $network" >&2
        return 1
      fi
      decoded_userinfo=$(uri_decode "$raw_userinfo")
      [ -n "$decoded_userinfo" ] || return 1
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" --arg uuid "$decoded_userinfo"         '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,packet_encoding:"xudp"}')
      [ -n "$flow" ] && outbound=$(jq --arg f "$flow" '.flow=$f' <<<"$outbound")
      if [ "$security" = reality ]; then
        local pbk sid_val
        pbk=$(query_value "$context" pbk); sid_val=$(query_value "$context" sid)
        [ -n "$pbk" ] || { tell_warn "VLESS-Reality 缺少 pbk 参数" >&2; return 1; }
        outbound=$(jq --arg sni "$sni" --arg fp "$fingerprint" --arg pbk "$pbk" --arg sid "$sid_val"           '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp},reality:{enabled:true,public_key:$pbk,short_id:$sid}}' <<<"$outbound")
      elif [ "$security" = tls ] || [ "$security" = xtls ]; then
        outbound=$(jq --arg sni "$sni" --arg fp "$fingerprint"           '.tls={enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp}}' <<<"$outbound")
      fi
      case $network in
        ""|tcp) ;;
        ws) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost"               '.transport=({type:"ws",path:$path}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound") ;;
        grpc) outbound=$(jq --arg svc "$service" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
        httpupgrade)
          [ -n "$vhost" ] || { tell_warn "HTTPUpgrade 缺少 host 参数" >&2; return 1; }
          outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport={type:"httpupgrade",path:$path,host:$host}' <<<"$outbound") ;;
        *) return 1 ;;
      esac ;;
    hysteria2|hy2)
      local up_mbps down_mbps port_tokens legacy_ports
      decoded_userinfo=$(uri_decode "$raw_userinfo")
      [ -n "$decoded_userinfo" ] || return 1
      if [ -n "$(jq -r .ports <<<"$context")" ]; then
        local server_ports=() token
        IFS=',' read -ra port_tokens <<<"$(jq -r .ports <<<"$context")"
        for token in "${port_tokens[@]}"; do
          if [[ "$token" == *-* ]]; then
            server_ports+=("${token//-/:}")
          else
            server_ports+=("${token}:${token}")
          fi
        done
        outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --arg password "$decoded_userinfo" --arg sni "$sni" --args           '{type:"hysteria2",tag:$tag,server:$server,password:$password,server_ports:$ARGS.positional,tls:{enabled:true,server_name:$sni,alpn:["h3"]}}' -- "${server_ports[@]}")
      else
        outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")"                          --arg password "$decoded_userinfo" --arg sni "$sni"           '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,
            tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      fi
      obfs_pw=$(query_value "$context" obfs-password); obfs_type=$(query_value "$context" obfs)
      obfs_type=$(printf '%s' "$obfs_type" | tr '[:upper:]' '[:lower:]')
      [ "$obfs_type" = none ] && { obfs_type=""; obfs_pw=""; }
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
        is_uint "${up_mbps:-0}" && is_uint "${down_mbps:-0}" || return 1
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
          if is_pos_int "$token"; then
            [ "$token" -le 65535 ] || return 1
            legacy_server_ports+=("${token}:${token}")
          elif [[ "$token" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]; then
            low=${token%-*}; high=${token#*-}
            [ "$low" -ge 1 ] && [ "$high" -le 65535 ] && [ "$low" -le "$high" ] || return 1
            legacy_server_ports+=("${token//-/:}")
          else
            return 1
          fi
        done
        outbound=$(jq '.server_ports=$ARGS.positional|del(.server_port)|.hop_interval="30s"' <<<"$outbound" --args -- "${legacy_server_ports[@]}")
      elif [ -n "$(jq -r .ports <<<"$context")" ]; then
        outbound=$(jq '.hop_interval="30s"' <<<"$outbound")
      fi
      min_pkt=$(query_value "$context" min_packet_size); max_pkt=$(query_value "$context" max_packet_size)
      if [ -n "$min_pkt" ] || [ -n "$max_pkt" ]; then
        [ "$obfs_type" = gecko ] || return 1
        min_pkt=${min_pkt:-512}; max_pkt=${max_pkt:-1200}
        is_pos_int "$min_pkt" && is_pos_int "$max_pkt" || return 1
        [ "$min_pkt" -ge 512 ] && [ "$max_pkt" -le 2048 ] && [ "$max_pkt" -ge "$min_pkt" ] || return 1
        outbound=$(jq --arg mn "$min_pkt" --arg mx "$max_pkt"           '.obfs.min_packet_size=($mn|tonumber) | .obfs.max_packet_size=($mx|tonumber)' <<<"$outbound")
      fi ;;
    tuic)
      local uri_userinfo; uri_userinfo="$raw_userinfo"; username=${uri_userinfo%%:*}; password=${uri_userinfo#*:}
      [ -n "$username" ] || return 1
      if [ "$password" = "$uri_userinfo" ]; then
        username=$(uri_decode "$uri_userinfo"); password=""
      else
        username=$(uri_decode "$username"); password=$(uri_decode "$password")
      fi
      congestion=$(query_value "$context" congestion_control); [ -n "$congestion" ] || congestion=bbr
      case "$congestion" in cubic|new_reno|bbr) ;; *) return 1 ;; esac
      udp_mode=$(query_value "$context" udp_relay_mode); [ -n "$udp_mode" ] || udp_mode=native
      case "$udp_mode" in native|quic) ;; *) return 1 ;; esac
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")"                        --arg uuid "$username" --arg password "$password" --arg cc "$congestion"                        --arg sni "$sni" --arg udp_mode "$udp_mode"         '{type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$password,
          congestion_control:$cc,udp_relay_mode:$udp_mode,
          tls:{enabled:true,server_name:$sni,alpn:["h3"]}}') ;;
    trojan)
      decoded_userinfo=$(uri_decode "$raw_userinfo")
      [ -n "$decoded_userinfo" ] || return 1
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")"                        --arg password "$decoded_userinfo" --arg sni "$sni" --arg fp "$fingerprint"         '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password,
          tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp}}}')
      case "$(query_value "$context" type)" in
        ""|tcp) ;;
        ws) outbound=$(jq --arg path "$(query_value "$context" path)" --arg host "$(query_value "$context" host)"           '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound") ;;
        grpc) outbound=$(jq --arg svc "$(query_value "$context" serviceName)" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound") ;;
        *) return 1 ;;
      esac ;;
    anytls)
      local a_meta
      a_meta=$(query_value "$context" client_metadata)
      decoded_userinfo=$(uri_decode "$raw_userinfo")
      [ -n "$decoded_userinfo" ] || return 1
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")"                        --arg password "$decoded_userinfo" --arg sni "$sni" --arg fp "$fingerprint"         '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:$fp}}}')
      [ -n "$a_meta" ] && outbound=$(jq --arg cm "$a_meta" '.client_metadata=$cm' <<<"$outbound") ;;
    socks5|socks)
      local uri_userinfo; uri_userinfo="$raw_userinfo"; username=${uri_userinfo%%:*}; password=${uri_userinfo#*:}
      if [ "$password" = "$uri_userinfo" ]; then
        username=$(uri_decode "$uri_userinfo"); password=""
      else
        username=$(uri_decode "$username"); password=$(uri_decode "$password")
      fi
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")"                        --arg user "$username" --arg pass "$password"         '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}
         |(if $user!="" then .username=$user else . end)
         |(if $pass!="" then .password=$pass else . end)') ;;
    snell)
      s_mode=$(query_value "$context" mode); [ -n "$s_mode" ] || s_mode=default
      case "$s_mode" in default|unshaped|unsafe-raw) ;; *) return 1 ;; esac
      s_ver=$(query_value "$context" version); [ -n "$s_ver" ] || s_ver=6
      [ "$s_ver" = 6 ] || return 1
      decoded_userinfo=$(uri_decode "$raw_userinfo")
      [ "${#decoded_userinfo}" -ge 12 ] && [ "${#decoded_userinfo}" -le 255 ] || return 1
      outbound=$(jq -n --arg tag "$tag" --arg server "$(jq -r .host <<<"$context")" --argjson port "$(jq -r .port <<<"$context")" \
        --arg psk "$decoded_userinfo" --arg mode "$s_mode" \
        '{type:"snell",tag:$tag,server:$server,server_port:$port,version:6,psk:$psk,mode:$mode}') ;;
    *) return 1 ;;
  esac
  if [ "$insecure" = 1 ] || [ "$insecure" = true ]; then outbound=$(jq 'if .tls then .tls.insecure=true else . end' <<<"$outbound"); fi
  alpn=$(query_value "$context" alpn)
  [ -n "$alpn" ] && outbound=$(jq --arg alpn "$alpn" 'if .tls then ($alpn|split(",")|map(select(length>0))) as $a | if ($a|length)>0 then .tls.alpn=$a else . end else . end' <<<"$outbound")
  printf '%s' "$outbound"
}

wg_nat_state_file(){ printf '%s/nat-state.json' "$WG_DIR"; }

wg_nat_state_read(){
  local key=$1 file
  file=$(wg_nat_state_file)
  [ -f "$file" ] || return 1
  jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null
}

wg_server_nat_remove(){
  local prev4 prev6 rc=0 nat_state legacy4 legacy6 owned=0
  nat_state=$(wg_nat_state_file)
  if [ -f "$nat_state" ]; then
    owned=1
    prev4=$(wg_nat_state_read ipv4_forward 2>/dev/null)
    prev6=$(wg_nat_state_read ipv6_forward 2>/dev/null)
    [[ "$prev4" =~ ^[01]$ ]] && [[ "$prev6" =~ ^[01]$ ]] || return 1
  else
    legacy4=$(jq -r '.nat_prev_ipv4_forward // empty' "$WG_CONF" 2>/dev/null)
    legacy6=$(jq -r '.nat_prev_ipv6_forward // empty' "$WG_CONF" 2>/dev/null)
    if [[ "$legacy4" =~ ^[01]$ ]] && [[ "$legacy6" =~ ^[01]$ ]]; then
      prev4=$legacy4; prev6=$legacy6; owned=1
    fi
  fi
  nft delete table ip sbm_nat 2>/dev/null || true
  nft delete table ip6 sbm_nat 2>/dev/null || true
  if [ "$owned" -eq 1 ]; then
    sysctl -w net.ipv4.ip_forward="$prev4" >/dev/null 2>&1 || rc=1
    [ -w /proc/sys/net/ipv6/conf/all/forwarding ] && { sysctl -w net.ipv6.conf.all.forwarding="$prev6" >/dev/null 2>&1 || rc=1; }
    if [ -f /etc/sysctl.d/99-sbm-forward.conf.sbm-backup ]; then
      mv -f /etc/sysctl.d/99-sbm-forward.conf.sbm-backup /etc/sysctl.d/99-sbm-forward.conf || rc=1
    else
      rm -f /etc/sysctl.d/99-sbm-forward.conf || rc=1
    fi
    [ "$rc" -ne 0 ] || rm -f "$nat_state" "${nat_state}.nft4" "${nat_state}.nft6"
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
  local resolver=$1 role dr_json
  [ -f "$WG_CONF" ] || { printf '%s' '[]'; return 0; }
  role=$(wg_config_role)
  if [ "$role" = client ] && [ -z "$NET_IPV4" ] && [ -n "$NET_IF_V6" ] && [ "$IPV6_OK" = 1 ]; then
    dr_json=$(jq -n --arg s "$resolver" '{server:$s,strategy:"ipv6_only"}')
  elif [ "$role" = client ] && [ -n "$NET_IPV4" ] && [ "$IPV6_OK" != 1 ]; then
    dr_json=$(jq -n --arg s "$resolver" '{server:$s,strategy:"ipv4_only"}')
  else
    dr_json=$(jq -n --arg s "$resolver" '$s')
  fi
  jq --argjson dr "$dr_json" '[.endpoint | .system = false | del(.name) | .domain_resolver = $dr]' "$WG_CONF"
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
  local peer_ip4=$1 peer_ip6=$2 out ms probed=0
  systemctl is-active --quiet sing-box && ip link show "$TUN_IF" >/dev/null 2>&1 && jq -e '.endpoints[]? | select(.tag=="wireguard")' "$CONFIG" >/dev/null 2>&1 || { echo disconnected; return; }
  if [ -n "$peer_ip6" ]; then
    probed=1
    out=$(ping -6 -c 1 -W 2 "$peer_ip6" 2>/dev/null)
    if [ $? -eq 0 ]; then
      ms=$(awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}' <<<"$out")
      [[ "$ms" =~ ^[0-9]+$ ]] && { printf 'ok|%s\n' "$ms"; return; }
    fi
  fi
  if [ -n "$peer_ip4" ]; then
    probed=1
    out=$(ping -4 -c 1 -W 2 "$peer_ip4" 2>/dev/null)
    if [ $? -eq 0 ]; then
      ms=$(awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}' <<<"$out")
      [[ "$ms" =~ ^[0-9]+$ ]] && { printf 'ok|%s\n' "$ms"; return; }
    fi
  fi
  [ "$probed" -eq 1 ] && echo unreachable || echo unknown
}

wg_actual_listen_port(){
  local configured=${1:-}
  systemctl is-active --quiet sing-box || { printf '%s' ""; return; }
  [[ "$configured" =~ ^[1-9][0-9]*$ ]] || return 0
  ss -Hlunp 2>/dev/null | awk -v p=":$configured" '$4 ~ (p"$") && /users:\(\("sing-box"/ {found=1} END{if(found) print p}' | sed 's/^://'
}

wg_keypair(){
  local keypair private public
  keypair=$("$CORE" generate wg-keypair 2>/dev/null) || return 1
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] && [ -n "$public" ] || return 1
  printf '%s|%s\n' "$private" "$public"
}

wg_default_address(){
  if [ "$1" = server ]; then
    printf '%s|%s\n' '10.10.0.1/24' 'fd00:10::1/64'
  else
    printf '%s|%s|%s|%s\n' '10.10.0.2/24' 'fd00:10::2/64' '10.10.0.1/24' 'fd00:10::1/64'
  fi
}

wg_valid_address(){
  local value=$1 prefix ip octet
  [[ $value == */* ]] || return 1
  ip=${value%/*}; prefix=${value#*/}
  is_pos_int "$prefix" || return 1
  if [[ $ip == *:* ]]; then
    [ "$prefix" -le 128 ] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    getent ahostsv6 "$ip" >/dev/null 2>&1
  else
    [ "$prefix" -le 32 ] || return 1
    [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
    IFS=. read -r -a octet <<<"$ip"
    for value in "${octet[@]}"; do
      [ "$value" -le 255 ] || return 1
    done
  fi
}

wg_valid_pubkey(){
  local k=$1
  [[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]] && [ "$(printf '%s' "$k" | base64 -d 2>/dev/null | wc -c)" -eq 32 ]
}

wg_prompt_address(){
local current4 current6 value edit4 edit6
  current4=$(jq -r '.address[0] // ""' "$WG_CONF")
  current6=$(jq -r '.address[1] // ""' "$WG_CONF")
  while :; do
    value=$(prompt "IPv4" "$current4")
    wg_valid_address "$value" || { tell_warn "IPv4 地址无效" >&2; continue; }
    [[ "$value" != *:*/* ]] || { tell_warn "IPv4 地址无效" >&2; continue; }
    edit4="$value"
    break
  done
  while :; do
    value=$(prompt "IPv6" "$current6")
    [[ $value == *:*/* ]] || { tell_warn "IPv6 地址无效" >&2; continue; }
    wg_valid_address "$value" || { tell_warn "IPv6 地址无效" >&2; continue; }
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
  mkdir -p "$WG_DIR" && chmod 700 "$WG_DIR" || return 1
  [ -f "$WG_CONF" ] || return 0
  role=$(wg_config_role) || return 1
  enabled=$(wg_config_enabled && printf true || printf false) || return 1
  previous=$(state_get exit) || return 1
  ip link del "$WG_IF" 2>/dev/null || true
  ! ip link show "$WG_IF" >/dev/null 2>&1 || return 1
  if [ "$role" = server ] && [ "$enabled" = true ]; then
    wg_server_nat_remove || return 1
  fi
  if [ "$previous" = wireguard ]; then
    state_set exit direct || return 1
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
  apply_config_quiet || return 1
  return 0
}

wg_status(){
  local file=$WG_CONF role enabled public ipv4 ipv6 peer_host peer_host_display peer_port peer_key endpoint_ips
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
      if [ "$enabled" = true ] && { systemctl is-active --quiet sing-box && ip link show "$TUN_IF" >/dev/null 2>&1 && jq -e '.endpoints[]? | select(.tag=="wireguard")' "$CONFIG" >/dev/null 2>&1; }; then
        state=$(wg_tunnel_state "$(jq -r '.peer_ip // empty' "$file" 2>/dev/null)" "$(jq -r '.peer_ip6 // empty' "$file" 2>/dev/null)")
        if [[ "$state" == ok\|* ]]; then
          tell "运行模式：客户端 状态：${GREEN}已连接${PLAIN}"
        elif [ "$state" = unknown ]; then
          tell "运行模式：客户端 状态：${YELLOW}无法探测${PLAIN}"
        else
          tell "运行模式：客户端 状态：${YELLOW}探测失败${PLAIN}"
        fi
      elif [ "$enabled" = true ]; then
        tell "运行模式：客户端 状态：${RED}异常${PLAIN}"
      else
        tell "运行模式：客户端 状态：${YELLOW}已停止${PLAIN}"
      fi
      tell "接口模式：用户态 (wireguard)"
      tell "隧道 IPv4：$ipv4"
      tell "隧道 IPv6：$ipv6"
      tell ""
      peer_host=$(jq -r '.peer_host // empty' "$file" 2>/dev/null)
      peer_host_display="$peer_host"; [[ "$peer_host_display" == *:* ]] && peer_host_display="[${peer_host_display}]"
      peer_port=$(jq -r '.peer_port // empty' "$file" 2>/dev/null)
      peer_key=$(jq -r '.peer_public_key // empty' "$file" 2>/dev/null)
      tell "服务器：${peer_host_display}:${peer_port}"
      ms=${state#*|}
      if [[ "$state" == ok\|* ]] && [[ "$ms" =~ ^[0-9]+$ ]]; then
        if [ "$ms" -lt 100 ]; then color="$GREEN"; elif [ "$ms" -lt 150 ]; then color="$YELLOW"; else color="$BROWN"; fi
        tell "服务器延迟：${color}${ms} ms${PLAIN}"
      elif [ "$state" = unknown ]; then
        tell "服务器延迟：${YELLOW}无法探测${PLAIN}"
      else
        tell "服务器延迟：${YELLOW}探测失败${PLAIN}"
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
      if [ "$enabled" = true ] && systemctl is-active --quiet sing-box && [ -n "$(wg_actual_listen_port "$(jq -r '.listen_port // 0' "$WG_CONF" 2>/dev/null)")" ]; then
        tell "运行模式：服务端 状态：${GREEN}运行中${PLAIN}"
      elif [ "$enabled" = true ]; then
        tell "运行模式：服务端 状态：${RED}异常${PLAIN}"
      else
        tell "运行模式：服务端 状态：${YELLOW}已停止${PLAIN}"
      fi
      tell "接口模式：用户态 (wireguard)"
      tell "隧道 IPv4：$ipv4"
      tell "隧道 IPv6：$ipv6"
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
    --argjson port "$port" \
    '{role:"server",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:$port,clients:[],
      endpoint:{type:"wireguard",tag:"wireguard",system:false,mtu:1408,
        address:[$a4,$a6],private_key:$private,listen_port:$port,peers:[]}}'
}

wg_build_client_config(){
  local private=$1 public=$2 ipv4=$3 ipv6=$4 peer4=$5 peer6=$6 host=$7 peer_key=$8 port=$9
  jq -n \
    --arg private "$private" --arg public "$public" \
    --arg a4 "$ipv4" --arg a6 "$ipv6" \
    --arg peer4 "$peer4" --arg peer6 "$peer6" \
    --arg host "$host" --arg peer_key "$peer_key" --argjson port "$port" \
    '{role:"client",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:0,
      peer_public_key:$peer_key,peer_ip:$peer4,peer_ip6:$peer6,peer_host:$host,peer_port:$port,
      endpoint:{type:"wireguard",tag:"wireguard",system:false,mtu:1408,
        address:[$a4,$a6],private_key:$private,
        peers:[{address:$host,port:$port,public_key:$peer_key,persistent_keepalive_interval:25,
          allowed_ips:["0.0.0.0/0","::/0"]}]}}'
}

wg_init_server(){
  local port body backup_wg previous_exit value private public ipv4 ipv6 cur_wg_port=""
  ui_title "WireGuard 服务端引导配置"
  local keypair
  keypair=$(wg_keypair) || { tell_warn "密钥生成失败"; wait_key; return; }
  private=${keypair%%|*}; public=${keypair#*|}
  [ "$(wg_config_role)" = server ] && cur_wg_port=$(wg_config_listen_port)
  port=$(prompt_port u "$cur_wg_port" "${cur_wg_port:-51820}") || return
  IFS='|' read -r ipv4 ipv6 <<<"$(wg_default_address server)"
  while :; do
    value=$(prompt "隧道 IPv4" "$ipv4")
    { wg_valid_address "$value" && [[ "$value" != *:*/* ]]; } || { tell_warn "IPv4 地址无效"; continue; }
    ipv4="$value"; break
  done
  while :; do
    value=$(prompt "隧道 IPv6" "$ipv6")
    { wg_valid_address "$value" && [[ "$value" == *:*/* ]]; } || { tell_warn "IPv6 地址无效"; continue; }
    ipv6="$value"; break
  done
  body=$(wg_build_server_config "$private" "$public" "$ipv4" "$ipv6" "$port" | jq '.enabled=true') || { tell_warn "配置生成失败"; wait_key; return; }
  backup_wg=$(wg_backup_create) || { tell_warn "旧配置备份失败"; wait_key; return; }
  WG_BACKUP_DIR="$backup_wg"
  previous_exit=$(state_get exit) || { rm -rf "$backup_wg"; WG_BACKUP_DIR=""; tell_warn "出口状态读取失败"; wait_key; return; }
  if ! wg_reinit_prepare; then
    rm -rf "$backup_wg"; WG_BACKUP_DIR=""
    tell_warn "旧 WireGuard 接口清理失败"; wait_key; return
  fi
  if ! wg_config_apply_transaction "$body"; then
    wg_reinit_rollback "$backup_wg" "$previous_exit" || true
    rm -rf "$backup_wg"; WG_BACKUP_DIR=""
    tell_warn "服务端启动失败，已恢复旧配置"; wait_key; return
  fi
  rm -rf "$backup_wg"; WG_BACKUP_DIR=""
  tell_ok "服务端启动完成"
  wait_key
  wg_status
}

wg_init_client(){
  local host port peer_key body private public ipv4 ipv6 peer4 peer6 value
  ui_title "WireGuard 客户端"
  local keypair
  keypair=$(wg_keypair) || { tell_warn "密钥生成失败"; wait_key; return; }
  private=${keypair%%|*}; public=${keypair#*|}
  tell "本机公钥: $public"
  echo ""
  host=$(trim_host "$(prompt '服务端地址')")
  [ -n "$host" ] || { tell_warn "服务端地址不能为空"; wait_key; return; }
  while :; do
    port=$(prompt "远端端口" "51820")
    is_pos_int "$port" && [ "$port" -le 65535 ] && break
    tell_warn "端口格式无效"
  done
  while :; do
    peer_key=$(prompt "服务端公钥")
    [ -n "$peer_key" ] && wg_valid_pubkey "$peer_key" && [ "$peer_key" != "$public" ] && break
    tell_warn "服务端公钥无效或与本机相同"
  done
  IFS='|' read -r ipv4 ipv6 peer4 peer6 <<<"$(wg_default_address client)"
  while :; do
    value=$(prompt "隧道内网 IPv4" "$ipv4")
    { wg_valid_address "$value" && [[ "$value" != *:*/* ]]; } && { ipv4="$value"; break; }
    tell_warn "IPv4 地址无效"
  done
  while :; do
    value=$(prompt "隧道内网 IPv6" "$ipv6")
    { wg_valid_address "$value" && [[ "$value" == *:*/* ]]; } && { ipv6="$value"; break; }
    tell_warn "IPv6 地址无效"
  done
  while :; do
    value=$(trim_host "$(prompt "服务端隧道 IPv4" "${peer4%/*}")"); value=${value%/*}; value=$(trim_host "$value")
    { [ -n "$value" ] && wg_valid_address "${value}/32" && [[ "$value" != *:* ]]; } || { tell_warn "服务端隧道 IPv4 地址无效"; continue; }
    [ "$value" != "${ipv4%/*}" ] || { tell_warn "服务端隧道 IPv4 不能与本机相同"; continue; }
    peer4="$value"; break
  done
  while :; do
    local self6_l=${ipv6%/*}; self6_l=${self6_l,,}
    value=$(trim_host "$(prompt "服务端隧道 IPv6" "${peer6%/*}")"); value=${value%/*}; value=$(trim_host "$value")
    { [ -n "$value" ] && wg_valid_address "${value}/128" && [[ "$value" == *:* ]]; } || { tell_warn "服务端隧道 IPv6 地址无效"; continue; }
    [ "${value,,}" != "$self6_l" ] || { tell_warn "服务端隧道 IPv6 不能与本机相同"; continue; }
    peer6="$value"; break
  done
  body=$(wg_build_client_config "$private" "$public" "$ipv4" "$ipv6" "$peer4" "$peer6" "$host" "$peer_key" "$port") || { tell_warn "配置生成失败"; wait_key; return; }
  local backup_wg previous_exit
  backup_wg=$(wg_backup_create) || { tell_warn "旧配置备份失败"; wait_key; return; }
  WG_BACKUP_DIR="$backup_wg"
  previous_exit=$(state_get exit) || { rm -rf "$backup_wg"; WG_BACKUP_DIR=""; tell_warn "出口状态读取失败"; wait_key; return; }
  if ! wg_reinit_prepare; then
    rm -rf "$backup_wg"; WG_BACKUP_DIR=""
    tell_warn "旧 WireGuard 接口清理失败"; wait_key; return
  fi
  if ! wg_config_apply_transaction "$body" true; then
    wg_reinit_rollback "$backup_wg" "$previous_exit" || true
    rm -rf "$backup_wg"; WG_BACKUP_DIR=""
    tell_warn "配置应用失败，已恢复旧配置"; wait_key; return
  fi
  rm -rf "$backup_wg"; WG_BACKUP_DIR=""
  tell_ok "配置完成"
  wait_key
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
  local body role edit4 edit6 ip4 ip6 peer4 peer6
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  ui_title "内网双栈地址"
  tell "IPv4: $(jq -r '.address[0] // ""' "$WG_CONF")"
  tell "IPv6: $(jq -r '.address[1] // ""' "$WG_CONF")"
  echo ""
  role=$(jq -r '.role // ""' "$WG_CONF")
  while :; do
    IFS='|' read -r edit4 edit6 <<<"$(wg_prompt_address)"
    ip4=${edit4%/*}; ip6=${edit6%/*}
    if [ "$role" = server ]; then
      if jq -e --arg ip "$ip4" 'any(.clients[]?; ((.ipv4 // "") | split("/")[0]) == $ip)' "$WG_CONF" >/dev/null 2>&1; then
        tell_warn "服务端 IPv4 与已有客户端冲突"; continue
      fi
      if jq -e --arg ip "$ip6" 'any(.clients[]?; ((.ipv6 // "") | split("/")[0] | ascii_downcase) == ($ip | ascii_downcase))' "$WG_CONF" >/dev/null 2>&1; then
        tell_warn "服务端 IPv6 与已有客户端冲突"; continue
      fi
    elif [ "$role" = client ]; then
      peer4=$(jq -r '.peer_ip // ""' "$WG_CONF"); peer6=$(jq -r '.peer_ip6 // ""' "$WG_CONF")
      [ -n "$peer4" ] && [ "$ip4" = "$peer4" ] && { tell_warn "本机 IPv4 与服务端隧道 IP 冲突"; continue; }
      [ -n "$peer6" ] && [ "${ip6,,}" = "${peer6,,}" ] && { tell_warn "本机 IPv6 与服务端隧道 IP 冲突"; continue; }
    fi
    break
  done
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
  local body=$1 force_apply=${2:-false} old_body apply_rc=0 had_old=0
  if [ -f "$WG_CONF" ]; then
    old_body=$(cat "$WG_CONF") || return 1
    had_old=1
  fi
  json_save "$WG_CONF" "$body" || return 1
  if wg_config_enabled || [ "$force_apply" = true ]; then
    apply_config || apply_rc=$?
    if [ "$apply_rc" -ne 0 ]; then
      if [ "$had_old" = 1 ]; then
        printf '%s\n' "$old_body" | json_write "$WG_CONF" || return 2
      else
        rm -f "$WG_CONF" || return 2
      fi
      [ "$apply_rc" -eq 2 ] && return 2
      return 1
    fi
  fi
  return 0
}

wg_server_client_apply(){
  local body=$1
  if ! wg_config_apply_transaction "$body"; then
    tell_warn "保存或应用失败，已恢复旧配置"
    return 1
  fi
  return 0
}

wg_server_client_delete_apply(){
  local body=$1
  json_save "$WG_CONF" "$body" || { tell_warn "客户端删除配置保存失败"; return 1; }
  if wg_config_enabled && ! apply_config; then
    tell_warn "客户端已删除，但 sing-box 配置应用失败"
    return 2
  fi
  return 0
}

wg_next_client_address(){
  local server4 server6 mask4 mask6 ip4 ip6 o1 o2 o3 o4 ip_int host_bits host_mask net_int bcast_int h scanned=0
  local used4 used6 cand4="" cand6="" base6 n cand_ip6 ip6_l c4 c6_l
  server4=$(jq -r '.address[0] // "10.10.0.1/24"' "$WG_CONF" 2>/dev/null)
  server6=$(jq -r '.address[1] // "fd00:10::1/64"' "$WG_CONF" 2>/dev/null)
  ip4=${server4%/*}; mask4=${server4#*/}
  ip6=${server6%/*}; mask6=${server6#*/}
  is_pos_int "$mask4" && [ "$mask4" -le 30 ] || return 1
  is_pos_int "$mask6" && [ "$mask6" -le 128 ] || return 1
  used4=$(jq -r '.clients[]?.ipv4 // empty' "$WG_CONF" 2>/dev/null | cut -d/ -f1)
  used6=$(jq -r '.clients[]?.ipv6 // empty' "$WG_CONF" 2>/dev/null | cut -d/ -f1 | tr '[:upper:]' '[:lower:]')
  IFS=. read -r o1 o2 o3 o4 <<<"$ip4"
  ip_int=$(( (o1<<24) | (o2<<16) | (o3<<8) | o4 ))
  host_bits=$((32 - mask4))
  if [ "$host_bits" -eq 31 ]; then host_mask=2147483647; else host_mask=$(( (1 << host_bits) - 1 )); fi
  net_int=$(( ip_int - (ip_int & host_mask) ))
  bcast_int=$(( net_int + host_mask ))
  for ((h=net_int+1; h<bcast_int && scanned<254; h++, scanned++)); do
    c4="$(( (h>>24)&255 )).$(( (h>>16)&255 )).$(( (h>>8)&255 )).$(( h&255 ))"
    [ "$c4" = "$ip4" ] && continue
    grep -Fqx "$c4" <<<"$used4" && continue
    cand4="$c4/$mask4"; break
  done
  [ -n "$cand4" ] || return 1
  ip6_l=$(printf '%s' "$ip6" | tr '[:upper:]' '[:lower:]')
  base6=${ip6%:*}
  for n in $(seq 2 254); do
    cand_ip6="$base6:$n"
    c6_l=$(printf '%s' "$cand_ip6" | tr '[:upper:]' '[:lower:]')
    [ "$c6_l" = "$ip6_l" ] && continue
    grep -Fqx "$c6_l" <<<"$used6" && continue
    cand6="$cand_ip6/$mask6"; break
  done
  [ -n "$cand6" ] || return 1
  printf '%s|%s\n' "$cand4" "$cand6"
}

wg_client_add(){
  local name ipv4 ipv6 pub body allowed4 allowed6 ip4 ip6 server4 server6 self_pub
  ui_title "添加客户端"
  name=$(prompt "客户端名称")
  [ -n "$name" ] || { tell_warn "客户端名称不能为空"; wait_key; return; }
  local next_addr next_ipv4 next_ipv6
next_addr=$(wg_next_client_address) || { tell_warn "没有可用的客户端隧道地址"; wait_key; return; }
IFS='|' read -r next_ipv4 next_ipv6 <<<"$next_addr"
  while :; do
    ipv4=$(prompt "隧道 IPv4" "$next_ipv4")
    { wg_valid_address "$ipv4" && [[ "$ipv4" != *:*/* ]]; } || { tell_warn "IPv4 地址无效"; continue; }
    ip4=${ipv4%/*}
    server4=$(jq -r '.address[0] // ""' "$WG_CONF" | cut -d/ -f1)
    [ -n "$server4" ] && [ "$ip4" = "$server4" ] && { tell_warn "客户端 IPv4 与服务端隧道 IP 冲突"; continue; }
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
    server6=$(jq -r '.address[1] // ""' "$WG_CONF" | cut -d/ -f1)
    [ -n "$server6" ] && [ "${ip6,,}" = "${server6,,}" ] && { tell_warn "客户端 IPv6 与服务端隧道 IP 冲突"; continue; }
    if jq -e --arg ip "$ip6" 'any(.clients[]?; ((.ipv6 // "") | split("/")[0] | ascii_downcase) == ($ip | ascii_downcase))' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "IPv6 地址已被其他客户端使用"
      continue
    fi
    break
  done
  self_pub=$(jq -r '.public_key // ""' "$WG_CONF")
  while :; do
    pub=$(prompt "客户端公钥")
    [ -n "$pub" ] && wg_valid_pubkey "$pub" && [ "$pub" != "$self_pub" ] || { tell_warn "客户端公钥无效或与本机相同"; continue; }
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
  local index count i row name ipv4 ipv6 pub value def4 def6 def_pub body ip4 ip6 server_ipv4 server_ipv6 self_pub
  count=$(jq '.endpoint.peers | length' "$WG_CONF" 2>/dev/null); count=${count:-0}
  [ "$count" -gt 0 ] || { tell_warn "暂无客户端"; wait_key; return; }
  while :; do
    ui_title "修改客户端"
    for ((i=0; i<count; i++)); do
      row=$(jq -r ".clients[$i] | \"\(.name) | \(.ipv4) | \(.ipv6)\"" "$WG_CONF" 2>/dev/null)
      menu_item "$((i+1))" "$row"
    done
    menu_item 0 "返回"
    index=$(prompt "请选择")
    [ "$index" = 0 ] && return
    if is_pos_int "$index" && [ "$index" -le "$count" ]; then
      index=$((index-1)); break
    fi
    tell_warn "输入无效，请重新选择"; sleep 1
  done
  name=$(prompt "客户端名称" "$(jq -r ".clients[$index].name // \"\"" "$WG_CONF")")
  server_ipv4=$(jq -r '.address[0] // ""' "$WG_CONF" | cut -d/ -f1)
  server_ipv6=$(jq -r '.address[1] // ""' "$WG_CONF" | cut -d/ -f1)
  self_pub=$(jq -r '.public_key // ""' "$WG_CONF")
  def4=$(jq -r ".clients[$index].ipv4 // \"\"" "$WG_CONF")
  while :; do
    value=$(prompt "隧道 IPv4" "$def4")
    { wg_valid_address "$value" && [[ "$value" != *:*/* ]]; } || { tell_warn "IPv4 地址无效"; continue; }
    ip4=${value%/*}
    [ -n "$server_ipv4" ] && [ "$ip4" = "$server_ipv4" ] && { tell_warn "客户端 IPv4 与服务端隧道 IP 冲突"; continue; }
    if jq -e --arg ip "$ip4" --argjson i "$index" 'any(.clients | to_entries[]; .key != $i and ((.value.ipv4 // "") | split("/")[0]) == $ip)' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "IPv4 地址已被其他客户端使用"; continue
    fi
    ipv4="$value"; break
  done
  def6=$(jq -r ".clients[$index].ipv6 // \"\"" "$WG_CONF")
  while :; do
    value=$(prompt "隧道 IPv6" "$def6")
    { wg_valid_address "$value" && [[ "$value" == *:*/* ]]; } || { tell_warn "IPv6 地址无效"; continue; }
    ip6=${value%/*}
    [ -n "$server_ipv6" ] && [ "${ip6,,}" = "${server_ipv6,,}" ] && { tell_warn "客户端 IPv6 与服务端隧道 IP 冲突"; continue; }
    if jq -e --arg ip "$ip6" --argjson i "$index" 'any(.clients | to_entries[]; .key != $i and ((.value.ipv6 // "") | split("/")[0] | ascii_downcase) == ($ip | ascii_downcase))' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "IPv6 地址已被其他客户端使用"; continue
    fi
    ipv6="$value"; break
  done
  def_pub=$(jq -r ".clients[$index].public_key // \"\"" "$WG_CONF")
  while :; do
    value=$(prompt "客户端公钥" "$def_pub")
    [ -n "$value" ] && wg_valid_pubkey "$value" && [ "$value" != "$self_pub" ] || { tell_warn "客户端公钥无效或与本机相同"; continue; }
    if jq -e --arg k "$value" --argjson i "$index" 'any(.endpoint.peers | to_entries[]; .key != $i and .value.public_key == $k)' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "客户端公钥已被其他客户端使用"; continue
    fi
    pub="$value"; break
  done
  body=$(jq --argjson i "$index" --arg name "$name" --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" --arg pub "$pub" --arg allowed4 "${ipv4%/*}/32" --arg allowed6 "${ipv6%/*}/128" \
    '.clients[$i]={name:$name,ipv4:$ipv4,ipv6:$ipv6,public_key:$pub} |
     .endpoint.peers[$i]={public_key:$pub,allowed_ips:[$allowed4,$allowed6]}' "$WG_CONF") || { tell_warn "配置生成失败"; wait_key; return; }
  wg_server_client_apply "$body" || { wait_key; return; }
  tell_ok "客户端修改完成"
  wait_key
}

wg_client_delete(){
  local index count i row body status
  while :; do
    count=$(jq '.endpoint.peers | length' "$WG_CONF" 2>/dev/null); count=${count:-0}
    [ "$count" -gt 0 ] || { tell_warn "暂无客户端"; wait_key; return; }
    ui_title "删除客户端"
    for ((i=0; i<count; i++)); do
      row=$(jq -r ".clients[$i] | \"\(.name) | \(.ipv4) | \(.ipv6)\"" "$WG_CONF" 2>/dev/null)
      menu_item "$((i+1))" "$row"
    done
    menu_item 0 "返回"
    index=$(prompt "请选择")
    [ "$index" = 0 ] && return
    if ! is_pos_int "$index" || [ "$index" -gt "$count" ]; then
      tell_warn "输入无效，请重新选择"; sleep 1; continue
    fi
    index=$((index-1))
    prompt_yes "确认删除客户端 $(jq -r ".clients[$index].name" "$WG_CONF")" || continue
    body=$(jq --argjson i "$index" 'del(.clients[$i]) | del(.endpoint.peers[$i])' "$WG_CONF") || { tell_warn "配置生成失败"; wait_key; continue; }
    if wg_server_client_delete_apply "$body"; then
      tell_ok "客户端删除完成"
    else
      status=$?
      [ "$status" -eq 2 ] || tell_warn "客户端删除未完成"
    fi
    wait_key
    count=$(jq '.endpoint.peers | length' "$WG_CONF" 2>/dev/null); count=${count:-0}
    [ "$count" -eq 0 ] && break
  done
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
        wait_key
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
  wait_key
}

wg_edit_client(){
  local value value6 body self_pub self4 self6 self6_l
  while :; do
    ui_title "修改配置"
    menu_item 1 "服务端地址"
    menu_item 2 "服务端端口"
    menu_item 3 "服务端公钥"
    menu_item 4 "内网双栈地址"
    menu_item 5 "服务端隧道 IP"
    menu_item 0 "返回"
    case $(prompt "请选择") in
      1)
        value=$(trim_host "$(prompt '服务端地址' "$(jq -r '.peer_host // ""' "$WG_CONF")")")
        [ -n "$value" ] || { tell_warn "服务端地址不能为空"; wait_key; continue; }
        body=$(jq --arg host "$value" '.peer_host=$host|.endpoint.peers[0].address=$host' "$WG_CONF") || continue
        wg_client_edit_apply "$body"
        ;;
      2)
        value=$(prompt "远端端口" "$(jq -r '.peer_port' "$WG_CONF")")
        is_pos_int "$value" && [ "$value" -le 65535 ] || { tell_warn "端口格式无效"; wait_key; continue; }
        body=$(jq --argjson port "$value" '.peer_port=$port|.endpoint.peers[0].port=$port' "$WG_CONF") || continue
        wg_client_edit_apply "$body"
        ;;
      3)
        value=$(prompt "服务端公钥" "$(jq -r '.peer_public_key // ""' "$WG_CONF")")
        self_pub=$(jq -r '.public_key // ""' "$WG_CONF")
        [ -n "$value" ] && wg_valid_pubkey "$value" && [ "$value" != "$self_pub" ] || { tell_warn "服务端公钥无效或与本机相同"; wait_key; continue; }
        body=$(jq --arg key "$value" '.peer_public_key=$key|.endpoint.peers[0].public_key=$key' "$WG_CONF") || continue
        wg_client_edit_apply "$body"
        ;;
      4) wg_edit_address ;;
      5)
        value=$(trim_host "$(prompt "服务端隧道 IPv4" "$(jq -r '.peer_ip // ""' "$WG_CONF")")"); value=${value%/*}; value=$(trim_host "$value")
        { [ -n "$value" ] && wg_valid_address "${value}/32" && [[ "$value" != *:* ]]; } || { tell_warn "服务端隧道 IPv4 无效"; wait_key; continue; }
        value6=$(trim_host "$(prompt "服务端隧道 IPv6" "$(jq -r '.peer_ip6 // ""' "$WG_CONF")")"); value6=${value6%/*}; value6=$(trim_host "$value6")
        { [ -n "$value6" ] && wg_valid_address "${value6}/128" && [[ "$value6" == *:* ]]; } || { tell_warn "服务端隧道 IPv6 无效"; wait_key; continue; }
        self4=$(jq -r '.address[0] // ""' "$WG_CONF" | cut -d/ -f1)
        self6=$(jq -r '.address[1] // ""' "$WG_CONF" | cut -d/ -f1)
        self6_l=${self6,,}
        [ "$value" != "$self4" ] || { tell_warn "服务端隧道 IPv4 不能与本机相同"; wait_key; continue; }
        [ "${value6,,}" != "$self6_l" ] || { tell_warn "服务端隧道 IPv6 不能与本机相同"; wait_key; continue; }
        body=$(jq --arg ip4 "$value" --arg ip6 "$value6" '.peer_ip=$ip4|.peer_ip6=$ip6' "$WG_CONF") || continue
        wg_client_edit_apply "$body"
        ;;
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
  local role previous_exit was_active=0 remove_rc=0 apply_rc=0
  ui_clear
  [ -f "$WG_CONF" ] || { tell_warn "未配置 WireGuard"; wait_key; return; }
  role=$(jq -r '.role // ""' "$WG_CONF" 2>/dev/null)
  wg_config_enabled && was_active=1
  prompt_yes "确认删除 WireGuard 配置" || return
  previous_exit=$(state_get exit) || { tell_warn "出口状态读取失败，取消删除"; wait_key; return; }
  if [ "$role" = server ] && ! wg_server_nat_remove; then
    tell_warn "NAT 状态清理失败，未删除 WireGuard 配置"
    wait_key
    return
  fi
  if [ "$previous_exit" = wireguard ]; then
    state_set exit direct || { tell_warn "出口状态更新失败，WireGuard 配置未删除"; wait_key; return; }
  fi
  rm -rf "$WG_DIR" || remove_rc=1
  if [ "$remove_rc" -eq 0 ]; then ip link del "$WG_IF" 2>/dev/null || true; fi
  if [ "$previous_exit" = wireguard ] || [ "$was_active" = 1 ]; then
    apply_config || apply_rc=1
  fi
  if [ "$remove_rc" -ne 0 ] && [ "$apply_rc" -ne 0 ]; then
    tell_warn "WireGuard 文件删除失败，直连状态已记录但配置应用失败，请检查服务"
  elif [ "$remove_rc" -ne 0 ]; then
    tell_warn "WireGuard 文件删除失败，出口状态已同步"
  elif [ "$apply_rc" -ne 0 ]; then
    tell_warn "WireGuard 已删除，但 sing-box 配置应用失败，请检查服务状态"
  else
    tell_ok "配置删除完成"
  fi
  wait_key
}
wg_toggle_transaction(){
  local role=$1 previous=$2 enabled=$3 body old_body rc=0
  old_body=$(cat "$WG_CONF") || return 1
  body=$(printf '%s\n' "$old_body" | jq --argjson enabled "$enabled" '.enabled=$enabled') || return 1
  if [ "$enabled" = true ]; then
    if [ "$role" = client ]; then
      state_set exit wireguard || return 1
    fi
    if wg_config_apply_transaction "$body"; then
      [ "$role" = client ] && [ "$previous" = warp ] && warp_registered && { json_edit "$WARP_CONF" 'del(.started_at)' || true; }
      return 0
    else
      rc=$?
    fi
    if [ "$role" = client ]; then state_set exit "$previous" || return 2; fi
    [ "$rc" -eq 2 ] && return 2
    return 1
  fi
  if [ "$role" = server ] && ! wg_server_nat_remove; then return 1; fi
  if [ "$previous" = wireguard ]; then
    state_set exit direct || return 1
  fi
  if wg_config_apply_transaction "$body" true; then return 0; else rc=$?; fi
  if [ "$previous" = wireguard ]; then state_set exit "$previous" || return 2; fi
  [ "$rc" -eq 2 ] && return 2
  return 1
}
wg_toggle(){
  local role previous enabled
  ui_clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  role=$(jq -r '.role' "$WG_CONF") || { tell_warn "WireGuard 配置读取失败"; wait_key; return; }
  previous=$(state_get exit) || { tell_warn "出口状态读取失败"; wait_key; return; }
  enabled=$(wg_config_enabled && printf true || printf false)
  if [ "$enabled" = true ]; then
    if wg_toggle_transaction "$role" "$previous" false; then
      tell_ok "停止完成"
    else
      tell_warn "配置应用失败，已恢复旧配置"
    fi
  else
    if [ "$role" = client ] && [ -z "$(jq -r '.peer_public_key // ""' "$WG_CONF")" ]; then
      tell_warn "缺少服务端公钥"
      wait_key
      return
    fi
    if [ "$role" = client ] && [ "$previous" != direct ]; then
      case "$previous" in
        warp) prompt_yes "当前 WARP 正在接管网络。
启动 WireGuard 后，网络出口将切换至 WireGuard，并停止 WARP。
是否切换" || return ;;
        *) prompt_yes "当前 $(exit_label) 正在接管网络。
启动 WireGuard 后，网络出口将切换至 WireGuard。
是否切换" || return ;;
      esac
    fi
    if wg_toggle_transaction "$role" "$previous" true; then
      sleep 2
      tell_ok "启动完成"
    else
      tell_warn "启动失败，已回滚"
    fi
  fi
  wait_key
}

protocol_set_anytls_metadata(){
  local file=$1 value=$2
  if [ -n "$value" ]; then
    json_edit "$file" '.meta.client_metadata=$v' --arg v "$value"
  else
    json_edit "$file" 'del(.meta.client_metadata)'
  fi
}

protocol_set_hysteria2_bbr(){
  local file=$1 profile=$2 up_mbps=$3 down_mbps=$4
  if [ -n "$profile" ]; then
    json_edit "$file" '
      .meta.up_mbps=0 | .meta.down_mbps=0 | .meta.bbr_profile=$b |
      del(.inbound.up_mbps,.inbound.down_mbps) |
      .inbound.bbr_profile=$b | .inbound.ignore_client_bandwidth=true
    ' --arg b "$profile"
  else
    json_edit "$file" '
      .meta.up_mbps=$up | .meta.down_mbps=$down | .meta.bbr_profile="" |
      if $up > 0 then .inbound.up_mbps=$up else del(.inbound.up_mbps) end |
      if $down > 0 then .inbound.down_mbps=$down else del(.inbound.down_mbps) end |
      del(.inbound.bbr_profile,.inbound.ignore_client_bandwidth)
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
      'del(.meta.obfs_type,.meta.obfs_password,.meta.min_packet_size,.meta.max_packet_size) | del(.inbound.obfs)'
  fi
}

protocol_commit(){
  local file=$1 old_json=$2 apply_rc=0 rc=1
  if apply_config; then return 0; else apply_rc=$?; fi
  printf '%s\n' "$old_json" | json_write "$file" || rc=2
  if [ "$apply_rc" -eq 2 ]; then
    apply_config_quiet || true
    rc=2
  else
    sync_hopping_rules || rc=2
  fi
  return "$rc"
}

protocol_edit_name(){
  local file=$1 value
  [ -n "$file" ] && [ -f "$file" ] || return 1
  value=$(prompt "新识别名称" "$(jq -r .name "$file" 2>/dev/null)")
  [ -n "$value" ] || return 1
  json_edit "$file" '.name=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
}

protocol_edit_port(){
  local file=$1 value
  [ -n "$file" ] && [ -f "$file" ] || return 1
  value=$(prompt_port "$(jq -r .proto "$file" 2>/dev/null)" "$(jq -r .port "$file" 2>/dev/null)") || return 1
  json_edit "$file" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
}

protocol_edit_option3(){
  local file=$1 kind=$2 value len
  [ -n "$file" ] && [ -f "$file" ] || return 1
  case $kind in
    socks)
      local old_user
      old_user=$(jq -r '.meta.username//.inbound.users[0].username//""' "$file")
      value=$(prompt "鉴权账号" "$old_user")
      [ -n "$value" ] || return 1
      json_edit "$file" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    vless-reality|vless-tls|vless-ws|vless-grpc|vmess-tls|vmess-ws|vmess-grpc|vmess-http|tuic)
      local old_uuid
      old_uuid=$(jq -r '.meta.uuid//""' "$file")
      value=$(prompt "新通信 UUID (留空自动生成, 当前: $old_uuid)")
      while :; do
        [ -z "$value" ] && value=$(random_uuid) && break
        valid_uuid "$value" && break
        tell_warn "UUID 格式无效"
        value=$(prompt "新通信 UUID (留空自动生成, 当前: $old_uuid)")
      done
      json_edit "$file" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    snell)
      while :; do
        local old_psk
        old_psk=$(jq -r .meta.psk "$file")
        value=$(prompt "新 PSK (留空自动生成, 12-255字节, 当前: $old_psk)")
        [ -z "$value" ] && value=$(random_password)
        len=${#value}
        if [ "$len" -ge 12 ] && [ "$len" -le 255 ]; then break; fi
        tell_warn "PSK 长度必须为 12-255 字节，当前 ${len} 字节"
      done
      json_edit "$file" '.meta.psk=$v|.inbound.psk=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    *)
      local old_pw
      old_pw=$(jq -r '.meta.password//""' "$file")
      value=$(prompt "新连接密码 (留空自动生成, 当前: $old_pw)")
      [ -z "$value" ] && value=$(random_password)
      json_edit "$file" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
  esac
}

protocol_edit_option4(){
  local file=$1 kind=$2 value current_hop other security method current_method default_method current_security default_security
  local title_name; title_name=$(server_node_name "$file")
  [ -n "$file" ] && [ -f "$file" ] || return 1
  case $kind in
    shadowsocks)
      current_method=$(jq -r '.meta.method//""' "$file")
      case "$current_method" in 2022-blake3-aes-128-gcm) default_method=1;; 2022-blake3-aes-256-gcm) default_method=2;; 2022-blake3-chacha20-poly1305) default_method=3;; aes-128-gcm) default_method=4;; aes-256-gcm) default_method=5;; chacha20-ietf-poly1305) default_method=6;; xchacha20-ietf-poly1305) default_method=7;; *) default_method=2;; esac
      while :; do
        ui_title "$title_name"; menu_item 1 "2022-blake3-aes-128-gcm"; menu_item 2 "2022-blake3-aes-256-gcm"; menu_item 3 "2022-blake3-chacha20-poly1305"; menu_item 4 "aes-128-gcm"; menu_item 5 "aes-256-gcm"; menu_item 6 "chacha20-ietf-poly1305"; menu_item 7 "xchacha20-ietf-poly1305"
        case $(prompt "加密方式" "$default_method") in
          1) value=2022-blake3-aes-128-gcm; break ;; 2) value=2022-blake3-aes-256-gcm; break ;;
          3) value=2022-blake3-chacha20-poly1305; break ;; 4) value=aes-128-gcm; break ;;
          5) value=aes-256-gcm; break ;; 6) value=chacha20-ietf-poly1305; break ;; 7) value=xchacha20-ietf-poly1305; break ;;
          *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
        esac
      done
      method=$(jq -r '.meta.method//""' "$file")
      if [ "$method" != "$value" ] && [[ "$value" == 2022-* ]]; then
        local new_pw
        new_pw=$(ss_generate_key "$value") || { tell_warn "新加密方式的密钥生成失败"; wait_key; return 1; }
        json_edit "$file" '.meta.method=$m|.inbound.method=$m|.meta.password=$p|.inbound.password=$p' --arg m "$value" --arg p "$new_pw" || { tell_warn "修改失败"; wait_key; return 1; }
      else
        json_edit "$file" '.meta.method=$m|.inbound.method=$m' --arg m "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      fi
      ;;
    vless-ws|vless-grpc|trojan-ws|trojan-grpc|vmess-tls|vmess-ws|vmess-grpc|vmess-http)
      case $kind in
        *-ws) value=$(prompt "WebSocket Path" "$(jq -r '.meta.path//"/ws"' "$file")")
              [ -n "$value" ] && [ "${value:0:1}" != "/" ] && value="/$value"
              json_edit "$file" '.meta.path=$v|.inbound.transport.path=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; } ;;
        *-grpc) value=$(prompt "gRPC Service Name" "$(jq -r '.meta.service_name//"TunService"' "$file")"); json_edit "$file" '.meta.service_name=$v|.inbound.transport.service_name=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; } ;;
        vmess-http) value=$(prompt "HTTP Path" "$(jq -r '.meta.path//"/"' "$file")")
              [ -n "$value" ] && [ "${value:0:1}" != "/" ] && value="/$value"
              json_edit "$file" '.meta.path=$v|.inbound.transport.path=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; } ;;
        vmess-tls)
          current_security=$(jq -r '.meta.security//"auto"' "$file")
          case "$current_security" in auto) default_security=1;; aes-128-gcm) default_security=2;; chacha20-poly1305) default_security=3;; *) default_security=1;; esac
          while :; do
            ui_title "$title_name"
            menu_item 1 "Auto"; menu_item 2 "AES-128-GCM"; menu_item 3 "ChaCha20-Poly1305"
            case $(prompt "请选择" "$default_security") in
              1) security=auto; break;; 2) security=aes-128-gcm; break;; 3) security=chacha20-poly1305; break;;
              *) tell_warn "输入无效，请重新选择"; sleep 1;;
            esac
          done
          json_edit "$file" '.meta.security=$v' --arg v "$security" || { tell_warn "修改失败"; wait_key; return 1; } ;;
      esac
      ;;
    tuic)
      value=$(prompt "连接密码" "$(jq -r '.meta.password//""' "$file")")
      [ -n "$value" ] || { tell_warn "密码不能为空"; wait_key; return 1; }
      json_edit "$file" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    socks)
      value=$(prompt "鉴权密码" "$(jq -r '.meta.password//""' "$file")")
      [ -n "$value" ] || return 1
      json_edit "$file" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    snell)
      while :; do
        ui_title "$title_name"
        menu_item 1 "Default"; menu_item 2 "Unshaped"; menu_item 3 "Unsafe Raw"
        local cur_sm def_sm; cur_sm=$(jq -r '.meta.mode//"default"' "$file"); case "$cur_sm" in default) def_sm=1;; unshaped) def_sm=2;; unsafe-raw) def_sm=3;; *) def_sm=1;; esac
        case $(prompt "流量整形模式" "$def_sm") in
          1|default) value=default; break ;; 2|unshaped) value=unshaped; break ;; 3|unsafe-raw) value=unsafe-raw; break ;;
          *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
        esac
      done
      json_edit "$file" '.meta.mode=$v|.inbound.mode=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    anytls)
      local old_meta
      old_meta=$(jq -r '.meta.client_metadata//""' "$file")
      value=$(prompt "客户端元数据 (当前: ${old_meta:-无}, 留空清空)")
      protocol_set_anytls_metadata "$file" "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    hysteria2)
      current_hop=$(jq -r '.hopping//""' "$file")
      while :; do
        value=$(prompt "跳跃范围 (当前: ${current_hop:-未开启}, 0 关闭, 留空取消)")
        [ -n "$value" ] || return 1
        if [ "$value" = 0 ]; then value=""; break; fi
        validate_range "$value" "$(jq -r '.port//""' "$file")" || continue
        if other=$(hopping_node) && [ "$other" != "$file" ]; then tell_warn "已有节点开启跳跃"; continue; fi
        break
      done
      json_edit "$file" '.hopping=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    *)
      tell_warn "当前协议不支持该配置项"; sleep 1; return 1 ;;
  esac
}

protocol_edit_option5(){
  local file=$1 kind=$2 value security bbr_profile up_mbps down_mbps current_bbr default_cc current_sec default_sec current_cc
  local title_name; title_name=$(server_node_name "$file")
  [ -n "$file" ] && [ -f "$file" ] || return 1
  case $kind in
    vless-reality)
      local old_target
      old_target=$(jq -r '.meta.target//""' "$file")
      while :; do
        value=$(sanitize_domain "$(prompt "新握手目标域名 (留空取消, 当前: $old_target)")")
        [ -n "$value" ] || return 1
        probe_handshake_target "$value" && break
        prompt_yes "检测异常，强制加载" && break
      done
      json_edit "$file" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v|.inbound.tls.reality.handshake.server_port=443' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }
      ;;
    vmess)
  current_sec=$(jq -r '.meta.security//"auto"' "$file")
  case "$current_sec" in auto) default_sec=1;; aes-128-gcm) default_sec=2;; chacha20-poly1305) default_sec=3;; *) default_sec=1;; esac
  while :; do
    ui_title "$title_name"; menu_item 1 "Auto"; menu_item 2 "AES-128-GCM"; menu_item 3 "ChaCha20-Poly1305"
    case $(prompt "请选择" "$default_sec") in
      1|auto) security=auto; break;; 2|aes-128-gcm) security=aes-128-gcm; break;; 3|chacha20-poly1305) security=chacha20-poly1305; break;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
  json_edit "$file" '.meta.security=$v' --arg v "$security" || { tell_warn "修改失败"; wait_key; return 1; }
  ;;
    tuic)
  current_cc=$(jq -r '.meta.congestion_control//"bbr"' "$file")
  case "$current_cc" in cubic) default_cc=1;; new_reno) default_cc=2;; bbr) default_cc=3;; *) default_cc=3;; esac
  while :; do
    ui_title "$title_name"; menu_item 1 "cubic"; menu_item 2 "New Reno"; menu_item 3 "bbr"
    case $(prompt "请选择" "$default_cc") in
      1|cubic) value=cubic; break;; 2|new_reno) value=new_reno; break;; 3|bbr) value=bbr; break;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
  json_edit "$file" '.meta.congestion_control=$v|.inbound.congestion_control=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; } ;;
    hysteria2)
      current_bbr=$(jq -r '.meta.bbr_profile//""' "$file")
      case "$current_bbr" in conservative) default_cc=1;; standard) default_cc=2;; aggressive) default_cc=3;; *) default_cc=4;; esac
      while :; do
        ui_title "$title_name"; menu_item 1 "BBR Conservative"; menu_item 2 "BBR Standard"; menu_item 3 "BBR Aggressive"; menu_item 4 "Brutal（手动带宽）"
        case $(prompt "请选择拥塞控制" "$default_cc") in
          1) bbr_profile=conservative; up_mbps=0; down_mbps=0; break ;;
          2) bbr_profile=standard; up_mbps=0; down_mbps=0; break ;;
          3) bbr_profile=aggressive; up_mbps=0; down_mbps=0; break ;;
          4) bbr_profile=""; while :; do
            up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.up_mbps//0' "$file")"); is_uint "$up_mbps" || { tell_warn "输入无效，请重新输入"; continue; }
            down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.down_mbps//0' "$file")"); is_uint "$down_mbps" || { tell_warn "输入无效，请重新输入"; continue; }
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
  local title_name; title_name=$(server_node_name "$file")
  [ -n "$file" ] && [ -f "$file" ] || return 1
  if [ "$kind" = vless-reality ]; then
    local old_sid sid_len
    old_sid=$(jq -r '.meta.short_id//""' "$file")
    while :; do
      value=$(prompt "新 short_id (留空自动生成 2-16位偶数十六进制, 当前: $old_sid)")
      [ -z "$value" ] && value=$(openssl rand -hex 8)
      sid_len=${#value}
      if [ $((sid_len % 2)) -eq 0 ] && [[ $value =~ ^[0-9a-fA-F]{2,16}$ ]]; then break; fi
      tell_warn "short_id 必须为 2-16 位偶数长度十六进制字符"
    done
    json_edit "$file" '.meta.short_id=$v|.inbound.tls.reality.short_id=[$v]' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; }

  elif [ "$kind" = hysteria2 ]; then
    if prompt_yes "是否开启协议混淆" "$( [ -n "$(jq -r '.meta.obfs_type//""' "$file")" ] && printf y || printf n )"; then
      while :; do
        ui_title "$title_name"; menu_item 1 "Salamander"; menu_item 2 "Gecko"
        current_obfs=$(jq -r '.meta.obfs_type//""' "$file")
        case "$current_obfs" in salamander) default_obfs=1;; gecko) default_obfs=2;; *) default_obfs=2;; esac
        case $(prompt "请选择混淆算法 (当前: ${current_obfs:-无})" "$default_obfs") in
          1) obfs_type=salamander; break ;; 2) obfs_type=gecko; break ;; *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
        esac
      done
      obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$(jq -r 'if (.meta.obfs_password//"")!="" then .meta.obfs_password else (.meta.password//"") end' "$file")")
      if [ "$obfs_type" = gecko ]; then
        while :; do
          min_pkt=$(prompt "最小包大小 (字节, 512-2048)" "$(jq -r '.meta.min_packet_size//512' "$file")")
          is_pos_int "$min_pkt" && [ "$min_pkt" -ge 512 ] && [ "$min_pkt" -le 2048 ] && break
          tell_warn "最小包大小必须为 512-2048"
        done
        while :; do
          max_pkt=$(prompt "最大包大小 (字节, 512-2048)" "$(jq -r '.meta.max_packet_size//1200' "$file")")
          is_pos_int "$max_pkt" && [ "$max_pkt" -ge 512 ] && [ "$max_pkt" -le 2048 ] && [ "$max_pkt" -ge "$min_pkt" ] && break
          tell_warn "最大包大小必须为 512-2048 且不小于最小包大小"
        done
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
      local old_pw method
      old_pw=$(jq -r '.meta.password//""' "$file")
      method=$(jq -r '.meta.method' "$file")
      while :; do
        value=$(prompt "连接密码 (留空自动生成, 当前: $old_pw)")
        if [ -z "$value" ]; then value=$(ss_generate_key "$method"); break; fi
        ss_valid_key "$method" "$value" && break
        tell_warn "密钥长度与加密方式不匹配"
      done
      json_edit "$file" '.meta.password=$v|.inbound.password=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; return 1; } ;;
    *) tell_warn "当前协议不支持该配置项"; sleep 1; return 1 ;;
  esac
}

menu_modify_protocol(){
  local choice kind name old_json file
  select_node file "修改配置" || return
  while :; do
    [ -n "$file" ] && [ -f "$file" ] || { tell_warn "节点文件不存在，无法修改"; wait_key; return 1; }
    kind=$(jq -er '.kind // empty' "$file" 2>/dev/null) || { tell_warn "节点配置读取失败"; wait_key; return 1; }
    name=$(jq -er '.name // .tag // empty' "$file" 2>/dev/null) || { tell_warn "节点名称读取失败"; wait_key; return 1; }
    ui_title "$name"
    menu_item 1 "节点名称"; menu_item 2 "监听端口"
    case $kind in
      shadowsocks) menu_item 3 "加密方式"; menu_item 4 "连接密码" ;;
      vless-reality) menu_item 3 "通信 UUID"; menu_item 4 "握手目标域名"; menu_item 5 "short_id" ;;
      vless-tls) menu_item 3 "通信 UUID" ;;
      vless-ws) menu_item 3 "通信 UUID"; menu_item 4 "WebSocket Path" ;;
      vless-grpc) menu_item 3 "通信 UUID"; menu_item 4 "gRPC Service Name" ;;
      vmess-tls) menu_item 3 "通信 UUID"; menu_item 4 "加密方式" ;;
      vmess-ws) menu_item 3 "通信 UUID"; menu_item 4 "WebSocket Path"; menu_item 5 "加密方式" ;;
      vmess-grpc) menu_item 3 "通信 UUID"; menu_item 4 "gRPC Service Name"; menu_item 5 "加密方式" ;;
      vmess-http) menu_item 3 "通信 UUID"; menu_item 4 "HTTP Path"; menu_item 5 "加密方式" ;;
      trojan) menu_item 3 "连接密码" ;;
      trojan-ws) menu_item 3 "连接密码"; menu_item 4 "WebSocket Path" ;;
      trojan-grpc) menu_item 3 "连接密码"; menu_item 4 "gRPC Service Name" ;;
      tuic) menu_item 3 "通信 UUID"; menu_item 4 "连接密码"; menu_item 5 "拥塞控制" ;;
      socks) menu_item 3 "鉴权账号"; menu_item 4 "鉴权密码" ;;
      snell) menu_item 3 "预共享密钥"; menu_item 4 "流量整形模式" ;;
      anytls) menu_item 3 "连接密码"; menu_item 4 "客户端元数据" ;;
      hysteria2) menu_item 3 "连接密码"; menu_item 4 "端口跳跃机制"; menu_item 5 "拥塞控制"; menu_item 6 "混淆设置" ;;
      *) menu_item 3 "连接密码" ;;
    esac
    menu_item 0 "返回"
    choice=$(prompt "请选择")
    [ "$choice" = 0 ] && return
    local skip_reload=0
    old_json=$(cat "$file") || { tell_warn "节点文件读取失败"; wait_key; return 1; }
    case "$kind:$choice" in
      *:1) protocol_edit_name "$file" || continue; skip_reload=1 ;;
      *:2) protocol_edit_port "$file" || continue ;;
      shadowsocks:3) protocol_edit_option4 "$file" "$kind" || continue ;;
      shadowsocks:4) protocol_edit_option7 "$file" "$kind" || continue ;;
      *:3) protocol_edit_option3 "$file" "$kind" || continue ;;
      vless-reality:4) protocol_edit_option5 "$file" "$kind" || continue ;;
      vless-reality:5) protocol_edit_option6 "$file" "$kind" || continue ;;
      vless-ws:4|vless-grpc:4|vmess-tls:4|vmess-ws:4|vmess-grpc:4|vmess-http:4|trojan-ws:4|trojan-grpc:4) protocol_edit_option4 "$file" "$kind" || continue; [ "$kind" = vmess-tls ] && skip_reload=1 ;;
      vmess-ws:5|vmess-grpc:5|vmess-http:5) protocol_edit_option5 "$file" vmess || continue; skip_reload=1 ;;
      tuic:4|socks:4|snell:4|anytls:4|hysteria2:4) protocol_edit_option4 "$file" "$kind" || continue; [ "$kind" = anytls ] && skip_reload=1 ;;
      tuic:5|hysteria2:5) protocol_edit_option5 "$file" "$kind" || continue ;;
      hysteria2:6) protocol_edit_option6 "$file" "$kind" || continue ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1; continue ;;
    esac
    if [ "$skip_reload" = 1 ]; then
      tell_ok "修改完成"; printf "\n"; render_share_uri "$file"
    elif protocol_commit "$file" "$old_json"; then
      tell_ok "修改完成"; printf "\n"; render_share_uri "$file"
    else
      tell_warn "配置冲突或校验失败，已回滚"
    fi
    wait_key
  done
}

core_version(){
  [ -x "$CORE" ] || return 0
  "$CORE" version 2>/dev/null | awk '/version/{print $3; exit}'
}

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

release_json_load(){
  local json=""
  reload_net_cache
  if [ -n "$NET_IPV4" ]; then
    json=$(curl -4 -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 -m 15 "$GH_API/releases/latest" 2>/dev/null) || json=""
  fi
  if [ -z "$json" ]; then
    json=$(curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 -m 15 "$GH_API/releases/latest" 2>/dev/null) || return 1
  fi
  jq -e . >/dev/null 2>&1 <<<"$json" || return 1
  RELEASE_JSON_CACHE="$json"
}

release_json(){
  if [ -n "$RELEASE_JSON_CACHE" ]; then printf '%s' "$RELEASE_JSON_CACHE"; return 0; fi
  release_json_load || return 1
  printf '%s' "$RELEASE_JSON_CACHE"
}

remote_version(){
  local json tag
  json=$(release_json) || return 1
  tag=$(jq -er '.tag_name // empty' <<<"$json" 2>/dev/null) || return 1
  printf '%s\n' "${tag#v}"
}

install_core(){
  local json url asset candidate tmp found digest
  reload_net_cache
  json=$(release_json) || { tell_warn "获取版本信息失败或遭遇 API 限流"; return 1; }
  for candidate in $(asset_candidates); do
    url=$(jq -er --arg s "$candidate.tar.gz" '.assets[]?|select(.name|endswith($s))|.browser_download_url' <<<"$json" 2>/dev/null | head -1) || url=
    digest=$(jq -er --arg s "$candidate.tar.gz" '.assets[]?|select(.name|endswith($s))|.digest // empty' <<<"$json" 2>/dev/null | head -1) || digest=
    [ -n "$url" ] && { asset=$candidate; break; }
  done
  [ -n "$url" ] || { tell_warn "未找到匹配架构的安装包"; return 1; }
  mkdir -p /root || { tell_warn "/root 目录不可用"; return 1; }
  tmp=$(mktemp -d /root/.sbm-core.XXXXXX) || { tell_warn "临时目录创建失败"; return 1; }
  INSTALL_TMP_DIR="$tmp"
  if [ -n "$NET_IPV4" ]; then
    if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 240 "$url" -o "$tmp/core.tar.gz" 2>/dev/null; then
      if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 240 "$url" -o "$tmp/core.tar.gz" 2>/dev/null; then
        rm -rf "$tmp"; INSTALL_TMP_DIR=""; tell_warn "安装包下载失败"; return 1
      fi
    fi
  else
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 240 "$url" -o "$tmp/core.tar.gz" 2>/dev/null; then
      rm -rf "$tmp"; INSTALL_TMP_DIR=""; tell_warn "安装包下载失败"; return 1
    fi
  fi
  if [ -z "$digest" ]; then
    rm -rf "$tmp"; INSTALL_TMP_DIR=""; tell_warn "发布元数据未提供安装包 SHA-256，拒绝安装"; return 1
  fi
  local expected actual
  expected=${digest#sha256:}
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { rm -rf "$tmp"; INSTALL_TMP_DIR=""; tell_warn "安装包 SHA-256 格式无效"; return 1; }
  actual=$(sha256sum "$tmp/core.tar.gz" | awk '{print $1}')
  [ "${actual,,}" = "${expected,,}" ] || { rm -rf "$tmp"; INSTALL_TMP_DIR=""; tell_warn "安装包 SHA-256 校验失败"; return 1; }
  tar -xzf "$tmp/core.tar.gz" -C "$tmp" || { rm -rf "$tmp"; INSTALL_TMP_DIR=""; tell_warn "安装包解压失败"; return 1; }
  found=$(find "$tmp" -type f -name sing-box | head -1)
  [ -n "$found" ] || { rm -rf "$tmp"; INSTALL_TMP_DIR=""; tell_warn "未找到二进制文件"; return 1; }
  local had_bak=0
  if [ -f "$CORE" ]; then cp -a "$CORE" "${CORE}.bak" && had_bak=1; fi
  if ! { cp "$found" "${CORE}.new" && chmod 755 "${CORE}.new" && mv -f "${CORE}.new" "$CORE"; }; then
    rm -f "${CORE}.new"
    [ "$had_bak" = 1 ] && rm -f "${CORE}.bak"
    rm -rf "$tmp"; INSTALL_TMP_DIR=""
    tell_warn "sing-box 二进制安装失败"
    return 1
  fi
  rm -rf "$tmp" || return 1
  INSTALL_TMP_DIR=""
  state_set asset "$asset" || return 1
  tell_ok "sing-box 内核已安装: $(core_version) [$asset]"
}

write_service(){
  local tmp changed=0
  tmp=$(mktemp) || return 1
  cat >"$tmp" <<EOF
[Unit]
Description=sing-box
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$SB_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
NoNewPrivileges=true
ExecStart=$CORE -D /var/lib/sing-box -c $CONFIG run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  if [ ! -f "$SERVICE_UNIT" ] || ! cmp -s "$tmp" "$SERVICE_UNIT"; then
    install -m644 "$tmp" "$SERVICE_UNIT" || { rm -f "$tmp"; return 1; }
    changed=1
  fi
  rm -f "$tmp"
  write_dropin || return 1
  if [ "$changed" = 1 ]; then
    SERVICE_UNIT_CHANGED=1
    systemctl daemon-reload || return 1
  fi
  return 0
}

write_dropin(){
  local tmp changed=0
  mkdir -p "$DROPIN_DIR" || return 1
  tmp=$(mktemp) || return 1
  cat >"$tmp" <<EOF
[Service]
ExecStartPost=-$SHORTCUT --sync
ExecStopPost=-$SHORTCUT --clear-hopping
EOF
  if [ ! -f "$DROPIN" ] || ! cmp -s "$tmp" "$DROPIN"; then
    install -m644 "$tmp" "$DROPIN" || { rm -f "$tmp"; return 1; }
    changed=1
  fi
  rm -f "$tmp"
  if [ "$changed" = 1 ]; then
    SERVICE_UNIT_CHANGED=1
    systemctl daemon-reload || return 1
  fi
  return 0
}

run_core_reinstall(){
  local success_msg=$1 apply_fail_msg=$2 install_fail_msg=$3
  if install_core; then
    if apply_config; then
      tell_ok "$success_msg"
      rm -f "${CORE}.bak"
    else
      tell_warn "$apply_fail_msg"
      if [ -f "${CORE}.bak" ]; then
        mv -f "${CORE}.bak" "$CORE" && apply_config_quiet || true
      fi
    fi
  else
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
  if jq 'if (.config.peers[0].endpoint.host // "") != "" and (.config.peers[0].endpoint.port // null) == null and (.config.peers[0].endpoint.host|test(":\\d+$")) then
        .config.peers[0].endpoint as $e |
        ($e.host | capture("^(?<host>.*):(?<port>[0-9]+)$")) as $hp |
        .config.peers[0].endpoint.host=($hp.host | gsub("^\\[|\\]$"; "")) |
        .config.peers[0].endpoint.port=($hp.port|tonumber)
      else . end' "$file" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

WARP_HTTP_CODE=000
WARP_API_INTERFACE=""
WARP_API_FAMILY=""
WARP_TUNNEL_INTERFACE=""
WARP_TUNNEL_ADDRESS=""

warp_transport_select(){
  if probe_network_stack; then save_net_cache || true; fi
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
  local host=$1 prefer resolved resolved4="" resolved6="" ep4 ep6
  prefer=$(warp_config_get '.tunnel_family // empty')
  WARP_TUNNEL_INTERFACE=""
  WARP_TUNNEL_ADDRESS=""
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    resolved4="$host"
  elif [[ "$host" == *:* ]]; then
    resolved6="$host"
  else
    resolved=$(resolve_addresses "$host" 2>/dev/null || true)
    resolved4=$(awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print;exit}' <<<"$resolved")
    resolved6=$(awk '/:/{print;exit}' <<<"$resolved")
  fi
  if [ -z "$resolved4" ]; then
    ep4=$(warp_config_get '.config.peers[0].endpoint.v4 // empty'); ep4=${ep4%:*}
    [[ "$ep4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && resolved4="$ep4"
  fi
  if [ -z "$resolved6" ]; then
    ep6=$(warp_config_get '.config.peers[0].endpoint.v6 // empty'); ep6=${ep6%]:*}; ep6=${ep6#\[}
    [[ "$ep6" == *:* ]] && resolved6="$ep6"
  fi
  if [ "$prefer" = 6 ]; then
    if [ -n "$resolved6" ] && [ -n "$NET_IPV6" ] && [ -n "$NET_IF_V6" ]; then
      WARP_TUNNEL_INTERFACE="$NET_IF_V6"; WARP_TUNNEL_ADDRESS="$resolved6"; return 0
    elif [ -n "$resolved4" ] && [ -n "$NET_IPV4" ] && [ -n "$NET_IF_V4" ]; then
      WARP_TUNNEL_INTERFACE="$NET_IF_V4"; WARP_TUNNEL_ADDRESS="$resolved4"; return 0
    fi
  else
    if [ -n "$resolved4" ] && [ -n "$NET_IPV4" ] && [ -n "$NET_IF_V4" ]; then
      WARP_TUNNEL_INTERFACE="$NET_IF_V4"; WARP_TUNNEL_ADDRESS="$resolved4"; return 0
    elif [ -n "$resolved6" ] && [ -n "$NET_IPV6" ] && [ -n "$NET_IF_V6" ]; then
      WARP_TUNNEL_INTERFACE="$NET_IF_V6"; WARP_TUNNEL_ADDRESS="$resolved6"; return 0
    fi
  fi
  return 1
}

warp_api_request_once(){
  local method=$1 url=$2 token=${3:-} body=${4:-} out=$5 code curl_rc api_ip=""
  WARP_HTTP_CODE=000
  [ -n "$out" ] || return 2
  if [ -n "$WARP_API_FAMILY" ]; then
    api_ip=$(resolve_addresses "api.cloudflareclient.com" 2>/dev/null | if [ "$WARP_API_FAMILY" = 4 ]; then awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print;exit}'; else awk '/:/{print;exit}'; fi)
    [ -n "$api_ip" ] && {
      if [ "$WARP_API_FAMILY" = 6 ]; then api_ip="[${api_ip}]"; fi
    }
  fi
  if [ "$method" = POST ]; then
    local args=(-sS --location --tlsv1.3 --connect-timeout 8 --max-time 20 -o "$out" -w '%{http_code}' -X POST "$url" \
      -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.10-2158' \
      -H 'Content-Type: application/json' --data "$body")
    [ -n "$WARP_API_FAMILY" ] && args=("-$WARP_API_FAMILY" "${args[@]}")
    [ -n "$WARP_API_INTERFACE" ] && args+=( --interface "$WARP_API_INTERFACE" )
    [ -n "$api_ip" ] && args+=( --resolve "api.cloudflareclient.com:443:${api_ip}" )
    code=$(curl "${args[@]}" 2>/dev/null); curl_rc=$?
  else
    local args=(-sS --location --tlsv1.3 --connect-timeout 8 --max-time 15 -o "$out" -w '%{http_code}' -X "$method" "$url" \
      -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.10-2158')
    [ -n "$token" ] && args+=( -H "Authorization: Bearer $token" )
    [ -n "$WARP_API_FAMILY" ] && args=("-$WARP_API_FAMILY" "${args[@]}")
    [ -n "$WARP_API_INTERFACE" ] && args+=( --interface "$WARP_API_INTERFACE" )
    [ -n "$api_ip" ] && args+=( --resolve "api.cloudflareclient.com:443:${api_ip}" )
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

warp_make_body(){
  local public=$1 install_id=${2:-} fcm tos
  [ "${#install_id}" -eq 22 ] || return 1
  fcm="${install_id}:APA91b$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134)"
  tos=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  jq -n --arg key "$public" --arg iid "$install_id" --arg fcm "$fcm" --arg tos "$tos" \
    '{key:$key,install_id:$iid,fcm_token:$fcm,tos:$tos,model:"PC",serial_number:$iid,locale:"zh_CN"}'
}

warp_refresh(){
  warp_registered || return 1
  local id token tmp current mode registered_at private public iid old_cid old_tf
  mode=$(warp_mode_get)
  warp_transport_select || return 1
  id=$(warp_config_get '.id'); token=$(warp_config_get '.token')
  [ -n "$id" ] && [ -n "$token" ] || return 1
  tmp=$(mktemp) || return 1
  register_cleanup "$tmp"
  if ! warp_api_request GET "$WARP_API/$id" "$token" '' "$tmp"; then
    cleanup_release "$tmp"; return 1
  fi
  warp_normalize_endpoint "$tmp" || true
  jq -e --arg id "$id" '.id==$id and .config.peers[0].public_key and .config.peers[0].endpoint.host and (.config.peers[0].endpoint.port|tonumber) and (.config.interface.addresses.v4 or .config.interface.addresses.v6)' "$tmp" >/dev/null 2>&1 || { cleanup_release "$tmp"; return 1; }
  current=$(cat "$WARP_CONF") || { cleanup_release "$tmp"; return 1; }
  registered_at=$(jq -r '.registered_at // empty' <<<"$current")
  private=$(jq -r '.private_key // empty' <<<"$current")
  public=$(jq -r '.public_key // empty' <<<"$current")
  iid=$(jq -r '.install_id // empty' <<<"$current")
  old_cid=$(jq -r '.config.client_id // empty' <<<"$current")
  old_tf=$(jq -r '.tunnel_family // empty' <<<"$current")
  register_cleanup "$tmp.new"
  jq --arg pk "$private" --arg pub "$public" --arg iid "$iid" --arg mode "$mode" --arg registered "$registered_at" --arg token "$token" --arg cid "$old_cid" --arg tf "$old_tf" \
    '. + {token:$token,private_key:$pk,public_key:$pub,install_id:$iid,warp_mode:$mode,registered_at:$registered} | if (.config.client_id // "") == "" and $cid != "" then .config.client_id = $cid else . end | if $tf != "" then .tunnel_family = $tf else . end' "$tmp" >"$tmp.new" 2>/dev/null || { cleanup_release "$tmp" "$tmp.new"; return 1; }
  install -m600 "$tmp.new" "$WARP_CONF" || { cleanup_release "$tmp" "$tmp.new"; return 1; }
  cleanup_release "$tmp" "$tmp.new"
}

warp_mode_get(){
  local mode; mode=$(warp_config_get '.warp_mode // "dual"')
  case "$mode" in ipv4|ipv6|dual) printf '%s' "$mode" ;; *) printf '%s' dual ;; esac
}
warp_mode_label(){ case "$(warp_mode_get)" in ipv4) printf 'IPv4' ;; ipv6) printf 'IPv6' ;; *) printf '双栈' ;; esac; }
warp_config_get(){ jq -r "$1" "$WARP_CONF" 2>/dev/null; }

warp_endpoint(){
  local resolver=$1 mode private peer addr4 addr6 host endpoint_host port allowed addresses
  local client_id reserved='[0,0,0]' cid_b64 cid_pad res_arr
  mode=$(warp_mode_get)
  private=$(warp_config_get '.private_key')
  peer=$(warp_config_get '.config.peers[0].public_key')
  addr4=$(warp_config_get '.config.interface.addresses.v4')
  addr6=$(warp_config_get '.config.interface.addresses.v6')
  host=$(warp_config_get '.config.peers[0].endpoint.host')
  port=$(warp_config_get '.config.peers[0].endpoint.port')
  if ! is_pos_int "$port" && [[ "$host" =~ ^(.+):([1-9][0-9]*)$ ]]; then
    port=${BASH_REMATCH[2]}; host=${BASH_REMATCH[1]}
  fi
  [ -n "$private" ] && [ -n "$peer" ] && [ -n "$host" ] && is_pos_int "$port" || return 1
  host=${host#\[}; host=${host%\]}
  warp_tunnel_select "$host" || return 1
  endpoint_host="$WARP_TUNNEL_ADDRESS"
  [ -n "$endpoint_host" ] || return 1
  client_id=$(warp_config_get '.config.client_id // empty')
  if [ -n "$client_id" ]; then
    cid_b64=$(printf '%s' "$client_id" | tr -d '[:space:]' | tr '_-' '/+')
    cid_pad=$(( (4 - ${#cid_b64}%4) % 4 ))
    [ "$cid_pad" -gt 0 ] && cid_b64="${cid_b64}$(printf '%*s' "$cid_pad" '' | tr ' ' '=')"
    res_arr=$(printf '%s' "$cid_b64" | base64 -d 2>/dev/null | od -An -tu1 -N3 2>/dev/null | awk '{for(i=1;i<=NF;i++) a[++n]=$i} END{if(n==3) printf "[%d,%d,%d]",a[1],a[2],a[3]}')
    [ -n "$res_arr" ] && reserved="$res_arr"
  fi
  case "$mode" in
    ipv4) [ -n "$addr4" ] || return 1; addresses=$(jq -n --arg a "$addr4/32" '[$a]'); allowed='["0.0.0.0/0"]' ;;
    ipv6) [ -n "$addr6" ] || return 1; addresses=$(jq -n --arg a "$addr6/128" '[$a]'); allowed='["::/0"]' ;;
    dual) [ -n "$addr4" ] && [ -n "$addr6" ] || return 1; addresses=$(jq -n --arg a4 "$addr4/32" --arg a6 "$addr6/128" '[$a4,$a6]'); allowed='["0.0.0.0/0","::/0"]' ;;
  esac
  jq -n --arg resolver "$resolver" --arg host "$endpoint_host" --argjson port "$port" --arg private "$private" --arg peer "$peer" \
    --arg bind "$WARP_TUNNEL_INTERFACE" --argjson addresses "$addresses" --argjson allowed "$allowed" --argjson reserved "$reserved" \
    '{type:"wireguard",tag:"warp",system:false,mtu:1280,address:$addresses,private_key:$private,
      peers:[{address:$host,port:$port,public_key:$peer,allowed_ips:$allowed,persistent_keepalive_interval:25,reserved:$reserved}],
      domain_resolver:$resolver} | if $bind != "" then . + {bind_interface:$bind} else . end'
}

warp_status(){
  if ! warp_registered; then echo unconfigured; return; fi
  if [ "$(state_get exit 2>/dev/null)" = warp ] && systemctl is-active --quiet sing-box 2>/dev/null && ip link show "$TUN_IF" >/dev/null 2>&1 && jq -e '.endpoints[]? | select(.tag=="warp")' "$CONFIG" >/dev/null 2>&1; then
    echo running
  else
    echo stopped
  fi
}

warp_register(){
  local new_ip_target=${1:-}
  case "$new_ip_target" in ipv4|ipv6|dual) ;; *) return 1 ;; esac
  warp_transport_select || { tell_warn "没有可用的 WARP 上游网络"; return 1; }
  local old_id old_token keypair private public body response_file refresh_file registration_id registration_token api_error
  local register_ok=0 attempt=1 warp_install_id
  WARP_PENDING_DELETE_ID=""
  WARP_PENDING_DELETE_TOKEN=""
  mkdir -p "$WARP_DIR" && chmod 700 "$WARP_DIR" || { tell_warn "目录创建失败"; return 1; }
  old_id=$(warp_config_get '.id'); old_token=$(warp_config_get '.token')
  keypair=$(wg_keypair) || { tell_warn "WireGuard 密钥生成失败"; return 1; }
  private=${keypair%%|*}; public=${keypair#*|}
  response_file=$(mktemp) || { tell_warn "临时文件创建失败"; return 1; }
  register_cleanup "$response_file"
  warp_install_id=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
  [ "${#warp_install_id}" -eq 22 ] || { cleanup_release "$response_file"; tell_warn "安装 ID 生成失败"; return 1; }
  while [ "$attempt" -le 8 ]; do
    body=$(warp_make_body "$public" "$warp_install_id") || { attempt=$((attempt+1)); continue; }
    : >"$response_file"
    tell "注册 ${attempt}/8 ..."
    if warp_api_request POST "$WARP_API" '' "$body" "$response_file"; then
      registration_id=$(jq -r '.id // empty' "$response_file" 2>/dev/null)
      registration_token=$(jq -r '.token // empty' "$response_file" 2>/dev/null)
      if [ -n "$registration_id" ] && [ -n "$registration_token" ]; then
        warp_normalize_endpoint "$response_file" || true
        if ! jq -e '.config.peers[0].public_key and .config.peers[0].endpoint.host and (.config.peers[0].endpoint.port|tonumber) and (.config.interface.addresses.v4 or .config.interface.addresses.v6)' "$response_file" >/dev/null 2>&1; then
          refresh_file=$(mktemp)
          register_cleanup "$refresh_file"
          if warp_api_request GET "$WARP_API/$registration_id" "$registration_token" '' "$refresh_file"; then
            warp_normalize_endpoint "$refresh_file" || true
            if jq -e --arg id "$registration_id" '.id==$id and .config.peers[0].public_key and .config.peers[0].endpoint.host and (.config.peers[0].endpoint.port|tonumber) and (.config.interface.addresses.v4 or .config.interface.addresses.v6)' "$refresh_file" >/dev/null 2>&1; then
              jq --arg token "$registration_token" '.token=$token' "$refresh_file" >"$response_file.new" 2>/dev/null && mv -f "$response_file.new" "$response_file"
            fi
          fi
          cleanup_release "$refresh_file"
          rm -f "$response_file.new"
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
    cleanup_release "$response_file"
    if [ "$WARP_HTTP_CODE" = 000 ]; then
      tell_warn "注册失败：无法连接 Cloudflare"
    elif [ -n "$api_error" ]; then
      tell_warn "注册失败：HTTP $WARP_HTTP_CODE $api_error"
    else
      tell_warn "注册失败：HTTP $WARP_HTTP_CODE"
    fi
    return 1
  fi
  if [ -f "$WARP_CONF" ]; then
    cp -p "$WARP_CONF" "${WARP_CONF}.warp_pre_register.bak"
    WARP_PRE_REG_BAK="${WARP_CONF}.warp_pre_register.bak"
  fi
  if ! jq --arg pk "$private" --arg pub "$public" --arg iid "$warp_install_id" --arg mode "$new_ip_target" '{id:.id,token:.token,private_key:$pk,public_key:$pub,install_id:$iid,account:.account,config:.config,warp_mode:$mode,registered_at:(now|todateiso8601)}' "$response_file" | json_write "$WARP_CONF"; then
    cleanup_release "$response_file"
    if [ -n "$WARP_PRE_REG_BAK" ] && [ -f "$WARP_PRE_REG_BAK" ]; then
      cp -p "$WARP_PRE_REG_BAK" "$WARP_CONF" 2>/dev/null || true
      rm -f "$WARP_PRE_REG_BAK"
    fi
    WARP_PRE_REG_BAK=""
    tell_warn "配置保存失败"; return 1
  fi
  cleanup_release "$response_file"
  if [ -n "$old_id" ] && [ -n "$old_token" ] && [ "$old_id" != "$(warp_config_get '.id')" ]; then
    WARP_PENDING_DELETE_ID="$old_id"
    WARP_PENDING_DELETE_TOKEN="$old_token"
  fi
  tell_ok "注册成功"
}

warp_trace(){
  local family=$1 res ip loc colo warp
  case "$family" in
    4) res=$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$WARP_TRACE" 2>/dev/null) || return 1 ;;
    6) res=$(curl -6 -fsS --connect-timeout 5 --max-time 8 "$WARP_TRACE" 2>/dev/null) || return 1 ;;
    *) return 2 ;;
  esac
  res=${res//$'\r'/}
  ip=$(awk -F= '$1=="ip"{print $2;exit}' <<<"$res"); loc=$(awk -F= '$1=="loc"{print $2;exit}' <<<"$res"); colo=$(awk -F= '$1=="colo"{print $2;exit}' <<<"$res"); warp=$(awk -F= '$1=="warp"{print $2;exit}' <<<"$res")
  [ -n "$ip" ] || return 1; printf '%s\t%s\t%s\t%s\n' "$ip" "$loc" "$colo" "$warp"
}

WARP_LAST_TRACE=""
warp_exit_ok(){
  local mode=${1:-$(warp_mode_get)} info4 info6 w4 w6 dual_out attempt=0
  WARP_LAST_TRACE=""
  while [ "$attempt" -lt 5 ]; do
    case "$mode" in
      ipv4)
        info4=$(warp_trace 4) || info4=
        w4=$(cut -f4 <<<"$info4")
        if [ "$w4" = on ] || [ "$w4" = plus ]; then return 0; fi
        if [ -n "$info4" ]; then WARP_LAST_TRACE="IPv4 未走 WARP (warp=${w4:-off})"; else WARP_LAST_TRACE="IPv4 探测超时，请检查宿主机 UDP 2408 或 journalctl -u sing-box"; fi
        ;;
      ipv6)
        info6=$(warp_trace 6) || info6=
        w6=$(cut -f4 <<<"$info6")
        if [ "$w6" = on ] || [ "$w6" = plus ]; then return 0; fi
        if [ -n "$info6" ]; then WARP_LAST_TRACE="IPv6 未走 WARP (warp=${w6:-off})"; else WARP_LAST_TRACE="IPv6 探测超时，请检查宿主机 UDP 2408 或 journalctl -u sing-box"; fi
        ;;
      dual)
        dual_out=$(
          t4=""; t6=""; p4=""; p6=""
          trap 'kill_tree "$p4"; kill_tree "$p6"; rm -f "$t4" "$t6"' EXIT
          t4=$(mktemp) || exit 1; t6=$(mktemp) || exit 1
          trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
          warp_trace 4 >"$t4" 2>/dev/null & p4=$!
          warp_trace 6 >"$t6" 2>/dev/null & p6=$!
          wait "$p4" "$p6" 2>/dev/null || true
          printf '%s\n%s\n' "$(cut -f4 "$t4" 2>/dev/null)" "$(cut -f4 "$t6" 2>/dev/null)"
        )
        w4=$(sed -n '1p' <<<"$dual_out"); w6=$(sed -n '2p' <<<"$dual_out")
        if { [ "$w4" = on ] || [ "$w4" = plus ]; } && { [ "$w6" = on ] || [ "$w6" = plus ]; }; then return 0; fi
        WARP_LAST_TRACE="IPv4=${w4:-超时}, IPv6=${w6:-超时}"
        ;;
      *) return 1 ;;
    esac
    attempt=$((attempt+1))
    [ "$attempt" -lt 5 ] && sleep 2
  done
  return 1
}

warp_show_exit(){
  local mode trace_both info4 info6 ip4 ip6 loc4 loc6 colo4 colo6 warp4 warp6
  mode=$(warp_mode_get)
  trace_both=$(
    t4=""; t6=""; p4=""; p6=""
    trap 'kill_tree "$p4"; kill_tree "$p6"; rm -f "$t4" "$t6"' EXIT
    t4=$(mktemp) || exit 1; t6=$(mktemp) || exit 1
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    warp_trace 4 >"$t4" 2>/dev/null & p4=$!
    warp_trace 6 >"$t6" 2>/dev/null & p6=$!
    wait "$p4" "$p6" 2>/dev/null || true
    printf '%s\n%s\n' "$(cat "$t4" 2>/dev/null)" "$(cat "$t6" 2>/dev/null)"
  )
  info4=$(sed -n '1p' <<<"$trace_both")
  info6=$(sed -n '2p' <<<"$trace_both")
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
  local choice mode old_response was_running=0 cur_exit rc=0
  if ! warp_registered; then
    tell "当前状态：${DIM}未注册${PLAIN}"
    tell ""
    prompt_yes "开始注册" "y" || return
  else
    if [ "$(warp_status)" = running ]; then
      was_running=1
      warp_show_exit
      tell ""
      prompt_yes "是否重新获取出口" "n" || return
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
      2)
        if ! kernel_ipv6_enabled; then tell_warn "当前系统内核未启用 IPv6，仅支持 WARP IPv4 模式"; sleep 1
        else mode=ipv6; break; fi ;;
      3)
        if ! kernel_ipv6_enabled; then tell_warn "当前系统内核未启用 IPv6，仅支持 WARP IPv4 模式"; sleep 1
        else mode=dual; break; fi ;;
      0) return 0 ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
    ui_title "WARP 出口"
    menu_item 1 "IPv4"; menu_item 2 "IPv6"; menu_item 3 "双栈"; menu_item 0 "返回"
    tell ""
  done
  cur_exit=$(state_get exit 2>/dev/null || echo direct)
  if [ "$cur_exit" != direct ] && [ "$cur_exit" != warp ]; then
    prompt_yes "当前 $(exit_label) 正在接管网络。
获取并启动 WARP 后，网络出口将切换至 WARP，并停止当前接管。
是否切换" || return 0
  fi
  tell "正在获取新的 WARP $(case "$mode" in ipv4) printf 'IPv4';; ipv6) printf 'IPv6';; dual) printf '双栈';; esac) 出口..."
  if warp_register "$mode"; then
    tell "正在获取 WARP 出口 IP..."
    warp_start_apply force skip_confirm
    rc=$?
    if [ "$rc" -eq 0 ]; then
      ui_title "WARP 出口"
      tell ""
      tell_ok "已获取新的 WARP $(warp_mode_label) 出口 IP"
      tell ""
      warp_show_exit
      rm -f "${WARP_CONF}.warp_pre_register.bak"
      WARP_PRE_REG_BAK=""
      if [ -n "$WARP_PENDING_DELETE_ID" ] && [ -n "$WARP_PENDING_DELETE_TOKEN" ]; then
        old_response=$(mktemp) || old_response=
        if [ -n "$old_response" ]; then
          register_cleanup "$old_response"
          warp_api_request DELETE "$WARP_API/$WARP_PENDING_DELETE_ID" "$WARP_PENDING_DELETE_TOKEN" '' "$old_response" || true
          cleanup_release "$old_response"
        fi
        WARP_PENDING_DELETE_ID=""
        WARP_PENDING_DELETE_TOKEN=""
      fi
    else
      tell_warn "${WARP_START_ERROR:-新 WARP 出口启用失败}"
      if [ -f "${WARP_CONF}.warp_pre_register.bak" ]; then
        cp -p "${WARP_CONF}.warp_pre_register.bak" "$WARP_CONF" && tell "已回滚至旧 WARP 配置"
        rm -f "${WARP_CONF}.warp_pre_register.bak"
        WARP_PRE_REG_BAK=""; WARP_PENDING_DELETE_ID=""; WARP_PENDING_DELETE_TOKEN=""
        if [ "$was_running" = 1 ]; then
          if state_set exit warp && apply_config_quiet; then
            tell_ok "已恢复原 WARP 出口"
          else
            tell_warn "旧 WARP 配置已还原，但自动恢复失败，请手动启用"
          fi
        fi
      else
        WARP_PRE_REG_BAK=""; WARP_PENDING_DELETE_ID=""; WARP_PENDING_DELETE_TOKEN=""
      fi
    fi
  else
    tell_warn "获取新的 WARP 出口 IP 失败"
    wait_key
    return
  fi
  wait_key
}

warp_stop(){
  local previous
  ui_title "WARP"; tell "正在停止..."
  previous=$(state_get exit) || previous=direct
  if [ "$previous" = warp ]; then
    state_set exit direct || { tell_warn "出口状态更新失败"; wait_key; return 1; }
    if ! apply_config_quiet; then
      state_set exit warp || true
      tell_warn "sing-box 停止 WARP 失败，已恢复状态"; wait_key; return 1
    fi
  fi
  warp_registered && { json_edit "$WARP_CONF" 'del(.started_at)' || true; }
  tell_ok "已停止"
  wait_key
}

WARP_START_ERROR=""
warp_start_apply(){
  local force=${1:-} skip_confirm=${2:-}
  WARP_START_ERROR=""
  warp_registered || { WARP_START_ERROR="请先注册 WARP"; return 1; }
  if [ "$force" != force ]; then
    if ! warp_refresh; then WARP_START_ERROR="WARP 注册信息刷新失败，已停止启动（拒绝使用过期配置）"; return 1; fi
  fi
  local previous mode previous_wg=0 old_started old_tf apply_rc=0 alt_tf
  mode=$(warp_mode_get)
  if ! kernel_ipv6_enabled && [ "$mode" != ipv4 ]; then
    WARP_START_ERROR="当前系统内核未启用 IPv6，无法启用 WARP $(warp_mode_label) 模式"
    return 1
  fi
  warp_transport_select || { WARP_START_ERROR="没有可用的 WARP 上游网络，无法启用 WARP"; return 1; }
  previous=$(state_get exit) || { WARP_START_ERROR="出口状态读取失败"; return 1; }
  [ "$previous" = warp ] && [ "$force" != force ] && previous=direct
  if [ "$previous" != direct ] && [ "$previous" != warp ]; then
    if [ "$skip_confirm" != skip_confirm ]; then
      prompt_yes "当前 $(exit_label) 正在接管网络。
启动 WARP 后，网络出口将切换至 WARP，并停止当前接管。
是否切换" || { WARP_START_ERROR="已取消出口切换"; return 3; }
    fi
    if [ "$previous" = wireguard ] && wg_client_active; then
      wg_set_enabled false || { WARP_START_ERROR="WireGuard 状态更新失败，未启动 WARP"; return 1; }
      previous_wg=1
    fi
  fi
  old_started=$(warp_config_get '.started_at // empty')
  old_tf=$(warp_config_get '.tunnel_family // empty')
  WARP_ROLLBACK_PREV="$previous"; WARP_ROLLBACK_WG="$previous_wg"
  WARP_ROLLBACK_STARTED="$old_started"; WARP_ROLLBACK_TF="$old_tf"
  WARP_ROLLBACK_APPLIED=0; APPLY_CONFIG_INSTALLED=0; WARP_ROLLBACK_ACTIVE=1
  state_set exit warp || { [ "$previous_wg" = 1 ] && wg_set_enabled true || true; WARP_ROLLBACK_ACTIVE=0; WARP_ROLLBACK_APPLIED=0; APPLY_CONFIG_INSTALLED=0; WARP_START_ERROR="出口状态更新失败"; return 1; }
  json_edit "$WARP_CONF" '.started_at=$started' --arg started "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || true
  if ! apply_config_quiet; then
    apply_rc=$?
    local restore_rc=0
    state_set exit "$previous" || restore_rc=2
    if [ "$previous_wg" = 1 ]; then wg_set_enabled true || restore_rc=2; fi
    if [ -n "$old_started" ]; then json_edit "$WARP_CONF" '.started_at=$s' --arg s "$old_started" || true; else json_edit "$WARP_CONF" 'del(.started_at)' || true; fi
    [ "$apply_rc" -eq 2 ] && restore_rc=2
    WARP_ROLLBACK_ACTIVE=0; WARP_ROLLBACK_APPLIED=0; APPLY_CONFIG_INSTALLED=0
    if [ "$restore_rc" -ne 0 ]; then
      WARP_START_ERROR="sing-box WARP 配置启动失败，且恢复原出口失败，请立即检查配置与服务状态"
      return 2
    fi
    WARP_START_ERROR="sing-box WARP 配置启动失败，已恢复原出口"
    return 1
  fi
  WARP_ROLLBACK_APPLIED=1
  sleep 2
  if ! warp_exit_ok "$mode"; then
    local verified=0
    if [ -n "$NET_IPV4" ] && [ -n "$NET_IPV6" ] && [ -n "$NET_IF_V4" ] && [ -n "$NET_IF_V6" ]; then
      local cur_ep_host
      cur_ep_host=$(jq -r '.endpoints[]? | select(.tag=="warp") | .peers[0].address // empty' "$CONFIG" 2>/dev/null)
      if [[ "$cur_ep_host" == *:* ]]; then alt_tf=4; else alt_tf=6; fi
      if json_edit "$WARP_CONF" '.tunnel_family=$tf' --arg tf "$alt_tf" && apply_config_quiet; then
        sleep 2
        if warp_exit_ok "$mode"; then verified=1; fi
      fi
    fi
    if [ "$verified" != 1 ]; then
      local restore_rc=0
      if [ -n "$old_tf" ]; then json_edit "$WARP_CONF" '.tunnel_family=$tf' --arg tf "$old_tf" || true; else json_edit "$WARP_CONF" 'del(.tunnel_family)' || true; fi
      if [ -n "$old_started" ]; then json_edit "$WARP_CONF" '.started_at=$s' --arg s "$old_started" || true; else json_edit "$WARP_CONF" 'del(.started_at)' || true; fi
      if [ "$previous" != warp ]; then
        state_set exit "$previous" || restore_rc=2
        if [ "$previous_wg" = 1 ]; then wg_set_enabled true || restore_rc=2; fi
        apply_config_quiet || restore_rc=2
      fi
      WARP_ROLLBACK_ACTIVE=0; WARP_ROLLBACK_APPLIED=0; APPLY_CONFIG_INSTALLED=0
      if [ "$restore_rc" -ne 0 ]; then
        WARP_START_ERROR="WARP 出口验证失败，且恢复原出口失败，请立即检查配置与服务状态"
        return 2
      fi
      WARP_START_ERROR="WARP 出口验证失败，未确认 Cloudflare WARP 已接管 $(warp_mode_label) 出口${WARP_LAST_TRACE:+（$WARP_LAST_TRACE）}；已恢复原出口"
      return 1
    fi
  fi
  WARP_ROLLBACK_ACTIVE=0; WARP_ROLLBACK_APPLIED=0; APPLY_CONFIG_INSTALLED=0
  return 0
}

warp_start(){
  local rc
  ui_title "WARP"
  tell "正在启动..."
  warp_start_apply
  rc=$?
  if [ "$rc" -eq 3 ]; then
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    tell_warn "${WARP_START_ERROR:-WARP 启动失败}"
    wait_key
    return "$rc"
  fi
  tell_ok "启动成功，当前为 WARP $(case "$(warp_mode_get)" in ipv4) echo "单 IPv4 出口";; ipv6) echo "单 IPv6 出口";; dual) echo "双栈出口";; esac)"
  warp_show_exit
  wait_key
}

warp_status_view(){
  ui_title "WARP 状态"
  case "$(warp_status)" in unconfigured) tell "状态：${DIM}未配置${PLAIN}"; wait_key; return;; stopped) tell "状态：${YELLOW}未启用${PLAIN}"; wait_key; return;; esac
  tell "${DIM}正在检测 WARP 状态...${PLAIN}"
  local mode trace_both info4 info6 ip4 ip6 loc4 loc6 colo4 colo6 warp4 warp6 started now created up_secs up_h up_m confirmed=0
  mode=$(warp_mode_get)
  trace_both=$(
    t4=""; t6=""; p4=""; p6=""
    trap 'kill_tree "$p4"; kill_tree "$p6"; rm -f "$t4" "$t6"' EXIT
    t4=$(mktemp) || exit 1; t6=$(mktemp) || exit 1
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    warp_trace 4 >"$t4" 2>/dev/null & p4=$!
    warp_trace 6 >"$t6" 2>/dev/null & p6=$!
    wait "$p4" "$p6" 2>/dev/null || true
    printf '%s\n%s\n' "$(cat "$t4" 2>/dev/null)" "$(cat "$t6" 2>/dev/null)"
  )
  info4=$(sed -n '1p' <<<"$trace_both")
  info6=$(sed -n '2p' <<<"$trace_both")
  ip4=$(cut -f1 <<<"$info4"); loc4=$(cut -f2 <<<"$info4"); colo4=$(cut -f3 <<<"$info4"); warp4=$(cut -f4 <<<"$info4")
  ip6=$(cut -f1 <<<"$info6"); loc6=$(cut -f2 <<<"$info6"); colo6=$(cut -f3 <<<"$info6"); warp6=$(cut -f4 <<<"$info6")
  case "$mode" in
    ipv4) [ "$warp4" = on ] || [ "$warp4" = plus ] && confirmed=1 ;;
    ipv6) [ "$warp6" = on ] || [ "$warp6" = plus ] && confirmed=1 ;;
    dual) { [ "$warp4" = on ] || [ "$warp4" = plus ]; } && { [ "$warp6" = on ] || [ "$warp6" = plus ]; } && confirmed=1 ;;
  esac
  ui_title "WARP 状态"
  if [ "$confirmed" = 1 ]; then tell "WARP：${GREEN}Cloudflare 已确认${PLAIN}"; else tell "WARP：${YELLOW}尚未确认${PLAIN}"; fi
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
  tell ""; tell "${YELLOW}⚠ 将删除 WARP 配置及注册信息${PLAIN}"; tell ""; prompt_yes "确认删除" || return
  local id token response_file previous remote_delete_ok=1 local_delete_ok=1 apply_ok=1
  previous=$(state_get exit) || previous=direct
  id=$(warp_config_get '.id'); token=$(warp_config_get '.token')
  if [ -n "$id" ] && [ -n "$token" ]; then
    if warp_transport_select; then
      response_file=$(mktemp) || response_file=
      if [ -n "$response_file" ]; then
        register_cleanup "$response_file"
        warp_api_request DELETE "$WARP_API/$id" "$token" '' "$response_file" || remote_delete_ok=0
        cleanup_release "$response_file"
      else
        remote_delete_ok=0
      fi
    else
      remote_delete_ok=0
    fi
  fi
  if [ "$previous" = warp ]; then
    state_set exit direct || { tell_warn "出口状态更新失败，未删除 WARP 配置"; wait_key; return 1; }
  fi
  rm -rf "$WARP_DIR" || local_delete_ok=0
  if [ "$previous" = warp ]; then apply_config_quiet || apply_ok=0; fi
  if [ "$local_delete_ok" -eq 1 ] && [ "$remote_delete_ok" -eq 1 ] && [ "$apply_ok" -eq 1 ]; then
    tell_ok "WARP 配置已删除"
  elif [ "$local_delete_ok" -eq 1 ]; then
    tell_warn "本地 WARP 配置已删除，但远程注销或运行配置清理未全部成功"
  else
    tell_warn "WARP 本地配置目录删除失败，请检查文件权限"
  fi
  wait_key
}

menu_warp(){
  while :; do
    ui_title "WARP 管理"
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
    sync_resolved_dns_route
  else
    rm -f "$CONFIG" || return 1
    timeout 15 systemctl stop sing-box >/dev/null 2>&1 || return 1
    systemctl is-active --quiet sing-box && return 1 || true
    sync_resolved_dns_route
  fi
}

apply_config(){
  local tmp error line guard=0 prev_conf=""
  APPLY_CONFIG_INSTALLED=0
  exec 8>"$CONFIG_LOCK" || { tell_warn "配置锁创建失败"; return 1; }
  flock -w 30 8 || { tell_warn "配置正在被其他任务修改"; exec 8>&-; return 1; }
  tmp=$(mktemp) || { flock -u 8; exec 8>&-; return 1; }
  register_cleanup "$tmp"
  if [ -f "$CONFIG" ]; then
    prev_conf=$(mktemp) || { cleanup_release "$tmp"; flock -u 8; exec 8>&-; tell_warn "配置备份文件创建失败"; return 1; }
    register_cleanup "$prev_conf"
    cp "$CONFIG" "$prev_conf" || { cleanup_release "$tmp" "$prev_conf"; flock -u 8; exec 8>&-; tell_warn "配置备份失败"; return 1; }
  fi
  build_config >"$tmp" 2>/dev/null || { cleanup_release "$tmp" "$prev_conf"; flock -u 8; exec 8>&-; tell_warn "配置生成失败"; return 1; }
  [ -s "$tmp" ] || { cleanup_release "$tmp" "$prev_conf"; flock -u 8; exec 8>&-; tell_warn "配置写入异常"; return 1; }
  if ! error=$("$CORE" check -c "$tmp" 2>&1); then
    tell_warn "配置校验未通过:"
    while IFS= read -r line; do tell "$line"; done <<<"$(head -4 <<<"$error")"
    cleanup_release "$tmp" "$prev_conf"; flock -u 8; exec 8>&-; return 1
  fi
  if ! install -m600 "$tmp" "$CONFIG"; then
    cleanup_release "$tmp" "$prev_conf"; flock -u 8; exec 8>&-
    tell_warn "配置安装失败"
    return 1
  fi
  APPLY_CONFIG_INSTALLED=1
  cleanup_release "$tmp"
  if ! timeout 15 systemctl restart sing-box >/dev/null 2>&1; then
    tell_warn "sing-box 重载/重启失败，正在回滚配置"
    if ! restore_config "$prev_conf"; then
      cleanup_release "$prev_conf"; flock -u 8; exec 8>&-; return 2
    fi
    APPLY_CONFIG_INSTALLED=0
    cleanup_release "$prev_conf"
    sync_hopping_rules || { flock -u 8; exec 8>&-; return 2; }
    flock -u 8; exec 8>&-; return 1
  fi
  sleep 1
  if systemctl is-failed --quiet sing-box 2>/dev/null; then
    tell_warn "sing-box 重载后进入失败状态，正在回滚配置"
    if ! restore_config "$prev_conf"; then
      cleanup_release "$prev_conf"; flock -u 8; exec 8>&-; return 2
    fi
    APPLY_CONFIG_INSTALLED=0
    cleanup_release "$prev_conf"
    sync_hopping_rules || { flock -u 8; exec 8>&-; return 2; }
    flock -u 8; exec 8>&-; return 1
  fi
  while ! systemctl is-active --quiet sing-box; do
    sleep 0.2; guard=$((guard+1)); [ "$guard" -gt 50 ] && break
  done
  if ! systemctl is-active --quiet sing-box; then
    tell_warn "服务启动异常:"
    while IFS= read -r line; do tell "$line"; done <<<"$(journalctl -u sing-box -n 5 --no-pager 2>/dev/null)"
    if ! restore_config "$prev_conf"; then
      cleanup_release "$prev_conf"; flock -u 8; exec 8>&-; return 2
    fi
    APPLY_CONFIG_INSTALLED=0
    cleanup_release "$prev_conf"
    sync_hopping_rules || { flock -u 8; exec 8>&-; return 2; }
    flock -u 8; exec 8>&-; return 1
  fi
  if ! sync_hopping_rules; then
    tell_warn "跳跃规则同步失败，正在回滚配置"
    if ! restore_config "$prev_conf"; then
      cleanup_release "$prev_conf"; flock -u 8; exec 8>&-; return 2
    fi
    APPLY_CONFIG_INSTALLED=0
    cleanup_release "$prev_conf"
    sync_hopping_rules || { flock -u 8; exec 8>&-; return 2; }
    flock -u 8; exec 8>&-; return 1
  fi
  cleanup_release "$prev_conf"
  sync_resolved_dns_route
  flock -u 8; exec 8>&-
  return 0
}

apply_config_quiet(){ apply_config >/dev/null 2>&1; }

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
  local index target=$1 title=${2:-选择节点} count row node_file kind port name proto
  local -a files
  [ -n "$target" ] || return 2
  while :; do
    ui_title "$title"
    count=0; files=()
    set -- "$NODE_DIR"/*.json
    [ "$#" -gt 0 ] || { tell "系统内暂无节点"; wait_key; return 1; }
    local tcp_list udp_list
    tcp_list=$(listening_ports t 2>/dev/null) || tcp_list=""
    udp_list=$(listening_ports u 2>/dev/null) || udp_list=""
    for node_file in "$@"; do
      [ -e "$node_file" ] || continue
      count=$((count+1)); files+=("$node_file")
      if ! row=$(jq -c '{kind:(.kind//"-"),port:(.port//"-"),name:(.name//"-"),proto:(.proto//"-")}' "$node_file" 2>/dev/null); then
        printf '%b%d.%b %b%s-%b配置损坏%b\n' "$BOLD$CYAN" "$count" "$PLAIN" "$BOLD$WHITE" "$(basename "$node_file")" "$BOLD$RED" "$PLAIN"
        continue
      fi
      kind=$(jq -r '.kind' <<<"$row"); port=$(jq -r '.port' <<<"$row")
      name=$(jq -r '.name' <<<"$row"); proto=$(jq -r '.proto' <<<"$row")
      local status_text color display_kind name_display
      if [ "$kind" = "shadowsocks" ]; then
        { grep -qx "$port" <<<"$tcp_list" || grep -qx "$port" <<<"$udp_list"; } && { color="$GREEN"; status_text="正常"; } || { color="$RED"; status_text="异常"; }
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
        vmess|vmess-tls|vmess-ws|vmess-grpc|vmess-http) display_kind="VMess" ;;
        anytls) display_kind="AnyTLS" ;;
        socks) display_kind="SOCKS5" ;;
        snell) display_kind="Snell" ;;
        *) display_kind="$kind" ;;
      esac
      name_display=$(jq -rn --arg s "$name" 'if ($s|length)>20 then ($s|.[0:20])+"\u2026" else $s end')
      printf '%b%d.%b %b%s-%s-%s-%b%s%b\n' \
        "$BOLD$CYAN" "$count" "$PLAIN" "$BOLD$WHITE" "$display_kind" "$name_display" "$port" \
        "$BOLD$color" "$status_text" "$PLAIN"
    done
    [ "$count" = 0 ] && { wait_key; return 1; }
    menu_item 0 "返回"
    index=$(prompt "请选择 (回车刷新)")
    [ -z "$index" ] && continue
    [ "$index" = 0 ] && return 1
    if is_pos_int "$index" && [ "$index" -le "$count" ]; then
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
  local d_low; d_low=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
  for dir in "$ACME_DIR"/certificates/*/"$d_low"; do
    [ -d "$dir" ] || continue
    rm -rf -- "$dir" || rc=1
  done
  return "$rc"
}

acme_domain_assets_exist(){
  local domain=$1 dir
  [ -n "$domain" ] || return 1
  local d_low; d_low=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
  for dir in "$ACME_DIR"/certificates/*/"$d_low"; do
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
  [ -n "$pid" ] && stop_pid_graceful "$pid"
  [ -n "$tmp" ] && rm -f -- "$tmp"
  [ -n "$log_file" ] && rm -f -- "$log_file"
}

server_change_domain_transaction(){
  local new_domain=$1 old_state=$2 had_new_assets=${3:-0}
  local tmp log_file pid old_domain apply_rc=0
  old_domain=$(jq -r '.domain // ""' <<<"$old_state")

  state_set domain "$new_domain" || return 2
  tmp=$(mktemp) || { state_restore "$old_state" || tell_warn "状态回滚失败，请手动检查"; return 2; }
  register_cleanup "$tmp"
  if ! jq -n --argjson p "$(acme_options "$new_domain")" '{log:{level:"warn",timestamp:true},certificate_providers:[($p+{type:"acme",tag:"acme-temporary"})]}' >"$tmp" 2>/dev/null; then
    cleanup_release "$tmp"
    state_restore "$old_state" || tell_warn "状态回滚失败，请手动检查"
    return 2
  fi
  if ! "$CORE" check -c "$tmp" >/dev/null 2>&1; then
    cleanup_release "$tmp"
    state_restore "$old_state" || tell_warn "状态回滚失败，请手动检查"
    return 3
  fi
  log_file=$(mktemp) || {
    cleanup_release "$tmp"
    state_restore "$old_state" || tell_warn "状态回滚失败，请手动检查"
    return 4
  }
  register_cleanup "$log_file"
  "$CORE" run -c "$tmp" >"$log_file" 2>&1 &
  pid=$!
  CERT_BG_PID=$pid
  if wait_for_certificate "$new_domain" "$pid" "$log_file"; then
    server_change_domain_process_cleanup "$pid" "$tmp" "$log_file"; unregister_cleanup "$tmp"; unregister_cleanup "$log_file"; CERT_BG_PID=""
    if apply_config; then
      if [ -n "$old_domain" ] && [ "${old_domain,,}" != "${new_domain,,}" ] && ! cleanup_old_domain_assets "$old_domain"; then
        tell_warn "旧域名证书清理失败，但新域名已成功切换；请稍后手动清理旧证书"
      fi
      return 0
    else
      apply_rc=$?
    fi
    server_change_domain_rollback "$old_state" "$new_domain" "$had_new_assets" || true
    [ "$apply_rc" -eq 2 ] && { apply_config_quiet || true; }
    return 5
  fi

  server_change_domain_process_cleanup "$pid" "$tmp" "$log_file"; unregister_cleanup "$tmp"; unregister_cleanup "$log_file"; CERT_BG_PID=""
  if ! server_change_domain_rollback "$old_state" "$new_domain" "$had_new_assets"; then
    return 5
  fi
  return 4
}

server_delete_node(){
  local file=$1
  [ -f "$file" ] || return 2
  rm -f -- "$file" || return 2
  apply_config || return 4
  return 0
}
server_node_rollback(){
  local file=$1 old_state=$2 need_apply=${3:-1} rc=0
  rm -f "$file" || rc=1
  state_restore "$old_state" || rc=1
  if [ "$need_apply" = 1 ]; then
    apply_config_quiet || rc=1
  else
    sync_hopping_rules || rc=1
  fi
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
  local file=$1 content=$2 old_state apply_rc=0
  if [ -n "$CERT_PRE_STATE" ]; then
    old_state="$CERT_PRE_STATE"
  else
    old_state=$(state_snapshot) || return 2
    CERT_PRE_STATE="$old_state"
  fi
  CERT_PENDING_NODE="$file"
  CERT_PENDING_APPLIED=0
  APPLY_CONFIG_INSTALLED=0
  json_save "$file" "$content" || {
    CERT_PENDING_NODE=""; CERT_PRE_STATE=""; APPLY_CONFIG_INSTALLED=0
    state_restore "$old_state" || true
    return 2
  }
  if apply_config; then
    CERT_PENDING_APPLIED=1
    if ! server_node_wait_for_certificate "$file"; then
      CERT_PENDING_NODE=""; CERT_PENDING_APPLIED=0; CERT_PRE_STATE=""; APPLY_CONFIG_INSTALLED=0
      server_node_rollback "$file" "$old_state" 1 || return 4
      return 3
    fi
    CERT_PENDING_NODE=""; CERT_PENDING_APPLIED=0; CERT_PRE_STATE=""; APPLY_CONFIG_INSTALLED=0
    return 0
  else
    apply_rc=$?
  fi
  CERT_PENDING_NODE=""; CERT_PENDING_APPLIED=0; CERT_PRE_STATE=""; APPLY_CONFIG_INSTALLED=0
  server_node_rollback "$file" "$old_state" "$([ "$apply_rc" -eq 2 ] && echo 1 || echo 0)" || return 4
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

ss_generate_key(){
  local method=$1 len
  len=$(ss_key_length "$method")
  if [ "$len" -gt 0 ]; then
    openssl rand -base64 "$len" 2>/dev/null | tr -d '\n'
  else
    random_password
  fi
}

valid_uuid(){
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

ss_valid_key(){
  local method=$1 key=$2 need raw_len
  need=$(ss_key_length "$method"); [ "$need" -eq 0 ] && { [ -n "$key" ]; return; }
  [[ "$key" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  printf '%s' "$key" | base64 -d >/dev/null 2>&1 || return 1
  raw_len=$(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c)
  [ "$raw_len" -eq "$need" ]
}

prompt_uuid(){
  local uuid
  while :; do
    uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)")
    valid_uuid "$uuid" && { printf '%s' "$uuid"; return 0; }
    tell_warn "UUID 格式无效" >&2
  done
}

create_shadowsocks(){
  local method=${1:-2022-blake3-aes-256-gcm} name port password tag body
  ui_title "创建 Shadowsocks"
  name=$(prompt "节点名称" "Shadowsocks")
  port=$(prompt_port tu "")
  while :; do
    password=$(prompt "密码/密钥 (留空自动生成)" "$(ss_generate_key "$method")")
    [ -n "$password" ] && ss_valid_key "$method" "$password" && break
    tell_warn "密钥长度与加密方式不匹配"
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --arg method "$method" --arg password "$password" --argjson port "$port" '
    {tag:$tag,name:$name,kind:"shadowsocks",port:$port,proto:"tu",hopping:"",tls_mode:"none",alpn:null,
     meta:{method:$method,password:$password},
     inbound:{type:"shadowsocks",tag:$tag,listen:$listen_addr,listen_port:$port,method:$method,password:$password,
       multiplex:{enabled:true}}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vless_transport(){
  local transport=$1 name port uuid tag body path service
  ui_title "创建 VLESS-${transport^^}"
  name=$(prompt "节点名称" "VLESS-${transport^^}")
  setup_certificate || return
  port=$(prompt_port t "")
  uuid=$(prompt_uuid)
  case "$transport" in
    ws) path=$(prompt "WebSocket Path" "/ws"); service="" ;;
    grpc) service=$(prompt "gRPC Service Name" "TunService"); path="" ;;
    *) return 1 ;;
  esac
  [ -n "$path" ] && [ "${path:0:1}" != "/" ] && path="/$path"
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" --arg uuid "$uuid" \
        --arg transport "$transport" --arg path "$path" --arg service "$service" '
   {tag:$tag,name:$name,kind:("vless-"+$transport),port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,
    meta:{uuid:$uuid,transport:$transport,path:$path,service_name:$service},
    inbound:({type:"vless",tag:$tag,listen:$listen_addr,listen_port:$port,users:[{uuid:$uuid}],
      tls:{enabled:true},transport:{type:(if $transport=="ws" then "ws" else "grpc" end)}}
      | if $transport=="ws" then .transport.path=$path else .transport.service_name=$service end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_trojan_transport(){
  local transport=$1 name port password tag body path service
  ui_title "创建 Trojan-${transport^^}"
  name=$(prompt "节点名称" "Trojan-${transport^^}")
  setup_certificate || return
  port=$(prompt_port t "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  case "$transport" in
    ws) path=$(prompt "WebSocket Path" "/ws"); service="" ;;
    grpc) service=$(prompt "gRPC Service Name" "TunService"); path="" ;;
    *) return 1 ;;
  esac
  [ -n "$path" ] && [ "${path:0:1}" != "/" ] && path="/$path"
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" --arg password "$password" \
        --arg transport "$transport" --arg path "$path" --arg service "$service" '
   {tag:$tag,name:$name,kind:("trojan-"+$transport),port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,
    meta:{password:$password,transport:$transport,path:$path,service_name:$service},
    inbound:({type:"trojan",tag:$tag,listen:$listen_addr,listen_port:$port,users:[{password:$password}],tls:{enabled:true},
      transport:{type:(if $transport=="ws" then "ws" else "grpc" end)}}
      | if $transport=="ws" then .transport.path=$path else .transport.service_name=$service end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vmess(){
  local transport=${1:-tls} name port uuid tag body path service security
  ui_title "创建 VMess-${transport^^}"
  name=$(prompt "节点名称" "VMess")
  setup_certificate || return
  port=$(prompt_port t "")
  uuid=$(prompt_uuid)
  menu_item 1 "Auto"; menu_item 2 "AES-128-GCM"; menu_item 3 "ChaCha20-Poly1305"
  while :; do
    case $(prompt "加密方式" 1) in
      1) security=auto; break ;; 2) security=aes-128-gcm; break ;; 3) security=chacha20-poly1305; break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1
          ui_title "创建 VMess-${transport^^}"
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
  [ -n "$path" ] && [ "${path:0:1}" != "/" ] && path="/$path"
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" --arg uuid "$uuid" --arg security "$security" \
        --arg transport "$transport" --arg path "$path" --arg service "$service" '
   {tag:$tag,name:$name,kind:("vmess-"+$transport),port:$port,proto:"t",hopping:"",tls_mode:"acme",alpn:null,
    meta:{uuid:$uuid,security:$security,transport:$transport,path:$path,service_name:$service},
    inbound:({type:"vmess",tag:$tag,listen:$listen_addr,listen_port:$port,users:[{uuid:$uuid,alterId:0}],tls:{enabled:true},transport:{}}
      | if $transport=="ws" then .transport={type:"ws",path:$path}
        elif $transport=="grpc" then .transport={type:"grpc",service_name:$service}
        elif $transport=="http" then .transport={type:"http",path:$path}
        else del(.transport) end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vless_reality(){
  local name port uuid target keypair private public short_id tag body default_sid
  ui_title "创建 VLESS-Reality"
  name=$(prompt "节点名称" "VLESS-Reality")
  port=$(prompt_port t "")
  uuid=$(prompt_uuid)
  while :; do
    target=$(sanitize_domain "$(prompt "握手目标域名" "www.microsoft.com")")
    [ -n "$target" ] || { tell_warn "域名无效"; continue; }
    probe_handshake_target "$target" && break
    prompt_yes "是否强制使用此域名" && break
  done
  keypair=$("$CORE" generate reality-keypair) || { tell_warn "密钥生成失败"; wait_key; return; }
  private=$(awk '/PrivateKey/{print $2}' <<<"$keypair")
  public=$(awk '/PublicKey/{print $2}' <<<"$keypair")
  [ -n "$private" ] && [ -n "$public" ] || { tell_warn "密钥生成失败"; wait_key; return; }
  default_sid=$(openssl rand -hex 8)
  while :; do
    short_id=$(prompt "short_id (留空自动生成 2-16位偶数十六进制)" "$default_sid")
    local sid_len=${#short_id}
    [ $((sid_len % 2)) -eq 0 ] 2>/dev/null || { tell_warn "short_id 必须为偶数长度的十六进制字符"; continue; }
    [[ $short_id =~ ^[0-9a-fA-F]{2,16}$ ]] || { tell_warn "short_id 必须为 2-16 位十六进制字符"; continue; }
    break
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" --arg uuid "$uuid" \
        --arg target "$target" --arg private "$private" --arg public "$public" --arg sid "$short_id" '
   {tag:$tag,name:$name,kind:"vless-reality",port:$port,proto:"t",hopping:"",
    tls_mode:"reality",alpn:null,
    meta:{uuid:$uuid,target:$target,public_key:$public,short_id:$sid},
    inbound:{type:"vless",tag:$tag,listen:$listen_addr,listen_port:$port,
      users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],
      tls:{enabled:true,server_name:$target,
        reality:{enabled:true,private_key:$private,short_id:[$sid],
          handshake:{server:$target,server_port:443}}}}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vless_tls(){
  local name port uuid tag body
  ui_title "创建 VLESS-TLS"
  name=$(prompt "节点名称" "VLESS-TLS")
  setup_certificate || return
  port=$(prompt_port t "")
  uuid=$(prompt_uuid)
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" --arg uuid "$uuid" '
   {tag:$tag,name:$name,kind:"vless-tls",port:$port,proto:"t",hopping:"",
    tls_mode:"acme",alpn:null,
    meta:{uuid:$uuid},
    inbound:{type:"vless",tag:$tag,listen:$listen_addr,listen_port:$port,
      users:[{uuid:$uuid,flow:"xtls-rprx-vision"}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_hysteria2(){
  local name port password hopping tag body up_mbps down_mbps obfs_type obfs_password bbr_profile
  local min_pkt max_pkt cc_choice
  ui_title "创建 Hysteria2"
  name=$(prompt "节点名称" "Hysteria2")
  setup_certificate || return
  port=$(prompt_port u "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  bbr_profile=""; up_mbps=0; down_mbps=0
  tell "拥塞控制:"
  menu_item 1 "BBR conservative"
  menu_item 2 "BBR standard"
  menu_item 3 "BBR aggressive"
  menu_item 4 "Brutal (需手动设置带宽)"
  while :; do
    cc_choice=$(prompt "请选择拥塞控制" 2)
    case "$cc_choice" in
      1) bbr_profile="conservative"; up_mbps=0; down_mbps=0; break ;;
      2) bbr_profile="standard"; up_mbps=0; down_mbps=0; break ;;
      3) bbr_profile="aggressive"; up_mbps=0; down_mbps=0; break ;;
      4)
        bbr_profile=""
        while :; do
          up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" "0")
          is_uint "$up_mbps" || { tell_warn "输入无效，请重新输入"; continue; }
          down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "0")
          is_uint "$down_mbps" || { tell_warn "输入无效，请重新输入"; continue; }
          if [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ]; then break; fi
          tell_warn "Brutal 模式至少需要设置一个方向的带宽"
        done
        break ;;
      *)
        tell_warn "输入无效，请重新选择"; sleep 1
        ui_title "创建 Hysteria2"; tell "拥塞控制:"
        menu_item 1 "BBR conservative"; menu_item 2 "BBR standard"; menu_item 3 "BBR aggressive"; menu_item 4 "Brutal (需手动设置带宽)"
        ;;
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
           ui_title "创建 Hysteria2"
           menu_item 1 "Salamander"; menu_item 2 "Gecko" ;;
      esac
    done
    obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$password")
    if [ "$obfs_type" = "gecko" ]; then
      while :; do
        min_pkt=$(prompt "最小包大小 (字节, 512-2048)" "512")
        is_pos_int "$min_pkt" && [ "$min_pkt" -ge 512 ] && [ "$min_pkt" -le 2048 ] && break
        tell_warn "最小包大小必须为 512-2048"
      done
      while :; do
        max_pkt=$(prompt "最大包大小 (字节, 512-2048)" "1200")
        is_pos_int "$max_pkt" && [ "$max_pkt" -ge 512 ] && [ "$max_pkt" -le 2048 ] && [ "$max_pkt" -ge "$min_pkt" ] && break
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
        validate_range "$hopping" "$port" && break
      done
    fi
  fi
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" \
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
    inbound:({type:"hysteria2",tag:$tag,listen:$listen_addr,listen_port:$port,
      users:[{password:$password}]}
      | if $up > 0 then .up_mbps=$up else . end
      | if $down > 0 then .down_mbps=$down else . end
      | if $bbr != "" then .bbr_profile=$bbr | .ignore_client_bandwidth=true else . end
      | if $obfs_type != "" then .obfs={type:$obfs_type, password:$obfs_pw} else . end
      | if $obfs_type == "gecko" and $min_pkt != "" then .obfs.min_packet_size=($min_pkt|tonumber) else . end
      | if $obfs_type == "gecko" and $max_pkt != "" then .obfs.max_packet_size=($max_pkt|tonumber) else . end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_tuic(){
  local name port uuid password tag body congestion
  ui_title "创建 TUIC"
  name=$(prompt "节点名称" "TUIC")
  setup_certificate || return
  port=$(prompt_port u "")
  uuid=$(prompt_uuid)
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  menu_item 1 "cubic"; menu_item 2 "New Reno"; menu_item 3 "bbr"
  while :; do
    case $(prompt "拥塞控制" 3) in
      1) congestion=cubic; break ;; 2) congestion=new_reno; break ;; 3) congestion=bbr; break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1
         ui_title "创建 TUIC"
         menu_item 1 "cubic"; menu_item 2 "New Reno"; menu_item 3 "bbr" ;;
    esac
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" \
        --arg uuid "$uuid" --arg password "$password" --arg congestion "$congestion" '
   {tag:$tag,name:$name,kind:"tuic",port:$port,proto:"u",hopping:"",
    tls_mode:"acme",alpn:["h3"],
    meta:{uuid:$uuid,password:$password,congestion_control:$congestion},
    inbound:{type:"tuic",tag:$tag,listen:$listen_addr,listen_port:$port,
      users:[{uuid:$uuid,password:$password}],congestion_control:$congestion}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_trojan(){
  local name port password tag body
  ui_title "创建 Trojan"
  name=$(prompt "节点名称" "Trojan")
  setup_certificate || return
  port=$(prompt_port t "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" --arg password "$password" '
   {tag:$tag,name:$name,kind:"trojan",port:$port,proto:"t",hopping:"",
    tls_mode:"acme",alpn:null,
    meta:{password:$password},
    inbound:{type:"trojan",tag:$tag,listen:$listen_addr,listen_port:$port,
      users:[{password:$password}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_anytls(){
  local name port password tag body client_meta
  ui_title "创建 AnyTLS"
  name=$(prompt "节点名称" "AnyTLS")
  setup_certificate || return
  port=$(prompt_port t "")
  password=$(prompt "连接密码 (留空自动生成)" "$(random_password)")
  client_meta=$(prompt "客户端元数据 (留空则为空)" "")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" --arg password "$password" --arg meta "$client_meta" '
   {tag:$tag,name:$name,kind:"anytls",port:$port,proto:"t",hopping:"",
    tls_mode:"acme",alpn:null,
    meta:({password:$password}
      | if $meta != "" then .client_metadata=$meta else . end),
    inbound:{type:"anytls",tag:$tag,listen:$listen_addr,listen_port:$port,
      users:[{password:$password}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_socks(){
  local name username password port tag body
  ui_title "创建 SOCKS5"
  name=$(prompt "节点名称" "Socks5")
  port=$(prompt_port t "")
  username=$(prompt "鉴权账号" "admin")
  password=$(prompt "鉴权密码 (留空自动生成)" "$(random_password)")
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" \
        --arg username "$username" --arg password "$password" '
   {tag:$tag,name:$name,kind:"socks",port:$port,proto:"t",hopping:"",
    tls_mode:"none",alpn:null,
    meta:{username:$username,password:$password},
    inbound:{type:"socks",tag:$tag,listen:$listen_addr,listen_port:$port,
      users:[{username:$username,password:$password}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_snell(){
  local name port psk mode tag body len
  ui_title "创建 Snell"
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
         ui_title "创建 Snell"
         menu_item 1 "Default"; menu_item 2 "Unshaped"; menu_item 3 "Unsafe Raw" ;;
    esac
  done
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  local listen_addr="::"; ! kernel_ipv6_enabled && listen_addr="0.0.0.0"
  body=$(jq -n --arg tag "$tag" --arg name "$name" --arg listen_addr "$listen_addr" --argjson port "$port" \
        --arg psk "$psk" --arg mode "$mode" '
   {tag:$tag,name:$name,kind:"snell",port:$port,proto:"t",hopping:"",
    tls_mode:"none",alpn:null,
    meta:{psk:$psk,mode:$mode},
    inbound:{type:"snell",tag:$tag,listen:$listen_addr,listen_port:$port,
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

peer_delete_apply(){
  local file=$1 current tag rc=0
  [ -f "$file" ] || return 2
  current=$(state_get exit) || return 2
  tag=$(client_peer_tag "$file"); [ -n "$tag" ] || tag=$(basename "$file" .json)
  if [ "$tag" = "$current" ]; then
    state_set exit direct || return 3
  fi
  rm -f -- "$file" || rc=2
  if [ "$tag" = "$current" ]; then
    apply_config || { [ "$rc" -ne 0 ] && return 6; return 1; }
    [ "$rc" -ne 0 ] && return 5
  fi
  return "$rc"
}

peer_select_transaction(){
  local file=$1 tag target_name previous wg_was_active=0 apply_rc=0 restore_rc=0
  tag=$(client_peer_tag "$file"); target_name=$(client_peer_name "$file"); previous=$(state_get exit) || return 1
  [ -n "$tag" ] || { tell_warn "节点配置已损坏，请先删除"; return 4; }
  if [ "$previous" = warp ]; then
    prompt_yes "当前 WARP 正在接管网络。
选择 ${target_name} 后，网络出口将切换至 ${target_name}，并停止 WARP。
是否切换" || return 3
  fi
  if wg_client_active; then
    prompt_yes "当前 WireGuard 客户端正在接管网络。
启动 ${target_name} 后，网络出口将切换至 ${target_name}。
是否切换" || return 3
    wg_set_enabled false || return 1
    wg_was_active=1
  fi
  state_set exit "$tag" || { [ "$wg_was_active" = 1 ] && wg_set_enabled true || true; return 1; }
  if apply_config; then
    [ "$previous" = warp ] && warp_registered && { json_edit "$WARP_CONF" 'del(.started_at)' || true; }
    tell_ok "已接管: $target_name"
    return 0
  else
    apply_rc=$?
  fi
  state_set exit "$previous" || { tell_warn "出口状态恢复失败，请手动检查"; restore_rc=2; }
  if [ "$wg_was_active" = 1 ]; then
    wg_set_enabled true || { tell_warn "WireGuard 状态恢复失败，请手动检查"; restore_rc=2; }
  fi
  [ "$apply_rc" -eq 2 ] && restore_rc=2
  return "$([ "$restore_rc" -ne 0 ] && echo 2 || echo 1)"
}

peer_stop_transaction(){
  local previous wg_was_active=0 apply_rc=0 restore_rc=0
  previous=$(state_get exit) || return 1
  if [ "$previous" = direct ] && ! wg_client_active; then return 0; fi
  if wg_client_active; then
    wg_set_enabled false || return 1
    wg_was_active=1
  fi
  state_set exit direct || { [ "$wg_was_active" = 1 ] && wg_set_enabled true || true; return 1; }
  if apply_config; then
    [ "$previous" = warp ] && warp_registered && { json_edit "$WARP_CONF" 'del(.started_at)' || true; }
    return 0
  else
    apply_rc=$?
  fi
  state_set exit "$previous" || { tell_warn "出口状态恢复失败，请手动检查"; restore_rc=2; }
  if [ "$wg_was_active" = 1 ]; then wg_set_enabled true || { tell_warn "WireGuard 状态恢复失败，请手动检查"; restore_rc=2; }; fi
  [ "$apply_rc" -eq 2 ] && restore_rc=2
  return "$([ "$restore_rc" -ne 0 ] && echo 2 || echo 1)"
}

peer_add(){
  local name uri tag outbound probe ip resolved_hosts local_ipv4 local_ipv6 server
  reload_net_cache
  ui_title "添加节点"
  name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return
  uri=$(prompt "节点链接"); [ -n "$uri" ] || return
  local uri_context
  uri_context=$(parse_uri "$uri") || { tell_warn "节点链接格式无效"; wait_key; return; }
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag" "$uri_context") || { tell_warn "无法解析"; wait_key; return; }
  server=$(jq -r '.server // empty' <<<"$outbound")
  [ -n "$server" ] || { tell_warn "无法从节点链接提取服务器地址"; wait_key; return; }
  local server_l; server_l=$(trim_host "$server" | tr '[:upper:]' '[:lower:]')
  case "$server_l" in 127.*|::1|0:0:0:0:0:0:0:1|::|::0|0:0:0:0:0:0:0:0|0.0.0.0|::ffff:127.*|::ffff:7f00:*)
    tell_warn "禁止自环接入"; wait_key; return ;;
  esac
  local_ipv4=$(ip -4 -o addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')
  local_ipv6=$(ip -6 -o addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print tolower($4)}')
  resolved_hosts=$(resolve_addresses "$server")
  local ip_l net_v6_l
  net_v6_l=$(printf '%s' "$NET_IPV6" | tr '[:upper:]' '[:lower:]')
  for ip in $resolved_hosts; do
    ip_l=$(printf '%s' "$ip" | tr '[:upper:]' '[:lower:]')
    case "$ip_l" in 127.*|::1|0:0:0:0:0:0:0:1|::|::0|0:0:0:0:0:0:0:0|0.0.0.0|::ffff:127.*|::ffff:7f00:*)
      tell_warn "禁止自环接入"; wait_key; return ;;
    esac
    if grep -Fqx "$ip_l" <<<"$local_ipv4" || grep -Fqx "$ip_l" <<<"$local_ipv6"; then tell_warn "禁止自环接入"; wait_key; return; fi
    [ -n "$NET_IPV4" ] && [ "$ip_l" = "$NET_IPV4" ] && { tell_warn "禁止自环接入(本机公网 IPv4)"; wait_key; return; }
    [ -n "$net_v6_l" ] && [ "$ip_l" = "$net_v6_l" ] && { tell_warn "禁止自环接入(本机公网 IPv6)"; wait_key; return; }
  done
  probe=$(mktemp) || { tell_warn "无法创建临时文件"; wait_key; return; }
  register_cleanup "$probe"
  if ! jq -n --argjson ob "$outbound" '{log:{level:"error"},dns:{servers:[{type:"udp",tag:"probe-dns",server:"1.1.1.1"}]},outbounds:[$ob,{type:"direct",tag:"direct"}],route:{final:"direct",default_domain_resolver:"probe-dns"}}' >"$probe"; then
    tell_warn "探测配置生成失败"
  elif "$CORE" check -c "$probe" >/dev/null 2>&1; then
    if ! json_save "$PEER_DIR/$tag.json" "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" '{tag:$tag,name:$name,uri:$uri,outbound:$ob}')"; then
      tell_warn "节点保存失败"
    else
      tell_ok "节点挂载完成: $name"
    fi
  else
    tell_warn "校验拦截:"; "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2
  fi
  cleanup_release "$probe"; wait_key
}

probe_peer_latency(){
  local file=$1 result=$2 latency_file=${3:-} server
  server=$(client_peer_server "$file") || { echo fail >"$result"; return; }
  [ -n "$server" ] || { echo fail >"$result"; return; }
  probe_target_latency "$server" "$result" "$latency_file"
}
list_peers(){
  local current i title=${1:-节点选择}
  current=$(state_get exit) || { tell_warn "出口状态读取失败"; wait_key; return 1; }
  local -a peer_tags=() peer_types=() peer_names=() peer_ports=() test_pids=()
  PEER_FILES_CACHE=()
  PEER_LIST_CACHE=""
  set -- "$PEER_DIR"/*.json
  [ "$#" -gt 0 ] || { ui_title "$title"; tell "暂无外部节点"; return 2; }
  ui_title "$title"
  tell "${DIM}正在检测节点延迟...${PLAIN}"
  local tmp_dir; tmp_dir=$(mktemp -d) || { tell_warn "无法创建临时目录"; wait_key; return 1; }
  register_cleanup "$tmp_dir"
  local idx=0 row file tag type name port line pid
  for file in "$@"; do
    [ -e "$file" ] || continue
    idx=$((idx+1))
    PEER_FILES_CACHE[$((idx-1))]="$file"
    if ! row=$(jq -c '{tag:(.tag//"-"),type:(.outbound.type//"-"),name:(.name//"-"),port:(.outbound.server_port // (if .outbound.server_ports then (.outbound.server_ports[0]|gsub(":";"-")) else null end) // "-")}' "$file" 2>/dev/null); then
      peer_tags[$((idx-1))]=""
      peer_types[$((idx-1))]="corrupt"
      peer_names[$((idx-1))]="$(basename "$file")"
      peer_ports[$((idx-1))]="-"
      continue
    fi
    tag=$(jq -r '.tag' <<<"$row"); type=$(jq -r '.type' <<<"$row"); name=$(jq -r '.name' <<<"$row"); port=$(jq -r '.port' <<<"$row")
    peer_tags[$((idx-1))]="$tag"; peer_types[$((idx-1))]="$type"; peer_names[$((idx-1))]="$name"; peer_ports[$((idx-1))]="$port"
    ( probe_peer_latency "$file" "$tmp_dir/res_$idx" "$tmp_dir/lat_$idx" ) 2>/dev/null &
    pid=$!
    test_pids+=("$pid")
    register_pid "$pid"
  done
  for pid in "${test_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
    unregister_pid "$pid"
  done
  for i in $(seq 1 "$idx"); do
    local t="${peer_types[$((i-1))]}" n="${peer_names[$((i-1))]}" p="${peer_ports[$((i-1))]}"
    if [ "$t" = "corrupt" ]; then
      printf -v line '%b%d.%b %b%s-%b配置损坏%b' "$BOLD$CYAN" "$i" "$PLAIN" "$BOLD$WHITE" "$n" "$BOLD$RED" "$PLAIN"
      PEER_LIST_CACHE+="${line}"$'\n'
      continue
    fi
    local display_type name_display ms color status_text current_text=""
    case "$t" in
      vless) display_type="VLESS" ;; trojan) display_type="Trojan" ;; hysteria2) display_type="Hysteria2" ;;
      tuic) display_type="TUIC" ;; shadowsocks) display_type="Shadowsocks" ;; vmess) display_type="VMess" ;;
      anytls) display_type="AnyTLS" ;; socks) display_type="SOCKS5" ;; snell) display_type="Snell" ;; *) display_type="$t" ;;
    esac
    name_display=$(jq -rn --arg s "$n" 'if ($s|length)>20 then ($s|.[0:20])+"\u2026" else $s end')
    ms=$(cat "$tmp_dir/lat_$i" 2>/dev/null)
    if [ "$(cat "$tmp_dir/res_$i" 2>/dev/null)" = ok ] && [[ "$ms" =~ ^[0-9]+$ ]]; then
      if [ "$ms" -lt 100 ]; then color="$GREEN"; elif [ "$ms" -lt 150 ]; then color="$YELLOW"; else color="$BROWN"; fi
      status_text="${ms} ms"
    else
      color="$RED"; status_text="超时"
    fi
    [ "$title" != "删除节点" ] && [ "${peer_tags[$((i-1))]}" = "$current" ] && current_text=" <=当前"
    printf -v line '%b%d.%b %b%s-%s-%s-%b%s%b%s' "$BOLD$CYAN" "$i" "$PLAIN" "$BOLD$WHITE" "$display_type" "$name_display" "$p" "$BOLD$color" "$status_text" "$PLAIN" "$current_text"
    PEER_LIST_CACHE+="${line}"$'\n'
  done
  PEER_LIST_CACHE="${PEER_LIST_CACHE%$'\n'}"
  cleanup_release "$tmp_dir"
  return 0
}

select_peer(){
  local title=${1:-节点选择} target=$2 reuse=${3:-0} index list_rc=0
  [ -n "$target" ] || return 2
  if [ "$reuse" != 1 ] || [ "${#PEER_FILES_CACHE[@]}" -eq 0 ]; then
    list_peers "$title"; list_rc=$?
    if [ "$list_rc" -eq 2 ]; then wait_key; return 1; fi
    [ "$list_rc" -eq 0 ] || return 1
  fi
  while :; do
    ui_title "$title"
    printf '\n%s\n' "$PEER_LIST_CACHE"
    menu_item 0 "返回"
    index=$(prompt "请选择 (回车刷新)")
    if [ -z "$index" ]; then
      list_peers "$title"; list_rc=$?
      if [ "$list_rc" -eq 2 ]; then wait_key; return 1; fi
      [ "$list_rc" -eq 0 ] || return 1
      continue
    fi
    [ "$index" = 0 ] && return 1
    if is_pos_int "$index" && [ "$index" -le "${#PEER_FILES_CACHE[@]}" ]; then
      printf -v "$target" '%s' "${PEER_FILES_CACHE[$((index-1))]}"
      return 0
    fi
    tell_warn "输入无效，请重新选择"; sleep 1
  done
}

peer_select(){
  local file _rc=0
  select_peer "接管/选择节点" file || return
  peer_select_transaction "$file" || _rc=$?
  [ "$_rc" -eq 3 ] && return 0
  if [ "$_rc" -ne 0 ] && [ "$_rc" -ne 4 ]; then
    tell_warn "切换失败，已回滚"
  fi
  wait_key
}

peer_delete(){
  local reuse=0
  while :; do
    local file status
    select_peer "删除节点" file "$reuse" || return
    local p_name; p_name=$(client_peer_name "$file"); [ -n "$p_name" ] || p_name=$(basename "$file"); if ! prompt_yes "确认删除 $p_name"; then
      reuse=1
      continue
    fi
    reuse=0
    if peer_delete_apply "$file"; then
      tell_ok "节点删除完成"
    else
      status=$?
      case $status in
        2) tell_warn "节点文件删除失败" ;;
        3) tell_warn "切换直连失败，节点未删除" ;;
        5) tell_warn "节点文件删除失败，出口已切直连并同步运行配置" ;;
        6) tell_warn "节点文件删除失败，出口已切直连但运行配置应用失败" ;;
        *) tell_warn "节点已删除，但 sing-box 配置应用失败，请检查服务状态" ;;
      esac
    fi
    wait_key
    set -- "$PEER_DIR"/*.json
    [ ! -e "$1" ] && break
  done
}

peer_stop(){
  ui_clear
  if peer_stop_transaction; then tell_ok "直连恢复完成"; else tell_warn "恢复直连失败，已回滚"; fi
  wait_key
}

exit_label(){
  local selected; selected=$(state_get exit) || { echo "状态异常"; return 1; }
  case $selected in
    direct) echo "直连" ;;
    wireguard) echo "WireGuard 专线" ;;
    warp) echo "WARP" ;;
    *) [ -f "$PEER_DIR/$selected.json" ] && jq -er '.name // empty' "$PEER_DIR/$selected.json" 2>/dev/null || echo "$selected" ;;
  esac
}

get_ip_info(){
  local mode=$1 res ip country asn name org w
  case "$mode" in 4|6) ;; *) return 2 ;; esac
  res=$(curl -sS -"$mode" --connect-timeout 3 -m 4 https://ipwho.is/ 2>/dev/null) || res=""
  ip=$(jq -r 'select(.success != false) | .ip // empty' <<<"$res" 2>/dev/null)
  if [ -n "$ip" ]; then
    country=$(jq -r '.country // empty' <<<"$res" 2>/dev/null)
    asn=$(jq -r '.connection.asn // empty' <<<"$res" 2>/dev/null); [ -n "$asn" ] && asn="AS$asn"
    name=$(jq -r '.connection.org // empty' <<<"$res" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\n' "$ip" "$country" "$asn" "$name"; return 0
  fi
  res=$(curl -sS -"$mode" --connect-timeout 3 -m 4 https://api.ip.sb/geoip 2>/dev/null) || res=""
  ip=$(jq -r '.ip // empty' <<<"$res" 2>/dev/null)
  if [ -n "$ip" ]; then
    country=$(jq -r '.country // empty' <<<"$res" 2>/dev/null)
    asn=$(jq -r '.asn // empty' <<<"$res" 2>/dev/null); [ -n "$asn" ] && asn="AS$asn"
    name=$(jq -r '.organization // .isp // empty' <<<"$res" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\n' "$ip" "$country" "$asn" "$name"; return 0
  fi
  res=$(curl -sS -"$mode" --connect-timeout 3 -m 4 https://ipinfo.io/json 2>/dev/null) || res=""
  ip=$(jq -r '.ip // empty' <<<"$res" 2>/dev/null)
  if [ -n "$ip" ]; then
    country=$(jq -r '.country // empty' <<<"$res" 2>/dev/null)
    org=$(jq -r '.org // empty' <<<"$res" 2>/dev/null)
    asn=${org%% *}; [[ "$asn" == AS* ]] || asn=""
    name=${org#"$asn"}; name=${name# }
    printf '%s\t%s\t%s\t%s\n' "$ip" "$country" "$asn" "$name"; return 0
  fi
  res=$(warp_trace "$mode" 2>/dev/null) || return 1
  ip=$(cut -f1 <<<"$res"); country=$(cut -f2 <<<"$res"); w=$(cut -f4 <<<"$res")
  [ -n "$ip" ] || return 1
  if [ "$w" = on ] || [ "$w" = plus ]; then name="Cloudflare WARP"; asn="AS13335"; else name="未知"; asn=""; fi
  printf '%s\t%s\t%s\t%s\n' "$ip" "$country" "$asn" "$name"
}

render_client_ip_status(){
  (
    local info4 info6 ip country asn name tmp4="" tmp6="" p4="" p6=""
    trap 'kill_tree "$p4"; kill_tree "$p6"; rm -f "$tmp4" "$tmp6"' EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    tmp4=$(mktemp) || exit 1; tmp6=$(mktemp) || exit 1
    get_ip_info 4 >"$tmp4" 2>/dev/null & p4=$!
    get_ip_info 6 >"$tmp6" 2>/dev/null & p6=$!
    wait "$p4" "$p6" 2>/dev/null || true
    info4=$(cat "$tmp4" 2>/dev/null)
    info6=$(cat "$tmp6" 2>/dev/null)
    if [ -n "$info4" ]; then
      IFS=$'\t' read -r ip country asn name <<<"$info4"
      tell "IPv4: ${GREEN}${ip}${PLAIN} | 地区: ${YELLOW}${country}${PLAIN}"
      tell "所属: ${CYAN}${name}${PLAIN} | ASN: ${PURPLE}${asn}${PLAIN}"
    else tell "IPv4: ${RED}无或不可用${PLAIN}"; fi
    if [ -n "$info6" ]; then
      IFS=$'\t' read -r ip country asn name <<<"$info6"
      tell "IPv6: ${GREEN}${ip}${PLAIN} | 地区: ${YELLOW}${country}${PLAIN}"
      tell "所属: ${CYAN}${name}${PLAIN} | ASN: ${PURPLE}${asn}${PLAIN}"
    else tell "IPv6: ${RED}无或不可用${PLAIN}"; fi
  )
}

menu_client_status(){
  ui_title "客户端状态"
  local exit_node proxy_name="直连" protocol="" ip_block
  exit_node=$(state_get exit) || { tell_warn "出口状态读取失败"; wait_key; return 1; }
  if [ "$exit_node" = "wireguard" ]; then
    proxy_name="WireGuard"
  elif [ "$exit_node" = "warp" ]; then
    proxy_name="WARP"
  elif [ "$exit_node" != "direct" ] && [ -f "$PEER_DIR/$exit_node.json" ]; then
    proxy_name=$(client_peer_name "$PEER_DIR/$exit_node.json")
    [ -n "$proxy_name" ] || proxy_name="$exit_node"
    protocol=$(jq -r '.outbound.type // ""' "$PEER_DIR/$exit_node.json" 2>/dev/null)
    case "$protocol" in
      vless) protocol="VLESS" ;; vmess) protocol="VMess" ;; hysteria2) protocol="Hysteria2" ;;
      tuic) protocol="TUIC" ;; trojan) protocol="Trojan" ;; shadowsocks) protocol="Shadowsocks" ;;
      socks) protocol="SOCKS5" ;; anytls) protocol="AnyTLS" ;; snell) protocol="Snell" ;;
      *) protocol="${protocol:-未知}" ;;
    esac
    proxy_name="$proxy_name $protocol"
  fi
  tell "网络接管：${YELLOW}${proxy_name}${PLAIN}"; tell ""
  tell "${DIM}正在检测出口 IP...${PLAIN}"
  ip_block=$(render_client_ip_status)
  ui_title "客户端状态"
  tell "网络接管：${YELLOW}${proxy_name}${PLAIN}"; tell ""
  [ -n "$ip_block" ] && printf '%s\n' "$ip_block"
  wait_key
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
  [ -f "$SELF" ] && [ "$SELF" != "$SHORTCUT" ] && ln -sf "$SELF" "$SHORTCUT" 2>/dev/null
  local had_net_cache=0 _bootstrap_conf config_rebuilt=0
  [ -f "$NET_CACHE" ] && had_net_cache=1
  load_net_cache
  [ "$had_net_cache" = 1 ] && probe_network_stack_async
  if [ ! -x "$CORE" ]; then
    tell "${CYAN}首次运行，安装 sing-box...${PLAIN}"
    install_core || exit 1
  fi
  SERVICE_UNIT_CHANGED=0
  write_service || exit 1
  systemctl enable sing-box >/dev/null 2>&1 || true
  if [ ! -f "$CONFIG" ]; then
    _bootstrap_conf=$(mktemp) || exit 1
    register_cleanup "$_bootstrap_conf"
    if ! build_config >"$_bootstrap_conf" 2>/dev/null || [ ! -s "$_bootstrap_conf" ] || ! json_write "$CONFIG" <"$_bootstrap_conf"; then
      cleanup_release "$_bootstrap_conf"
      tell_warn "初始配置生成失败，请进入菜单检查"
      wait_key
      return 0
    fi
    cleanup_release "$_bootstrap_conf"
    config_rebuilt=1
  fi
  if ! "$CORE" check -c "$CONFIG" >/dev/null 2>&1; then
    _bootstrap_conf=$(mktemp) || exit 1
    register_cleanup "$_bootstrap_conf"
    if build_config >"$_bootstrap_conf" 2>/dev/null && [ -s "$_bootstrap_conf" ] && "$CORE" check -c "$_bootstrap_conf" >/dev/null 2>&1; then
      json_write "$CONFIG" <"$_bootstrap_conf" || { cleanup_release "$_bootstrap_conf"; tell_warn "配置写入失败"; wait_key; return 0; }
      cleanup_release "$_bootstrap_conf"
      config_rebuilt=1
      tell_ok "sing-box 配置已重建"
    else
      cleanup_release "$_bootstrap_conf"
      tell_warn "sing-box 配置存在异常，请进入菜单排查或删除异常节点"
      wait_key
      return 0
    fi
  fi
  if systemctl is-active --quiet sing-box; then
    if [ "$SERVICE_UNIT_CHANGED" = 1 ] || [ "$config_rebuilt" = 1 ]; then
      timeout 15 systemctl restart sing-box >/dev/null 2>&1 || { tell_warn "sing-box 重启失败，请进入菜单排查"; wait_key; return 0; }
    fi
  else
    timeout 15 systemctl start sing-box >/dev/null 2>&1 || { tell_warn "sing-box 启动失败，请进入菜单排查"; wait_key; return 0; }
  fi
  sync_hopping_rules || { tell_warn "跳跃规则同步失败，请进入菜单检查"; wait_key; return 0; }
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case $1 in
    --sync)
      init_dirs || exit 1
      clear_legacy_bypass_rules || exit 1
      sync_hopping_rules || exit 1
      if [ -f "$CONFIG" ] && jq -e '.inbounds[]? | select(.type=="tun")' "$CONFIG" >/dev/null 2>&1; then
        for _ in $(seq 1 25); do ip link show "$TUN_IF" >/dev/null 2>&1 && break; sleep 0.2; done
      fi
      sync_resolved_dns_route
      [ -f "$WG_CONF" ] && [ "$(jq -r '.role // ""' "$WG_CONF")" = server ] && wg_config_enabled && wg_server_nat_remove || true
      exit 0 ;;
    --clear-hopping)
      clear_hopping_rules
      sync_resolved_dns_route
      exit 0 ;;
  esac

  bootstrap || exit 1

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
