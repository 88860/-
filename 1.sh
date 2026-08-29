#!/bin/bash
set -u
export LC_ALL=C

TARGET="/usr/lib/sysctl.d/50-default.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

die() {
    echo -e "${RED}错误：$1${NC}"
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"

command -v sysctl >/dev/null 2>&1 || die "sysctl 不存在"
command -v sed >/dev/null 2>&1 || die "sed 不存在"
command -v grep >/dev/null 2>&1 || die "grep 不存在"
command -v sort >/dev/null 2>&1 || die "sort 不存在"

[ -f "$TARGET" ] || die "$TARGET 不存在，拒绝创建新配置文件"

echo "============================================================"
echo " Debian 13 双栈 TCP/UDP 网络调优"
echo " 只读审计 → 自动判断 → 人工确认 → 精准持久化"
echo "============================================================"
echo
echo "策略："
echo "  配置文件：只修改 $TARGET"
echo "  不创建新的 sysctl.d 配置文件"
echo "  不立即应用 sysctl"
echo "  不重启网络 / SSH / VPS"
echo "  Swap / vm.*：不修改"
echo

# ============================================================
# 基础函数
# ============================================================

get_sysctl() {
    sysctl -n "$1" 2>/dev/null || echo "unknown"
}

normalize_value() {
    printf '%s\n' "$1" |
        sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

file_has_active_key() {
    local key="$1"
    local re="${key//./\\.}"

    grep -Eq \
        "^[[:space:]]*${re}[[:space:]]*=" \
        "$TARGET"
}

file_has_commented_key() {
    local key="$1"
    local re="${key//./\\.}"

    grep -Eq \
        "^[[:space:]]*[#;][[:space:]]*${re}[[:space:]]*=" \
        "$TARGET"
}

# ============================================================
# 获取 sysctl.d 配置文件
# ============================================================

get_sysctl_files() {

    local d

    for d in \
        /usr/lib/sysctl.d \
        /usr/local/lib/sysctl.d \
        /run/sysctl.d \
        /etc/sysctl.d
    do
        [ -d "$d" ] || continue

        find "$d" \
            -maxdepth 1 \
            -type f \
            -name '*.conf' \
            -print 2>/dev/null
    done |
        sort -V -u
}

# ============================================================
# 查找某参数在配置体系中的最后一个有效值
# ============================================================

last_key_in_file() {

    local key="$1"
    local file="$2"

    local line
    local lhs
    local rhs
    local result=""

    while IFS= read -r line
    do

        case "$line" in
            '')
                continue
                ;;
            [[:space:]]*'#'*)
                continue
                ;;
            [[:space:]]*';'*)
                continue
                ;;
        esac

        case "$line" in
            *=*)
                ;;
            *)
                continue
                ;;
        esac

        lhs="${line%%=*}"
        rhs="${line#*=}"

        lhs="$(
            printf '%s' "$lhs" |
                sed 's/[[:space:]]//g'
        )"

        [ "$lhs" = "$key" ] ||
        [ "$lhs" = "/$key" ] ||
            continue

        rhs="$(
            printf '%s' "$rhs" |
                sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
        )"

        result="$rhs"

    done < "$file"

    [ -n "$result" ] &&
        printf '%s' "$result"
}

# ============================================================
# 查找实际持久化来源
# ============================================================

find_effective_source() {

    local key="$1"

    local f
    local val

    local found_file=""
    local found_val=""

    while IFS= read -r f
    do

        [ -r "$f" ] || continue

        val="$(last_key_in_file "$key" "$f")"

        if [ -n "$val" ]; then
            found_file="$f"
            found_val="$val"
        fi

    done < <(get_sysctl_files)

    if [ -n "$found_file" ]; then

        printf '%s|%s' \
            "$found_file" \
            "$found_val"

    else

        printf 'NOT_FOUND|'

    fi
}

# ============================================================
# 精准修改 TARGET
#
# 1. active 参数存在 → 修改
# 2. 注释参数存在 → 解除注释并修改
# 3. 完全不存在 → 追加
#
# 不使用复杂 awk
# ============================================================

