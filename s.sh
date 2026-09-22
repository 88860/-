#!/usr/bin/env bash
set -u
# KVM/LXC standalone build: generated from modular sources.
KVM_STANDALONE=1; export KVM_STANDALONE
KVM_BASE_DIR=${KVM_BASE_DIR:-/etc/kvm-new}; export KVM_BASE_DIR
KVM_ENTRYPOINT=${KVM_ENTRYPOINT:-$0}; export KVM_ENTRYPOINT

# ===== MODULE: lib/entrypoint.sh =====
entrypoint_install(){
  local uid src target cmd_target
  uid=$(id -u 2>/dev/null || printf 1)
  [ "$uid" = 0 ] || { printf '必须使用 root 运行。\n' >&2; return 1; }
  src=${KVM_ENTRYPOINT:-$0}
  target=${KVM_SCRIPT_PATH:-/root/s.sh}
  cmd_target=${KVM_COMMAND_PATH:-/usr/local/bin/s}
  if [ -f "$src" ]; then
    if [ "$(CDPATH= cd -- "$(dirname -- "$src")" 2>/dev/null && pwd)/$(basename -- "$src")" != "$target" ]; then
      cp -f -- "$src" "$target" || return 1
    fi
  fi
  [ -f "$target" ] || { printf '无法定位主脚本，无法安装 s 命令。\n' >&2; return 1; }
  chmod 755 "$target" || return 1
  mkdir -p "$(dirname -- "$cmd_target")" || return 1
  ln -sfn "$target" "$cmd_target" || return 1
  hash -r 2>/dev/null || true
  return 0
}

# ===== MODULE: lib/environment.sh =====

# Environment/capability detection.  Detection is intentionally read-only:
# package installation belongs to package/core preparation.
environment_memory_mb(){
  [ -n "${KVM_MEMORY_LIMIT_MB:-}" ] && { printf "%s" "$KVM_MEMORY_LIMIT_MB"; return 0; }
  local v max=0
  if [ -r /sys/fs/cgroup/memory.max ]; then
    v=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] && [ "$v" -lt 9223372036854771712 ]; then
      max=$((v/1024/1024))
    fi
  fi
  if [ "$max" = 0 ] && [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    v=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] && [ "$v" -lt 9223372036854771712 ]; then
      max=$((v/1024/1024))
    fi
  fi
  if [ "$max" = 0 ] && [ -r /proc/meminfo ]; then
    max=$(awk '/^MemTotal:/{printf "%d", $2/1024; exit}' /proc/meminfo)
  fi
  [ "$max" -gt 0 ] || max=128
  printf '%s' "$max"
}

environment_low_memory(){ [ "$(environment_memory_mb)" -le 128 ]; }

environment_gomemlimit_mb(){
  local total limit
  total=$(environment_memory_mb)
  # Keep Go's heap below the cgroup ceiling.  64 MiB LXC gets 32 MiB;
  # 128 MiB gets 48 MiB, matching the low-memory strategy used by
  # singbox-lite.  Larger hosts scale conservatively.
  if [ "$total" -le 64 ]; then
    limit=32
  elif [ "$total" -le 128 ]; then
    limit=48
  elif [ "$total" -le 256 ]; then
    limit=$((total*50/100))
  elif [ "$total" -le 512 ]; then
    limit=$((total*65/100))
  else
    limit=$((total*80/100))
  fi
  [ "$limit" -lt 24 ] && limit=24
  printf '%s' "$limit"
}

environment_detect(){
  ENV_OS=unknown; ENV_OS_VERSION=unknown; ENV_ARCH=$(uname -m 2>/dev/null || printf unknown); ENV_VIRT=unknown; ENV_INIT=none
  CAP_TUN=0; CAP_TUN_OPEN=0; CAP_JQ=0; CAP_OPENSSL=0; CAP_NET_ADMIN=0; CAP_NFT=0; CAP_IPTABLES=0; CAP_IP=0; CAP_IP_RULE=0; CAP_IP_ROUTE=0; CAP_SS=0; CAP_CURL=0; CAP_WGET=0; CAP_PING=0
  [ -r /etc/os-release ] && { . /etc/os-release; ENV_OS=${ID:-unknown}; ENV_OS_VERSION=${VERSION_ID:-unknown}; }
  if command -v systemd-detect-virt >/dev/null 2>&1; then ENV_VIRT=$(systemd-detect-virt 2>/dev/null || printf unknown); else ENV_VIRT=unknown; fi
  if [ "$ENV_VIRT" = none ] || [ -z "$ENV_VIRT" ]; then ENV_VIRT=kvm; fi
  if [ "$ENV_VIRT" = unknown ] && grep -qaE '(^|/)(lxc|docker|kubepods)(/|$)' /proc/1/cgroup 2>/dev/null; then ENV_VIRT=lxc; fi
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then ENV_INIT=systemd; elif command -v rc-service >/dev/null 2>&1; then ENV_INIT=openrc; fi
  [ -c /dev/net/tun ] && CAP_TUN=1; [ -c /dev/net/tun ] && [ -r /dev/net/tun ] && [ -w /dev/net/tun ] && CAP_TUN_OPEN=1
  command -v nft >/dev/null 2>&1 && CAP_NFT=1; command -v jq >/dev/null 2>&1 && CAP_JQ=1; command -v openssl >/dev/null 2>&1 && CAP_OPENSSL=1; command -v iptables >/dev/null 2>&1 && CAP_IPTABLES=1; command -v ip >/dev/null 2>&1 && CAP_IP=1
  command -v ss >/dev/null 2>&1 && CAP_SS=1; command -v curl >/dev/null 2>&1 && CAP_CURL=1; command -v wget >/dev/null 2>&1 && CAP_WGET=1; command -v ping >/dev/null 2>&1 && CAP_PING=1
  command -v ip >/dev/null 2>&1 && ip rule show >/dev/null 2>&1 && CAP_IP_RULE=1; command -v ip >/dev/null 2>&1 && ip route show >/dev/null 2>&1 && CAP_IP_ROUTE=1
  if [ -r /proc/self/status ]; then
    local h bit=12 word val
    h=$(awk '/^CapEff:/{print $2;exit}' /proc/self/status)
    if [ -n "$h" ]; then val=$((16#$h)); (( (val >> bit) & 1 )) && CAP_NET_ADMIN=1; fi
  fi
  [ -f /proc/net/if_inet6 ] && ENV_IPV6=1 || ENV_IPV6=0; [ -r /proc/net/route ] && ENV_IPV4=1 || ENV_IPV4=0
  ENV_MEMORY_MB=$(environment_memory_mb); ENV_GOMEMLIMIT_MB=$(environment_gomemlimit_mb)
}

# ===== MODULE: lib/network.sh =====
network_default_v4_if(){ ip -4 route show default 2>/dev/null | awk 'NR==1{print $5;exit}'; }
network_default_v6_if(){ ip -6 route show default 2>/dev/null | awk 'NR==1{print $5;exit}'; }
network_ipv4_usable(){ command -v ip >/dev/null 2>&1 && [ -n "$(network_default_v4_if)" ]; }
network_ipv6_usable(){ command -v ip >/dev/null 2>&1 && [ -n "$(network_default_v6_if)" ]; }
network_source_v4(){ ip -4 route get "${1:-1.1.1.1}" 2>/dev/null|awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'; }
network_source_v6(){ ip -6 route get "${1:-2606:4700:4700::1111}" 2>/dev/null|awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'; }
network_summary(){
  local v4 v6 s4 s6
  v4=$(network_ipv4_usable&&printf usable||printf unavailable)
  v6=$(network_ipv6_usable&&printf usable||printf unavailable)
  s4=$(network_source_v4 2>/dev/null || true)
  s6=$(network_source_v6 2>/dev/null || true)
  printf 'IPv4: %s' "$v4"
  [ -n "$s4" ] && printf ' (%s)' "$(ui_ip "$s4")"
  printf '\nIPv6: %s' "$v6"
  [ -n "$s6" ] && printf ' (%s)' "$(ui_ip "$s6")"
  printf '\n'
}

# ===== MODULE: lib/package.sh =====

package_has(){ case "$1" in ca-certificates) [ -f /etc/ssl/certs/ca-certificates.crt ];; *) command -v "$1" >/dev/null 2>&1;; esac; }
package_manager(){ command -v apk >/dev/null 2>&1 && { printf '%s' apk; return; }; command -v apt-get >/dev/null 2>&1 && { printf '%s' apt; return; }; command -v dnf >/dev/null 2>&1 && { printf '%s' dnf; return; }; command -v yum >/dev/null 2>&1 && { printf '%s' yum; return; }; printf '%s' none; }
package_install(){
  local pm; pm=$(package_manager)
  case "$pm" in
    apk) apk add --no-cache "$@";;
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@";;
    dnf) dnf install -y --setopt=install_weak_deps=False "$@";;
    yum) yum install -y "$@";;
    *) return 1;;
  esac
}
package_update_index(){
  case "$(package_manager)" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq;;
    *) return 0;;
  esac
}
package_ensure_commands(){
  local missing=() c
  for c in "$@"; do package_has "$c" || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  local pm; pm=$(package_manager)
  [ "$pm" != none ] || return 1
  local pkgs=()
  for c in "${missing[@]}"; do
    case "$c" in
      bash) pkgs+=(bash);; jq) pkgs+=(jq);; openssl) pkgs+=(openssl);; curl) pkgs+=(curl);; wget) pkgs+=(wget);; tar) pkgs+=(tar);; ca-certificates) pkgs+=(ca-certificates);; ip) pkgs+=(iproute2);; ss) pkgs+=(iproute2);; ping) pkgs+=(iputils-ping);; nft) pkgs+=(nftables);; *) pkgs+=("$c");;
    esac
  done
  if [ "$pm" = apt ]; then package_update_index || return 1; fi
  package_install "${pkgs[@]}"
}
package_prepare(){
  # Minimal dependency set for the management plane. nftables/TUN helpers are optional.
  package_ensure_commands bash jq openssl tar ca-certificates ip ss || return 1
  if ! package_has curl && ! package_has wget; then package_ensure_commands curl || return 1; fi
  return 0
}

# ===== MODULE: lib/state.sh =====
state_root=${KVM_STATE_ROOT:-/var/lib/kvm-new}; state_file=${KVM_STATE_FILE:-$state_root/state.env}; STATE=$state_file
state_init(){ mkdir -p "$state_root" || return 1; [ -f "$state_file" ] || : >"$state_file"; chmod 600 "$state_file"; }
state_get(){ local key=$1; [ -f "$state_file" ]||return 1; awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$state_file"; }
state_set(){ local key=$1 value=$2 tmp; state_init||return 1; tmp=$(mktemp "$state_root/.state.XXXXXX")||return 1; awk -F= -v k="$key" '$1!=k' "$state_file">"$tmp"; printf '%s=%s\n' "$key" "$value">>"$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$state_file"; }
state_unset(){ state_set "$1" '' >/dev/null; }
state_snapshot(){ state_init&&cp -p "$state_file" "$1"; }
state_restore(){ [ -f "$1" ]&&state_init&&cp -p "$1" "$state_file"; }

sync_proxy_env(){
  EXIT_TAG=$(state_get exit 2>/dev/null || printf direct)
  export EXIT_TAG
  return 0
}

# ===== MODULE: lib/config.sh =====
config_root=${KVM_CONFIG_ROOT:-/etc/sing-box}; config_file=${KVM_CONFIG_FILE:-$config_root/config.json}; config_backup_dir=${KVM_CONFIG_BACKUP_DIR:-$config_root/backups}
config_init(){ mkdir -p "$config_root" "$config_backup_dir"; }
config_tmp(){ config_init >/dev/null 2>&1 || return 1; mktemp "$config_root/.config.XXXXXX"; }
config_backup(){ [ -f "$config_file" ]||return 0; config_init||return 1; cp -p "$config_file" "$config_backup_dir/config.$(date +%Y%m%d%H%M%S).json"; }
config_validate(){ local f=${1:-$config_file}; core_check "$f"; }
config_install(){ local src=$1; [ -f "$src" ]||return 1; config_init||return 1; config_validate "$src"||return 1; [ -f "$config_file" ]&&config_backup||true; chmod 600 "$src"; mv -f "$src" "$config_file"; chmod 600 "$config_file"; }
config_dns_json(){ dns_json; }

# ===== MODULE: lib/config-builder.sh =====
CONFIG_DIR=${KVM_CONFIG_ROOT:-${CONFIG_DIR:-/etc/sing-box}}
CONFIG_FILE=${KVM_CONFIG_FILE:-${CONFIG_FILE:-$CONFIG_DIR/config.json}}
CONFIG_TMP=${CONFIG_TMP:-$CONFIG_DIR/config.json.tmp}
config_builder_prepare(){ mkdir -p "$CONFIG_DIR"; }
config_builder_write(){ config_builder_prepare || return 1; cat > "$CONFIG_TMP"; }
config_builder_commit(){ [ -f "$CONFIG_TMP" ] || return 1; mv -f "$CONFIG_TMP" "$CONFIG_FILE"; }
config_builder_check(){ core_check "$1"; }

# ===== MODULE: lib/dns.sh =====
DNS_CF_IPV4=${DNS_CF_IPV4:-1.1.1.1}; DNS_CF_IPV6=${DNS_CF_IPV6:-2606:4700:4700::1111}; DNS_CF_DOMAIN=${DNS_CF_DOMAIN:-one.one.one.one}
DNS_CONTROL_TAG=${DNS_CONTROL_TAG:-dns-control}; DNS_DATA_TAG=${DNS_DATA_TAG:-dns-data}
dns_detect_mode(){ if network_ipv4_usable&&network_ipv6_usable;then printf dual;elif network_ipv4_usable;then printf ipv4;elif network_ipv6_usable;then printf ipv6;else printf none;fi; }
dns_strategy(){ case $(dns_detect_mode) in dual|ipv6)printf prefer_ipv6;;ipv4)printf prefer_ipv4;;*)printf prefer_ipv4;;esac; }
dns_json(){
  local exit_tag=${1:-${EXIT_TAG:-direct}}; local mode=$(dns_detect_mode); local server='1.1.1.1'; [ "$mode" = ipv6 ]&&server="$DNS_CF_IPV6"; [ "$exit_tag" = warp-system ]&&exit_tag=direct
  cat <<JSON
{"servers":[{"type":"local","tag":"$DNS_CONTROL_TAG"},{"type":"https","tag":"$DNS_DATA_TAG","server":"$server","server_port":443,"path":"/dns-query","tls":{"enabled":true,"server_name":"cloudflare-dns.com"},"detour":"$exit_tag"}],"final":"$DNS_DATA_TAG","strategy":"$(dns_strategy)"}
JSON
}
dns_summary(){ printf 'DNS: control=direct data=tunnel exit=%s strategy=%s\n' "${EXIT_TAG:-direct}" "$(dns_strategy)"; }

# ===== MODULE: lib/runtime.sh =====
RUNTIME_PID_DIR=${RUNTIME_PID_DIR:-/run/kvm-new}
RUNTIME_UNIT_DIR=${RUNTIME_UNIT_DIR:-/etc/systemd/system}

runtime_mem_env(){ printf '%s' "${ENV_GOMEMLIMIT_MB:-$(environment_gomemlimit_mb 2>/dev/null || printf 48)}MiB"; }
runtime_pid_file(){ printf '%s/%s.pid' "$RUNTIME_PID_DIR" "$1"; }
runtime_log_file(){ printf '%s/%s.log' "$RUNTIME_PID_DIR" "$1"; }
runtime_binary(){ printf '%s' "${SING_BOX_BIN:-sing-box}"; }
runtime_config(){ printf '%s' "${SING_BOX_CONFIG:-/etc/sing-box/config.json}"; }
runtime_pid_alive(){ local pid=$1; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
runtime_systemd_unit(){
  local n=$1 unit="$RUNTIME_UNIT_DIR/$n.service" bin cfg mem
  [ "${ENV_INIT:-none}" = systemd ] || return 1
  bin=$(runtime_binary); cfg=$(runtime_config); mem=$(runtime_mem_env)
  command -v "$bin" >/dev/null 2>&1 || [ -x "$bin" ] || return 1
  if [ -f "$unit" ]; then
    local dropin="$RUNTIME_UNIT_DIR/$n.service.d/10-s-gomemlimit.conf"
    mkdir -p "$(dirname -- "$dropin")" || return 1
    cat >"$dropin" <<EOF2
[Service]
Environment=GOMEMLIMIT=$mem
EOF2
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    return 0
  fi
  mkdir -p "$RUNTIME_UNIT_DIR" || return 1
  cat >"$unit" <<EOF2
[Unit]
Description=$n
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=GOMEMLIMIT=$mem
ExecStart=$bin run -c $cfg
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload >/dev/null 2>&1 || return 1
}
runtime_service_exists(){
  local n=$1
  case ${ENV_INIT:-none} in
    systemd) systemctl cat "$n.service" >/dev/null 2>&1 || [ -f "$RUNTIME_UNIT_DIR/$n.service" ] ;;
    openrc) [ -x "/etc/init.d/$n" ] || [ "$n" = sing-box ];;
    *) core_has 2>/dev/null || command -v "$(runtime_binary)" >/dev/null 2>&1;;
  esac
}
runtime_start(){
  local n=$1 pidf pid bin cfg log mem
  bin=$(runtime_binary); cfg=$(runtime_config); log=$(runtime_log_file "$n"); mem=$(runtime_mem_env)
  [ -x "$bin" ] || command -v "$bin" >/dev/null 2>&1 || return 1
  [ -f "$cfg" ] || return 1
  case ${ENV_INIT:-none} in
    systemd)
      runtime_systemd_unit "$n" || return 1
      systemctl reset-failed "$n.service" >/dev/null 2>&1 || true
      systemctl enable "$n.service" >/dev/null 2>&1 || true
      systemctl start "$n.service" || return 1
      ;;
    openrc)
      if [ -x "/etc/init.d/$n" ]; then rc-service "$n" start; else runtime_start_pid "$n"; fi ;;
    *) runtime_start_pid "$n" ;;
  esac
}
runtime_start_pid(){
  local n=$1 pidf pid bin cfg log mem
  bin=$(runtime_binary); cfg=$(runtime_config); log=$(runtime_log_file "$n"); mem=$(runtime_mem_env); pidf=$(runtime_pid_file "$n")
  mkdir -p "$RUNTIME_PID_DIR" || return 1
  if [ -s "$pidf" ]; then pid=$(cat "$pidf" 2>/dev/null); if runtime_pid_alive "$pid"; then return 0; fi; fi
  rm -f "$pidf"
  nohup env GOMEMLIMIT="$mem" "$bin" run -c "$cfg" >>"$log" 2>&1 & pid=$!
  printf '%s\n' "$pid" >"$pidf"
  sleep 1
  if ! runtime_pid_alive "$pid"; then rm -f "$pidf"; return 1; fi
}
runtime_stop(){
  local n=$1
  case ${ENV_INIT:-none} in
    systemd) systemctl stop "$n.service" 2>/dev/null;;
    openrc) if [ -x "/etc/init.d/$n" ]; then rc-service "$n" stop; else runtime_stop_pid "$n"; fi;;
    *) runtime_stop_pid "$n";;
  esac
}
runtime_stop_pid(){
  local n=$1 pidf pid; pidf=$(runtime_pid_file "$n"); [ -s "$pidf" ] || return 0; pid=$(cat "$pidf" 2>/dev/null); kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do runtime_pid_alive "$pid" || break; sleep 1; done
  runtime_pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true; rm -f "$pidf"
}
runtime_restart(){ local n=$1; runtime_stop "$n"; runtime_start "$n"; }
runtime_reload(){ local n=$1; case ${ENV_INIT:-none} in systemd) systemctl reload "$n.service" 2>/dev/null || systemctl restart "$n.service";;openrc) [ -x "/etc/init.d/$n" ] && rc-service "$n" reload || runtime_restart "$n";;*) runtime_restart "$n";;esac; }
runtime_is_active(){ local n=$1 pidf pid; case ${ENV_INIT:-none} in systemd) systemctl is-active --quiet "$n.service";;openrc) [ -x "/etc/init.d/$n" ] && rc-service "$n" status >/dev/null 2>&1 || { pidf=$(runtime_pid_file "$n"); [ -s "$pidf" ] && pid=$(cat "$pidf") && runtime_pid_alive "$pid"; };;*) pidf=$(runtime_pid_file "$n"); [ -s "$pidf" ] || return 1; pid=$(cat "$pidf"); runtime_pid_alive "$pid";;esac; }

