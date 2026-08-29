#!/usr/bin/env bash

set -u
export LC_ALL=C

TARGET="/usr/lib/sysctl.d/50-default.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# 基础检查
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}✗ 必须使用 root 运行。${NC}"
    exit 1
fi

if [ ! -f "$TARGET" ]; then
    echo -e "${RED}✗ 找不到 $TARGET${NC}"
    exit 1
fi

echo "============================================================"
echo " Debian 13 双栈 TCP/UDP 网络调优"
echo " 全面审计 → 自动判断 → 人工确认 → 精准持久化"
echo "============================================================"
echo
echo "策略："
echo "  公网带宽：按 ≥1 Gbps 处理"
echo "  CPU/RAM：自动检测"
echo "  Swap：不修改"
echo "  配置文件：只修改 $TARGET"
echo "  不创建新的 sysctl 配置文件"
echo

# ============================================================
# 工具函数
# ============================================================

get_sysctl()
{
    local key="$1"
    sysctl -n "$key" 2>/dev/null || echo "unknown"
}

num()
{
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

# ============================================================
# [1/10] 系统检测
# ============================================================

echo "[1/10] 系统检测"

if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-unknown}"
else
    OS_NAME="unknown"
fi

KERNEL="$(uname -r)"
CPU_CORES="$(nproc 2>/dev/null || echo 1)"

RAM_MB="$(
    awk '/MemTotal:/ {
        printf "%d", $2/1024
        exit
    }' /proc/meminfo 2>/dev/null
)"

RAM_MB="${RAM_MB:-0}"

SWAP_MB="$(
    awk 'NR>1 {
        total += $3
    }
    END {
        printf "%d", total/1024
    }' /proc/swaps 2>/dev/null
)"

SWAP_MB="${SWAP_MB:-0}"

echo "  OS       : $OS_NAME"
echo "  Kernel   : $KERNEL"
echo "  CPU      : ${CPU_CORES} cores"
echo "  RAM      : ${RAM_MB} MB"
echo "  Swap     : ${SWAP_MB} MB（不修改）"
echo

# ============================================================
# [2/10] 双栈 / TCP / UDP
# ============================================================

echo "[2/10] IPv4 / IPv6 / TCP / UDP 检测"

IPV4_COUNT="$(
    ip -4 addr show scope global 2>/dev/null |
    grep -c 'inet '
)"

IPV6_COUNT="$(
    ip -6 addr show scope global 2>/dev/null |
    grep -c 'inet6 '
)"

IPV4_COUNT="${IPV4_COUNT:-0}"
IPV6_COUNT="${IPV6_COUNT:-0}"

IPV6_DISABLED="$(get_sysctl net.ipv6.conf.all.disable_ipv6)"

TCP_LISTEN="$(ss -Hlt 2>/dev/null | wc -l)"
TCP_ESTABLISHED="$(ss -Htan state established 2>/dev/null | wc -l)"
UDP_SOCKETS="$(ss -Huan 2>/dev/null | wc -l)"

DEFAULT_IFACE="$(
    ip route show default 2>/dev/null |
    awk 'NR==1 {print $5; exit}'
)"

echo "  IPv4 地址        : $IPV4_COUNT"
echo "  IPv6 地址        : $IPV6_COUNT"
echo "  IPv6 disabled    : $IPV6_DISABLED"
echo "  TCP LISTEN       : $TCP_LISTEN"
echo "  TCP established  : $TCP_ESTABLISHED"
echo "  UDP sockets      : $UDP_SOCKETS"
echo "  默认网卡         : ${DEFAULT_IFACE:-unknown}"
echo

# ============================================================
# [3/10] SSH 检测
# ============================================================

echo "[3/10] SSH 会话检测"

if [ -n "${SSH_CONNECTION:-}" ]; then

    SSH_REMOTE="$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $1}')"
    SSH_REMOTE_PORT="$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $2}')"
    SSH_LOCAL="$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $3}')"
    SSH_LOCAL_PORT="$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $4}')"

    echo -e "  ${GREEN}✓ 检测到当前 SSH 远程会话${NC}"
    echo "  远端 IP     : $SSH_REMOTE"
    echo "  远端端口    : $SSH_REMOTE_PORT"
    echo "  本地地址    : $SSH_LOCAL"
    echo "  本地端口    : $SSH_LOCAL_PORT"