set_target_value() {

    local key="$1"
    local value="$2"

    local tmp
    local tmp2
    local esc_key

    local found=0

    tmp="$(mktemp /tmp/sysctl.XXXXXX)" || return 1

    esc_key="${key//./\\.}"

    # --------------------------------------------------------
    # active 参数
    # --------------------------------------------------------

    if grep -Eq \
        "^[[:space:]]*${esc_key}[[:space:]]*=" \
        "$TARGET"
    then

        sed -E \
            "s|^[[:space:]]*${esc_key}[[:space:]]*=.*$|${key} = ${value}|" \
            "$TARGET" > "$tmp" ||
        {
            rm -f "$tmp"
            return 1
        }

        found=1

    else

        cp -- "$TARGET" "$tmp" ||
        {
            rm -f "$tmp"
            return 1
        }

    fi

    # --------------------------------------------------------
    # commented 参数
    # --------------------------------------------------------

    if grep -Eq \
        "^[[:space:]]*[#;][[:space:]]*${esc_key}[[:space:]]*=" \
        "$tmp"
    then

        tmp2="${tmp}.2"

        sed -E \
            "s|^[[:space:]]*[#;][[:space:]]*${esc_key}[[:space:]]*=.*$|${key} = ${value}|" \
            "$tmp" > "$tmp2" ||
        {
            rm -f "$tmp" "$tmp2"
            return 1
        }

        mv -- "$tmp2" "$tmp" ||
        {
            rm -f "$tmp" "$tmp2"
            return 1
        }

        found=1

    fi

    # --------------------------------------------------------
    # 参数完全不存在 → 追加
    # --------------------------------------------------------

    if [ "$found" -eq 0 ]; then

        printf '\n%s = %s\n' \
            "$key" \
            "$value" >> "$tmp" ||
        {
            rm -f "$tmp"
            return 1
        }

    fi

    # --------------------------------------------------------
    # 写回唯一允许修改的文件
    # --------------------------------------------------------

    cat "$tmp" > "$TARGET" ||
    {
        rm -f "$tmp"
        return 1
    }

    rm -f "$tmp"

    return 0
}

# ============================================================
# [1/10] 系统检测
# ============================================================

echo "[1/10] 系统检测"

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    PRETTY_NAME="unknown"
fi

CPU="$(nproc 2>/dev/null || echo 1)"

RAM_KB="$(
    sed -n \
        's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' \
        /proc/meminfo |
        head -1
)"

RAM_KB="${RAM_KB:-0}"

RAM_MB=$((RAM_KB / 1024))

SWAP_MB="$(
    free -m 2>/dev/null |
        sed -n \
        's/^Swap:[[:space:]]*[^ ]*[[:space:]]*\([^ ]*\).*/\1/p' |
        head -1
)"

SWAP_MB="${SWAP_MB:-0}"

KERNEL="$(uname -r)"

echo "  OS       : ${PRETTY_NAME:-unknown}"
echo "  Kernel   : $KERNEL"
echo "  CPU      : $CPU cores"
echo "  RAM      : ${RAM_MB} MB"
echo "  Swap     : ${SWAP_MB} MB（不修改）"

echo

# ============================================================
# [2/10] IPv4 / IPv6 / TCP / UDP
# ============================================================

echo "[2/10] IPv4 / IPv6 / TCP / UDP 检测"

IPV4_COUNT="$(
    ip -4 addr 2>/dev/null |
        grep -c 'inet ' ||
        true
)"

IPV6_COUNT="$(
    ip -6 addr 2>/dev/null |
        grep -c 'inet6 ' ||
        true
)"

IPV6_DISABLED="$(
    get_sysctl net.ipv6.conf.all.disable_ipv6
)"

TCP_LISTEN="$(
    ss -Hln 2>/dev/null |
        grep -c '^tcp' ||
        true
)"

TCP_EST="$(
    ss -Hnt 2>/dev/null |
        grep -c 'ESTAB' ||
        true
)"