# ===== MODULE: lib/transport.sh =====
transport_json='null'
transport_prompt(){
  transport_json='null'; TRANSPORT_MODE=tcp
  local mode path host service
  mode=$(ui_prompt '传输层: 0 TCP 1 WebSocket 2 gRPC 3 HTTPUpgrade' 0)
  case "$mode" in
    1) TRANSPORT_MODE=ws; path=$(ui_prompt 'WS Path' /ws); host=$(ui_prompt 'WS Host' '');
       transport_json=$(jq -n --arg p "$path" --arg h "$host" '{type:"ws",path:$p,headers:(if $h=="" then {} else {Host:$h} end)}');;
    2) TRANSPORT_MODE=grpc; service=$(ui_prompt 'gRPC Service Name' TunService);
       transport_json=$(jq -n --arg s "$service" '{type:"grpc",service_name:$s}');;
    3) TRANSPORT_MODE=httpupgrade; path=$(ui_prompt 'HTTPUpgrade Path' /upgrade); host=$(ui_prompt 'HTTPUpgrade Host' '');
       transport_json=$(jq -n --arg p "$path" --arg h "$host" '{type:"httpupgrade",path:$p,host:$h}');;
    *) ;;
  esac
}
transport_apply(){ local obj=$1; if [ "$transport_json" != null ]; then jq -c --argjson t "$transport_json" '.transport=$t' <<<"$obj"; else printf '%s' "$obj"; fi; }

# ===== MODULE: lib/core.sh =====
SING_BOX_BIN=${SING_BOX_BIN:-$(command -v sing-box 2>/dev/null || printf /usr/local/bin/sing-box)}
SING_BOX_CONFIG=${SING_BOX_CONFIG:-${KVM_CONFIG_FILE:-/etc/sing-box/config.json}}
SING_BOX_SERVICE=${SING_BOX_SERVICE:-sing-box}
CORE_RELEASE_API=${CORE_RELEASE_API:-https://api.github.com/repos/SagerNet/sing-box/releases/latest}
CORE_INSTALL_DIR=${CORE_INSTALL_DIR:-/usr/local/bin}

core_has(){ [ -x "$SING_BOX_BIN" ] || command -v "$SING_BOX_BIN" >/dev/null 2>&1; }
core_version(){
  core_has || return 1
  "$SING_BOX_BIN" version 2>/dev/null | awk '/^sing-box version /{print $3; exit}'
}
core_version_tuple(){
  local v=${1:-$(core_version 2>/dev/null || true)}
  v=${v#v}; v=${v%%[-+]*}
  printf '%s\n' "$v" | awk -F. 'NF>=2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {printf "%d %d %d\n",$1,$2,($3 ~ /^[0-9]+$/?$3:0)}'
}
core_version_ge(){
  local a b av bv; a=${1#v}; b=${2#v}
  av=$(core_version_tuple "$a") || return 1; bv=$(core_version_tuple "$b") || return 1
  awk -v a="$av" -v b="$bv" 'BEGIN{split(a,x," ");split(b,y," "); exit !((x[1]>y[1])||(x[1]==y[1]&&x[2]>y[2])||(x[1]==y[1]&&x[2]==y[2]&&x[3]>=y[3]))}'
}
core_min_version(){ printf '%s' "${KVM_MIN_SING_BOX_VERSION:-1.14.1}"; }
core_check(){ core_has && [ -f "${1:-$SING_BOX_CONFIG}" ] && "$SING_BOX_BIN" check -c "${1:-$SING_BOX_CONFIG}"; }
core_asset_arch(){ case "${ENV_ARCH:-$(uname -m)}" in x86_64|amd64) printf amd64;; aarch64|arm64) printf arm64;; armv7l|armv7) printf armv7;; armv6l|armv6) printf armv6;; i386|i686) printf 386;; riscv64) printf riscv64;; *) return 1;; esac; }
core_libc_suffix(){ if [ -f /etc/alpine-release ] || (command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl); then printf -- '-musl'; fi; }
core_release_json(){ local fetch=${1:-curl}; case "$fetch" in curl) curl -fsSL --retry 2 --connect-timeout 8 --max-time 30 "$CORE_RELEASE_API";; wget) wget -qO- --tries=2 --timeout=8 "$CORE_RELEASE_API";; *) return 1;; esac; }
core_install(){
  local force=${1:-0}
  core_has && [ "$force" != 1 ] && core_version_ge "$(core_version 2>/dev/null || true)" "$(core_min_version)" && return 0
  local fetch url json version arch suffix pattern tmp archive extracted expected downloaded_version
  if command -v curl >/dev/null 2>&1; then fetch=curl; elif command -v wget >/dev/null 2>&1; then fetch=wget; else fetch=; fi
  [ -n "$fetch" ] || { printf '缺少 curl/wget，无法安装 sing-box\n' >&2; return 1; }
  arch=$(core_asset_arch) || { printf '不支持的架构: %s\n' "${ENV_ARCH:-$(uname -m)}" >&2; return 1; }
  suffix=$(core_libc_suffix); json=$(core_release_json "$fetch") || return 1
  version=$(jq -r '.tag_name // empty' <<<"$json"); [ -n "$version" ] || return 1
  core_version_ge "$version" "$(core_min_version)" || { printf '远端 sing-box 版本 %s 低于最低要求 %s\n' "$version" "$(core_min_version)" >&2; return 1; }
  pattern="linux-${arch}${suffix}.tar.gz"
  url=$(jq -r --arg p "$pattern" '.assets[]? | select(.name | endswith($p)) | .browser_download_url' <<<"$json" | head -n1)
  expected=$(jq -r --arg p "$pattern" '.assets[]? | select(.name | endswith($p)) | (.digest // "")' <<<"$json" | head -n1)
  [ -n "$url" ] || { printf '未找到 sing-box 资产: %s\n' "$pattern" >&2; return 1; }
  tmp=$(mktemp -d /tmp/kvm-singbox.XXXXXX) || return 1; archive="$tmp/sing-box.tar.gz"
  if [ "$fetch" = curl ]; then curl -fsSL --retry 2 --connect-timeout 8 --max-time 180 "$url" -o "$archive" 2>/dev/null || { rm -rf "$tmp"; return 1; }; else wget -qO "$archive" --tries=2 --timeout=8 "$url" 2>/dev/null || { rm -rf "$tmp"; return 1; }; fi
  [[ "$expected" == sha256:* ]] || { printf 'Release 未提供可验证的 SHA-256，拒绝安装\n' >&2; rm -rf "$tmp"; return 1; }
  command -v sha256sum >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  printf '%s  %s\n' "${expected#sha256:}" "$archive" | sha256sum -c - >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  tar -xzf "$archive" -C "$tmp" || { rm -rf "$tmp"; return 1; }
  extracted=$(find "$tmp" -type f -name sing-box -perm -u+x -print -quit 2>/dev/null); [ -n "$extracted" ] || { rm -rf "$tmp"; return 1; }
  downloaded_version=$("$extracted" version 2>/dev/null | awk '/^sing-box version /{print $3; exit}')
  core_version_ge "$downloaded_version" "$(core_min_version)" || { printf '下载的 sing-box 版本 %s 低于最低要求 %s\n' "${downloaded_version:-未知}" "$(core_min_version)" >&2; rm -rf "$tmp"; return 1; }
  install -m755 "$extracted" "$SING_BOX_BIN" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"; sync 2>/dev/null || true
  core_has || return 1
  printf 'sing-box %s installed\n' "$(core_version 2>/dev/null | head -n1)" >&2
}
core_ensure(){
  local min cur
  min=$(core_min_version); cur=$(core_version 2>/dev/null || true)
  if [ -z "$cur" ] || ! core_version_ge "$cur" "$min"; then
    core_install 1 || return 1
    cur=$(core_version 2>/dev/null || true)
    core_version_ge "$cur" "$min" || { printf 'sing-box 版本过低，要求 >= %s，当前 %s\n' "$min" "${cur:-未知}" >&2; return 1; }
  fi
}

core_start(){ runtime_start "$SING_BOX_SERVICE"; }
core_stop(){ runtime_stop "$SING_BOX_SERVICE"; }
core_restart(){ runtime_restart "$SING_BOX_SERVICE"; }
core_reload(){ runtime_reload "$SING_BOX_SERVICE"; }
core_status(){ runtime_is_active "$SING_BOX_SERVICE"; }

# ===== MODULE: lib/core-config.sh =====
build_config(){
  local exit=${1:-${EXIT_TAG:-$(state_get exit 2>/dev/null || printf direct)}} dns tun rules peer_host peer_tag
  dns=$(dns_json "$exit") || return 1
  tun='null'; if routing_apply_base 2>/dev/null; then tun=$(routing_tun_json 2>/dev/null || true); [ -n "$tun" ] || tun='null'; fi
  rules=$(routing_rules_json) || return 1
  local fallback='null'
  if [ "${PROXY_MODE:-system-proxy}" = system-proxy ] || [ "${PROXY_MODE:-}" = limited-route ]; then
    fallback=$(jq -n --argjson p "${SYSTEM_PROXY_PORT:-2080}" '{type:"mixed",tag:"system-proxy",listen:"127.0.0.1",listen_port:$p,set_system_proxy:true}')
  fi
  peer_tag=''; peer_host=''
  if [ "$exit" != direct ] && [ "$exit" != warp-system ] && [ -f "$PEER_ROOT/$exit.json" ]; then
    peer_tag=$(jq -r '.outbound.tag // empty' "$PEER_ROOT/$exit.json")
    peer_host=$(jq -r '.outbound.server // empty' "$PEER_ROOT/$exit.json")
    [ -n "$peer_tag" ] || return 1
  fi
  if [ -n "$peer_host" ]; then
    if [[ "$peer_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      rules=$(jq -c --arg h "$peer_host" --arg out "$ROUTE_DIRECT_OUTBOUND" '. + [{ip_cidr:[($h+"/32")],action:"route",outbound:$out}]' <<<"$rules")
    elif [[ "$peer_host" =~ ^[0-9a-fA-F:]+$ ]]; then
      rules=$(jq -c --arg h "$peer_host" --arg out "$ROUTE_DIRECT_OUTBOUND" '. + [{ip_cidr:[($h+"/128")],action:"route",outbound:$out}]' <<<"$rules")
    else
      rules=$(jq -c --arg h "$peer_host" --arg out "$ROUTE_DIRECT_OUTBOUND" '. + [{domain:[$h],action:"route",outbound:$out}]' <<<"$rules")
    fi
  fi
  local node_inbounds='[]' cert_provider='null' has_acme=0
  if [ -d "${NODE_DIR:-}" ]; then
    for _node_file in "$NODE_DIR"/*.json; do
      [ -f "$_node_file" ] || continue
      _node_json=$(jq -c '.inbound' "$_node_file" 2>/dev/null) || return 1
      if jq -e '.inbound.tls.certificate_provider.type == "acme" or .inbound.tls.certificate_provider == "acme-default"' "$_node_file" >/dev/null 2>&1; then
        has_acme=1
        _node_json=$(jq -c 'if .tls.certificate_provider|type == "object" then .tls.certificate_provider="acme-default" else . end' <<<"$_node_json") || return 1
      fi
      node_inbounds=$(jq -c --argjson n "$_node_json" '. + [$n]' <<<"$node_inbounds") || return 1
      if jq -e '.embedded_inbounds' "$_node_file" >/dev/null 2>&1; then
        _embedded=$(jq -c '.embedded_inbounds // []' "$_node_file") || return 1
        node_inbounds=$(jq -c --argjson e "$_embedded" '. + $e' <<<"$node_inbounds") || return 1
      fi
    done
  fi
  if [ "$has_acme" = 1 ]; then
    local acme_domain acme_email
    acme_domain=$(state_get domain 2>/dev/null || true)
    acme_email=$(state_get email 2>/dev/null || true)
    [ -n "$acme_domain" ] && [ -n "$acme_email" ] || return 1
    local acme_challenge cf_token ali_key ali_secret
    acme_challenge=$(state_get challenge 2>/dev/null || true)
    cf_token=$(state_get cf_token 2>/dev/null || true)
    ali_key=$(state_get ali_key 2>/dev/null || true)
    ali_secret=$(state_get ali_secret 2>/dev/null || true)
    cert_provider=$(jq -n --arg d "$acme_domain" --arg e "$acme_email" --arg dir "${ACME_DIR:-/var/lib/kvm-new/acme}" --arg mode "$acme_challenge" --arg cf "$cf_token" --arg ak "$ali_key" --arg as "$ali_secret" '
      {type:"acme",tag:"acme-default",domain:[$d],default_server_name:$d,email:$e,data_directory:$dir,key_type:"p256"}
       | if $mode=="http" then .disable_tls_alpn_challenge=true
         elif $mode=="alpn" then .disable_http_challenge=true
         elif $mode=="dns_cloudflare" then .dns01_challenge={provider:"cloudflare",api_token:$cf}
         elif $mode=="dns_alidns" then .dns01_challenge={provider:"alidns",access_key_id:$ak,access_key_secret:$as}
         else . end') || return 1
  fi
  local base_tmp="$CONFIG_DIR/.build-config.$$" warp_ep='null'
  if [ "$exit" = warp-system ] && declare -F warp_endpoint_json >/dev/null 2>&1 && warp_has 2>/dev/null; then
    warp_ep=$(warp_endpoint_json) || return 1
  fi
  jq -n --argjson dns "$dns" --argjson tun "$tun" --argjson fallback "$fallback" --argjson rules "$rules" --argjson nodes "$node_inbounds" --argjson warp "$warp_ep" --argjson provider "$cert_provider" --arg direct "$ROUTE_DIRECT_OUTBOUND" --arg warp_tag "$WARP_ENDPOINT_TAG" '
    {"$schema":"https://sing-box.sagernet.org/schema.json",log:{level:"warn",timestamp:true},dns:$dns,certificate_providers:(if $provider==null then [] else [$provider] end),inbounds:$nodes,outbounds:[{type:"direct",tag:$direct}],route:{rules:$rules,final:$direct,auto_detect_interface:true,default_domain_resolver:"dns-control"}}
    | if $tun != null then .inbounds += [$tun] else . end
    | if $fallback != null then .inbounds += [$fallback] else . end
    | if $warp != null then .endpoints=[$warp] | .route.final=$warp_tag else . end' >"$base_tmp" || { rm -f "$base_tmp"; return 1; }
  if [ -n "$peer_tag" ] && [ -f "$PEER_ROOT/$exit.json" ]; then
    jq --slurpfile p "$PEER_ROOT/$exit.json" '.outbounds += [($p[0].outbound + {domain_resolver:"dns-control"})] + (($p[0].extra_outbounds // []) | map(. + {domain_resolver:"dns-control"})) | .route.final=$p[0].outbound.tag' "$base_tmp" || { rm -f "$base_tmp"; return 1; }
  else
    cat "$base_tmp"
  fi
  rm -f "$base_tmp"
}
apply_config(){
  local tmp old had_service=0
  config_init || return 1
  tmp=$(config_tmp) || return 1
  old=''
  [ -f "$config_file" ] && { old=$(mktemp); cp -p "$config_file" "$old" || { rm -f "$tmp" "$old"; return 1; }; }
  core_status && had_service=1 || true
  if ! build_config >"$tmp" || ! config_validate "$tmp" || ! config_install "$tmp"; then
    [ -n "$old" ] && cp -p "$old" "$config_file"
    rm -f "$tmp" "$old"
    return 1
  fi
  if [ "$had_service" = 1 ]; then
    if ! core_restart; then
      [ -n "$old" ] && cp -p "$old" "$config_file" || rm -f "$config_file"
      core_restart >/dev/null 2>&1 || true
      rm -f "$old" "$tmp"
      return 1
    fi
  elif ! core_start; then
    [ -n "$old" ] && cp -p "$old" "$config_file" || rm -f "$config_file"
    core_stop >/dev/null 2>&1 || true
    rm -f "$old" "$tmp"
    return 1
  fi
  if ! core_status; then
    [ -n "$old" ] && cp -p "$old" "$config_file" || rm -f "$config_file"
    if [ "$had_service" = 1 ]; then core_restart >/dev/null 2>&1 || true; else core_stop >/dev/null 2>&1 || true; fi
    rm -f "$old" "$tmp"
    return 1
  fi
  rm -f "$old" "$tmp"
  routing_verify >/dev/null 2>&1 || true
  return 0
}
apply_config_quiet(){ apply_config >/dev/null 2>&1; }

# ===== MODULE: lib/routing.sh =====
ROUTE_DIRECT_SSH=1; ROUTE_DIRECT_ICMP=1; ROUTE_DIRECT_SERVER_DNS=1; ROUTE_PROXY_TCP=1; ROUTE_PROXY_UDP=1; ROUTE_PROXY_DNS=1
ROUTE_TUN_TAG=${ROUTE_TUN_TAG:-tun-in}; ROUTE_DIRECT_OUTBOUND=${ROUTE_DIRECT_OUTBOUND:-direct}; ROUTE_PROXY_OUTBOUND=${ROUTE_PROXY_OUTBOUND:-${EXIT_TAG:-warp-exit}}
routing_summary(){ printf '%s\n' 'DIRECT: SSH ICMP server-control-DNS'; printf '%s\n' "TUNNEL: TCP UDP DNS -> ${ROUTE_PROXY_OUTBOUND}"; printf 'MODE: %s\n' "$(proxy_mode_name 2>/dev/null||printf unknown)"; }
routing_tun_json(){ [ "${CAP_TUN:-0}" = 1 ]&&[ "${CAP_TUN_OPEN:-0}" = 1 ]||return 1; local ar=false; [ "${CAP_NFT:-0}" = 1 ]&&ar=true; cat <<JSON
{"type":"tun","tag":"$ROUTE_TUN_TAG","interface_name":"tun0","address":["172.18.0.1/30","fdfe:dcba:9876::1/126"],"dns_mode":"hijack","auto_route":true,"auto_redirect":$ar,"strict_route":true}
JSON
}
routing_ssh_ports(){
  {
    [ -n "${SSH_CONNECTION:-}" ] && awk '{print $4}' <<<"$SSH_CONNECTION"
    command -v ss >/dev/null 2>&1 && ss -Hlntp 2>/dev/null | awk '/sshd/{print $4}' | sed 's/.*://'
    sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9][0-9]*\).*/\1/p' /etc/ssh/sshd_config 2>/dev/null
    for f in /etc/ssh/sshd_config.d/*.conf; do [ -f "$f" ] || continue; sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9][0-9]*\).*/\1/p' "$f"; done
    command -v sshd >/dev/null 2>&1 && sshd -T 2>/dev/null | awk '/^port /{print $2}'
  } | awk '$1 ~ /^[1-9][0-9]*$/ && $1 <= 65535 {print $1}' | sort -nu
}
routing_rules_json(){
  local ssh_json='[]'; local p
  while IFS= read -r p; do [ -n "$p" ] || continue; ssh_json=$(jq -c --argjson p "$p" '. + [$p]' <<<"$ssh_json"); done < <(routing_ssh_ports)
  [ "$ssh_json" != '[]' ] || ssh_json='[22]'
  jq -n --arg direct "$ROUTE_DIRECT_OUTBOUND" --argjson ports "$ssh_json" '[{"network":["tcp"],"port":$ports,"action":"route","outbound":$direct},{"network":["icmp"],"action":"route","outbound":$direct},{"action":"hijack-dns"}]'
}
routing_apply_base(){ [ "${PROXY_MODE:-system-proxy}" = system-proxy ]&&return 1; return 0; }
routing_direct_all(){ ROUTE_PROXY_OUTBOUND="$ROUTE_DIRECT_OUTBOUND"; export ROUTE_PROXY_OUTBOUND; }; routing_proxy_all(){ [ "${EXIT_TAG:-direct}" != direct ] && [ "${EXIT_TAG:-direct}" != warp-system ]; }
routing_snapshot(){ local d=$1; mkdir -p "$d"; printf '%s\n' "${ROUTE_TUN_TAG:-tun-in}" >"$d/routing.env"; command -v ip >/dev/null 2>&1 && ip -j rule show >"$d/ip-rule.json" 2>/dev/null || :; command -v ip >/dev/null 2>&1 && ip -j route show table main >"$d/ip-route-main.json" 2>/dev/null || :; if [ "${CAP_NFT:-0}" = 1 ] && command -v nft >/dev/null 2>&1; then nft -j list ruleset >"$d/nft.json" 2>/dev/null || :; fi; }
routing_verify(){ if [ "${PROXY_MODE:-system-proxy}" = system-proxy ]; then return 0; fi; [ "${CAP_TUN:-0}" = 1 ] || return 1; command -v ip >/dev/null 2>&1 || return 1; ip link show tun0 >/dev/null 2>&1 || return 1; }
routing_restore(){ local d=$1; [ -d "$d" ] || return 1; return 0; }

# ===== MODULE: lib/transaction.sh =====
transaction_root=${KVM_TRANSACTION_ROOT:-/var/lib/kvm-new/runtime/transaction}; transaction_id=''; transaction_dir=''
transaction_begin(){
  [ -z "$transaction_dir" ] || return 1
  mkdir -p "$transaction_root" || return 1
  transaction_id=$(date +%Y%m%d%H%M%S)-$$
  transaction_dir="$transaction_root/$transaction_id"
  mkdir -p "$transaction_dir" || { transaction_dir=''; transaction_id=''; return 1; }
  state_snapshot "$transaction_dir/state.env" || { rm -rf "$transaction_dir"; transaction_dir=''; transaction_id=''; return 1; }
  [ -f "$config_file" ] && cp -p "$config_file" "$transaction_dir/config.json"
  if [ -d "${PEER_ROOT:-}" ]; then mkdir -p "$transaction_dir/peers"; cp -a "$PEER_ROOT/." "$transaction_dir/peers/" 2>/dev/null || true; fi
  if core_status; then : >"$transaction_dir/service.active"; fi
  routing_snapshot "$transaction_dir"
  : >"$transaction_dir/active"
}
transaction_commit(){
  [ -n "$transaction_dir" ] || return 1
  rm -f "$transaction_dir/active"
  rm -rf "$transaction_dir"
  transaction_dir=''; transaction_id=''
}
transaction_rollback(){
  [ -n "$transaction_dir" ] || return 1
  local had_service=0
  [ -f "$transaction_dir/service.active" ] && had_service=1
  state_restore "$transaction_dir/state.env" || return 1
  if [ -d "$transaction_dir/peers" ] && [ -n "${PEER_ROOT:-}" ]; then
    mkdir -p "$PEER_ROOT" || return 1
    find "$PEER_ROOT" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true
    cp -a "$transaction_dir/peers/." "$PEER_ROOT/" 2>/dev/null || true
  fi
  if [ -f "$transaction_dir/config.json" ]; then
    config_init || return 1
    cp -p "$transaction_dir/config.json" "$config_file" || return 1
  elif [ -f "$config_file" ]; then
    rm -f "$config_file"
  fi
  routing_restore "$transaction_dir" || return 1
  if [ "$had_service" = 1 ]; then core_restart || return 1; else core_stop || true; fi
  routing_verify 2>/dev/null || true
  rm -rf "$transaction_dir"
  transaction_dir=''; transaction_id=''
}

# ===== MODULE: proxy/mode.sh =====
proxy_mode_detect(){
  if [ "${CAP_TUN:-0}" = 1 ] && [ "${CAP_TUN_OPEN:-0}" = 1 ]; then
    if [ "${CAP_NFT:-0}" = 1 ]; then PROXY_MODE=full-tun; else PROXY_MODE=tun-no-firewall; fi
  elif [ "${CAP_IP:-0}" = 1 ] && [ "${CAP_NET_ADMIN:-0}" = 1 ]; then PROXY_MODE=limited-route
  else PROXY_MODE=system-proxy; fi
  export PROXY_MODE
}
proxy_mode_name(){ case ${PROXY_MODE:-} in full-tun)printf '%s' 'TUN + nft auto-redirect';;tun-no-firewall)printf '%s' 'TUN + iproute2';;limited-route)printf '%s' '受限路由';;system-proxy)printf '%s' '系统代理';;*)printf '%s' unknown;;esac; }

