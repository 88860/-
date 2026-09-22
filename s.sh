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
state_root=${KVM_STATE_ROOT:-/var/lib/kvm-new}; state_file=${KVM_STATE_FILE:-$state_root/state.env}
state_init(){ mkdir -p "$state_root" || return 1; [ -f "$state_file" ] || : >"$state_file"; chmod 600 "$state_file"; }
state_get(){ local key=$1; [ -f "$state_file" ]||return 1; awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$state_file"; }
state_set(){ local key=$1 value=$2 tmp; state_init||return 1; tmp=$(mktemp "$state_root/.state.XXXXXX")||return 1; awk -F= -v k="$key" '$1!=k' "$state_file">"$tmp"; printf '%s=%s\n' "$key" "$value">>"$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$state_file"; }
state_unset(){ state_set "$1" '' >/dev/null; }
state_snapshot(){ state_init&&cp -p "$state_file" "$1"; }
state_restore(){ [ -f "$1" ]&&state_init&&cp -p "$1" "$state_file"; }

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
    systemd) systemctl stop "$n.service" 2>/dev/null || true;;
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
core_version(){ core_has && "$SING_BOX_BIN" version; }
core_check(){ core_has&&[ -f "${1:-$SING_BOX_CONFIG}" ]&&"$SING_BOX_BIN" check -c "${1:-$SING_BOX_CONFIG}"; }
core_asset_arch(){ case "${ENV_ARCH:-$(uname -m)}" in x86_64|amd64) printf amd64;; aarch64|arm64) printf arm64;; armv7l|armv7) printf armv7;; armv6l|armv6) printf armv6;; i386|i686) printf 386;; riscv64) printf riscv64;; *) return 1;; esac; }
core_libc_suffix(){ if [ -f /etc/alpine-release ] || (command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl); then printf -- '-musl'; fi; }
core_release_json(){
  local fetch=${1:-curl}
  case "$fetch" in
    curl) curl -fsSL --retry 2 --connect-timeout 8 --max-time 30 "$CORE_RELEASE_API";;
    wget) wget -qO- --tries=2 --timeout=8 "$CORE_RELEASE_API";;
    *) return 1;;
  esac
}
core_install(){
  core_has && return 0
  local fetch url json version arch suffix pattern tmp archive extracted expected
  if command -v curl >/dev/null 2>&1; then fetch=curl; elif command -v wget >/dev/null 2>&1; then fetch=wget; else fetch=; fi
  [ -n "$fetch" ] || { printf '缺少 curl/wget，无法安装 sing-box\n' >&2; return 1; }
  arch=$(core_asset_arch) || { printf '不支持的架构: %s\n' "${ENV_ARCH:-$(uname -m)}" >&2; return 1; }
  suffix=$(core_libc_suffix); json=$(core_release_json "$fetch") || return 1
  version=$(jq -r '.tag_name // empty' <<<"$json")
  [ -n "$version" ] || return 1
  pattern="linux-${arch}${suffix}.tar.gz"
  url=$(jq -r --arg p "$pattern" '.assets[]? | select(.name | endswith($p)) | .browser_download_url' <<<"$json" | head -n1)
  expected=$(jq -r --arg p "$pattern" '.assets[]? | select(.name | endswith($p)) | (.digest // "")' <<<"$json" | head -n1)
  [ -n "$url" ] || { printf '未找到 sing-box 资产: %s\n' "$pattern" >&2; return 1; }
  tmp=$(mktemp -d /tmp/kvm-singbox.XXXXXX) || return 1
  archive="$tmp/sing-box.tar.gz"
  if [ "$fetch" = curl ]; then curl -fsSL --retry 2 --connect-timeout 8 --max-time 180 "$url" -o "$archive" 2>/dev/null || { rm -rf "$tmp"; return 1; }; else wget -qO "$archive" --tries=2 --timeout=8 "$url" 2>/dev/null || { rm -rf "$tmp"; return 1; }; fi
  if [[ "$expected" == sha256:* ]] && command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "${expected#sha256:}" "$archive" | sha256sum -c - >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  fi
  tar -xzf "$archive" -C "$tmp" || { rm -rf "$tmp"; return 1; }
  extracted=$(find "$tmp" -type f -name sing-box -perm -u+x -print -quit 2>/dev/null)
  [ -n "$extracted" ] || { rm -rf "$tmp"; return 1; }
  install -m755 "$extracted" "$SING_BOX_BIN" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  sync 2>/dev/null || true
  if [ -w /proc/sys/vm/drop_caches ]; then echo 1 >/proc/sys/vm/drop_caches 2>/dev/null || true; fi
  core_has || return 1
  printf 'sing-box %s installed\n' "$(core_version 2>/dev/null | head -n1)" >&2
}
core_ensure(){ core_has && return 0; core_install; }
core_start(){ runtime_start "$SING_BOX_SERVICE"; }
core_stop(){ runtime_stop "$SING_BOX_SERVICE"; }
core_restart(){ runtime_restart "$SING_BOX_SERVICE"; }
core_reload(){ runtime_reload "$SING_BOX_SERVICE"; }
core_status(){ runtime_is_active "$SING_BOX_SERVICE"; }