UDP_COUNT="$(
    ss -Hun 2>/dev/null |
        wc -l |
        tr -d ' '
)"

DEFAULT_IF="$(
    ip route show default 2>/dev/null |
        sed -n 's/.* dev \([^ ]*\).*/\1/p' |
        head -1
)"

echo "  IPv4 地址        : $IPV4_COUNT"
echo "  IPv6 地址        : $IPV6_COUNT"
echo "  IPv6 disabled    : $IPV6_DISABLED"
echo "  TCP LISTEN       : $TCP_LISTEN"
echo "  TCP established  : $TCP_EST"
echo "  UDP sockets      : $UDP_COUNT"
echo "  默认网卡         : ${DEFAULT_IF:-unknown}"

echo

# ============================================================
# [3/10] SSH 会话
# ============================================================

echo "[3/10] SSH 会话检测"

if [ -n "${SSH_CONNECTION:-}" ]; then

    set -- $SSH_CONNECTION

    echo "  ✓ 检测到当前 SSH 远程会话"
    echo "  远端 IP     : $1"
    echo "  远端端口    : $2"
    echo "  本地地址    : $3"
    echo "  本地端口    : $4"

else

    echo "  未检测到 SSH_CONNECTION"

fi

echo

# ============================================================
# [4/10] CPU / RAM
# ============================================================

echo "[4/10] CPU / RAM 调优等级"

if [ "$CPU" -le 1 ]; then
    CPU_LEVEL="small"
elif [ "$CPU" -le 2 ]; then
    CPU_LEVEL="medium"
else
    CPU_LEVEL="large"
fi

if [ "$RAM_MB" -le 1536 ]; then
    RAM_LEVEL="small"
elif [ "$RAM_MB" -le 4096 ]; then
    RAM_LEVEL="medium"
else
    RAM_LEVEL="large"
fi

echo "  CPU 等级 : $CPU_LEVEL"
echo "  RAM 等级 : $RAM_LEVEL"

echo
echo "  公网带宽：按 ≥1 Gbps 处理"

echo

# ============================================================
# [5/10] BBR / FQ / TFO
# ============================================================

echo "[5/10] BBR / FQ / TCP Fast Open"

CC="$(
    get_sysctl net.ipv4.tcp_congestion_control
)"

AVAILABLE_CC="$(
    get_sysctl net.ipv4.tcp_available_congestion_control
)"

QDISC="$(
    get_sysctl net.core.default_qdisc
)"

TFO="$(
    get_sysctl net.ipv4.tcp_fastopen
)"

BBR_SUPPORTED=0
FQ_SUPPORTED=0

echo " $AVAILABLE_CC " |
    grep -q ' bbr ' &&
    BBR_SUPPORTED=1

[ -e /proc/sys/net/core/default_qdisc ] &&
    FQ_SUPPORTED=1

echo "  当前拥塞控制      : $CC"
echo "  可用拥塞控制      : $AVAILABLE_CC"
echo "  当前默认 qdisc    : $QDISC"
echo "  当前 TCP Fast Open : $TFO"

if [ "$BBR_SUPPORTED" -eq 1 ]; then
    echo "  BBR 内核支持      : yes"
else
    echo "  BBR 内核支持      : no"
fi

if [ "$FQ_SUPPORTED" -eq 1 ]; then
    echo "  FQ 配置接口       : yes"
else
    echo "  FQ 配置接口       : no"
fi

echo

# ============================================================
# [6/10] 网络实际压力
# ============================================================

echo "[6/10] 网络实际压力检测"

softnet_before="$(
    awk '
        {
            s += strtonum("0x" $2)
        }
        END {
            print s + 0
        }
    ' /proc/net/softnet_stat 2>/dev/null
)"

softnet_before="${softnet_before:-0}"

rx_before="$(
    cat /sys/class/net/*/statistics/rx_dropped 2>/dev/null |
        awk '{s += $1} END {print s + 0}'
)"

rx_before="${rx_before:-0}"

tx_before="$(
    cat /sys/class/net/*/statistics/tx_dropped 2>/dev/null |
        awk '{s += $1} END {print s + 0}'
)"