else

    echo "  当前未检测到 SSH_CONNECTION"

fi

echo

# ============================================================
# [4/10] CPU / RAM 自动分档
# ============================================================

echo "[4/10] CPU / RAM 调优等级"

if [ "$RAM_MB" -lt 768 ]; then
    RAM_CLASS="tiny"
elif [ "$RAM_MB" -lt 1536 ]; then
    RAM_CLASS="small"
elif [ "$RAM_MB" -lt 4096 ]; then
    RAM_CLASS="medium"
else
    RAM_CLASS="large"
fi

if [ "$CPU_CORES" -le 1 ]; then
    CPU_CLASS="1"
elif [ "$CPU_CORES" -le 2 ]; then
    CPU_CLASS="2"
elif [ "$CPU_CORES" -le 4 ]; then
    CPU_CLASS="4"
else
    CPU_CLASS="8plus"
fi

echo "  CPU 等级 : $CPU_CLASS"
echo "  RAM 等级 : $RAM_CLASS"
echo
echo "  公网带宽：≥1 Gbps（按固定前提处理）"
echo

# ============================================================
# [5/10] BBR / FQ / TFO
# ============================================================

echo "[5/10] BBR / FQ / TCP Fast Open"

CURRENT_CC="$(get_sysctl net.ipv4.tcp_congestion_control)"
AVAILABLE_CC="$(get_sysctl net.ipv4.tcp_allowed_congestion_control)"
CURRENT_QDISC="$(get_sysctl net.core.default_qdisc)"
CURRENT_TFO="$(get_sysctl net.ipv4.tcp_fastopen)"

if printf '%s\n' "$AVAILABLE_CC" | grep -qw bbr; then
    BBR_SUPPORTED="yes"
else
    BBR_SUPPORTED="no"
fi

if modinfo sch_fq >/dev/null 2>&1; then
    FQ_SUPPORTED="yes"
else
    FQ_SUPPORTED="no"
fi

echo "  当前拥塞控制      : $CURRENT_CC"
echo "  可用拥塞控制      : $AVAILABLE_CC"
echo "  当前默认 qdisc    : $CURRENT_QDISC"
echo "  当前 TCP Fast Open : $CURRENT_TFO"
echo "  BBR 内核支持      : $BBR_SUPPORTED"
echo "  FQ 内核支持       : $FQ_SUPPORTED"
echo

# ============================================================
# [6/10] 网络实际压力
# ============================================================

echo "[6/10] 网络实际压力检测"

SOFTNET_BEFORE="$(
    awk '{
        sum += $2
    }
    END {
        print sum+0
    }' /proc/net/softnet_stat 2>/dev/null
)"

SOFTNET_BEFORE="${SOFTNET_BEFORE:-0}"

RX_BEFORE="$(
    awk -F: '
    /^[[:space:]]*[a-zA-Z0-9_.-]+:/ {
        split($2,a," ")
        sum += a[4]
    }
    END {
        print sum+0
    }' /proc/net/dev 2>/dev/null
)"

RX_BEFORE="${RX_BEFORE:-0}"

TX_BEFORE="$(
    awk -F: '
    /^[[:space:]]*[a-zA-Z0-9_.-]+:/ {
        split($2,a," ")
        sum += a[12]
    }
    END {
        print sum+0
    }' /proc/net/dev 2>/dev/null
)"

TX_BEFORE="${TX_BEFORE:-0}"

sleep 3

SOFTNET_AFTER="$(
    awk '{
        sum += $2
    }
    END {
        print sum+0
    }' /proc/net/softnet_stat 2>/dev/null
)"

SOFTNET_AFTER="${SOFTNET_AFTER:-0}"

RX_AFTER="$(
    awk -F: '
    /^[[:space:]]*[a-zA-Z0-9_.-]+:/ {
        split($2,a," ")
        sum += a[4]
    }
    END {
        print sum+0
    }' /proc/net/dev 2>/dev/null
)"

RX_AFTER="${RX_AFTER:-0}"

TX_AFTER="$(
    awk -F: '
    /^[[:space:]]*[a-zA-Z0-9_.-]+:/ {
        split($2,a," ")
        sum += a[12]
    }
    END {
        print sum+0
    }' /proc/net/dev 2>/dev/null
)"

TX_AFTER="${TX_AFTER:-0}"

