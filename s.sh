#!/bin/sh
export LC_ALL=C
SELF=$(readlink -f "$0" 2>/dev/null || echo "$PWD/${0#./}")
export SBM_LAUNCHER_SELF="$SELF"

INIT_EXE=$(readlink -f /proc/1/exe 2>/dev/null || true)
case "$INIT_EXE" in
  */systemd) PLATFORM=systemd ;;
  *)
    if command -v rc-service >/dev/null 2>&1 && command -v rc-status >/dev/null 2>&1; then
      PLATFORM=OpenRC
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
      PLATFORM=systemd
    else
      printf '  %b[×] 不支持的 init 系统：%s%b\n' "${RED:-\033[31m}" "${INIT_EXE:-未知}" "${PLAIN:-\033[0m}" >&2
      exit 1
    fi
    ;;
esac
export PLATFORM

printf '  %b[√] 检测到 %s 环境%b\n' "${GREEN:-\033[32m}" "$PLATFORM" "${PLAIN:-\033[0m}"

TMP_ROOT=${TMPDIR:-/tmp}/sbm-unified.$$
mkdir -p "$TMP_ROOT" || exit 1
COMMON="$TMP_ROOT/common.sh"
PAYLOAD="$TMP_ROOT/main.sh"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
cat >"$COMMON" <<'__SBM_COMMON__'
apply_config_quiet(){ apply_config >/dev/null 2>&1; }

core_cache_reset(){ CORE_VERSION=""; CORE_TAGS=""; }

exit_label(){
  local selected; selected=$(state_get exit)
  case $selected in
    direct) echo "直连" ;;
    wireguard) echo "WireGuard 专线" ;;
    *) [ -f "$PEER_DIR/$selected.json" ] && jq -r .name "$PEER_DIR/$selected.json" || echo "$selected" ;;
  esac
}

json_save(){
  local dest=$1 content=$2
  [ -n "$content" ] || return 1
  printf '%s\n' "$content" | json_write "$dest"
}

clear_acme_pending(){
  ACME_PENDING_DOMAIN=""; ACME_PENDING_EMAIL=""; ACME_PENDING_MODE=""; ACME_PENDING_CF_TOKEN=""; ACME_PENDING_ALI_KEY=""; ACME_PENDING_ALI_SECRET=""
  ACME_PENDING_ACMEDNS_URL=""; ACME_PENDING_ACMEDNS_USER=""; ACME_PENDING_ACMEDNS_PASS=""; ACME_PENDING_ACMEDNS_SUB=""
  BUILD_DOMAIN_OVERRIDE=""
}

commit_acme_pending_state(){
  [ -n "$ACME_PENDING_DOMAIN" ] || return 0
  json_edit "$STATE" '.domain=$d|.email=$e|.challenge=$m|.cf_token=$cf|.ali_key=$ak|.ali_secret=$as|.acmedns_url=$au|.acmedns_user=$uu|.acmedns_pass=$pp|.acmedns_sub=$ss' \
    --arg d "$ACME_PENDING_DOMAIN" --arg e "$ACME_PENDING_EMAIL" --arg m "$ACME_PENDING_MODE" \
    --arg cf "$ACME_PENDING_CF_TOKEN" --arg ak "$ACME_PENDING_ALI_KEY" --arg as "$ACME_PENDING_ALI_SECRET" \
    --arg au "$ACME_PENDING_ACMEDNS_URL" --arg uu "$ACME_PENDING_ACMEDNS_USER" --arg pp "$ACME_PENDING_ACMEDNS_PASS" --arg ss "$ACME_PENDING_ACMEDNS_SUB"
}

menu_change_domain(){
  local new_domain old_state file count=0 email mode cf_token ali_key ali_secret acmedns_url acmedns_user acmedns_pass acmedns_sub tmp pid log_file had_new_assets=0 old_domain
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 更换域名 <<${PLAIN}"
  tell "  当前域名: $(state_get domain || true)"; tell "  绑定节点:"
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    if [ "$(jq -r .tls_mode "$file")" = acme ]; then tell "  - $(jq -r .name "$file") [$(jq -r .kind "$file")]"; count=$((count+1)); fi
  done
  [ "$count" = 0 ] && tell "  无"
  echo ""
  new_domain=$(prompt "新域名 (留空取消)"); [ -z "$new_domain" ] && return
  old_state=$(cat "$STATE"); old_domain=$(printf '%s\n' "$old_state" | jq -r .domain)
  acme_domain_assets_exist "$new_domain" && had_new_assets=1
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; wait_key; return; }

  email=$(state_get email); mode=$(state_get challenge); cf_token=$(state_get cf_token); ali_key=$(state_get ali_key); ali_secret=$(state_get ali_secret)
  acmedns_url=$(state_get acmedns_url); acmedns_user=$(state_get acmedns_user); acmedns_pass=$(state_get acmedns_pass); acmedns_sub=$(state_get acmedns_sub)
  if prompt_yes "同步重置验证机制"; then
    email=$(prompt "ACME 通知邮箱" "admin@$new_domain"); [ -n "$email" ] || { wait_key; return; }
    printf '\n  %b选择证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
    echo "  1. HTTP         (推荐 需放行80端口)"
    echo "  2. TLS-ALPN     (推荐 需放行443端口)"
    echo "  3. Cloudflare API"
    echo "  4. 阿里云 DNS API"
    echo "  5. ACME-DNS API"
    while :; do
      case $(prompt "请选择方式" 1) in
        1) mode=http; break ;;
        2) mode=alpn; break ;;
        3) mode=dns_cloudflare; cf_token=$(prompt 'Cloudflare API Token'); break ;;
        4) mode=dns_alidns; ali_key=$(prompt 'AccessKeyId'); ali_secret=$(prompt 'AccessKeySecret'); break ;;
        5) mode=dns_acmedns; acmedns_url=$(prompt 'server_url'); acmedns_user=$(prompt 'username'); acmedns_pass=$(prompt 'password'); acmedns_sub=$(prompt 'subdomain'); break ;;
        *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
      esac
    done
  fi
  validate_domain "$new_domain" "$mode" || { prompt_yes "解析验证存在异常，是否继续" || { wait_key; return; }; }
  ACME_PENDING_DOMAIN="$new_domain"; ACME_PENDING_EMAIL="$email"; ACME_PENDING_MODE="$mode"; ACME_PENDING_CF_TOKEN="$cf_token"; ACME_PENDING_ALI_KEY="$ali_key"; ACME_PENDING_ALI_SECRET="$ali_secret"
  ACME_PENDING_ACMEDNS_URL="$acmedns_url"; ACME_PENDING_ACMEDNS_USER="$acmedns_user"; ACME_PENDING_ACMEDNS_PASS="$acmedns_pass"; ACME_PENDING_ACMEDNS_SUB="$acmedns_sub"
  tmp=$(mktemp) || { clear_acme_pending; tell_warn "临时配置创建失败"; wait_key; return; }; TMP_FILES="$TMP_FILES $tmp"
  if ! jq -n --argjson p "$(acme_options "$new_domain")" '{log:{level:"warn",timestamp:true},certificate_providers:[($p+{type:"acme",tag:"acme-temporary"})]}' >"$tmp" 2>/dev/null; then
    rm -f "$tmp"; printf '%s\n' "$old_state" | json_write "$STATE"; clear_acme_pending; tell_warn "证书临时配置生成失败"; wait_key; return
  fi
  if ! "$CORE" check -c "$tmp" >/dev/null 2>&1; then
    tell_warn "新域名 ACME 配置校验失败"; rm -f "$tmp"; printf '%s\n' "$old_state" | json_write "$STATE"; clear_acme_pending; wait_key; return
  fi
  log_file=$(mktemp) || { printf '%s\n' "$old_state" | json_write "$STATE"; clear_acme_pending; tell_warn "证书日志文件创建失败"; wait_key; return; }; TMP_FILES="$TMP_FILES $log_file"
  "$CORE" run -c "$tmp" >"$log_file" 2>&1 & pid=$!
  if wait_for_certificate "$new_domain" "$pid" "$log_file"; then
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    BUILD_DOMAIN_OVERRIDE="$new_domain"
    if apply_config; then
      if commit_acme_pending_state; then
        cleanup_old_domain_assets "$old_domain"
        clear_acme_pending
        tell_ok "新域名证书已签发并完成校验"
        tell_ok "域名已正式切换为: $new_domain"
        tell_ok "所有已配置域名节点已同步使用新域名"
        menu_server_info
      else
        printf '%s\n' "$old_state" | json_write "$STATE"
        clear_acme_pending; apply_config_quiet
        tell_warn "域名状态保存失败，已恢复旧配置"; wait_key
      fi
    else
      printf '%s\n' "$old_state" | json_write "$STATE"
      [ "$had_new_assets" = 1 ] || cleanup_old_domain_assets "$new_domain"
      clear_acme_pending; apply_config_quiet
      tell_warn "新域名正式切换失败，已恢复旧配置"; wait_key
    fi
  else
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    printf '%s\n' "$old_state" | json_write "$STATE"
    [ "$had_new_assets" = 1 ] || cleanup_old_domain_assets "$new_domain"
    clear_acme_pending; rm -f "$tmp"
    tell_warn "证书未成功签发，域名切换已回滚"; wait_key
  fi
  rm -f "$tmp"
}

menu_client(){
  while :; do
    screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 客户端管理 <<${PLAIN}"
    tell "  当前出口: ${YELLOW}$(exit_label)${PLAIN}"; tell ""
    tell "  1. 添加节点"; tell "  2. 节点选择"; tell "  3. 删除节点"; tell "  4. 停止代理"; tell "  5. 客户端状态"; tell "  0. 返回"
    tell "${CYAN}--------------------------------${PLAIN}"
    case $(prompt "请选择") in
      1) peer_add ;; 2) peer_select ;; 3) peer_delete ;; 4) peer_stop ;; 5) menu_client_status ;;
      0) break ;; *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

peer_select(){
  local tag target_name
  select_peer "接管/选择节点" || return
  tag=$(jq -r .tag "$PICKED"); target_name=$(jq -r '.name // .tag' "$PICKED")
  BUILD_SELECTED_OVERRIDE="$tag"
  if apply_config; then
    state_set exit "$tag" && sync_proxy_env && tell_ok "已接管: $target_name" || tell_warn "已应用节点，但状态保存失败"
  else
    BUILD_SELECTED_OVERRIDE=direct
    state_set exit direct >/dev/null 2>&1 || true
    sync_proxy_env >/dev/null 2>&1 || true
    apply_config_quiet >/dev/null 2>&1 || true
    tell_warn "切换失败，已恢复直连"
  fi
  BUILD_SELECTED_OVERRIDE=""
  wait_key
}

prompt_yes(){
  local value; value=$(prompt "$1 (y/N)" "n")
  [ "$value" = y ] || [ "$value" = Y ]
}

save_node(){
  local file=$1 content=$2 acme_domain
  json_save "$file" "$content" || { tell_warn "数据写入失败"; wait_key; return 1; }
  if [ "$(jq -r .tls_mode "$file" 2>/dev/null)" = acme ]; then
    if ! apply_config; then
      rm -f "$file"; clear_acme_pending; tell_warn "配置应用失败"; wait_key; return 1
    fi
    acme_domain=${ACME_PENDING_DOMAIN:-$(state_get domain)}
    if ! wait_for_certificate "$acme_domain"; then
      rm -f "$file"; clear_acme_pending; tell_warn "证书未成功签发，已取消本次协议创建"; apply_config_quiet; wait_key; return 1
    fi
    if [ -n "$ACME_PENDING_DOMAIN" ] && ! commit_acme_pending_state; then
      rm -f "$file"; clear_acme_pending; apply_config_quiet; tell_warn "域名配置写入失败，已取消本次协议创建"; wait_key; return 1
    fi
    clear_acme_pending
  else
    apply_config || { rm -f "$file"; tell_warn "配置应用失败"; wait_key; return 1; }
  fi
  tell_ok "协议应用成功"; printf "
"; render_share_uri "$file"; wait_key
}

slugify(){ printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-20; }

state_get(){ jq -r --arg k "$1" '.[$k]//""' "$STATE" 2>/dev/null; }

state_set(){ json_edit "$STATE" '.[$k]=$v' --arg k "$1" --arg v "$2"; }

unique_tag(){
  local base tag index=1
  base=$(slugify "$1"); [ -n "$base" ] || base=node
  tag="$2$base"
  while [ -e "$3/$tag.json" ]; do tag="$2$base$index"; index=$((index+1)); done
  printf '%s' "$tag"
}

uri_encode(){ jq -rn --arg s "$1" '$s|@uri'; }

wg_listen_port(){ [ -f "$WG_CONF" ] && jq -r '.listen_port//0' "$WG_CONF" | grep -E '^[1-9][0-9]*$'; }

read_line(){
  local value
  if [ -c /dev/tty ]; then IFS= read -r value </dev/tty || value=""; else IFS= read -r value || value=""; fi
  value=$(printf '%s' "$value" | tr -d '\r')
  printf '%s' "$value"
}

prompt(){
  local msg="$1" def="${2:-}" value
  if [ -n "$def" ]; then printf '  %b%s [%s]: %b' "${CYAN}" "$msg" "$def" "${PLAIN}" >&2; else printf '  %b%s: %b' "${CYAN}" "$msg" "${PLAIN}" >&2; fi
  value=$(read_line)
  printf '%s\n' "${value:-$def}"
}

wait_key(){ printf '\n  %b>> 按回车键继续...%b' "${CYAN}" "${PLAIN}" >&2; read_line >/dev/null; }
screen_clear(){ printf '\033[H\033[2J\033[3J'; }
SCRIPT_URL="https://raw.githubusercontent.com/88860/-/main/s.sh"

run_script_update(){
  local script_tmp
  screen_clear
  tell "正在检测管理脚本更新..."
  script_tmp=$(mktemp) || { tell_warn "无法创建临时文件"; wait_key; return 1; }
  TMP_FILES="$TMP_FILES $script_tmp"
  if ! curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "${SCRIPT_URL}" -o "$script_tmp" 2>/dev/null; then
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -m 30 "${SCRIPT_URL}" -o "$script_tmp" 2>/dev/null; then
      tell_warn "脚本下载失败，请检查 GitHub 访问"; wait_key; return 1
    fi
  fi
  if [ ! -s "$script_tmp" ]; then
    tell_warn "下载的脚本为空，放弃更新"
  elif sh -n "$script_tmp" 2>/dev/null; then
    if cmp -s "$script_tmp" "$SELF"; then
      tell_ok "脚本已是最新版本"
    elif install -m700 "$script_tmp" "$SELF"; then
      tell_ok "脚本更新成功，请重新运行本脚本生效"
      wait_key
      exit 0
    else
      tell_warn "脚本写入失败，原脚本未修改"
    fi
  else
    tell_warn "下载的脚本存在语法错误，放弃更新"
  fi
  wait_key
}


tell(){ printf '  %b\n' "$*"; }
tell_ok(){ printf '  %b[√] %b%b\n' "${GREEN}" "$*" "${PLAIN}"; }
tell_warn(){ printf '  %b[×] %b%b\n' "${RED}" "$*" "${PLAIN}"; }
tell_alert(){ printf '  %b[!] %b%b\n' "${YELLOW}" "$*" "${PLAIN}"; }

uri_decode(){
  printf '%s\n' "$1" | awk 'BEGIN{for(i=0;i<16;i++){hex[sprintf("%X",i)]=i;hex[sprintf("%x",i)]=i}}{gsub(/\+/," ");res="";i=1;while(i<=length($0)){c=substr($0,i,1);if(c=="%"&&i+2<=length($0)){res=res sprintf("%c",hex[substr($0,i+1,1)]*16+hex[substr($0,i+2,1)]);i+=3}else{res=res c;i++}}print res}' 2>/dev/null || printf '%s\n' "$1"
}

random_password(){ openssl rand -hex 8 2>/dev/null || tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16; }
random_uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '%s' "$(tr -dc 'a-f0-9' </dev/urandom | head -c 32)" | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'; }

service_stop(){ case "$PLATFORM" in OpenRC) rc-service sing-box stop >/dev/null 2>&1 || true ;; systemd) timeout 15 systemctl stop sing-box >/dev/null 2>&1 || true ;; esac; }
service_is_active(){ case "$PLATFORM" in OpenRC) rc-service sing-box status >/dev/null 2>&1 ;; systemd) systemctl is-active --quiet sing-box ;; *) return 1 ;; esac; }

wg_valid_address(){
  local value=$1 prefix ip octet oldIFS
  case "$value" in */*) ;; *) return 1 ;; esac
  ip=${value%/*}; prefix=${value#*/}
  echo "$prefix" | grep -Eq '^[0-9]+$' || return 1
  case "$ip" in
    *:*) [ "$prefix" -le 128 ] 2>/dev/null || return 1; getent ahostsv6 "$ip" >/dev/null 2>&1 || return 1 ;;
    *)
      [ "$prefix" -le 32 ] 2>/dev/null || return 1
      oldIFS=$IFS; IFS=.; set -- $ip; IFS=$oldIFS
      [ $# -eq 4 ] || return 1
      for octet in "$@"; do echo "$octet" | grep -Eq '^[0-9]+$' && [ "$octet" -le 255 ] 2>/dev/null || return 1; done
      ;;
  esac
}

wg_prompt_address(){
  local current4 current6 value
  current4=$(jq -r '.address[0] // ""' "$WG_CONF")
  current6=$(jq -r '.address[1] // ""' "$WG_CONF")
  while :; do
    value=$(prompt "IPv4" "$current4")
    wg_valid_address "$value" && ! printf '%s' "$value" | grep -q ':' || { tell_warn "IPv4 地址无效"; continue; }
    WG_EDIT_IPV4=$value; break
  done
  while :; do
    value=$(prompt "IPv6" "$current6")
    printf '%s' "$value" | grep -q ':' && wg_valid_address "$value" || { tell_warn "IPv6 地址无效"; continue; }
    WG_EDIT_IPV6=$value; break
  done
}

wg_save(){
  json_save "$WG_CONF" "$1"
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

init_dirs(){
  mkdir -p "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box /usr/local/bin
  chmod 700 "$SBM_DIR" "$NODE_DIR" "$PEER_DIR" "$WG_DIR" "$ACME_DIR" "$SB_DIR" /var/lib/sing-box
  [ -f "$STATE" ] || printf '%s\n' '{"exit":"direct","domain":"","email":"","challenge":"http","asset":""}' | json_write "$STATE"
  [ -f "$PKG_LOG" ] || : >"$PKG_LOG"
}

json_edit(){
  local file=$1 expr=$2; shift 2
  local tmp; tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  if jq "$@" "$expr" "$file" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    install -m600 "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
  fi
  return 1
}

json_write(){
  local dest=$1 tmp
  tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  cat >"$tmp"
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  install -m600 "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
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
    screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"
    tell "  1. VLESS REALITY"; tell "  2. VLESS Vision+TCP+TLS"; tell "  3. Hysteria2"; tell "  4. TUIC"; tell "  5. Trojan"; tell "  6. AnyTLS"; tell "  7. SOCKS5"; tell "  8. Snell"; tell "  0. 返回"; tell "${CYAN}------------------------------${PLAIN}"
    case $(prompt "请选择") in
      1) create_vless_reality; break;; 2) create_vless_tls; break;; 3) create_hysteria2; break;; 4) create_tuic; break;; 5) create_trojan; break;; 6) create_anytls; break;; 7) create_socks; break;; 8) create_snell; break;; 0) return;; *) tell_warn "输入无效，请重新选择"; sleep 1;;
    esac
  done
}

menu_server_info(){
  local file port proto status count=0 tcp_list udp_list
  tcp_list=$(listening_ports t); udp_list=$(listening_ports u)
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> 服务端信息 <<${PLAIN}"
  service_is_active && tell_ok "singbox: 运行中" || tell_warn "singbox: 未运行"

  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    count=$((count+1))
    port=$(jq -r .port "$file"); proto=$(jq -r .proto "$file")
    if [ "$proto" = u ]; then
      if printf '%s\n' "$udp_list" | grep -qx "$port"; then status="${GREEN}正常监听${PLAIN}"; else status="${RED}未在监听${PLAIN}"; fi
    else
      if printf '%s\n' "$tcp_list" | grep -qx "$port"; then status="${GREEN}正常监听${PLAIN}"; else status="${RED}未在监听${PLAIN}"; fi
    fi
    tell ""
    tell "${CYAN}>>${PLAIN} $(jq -r .name "$file") [$(jq -r .kind "$file")] | 端口 $port $status"
    render_share_uri "$file"
  done
  [ "$count" = 0 ] && tell "\n  暂无节点"
  render_certificate_status
  wait_key
}

render_certificate_status(){
  local domain crt expiry days file
  domain=$(state_get domain); [ -n "$domain" ] || return 0
  tell ""; tell "  全局域名: $domain | 验证: $(state_get challenge)"
  crt=""
  while IFS= read -r file; do
    if openssl x509 -in "$file" -noout -checkhost "$domain" >/dev/null 2>&1; then crt="$file"; break; fi
  done <<EOF
$(find "$ACME_DIR" -type f -name '*.crt' 2>/dev/null)
EOF
  [ -n "$crt" ] || { tell "  ${RED}证书状态: 未找到匹配域名的证书${PLAIN}"; return 0; }
  expiry=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
  [ -n "$expiry" ] || { tell "  ${RED}证书状态: 无法读取${PLAIN}"; return 0; }
  days=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  tell "  到期时间: $expiry | 剩余: ${days} 天"
  service_is_active || tell_warn "服务离线，无法自动续期"
}