# ===== MODULE: proxy/system/config.sh =====
proxy_system_config(){
  jq -n --argjson sp "${SYSTEM_PROXY_PORT:-2080}" '{inbounds:[{type:"mixed",tag:"system-proxy",listen:"127.0.0.1",listen_port:$sp,set_system_proxy:true}]}'
}

# ===== MODULE: proxy/system/apply.sh =====
proxy_system_apply(){
  proxy_system_verify || return 1
  mkdir -p "${KVM_RUNTIME_ROOT:-/var/lib/kvm-new/runtime}"
  cat >"${KVM_RUNTIME_ROOT:-/var/lib/kvm-new/runtime}/system-proxy.env" <<EOF2
PROXY_MODE=system-proxy
SOCKS_LISTEN=127.0.0.1
SOCKS_PORT=${SYSTEM_PROXY_PORT:-2080}
HTTP_LISTEN=127.0.0.1
HTTP_PORT=${SYSTEM_HTTP_PROXY_PORT:-2081}
EOF2
  chmod 600 "${KVM_RUNTIME_ROOT:-/var/lib/kvm-new/runtime}/system-proxy.env"
}

# ===== MODULE: proxy/system/cleanup.sh =====
proxy_system_cleanup(){ rm -f "${KVM_RUNTIME_ROOT:-/var/lib/kvm-new/runtime}/system-proxy.env"; return 0; }

# ===== MODULE: proxy/system/verify.sh =====
proxy_system_verify(){ command -v "${SING_BOX_BIN:-sing-box}" >/dev/null 2>&1 || return 1; command -v jq >/dev/null 2>&1 || return 1; return 0; }

# ===== MODULE: client/manager.sh =====
PEER_ROOT=${KVM_PEER_ROOT:-/var/lib/kvm-new/peers}; PEER_DIR=$PEER_ROOT; EXIT_STATE_KEY=exit
client_init(){ mkdir -p "$PEER_ROOT"; chmod 700 "$PEER_ROOT"; }