SOFTNET_DROP=$((SOFTNET_AFTER - SOFTNET_BEFORE))
RX_DROP=$((RX_AFTER - RX_BEFORE))
TX_DROP=$((TX_AFTER - TX_BEFORE))

[ "$SOFTNET_DROP" -lt 0 ] && SOFTNET_DROP=0
[ "$RX_DROP" -lt 0 ] && RX_DROP=0
[ "$TX_DROP" -lt 0 ] && TX_DROP=0

echo "  softnet drops / 3s : $SOFTNET_DROP"
echo "  RX drops / 3s      : $RX_DROP"
echo "  TX drops / 3s      : $TX_DROP"
echo

# ============================================================
# [7/10] 当前重要参数
# ============================================================

echo "[7/10] 当前运行参数"

declare -A RUNNING

PARAMS=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_syncookies
    net.core.somaxconn
    net.ipv4.tcp_max_syn_backlog
    net.core.netdev_max_backlog
    net.core.netdev_budget
    net.core.netdev_budget_usecs

    net.core.rmem_default
    net.core.wmem_default
    net.core.rmem_max
    net.core.wmem_max

    net.ipv4.udp_rmem_min
    net.ipv4.udp_wmem_min

    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.ipv4.tcp_mem

    net.ipv4.tcp_window_scaling
    net.ipv4.tcp_sack
    net.ipv4.tcp_timestamps

    net.ipv4.tcp_fin_timeout
    net.ipv4.tcp_keepalive_time
    net.ipv4.tcp_keepalive_intvl
    net.ipv4.tcp_keepalive_probes

    net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_base_mss
    net.ipv4.tcp_ecn

    net.ipv4.tcp_fastopen
    net.ipv4.tcp_notsent_lowat
    net.ipv4.tcp_no_metrics_save

    net.ipv4.ip_local_port_range

    net.ipv4.ip_forward
    net.ipv4.conf.all.forwarding
    net.ipv4.conf.default.forwarding

    net.ipv6.conf.all.forwarding
    net.ipv6.conf.default.forwarding
    net.ipv6.conf.all.disable_ipv6
)

for key in "${PARAMS[@]}"; do
    RUNNING["$key"]="$(get_sysctl "$key")"
done

echo "  default_qdisc       : ${RUNNING[net.core.default_qdisc]}"
echo "  congestion_control  : ${RUNNING[net.ipv4.tcp_congestion_control]}"
echo "  tcp_fastopen        : ${RUNNING[net.ipv4.tcp_fastopen]}"
echo "  somaxconn            : ${RUNNING[net.core.somaxconn]}"
echo "  tcp_max_syn_backlog  : ${RUNNING[net.ipv4.tcp_max_syn_backlog]}"
echo "  netdev_max_backlog   : ${RUNNING[net.core.netdev_max_backlog]}"
echo "  tcp_syncookies       : ${RUNNING[net.ipv4.tcp_syncookies]}"
echo "  tcp_window_scaling   : ${RUNNING[net.ipv4.tcp_window_scaling]}"
echo "  tcp_sack             : ${RUNNING[net.ipv4.tcp_sack]}"
echo "  tcp_timestamps       : ${RUNNING[net.ipv4.tcp_timestamps]}"
echo

# ============================================================
# [8/10] 检查 systemd-sysctl 配置
# ============================================================

echo "[8/10] 检测 systemd-sysctl 实际配置文件"

SYSCTL_FILES=()

for dir in \
    /etc/sysctl.d \
    /run/sysctl.d \
    /usr/local/lib/sysctl.d \
    /usr/lib/sysctl.d
do

    [ -d "$dir" ] || continue

    while IFS= read -r file; do
        SYSCTL_FILES+=("$file")
    done < <(
        find "$dir" \
            -maxdepth 1 \
            -type f \
            -name '*.conf' \
            -print 2>/dev/null
    )

done

# 去重并排序
mapfile -t SYSCTL_FILES < <(
    printf '%s\n' "${SYSCTL_FILES[@]}" |
    awk '!seen[$0]++' |
    sort
)

echo

if [ "${#SYSCTL_FILES[@]}" -eq 0 ]; then
    echo "  未找到 sysctl.d 配置文件"
else

    echo "  systemd-sysctl 配置文件："

    for file in "${SYSCTL_FILES[@]}"; do
        echo "    $file"
    done