wg_default_address(){
  local role=$1
  if [ "$role" = server ]; then
    WG_IPV4="10.10.0.1/24"; WG_IPV6="fd00:10::1/64"
    WG_PEER_IPV4="10.10.0.2"; WG_PEER_IPV6="fd00:10::2"
  else
    WG_IPV4="10.10.0.2/24"; WG_IPV6="fd00:10::2/64"
    WG_PEER_IPV4="10.10.0.1"; WG_PEER_IPV6="fd00:10::1"
  fi
}

create_vless_reality(){
  local name port uuid target keypair private public short_id tag body default_sid
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"
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
   {tag:$tag,name:$name,kind:"vless-reality",port:$port,proto:"t",tls_mode:"reality",alpn:null,meta:{uuid:$uuid,target:$target,public_key:$public,short_id:$sid},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$target,reality:{enabled:true,handshake:{server:$target,server_port:443},private_key:$private,short_id:[$sid]}}}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_vless_tls(){
  local name port uuid tag body
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"; name=$(prompt "节点名称" "VLESS-TLS"); setup_certificate || return; port=$(prompt_port t ""); uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)"); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" '{tag:$tag,name:$name,kind:"vless-tls",port:$port,proto:"t",tls_mode:"acme",alpn:null,meta:{uuid:$uuid},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}]}}')
  save_node "$NODE_DIR/$tag.json" "$body"
}

create_tuic(){
  local name port uuid password tag body
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"; name=$(prompt "节点名称" "TUIC"); setup_certificate || return; port=$(prompt_port u ""); uuid=$(prompt "通信 UUID (留空自动生成)" "$(random_uuid)"); password=$(prompt "连接密码 (留空自动生成)" "$(random_password)"); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" '{tag:$tag,name:$name,kind:"tuic",port:$port,proto:"u",tls_mode:"acme",alpn:["h3"],meta:{uuid:$uuid,password:$password},inbound:{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$password}],congestion_control:"bbr"}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

create_trojan(){
  local name port password tag body
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"; name=$(prompt "节点名称" "Trojan"); setup_certificate || return; port=$(prompt_port t ""); password=$(prompt "连接密码 (留空自动生成)" "$(random_password)"); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" '{tag:$tag,name:$name,kind:"trojan",port:$port,proto:"t",tls_mode:"acme",alpn:null,meta:{password:$password},inbound:{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}]}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

create_anytls(){
  local name port password tag body client_meta
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"; name=$(prompt "节点名称" "AnyTLS"); setup_certificate || return; port=$(prompt_port t ""); password=$(prompt "连接密码 (留空自动生成)" "$(random_password)"); client_meta=$(prompt "客户端元数据 (留空则为空)" ""); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" --arg meta "$client_meta" '{tag:$tag,name:$name,kind:"anytls",port:$port,proto:"t",tls_mode:"acme",alpn:null,meta:({password:$password}|if $meta!="" then .client_metadata=$meta else . end),inbound:{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}]}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

create_socks(){
  local name username password port tag body
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"; name=$(prompt "节点名称" "Socks5"); username=$(prompt "鉴权账号" "admin"); password=$(prompt "鉴权密码 (留空自动生成)" "$(random_password)"); [ -n "$username" ] && [ -n "$password" ] || { tell_warn "必填项为空"; wait_key; return; }; port=$(prompt_port t ""); tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg username "$username" --arg password "$password" '{tag:$tag,name:$name,kind:"socks",port:$port,proto:"t",tls_mode:"none",alpn:null,meta:{username:$username,password:$password},inbound:{type:"socks",tag:$tag,listen:"::",listen_port:$port,users:[{username:$username,password:$password}]}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

create_snell(){
  local name port psk mode tag body len
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"; name=$(prompt "节点名称" "Snell"); port=$(prompt_port t "")
  while :; do psk=$(prompt "预共享密钥 (PSK, 12-255 字节)" "$(random_password)"); len=$(printf '%s' "$psk" | wc -c | tr -d ' '); [ "$len" -ge 12 ] && [ "$len" -le 255 ] && break; tell_warn "PSK 长度必须为 12-255 字节，当前 ${len} 字节"; done
  tell "  1. default"; tell "  2. unshaped"; tell "  3. unsafe-raw"; while :; do case $(prompt "流量整形模式" 1) in 1) mode=default; break;; 2) mode=unshaped; break;; 3) mode=unsafe-raw; break;; *) tell_warn "输入无效";; esac; done
  tag=$(unique_tag "$name" in- "$NODE_DIR"); body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg psk "$psk" --arg mode "$mode" '{tag:$tag,name:$name,kind:"snell",port:$port,proto:"t",tls_mode:"none",alpn:null,meta:{psk:$psk,mode:$mode},inbound:{type:"snell",tag:$tag,listen:"::",listen_port:$port,version:6,psk:$psk,mode:$mode}}'); save_node "$NODE_DIR/$tag.json" "$body"
}

wg_actual_listen_port(){
  local configured=${1:-}
  [ -d "/sys/class/net/$WG_IF" ] || { printf '%s' ""; return; }
  printf "%s" "$configured" | grep -Eq "^[1-9][0-9]*$" || return 0
  ss -Hlunp 2>/dev/null | awk -v p=":$configured" '$4 ~ (p"$") && /users:\(\("sing-box"/ {found=1} END{if(found) print p}' | sed 's/^://'
}

wg_tunnel_state(){
  local peer_ip4=$1 peer_ip6=$2 out ms
  [ -d "/sys/class/net/$WG_IF" ] || { echo disconnected; return; }
  if [ -n "$peer_ip6" ]; then
    out=$(ping -6 -I "$WG_IF" -c 1 -W 2 "$peer_ip6" 2>/dev/null)
    if [ $? -eq 0 ]; then
      ms=$(printf "%s\n" "$out" | awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}')
      printf "%s" "$ms" | grep -Eq "^[0-9]+$" && { printf 'ok|%s\n' "$ms"; return; }
    fi
  fi
  if [ -n "$peer_ip4" ]; then
    out=$(ping -4 -I "$WG_IF" -c 1 -W 2 "$peer_ip4" 2>/dev/null)
    if [ $? -eq 0 ]; then
      ms=$(printf "%s\n" "$out" | awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}')
      printf "%s" "$ms" | grep -Eq "^[0-9]+$" && { printf 'ok|%s\n' "$ms"; return; }
    fi
  fi
  echo disconnected
}

wg_status(){
  local file=$WG_CONF role enabled public ipv4 ipv6 peer_host peer_port peer_key endpoint_ips
  screen_clear
  if [ ! -f "$file" ]; then
    tell "${RED}WireGuard 尚未配置，请先初始化。${PLAIN}"
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
      tell "${BRIGHT_CYAN}${BOLD}>> WireGuard 状态信息 <<${PLAIN}"
      if [ "$enabled" = true ] && [ -d "/sys/class/net/$WG_IF" ]; then
        tell "运行模式：客户端 状态：${GREEN}已启动${PLAIN}"
      elif [ "$enabled" = true ]; then
        tell "运行模式：客户端 状态：${RED}异常${PLAIN}"
      else
        tell "运行模式：客户端 状态：${RED}已停止${PLAIN}"
      fi
      get_ip_info 4
      if [ -n "$IP_INFO_IP" ]; then
        tell "本机IPv4：${GREEN}${IP_INFO_IP}${PLAIN}"
      else
        tell "本机IPv4：${RED}无或不可用${PLAIN}"
      fi
      get_ip_info 6
      if [ -n "$IP_INFO_IP" ]; then
        tell "本机IPv6：${GREEN}${IP_INFO_IP}${PLAIN}"
      else
        tell "本机IPv6：${RED}无或不可用${PLAIN}"
      fi
      tell "隧道IPv4：${GREEN}$ipv4${PLAIN}"
      tell "隧道IPv6：${GREEN}$ipv6${PLAIN}"
      tell ""
      peer_host=$(jq -r '.peer_host // empty' "$file" 2>/dev/null)
      peer_port=$(jq -r '.peer_port // empty' "$file" 2>/dev/null)
      peer_key=$(jq -r '.peer_public_key // empty' "$file" 2>/dev/null)
      tell "服务器：${GREEN}${peer_host}${PLAIN}:${YELLOW}${peer_port}${PLAIN}"
      state="disconnected"
      if [ "$enabled" = true ] && [ -d "/sys/class/net/$WG_IF" ]; then
        state=$(wg_tunnel_state "$(jq -r '.peer_ip // empty' "$file" 2>/dev/null)" "$(jq -r '.peer_ip6 // empty' "$file" 2>/dev/null)")
      fi
      ms=${state#*|}
      if case "$state" in ok\|*) printf "%s" "$ms" | grep -Eq "^[0-9]+$" ;; *) false ;; esac; then
        if [ "$ms" -lt 100 ]; then color="$GREEN"; elif [ "$ms" -lt 150 ]; then color="$YELLOW"; else color="$BROWN"; fi
        tell "服务器延迟：${color}${ms}ms${PLAIN}"
      else
        tell "服务器延迟：${RED}未连接${PLAIN}"
      fi
      tell "服务器公钥：$peer_key"
      tell "本机公钥：$public"
      tell ""
      endpoint_ips=$(resolve_addresses "$peer_host" 2>/dev/null || true)
      tell "外层IPv4|$(if printf "%s\n" "$endpoint_ips" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then printf '%s正常%s' "$GREEN" "$PLAIN"; else printf '%s不可用%s' "$RED" "$PLAIN"; fi)      隧道IPv4|$(if [ -n "$ipv4" ] && [ "$enabled" = true ] && [ -d "/sys/class/net/$WG_IF" ]; then printf '%s正常%s' "$GREEN" "$PLAIN"; else printf '%s不可用%s' "$RED" "$PLAIN"; fi)"
      tell "外层IPv6|$(if printf "%s\n" "$endpoint_ips" | grep -q ':'; then printf '%s正常%s' "$GREEN" "$PLAIN"; else printf '%s不可用%s' "$RED" "$PLAIN"; fi)      隧道IPv6|$(if [ -n "$ipv6" ] && [ "$enabled" = true ] && [ -d "/sys/class/net/$WG_IF" ]; then printf '%s正常%s' "$GREEN" "$PLAIN"; else printf '%s不可用%s' "$RED" "$PLAIN"; fi)"
      tell ""
      tell "${CYAN}----------------------------------------${PLAIN}"
      ;;
    server)
      local peer_count peer_index peer_name peer_ipv4 peer_ipv6 peer_pub
      tell "${BRIGHT_CYAN}${BOLD}>> WireGuard 状态信息 <<${PLAIN}"
      if [ "$enabled" = true ] && [ -d "/sys/class/net/$WG_IF" ]; then
        tell "运行模式：服务端 状态：${GREEN}已启动${PLAIN}"
      elif [ "$enabled" = true ]; then
        tell "运行模式：服务端 状态：${RED}异常${PLAIN}"
      else
        tell "运行模式：服务端 状态：${RED}已停止${PLAIN}"
      fi
      tell "隧道IPv4：${GREEN}$ipv4${PLAIN}"
      tell "隧道IPv6：${GREEN}$ipv6${PLAIN}"
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
      peer_index=0
      while [ "$peer_index" -lt "$peer_count" ]; do
        peer_name=$(jq -r ".clients[$peer_index].name // \"客户端 $((peer_index+1))\"" "$file" 2>/dev/null)
        peer_ipv4=$(jq -r ".endpoint.peers[$peer_index].allowed_ips[0] // \"\"" "$file" 2>/dev/null)
        peer_ipv6=$(jq -r ".endpoint.peers[$peer_index].allowed_ips[1] // \"\"" "$file" 2>/dev/null)
        peer_pub=$(jq -r ".endpoint.peers[$peer_index].public_key // \"\"" "$file" 2>/dev/null)
        tell ""
        tell "客户端 $((peer_index+1))：$peer_name"
        tell "IPv4：${GREEN}$peer_ipv4${PLAIN}"
        tell "IPv6：${GREEN}$peer_ipv6${PLAIN}"
        tell "公钥：$peer_pub"
        peer_index=$((peer_index+1))
      done
      tell ""
      tell "${CYAN}----------------------------------------${PLAIN}"
      ;;
    *)
      tell "${RED}WireGuard 尚未配置，请先初始化。${PLAIN}"
      ;;
  esac
  wait_key
}

menu_wireguard(){
  while :; do
    screen_clear
    tell "${BRIGHT_CYAN}${BOLD}>> WireGuard <<${PLAIN}"
    if [ ! -f "$WG_CONF" ]; then
      tell "  模式：${RED}未配置${PLAIN}"
    else
      local role enabled state ms color
      role=$(jq -r '.role // ""' "$WG_CONF")
      enabled=$(jq -r '.enabled//false' "$WG_CONF")
      if [ "$role" = client ] && [ "$enabled" = true ]; then
        if [ ! -d "/sys/class/net/$WG_IF" ]; then
          tell "  模式：客户端|${RED}异常${PLAIN}"
        else
          state=$(wg_tunnel_state "$(jq -r '.peer_ip // empty' "$WG_CONF")" "$(jq -r '.peer_ip6 // empty' "$WG_CONF")")
          ms=${state#*|}
          if case "$state" in ok\|*) printf "%s" "$ms" | grep -Eq "^[0-9]+$" ;; *) false ;; esac; then
            if [ "$ms" -lt 100 ]; then color="$GREEN"; elif [ "$ms" -lt 150 ]; then color="$YELLOW"; else color="$BROWN"; fi
            tell "  模式：客户端|${GREEN}已连接${PLAIN}|${color}${ms} ms${PLAIN}"
          else
            tell "  模式：客户端|${RED}未连接${PLAIN}"
          fi
        fi
      elif [ "$role" = server ]; then
        if [ "$enabled" = true ]; then
          if [ -d "/sys/class/net/$WG_IF" ]; then tell "  模式：服务端|${GREEN}已启动${PLAIN}"; else tell "  模式：服务端|${RED}异常${PLAIN}"; fi
        else
          tell "  模式：服务端|${RED}已停止${PLAIN}"
        fi
      else
        if [ "$enabled" = true ]; then
          if [ -d "/sys/class/net/$WG_IF" ]; then tell "  模式：客户端|${GREEN}已启动${PLAIN}"; else tell "  模式：客户端|${RED}异常${PLAIN}"; fi
        else
          tell "  模式：客户端|${RED}已停止${PLAIN}"
        fi
      fi
    fi
    tell ""
    tell "  1. 初始化配置"
    tell "  2. 修改配置"
    tell "  3. 启动/停止"
    tell "  4. 状态信息"
    tell "  5. 删除配置"
    tell "  0. 退出"
    tell "${CYAN}--------------------------------${PLAIN}"
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