uri_decode(){ local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }
parse_uri(){
  local raw=$1 rest tail port_spec decoded pad
  URI_SCHEME=${raw%%://*}; rest=${raw#*://}
  URI_QUERY=""; URI_USERINFO=""; URI_PORT=443; URI_PORTS=""; URI_HOST=""; VMESS_JSON=""
  case "$URI_SCHEME" in
    vmess)
      rest=${rest%%#*}; rest=${rest%%\?*}
      pad=$(( (4 - ${#rest}%4) % 4 )); [ "$pad" -gt 0 ] && rest="$rest$(printf '=%.0s' $(seq 1 $pad))"
      decoded=$(printf '%s' "$rest" | tr '_-' '/+' | base64 -d 2>/dev/null | tr -d '\r\n') || return 1
      jq -e . >/dev/null 2>&1 <<<"$decoded" || return 1
      VMESS_JSON=$decoded
      URI_HOST=$(jq -r '.add // empty' <<<"$decoded")
      URI_PORT=$(jq -r '.port // 443' <<<"$decoded")
      URI_USERINFO=$(jq -r '.id // empty' <<<"$decoded")
      URI_QUERY="type=$(jq -r '.net // "tcp"' <<<"$decoded")&path=$(jq -r '.path // empty' <<<"$decoded")&host=$(jq -r '.host // empty' <<<"$decoded")&sni=$(jq -r '.sni // .host // empty' <<<"$decoded")&security=$(jq -r '.tls // empty' <<<"$decoded")&serviceName=$(jq -r '.path // empty' <<<"$decoded")&alpn=$(jq -r '.alpn // empty' <<<"$decoded")"
      [[ "$URI_PORT" =~ ^[0-9]+$ ]] && [ "$URI_PORT" -ge 1 ] && [ "$URI_PORT" -le 65535 ] || return 1
      [ -n "$URI_HOST" ] && [ -n "$URI_USERINFO" ] || return 1
      return 0
      ;;
    ss|shadowsocks)
      # SIP002: ss://BASE64(method:password)@host:port or ss://BASE64(method:password@host:port)
      rest=${rest%%#*}
      if [[ "$rest" == *@* ]]; then
        local ui=${rest%@*}; rest=${rest#*@}; pad=$(( (4 - ${#ui}%4) % 4 )); [ "$pad" -gt 0 ] && ui="$ui$(printf '=%.0s' $(seq 1 $pad))"
        decoded=$(printf '%s' "$ui" | tr '_-' '/+' | base64 -d 2>/dev/null) || return 1
        URI_USERINFO="$decoded"
      else
        pad=$(( (4 - ${#rest}%4) % 4 )); [ "$pad" -gt 0 ] && rest="$rest$(printf '=%.0s' $(seq 1 $pad))"
        decoded=$(printf '%s' "$rest" | tr '_-' '/+' | base64 -d 2>/dev/null) || return 1
        if [[ "$decoded" == *@* ]]; then
          URI_USERINFO=${decoded%@*}; rest=${decoded#*@}
        else
          return 1
        fi
      fi
      case "$URI_USERINFO" in *:*) ;; *) return 1;; esac
      URI_QUERY="method=${URI_USERINFO%%:*}"; URI_USERINFO=${URI_USERINFO#*:}
      case "$rest" in
        \[*\]*:*) URI_HOST=${rest%%\]*}; URI_HOST=${URI_HOST#\[}; port_spec=${rest##*:};;
        *:*) URI_HOST=${rest%%:*}; port_spec=${rest#*:};;
        *) return 1;;
      esac
      URI_PORT=$port_spec
      [[ "$URI_PORT" =~ ^[0-9]+$ ]] && [ "$URI_PORT" -ge 1 ] && [ "$URI_PORT" -le 65535 ] || return 1
      [ -n "$URI_HOST" ] || return 1
      return 0
      ;;
  esac
  case $rest in *\#*) rest=${rest%%\#*};; esac
  case $rest in *\?*) URI_QUERY=${rest#*\?}; rest=${rest%%\?*};; esac
  rest=${rest%%/*}
  case "$rest" in *@*) URI_USERINFO=$(uri_decode "${rest%@*}"); rest=${rest##*@};; esac
  if [[ "$rest" == \[*\]* ]]; then
    URI_HOST=${rest%%\]*}; URI_HOST=${URI_HOST#\[}; tail=${rest##*\]}
    [ -z "$tail" ] || { [[ "$tail" == :* ]] || return 1; port_spec=${tail#:}; }
  else
    case "$rest" in *:*) URI_HOST=${rest%%:*}; port_spec=${rest#*:};; *) URI_HOST=$rest; port_spec="";; esac
  fi
  if [ "$URI_SCHEME" = hysteria2 ] || [ "$URI_SCHEME" = hy2 ]; then
    if [ -n "$port_spec" ]; then
      IFS=',' read -ra authority <<<"$port_spec"; [ "${#authority[@]}" -gt 0 ] || return 1
      for token in "${authority[@]}"; do
        if [[ "$token" =~ ^[0-9]+$ ]]; then [ "$token" -ge 1 ] && [ "$token" -le 65535 ] || return 1
        elif [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then low=${token%-*}; high=${token#*-}; [ "$low" -ge 1 ] && [ "$high" -le 65535 ] && [ "$low" -le "$high" ] || return 1
        else return 1; fi
      done
      if [[ "$port_spec" == *-* || "$port_spec" == *,* ]]; then URI_PORTS="$port_spec"; else URI_PORT="$port_spec"; fi
    fi
  else
    URI_PORT=${port_spec:-443}; [[ "$URI_PORT" =~ ^[0-9]+$ ]] && [ "$URI_PORT" -ge 1 ] && [ "$URI_PORT" -le 65535 ] || return 1
  fi
  [ -n "$URI_HOST" ] || return 1
}
query_value(){ local pair; IFS='&' read -ra _pairs <<<"${URI_QUERY:-}"; for pair in "${_pairs[@]}"; do [ "${pair%%=*}" = "$1" ] && { uri_decode "${pair#*=}"; return; }; done; }

uri_to_outbound(){
  local tag=$1 outbound sni security network path vhost service username password congestion alpn obfs_type obfs_pw flow
  sni=$(query_value sni); [ -n "$sni" ] || sni=$(query_value peer); [ -n "$sni" ] || sni=$URI_HOST
  case $URI_SCHEME in
    vless)
      security=$(query_value security); network=$(query_value type); path=$(query_value path); vhost=$(query_value host); service=$(query_value serviceName); flow=$(query_value flow)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg uuid "$URI_USERINFO" '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,packet_encoding:"xudp"}')
      [ -z "$flow" ] || outbound=$(jq --arg f "$flow" '.flow=$f' <<<"$outbound")
      if [ "$security" = reality ]; then outbound=$(jq --arg sni "$sni" --arg pbk "$(query_value pbk)" --arg sid "$(query_value sid)" '.tls={enabled:true,server_name:$sni,reality:{enabled:true,public_key:$pbk,short_id:$sid}}' <<<"$outbound"); elif [ "$security" = tls ] || [ "$security" = xtls ]; then outbound=$(jq --arg sni "$sni" '.tls={enabled:true,server_name:$sni}' <<<"$outbound"); fi
      [ "$(query_value security)" = tls ] && outbound=$(jq --arg sni "$sni" '.tls={enabled:true,server_name:$sni}' <<<"$outbound")
      case $network in ws) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport=({type:"ws",path:$path}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound");; grpc) outbound=$(jq --arg svc "$service" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound");; httpupgrade) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport={type:"httpupgrade",path:$path,host:$host}' <<<"$outbound");; esac
      ;;
    vmess)
      username=${URI_USERINFO%%:*}; password=${URI_USERINFO#*:}; [ "$password" = "$URI_USERINFO" ] && password=""
      network=$(query_value type); path=$(query_value path); vhost=$(query_value host)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg uuid "$username" --arg sec "$(query_value security)" '{type:"vmess",tag:$tag,server:$server,server_port:$port,uuid:$uuid,security:(if $sec=="" then "auto" else $sec end),alter_id:0}')
      case $network in ws) outbound=$(jq --arg path "${path:-/}" --arg host "$vhost" '.transport=({type:"ws",path:$path}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound");; grpc) outbound=$(jq --arg svc "$(query_value serviceName)" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound");; esac
      ;;
    trojan)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg password "$URI_USERINFO" --arg sni "$sni" '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni}}')
      case $(query_value type) in ws) outbound=$(jq --arg path "$(query_value path)" --arg host "$(query_value host)" '.transport=({type:"ws",path:(if $path=="" then "/" else $path end)}+(if $host=="" then {} else {headers:{Host:$host}} end))' <<<"$outbound");; grpc) outbound=$(jq --arg svc "$(query_value serviceName)" '.transport={type:"grpc",service_name:$svc}' <<<"$outbound");; esac
      ;;
    hysteria2|hy2)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg password "$URI_USERINFO" --arg sni "$sni" '{type:"hysteria2",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      obfs_pw=$(query_value obfs-password); obfs_type=$(query_value obfs)
      if [ -n "$obfs_pw" ]; then [ -n "$obfs_type" ] || obfs_type=salamander; fi
      [ -z "$obfs_type" ] || outbound=$(jq --arg type "$obfs_type" --arg pw "$obfs_pw" '.obfs={type:$type,password:$pw}' <<<"$outbound")
      local bbr up down
      bbr=$(query_value bbr_profile); up=$(query_value up_mbps); down=$(query_value down_mbps)
      [ -n "$bbr" ] && outbound=$(jq --arg b "$bbr" '.bbr_profile=$b' <<<"$outbound")
      [[ "$up" =~ ^[0-9]+$ ]] && [ "$up" -gt 0 ] && outbound=$(jq --argjson v "$up" '.up_mbps=$v' <<<"$outbound")
      [[ "$down" =~ ^[0-9]+$ ]] && [ "$down" -gt 0 ] && outbound=$(jq --argjson v "$down" '.down_mbps=$v' <<<"$outbound")
      ;;
    tuic)
      username=${URI_USERINFO%%:*}; password=${URI_USERINFO#*:}; [ "$password" = "$URI_USERINFO" ] && password=""
      congestion=$(query_value congestion_control); [ -n "$congestion" ] || congestion=bbr
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg uuid "$username" --arg password "$password" --arg cc "$congestion" --arg sni "$sni" '{type:"tuic",tag:$tag,server:$server,server_port:$port,uuid:$uuid,password:$password,congestion_control:$cc,tls:{enabled:true,server_name:$sni,alpn:["h3"]}}')
      ;;
    anytls)
      local client_metadata; client_metadata=$(query_value client_metadata)
      outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg password "$URI_USERINFO" --arg sni "$sni" --arg cm "$client_metadata" '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni}} | if $cm!="" then .client_metadata=$cm else . end');;
    socks5|socks) username=${URI_USERINFO%%:*}; password=${URI_USERINFO#*:}; [ "$password" = "$URI_USERINFO" ] && password=""; outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg user "$username" --arg pass "$password" '{type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"}|if $user!="" then .username=$user else . end|if $pass!="" then .password=$pass else . end');;
    shadowtls)
      local st_version st_password ss_method ss_password st_sni st_tag
      st_version=$(query_value version); [ -n "$st_version" ] || st_version=3
      st_password=$(query_value password); [ -n "$st_password" ] || st_password="$URI_USERINFO"
      ss_method=$(query_value ss_method); ss_password=$(query_value ss_password); st_sni=$(query_value sni); [ -n "$st_sni" ] || st_sni="$URI_HOST"
      [ "$st_version" = 2 ] || [ "$st_version" = 3 ] || return 1
      [ -n "$ss_method" ] && [ -n "$ss_password" ] || return 1
      st_tag="${tag}-shadowtls"
      outbound=$(jq -n --arg tag "$tag" --arg st "$st_tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg method "$ss_method" --arg password "$ss_password" '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:$method,password:$password,detour:$st}')
      CLIENT_EXTRA_OUTBOUNDS=$(jq -cn --arg tag "$st_tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --argjson version "$st_version" --arg password "$st_password" --arg sni "$st_sni" '[{type:"shadowtls",tag:$tag,server:$server,server_port:$port,version:$version,password:$password,tls:{enabled:true,server_name:$sni}}]')
      ;;
    snell) outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg psk "$URI_USERINFO" --arg mode "$(query_value mode)" '{type:"snell",tag:$tag,server:$server,server_port:$port,version:6,psk:$psk,mode:(if $mode=="" then "default" else $mode end)}');;
    shadowsocks|ss) outbound=$(jq -n --arg tag "$tag" --arg server "$URI_HOST" --argjson port "$URI_PORT" --arg method "$(query_value method)" --arg password "$URI_USERINFO" '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:$method,password:$password}');;
    *) return 1;;
  esac
  printf '%s' "$outbound"
}

resolve_addresses(){
  local host=$1
  if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || [[ "$host" == *:* ]]; then printf '%s\n' "$host"; return; fi
  getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u
}
node_ports(){ for f in "$NODE_DIR"/*.json; do [ -e "$f" ] || continue; jq -r '.port // .inbound.listen_port // empty' "$f" 2>/dev/null; done | sort -nu; }

client_set_exit(){
  local old new=$1
  case "$new" in direct|warp-system);; *) [ -f "$PEER_ROOT/$new.json" ] || return 1;; esac
  old=$(state_get "$EXIT_STATE_KEY" 2>/dev/null || printf direct)
  state_set "$EXIT_STATE_KEY" "$new" || return 1
  EXIT_TAG=$new; export EXIT_TAG
  if ! apply_config; then state_set "$EXIT_STATE_KEY" "$old" || true; EXIT_TAG=$old; export EXIT_TAG; return 1; fi
}

peer_add(){
  local name uri tag outbound probe port ip resolved_hosts local_ipv4 local_ipv6
  ui_clear; ui_tell "${UI_CYAN}========== 添加节点 ==========${UI_PLAIN}"
  name=$(ui_prompt '识别名称' 'RemoteNode'); [ -n "$name" ] || return
  uri=$(ui_prompt '节点链接'); [ -n "$uri" ] || return
  parse_uri "$uri" || { ui_warn '节点链接格式无效'; ui_wait; return; }
  resolved_hosts=$(resolve_addresses "$URI_HOST")
  local_ipv4=$(ip -4 -o addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')
  local_ipv6=$(ip -6 -o addr show 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')
  for port in $(node_ports); do
    if [ "$URI_PORT" = "$port" ]; then
      if [ "$URI_HOST" = 127.0.0.1 ] || [ "$URI_HOST" = localhost ] || [ "$URI_HOST" = ::1 ]; then ui_warn '禁止自环接入'; ui_wait; return; fi
      for ip in $resolved_hosts; do grep -Fqx "$ip" <<<"$local_ipv4" || grep -Fqx "$ip" <<<"$local_ipv6" || continue; ui_warn '禁止自环接入'; ui_wait; return; done
    fi
  done
  tag="out-${name//[^A-Za-z0-9_-]/-}"; tag=${tag:0:24}; local n=1; while [ -e "$PEER_ROOT/$tag.json" ]; do tag="out-${name//[^A-Za-z0-9_-]/-}-$n"; n=$((n+1)); done
  CLIENT_EXTRA_OUTBOUNDS='[]'
  local outbound_tmp
  outbound_tmp=$(mktemp) || { ui_warn '无法创建解析临时文件'; ui_wait; return; }
  if ! uri_to_outbound "$tag" >"$outbound_tmp"; then rm -f "$outbound_tmp"; ui_warn '无法解析'; ui_wait; return; fi
  outbound=$(cat "$outbound_tmp"); rm -f "$outbound_tmp"
  probe=$(mktemp); jq -n --argjson ob "$outbound" --argjson extra "${CLIENT_EXTRA_OUTBOUNDS:-[]}" --arg tag "$tag" '{"$schema":"https://sing-box.sagernet.org/schema.json",log:{level:"error"},outbounds:([$ob] + $extra + [{type:"direct",tag:"direct"}]),route:{final:$tag}}' >"$probe"
  if "$SING_BOX_BIN" check -c "$probe" >/dev/null 2>&1; then
    jq -n --arg tag "$tag" --arg name "$name" --arg uri "$uri" --argjson ob "$outbound" --argjson extra "${CLIENT_EXTRA_OUTBOUNDS:-[]}" --arg hosts "$resolved_hosts" '{tag:$tag,name:$name,uri:$uri,outbound:$ob,extra_outbounds:$extra,probe_addresses:($hosts|split("\n")|map(select(length>0)))}' >"$PEER_ROOT/$tag.json"
    chmod 600 "$PEER_ROOT/$tag.json"; ui_ok "挂载完成: $name"
  else ui_warn '校验拦截'; "$SING_BOX_BIN" check -c "$probe" 2>&1 | head -3 >&2; fi
  rm -f "$probe"; ui_wait
}

list_peers(){
  local current=$(state_get exit) title=${1:-节点选择} i=0 f tag type name port mark
  PEER_COUNT=0; PEER_FILES=()
  ui_clear; ui_tell "${UI_CYAN}========== $title ==========${UI_PLAIN}"
  for f in "$PEER_ROOT"/*.json; do
    [ -e "$f" ] || continue
    i=$((i+1)); PEER_FILES+=("$f"); tag=$(jq -r '.tag // "-"' "$f"); type=$(jq -r '.outbound.type // "-"' "$f"); name=$(jq -r '.name // "-"' "$f"); port=$(jq -r '.outbound.server_port // .outbound.server_ports[0] // "-"' "$f")
    mark=''; [ "$tag" = "$current" ] && mark=" ${UI_CYAN}<=当前${UI_PLAIN}"
    ui_tell "  $i. [$type] $name:$port$mark"
  done
  PEER_COUNT=$i
  [ "$i" -eq 0 ] && ui_tell '  暂无外部节点'
}
select_peer(){ local title=${1:-节点选择} index; while :; do list_peers "$title"; [ "$PEER_COUNT" = 0 ] && { ui_wait; return 1; }; ui_tell '  0. 返回'; index=$(ui_prompt '请选择 [回车刷新]'); [ -z "$index" ] && continue; [ "$index" = 0 ] && return 1; if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "$PEER_COUNT" ]; then PICKED="${PEER_FILES[$((index-1))]}"; return 0; else ui_warn '序号无效，请重新输入'; sleep 1; fi; done; }
peer_select(){ local tag target_name; select_peer '接管/选择节点' || return; tag=$(jq -r .tag "$PICKED"); target_name=$(jq -r '.name // .tag' "$PICKED"); if client_set_exit "$tag"; then ui_ok "已接管: $target_name"; else ui_warn '切换失败，已恢复直连'; client_set_exit direct >/dev/null 2>&1 || true; fi; ui_wait; }
peer_delete(){ while :; do select_peer '删除节点' || return; local previous_exit tag; previous_exit=$(state_get exit); tag=$(jq -r .tag "$PICKED"); if [ "$tag" = "$previous_exit" ]; then client_set_exit direct || { ui_warn '无法切换到直连'; ui_wait; continue; }; fi; rm -f "$PICKED"; ui_ok '已删除节点'; ui_wait; done; }
peer_stop(){ ui_clear; local previous; previous=$(state_get exit); state_set exit direct && sync_proxy_env; if apply_config; then ui_ok '已恢复直连'; else state_set exit "$previous" && sync_proxy_env; apply_config_quiet; ui_warn '恢复直连失败，已回滚'; fi; ui_wait; }
exit_label(){ case ${EXIT_TAG:-$(state_get exit 2>/dev/null||printf direct)} in warp-system)printf 'Cloudflare WARP';;direct)printf '直连';;*) [ -f "$PEER_ROOT/${EXIT_TAG:-}.json" ] && jq -r '.name // .tag' "$PEER_ROOT/${EXIT_TAG}.json" || printf '%s' "${EXIT_TAG:-direct}";; esac; }

# ===== MODULE: warp/manager.sh =====
# WARP is implemented entirely by sing-box's WireGuard endpoint.
# No warp-cli, wg, wg-quick, or other WARP-specific package is required.
WARP_ROOT=${KVM_WARP_ROOT:-/var/lib/kvm-new/warp}
WARP_FILE=${KVM_WARP_FILE:-$WARP_ROOT/config.json}
WARP_ENDPOINT_TAG=${WARP_ENDPOINT_TAG:-warp-wg}
WARP_EXIT_TAG=${WARP_EXIT_TAG:-warp-system}

warp_init(){ mkdir -p "$WARP_ROOT"; chmod 700 "$WARP_ROOT"; }
warp_has(){ warp_init; [ -s "$WARP_FILE" ] && jq -e '.private_key and .public_key and .id and .token and .config.interface.addresses.v4 and .config.peers[0].public_key and (.config.client_id // .config.client_id_b64 // .client_id // empty)' "$WARP_FILE" >/dev/null 2>&1; }
warp_reg_json(){ cat "$WARP_FILE" 2>/dev/null; }
warp_public_ip(){
  local proxy=$1 ip
  ip=$(curl -4 -fsS -m 12 --proxy "$proxy" https://api.ipify.org 2>/dev/null || true)
  [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  curl -4 -fsS -m 12 --proxy "$proxy" https://ifconfig.me/ip 2>/dev/null || true
}
warp_keypair(){
  local out priv pub
  out="$("${SING_BOX_BIN:-sing-box}" generate wg-keypair 2>/dev/null)" || return 1
  priv=$(awk '/PrivateKey/{print $2; exit}' <<<"$out")
  pub=$(awk '/PublicKey/{print $2; exit}' <<<"$out")
  [ -n "$priv" ] && [ -n "$pub" ] || return 1
  WARP_PRIVATE_KEY=$priv; WARP_PUBLIC_KEY=$pub
}
warp_register(){
  warp_init
  if warp_has; then ui_ok 'WARP 已注册'; ui_wait; return 0; fi
  warp_keypair || { ui_warn 'sing-box 无法生成 WARP 密钥'; ui_wait; return 1; }
  local install_id fcm tos body response
  install_id=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
  fcm="${install_id}:APA91b$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134)"
  tos=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  body=$(jq -n --arg key "$WARP_PUBLIC_KEY" --arg iid "$install_id" --arg fcm "$fcm" --arg tos "$tos" \
    '{key:$key,install_id:$iid,fcm_token:$fcm,tos:$tos,model:"PC",serial_number:$iid,locale:"zh_CN"}')
  response=$(curl -4 -fsSL --tlsv1.3 -m 20 \
    -H 'User-Agent: okhttp/3.12.1' \
    -H 'CF-Client-Version: a-7.21-0721' \
    -H 'Content-Type: application/json' \
    --data "$body" 'https://api.cloudflareclient.com/v0a2158/reg' 2>/dev/null) || {
      ui_warn 'WARP 注册请求失败'; ui_wait; return 1;
    }
  if ! jq -e '.id and .token and .config.interface.addresses.v4 and .config.peers[0].public_key' <<<"$response" >/dev/null 2>&1; then
    ui_warn "WARP 注册失败: $(jq -r '.error//.message//.errors[0].message//"未知错误"' <<<"$response" 2>/dev/null)"
    ui_wait; return 1
  fi
  jq --arg private "$WARP_PRIVATE_KEY" --arg public "$WARP_PUBLIC_KEY" '. + {private_key:$private,public_key:$public}' <<<"$response" >"$WARP_FILE.tmp" || { ui_warn 'WARP 配置生成失败'; ui_wait; return 1; }
  chmod 600 "$WARP_FILE.tmp"; mv -f "$WARP_FILE.tmp" "$WARP_FILE"
  ui_ok 'WARP 注册成功'
  printf '  WARP IPv4: '; ui_ip "$(jq -r '.config.interface.addresses.v4' "$WARP_FILE")"; printf '\n'
  ui_wait
}
warp_endpoint_json(){
  warp_has || return 1
  local a4 a6 peer endpoint ep_host ep_port reserved client_id
  a4=$(jq -r '.config.interface.addresses.v4' "$WARP_FILE")
  a6=$(jq -r '.config.interface.addresses.v6 // empty' "$WARP_FILE")
  peer=$(jq -r '.config.peers[0].public_key' "$WARP_FILE")
  endpoint=$(jq -r '.config.peers[0].endpoint.v4 // empty' "$WARP_FILE")
  ep_port=2408
  if [ -n "$endpoint" ]; then
    if [[ "$endpoint" == *:* ]]; then
      ep_host=${endpoint%:*}; ep_port=${endpoint##*:}
    else
      ep_host=$endpoint
    fi
  else
    endpoint=$(jq -r '.config.peers[0].endpoint.host // empty' "$WARP_FILE")
    ep_host=${endpoint%%:*}
    [[ "$ep_host" == \[*\] ]] && ep_host=${ep_host#\[} && ep_host=${ep_host%\]}
    [ -n "$ep_host" ] || ep_host=162.159.192.1
  fi
  [[ "$ep_port" =~ ^[0-9]+$ ]] && [ "$ep_port" -ge 1 ] && [ "$ep_port" -le 65535 ] || ep_port=2408
  client_id=$(jq -r '.config.client_id // .config.client_id_b64 // .client_id // empty' "$WARP_FILE")
  reserved='[0,0,0]'
  if [ -n "$client_id" ]; then
    local decoded
    decoded=$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1 | awk '{$1=$1; print}' | tr '\n' ',' | sed 's/,$//')
    if [ -n "$decoded" ]; then
      reserved="[$decoded]"
    fi
  fi
  jq -n --arg tag "$WARP_ENDPOINT_TAG" --arg name 'warp0' --arg a4 "$a4" --arg a6 "$a6" \
    --arg private "$(jq -r '.private_key' "$WARP_FILE")" --arg peer "$peer" --arg host "$ep_host" --argjson port "$ep_port" --argjson reserved "$reserved" \
    '{type:"wireguard",tag:$tag,system:false,name:$name,mtu:1280,address:([($a4+"/32")]+(if $a6!="" then [($a6+"/128")] else [] end)),private_key:$private,listen_port:0,peers:[{address:$host,port:$port,public_key:$peer,allowed_ips:["0.0.0.0/0","::/0"],persistent_keepalive_interval:30,reserved:$reserved}]}'
}
warp_get_exit(){
  warp_has || { ui_warn '请先注册 WARP'; ui_wait; return 1; }
  local ep cfg pid port proxy ip4 ip6
  ep=$(warp_endpoint_json) || { ui_warn 'WARP 配置读取失败'; ui_wait; return 1; }
  port=$((30000 + RANDOM % 10000)); proxy="socks5h://127.0.0.1:$port"
  cfg=$(mktemp "$WARP_ROOT/probe.XXXXXX.json") || { ui_warn '临时配置创建失败'; ui_wait; return 1; }
  jq -n --argjson ep "$ep" --argjson port "$port" \
    '{log:{level:"error"},endpoints:[$ep],inbounds:[{type:"mixed",tag:"probe-in",listen:"127.0.0.1",listen_port:$port}],route:{final:"warp-wg"}}' >"$cfg" || { rm -f "$cfg"; ui_warn 'WARP 探测配置生成失败'; ui_wait; return 1; }
  if ! "$SING_BOX_BIN" check -c "$cfg" >/dev/null 2>&1; then rm -f "$cfg"; ui_warn '当前 sing-box 不支持 WARP WireGuard endpoint'; ui_wait; return 1; fi
  "$SING_BOX_BIN" run -c "$cfg" >/dev/null 2>&1 & pid=$!
  trap 'kill "$pid" >/dev/null 2>&1 || true; rm -f "$cfg"' RETURN
  for _ in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  ip4=$(warp_public_ip "$proxy")
  kill "$pid" >/dev/null 2>&1 || true; wait "$pid" 2>/dev/null || true; rm -f "$cfg"; trap - RETURN
  [ -n "$ip4" ] || { ui_warn 'WARP 隧道未建立，未获取到出口 IP'; ui_wait; return 1; }
  if client_set_exit "$WARP_EXIT_TAG"; then
    ui_ok 'WARP 出口已启用'
    printf '  WARP IPv4: '; ui_ip "$ip4"; printf '\n'
  else
    ui_warn 'WARP 出口应用失败'
  fi
  ui_wait
}
warp_show_config(){
  warp_has || { ui_warn 'WARP 尚未注册'; ui_wait; return 1; }
  ui_title 'WARP 配置'
  printf '  注册 ID: %s\n' "$(jq -r '.id' "$WARP_FILE")"
  printf '  设备类型: %s\n' "$(jq -r '.type // .model // "未知"' "$WARP_FILE")"
  printf '  WARP IPv4: '; ui_ip "$(jq -r '.config.interface.addresses.v4' "$WARP_FILE")"; printf '\n'
  if [ -n "$(jq -r '.config.interface.addresses.v6 // empty' "$WARP_FILE")" ]; then printf '  WARP IPv6: '; ui_ip "$(jq -r '.config.interface.addresses.v6' "$WARP_FILE")"; printf '\n'; fi
  printf '  WARP 节点: '; ui_ip "$(jq -r '.config.peers[0].endpoint.v4 // .config.peers[0].endpoint.host' "$WARP_FILE")"; printf '\n'
  printf '  公钥: %s\n' "$(jq -r '.config.peers[0].public_key' "$WARP_FILE")"
  printf '  reserved: %s\n' "$(jq -r '.config.client_id // .config.client_id_b64 // .client_id // ""' "$WARP_FILE" | base64 -d 2>/dev/null | od -An -tu1 | awk '{$1=$1; print}' | tr '\n' ',' | sed 's/,$//' | sed 's/^/[/' | sed 's/$/]/')"
  ui_wait
}
warp_delete_config(){
  warp_has || { ui_warn 'WARP 尚未注册'; ui_wait; return 1; }
  local id token
  id=$(jq -r '.id' "$WARP_FILE"); token=$(jq -r '.token' "$WARP_FILE")
  curl -4 -fsSL --tlsv1.3 -m 15 -X DELETE \
    -H 'User-Agent: okhttp/3.12.1' -H 'Content-Type: application/json' -H "Authorization: Bearer $token" \
    "https://api.cloudflareclient.com/v0a2158/reg/$id" >/dev/null 2>&1 || true
  if [ "$(state_get exit 2>/dev/null || printf direct)" = "$WARP_EXIT_TAG" ]; then client_set_exit direct >/dev/null 2>&1 || true; fi
  rm -f "$WARP_FILE"; ui_ok 'WARP 配置已删除'; ui_wait
}
warp_config(){ warp_show_config; }
warp_enable(){ warp_get_exit; }
warp_disable(){ client_set_exit direct >/dev/null 2>&1 || true; ui_ok 'WARP 已停用'; ui_wait; }
warp_status(){ warp_has && ui_ok 'WARP 已注册' || ui_warn 'WARP 未注册'; ui_wait; }

# ===== MODULE: lib/update.sh =====

script_path(){ printf '%s' "${KVM_SCRIPT_PATH:-/root/s.sh}"; }
script_update_url(){ printf '%s' "${KVM_UPDATE_URL:-https://raw.githubusercontent.com/88860/-/main/s.sh}"; }

run_update(){
  local current latest tmp url self target
  ui_title '状态与更新'
  ui_tell '正在检测 sing-box 内核更新...'
  current=$(core_version 2>/dev/null || true)
  latest=$(remote_version 2>/dev/null || true)
  ui_tell "  当前内核: ${current:-未知}"
  ui_tell "  最新版本: ${latest:-获取失败}"
  if [ -n "$latest" ] && [ "$current" != "$latest" ]; then
    if ui_yes "发现 sing-box 新版本 v$latest，是否更新"; then
      if core_install 1; then
        core_cache_reset 2>/dev/null || true
        if apply_config_quiet; then ui_ok 'sing-box 内核更新并重新应用配置成功'; else ui_warn '内核已更新，但配置重新应用失败，已保留原配置'; fi
      else
        ui_warn 'sing-box 内核更新失败，原内核未覆盖'
      fi
    fi
  elif [ -n "$latest" ]; then
    ui_ok 'sing-box 已是最新版本'
  else
    ui_warn '无法获取 sing-box 最新版本，请检查网络'
  fi

  printf '\n'
  ui_tell '正在检测 s 脚本更新...'
  url=$(script_update_url)
  tmp=$(mktemp 2>/dev/null) || { ui_warn '无法创建更新临时文件'; ui_wait; return 1; }
  if ! curl -4 -fL --retry 2 --connect-timeout 10 -m 30 "$url" -o "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    ui_warn '脚本更新检查失败，请检查更新地址或网络'
    ui_wait
    return 1
  fi
  if ! bash -n "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; ui_warn '远端脚本语法校验失败，已拒绝更新'; ui_wait; return 1
  fi
  self=$(script_path)
  target="$self"
  if [ ! -f "$target" ]; then target=${KVM_ENTRYPOINT:-$0}; fi
  if cmp -s "$tmp" "$target"; then
    ui_ok 's 脚本已是最新版本'
  else
    if install -m700 "$tmp" "$target"; then
      ui_ok "s 脚本更新成功: $target"
      ui_tell '请重新执行 s 使新版本完全接管当前会话'
    else
      ui_warn 's 脚本写入失败，原脚本未修改'
    fi
  fi
  rm -f "$tmp"
  ui_wait
}

status_memory_text(){
  local total used avail
  total=$(awk '/^MemTotal:/{printf "%d",$2/1024;exit}' /proc/meminfo 2>/dev/null || printf 0)
  avail=$(awk '/^MemAvailable:/{printf "%d",$2/1024;exit}' /proc/meminfo 2>/dev/null || printf 0)
  [ "$total" -gt 0 ] || { printf '未知'; return; }
  used=$((total-avail)); [ "$used" -ge 0 ] || used=0
  printf '%s / %s MB' "$used" "$total"
}

status_uptime(){
  local sec=${1:-0} d h m
  d=$((sec/86400)); h=$(((sec%86400)/3600)); m=$(((sec%3600)/60))
  if [ "$d" -gt 0 ]; then printf '%d天%d小时' "$d" "$h";
  elif [ "$h" -gt 0 ]; then printf '%d小时%d分钟' "$h" "$m";
  elif [ "$m" -gt 0 ]; then printf '%d分钟' "$m";
  else printf '不足1分钟'; fi
}

run_uninstall(){
  local answer
  ui_title '彻底卸载'
  ui_warn '卸载将停止 sing-box，并删除 s 脚本及本项目生成的配置/状态。'
  answer=$(ui_prompt '输入 yes 确认')
  [ "$answer" = yes ] || { ui_tell '已取消'; ui_wait; return 0; }
  core_stop >/dev/null 2>&1 || true
  if [ "${ENV_INIT:-none}" = systemd ] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -rf /etc/sing-box /var/lib/kvm-new /run/kvm-new
  rm -f /usr/local/bin/s /root/s.sh
  ui_ok '卸载完成'
  exit 0
}

menu_status(){
  while :; do
    ui_clear
    ui_tell "${UI_CYAN}========== 状态与更新 ==========${UI_PLAIN}"
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
    local s_state="${UI_RED}未运行${UI_PLAIN}"
    core_status >/dev/null 2>&1 && s_state="${UI_GREEN}正常运行${UI_PLAIN}"
    ui_tell "  系统版本: ${os}"
    ui_tell "  内核架构: ${core} (${arch})"
    ui_tell "  内存状态: ${mem}"
    ui_tell "  运行时间: ${up}"
    ui_tell "  singbox : ${s_state}"
    ui_tell "  singbox版本: ${sb_ver:-无} (${sb_asset:-未知})"
    ui_tell ''
    render_client_ip_status
    ui_tell ''
    ui_tell '  1. 检测更新'
    ui_tell '  2. 彻底卸载'
    ui_tell '  0. 返回'
    ui_tell "${UI_CYAN}================================${UI_PLAIN}"
    case $(ui_prompt '请选择') in
      1) run_update ;;
      2) run_uninstall ;;
      0) break ;;
      *) ui_invalid ;;
    esac
  done
}

# ===== MODULE: lib/ui.sh =====
UI_RED='\033[31m'
UI_GREEN='\033[32m'
UI_CYAN='\033[36m'
UI_YELLOW='\033[33m'
UI_PURPLE='\033[35m'
UI_BROWN='\033[38;5;130m'
UI_PLAIN='\033[0m'

ui_clear(){
  if command -v clear >/dev/null 2>&1; then clear 2>/dev/null || printf '\033[H\033[2J'; else printf '\033[H\033[2J'; fi
}
ui_read(){ local v; if [ -c /dev/tty ]; then IFS= read -r v </dev/tty || { if [ "$$" != "$BASHPID" ]; then kill -TERM "$PPID" 2>/dev/null || true; else exit 0; fi; return 130; }; else IFS= read -r v || { if [ "$$" != "$BASHPID" ]; then kill -TERM "$PPID" 2>/dev/null || true; else exit 0; fi; return 130; }; fi; printf '%s' "${v%$'\r'}"; }
ui_ip(){
  local v=$1
  if [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { [[ "$v" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$v" == *:* ]]; }; then
    printf '%b%s%b' "$UI_GREEN" "$v" "$UI_PLAIN"
  else
    printf '%s' "$v"
  fi
}
ui_color_ips(){
  local text=${1:-} esc=$'\033'
  printf '%s\n' "$text" | sed -E \
    -e "s/([0-9]{1,3}\\.){3}[0-9]{1,3}/${esc}[32m&${esc}[0m/g" \
    -e "s/([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f]{0,4}/${esc}[32m&${esc}[0m/g"
}
ui_ip_or_host(){
  local v=$1
  if [[ "$v" =~ ^\[[0-9A-Fa-f:]+\](:[0-9]+)?$ ]]; then
    printf '%b%s%b' "$UI_GREEN" "$v" "$UI_PLAIN"
  else
    ui_ip "$v"
  fi
}
ui_prompt(){ local msg="$1" def="${2:-}" v; msg=$(ui_color_ips "$msg"); def=$(ui_color_ips "$def"); if [ -n "$def" ]; then printf '  %b%s [%b]: %b' "$UI_CYAN" "$msg" "$def" "$UI_PLAIN" >&2; else printf '  %b%s: %b' "$UI_CYAN" "$msg" "$UI_PLAIN" >&2; fi; v=$(ui_read); printf '%s' "${v:-$def}"; }
ui_yes(){ local v; v=$(ui_prompt "$1 (y/N)" 'n'); [[ "$v" == y || "$v" == Y ]]; }
ui_wait(){ printf '\n  %b>> 按回车键继续...%b' "$UI_CYAN" "$UI_PLAIN" >&2; ui_read >/dev/null; }
ui_tell(){ printf '  %b\n' "$(ui_color_ips "$*")"; }
ui_ok(){ printf '  %b[√] %b%b\n' "$UI_GREEN" "$(ui_color_ips "$*")" "$UI_PLAIN"; }
ui_warn(){ printf '  %b[×] %b%b\n' "$UI_RED" "$(ui_color_ips "$*")" "$UI_PLAIN"; }
ui_alert(){ printf '  %b[!] %b%b\n' "$UI_YELLOW" "$(ui_color_ips "$*")" "$UI_PLAIN"; }
ui_title(){ ui_clear; ui_tell "${UI_CYAN}========== $1 ==========${UI_PLAIN}"; }
ui_footer(){ ui_tell "${UI_CYAN}================================${UI_PLAIN}"; }
ui_menu(){ local n label; while [ "$#" -gt 0 ]; do n=$1; label=$2; shift 2; ui_tell "  $n. $label"; done; }
ui_invalid(){ ui_warn '输入无效，请重新选择'; sleep 1; }
ui_back(){ ui_tell '  0. 返回'; }

# ===== MODULE: server/protocols/node.sh =====
NODE_ROOT=${KVM_NODE_ROOT:-/var/lib/kvm-new/nodes}
NODE_DIR=$NODE_ROOT
ACME_DIR=${KVM_ACME_ROOT:-/var/lib/kvm-new/acme}

node_init(){ mkdir -p "$NODE_DIR" && chmod 700 "$NODE_DIR"; }
node_unique_tag(){
  local base=${1//[^A-Za-z0-9_-]/-} tag="in-${base:-node}" n=1
  node_init || return 1
  while [ -e "$NODE_DIR/$tag.json" ]; do tag="in-${base:-node}-$n"; n=$((n+1)); done
  printf '%s' "$tag"
}
node_uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '%s-%s' "$(date +%s)" "$$"; }
node_secret(){ openssl rand -base64 24 2>/dev/null | tr -d '/+=' | cut -c1-24; }
node_secret_base64(){
  local bytes=${1:-16}
  if command -v sing-box >/dev/null 2>&1; then sing-box generate rand --base64 "$bytes" 2>/dev/null && return 0; fi
  openssl rand -base64 "$bytes" 2>/dev/null
}
node_port(){
  local p used file
  while :; do
    p=$((20000 + RANDOM % 30000)); used=0
    if command -v ss >/dev/null 2>&1 && ss -Hlnptu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$p$"; then used=1; fi
    if [ "$used" = 0 ]; then
      for file in "$NODE_DIR"/*.json; do
        [ -f "$file" ] || continue
        [ "$(jq -r '.port // .inbound.listen_port // empty' "$file" 2>/dev/null)" = "$p" ] && { used=1; break; }
      done
    fi
    [ "$used" = 0 ] && { printf '%s' "$p"; return; }
  done
}
node_list(){ node_init || return 1; find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sort; }
node_save(){
  local file=$1 kind port tag

  node_init || return 1
  [ -s "$file" ] || return 1
  jq -e . "$file" >/dev/null 2>&1 || return 1
  kind=$(jq -r '.kind // empty' "$file"); port=$(jq -r '.port // 0' "$file"); tag=$(jq -r '.tag // empty' "$file")
  [[ "$kind" =~ ^(vless|vmess|trojan|shadowsocks|shadowtls-shadowsocks|snell|socks5|hysteria2|tuic|anytls)$ ]] || return 1
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  jq -e '.tag and .name and .inbound.type and .inbound.tag and (.inbound.listen_port|numbers)' "$file" >/dev/null 2>&1 || return 1
  [ "$tag" = "$(jq -r '.inbound.tag' "$file")" ] || return 1
  [ "$(jq -r '.inbound.listen_port' "$file")" = "$port" ] || return 1
  case "$kind" in hysteria2|tuic) [ "$(jq -r '.inbound.listen_port' "$file")" = "$port" ] || return 1;; esac
  chmod 600 "$file"
}
node_kind_label(){
  case ${1:-} in
    vless) printf 'VLESS' ;; vmess) printf 'VMess' ;; trojan) printf 'Trojan' ;;
    shadowsocks) printf 'Shadowsocks' ;; shadowtls-shadowsocks) printf 'ShadowTLS+SS' ;;
    snell) printf 'Snell' ;; socks5) printf 'SOCKS5' ;; hysteria2) printf 'Hysteria2' ;;
    tuic) printf 'TUIC' ;; anytls) printf 'AnyTLS' ;; *) printf '%s' "${1:-未知}" ;;
  esac
}

# ===== MODULE: server/protocols/basic.sh =====
server_prompt_cert(){
  SERVER_STATE_SNAPSHOT=$(mktemp) || return 1
  state_snapshot "$SERVER_STATE_SNAPSHOT" || return 1
  local d cf k
  d=$(ui_prompt '证书域名' "$(state_get domain 2>/dev/null)")
  [ -n "$d" ] || return 1
  cf=$(ui_prompt '证书文件' "$(state_get cert_file 2>/dev/null)")
  k=$(ui_prompt '私钥文件' "$(state_get key_file 2>/dev/null)")
  [ -f "$cf" ] && [ -f "$k" ] || { ui_warn '证书或私钥不存在'; return 1; }
  state_set domain "$d"; state_set cert_file "$cf"; state_set key_file "$k"; TLS_MODE=cert
}
server_prompt_acme(){
  SERVER_STATE_SNAPSHOT=$(mktemp) || return 1
  state_snapshot "$SERVER_STATE_SNAPSHOT" || return 1
  local d e
  d=$(ui_prompt 'ACME 域名' "$(state_get domain 2>/dev/null)")
  e=$(ui_prompt 'ACME 邮箱' "$(state_get email 2>/dev/null)")
  [ -n "$d" ] && [ -n "$e" ] || return 1
  command -v "$SING_BOX_BIN" >/dev/null 2>&1 || return 1
  [[ $("$SING_BOX_BIN" version 2>/dev/null) == *with_acme* ]] || { ui_warn '当前 sing-box 未包含 with_acme 构建标签'; return 1; }
  state_set domain "$d"; state_set email "$e"; [ -n "$(state_get challenge 2>/dev/null || true)" ] || state_set challenge http; TLS_MODE=acme
}
server_prompt_tls(){
  local mode
  mode=$(ui_prompt 'TLS 证书: 1 已有证书 2 ACME' 1)
  case "$mode" in 2) server_prompt_acme ;; *) server_prompt_cert ;; esac
}
server_tls_json(){
  if [ "${TLS_MODE:-cert}" = acme ]; then
    jq -n --arg d "$(state_get domain)" --arg e "$(state_get email)" \
      '{enabled:true,server_name:$d,certificate_provider:"acme-default"}'
  else
    jq -n --arg d "$(state_get domain)" --arg cf "$(state_get cert_file)" --arg k "$(state_get key_file)" \
      '{enabled:true,server_name:$d,certificate_path:$cf,key_path:$k}'
  fi
}
protocol_transport_json(){
  case ${1:-tcp} in
    tcp) jq -n '{}' ;;
    ws) local path host; path=$(ui_prompt 'WS 路径' '/ws'); host=$(ui_prompt 'CDN Host' "$(state_get domain)"); jq -n --arg p "$path" --arg h "$host" '{type:"ws",path:$p,headers:{Host:$h}}' ;;
    grpc) local svc; svc=$(ui_prompt 'gRPC ServiceName' 'grpc'); jq -n --arg s "$svc" '{type:"grpc",service_name:$s}' ;;
    httpupgrade) local path host; path=$(ui_prompt 'HTTPUpgrade 路径' '/'); host=$(ui_prompt 'CDN Host' "$(state_get domain)"); jq -n --arg p "$path" --arg h "$host" '{type:"httpupgrade",path:$p,host:$h}' ;;
    *) return 1 ;;
  esac
}
protocol_apply_transport(){
  local f=$1 mode=$2 t
  [ "$mode" = tcp ] && return 0
  t=$(protocol_transport_json "$mode") || return 1
  jq --argjson t "$t" --arg mode "$mode" '.inbound.transport=$t | .meta.transport=$mode' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
}
server_save_and_apply(){
  local f=$1 transport=${2:-tcp}
  node_save "$f" || { ui_warn '节点数据无效'; return 1; }
  protocol_apply_transport "$f" "$transport" || { rm -f "$f"; ui_warn '传输层配置失败'; return 1; }
  if ! apply_config; then
    rm -f "$f"
    [ -n "${SERVER_STATE_SNAPSHOT:-}" ] && state_restore "$SERVER_STATE_SNAPSHOT" || true
    rm -f "${SERVER_STATE_SNAPSHOT:-}"; SERVER_STATE_SNAPSHOT=''
    ui_warn '配置应用失败，已回滚节点'
    return 1
  fi
  rm -f "${SERVER_STATE_SNAPSHOT:-}"; SERVER_STATE_SNAPSHOT=''
  ui_ok '协议已应用'
  if declare -F render_share_uri >/dev/null 2>&1; then render_share_uri "$f"; fi
  ui_wait
}
protocol_new_file(){ local name=$1; node_unique_tag "$name"; }

server_uri_encode(){ jq -rn --arg s "${1:-}" '$s|@uri'; }
server_public_host4(){
  [ -n "${NET_IPV4:-}" ] && { printf '%s' "$NET_IPV4"; return; }
  network_source_v4 2>/dev/null && return
  curl -4 -fsS -m 8 https://api.ipify.org 2>/dev/null || true
}
server_public_host6(){
  [ -n "${NET_IPV6:-}" ] && { printf '%s' "$NET_IPV6"; return; }
  network_source_v6 2>/dev/null && return
  curl -6 -fsS -m 8 https://api64.ipify.org 2>/dev/null || true
}
server_build_share_uri(){
  local file=$1 kind name port host meta method password uuid sni transport path hosthdr service cc version mode
  name=$(jq -r '.name // .tag' "$file")
  kind=$(jq -r '.kind' "$file")
  port=$(jq -r '.port // .inbound.listen_port' "$file")
  meta=$(jq -c '.meta // {}' "$file")
  host=${2:-}
  [ -n "$host" ] || return 1
  case "$kind" in
    vless)
      uuid=$(jq -r '.meta.uuid // .inbound.users[0].uuid // empty' "$file")
      transport=$(jq -r '.meta.transport // "tcp"' "$file")
      if [ "$(jq -r '.tls_mode // ""' "$file")" = reality ]; then
        sni=$(jq -r '.meta.target // .inbound.tls.server_name' "$file")
        printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
          "$uuid" "$host" "$port" "$(server_uri_encode "$sni")" "$(jq -r '.meta.public_key' "$file")" "$(jq -r '.meta.short_id' "$file")" "$(server_uri_encode "$name")"
      else
        local q='encryption=none&security=tls'
        sni=$(state_get domain 2>/dev/null); [ -n "$sni" ] || sni=$host
        q="$q&sni=$(server_uri_encode "$sni")&allowInsecure=0"
        case "$transport" in
          ws) path=$(jq -r '.inbound.transport.path // "/ws"' "$file"); hosthdr=$(jq -r '.inbound.transport.headers.Host // empty' "$file"); q="$q&type=ws&path=$(server_uri_encode "$path")"; [ -n "$hosthdr" ] && q="$q&host=$(server_uri_encode "$hosthdr")";;
          grpc) service=$(jq -r '.inbound.transport.service_name // "grpc"' "$file"); q="$q&type=grpc&serviceName=$(server_uri_encode "$service")";;
          httpupgrade) path=$(jq -r '.inbound.transport.path // "/"' "$file"); hosthdr=$(jq -r '.inbound.transport.headers.Host // .inbound.transport.host // empty' "$file"); q="$q&type=httpupgrade&path=$(server_uri_encode "$path")"; [ -n "$hosthdr" ] && q="$q&host=$(server_uri_encode "$hosthdr")";;
          *) q="$q&type=tcp";;
        esac
        printf 'vless://%s@%s:%s?%s#%s' "$uuid" "$host" "$port" "$q" "$(server_uri_encode "$name")"
      fi;;
    vmess)
      uuid=$(jq -r '.meta.uuid // .inbound.users[0].uuid // empty' "$file")
      transport=$(jq -r '.meta.transport // "tcp"' "$file")
      path=$(jq -r '.inbound.transport.path // empty' "$file")
      hosthdr=$(jq -r '.inbound.transport.headers.Host // .inbound.transport.host // empty' "$file")
      service=$(jq -r '.inbound.transport.service_name // empty' "$file")
      sni=$(state_get domain 2>/dev/null); [ -n "$sni" ] || sni=$host
      jq -cn --arg v "2" --arg ps "" --arg add "$host" --arg port "$port" --arg id "$uuid" --arg aid "0" --arg sc "auto" --arg net "$transport" --arg type "$transport" --arg host "$hosthdr" --arg path "$path" --arg tls "tls" --arg sni "$sni" --arg serviceName "$service" \
        '{v:$v,ps:$ps,add:$add,port:($port|tonumber),id:$id,aid:0,scy:$sc,net:$net,type:$type,host:$host,path:$path,tls:$tls,sni:$sni,serviceName:$serviceName}' | tr -d '\n' | base64 -w0 | tr '+/' '-_' | tr -d '=' | { read -r b; printf 'vmess://%s#%s' "$b" "$(server_uri_encode "$name")"; }
      ;;
    trojan)
      password=$(jq -r '.meta.password // .inbound.users[0].password // empty' "$file"); sni=$(state_get domain 2>/dev/null); [ -n "$sni" ] || sni=$host; transport=$(jq -r '.meta.transport // "tcp"' "$file")
      printf 'trojan://%s@%s:%s?security=tls&sni=%s&allowInsecure=0' "$(server_uri_encode "$password")" "$host" "$port" "$(server_uri_encode "$sni")"
      case "$transport" in ws) printf '&type=ws&path=%s' "$(server_uri_encode "$(jq -r '.inbound.transport.path // "/ws"' "$file")")";; grpc) printf '&type=grpc&serviceName=%s' "$(server_uri_encode "$(jq -r '.inbound.transport.service_name // "grpc"' "$file")")";; esac
      printf '#%s' "$(server_uri_encode "$name")";;
    shadowsocks)
      method=$(jq -r '.meta.method // .inbound.method' "$file"); password=$(jq -r '.meta.password // .inbound.password' "$file")
      local plain b64
      plain="$method:$password"; b64=$(printf '%s' "$plain" | base64 -w0 2>/dev/null || printf '%s' "$plain" | base64 | tr -d '\n')
      printf 'ss://%s@%s:%s#%s' "$b64" "$host" "$port" "$(server_uri_encode "$name")";;
    hysteria2)
      password=$(jq -r '.meta.password // .inbound.users[0].password' "$file"); sni=$(state_get domain 2>/dev/null); [ -n "$sni" ] || sni=$host
      printf 'hysteria2://%s@%s:%s?sni=%s' "$(server_uri_encode "$password")" "$host" "$port" "$(server_uri_encode "$sni")"
      cc=$(jq -r '.meta.bbr_profile // empty' "$file"); [ -n "$cc" ] && printf '&bbr_profile=%s' "$(server_uri_encode "$cc")"
      local cup cdown; cup=$(jq -r '.meta.up_mbps // 0' "$file"); cdown=$(jq -r '.meta.down_mbps // 0' "$file")
      if [ "${cup:-0}" -gt 0 ] || [ "${cdown:-0}" -gt 0 ]; then printf '&up_mbps=%s&down_mbps=%s' "$cup" "$cdown"; fi
      local obfs opw min max; obfs=$(jq -r '.meta.obfs // empty' "$file"); opw=$(jq -r '.meta.obfs_password // empty' "$file"); min=$(jq -r '.meta.min_packet_size // empty' "$file"); max=$(jq -r '.meta.max_packet_size // empty' "$file")
      [ -n "$obfs" ] && printf '&obfs=%s&obfs-password=%s' "$(server_uri_encode "$obfs")" "$(server_uri_encode "$opw")"
      [ "$obfs" = gecko ] && [ -n "$min" ] && printf '&min_packet_size=%s' "$min"; [ "$obfs" = gecko ] && [ -n "$max" ] && printf '&max_packet_size=%s' "$max"
      printf '#%s' "$(server_uri_encode "$name")";;
    tuic)
      uuid=$(jq -r '.meta.uuid // .inbound.users[0].uuid' "$file"); password=$(jq -r '.meta.password // .inbound.users[0].password' "$file"); cc=$(jq -r '.meta.congestion_control // .inbound.congestion_control // "cubic"' "$file"); sni=$(state_get domain 2>/dev/null); [ -n "$sni" ] || sni=$host
      printf 'tuic://%s:%s@%s:%s?congestion_control=%s&alpn=h3&sni=%s&allow_insecure=0#%s' "$uuid" "$(server_uri_encode "$password")" "$host" "$port" "$(server_uri_encode "$cc")" "$(server_uri_encode "$sni")" "$(server_uri_encode "$name")";;
    anytls)
      password=$(jq -r '.meta.password // .inbound.users[0].password' "$file"); sni=$(state_get domain 2>/dev/null); [ -n "$sni" ] || sni=$host
      printf 'anytls://%s@%s:%s?sni=%s&insecure=0#%s' "$(server_uri_encode "$password")" "$host" "$port" "$(server_uri_encode "$sni")" "$(server_uri_encode "$name")";;
    socks5)
      printf 'socks5://%s:%s@%s:%s#%s' "$(server_uri_encode "$(jq -r '.meta.username // .inbound.users[0].username' "$file")")" "$(server_uri_encode "$(jq -r '.meta.password // .inbound.users[0].password' "$file")")" "$host" "$port" "$(server_uri_encode "$name")";;
    snell)
      printf 'snell://%s@%s:%s?version=6&mode=%s#%s' "$(server_uri_encode "$(jq -r '.meta.psk // .inbound.psk' "$file")")" "$host" "$port" "$(jq -r '.meta.mode // .inbound.mode // "default"' "$file")" "$(server_uri_encode "$name")";;
    shadowtls-shadowsocks)
      local stv stpw stm ss_pw
      stv=$(jq -r '.meta.version // .inbound.version' "$file")
      stpw=$(jq -r '.meta.shadowtls_password' "$file")
      stm=$(jq -r '.meta.method' "$file")
      ss_pw=$(jq -r '.meta.password' "$file")
      sni=$(jq -r '.meta.handshake' "$file")
      printf 'shadowtls://%s@%s:%s?version=%s&sni=%s&ss_method=%s&ss_password=%s#%s\n' \
        "$(server_uri_encode "$stpw")" "$host" "$port" "$stv" "$(server_uri_encode "$sni")" "$(server_uri_encode "$stm")" "$(server_uri_encode "$ss_pw")" "$(server_uri_encode "$name")"
      return 0;;
    *) return 1;;
  esac
}
render_share_uri(){
  local file=$1 h4 h6 uri
  h4=$(server_public_host4); h6=$(server_public_host6)
  if [ "$(jq -r '.tls_mode // empty' "$file")" = acme ]; then
    local d; d=$(state_get domain 2>/dev/null); [ -n "$d" ] && h4="$d" && h6=''
  fi
  if [ -n "$h4" ]; then uri=$(server_build_share_uri "$file" "$h4") && ui_tell "${UI_GREEN}${uri}${UI_PLAIN}"; fi
  if [ -n "$h6" ]; then uri=$(server_build_share_uri "$file" "[$h6]") && ui_tell "${UI_GREEN}${uri}${UI_PLAIN}"; fi
  [ -n "$h4$h6" ] || ui_warn '未识别到本机公网 IP，无法生成分享信息'
}

create_vless_tcp_tls(){
  local name port uuid tag f tls tlsmode
  ui_title 'VLESS / TCP + TLS'; name=$(ui_prompt '节点名称' 'VLESS-TLS'); server_prompt_tls || return
  port=$(prompt_port t "$(node_port)"); uuid=$(ui_prompt 'UUID' "$(node_uuid)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"; tls=$(server_tls_json); tlsmode=${TLS_MODE:-cert}
  jq -n --arg tag "$tag" --arg name "$name" --arg uuid "$uuid" --arg tlsmode "$tlsmode" --argjson port "$port" --argjson tls "$tls" \
    '{tag:$tag,name:$name,kind:"vless",port:$port,tls_mode:$tlsmode,meta:{uuid:$uuid,transport:"tcp"},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:$tls}}' >"$f"
  server_save_and_apply "$f" tcp
}
create_vless_reality(){
  local name port uuid target kp priv pub sid tag f
  ui_title 'VLESS / TCP + Reality'; name=$(ui_prompt '节点名称' 'VLESS-Reality'); port=$(prompt_port t "$(node_port)"); uuid=$(ui_prompt 'UUID' "$(node_uuid)"); target=$(ui_prompt 'Reality 握手域名' 'www.microsoft.com')
  kp=$(sing-box generate reality-keypair 2>/dev/null) || { ui_warn 'Reality 密钥生成失败'; ui_wait; return; }; priv=$(awk '/PrivateKey/{print $2}' <<<"$kp"); pub=$(awk '/PublicKey/{print $2}' <<<"$kp"); sid=$(openssl rand -hex 4 2>/dev/null || printf 01234567); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"
  jq -n --arg tag "$tag" --arg name "$name" --arg uuid "$uuid" --arg target "$target" --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" --argjson port "$port" \
    '{tag:$tag,name:$name,kind:"vless",port:$port,tls_mode:"reality",meta:{uuid:$uuid,target:$target,public_key:$pub,short_id:$sid,transport:"tcp"},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$target,reality:{enabled:true,handshake:{server:$target,server_port:443},private_key:$priv,short_id:[$sid]}}}}' >"$f"
  server_save_and_apply "$f" tcp
}
create_vless_transport(){
  local mode=$1 name port uuid tag f tls
  ui_title "VLESS / $mode"; name=$(ui_prompt '节点名称' "VLESS-${mode}"); server_prompt_tls || return; port=$(prompt_port t "$(node_port)"); uuid=$(ui_prompt 'UUID' "$(node_uuid)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"; tls=$(server_tls_json)
  jq -n --arg tag "$tag" --arg name "$name" --arg uuid "$uuid" --argjson port "$port" --argjson tls "$tls" --arg transport "$mode" --arg tlsmode "${TLS_MODE:-cert}" \
    '{tag:$tag,name:$name,kind:"vless",port:$port,tls_mode:$tlsmode,meta:{uuid:$uuid,transport:$transport},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid}],tls:$tls}}' >"$f"
  server_save_and_apply "$f" "$mode"
}
create_vmess_tcp(){
  local name port uuid tag f; ui_title 'VMess / TCP'; name=$(ui_prompt '节点名称' 'VMess-TCP'); port=$(prompt_port t "$(node_port)"); uuid=$(ui_prompt 'UUID' "$(node_uuid)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"
  jq -n --arg tag "$tag" --arg name "$name" --arg uuid "$uuid" --argjson port "$port" '{tag:$tag,name:$name,kind:"vmess",port:$port,tls_mode:"none",meta:{uuid:$uuid,transport:"tcp"},inbound:{type:"vmess",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,alterId:0}]}}' >"$f"; server_save_and_apply "$f" tcp
}
create_vmess_transport(){
  local mode=$1 name port uuid tag f tls; ui_title "VMess / $mode"; name=$(ui_prompt '节点名称' "VMess-${mode}"); server_prompt_tls || return; port=$(prompt_port t "$(node_port)"); uuid=$(ui_prompt 'UUID' "$(node_uuid)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"; tls=$(server_tls_json)
  jq -n --arg tag "$tag" --arg name "$name" --arg uuid "$uuid" --argjson port "$port" --argjson tls "$tls" --arg transport "$mode" --arg tlsmode "${TLS_MODE:-cert}" '{tag:$tag,name:$name,kind:"vmess",port:$port,tls_mode:$tlsmode,meta:{uuid:$uuid,transport:$transport},inbound:{type:"vmess",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,alterId:0}],tls:$tls}}' >"$f"; server_save_and_apply "$f" "$mode"
}
create_trojan_tcp_tls(){
  local name port pw tag f tls tlsmode; ui_title 'Trojan / TCP + TLS'; name=$(ui_prompt '节点名称' 'Trojan-TLS'); server_prompt_tls || return; port=$(prompt_port t "$(node_port)"); pw=$(ui_prompt '密码' "$(node_secret_base64)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"; tls=$(server_tls_json); tlsmode=${TLS_MODE:-cert}
  jq -n --arg tag "$tag" --arg name "$name" --arg pw "$pw" --arg tlsmode "$tlsmode" --argjson port "$port" --argjson tls "$tls" '{tag:$tag,name:$name,kind:"trojan",port:$port,tls_mode:$tlsmode,meta:{password:$pw,transport:"tcp"},inbound:{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pw}],tls:$tls}}' >"$f"; server_save_and_apply "$f" tcp
}
create_trojan_transport(){
  local mode=$1 name port pw tag f tls; ui_title "Trojan / $mode"; name=$(ui_prompt '节点名称' "Trojan-${mode}"); server_prompt_tls || return; port=$(prompt_port t "$(node_port)"); pw=$(ui_prompt '密码' "$(node_secret_base64)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"; tls=$(server_tls_json)
  jq -n --arg tag "$tag" --arg name "$name" --arg pw "$pw" --argjson port "$port" --argjson tls "$tls" --arg transport "$mode" --arg tlsmode "${TLS_MODE:-cert}" '{tag:$tag,name:$name,kind:"trojan",port:$port,tls_mode:$tlsmode,meta:{password:$pw,transport:$transport},inbound:{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pw}],tls:$tls}}' >"$f"; server_save_and_apply "$f" "$mode"
}
create_shadowsocks(){
  local choice method_label method name port pw tag f
  ui_title 'Shadowsocks'
  ui_tell '  加密方式'
  ui_menu 1 'SS2022 AES-256-GCM' 2 'SS2022 ChaCha20-Poly1305' 3 'AES-256-GCM' 4 'ChaCha20-Poly1305'
  ui_back; ui_footer
  while :; do
    case $(ui_prompt '请选择加密方式') in
      1) method_label='SS2022 AES-256-GCM'; method='2022-blake3-aes-256-gcm'; break ;;
      2) method_label='SS2022 ChaCha20-Poly1305'; method='2022-blake3-chacha20-poly1305'; break ;;
      3) method_label='AES-256-GCM'; method='aes-256-gcm'; break ;;
      4) method_label='ChaCha20-Poly1305'; method='chacha20-ietf-poly1305'; break ;;
      0) return ;;
      *) ui_invalid ;;
    esac
  done
  name=$(ui_prompt '节点名称' "SS-${method_label}")
  port=$(prompt_port t "$(node_port)")
  if [[ "$method" == 2022-blake3-aes-256-gcm ]]; then pw=$(node_secret_base64 32); elif [[ "$method" == 2022-* ]]; then pw=$(node_secret_base64 16); else pw=$(ui_prompt '密码' "$(node_secret)"); fi
  tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"
  jq -n --arg tag "$tag" --arg name "$name" --arg pw "$pw" --arg method "$method" --arg method_label "$method_label" --argjson port "$port" \
    '{tag:$tag,name:$name,kind:"shadowsocks",port:$port,tls_mode:"none",meta:{method:$method,method_label:$method_label,password:$pw},inbound:{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:$method,password:$pw}}' >"$f"
  server_save_and_apply "$f" tcp
}

create_shadowtls(){
  local version method_label method name port stpw sspw target tag ssport f
  ui_title 'ShadowTLS + Shadowsocks'
  ui_tell '  ShadowTLS 版本'
  ui_menu 1 'v2' 2 'v3'
  ui_back; ui_footer
  while :; do
    case $(ui_prompt '请选择 ShadowTLS 版本') in
      1) version=2; break ;;
      2) version=3; break ;;
      0) return ;;
      *) ui_invalid ;;
    esac
  done
  ui_clear
  ui_title "ShadowTLS v${version} + Shadowsocks"
  ui_tell '  Shadowsocks 加密方式'
  ui_menu 1 'SS2022 AES-256-GCM' 2 'SS2022 ChaCha20-Poly1305' 3 'AES-256-GCM' 4 'ChaCha20-Poly1305'
  ui_back; ui_footer
  while :; do
    case $(ui_prompt '请选择加密方式') in
      1) method_label='SS2022 AES-256-GCM'; method='2022-blake3-aes-256-gcm'; break ;;
      2) method_label='SS2022 ChaCha20-Poly1305'; method='2022-blake3-chacha20-poly1305'; break ;;
      3) method_label='AES-256-GCM'; method='aes-256-gcm'; break ;;
      4) method_label='ChaCha20-Poly1305'; method='chacha20-ietf-poly1305'; break ;;
      0) return ;;
      *) ui_invalid ;;
    esac
  done
  name=$(ui_prompt '节点名称' "ShadowTLS-v${version}-${method_label}")
  port=$(prompt_port t "$(node_port)")
  target=$(ui_prompt '握手域名' 'www.microsoft.com')
  stpw=$(ui_prompt 'ShadowTLS 密码' "$(node_secret)")
  case "$method" in 2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) sspw=$(node_secret_base64 32);; *) sspw=$(ui_prompt 'Shadowsocks 密码' "$(node_secret)");; esac
  ssport=$(node_port); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"
  jq -n --arg tag "$tag" --arg ss "$tag-ss" --arg name "$name" --arg target "$target" --arg stpw "$stpw" --arg method "$method" --arg method_label "$method_label" --arg sspw "$sspw" --argjson port "$port" --argjson ssport "$ssport" --argjson version "$version" \
    '{tag:$tag,name:$name,kind:"shadowtls-shadowsocks",port:$port,tls_mode:"shadowtls",meta:{shadowtls_password:$stpw,method:$method,method_label:$method_label,password:$sspw,handshake:$target,version:$version},inbound:({type:"shadowtls",tag:$tag,listen:"::",listen_port:$port,version:$version,handshake:{server:$target,server_port:443},detour:$ss} | if $version==2 then .password=$stpw else .users=[{name:"default",password:$stpw}] end),embedded_inbounds:[{type:"shadowsocks",tag:$ss,listen:"127.0.0.1",listen_port:$ssport,method:$method,password:$sspw}]}' >"$f"
  server_save_and_apply "$f" tcp
}

create_snell(){
  local mode name port psk tag f
  ui_title 'Snell v6'
  ui_menu 1 'default' 2 'unshaped' 3 'unsafe-raw'
  ui_back; ui_footer
  while :; do
    case $(ui_prompt '请选择流量整形模式') in
      1) mode='default'; break ;;
      2) mode='unshaped'; break ;;
      3) mode='unsafe-raw'; break ;;
      0) return ;;
      *) ui_invalid ;;
    esac
  done
  name=$(ui_prompt '节点名称' 'Snell-v6'); port=$(prompt_port t "$(node_port)")
  while :; do psk=$(ui_prompt 'PSK (12-255 字节)' "$(node_secret)"); [ ${#psk} -ge 12 ] && [ ${#psk} -le 255 ] && break; ui_warn 'PSK 长度必须为 12-255 字节'; done
  tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"
  jq -n --arg tag "$tag" --arg name "$name" --arg psk "$psk" --arg mode "$mode" --argjson port "$port" \
    '{tag:$tag,name:$name,kind:"snell",port:$port,tls_mode:"none",meta:{psk:$psk,version:6,mode:$mode},inbound:{type:"snell",tag:$tag,listen:"::",listen_port:$port,version:6,psk:$psk,mode:$mode}}' >"$f"
  server_save_and_apply "$f" tcp
}

create_socks5(){
  local name user pw port tag f; ui_title 'SOCKS5'; name=$(ui_prompt '节点名称' 'SOCKS5'); user=$(ui_prompt '用户名' 'admin'); pw=$(ui_prompt '密码' "$(node_secret)"); port=$(prompt_port t "$(node_port)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"
  jq -n --arg tag "$tag" --arg name "$name" --arg user "$user" --arg pw "$pw" --argjson port "$port" '{tag:$tag,name:$name,kind:"socks5",port:$port,tls_mode:"none",meta:{username:$user,password:$pw},inbound:{type:"socks",tag:$tag,listen:"::",listen_port:$port,users:[{username:$user,password:$pw}]}}' >"$f"; server_save_and_apply "$f" tcp
}
create_hysteria2(){
  local profile obfs_mode obfs_pw name port pw tag f tls up down tlsmode
  ui_title 'Hysteria2'
  ui_tell '  拥塞控制'
  ui_menu 1 'conservative' 2 'standard' 3 'aggressive' 4 'brutal'
  ui_back; ui_footer
  while :; do
    case $(ui_prompt '请选择拥塞控制') in
      1) profile='conservative'; break ;;
      2) profile='standard'; break ;;
      3) profile='aggressive'; break ;;
      4) profile='brutal'; break ;;
      0) return ;;
      *) ui_invalid ;;
    esac
  done
  ui_clear
  ui_title "Hysteria2 / ${profile}"
  if ui_yes '是否开启混淆'; then
    ui_tell '  1. salamander'
    ui_tell '  2. gecko'
    while :; do
      case $(ui_prompt '请选择混淆类型') in
        1) obfs_mode='salamander'; break ;;
        2) obfs_mode='gecko'; break ;;
        0) return ;;
        *) ui_invalid ;;
      esac
    done
    obfs_pw=$(ui_prompt '混淆密码' "$(node_secret)")
  else
    obfs_mode=''; obfs_pw=''
  fi
  name=$(ui_prompt '节点名称' "Hysteria2-${profile}"); server_prompt_tls || return; port=$(prompt_port u "$(node_port)"); tlsmode=${TLS_MODE:-cert}; pw=$(ui_prompt '密码' "$(node_secret)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"; tls=$(server_tls_json)
  if [ "$profile" = brutal ]; then
    up=$(ui_prompt '上行带宽 Mbps' '100'); down=$(ui_prompt '下行带宽 Mbps' '100')
  fi
  jq -n --arg tag "$tag" --arg name "$name" --arg pw "$pw" --arg profile "$profile" --arg obfs "$obfs_mode" --arg obfs_pw "$obfs_pw" --arg tlsmode "$tlsmode" --argjson port "$port" --argjson tls "$tls" --argjson up "${up:-0}" --argjson down "${down:-0}" \
    '{tag:$tag,name:$name,kind:"hysteria2",port:$port,tls_mode:$tlsmode,meta:{password:$pw,bbr_profile:(if $profile=="brutal" then "" else $profile end),congestion:$profile,up_mbps:(if $profile=="brutal" then $up else 0 end),down_mbps:(if $profile=="brutal" then $down else 0 end),obfs:$obfs,obfs_password:$obfs_pw},inbound:({type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pw}],tls:$tls} | if $profile=="brutal" then .up_mbps=$up|.down_mbps=$down|.brutal_debug=false else .bbr_profile=$profile end | if $obfs!="" then .obfs={type:$obfs,password:$obfs_pw} else . end)}' >"$f"
  server_save_and_apply "$f" tcp
}

create_tuic(){
  local cc name port uuid pw tag f tls tlsmode
  ui_title 'TUIC'
  ui_tell '  拥塞控制'
  ui_menu 1 'CUBIC' 2 'New Reno' 3 'BBR'
  ui_back; ui_footer
  while :; do
    case $(ui_prompt '请选择拥塞控制') in
      1) cc='cubic'; break ;;
      2) cc='new_reno'; break ;;
      3) cc='bbr'; break ;;
      0) return ;;
      *) ui_invalid ;;
    esac
  done
  name=$(ui_prompt '节点名称' "TUIC-${cc}"); server_prompt_tls || return; port=$(prompt_port u "$(node_port)"); tlsmode=${TLS_MODE:-cert}; uuid=$(ui_prompt 'UUID' "$(node_uuid)"); pw=$(ui_prompt '密码' "$(node_secret)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"; tls=$(server_tls_json)
  jq -n --arg tag "$tag" --arg name "$name" --arg uuid "$uuid" --arg pw "$pw" --arg cc "$cc" --arg tlsmode "$tlsmode" --argjson port "$port" --argjson tls "$tls" \
    '{tag:$tag,name:$name,kind:"tuic",port:$port,tls_mode:$tlsmode,meta:{uuid:$uuid,password:$pw,congestion_control:$cc},inbound:{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$pw}],congestion_control:$cc,tls:$tls}}' >"$f"
  server_save_and_apply "$f" tcp
}

create_anytls(){
  local name port pw tag f tls tlsmode; ui_title 'AnyTLS'; name=$(ui_prompt '节点名称' 'AnyTLS'); server_prompt_tls || return; port=$(prompt_port t "$(node_port)"); pw=$(ui_prompt '密码' "$(node_secret)"); tag=$(protocol_new_file "$name") || return; f="$NODE_DIR/$tag.json"; tls=$(server_tls_json); tlsmode=${TLS_MODE:-cert}
  jq -n --arg tag "$tag" --arg name "$name" --arg pw "$pw" --arg tlsmode "$tlsmode" --argjson port "$port" --argjson tls "$tls" '{tag:$tag,name:$name,kind:"anytls",port:$port,tls_mode:$tlsmode,meta:{password:$pw},inbound:{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pw}],tls:$tls}}' >"$f"; server_save_and_apply "$f" tcp
}

# ===== MODULE: server/protocol-menu.sh =====
menu_create_protocol(){
  while :; do
    ui_title '创建协议'
    ui_menu 1 'VLESS' 2 'VMess' 3 'Trojan' 4 'Shadowsocks' 5 'ShadowTLS + Shadowsocks' 6 'Snell' 7 'SOCKS5' 8 'Hysteria2' 9 'TUIC' 10 'AnyTLS'
    ui_back; ui_footer
    case $(ui_prompt '请选择') in
      1) menu_vless; return 0 ;;
      2) menu_vmess; return 0 ;;
      3) menu_trojan; return 0 ;;
      4) create_shadowsocks; return 0 ;;
      5) create_shadowtls; return 0 ;;
      6) create_snell; return 0 ;;
      7) create_socks5; return 0 ;;
      8) create_hysteria2; return 0 ;;
      9) create_tuic; return 0 ;;
      10) create_anytls; return 0 ;;
      0) break ;;
      *) ui_invalid ;;
    esac
  done
}

menu_vless(){
  while :; do
    ui_title 'VLESS'
    ui_menu 1 'TCP + TLS' 2 'TCP + Reality' 3 'WS + CDN' 4 'gRPC + CDN' 5 'HTTPUpgrade + CDN'
    ui_back; ui_footer
    case $(ui_prompt '请选择') in
      1) create_vless_tcp_tls; break ;;
      2) create_vless_reality; break ;;
      3) create_vless_transport ws; break ;;
      4) create_vless_transport grpc; break ;;
      5) create_vless_transport httpupgrade; break ;;
      0) break ;;
      *) ui_invalid ;;
    esac
  done
}

menu_vmess(){
  while :; do
    ui_title 'VMess'
    ui_menu 1 'TCP' 2 'WS + CDN' 3 'gRPC + CDN'
    ui_back; ui_footer
    case $(ui_prompt '请选择') in
      1) create_vmess_tcp; break ;;
      2) create_vmess_transport ws; break ;;
      3) create_vmess_transport grpc; break ;;
      0) break ;;
      *) ui_invalid ;;
    esac
  done
}

menu_trojan(){
  while :; do
    ui_title 'Trojan'
    ui_menu 1 'TCP + TLS' 2 'WS + CDN' 3 'gRPC + CDN'
    ui_back; ui_footer
    case $(ui_prompt '请选择') in
      1) create_trojan_tcp_tls; break ;;
      2) create_trojan_transport ws; break ;;
      3) create_trojan_transport grpc; break ;;
      0) break ;;
      *) ui_invalid ;;
    esac
  done
}

# ===== MODULE: server/menu.sh =====

select_node(){
  local files=() file i=1 n tcp_list udp_list proto
  mapfile -t files < <(node_list)
  ui_clear
  ui_tell "${UI_CYAN}========== 节点列表 ==========${UI_PLAIN}"
  [ ${#files[@]} -gt 0 ] || { ui_tell '  暂无节点'; ui_wait; return 1; }
  tcp_list=$(listening_ports t 2>/dev/null || true); udp_list=$(listening_ports u 2>/dev/null || true)
  for file in "${files[@]}"; do
    local name port kind state
    name=$(jq -r '.name // .tag' "$NODE_DIR/$file" 2>/dev/null)
    port=$(jq -r '.port // .inbound.listen_port // "-"' "$NODE_DIR/$file" 2>/dev/null)
    kind=$(jq -r '.kind // .inbound.type // "-"' "$NODE_DIR/$file" 2>/dev/null)
    proto=$(jq -r '.proto // (if (.kind=="hysteria2" or .kind=="tuic") then "u" else "t" end)' "$NODE_DIR/$file" 2>/dev/null)
    state="${UI_RED}异常${UI_PLAIN}"
    if core_status >/dev/null 2>&1 && { [ "$proto" = u ] && grep -qx "$port" <<<"$udp_list" || [ "$proto" != u ] && grep -qx "$port" <<<"$tcp_list"; }; then
      state="${UI_GREEN}正常${UI_PLAIN}"
    fi
    ui_tell "  $i. [$kind] $name:$port [$state]"
    i=$((i+1))
  done
  ui_tell '  0. 返回'
  n=$(ui_prompt '请选择')
  [ "$n" = 0 ] && return 1
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -lt "$i" ] || { ui_invalid; return 1; }
  PICKED="$NODE_DIR/${files[$((n-1))]}"
  return 0
}

server_port_in_use(){
  local proto=$1 port=$2 current=${3:-}
  [ -n "$current" ] && [ "$port" = "$current" ] && return 1
  if command -v ss >/dev/null 2>&1; then
    if [ "$proto" = u ]; then
      ss -Hlun 2>/dev/null | awk -v p=":$port$" '$5 ~ p{found=1} END{exit !found}' && return 0
    else
      ss -Hltn 2>/dev/null | awk -v p=":$port$" '$4 ~ p{found=1} END{exit !found}' && return 0
    fi
  fi
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.port // .inbound.listen_port // empty' "$f" 2>/dev/null)" = "$port" ] && return 0
  done < <(node_list 2>/dev/null | sed "s#^#$NODE_DIR/#")
  return 1
}

listening_ports(){
  case ${1:-t} in
    u) ss -Hlun 2>/dev/null | awk '{print $5}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -nu;;
    *) ss -Hltn 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -nu;;
  esac
}

prompt_port(){
  local proto=$1 def=${2:-} p
  while :; do
    p=$(ui_prompt '监听端口' "$def")
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
      if server_port_in_use "$proto" "$p" "$def"; then
        ui_warn '端口已被占用，请重新输入'
      else
        printf '%s' "$p"; return 0
      fi
    else
      ui_warn '端口无效，请输入 1-65535'
    fi
  done
}

menu_server(){
  local previous
  while :; do
    ui_clear
    ui_tell "${UI_CYAN}========== 服务端管理 ==========${UI_PLAIN}"
    ui_tell '  1. 创建协议'
    ui_tell '  2. 删除协议'
    ui_tell '  3. 修改配置'
    ui_tell '  4. 服务端信息'
    ui_tell '  5. 更换域名'
    ui_tell '  6. 重启服务'
    ui_tell '  7. 停止服务'
    ui_tell '  0. 返回'
    ui_tell "${UI_CYAN}================================${UI_PLAIN}"
    case $(ui_prompt '请选择') in
      1) menu_create_protocol ;;
      2) menu_delete_protocol ;;
      3) menu_modify_protocol ;;
      4) menu_server_info ;;
      5) menu_change_domain ;;
      6)
        if core_restart >/dev/null 2>&1; then ui_ok '已重启'; else ui_warn 'singbox 未运行'; ui_warn '重启失败'; fi
        ui_wait ;;
      7)
        if core_stop >/dev/null 2>&1; then
          ui_ok '已停止'
        else
          ui_warn '停止失败'
        fi
        ui_wait ;;
      0) break ;;
      *) ui_invalid ;;
    esac
  done
}

menu_server_info(){
  local file port proto status count=0 tcp_list udp_list
  tcp_list=$(listening_ports t 2>/dev/null || true)
  udp_list=$(listening_ports u 2>/dev/null || true)
  ui_clear
  ui_tell "${UI_CYAN}========== 服务端信息 ==========${UI_PLAIN}"
  if core_status >/dev/null 2>&1; then ui_ok 'singbox: 正常运行'; else ui_warn 'singbox: 未运行'; fi
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    count=$((count+1)); port=$(jq -r .port "$file" 2>/dev/null); proto=$(jq -r '.proto // (if (.kind=="hysteria2" or .kind=="tuic") then "u" else "t" end)' "$file" 2>/dev/null)
    if [ "$proto" = u ]; then
      grep -qx "$port" <<<"$udp_list" && status="${UI_GREEN}正常监听${UI_PLAIN}" || status="${UI_RED}未在监听${UI_PLAIN}"
    else
      grep -qx "$port" <<<"$tcp_list" && status="${UI_GREEN}正常监听${UI_PLAIN}" || status="${UI_RED}未在监听${UI_PLAIN}"
    fi
    ui_tell ''
    ui_tell "── $(jq -r .name "$file" 2>/dev/null) [$(jq -r .kind "$file" 2>/dev/null)] | 端口 $port $status"
    if declare -F render_share_uri >/dev/null 2>&1; then render_share_uri "$file"; fi
  done
  [ "$count" = 0 ] && ui_tell '  暂无节点'
  if declare -F render_certificate_status >/dev/null 2>&1; then render_certificate_status; fi
  ui_wait
}

menu_change_domain(){
  local new_domain old_domain email mode cf_token ali_key ali_secret acmedns_url acmedns_user acmedns_pass acmedns_sub old_state_file tmp pid log_file
  local old_files=() file count=0
  ui_clear
  ui_tell "${UI_CYAN}========== 更换域名 ==========${UI_PLAIN}"
  old_domain=$(state_get domain 2>/dev/null || true)
  ui_tell "  当前域名: ${old_domain:-未设置}"
  ui_tell '  绑定节点:'
  for file in "$NODE_DIR"/*.json; do
    [ -e "$file" ] || continue
    if [ "$(jq -r '.tls_mode // empty' "$file" 2>/dev/null)" = acme ]; then
      old_files+=("$file"); count=$((count+1))
      ui_tell "  - $(jq -r '.name // .tag' "$file") [$(jq -r '.kind' "$file")]"
    fi
  done
  [ "$count" -gt 0 ] || { ui_tell '  无'; ui_warn '当前没有使用 ACME 域名证书的节点'; ui_wait; return; }
  ui_tell ''
  new_domain=$(ui_prompt '新域名 (留空取消)')
  [ -n "$new_domain" ] || return
  [ "$new_domain" != "$old_domain" ] || { ui_warn '新域名与当前域名相同'; ui_wait; return; }

  if ! command -v "$SING_BOX_BIN" >/dev/null 2>&1 && ! command -v sing-box >/dev/null 2>&1; then
    ui_warn '未找到 sing-box，无法签发新证书'; ui_wait; return
  fi
  local sb=${SING_BOX_BIN:-sing-box}
  local tags
  tags=$("$sb" version 2>/dev/null || true)
  [[ "$tags" == *with_acme* ]] || { ui_warn '当前 sing-box 未包含 with_acme，无法使用 ACME'; ui_wait; return; }

  email=$(ui_prompt 'ACME 通知邮箱' "$(state_get email 2>/dev/null || printf 'admin@%s' "$new_domain")")
  [ -n "$email" ] || return
  ui_tell ''
  ui_tell "${UI_CYAN}选择证书验证方式:${UI_PLAIN}"
  ui_tell '  1. HTTP         (推荐 需放行80端口)'
  ui_tell '  2. TLS-ALPN     (推荐 需放行443端口)'
  ui_tell '  3. Cloudflare API'
  ui_tell '  4. 阿里云 DNS API'
  ui_tell '  5. ACME-DNS API'
  mode=http; cf_token=''; ali_key=''; ali_secret=''; acmedns_url=''; acmedns_user=''; acmedns_pass=''; acmedns_sub=''
  while :; do
    case $(ui_prompt '请选择方式' 1) in
      1) mode=http; break;;
      2) mode=alpn; break;;
      3) mode=dns_cloudflare; cf_token=$(ui_prompt 'Cloudflare API Token'); [ -n "$cf_token" ] && break;;
      4) mode=dns_alidns; ali_key=$(ui_prompt 'AccessKeyId'); ali_secret=$(ui_prompt 'AccessKeySecret'); [ -n "$ali_key" ] && [ -n "$ali_secret" ] && break;;
      5) ui_warn '当前 sing-box 1.14 官方 ACME DNS-01 仅内置 Cloudflare / Alibaba Cloud DNS；ACME-DNS 入口暂不执行，以免生成不可用配置'; sleep 1;;
      *) ui_invalid;;
    esac
  done

  old_state_file=$(mktemp) || { ui_warn '状态快照创建失败'; ui_wait; return; }; state_snapshot "$old_state_file" || { rm -f "$old_state_file"; ui_warn '状态快照失败'; ui_wait; return; }
  tmp=$(mktemp) || { ui_warn '临时配置创建失败'; ui_wait; return; }
  local provider
  provider=$(jq -n --arg d "$new_domain" --arg e "$email" --arg dir "$ACME_DIR" --arg mode "$mode" --arg cf "$cf_token" --arg ak "$ali_key" --arg as "$ali_secret" '
    {type:"acme",tag:"acme-temporary",domain:[$d],default_server_name:$d,email:$e,data_directory:$dir,key_type:"p256"}
    | if $mode=="http" then .disable_tls_alpn_challenge=true
      elif $mode=="alpn" then .disable_http_challenge=true
      elif $mode=="dns_cloudflare" then .dns01_challenge={provider:"cloudflare",api_token:$cf}
      elif $mode=="dns_alidns" then .dns01_challenge={provider:"alidns",access_key_id:$ak,access_key_secret:$as}
      else . end') || { rm -f "$tmp"; ui_warn 'ACME 配置生成失败'; ui_wait; return; }
  jq -n --argjson p "$provider" '{log:{level:"warn"},certificate_providers:[$p]}' >"$tmp" || { rm -f "$tmp"; ui_warn 'ACME 临时配置写入失败'; ui_wait; return; }
  if ! "$sb" check -c "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; ui_warn '新域名 ACME 配置校验失败'; ui_wait; return
  fi
  log_file=$(mktemp) || { rm -f "$tmp"; ui_warn '证书日志文件创建失败'; ui_wait; return; }
  "$sb" run -c "$tmp" >"$log_file" 2>&1 & pid=$!
  ui_tell "等待证书签发完成: $new_domain"
  local ready=0 cert
  for _ in $(seq 1 180); do
    while IFS= read -r cert; do
      [ -f "$cert" ] || continue
      if command -v openssl >/dev/null 2>&1 && openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -Eq "DNS:$new_domain([, ]|$)"; then
        ready=1; break 2
      fi
    done < <(find "$ACME_DIR" -type f \( -name '*.crt' -o -name '*.pem' \) -print 2>/dev/null)
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  if [ "$ready" != 1 ]; then
    ui_warn '新域名证书未成功签发，已保持旧配置'
    [ -s "$log_file" ] && tail -n 12 "$log_file" >&2 || true
    rm -f "$tmp" "$log_file" "$old_state_file"
    ui_wait; return
  fi

  state_set domain "$new_domain" || { rm -f "$tmp" "$log_file"; ui_warn '新域名写入失败'; ui_wait; return; }
  state_set email "$email" || true
  state_set challenge "$mode" || true
  state_set cf_token "$cf_token" || true
  state_set ali_key "$ali_key" || true
  state_set ali_secret "$ali_secret" || true
  if ! apply_config; then
    state_restore "$old_state_file" || true
    apply_config_quiet >/dev/null 2>&1 || true
    rm -f "$tmp" "$log_file" "$old_state_file"
    ui_warn '新域名配置应用失败，已恢复旧配置'; ui_wait; return
  fi
  rm -f "$tmp" "$log_file" "$old_state_file"
  ui_ok "域名已切换为: $new_domain"
  ui_ok '所有 ACME 节点已同步使用新域名'
  ui_wait
}

menu_delete_protocol(){
  ui_clear
  ui_tell "${UI_CYAN}========== 删除协议 ==========${UI_PLAIN}"
  select_node || return
  ui_yes "确认删除 $(jq -r .name "$PICKED")" || return
  local old_json previous_exit tag
  old_json=$(cat "$PICKED")
  previous_exit=$(state_get exit)
  tag=$(jq -r .tag "$PICKED")
  if [ "$tag" = "$previous_exit" ]; then state_set exit direct && sync_proxy_env; fi
  rm -f "$PICKED"
  if apply_config_quiet; then
    ui_ok '已删除'
  else
    printf '%s\n' "$old_json" >"$PICKED"
    state_set exit "$previous_exit" && sync_proxy_env
    apply_config_quiet >/dev/null 2>&1 || true
    ui_warn '删除导致配置异常，已安全回滚'
  fi
  ui_wait
}

menu_modify_protocol(){
  local kind value old_json
  ui_clear
  ui_tell "${UI_CYAN}========== 修改配置 ==========${UI_PLAIN}"
  select_node || return
  while :; do
    kind=$(jq -r '.kind // .inbound.type // "unknown"' "$PICKED")
    ui_clear
    ui_tell "${UI_CYAN}========== $(jq -r .name "$PICKED") [$kind] ==========${UI_PLAIN}"
    ui_tell '  1. 识别名称'
    ui_tell '  2. 监听端口'
    case "$kind" in
      vless) ui_tell '  3. 通信 UUID'; ui_tell '  4. 连接密码' ;;
      vmess) ui_tell '  3. 通信 UUID' ;;
      trojan|anytls|hysteria2|tuic|shadowsocks|shadowtls-shadowsocks|socks5|snell) ui_tell '  3. 连接密码' ;;
    esac
    ui_tell '  0. 返回'
    ui_tell "${UI_CYAN}==============================${UI_PLAIN}"
    old_json=$(cat "$PICKED")
    case $(ui_prompt '请选择') in
      1)
        value=$(ui_prompt '新识别名称' "$(jq -r .name "$PICKED")")
        [ -n "$value" ] || continue
        jq --arg v "$value" '.name=$v' "$PICKED" >"$PICKED.tmp" && mv -f "$PICKED.tmp" "$PICKED" || { ui_warn '修改失败'; ui_wait; continue; }
        ;;
      2)
        value=$(prompt_port "$(jq -r '.proto // (if (.kind=="hysteria2" or .kind=="tuic") then "u" else "t" end)' "$PICKED")" "$(jq -r '.port // .inbound.listen_port' "$PICKED")") || continue
        jq --argjson v "$value" '.port=$v|.inbound.listen_port=$v' "$PICKED" >"$PICKED.tmp" && mv -f "$PICKED.tmp" "$PICKED" || { ui_warn '修改失败'; ui_wait; continue; }
        ;;
      3)
        value=$(ui_prompt '新连接密码 / UUID / PSK' '')
        [ -n "$value" ] || continue
        jq --arg v "$value" '
          if .kind=="vless" or .kind=="vmess" then .meta.uuid=$v|.inbound.users[0].uuid=$v
          elif .kind=="snell" then .meta.psk=$v|.inbound.psk=$v
          elif .kind=="socks5" then .meta.password=$v|.inbound.users[0].password=$v
          elif .kind=="shadowsocks" then .meta.password=$v|.inbound.password=$v
          elif .kind=="shadowtls-shadowsocks" then .meta.shadowtls_password=$v|.meta.password=$v|if .inbound.version==2 then .inbound.password=$v else .inbound.users[0].password=$v end
          else .meta.password=$v|.inbound.users[0].password=$v end' "$PICKED" >"$PICKED.tmp" && mv -f "$PICKED.tmp" "$PICKED" || { ui_warn '修改失败'; ui_wait; continue; }
        ;;
      4)
        value=$(ui_prompt '鉴权账号 / 连接密码' '')
        [ -n "$value" ] || continue
        jq --arg v "$value" 'if .kind=="socks5" then .meta.username=$v|.inbound.users[0].username=$v elif .kind=="shadowsocks" then .meta.password=$v|.inbound.password=$v elif .kind=="shadowtls-shadowsocks" then .meta.password=$v|.embedded_inbounds[0].password=$v else .meta.password=$v|.inbound.users[0].password=$v end' "$PICKED" >"$PICKED.tmp" && mv -f "$PICKED.tmp" "$PICKED" || { ui_warn '修改失败'; ui_wait; continue; }
        ;;
      0) return ;;
      *) ui_invalid; continue ;;
    esac
    if apply_config_quiet; then ui_ok '已生效'; else printf '%s\n' "$old_json" >"$PICKED"; apply_config_quiet >/dev/null 2>&1 || true; ui_warn '配置冲突或校验失败，已回滚'; fi
    ui_wait
  done
}

# ===== MODULE: client/menu.sh =====
menu_client(){
  while :; do
    ui_clear
    ui_tell "${UI_CYAN}========== 客户端管理 ==========${UI_PLAIN}"
    ui_tell "  当前出口: ${UI_YELLOW}$(exit_label)${UI_PLAIN}"
    ui_tell ''
    ui_tell '  1. 添加节点'
    ui_tell '  2. 节点选择'
    ui_tell '  3. 删除节点'
    ui_tell '  4. 停止代理'
    ui_tell '  5. 客户端状态'
    ui_tell '  0. 返回'
    ui_tell "${UI_CYAN}================================${UI_PLAIN}"
    case $(ui_prompt '请选择') in
      1) peer_add ;;
      2) peer_select ;;
      3) peer_delete ;;
      4) peer_stop ;;
      5) menu_client_status ;;
      0) break ;;
      *) ui_invalid ;;
    esac
  done
}

menu_client_status(){
  ui_clear
  ui_tell "${UI_CYAN}========== 客户端状态 ==========${UI_PLAIN}"
  local exit_node proxy_name protocol
  exit_node=$(state_get exit 2>/dev/null || printf direct)
  proxy_name='直连'
  protocol=''
  if [ "$exit_node" != direct ] && [ -f "$PEER_DIR/$exit_node.json" ]; then
    proxy_name=$(jq -r '.name // .tag // "未知"' "$PEER_DIR/$exit_node.json" 2>/dev/null)
    protocol=$(jq -r '.outbound.type // ""' "$PEER_DIR/$exit_node.json" 2>/dev/null)
    case "$protocol" in
      vless) protocol='VLESS' ;;
      vmess) protocol='VMess' ;;
      hysteria2) protocol='Hysteria2' ;;
      tuic) protocol='TUIC' ;;
      trojan) protocol='Trojan' ;;
      shadowsocks) protocol='Shadowsocks' ;;
      socks) protocol='SOCKS' ;;
      http) protocol='HTTP' ;;
      *) protocol="${protocol:-未知}" ;;
    esac
    proxy_name="$proxy_name $protocol"
  elif [ "$exit_node" = warp-system ]; then
    proxy_name='WARP'
  fi
  ui_tell "  网络接管：${UI_CYAN}${proxy_name}${UI_PLAIN}"
  ui_tell ''
  render_client_ip_status
  ui_wait
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
    IP_INFO_IP="$ip"; IP_INFO_C="$country"; IP_INFO_ASN="$asn"; IP_INFO_NAME="$name"
  else
    IP_INFO_IP=''; IP_INFO_C=''; IP_INFO_ASN=''; IP_INFO_NAME=''
  fi
}

render_client_ip_status(){
  get_ip_info 4
  if [ -n "$IP_INFO_IP" ]; then
    printf '  IPv4: '; ui_ip "$IP_INFO_IP"; printf ' | 地区: %b%s%b\n' "$UI_YELLOW" "$IP_INFO_C" "$UI_PLAIN"
    ui_tell "  所属: ${UI_CYAN}${IP_INFO_NAME}${UI_PLAIN} | ASN: ${UI_PURPLE}${IP_INFO_ASN}${UI_PLAIN}"
  else
    ui_tell "  IPv4: ${UI_RED}无或不可用${UI_PLAIN}"
  fi
  get_ip_info 6
  if [ -n "$IP_INFO_IP" ]; then
    printf '  IPv6: '; ui_ip "$IP_INFO_IP"; printf ' | 地区: %b%s%b\n' "$UI_YELLOW" "$IP_INFO_C" "$UI_PLAIN"
    ui_tell "  所属: ${UI_CYAN}${IP_INFO_NAME}${UI_PLAIN} | ASN: ${UI_PURPLE}${IP_INFO_ASN}${UI_PLAIN}"
  else
    ui_tell "  IPv6: ${UI_RED}无或不可用${UI_PLAIN}"
  fi
}

# ===== MODULE: warp/menu.sh =====
menu_warp(){
  while :; do
    ui_title 'WARP 管理'
    ui_menu 1 '注册 WARP' 2 '获取 WARP 出口' 3 '查看 WARP 配置' 4 '删除 WARP 配置'
    ui_back; ui_footer
    case $(ui_prompt '请选择') in
      1) warp_register;;
      2) warp_get_exit;;
      3) warp_show_config;;
      4) warp_delete_config;;
      0) break;;
      *) ui_invalid;;
    esac
  done
}

# ===== MODULE: bin/main-menu.sh =====
menu_main(){
  while :; do
    ui_clear
    ui_tell "${UI_CYAN}================================${UI_PLAIN}"
    ui_tell "${UI_CYAN}             s管理              ${UI_PLAIN}"
    ui_tell "${UI_CYAN}      [ 仅适配 Systemd ]        ${UI_PLAIN}"
    ui_tell "${UI_CYAN}================================${UI_PLAIN}"
    ui_tell '  1. 服务端管理'
    ui_tell '  2. 客户端管理'
    ui_tell '  3. WARP 管理'
    ui_tell '  4. 状态与更新'
    ui_tell '  0. 退出'
    ui_tell "${UI_CYAN}================================${UI_PLAIN}"
    case $(ui_prompt '请选择') in
      1) menu_server ;;
      2) menu_client ;;
      3) menu_warp ;;
      4) menu_status ;;
      0) ui_clear; return 0 ;;
      *) ui_invalid ;;
    esac
  done
}

# ===== MODULE: standalone-entry =====
standalone_bootstrap(){
  environment_detect || return 1
  package_prepare || { printf '依赖准备失败，无法继续。\n' >&2; return 1; }
  core_ensure || { printf 'sing-box 内核准备失败，无法继续。\n' >&2; return 1; }
  proxy_mode_detect || return 1
  state_init || return 1
  config_init || return 1
  client_init || return 1
  mkdir -p "$ACME_DIR" && chmod 700 "$ACME_DIR" || return 1
  SING_BOX_CONFIG=$config_file
  export SING_BOX_CONFIG
  EXIT_TAG=$(state_get exit 2>/dev/null || printf direct)
  export EXIT_TAG
}
standalone_main(){
  trap 'ui_clear >/dev/null 2>&1 || true; exit 130' INT TERM HUP
  standalone_bootstrap || exit 1
  entrypoint_install || exit 1
  if [ "${KVM_NONINTERACTIVE:-0}" = 1 ]; then
    printf 'OS=%s\nARCH=%s\nVIRT=%s\nINIT=%s\nMODE=%s\nTUN=%s\nNFT=%s\nIPTABLES=%s\nIP=%s\nNET_ADMIN=%s\n' "$ENV_OS" "$ENV_ARCH" "$ENV_VIRT" "$ENV_INIT" "$PROXY_MODE" "$CAP_TUN" "$CAP_NFT" "$CAP_IPTABLES" "$CAP_IP" "$CAP_NET_ADMIN"
    return 0
  fi
  menu_main
}
standalone_main "$@"