fi

echo

# ============================================================
# 精确寻找参数最终来源
#
# 注意：
# systemd-sysctl 按文件名排序。
# 同名文件的目录优先级也会影响最终配置。
#
# 这里使用简单 Bash + grep，
# 避免之前出现的复杂 AWK 语法错误。
# ============================================================

find_param_source()
{
    local key="$1"
    local found=""

    for file in "${SYSCTL_FILES[@]}"; do

        [ -r "$file" ] || continue

        if grep -Eq "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$file"; then
            found="$file"
        fi

    done

    printf '%s' "$found"
}

find_param_value()
{
    local key="$1"
    local file="$2"

    [ -r "$file" ] || return 0

    sed -n \
        -E \
        "s/^[[:space:]]*${key//./\\.}[[:space:]]*=[[:space:]]*(.*)$/\1/p" \
        "$file" |
        tail -n1
}

# ============================================================
# [9/10] 自动生成调优目标
# ============================================================

echo "[9/10] 自动生成调优目标"

declare -A TARGET
declare -A REASON

# ------------------------------------------------------------
# BBR
# ------------------------------------------------------------

if [ "$BBR_SUPPORTED" = "yes" ]; then
    TARGET[net.ipv4.tcp_congestion_control]="bbr"
    REASON[net.ipv4.tcp_congestion_control]="内核支持 BBR，公网 ≥1 Gbps"
fi

# ------------------------------------------------------------
# FQ
# ------------------------------------------------------------

if [ "$FQ_SUPPORTED" = "yes" ]; then
    TARGET[net.core.default_qdisc]="fq"
    REASON[net.core.default_qdisc]="BBR 推荐配合 fq"
fi

# ------------------------------------------------------------
# TCP Fast Open
# 3 = client + server
# ------------------------------------------------------------

TARGET[net.ipv4.tcp_fastopen]="3"
REASON[net.ipv4.tcp_fastopen]="启用 TCP client/server Fast Open"

# ------------------------------------------------------------
# TCP 基础能力
# ------------------------------------------------------------

TARGET[net.ipv4.tcp_syncookies]="1"
REASON[net.ipv4.tcp_syncookies]="保持 SYN flood 防护"

TARGET[net.ipv4.tcp_window_scaling]="1"
REASON[net.ipv4.tcp_window_scaling]="高带宽长 RTT 必需"

TARGET[net.ipv4.tcp_sack]="1"
REASON[net.ipv4.tcp_sack]="保持 TCP SACK"

TARGET[net.ipv4.tcp_timestamps]="1"
REASON[net.ipv4.tcp_timestamps]="保持 TCP timestamps"

# ------------------------------------------------------------
# 端口范围
# ------------------------------------------------------------

TARGET[net.ipv4.ip_local_port_range]="1024 65535"
REASON[net.ipv4.ip_local_port_range]="增加本地临时端口空间"

# ------------------------------------------------------------
# backlog
#
# 1GB VPS 不使用夸张的 32768/65535。
# ------------------------------------------------------------

if [ "$CPU_CORES" -le 1 ]; then

    TARGET[net.core.somaxconn]="4096"
    REASON[net.core.somaxconn]="1 vCPU，控制监听队列"

    TARGET[net.ipv4.tcp_max_syn_backlog]="4096"
    REASON[net.ipv4.tcp_max_syn_backlog]="1 vCPU，适中的 SYN backlog"

else

    TARGET[net.core.somaxconn]="8192"
    REASON[net.core.somaxconn]="多 vCPU，高并发监听"

    TARGET[net.ipv4.tcp_max_syn_backlog]="8192"
    REASON[net.ipv4.tcp_max_syn_backlog]="多 vCPU，高并发 SYN backlog"

fi

# ------------------------------------------------------------
# 网络 backlog
#
# 只有实际出现 softnet/RX drop 才提高。
# ------------------------------------------------------------

if [ "$SOFTNET_DROP" -gt 0 ] || [ "$RX_DROP" -gt 0 ]; then

    if [ "$CPU_CORES" -le 1 ]; then
        TARGET[net.core.netdev_max_backlog]="4096"
        REASON[net.core.netdev_max_backlog]="检测到网络丢包/softnet压力"
    else
        TARGET[net.core.netdev_max_backlog]="8192"
        REASON[net.core.netdev_max_backlog]="检测到网络丢包/softnet压力"
    fi