wg_edit_address(){
  local body
  screen_clear; [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  tell "${BRIGHT_CYAN}${BOLD}>> 内网双栈地址 <<${PLAIN}"; tell "  IPv4: ${GREEN}$(jq -r '.address[0] // ""' "$WG_CONF")${PLAIN}"; tell "  IPv6: ${GREEN}$(jq -r '.address[1] // ""' "$WG_CONF")${PLAIN}"; echo ""
  wg_prompt_address
  body=$(jq --arg a4 "$WG_EDIT_IPV4" --arg a6 "$WG_EDIT_IPV6" '.address=[$a4,$a6]|.endpoint.address=[$a4,$a6]' "$WG_CONF") || { tell_warn "地址生成失败"; wait_key; return; }
  if ! wg_edit_address_apply "$body"; then tell_warn "应用失败"; wait_key; return; fi
  tell_ok "已修改"; wait_key
}

wg_next_client_address(){
  local server4 server6 base4 base6 prefix4 prefix6 n used4 used6
  server4=$(jq -r '.address[0] // "10.10.0.1/24"' "$WG_CONF"); server6=$(jq -r '.address[1] // "fd00:10::1/64"' "$WG_CONF")
  prefix4=${server4#*/}; prefix6=${server6#*/}
  [ "$prefix4" = 24 ] || { tell_warn "WireGuard IPv4 自动分配目前要求 /24 网段，请手动指定客户端地址"; return 1; }
  [ "$prefix6" = 64 ] || { tell_warn "WireGuard IPv6 自动分配目前要求 /64 网段，请手动指定客户端地址"; return 1; }
  base4=${server4%/*}; base4=${base4%.*}; base6=${server6%/*}; base6=${base6%:*}
  n=2
  while [ "$n" -le 254 ]; do
    used4=$(jq -r --arg ip "$base4.$n" '.clients[]?.ipv4 // empty' "$WG_CONF" | awk -F/ -v ip="$base4.$n" '$1==ip{f=1} END{print f+0}')
    used6=$(jq -r --arg ip "$base6:$n" '.clients[]?.ipv6 // empty' "$WG_CONF" | awk -F/ -v ip="$base6:$n" '$1==ip{f=1} END{print f+0}')
    if [ "$used4" = 0 ] && [ "$used6" = 0 ]; then WG_NEXT_IPV4="$base4.$n/$prefix4"; WG_NEXT_IPV6="$base6:$n/$prefix6"; return 0; fi
    n=$((n+1))
  done
  return 1
}

wg_delete(){
  screen_clear; [ -f "$WG_CONF" ] || { tell_warn "未配置 WireGuard"; wait_key; return; }
  prompt_yes "确认删除 WireGuard 配置" || return
  local previous was_active
  previous=$(state_get exit)
  was_active=0
  [ "$(jq -r '.enabled // false' "$WG_CONF" 2>/dev/null)" = true ] && was_active=1
  wg_delete_platform_cleanup
  if [ "$was_active" = 1 ] || [ "$previous" = wireguard ]; then
    service_stop
  fi
  rm -rf "$WG_DIR"
  mkdir -p "$WG_DIR"; chmod 700 "$WG_DIR"
  if [ "$was_active" = 1 ] || [ "$previous" = wireguard ]; then
    state_set exit direct || { tell_warn "配置已删除，但状态保存失败"; wait_key; return; }
    sync_proxy_env
    if apply_config restart; then tell_ok "配置已删除"; else tell_warn "配置已删除，但配置应用失败"; fi
  else
    tell_ok "配置已删除"
  fi
  wait_key
}

list_peers(){
  local current=$(state_get exit) title=${1:-节点选择}
  PEER_COUNT=0
  set -- "$PEER_DIR"/*.json
  [ ! -e "$1" ] && { screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> $title <<${PLAIN}"; tell "  暂无外部节点"; return 0; }
  local tmp_dir idx=0 raw_data old_ifs test_pids=""
  tmp_dir=$(mktemp -d) || return 1
  TMP_FILES="$TMP_FILES $tmp_dir"
  raw_data=$(jq -r '"\(input_filename)|\(.tag//"-")|\(.outbound.type//"-")|\(.name//"-")|\(.outbound.server_port // (if .outbound.server_ports then (.outbound.server_ports[0]|gsub(":";"-")) else null end) // .outbound.listen_port // "-")|\(.outbound.server//"")"' "$@" 2>/dev/null)
  if [ -n "$raw_data" ]; then
    old_ifs="$IFS"; IFS="|"
    while read -r file tag type name port host; do
      idx=$((idx+1))
      eval "PEER_FILE_${idx}=\"$file\""; eval "PEER_TAG_${idx}=\"$tag\""; eval "PEER_TYPE_${idx}=\"$type\""; eval "PEER_NAME_${idx}=\"$name\""; eval "PEER_PORT_${idx}=\"$port\""
      (
        local ms=""
        peer_latency "$file" "$tmp_dir/res_$idx" "$tmp_dir/lat_$idx"
      ) &
      test_pids="$test_pids $!"
    done <<EOF
$raw_data
EOF
    IFS="$old_ifs"
  fi
  PEER_COUNT=$idx
  [ -n "$test_pids" ] && wait $test_pids 2>/dev/null
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> $title <<${PLAIN}"
  idx=1
  while [ "$idx" -le "$PEER_COUNT" ]; do
    local tag type name port mark="" ms color status_text
    eval "tag=\"\$PEER_TAG_${idx}\""; eval "type=\"\$PEER_TYPE_${idx}\""; eval "name=\"\$PEER_NAME_${idx}\""; eval "port=\"\$PEER_PORT_${idx}\""
    ms=$(cat "$tmp_dir/lat_$idx" 2>/dev/null)
    [ -n "$ms" ] || ms=$(cat "$tmp_dir/res_$idx" 2>/dev/null)
    if echo "$ms" | grep -Eq '^[0-9]+$'; then
      if [ "$ms" -lt 100 ]; then color="$GREEN"; elif [ "$ms" -lt 150 ]; then color="$YELLOW"; else color="$BROWN"; fi
      status_text="${ms} ms"
    else
      color="$RED"; status_text="超时"
    fi
    [ "$tag" = "$current" ] && mark=" ${CYAN}<=当前${color}" || mark=""
    printf "  %b%2d. [%-7s] %s:%s %b %s%b\n" "$color" "$idx" "$type" "$name" "$port" "$mark" "$status_text" "$PLAIN"
    idx=$((idx+1))
  done
  rm -rf "$tmp_dir"; return 0
}

wg_client_delete(){
  local index count body
  count=$(jq '.endpoint.peers | length' "$WG_CONF" 2>/dev/null); count=${count:-0}
  [ "$count" -gt 0 ] || { tell_warn "暂无客户端"; wait_key; return; }
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> 删除客户端 <<${PLAIN}"
  jq -r '.clients | to_entries[] | "  \(.key+1). \(.value.name) | \(.value.ipv4) | \(.value.ipv6)"' "$WG_CONF" 2>/dev/null
  tell "  0. 返回"
  index=$(prompt "请选择")
  [ "$index" = 0 ] && return
  echo "$index" | grep -Eq '^[0-9]+$' && [ "$index" -ge 1 ] && [ "$index" -le "$count" ] || { tell_warn "序号无效"; wait_key; return; }
  index=$((index-1))
  prompt_yes "确认删除客户端 $(jq -r ".clients[$index].name" "$WG_CONF")" || return
  body=$(jq --argjson i "$index" 'del(.clients[$i]) | del(.endpoint.peers[$i])' "$WG_CONF") || { tell_warn "配置生成失败"; wait_key; return; }
  wg_client_apply_body "$body" || { wait_key; return; }
  tell_ok "客户端已删除"
  wait_key
}

wg_edit_server(){
  local value body
  while :; do screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 修改配置 <<${PLAIN}"; tell "  1. 客户端管理"; tell "  2. 监听端口"; tell "  3. 隧道内网地址"; tell "  0. 返回"
    case $(prompt "请选择") in
      1) wg_server_clients ;; 2) value=$(prompt_port u "$(jq -r '.listen_port' "$WG_CONF")") || continue; body=$(jq --argjson p "$value" '.listen_port=$p|.endpoint.listen_port=$p' "$WG_CONF") || continue; wg_server_edit_apply "$body" && tell_ok "已修改"; sleep 1 ;;
      3) wg_edit_address ;; 0) return ;; *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
}

wg_edit_client(){
  local value body
  while :; do screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 修改配置 <<${PLAIN}"; tell "  1. 服务端地址"; tell "  2. 服务端端口"; tell "  3. 服务端公钥"; tell "  4. 内网双栈地址"; tell "  0. 返回"
    case $(prompt "请选择") in
      1) value=$(prompt "服务端地址" "$(jq -r '.peer_host // ""' "$WG_CONF")"); [ -n "$value" ] || { tell_warn "服务端地址不能为空"; sleep 1; continue; }; body=$(jq --arg v "$value" '.peer_host=$v|.endpoint.peers[0].address=$v' "$WG_CONF") || continue; wg_client_edit_apply "$body" && tell_ok "已修改"; sleep 1 ;;
      2) value=$(prompt_port u "$(jq -r '.peer_port // 0' "$WG_CONF")") || continue; body=$(jq --argjson p "$value" '.peer_port=$p|.endpoint.peers[0].port=$p' "$WG_CONF") || continue; wg_client_edit_apply "$body" && tell_ok "已修改"; sleep 1 ;;
      3) value=$(prompt "服务端公钥" "$(jq -r '.peer_public_key // ""' "$WG_CONF")"); [ -n "$value" ] || { tell_warn "服务端公钥不能为空"; sleep 1; continue; }; body=$(jq --arg v "$value" '.peer_public_key=$v|.endpoint.peers[0].public_key=$v' "$WG_CONF") || continue; wg_client_edit_apply "$body" && tell_ok "已修改"; sleep 1 ;;
      4) wg_edit_address ;; 0) return ;; *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
}

validate_port(){
  local port=$1 proto=$2 allow=${3:-}
  case "$port" in ''|*[!0-9]*) tell_warn "端口格式无效"; return 1;; esac
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || { tell_warn "端口格式无效"; return 1; }
  if [ "$PLATFORM" = systemd ]; then
    [ "$port" = 80 ] && { tell_warn "端口 80 已保留给证书签发"; return 1; }
  else
    [ "$port" = 80 ] && [ "$(state_get challenge)" = http ] && { tell_warn "端口 80 已保留给证书签发"; return 1; }
  fi
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
    validate_port "$port" "$proto" "$current" && { printf '%s' "$port"; return 0; }
  done
}

probe_handshake_target(){
  local target=$1 result
  command -v openssl >/dev/null 2>&1 || { tell_warn "openssl 未安装，无法验证"; return 1; }
  result=$(printf '\n' | timeout 10 openssl s_client -connect "$target:443" -servername "$target" -alpn h2 -tls1_3 2>/dev/null)
  printf '%s\n' "$result" | grep -q 'TLSv1.3' || { tell_warn "不支持 TLS 1.3 协议"; return 1; }
  printf '%s\n' "$result" | grep -q 'ALPN protocol: h2' || { tell_warn "不支持 HTTP/2 协议"; return 1; }
  printf '%s\n' "$result" | grep -qi 'X25519' || { tell_warn "未检测到 X25519 特性"; return 1; }
  tell_ok "握手目标验证通过"; return 0
}

current_public_ipv4(){
  if [ -n "${NET_IPV4:-}" ]; then printf '%s' "$NET_IPV4"; elif command -v local_ipv4 >/dev/null 2>&1; then local_ipv4; fi
}
current_public_ipv6(){
  if [ -n "${NET_IPV6:-}" ]; then printf '%s' "$NET_IPV6"; elif command -v local_ipv6 >/dev/null 2>&1; then local_ipv6; fi
}

validate_domain(){
  local domain=$1 resolved ipv4 ipv6 mode=${2:-$(state_get challenge)}
  resolved=$(resolve_addresses "$domain")
  [ -n "$resolved" ] || { tell_warn "无法解析该域名"; return 1; }
  ipv4=$(current_public_ipv4); ipv6=$(current_public_ipv6)
  if ! { [ -n "$ipv4" ] && printf '%s\n' "$resolved" | grep -qx "$ipv4"; } && ! { [ -n "$ipv6" ] && printf '%s\n' "$resolved" | grep -qx "$ipv6"; }; then
    tell_warn "域名解析地址与本机 IP 不匹配"; return 1
  fi
  case "$mode" in
    http) printf '%s\n' "$(listening_ports t)" | grep -qx 80 && { tell_warn "本机 80 端口已被占用"; return 1; } ;;
    alpn) printf '%s\n' "$(listening_ports t)" | grep -qx 443 && { tell_warn "本机 443 端口已被占用"; return 1; } ;;
  esac
  tell_ok "解析记录正常"; return 0
}

certificate_ready(){
  local domain=$1 cert key cert_pub key_pub file
  [ -n "$domain" ] || return 1
  while IFS= read -r file; do
    if openssl x509 -in "$file" -noout -checkhost "$domain" >/dev/null 2>&1 && openssl x509 -in "$file" -noout -checkend 0 >/dev/null 2>&1; then cert="$file"; break; fi
  done <<EOF
$(find "$ACME_DIR/certificates" -type f -name '*.crt' 2>/dev/null)
EOF
  [ -n "$cert" ] || return 1
  key="${cert%.crt}.key"; [ -f "$key" ] || return 1
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
  key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
  [ -n "$cert_pub" ] && [ "$key_pub" = "$cert_pub" ]
}

wait_for_certificate(){
  local domain=$1 pid=${2:-} log_file=${3:-} log
  tell "等待证书签发完成: $domain"
  while :; do
    certificate_ready "$domain" && { tell_ok "证书已成功签发并完成校验"; return 0; }
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      tell_warn "证书签发进程已退出，证书签发失败"
      [ -n "$log_file" ] && [ -s "$log_file" ] && { tell "ACME 最后错误信息:"; tail -n 12 "$log_file"; }
      return 1
    fi
    if [ -z "$pid" ] && ! service_is_active; then
      tell_warn "sing-box 已停止，证书签发失败"
      if [ "$PLATFORM" = systemd ]; then log=$(journalctl -u sing-box -n 8 --no-pager 2>/dev/null); [ -n "$log" ] && tell "$log"; fi
      return 1
    fi
    sleep 1
  done
}

setup_certificate(){
  local suggest=${1:-} domain email mode cf_token ali_key ali_secret acmedns_url acmedns_user acmedns_pass acmedns_sub
  [ -n "$(state_get domain)" ] && [ -n "$(state_get email)" ] && return 0
  has_acme_support || { tell_warn "系统组件缺失，无法进行自动签发"; return 1; }
  printf '\n  %b该协议需要绑定域名并签发证书%b\n' "${YELLOW}" "${PLAIN}"
  if [ -n "$suggest" ]; then domain="$suggest"; printf '  %b已指定域名: %s%b\n' "${GREEN}" "$domain" "${PLAIN}"; else domain=$(prompt "输入域名"); [ -n "$domain" ] || return 1; fi
  email=$(prompt "ACME 通知邮箱" "admin@$domain"); [ -n "$email" ] || return 1
  printf '\n  %b选择域名证书验证方式:%b\n' "${CYAN}" "${PLAIN}"
  echo "  1. HTTP-01      (推荐，需放行 80 端口)"
  echo "  2. TLS-ALPN-01  (推荐，需放行 443 端口)"
  echo "  3. DNS-01       (Cloudflare API)"
  echo "  4. DNS-01       (阿里云 DNS API)"
  echo "  5. DNS-01       (ACME-DNS API)"
  cf_token=$(state_get cf_token); ali_key=$(state_get ali_key); ali_secret=$(state_get ali_secret)
  acmedns_url=$(state_get acmedns_url); acmedns_user=$(state_get acmedns_user); acmedns_pass=$(state_get acmedns_pass); acmedns_sub=$(state_get acmedns_sub)
  while :; do
    case $(prompt "请选择方式" 1) in
      1) mode=http; break;; 2) mode=alpn; break;;
      3) mode=dns_cloudflare; cf_token=$(prompt 'Cloudflare API Token'); break;;
      4) mode=dns_alidns; ali_key=$(prompt 'AccessKeyId'); ali_secret=$(prompt 'AccessKeySecret'); break;;
      5) mode=dns_acmedns; acmedns_url=$(prompt 'server_url'); acmedns_user=$(prompt 'username'); acmedns_pass=$(prompt 'password'); acmedns_sub=$(prompt 'subdomain'); break;;
      *) tell_warn "输入无效，请重新选择"; sleep 1;;
    esac
  done
  if ! validate_domain "$domain" "$mode"; then prompt_yes "验证存在异常，是否强制继续" || return 1; fi
  ACME_PENDING_DOMAIN="$domain"; ACME_PENDING_EMAIL="$email"; ACME_PENDING_MODE="$mode"; ACME_PENDING_CF_TOKEN="$cf_token"; ACME_PENDING_ALI_KEY="$ali_key"; ACME_PENDING_ALI_SECRET="$ali_secret"
  ACME_PENDING_ACMEDNS_URL="$acmedns_url"; ACME_PENDING_ACMEDNS_USER="$acmedns_user"; ACME_PENDING_ACMEDNS_PASS="$acmedns_pass"; ACME_PENDING_ACMEDNS_SUB="$acmedns_sub"
  BUILD_DOMAIN_OVERRIDE="$domain"
  return 0
}

select_peer(){
  local title=${1:-节点选择} index
  while :; do
    list_peers "$title"; [ "$PEER_COUNT" = 0 ] && { wait_key; return 1; }
    tell "  0. 返回"; index=$(prompt "请选择 [回车刷新]")
    [ -z "$index" ] && continue
    [ "$index" = 0 ] && return 1
    if printf '%s\n' "$index" | grep -Eq '^[0-9]+$' && [ "$index" -ge 1 ] && [ "$index" -le "$PEER_COUNT" ]; then
      eval "PICKED=\"\$PEER_FILE_${index}\""; return 0
    fi
    tell_warn "序号无效，请重新输入"; sleep 1
  done
}

peer_delete(){
  while :; do
    select_peer "删除节点" || return
    local previous_exit tag
    previous_exit=$(state_get exit); tag=$(jq -r .tag "$PICKED")
    if [ "$tag" = "$previous_exit" ]; then service_stop; fi
    rm -f "$PICKED"
    if [ "$tag" = "$previous_exit" ]; then
      state_set exit direct && sync_proxy_env || { tell_warn "状态保存失败"; wait_key; continue; }
      if apply_config restart; then tell_ok "已删除当前生效节点，已恢复直连"; else tell_warn "节点已删除，但配置应用失败"; fi
    else tell_ok "已删除节点"; fi
  done
}

wg_keypair(){
  local keypair private public
  keypair=$("$CORE" generate wg-keypair 2>/dev/null) || return 1
  private=$(printf '%s\n' "$keypair" | awk '/PrivateKey/{print $2}')
  public=$(printf '%s\n' "$keypair" | awk '/PublicKey/{print $2}')
  [ -n "$private" ] && [ -n "$public" ] || return 1
  WG_PRIVATE="$private"; WG_PUBLIC="$public"
}

wg_client_address_conflict(){
  local index=$1 ipv4=$2 ipv6=$3 ip4=${ipv4%/*} ip6=${ipv6%/*} conflict4 conflict6
  conflict4=$(jq -r --arg ip "$ip4" --argjson i "$index" '.clients | to_entries[] | select(.key != $i) | .value.ipv4 // empty' "$WG_CONF" 2>/dev/null | awk -F/ -v ip="$ip4" '$1==ip{f=1} END{print f+0}')
  conflict6=$(jq -r --arg ip "$ip6" --argjson i "$index" '.clients | to_entries[] | select(.key != $i) | .value.ipv6 // empty' "$WG_CONF" 2>/dev/null | awk -F/ -v ip="$ip6" '$1==ip{f=1} END{print f+0}')
  [ "$conflict4" = 0 ] && [ "$conflict6" = 0 ]
}

wg_server_clients(){
  while :; do
    screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 客户端管理 <<${PLAIN}"; tell "  1. 添加客户端"; tell "  2. 修改客户端"; tell "  3. 删除客户端"; tell "  4. 查看客户端"; tell "  0. 返回"
    case $(prompt "请选择") in 1) wg_client_add;; 2) wg_client_edit;; 3) wg_client_delete;; 4) wg_client_list;; 0) return;; *) tell_warn "输入无效"; sleep 1;; esac
  done
}

wg_client_list(){
  local count index name ipv4 ipv6 pub
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 客户端列表 <<${PLAIN}"
  count=$(jq '.endpoint.peers|length' "$WG_CONF" 2>/dev/null); count=${count:-0}
  if [ "$count" -eq 0 ]; then
    tell "暂无客户端"
  else
    index=0
    while [ "$index" -lt "$count" ]; do
      name=$(jq -r ".clients[$index].name // \"客户端 $((index+1))\"" "$WG_CONF" 2>/dev/null)
      ipv4=$(jq -r ".clients[$index].ipv4 // \"\"" "$WG_CONF" 2>/dev/null)
      ipv6=$(jq -r ".clients[$index].ipv6 // \"\"" "$WG_CONF" 2>/dev/null)
      pub=$(jq -r ".clients[$index].public_key // \"\"" "$WG_CONF" 2>/dev/null)
      tell "  ${BRIGHT_CYAN}$((index+1)). ${name}${PLAIN}"
      tell "     IPv4：${GREEN}${ipv4}${PLAIN}"
      tell "     IPv6：${GREEN}${ipv6}${PLAIN}"
      tell "     公钥：${pub}"
      index=$((index+1))
    done
  fi
  wait_key
}

wg_edit(){
  local role
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  role=$(jq -r '.role // ""' "$WG_CONF")
  case "$role" in server) wg_edit_server;; client) wg_edit_client;; *) tell_warn "WireGuard 配置无效"; wait_key;; esac
}

run_core_reinstall(){
  local success_msg=$1 apply_fail_msg=$2 install_fail_msg=$3
  service_stop
  if install_core; then
    if apply_config restart; then tell_ok "$success_msg"; else tell_warn "$apply_fail_msg"; fi
  else tell_warn "$install_fail_msg"; fi
  wait_key
}

get_ip_info(){
  local mode=$1 selected=${2:-} port tmp_conf tmp_log pid res ip country asn name url family_url i
  IP_INFO_IP=""; IP_INFO_C=""; IP_INFO_ASN=""; IP_INFO_NAME=""
  case "$mode" in 4) family_url=https://api4.ipify.org/?format=json ;; 6) family_url=https://api6.ipify.org/?format=json ;; *) return 1 ;; esac
  if [ -n "$selected" ] && [ "$selected" != direct ]; then
    [ -s "$CONFIG" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    mkdir -p "$SBM_DIR/tmp" 2>/dev/null || return 1
    port=$((20000 + $(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ') % 20000))
    [ "$port" -ge 20000 ] 2>/dev/null || port=20873
    tmp_conf=$(mktemp "$SBM_DIR/tmp/status-proxy.XXXXXX") || return 1
    tmp_log=$(mktemp "$SBM_DIR/tmp/status-proxy-log.XXXXXX") || { rm -f "$tmp_conf"; return 1; }
    if [ "$selected" = wireguard ]; then
      [ -s "$WG_CONF" ] || { rm -f "$tmp_conf" "$tmp_log"; return 1; }
      jq -n --argjson port "$port" --arg final "$selected" --argjson endpoint "$(jq -c '.endpoint' "$WG_CONF" 2>/dev/null)" '
        {log:{level:"warn"},dns:{servers:[{type:"https",tag:"dns-direct-v4",server:"1.1.1.1",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}}],final:"dns-direct-v4",strategy:"prefer_ipv4"},inbounds:[{type:"mixed",tag:"status-in",listen:"127.0.0.1",listen_port:$port}],outbounds:[{type:"direct",tag:"direct"},($endpoint|.tag=$final|.domain_resolver="dns-direct-v4")],endpoints:[],route:{final:$final,default_domain_resolver:"dns-direct-v4",auto_detect_interface:false}}
      ' >"$tmp_conf" 2>/dev/null || { rm -f "$tmp_conf" "$tmp_log"; return 1; }
    else
      [ -s "$PEER_DIR/$selected.json" ] || { rm -f "$tmp_conf" "$tmp_log"; return 1; }
      outbound=$(jq -c '.outbound | .domain_resolver="dns-direct-v4"' "$PEER_DIR/$selected.json" 2>/dev/null) || { rm -f "$tmp_conf" "$tmp_log"; return 1; }
      [ -n "$outbound" ] && [ "$outbound" != null ] || { rm -f "$tmp_conf" "$tmp_log"; return 1; }
      jq -n --argjson port "$port" --arg final "$selected" --argjson outbound "$outbound" '
        {log:{level:"warn"},dns:{servers:[{type:"https",tag:"dns-direct-v4",server:"1.1.1.1",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}}],final:"dns-direct-v4",strategy:"prefer_ipv4"},inbounds:[{type:"mixed",tag:"status-in",listen:"127.0.0.1",listen_port:$port}],outbounds:[{type:"direct",tag:"direct"},$outbound],endpoints:[],route:{final:$final,default_domain_resolver:"dns-direct-v4",auto_detect_interface:false}}
      ' >"$tmp_conf" 2>/dev/null || { rm -f "$tmp_conf" "$tmp_log"; return 1; }
    fi
    if ! "$CORE" check -c "$tmp_conf" >/dev/null 2>&1; then
      rm -f "$tmp_conf" "$tmp_log"
      return 1
    fi
    "$CORE" run -c "$tmp_conf" >"$tmp_log" 2>&1 & pid=$!
    res=""; i=0
    while [ "$i" -lt 3 ]; do
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
      res=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl -sS --socks5-hostname "127.0.0.1:$port" -m 5 "$family_url" 2>/dev/null) && break
      i=$((i+1)); sleep 0.2
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$tmp_conf" "$tmp_log"
  else
    if command -v curl >/dev/null 2>&1; then
      res=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl -sS -"$mode" -m 5 "$family_url" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
      res=$(wget -qO- -T 5 "$family_url" 2>/dev/null)
    else
      res=""
    fi
  fi
  ip=$(printf '%s' "$res" | jq -r '.ip // empty' 2>/dev/null)
  case "$mode" in
    4) printf '%s' "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1 ;;
    6) printf '%s' "$ip" | grep -q ':' || return 1 ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    res=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
      curl -sS -m 5 "https://ipwho.is/$ip" 2>/dev/null)
  elif command -v wget >/dev/null 2>&1; then
    res=$(wget -qO- -T 5 "https://ipwho.is/$ip" 2>/dev/null)
  else
    res=""
  fi
  country=$(printf '%s' "$res" | jq -r '.country // empty' 2>/dev/null)
  asn=$(printf '%s' "$res" | jq -r '.connection.asn // empty' 2>/dev/null)
  [ -n "$asn" ] && asn="AS$asn"
  name=$(printf '%s' "$res" | jq -r '.connection.org // empty' 2>/dev/null)
  IP_INFO_IP="$ip"; IP_INFO_C="$country"; IP_INFO_ASN="$asn"; IP_INFO_NAME="$name"
  return 0
}

render_client_ip_status(){
  local exit_node
  exit_node=$(state_get exit)
  if [ "$exit_node" != direct ] && [ -n "$exit_node" ]; then
    get_ip_info 4 "$exit_node"
  else
    get_ip_info 4
  fi
  if [ -n "$IP_INFO_IP" ]; then
    tell "  IPv4: ${GREEN}${IP_INFO_IP}${PLAIN} | 地区: ${YELLOW}${IP_INFO_C}${PLAIN}"
    tell "  所属: ${CYAN}${IP_INFO_NAME}${PLAIN} | ASN: ${PURPLE}${IP_INFO_ASN}${PLAIN}"
  else
    tell "  IPv4: ${RED}无或不可用${PLAIN}"
  fi
  if [ "$exit_node" != direct ] && [ -n "$exit_node" ]; then
    get_ip_info 6 "$exit_node"
  else
    get_ip_info 6
  fi
  if [ -n "$IP_INFO_IP" ]; then
    tell "  IPv6: ${GREEN}${IP_INFO_IP}${PLAIN} | 地区: ${YELLOW}${IP_INFO_C}${PLAIN}"
    tell "  所属: ${CYAN}${IP_INFO_NAME}${PLAIN} | ASN: ${PURPLE}${IP_INFO_ASN}${PLAIN}"
  else
    tell "  IPv6: ${RED}无或不可用${PLAIN}"
  fi
}

render_status_ip(){
  local exit_node protocol mode
  exit_node=$(state_get exit); mode="直连"
  if [ "$exit_node" = wireguard ]; then mode="WireGuard"
  elif [ "$exit_node" != direct ] && [ -f "$PEER_DIR/$exit_node.json" ]; then
    protocol=$(jq -r '.outbound.type // ""' "$PEER_DIR/$exit_node.json" 2>/dev/null)
    case "$protocol" in hysteria2) mode="Hysteria2";; vless) mode="VLESS";; vmess) mode="VMess";; tuic) mode="TUIC";; trojan) mode="Trojan";; anytls) mode="AnyTLS";; socks) mode="SOCKS5";; snell) mode="Snell";; http) mode="HTTP";; *) mode="${protocol:-未知}";; esac
  fi
  tell "  出口方式：${CYAN}${mode}${PLAIN}"
  render_client_ip_status
}


has_acme_support(){ case "$(core_tags)" in *with_acme*) return 0 ;; *) return 1 ;; esac; }

cleanup_old_domain_assets(){
  local domain=$1 dir
  [ -n "$domain" ] || return 0
  while IFS= read -r dir; do
    [ -n "$dir" ] && rm -rf -- "$dir"
  done <<EOF
$(find "$ACME_DIR/certificates" -type d -name "$domain" 2>/dev/null)
EOF
}

listening_ports(){
  local mode=$1
  if command -v ss >/dev/null 2>&1; then
    case "$mode" in
      t) ss -Hln -t 2>/dev/null | awk '{n=$4; sub(/^.*:/,"",n); if(n ~ /^[0-9]+$/) print n}' | sort -un ;;
      u) ss -Hln -u 2>/dev/null | awk '{n=$4; sub(/^.*:/,"",n); if(n ~ /^[0-9]+$/) print n}' | sort -un ;;
      *) ss -Hln -tu 2>/dev/null | awk '{n=$4; sub(/^.*:/,"",n); if(n ~ /^[0-9]+$/) print n}' | sort -un ;;
    esac
    return 0
  fi
  command -v netstat >/dev/null 2>&1 || return 0
  case "$mode" in
    t) netstat -tln 2>/dev/null | awk 'NR>2 {n=$4; sub(/^.*:/,"",n); if(n ~ /^[0-9]+$/) print n}' | sort -un ;;
    u) netstat -uln 2>/dev/null | awk 'NR>2 {n=$4; sub(/^.*:/,"",n); if(n ~ /^[0-9]+$/) print n}' | sort -un ;;
    *) netstat -tuln 2>/dev/null | awk 'NR>2 {n=$4; sub(/^.*:/,"",n); if(n ~ /^[0-9]+$/) print n}' | sort -un ;;
  esac
}

random_port(){
  awk 'BEGIN{srand(); print int(rand()*40001)+20000}'
}

acme_domain_assets_exist(){
  local domain=$1 dir
  [ -n "$domain" ] || return 1
  for dir in "$ACME_DIR"/certificates/*/"$domain"; do
    [ -d "$dir" ] && return 0
  done
  return 1
}
sync_proxy_env(){
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  rm -f /etc/profile.d/sbm_proxy.sh
  return 0
}

network_public_ip(){
  local family=$1 iface=${2:-} url
  case "$family" in
    4) url=https://ipv4.icanhazip.com ;;
    6) url=https://ipv6.icanhazip.com ;;
    *) return 1 ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$iface" ]; then
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY curl -"$family" -fsS --connect-timeout 3 -m 5 --interface "$iface" "$url" 2>/dev/null | tr -d '\n '
    else
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY curl -"$family" -fsS --connect-timeout 3 -m 5 "$url" 2>/dev/null | tr -d '\n '
    fi
  elif command -v wget >/dev/null 2>&1; then
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY wget -qO- -T 5 "$url" 2>/dev/null | tr -d '\n '
  fi
}
local_ipv4(){ network_public_ip 4 "${1:-}"; }
local_ipv6(){ network_public_ip 6 "${1:-}"; }

