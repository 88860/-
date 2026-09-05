#!/usr/bin/env bash

SBM_VERSION="1.3.0"

if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash >/dev/null 2>&1 && exec bash "$0" "$@"
    fi
    echo "need bash" >&2; exit 1
fi

set -uo pipefail
export LANG=C.UTF-8

SBM_HOME=/root/s.sh
SBM_LINK=/usr/local/bin/s

SB_ROOT=/etc/sing-box
SB_BIN=/usr/local/bin/sing-box
SB_CONF=$SB_ROOT/config.json
SB_NODES=$SB_ROOT/nodes
SB_PEERS=$SB_ROOT/peers
SB_STATE=$SB_ROOT/state.json
PROT_PORTS=$SB_ROOT/protected_ports
SSH_PORTS=$SB_ROOT/ssh_ports
CERT_DIR=$SB_ROOT/cert
CERT_DOMAIN=$CERT_DIR/domain
TLS_CRT=$CERT_DIR/fullchain.pem
TLS_KEY=$CERT_DIR/private.key

SVC_SB=sing-box
SVC_RULES=sing-box-rules
ACME_HOME=$HOME/.acme.sh
ACME=$ACME_HOME/acme.sh
SB_REPO=SagerNet/sing-box

MARK_BYPASS=0x1e7
MARK_TPROXY=0x1e8
PREF_BYPASS=100
PREF_TPROXY=101
TBL_TPROXY=107
PORT_TPROXY=2081

NFT_FILTER=sbm_filter
NFT_BYPASS=sbm_bypass
NFT_TPROXY=sbm_tproxy
NFT_GUARD=sbm_guard
NFT_HOP=sbm_hop

SBM_BATCH=0
SEP="================================"

if [[ -t 1 ]]; then
    CR=$'\033[31m'; CG=$'\033[32m'; CY=$'\033[33m'
    CD=$'\033[2m'; CN=$'\033[0m'
else
    CR=""; CG=""; CY=""; CD=""; CN=""
fi

have() { command -v "$1" >/dev/null 2>&1; }

ui_sep()   { printf '%s\n' "$SEP"; }
ui_title() { printf '\n%s\n  %s\n%s\n\n' "$SEP" "$1" "$SEP"; }
msg()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓ %s%s\n' "$CG" "$*" "$CN"; }
warn() { printf '%s! %s%s\n' "$CY" "$*" "$CN"; }
err()  { printf '%s✗ %s%s\n' "$CR" "$*" "$CN" >&2; }
dim()  { printf '%s%s%s\n' "$CD" "$*" "$CN"; }
die()  { err "$*"; exit 1; }
kv()   { printf '%s:\n%s\n\n' "$1" "$2"; }
pause(){ echo; read -r -p "按回车继续..." _; }

need_root() { [[ $(id -u) -eq 0 ]] || die "请以 root 运行。"; }

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

conf_err() {
    "$SB_BIN" check -c "$1" 2>&1 | head -n 6 | while read -r l; do dim "  $l"; done
}

_TMO=""
tmo() {
    local s=$1; shift
    if [[ -z $_TMO ]]; then
        if timeout 1 true >/dev/null 2>&1; then _TMO=posix
        elif timeout -t 1 true >/dev/null 2>&1; then _TMO=busybox
        else _TMO=none; fi
    fi
    case $_TMO in
        posix)   timeout "$s" "$@" ;;
        busybox) timeout -t "$s" "$@" ;;
        *)       "$@" ;;
    esac
}

ask_menu() {
    local __v=$1 allow=" $2 " in
    while :; do
        read -r -p "请选择:" in
        in=${in//[[:space:]]/}
        [[ -n $in && $allow == *" $in "* ]] && { printf -v "$__v" '%s' "$in"; return 0; }
        warn "无效选项。"
    done
}

ask_req() {
    local __v=$1 q=$2 in
    while :; do
        printf '%s\n' "$q"; read -r -p "> " in
        in=$(trim "$in")
        [[ -n $in ]] && { printf -v "$__v" '%s' "$in"; return 0; }
        warn "不能为空。"
    done
}

ask_def() {
    local __v=$1 q=$2 d=$3 in
    printf '%s\n' "$q"; dim "(回车使用 $d)"; read -r -p "> " in
    in=$(trim "$in"); [[ -z $in ]] && in=$d
    printf -v "$__v" '%s' "$in"
}

ask_yn() {
    local q=$1 d=${2:-N} in
    while :; do
        read -r -p "$q [y/N] " in
        in=${in:-$d}
        case $in in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)   return 1 ;;
            *) warn "请输入 y 或 n。" ;;
        esac
    done
}

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
is_port() { is_uint "$1" && (( $1 >= 1 && $1 <= 65535 )); }
is_v4()   { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_v6()   { [[ $1 == *:* && $1 =~ ^[0-9a-fA-F:.]+$ ]]; }
is_ip()   { is_v4 "$1" || is_v6 "$1"; }

is_domain() {
    [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

is_name() {
    local n=$1
    [[ -n $n ]] || return 1
    (( ${#n} <= 32 )) || return 1
    [[ $n =~ [/\\:*?\"\<\>\|] ]] && return 1
    [[ $n == .* ]] && return 1
    [[ $n =~ ^[[:space:]] || $n =~ [[:space:]]$ ]] && return 1
    return 0
}

ver_gt() {
    [[ $1 == "$2" ]] && return 1
    local IFS=. i a b
    local -a x=($1) y=($2)
    for (( i = 0; i < 3; i++ )); do
        a=${x[i]:-0}; b=${y[i]:-0}
        a=${a%%[^0-9]*}; b=${b%%[^0-9]*}
        (( 10#${a:-0} > 10#${b:-0} )) && return 0
        (( 10#${a:-0} < 10#${b:-0} )) && return 1
    done
    return 1
}

gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
    elif [[ -x $SB_BIN ]]; then "$SB_BIN" generate uuid
    else printf '%04x%04x-%04x-4%03x-%04x-%04x%04x%04x' \
        $RANDOM $RANDOM $RANDOM $((RANDOM % 4096)) \
        $(( (RANDOM % 16384) + 32768 )) $RANDOM $RANDOM $RANDOM
    fi
}

gen_pass() {
    local n=${1:-16} s=""
    while (( ${#s} < n )); do s+=$(gen_uuid | tr -d '-'); done
    printf '%s' "${s:0:n}"
}

gen_hex() {
    local n=${1:-8}
    if [[ -r /dev/urandom ]] && have od; then
        head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'
    else
        gen_pass $(( n * 2 )) | tr 'A-Z' 'a-z' | tr -c '0-9a-f' '0'
    fi
}

now_ms() {
    if [[ -n ${EPOCHREALTIME:-} ]]; then
        local t=${EPOCHREALTIME/,/.}
        printf '%d' $(( ${t%.*} * 1000 + 10#${t#*.}0 / 100 ))
    else printf '%d' $(( $(date +%s) * 1000 )); fi
}

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
urldec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }

hostport() {
    if [[ $1 == *:* && $1 != \[* ]]; then printf '[%s]:%s' "$1" "$2"
    else printf '%s:%s' "$1" "$2"; fi
}

port_busy() {
    local p=$1 pr=${2:-tcp} hex fs f
    is_port "$p" || return 1
    hex=$(printf '%04X' "$p")
    case $pr in
        tcp) fs="/proc/net/tcp /proc/net/tcp6" ;;
        udp) fs="/proc/net/udp /proc/net/udp6" ;;
        *) return 1 ;;
    esac
    for f in $fs; do
        [[ -r $f ]] || continue
        if [[ $pr == tcp ]]; then
            awk -v k=":$hex" 'NR>1 && $2 ~ k"$" && $4=="0A"{n=1;exit} END{exit !n}' "$f" && return 0
        else
            awk -v k=":$hex" 'NR>1 && $2 ~ k"$"{n=1;exit} END{exit !n}' "$f" && return 0
        fi
    done
    return 1
}

rand_port() {
    local p
    while :; do
        p=$(( (RANDOM % 40000) + 20000 ))
        port_busy "$p" tcp && continue
        port_busy "$p" udp && continue
        port_used "$p" && continue
        printf '%d' "$p"; return 0
    done
}

http_get() {
    if have curl; then curl -fsSL --retry 2 --connect-timeout 8 --max-time 20 "$1" 2>/dev/null
    else wget -qO- --tries=2 --timeout=8 "$1" 2>/dev/null; fi
}

http_getv() {
    local f=""
    [[ -n $1 ]] && f="-$1"
    curl -fsSL $f --connect-timeout 4 --max-time 8 "$2" 2>/dev/null
}

http_getp() {
    local f=""
    [[ -n $1 ]] && f="-$1"
    curl -fsSL $f --socks5-hostname "$3" --connect-timeout 5 --max-time 12 "$2" 2>/dev/null
}

PUB4=""; PUB6=""

pub_ip() {
    [[ -n $PUB4$PUB6 ]] && return 0
    PUB4=$(http_getv 4 https://api.ipify.org | tr -d '[:space:]')
    is_v4 "$PUB4" || PUB4=$(http_getv 4 https://api.ip.sb/ip | tr -d '[:space:]')
    is_v4 "$PUB4" || PUB4=""
    PUB6=$(http_getv 6 https://api64.ipify.org | tr -d '[:space:]')
    is_v6 "$PUB6" || PUB6=""
    return 0
}

ip_cc() {
    local r
    if [[ -n ${1:-} ]]; then
        r=$(http_getv "" "https://api.ip.sb/geoip/$1" | jq -r '.country // empty' 2>/dev/null)
    else
        r=$(http_getv "${2:-4}" https://api.ip.sb/geoip | jq -r '.country // empty' 2>/dev/null)
    fi
    printf '%s' "${r:-未知}"
}

resolve() {
    local h=$1 fam=${2:-} out=""
    is_ip "$h" && { printf '%s\n' "$h"; return 0; }
    if have getent; then
        case $fam in
            4) out=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}') ;;
            6) out=$(getent ahostsv6 "$h" 2>/dev/null | awk '{print $1}') ;;
            *) out=$(getent ahosts   "$h" 2>/dev/null | awk '{print $1}') ;;
        esac
        [[ -z $out ]] && out=$(getent hosts "$h" 2>/dev/null | awk '{print $1}')
    fi
    if [[ -z $out ]] && have nslookup; then
        out=$(nslookup "$h" 2>/dev/null | awk '/^Name:/{f=1} f && /^Address/{print $NF}')
    fi
    [[ -n $out ]] || return 1
    case $fam in
        4) grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<<"$out" | sort -u ;;
        6) grep ':' <<<"$out" | grep -E '^[0-9a-fA-F:]+$' | sort -u ;;
        *) grep -E '^[0-9a-fA-F:.]+$' <<<"$out" | sort -u ;;
    esac
}

tcp_ping() {
    local t0 t1
    t0=$(now_ms)
    if tmo 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; then
        t1=$(now_ms); printf '%d' $(( t1 - t0 )); return 0
    fi
    have nc || return 1
    t0=$(now_ms)
    nc -z -w 3 "$1" "$2" >/dev/null 2>&1 || return 1
    t1=$(now_ms); printf '%d' $(( t1 - t0 ))
}

icmp_ping() {
    local out
    if [[ ${2:-4} == 6 ]]; then
        if have ping6; then out=$(ping6 -c 1 -W 3 "$1" 2>/dev/null)
        else out=$(ping -6 -c 1 -W 3 "$1" 2>/dev/null); fi
    else
        out=$(ping -c 1 -W 3 "$1" 2>/dev/null)
    fi
    [[ -n $out ]] || return 1
    awk -F'[=/ ]+' '/time=/{for(i=1;i<=NF;i++) if($i=="time"){print int($(i+1));exit}}' <<<"$out"
}

latency() {
    local h=$1 p=$2 l4=$3 fam=$4 a ms
    a=$(resolve "$h" "$fam" | head -n1)
    [[ -n $a ]] || { printf '解析失败'; return 1; }
    if [[ $l4 == tcp ]]; then ms=$(tcp_ping "$a" "$p") || { printf '超时'; return 1; }
    else ms=$(icmp_ping "$a" "$fam") || { printf '无法测量'; return 1; }; fi
    printf '%sms' "$ms"
}

DISTRO=""; FAMILY=""; DNAME=""; PKG=""; INIT=""

osr() {
    [[ -r /etc/os-release ]] || return 1
    awk -F= -v k="$1" '$1==k{v=$2;gsub(/^"|"$/,"",v);print v;exit}' /etc/os-release
}

detect_distro() {
    DISTRO=$(osr ID); DNAME=$(osr PRETTY_NAME)
    local v; v=$(osr VERSION_ID)
    if [[ -z $DISTRO ]]; then
        if [[ -f /etc/alpine-release ]]; then DISTRO=alpine; v=$(cat /etc/alpine-release)
        elif [[ -f /etc/debian_version ]]; then DISTRO=debian; v=$(cat /etc/debian_version)
        fi
    fi
    case $DISTRO in
        debian|ubuntu|devuan|raspbian) FAMILY=debian; PKG=apt ;;
        alpine)                        FAMILY=alpine; PKG=apk ;;
        *)
            if have apk; then FAMILY=alpine; PKG=apk
            elif have apt-get; then FAMILY=debian; PKG=apt
            else die "仅支持 Debian/Ubuntu 与 Alpine，检测到 ${DISTRO:-未知}"; fi ;;
    esac
    [[ -z $DNAME ]] && DNAME="$DISTRO $v"
    if have systemctl && [[ -d /run/systemd/system ]]; then INIT=systemd
    elif have rc-service; then INIT=openrc
    else die "需要 systemd 或 OpenRC。"; fi
    return 0
}

_upd=0
pkg_update() {
    (( _upd )) && return 0
    case $PKG in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 ;;
        apk) apk update >/dev/null 2>&1 ;;
    esac
    _upd=1
}

pkg_install() {
    [[ $# -gt 0 ]] || return 0
    pkg_update
    case $PKG in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
        apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
    esac
}

pkg_of() {
    case $1 in
        ip)       echo iproute2 ;;
        nft)      echo nftables ;;
        crontab)  [[ $FAMILY == alpine ]] && echo dcron || echo cron ;;
        getent)   [[ $FAMILY == alpine ]] && echo musl-utils || echo libc-bin ;;
        ping)     [[ $FAMILY == alpine ]] && echo iputils || echo iputils-ping ;;
        nslookup) [[ $FAMILY == alpine ]] && echo bind-tools || echo dnsutils ;;
        od)       [[ $FAMILY == alpine ]] && echo coreutils || echo coreutils ;;
        *)        echo "$1" ;;
    esac
}

pkg_ensure() {
    local c=$1 p
    have "$c" && return 0
    (( SBM_BATCH )) && return 1
    p=$(pkg_of "$c")
    [[ -n $p ]] || return 1
    msg "缺少 $c，正在安装 $p..."
    pkg_install "$p"
    have "$c" && { ok "$c 就绪"; return 0; }
    err "$c 安装失败"; return 1
}

need_iproute() {
    ip -V 2>&1 | grep -qi iproute2 && return 0
    (( SBM_BATCH )) && return 1
    warn "当前 ip 为 busybox 版，缺 tuntap/rule 支持，正在安装 iproute2..."
    pkg_install iproute2
    ip -V 2>&1 | grep -qi iproute2 && { ok "iproute2 就绪"; return 0; }
    err "iproute2 安装失败"
    return 1
}

need_nft() {
    have nft && return 0
    (( SBM_BATCH )) && return 1
    pkg_ensure nft
}

svc_start()   { case $INIT in systemd) systemctl start "$1" >/dev/null 2>&1 ;; openrc) rc-service "$1" start >/dev/null 2>&1 ;; esac; }
svc_stop()    { case $INIT in systemd) systemctl stop "$1" >/dev/null 2>&1 ;; openrc) rc-service "$1" stop >/dev/null 2>&1 ;; esac; }
svc_restart() { case $INIT in systemd) systemctl restart "$1" >/dev/null 2>&1 ;; openrc) rc-service "$1" restart >/dev/null 2>&1 ;; esac; }
svc_enable()  { case $INIT in systemd) systemctl enable "$1" >/dev/null 2>&1 ;; openrc) rc-update add "$1" default >/dev/null 2>&1 ;; esac; }
svc_disable() { case $INIT in systemd) systemctl disable "$1" >/dev/null 2>&1 ;; openrc) rc-update del "$1" default >/dev/null 2>&1 ;; esac; }
svc_reload()  { [[ $INIT == systemd ]] && systemctl daemon-reload >/dev/null 2>&1; return 0; }

svc_up() {
    case $INIT in
        systemd) systemctl is-active --quiet "$1" ;;
        openrc)  rc-service "$1" status >/dev/null 2>&1 ;;
    esac
}

svc_has() {
    case $INIT in
        systemd) [[ -f /etc/systemd/system/$1.service ]] ;;
        openrc)  [[ -f /etc/init.d/$1 ]] ;;
    esac
}

svc_log_hint() {
    case $INIT in
        systemd) dim "  journalctl -u $SVC_SB -n 30 --no-pager" ;;
        openrc)  dim "  tail -n 30 /var/log/$SVC_SB.err" ;;
    esac
}
install_sb_unit() {
    case $INIT in
        systemd)
            cat >"/etc/systemd/system/$SVC_SB.service" <<EOF
[Unit]
Description=sing-box
After=network-online.target nss-lookup.target $SVC_RULES.service
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SB_BIN -c $SB_CONF run
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
            svc_reload ;;
        openrc)
            cat >"/etc/init.d/$SVC_SB" <<EOF
#!/sbin/openrc-run
name="$SVC_SB"
description="sing-box"
supervisor="supervise-daemon"
command="$SB_BIN"
command_args="-c $SB_CONF run"
respawn_delay=10
respawn_max=0
output_log="/var/log/\${RC_SVCNAME}.log"
error_log="/var/log/\${RC_SVCNAME}.err"

depend() {
    need net
    after $SVC_RULES
}

start_pre() {
    checkpath -f -m 0644 "\${output_log}" "\${error_log}"
}
EOF
            chmod +x "/etc/init.d/$SVC_SB" ;;
    esac
    svc_enable "$SVC_SB"
}

install_rules_unit() {
    case $INIT in
        systemd)
            cat >"/etc/systemd/system/$SVC_RULES.service" <<EOF
[Unit]
Description=sing-box manager rules
After=network-online.target nftables.service ufw.service
Wants=network-online.target
Before=$SVC_SB.service
ConditionPathExists=$SBM_HOME

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SBM_HOME --apply-rules

[Install]
WantedBy=multi-user.target
EOF
            svc_reload ;;
        openrc)
            cat >"/etc/init.d/$SVC_RULES" <<EOF
#!/sbin/openrc-run
description="sing-box manager rules"

depend() {
    need net
    before $SVC_SB
}

start() {
    if [ ! -x "$SBM_HOME" ]; then
        ewarn "$SBM_HOME 不存在，跳过规则重建"
        return 0
    fi
    ebegin "Applying sing-box manager rules"
    "$SBM_HOME" --apply-rules
    eend \$?
}

stop() {
    return 0
}
EOF
            chmod +x "/etc/init.d/$SVC_RULES" ;;
    esac
    svc_enable "$SVC_RULES"
}

svc_purge() {
    svc_stop "$1"; svc_disable "$1"
    case $INIT in
        systemd) rm -f "/etc/systemd/system/$1.service"; svc_reload ;;
        openrc)  rm -f "/etc/init.d/$1" ;;
    esac
}