fi

# ------------------------------------------------------------
# netdev budget
#
# 不因为“千兆”盲目修改。
# 只有出现 softnet drops 才处理。
# ------------------------------------------------------------

if [ "$SOFTNET_DROP" -gt 0 ]; then

    TARGET[net.core.netdev_budget]="600"
    REASON[net.core.netdev_budget]="检测到 softnet drops"

    TARGET[net.core.netdev_budget_usecs]="8000"
    REASON[net.core.netdev_budget_usecs]="检测到 softnet drops"

fi

# ------------------------------------------------------------
# Socket buffer
#
# 1GB VPS：
#
# 不使用 256MB 这种极端值。
# ------------------------------------------------------------

if [ "$RAM_MB" -lt 1536 ]; then

    TARGET[net.core.rmem_default]="262144"
    REASON[net.core.rmem_default]="≤1.5GB RAM，控制默认 RX buffer"

    TARGET[net.core.wmem_default]="262144"
    REASON[net.core.wmem_default]="≤1.5GB RAM，控制默认 TX buffer"

    TARGET[net.core.rmem_max]="16777216"
    REASON[net.core.rmem_max]="≤1.5GB RAM，16MB socket 上限"

    TARGET[net.core.wmem_max]="16777216"
    REASON[net.core.wmem_max]="≤1.5GB RAM，16MB socket 上限"

    TARGET[net.ipv4.udp_rmem_min]="8192"
    REASON[net.ipv4.udp_rmem_min]="UDP 最小 RX buffer"

    TARGET[net.ipv4.udp_wmem_min]="8192"
    REASON[net.ipv4.udp_wmem_min]="UDP 最小 TX buffer"

    TARGET[net.ipv4.tcp_rmem]="4096 262144 16777216"
    REASON[net.ipv4.tcp_rmem]="1GB VPS，避免 TCP memory 过度膨胀"

    TARGET[net.ipv4.tcp_wmem]="4096 262144 16777216"
    REASON[net.ipv4.tcp_wmem]="1GB VPS，避免 TCP memory 过度膨胀"

else

    TARGET[net.core.rmem_default]="524288"
    REASON[net.core.rmem_default]="较大 RAM，提升默认 RX buffer"

    TARGET[net.core.wmem_default]="524288"
    REASON[net.core.wmem_default]="较大 RAM，提升默认 TX buffer"

    TARGET[net.core.rmem_max]="33554432"
    REASON[net.core.rmem_max]="较大 RAM，32MB socket 上限"

    TARGET[net.core.wmem_max]="33554432"
    REASON[net.core.wmem_max]="较大 RAM，32MB socket 上限"

    TARGET[net.ipv4.udp_rmem_min]="8192"
    REASON[net.ipv4.udp_rmem_min]="UDP 最小 RX buffer"

    TARGET[net.ipv4.udp_wmem_min]="8192"
    REASON[net.ipv4.udp_wmem_min]="UDP 最小 TX buffer"

    TARGET[net.ipv4.tcp_rmem]="4096 524288 33554432"
    REASON[net.ipv4.tcp_rmem]="较大 RAM，TCP RX autotuning"

    TARGET[net.ipv4.tcp_wmem]="4096 524288 33554432"
    REASON[net.ipv4.tcp_wmem]="较大 RAM，TCP TX autotuning"

fi

# ------------------------------------------------------------
# TCP memory
#
# 不直接套固定大数。
# 让内核根据 RAM 自动计算。
# ------------------------------------------------------------

TOTAL_PAGES="$(
    awk '/MemTotal:/ {
        printf "%d", ($2*1024)/4096
        exit
    }' /proc/meminfo
)"

TOTAL_PAGES="${TOTAL_PAGES:-0}"

if [ "$TOTAL_PAGES" -gt 0 ]; then

    TCP_MEM_MIN=$((TOTAL_PAGES / 32))
    TCP_MEM_PRESSURE=$((TOTAL_PAGES / 8))
    TCP_MEM_MAX=$((TOTAL_PAGES / 4))

    if [ "$TCP_MEM_MIN" -lt 32768 ]; then
        TCP_MEM_MIN=32768
    fi

    if [ "$TCP_MEM_PRESSURE" -lt 65536 ]; then
        TCP_MEM_PRESSURE=65536
    fi

    if [ "$TCP_MEM_MAX" -lt 131072 ]; then
        TCP_MEM_MAX=131072
    fi

    TARGET[net.ipv4.tcp_mem]="$TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX"
    REASON[net.ipv4.tcp_mem]="根据实际 RAM 自动计算 TCP memory"