tx_before="${tx_before:-0}"

sleep 3

softnet_after="$(
    awk '
        {
            s += strtonum("0x" $2)
        }
        END {
            print s + 0
        }
    ' /proc/net/softnet_stat 2>/dev/null
)"

softnet_after="${softnet_after:-0}"

rx_after="$(
    cat /sys/class/net/*/statistics/rx_dropped 2>/dev/null |
        awk '{s += $1} END {print s + 0}'
)"

rx_after="${rx_after:-0}"

tx_after="$(
    cat /sys/class/net/*/statistics/tx_dropped 2>/dev/null |
        awk '{s += $1} END {print s + 0}'
)"

tx_after="${tx_after:-0}"

softnet_delta=$((softnet_after - softnet_before))
rx_delta=$((rx_after - rx_before))
tx_delta=$((tx_after - tx_before))

[ "$softnet_delta" -lt 0 ] && softnet_delta=0
[ "$rx_delta" -lt 0 ] && rx_delta=0
[ "$tx_delta" -lt 0 ] && tx_delta=0

echo "  softnet drops / 3s : $softnet_delta"
echo "  RX drops / 3s      : $rx_delta"
echo "  TX drops / 3s      : $tx_delta"

echo

# ============================================================
# [7/10] 当前运行参数
# ============================================================

echo "[7/10] 当前运行参数"

declare -A CURRENT

PARAMS=(

    net.core.default_qdisc

    net.ipv4.tcp_congestion_control
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_syncookies
    net.ipv4.tcp_max_syn_backlog

    net.core.somaxconn
    net.core.netdev_max_backlog

    net.ipv4.tcp_window_scaling
    net.ipv4.tcp_sack
    net.ipv4.tcp_timestamps

    net.ipv4.tcp_ecn
    net.ipv4.tcp_mtu_probing

    net.ipv4.tcp_fin_timeout

    net.ipv4.tcp_keepalive_time
    net.ipv4.tcp_keepalive_intvl
    net.ipv4.tcp_keepalive_probes

    net.ipv4.tcp_max_tw_buckets

    net.ipv4.ip_local_port_range
)

for p in "${PARAMS[@]}"
do
    CURRENT["$p"]="$(get_sysctl "$p")"
done

echo "  default_qdisc       : ${CURRENT[net.core.default_qdisc]}"
echo "  congestion_control  : ${CURRENT[net.ipv4.tcp_congestion_control]}"
echo "  tcp_fastopen        : ${CURRENT[net.ipv4.tcp_fastopen]}"
echo "  tcp_syncookies      : ${CURRENT[net.ipv4.tcp_syncookies]}"
echo "  tcp_max_syn_backlog : ${CURRENT[net.ipv4.tcp_max_syn_backlog]}"
echo "  somaxconn            : ${CURRENT[net.core.somaxconn]}"
echo "  netdev_max_backlog   : ${CURRENT[net.core.netdev_max_backlog]}"
echo "  tcp_window_scaling   : ${CURRENT[net.ipv4.tcp_window_scaling]}"
echo "  tcp_sack             : ${CURRENT[net.ipv4.tcp_sack]}"
echo "  tcp_timestamps       : ${CURRENT[net.ipv4.tcp_timestamps]}"
echo "  tcp_ecn              : ${CURRENT[net.ipv4.tcp_ecn]}"
echo "  tcp_mtu_probing      : ${CURRENT[net.ipv4.tcp_mtu_probing]}"
echo "  tcp_fin_timeout      : ${CURRENT[net.ipv4.tcp_fin_timeout]}"
echo "  tcp_keepalive_time   : ${CURRENT[net.ipv4.tcp_keepalive_time]}"
echo "  tcp_keepalive_intvl  : ${CURRENT[net.ipv4.tcp_keepalive_intvl]}"
echo "  tcp_keepalive_probes : ${CURRENT[net.ipv4.tcp_keepalive_probes]}"
echo "  tcp_max_tw_buckets   : ${CURRENT[net.ipv4.tcp_max_tw_buckets]}"
echo "  ip_local_port_range  : ${CURRENT[net.ipv4.ip_local_port_range]}"