self_install() {
    local src
    src=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    [[ -f $src ]] || return 0
    if [[ $src != "$SBM_HOME" ]]; then
        if install -m 0700 "$src" "$SBM_HOME" 2>/dev/null; then
            dim "脚本已保存到 $SBM_HOME"
        else
            warn "无法写入 $SBM_HOME，开机规则重建将不可用"
            return 1
        fi
    else
        chmod 700 "$SBM_HOME" 2>/dev/null
    fi
    if [[ $(readlink "$SBM_LINK" 2>/dev/null) != "$SBM_HOME" ]]; then
        mkdir -p "$(dirname "$SBM_LINK")" 2>/dev/null
        ln -sf "$SBM_HOME" "$SBM_LINK" 2>/dev/null && dim "快捷命令已就绪，输入 s 打开脚本"
    fi
    return 0
}

VIRT=""; IN_CT=0; HAS_TUN=0; HAS_NA=0; PMODE=""
SB_ARCH=""; CPU_LVL=""

detect_virt() {
    VIRT=none; IN_CT=0
    if have systemd-detect-virt; then
        local v; v=$(systemd-detect-virt 2>/dev/null)
        [[ -n $v && $v != none ]] && VIRT=$v
    fi
    if [[ $VIRT == none ]]; then
        if [[ -f /.dockerenv || -f /run/.containerenv ]]; then VIRT=docker
        elif [[ -r /proc/1/environ ]] && grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then VIRT=lxc
        elif [[ -r /proc/1/cgroup ]] && grep -qE '(:/lxc/|:/docker/|:/kubepods)' /proc/1/cgroup 2>/dev/null; then
            VIRT=$(grep -oE 'lxc|docker|kubepods' /proc/1/cgroup 2>/dev/null | head -n1)
        elif [[ -d /proc/vz && ! -d /proc/bc ]]; then VIRT=openvz
        elif [[ -r /sys/class/dmi/id/product_name ]]; then
            case $(cat /sys/class/dmi/id/product_name 2>/dev/null) in
                *KVM*|*QEMU*) VIRT=kvm ;;
                *VMware*) VIRT=vmware ;;
                *VirtualBox*) VIRT=virtualbox ;;
                *Hyper-V*|*Virtual\ Machine*) VIRT=hyperv ;;
            esac
        fi
    fi
    case $VIRT in
        lxc|lxd|docker|podman|openvz|kubepods|container-other|systemd-nspawn) IN_CT=1 ;;
    esac
    return 0
}

check_na() {
    HAS_NA=0
    if [[ -r /proc/self/status ]]; then
        local c; c=$(awk '/^CapEff:/{print $2}' /proc/self/status 2>/dev/null)
        [[ -n $c ]] && (( 0x${c:(-8)} & 0x1000 )) && HAS_NA=1
    fi
    if (( ! HAS_NA )) && ip -V 2>&1 | grep -qi iproute2; then
        if ip rule add fwmark 0x1ff lookup main pref 32000 >/dev/null 2>&1; then
            ip rule del fwmark 0x1ff lookup main pref 32000 >/dev/null 2>&1
            HAS_NA=1
        fi
    fi
    return 0
}

check_tun() {
    HAS_TUN=0
    ip -V 2>&1 | grep -qi iproute2 || return 0
    if [[ ! -c /dev/net/tun ]]; then
        have modprobe && modprobe tun >/dev/null 2>&1
        [[ -c /dev/net/tun ]] || {
            mkdir -p /dev/net 2>/dev/null
            mknod /dev/net/tun c 10 200 >/dev/null 2>&1 && chmod 600 /dev/net/tun
        }
    fi
    [[ -c /dev/net/tun ]] || return 0
    { exec 9<>/dev/net/tun; } >/dev/null 2>&1 || return 0
    exec 9>&- 2>/dev/null
    if ip tuntap add dev sbmprobe0 mode tun >/dev/null 2>&1; then
        ip tuntap del dev sbmprobe0 mode tun >/dev/null 2>&1
        HAS_TUN=1
    fi
    return 0
}

nft_can_tproxy() {
    have nft || return 1
    nft add table inet sbm_probe >/dev/null 2>&1 || return 1
    local r=1
    nft add chain inet sbm_probe pre '{ type filter hook prerouting priority -150 ; }' >/dev/null 2>&1 &&
        nft add rule inet sbm_probe pre meta l4proto tcp tproxy to :12345 >/dev/null 2>&1 && r=0
    nft delete table inet sbm_probe >/dev/null 2>&1
    return $r
}

nft_can_nat() {
    have nft || return 1
    nft add table inet sbm_probe >/dev/null 2>&1 || return 1
    local r=1
    nft add chain inet sbm_probe pre '{ type nat hook prerouting priority -100 ; }' >/dev/null 2>&1 && r=0
    nft delete table inet sbm_probe >/dev/null 2>&1
    return $r
}

detect_mode() {
    detect_virt; check_na; check_tun
    if   (( HAS_TUN && HAS_NA )); then PMODE=tun
    elif (( HAS_NA )) && nft_can_tproxy; then PMODE=tproxy
    else PMODE=manual; fi
    printf '%s' "$PMODE"
}

show_env() {
    ui_title "环境检测"
    kv "虚拟化" "$VIRT$( (( IN_CT )) && echo ' (容器)' )"
    msg "TUN 设备:"; (( HAS_TUN )) && ok "可用" || err "不可用"; echo
    msg "网络管理权限:"; (( HAS_NA )) && ok "具备 CAP_NET_ADMIN" || err "缺失"; echo
    msg "代理模式:"
    case $PMODE in
        tun)    ok "TUN 透明代理（全局）" ;;
        tproxy) warn "TPROXY 透明代理（全局）"; dim "  无法创建 TUN，已降级" ;;
        manual) err "本地端口代理（非全局）" ;;
    esac
    echo
}

warn_manual() {
    ui_title "受限环境提示"
    warn "无法启用全局透明代理。"
    echo
    msg "原因:"
    (( HAS_TUN )) || dim "  · 无法创建 TUN 设备"
    (( HAS_NA ))  || dim "  · 缺少 CAP_NET_ADMIN"
    (( HAS_NA )) && (( ! HAS_TUN )) && ! nft_can_tproxy && dim "  · 内核不支持 nft tproxy"
    echo
    msg "可选方案:"
    dim "  1. 使用本地代理端口（当前方式）"
    dim "  2. LXC 宿主机执行:"
    dim "     lxc config set <容器> security.nesting true"
    dim "     lxc config device add <容器> tun unix-char path=/dev/net/tun"
    dim "  3. Docker 追加: --cap-add NET_ADMIN --device /dev/net/tun"
    echo
    dim "  中转不受此限制，别人连本机仍可经远端节点出口。"
    echo
}

_V2="cx16 lahf_lm popcnt sse3 sse4_1 sse4_2 ssse3"
_V3="avx avx2 bmi1 bmi2 f16c fma movbe abm xsave"

_flags() {
    [[ -r /proc/cpuinfo ]] || return 1
    awk -F': ' '/^flags|^Features/{print $2;exit}' /proc/cpuinfo
}

_all_flags() {
    local f=" $1 " x; shift
    for x in "$@"; do [[ $f == *" $x "* ]] || return 1; done
    return 0
}

x86_level() {
    local f; f=$(_flags) || { echo 1; return; }
    if _all_flags "$f" $_V2 && _all_flags "$f" $_V3; then echo 3
    elif _all_flags "$f" $_V2; then echo 2
    else echo 1; fi
}

detect_arch() {
    local m l; m=$(uname -m)
    case $m in
        x86_64|amd64)
            l=$(x86_level); CPU_LVL="amd64-v$l"
            [[ $l == 3 ]] && SB_ARCH=amd64v3 || SB_ARCH=amd64 ;;
        i386|i486|i586|i686) SB_ARCH=386;      CPU_LVL=386 ;;
        aarch64|arm64)       SB_ARCH=arm64;    CPU_LVL=arm64 ;;
        armv8l|armv7l|armv7) SB_ARCH=armv7;    CPU_LVL=armv7 ;;
        armv6l|armv6)        SB_ARCH=armv6;    CPU_LVL=armv6 ;;
        s390x)               SB_ARCH=s390x;    CPU_LVL=s390x ;;
        ppc64le)             SB_ARCH=ppc64le;  CPU_LVL=ppc64le ;;
        riscv64)             SB_ARCH=riscv64;  CPU_LVL=riscv64 ;;
        loongarch64)         SB_ARCH=loong64;  CPU_LVL=loong64 ;;
        *) die "不支持的架构：$m" ;;
    esac
    return 0
}

NAT_MODE=0; NAT_TYPE=""; NAT_DONE=0; LADDRS=""

laddrs() { ip -o addr show scope global 2>/dev/null | awk '{split($4,a,"/");print a[1]}'; }

is_local_addr() {
    [[ -n $LADDRS ]] || LADDRS=$(laddrs)
    grep -qxF "$1" <<<"$LADDRS"
}