fi

# ------------------------------------------------------------
# TCP 连接管理
# ------------------------------------------------------------

TARGET[net.ipv4.tcp_fin_timeout]="30"
REASON[net.ipv4.tcp_fin_timeout]="减少 FIN-WAIT 持有时间"

TARGET[net.ipv4.tcp_keepalive_time]="600"
REASON[net.ipv4.tcp_keepalive_time]="长连接存活检测"

TARGET[net.ipv4.tcp_keepalive_intvl]="15"
REASON[net.ipv4.tcp_keepalive_intvl]="keepalive 检测间隔"

TARGET[net.ipv4.tcp_keepalive_probes]="5"
REASON[net.ipv4.tcp_keepalive_probes]="keepalive 探测次数"

# ------------------------------------------------------------
# MTU / TCP 行为
# ------------------------------------------------------------

TARGET[net.ipv4.tcp_mtu_probing]="1"
REASON[net.ipv4.tcp_mtu_probing]="检测 PMTU black-hole"

TARGET[net.ipv4.tcp_base_mss]="1024"
REASON[net.ipv4.tcp_base_mss]="MTU probing 基础 MSS"

TARGET[net.ipv4.tcp_ecn]="0"
REASON[net.ipv4.tcp_ecn]="避免 VPS/路径设备 ECN 兼容性问题"

TARGET[net.ipv4.tcp_notsent_lowat]="131072"
REASON[net.ipv4.tcp_notsent_lowat]="限制 TCP 未发送数据堆积"

TARGET[net.ipv4.tcp_no_metrics_save]="0"
REASON[net.ipv4.tcp_no_metrics_save]="保留 TCP route metrics"

# ============================================================
# 双栈 forwarding
#
# 注意：
# 只有检测到当前已经开启 forwarding 才保持。
# 不因为 sing-box 自动开启路由转发。
# ============================================================

if [ "${RUNNING[net.ipv4.ip_forward]}" = "1" ]; then

    TARGET[net.ipv4.ip_forward]="1"
    REASON[net.ipv4.ip_forward]="当前系统已启用 IPv4 forwarding，保持"

fi

if [ "${RUNNING[net.ipv4.conf.all.forwarding]}" = "1" ]; then

    TARGET[net.ipv4.conf.all.forwarding]="1"
    REASON[net.ipv4.conf.all.forwarding]="当前系统已启用 IPv4 interface forwarding，保持"

fi

if [ "${RUNNING[net.ipv4.conf.default.forwarding]}" = "1" ]; then

    TARGET[net.ipv4.conf.default.forwarding]="1"
    REASON[net.ipv4.conf.default.forwarding]="当前系统已启用 IPv4 default forwarding，保持"

fi

if [ "${RUNNING[net.ipv6.conf.all.forwarding]}" = "1" ]; then

    TARGET[net.ipv6.conf.all.forwarding]="1"
    REASON[net.ipv6.conf.all.forwarding]="当前系统已启用 IPv6 forwarding，保持"

fi

if [ "${RUNNING[net.ipv6.conf.default.forwarding]}" = "1" ]; then

    TARGET[net.ipv6.conf.default.forwarding]="1"
    REASON[net.ipv6.conf.default.forwarding]="当前系统已启用 IPv6 default forwarding，保持"

fi

# ============================================================
# [10/10] 审计结果
# ============================================================

echo
echo "[10/10] 参数最终审计"

echo
echo "============================================================"
echo "                    参数实际配置来源"
echo "============================================================"

for key in "${!TARGET[@]}"; do

    source="$(find_param_source "$key")"

    if [ -n "$source" ]; then

        value="$(find_param_value "$key" "$source")"

        echo
        echo "[$key]"
        echo "  实际配置文件 : $source"
        echo "  文件值       : $value"

    else

        echo
        echo "[$key]"
        echo "  实际配置文件 : 未找到"

    fi

done

# ============================================================
# 判断修改
# ============================================================