ipv6_egress_available(){
  local iface=${NET_IF_V6:-}
  [ -n "$iface" ] || iface=$(default_iface 6)
  [ -n "$iface" ] || return 1
  ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q 'inet6 ' || return 1
  ip -6 route show default 2>/dev/null | grep -q '^default' || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  timeout 5 openssl s_client -6 -connect '[2606:4700:4700::1111]:443' -servername cloudflare-dns.com </dev/null >/dev/null 2>&1
}

run_update(){
  local current latest
  screen_clear
  tell "正在检测 sing-box 内核更新..."
  current=$(core_version); latest=$(remote_version)
  tell "本地版本: ${current:-未知}"; tell "目标版本: ${latest:-获取失败}"
  if [ -z "$latest" ]; then
    tell_warn "无法获取最新版本，请检查网络或 GitHub 访问"
  elif [ -z "$current" ]; then
    if prompt_yes "无法读取当前内核版本，是否重新下载并安装 sing-box v$latest"; then
      run_core_reinstall "内核重新安装完成" "内核已下载，但配置应用失败" "内核重新安装失败"
    fi
  elif [ "$current" != "$latest" ]; then
    if prompt_yes "发现新版本 v$latest，是否立即更新"; then
      run_core_reinstall "内核更新完成" "内核更新完成，但配置应用失败" "内核更新失败"
    fi
  else
    tell_ok "内核已是最新版本"
  fi
  wait_key
}

menu_status(){
  while :; do
    screen_clear
    tell "${BRIGHT_CYAN}${BOLD}>> 状态与更新 <<${PLAIN}"
    local os=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null || echo "Alpine Linux")
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
    service_is_active && s_state="${GREEN}正常运行${PLAIN}"
    tell "  系统版本: ${os}"
    tell "  内核架构: ${core} (${arch})"
    tell "  内存状态: ${mem}"
    tell "  运行时间: ${up}"
    tell "  singbox : ${s_state}"
    tell "  singbox版本: ${sb_ver:-无} (${sb_asset:-未知})"
    tell ""
    render_status_ip
    tell ""
    tell "  1. 更新内核"
    tell "  2. 更新脚本"
    tell "  3. 卸载脚本"
    tell "  0. 返回"
    tell "${CYAN}--------------------------------${PLAIN}"
    case $(prompt "请选择") in
      1) run_update ;;
      2) run_script_update ;;
      3) run_uninstall ;;
      0) break ;;
      *) tell_warn "输入无效"; sleep 1 ;;
    esac
  done
}

__SBM_COMMON__
BUILD_DOMAIN_OVERRIDE=""
BUILD_SELECTED_OVERRIDE=""
NODE_EDIT_FILE=""
NODE_OVERRIDE_TARGET=""
NODE_OVERRIDE_FILE=""
WG_OVERRIDE_FILE=""
URI_SCHEME=""
URI_HOST=""
URI_PORT=""
URI_PORTS=""
URI_QUERY=""
URI_USERINFO=""

case "$PLATFORM" in
  OpenRC)
    











cat >"$PAYLOAD" <<'__SBM_OPENRC__'
wg_edit_address_apply(){ wg_apply_body "$1"; }
wg_client_apply_body(){ wg_apply_body "$1"; }
wg_server_edit_apply(){ wg_apply_body "$1"; }
wg_client_edit_apply(){ wg_apply_body "$1"; }

wg_delete_platform_cleanup(){ :; }

peer_latency(){
  local file=$1 result=$2 latency_file=${3:-} host ms
  host=$(jq -r '.outbound.server//""' "$file" 2>/dev/null) || { echo fail >"$result"; return 1; }
  ms=$(direct_ping_ms "$host")
  case "$ms" in
    ''|*[!0-9]*) echo fail >"$result"; return 1 ;;
    *) echo ok >"$result"; [ -n "$latency_file" ] && printf '%s\n' "$ms" >"$latency_file"; return 0 ;;
  esac
}

#!/bin/sh
export LC_ALL=C
export GOMEMLIMIT=15MiB
export GOGC=20

RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
BROWN='\033[1;33m'
PURPLE='\033[35m'
BLUE='\033[34m'
PLAIN='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
BRIGHT_CYAN='\033[1;36m'
BRIGHT_GREEN='\033[1;32m'
BRIGHT_YELLOW='\033[1;33m'
BRIGHT_MAGENTA='\033[1;35m'

if [ -z "${TERM:-}" ] || [ "${TERM:-}" = dumb ]; then
  RED=''; GREEN=''; CYAN=''; YELLOW=''; BROWN=''; PURPLE=''; BLUE=''; BOLD=''; DIM=''; BRIGHT_CYAN=''; BRIGHT_GREEN=''; BRIGHT_YELLOW=''; BRIGHT_MAGENTA=''; PLAIN=''
fi

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
SELF=${SBM_LAUNCHER_SELF:-$(readlink -f "$0" 2>/dev/null || echo "$PWD/${0#./}")}
SHORTCUT=/usr/local/bin/s
CORE=/usr/local/bin/sing-box
SERVICE_FILE=/etc/init.d/sing-box
CERT_TAG=acme-cert

NODE_COUNT=0
PEER_COUNT=0
PICKED=""
CORE_VERSION=""
CORE_TAGS=""
TMP_FILES=""
NET_MONITOR_PID=/var/run/sbm_netmon.pid
REAPPLY_LOCK=$SBM_DIR/reapply.lock
ACME_PENDING_DOMAIN=""
ACME_PENDING_EMAIL=""
ACME_PENDING_MODE=""
ACME_PENDING_CF_TOKEN=""
ACME_PENDING_ALI_KEY=""
ACME_PENDING_ALI_SECRET=""
ACME_PENDING_ACMEDNS_URL=""
ACME_PENDING_ACMEDNS_USER=""
ACME_PENDING_ACMEDNS_PASS=""
ACME_PENDING_ACMEDNS_SUB=""

IP_INFO_IP=""
IP_INFO_C=""
IP_INFO_ASN=""
IP_INFO_NAME=""

[ "$(id -u)" = 0 ] || { printf '%b[×] 权限不足: 请使用 root 用户运行%b\n' "${RED}" "${PLAIN}"; exit 1; }

cleanup_tmp() {
  [ -n "$TMP_FILES" ] && rm -rf $TMP_FILES
}
trap cleanup_tmp EXIT INT TERM

























check_dependencies(){
  local to_install=""
  command -v jq >/dev/null 2>&1 || to_install="$to_install jq"
  command -v curl >/dev/null 2>&1 || to_install="$to_install curl"
  [ -f /etc/ssl/certs/ca-certificates.crt ] || to_install="$to_install ca-certificates"
  command -v openssl >/dev/null 2>&1 || to_install="$to_install openssl"
  command -v ping >/dev/null 2>&1 || to_install="$to_install iputils"
  command -v timeout >/dev/null 2>&1 || to_install="$to_install coreutils"
  command -v ip >/dev/null 2>&1 || to_install="$to_install iproute2"
  command -v flock >/dev/null 2>&1 || to_install="$to_install util-linux"

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





acme_options(){
  local domain=$1 body email mode cf_token ali_key ali_secret acmedns_user acmedns_pass acmedns_sub acmedns_url
  if [ -n "$ACME_PENDING_DOMAIN" ] && [ "$domain" = "$ACME_PENDING_DOMAIN" ]; then
    email=$ACME_PENDING_EMAIL; mode=$ACME_PENDING_MODE; cf_token=$ACME_PENDING_CF_TOKEN; ali_key=$ACME_PENDING_ALI_KEY; ali_secret=$ACME_PENDING_ALI_SECRET
    acmedns_user=$ACME_PENDING_ACMEDNS_USER; acmedns_pass=$ACME_PENDING_ACMEDNS_PASS; acmedns_sub=$ACME_PENDING_ACMEDNS_SUB; acmedns_url=$ACME_PENDING_ACMEDNS_URL
  else
    email=$(state_get email); mode=$(state_get challenge); cf_token=$(state_get cf_token); ali_key=$(state_get ali_key); ali_secret=$(state_get ali_secret)
    acmedns_user=$(state_get acmedns_user); acmedns_pass=$(state_get acmedns_pass); acmedns_sub=$(state_get acmedns_sub); acmedns_url=$(state_get acmedns_url)
  fi
  body=$(jq -n --arg d "$domain" --arg e "$email" --arg dir "$ACME_DIR" '{domain:[$d],email:$e,data_directory:$dir,key_type:"p256"}') || return 1
  case "$mode" in
    alpn) body=$(echo "$body" | jq '.disable_http_challenge=true') || return 1 ;;
    dns_cloudflare) body=$(echo "$body" | jq --arg t "$cf_token" '.dns01_challenge={provider:"cloudflare",api_token:$t}') || return 1 ;;
    dns_alidns) body=$(echo "$body" | jq --arg k "$ali_key" --arg s "$ali_secret" '.dns01_challenge={provider:"alidns",access_key_id:$k,access_key_secret:$s}') || return 1 ;;
    dns_acmedns) body=$(echo "$body" | jq --arg u "$acmedns_user" --arg p "$acmedns_pass" --arg s "$acmedns_sub" --arg r "$acmedns_url" '.dns01_challenge={provider:"acmedns",username:$u,password:$p,subdomain:$s,server_url:$r}') || return 1 ;;
    *) body=$(echo "$body" | jq '.disable_tls_alpn_challenge=true') || return 1 ;;
  esac
  printf '%s' "$body"
}

remote_version(){
  wget -qO- -T 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//'
}

transparent_proxy_available(){
  local cap hex low16 nibble
  [ -c /dev/net/tun ] || return 1
  hex=$(awk '$1=="CapEff:"{print $2; exit}' /proc/self/status 2>/dev/null)
  [ -n "$hex" ] || return 1
  low16=$(printf '%s' "$hex" | sed 's/^.*\(....\)$/\1/')
  [ "${#low16}" -eq 4 ] || return 1
  nibble=$(printf '%s' "$low16" | cut -c1)
  case "$nibble" in
    1|3|5|7|9|b|d|f|B|D|F) return 0 ;;
    *) return 1 ;;
  esac
}