echo

# ============================================================
# [8/10] systemd-sysctl 文件
# ============================================================

echo "[8/10] 检测 systemd-sysctl 实际配置文件"

echo
echo "  systemd-sysctl 配置文件："

while IFS= read -r f
do
    echo "    $f"
done < <(get_sysctl_files)

echo

# ============================================================
# bpftune 审计
# ============================================================

echo "------------------------------------------------------------"
echo " bpftune / BPF 自动调优能力审计"
echo "------------------------------------------------------------"

if command -v bpftune >/dev/null 2>&1; then

    echo "  bpftune          : 已安装"

else

    echo "  bpftune          : 未安装"
    echo "  本脚本不会安装或启动 bpftune"

fi

echo

# ============================================================
# [9/10] 自动生成调优目标
# ============================================================

echo "[9/10] 自动生成调优目标"

declare -a TARGET_KEYS=()
declare -a TARGET_VALUES=()
declare -a TARGET_REASONS=()

add_target() {

    TARGET_KEYS+=("$1")
    TARGET_VALUES+=("$2")
    TARGET_REASONS+=("$3")

}

# ------------------------------------------------------------
# 1. BBR
# ------------------------------------------------------------

if [ "$CC" = "bbr" ]; then

    echo "  ✓ BBR 已经运行，不写入重复配置"

elif [ "$BBR_SUPPORTED" -eq 1 ]; then

    add_target \
        "net.ipv4.tcp_congestion_control" \
        "bbr" \
        "内核支持 BBR，当前运行值不是 BBR"

else

    echo "  - BBR 内核不支持，不修改"

fi

# ------------------------------------------------------------
# 2. FQ
# ------------------------------------------------------------

if [ "$QDISC" = "fq" ]; then

    echo "  ✓ default_qdisc 已经是 fq"

elif [ "$FQ_SUPPORTED" -eq 1 ]; then

    add_target \
        "net.core.default_qdisc" \
        "fq" \
        "BBR 推荐配合 fq；当前不是 fq"

else

    echo "  - 无法确认 FQ 支持，不修改"

fi

# ------------------------------------------------------------
# 3. TCP Fast Open
# ------------------------------------------------------------

case "$TFO" in

    3)

        echo "  ✓ TCP Fast Open 已为 3"

        ;;

    0|1|2)

        add_target \
            "net.ipv4.tcp_fastopen" \
            "3" \
            "启用 TCP client/server Fast Open"

        ;;

    *)

        echo "  - tcp_fastopen 当前值异常：$TFO，不修改"

        ;;

esac

# ------------------------------------------------------------
# 4. SYN backlog
# ------------------------------------------------------------

BACKLOG="${CURRENT[net.ipv4.tcp_max_syn_backlog]}"

if [ "$BACKLOG" = "128" ]; then

    add_target \
        "net.ipv4.tcp_max_syn_backlog" \
        "4096" \
        "当前为 Debian 默认 128；公网高并发服务适当扩大 SYN backlog"

else

    echo "  ✓ tcp_max_syn_backlog 当前为 $BACKLOG，不强制修改"

fi

# ------------------------------------------------------------
# 5. somaxconn
# ------------------------------------------------------------

SOMAX="${CURRENT[net.core.somaxconn]}"

if [ "$SOMAX" -lt 4096 ] 2>/dev/null; then

    add_target \
        "net.core.somaxconn" \
        "4096" \
        "监听队列上限偏低"

else

    echo "  ✓ somaxconn 当前为 $SOMAX"

fi

# ------------------------------------------------------------
# 6. netdev backlog
# ------------------------------------------------------------