_priv4() {
    [[ $1 =~ ^10\. ]] && return 0
    [[ $1 =~ ^192\.168\. ]] && return 0
    [[ $1 =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
    [[ $1 =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
    return 1
}

detect_nat() {
    pub_ip
    LADDRS=$(laddrs)
    NAT_MODE=0; NAT_TYPE=""
    if [[ -z $PUB4 ]]; then
        [[ -n $PUB6 ]] && { NAT_TYPE=ipv6only; NAT_MODE=1; }
        return 0
    fi
    [[ -n $LADDRS ]] || return 0
    is_local_addr "$PUB4" && return 0
    NAT_MODE=1
    local a
    for a in $LADDRS; do
        is_v4 "$a" && _priv4 "$a" && {
            [[ $a =~ ^100\. ]] && NAT_TYPE=cgnat || NAT_TYPE=nat4; break; }
    done
    [[ -z $NAT_TYPE ]] && NAT_TYPE=nat4
    return 0
}

nat_ready() { (( NAT_DONE )) && return 0; detect_nat; NAT_DONE=1; }
nat_on()    { nat_ready; (( NAT_MODE )) && [[ $NAT_TYPE != ipv6only ]]; }

nat_pcount() {
    local n; n=$(st_get nat_ports | jq -r 'length' 2>/dev/null)
    is_uint "$n" && printf '%d' "$n" || printf '0'
}

nat_ask_ports() {
    local in r nr rs=() c
    ui_title "NAT 端口配置"
    kv "公网 IPv4" "$PUB4（共享）"
    kv "本机地址" "$(laddrs | tr '\n' ' ')"
    warn "本机处于 NAT 之后，只有服务商分配的端口能从外部连入。"
    echo
    msg "请输入服务商分配的端口:"
    dim "(如 23456-23460 或 23456 23457，空格分隔)"
    read -r -p "> " in
    for r in $in; do
        nr=$(rg_norm "$r") || { warn "格式不正确: $r"; continue; }
        rs+=("$nr")
    done
    (( ${#rs[@]} )) || { err "未录入有效端口。"; return 1; }
    st_set nat_ports "$(printf '%s\n' "${rs[@]}" | jq -R . | jq -sc .)" 1
    echo
    msg "映射方式:"
    dim "  1. 外部端口 = 内部端口"
    dim "  2. 外部端口 → 固定内部端口"
    echo
    ask_menu c "1 2"
    st_set nat_map "$( [[ $c == 1 ]] && echo same || echo custom )"
    ok "已记录"; echo
}

nat_allowed() {
    local p=$1 r
    while read -r r; do
        [[ -n $r ]] || continue
        rg_has "$p" "$r" && return 0
    done < <(st_get nat_ports | jq -r '.[]? // empty' 2>/dev/null)
    return 1
}

nat_udp_ok() {
    nat_on || return 0
    warn "NAT 环境下 UDP 协议需要服务商转发 UDP。"
    dim "  部分服务商仅转发 TCP，此时该节点无法从外部连通。"
    echo
    ask_yn "确认端口映射包含 UDP？" "Y"
}

ask_port() {
    local __v=$1 pr=${2:-tcp} __e=${3:-} in ext
    if nat_on; then
        (( $(nat_pcount) > 0 )) || nat_ask_ports || return 1
        while :; do
            msg "外部端口:"
            dim "(分配范围: $(st_get nat_ports | jq -r 'join(" ")'))"
            read -r -p "> " ext
            ext=$(trim "$ext")
            is_port "$ext" || { warn "端口不合法。"; continue; }
            nat_allowed "$ext" || { err "端口 $ext 不在分配范围内，请更换。"; continue; }
            if [[ $(st_get nat_map) == same ]]; then in=$ext
            else
                while :; do
                    msg "内部监听端口:"
                    dim "(控制台中 $ext 映射到的内部端口)"
                    read -r -p "> " in
                    in=$(trim "$in")
                    is_port "$in" && break
                    warn "端口不合法。"
                done
            fi
            echo; msg "正在检测端口..."
            port_busy "$in" "$pr" && { err "内部端口 $in 已被占用，请更换。"; echo; continue; }
            port_used "$in" && { err "内部端口 $in 已被其他节点使用，请更换。"; echo; continue; }
            kv "外部端口" "$ext"; kv "内部端口" "$in"; ok "可用"; echo
            printf -v "$__v" '%s' "$in"
            [[ -n $__e ]] && printf -v "$__e" '%s' "$ext"
            return 0
        done
    fi
    while :; do
        msg "端口:"; dim "(回车随机)"; read -r -p "> " in
        in=$(trim "$in")
        [[ -z $in ]] && { in=$(rand_port); msg "已随机分配: $in"; }
        is_port "$in" || { warn "端口需为 1-65535。"; continue; }
        echo; msg "正在检测端口..."
        port_busy "$in" "$pr" && { err "端口 $in/$pr 已被占用，请更换。"; echo; continue; }
        port_used "$in" && { err "端口 $in 已被其他节点使用，请更换。"; echo; continue; }
        kv "端口" "$in"; ok "可用"; echo
        printf -v "$__v" '%s' "$in"
        [[ -n $__e ]] && printf -v "$__e" '%s' "$in"
        return 0
    done
}

FW=""

fw_detect() {
    FW=none
    if have ufw && ufw status 2>/dev/null | grep -qi 'status: active'; then FW=ufw
    elif have nft; then FW=nft
    fi
    printf '%s' "$FW"
}

fw_type() { [[ -n $FW ]] || fw_detect >/dev/null; printf '%s' "$FW"; }

nft_input_chain() {
    have nft || return 1
    local r
    r=$(nft list chains 2>/dev/null | awk '
        /^table/{f=$2;t=$3}
        /hook input/{
            if (t ~ /^sbm_/) next
            for(i=1;i<=NF;i++) if($i=="chain"){print f,t,$(i+1);exit}
        }')
    [[ -n $r ]] || return 1
    printf '%s' "$r"
}

nft_del_tag() {
    have nft || return 0
    local tag=$1 f t c h
    while read -r f t c h; do
        [[ -n $h ]] && nft delete rule "$f" "$t" "$c" handle "$h" >/dev/null 2>&1
    done < <(nft -a list ruleset 2>/dev/null | awk -v tag="$tag" '
        /^table/{f=$2;t=$3}
        /chain /{for(i=1;i<=NF;i++) if($i=="chain") c=$(i+1)}
        $0 ~ tag {for(i=1;i<=NF;i++) if($i=="handle") print f,t,c,$(i+1)}')
}

fw_allow_rg() {
    local s=$1 e=$2 pr=${3:-tcp} spec tag f t c
    (( s == e )) && spec=$s || spec="$s-$e"
    tag="sbm-$s-$e-$pr"
    case $(fw_type) in
        ufw)
            (( s == e )) && ufw allow "$s/$pr" >/dev/null 2>&1 \
                         || ufw allow "$s:$e/$pr" >/dev/null 2>&1 ;;
        nft)
            need_nft || return 1
            if read -r f t c < <(nft_input_chain); then
                nft insert rule "$f" "$t" "$c" "$pr" dport "$spec" accept \
                    comment "\"$tag\"" >/dev/null 2>&1
            else
                nft add table inet $NFT_FILTER >/dev/null 2>&1
                nft add chain inet $NFT_FILTER input \
                    '{ type filter hook input priority -10 ; policy accept ; }' >/dev/null 2>&1
                nft add rule inet $NFT_FILTER input "$pr" dport "$spec" accept \
                    comment "\"$tag\"" >/dev/null 2>&1
            fi ;;
    esac
}

fw_del_rg() {
    local s=$1 e=$2 pr=${3:-tcp}
    case $(fw_type) in
        ufw)
            (( s == e )) && ufw delete allow "$s/$pr" >/dev/null 2>&1 \
                         || ufw delete allow "$s:$e/$pr" >/dev/null 2>&1 ;;
        nft) nft_del_tag "sbm-$s-$e-$pr" ;;
    esac
}

fw_allow() { fw_allow_rg "$1" "$1" "${2:-tcp}"; }
fw_del()   { fw_del_rg   "$1" "$1" "${2:-tcp}"; }

fw_reapply() {
    local f p pr
    [[ -d $SB_NODES ]] || return 0
    shopt -s nullglob
    for f in "$SB_NODES"/*.json; do
        p=$(jq -r '.port // empty' "$f" 2>/dev/null)
        pr=$(jq -r '.l4 // "tcp"' "$f" 2>/dev/null)
        [[ -n $p ]] && fw_allow "$p" "$pr"
    done
    shopt -u nullglob
}
_ssh_sess() {
    [[ -n ${SSH_CONNECTION:-} ]] || return 1
    awk '{print $4}' <<<"$SSH_CONNECTION"
}

_ssh_sshd_t() {
    have sshd || return 1
    sshd -T 2>/dev/null | awk '$1=="port" && $2 ~ /^[0-9]+$/{print $2}'
}

_ssh_cfg() {
    local m=/etc/ssh/sshd_config fs=() inc f
    [[ -r $m ]] || return 1
    fs+=("$m")
    while read -r inc; do
        for f in $inc; do [[ -f $f ]] && fs+=("$f"); done
    done < <(awk 'tolower($1)=="include"{$1="";print}' "$m" 2>/dev/null)
    awk 'tolower($1)=="port" && $2 ~ /^[0-9]+$/{print $2}' "${fs[@]}" 2>/dev/null
}

_ssh_proc() {
    local -A ino=()
    local pd cm fd lk i f la st
    for pd in /proc/[0-9]*; do
        [[ -r $pd/comm ]] || continue
        read -r cm <"$pd/comm" 2>/dev/null || continue
        [[ $cm == sshd* ]] || continue
        for fd in "$pd"/fd/*; do
            lk=$(readlink "$fd" 2>/dev/null) || continue
            [[ $lk =~ ^socket:\[([0-9]+)\]$ ]] && ino[${BASH_REMATCH[1]}]=1
        done
    done
    (( ${#ino[@]} )) || return 1
    for f in /proc/net/tcp /proc/net/tcp6; do
        [[ -r $f ]] || continue
        while read -r _ la _ st _ _ _ _ _ i _; do
            [[ $st == 0A ]] || continue
            [[ -n ${ino[$i]:-} ]] || continue
            printf '%d\n' "$((16#${la##*:}))"
        done < <(tail -n +2 "$f")
    done
}

ssh_ports_detect() {
    { _ssh_sess; _ssh_sshd_t; _ssh_cfg; _ssh_proc; } 2>/dev/null \
        | grep -E '^[0-9]+$' | sort -un
}

ssh_ports_confirm() {
    local det ses p fin=() ext has
    det=$(ssh_ports_detect)
    ses=$(_ssh_sess 2>/dev/null)
    [[ -z $det ]] && { warn "未检测到 SSH 端口，默认 22。"; det=22; }

    ui_title "SSH 端口确认"
    msg "以下端口将绕过代理，保持直连:"
    echo
    while read -r p; do
        [[ -n $p ]] || continue
        if [[ $p == "$ses" ]]; then
            printf '  %s  %s(当前会话，强制保护)%s\n' "$p" "$CG" "$CN"
        else printf '  %s\n' "$p"; fi
        fin+=("$p")
    done <<<"$det"
    echo
    nat_on && { dim "  这是 sshd 实际监听的内部端口，非你连接用的外部端口。"; echo; }

    if ! ask_yn "确认使用以上端口？" "Y"; then
        msg "请输入需要保护的端口，空格分隔:"
        read -r -p "> " ext
        fin=()
        for p in $ext; do
            is_port "$p" && fin+=("$p") || warn "忽略无效端口: $p"
        done
        if [[ -n $ses ]]; then
            has=0
            for p in ${fin[@]+"${fin[@]}"}; do [[ $p == "$ses" ]] && has=1; done
            (( has )) || { warn "已补回当前会话端口 $ses。"; fin+=("$ses"); }
        fi
    fi

    (( ${#fin[@]} )) || { err "没有有效的 SSH 端口。"; return 1; }
    mkdir -p "$SB_ROOT"
    printf '%s\n' "${fin[@]}" | sort -un >"$SSH_PORTS"
    ok "已记录 $(wc -l <"$SSH_PORTS") 个保护端口"
    return 0
}

collect_protected() {
    local ps=() f p
    mkdir -p "$SB_ROOT"
    if [[ ! -s $SSH_PORTS ]]; then
        if (( SBM_BATCH )); then
            ssh_ports_detect >"$SSH_PORTS" 2>/dev/null
            [[ -s $SSH_PORTS ]] || printf '22\n' >"$SSH_PORTS"
        else
            ssh_ports_confirm || return 1
        fi
    fi
    while read -r p; do [[ -n $p ]] && ps+=("$p"); done <"$SSH_PORTS"
    shopt -s nullglob
    for f in "$SB_NODES"/*.json; do
        p=$(jq -r '.port // empty' "$f" 2>/dev/null)
        [[ -n $p ]] && ps+=("$p")
    done
    shopt -u nullglob
    printf '%s\n' "${ps[@]}" | sort -un >"$PROT_PORTS"
}

bypass_apply() {
    local p pr
    collect_protected || return 1
    need_iproute || return 1
    need_nft || return 1
    ip    rule del fwmark $MARK_BYPASS lookup main pref $PREF_BYPASS >/dev/null 2>&1
    ip -6 rule del fwmark $MARK_BYPASS lookup main pref $PREF_BYPASS >/dev/null 2>&1
    ip    rule add fwmark $MARK_BYPASS lookup main pref $PREF_BYPASS >/dev/null 2>&1
    ip -6 rule add fwmark $MARK_BYPASS lookup main pref $PREF_BYPASS >/dev/null 2>&1
    nft add table inet $NFT_BYPASS >/dev/null 2>&1
    nft flush table inet $NFT_BYPASS >/dev/null 2>&1
    nft add chain inet $NFT_BYPASS output \
        '{ type route hook output priority -160 ; }' >/dev/null 2>&1 || return 1
    while read -r p; do
        [[ -n $p ]] || continue
        for pr in tcp udp; do
            nft add rule inet $NFT_BYPASS output "$pr" sport "$p" \
                meta mark set $MARK_BYPASS >/dev/null 2>&1
        done
    done <"$PROT_PORTS"
    return 0
}

bypass_clear() {
    ip    rule del fwmark $MARK_BYPASS lookup main pref $PREF_BYPASS >/dev/null 2>&1
    ip -6 rule del fwmark $MARK_BYPASS lookup main pref $PREF_BYPASS >/dev/null 2>&1
    have nft && nft delete table inet $NFT_BYPASS >/dev/null 2>&1
    return 0
}

bypass_refresh() {
    proxy_on || return 0
    [[ $(st_get proxy_mode) == manual ]] && return 0
    bypass_clear
    bypass_apply
}

tproxy_apply() {
    need_iproute || return 1
    need_nft || return 1
    ip    rule del fwmark $MARK_TPROXY lookup $TBL_TPROXY pref $PREF_TPROXY >/dev/null 2>&1
    ip -6 rule del fwmark $MARK_TPROXY lookup $TBL_TPROXY pref $PREF_TPROXY >/dev/null 2>&1
    ip    rule add fwmark $MARK_TPROXY lookup $TBL_TPROXY pref $PREF_TPROXY >/dev/null 2>&1
    ip    route replace local default dev lo table $TBL_TPROXY >/dev/null 2>&1
    ip -6 rule add fwmark $MARK_TPROXY lookup $TBL_TPROXY pref $PREF_TPROXY >/dev/null 2>&1
    ip -6 route replace local default dev lo table $TBL_TPROXY >/dev/null 2>&1

    nft add table inet $NFT_TPROXY >/dev/null 2>&1
    nft flush table inet $NFT_TPROXY >/dev/null 2>&1

    nft add chain inet $NFT_TPROXY output \
        '{ type route hook output priority -150 ; }' >/dev/null 2>&1 || return 1
    nft add rule inet $NFT_TPROXY output meta mark $MARK_BYPASS return >/dev/null 2>&1
    nft add rule inet $NFT_TPROXY output fib daddr type local return >/dev/null 2>&1
    nft add rule inet $NFT_TPROXY output ip daddr \
        '{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 }' \
        return >/dev/null 2>&1
    nft add rule inet $NFT_TPROXY output ip6 daddr \
        '{ fe80::/10, fc00::/7, ff00::/8 }' return >/dev/null 2>&1
    nft add rule inet $NFT_TPROXY output meta l4proto '{ tcp, udp }' \
        meta mark set $MARK_TPROXY >/dev/null 2>&1

    nft add chain inet $NFT_TPROXY prerouting \
        '{ type filter hook prerouting priority -150 ; }' >/dev/null 2>&1 || return 1
    nft add rule inet $NFT_TPROXY prerouting iif != lo return >/dev/null 2>&1
    nft add rule inet $NFT_TPROXY prerouting meta mark != $MARK_TPROXY return >/dev/null 2>&1
    nft add rule inet $NFT_TPROXY prerouting meta l4proto '{ tcp, udp }' \
        tproxy to ":$PORT_TPROXY" accept >/dev/null 2>&1 || return 1

    guard_apply
    return 0
}

tproxy_clear() {
    ip    rule del fwmark $MARK_TPROXY lookup $TBL_TPROXY pref $PREF_TPROXY >/dev/null 2>&1
    ip -6 rule del fwmark $MARK_TPROXY lookup $TBL_TPROXY pref $PREF_TPROXY >/dev/null 2>&1
    ip    route flush table $TBL_TPROXY >/dev/null 2>&1
    ip -6 route flush table $TBL_TPROXY >/dev/null 2>&1
    have nft && nft delete table inet $NFT_TPROXY >/dev/null 2>&1
    guard_clear
    return 0
}

guard_apply() {
    have nft || return 0
    nft add table inet $NFT_GUARD >/dev/null 2>&1
    nft flush table inet $NFT_GUARD >/dev/null 2>&1
    nft add chain inet $NFT_GUARD input \
        '{ type filter hook input priority -20 ; }' >/dev/null 2>&1
    nft add rule inet $NFT_GUARD input iif lo accept >/dev/null 2>&1
    nft add rule inet $NFT_GUARD input meta l4proto '{ tcp, udp }' \
        th dport $PORT_TPROXY drop >/dev/null 2>&1
}

guard_clear() {
    have nft && nft delete table inet $NFT_GUARD >/dev/null 2>&1
    return 0
}

rules_all() {
    fw_detect >/dev/null
    [[ $FW == nft ]] && { fw_reapply; hop_reapply; }
    if proxy_on && [[ $(st_get proxy_mode) != manual ]]; then
        bypass_apply
        [[ $(st_get proxy_mode) == tproxy ]] && tproxy_apply
    fi
    return 0
}

st_init() {
    mkdir -p "$SB_ROOT"; chmod 700 "$SB_ROOT"
    [[ -f $SB_STATE ]] && return 0
    cat >"$SB_STATE" <<'EOF'
{
  "relay": true,
  "proxy": false,
  "active_peer": "",
  "proxy_mode": "",
  "mixed_port": 0,
  "mixed_user": "",
  "mixed_pass": "",
  "nat_ports": [],
  "nat_map": "same"
}
EOF
    chmod 600 "$SB_STATE"
}

st_get() {
    st_init
    jq -r --arg k "$1" 'if .[$k] == null then empty
        elif (.[$k]|type) == "array" or (.[$k]|type) == "object" then (.[$k]|tojson)
        else .[$k] end' "$SB_STATE" 2>/dev/null
}

st_set() {
    local k=$1 v=$2 raw=${3:-0} t=$SB_STATE.tmp
    st_init
    if (( raw )); then jq --arg k "$k" --argjson v "$v" '.[$k]=$v' "$SB_STATE" >"$t"
    else jq --arg k "$k" --arg v "$v" '.[$k]=$v' "$SB_STATE" >"$t"; fi
    [[ -s $t ]] && { mv "$t" "$SB_STATE"; chmod 600 "$SB_STATE"; } || rm -f "$t"
}

relay_on() { [[ $(st_get relay) == true ]]; }
proxy_on() { [[ $(st_get proxy) == true ]]; }

mix_port() {
    local p; p=$(st_get mixed_port)
    if ! is_port "$p"; then
        while :; do
            p=$(( (RANDOM % 20000) + 40000 ))
            port_busy "$p" tcp && continue
            port_used "$p" && continue
            break
        done
        st_set mixed_port "$p" 1
    fi
    printf '%d' "$p"
}

mix_user() {
    local u; u=$(st_get mixed_user)
    [[ -n $u ]] || { u="sbm-$(gen_pass 8)"; st_set mixed_user "$u"; }
    printf '%s' "$u"
}

mix_pass() {
    local p; p=$(st_get mixed_pass)
    [[ -n $p ]] || { p=$(gen_pass 24); st_set mixed_pass "$p"; }
    printf '%s' "$p"
}

mix_auth() { printf '%s:%s@127.0.0.1:%s' "$(mix_user)" "$(mix_pass)" "$(mix_port)"; }

show_mix_usage() {
    local p u pw
    p=$(mix_port); u=$(mix_user); pw=$(mix_pass)
    echo
    msg "本地代理端口:"
    echo
    printf '  SOCKS5 / HTTP  127.0.0.1:%s\n' "$p"
    printf '  用户名          %s\n' "$u"
    printf '  密码            %s\n' "$pw"
    echo
    msg "命令行使用:"
    dim "  export ALL_PROXY=socks5h://$u:$pw@127.0.0.1:$p"
    dim "  curl -x socks5h://$u:$pw@127.0.0.1:$p https://api.ipify.org"
    echo
    warn "该端口仅监听回环，不应尝试暴露。"
    dim "  需给局域网设备使用时，请添加 SOCKS5 服务端节点。"
    echo
}

sb_ver() { [[ -x $SB_BIN ]] || return 1; "$SB_BIN" version 2>/dev/null | awk '/version/{print $3;exit}'; }

sb_latest() {
    http_get "https://api.github.com/repos/$SB_REPO/releases/latest" \
        | jq -r '.tag_name // empty' | sed 's/^v//'
}

sb_install() {
    local v=${1:-} pkg d url bin
    pkg_ensure jq || return 1
    pkg_ensure tar || return 1
    [[ -z $v ]] && v=$(sb_latest)
    [[ -n $v ]] || { err "无法获取版本信息，请检查网络与根证书。"; return 1; }
    pkg="sing-box-$v-linux-$SB_ARCH"
    url="https://github.com/$SB_REPO/releases/download/v$v/$pkg.tar.gz"
    kv "版本" "$v"; kv "CPU" "$CPU_LVL"; kv "下载" "$pkg"
    d=$(mktemp -d) || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$d'" RETURN
    if have curl; then curl -fL --retry 3 --connect-timeout 10 -o "$d/sb.tgz" "$url" 2>/dev/null
    else wget -qO "$d/sb.tgz" --tries=3 "$url" 2>/dev/null; fi
    [[ -s $d/sb.tgz ]] || { err "下载失败: $url"; return 1; }
    tar -xzf "$d/sb.tgz" -C "$d" 2>/dev/null || { err "解压失败。"; return 1; }
    bin=$(find "$d" -type f -name sing-box | head -n1)
    [[ -n $bin ]] || { err "压缩包内未找到可执行文件。"; return 1; }
    install -m 0755 "$bin" "$SB_BIN" || { err "写入 $SB_BIN 失败。"; return 1; }
    "$SB_BIN" version >/dev/null 2>&1 || { err "无法运行，架构可能不匹配（$SB_ARCH）。"; return 1; }
    ok "安装完成 $(sb_ver)"
}

sb_upgrade() {
    local cur new
    cur=$(sb_ver) || { sb_install; return $?; }
    ui_title "更新 sing-box"
    kv "当前版本" "$cur"
    msg "检测最新版本..."
    new=$(sb_latest)
    [[ -n $new ]] || { err "无法获取最新版本。"; return 1; }
    kv "最新版本" "$new"
    ver_gt "$new" "$cur" || { ok "已是最新版本"; return 0; }
    ask_yn "升级到 $new？" "Y" || return 1
    sb_install "$new" || return 1
    if [[ -f $SB_CONF ]] && ! "$SB_BIN" check -c "$SB_CONF" >/dev/null 2>&1; then
        warn "现有配置在新版本下校验未通过:"; conf_err "$SB_CONF"
    fi
    msg "重启服务:"
    svc_up "$SVC_SB" && svc_restart "$SVC_SB"
    ok "完成"
}

nd_dir()  { [[ $1 == nodes ]] && printf '%s' "$SB_NODES" || printf '%s' "$SB_PEERS"; }
nd_path() { printf '%s/%s.json' "$(nd_dir "$1")" "$2"; }
nd_has()  { [[ -f $(nd_path "$1" "$2") ]]; }

nd_list() {
    local d f; d=$(nd_dir "$1")
    [[ -d $d ]] || return 0
    shopt -s nullglob
    for f in "$d"/*.json; do basename "$f" .json; done
    shopt -u nullglob
}

nd_count() { nd_list "$1" | grep -c . ; }
nd_get()   { jq -r --arg k "$3" '.[$k]     // empty' "$(nd_path "$1" "$2")" 2>/dev/null; }
nd_meta()  { jq -r --arg k "$3" '.meta[$k] // empty' "$(nd_path "$1" "$2")" 2>/dev/null; }

nd_save() {
    local r=$1 n=$2 j=$3 d p
    d=$(nd_dir "$r"); mkdir -p "$d"; chmod 700 "$d"
    p=$d/$n.json
    printf '%s\n' "$j" | jq . >"$p.tmp" 2>/dev/null || {
        rm -f "$p.tmp"; err "节点数据写入失败。"; return 1; }
    mv "$p.tmp" "$p"; chmod 600 "$p"
}

nd_del() { rm -f "$(nd_path "$1" "$2")"; }

nd_set() {
    local r=$1 k=$3 v=$4 raw=${5:-0} p t
    p=$(nd_path "$r" "$2")
    [[ -f $p ]] || return 1
    t=$p.tmp
    if (( raw )); then jq --arg k "$k" --argjson v "$v" '.[$k]=$v' "$p" >"$t"
    else jq --arg k "$k" --arg v "$v" '.[$k]=$v' "$p" >"$t"; fi
    [[ -s $t ]] && mv "$t" "$p" || { rm -f "$t"; return 1; }
}

nd_rename() {
    local r=$1 o=$2 n=$3 d t
    d=$(nd_dir "$r")
    [[ -f $d/$o.json ]] || return 1
    [[ -e $d/$n.json ]] && { err "名称已存在。"; return 1; }
    mv "$d/$o.json" "$d/$n.json"
    t=$d/$n.json.tmp
    jq --arg n "$n" '.name=$n
        | if .inbound  then .inbound.tag=$n  else . end
        | if .outbound then .outbound.tag=$n else . end' "$d/$n.json" >"$t" \
        && mv "$t" "$d/$n.json"
}

port_used() {
    local p=$1 f
    [[ $p == "$PORT_TPROXY" ]] && return 0
    [[ $p == "$(jq -r '.mixed_port // 0' "$SB_STATE" 2>/dev/null)" ]] && return 0
    shopt -s nullglob
    for f in "$SB_NODES"/*.json; do
        [[ $(jq -r '.port // empty' "$f" 2>/dev/null) == "$p" ]] && { shopt -u nullglob; return 0; }
    done
    shopt -u nullglob
    hop_covers "$p" && return 0
    return 1
}

ask_name() {
    local __v=$1 r=$2 in
    while :; do
        msg "节点名称:"; read -r -p "> " in
        in=$(trim "$in")
        is_name "$in" || { warn "非空、≤32 字符、不含 / \\ : * ? \" < > |、首尾无空格。"; continue; }
        nd_has "$r" "$in" && { warn "名称已存在。"; continue; }
        printf -v "$__v" '%s' "$in"; echo; return 0
    done
}

ask_uuid() {
    local __v=$1 in
    while :; do
        msg "UUID:"; dim "(回车随机)"; read -r -p "> " in
        in=$(trim "$in")
        if [[ -z $in ]]; then
            in=$(gen_uuid); dim "已生成: $in"; echo
            printf -v "$__v" '%s' "$in"; return 0
        fi
        [[ $in =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
            && { echo; printf -v "$__v" '%s' "$in"; return 0; }
        warn "UUID 格式不正确。"
    done
}

ask_pass() {
    local __v=$1 l=${2:-密码} in
    msg "$l:"; dim "(回车随机)"; read -r -p "> " in
    in=$(trim "$in")
    [[ -z $in ]] && { in=$(gen_pass 16); dim "已生成: $in"; }
    echo
    printf -v "$__v" '%s' "$in"
}

def_addr() {
    pub_ip
    [[ -n $PUB4 ]] && { printf '%s' "$PUB4"; return 0; }
    [[ -n $PUB6 ]] && { printf '%s' "$PUB6"; return 0; }
    return 1
}
lk_build() {
    local r=$1 n=$2 pov=${3:-} p pt sv pr fg hp uu pw sn pk sd us cc mp
    p=$(nd_path "$r" "$n")
    [[ -f $p ]] || return 1
    pr=$(jq -r '.protocol' "$p")
    sv=$(jq -r '.server // ""' "$p")
    [[ -n ${LK_HOST:-} ]] && sv=$LK_HOST
    pt=$(jq -r '.ext_port // .port' "$p")
    [[ -n $pov ]] && pt=$pov
    fg=$(urlenc "$n")
    hp=$(hostport "$sv" "$pt")
    uu=$(jq -r '.meta.uuid // ""' "$p")
    pw=$(jq -r '.meta.password // ""' "$p")
    sn=$(jq -r '.meta.sni // ""' "$p")
    pk=$(jq -r '.meta.public_key // ""' "$p")
    sd=$(jq -r '.meta.short_id // ""' "$p")
    us=$(jq -r '.meta.username // ""' "$p")
    cc=$(jq -r '.meta.congestion_control // "bbr"' "$p")
    case $pr in
        vless-reality)
            printf 'vless://%s@%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
                "$uu" "$hp" "$(urlenc "$sn")" "$pk" "$sd" "$fg" ;;
        vless-tls)
            printf 'vless://%s@%s?encryption=none&flow=xtls-rprx-vision&security=tls&sni=%s&fp=chrome&type=tcp#%s' \
                "$uu" "$hp" "$(urlenc "$sn")" "$fg" ;;
        hysteria2)
            mp=$(jq -r 'if (.hop.enabled // false) and (.hop.auto // false)
                        then (.hop.ranges // [] | join(",")) else "" end' "$p")
            if [[ -n $mp && -z $pov ]]; then
                printf 'hysteria2://%s@%s/?sni=%s&alpn=h3&mport=%s#%s' \
                    "$(urlenc "$pw")" "$hp" "$(urlenc "$sn")" "$mp" "$fg"
            else
                printf 'hysteria2://%s@%s/?sni=%s&alpn=h3#%s' \
                    "$(urlenc "$pw")" "$hp" "$(urlenc "$sn")" "$fg"
            fi ;;
        tuic)
            printf 'tuic://%s:%s@%s?congestion_control=%s&alpn=h3&sni=%s&udp_relay_mode=native#%s' \
                "$uu" "$(urlenc "$pw")" "$hp" "$cc" "$(urlenc "$sn")" "$fg" ;;
        trojan)
            printf 'trojan://%s@%s?security=tls&sni=%s&fp=chrome&type=tcp#%s' \
                "$(urlenc "$pw")" "$hp" "$(urlenc "$sn")" "$fg" ;;
        anytls)
            printf 'anytls://%s@%s?sni=%s&insecure=0#%s' \
                "$(urlenc "$pw")" "$hp" "$(urlenc "$sn")" "$fg" ;;
        socks5)
            printf 'socks5://%s:%s@%s#%s' \
                "$(urlenc "$us")" "$(urlenc "$pw")" "$hp" "$fg" ;;
        *) return 1 ;;
    esac
}

lk_refresh() {
    local l
    l=$(lk_build "$1" "$2") || return 1
    nd_set "$1" "$2" link "$l"
    printf '%s' "$l"
}

lk_v6() {
    local r=$1 n=$2 p
    p=$(nd_path "$r" "$n")
    pub_ip
    [[ -n $PUB6 ]] || return 1
    [[ -n $(jq -r '.meta.domain // empty' "$p") ]] && return 1
    LK_HOST=$PUB6 lk_build "$r" "$n" "$(jq -r '.port' "$p")"
}

qs_get() {
    local q=$1 k=$2 kv
    while IFS= read -r kv; do
        [[ ${kv%%=*} == "$k" ]] && { urldec "${kv#*=}"; return 0; }
    done < <(printf '%s\n' "${q//&/$'\n'}")
    return 1
}

lk_parse() {
    local u=$1 sc rs fg bd ui hp h pt qs sn ins out pr pn l4 mt
    u=$(trim "$u")
    sc=$(tr '[:upper:]' '[:lower:]' <<<"${u%%://*}")
    rs=${u#*://}
    if [[ $rs == *#* ]]; then fg=$(urldec "${rs##*#}"); rs=${rs%%#*}; else fg=""; fi
    if [[ $rs == *\?* ]]; then qs=${rs#*\?}; bd=${rs%%\?*}; else qs=""; bd=$rs; fi
    bd=${bd%/}
    if [[ $bd == *@* ]]; then ui=${bd%@*}; hp=${bd##*@}; else ui=""; hp=$bd; fi
    if [[ $hp == \[*\]:* ]]; then h=${hp%%\]:*}; h=${h#\[}; pt=${hp##*\]:}
    else h=${hp%%:*}; pt=${hp##*:}; fi
    [[ -n $h ]] || return 1
    is_port "$pt" || return 1
    sn=$(qs_get "$qs" sni || qs_get "$qs" peer || printf '%s' "$h")
    ins=$(qs_get "$qs" insecure || qs_get "$qs" allowInsecure || printf 0)
    [[ $ins == 1 || $ins == true ]] && ins=true || ins=false
    case $sc in
        vless)
            local uu fl se pk sd fp
            uu=$(urldec "$ui")
            fl=$(qs_get "$qs" flow || printf '')
            se=$(qs_get "$qs" security || printf none)
            fp=$(qs_get "$qs" fp || printf chrome)
            l4=tcp
            if [[ $se == reality ]]; then
                pk=$(qs_get "$qs" pbk || printf '')
                sd=$(qs_get "$qs" sid || printf '')
                [[ -n $pk ]] || { err "Reality 链接缺少 pbk。"; return 1; }
                pr=vless-reality; pn="VLESS Reality Vision"
                out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg u "$uu" --arg f "$fl" \
                    --arg n "$sn" --arg fp "$fp" --arg k "$pk" --arg d "$sd" '{
                      type:"vless", server:$s, server_port:$p, uuid:$u,
                      flow:(if $f=="" then "xtls-rprx-vision" else $f end),
                      tls:{enabled:true, server_name:$n,
                           utls:{enabled:true,fingerprint:$fp},
                           reality:{enabled:true,public_key:$k,short_id:$d}}}')
                mt=$(jq -nc --arg u "$uu" --arg n "$sn" --arg k "$pk" --arg d "$sd" \
                    '{uuid:$u,sni:$n,public_key:$k,short_id:$d}')
            elif [[ $se == tls ]]; then
                pr=vless-tls; pn="VLESS TLS Vision"
                out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg u "$uu" --arg f "$fl" \
                    --arg n "$sn" --arg fp "$fp" --argjson i "$ins" '{
                      type:"vless", server:$s, server_port:$p, uuid:$u,
                      flow:(if $f=="" then "xtls-rprx-vision" else $f end),
                      tls:{enabled:true, server_name:$n, insecure:$i,
                           utls:{enabled:true,fingerprint:$fp}}}')
                mt=$(jq -nc --arg u "$uu" --arg n "$sn" '{uuid:$u,sni:$n}')
            else
                err "不支持的 VLESS 安全层: $se（仅 reality / tls）"; return 1
            fi ;;
        hysteria2|hy2)
            pr=hysteria2; pn="Hysteria2"; l4=udp
            local pw mp sp
            pw=$(urldec "$ui")
            mp=$(qs_get "$qs" mport || qs_get "$qs" ports || printf '')
            if [[ -n $mp ]]; then
                sp=$(printf '%s' "$mp" | tr ',' '\n' | sed 's/-/:/' \
                    | jq -R . | jq -sc 'map(select(length>0))')
            else sp="[]"; fi
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg w "$pw" --arg n "$sn" \
                --argjson i "$ins" --argjson sp "$sp" '
                {type:"hysteria2", server:$s, password:$w,
                 tls:{enabled:true,server_name:$n,alpn:["h3"],insecure:$i}}
                + (if ($sp|length)>0 then {server_ports:$sp,hop_interval:"30s"}
                   else {server_port:$p} end)')
            mt=$(jq -nc --arg w "$pw" --arg n "$sn" --arg m "$mp" \
                '{password:$w,sni:$n,mport:$m}') ;;
        tuic)
            pr=tuic; pn="TUIC"; l4=udp
            [[ $ui == *:* ]] || { err "TUIC 链接缺少密码。"; return 1; }
            local uu pw cc
            uu=${ui%%:*}; pw=$(urldec "${ui#*:}")
            cc=$(qs_get "$qs" congestion_control || printf bbr)
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg u "$uu" --arg w "$pw" \
                --arg n "$sn" --arg c "$cc" --argjson i "$ins" '{
                  type:"tuic", server:$s, server_port:$p, uuid:$u, password:$w,
                  congestion_control:$c, udp_relay_mode:"native",
                  tls:{enabled:true,server_name:$n,alpn:["h3"],insecure:$i}}')
            mt=$(jq -nc --arg u "$uu" --arg w "$pw" --arg n "$sn" --arg c "$cc" \
                '{uuid:$u,password:$w,sni:$n,congestion_control:$c}') ;;
        trojan)
            pr=trojan; pn="Trojan TLS"; l4=tcp
            local pw; pw=$(urldec "$ui")
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg w "$pw" --arg n "$sn" \
                --argjson i "$ins" '{
                  type:"trojan", server:$s, server_port:$p, password:$w,
                  tls:{enabled:true,server_name:$n,insecure:$i,
                       utls:{enabled:true,fingerprint:"chrome"}}}')
            mt=$(jq -nc --arg w "$pw" --arg n "$sn" '{password:$w,sni:$n}') ;;
        anytls)
            pr=anytls; pn="AnyTLS"; l4=tcp
            local pw; pw=$(urldec "$ui")
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg w "$pw" --arg n "$sn" \
                --argjson i "$ins" '{
                  type:"anytls", server:$s, server_port:$p, password:$w,
                  tls:{enabled:true,server_name:$n,insecure:$i}}')
            mt=$(jq -nc --arg w "$pw" --arg n "$sn" '{password:$w,sni:$n}') ;;
        socks5|socks)
            pr=socks5; pn="SOCKS5"; l4=tcp
            local us pw dc
            if [[ $ui == *:* ]]; then us=$(urldec "${ui%%:*}"); pw=$(urldec "${ui#*:}")
            else
                dc=$(printf '%s' "$ui" | base64 -d 2>/dev/null)
                if [[ $dc == *:* ]]; then us=${dc%%:*}; pw=${dc#*:}; else us=""; pw=""; fi
            fi
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg u "$us" --arg w "$pw" '
                {type:"socks", server:$s, server_port:$p, version:"5"}
                + (if $u != "" then {username:$u} else {} end)
                + (if $w != "" then {password:$w} else {} end)')
            mt=$(jq -nc --arg u "$us" --arg w "$pw" '{username:$u,password:$w}') ;;
        *)
            err "无法识别的协议: $sc://"
            dim "  支持 vless:// hysteria2:// hy2:// tuic:// trojan:// anytls:// socks5://"
            return 1 ;;
    esac
    [[ -z $fg ]] && fg="$h-$pt"
    jq -nc --arg pr "$pr" --arg pn "$pn" --arg n "$fg" --arg s "$h" \
        --argjson p "$pt" --arg l "$l4" --argjson o "$out" --argjson m "$mt" '{
          protocol:$pr, protocol_name:$pn, name:$n, server:$s,
          port:$p, ext_port:$p, l4:$l, outbound:$o, meta:$m}'
}

peer_ips() {
    local f s
    shopt -s nullglob
    for f in "$SB_PEERS"/*.json; do
        s=$(jq -r '.server // empty' "$f" 2>/dev/null)
        [[ -n $s ]] || continue
        if is_ip "$s"; then printf '%s\n' "$s"; else resolve "$s" 2>/dev/null; fi
    done
    shopt -u nullglob
}

mix_inbound() {
    jq -nc --argjson p "$(mix_port)" --arg u "$(mix_user)" --arg w "$(mix_pass)" '{
      type:"mixed", tag:"mixed-in", listen:"127.0.0.1", listen_port:$p,
      users:[{username:$u,password:$w}]}'
}

cfg_build() {
    local pe md pon ron fs=() nin="[]" tags="[]" lin="[]" pout=null pips="[]"
    pe=$(st_get active_peer)
    md=$(st_get proxy_mode); [[ -z $md ]] && md=manual
    proxy_on && pon=true || pon=false
    relay_on && ron=true || ron=false
    shopt -s nullglob; fs=("$SB_NODES"/*.json); shopt -u nullglob
    if (( ${#fs[@]} )); then
        nin=$(jq -s '[.[].inbound]' "${fs[@]}")
        tags=$(jq -s '[.[].inbound.tag]' "${fs[@]}")
    fi
    if [[ -n $pe && -f $SB_PEERS/$pe.json ]]; then
        pout=$(jq -c --argjson m "$((MARK_BYPASS))" \
            '.outbound | .tag="proxy" | .routing_mark=$m' "$SB_PEERS/$pe.json")
    fi
    pips=$(peer_ips | sort -u | jq -R . | jq -sc 'map(select(length>0))')
    if [[ $pon == true ]]; then
        case $md in
            tun) lin='[{"type":"tun","tag":"tun-in","interface_name":"sbm-tun0",
                 "address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],"mtu":9000,
                 "auto_route":true,"strict_route":false,"stack":"mixed"}]' ;;
            tproxy) lin=$(jq -nc --argjson p "$PORT_TPROXY" \
                 '[{type:"tproxy",tag:"tproxy-in",listen:"::",listen_port:$p}]') ;;
            manual) lin=$(jq -nc --argjson m "$(mix_inbound)" '[$m]') ;;
        esac
    fi
    jq -n --argjson nin "$nin" --argjson lin "$lin" --argjson tags "$tags" \
        --argjson peer "$pout" --argjson pips "$pips" --argjson mark "$((MARK_BYPASS))" \
        --argjson relay "$ron" --argjson proxy "$pon" '
      ($peer != null) as $has
      | (if $has and $relay then "proxy" else "direct" end) as $ro
      | (if $has and $proxy then "proxy" else "direct" end) as $lo
      | (($tags|length) > 0) as $hn
      | {
          log:{level:"warn",timestamp:true},
          dns:{
            servers:((if $has then [{tag:"remote",address:"tls://1.1.1.1",detour:"proxy"}] else [] end)
                     + [{tag:"local",address:"local",detour:"direct"}]),
            rules:(if $hn then [{inbound:$tags,
                     server:(if $ro=="proxy" then "remote" else "local" end)}] else [] end),
            final:(if $lo=="proxy" then "remote" else "local" end),
            strategy:"prefer_ipv4"
          },
          inbounds:($nin + $lin),
          outbounds:((if $has then [$peer] else [] end)
                     + [{type:"direct",tag:"direct",routing_mark:$mark}]),
          route:{
            rules:([{action:"sniff"},{protocol:"dns",action:"hijack-dns"}]
                   + (if ($pips|length)>0 then [{ip_cidr:$pips,outbound:"direct"}] else [] end)
                   + [{ip_is_private:true,outbound:"direct"}]
                   + (if $hn then [{inbound:$tags,outbound:$ro}] else [] end)),
            auto_detect_interface:true,
            final:$lo
          }
        }'
}

cfg_write() {
    local t=$SB_CONF.new
    mkdir -p "$SB_ROOT"
    printf '%s\n' "$1" >"$t" || { err "写入失败。"; return 1; }
    jq empty "$t" 2>/dev/null || { err "生成的配置不是合法 JSON。"; rm -f "$t"; return 1; }
    if [[ -x $SB_BIN ]] && ! "$SB_BIN" check -c "$t" >/dev/null 2>&1; then
        err "配置校验失败"; conf_err "$t"
        dim "  （若为协议不支持，请先更新 sing-box）"
        rm -f "$t"; return 1
    fi
    mv "$t" "$SB_CONF"; chmod 600 "$SB_CONF"
}

cfg_apply() {
    local c
    c=$(cfg_build) || return 1
    cfg_write "$c" || return 1
    if [[ $(jq '.inbounds | length' "$SB_CONF") == 0 ]]; then
        svc_up "$SVC_SB" && svc_stop "$SVC_SB"
        return 0
    fi
    svc_has "$SVC_SB" || install_sb_unit
    if svc_up "$SVC_SB"; then svc_restart "$SVC_SB"; else svc_start "$SVC_SB"; fi
    sleep 2
    svc_up "$SVC_SB" && return 0
    err "sing-box 启动失败。"; svc_log_hint
    return 1
}

warn_reload() {
    (( $(nd_count nodes) > 0 )) || return 0
    warn "此操作需重载配置，连接本机的用户会断开约 1 秒（客户端自动重连）。"
    ask_yn "继续？" "Y"
}

acme_has()   { [[ -x $ACME ]]; }
cert_dom()   { cat "$CERT_DOMAIN" 2>/dev/null; }
cert_ready() { [[ -s $TLS_CRT && -s $TLS_KEY ]]; }

reload_cmd() {
    case $INIT in
        systemd) printf 'systemctl restart %s' "$SVC_SB" ;;
        openrc)  printf 'rc-service %s restart' "$SVC_SB" ;;
    esac
}

tls_nodes() {
    local f n=0
    shopt -s nullglob
    for f in "$SB_NODES"/*.json; do
        [[ -n $(jq -r '.meta.domain // empty' "$f" 2>/dev/null) ]] && n=$(( n + 1 ))
    done
    shopt -u nullglob
    printf '%d' "$n"
}

acme_setup() {
    acme_has && return 0
    ui_title "安装 acme.sh"
    pkg_ensure curl || return 1
    pkg_ensure openssl || return 1
    pkg_ensure socat || warn "socat 安装失败，HTTP 验证可能不可用。"
    have crontab || pkg_ensure crontab || warn "cron 不可用，证书无法自动续期。"
    if [[ $FAMILY == alpine ]]; then
        rc-update add dcron default >/dev/null 2>&1
        rc-service dcron start >/dev/null 2>&1
    fi
    local em
    while :; do
        msg "证书注册邮箱:"; dim "(用于到期提醒)"; read -r -p "> " em
        em=$(trim "$em")
        [[ $em =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]] && break
        warn "邮箱格式不正确。"
    done
    echo
    msg "正在安装..."
    curl -fsSL https://get.acme.sh | sh -s email="$em" >/dev/null 2>&1
    acme_has || { err "acme.sh 安装失败。"; return 1; }
    "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1
    "$ACME" --upgrade --auto-upgrade >/dev/null 2>&1
    ok "acme.sh 就绪"; echo
}

dom_here() {
    local ips a
    ips=$(resolve "$1") || return 0
    [[ -z $ips ]] && return 1
    pub_ip
    for a in $ips; do
        [[ $a == "$PUB4" || $a == "$PUB6" ]] && return 0
        is_local_addr "$a" && return 0
    done
    return 1
}

acme_issue() {
    local d=$1 md=standalone c api v6=""
    nat_ready
    if nat_on; then
        warn "NAT 环境无法使用 HTTP 验证（80 端口不可映射）。"
        md=dns
    elif (( NAT_MODE )) && [[ $NAT_TYPE == ipv6only ]]; then
        warn "本机仅有公网 IPv6，将使用 IPv6 进行 HTTP 验证。"
        dim "  需确保 AAAA 记录指向 $PUB6"
        v6="--listen-v6"
    elif ! dom_here "$d"; then
        warn "域名 $d 未解析到本机。"
        dim "  本机: ${PUB4:-无} ${PUB6:-无}"
        if ask_yn "改用 DNS API 验证？" "N"; then md=dns
        elif ! ask_yn "仍尝试 HTTP 验证？" "N"; then return 1; fi
    fi
    if [[ $md == dns ]]; then
        msg "选择 DNS 服务商:"; echo
        msg "  1. Cloudflare"; msg "  2. 阿里云"; msg "  3. 腾讯云 DNSPod"; echo
        ask_menu c "1 2 3"
        case $c in
            1) api=dns_cf; local t; ask_req t "Cloudflare API Token:"; export CF_Token="$t" ;;
            2) api=dns_ali; local k s; ask_req k "AccessKey ID:"; ask_req s "AccessKey Secret:"
               export Ali_Key="$k" Ali_Secret="$s" ;;
            3) api=dns_dp; local i t2; ask_req i "DNSPod ID:"; ask_req t2 "DNSPod Token:"
               export DP_Id="$i" DP_Key="$t2" ;;
        esac
        msg "正在申请证书（DNS 验证）..."
        "$ACME" --issue -d "$d" --dns "$api" --keylength ec-256 \
            --server letsencrypt >/dev/null 2>&1 || { err "证书申请失败"; return 1; }
    else
        port_busy 80 tcp && {
            err "80 端口被占用，HTTP 验证无法进行。"
            dim "  请停止占用者或改用 DNS API 验证。"
            return 1; }
        fw_allow 80 tcp
        msg "正在申请证书（HTTP 验证）..."
        if ! "$ACME" --issue -d "$d" --standalone $v6 --keylength ec-256 \
                --server letsencrypt >/dev/null 2>&1; then
            err "证书申请失败"
            "$ACME" --issue -d "$d" --standalone $v6 --keylength ec-256 2>&1 \
                | tail -n 8 | while read -r l; do dim "  $l"; done
            fw_del 80 tcp
            return 1
        fi
        fw_del 80 tcp
    fi
    mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
    "$ACME" --install-cert -d "$d" --ecc \
        --fullchain-file "$TLS_CRT" --key-file "$TLS_KEY" \
        --reloadcmd "$(reload_cmd)" >/dev/null 2>&1 || { err "证书安装失败。"; return 1; }
    chmod 600 "$TLS_KEY"
    printf '%s' "$d" >"$CERT_DOMAIN"
    ok "证书就绪"; echo
}

cert_prepare() {
    local d=$1
    [[ $(cert_dom) == "$d" ]] && cert_ready && { ok "复用已有证书"; echo; return 0; }
    acme_setup || return 1
    acme_issue "$d" || return 1
    cert_ready || { err "证书文件缺失。"; return 1; }
}

cert_switch() {
    local new=$1 f n
    cert_prepare "$new" || return 1
    shopt -s nullglob
    for f in "$SB_NODES"/*.json; do
        [[ -n $(jq -r '.meta.domain // empty' "$f") ]] || continue
        jq --arg d "$new" '.server=$d | .meta.domain=$d | .meta.sni=$d
            | .inbound.tls.server_name=$d' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    done
    shopt -u nullglob
    cfg_apply || return 1
    while read -r n; do [[ -n $n ]] && lk_refresh nodes "$n" >/dev/null; done < <(nd_list nodes)
    ok "已切换到 $new，所有 TLS 节点链接已更新"
}

ask_domain() {
    local __v=$1 cur in n
    cur=$(cert_dom)
    while :; do
        msg "绑定域名:"
        [[ -n $cur ]] && dim "(当前 $cur，回车复用)"
        read -r -p "> " in
        in=$(trim "$in"); in=${in#*://}; in=${in%%/*}
        [[ -z $in && -n $cur ]] && in=$cur
        is_domain "$in" || { warn "域名格式不正确。"; continue; }
        if [[ -n $cur && $in != "$cur" ]]; then
            n=$(tls_nodes)
            warn "本脚本只维护一份证书。"
            dim "  换成 $in 后，已有 $n 个 TLS 节点会一起改用新域名，"
            dim "  旧域名的分享链接全部失效，需重新分发。"
            ask_yn "确认更换？" "N" || continue
            cert_switch "$in" || continue
        fi
        printf -v "$__v" '%s' "$in"; echo; return 0
    done
}

acme_purge() {
    local d; d=$(cert_dom)
    [[ -n $d ]] || return 0
    acme_has && "$ACME" --remove -d "$d" --ecc >/dev/null 2>&1
    rm -rf "$ACME_HOME/${d}_ecc"
}
lk_build() {
    local r=$1 n=$2 pov=${3:-} p pt sv pr fg hp uu pw sn pk sd us cc mp
    p=$(nd_path "$r" "$n")
    [[ -f $p ]] || return 1
    pr=$(jq -r '.protocol' "$p")
    sv=$(jq -r '.server // ""' "$p")
    [[ -n ${LK_HOST:-} ]] && sv=$LK_HOST
    pt=$(jq -r '.ext_port // .port' "$p")
    [[ -n $pov ]] && pt=$pov
    fg=$(urlenc "$n")
    hp=$(hostport "$sv" "$pt")
    uu=$(jq -r '.meta.uuid // ""' "$p")
    pw=$(jq -r '.meta.password // ""' "$p")
    sn=$(jq -r '.meta.sni // ""' "$p")
    pk=$(jq -r '.meta.public_key // ""' "$p")
    sd=$(jq -r '.meta.short_id // ""' "$p")
    us=$(jq -r '.meta.username // ""' "$p")
    cc=$(jq -r '.meta.congestion_control // "bbr"' "$p")
    case $pr in
        vless-reality)
            printf 'vless://%s@%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
                "$uu" "$hp" "$(urlenc "$sn")" "$pk" "$sd" "$fg" ;;
        vless-tls)
            printf 'vless://%s@%s?encryption=none&flow=xtls-rprx-vision&security=tls&sni=%s&fp=chrome&type=tcp#%s' \
                "$uu" "$hp" "$(urlenc "$sn")" "$fg" ;;
        hysteria2)
            mp=$(jq -r 'if (.hop.enabled // false) and (.hop.auto // false)
                        then (.hop.ranges // [] | join(",")) else "" end' "$p")
            if [[ -n $mp && -z $pov ]]; then
                printf 'hysteria2://%s@%s/?sni=%s&alpn=h3&mport=%s#%s' \
                    "$(urlenc "$pw")" "$hp" "$(urlenc "$sn")" "$mp" "$fg"
            else
                printf 'hysteria2://%s@%s/?sni=%s&alpn=h3#%s' \
                    "$(urlenc "$pw")" "$hp" "$(urlenc "$sn")" "$fg"
            fi ;;
        tuic)
            printf 'tuic://%s:%s@%s?congestion_control=%s&alpn=h3&sni=%s&udp_relay_mode=native#%s' \
                "$uu" "$(urlenc "$pw")" "$hp" "$cc" "$(urlenc "$sn")" "$fg" ;;
        trojan)
            printf 'trojan://%s@%s?security=tls&sni=%s&fp=chrome&type=tcp#%s' \
                "$(urlenc "$pw")" "$hp" "$(urlenc "$sn")" "$fg" ;;
        anytls)
            printf 'anytls://%s@%s?sni=%s&insecure=0#%s' \
                "$(urlenc "$pw")" "$hp" "$(urlenc "$sn")" "$fg" ;;
        socks5)
            printf 'socks5://%s:%s@%s#%s' \
                "$(urlenc "$us")" "$(urlenc "$pw")" "$hp" "$fg" ;;
        *) return 1 ;;
    esac
}

lk_refresh() {
    local l
    l=$(lk_build "$1" "$2") || return 1
    nd_set "$1" "$2" link "$l"
    printf '%s' "$l"
}

lk_v6() {
    local r=$1 n=$2 p
    p=$(nd_path "$r" "$n")
    pub_ip
    [[ -n $PUB6 ]] || return 1
    [[ -n $(jq -r '.meta.domain // empty' "$p") ]] && return 1
    LK_HOST=$PUB6 lk_build "$r" "$n" "$(jq -r '.port' "$p")"
}

qs_get() {
    local q=$1 k=$2 kv
    while IFS= read -r kv; do
        [[ ${kv%%=*} == "$k" ]] && { urldec "${kv#*=}"; return 0; }
    done < <(printf '%s\n' "${q//&/$'\n'}")
    return 1
}

lk_parse() {
    local u=$1 sc rs fg bd ui hp h pt qs sn ins out pr pn l4 mt
    u=$(trim "$u")
    sc=$(tr '[:upper:]' '[:lower:]' <<<"${u%%://*}")
    rs=${u#*://}
    if [[ $rs == *#* ]]; then fg=$(urldec "${rs##*#}"); rs=${rs%%#*}; else fg=""; fi
    if [[ $rs == *\?* ]]; then qs=${rs#*\?}; bd=${rs%%\?*}; else qs=""; bd=$rs; fi
    bd=${bd%/}
    if [[ $bd == *@* ]]; then ui=${bd%@*}; hp=${bd##*@}; else ui=""; hp=$bd; fi
    if [[ $hp == \[*\]:* ]]; then h=${hp%%\]:*}; h=${h#\[}; pt=${hp##*\]:}
    else h=${hp%%:*}; pt=${hp##*:}; fi
    [[ -n $h ]] || return 1
    is_port "$pt" || return 1
    sn=$(qs_get "$qs" sni || qs_get "$qs" peer || printf '%s' "$h")
    ins=$(qs_get "$qs" insecure || qs_get "$qs" allowInsecure || printf 0)
    [[ $ins == 1 || $ins == true ]] && ins=true || ins=false
    case $sc in
        vless)
            local uu fl se pk sd fp
            uu=$(urldec "$ui")
            fl=$(qs_get "$qs" flow || printf '')
            se=$(qs_get "$qs" security || printf none)
            fp=$(qs_get "$qs" fp || printf chrome)
            l4=tcp
            if [[ $se == reality ]]; then
                pk=$(qs_get "$qs" pbk || printf '')
                sd=$(qs_get "$qs" sid || printf '')
                [[ -n $pk ]] || { err "Reality 链接缺少 pbk。"; return 1; }
                pr=vless-reality; pn="VLESS Reality Vision"
                out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg u "$uu" --arg f "$fl" \
                    --arg n "$sn" --arg fp "$fp" --arg k "$pk" --arg d "$sd" '{
                      type:"vless", server:$s, server_port:$p, uuid:$u,
                      flow:(if $f=="" then "xtls-rprx-vision" else $f end),
                      tls:{enabled:true, server_name:$n,
                           utls:{enabled:true,fingerprint:$fp},
                           reality:{enabled:true,public_key:$k,short_id:$d}}}')
                mt=$(jq -nc --arg u "$uu" --arg n "$sn" --arg k "$pk" --arg d "$sd" \
                    '{uuid:$u,sni:$n,public_key:$k,short_id:$d}')
            elif [[ $se == tls ]]; then
                pr=vless-tls; pn="VLESS TLS Vision"
                out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg u "$uu" --arg f "$fl" \
                    --arg n "$sn" --arg fp "$fp" --argjson i "$ins" '{
                      type:"vless", server:$s, server_port:$p, uuid:$u,
                      flow:(if $f=="" then "xtls-rprx-vision" else $f end),
                      tls:{enabled:true, server_name:$n, insecure:$i,
                           utls:{enabled:true,fingerprint:$fp}}}')
                mt=$(jq -nc --arg u "$uu" --arg n "$sn" '{uuid:$u,sni:$n}')
            else
                err "不支持的 VLESS 安全层: $se（仅 reality / tls）"; return 1
            fi ;;
        hysteria2|hy2)
            pr=hysteria2; pn="Hysteria2"; l4=udp
            local pw mp sp
            pw=$(urldec "$ui")
            mp=$(qs_get "$qs" mport || qs_get "$qs" ports || printf '')
            if [[ -n $mp ]]; then
                sp=$(printf '%s' "$mp" | tr ',' '\n' | sed 's/-/:/' \
                    | jq -R . | jq -sc 'map(select(length>0))')
            else sp="[]"; fi
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg w "$pw" --arg n "$sn" \
                --argjson i "$ins" --argjson sp "$sp" '
                {type:"hysteria2", server:$s, password:$w,
                 tls:{enabled:true,server_name:$n,alpn:["h3"],insecure:$i}}
                + (if ($sp|length)>0 then {server_ports:$sp,hop_interval:"30s"}
                   else {server_port:$p} end)')
            mt=$(jq -nc --arg w "$pw" --arg n "$sn" --arg m "$mp" \
                '{password:$w,sni:$n,mport:$m}') ;;
        tuic)
            pr=tuic; pn="TUIC"; l4=udp
            [[ $ui == *:* ]] || { err "TUIC 链接缺少密码。"; return 1; }
            local uu pw cc
            uu=${ui%%:*}; pw=$(urldec "${ui#*:}")
            cc=$(qs_get "$qs" congestion_control || printf bbr)
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg u "$uu" --arg w "$pw" \
                --arg n "$sn" --arg c "$cc" --argjson i "$ins" '{
                  type:"tuic", server:$s, server_port:$p, uuid:$u, password:$w,
                  congestion_control:$c, udp_relay_mode:"native",
                  tls:{enabled:true,server_name:$n,alpn:["h3"],insecure:$i}}')
            mt=$(jq -nc --arg u "$uu" --arg w "$pw" --arg n "$sn" --arg c "$cc" \
                '{uuid:$u,password:$w,sni:$n,congestion_control:$c}') ;;
        trojan)
            pr=trojan; pn="Trojan TLS"; l4=tcp
            local pw; pw=$(urldec "$ui")
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg w "$pw" --arg n "$sn" \
                --argjson i "$ins" '{
                  type:"trojan", server:$s, server_port:$p, password:$w,
                  tls:{enabled:true,server_name:$n,insecure:$i,
                       utls:{enabled:true,fingerprint:"chrome"}}}')
            mt=$(jq -nc --arg w "$pw" --arg n "$sn" '{password:$w,sni:$n}') ;;
        anytls)
            pr=anytls; pn="AnyTLS"; l4=tcp
            local pw; pw=$(urldec "$ui")
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg w "$pw" --arg n "$sn" \
                --argjson i "$ins" '{
                  type:"anytls", server:$s, server_port:$p, password:$w,
                  tls:{enabled:true,server_name:$n,insecure:$i}}')
            mt=$(jq -nc --arg w "$pw" --arg n "$sn" '{password:$w,sni:$n}') ;;
        socks5|socks)
            pr=socks5; pn="SOCKS5"; l4=tcp
            local us pw dc
            if [[ $ui == *:* ]]; then us=$(urldec "${ui%%:*}"); pw=$(urldec "${ui#*:}")
            else
                dc=$(printf '%s' "$ui" | base64 -d 2>/dev/null)
                if [[ $dc == *:* ]]; then us=${dc%%:*}; pw=${dc#*:}; else us=""; pw=""; fi
            fi
            out=$(jq -nc --arg s "$h" --argjson p "$pt" --arg u "$us" --arg w "$pw" '
                {type:"socks", server:$s, server_port:$p, version:"5"}
                + (if $u != "" then {username:$u} else {} end)
                + (if $w != "" then {password:$w} else {} end)')
            mt=$(jq -nc --arg u "$us" --arg w "$pw" '{username:$u,password:$w}') ;;
        *)
            err "无法识别的协议: $sc://"
            dim "  支持 vless:// hysteria2:// hy2:// tuic:// trojan:// anytls:// socks5://"
            return 1 ;;
    esac
    [[ -z $fg ]] && fg="$h-$pt"
    jq -nc --arg pr "$pr" --arg pn "$pn" --arg n "$fg" --arg s "$h" \
        --argjson p "$pt" --arg l "$l4" --argjson o "$out" --argjson m "$mt" '{
          protocol:$pr, protocol_name:$pn, name:$n, server:$s,
          port:$p, ext_port:$p, l4:$l, outbound:$o, meta:$m}'
}

peer_ips() {
    local f s
    shopt -s nullglob
    for f in "$SB_PEERS"/*.json; do
        s=$(jq -r '.server // empty' "$f" 2>/dev/null)
        [[ -n $s ]] || continue
        if is_ip "$s"; then printf '%s\n' "$s"; else resolve "$s" 2>/dev/null; fi
    done
    shopt -u nullglob
}

mix_inbound() {
    jq -nc --argjson p "$(mix_port)" --arg u "$(mix_user)" --arg w "$(mix_pass)" '{
      type:"mixed", tag:"mixed-in", listen:"127.0.0.1", listen_port:$p,
      users:[{username:$u,password:$w}]}'
}

cfg_build() {
    local pe md pon ron fs=() nin="[]" tags="[]" lin="[]" pout=null pips="[]"
    pe=$(st_get active_peer)
    md=$(st_get proxy_mode); [[ -z $md ]] && md=manual
    proxy_on && pon=true || pon=false
    relay_on && ron=true || ron=false
    shopt -s nullglob; fs=("$SB_NODES"/*.json); shopt -u nullglob
    if (( ${#fs[@]} )); then
        nin=$(jq -s '[.[].inbound]' "${fs[@]}")
        tags=$(jq -s '[.[].inbound.tag]' "${fs[@]}")
    fi
    if [[ -n $pe && -f $SB_PEERS/$pe.json ]]; then
        pout=$(jq -c --argjson m "$((MARK_BYPASS))" \
            '.outbound | .tag="proxy" | .routing_mark=$m' "$SB_PEERS/$pe.json")
    fi
    pips=$(peer_ips | sort -u | jq -R . | jq -sc 'map(select(length>0))')
    if [[ $pon == true ]]; then
        case $md in
            tun) lin='[{"type":"tun","tag":"tun-in","interface_name":"sbm-tun0",
                 "address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],"mtu":9000,
                 "auto_route":true,"strict_route":false,"stack":"mixed"}]' ;;
            tproxy) lin=$(jq -nc --argjson p "$PORT_TPROXY" \
                 '[{type:"tproxy",tag:"tproxy-in",listen:"::",listen_port:$p}]') ;;
            manual) lin=$(jq -nc --argjson m "$(mix_inbound)" '[$m]') ;;
        esac
    fi
    jq -n --argjson nin "$nin" --argjson lin "$lin" --argjson tags "$tags" \
        --argjson peer "$pout" --argjson pips "$pips" --argjson mark "$((MARK_BYPASS))" \
        --argjson relay "$ron" --argjson proxy "$pon" '
      ($peer != null) as $has
      | (if $has and $relay then "proxy" else "direct" end) as $ro
      | (if $has and $proxy then "proxy" else "direct" end) as $lo
      | (($tags|length) > 0) as $hn
      | {
          log:{level:"warn",timestamp:true},
          dns:{
            servers:((if $has then [{tag:"remote",address:"tls://1.1.1.1",detour:"proxy"}] else [] end)
                     + [{tag:"local",address:"local",detour:"direct"}]),
            rules:(if $hn then [{inbound:$tags,
                     server:(if $ro=="proxy" then "remote" else "local" end)}] else [] end),
            final:(if $lo=="proxy" then "remote" else "local" end),
            strategy:"prefer_ipv4"
          },
          inbounds:($nin + $lin),
          outbounds:((if $has then [$peer] else [] end)
                     + [{type:"direct",tag:"direct",routing_mark:$mark}]),
          route:{
            rules:([{action:"sniff"},{protocol:"dns",action:"hijack-dns"}]
                   + (if ($pips|length)>0 then [{ip_cidr:$pips,outbound:"direct"}] else [] end)
                   + [{ip_is_private:true,outbound:"direct"}]
                   + (if $hn then [{inbound:$tags,outbound:$ro}] else [] end)),
            auto_detect_interface:true,
            final:$lo
          }
        }'
}

cfg_write() {
    local t=$SB_CONF.new
    mkdir -p "$SB_ROOT"
    printf '%s\n' "$1" >"$t" || { err "写入失败。"; return 1; }
    jq empty "$t" 2>/dev/null || { err "生成的配置不是合法 JSON。"; rm -f "$t"; return 1; }
    if [[ -x $SB_BIN ]] && ! "$SB_BIN" check -c "$t" >/dev/null 2>&1; then
        err "配置校验失败"; conf_err "$t"
        dim "  （若为协议不支持，请先更新 sing-box）"
        rm -f "$t"; return 1
    fi
    mv "$t" "$SB_CONF"; chmod 600 "$SB_CONF"
}

cfg_apply() {
    local c
    c=$(cfg_build) || return 1
    cfg_write "$c" || return 1
    if [[ $(jq '.inbounds | length' "$SB_CONF") == 0 ]]; then
        svc_up "$SVC_SB" && svc_stop "$SVC_SB"
        return 0
    fi
    svc_has "$SVC_SB" || install_sb_unit
    if svc_up "$SVC_SB"; then svc_restart "$SVC_SB"; else svc_start "$SVC_SB"; fi
    sleep 2
    svc_up "$SVC_SB" && return 0
    err "sing-box 启动失败。"; svc_log_hint
    return 1
}

warn_reload() {
    (( $(nd_count nodes) > 0 )) || return 0
    warn "此操作需重载配置，连接本机的用户会断开约 1 秒（客户端自动重连）。"
    ask_yn "继续？" "Y"
}

acme_has()   { [[ -x $ACME ]]; }
cert_dom()   { cat "$CERT_DOMAIN" 2>/dev/null; }
cert_ready() { [[ -s $TLS_CRT && -s $TLS_KEY ]]; }

reload_cmd() {
    case $INIT in
        systemd) printf 'systemctl restart %s' "$SVC_SB" ;;
        openrc)  printf 'rc-service %s restart' "$SVC_SB" ;;
    esac
}

tls_nodes() {
    local f n=0
    shopt -s nullglob
    for f in "$SB_NODES"/*.json; do
        [[ -n $(jq -r '.meta.domain // empty' "$f" 2>/dev/null) ]] && n=$(( n + 1 ))
    done
    shopt -u nullglob
    printf '%d' "$n"
}

acme_setup() {
    acme_has && return 0
    ui_title "安装 acme.sh"
    pkg_ensure curl || return 1
    pkg_ensure openssl || return 1
    pkg_ensure socat || warn "socat 安装失败，HTTP 验证可能不可用。"
    have crontab || pkg_ensure crontab || warn "cron 不可用，证书无法自动续期。"
    if [[ $FAMILY == alpine ]]; then
        rc-update add dcron default >/dev/null 2>&1
        rc-service dcron start >/dev/null 2>&1
    fi
    local em
    while :; do
        msg "证书注册邮箱:"; dim "(用于到期提醒)"; read -r -p "> " em
        em=$(trim "$em")
        [[ $em =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]] && break

hop_auto_cap() { [[ $1 == hysteria2 ]]; }
hop_label()    { hop_auto_cap "$1" && printf '端口跳跃' || printf '多端口复用'; }

rg_norm() {
    local r=$1 s e t
    r=${r//[[:space:]]/}; r=${r//:/-}; r=${r//\~/-}
    if [[ $r =~ ^([0-9]+)-([0-9]+)$ ]]; then s=${BASH_REMATCH[1]}; e=${BASH_REMATCH[2]}
    elif [[ $r =~ ^[0-9]+$ ]]; then s=$r; e=$r
    else return 1; fi
    is_port "$s" && is_port "$e" || return 1
    (( s <= e )) || { t=$s; s=$e; e=$t; }
    printf '%s-%s' "$s" "$e"
}
rg_s()    { printf '%s' "${1%%-*}"; }
rg_e()    { printf '%s' "${1##*-}"; }
rg_size() { printf '%d' $(( $(rg_e "$1") - $(rg_s "$1") + 1 )); }
rg_has()  { (( $1 >= $(rg_s "$2") && $1 <= $(rg_e "$2") )); }

hop_ranges()  { jq -r '.hop.ranges // [] | .[]' "$(nd_path nodes "$1")" 2>/dev/null; }
hop_enabled() { [[ $(jq -r '.hop.enabled // false' "$(nd_path nodes "$1")" 2>/dev/null) == true ]]; }
hop_auto()    { [[ $(jq -r '.hop.auto // false'    "$(nd_path nodes "$1")" 2>/dev/null) == true ]]; }

hop_covers() {
    local p=$1 skip=${2:-} n r
    while read -r n; do
        [[ -n $n && $n != "$skip" ]] || continue
        while read -r r; do
            [[ -n $r ]] || continue
            rg_has "$p" "$r" && return 0
        done < <(hop_ranges "$n")
    done < <(nd_list nodes)
    return 1
}

hop_check_rg() {
    local r=$1 self=$2 sp=$3 s e p n o or sl
    s=$(rg_s "$r"); e=$(rg_e "$r")

    if [[ -s $SSH_PORTS ]]; then sl=$(cat "$SSH_PORTS"); else sl=$(ssh_ports_detect); fi
    while read -r p; do
        [[ -n $p ]] || continue
        rg_has "$p" "$r" && { err "范围 $r 包含 SSH 端口 $p，启用后会立即失去连接。"; return 1; }
    done <<<"$sl"

    rg_has "$PORT_TPROXY" "$r" && { err "范围 $r 包含 TPROXY 端口 $PORT_TPROXY。"; return 1; }
    p=$(st_get mixed_port)
    is_port "$p" && rg_has "$p" "$r" && { err "范围 $r 包含本地代理端口 $p。"; return 1; }

    while read -r n; do
        [[ -n $n && $n != "$self" ]] || continue
        o=$(nd_get nodes "$n" port)
        [[ -n $o ]] && rg_has "$o" "$r" && { err "范围 $r 包含节点 $n 的端口 $o。"; return 1; }
        while read -r or; do
            [[ -n $or ]] || continue
            (( s <= $(rg_e "$or") && e >= $(rg_s "$or") )) && {
                err "范围 $r 与节点 $n 的 $or 重叠。"; return 1; }
        done < <(hop_ranges "$n")
    done < <(nd_list nodes)

    if nat_on; then
        nat_allowed "$s" && nat_allowed "$e" || {
            err "范围 $r 超出服务商分配端口，外部无法到达。"; return 1; }
        [[ $(st_get nat_map) == same ]] || {
            err "固定映射方式下无法使用端口跳跃。"; return 1; }
    fi

    for p in 53 80 443 3306 5432 6379; do
        [[ $p == "$sp" ]] && continue
        rg_has "$p" "$r" && {
            warn "范围 $r 包含常用端口 $p，本机若有对应服务将被劫持。"
            ask_yn "仍然使用？" "N" || return 1; }
    done

    (( $(rg_size "$r") > 20000 )) && warn "跨度 $(rg_size "$r") 个端口，可能触发运营商限速。"
    return 0
}

hop_ask() {
    local nd=$1 lp=$2 l4=$3 pr=$4
    local lbl rs=() in r tmp=() bad nr ps pe pp busy tot=0 rj auto
    lbl=$(hop_label "$pr")

    echo
    msg "$lbl:"
    if hop_auto_cap "$pr"; then
        dim "  多个外部端口共用同一监听端口，客户端自动轮换"
    else
        dim "  多个外部端口共用同一监听端口，任一端口均可连入"
        dim "  注意：$pr 客户端不自动轮换，需手动更换端口"
    fi
    echo

    if ! nft_can_nat; then
        warn "当前环境无 NAT 表写入权限，$lbl 不可用。"
        dim "  常见于无特权容器。授予 CAP_NET_ADMIN 后可用。"
        echo
        hop_reset "$nd"
        return 0
    fi

    ask_yn "启用？" "N" || { hop_reset "$nd"; return 0; }
    echo

    while :; do
        msg "端口范围:"
        dim "(如 20000-30000，多段空格分隔，回车结束)"
        read -r -p "> " in
        in=$(trim "$in")
        [[ -z $in ]] && { (( ${#rs[@]} )) && break; warn "至少需要一段端口。"; continue; }

        bad=0; tmp=()
        for r in $in; do
            nr=$(rg_norm "$r") || { warn "格式不正确: $r"; bad=1; break; }
            hop_check_rg "$nr" "$nd" "$lp" || { bad=1; break; }
            ps=$(rg_s "$nr"); pe=$(rg_e "$nr"); busy=0
            if (( pe - ps < 64 )); then
                for (( pp = ps; pp <= pe; pp++ )); do
                    (( pp == lp )) && continue
                    port_busy "$pp" "$l4" && { warn "端口 $pp 已被占用。"; busy=1; }
                done
            fi
            (( busy )) && { bad=1; break; }
            tmp+=("$nr")
        done
        (( bad )) && { echo; continue; }

        (( ${#tmp[@]} )) && rs+=("${tmp[@]}")
        tot=0
        for r in "${rs[@]}"; do tot=$(( tot + $(rg_size "$r") )); done

        if ! hop_auto_cap "$pr" && (( tot > 64 )); then
            warn "客户端不自动轮换时，超过 64 个端口意义有限。"
            ask_yn "仍使用 $tot 个端口？" "N" || { rs=(); continue; }
        fi

        echo; msg "已配置:"
        for r in "${rs[@]}"; do
            (( $(rg_size "$r") == 1 )) && printf '  %s\n' "$(rg_s "$r")" \
                || printf '  %s  (%d 个端口)\n' "$r" "$(rg_size "$r")"
        done
        echo
        ask_yn "继续添加？" "N" || break
        echo
    done

    rj=$(printf '%s\n' "${rs[@]}" | jq -R . | jq -sc 'map(select(length>0))')
    hop_auto_cap "$pr" && auto=true || auto=false
    nd_set nodes "$nd" hop \
        "$(jq -nc --argjson r "$rj" --argjson a "$auto" \
            '{enabled:true,auto:$a,ranges:$r}')" 1

    echo
    kv "监听端口" "$lp"
    kv "外部端口" "共 $tot 个"
}

hop_reset() {
    nd_set nodes "$1" hop '{"enabled":false,"auto":false,"ranges":[]}' 1
}

hop_apply() {
    local nd=$1 lp l4 r s e spec
    hop_enabled "$nd" || return 0
    need_nft || return 1
    lp=$(nd_get nodes "$nd" port)
    l4=$(nd_get nodes "$nd" l4)

    nft add table inet $NFT_HOP >/dev/null 2>&1
    nft add chain inet $NFT_HOP prerouting \
        '{ type nat hook prerouting priority -100 ; policy accept ; }' >/dev/null 2>&1 || return 1
    while read -r r; do
        [[ -n $r ]] || continue
        s=$(rg_s "$r"); e=$(rg_e "$r")
        (( s == e )) && spec=$s || spec="$s-$e"
        nft add rule inet $NFT_HOP prerouting "$l4" dport "$spec" \
            redirect to ":$lp" comment "\"sbm-hop-$nd\"" >/dev/null 2>&1
        fw_allow_rg "$s" "$e" "$l4"
    done < <(hop_ranges "$nd")

    [[ $l4 == udp ]] && hop_conntrack
    return 0
}

hop_clear() {
    local nd=$1 l4 r s e
    l4=$(nd_get nodes "$nd" l4)
    nft_del_tag "sbm-hop-$nd"
    while read -r r; do
        [[ -n $r ]] || continue
        s=$(rg_s "$r"); e=$(rg_e "$r")
        fw_del_rg "$s" "$e" "$l4"
    done < <(hop_ranges "$nd")
    return 0
}

hop_reapply() {
    have nft && nft delete table inet $NFT_HOP >/dev/null 2>&1
    local n
    while read -r n; do [[ -n $n ]] && hop_apply "$n"; done < <(nd_list nodes)
}

hop_conntrack() {
    local f=/proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream cur c=/etc/sysctl.d/99-sbm.conf
    [[ -w $f ]] || return 0
    cur=$(cat "$f" 2>/dev/null)
    is_uint "$cur" || return 0
    (( cur >= 300 )) && return 0
    echo 300 >"$f" 2>/dev/null || return 0
    grep -q nf_conntrack_udp_timeout_stream "$c" 2>/dev/null || \
        printf 'net.netfilter.nf_conntrack_udp_timeout_stream = 300\n' >>"$c"
}

hop_commit() {
    local nd=$1 l
    hop_enabled "$nd" || return 0
    hop_apply "$nd" || { hop_reset "$nd"; err "NAT 规则写入失败，已撤销。"; return 1; }
    bypass_refresh
    l=$(lk_refresh nodes "$nd")
    echo; msg "更新后的链接:"; echo
    printf '%s\n\n' "$l"
    hop_alt_links "$nd"
    ok "$(hop_label "$(nd_get nodes "$nd" protocol)")已启用"
}

hop_alt_links() {
    local nd=$1 tot=0 r s e pp shown=0 max=12
    hop_enabled "$nd" || return 0
    hop_auto "$nd" && return 0
    while read -r r; do
        [[ -n $r ]] && tot=$(( tot + $(rg_size "$r") ))
    done < <(hop_ranges "$nd")
    (( tot )) || return 0
    echo; msg "备用入口链接:"; dim "  某端口不可用时换一条"; echo
    while read -r r; do
        [[ -n $r ]] || continue
        s=$(rg_s "$r"); e=$(rg_e "$r")
        for (( pp = s; pp <= e; pp++ )); do
            (( shown >= max )) && break 2
            printf '%s\n\n' "$(lk_build nodes "$nd" "$pp")"
            shown=$(( shown + 1 ))
        done
    done < <(hop_ranges "$nd")
    (( tot > shown )) && dim "  共 $tot 个端口，以上为前 $shown 条"
    return 0
}

hop_link_port() {
    local nd=$1 in r okf
    echo; msg "端口范围:"
    while read -r r; do [[ -n $r ]] && printf '  %s\n' "$r"; done < <(hop_ranges "$nd")
    echo
    while :; do
        msg "生成哪个端口的链接:"; read -r -p "> " in
        in=$(trim "$in")
        [[ -z $in ]] && return 0
        is_port "$in" || { warn "端口不合法。"; continue; }
        okf=0
        while read -r r; do
            [[ -n $r ]] && rg_has "$in" "$r" && okf=1
        done < <(hop_ranges "$nd")
        [[ $in == "$(nd_get nodes "$nd" ext_port)" ]] && okf=1
        (( okf )) && break
        warn "端口 $in 不在已配置范围内。"
    done
    echo; printf '%s\n\n' "$(lk_build nodes "$nd" "$in")"
}

ensure_rt() {
    ui_title "环境检测"
    kv "系统" "$DNAME"
    kv "架构" "$(uname -m)"
    kv "CPU优化" "$CPU_LVL"

    msg "防火墙:"
    fw_detect >/dev/null
    case $FW in
        none) warn "未检测到防火墙工具，跳过放行" ;;
        *)    ok "$FW" ;;
    esac
    echo

    msg "网络环境:"
    nat_ready
    if nat_on; then
        warn "NAT（公网 IPv4 共享）"
        dim "  出口 $PUB4 / 本机 $(laddrs | tr '\n' ' ')"
    elif [[ $NAT_TYPE == ipv6only ]]; then warn "仅有公网 IPv6"
    else ok "独立公网 IPv4"; fi
    echo

    msg "sing-box:"
    if [[ -x $SB_BIN ]]; then ok "已安装 $(sb_ver)"; echo
    else warn "未安装"; echo; sb_install || return 1; fi

    svc_has "$SVC_RULES" || install_rules_unit
    svc_has "$SVC_SB"    || install_sb_unit
    return 0
}

nd_commit() {
    local n=$1 pr=$2 pn=$3 pt=$4 ex=$5 l4=$6 sv=$7 ib=$8 mt=${9}
    local j l v6

    j=$(jq -nc --arg n "$n" --arg pr "$pr" --arg pn "$pn" --argjson p "$pt" \
        --argjson e "$ex" --arg l "$l4" --arg s "$sv" --argjson ib "$ib" \
        --argjson mt "$mt" --argjson c "$(date +%s)" '{
          name:$n, protocol:$pr, protocol_name:$pn, port:$p, ext_port:$e,
          l4:$l, server:$s, created:$c, inbound:$ib, meta:$mt, link:"",
          hop:{enabled:false,auto:false,ranges:[]}}')

    nd_save nodes "$n" "$j" || return 1

    echo; ui_sep
    msg "生成配置中..."
    if ! cfg_apply; then
        nd_del nodes "$n"
        cfg_apply >/dev/null 2>&1
        err "配置生效失败，已回滚该节点。"
        return 1
    fi

    msg "生成链接..."
    l=$(lk_refresh nodes "$n") || warn "链接生成失败"
    msg "配置防火墙..."
    fw_allow "$pt" "$l4"
    bypass_refresh

    ui_sep; echo
    msg "启动结果:"
    svc_up "$SVC_SB" && ok "运行正常" || { err "启动失败"; svc_log_hint; return 1; }
    echo
    msg "链接:"; echo
    printf '%s\n\n' "$l"
    if v6=$(lk_v6 nodes "$n"); then
        msg "IPv6 直连链接:"; dim "  IPv6 无 NAT，使用内部端口 $pt"; echo
        printf '%s\n\n' "$v6"
    fi
    ui_sep
    return 0
}

add_reality() {
    ui_title "VLESS Reality Vision"
    local n uu sn pt ex kp pv pb sd sv ib mt
    ask_name n nodes
    ask_uuid uu
    ask_reality_dom sn || return 1
    ask_port pt tcp ex || return 1
    ensure_rt || return 1

    msg "生成Reality Key..."
    kp=$(reality_kp) || { err "密钥生成失败。"; return 1; }
    pv=${kp%% *}; pb=${kp##* }
    sd=$(reality_sid)
    sv=$(def_addr) || { err "无法获取公网地址。"; return 1; }

    ib=$(jq -nc --arg t "$n" --argjson p "$pt" --arg u "$uu" --arg s "$sn" \
        --arg k "$pv" --arg d "$sd" '{
          type:"vless", tag:$t, listen:"::", listen_port:$p,
          users:[{uuid:$u,flow:"xtls-rprx-vision"}],
          tls:{enabled:true, server_name:$s,
               reality:{enabled:true, handshake:{server:$s,server_port:443},
                        private_key:$k, short_id:[$d]}}}')
    mt=$(jq -nc --arg u "$uu" --arg s "$sn" --arg pb "$pb" --arg pv "$pv" --arg d "$sd" \
        '{uuid:$u,sni:$s,public_key:$pb,private_key:$pv,short_id:$d}')

    nd_commit "$n" vless-reality "VLESS Reality Vision" \
        "$pt" "$ex" tcp "$sv" "$ib" "$mt" || return 1
    hop_ask "$n" "$pt" tcp vless-reality
    hop_commit "$n"
}

add_vless_tls() {
    ui_title "VLESS TLS Vision"
    local n uu dm pt ex ib mt
    ask_name n nodes
    ask_uuid uu
    ensure_rt || return 1
    ask_domain dm
    ask_port pt tcp ex || return 1
    cert_prepare "$dm" || return 1

    ib=$(jq -nc --arg t "$n" --argjson p "$pt" --arg u "$uu" --arg s "$dm" \
        --arg c "$TLS_CRT" --arg k "$TLS_KEY" '{
          type:"vless", tag:$t, listen:"::", listen_port:$p,
          users:[{uuid:$u,flow:"xtls-rprx-vision"}],
          tls:{enabled:true,server_name:$s,certificate_path:$c,key_path:$k}}')
    mt=$(jq -nc --arg u "$uu" --arg s "$dm" '{uuid:$u,sni:$s,domain:$s}')

    nd_commit "$n" vless-tls "VLESS TLS Vision" \
        "$pt" "$ex" tcp "$dm" "$ib" "$mt" || return 1
    hop_ask "$n" "$pt" tcp vless-tls
    hop_commit "$n"
}

add_hy2() {
    ui_title "Hysteria2"
    local n pw dm pt ex up dn ib mt
    ask_name n nodes
    ask_pass pw "密码"
    ensure_rt || return 1
    nat_udp_ok || return 1
    ask_domain dm
    ask_port pt udp ex || return 1

    msg "带宽设置:"
    dim "  按实际出口带宽填写，填 0 表示不限速（由 BBR 控制）"
    dim "  填得比实际高会导致丢包率上升，宁低勿高"
    echo
    while :; do ask_def up "上行带宽 (Mbps):" 100; is_uint "$up" && break; warn "请输入整数。"; done
    while :; do ask_def dn "下行带宽 (Mbps):" 100; is_uint "$dn" && break; warn "请输入整数。"; done
    echo

    cert_prepare "$dm" || return 1

    ib=$(jq -nc --arg t "$n" --argjson p "$pt" --arg w "$pw" --arg s "$dm" \
        --arg c "$TLS_CRT" --arg k "$TLS_KEY" --argjson u "$up" --argjson d "$dn" '
        {type:"hysteria2", tag:$t, listen:"::", listen_port:$p,
         users:[{password:$w}],
         tls:{enabled:true,server_name:$s,alpn:["h3"],
              certificate_path:$c,key_path:$k}}
        + (if $u > 0 then {up_mbps:$u} else {} end)
        + (if $d > 0 then {down_mbps:$d} else {} end)')
    mt=$(jq -nc --arg w "$pw" --arg s "$dm" --arg u "$up" --arg d "$dn" \
        '{password:$w,sni:$s,domain:$s,up_mbps:$u,down_mbps:$d}')

    nd_commit "$n" hysteria2 Hysteria2 "$pt" "$ex" udp "$dm" "$ib" "$mt" || return 1
    hop_ask "$n" "$pt" udp hysteria2
    hop_commit "$n"
}

add_tuic() {
    ui_title "TUIC"
    local n uu pw dm pt ex cc c ib mt
    ask_name n nodes
    ask_uuid uu
    ask_pass pw "密码"
    ensure_rt || return 1
    nat_udp_ok || return 1
    ask_domain dm
    ask_port pt udp ex || return 1

    msg "拥塞控制算法:"; echo
    msg "  1. bbr"; msg "  2. cubic"; msg "  3. new_reno"; echo
    ask_menu c "1 2 3"
    case $c in 1) cc=bbr ;; 2) cc=cubic ;; 3) cc=new_reno ;; esac
    echo

    cert_prepare "$dm" || return 1

    ib=$(jq -nc --arg t "$n" --argjson p "$pt" --arg u "$uu" --arg w "$pw" \
        --arg cc "$cc" --arg s "$dm" --arg c "$TLS_CRT" --arg k "$TLS_KEY" '{
          type:"tuic", tag:$t, listen:"::", listen_port:$p,
          users:[{uuid:$u,password:$w}],
          congestion_control:$cc, auth_timeout:"3s",
          zero_rtt_handshake:false, heartbeat:"10s",
          tls:{enabled:true,server_name:$s,alpn:["h3"],
               certificate_path:$c,key_path:$k}}')
    mt=$(jq -nc --arg u "$uu" --arg w "$pw" --arg s "$dm" --arg cc "$cc" \
        '{uuid:$u,password:$w,sni:$s,domain:$s,congestion_control:$cc}')

    nd_commit "$n" tuic TUIC "$pt" "$ex" udp "$dm" "$ib" "$mt" || return 1
    hop_ask "$n" "$pt" udp tuic
    hop_commit "$n"
}

add_trojan() {
    ui_title "Trojan TLS"
    local n pw dm pt ex ib mt
    ask_name n nodes
    ask_pass pw "密码"
    ensure_rt || return 1
    ask_domain dm
    ask_port pt tcp ex || return 1
    cert_prepare "$dm" || return 1

    ib=$(jq -nc --arg t "$n" --argjson p "$pt" --arg w "$pw" --arg s "$dm" \
        --arg c "$TLS_CRT" --arg k "$TLS_KEY" '{
          type:"trojan", tag:$t, listen:"::", listen_port:$p,
          users:[{password:$w}],
          tls:{enabled:true,server_name:$s,certificate_path:$c,key_path:$k}}')
    mt=$(jq -nc --arg w "$pw" --arg s "$dm" '{password:$w,sni:$s,domain:$s}')

    nd_commit "$n" trojan "Trojan TLS" "$pt" "$ex" tcp "$dm" "$ib" "$mt" || return 1
    hop_ask "$n" "$pt" tcp trojan
    hop_commit "$n"
}

add_anytls() {
    ui_title "AnyTLS"
    local n pw dm pt ex ib mt
    ask_name n nodes
    ask_pass pw "密码"
    ensure_rt || return 1
    ask_domain dm
    ask_port pt tcp ex || return 1
    cert_prepare "$dm" || return 1

    ib=$(jq -nc --arg t "$n" --argjson p "$pt" --arg w "$pw" --arg s "$dm" \
        --arg c "$TLS_CRT" --arg k "$TLS_KEY" '{
          type:"anytls", tag:$t, listen:"::", listen_port:$p,
          users:[{password:$w}],
          tls:{enabled:true,server_name:$s,certificate_path:$c,key_path:$k}}')
    mt=$(jq -nc --arg w "$pw" --arg s "$dm" '{password:$w,sni:$s,domain:$s}')

    nd_commit "$n" anytls AnyTLS "$pt" "$ex" tcp "$dm" "$ib" "$mt" || return 1
    hop_ask "$n" "$pt" tcp anytls
    hop_commit "$n"
}

add_socks5() {
    ui_title "SOCKS5"
    local n ls pt ex us pw sv ib mt
    ask_name n nodes

    msg "监听地址:"
    dim "(回车默认 :: 双栈；填 127.0.0.1 仅本机可用)"
    read -r -p "> " ls
    ls=$(trim "$ls"); [[ -z $ls ]] && ls="::"
    echo

    ensure_rt || return 1
    ask_port pt tcp ex || return 1

    msg "SOCKS5 不加密，账号密码以明文经过网络。"
    dim "  建议仅用于可信链路"
    echo
    ask_req us "用户名:"
    echo
    ask_pass pw "密码"

    sv=$(def_addr) || { err "无法获取公网地址。"; return 1; }

    ib=$(jq -nc --arg t "$n" --arg l "$ls" --argjson p "$pt" --arg u "$us" --arg w "$pw" '{
          type:"socks", tag:$t, listen:$l, listen_port:$p,
          users:[{username:$u,password:$w}]}')
    mt=$(jq -nc --arg u "$us" --arg w "$pw" --arg l "$ls" \
        '{username:$u,password:$w,listen:$l}')

    nd_commit "$n" socks5 SOCKS5 "$pt" "$ex" tcp "$sv" "$ib" "$mt" || return 1
    hop_ask "$n" "$pt" tcp socks5
    hop_commit "$n"
}

add_menu() {
    local c
    while :; do
        ui_title "添加协议"
        msg "1. VLESS Reality Vision"; echo
        msg "2. VLESS TLS Vision"; echo
        msg "3. Hysteria2"; echo
        msg "4. TUIC"; echo
        msg "5. Trojan TLS"; echo
        msg "6. AnyTLS"; echo
        msg "7. SOCKS5"; echo
        msg "0. 返回"; echo
        nat_on && { dim "NAT 环境推荐 Reality（无需域名与证书）"; echo; }
        ui_sep
        ask_menu c "0 1 2 3 4 5 6 7"
        case $c in
            0) return 0 ;;
            1) add_reality ;;
            2) add_vless_tls ;;
            3) add_hy2 ;;
            4) add_tuic ;;
            5) add_trojan ;;
            6) add_anytls ;;
            7) add_socks5 ;;
        esac
        pause
    done
}

pt_disp() {
    local p e
    p=$(nd_get nodes "$1" port); e=$(nd_get nodes "$1" ext_port)
    [[ $p == "$e" ]] && printf '%s' "$p" || printf '外部 %s → 内部 %s' "$e" "$p"
}

del_menu() {
    local ns=() op="0" i=1 n c t p l4
    ui_title "删除协议"
    msg "已安装协议:"; echo
    while read -r n; do
        [[ -n $n ]] || continue
        printf '%d. %s\n   %s\n   %s %s\n\n' "$i" "$n" \
            "$(nd_get nodes "$n" protocol_name)" \
            "$(tr '[:lower:]' '[:upper:]' <<<"$(nd_get nodes "$n" l4)")" \
            "$(pt_disp "$n")"
        ns+=("$n"); op+=" $i"; i=$(( i + 1 ))
    done < <(nd_list nodes)

    (( ${#ns[@]} )) || { dim "（无）"; echo; pause; return 0; }
    msg "0. 返回"; echo; ui_sep
    ask_menu c "$op"
    [[ $c == 0 ]] && return 0

    t=${ns[c-1]}
    p=$(nd_get nodes "$t" port); l4=$(nd_get nodes "$t" l4)
    echo
    warn "将删除节点 $t（$(pt_disp "$t") / $l4）"
    ask_yn "确认删除？" "N" || return 0

    hop_clear "$t"
    nd_del nodes "$t"
    cfg_apply || { err "配置更新失败，请检查。"; pause; return 1; }
    fw_del "$p" "$l4"
    bypass_refresh
    ok "已删除 $t"

    if (( $(tls_nodes) == 0 )) && [[ -n $(cert_dom) ]]; then
        ask_yn "已无 TLS 节点，删除证书？" "N" && {
            acme_purge; rm -f "$TLS_CRT" "$TLS_KEY" "$CERT_DOMAIN"; ok "证书已删除"; }
    fi
    pause
}

mod_menu() {
    local ns=() op="0" i=1 n c
    ui_title "修改配置"
    msg "选择节点:"; echo
    while read -r n; do
        [[ -n $n ]] || continue
        printf '%d. %s\n\n' "$i" "$n"
        ns+=("$n"); op+=" $i"; i=$(( i + 1 ))
    done < <(nd_list nodes)
    (( ${#ns[@]} )) || { dim "（无节点）"; echo; pause; return 0; }
    msg "0. 返回"; echo; ui_sep
    ask_menu c "$op"
    [[ $c == 0 ]] && return 0
    mod_node "${ns[c-1]}"
}

mod_node() {
            '.port=$n | .ext_port=$e | .inbound.listen_port=$n' "$p" >"$t" && mv "$t" "$p"
        cfg_apply >/dev/null 2>&1
        hop_apply "$nd"
        err "修改失败，已回滚。"
    fi
    pause
}

mod_uuid() {
    local nd=$1 new p t
    echo; kv "当前UUID" "$(nd_meta nodes "$nd" uuid)"
    ask_uuid new
    warn_reload || return 0
    p=$(nd_path nodes "$nd"); t=$p.tmp
    jq --arg u "$new" '.meta.uuid=$u | .inbound.users[0].uuid=$u' "$p" >"$t" \
        && mv "$t" "$p" || { rm -f "$t"; return 1; }
    cfg_apply && { lk_refresh nodes "$nd" >/dev/null; ok "UUID 已更新"; } || err "更新失败"
    pause
}

mod_secret() {
    local nd=$1 pr p t us pw
    pr=$(nd_get nodes "$nd" protocol)
    p=$(nd_path nodes "$nd"); t=$p.tmp
    echo
    if [[ $pr == socks5 ]]; then
        kv "当前用户名" "$(nd_meta nodes "$nd" username)"
        ask_req us "新用户名:"
        echo
        ask_pass pw "新密码"
        warn_reload || return 0
        jq --arg u "$us" --arg w "$pw" '.meta.username=$u | .meta.password=$w
            | .inbound.users[0].username=$u | .inbound.users[0].password=$w' "$p" >"$t" \
            && mv "$t" "$p" || { rm -f "$t"; return 1; }
    else
        ask_pass pw "新密码"
        warn_reload || return 0
        jq --arg w "$pw" '.meta.password=$w | .inbound.users[0].password=$w' "$p" >"$t" \
            && mv "$t" "$p" || { rm -f "$t"; return 1; }
    fi
    cfg_apply && { lk_refresh nodes "$nd" >/dev/null; ok "已更新"; } || err "更新失败"
    pause
}

mod_dom() {
    local nd=$1 new p t
    echo; kv "当前域名" "$(nd_meta nodes "$nd" domain)"
    ask_domain new
    cert_prepare "$new" || return 1
    warn_reload || return 0
    p=$(nd_path nodes "$nd"); t=$p.tmp
    jq --arg d "$new" --arg c "$TLS_CRT" --arg k "$TLS_KEY" '
        .server=$d | .meta.domain=$d | .meta.sni=$d
        | .inbound.tls.server_name=$d
        | .inbound.tls.certificate_path=$c
        | .inbound.tls.key_path=$k' "$p" >"$t" \
        && mv "$t" "$p" || { rm -f "$t"; return 1; }
    cfg_apply && { lk_refresh nodes "$nd" >/dev/null; ok "域名已更新"; } || err "更新失败"
    pause
}
srv_info() {
    local tot i=0 n p l4 pe v6 rl th rr
    ui_title "服务端信息"

    msg "Sing-box:"
    svc_up "$SVC_SB" && ok "运行正常" || err "未运行"
    echo
    kv "版本" "$(sb_ver || echo 未安装)"
    kv "CPU优化版本" "$CPU_LVL"
    nat_on && kv "网络环境" "NAT（出口 $PUB4 共享）"

    msg "中转:"
    pe=$(st_get active_peer)
    if relay_on; then
        [[ -n $pe ]] && ok "已开启 → $pe" || warn "已开启但未选远端节点（走本机出口）"
    else dim "已关闭（走本机出口）"; fi
    echo

    tot=$(nd_count nodes)
    msg "监听:"; echo
    (( tot )) || { dim "（无节点）"; echo; ui_sep; pause; return 0; }

    while read -r n; do
        [[ -n $n ]] || continue
        i=$(( i + 1 ))
        p=$(nd_get nodes "$n" port); l4=$(nd_get nodes "$n" l4)
        printf '%d.\n\n' "$i"
        kv "名称" "$n"
        kv "协议" "$(nd_get nodes "$n" protocol_name)"
        kv "端口" "$(pt_disp "$n") $(tr '[:lower:]' '[:upper:]' <<<"$l4")"

        if hop_enabled "$n"; then
            rl=""; th=0
            while read -r rr; do
                [[ -n $rr ]] || continue
                rl="$rl$rr "; th=$(( th + $(rg_size "$rr") ))
            done < <(hop_ranges "$n")
            hop_auto "$n" && kv "端口跳跃" "$rl(共 $th 个，客户端自动轮换)" \
                          || kv "多端口复用" "$rl(共 $th 个，需手动更换)"
        fi

        msg "状态:"
        port_busy "$p" "$l4" && ok "正常" || err "未监听"
        echo
        msg "链接:"; echo
        printf '%s\n\n' "$(nd_get nodes "$n" link)"
        v6=$(lk_v6 nodes "$n") && printf '  IPv6:\n%s\n\n' "$v6"
    done < <(nd_list nodes)

    ui_sep
    pause
}

relay_toggle() {
    local cur new
    cur=$(st_get relay)
    [[ $cur == true ]] && new=false || new=true

    ui_title "中转设置"
    msg "当前状态:"
    [[ $cur == true ]] && ok "已开启" || dim "已关闭"
    echo
    msg "说明:"
    dim "  开启 = 别人连接本机节点时，出口是选定的远端节点"
    dim "  关闭 = 别人连接本机节点时，出口是本机"
    dim "  与「开启代理」无关，后者只影响本机自身上网"
    echo
    [[ $new == true && -z $(st_get active_peer) ]] && {
        warn "尚未选择远端节点，开启后暂不生效（自动回落本机出口）。"; echo; }
    ask_yn "确认切换？" "Y" || return 0
    warn_reload || return 0

    st_set relay "$new" 1
    if cfg_apply; then
        [[ $new == true ]] && ok "中转已开启" || ok "中转已关闭"
    else
        st_set relay "$cur" 1; cfg_apply >/dev/null 2>&1
        err "切换失败，已保持原状态。"
    fi
    pause
}

srv_restart() {
    local n p l4 cf=0
    ui_title "重启 sing-box"
    [[ -f $SB_CONF ]] || { err "尚未配置。"; pause; return 1; }

    msg "检测配置:"
    "$SB_BIN" check -c "$SB_CONF" >/dev/null 2>&1 && ok "" || {
        err "配置有误"; conf_err "$SB_CONF"; pause; return 1; }
    echo

    msg "检测端口:"
    while read -r n; do
        [[ -n $n ]] || continue
        p=$(nd_get nodes "$n" port); l4=$(nd_get nodes "$n" l4)
        port_busy "$p" "$l4" && ! svc_up "$SVC_SB" && {
            err "$p/$l4 被其他进程占用"; cf=1; }
    done < <(nd_list nodes)
    (( cf )) || ok ""
    echo

    msg "启动服务:"
    svc_restart "$SVC_SB"
    sleep 2
    svc_up "$SVC_SB" && ok "" || { err "启动失败"; svc_log_hint; pause; return 1; }
    echo
    msg "状态:"; ok "运行正常"; echo
    ui_sep
    pause
}

srv_stop() {
    ui_title "停止服务"
    warn "停止后所有连接本机节点的用户将断开。"
    dim "  本机代理也会一并失效（单进程）。"
    echo
    ask_yn "确认停止？" "N" || return 0
    svc_stop "$SVC_SB"
    sleep 1
    svc_up "$SVC_SB" && err "停止失败" || ok "已停止"
    pause
}

srv_menu() {
    local c
    while :; do
        ui_title "服务端管理"
        msg "1. 添加协议"; echo
        msg "2. 删除协议"; echo
        msg "3. 修改配置"; echo
        msg "4. 服务端信息"; echo
        msg "5. Reality域名管理"; echo
        msg "6. 重启服务"; echo
        msg "7. 停止服务"; echo
        msg "8. 更新 sing-box"; echo
        msg "9. 卸载 sing-box"; echo
        relay_on && msg "10. 中转设置  (已开启)" || msg "10. 中转设置  (已关闭)"
        echo
        msg "0. 返回"; echo
        ui_sep
        ask_menu c "0 1 2 3 4 5 6 7 8 9 10"
        case $c in
            0)  return 0 ;;
            1)  add_menu ;;
            2)  del_menu ;;
            3)  mod_menu ;;
            4)  srv_info ;;
            5)  reality_menu ;;
            6)  srv_restart ;;
            7)  srv_stop ;;
            8)  sb_upgrade; pause ;;
            9)  do_uninstall && return 0 ;;
            10) relay_toggle ;;
        esac
    done
}

ossl_tls13() { openssl s_client -help 2>&1 | grep -q -- '-tls1_3'; }

tls_probe() {
    local ex=""
    ossl_tls13 && ex="-tls1_3"
    printf 'Q\n' | tmo 12 openssl s_client \
        -connect "$1:443" -servername "$1" -alpn h2 $ex 2>&1
}

is_cdn() {
    local h; h=$(curl -sI --max-time 8 "https://$1" 2>/dev/null)
    [[ -z $h ]] && return 1
    grep -qiE '^(cf-ray|cf-cache-status|x-amz-cf-id|x-akamai|x-fastly|x-sucuri)' <<<"$h" && return 0
    grep -qiE '^server:[[:space:]]*(cloudflare|cloudfront|akamai|fastly|bunnycdn)' <<<"$h" && return 0
    return 1
}

redir_to() {
    local l
    l=$(curl -sI --max-time 8 "https://$1" 2>/dev/null \
        | awk 'tolower($1)=="location:"{print $2;exit}' | tr -d '\r')
    [[ -z $l ]] && return 1
    l=${l#*://}; printf '%s' "${l%%/*}"
}

reality_check() {
    local d=$1 pb fatal=0 ips a rt
    pkg_ensure openssl || { warn "缺少 openssl，跳过检测。"; return 0; }

    echo; msg "正在检测Reality域名..."; echo

    ips=$(resolve "$d" 2>/dev/null)
    [[ -z $ips ]] && have getent && { err "域名无法解析"; return 1; }
    for a in $ips; do
        is_local_addr "$a" && { err "该域名解析到本机地址，会造成自环"; return 1; }
    done

    pb=$(tls_probe "$d")
    msg "检测结果:"; echo

    if ! ossl_tls13; then
        warn "本机 OpenSSL 不支持 TLS 1.3 探测，已跳过该项"
    elif grep -q 'TLSv1.3' <<<"$pb"; then ok "TLS 1.3 支持"
    else err "不支持 TLS 1.3"; fatal=1; fi

    grep -q 'ALPN protocol: h2' <<<"$pb" && ok "HTTP/2 支持" \
        || { err "不支持 HTTP/2"; fatal=1; }

    grep -qE 'Verify return code: 0 \(ok\)' <<<"$pb" && ok "证书链有效" \
        || warn "证书链校验未通过（不影响 Reality）"

    is_cdn "$d" && warn "疑似 CDN 站点，建议改用源站域名" || ok "非 CDN"

    if rt=$(redir_to "$d") && [[ $rt != "$d" ]]; then
        warn "存在跳转: $d → $rt"; dim "  建议直接使用 $rt"
    else ok "无跳转"; fi
    echo

    (( fatal )) && { err "不可用"; return 1; }
    ok "可用"; echo
    return 0
}

ask_reality_dom() {
    local __v=$1 in
    while :; do
        msg "Reality目标域名:"; dim "(如 www.microsoft.com)"; read -r -p "> " in
        in=$(trim "$in"); in=${in#*://}; in=${in%%/*}
        is_domain "$in" || { warn "域名格式不正确。"; continue; }
        reality_check "$in" && { printf -v "$__v" '%s' "$in"; return 0; }
        ask_yn "该域名不可用，更换？" "Y" || return 1
    done
}

reality_kp() {
    local o pv pb
    o=$("$SB_BIN" generate reality-keypair 2>/dev/null) || return 1
    pv=$(awk -F': *' '/PrivateKey/{print $2;exit}' <<<"$o")
    pb=$(awk -F': *' '/PublicKey/{print $2;exit}' <<<"$o")
    [[ -n $pv && -n $pb ]] || return 1
    printf '%s %s' "$pv" "$pb"
}

reality_sid() { gen_hex 8; }

reality_list() {
    local n
    while read -r n; do
        [[ -n $n ]] || continue
        [[ $(nd_get nodes "$n" protocol) == vless-reality ]] || continue
        printf '%s\t%s\n' "$n" "$(nd_meta nodes "$n" sni)"
    done < <(nd_list nodes)
}

reality_pick() {
    local __v=$1 rows ns=() i=1 n sn op="0" c
    rows=$(reality_list)
    [[ -n $rows ]] || { err "无可选节点。"; return 1; }
    echo; msg "选择节点:"; echo
    while IFS=$'\t' read -r n sn; do
        [[ -n $n ]] || continue
        printf '  %d. %s  (%s)\n' "$i" "$n" "$sn"
        ns+=("$n"); op+=" $i"; i=$(( i + 1 ))
    done <<<"$rows"
    echo; msg "  0. 返回"; echo
    ask_menu c "$op"
    [[ $c == 0 ]] && return 1
    printf -v "$__v" '%s' "${ns[c-1]}"
}

reality_change() {
    local nd new p t
    reality_pick nd || return 0
    ask_reality_dom new || return 0
    warn_reload || return 0
    p=$(nd_path nodes "$nd"); t=$p.tmp
    jq --arg s "$new" '.meta.sni=$s
        | .inbound.tls.server_name=$s
        | .inbound.tls.reality.handshake.server=$s' "$p" >"$t" \
        && mv "$t" "$p" || { rm -f "$t"; err "更新失败。"; return 1; }
    if cfg_apply; then
        lk_refresh nodes "$nd" >/dev/null
        ok "已更换为 $new"
        echo; msg "新链接:"; echo
        printf '%s\n\n' "$(nd_get nodes "$nd" link)"
    else err "配置应用失败。"; fi
    pause
}

reality_menu() {
    local rows cnt n sn c
    while :; do
        ui_title "Reality域名管理"
        rows=$(reality_list)
        [[ -n $rows ]] || { dim "尚无使用 Reality 的节点。"; echo; ui_sep; pause; return 0; }
        msg "当前Reality:"; echo
        cnt=0
        while IFS=$'\t' read -r n sn; do
            [[ -n $n ]] || continue
            cnt=$(( cnt + 1 ))
            printf '  %d. %s\n     %s\n\n' "$cnt" "$n" "$sn"
        done <<<"$rows"
        ui_sep
        msg "2. 更换Reality域名"; echo
        msg "3. 检测Reality域名"; echo
        msg "0. 返回"; echo
        ui_sep
        ask_menu c "0 2 3"
        case $c in
            0) return 0 ;;
            2) reality_change ;;
            3) reality_pick n && { reality_check "$(nd_meta nodes "$n" sni)"; pause; } ;;
        esac
    done
}

peer_loop_check() {
    local sv=$1 pt=$2 f p ips a
    case $sv in
        127.0.0.1|::1|localhost) err "不能添加指向本机的节点。"; return 1 ;;
    esac
    ips=$(resolve "$sv" 2>/dev/null)
    for a in $ips $sv; do
        is_local_addr "$a" && { err "该地址属于本机，会造成流量自环。"; return 1; }
    done
    pub_ip
    if [[ $sv == "$PUB4" || $sv == "$PUB6" ]]; then
        shopt -s nullglob
        for f in "$SB_NODES"/*.json; do
            p=$(jq -r '.ext_port // .port' "$f")
            [[ $p == "$pt" ]] && {
                shopt -u nullglob
                err "该节点即本机的 $(basename "$f" .json)，会造成流量自环。"
                return 1; }
        done
        shopt -u nullglob
        if nat_on; then
            warn "该地址与本机共享同一公网 IP，但端口不同。"
            dim "  NAT 环境下这可能是同一宿主上其他用户的机器。"
            ask_yn "确认不是本机节点？" "N" || return 1
        else
            err "该地址是本机公网地址，会造成流量自环。"
            return 1
        fi
    fi
    return 0
}

peer_add() {
    local url ps pn n sv pt j
    ui_title "添加节点"
    msg "请粘贴节点链接:"; echo
    read -r -p "> " url
    url=$(trim "$url")
    [[ -n $url ]] || { err "链接为空。"; pause; return 1; }

    echo; msg "正在识别..."; echo
    ps=$(lk_parse "$url") || { pause; return 1; }

    pn=$(jq -r '.protocol_name' <<<"$ps")
    n=$(jq -r '.name' <<<"$ps")
    sv=$(jq -r '.server' <<<"$ps")
    pt=$(jq -r '.port' <<<"$ps")

    kv "协议" "$pn"
    nat_ready
    peer_loop_check "$sv" "$pt" || { pause; return 1; }

    if ! is_name "$n" || nd_has peers "$n"; then
        [[ -n $n ]] && warn "节点名 $n 不可用（重名或含非法字符）。"
        ask_name n peers
    else kv "节点名称" "$n"; fi

    j=$(jq -c --arg n "$n" --argjson c "$(date +%s)" \
        '. + {name:$n, created:$c, link:""}' <<<"$ps")
    nd_save peers "$n" "$j" || { pause; return 1; }
    lk_refresh peers "$n" >/dev/null

    msg "保存:"; ok ""; echo

    if [[ -z $(st_get active_peer) ]]; then
        st_set active_peer "$n"
        cfg_apply >/dev/null 2>&1
        dim "  已自动设为当前节点"
        relay_on && dim "  中转已随之生效"
    fi
    ui_sep
    pause
}

peer_select() {
    local ns=() op="0" i=1 n pn sv pt l4 act c
    ui_title "节点选择"
    act=$(st_get active_peer)
    (( $(nd_count peers) )) || { dim "（无节点，请先添加）"; echo; pause; return 0; }

    while read -r n; do
        [[ -n $n ]] || continue
        pn=$(nd_get peers "$n" protocol_name)
        sv=$(nd_get peers "$n" server); pt=$(nd_get peers "$n" port)
        l4=$(nd_get peers "$n" l4)
        if [[ $n == "$act" ]]; then
            printf '%d. %s  %s  %s(当前)%s\n\n' "$i" "$n" "$pn" "$CG" "$CN"
        else printf '%d. %s  %s\n\n' "$i" "$n" "$pn"; fi
        printf '   IPv4:\n   %s\n\n' "$(latency "$sv" "$pt" "$l4" 4)"
        printf '   IPv6:\n   %s\n\n' "$(latency "$sv" "$pt" "$l4" 6)"
        ns+=("$n"); op+=" $i"; i=$(( i + 1 ))
    done < <(nd_list peers)

    msg "0. 返回"; echo; ui_sep
    ask_menu c "$op"
    [[ $c == 0 ]] && return 0
    peer_use "${ns[c-1]}"
    pause
}

peer_use() {
    local n=$1 prev
    nd_has peers "$n" || { err "节点不存在。"; return 1; }
    prev=$(st_get active_peer)
    [[ $n == "$prev" ]] && { dim "已是当前节点。"; return 0; }
    warn_reload || return 0
    st_set active_peer "$n"
    if ! cfg_apply; then
        st_set active_peer "$prev"
        cfg_apply >/dev/null 2>&1
        err "切换失败，已恢复原节点。"
        return 1
    fi
    ok "已切换到 $n"
}

peer_del() {
    local ns=() op="0" i=1 n act c t nx
    ui_title "删除节点"
    act=$(st_get active_peer)
    while read -r n; do
        [[ -n $n ]] || continue
        printf '%d. %s  %s%s\n\n' "$i" "$n" \
            "$(nd_get peers "$n" protocol_name)" \
            "$( [[ $n == "$act" ]] && printf '  (当前)' )"
        ns+=("$n"); op+=" $i"; i=$(( i + 1 ))
    done < <(nd_list peers)

    (( ${#ns[@]} )) || { dim "（无节点）"; echo; pause; return 0; }
    msg "0. 返回"; echo; ui_sep
    ask_menu c "$op"
    [[ $c == 0 ]] && return 0

    t=${ns[c-1]}
    echo
    if [[ $t == "$act" ]]; then
        warn "该节点是当前使用的节点。"
        proxy_on && dim "  删除后本机代理将失去出口。"
        relay_on && dim "  中转将回落到本机出口。"
    fi
    ask_yn "确认删除 $t？" "N" || return 0

    nd_del peers "$t"
    if [[ $t == "$act" ]]; then
        nx=$(nd_list peers | head -n1)
        st_set active_peer "$nx"
        [[ -n $nx ]] && dim "  已自动切换到 $nx"
    fi
    cfg_apply >/dev/null 2>&1
    ok "已删除 $t"
    pause
}

proxy_start() {
    local pe
    ui_title "开启代理"
    pe=$(st_get active_peer)
    [[ -n $pe ]] || { err "请先选择远端节点。"; pause; return 1; }
    kv "当前节点" "$pe"

    msg "检测sing-box:"
    if [[ -x $SB_BIN ]]; then ok "已安装"; echo
    else warn "未安装"; echo; sb_install || { pause; return 1; }; fi
    svc_has "$SVC_RULES" || install_rules_unit
    svc_has "$SVC_SB"    || install_sb_unit

    detect_mode >/dev/null
    show_env

    if [[ $PMODE == manual ]]; then
        warn_manual
        ask_yn "继续？" "Y" || return 0
    else
        ssh_ports_confirm || { pause; return 1; }
    fi
    warn_reload || return 0

    st_set proxy_mode "$PMODE"
    st_set proxy true 1

    if [[ $PMODE != manual ]]; then
        echo
        msg "SSH 端口:"
        ok "直连保护（$(tr '\n' ' ' <"$SSH_PORTS")）"
        echo
        msg "配置绕行保护:"
        if ! bypass_apply; then
            st_set proxy false 1
            err "保护规则写入失败，已中止。"
            pause; return 1
        fi
        ok ""; echo
        if [[ $PMODE == tproxy ]]; then
            msg "配置 TPROXY 重定向:"
            if ! tproxy_apply; then
                bypass_clear
                st_set proxy false 1
                err "TPROXY 规则写入失败，已中止。"
                pause; return 1
            fi
            ok ""; echo
        fi
    fi

    msg "应用配置:"
    if ! cfg_apply; then
        [[ $PMODE == tproxy ]] && tproxy_clear
        [[ $PMODE != manual ]] && bypass_clear
        st_set proxy false 1
        cfg_apply >/dev/null 2>&1
        pause; return 1
    fi
    ok ""; echo

    [[ $PMODE == manual ]] && show_mix_usage
    verify_conn
    ui_sep
    pause
}

proxy_stop() {
    local md
    ui_title "关闭代理"
    proxy_on || { dim "代理未开启。"; echo; pause; return 0; }
    warn_reload || return 0

    md=$(st_get proxy_mode)
    st_set proxy false 1

    [[ $md == tproxy ]] && { msg "撤除 TPROXY 规则:"; tproxy_clear; ok ""; echo; }
    [[ $md != manual ]] && { msg "撤除绕行保护:"; bypass_clear; ok ""; echo; }

    msg "更新配置:"
    cfg_apply || { err "配置更新失败。"; pause; return 1; }
    ok ""; echo
    ok "已关闭本机全局代理"
    echo

    if relay_on && [[ -n $(st_get active_peer) ]]; then
        dim "  中转仍在运行：连接本机的流量继续经由 $(st_get active_peer) 出口"
        echo
    fi
    ui_sep
    pause
}

verify_conn() {
    local md ip4 ip6 au
    md=$(st_get proxy_mode)
    msg "连通性验证:"
    echo

    if [[ $md == manual ]]; then
        au=$(mix_auth)
        ip4=$(http_getp 4 https://api.ipify.org "$au" | tr -d '[:space:]')
        ip6=$(http_getp 6 https://api64.ipify.org "$au" | tr -d '[:space:]')
    else
        ip4=$(http_getv 4 https://api.ipify.org | tr -d '[:space:]')
        ip6=$(http_getv 6 https://api64.ipify.org | tr -d '[:space:]')
    fi

    if is_v4 "$ip4"; then
        printf '  出口IPv4:\n  %s  (%s)\n\n' "$ip4" "$(ip_cc "$ip4")"
    else
        err "代理链路 IPv4 不通"
        echo
        if [[ $md == tproxy ]]; then
            warn "TPROXY 未能接管流量，可能内核缺少 nft tproxy 支持。"
            if ask_yn "回退为本地端口模式？" "Y"; then
                tproxy_clear
                bypass_clear
                st_set proxy_mode manual
                cfg_apply >/dev/null 2>&1
                warn "已回退为本地端口模式。"
                show_mix_usage
            fi
        fi
    fi

    if is_v6 "$ip6"; then
        printf '  出口IPv6:\n  %s  (%s)\n\n' "$ip6" "$(ip_cc "$ip6")"
    else
        dim "  出口IPv6: 不可用"
        echo
    fi

    msg "状态:"
    svc_up "$SVC_SB" && ok "运行正常" || err "异常"
    echo
}

cli_status() {
    local pe sv pt l4 md ip4 ip6 au
    ui_title "客户端状态"

    msg "sing-box:"
    svc_up "$SVC_SB" && ok "运行正常" || err "未运行"
    echo

    pe=$(st_get active_peer)
    md=$(st_get proxy_mode)
    kv "当前节点" "${pe:-未选择}"
    [[ -n $pe ]] && kv "当前协议" "$(nd_get peers "$pe" protocol_name)"

    msg "本机代理:"
    if proxy_on; then
        case $md in
            tun)    ok "已开启（TUN 全局）" ;;
            tproxy) ok "已开启（TPROXY 全局）" ;;
            manual) warn "已开启（仅本地端口 127.0.0.1:$(mix_port)）" ;;
        esac
    else dim "已关闭"; fi
    echo

    msg "中转:"
    if relay_on && [[ -n $pe ]]; then ok "已开启 → $pe"
    elif relay_on; then warn "已开启但未生效"
    else dim "已关闭"; fi
    echo

    [[ -n $pe ]] || { ui_sep; pause; return 0; }

    sv=$(nd_get peers "$pe" server)
    pt=$(nd_get peers "$pe" port)
    l4=$(nd_get peers "$pe" l4)

    if [[ $l4 == tcp ]]; then
        msg "TCP:"; echo
        printf '  IPv4:\n  %s\n\n' "$(latency "$sv" "$pt" tcp 4)"
        printf '  IPv6:\n  %s\n\n' "$(latency "$sv" "$pt" tcp 6)"
    else
        msg "UDP:"; echo
        printf '  IPv4:\n  %s\n\n' "$(latency "$sv" "$pt" udp 4)"
        printf '  IPv6:\n  %s\n\n' "$(latency "$sv" "$pt" udp 6)"
        dim "  UDP 无握手可测，此处为 ICMP 延迟"
        echo
    fi

    proxy_on || { ui_sep; pause; return 0; }

    if [[ $md == manual ]]; then
        au=$(mix_auth)
        ip4=$(http_getp 4 https://api.ipify.org "$au" | tr -d '[:space:]')
        ip6=$(http_getp 6 https://api64.ipify.org "$au" | tr -d '[:space:]')
    else
        ip4=$(http_getv 4 https://api.ipify.org | tr -d '[:space:]')
        ip6=$(http_getv 6 https://api64.ipify.org | tr -d '[:space:]')
    fi

    if is_v4 "$ip4"; then
        kv "出口IPv4" "$ip4"; kv "国家" "$(ip_cc "$ip4")"
    else kv "出口IPv4" "不可用"; fi
    if is_v6 "$ip6"; then
        kv "出口IPv6" "$ip6"; kv "国家" "$(ip_cc "$ip6")"
    else kv "出口IPv6" "不可用"; fi

    ui_sep
    pause
}

cli_menu() {
    local c
    while :; do
        ui_title "客户端管理"
        msg "1. 添加节点"; echo
        msg "2. 节点选择"; echo
        msg "3. 删除节点"; echo
        msg "4. 开启代理"; echo
        msg "5. 关闭代理"; echo
        msg "6. 客户端状态"; echo
        msg "0. 返回"; echo
        ui_sep
        ask_menu c "0 1 2 3 4 5 6"
        case $c in
            0) return 0 ;;
            1) peer_add ;;
            2) peer_select ;;
            3) peer_del ;;
            4) proxy_start ;;
            5) proxy_stop ;;
            6) cli_status ;;
        esac
    done
}

mem_info() {
    local tot av used
    [[ -r /proc/meminfo ]] || { printf '未知'; return; }
    tot=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
    av=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
    [[ -z $av ]] && av=$(awk '/^MemFree:/{print int($2/1024)}' /proc/meminfo)
    used=$(( tot - av ))
    if (( tot >= 1024 )); then
        printf '%dMB / %.1fGB' "$used" "$(awk -v t="$tot" 'BEGIN{printf "%.1f", t/1024}')"
    else printf '%dMB / %dMB' "$used" "$tot"; fi
}

cpu_cores() {
    if have nproc; then nproc
    else grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '未知'; fi
}

sys_status() {
    fi
    have jq   || missing+=(jq)
    have curl || missing+=(curl)
    (( ${#missing[@]} )) && {
        msg "正在安装基础依赖: ${missing[*]}"
        for c in "${missing[@]}"; do pkg_ensure "$c" || die "依赖 $c 安装失败。"; done
        echo
    }
    have getent || pkg_ensure getent >/dev/null 2>&1
    need_nft || warn "缺少 nftables，防火墙放行与透明代理将不可用"
    need_iproute || warn "缺少 iproute2，TUN 与透明代理将不可用"
    return 0
}

boot() {
    need_root
    detect_distro
    detect_arch
    base_deps
    mkdir -p "$SB_NODES" "$SB_PEERS" "$CERT_DIR"
    chmod 700 "$SB_ROOT" "$SB_NODES" "$SB_PEERS" "$CERT_DIR"
    st_init
}

main_menu() {
    local c
    while :; do
        ui_title "Sing-box Manager"
        msg "1. 服务端管理"; echo
        msg "2. 客户端管理"; echo
        msg "3. 系统状态"; echo
        msg "4. 环境自检"; echo
        msg "0. 退出"; echo
        ui_sep
        ask_menu c "0 1 2 3 4"
        case $c in
            0) echo; exit 0 ;;
            1) srv_menu ;;
            2) cli_menu ;;
            3) sys_status ;;
            4) doctor; pause ;;
        esac
    done
}

main() {
    case ${1:-} in
        --apply-rules)
            SBM_BATCH=1
            need_root; detect_distro; st_init
            rules_all
            exit 0 ;;
        --doctor)
            boot; detect_virt; doctor; exit 0 ;;
        --version)
            printf 'sbm %s\n' "$SBM_VERSION"; exit 0 ;;
    esac
    boot
    detect_virt
    fw_detect >/dev/null
    self_install
    main_menu
}

main "$@"