default_iface(){
  local family=$1 target iface
  if [ "$family" = 4 ]; then target=1.1.1.1; else target=2606:4700:4700::1111; fi
  iface=$(ip -"$family" route get "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  if [ -n "${TUN_IF:-}" ] && [ "$iface" = "$TUN_IF" ]; then iface=""; fi
  if [ -n "${WG_IF:-}" ] && [ "$iface" = "$WG_IF" ]; then iface=""; fi
  if [ -z "$iface" ]; then
    iface=$(ip -"$family" route show table main default 2>/dev/null | awk -v t="${TUN_IF:-}" -v w="${WG_IF:-}" '$5!="" && ($5!=t || t=="") && ($5!=w || w==""){print $5;exit}')
  fi
  printf '%s' "$iface"
}


ipv6_listen_available(){
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '
}

resolve_addresses(){
  if command -v getent >/dev/null 2>&1; then
    { getent ahostsv4 "$1"; getent ahostsv6 "$1"; getent hosts "$1"; } 2>/dev/null | awk '{print $1}' | sort -u
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$1" 2>/dev/null | awk '/^Name:/{f=1} f && /^Address/{print $NF}' | sort -u
  fi
}

install_core(){
  local version arch url tmpdir

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
  tmpdir=$(mktemp -d) || return 1
  TMP_FILES="$TMP_FILES $tmpdir"

  if wget -qO- -T 120 "$url" 2>/dev/null | tar -xzf - -C "$tmpdir" 2>/dev/null; then
    if [ -f "$tmpdir/sing-box-${version}-${arch}/sing-box" ]; then
      install -m755 "$tmpdir/sing-box-${version}-${arch}/sing-box" "$CORE" || {
        rm -rf "$tmpdir"
        return 1
      }
      core_cache_reset
      state_set asset "$arch" || true
      tell_ok "sing-box 内核已安装: v${version} [$arch]"
      rm -rf "$tmpdir"
      return 0
    fi
  fi

  rm -rf "$tmpdir"
  tell_warn "安装包下载或解压失败"
  return 1
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

respawn_delay=0
respawn_max=0

depend() {
    need net
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
    if command -v ss >/dev/null 2>&1; then
      ss -Hlnpt 2>/dev/null | awk '/sshd/{n=$4; sub(/^.*:/,"",n); if(n ~ /^[0-9]+$/) print n}'
    elif command -v netstat >/dev/null 2>&1; then
      netstat -tlnp 2>/dev/null | awk '/sshd/{n=$4; sub(/^.*:/,"",n); if(n ~ /^[0-9]+$/) print n}'
    fi
    [ -f /etc/ssh/sshd_config ] && sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' /etc/ssh/sshd_config 2>/dev/null
    for f in /etc/ssh/sshd_config.d/*.conf; do [ -e "$f" ] && sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\).*/\1/p' "$f" 2>/dev/null; done
  } | grep -E '^[1-9][0-9]*$' | sort -un
}


protected_ports(){ { ssh_ports; for f in "$NODE_DIR"/*.json; do [ -e "$f" ] || continue; jq -r '.port//empty' "$f"; done; wg_listen_port; } | grep -E '^[1-9][0-9]*$' | sort -un; }














create_hysteria2(){
  local name port password tag body up_mbps down_mbps obfs_type obfs_password bbr_profile min_pkt max_pkt cc_choice
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"; name=$(prompt "节点名称" "Hysteria2"); setup_certificate || return; port=$(prompt_port u ""); password=$(prompt "连接密码 (留空自动生成)" "$(random_password)"); bbr_profile=""; up_mbps=0; down_mbps=0
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
    if [ "$obfs_type" = gecko ]; then min_pkt=$(prompt "最小包大小 (字节, 512-2048)" 512); max_pkt=$(prompt "最大包大小 (字节, 512-2048)" 1200); echo "$min_pkt"|grep -Eq '^[0-9]+$' || min_pkt=512; echo "$max_pkt"|grep -Eq '^[0-9]+$' || max_pkt=1200; fi
  fi
  tag=$(unique_tag "$name" in- "$NODE_DIR")
  body=$(jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg password "$password" --argjson up "$up_mbps" --argjson down "$down_mbps" --arg obfs_type "$obfs_type" --arg obfs_pw "$obfs_password" --arg bbr "$bbr_profile" --arg min_pkt "$min_pkt" --arg max_pkt "$max_pkt" '
   {tag:$tag,name:$name,kind:"hysteria2",port:$port,proto:"u",tls_mode:"acme",alpn:["h3"],meta:({password:$password,up_mbps:$up,down_mbps:$down,obfs_type:$obfs_type,obfs_password:$obfs_pw}|if $bbr!="" then .bbr_profile=$bbr else . end|if $obfs_type=="gecko" and $min_pkt!="" then .min_packet_size=($min_pkt|tonumber) else . end|if $obfs_type=="gecko" and $max_pkt!="" then .max_packet_size=($max_pkt|tonumber) else . end),inbound:({type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{password:$password}]}|if $up>0 then .up_mbps=$up else . end|if $down>0 then .down_mbps=$down else . end|if $bbr!="" then .bbr_profile=$bbr else . end|if $obfs_type!="" then .obfs={type:$obfs_type,password:$obfs_pw} else . end|if $obfs_type=="gecko" and $min_pkt!="" then .obfs.min_packet_size=($min_pkt|tonumber) else . end|if $obfs_type=="gecko" and $max_pkt!="" then .obfs.max_packet_size=($max_pkt|tonumber) else . end)}')
  save_node "$NODE_DIR/$tag.json" "$body"
}







build_config(){
  local selected domain listen_addr dns_strategy bootstrap_tag final='direct'
  local inbounds outbounds endpoints dns rules providers='[]' selected_outbound tls_extra='{}' dns_v6=0
  selected=${BUILD_SELECTED_OVERRIDE:-$(state_get exit)}
  domain=${BUILD_DOMAIN_OVERRIDE:-$(state_get domain)}
  listen_addr='0.0.0.0'
  dns_strategy='prefer_ipv4'
  bootstrap_tag='dns-bootstrap-v4'
  if ipv6_egress_available; then
    dns_strategy='prefer_ipv6'
    dns_v6=1
  fi
  if ipv6_listen_available; then
    listen_addr='::'
  fi
  inbounds='[]'
  endpoints='[]'
  outbounds='[{"type":"direct","tag":"direct"}]'

  if [ -n "$domain" ]; then
    local acme_json
    acme_json=$(acme_options "$domain") || return 1
    providers=$(jq -n --arg tag "$CERT_TAG" --argjson options "$acme_json" '[$options+{type:"acme",tag:$tag}]') || return 1
    tls_extra=$(jq -n --arg cert "$CERT_TAG" '{certificate_provider:$cert}') || return 1
  fi
  if [ -n "$ACME_PENDING_DOMAIN" ] && [ "$ACME_PENDING_DOMAIN" != "$domain" ]; then
    local pending_json
    pending_json=$(acme_options "$ACME_PENDING_DOMAIN") || return 1
    providers=$(jq -c --arg tag "${CERT_TAG}-pending" --argjson options "$pending_json" '. + [$options+{type:"acme",tag:$tag}]' <<EOF
$providers
EOF
) || return 1
  fi

  if find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null | grep -q .; then
    inbounds=$(for f in "$NODE_DIR"/*.json; do [ -e "$f" ] || continue; if [ -n "$NODE_OVERRIDE_TARGET" ] && [ "$f" = "$NODE_OVERRIDE_TARGET" ] && [ -f "$NODE_OVERRIDE_FILE" ]; then cat "$NODE_OVERRIDE_FILE"; else cat "$f"; fi; done | jq -s \
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
  elif { [ -f "$WG_CONF" ] || [ -n "$WG_OVERRIDE_FILE" ]; } && [ "$(jq -r '.enabled//false' "${WG_OVERRIDE_FILE:-$WG_CONF}")" = true ]; then
    local wgob wgrole wg_source
    if [ -n "$WG_OVERRIDE_FILE" ] && [ -f "$WG_OVERRIDE_FILE" ]; then wg_source="$WG_OVERRIDE_FILE"; else wg_source="$WG_CONF"; fi
    wgob=$(jq -c --arg resolver "$bootstrap_tag" '.endpoint | if (.peers[0].address // "") != "" then .domain_resolver=$resolver else . end' "$wg_source") || return 1
    wgrole=$(jq -r '.role//""' "$wg_source")
    [ "$wgrole" = client ] || [ "$wgrole" = server ] || return 1
    endpoints=$(jq -c --argjson ep "$wgob" '.+[$ep]' <<EOF
$endpoints
EOF
) || return 1
    if [ "$wgrole" = client ] && [ "$selected" = wireguard ]; then final=wireguard; fi
  fi



  dns=$(jq -n --arg strategy "$dns_strategy" --arg final "$final" --argjson v6ok "$dns_v6" '
    (if $v6ok then "2606:4700:4700::1111" else "1.1.1.1" end) as $remote_server |
    {servers:[
      {type:"https",tag:"dns-bootstrap-v4",server:"1.1.1.1",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}},
      {type:"https",tag:"dns-bootstrap-v6",server:"2606:4700:4700::1111",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}},
      {type:"https",tag:"dns-remote",server:$remote_server,server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"},domain_resolver:{server:(if $v6ok then "dns-bootstrap-v6" else "dns-bootstrap-v4" end),strategy:$strategy}}
    ],strategy:$strategy,final:"dns-remote"}
    | if $final!="direct" then .servers |= map(if .tag=="dns-remote" then .detour=$final else . end) else . end
  ') || return 1

  rules=$(jq -n '[{action:"sniff"}]') || return 1
  local target_resolver="$bootstrap_tag"
  [ "$final" = direct ] || [ "$final" = wireguard ] || target_resolver=dns-remote
  jq -n --argjson inbounds "$inbounds" --argjson outbounds "$outbounds" --argjson endpoints "$endpoints" --argjson dns "$dns" --argjson rules "$rules" --argjson providers "$providers" --arg final "$final" --arg resolver "$target_resolver" '
    {log:{level:"warn",timestamp:true},dns:$dns,inbounds:$inbounds,outbounds:$outbounds,endpoints:$endpoints,route:{rules:$rules,final:$final,default_domain_resolver:$resolver}}
    | if ($providers|length)>0 then .certificate_providers=$providers else . end
  '
}

apply_config(){
  local tmp
  tmp=$(mktemp) || return 1
  TMP_FILES="$TMP_FILES $tmp"
  if ! build_config >"$tmp" || ! jq -e . "$tmp" >/dev/null 2>&1 || ! "$CORE" check -c "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; return 1; fi
  install -m600 "$tmp" "$CONFIG" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  if rc-service sing-box status >/dev/null 2>&1; then
    rc-service sing-box restart >/dev/null 2>&1 || return 1
  else
    rc-service sing-box start >/dev/null 2>&1 || return 1
  fi
  rc-service sing-box status >/dev/null 2>&1 || return 1
  return 0
}





build_uri(){
  local kind=$1 name=$2 port=$3 meta=$4 host=$5 uri=""
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
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "$host") || return 1
    [ -n "$uri" ] || { tell_warn "生成分享链接失败"; return 1; }
    tell "${GREEN}$uri${PLAIN}"
    return 0
  fi

  raw_ip=$(env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= wget -qO- -T 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n ')
  if [ -n "$raw_ip" ]; then
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "$raw_ip")
    if [ -n "$uri" ]; then tell "${GREEN}$uri${PLAIN}"; found=1; fi
  fi

  raw_ip=$(env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= wget -qO- -T 5 https://ipv6.icanhazip.com 2>/dev/null | tr -d '\r\n ')
  if [ -n "$raw_ip" ]; then
    uri=$(build_uri "$kind" "$name" "$port" "$meta" "[$raw_ip]")
    if [ -n "$uri" ]; then tell "${GREEN}$uri${PLAIN}"; found=1; fi
  fi

  [ "$found" = 1 ] || { tell_warn "未识别到本机公网 IP，生成链接失败"; return 1; }
  [ "$kind" = snell ] && tell_warn "Snell 分享链接可能不被所有客户端识别，请手动复制 PSK"
  return 0
}




menu_delete_protocol(){
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 删除协议 <<${PLAIN}"
  select_node || return
  prompt_yes "确认删除 $(jq -r .name "$PICKED")" || return
  local was_acme
  was_acme=$(jq -r .tls_mode "$PICKED")
  local backup
  backup=$(mktemp "$TMPDIR/node-delete.XXXXXX") || { tell_warn "临时文件创建失败"; wait_key; return; }
  mv "$PICKED" "$backup" || { rm -f "$backup"; tell_warn "删除失败"; wait_key; return; }
  if apply_config; then
    [ "$(jq -r .tag "$backup")" = "$(state_get exit)" ] && state_set exit direct && sync_proxy_env
    rm -f "$backup"
    tell_ok "已删除"
    if [ "$was_acme" = "acme" ]; then
      local acme_count=0
      for f in "$NODE_DIR"/*.json; do [ -e "$f" ] || continue; [ "$(jq -r .tls_mode "$f")" = "acme" ] && acme_count=$((acme_count+1)); done
      if [ "$acme_count" -eq 0 ] && [ -n "$(state_get domain)" ]; then
        printf "\n"
        if prompt_yes "是否连同域名和证书一起清理"; then
          local old_domain old_email old_challenge
          old_domain=$(state_get domain); old_email=$(state_get email); old_challenge=$(state_get challenge)
          if json_edit "$STATE" '.domain=""|.email=""|.challenge="http"' && apply_config; then
            find "$ACME_DIR" -mindepth 1 -delete 2>/dev/null; tell_ok "相关配置已清理"
          else
            json_edit "$STATE" '.domain=$d|.email=$e|.challenge=$c' --arg d "$old_domain" --arg e "$old_email" --arg c "$old_challenge" >/dev/null 2>&1 || true
            tell_warn "域名配置清理失败"
          fi
        fi
      fi
    fi
  else
    mv "$backup" "$PICKED"
    tell_warn "配置应用失败"
  fi
  wait_key
}

node_edit_stage(){
  local file=$1 expr=$2; shift 2
  local tmp
  [ -n "$NODE_EDIT_FILE" ] || return 1
  tmp=$(mktemp) || return 1
  if jq "$@" "$expr" "$NODE_EDIT_FILE" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    install -m600 "$tmp" "$NODE_EDIT_FILE" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

wg_apply_body(){
  local body=$1 tmp
  tmp=$(mktemp) || return 1
  printf '%s\n' "$body" >"$tmp" || { rm -f "$tmp"; return 1; }
  WG_OVERRIDE_FILE="$tmp"
  if apply_config; then
    install -m600 "$tmp" "$WG_CONF" || { rm -f "$tmp"; WG_OVERRIDE_FILE=""; return 1; }
    rm -f "$tmp"; WG_OVERRIDE_FILE=""; return 0
  fi
  rm -f "$tmp"; WG_OVERRIDE_FILE=""; return 1
}

menu_modify_protocol(){
  local kind value bbr_profile up_mbps down_mbps obfs_type obfs_password min_pkt max_pkt len
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 修改配置 <<${PLAIN}"
  select_node || return
  NODE_EDIT_FILE=$(mktemp) || { tell_warn "临时文件创建失败"; wait_key; return; }
  cp "$PICKED" "$NODE_EDIT_FILE" || { rm -f "$NODE_EDIT_FILE"; NODE_EDIT_FILE=""; return; }
  NODE_OVERRIDE_TARGET="$PICKED"
  NODE_OVERRIDE_FILE="$NODE_EDIT_FILE"
  while :; do
    kind=$(jq -r .kind "$NODE_EDIT_FILE")
    screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> $(jq -r .name "$NODE_EDIT_FILE") [$kind] <<${PLAIN}"
    tell "  1. 识别名称"; tell "  2. 监听端口"
    case "$kind" in
      vless-reality|vless-tls) tell "  3. 通信 UUID" ;;
      tuic) tell "  3. 通信 UUID"; tell "  4. 连接密码" ;;
      socks) tell "  3. 鉴权密码"; tell "  4. 鉴权账号" ;;
      snell) tell "  3. 预共享密钥"; tell "  4. 流量整形模式" ;;
      anytls) tell "  3. 连接密码"; tell "  4. 客户端元数据" ;;
      hysteria2) tell "  3. 连接密码"; tell "  4. 拥塞控制"; tell "  5. 混淆设置" ;;
      *) tell "  3. 连接密码" ;;
    esac
    [ "$kind" = vless-reality ] && tell "  5. 握手目标域名"
    [ "$kind" = vless-reality ] && tell "  6. short_id"
    tell "  0. 返回"; tell "${CYAN}------------------------------${PLAIN}"
    case $(prompt "请选择") in
      1)
        value=$(prompt "新识别名称" "$(jq -r .name "$NODE_EDIT_FILE")"); [ -n "$value" ] || continue
        node_edit_stage "$PICKED" '.name=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; continue; } ;;
      2)
        value=$(prompt_port "$(jq -r .proto "$NODE_EDIT_FILE")" "$(jq -r .port "$NODE_EDIT_FILE")") || continue
        node_edit_stage "$PICKED" '.port=$v|.inbound.listen_port=$v' --argjson v "$value" || { tell_warn "修改失败"; wait_key; continue; } ;;
      3)
        if [ "$kind" = vless-reality ] || [ "$kind" = vless-tls ] || [ "$kind" = tuic ]; then
          value=$(prompt "新通信 UUID (留空自动生成)" "$(jq -r '.meta.uuid//""' "$NODE_EDIT_FILE")"); [ -n "$value" ] || value=$(random_uuid)
          node_edit_stage "$PICKED" '.meta.uuid=$v|.inbound.users[0].uuid=$v' --arg v "$value"
        elif [ "$kind" = snell ]; then
          while :; do
            value=$(prompt "新 PSK (留空自动生成, 12-255字节)" "$(jq -r '.meta.psk//""' "$NODE_EDIT_FILE")"); [ -n "$value" ] || value=$(random_password)
            len=$(printf '%s' "$value" | wc -c | tr -d ' ')
            [ "$len" -ge 12 ] && [ "$len" -le 255 ] && break
            tell_warn "PSK 长度必须为 12-255 字节，当前 ${len} 字节"
          done
          node_edit_stage "$PICKED" '.meta.psk=$v|.inbound.psk=$v' --arg v "$value"
        else
          value=$(prompt "新连接密码 (留空自动生成)" "$(jq -r '.meta.password//""' "$NODE_EDIT_FILE")"); [ -n "$value" ] || value=$(random_password)
          node_edit_stage "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value"
        fi || { tell_warn "修改失败"; wait_key; continue; } ;;
      4)
        if [ "$kind" = socks ]; then
          value=$(prompt "鉴权账号" "$(jq -r '.meta.username//""' "$NODE_EDIT_FILE")"); [ -n "$value" ] || continue
          node_edit_stage "$PICKED" '.meta.username=$v|.inbound.users[0].username=$v' --arg v "$value"
        elif [ "$kind" = tuic ]; then
          value=$(prompt "新连接密码 (留空自动生成)" "$(jq -r '.meta.password//""' "$NODE_EDIT_FILE")"); [ -n "$value" ] || value=$(random_password)
          node_edit_stage "$PICKED" '.meta.password=$v|.inbound.users[0].password=$v' --arg v "$value"
        elif [ "$kind" = snell ]; then
          tell "  1. default"; tell "  2. unshaped"; tell "  3. unsafe-raw"
          while :; do
            case $(prompt "流量整形模式" 1) in
              1) value=default; break ;; 2) value=unshaped; break ;; 3) value=unsafe-raw; break ;;
              *) tell_warn "输入无效" ;;
            esac
          done
          node_edit_stage "$PICKED" '.meta.mode=$v|.inbound.mode=$v' --arg v "$value"
        elif [ "$kind" = anytls ]; then
          value=$(prompt "客户端元数据 (留空则为空)" "$(jq -r '.meta.client_metadata//""' "$NODE_EDIT_FILE")")
          if [ -n "$value" ]; then node_edit_stage "$PICKED" '.meta.client_metadata=$v' --arg v "$value"; else node_edit_stage "$PICKED" 'del(.meta.client_metadata)'; fi
        elif [ "$kind" = hysteria2 ]; then
          tell "  1. BBR conservative"; tell "  2. BBR standard"; tell "  3. BBR aggressive"; tell "  4. Brutal (需手动设置带宽)"
          while :; do
            case $(prompt "请选择拥塞控制" 2) in
              1) bbr_profile=conservative; up_mbps=0; down_mbps=0; break ;;
              2) bbr_profile=standard; up_mbps=0; down_mbps=0; break ;;
              3) bbr_profile=aggressive; up_mbps=0; down_mbps=0; break ;;
              4)
                bbr_profile=""
                while :; do
                  up_mbps=$(prompt "上行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.up_mbps//0' "$NODE_EDIT_FILE")")
                  echo "$up_mbps" | grep -Eq '^[0-9]+$' || { tell_warn "输入无效"; continue; }
                  down_mbps=$(prompt "下行带宽 (Mbps, 0为不限制)" "$(jq -r '.meta.down_mbps//0' "$NODE_EDIT_FILE")")
                  echo "$down_mbps" | grep -Eq '^[0-9]+$' || { tell_warn "输入无效"; continue; }
                  [ "$up_mbps" -gt 0 ] || [ "$down_mbps" -gt 0 ] || { tell_warn "Brutal 模式至少需要设置一个方向的带宽"; continue; }
                  break
                done
                break ;;
              *) tell_warn "输入无效" ;;
            esac
          done
          if [ -n "$bbr_profile" ]; then
            node_edit_stage "$PICKED" '.meta.up_mbps=0|.meta.down_mbps=0|.meta.bbr_profile=$b|del(.inbound.up_mbps,.inbound.down_mbps)|.inbound.bbr_profile=$b' --arg b "$bbr_profile"
          else
            node_edit_stage "$PICKED" '.meta.up_mbps=$up|.meta.down_mbps=$down|.meta.bbr_profile=""|if $up>0 then .inbound.up_mbps=$up else del(.inbound.up_mbps) end|if $down>0 then .inbound.down_mbps=$down else del(.inbound.down_mbps) end|del(.inbound.bbr_profile)' --argjson up "$up_mbps" --argjson down "$down_mbps"
          fi
        else
          tell_warn "输入无效"; continue
        fi || { tell_warn "修改失败"; wait_key; continue; } ;;
      5)
        if [ "$kind" = vless-reality ]; then
          while :; do
            value=$(prompt "新握手目标域名 (留空取消)")
            [ -n "$value" ] || break
            if probe_handshake_target "$value"; then break; fi
            prompt_yes "检测异常，强制加载" && break
          done
          [ -n "$value" ] || continue
          node_edit_stage "$PICKED" '.meta.target=$v|.inbound.tls.server_name=$v|.inbound.tls.reality.handshake.server=$v' --arg v "$value" || { tell_warn "修改失败"; wait_key; continue; }
        elif [ "$kind" = hysteria2 ]; then
          if prompt_yes "是否配置并开启协议混淆 (选择 N 则关闭混淆)"; then
            tell "  1. Salamander"; tell "  2. Gecko"
            while :; do
              case $(prompt "请选择混淆算法" 2) in 1) obfs_type=salamander; break ;; 2) obfs_type=gecko; break ;; *) tell_warn "输入无效" ;; esac
            done
            obfs_password=$(prompt "混淆密码 (留空与连接密码相同)" "$(jq -r '.meta.obfs_password//""' "$NODE_EDIT_FILE")")
            [ -n "$obfs_password" ] || obfs_password=$(jq -r '.meta.password' "$NODE_EDIT_FILE")
            if [ "$obfs_type" = gecko ]; then
              min_pkt=$(prompt "最小包大小 (字节, 512-2048)" "$(jq -r '.meta.min_packet_size//512' "$NODE_EDIT_FILE")")
              max_pkt=$(prompt "最大包大小 (字节, 512-2048)" "$(jq -r '.meta.max_packet_size//1200' "$NODE_EDIT_FILE")")
              echo "$min_pkt" | grep -Eq '^[0-9]+$' || min_pkt=512
              echo "$max_pkt" | grep -Eq '^[0-9]+$' || max_pkt=1200
              [ "$min_pkt" -ge 512 ] && [ "$min_pkt" -le 2048 ] || min_pkt=512
              [ "$max_pkt" -ge 512 ] && [ "$max_pkt" -le 2048 ] || max_pkt=1200
              [ "$max_pkt" -ge "$min_pkt" ] || max_pkt="$min_pkt"
              node_edit_stage "$PICKED" '.meta.obfs_type=$t|.meta.obfs_password=$p|.meta.min_packet_size=($mn|tonumber)|.meta.max_packet_size=($mx|tonumber)|.inbound.obfs={type:$t,password:$p,min_packet_size:($mn|tonumber),max_packet_size:($mx|tonumber)}' --arg t "$obfs_type" --arg p "$obfs_password" --arg mn "$min_pkt" --arg mx "$max_pkt"
            else
              node_edit_stage "$PICKED" '.meta.obfs_type=$t|.meta.obfs_password=$p|del(.meta.min_packet_size,.meta.max_packet_size)|.inbound.obfs={type:$t,password:$p}' --arg t "$obfs_type" --arg p "$obfs_password"
            fi
          else
            node_edit_stage "$PICKED" '.meta.obfs_type=""|.meta.obfs_password=""|del(.meta.min_packet_size,.meta.max_packet_size)|del(.inbound.obfs)'
          fi
        else
          tell_warn "输入无效"; continue
        fi || { tell_warn "修改失败"; wait_key; continue; } ;;
      6)
        if [ "$kind" = vless-reality ]; then
          value=$(prompt "新 short_id (留空自动生成 8位十六进制)" "$(jq -r '.meta.short_id//""' "$NODE_EDIT_FILE")")
          [ -n "$value" ] || value=$(openssl rand -hex 4 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c8)
          echo "$value" | grep -Eq '^[0-9a-fA-F]{1,8}$' || { tell_warn "short_id 必须为 1-8 位十六进制字符"; wait_key; continue; }
          node_edit_stage "$PICKED" '.meta.short_id=$v|.inbound.tls.reality.short_id=[$v]' --arg v "$value" || { tell_warn "修改失败"; wait_key; continue; }
        else
          tell_warn "输入无效"; continue
        fi ;;
      0) rm -f "$NODE_EDIT_FILE"; NODE_EDIT_FILE=""; NODE_OVERRIDE_TARGET=""; NODE_OVERRIDE_FILE=""; return ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
    if apply_config; then
      install -m600 "$NODE_EDIT_FILE" "$PICKED" || { tell_warn "配置保存失败"; wait_key; continue; }
      cp "$PICKED" "$NODE_EDIT_FILE" || { rm -f "$NODE_EDIT_FILE"; NODE_EDIT_FILE=""; NODE_OVERRIDE_TARGET=""; NODE_OVERRIDE_FILE=""; tell_warn "临时配置更新失败"; wait_key; return; }
      tell_ok "已生效"; echo ""; render_share_uri "$PICKED"
    else tell_warn "配置应用失败"; fi
    wait_key
  done
}





menu_server(){
  while :; do
    screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 服务端管理 <<${PLAIN}"
    tell "  1. 创建协议"; tell "  2. 删除协议"; tell "  3. 修改配置"; tell "  4. 服务端信息"
    tell "  5. 更换域名"; tell "  6. 重启服务"; tell "  7. 停止服务"; tell "  0. 返回"
    tell "${CYAN}--------------------------------${PLAIN}"
    case $(prompt "请选择") in
      1) menu_create_protocol ;; 2) menu_delete_protocol ;; 3) menu_modify_protocol ;;
      4) menu_server_info ;; 5) menu_change_domain ;;
      6)
         timeout 15 rc-service sing-box restart >/dev/null 2>&1
         if rc-service sing-box status >/dev/null 2>&1; then tell_ok "已重启"; else tell_warn "singbox 未运行"; tell_warn "重启失败"; fi
         wait_key ;;
      7)
         BUILD_SELECTED_OVERRIDE=direct
         if timeout 15 rc-service sing-box stop >/dev/null 2>&1; then
           local stop_tmp
           stop_tmp=$(mktemp) || { BUILD_SELECTED_OVERRIDE=""; tell_warn "临时文件创建失败"; wait_key; continue; }
           TMP_FILES="$TMP_FILES $stop_tmp"
           if build_config >"$stop_tmp" && jq -e . "$stop_tmp" >/dev/null 2>&1 && "$CORE" check -c "$stop_tmp" >/dev/null 2>&1 && install -m600 "$stop_tmp" "$CONFIG" && state_set exit direct; then
             rm -f "$stop_tmp"; tell_ok "已停止"
           else
             rm -f "$stop_tmp"; tell_warn "服务已停止，但配置同步失败"
           fi
         else tell_warn "停止服务失败"; fi
         BUILD_SELECTED_OVERRIDE=""
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
  if ! echo "$URI_PORT" | grep -Eq '^[0-9]+$' || [ "$URI_PORT" -lt 1 ] || [ "$URI_PORT" -gt 65535 ]; then
    return 1
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
  local name uri tag outbound probe
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 添加节点 <<${PLAIN}"; name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return; uri=$(prompt "节点链接"); [ -n "$uri" ] || return; parse_uri "$uri" || { tell_warn "节点链接格式无效"; wait_key; return; }
  if peer_target_is_local_uri "$URI_HOST" "$URI_PORT" "$URI_SCHEME"; then tell_warn "节点目标指向本机服务端地址，拒绝形成本机环路"; wait_key; return; fi
  tag=$(unique_tag "$name" out- "$PEER_DIR"); outbound=$(uri_to_outbound "$tag") || { tell_warn "无法解析"; wait_key; return; }; probe=$(mktemp); TMP_FILES="$TMP_FILES $probe"
  jq -n --argjson ob "$outbound" '{log:{level:"error"},outbounds:[$ob,{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$probe"
  if "$CORE" check -c "$probe" >/dev/null 2>&1; then
    if json_save "$PEER_DIR/$tag.json" "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" '{tag:$tag,name:$name,uri:$uri,outbound:$ob}')"; then tell_ok "挂载完成: $name"; else tell_warn "节点保存失败"; fi
  else tell_warn "校验拦截:"; "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2; fi
  rm -f "$probe"; wait_key
}

local_addresses(){
  {
    printf '%s\n' 127.0.0.1 ::1
    ip -o -4 addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}'
    ip -o -6 addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}'
  } | sort -u
}

peer_target_address_is_local(){
  local host=$1 ip localaddr
  [ -n "$host" ] || return 1
  if echo "$host" | grep -Eq '^[0-9]+(\.[0-9]+){3}$|:'; then
    while IFS= read -r localaddr; do [ "$host" = "$localaddr" ] && return 0; done <<EOF
$(local_addresses)
EOF
    return 1
  fi
  for ip in $(resolve_addresses "$host"); do
    while IFS= read -r localaddr; do [ "$ip" = "$localaddr" ] && return 0; done <<EOF
$(local_addresses)
EOF
  done
  return 1
}

peer_listener_has_target(){
  local proto=$1 host=$2 port=$3 ip
  if echo "$host" | grep -Eq '^[0-9]+(\.[0-9]+){3}$|:'; then
    socket_listener_match "$proto" "$host" "$port" && return 0
  else
    for ip in $(resolve_addresses "$host"); do
      socket_listener_match "$proto" "$ip" "$port" && return 0
    done
  fi
  return 1
}

peer_target_is_local(){
  local target=$1 host port scheme proto
  if [ -f "$target" ]; then
    host=$(jq -r '.outbound.server//""' "$target" 2>/dev/null)
    port=$(jq -r '.outbound.server_port//0' "$target" 2>/dev/null)
    scheme=$(jq -r '.outbound.type//""' "$target" 2>/dev/null)
  else
    host=$target
    port=$2
    scheme=$3
  fi
  peer_target_address_is_local "$host" || return 1
  case "$scheme" in
    hysteria2|hy2|tuic|wireguard) proto=u ;;
    shadowsocks|ss) proto=both ;;
    *) proto=t ;;
  esac
  case "$proto" in
    both) peer_listener_has_target t "$host" "$port" || peer_listener_has_target u "$host" "$port" ;;
    *) peer_listener_has_target "$proto" "$host" "$port" ;;
  esac
}

peer_target_is_local_uri(){
  local host=$1 port=$2 scheme=$3
  [ -n "$host" ] || return 1
  echo "$port" | grep -Eq '^[1-9][0-9]{0,4}$' || return 1
  [ "$port" -le 65535 ] || return 1
  peer_target_is_local "$host" "$port" "$scheme"
}

direct_ping_ms(){
  local host=$1
  [ -n "$host" ] || return 1
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    ping -c 1 -W 2 "$host" 2>/dev/null | awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}'
}






peer_stop(){
  screen_clear
  BUILD_SELECTED_OVERRIDE=direct
  if apply_config; then state_set exit direct && sync_proxy_env && tell_ok "已恢复直连" || tell_warn "状态保存失败"; else tell_warn "恢复直连失败"; fi
  BUILD_SELECTED_OVERRIDE=""
  wait_key
}




socket_listener_match(){
  local proto=$1 host=$2 port=$3 family localaddr addr
  [ -n "$host" ] && [ -n "$port" ] || return 1
  case "$proto" in
    t) family=tcp ;;
    u) family=udp ;;
    *) return 1 ;;
  esac
  if command -v ss >/dev/null 2>&1; then
    case "$family" in tcp) set -- -t ;; udp) set -- -u ;; esac
    ss -Hln "$@" 2>/dev/null | awk -v target="$host" -v port="$port" '
      {
        addr=$4; n=addr
        sub(/^.*:/, "", n)
        if (n != port) next
        sub(/:[0-9]+$/, "", addr)
        gsub(/^\[/, "", addr); gsub(/\]$/, "", addr)
        if (addr==target || addr=="0.0.0.0" || addr=="::" || addr=="*") found=1
      }
      END{exit !found}'
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    case "$proto" in
      t) localaddr=$(netstat -tln 2>/dev/null | awk 'NR>2{print $4}') ;;
      u) localaddr=$(netstat -uln 2>/dev/null | awk 'NR>2{print $4}') ;;
    esac
    while IFS= read -r addr; do
      [ -n "$addr" ] || continue
      case "$addr" in
        *":$port")
          addr=${addr%:$port}
          addr=${addr#\[}; addr=${addr%\]}
          [ "$addr" = "$host" ] || [ "$addr" = "0.0.0.0" ] || [ "$addr" = "::" ] || [ "$addr" = "*" ] && return 0
          ;;
      esac
    done <<EOF
$localaddr
EOF
  fi
  return 1
}



wg_init_server(){
  local port body value
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> WireGuard 服务端引导配置 <<${PLAIN}"
  wg_keypair || { tell_warn "密钥生成失败"; wait_key; return; }
  port=$(prompt_port u "51820") || return
  wg_default_address server
  while :; do value=$(prompt "隧道 IPv4" "$WG_IPV4"); wg_valid_address "$value" && ! printf '%s' "$value" | grep -q ':' && { WG_IPV4=$value; break; }; tell_warn "IPv4 地址无效"; done
  while :; do value=$(prompt "隧道 IPv6" "$WG_IPV6"); printf '%s' "$value" | grep -q ':' && wg_valid_address "$value" && { WG_IPV6=$value; break; }; tell_warn "IPv6 地址无效"; done
  body=$(jq -n --arg private "$WG_PRIVATE" --arg public "$WG_PUBLIC" --arg a4 "$WG_IPV4" --arg a6 "$WG_IPV6" --argjson port "$port" '{role:"server",enabled:false,private_key:$private,public_key:$public,address:[$a4,$a6],listen_port:$port,clients:[],endpoint:{type:"wireguard",tag:"wireguard",system:false,mtu:1280,address:[$a4,$a6],private_key:$private,listen_port:$port,peers:[]}}') || { tell_warn "配置生成失败"; wait_key; return; }
  if ! wg_apply_body "$body"; then tell_warn "配置应用失败"; wait_key; return; fi
  tell_ok "配置完成"
  printf '\n  %b配置完成，按回车启用服务端...%b' "${CYAN}" "${PLAIN}" >&2
  read_line >/dev/null
  body=$(jq '.enabled=true' "$WG_CONF") || { tell_warn "启用配置生成失败"; wait_key; return; }
  if wg_apply_body "$body"; then tell_ok "服务端已启用"; else tell_warn "服务端启用失败"; fi
  wait_key
}

wg_init_client(){
  local host port peer_key body
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> WireGuard 客户端 <<${PLAIN}"
  wg_keypair || { tell_warn "密钥生成失败"; wait_key; return; }
  tell "  本机公钥: $WG_PUBLIC"; echo ""
  host=$(prompt "服务端地址"); [ -n "$host" ] || { tell_warn "服务端地址不能为空"; wait_key; return; }
  port=$(prompt_port u "51820") || return
  while :; do peer_key=$(prompt "服务端公钥"); [ -n "$peer_key" ] && break; tell_warn "服务端公钥不能为空"; done
  wg_default_address client
  while :; do WG_IPV4=$(prompt "隧道内网 IPv4" "$WG_IPV4"); wg_valid_address "$WG_IPV4" && ! printf '%s' "$WG_IPV4" | grep -q ':' && break; tell_warn "IPv4 地址无效"; done
  while :; do WG_IPV6=$(prompt "隧道内网 IPv6" "$WG_IPV6"); printf '%s' "$WG_IPV6" | grep -q ':' && wg_valid_address "$WG_IPV6" && break; tell_warn "IPv6 地址无效"; done
  body=$(jq -n --arg private "$WG_PRIVATE" --arg public "$WG_PUBLIC" --arg a4 "$WG_IPV4" --arg a6 "$WG_IPV6" --arg peer4 "$WG_PEER_IPV4" --arg peer6 "$WG_PEER_IPV6" --arg host "$host" --arg peer_key "$peer_key" --argjson port "$port" '{role:"client",enabled:false,private_key:$private,public_key:$public,address:[$a4,$a6],listen_port:0,peer_public_key:$peer_key,peer_ip:$peer4,peer_ip6:$peer6,peer_host:$host,peer_port:$port,endpoint:{type:"wireguard",tag:"wireguard",system:false,mtu:1280,address:[$a4,$a6],private_key:$private,peers:[{address:$host,port:$port,public_key:$peer_key,allowed_ips:["0.0.0.0/0","::/0"]}]}}') || { tell_warn "配置生成失败"; wait_key; return; }
  if wg_apply_body "$body"; then tell_ok "配置完成"; else tell_warn "配置应用失败"; fi
  wait_key
}

wg_init(){
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 初始化配置 <<${PLAIN}"; tell "  1. 服务端"; tell "  2. 客户端"; tell "  0. 返回"
  case $(prompt "请选择") in 1) wg_init_server ;; 2) wg_init_client ;; 0) return ;; *) tell_warn "输入无效"; sleep 1 ;; esac
}





wg_client_add(){
  local name ipv4 ipv6 pub body allowed4 allowed6 ip4 ip6
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> 添加客户端 <<${PLAIN}"
  name=$(prompt "客户端名称")
  [ -n "$name" ] || { tell_warn "客户端名称不能为空"; wait_key; return; }
  wg_next_client_address || { tell_warn "没有可用的客户端隧道地址"; wait_key; return; }
  while :; do
    ipv4=$(prompt "隧道 IPv4" "$WG_NEXT_IPV4")
    { wg_valid_address "$ipv4" && ! printf "%s" "$ipv4" | grep -q ":"; } || { tell_warn "IPv4 地址无效"; continue; }
    ip4=${ipv4%/*}
    if jq -e --arg ip "$ip4" 'any(.clients[]?; ((.ipv4 // "") | split("/")[0]) == $ip)' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "IPv4 地址已被其他客户端使用"
      continue
    fi
    break
  done
  while :; do
    ipv6=$(prompt "隧道 IPv6" "$WG_NEXT_IPV6")
    { wg_valid_address "$ipv6" && printf "%s" "$ipv6" | grep -q ":"; } || { tell_warn "IPv6 地址无效"; continue; }
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
  wg_apply_body "$body" || { wait_key; return; }
  tell_ok "客户端已添加"
  wait_key
}

wg_client_edit(){
  local index count name ipv4 ipv6 pub body
  count=$(jq '.endpoint.peers | length' "$WG_CONF" 2>/dev/null); count=${count:-0}
  [ "$count" -gt 0 ] || { tell_warn "暂无客户端"; wait_key; return; }
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> 修改客户端 <<${PLAIN}"
  jq -r '.clients | to_entries[] | "  \(.key+1). \(.value.name) | \(.value.ipv4) | \(.value.ipv6)"' "$WG_CONF" 2>/dev/null
  tell "  0. 返回"
  index=$(prompt "请选择")
  [ "$index" = 0 ] && return
  echo "$index" | grep -Eq '^[0-9]+$' && [ "$index" -ge 1 ] && [ "$index" -le "$count" ] || { tell_warn "序号无效"; wait_key; return; }
  index=$((index-1))
  name=$(prompt "客户端名称" "$(jq -r ".clients[$index].name // \"\"" "$WG_CONF")")
  ipv4=$(prompt "隧道 IPv4" "$(jq -r ".clients[$index].ipv4 // \"\"" "$WG_CONF")")
  { wg_valid_address "$ipv4" && ! printf "%s" "$ipv4" | grep -q ":"; } || { tell_warn "IPv4 地址无效"; wait_key; return; }
  if ! wg_client_address_conflict "$index" "$ipv4" "$(jq -r ".clients[$index].ipv6 // \"\"" "$WG_CONF")"; then
    tell_warn "IPv4 地址已被其他客户端使用"
    wait_key
    return
  fi
  ipv6=$(prompt "隧道 IPv6" "$(jq -r ".clients[$index].ipv6 // \"\"" "$WG_CONF")")
  { wg_valid_address "$ipv6" && printf "%s" "$ipv6" | grep -q ":"; } || { tell_warn "IPv6 地址无效"; wait_key; return; }
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
  wg_apply_body "$body" || { wait_key; return; }
  tell_ok "客户端已修改"
  wait_key
}








wg_toggle(){
  local role previous previous_name
  screen_clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  role=$(jq -r '.role' "$WG_CONF"); previous=$(state_get exit); previous_name=$(exit_label)
  if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then
    body=$(jq '.enabled=false' "$WG_CONF") || { tell_warn "配置生成失败"; wait_key; return; }
    if [ "$previous" = wireguard ]; then BUILD_SELECTED_OVERRIDE=direct; fi
    if wg_apply_body "$body"; then [ "$previous" = wireguard ] && state_set exit direct && sync_proxy_env; tell_ok "已停止"; else tell_warn "配置应用失败"; fi
    BUILD_SELECTED_OVERRIDE=""
  else
    if [ "$role" = client ] && [ -z "$(jq -r '.peer_public_key // ""' "$WG_CONF")" ]; then
      tell_warn "缺少服务端公钥"; wait_key; return
    fi
    if [ "$role" = client ] && [ "$previous" != direct ]; then
      prompt_yes "当前 ${previous_name} 正在接管网络。\n启动 WireGuard 后，网络出口将切换至 WireGuard。\n是否切换" || return
    fi
    body=$(jq '.enabled=true' "$WG_CONF") || { tell_warn "配置生成失败"; wait_key; return; }
    if [ "$role" = client ]; then BUILD_SELECTED_OVERRIDE=wireguard; else BUILD_SELECTED_OVERRIDE="$previous"; fi
    if wg_apply_body "$body"; then [ "$role" = client ] && state_set exit wireguard && sync_proxy_env; tell_ok "已启动"; else tell_warn "配置应用失败"; fi
    BUILD_SELECTED_OVERRIDE=""
  fi
  wait_key
}




run_uninstall(){
  local packages
  screen_clear
  tell_alert "警告: 卸载将清空所有配置"
  [ "$(prompt '输入 yes 确认')" = yes ] || return
  packages=$(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null | tr '\n' ' ')
  rc-service sing-box stop >/dev/null 2>&1 || true
  stop_net_monitor
  rc-update del sing-box default >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" /etc/profile.d/sbm_proxy.sh
  rm -rf "$SB_DIR" "$SBM_DIR" /var/lib/sing-box "$CORE" "$SHORTCUT"
  if [ -n "$packages" ]; then
    tell "脚本曾安装过: [ $packages ]"
    if prompt_yes "是否移除依赖组件"; then
      apk del $packages >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$SELF"
  tell_ok "清理完成"
  exit 0
}



stop_net_monitor(){
  if [ -f "$NET_MONITOR_PID" ]; then
    local pid; pid=$(cat "$NET_MONITOR_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
    rm -f "$NET_MONITOR_PID"
  fi
}

start_net_monitor(){
  stop_net_monitor
  (
    trap 'exit 0' TERM INT
    while :; do
      ip monitor link route address 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          *" lo "*|*"lo:"*|*"docker"*|*"veth"*|*"br-"*|*"virbr"*|*"tailscale"*|*"zt"*) continue ;;
        esac
        sleep 2
        "$SELF" --reapply >/dev/null 2>&1 &
        break
      done
      sleep 5
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $! > "$NET_MONITOR_PID"
}

reapply_config(){
  exec 9>"$REAPPLY_LOCK"
  flock -w 5 9 || exit 0
  _new_conf=$(mktemp) || { flock -u 9; exit 1; }
  if ! build_config >"$_new_conf" 2>/dev/null || [ ! -s "$_new_conf" ] || ! jq -e . "$_new_conf" >/dev/null 2>&1 || ! "$CORE" check -c "$_new_conf" >/dev/null 2>&1; then
    rm -f "$_new_conf"; flock -u 9; exit 1
  fi
  if cmp -s "$_new_conf" "$CONFIG"; then
    rm -f "$_new_conf"; flock -u 9; exit 0
  fi
  install -m600 "$_new_conf" "$CONFIG" || { rm -f "$_new_conf"; flock -u 9; exit 1; }
  rm -f "$_new_conf"
  rc-service sing-box restart >/dev/null 2>&1 || { flock -u 9; exit 1; }
  rc-service sing-box status >/dev/null 2>&1 || { flock -u 9; exit 1; }
  flock -u 9
  exit 0
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
  write_service || { tell_warn "OpenRC 服务文件创建失败"; exit 1; }
  [ -x "$SERVICE_FILE" ] || { tell_warn "OpenRC 服务文件不可执行"; exit 1; }
  rc-update add sing-box default >/dev/null 2>&1 || { tell_warn "无法加入 OpenRC 默认启动项"; exit 1; }
  if [ ! -f "$CONFIG" ]; then
    local init_tmp
    init_tmp=$(mktemp) || { tell_warn "初始配置临时文件创建失败"; exit 1; }
    TMP_FILES="$TMP_FILES $init_tmp"
    if build_config >"$init_tmp" && jq -e . "$init_tmp" >/dev/null 2>&1 && "$CORE" check -c "$init_tmp" >/dev/null 2>&1 && install -m600 "$init_tmp" "$CONFIG"; then
      rm -f "$init_tmp"
    else
      rm -f "$init_tmp"; tell_warn "初始 sing-box 配置生成或校验失败"; exit 1
    fi
  fi
  rc-service sing-box status >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1 || { tell_warn "sing-box 启动失败"; exit 1; }
  rc-service sing-box status >/dev/null 2>&1 || { tell_warn "sing-box 未正常运行"; exit 1; }
  sync_proxy_env
  start_net_monitor

}

. "$SBM_COMMON"

case $1 in
  --sync) init_dirs; sync_proxy_env; exit 0 ;;
  --reapply) init_dirs; reapply_config ;;
esac

bootstrap

while :; do
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> s管理 <<${PLAIN}"
  tell ""
  tell "  当前环境：${BRIGHT_GREEN}${BOLD}${PLATFORM}${PLAIN}"
  tell "${BRIGHT_CYAN}--------------------------------${PLAIN}"
  tell "  1. 服务端管理"
  tell "  2. 客户端管理"
  tell "  3. WireGuard 管理"
  tell "  4. 状态与更新"
  tell "  0. 退出"
  tell "${CYAN}--------------------------------${PLAIN}"
  case $(prompt "请选择") in
    1) menu_server ;;
    2) menu_client ;;
    3) menu_wireguard ;;
    4) menu_status ;;
    0) screen_clear; exit 0 ;;
    *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
  esac
done

__SBM_OPENRC__
    chmod 700 "$PAYLOAD" "$COMMON"
    export SBM_COMMON="$COMMON"
    /bin/sh "$PAYLOAD" "$@"
    rc=$?
    exit "$rc"
    ;;
  systemd)
    cat >"$PAYLOAD" <<'__SBM_SYSTEMD__'
wg_edit_address_apply(){
  wg_save "$1" || return 1
  if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then apply_config || return 1; fi
}
wg_client_apply_body(){ wg_server_client_apply "$1"; }
wg_server_edit_apply(){ wg_server_client_apply "$1"; }
wg_client_edit_apply(){ wg_server_client_apply "$1"; }

wg_delete_platform_cleanup(){ wg_server_nat_remove 2>/dev/null || true; }

peer_latency(){ probe_peer_latency "$1" "$2" "$3"; }

#!/usr/bin/env bash
export LC_ALL=C
shopt -s nullglob

RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
PURPLE='\033[35m'
BROWN='\033[1;33m'
PLAIN='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
BRIGHT_CYAN='\033[1;36m'
BRIGHT_GREEN='\033[1;32m'
BRIGHT_YELLOW='\033[1;33m'
BRIGHT_MAGENTA='\033[1;35m'

if [ -z "${TERM:-}" ] || [ "${TERM:-}" = dumb ]; then
  RED=''; GREEN=''; CYAN=''; YELLOW=''; BROWN=''; PURPLE=''; BLUE=''; BOLD=''; DIM=''; BRIGHT_CYAN=''; BRIGHT_GREEN=''; BRIGHT_YELLOW=''; BRIGHT_MAGENTA=''; PLAIN=''
fi

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
SELF=${SBM_LAUNCHER_SELF:-$(readlink -f "$0" 2>/dev/null || echo "$PWD/${0#./}")}
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
HOP_TABLE=sbm_hop

NET_IPV4=""
NET_IPV6=""
NET_IF_V4=""
NET_IF_V6=""
NET_STACK=""
IPV6_OK=0

TMP_FILES=""
ACME_PENDING_DOMAIN=""
ACME_PENDING_EMAIL=""
ACME_PENDING_MODE=""
ACME_PENDING_CF_TOKEN=""
ACME_PENDING_ALI_KEY=""
ACME_PENDING_ALI_SECRET=""
ACME_PENDING_ACMEDNS_URL=""
ACME_PENDING_ACMEDNS_USER=""
ACME_PENDING_ACMEDNS_PASS=""
ACME_PENDING_ACMEDNS_SUB=""

stop_net_monitor(){
  if [ -f "$NET_MONITOR_PID" ]; then
    local pid; pid=$(cat "$NET_MONITOR_PID" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      pkill -KILL -P "$pid" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null
      { wait "$pid"; } 2>/dev/null
    fi
    while read -r rpid; do
      [ -n "$rpid" ] || continue
      kill -KILL "$rpid" 2>/dev/null
    done < <(pgrep -f -- "^/bin/bash $SELF --reapply$" 2>/dev/null)
    while read -r rpid; do
      [ -n "$rpid" ] || continue
      kill -KILL "$rpid" 2>/dev/null
    done < <(pgrep -f -- "^bash $SELF --reapply$" 2>/dev/null)
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




acme_options(){
  local domain=$1 body email mode cf_token ali_key ali_secret acmedns_user acmedns_pass acmedns_sub acmedns_url
  if [ -n "$ACME_PENDING_DOMAIN" ] && [ "$domain" = "$ACME_PENDING_DOMAIN" ]; then
    email=$ACME_PENDING_EMAIL; mode=$ACME_PENDING_MODE; cf_token=$ACME_PENDING_CF_TOKEN; ali_key=$ACME_PENDING_ALI_KEY; ali_secret=$ACME_PENDING_ALI_SECRET
    acmedns_user=$ACME_PENDING_ACMEDNS_USER; acmedns_pass=$ACME_PENDING_ACMEDNS_PASS; acmedns_sub=$ACME_PENDING_ACMEDNS_SUB; acmedns_url=$ACME_PENDING_ACMEDNS_URL
  else
    email=$(state_get email); mode=$(state_get challenge); cf_token=$(state_get cf_token); ali_key=$(state_get ali_key); ali_secret=$(state_get ali_secret)
    acmedns_user=$(state_get acmedns_user); acmedns_pass=$(state_get acmedns_pass); acmedns_sub=$(state_get acmedns_sub); acmedns_url=$(state_get acmedns_url)
  fi
  body=$(jq -n --arg d "$domain" --arg e "$email" --arg dir "$ACME_DIR" '{domain:[$d],email:$e,data_directory:$dir,key_type:"p256"}') || return 1
  case "$mode" in
    alpn) body=$(echo "$body" | jq '.disable_http_challenge=true') || return 1 ;;
    dns_cloudflare) body=$(echo "$body" | jq --arg t "$cf_token" '.dns01_challenge={provider:"cloudflare",api_token:$t}') || return 1 ;;
    dns_alidns) body=$(echo "$body" | jq --arg k "$ali_key" --arg s "$ali_secret" '.dns01_challenge={provider:"alidns",access_key_id:$k,access_key_secret:$s}') || return 1 ;;
    dns_acmedns) body=$(echo "$body" | jq --arg u "$acmedns_user" --arg p "$acmedns_pass" --arg s "$acmedns_sub" --arg r "$acmedns_url" '.dns01_challenge={provider:"acmedns",username:$u,password:$p,subdomain:$s,server_url:$r}') || return 1 ;;
    *) body=$(echo "$body" | jq '.disable_tls_alpn_challenge=true') || return 1 ;;
  esac
  printf '%s' "$body"
}

default_iface(){
  local family=$1 target iface
  if [ "$family" = 4 ]; then target=1.1.1.1; else target=2606:4700:4700::1111; fi
  iface=$(ip -"$family" route get "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  case "$iface" in "$TUN_IF"|"$WG_IF") iface="" ;; esac
  [ -n "$iface" ] || iface=$(ip -"$family" route show table main default 2>/dev/null | awk -v t="$TUN_IF" -v w="$WG_IF" '$5!=t && $5!=w {print $5; exit}')
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
    out=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY curl -4 -fsS --connect-timeout 2 -m 4 --interface "$NET_IF_V4" --resolve cloudflare-dns.com:443:1.1.1.1 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$encoded&type=A" 2>/dev/null)
    jq -r '.Answer[]?.data // empty' <<<"$out" 2>/dev/null
  fi
  if [ -n "$NET_IF_V6" ]; then
    out=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY curl -6 -fsS --connect-timeout 2 -m 4 --interface "$NET_IF_V6" --resolve 'cloudflare-dns.com:443:[2606:4700:4700::1111]' -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$encoded&type=AAAA" 2>/dev/null)
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
  local tmp4="" tmp6="" ip4="" ip6=""
  if [ -n "$local_v4" ]; then
    tmp4=$(mktemp); TMP_FILES="$TMP_FILES $tmp4"
    (local_ipv4 "$NET_IF_V4" > "$tmp4") &
  fi
  if [ -n "$local_v6" ]; then
    tmp6=$(mktemp); TMP_FILES="$TMP_FILES $tmp6"
    (local_ipv6 "$NET_IF_V6" > "$tmp6") &
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
  if [ -n "$ip6" ] && ipv6_egress_available; then
    IPV6_OK=1
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
RestartSec=1
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
ExecStopPost=-$SHORTCUT --screen_clear-hopping
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


protected_ports(){ { ssh_ports; node_ports; wg_listen_port; } | grep -E '^[1-9][0-9]*$' | sort -un; }
hopping_node(){
  local file
  for file in "$NODE_DIR"/*.json; do
    [ -n "$(jq -r '.hopping//""' "$file")" ] && { printf '%s' "$file"; return 0; }
  done
  return 1
}

clear_legacy_bypass_rules(){
  local state="$SBM_DIR/bypass_rules" family selector value
  [ -f "$state" ] || return 0
  while read -r family selector value; do
    case "$family:$selector:$value" in
      4:sport:*) ip -4 rule del pref 90 sport "$value" lookup main 2>/dev/null || true ;;
      6:sport:*) ip -6 rule del pref 90 sport "$value" lookup main 2>/dev/null || true ;;
      4:fwmark:fwmark) ip -4 rule del pref 90 fwmark 255 lookup main 2>/dev/null || true ;;
      6:fwmark:fwmark) ip -6 rule del pref 90 fwmark 255 lookup main 2>/dev/null || true ;;
    esac
  done < "$state"
  rm -f "$state"
}

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
  out4=$(default_iface 4); out6=$(default_iface 6)
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


build_config(){
  local selected domain inbounds outbounds endpoints rules dns_block final use_tun
  local peer_host node_files tls_extra providers
  local dns_direct_tag dns_strategy auto_detect

  selected=${BUILD_SELECTED_OVERRIDE:-$(state_get exit)}; domain=${BUILD_DOMAIN_OVERRIDE:-$(state_get domain)}
  final=direct; use_tun=0; endpoints='[]'; peer_host=""; providers='[]'; tls_extra='{}'

  dns_direct_tag="dns-direct-v4"
  dns_strategy="prefer_ipv4"
  if ipv6_egress_available; then
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
        final="wireguard"
        if transparent_proxy_available; then use_tun=1; else use_tun=0; fi
      fi
    else
      endpoints=$(jq --arg resolver "$dns_direct_tag" '[.endpoint | .domain_resolver = $resolver]' "$WG_CONF")
    fi
  fi

  if [ "$selected" != direct ] && [ "$selected" != wireguard ]; then
    if [ -f "$PEER_DIR/$selected.json" ]; then
      outbounds=$(jq -n --argjson base "$outbounds" --slurpfile peer "$PEER_DIR/$selected.json" \
        --arg resolver "$dns_direct_tag" '$base + [$peer[0].outbound + {domain_resolver:$resolver}]')
      final=$selected
      if transparent_proxy_available; then use_tun=1; else use_tun=0; fi
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
        mtu:1500}] + $list')
  fi

  ssh_rule_ports=$(ssh_ports | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')
  rules=$(jq -n --arg host "$peer_host" --argjson ssh_ports "$ssh_rule_ports" '
    (if ($ssh_ports|length)>0 then [{network:"tcp",port:$ssh_ports,action:"bypass"}] else [] end)
    + [{network:"icmp",action:"bypass"},
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
    (if $direct_tag == "dns-direct-v6" then "2606:4700:4700::1111" else "1.1.1.1" end) as $remote_server |
    {servers:[
      {type:"https",tag:"dns-direct-v4",server:"1.1.1.1",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}},
      {type:"https",tag:"dns-direct-v6",server:"2606:4700:4700::1111",server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}},
      {type:"https",tag:"dns-remote",server:$remote_server,server_port:443,path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}}
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

restore_config(){
  local backup=$1
  if [ -n "$backup" ] && [ -s "$backup" ]; then
    install -m600 "$backup" "$CONFIG"
    timeout 15 systemctl restart sing-box >/dev/null 2>&1
  else
    rm -f "$CONFIG"
    timeout 15 systemctl stop sing-box >/dev/null 2>&1
  fi
}

apply_config(){
  local tmp error line guard=0 prev_conf="" action=${1:-reload-or-restart}
  case "$action" in reload-or-restart|restart) ;; *) return 2 ;; esac
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
  if ! timeout 15 systemctl "$action" sing-box >/dev/null 2>&1; then
    tell_warn "sing-box 重载/重启失败，正在回滚配置"
    restore_config "$prev_conf"
    sync_hopping_rules
    return 1
  fi
  while ! systemctl is-active --quiet sing-box; do
    sleep 0.2; guard=$((guard+1)); [ "$guard" -gt 15 ] && break
  done
  if ! systemctl is-active --quiet sing-box; then
    tell_warn "服务启动异常:"
    while IFS= read -r line; do tell "    $line"; done <<<"$(journalctl -u sing-box -n 5 --no-pager 2>/dev/null)"
    restore_config "$prev_conf"
    sync_hopping_rules
    return 1
  fi
  if jq -e '.inbounds[]? | select(.tag=="tun-in")' "$CONFIG" >/dev/null 2>&1; then
    if ! transparent_proxy_available || ! ip link show "$TUN_IF" >/dev/null 2>&1; then
      tell_warn "TUN 全局接管未建立，正在回滚配置"
      restore_config "$prev_conf"
      sync_hopping_rules
      return 1
    fi
  fi
  sync_hopping_rules
  return 0
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












create_hysteria2(){
  local name port password hopping tag body up_mbps down_mbps obfs_type obfs_password bbr_profile
  local min_pkt max_pkt cc_choice
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 创建协议 <<${PLAIN}"
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
      obfs_str=""; [ -n "$obfs_type" ] && obfs_str="&obfs=$(uri_encode "$obfs_type")&obfs-password=$(uri_encode "$obfs_pw")"
      bbr_str=""; [ -n "$bbr" ] && bbr_str="&bbr_profile=$(uri_encode "$bbr")"
      pkt_str=""
      if [ "$obfs_type" = gecko ]; then
        [ -n "$min_pkt" ] && pkt_str="${pkt_str}&min_packet_size=${min_pkt}"
        [ -n "$max_pkt" ] && pkt_str="${pkt_str}&max_packet_size=${max_pkt}"
      fi
      if [ -n "$hopping" ]; then
        uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$hopping?sni=$(uri_encode "$host")${bbr_str}${obfs_str}${pkt_str}#$(uri_encode "$name")"
      else
        uri="hysteria2://$(uri_encode "$(jq -r .password <<<"$meta")")@$host:$port?sni=$(uri_encode "$host")${bbr_str}${obfs_str}${pkt_str}#$(uri_encode "$name")"
      fi ;;
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




menu_delete_protocol(){
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 删除协议 <<${PLAIN}"
  select_node || return
  prompt_yes "确认删除 $(jq -r .name "$PICKED")" || return
  local was_acme old_json previous_exit
  was_acme=$(jq -r .tls_mode "$PICKED"); old_json=$(cat "$PICKED"); previous_exit=$(state_get exit)
  if [ "$(jq -r .tag "$PICKED")" = "$previous_exit" ]; then state_set exit direct && sync_proxy_env; fi
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
    json_save "$PICKED" "$old_json"; state_set exit "$previous_exit" && sync_proxy_env; apply_config_quiet; tell_warn "删除导致配置异常，已安全回滚"
  fi
  wait_key
}

menu_modify_protocol(){
  local kind value other current_hop up_mbps down_mbps obfs_type obfs_password old_json bbr_profile min_pkt max_pkt
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 修改配置 <<${PLAIN}"
  select_node || return
  while :; do
    kind=$(jq -r .kind "$PICKED")
    screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> $(jq -r .name "$PICKED") [$kind] <<${PLAIN}"
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
    tell "  0. 返回"; tell "${CYAN}------------------------------${PLAIN}"
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
              while :; do
                min_pkt=$(prompt "最小包大小 (字节, 512-2048)" "$(jq -r '.meta.min_packet_size//512' "$PICKED")")
                [[ $min_pkt =~ ^[0-9]+$ ]] && [ "$min_pkt" -ge 512 ] && [ "$min_pkt" -le 2048 ] && break
                tell_warn "最小包大小必须为 512-2048"
              done
              while :; do
                max_pkt=$(prompt "最大包大小 (字节, 512-2048)" "$(jq -r '.meta.max_packet_size//1200' "$PICKED")")
                [[ $max_pkt =~ ^[0-9]+$ ]] && [ "$max_pkt" -ge 512 ] && [ "$max_pkt" -le 2048 ] && [ "$max_pkt" -ge "$min_pkt" ] && break
                tell_warn "最大包大小必须为 512-2048 且不小于最小包大小"
              done
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







menu_server(){
  local previous
  while :; do
    screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 服务端管理 <<${PLAIN}"
    tell "  1. 创建协议"; tell "  2. 删除协议"; tell "  3. 修改配置"; tell "  4. 服务端信息"
    tell "  5. 更换域名"; tell "  6. 重启服务"; tell "  7. 停止服务"; tell "  0. 返回"
    tell "${CYAN}--------------------------------${PLAIN}"
    case $(prompt "请选择") in
      1) menu_create_protocol ;; 2) menu_delete_protocol ;; 3) menu_modify_protocol ;;
      4) menu_server_info ;; 5) menu_change_domain ;;
      6)
         timeout 15 systemctl restart sing-box >/dev/null 2>&1
         if systemctl is-active --quiet sing-box; then sync_hopping_rules; tell_ok "已重启"
         else tell_warn "singbox 未运行"; tell_warn "重启失败"; fi
         wait_key ;;
      7)
         previous=$(state_get exit); state_set exit direct && sync_proxy_env
         if timeout 15 systemctl stop sing-box 2>/dev/null; then
           if build_config | json_write "$CONFIG"; then tell_ok "已停止"; else tell_warn "服务已停止，但配置同步失败"; fi
         else state_set exit "$previous" && sync_proxy_env; tell_warn "操作异常，已回滚"; fi
         wait_key ;;
      0) break ;;
      *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
    esac
  done
}

parse_uri(){
  local raw=$1 rest tail authority port_spec token low high
  URI_SCHEME=${raw%%://*}; rest=${raw#*://}
  case $rest in *\#*) rest=${rest%%\#*} ;; esac
  URI_QUERY=""; case $rest in *\?*) URI_QUERY=${rest#*\?}; rest=${rest%%\?*} ;; esac
  rest=${rest%%/*}
  URI_USERINFO=""; case $rest in *@*) URI_USERINFO=$(uri_decode "${rest%@*}"); rest=${rest##*@} ;; esac
  URI_PORT=443
  URI_PORTS=""
  if [[ "$rest" == \[*\]* ]]; then
    URI_HOST=${rest%%\]*}; URI_HOST=${URI_HOST#\[}
    tail=${rest##*\]}
    [ -n "$tail" ] && { [[ "$tail" == :* ]] || return 1; port_spec=${tail#:}; }
  else
    case "$rest" in
      *:*) URI_HOST=${rest%%:*}; port_spec=${rest#*:} ;;
      *) URI_HOST=$rest; port_spec="" ;;
    esac
  fi
  if [ "$URI_SCHEME" = hysteria2 ] || [ "$URI_SCHEME" = hy2 ]; then
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
        URI_PORTS="$port_spec"
      else
        URI_PORT="$port_spec"
      fi
    fi
  else
    URI_PORT=${port_spec:-443}
    if ! [[ "$URI_PORT" =~ ^[0-9]+$ ]] || [ "$URI_PORT" -lt 1 ] || [ "$URI_PORT" -gt 65535 ]; then URI_PORT=443; fi
  fi
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
      [ -z "$flow" ] || [ "$flow" = "xtls-rprx-vision" ] || return 1
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
      if [ -n "$URI_PORTS" ]; then
        local server_ports=() token
        IFS=',' read -ra port_tokens <<<"$URI_PORTS"
        for token in "${port_tokens[@]}"; do server_ports+=("${token//-/:}"); done
        outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --arg password "$URI_USERINFO" --arg sni "$sni" --args \
          '{type:"hysteria2",tag:$tag,server:$server,password:$password,server_ports:$ARGS.positional,tls:{enabled:true,server_name:$sni,alpn:["h3"]}}' -- "${server_ports[@]}")
      else
        outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                         --arg password "$URI_USERINFO" --arg sni "$sni" \
          '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,
            tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      fi
      obfs_pw=$(query_value obfs-password); obfs_type=$(query_value obfs)
      if [ -n "$obfs_pw" ]; then
        [ -z "$obfs_type" ] && obfs_type="salamander"
      fi
      if [ -n "$obfs_type" ]; then
        [ "$obfs_type" = salamander ] || [ "$obfs_type" = gecko ] || return 1
        [ -n "$obfs_pw" ] || return 1
        outbound=$(jq --arg type "$obfs_type" --arg pw "$obfs_pw" '.obfs={type:$type,password:$pw}' <<<"$outbound")
      fi
      bbr_profile=$(query_value bbr_profile); [ -n "$bbr_profile" ] || bbr_profile=standard
      case "$bbr_profile" in conservative|standard|aggressive) ;; *) return 1 ;; esac
      outbound=$(jq --arg bbr "$bbr_profile" '.bbr_profile=$bbr' <<<"$outbound")
      disable_parrot=$(query_value disable_chrome_parrot)
      if [ "$disable_parrot" = "1" ] || [ "$disable_parrot" = "true" ]; then outbound=$(jq '.disable_chrome_parrot=true' <<<"$outbound"); fi
      hop_range=$(query_value mport); [ -z "$hop_range" ] && hop_range=$(query_value ports)
      if [ -z "$URI_PORTS" ] && [ -n "$hop_range" ]; then
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
      elif [ -n "$URI_PORTS" ]; then
        outbound=$(jq '.hop_interval="30s"' <<<"$outbound")
      fi
      min_pkt=$(query_value min_packet_size); max_pkt=$(query_value max_packet_size)
      if [ -n "$min_pkt" ] || [ -n "$max_pkt" ]; then
        [ "$obfs_type" = gecko ] || return 1
        min_pkt=${min_pkt:-512}; max_pkt=${max_pkt:-1200}
        [[ "$min_pkt" =~ ^[0-9]+$ ]] && [[ "$max_pkt" =~ ^[0-9]+$ ]] || return 1
        [ "$min_pkt" -ge 512 ] && [ "$max_pkt" -le 2048 ] && [ "$max_pkt" -ge "$min_pkt" ] || return 1
        outbound=$(jq --arg mn "$min_pkt" --arg mx "$max_pkt" \
          '.obfs.min_packet_size=($mn|tonumber) | .obfs.max_packet_size=($mx|tonumber)' <<<"$outbound")
      fi ;;
    tuic)
      username=${URI_USERINFO%%:*}; password=${URI_USERINFO#*:}
      [ "$password" = "$URI_USERINFO" ] && password=""
      congestion=$(query_value congestion_control); [ -n "$congestion" ] || congestion=bbr
      case "$congestion" in cubic|new_reno|bbr) ;; *) return 1 ;; esac
      alpn=$(query_value alpn); [ -n "$alpn" ] || alpn=h3
      udp_mode=$(query_value udp_relay_mode); [ -n "$udp_mode" ] || udp_mode=native
      case "$udp_mode" in native|quic) ;; *) return 1 ;; esac
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
      case "$s_mode" in default|unshaped|unsafe-raw) ;; *) return 1 ;; esac
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" \
                       --arg psk "$URI_USERINFO" --arg mode "$s_mode" \
        '{type:"snell",tag:$tag,server:$server,server_port:$port,version:6,psk:$psk,mode:$mode}') ;;
    *) return 1 ;;
  esac
  if [ "$insecure" = 1 ] || [ "$insecure" = true ]; then outbound=$(jq 'if .tls then .tls.insecure=true else . end' <<<"$outbound"); fi
  printf '%s' "$outbound"
}

peer_add(){
  local name uri tag outbound probe port ip resolved_hosts local_ipv4 local_ipv6
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 添加节点 <<${PLAIN}"
  name=$(prompt "识别名称" "RemoteNode"); [ -n "$name" ] || return
  uri=$(prompt "节点链接"); [ -n "$uri" ] || return
  parse_uri "$uri" || { tell_warn "节点链接格式无效"; wait_key; return; }
  resolved_hosts=$(resolve_addresses "$URI_HOST")
  local_ipv4=$(ip -4 -o addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')
  local_ipv6=$(ip -6 -o addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')
  for port in $(node_ports); do
    if [ "$URI_PORT" = "$port" ]; then
      if [ "$URI_HOST" = "127.0.0.1" ] || [ "$URI_HOST" = "localhost" ] || [ "$URI_HOST" = "::1" ]; then tell_warn "禁止自环接入"; wait_key; return; fi
      for ip in $resolved_hosts; do
        if grep -Fqx "$ip" <<<"$local_ipv4" || grep -Fqx "$ip" <<<"$local_ipv6"; then tell_warn "禁止自环接入"; wait_key; return; fi
      done
    fi
  done
  tag=$(unique_tag "$name" out- "$PEER_DIR")
  outbound=$(uri_to_outbound "$tag") || { tell_warn "无法解析"; wait_key; return; }
  probe=$(mktemp); TMP_FILES="$TMP_FILES $probe"
  jq -n --argjson ob "$outbound" '{log:{level:"error"},outbounds:[$ob,{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$probe"
  if "$CORE" check -c "$probe" >/dev/null 2>&1; then
    json_save "$PEER_DIR/$tag.json" "$(jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" --arg hosts "$resolved_hosts" '{tag:$tag,name:$name,uri:$uri,outbound:$ob,probe_addresses:($hosts|split("\n")|map(select(length>0)))}')"
    tell_ok "挂载完成: $name"
  else
    tell_warn "校验拦截:"; "$CORE" check -c "$probe" 2>&1 | sed 's/^/    /' | head -3 >&2
  fi
  rm -f "$probe"; wait_key
}

probe_peer_latency(){
  local file=$1 result=$2 latency_file=${3:-} server iface family out ms families deadline left targets target probe_family
  command -v ping >/dev/null 2>&1 || { echo fail >"$result"; return 1; }
  server=$(jq -r '.outbound.server//""' "$file" 2>/dev/null) || { echo fail >"$result"; return; }
  [ -n "$server" ] || { echo fail >"$result"; return; }
  if [[ "$server" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || [[ "$server" =~ ^[0-9A-Fa-f:]+$ ]]; then
    targets=$server
  else
    targets=$(resolve_addresses "$server")
  fi
  [ -n "$targets" ] || { echo fail >"$result"; return 1; }
  local targets4="" targets6="" ordered_targets
  while IFS= read -r target; do
    if [[ "$target" =~ ^[0-9A-Fa-f:]+$ ]]; then
      targets6+="$target"$'\n'
    elif [[ "$target" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      targets4+="$target"$'\n'
    fi
  done <<<"$targets"
  if [ -n "$NET_IF_V6" ] && [ "$IPV6_OK" = 1 ]; then
    ordered_targets="${targets6}${targets4}"
  else
    ordered_targets="${targets4}${targets6}"
  fi
  deadline=$((SECONDS+3))
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if [[ "$target" =~ ^[0-9A-Fa-f:]+$ ]]; then
      families="6"
    elif [[ "$target" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      families="4"
    elif [ "$NET_STACK" = v6 ]; then
      families="6 4"
    elif [ "$NET_IF_V6" ] && [ "$IPV6_OK" = 1 ]; then
      families="6 4"
    else
      families="4 6"
    fi
    for family in $families; do
      left=$((deadline-SECONDS)); [ "$left" -gt 0 ] || break 2
      if [ "$family" = 6 ]; then
        [ -n "$NET_IF_V6" ] || continue
        iface=$NET_IF_V6
        probe_family=6
      else
        [ -n "$NET_IF_V4" ] || continue
        iface=$NET_IF_V4
        probe_family=4
      fi
      out=$(timeout "${left}s" ping -"$probe_family" -I "$iface" -c 1 -W "$left" "$target" 2>/dev/null)
      if [ $? -eq 0 ]; then
        ms=$(awk -F'time=' '/time=/{gsub(/ ms.*/,"",$2); printf "%.0f\n",$2; exit}' <<<"$out")
        if [[ "$ms" =~ ^[0-9]+$ ]]; then
          echo ok >"$result"
          [ -n "$latency_file" ] && printf '%s\n' "$ms" >"$latency_file"
          return 0
        fi
      fi
    done
  done <<< "$ordered_targets"
  echo fail >"$result"
  return 1
}