if [ "$softnet_delta" -gt 0 ]; then

    CURRENT_BACKLOG="${CURRENT[net.core.netdev_max_backlog]}"

    if [ "$CURRENT_BACKLOG" -lt 4096 ] 2>/dev/null; then

        add_target \
            "net.core.netdev_max_backlog" \
            "4096" \
            "检测到 softnet drops，增加网络接收 backlog"

    else

        echo "  ✓ 检测到 softnet drops，但 netdev_max_backlog 已为 $CURRENT_BACKLOG"

    fi

else

    echo "  ✓ 无 softnet drops，不修改 netdev_max_backlog"

fi

# ------------------------------------------------------------
# 7. MTU Black Hole Probing
# ------------------------------------------------------------

MTU="${CURRENT[net.ipv4.tcp_mtu_probing]}"

if [ "$MTU" = "1" ]; then

    echo "  ✓ tcp_mtu_probing 已为 1"

else

    add_target \
        "net.ipv4.tcp_mtu_probing" \
        "1" \
        "开启 MTU 探测，降低跨境/代理路径 PMTU black-hole 导致连接异常的风险"

fi

# ------------------------------------------------------------
# 8. 临时端口
# ------------------------------------------------------------

PORT_RANGE="${CURRENT[net.ipv4.ip_local_port_range]}"

PORT_HIGH="$(
    printf '%s' "$PORT_RANGE" |
        sed -n \
        's/^[[:space:]]*[0-9][0-9]*[[:space:]]*\([0-9][0-9]*\).*/\1/p'
)"

if [ -n "$PORT_HIGH" ] &&
   [ "$PORT_HIGH" -lt 60999 ] 2>/dev/null
then

    add_target \
        "net.ipv4.ip_local_port_range" \
        "1024 65535" \
        "当前临时端口上限偏低"

else

    echo "  ✓ ip_local_port_range 当前无需调整"

fi

# ------------------------------------------------------------
# 明确不盲目调整
# ------------------------------------------------------------

echo
echo "  ✓ 不盲目修改 TCP keepalive"
echo "  ✓ 不盲目修改 tcp_fin_timeout"
echo "  ✓ 不盲目修改 tcp_max_tw_buckets"
echo "  ✓ 不盲目修改 TCP/UDP buffer"
echo "  ✓ 不盲目修改 tcp_mem"
echo "  ✓ 不自动关闭 ECN"
echo "  ✓ 不修改 TCP timestamps"
echo "  ✓ 不修改 TCP SACK"
echo "  ✓ 不修改 TCP window scaling"

echo

# ============================================================
# [10/10] 参数最终审计
# ============================================================

echo "[10/10] 参数最终审计"

echo
echo "============================================================"
echo "                 参数实际持久化配置来源"
echo "============================================================"
echo

SOURCE_KEYS=(

    net.ipv4.tcp_congestion_control
    net.core.default_qdisc
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_syncookies

    net.core.somaxconn
    net.ipv4.tcp_max_syn_backlog
    net.core.netdev_max_backlog

    net.ipv4.tcp_mtu_probing

    net.ipv4.ip_local_port_range
)

for key in "${SOURCE_KEYS[@]}"
do

    echo "[$key]"

    result="$(
        find_effective_source "$key"
    )"

    file="${result%%|*}"
    val="${result#*|}"

    if [ "$file" = "NOT_FOUND" ]; then

        echo "  实际持久化配置 : 未找到"

    else

        echo "  实际配置文件    : $file"
        echo "  文件值          : $val"

    fi

    echo "  当前运行值      : ${CURRENT[$key]}"

    echo

done

# ============================================================
# 调优审计结果
# ============================================================

echo "============================================================"
echo "                      调优审计结果"
echo "============================================================"
echo

CHANGES=0