# ===== MODULE: lib/core-config.sh =====
build_config(){
  local exit=${1:-${EXIT_TAG:-$(state_get exit 2>/dev/null || printf direct)}} dns nodes tun rules peer_host peer_tag
  [ "$exit" = "warp-system" ] && exit=direct
  dns=$(dns_json "$exit") || return 1
  node_init; nodes='[]'
  if compgen -G "$NODE_DIR/*.json" >/dev/null 2>&1; then nodes=$(jq -s '[.[] | .inbound, (.embedded_inbounds // [])[]] | map(select(. != null))' "$NODE_DIR"/*.json) || return 1; fi
  tun='null'; if routing_apply_base 2>/dev/null; then tun=$(routing_tun_json 2>/dev/null || true); [ -n "$tun" ] || tun='null'; fi
  rules=$(routing_rules_json) || return 1
  local fallback='null'
  if [ "${PROXY_MODE:-system-proxy}" = system-proxy ] || [ "${PROXY_MODE:-}" = limited-route ]; then
    fallback=$(jq -n --argjson p "${SYSTEM_PROXY_PORT:-2080}" '{type:"mixed",tag:"system-proxy",listen:"127.0.0.1",listen_port:$p,set_system_proxy:true}')
  fi
  peer_tag=''; peer_host=''
  if [ "$exit" != direct ] && [ -f "$PEER_ROOT/$exit.json" ]; then
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
  local base_tmp="$CONFIG_DIR/.build-config.$$"
  jq -n --argjson dns "$dns" --argjson inbounds "$nodes" --argjson tun "$tun" --argjson fallback "$fallback" --argjson rules "$rules" --arg direct "$ROUTE_DIRECT_OUTBOUND" '
    {log:{level:"warn",timestamp:true},dns:$dns,inbounds:$inbounds,outbounds:[{type:"direct",tag:$direct}],route:{rules:$rules,final:$direct,auto_detect_interface:true,default_domain_resolver:"dns-control"}}
    | if $tun != null then .inbounds=[$tun]+.inbounds else . end
    | if $fallback != null then .inbounds += [$fallback] else . end' >"$base_tmp" || { rm -f "$base_tmp"; return 1; }
  if [ -n "$peer_tag" ] && [ -f "$PEER_ROOT/$exit.json" ]; then
    jq --slurpfile p "$PEER_ROOT/$exit.json" '.outbounds += [($p[0].outbound + {domain_resolver:"dns-control"})] | .route.final=$p[0].outbound.tag' "$base_tmp" || { rm -f "$base_tmp"; return 1; }
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
  if [ -d "${NODE_DIR:-}" ]; then mkdir -p "$transaction_dir/nodes"; cp -a "$NODE_DIR/." "$transaction_dir/nodes/" 2>/dev/null || true; fi
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
  if [ -d "$transaction_dir/nodes" ] && [ -n "${NODE_DIR:-}" ]; then
    mkdir -p "$NODE_DIR" || return 1
    find "$NODE_DIR" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true
    cp -a "$transaction_dir/nodes/." "$NODE_DIR/" 2>/dev/null || true
  fi
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

# ===== MODULE: server/protocols/node.sh =====
NODE_ROOT=${KVM_NODE_ROOT:-/var/lib/kvm-new/nodes}; NODE_DIR=$NODE_ROOT
node_init(){ mkdir -p "$NODE_DIR"; chmod 700 "$NODE_DIR"; }
node_unique_tag(){ local base=${1//[^A-Za-z0-9_-]/-} tag="in-${base:-node}" n=1; node_init; while [ -e "$NODE_DIR/$tag.json" ];do tag="in-${base:-node}-$n";n=$((n+1));done;printf '%s' "$tag"; }
node_save(){
  local file=$1 kind port
  node_init; [ -s "$file" ] || return 1
  jq -e . "$file" >/dev/null 2>&1 || return 1
  kind=$(jq -r '.kind // empty' "$file"); port=$(jq -r '.port // 0' "$file")
  [[ "$kind" =~ ^(vless-reality|vless-tls|vmess|trojan|hysteria2|tuic|anytls|socks|snell|shadowsocks|shadowtls-shadowsocks)$ ]] || return 1
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  jq -e '.tag and .name and .inbound.type and .inbound.tag and .inbound.listen_port' "$file" >/dev/null 2>&1 || return 1
  case "$kind" in
    vless-reality|vless-tls) jq -e '.meta.uuid' "$file" >/dev/null 2>&1 || return 1 ;;
    vmess) jq -e '.meta.uuid and .inbound.users[0].uuid' "$file" >/dev/null 2>&1 || return 1 ;;
    trojan|hysteria2|anytls) jq -e '.meta.password and (.inbound.users|length>0)' "$file" >/dev/null 2>&1 || return 1 ;;
    tuic) jq -e '.meta.uuid and .meta.password and (.inbound.users|length>0)' "$file" >/dev/null 2>&1 || return 1 ;;
    socks) jq -e '.meta.username and .meta.password' "$file" >/dev/null 2>&1 || return 1 ;;
    snell) jq -e '.meta.psk and .inbound.version==6 and (.meta.psk|length)>=12 and (.meta.psk|length)<=255' "$file" >/dev/null 2>&1 || return 1 ;;
    shadowsocks) jq -e '.meta.method and .meta.password' "$file" >/dev/null 2>&1 || return 1; if jq -e '(.meta.method|startswith("2022-"))' "$file" >/dev/null 2>&1; then jq -e '.meta.password|length>0' "$file" >/dev/null 2>&1 || return 1; fi ;;
    shadowtls-shadowsocks) jq -e '.meta.shadowtls_password and .inbound.version==3 and .inbound.detour and (.embedded_inbounds|length>0)' "$file" >/dev/null 2>&1 || return 1 ;;
  esac
  chmod 600 "$file"
}
node_list(){ node_init; find "$NODE_DIR" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null|sort; }
node_delete(){ local t=$1; [ -n "$t" ]&&rm -f "$NODE_DIR/$t.json"; }
node_get(){ jq -r "${2:-.}" "$NODE_DIR/$1.json"; }
node_uuid(){ command -v uuidgen >/dev/null 2>&1&&uuidgen||cat /proc/sys/kernel/random/uuid 2>/dev/null||printf '%s-%s' "$(date +%s)" "$$"; }
node_secret(){ if command -v openssl >/dev/null 2>&1;then openssl rand -base64 24|tr -d '/+='|cut -c1-24;else tr -dc 'A-Za-z0-9' </dev/urandom|head -c24;fi; }
node_secret_base64(){ if command -v sing-box >/dev/null 2>&1; then sing-box generate rand --base64 16 2>/dev/null && return 0; fi; if command -v openssl >/dev/null 2>&1; then openssl rand -base64 16; else base64 </dev/urandom 2>/dev/null | tr -d '\n' | cut -c1-24; fi; }
node_port(){ local p; while :;do p=$((20000+RANDOM%30000)); ss -Hlnptu 2>/dev/null|awk '{print $5}'|grep -Eq "[:.]$p$"||{ printf '%s' "$p";return;};done; }
node_render(){
  local f=$1 host=${2:-} uri host_uri green reset
  [ -f "$f" ] || return 1
  host_uri=$host
  if [[ "$host_uri" == *:* && "$host_uri" != \[*\] ]]; then host_uri="[$host_uri]"; fi
  uri=$(jq -r --arg host "$host" --arg host_uri "$host_uri" '
    def e: @uri;
    if .kind=="vless-reality" then "vless://"+(.meta.uuid|e)+"@"+$host_uri+":"+(.port|tostring)+"?encryption=none&flow=xtls-rprx-vision&security=reality&sni="+(.meta.target|e)+"&pbk="+(.meta.public_key|e)+"&sid="+(.meta.short_id|e)+"&type=tcp#"+(.name|e)
    elif .kind=="vless-tls" then "vless://"+(.meta.uuid|e)+"@"+$host_uri+":"+(.port|tostring)+"?encryption=none&security=tls&sni="+($host|e)+"&type="+(.meta.transport//"tcp")+"#"+(.name|e)
    elif .kind=="trojan" then "trojan://"+(.meta.password|e)+"@"+$host_uri+":"+(.port|tostring)+"?security=tls&sni="+($host|e)+"&type="+(.meta.transport//"tcp")+"#"+(.name|e)
    elif .kind=="hysteria2" then "hysteria2://"+(.meta.password|e)+"@"+$host_uri+":"+(.port|tostring)+"?sni="+($host|e)+"#"+(.name|e)
    elif .kind=="tuic" then "tuic://"+(.meta.uuid|e)+":"+(.meta.password|e)+"@"+$host_uri+":"+(.port|tostring)+"?congestion_control=bbr&alpn=h3#"+(.name|e)
    elif .kind=="anytls" then "anytls://"+(.meta.password|e)+"@"+$host_uri+":"+(.port|tostring)+"?sni="+($host|e)+"#"+(.name|e)
    elif .kind=="vmess" then ("vmess://"+({v:"2",ps:.meta.uuid,add:$host_uri,port:(.port|tostring),id:.meta.uuid,aid:"0",net:(.meta.transport//"tcp"),type:"none",host:(.meta.host//""),path:(.meta.path//"")} | @base64))
    elif .kind=="shadowsocks" then "ss://"+((.meta.method+":"+.meta.password)|@base64)+"@"+$host_uri+":"+(.port|tostring)+"#"+(.name|e)
    elif .kind=="shadowtls-shadowsocks" then "shadowtls://"+(.meta.shadowtls_password|e)+"@"+$host_uri+":"+(.port|tostring)+"?host="+(.meta.handshake|e)+"#"+(.name|e)
    elif .kind=="socks" then "socks://"+(.meta.username|e)+":"+(.meta.password|e)+"@"+$host_uri+":"+(.port|tostring)+"#"+(.name|e)
    elif .kind=="snell" then "snell://"+(.meta.psk|e)+"@"+$host_uri+":"+(.port|tostring)+"?version=6&mode="+(.meta.mode//"default")+"#"+(.name|e)
    else "" end' "$f") || return 1
  green=$'\033[32m'; reset=$'\033[0m'
  if [ -n "$host" ] && { [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { [[ "$host" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$host" == *:* ]]; }; }; then
    printf '%s\n' "${uri//$host/${green}${host}${reset}}"
  else
    printf '%s\n' "$uri"
  fi
}

# ===== MODULE: server/protocols/basic.sh =====
server_prompt_cert(){ SERVER_STATE_SNAPSHOT=$(mktemp) || return 1; state_snapshot "$SERVER_STATE_SNAPSHOT" || return 1; local d cf k; d=$(ui_prompt '证书域名' "$(state_get domain 2>/dev/null)"); [ -n "$d" ]||return 1; cf=$(ui_prompt '证书文件' "$(state_get cert_file 2>/dev/null)"); k=$(ui_prompt '私钥文件' "$(state_get key_file 2>/dev/null)"); [ -f "$cf" ]&&[ -f "$k" ]||{ ui_warn '证书或私钥不存在';return 1; }; state_set domain "$d";state_set cert_file "$cf";state_set key_file "$k"; TLS_MODE=cert; }
server_prompt_acme(){ SERVER_STATE_SNAPSHOT=$(mktemp) || return 1; state_snapshot "$SERVER_STATE_SNAPSHOT" || return 1; local d e; d=$(ui_prompt 'ACME 域名' "$(state_get domain 2>/dev/null)"); [ -n "$d" ]||return 1; e=$(ui_prompt 'ACME 邮箱' "$(state_get email 2>/dev/null)"); [ -n "$e" ]||return 1; command -v "${SING_BOX_BIN:-sing-box}" >/dev/null 2>&1 || return 1; [[ "$("${SING_BOX_BIN:-sing-box}" version 2>/dev/null)" == *with_acme* ]] || { ui_warn '当前 sing-box 未包含 with_acme 构建标签'; return 1; }; state_set domain "$d"; state_set email "$e"; TLS_MODE=acme; }
server_prompt_tls(){ local mode; mode=$(ui_prompt 'TLS 证书: 1 已有证书 2 ACME' 1); case "$mode" in 2) server_prompt_acme;; *) server_prompt_cert;; esac; }
server_tls_json(){ if [ "${TLS_MODE:-cert}" = acme ]; then jq -n --arg d "$(state_get domain)" --arg e "$(state_get email)" '{enabled:true,server_name:$d,certificate_provider:{type:"acme",domain:[$d],email:$e,data_directory:"/var/lib/kvm-new/acme"}}'; else jq -n --arg d "$(state_get domain)" --arg cf "$(state_get cert_file)" --arg k "$(state_get key_file)" '{enabled:true,server_name:$d,certificate_path:$cf,key_path:$k}'; fi; }
server_apply_transport(){
  local f=$1 kind t mode path host service
  kind=$(jq -r '.kind // empty' "$f" 2>/dev/null) || return 1
  case "$kind" in vless-tls|vmess|trojan) ;; *) return 0 ;; esac
  [ "${TRANSPORT_MODE:-tcp}" = tcp ] && return 0
  t=${transport_json:-null}
  [ "$t" != null ] || return 1
  mode=${TRANSPORT_MODE:-tcp}
  case "$mode" in
    ws)
      path=$(jq -r '.path // /ws' <<<"$t")
      host=$(jq -r '.headers.Host // empty' <<<"$t")
      jq --argjson t "$t" --arg mode "$mode" --arg path "$path" --arg host "$host" '.inbound.transport=$t|.meta.transport=$mode|.meta.path=$path|.meta.host=$host' "$f" >"$f.tmp" || return 1;;
    grpc)
      service=$(jq -r '.service_name // empty' <<<"$t")
      jq --argjson t "$t" --arg mode "$mode" --arg service "$service" '.inbound.transport=$t|.meta.transport=$mode|.meta.service_name=$service' "$f" >"$f.tmp" || return 1;;
    httpupgrade)
      path=$(jq -r '.path // /upgrade' <<<"$t")
      host=$(jq -r '.host // empty' <<<"$t")
      jq --argjson t "$t" --arg mode "$mode" --arg path "$path" --arg host "$host" '.inbound.transport=$t|.meta.transport=$mode|.meta.path=$path|.meta.host=$host' "$f" >"$f.tmp" || return 1;;
    *) return 1;;
  esac
  mv -f "$f.tmp" "$f"
}
server_apply(){ apply_config; }
server_save_and_apply(){ local f=$1; node_save "$f"||{ ui_warn '节点数据无效';return 1; }; server_apply_transport "$f" || { rm -f "$f"; ui_warn '传输层配置失败'; return 1; }; if ! server_apply;then rm -f "$f"; [ -n "${SERVER_STATE_SNAPSHOT:-}" ] && state_restore "$SERVER_STATE_SNAPSHOT" || true; rm -f "${SERVER_STATE_SNAPSHOT:-}"; SERVER_STATE_SNAPSHOT=''; ui_warn '配置应用失败，已回滚节点';return 1;fi; rm -f "${SERVER_STATE_SNAPSHOT:-}"; SERVER_STATE_SNAPSHOT=''; ui_ok '协议已应用'; node_render "$f" "$(state_get domain 2>/dev/null || network_source_v4)"; }
create_vless_reality(){ local name port uuid target kp priv pub sid tag f; name=$(ui_prompt '节点名称' VLESS-Reality);port=$(ui_prompt '监听端口' "$(node_port)");uuid=$(ui_prompt 'UUID' "$(node_uuid)");target=$(ui_prompt 'Reality 握手域名' www.microsoft.com); kp=$(sing-box generate reality-keypair 2>/dev/null)||return 1;priv=$(awk '/PrivateKey/{print $2}'<<<"$kp");pub=$(awk '/PublicKey/{print $2}'<<<"$kp");sid=$(openssl rand -hex 4 2>/dev/null||printf 01234567);tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json"; jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg target "$target" --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" '{tag:$tag,name:$name,kind:"vless-reality",port:$port,tls_mode:"none",meta:{uuid:$uuid,target:$target,private_key:$priv,public_key:$pub,short_id:$sid},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$target,reality:{enabled:true,handshake:{server:$target,server_port:443},private_key:$priv,short_id:[$sid]}}}}' >"$f"; server_save_and_apply "$f"; }
create_vless_tls(){ local name port uuid tag f d tls; name=$(ui_prompt '节点名称' VLESS-TLS);server_prompt_tls||return;transport_prompt;d=$(state_get domain);port=$(ui_prompt '监听端口' "$(node_port)");uuid=$(ui_prompt 'UUID' "$(node_uuid)");tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json";tls=$(server_tls_json);jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg mode "${TLS_MODE:-cert}" --arg transport "${TRANSPORT_MODE:-tcp}" --argjson tls "$tls" '{tag:$tag,name:$name,kind:"vless-tls",port:$port,tls_mode:$mode,meta:{uuid:$uuid,transport:$transport},inbound:{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:$tls}}' >"$f";server_save_and_apply "$f"; }
create_trojan(){ local name port pw tag f d tls; name=$(ui_prompt '节点名称' Trojan);server_prompt_tls||return;transport_prompt;d=$(state_get domain);port=$(ui_prompt '监听端口' "$(node_port)");pw=$(ui_prompt '密码' "$(node_secret_base64)");tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json";tls=$(server_tls_json);jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg pw "$pw" --arg mode "${TLS_MODE:-cert}" --arg transport "${TRANSPORT_MODE:-tcp}" --argjson tls "$tls" '{tag:$tag,name:$name,kind:"trojan",port:$port,tls_mode:$mode,meta:{password:$pw,transport:$transport},inbound:{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pw}],tls:$tls}}' >"$f";server_save_and_apply "$f"; }
create_hysteria2(){ local name port pw tag f tls; name=$(ui_prompt '节点名称' Hysteria2);server_prompt_tls||return;port=$(ui_prompt '监听端口' "$(node_port)");pw=$(ui_prompt '密码' "$(node_secret_base64)");tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json";tls=$(server_tls_json);jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg pw "$pw" --arg mode "${TLS_MODE:-cert}" --arg transport "${TRANSPORT_MODE:-tcp}" --argjson tls "$tls" '{tag:$tag,name:$name,kind:"hysteria2",port:$port,tls_mode:$mode,meta:{password:$pw,transport:$transport},inbound:{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,up_mbps:100,down_mbps:100,users:[{password:$pw}],tls:$tls}}' >"$f";server_save_and_apply "$f"; }
create_tuic(){ local name port uuid pw tag f tls;name=$(ui_prompt '节点名称' TUIC);server_prompt_tls||return;port=$(ui_prompt '监听端口' "$(node_port)");uuid=$(ui_prompt 'UUID' "$(node_uuid)");pw=$(ui_prompt '密码' "$(node_secret_base64)");tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json";tls=$(server_tls_json);jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg pw "$pw" --arg mode "${TLS_MODE:-cert}" --arg transport "${TRANSPORT_MODE:-tcp}" --argjson tls "$tls" '{tag:$tag,name:$name,kind:"tuic",port:$port,tls_mode:$mode,meta:{uuid:$uuid,password:$pw},inbound:{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$pw}],congestion_control:"bbr",tls:$tls}}' >"$f";server_save_and_apply "$f"; }
create_anytls(){ local name port pw tag f tls;name=$(ui_prompt '节点名称' AnyTLS);server_prompt_tls||return;port=$(ui_prompt '监听端口' "$(node_port)");pw=$(ui_prompt '密码' "$(node_secret_base64)");tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json";tls=$(server_tls_json);jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg pw "$pw" --arg mode "${TLS_MODE:-cert}" --arg transport "${TRANSPORT_MODE:-tcp}" --argjson tls "$tls" '{tag:$tag,name:$name,kind:"anytls",port:$port,tls_mode:$mode,meta:{password:$pw,transport:$transport},inbound:{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{password:$pw}],tls:$tls}}' >"$f";server_save_and_apply "$f"; }
create_socks5(){ local name port u pw tag f;name=$(ui_prompt '节点名称' SOCKS5);port=$(ui_prompt '监听端口' "$(node_port)");u=$(ui_prompt '用户名' admin);pw=$(ui_prompt '密码' "$(node_secret_base64)");tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json";jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg u "$u" --arg pw "$pw" '{tag:$tag,name:$name,kind:"socks",port:$port,tls_mode:"none",meta:{username:$u,password:$pw},inbound:{type:"socks",tag:$tag,listen:"::",listen_port:$port,users:[{username:$u,password:$pw}]}}' >"$f";server_save_and_apply "$f"; }
create_snell(){ local name port psk tag f;name=$(ui_prompt '节点名称' Snell);port=$(ui_prompt '监听端口' "$(node_port)");psk=$(ui_prompt 'PSK' "$(node_secret)");tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json";jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg psk "$psk" '{tag:$tag,name:$name,kind:"snell",port:$port,tls_mode:"none",meta:{psk:$psk,mode:"default"},inbound:{type:"snell",tag:$tag,listen:"::",listen_port:$port,version:6,psk:$psk,users:[{name:$name,userkey:$psk}],mode:"default"}}' >"$f";server_save_and_apply "$f"; }
create_vmess(){ local name port uuid tag f;name=$(ui_prompt '节点名称' VMess-TCP);transport_prompt;port=$(ui_prompt '监听端口' "$(node_port)");uuid=$(ui_prompt 'UUID' "$(node_uuid)");tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json";jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg transport "${TRANSPORT_MODE:-tcp}" '{tag:$tag,name:$name,kind:"vmess",port:$port,tls_mode:"none",meta:{uuid:$uuid,transport:$transport},inbound:{type:"vmess",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,alterId:0}],network:"tcp"}}' >"$f";server_save_and_apply "$f"; }
create_shadowsocks(){ local name port method pw tag f;name=$(ui_prompt '节点名称' Shadowsocks);method=$(ui_prompt '加密方式' 2022-blake3-aes-128-gcm);port=$(ui_prompt '监听端口' "$(node_port)");pw=$(ui_prompt '密码' "$(node_secret_base64)");tag=$(node_unique_tag "$name");f="$NODE_DIR/$tag.json";jq -n --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg method "$method" --arg pw "$pw" '{tag:$tag,name:$name,kind:"shadowsocks",port:$port,tls_mode:"none",meta:{method:$method,password:$pw},inbound:{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:$method,password:$pw}}' >"$f";server_save_and_apply "$f"; }
create_shadowtls_shadowsocks(){ local name port ssport method pw stpw target tag ss_tag f; name=$(ui_prompt '节点名称' ShadowTLS+Shadowsocks);port=$(ui_prompt 'ShadowTLS 端口' "$(node_port)");ssport=$(ui_prompt '内部 Shadowsocks 端口' "$((port+1))");method=$(ui_prompt 'Shadowsocks 加密方式' 2022-blake3-aes-128-gcm);pw=$(ui_prompt 'Shadowsocks 密码' "$(node_secret_base64)");stpw=$(ui_prompt 'ShadowTLS 用户密码' "$(node_secret)");target=$(ui_prompt 'ShadowTLS 握手域名' www.microsoft.com);tag=$(node_unique_tag "$name");ss_tag="${tag}-ss";f="$NODE_DIR/$tag.json";jq -n --arg tag "$tag" --arg ss "$ss_tag" --arg name "$name" --arg target "$target" --arg pw "$pw" --arg stpw "$stpw" --arg method "$method" --argjson port "$port" --argjson ssport "$ssport" '{tag:$tag,name:$name,kind:"shadowtls-shadowsocks",port:$port,tls_mode:"shadowtls",meta:{method:$method,password:$pw,shadowtls_password:$stpw,handshake:$target},inbound:{type:"shadowtls",tag:$tag,listen:"::",listen_port:$port,version:3,users:[{name:$name,password:$stpw}],handshake:{server:$target,server_port:443},strict_mode:true,detour:$ss},embedded_inbounds:[{type:"shadowsocks",tag:$ss,listen:"127.0.0.1",listen_port:$ssport,method:$method,password:$pw}]}' >"$f";server_save_and_apply "$f"; }

# ===== MODULE: client/manager.sh =====
PEER_ROOT=${KVM_PEER_ROOT:-/var/lib/kvm-new/peers}; EXIT_STATE_KEY=exit
client_init(){ mkdir -p "$PEER_ROOT"; chmod 700 "$PEER_ROOT"; }
client_set_exit(){ local old new=$1; case "$new" in direct|warp-system) ;; *) [ -f "$PEER_ROOT/$new.json" ] || return 1;; esac; local old; old=$(state_get "$EXIT_STATE_KEY" 2>/dev/null || printf direct); state_set "$EXIT_STATE_KEY" "$1" || return 1; EXIT_TAG=$1; export EXIT_TAG; if ! apply_config; then state_set "$EXIT_STATE_KEY" "$old" || true; EXIT_TAG=$old; export EXIT_TAG; return 1; fi; }
client_show(){ printf '当前 EXIT: %s\n' "${EXIT_TAG:-$(state_get exit 2>/dev/null || printf direct)}"; }
peer_add(){ client_init; local f tag; f=$(ui_prompt '导入客户端 outbound JSON 文件路径'); [ -f "$f" ]|| { ui_warn '文件不存在';ui_wait;return;}; jq -e '.outbound.type and .outbound.tag and .outbound.server and .outbound.server_port' "$f" >/dev/null 2>&1|| { ui_warn 'JSON 必须包含 outbound.type/tag/server/server_port';ui_wait;return;}; tag=$(jq -r '.outbound.tag' "$f"); [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { ui_warn 'tag 含非法字符';ui_wait;return; }; cp -p "$f" "$PEER_ROOT/$tag.json"; ui_ok "已导入 $tag";ui_wait; }
peer_select(){ local opts=(); client_init; mapfile -t opts < <(find "$PEER_ROOT" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null|sed 's/\.json$//'); ui_title '选择 EXIT';ui_menu 1 'WARP system EXIT';local i=2 x;for x in "${opts[@]}";do ui_menu "$i" "$x";i=$((i+1));done;ui_back;local n=$(ui_prompt '请选择');if [ "$n" = 1 ];then client_set_exit warp-system||ui_warn 'WARP EXIT 应用失败';return;fi;if [ "$n" -ge 2 ] 2>/dev/null&&[ "$n" -lt "$i" ];then x=${opts[$((n-2))]};client_set_exit "$x"||ui_warn 'EXIT 应用失败';fi; }
peer_delete(){
  local x old
  client_init
  x=$(ui_prompt '输入节点文件名（不含 .json）')
  [[ "$x" =~ ^[A-Za-z0-9._-]+$ ]] || { ui_warn '节点名非法';ui_wait;return; }
  [ -f "$PEER_ROOT/$x.json" ] || { ui_warn '节点不存在';ui_wait;return; }
  old=$(state_get exit 2>/dev/null || printf direct)
  if [ "$old" = "$x" ]; then
    client_set_exit direct || { ui_warn '当前节点正在使用，无法安全切换到直连';ui_wait;return; }
  fi
  rm -f "$PEER_ROOT/$x.json" || { ui_warn '删除节点失败';ui_wait;return; }
  ui_ok '节点已删除'
  ui_wait
}
peer_stop(){ client_set_exit direct||{ ui_warn '切换直连失败';ui_wait;return; };ui_ok '已停止代理 EXIT';ui_wait; }
menu_client_status(){ client_show;ui_wait; }
exit_label(){ case ${EXIT_TAG:-$(state_get exit 2>/dev/null||printf direct)} in warp-system)printf 'Cloudflare WARP';;direct)printf '直连';;*)printf '%s' "$EXIT_TAG";;esac; }

# ===== MODULE: warp/manager.sh =====
WARP_BIN=${WARP_BIN:-warp-cli}
warp_has(){ command -v "$WARP_BIN" >/dev/null 2>&1; }
warp_status_raw(){ warp_has&&"$WARP_BIN" status 2>&1; }
warp_config(){ if ! warp_has;then ui_warn '未安装 cloudflare-warp/warp-cli';ui_tell '官方 Linux 文档支持 apt/yum 安装 cloudflare-warp。';ui_wait;return;fi; "$WARP_BIN" registration show 2>/dev/null||true;ui_tell '首次使用请执行 registration new；项目不会自动注册账号。';ui_wait; }
warp_enable(){ warp_has|| {  ui_warn 'warp-cli 不存在';ui_wait;return; }; "$WARP_BIN" connect|| { ui_warn 'WARP 连接失败';ui_wait;return;}; if ! client_set_exit warp-system; then "$WARP_BIN" disconnect >/dev/null 2>&1||true; ui_warn 'WARP 已连接但 EXIT 配置应用失败，已断开 WARP';ui_wait;return; fi;ui_ok 'WARP EXIT 已启用';ui_wait; }
warp_disable(){ local was_connected=0; if warp_has; then warp_status_raw 2>/dev/null | grep -qi 'connected' && was_connected=1 || true; "$WARP_BIN" disconnect || { ui_warn 'WARP 断开失败';ui_wait;return; }; fi; if ! client_set_exit direct; then [ "$was_connected" = 1 ] && "$WARP_BIN" connect >/dev/null 2>&1 || true; ui_warn '直连配置应用失败，WARP 状态已尝试恢复';ui_wait;return; fi;ui_ok 'WARP 已停用';ui_wait; }
warp_status(){ if warp_has;then warp_status_raw;else ui_warn 'warp-cli 不存在';fi;ui_wait; }

# ===== MODULE: lib/ui.sh =====
UI_RED='\033[31m'
UI_GREEN='\033[32m'
UI_CYAN='\033[36m'
UI_YELLOW='\033[33m'
UI_BROWN='\033[38;5;130m'
UI_PLAIN='\033[0m'

ui_clear(){
  if command -v clear >/dev/null 2>&1; then clear 2>/dev/null || printf '\033[H\033[2J'; else printf '\033[H\033[2J'; fi
}
ui_read(){ local v; if [ -c /dev/tty ]; then IFS= read -r v </dev/tty || v=''; else IFS= read -r v || v=''; fi; printf '%s' "${v%$'\r'}"; }
ui_ip(){
  local v=$1
  if [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { [[ "$v" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$v" == *:* ]]; }; then
    printf '%b%s%b' "$UI_GREEN" "$v" "$UI_PLAIN"
  else
    printf '%s' "$v"
  fi
}
ui_ip_or_host(){
  local v=$1
  if [[ "$v" =~ ^\[[0-9A-Fa-f:]+\](:[0-9]+)?$ ]]; then
    printf '%b%s%b' "$UI_GREEN" "$v" "$UI_PLAIN"
  else
    ui_ip "$v"
  fi
}
ui_prompt(){ local msg="$1" def="${2:-}" v; if [ -n "$def" ]; then printf '  %b%s [%s]: %b' "$UI_CYAN" "$msg" "$def" "$UI_PLAIN" >&2; else printf '  %b%s: %b' "$UI_CYAN" "$msg" "$UI_PLAIN" >&2; fi; v=$(ui_read); printf '%s' "${v:-$def}"; }
ui_yes(){ local v; v=$(ui_prompt "$1 (y/N)" 'n'); [[ "$v" == y || "$v" == Y ]]; }
ui_wait(){ printf '\n  %b>> 按回车键继续...%b' "$UI_CYAN" "$UI_PLAIN" >&2; ui_read >/dev/null; }
ui_tell(){ printf '  %b\n' "$*"; }
ui_ok(){ printf '  %b[√] %s%b\n' "$UI_GREEN" "$*" "$UI_PLAIN"; }
ui_warn(){ printf '  %b[×] %s%b\n' "$UI_RED" "$*" "$UI_PLAIN"; }
ui_alert(){ printf '  %b[!] %s%b\n' "$UI_YELLOW" "$*" "$UI_PLAIN"; }
ui_title(){ ui_clear; ui_tell "${UI_CYAN}========== $1 ==========${UI_PLAIN}"; }
ui_footer(){ ui_tell "${UI_CYAN}================================${UI_PLAIN}"; }
ui_menu(){ local n label; while [ "$#" -gt 0 ]; do n=$1; label=$2; shift 2; ui_tell "  $n. $label"; done; }
ui_invalid(){ ui_warn '输入无效，请重新选择'; sleep 1; }
ui_back(){ ui_tell '  0. 返回'; }

# ===== MODULE: server/menu.sh =====
server_restart(){ core_restart && ui_ok 'sing-box 已重启' || ui_warn 'sing-box 重启失败'; ui_wait; }
server_stop(){ core_stop && ui_ok 'sing-box 已停止' || ui_warn 'sing-box 停止失败'; ui_wait; }
server_update_tls_nodes(){
  local f tls mode; for f in "$NODE_DIR"/*.json; do [ -f "$f" ] || continue; mode=$(jq -r '.tls_mode // "none"' "$f"); case "$mode" in cert|acme) TLS_MODE="$mode"; tls=$(server_tls_json) || return 1; jq --argjson tls "$tls" '.inbound.tls=$tls' "$f" >"$f.tmp" || return 1; mv -f "$f.tmp" "$f";; esac; done
}
menu_delete_protocol(){
  local files=() n x old; mapfile -t files < <(node_list); [ ${#files[@]} -gt 0 ] || { ui_warn '没有节点';ui_wait;return; }
  ui_menu 1 '全部节点'; local i=2; for x in "${files[@]}"; do ui_menu "$i" "${x%.json}"; i=$((i+1)); done; ui_back; n=$(ui_prompt '选择'); [ "$n" = 0 ] && return
  transaction_begin || { ui_warn '无法创建回滚事务'; ui_wait; return; }
  if [ "$n" = 1 ]; then rm -f "$NODE_DIR"/*.json; else [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 2 ] && [ "$n" -lt "$i" ] || { transaction_rollback >/dev/null 2>&1 || true; ui_invalid; return; }; x=${files[$((n-2))]}; rm -f "$NODE_DIR/$x"; fi
  if apply_config_quiet; then transaction_commit; ui_ok '节点删除并应用成功'; else transaction_rollback >/dev/null 2>&1 || true; ui_warn '删除后配置应用失败，节点和配置已回滚'; fi; ui_wait
}
menu_modify_protocol(){
  local files=() n f name port old
  mapfile -t files < <(node_list); [ ${#files[@]} -gt 0 ] || { ui_warn '没有节点';ui_wait;return; }
  ui_menu 1 '全部节点'; local i=2 x; for x in "${files[@]}"; do ui_menu "$i" "${x%.json}"; i=$((i+1)); done; ui_back; n=$(ui_prompt '选择'); [ "$n" = 0 ] && return
  [ "$n" != 1 ] || { ui_warn '请逐个修改节点';ui_wait;return; }; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 2 ] && [ "$n" -lt "$i" ] || { ui_invalid;return; }
  f="$NODE_DIR/${files[$((n-2))]}"; cp -p "$f" "$f.bak" || return
  name=$(ui_prompt '节点名称' "$(jq -r '.name' "$f")"); port=$(ui_prompt '监听端口' "$(jq -r '.port' "$f")")
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { ui_warn '端口无效'; rm -f "$f.bak"; ui_wait; return; }
  jq --arg name "$name" --argjson port "$port" '.name=$name|.port=$port|.inbound.listen_port=$port' "$f" >"$f.tmp" || { rm -f "$f.bak"; ui_warn '修改失败';ui_wait;return; }; mv -f "$f.tmp" "$f"
  if apply_config_quiet; then rm -f "$f.bak"; ui_ok '节点已修改并应用'; else mv -f "$f.bak" "$f"; ui_warn '配置应用失败，已恢复节点数据'; fi; ui_wait
}
menu_server_info(){ ui_title '服务端信息'; node_list; printf '\n'; network_summary; printf '服务端 IP: '; ui_ip "$(network_source_v4 2>/dev/null || true)"; printf '\n'; printf 'sing-box: '; core_status&&printf 'active\n'||printf 'inactive\n'; ui_wait; }
menu_change_domain(){ server_prompt_tls || { ui_wait; return; }; transaction_begin || { [ -n "${SERVER_STATE_SNAPSHOT:-}" ] && state_restore "$SERVER_STATE_SNAPSHOT" || true; rm -f "${SERVER_STATE_SNAPSHOT:-}"; SERVER_STATE_SNAPSHOT=''; ui_warn '无法创建回滚事务'; ui_wait; return; }; if server_update_tls_nodes && apply_config_quiet; then transaction_commit; rm -f "${SERVER_STATE_SNAPSHOT:-}"; SERVER_STATE_SNAPSHOT=''; ui_ok '证书/TLS 设置已更新并应用'; else transaction_rollback >/dev/null 2>&1 || true; [ -n "${SERVER_STATE_SNAPSHOT:-}" ] && state_restore "$SERVER_STATE_SNAPSHOT" || true; rm -f "${SERVER_STATE_SNAPSHOT:-}"; SERVER_STATE_SNAPSHOT=''; ui_warn 'TLS 设置应用失败，已恢复原状态'; fi; ui_wait; }
menu_server(){ while :; do ui_title '服务端管理'; ui_menu 1 '创建协议' 2 '删除协议' 3 '修改配置' 4 '服务端信息' 5 '证书/域名' 6 '重启服务' 7 '停止服务'; ui_back; case $(ui_prompt '请选择') in 1)menu_create_protocol;;2)menu_delete_protocol;;3)menu_modify_protocol;;4)menu_server_info;;5)menu_change_domain;;6)server_restart;;7)server_stop;;0)break;;*)ui_invalid;;esac; done; }

# ===== MODULE: server/protocol-menu.sh =====
menu_create_protocol(){ while :;do ui_title '创建协议（当前闭环）';ui_menu 1 'VLESS + Reality' 2 'VLESS + TLS' 3 'VMess TCP' 4 'Trojan + TLS' 5 'Shadowsocks' 6 'Hysteria2 + TLS' 7 'TUIC + TLS' 8 'AnyTLS + TLS' 9 'SOCKS5' 10 'Snell v6' 11 'ShadowTLS + Shadowsocks';ui_back;case $(ui_prompt '请选择') in 1)create_vless_reality;;2)create_vless_tls;;3)create_vmess;;4)create_trojan;;5)create_shadowsocks;;6)create_hysteria2;;7)create_tuic;;8)create_anytls;;9)create_socks5;;10)create_snell;;11)create_shadowtls_shadowsocks;;0)break;;*)ui_invalid;;esac;done; }

# ===== MODULE: client/menu.sh =====
menu_client(){
  while :; do
    ui_title '客户端管理'
    ui_tell "  当前出口: ${UI_YELLOW}$(exit_label 2>/dev/null || printf '直连')${UI_PLAIN}"
    ui_tell ''
    ui_menu 1 '添加节点' 2 '节点选择' 3 '删除节点' 4 '停止代理' 5 '客户端状态'
    ui_back; ui_footer
    case $(ui_prompt '请选择') in
      1) peer_add;; 2) peer_select;; 3) peer_delete;; 4) peer_stop;; 5) menu_client_status;; 0) break;; *) ui_invalid;;
    esac
  done
}

# ===== MODULE: warp/menu.sh =====
menu_warp(){
  while :; do
    ui_title 'WARP'
    ui_menu 1 '配置 WARP' 2 '启用 WARP' 3 '停用 WARP' 4 'WARP 状态'
    ui_back; ui_footer
    case $(ui_prompt '请选择') in
      1) warp_config;; 2) warp_enable;; 3) warp_disable;; 4) warp_status;; 0) break;; *) ui_invalid;;
    esac
  done
}

# ===== MODULE: bin/main-menu.sh =====
menu_main(){ while :;do ui_title 'KVM/LXC 流量控制';ui_tell "环境: $ENV_OS $ENV_OS_VERSION / $ENV_VIRT / $ENV_INIT";ui_tell "模式: $(proxy_mode_name)";ui_tell "EXIT: $(exit_label)";ui_tell '';ui_menu 1 '服务端管理' 2 '客户端/EXIT' 3 'WARP 管理' 4 '状态与诊断';ui_back;case $(ui_prompt '请选择') in 1)menu_server;;2)menu_client;;3)menu_warp;;4)menu_status;;0)ui_clear;return 0;;*)ui_invalid;;esac;done; }
menu_status(){ ui_title '状态与诊断';network_summary;dns_summary;routing_summary;printf 'TUN=%s open=%s nft=%s net_admin=%s\n' "$CAP_TUN" "$CAP_TUN_OPEN" "$CAP_NFT" "$CAP_NET_ADMIN";printf 'sing-box=';core_status&&printf active\n||printf inactive\n;ui_wait; }

# ===== MODULE: standalone-entry =====
standalone_bootstrap(){
  environment_detect || return 1
  package_prepare || { printf '依赖准备失败，无法继续。\n' >&2; return 1; }
  core_ensure || { printf 'sing-box 内核准备失败，无法继续。\n' >&2; return 1; }
  proxy_mode_detect || return 1
  state_init || return 1
  config_init || return 1
  node_init || return 1
  SING_BOX_CONFIG=$config_file
  export SING_BOX_CONFIG
  EXIT_TAG=$(state_get exit 2>/dev/null || printf direct)
  export EXIT_TAG
}
standalone_main(){
  standalone_bootstrap || exit 1
  entrypoint_install || exit 1
  if [ "${KVM_NONINTERACTIVE:-0}" = 1 ]; then
    printf 'OS=%s\nARCH=%s\nVIRT=%s\nINIT=%s\nMODE=%s\nTUN=%s\nNFT=%s\nIPTABLES=%s\nIP=%s\nNET_ADMIN=%s\n' "$ENV_OS" "$ENV_ARCH" "$ENV_VIRT" "$ENV_INIT" "$PROXY_MODE" "$CAP_TUN" "$CAP_NFT" "$CAP_IPTABLES" "$CAP_IP" "$CAP_NET_ADMIN"
    return 0
  fi
  menu_main
}
standalone_main "$@"