wg_client_active(){
  [ -f "$WG_CONF" ] && [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] && [ "$(jq -r .role "$WG_CONF")" = client ]
}




peer_stop(){
  screen_clear; local previous; previous=$(state_get exit)
  state_set exit direct && sync_proxy_env
  if apply_config; then tell_ok "已恢复直连"
  else state_set exit "$previous" && sync_proxy_env; apply_config_quiet; tell_warn "恢复直连失败，已回滚"; fi
  wait_key
}





menu_client_status(){
  screen_clear; tell "${BRIGHT_CYAN}${BOLD}>> 客户端状态 <<${PLAIN}"
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









wg_reinit_prepare(){
  local role enabled previous
  [ -f "$WG_CONF" ] || return 0
  role=$(jq -r '.role // ""' "$WG_CONF" 2>/dev/null)
  enabled=$(jq -r '.enabled // false' "$WG_CONF" 2>/dev/null)
  previous=$(state_get exit)
  ip link del "$WG_IF" 2>/dev/null || true
  [ ! -d "/sys/class/net/$WG_IF" ] || return 1
  if [ "$role" = server ] && [ "$enabled" = true ]; then
    wg_server_nat_remove
  fi
  if [ "$previous" = wireguard ]; then
    state_set exit direct && sync_proxy_env
  fi
  return 0
}

wg_reinit_rollback(){
  local backup=$1 previous=$2 role
  rm -rf "$WG_DIR"
  mkdir -p "$WG_DIR"
  if [ -n "$(find "$backup" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    cp -a "$backup"/. "$WG_DIR"/
  fi
  chmod 700 "$WG_DIR"
  role=$(jq -r '.role // ""' "$WG_CONF" 2>/dev/null)
  state_set exit "$previous" && sync_proxy_env
  if [ "$role" = server ] && [ "$(jq -r '.enabled // false' "$WG_CONF" 2>/dev/null)" = true ]; then
    wg_server_nat_apply
  fi
  apply_config_quiet
}


wg_init_server(){
  local port body backup_wg previous_exit value
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> WireGuard 服务端引导配置 <<${PLAIN}"
  wg_keypair || { tell_warn "密钥生成失败"; wait_key; return; }
  port=$(prompt_port u "51820") || return
  wg_default_address server
  while :; do
    value=$(prompt "隧道 IPv4" "$WG_IPV4")
    { wg_valid_address "$value" && [[ "$value" != *:*/* ]]; } || { tell_warn "IPv4 地址无效"; continue; }
    WG_IPV4="$value"
    break
  done
  while :; do
    value=$(prompt "隧道 IPv6" "$WG_IPV6")
    { wg_valid_address "$value" && [[ "$value" == *:*/* ]]; } || { tell_warn "IPv6 地址无效"; continue; }
    WG_IPV6="$value"
    break
  done
  body=$(jq -n \
    --arg private "$WG_PRIVATE" --arg public "$WG_PUBLIC" \
    --arg a4 "$WG_IPV4" --arg a6 "$WG_IPV6" \
    --arg iface "$WG_IF" --argjson port "$port" \
    '{role:"server",enabled:false,private_key:$private,public_key:$public,
      address:[$a4,$a6],listen_port:$port,clients:[],
      endpoint:{type:"wireguard",tag:"wireguard",system:true,name:$iface,mtu:1280,
        address:[$a4,$a6],private_key:$private,listen_port:$port,peers:[]}}') || { tell_warn "配置生成失败"; wait_key; return; }
  backup_wg=$(mktemp -d) || { tell_warn "临时目录创建失败"; wait_key; return; }
  if [ -f "$WG_CONF" ]; then
    cp -a "$WG_DIR"/. "$backup_wg"/ 2>/dev/null || { rm -rf "$backup_wg"; tell_warn "旧配置备份失败"; wait_key; return; }
  fi
  previous_exit=$(state_get exit)
  if ! wg_reinit_prepare; then
    rm -rf "$backup_wg"
    tell_warn "旧 WireGuard 接口清理失败"
    wait_key
    return
  fi
  if ! wg_save "$body"; then
    wg_reinit_rollback "$backup_wg" "$previous_exit"
    rm -rf "$backup_wg"
    tell_warn "保存失败，已恢复旧配置"
    wait_key
    return
  fi
  printf "\n  ${CYAN}配置完成（回车启动服务端）${PLAIN}\n" >&2
  read_line >/dev/null
  body=$(jq '.enabled=true' "$WG_CONF") || {
    tell_warn "启动配置生成失败"
    wait_key
    return
  }
  if ! wg_save "$body"; then
    if [ -n "$(find "$backup_wg" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
      rm -rf "$WG_DIR"; mkdir -p "$WG_DIR"; cp -a "$backup_wg"/. "$WG_DIR"/; chmod 700 "$WG_DIR"
    else
      json_edit "$WG_CONF" '.enabled=false'
    fi
    rm -rf "$backup_wg"
    tell_warn "启动配置保存失败，已恢复旧配置"
    wait_key
    return
  fi
  wg_server_nat_apply
  if ! apply_config restart; then
    wg_server_nat_remove
    if [ -n "$(find "$backup_wg" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
      rm -rf "$WG_DIR"; mkdir -p "$WG_DIR"; cp -a "$backup_wg"/. "$WG_DIR"/; chmod 700 "$WG_DIR"
      state_set exit "$previous_exit" && sync_proxy_env
      if [ "$(jq -r '.role // ""' "$WG_CONF" 2>/dev/null)" = server ] && [ "$(jq -r '.enabled // false' "$WG_CONF" 2>/dev/null)" = true ]; then wg_server_nat_apply; fi
      apply_config_quiet
    else
      json_edit "$WG_CONF" '.enabled=false'
      apply_config_quiet
      state_set exit "$previous_exit" && sync_proxy_env
    fi
    rm -rf "$backup_wg"
    tell_warn "服务端启动失败，已恢复旧配置"
    wait_key
    return
  fi
  rm -rf "$backup_wg"
  tell_ok "配置完成"
  wait_key
}

wg_init_client(){
  local host port peer_key body
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> WireGuard 客户端 <<${PLAIN}"
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
  while :; do
    WG_IPV4=$(prompt "隧道内网 IPv4" "$WG_IPV4")
    { wg_valid_address "$WG_IPV4" && [[ "$WG_IPV4" != *:*/* ]]; } && break
    tell_warn "IPv4 地址无效"
  done
  while :; do
    WG_IPV6=$(prompt "隧道内网 IPv6" "$WG_IPV6")
    { wg_valid_address "$WG_IPV6" && [[ "$WG_IPV6" == *:*/* ]]; } && break
    tell_warn "IPv6 地址无效"
  done
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
  local backup_wg previous_exit
  backup_wg=$(mktemp -d) || { tell_warn "临时目录创建失败"; wait_key; return; }
  if [ -f "$WG_CONF" ]; then
    cp -a "$WG_DIR"/. "$backup_wg"/ 2>/dev/null || { rm -rf "$backup_wg"; tell_warn "旧配置备份失败"; wait_key; return; }
  fi
  previous_exit=$(state_get exit)
  if ! wg_reinit_prepare; then
    rm -rf "$backup_wg"
    tell_warn "旧 WireGuard 接口清理失败"
    wait_key
    return
  fi
  if ! wg_save "$body"; then
    wg_reinit_rollback "$backup_wg" "$previous_exit"
    rm -rf "$backup_wg"
    tell_warn "保存失败，已恢复旧配置"
    wait_key
    return
  fi
  if ! apply_config; then
    rm -rf "$WG_DIR"
    mkdir -p "$WG_DIR"
    if [ -n "$(find "$backup_wg" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then cp -a "$backup_wg"/. "$WG_DIR"/; fi
    chmod 700 "$WG_DIR"
    state_set exit "$previous_exit" && sync_proxy_env
    if [ "$(jq -r '.role // ""' "$WG_CONF" 2>/dev/null)" = server ] && [ "$(jq -r '.enabled // false' "$WG_CONF" 2>/dev/null)" = true ]; then wg_server_nat_apply; fi
    apply_config_quiet
    rm -rf "$backup_wg"
    tell_warn "配置校验失败，已恢复旧配置"
    wait_key
    return
  fi
  rm -rf "$backup_wg"
  tell_ok "配置完成"
  wait_key
}

wg_init(){
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> 初始化配置 <<${PLAIN}"
  tell "  1. 服务端"
  tell "  2. 客户端"
  tell "  0. 返回"
  case $(prompt "请选择") in
    1) wg_init_server ;;
    2) wg_init_client ;;
    0) return ;;
    *) tell_warn "输入无效"; sleep 1 ;;
  esac
}


wg_server_client_apply(){
  local body=$1 old_body
  old_body=$(cat "$WG_CONF")
  if ! wg_save "$body"; then
    tell_warn "保存失败"
    return 1
  fi
  if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ] && ! apply_config restart; then
    printf '%s\n' "$old_body" | json_write "$WG_CONF"
    apply_config_quiet
    tell_warn "应用失败，已恢复旧配置"
    return 1
  fi
  return 0
}