for ((i=0; i<${#TARGET_KEYS[@]}; i++))
do

    key="${TARGET_KEYS[$i]}"
    val="${TARGET_VALUES[$i]}"
    reason="${TARGET_REASONS[$i]}"

    current="${CURRENT[$key]}"

    if [ "$(normalize_value "$current")" =
         "$(normalize_value "$val")" ]
    then

        continue

    fi

    echo "⚠ $key"
    echo "    当前运行值 : $current"
    echo "    建议值     : $val"
    echo "    原因       : $reason"

    if file_has_active_key "$key"; then

        echo "    50-default : 已存在参数 → 精准修改"

    elif file_has_commented_key "$key"; then

        echo "    50-default : 存在注释参数 → 解除注释并修改"

    else

        echo "    50-default : 参数不存在 → 追加到现有文件"

    fi

    echo

    CHANGES=$((CHANGES + 1))

done

# ============================================================
# 没有修改
# ============================================================

if [ "$CHANGES" -eq 0 ]; then

    echo "✓ 未发现需要修改的项目。"
    exit 0

fi

# ============================================================
# 明确不会修改
# ============================================================

echo "============================================================"
echo "                   明确不会修改"
echo "============================================================"

echo "  ✓ Swap"
echo "  ✓ vm.*"
echo "  ✓ IPv4 forwarding"
echo "  ✓ IPv6 forwarding"
echo "  ✓ IPv6 disable"

echo "  ✓ SSH 服务"
echo "  ✓ 网络服务"
echo "  ✓ 当前连接"

echo "  ✓ 当前运行中的 sysctl"
echo "  ✓ 当前运行中的 qdisc"
echo "  ✓ 当前运行中的 congestion control"

echo "  ✓ modprobe"
echo "  ✓ sysctl -w"
echo "  ✓ systemd-sysctl reload"

echo "  ✓ 网络重启"
echo "  ✓ SSH 重启"
echo "  ✓ VPS 重启"

echo
echo "  ✓ 不创建新的 sysctl.d 文件"
echo "  ✓ 唯一允许修改：$TARGET"

echo

# ============================================================
# 安全确认
# ============================================================

echo "============================================================"
echo "                         安全确认"
echo "============================================================"

echo
echo "本次共发现 $CHANGES 个待修改项目。"

echo
echo "确认后只会："
echo "  1. 修改 $TARGET"
echo "  2. 已存在参数 → 修改对应行"
echo "  3. 注释参数 → 解除注释并修改"
echo "  4. 完全不存在参数 → 追加到这个已有文件"

echo
echo "不会立即应用新的 sysctl。"
echo "不会执行 sysctl -w。"
echo "不会 reload systemd-sysctl。"
echo "不会重启 SSH / 网络 / VPS。"

echo

read -r -p \
    "确认执行以上修改？[y/N] " \
    ANSWER

case "$ANSWER" in

    y|Y|yes|YES)
        ;;

    *)

        echo
        echo "已取消，没有修改任何文件。"
        exit 0

        ;;

esac

# ============================================================
# 开始修改
# ============================================================

echo
echo "============================================================"
echo "                       开始精准修改"
echo "============================================================"
echo

for ((i=0; i<${#TARGET_KEYS[@]}; i++))
do

    key="${TARGET_KEYS[$i]}"
    val="${TARGET_VALUES[$i]}"
    current="${CURRENT[$key]}"

    if [ "$(normalize_value "$current")" =
         "$(normalize_value "$val")" ]
    then

        continue

    fi

    echo "  → $key = $val"

    if set_target_value "$key" "$val"; then

        echo "      ✓ 修改成功"

    else

        echo -e "      ${RED}✗ 修改失败${NC}"

        die "修改 $TARGET 失败"

    fi

done

# ============================================================
# 完成
# ============================================================

echo
echo "============================================================"
echo "                       修改完成"
echo "============================================================"

echo
echo "配置文件：$TARGET"

echo
echo "注意："
echo "  本脚本没有立即应用新的 sysctl。"
echo "  没有执行 sysctl -w。"
echo "  没有 reload systemd-sysctl。"
echo "  没有重启 SSH / 网络 / VPS。"

echo
echo "当前文件中的目标参数："

grep -nE \
    '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_fastopen|net\.ipv4\.tcp_max_syn_backlog|net\.ipv4\.tcp_mtu_probing|net\.ipv4\.ip_local_port_range)[[:space:]]*=' \
    "$TARGET" ||
    true

echo
echo "完成。"