declare -a CHANGE_KEYS=()
declare -a CHANGE_VALUES=()
declare -a CHANGE_SOURCES=()
declare -a CHANGE_MODES=()

echo
echo "============================================================"
echo "                       调优审计结果"
echo "============================================================"

for key in "${PARAMS[@]}"; do

    target="${TARGET[$key]:-}"

    [ -n "$target" ] || continue

    current="${RUNNING[$key]:-unknown}"

    if [ "$current" = "$target" ]; then

        echo -e "${GREEN}✓ $key${NC}"
        echo "    当前：$current"
        echo "    目标：$target"
        echo "    状态：无需修改"

        continue

    fi

    source="$(find_param_source "$key")"

    echo
    echo -e "${YELLOW}⚠ $key${NC}"
    echo "    当前运行值 : $current"
    echo "    建议值     : $target"
    echo "    原因       : ${REASON[$key]:-自动调优}"

    if [ "$source" = "$TARGET" ]; then

        echo "    配置来源   : $TARGET"
        echo "    操作       : 精准修改现有参数"

        CHANGE_KEYS+=("$key")
        CHANGE_VALUES+=("$target")
        CHANGE_SOURCES+=("$TARGET")
        CHANGE_MODES+=("replace")

    elif [ -z "$source" ]; then

        echo "    配置来源   : 不存在"
        echo "    操作       : 追加到 $TARGET"

        CHANGE_KEYS+=("$key")
        CHANGE_VALUES+=("$target")
        CHANGE_SOURCES+=("$TARGET")
        CHANGE_MODES+=("append")

    else

        echo "    配置来源   : $source"
        echo "    操作       : 不修改该参数"
        echo "    原因       : 实际生效来源不是 $TARGET"

    fi

done

# ============================================================
# 注释参数审计
# ============================================================

echo
echo "============================================================"
echo "               50-default.conf 注释参数检查"
echo "============================================================"

COMMENTED_COUNT=0

for key in "${PARAMS[@]}"; do

    target="${TARGET[$key]:-}"

    [ -n "$target" ] || continue

    if grep -Eq "^[[:space:]]*[#;][[:space:]]*${key//./\\.}[[:space:]]*=" "$TARGET"; then

        echo "  注释参数：$key"
        echo "  目标值  ：$target"

        COMMENTED_COUNT=$((COMMENTED_COUNT + 1))

    fi

done

if [ "$COMMENTED_COUNT" -eq 0 ]; then
    echo "  未发现目标参数的注释配置。"
fi

# ============================================================
# 待修改项目
# ============================================================

echo
echo "============================================================"
echo "                       待修改项目"
echo "============================================================"

if [ "${#CHANGE_KEYS[@]}" -eq 0 ]; then

    echo
    echo -e "${GREEN}✓ 没有可以安全修改的项目。${NC}"
    echo
    echo "注意："
    echo "  如果某参数实际由其他配置文件提供，"
    echo "  本脚本按照你的要求不会修改那个文件。"
    echo
    exit 0

fi