wg_client_add(){
  local name ipv4 ipv6 pub body allowed4 allowed6 ip4 ip6
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> 添加客户端 <<${PLAIN}"
  name=$(prompt "客户端名称")
  [ -n "$name" ] || { tell_warn "客户端名称不能为空"; wait_key; return; }
  wg_next_client_address || { tell_warn "没有可用的客户端隧道地址"; wait_key; return; }
  while :; do
    ipv4=$(prompt "隧道 IPv4" "$WG_NEXT_IPV4")
    { wg_valid_address "$ipv4" && [[ "$ipv4" != *:*/* ]]; } || { tell_warn "IPv4 地址无效"; continue; }
    ip4=${ipv4%/*}
    if jq -e --arg ip "$ip4" 'any(.clients[]?; ((.ipv4 // "") | split("/")[0]) == $ip)' "$WG_CONF" >/dev/null 2>&1; then
      tell_warn "IPv4 地址已被其他客户端使用"
      continue
    fi
    break
  done
  while :; do
    ipv6=$(prompt "隧道 IPv6" "$WG_NEXT_IPV6")
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
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> 修改客户端 <<${PLAIN}"
  jq -r '.clients | to_entries[] | "  \(.key+1). \(.value.name) | \(.value.ipv4) | \(.value.ipv6)"' "$WG_CONF" 2>/dev/null
  tell "  0. 返回"
  index=$(prompt "请选择")
  [ "$index" = 0 ] && return
  [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$count" ] || { tell_warn "序号无效"; wait_key; return; }
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
  tell_ok "客户端已修改"
  wait_key
}









wg_toggle(){
  local role previous previous_name
  screen_clear
  [ -f "$WG_CONF" ] || { tell_warn "请先初始化配置"; wait_key; return; }
  role=$(jq -r '.role' "$WG_CONF"); previous=$(state_get exit); previous_name=$(exit_label)
  modprobe wireguard 2>/dev/null || true
  if [ "$(jq -r '.enabled//false' "$WG_CONF")" = true ]; then
    json_edit "$WG_CONF" '.enabled=false' || { tell_warn "保存失败"; wait_key; return; }
    if [ "$role" = server ]; then wg_server_nat_remove; fi
    if [ "$previous" = wireguard ]; then state_set exit direct && sync_proxy_env; fi
    if apply_config; then tell_ok "已停止"; else tell_warn "配置应用失败"; fi
  else
    if [ "$role" = client ] && [ -z "$(jq -r '.peer_public_key // ""' "$WG_CONF")" ]; then
      tell_warn "缺少服务端公钥"
      wait_key
      return
    fi
    if [ "$role" = client ] && [ "$previous" != direct ]; then
      prompt_yes "当前 ${previous_name} 正在接管网络。
启动 WireGuard 后，网络出口将切换至 WireGuard。
是否切换" || return
    fi
    json_edit "$WG_CONF" '.enabled=true' || { tell_warn "保存失败"; wait_key; return; }
    if [ "$role" = server ]; then wg_server_nat_apply; fi
    if [ "$role" = client ]; then state_set exit wireguard && sync_proxy_env; fi
    if apply_config; then
      sleep 2
      tell_ok "已启动"
    else
      json_edit "$WG_CONF" '.enabled=false'
      state_set exit "$previous" && sync_proxy_env
      if [ "$role" = server ]; then wg_server_nat_remove; fi
      apply_config_quiet
      tell_warn "启动失败，已回滚"
    fi
  fi
  wait_key
}




run_uninstall(){
  local packages
  screen_clear
  tell_warn "警告: 卸载将清空所有配置"
  [ "$(prompt '输入 yes 确认')" = yes ] || return
  mapfile -t packages < <(grep -v '^[[:space:]]*$' "$PKG_LOG" 2>/dev/null)
  systemctl disable --now sing-box 2>/dev/null
  stop_net_monitor
  rm -f "$SERVICE_UNIT" "$DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null
  systemctl daemon-reload
  clear_hopping_rules
  wg_server_nat_remove
  clear_legacy_bypass_rules
  ip link del "$WG_IF" 2>/dev/null
  ip link del "$TUN_IF" 2>/dev/null
  rm -rf "$SB_DIR" "$SBM_DIR" /var/lib/sing-box "$CORE" "$SHORTCUT"
  if [ ${#packages[@]} -gt 0 ]; then
    tell "脚本曾安装过: [ ${packages[*]} ]"
    if prompt_yes "是否移除依赖组件"; then
      apt-get remove -y -q "${packages[@]}" >/dev/null 2>&1
      apt-get autoremove -y -q >/dev/null 2>&1
    fi
  fi
  rm -f "$SELF"
  tell_ok "清理完成"
  exit 0
}


. "$SBM_COMMON"

bootstrap(){
  init_dirs
  clear_legacy_bypass_rules
  check_dependencies
  chmod 700 "$SELF" 2>/dev/null
  ln -sf "$SELF" "$SHORTCUT" 2>/dev/null
  load_net_cache
  probe_network_stack_async
  if [ ! -x "$CORE" ]; then
    tell "${CYAN}首次运行，安装 sing-box...${PLAIN}"
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
  sync_hopping_rules
  start_net_monitor
}


case $1 in
  --sync) init_dirs; clear_legacy_bypass_rules; sync_hopping_rules; exit 0 ;;
  --screen_clear-hopping) clear_hopping_rules; exit 0 ;;
  --reapply)
    exec 9>"$REAPPLY_LOCK"
    flock -w 5 9 || exit 0
    init_dirs
    load_net_cache
    prev_if4="$NET_IF_V4"; prev_if6="$NET_IF_V6"
    NET_IF_V4=$(default_iface 4)
    NET_IF_V6=$(default_iface 6)
    if [ "$NET_IF_V4" != "$prev_if4" ] || [ "$NET_IF_V6" != "$prev_if6" ]; then
      probe_network_stack
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
      restore_config "$_prev_conf"
      rm -f "$_prev_conf"; flock -u 9; exit 1
    fi
    if ! systemctl is-active --quiet sing-box; then
      restore_config "$_prev_conf"
      rm -f "$_prev_conf"; flock -u 9; exit 1
    fi
    rm -f "$_prev_conf"
    sync_hopping_rules
    flock -u 9
    exit 0 ;;
esac

bootstrap

while :; do
  screen_clear
  tell "${BRIGHT_CYAN}${BOLD}>> s管理 <<${PLAIN}"
  tell ""
  tell "  当前环境：${BRIGHT_GREEN}${BOLD}${PLATFORM}${PLAIN}"
  tell "${BRIGHT_CYAN}--------------------------------${PLAIN}"
  tell "  1. 服务端管理"
  tell "  2. 客户端管理"
  tell "  3. WireGuard 管理"
  tell "  4. 状态与更新"
  tell "  0. 退出"
  tell "${CYAN}--------------------------------${PLAIN}"
  case $(prompt "请选择") in
    1) menu_server ;;
    2) menu_client ;;
    3) menu_wireguard ;;
    4) menu_status ;;
    0) screen_clear; exit 0 ;;
    *) tell_warn "输入无效，请重新选择"; sleep 1 ;;
  esac
done

__SBM_SYSTEMD__
    chmod 700 "$PAYLOAD" "$COMMON"
    export SBM_COMMON="$COMMON"
    /bin/bash "$PAYLOAD" "$@"
    rc=$?
    exit "$rc"
    ;;
esac