for ((i=0; i<${#CHANGE_KEYS[@]}; i++)); do

    key="${CHANGE_KEYS[$i]}"
    value="${CHANGE_VALUES[$i]}"
    mode="${CHANGE_MODES[$i]}"

    printf "  %-42s → %s\n" "$key" "$value"

    if [ "$mode" = "replace" ]; then
        echo "      精准修改：$TARGET"
    else
        echo "      新增参数：$TARGET"
    fi

done

# ============================================================
# 明确不会修改
# ============================================================

echo
echo "============================================================"
echo "                    明确不会修改"
echo "============================================================"

echo "  ✓ Swap"
echo "  ✓ vm.swappiness"
echo "  ✓ vm.overcommit_memory"
echo "  ✓ vm.* 其他参数"
echo "  ✓ SSH 服务"
echo "  ✓ 网络服务"
echo "  ✓ routing table"
echo "  ✓ 当前连接"
echo "  ✓ 当前 qdisc"
echo "  ✓ 当前 congestion control"
echo "  ✓ 当前 sysctl 运行值"
echo "  ✓ modprobe"
echo "  ✓ sysctl -w"
echo "  ✓ systemd-sysctl reload"
echo "  ✓ systemctl restart networking"
echo "  ✓ systemctl restart NetworkManager"
echo "  ✓ systemctl restart ssh"
echo "  ✓ reboot"
echo
echo "  ✓ 不创建 /etc/sysctl.d/90-singbox.conf"
echo "  ✓ 不创建任何新的 sysctl.d 文件"
echo
echo "唯一允许修改："
echo "  $TARGET"

# ============================================================
# 最终确认
# ============================================================

echo
echo "============================================================"
echo "                         安全确认"
echo "============================================================"

echo
echo "确认后，本脚本只会："
echo
echo "  1. 修改 $TARGET 中已有参数"
echo "  2. 解除该文件中对应参数的注释"
echo "  3. 对完全不存在的参数追加到该文件"
echo
echo "不会立即应用 sysctl。"
echo "因此不会主动改变当前 SSH / 网络连接。"
echo
echo "配置将在系统后续 systemd-sysctl 应用配置时生效。"
echo
printf "确认执行以上修改？[y/N] "

read -r CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

    echo
    echo -e "${YELLOW}已取消，没有修改任何文件。${NC}"
    exit 0

fi

# ============================================================
# 写入阶段
# ============================================================

echo
echo "============================================================"
echo "                       开始精准修改"
echo "============================================================"

for ((i=0; i<${#CHANGE_KEYS[@]}; i++)); do

    key="${CHANGE_KEYS[$i]}"
    value="${CHANGE_VALUES[$i]}"
    mode="${CHANGE_MODES[$i]}"

    echo
    echo "→ $key = $value"

    # --------------------------------------------------------
    # 1. 已有有效参数
    # --------------------------------------------------------

    if [ "$mode" = "replace" ]; then

        sed -i -E \
            "s|^[[:space:]]*${key//./\\.}[[:space:]]*=.*$|${key} = ${value}|" \
            "$TARGET"

        echo -e "  ${GREEN}✓ 已精准修改${NC}"

        continue

    fi

    # --------------------------------------------------------
    # 2. 检查注释参数
    # --------------------------------------------------------

    if grep -Eq \
        "^[[:space:]]*[#;][[:space:]]*${key//./\\.}[[:space:]]*=" \
        "$TARGET"
    then

        sed -i -E \
            "s|^[[:space:]]*[#;][[:space:]]*${key//./\\.}[[:space:]]*=.*$|${key} = ${value}|" \
            "$TARGET"

        echo -e "  ${GREEN}✓ 已解除注释并修改${NC}"

        continue

    fi

    # --------------------------------------------------------
    # 3. 完全不存在 → 追加
    # --------------------------------------------------------

    printf '\n%s = %s\n' "$key" "$value" >> "$TARGET"

    echo -e "  ${GREEN}✓ 已追加${NC}"

done

# ============================================================
# 写入后验证
# ============================================================

echo
echo "============================================================"
echo "                       写入结果验证"
echo "============================================================"

FAILED=0

for ((i=0; i<${#CHANGE_KEYS[@]}; i++)); do

    key="${CHANGE_KEYS[$i]}"
    expected="${CHANGE_VALUES[$i]}"

    actual="$(
        sed -n -E \
            "s|^[[:space:]]*${key//./\\.}[[:space:]]*=[[:space:]]*(.*)$|\1|p" \
            "$TARGET" |
        tail -n1
    )"

    if [ "$actual" = "$expected" ]; then

        echo -e "${GREEN}✓ $key = $actual${NC}"

    else

        echo -e "${RED}✗ $key${NC}"
        echo "    期望：$expected"
        echo "    实际：$actual"

        FAILED=$((FAILED + 1))

    fi

done

echo
echo "============================================================"

if [ "$FAILED" -eq 0 ]; then

    echo -e "${GREEN}✓ 所有持久化修改验证通过。${NC}"

else

    echo -e "${RED}✗ 有 $FAILED 项验证失败，请检查 $TARGET${NC}"
    exit 1

fi

echo
echo "配置文件："
echo "  $TARGET"
echo
echo "本次没有执行："
echo "  sysctl -w"
echo "  modprobe"
echo "  systemd-sysctl reload"
echo "  网络重启"
echo "  SSH 重启"
echo "  VPS 重启"
echo
echo -e "${GREEN}✓ 当前 SSH / 网络连接不会被脚本主动重置。${NC}"
echo
echo "============================================================"
echo "                         完成"
echo "============================================================"
