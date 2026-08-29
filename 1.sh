#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C

TARGET="/usr/lib/sysctl.d/50-default.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() {
    echo -e "${RED}错误：$1${NC}"
    exit 1
}

command -v sysctl >/dev/null 2>&1 || die "sysctl 不存在"
command -v awk >/dev/null 2>&1 || die "awk 不存在"
command -v sed >/dev/null 2>&1 || die "sed 不存在"
command -v grep >/dev/null 2>&1 || die "grep 不存在"
command -v ip >/dev/null 2>&1 || die "ip 不存在"
command -v ss >/dev/null 2>&1 || die "ss 不存在"

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
[ -f "$TARGET" ] || die "$TARGET 不存在"

echo "============================================================"
echo " Debian 13 双栈 TCP/UDP 网络调优"
echo " 只读审计 → 自动判断 → 人工确认 → 精准持久化"
echo "============================================================"
echo
echo "策略："
echo "  只修改：$TARGET"
echo "  不创建新的 sysctl.d 文件"
echo "  不立即应用 sysctl"
echo "  不重启网络 / SSH / VPS"
echo "  Swap / vm.* 不修改"
echo

# ------------------------------------------------------------
# 基础函数
# ------------------------------------------------------------

get_sysctl() {
    sysctl -n "$1" 2>/dev/null || echo "unknown"
}

norm() {
    printf '%s\n' "$1" | awk '{$1=$1; print}'
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# 当前文件是否存在 active 参数
file_has_active_key() {
    local key="$1"

    awk -v k="$key" '
    {
        line=$0
        sub(/^[[:space:]]+/, "", line)

        if (line == "" || line ~ /^#/ || line ~ /^;/)
            next

        pos=index(line, "=")
        if (!pos)
            next

        lhs=substr(line, 1, pos-1)
        gsub(/[[:space:]]/, "", lhs)

        if (lhs == k || lhs == "/" k)
            found=1
    }
    END {
        exit(found ? 0 : 1)
    }
    ' "$TARGET"
}

# 当前文件是否存在注释参数
file_has_commented_key() {
    local key="$1"

    awk -v k="$key" '
    {
        line=$0
        sub(/^[[:space:]]+/, "", line)

        if (line !~ /^#/ && line !~ /^;/)
            next

        sub(/^[#;][[:space:]]*/, "", line)

        pos=index(line, "=")
        if (!pos)
            next

        lhs=substr(line, 1, pos-1)
        gsub(/[[:space:]]/, "", lhs)

        if (lhs == k || lhs == "/" k)
            found=1
    }
    END {
        exit(found ? 0 : 1)
    }
    ' "$TARGET"
}

# 所有 systemd-sysctl 配置文件
get_sysctl_files() {
    local d f

    for d in \
        /usr/lib/sysctl.d \
        /usr/local/lib/sysctl.d \
        /run/sysctl.d \
        /etc/sysctl.d
    do
        [ -d "$d" ] || continue

        for f in "$d"/*.conf; do
            [ -f "$f" ] || continue
            printf '%s\n' "$f"
        done
    done
}

# 查找参数来源。
# 这里按实际目录优先级处理：
# /usr/lib < /usr/local/lib < /run < /etc
find_source() {
    local key="$1"
    local best_file=""
    local best_line=""
    local best_value=""

    local f line_no line lhs rhs
    local files=()

    mapfile -t files < <(
        get_sysctl_files |
        awk '
        {
            file=$0

            if (file ~ "^/usr/lib/sysctl.d/")
                pri=1
            else if (file ~ "^/usr/local/lib/sysctl.d/")
                pri=2
            else if (file ~ "^/run/sysctl.d/")
                pri=3
            else if (file ~ "^/etc/sysctl.d/")
                pri=4
            else
                pri=0

            print pri "\t" file
        }
        ' |
        sort -k1,1n -k2,2 |
        cut -f2-
    )

    for f in "${files[@]}"; do
        while IFS=$'\t' read -r line_no line; do
            [ -n "$line_no" ] || continue

            lhs="${line%%=*}"
            rhs="${line#*=}"

            lhs="$(printf '%s' "$lhs" | sed 's/[[:space:]]//g')"
            rhs="$(printf '%s' "$rhs" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

            if [ "$lhs" = "$key" ] || [ "$lhs" = "/$key" ]; then
                best_file="$f"
                best_line="$line_no"
                best_value="$rhs"
            fi
        done < <(
            awk '
            {
                line=$0
                sub(/^[[:space:]]+/, "", line)

                if (line == "" || line ~ /^#/ || line ~ /^;/)
                    next

                if (index(line, "="))
                    print NR "\t" line
            }
            ' "$f"
        )
    done

    if [ -n "$best_file" ]; then
        printf '%s|%s|%s\n' "$best_file" "$best_line" "$best_value"
    else
        printf 'NOT_FOUND||\n'
    fi
}

# 修改目标文件：
# active -> 修改
# comment -> 解除注释
# 不存在 -> 追加
set_target_value() {
    local key="$1"
    local value="$2"
    local tmp

    tmp="$(mktemp)"

    if ! awk -v k="$key" -v v="$value" '
    BEGIN {
        changed=0
    }

    {
        original=$0
        line=$0

        sub(/^[[:space:]]+/, "", line)

        # active
        if (line != "" && line !~ /^#/ && line !~ /^;/) {
            pos=index(line, "=")

            if (pos) {
                lhs=substr(line, 1, pos-1)
                gsub(/[[:space:]]/, "", lhs)

                if (lhs == k || lhs == "/" k) {
                    print k " = " v
                    changed=1
                    next
                }
            }
        }

        # commented
        if (line ~ /^#/ || line ~ /^;/) {
            commented=line
            sub(/^[#;][[:space:]]*/, "", commented)

            pos=index(commented, "=")

            if (pos) {
                lhs=substr(commented, 1, pos-1)
                gsub(/[[:space:]]/, "", lhs)

                if (lhs == k || lhs == "/" k) {
                    print k " = " v
                    changed=1
                    next
                }
            }
        }

        print original
    }

    END {
        if (!changed)
            print k " = " v
    }
    ' "$TARGET" > "$tmp"; then
        rm -f "$tmp"
        die "生成修改文件失败"
    fi

    if ! cat "$tmp" > "$TARGET"; then
        rm -f "$tmp"
        die "修改 $TARGET 失败"
    fi

    rm -f "$tmp"
}

# ------------------------------------------------------------
# [1/10] 系统
# ------------------------------------------------------------

echo "[1/10] 系统检测"

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    PRETTY_NAME="unknown"
fi

CPU="$(nproc 2>/dev/null || echo 1)"
RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
RAM_MB=$((RAM_KB / 1024))
SWAP_MB="$(free -m | awk '/^Swap:/ {print $3}')"
KERNEL="$(uname -r)"

echo "  OS       : ${PRETTY_NAME:-unknown}"
echo "  Kernel   : $KERNEL"
echo "  CPU      : $CPU cores"
echo "  RAM      : $RAM_MB MB"
echo "  Swap     : $SWAP_MB MB（不修改）"
echo

# ------------------------------------------------------------
# [2/10] 网络
# ------------------------------------------------------------

echo "[2/10] IPv4 / IPv6 / TCP / UDP 检测"

IPV4_COUNT="$(ip -4 addr | awk '/inet / {c++} END {print c+0}')"
IPV6_COUNT="$(ip -6 addr | awk '/inet6 / {c++} END {print c+0}')"
IPV6_DISABLED="$(get_sysctl net.ipv6.conf.all.disable_ipv6)"

TCP_LISTEN="$(ss -Hln | awk '$1 ~ /^tcp/ {c++} END {print c+0}')"
TCP_EST="$(ss -Hnt | awk '$1 == "ESTAB" {c++} END {print c+0}')"
UDP_COUNT="$(ss -Hun | awk 'END {print NR+0}')"

DEFAULT_IF="$(ip route show default | awk 'NR==1 {print $5}')"

echo "  IPv4 地址        : $IPV4_COUNT"
echo "  IPv6 地址        : $IPV6_COUNT"
echo "  IPv6 disabled    : $IPV6_DISABLED"
echo "  TCP LISTEN       : $TCP_LISTEN"
echo "  TCP established  : $TCP_EST"
echo "  UDP sockets      : $UDP_COUNT"
echo "  默认网卡         : ${DEFAULT_IF:-unknown}"
echo

# ------------------------------------------------------------
# [3/10] SSH
# ------------------------------------------------------------

echo "[3/10] SSH 会话检测"

if [ -n "${SSH_CONNECTION:-}" ]; then
    read -r SSH_REMOTE_IP SSH_REMOTE_PORT SSH_LOCAL_IP SSH_LOCAL_PORT <<< "$SSH_CONNECTION"

    echo "  ✓ 当前 SSH 远程会话"
    echo "  远端 IP     : $SSH_REMOTE_IP"
    echo "  远端端口    : $SSH_REMOTE_PORT"
    echo "  本地地址    : $SSH_LOCAL_IP"
    echo "  本地端口    : $SSH_LOCAL_PORT"
else
    echo "  未检测到 SSH_CONNECTION"
fi

echo

# ------------------------------------------------------------
# [4/10] CPU / RAM
# ------------------------------------------------------------

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
echo "  公网带宽：按 ≥1 Gbps 处理"
echo

# ------------------------------------------------------------
# [5/10] BBR / FQ / TFO
# ------------------------------------------------------------

echo "[5/10] BBR / FQ / TCP Fast Open"

CC="$(get_sysctl net.ipv4.tcp_congestion_control)"
AVAILABLE_CC="$(get_sysctl net.ipv4.tcp_available_congestion_control)"
QDISC="$(get_sysctl net.core.default_qdisc)"
TFO="$(get_sysctl net.ipv4.tcp_fastopen)"

if printf '%s\n' "$AVAILABLE_CC" | tr ' ' '\n' | grep -qx bbr; then
    BBR_SUPPORTED=1
else
    BBR_SUPPORTED=0
fi

if [ -e /proc/sys/net/core/default_qdisc ]; then
    FQ_SUPPORTED=1
else
    FQ_SUPPORTED=0
fi

echo "  当前拥塞控制      : $CC"
echo "  可用拥塞控制      : $AVAILABLE_CC"
echo "  当前默认 qdisc    : $QDISC"
echo "  当前 TCP Fast Open : $TFO"

[ "$BBR_SUPPORTED" -eq 1 ] &&
    echo "  BBR 内核支持      : yes" ||
    echo "  BBR 内核支持      : no"

[ "$FQ_SUPPORTED" -eq 1 ] &&
    echo "  FQ 配置接口       : yes" ||
    echo "  FQ 配置接口       : no"

echo

# ------------------------------------------------------------
# [6/10] 网络压力
# ------------------------------------------------------------

echo "[6/10] 网络实际压力检测"

softnet_before="$(awk '{sum+=$2} END {print sum+0}' /proc/net/softnet_stat)"
rx_before="$(cat /sys/class/net/*/statistics/rx_dropped 2>/dev/null | awk '{sum+=$1} END {print sum+0}')"
tx_before="$(cat /sys/class/net/*/statistics/tx_dropped 2>/dev/null | awk '{sum+=$1} END {print sum+0}')"

sleep 3

softnet_after="$(awk '{sum+=$2} END {print sum+0}' /proc/net/softnet_stat)"
rx_after="$(cat /sys/class/net/*/statistics/rx_dropped 2>/dev/null | awk '{sum+=$1} END {print sum+0}')"
tx_after="$(cat /sys/class/net/*/statistics/tx_dropped 2>/dev/null | awk '{sum+=$1} END {print sum+0}')"

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

# ------------------------------------------------------------
# [7/10] 当前参数
# ------------------------------------------------------------

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

for p in "${PARAMS[@]}"; do
    CURRENT["$p"]="$(get_sysctl "$p")"
done

printf '%-24s : %s\n' "default_qdisc" "${CURRENT[net.core.default_qdisc]}"
printf '%-24s : %s\n' "congestion_control" "${CURRENT[net.ipv4.tcp_congestion_control]}"
printf '%-24s : %s\n' "tcp_fastopen" "${CURRENT[net.ipv4.tcp_fastopen]}"
printf '%-24s : %s\n' "tcp_syncookies" "${CURRENT[net.ipv4.tcp_syncookies]}"
printf '%-24s : %s\n' "tcp_max_syn_backlog" "${CURRENT[net.ipv4.tcp_max_syn_backlog]}"
printf '%-24s : %s\n' "somaxconn" "${CURRENT[net.core.somaxconn]}"
printf '%-24s : %s\n' "netdev_max_backlog" "${CURRENT[net.core.netdev_max_backlog]}"
printf '%-24s : %s\n' "tcp_window_scaling" "${CURRENT[net.ipv4.tcp_window_scaling]}"
printf '%-24s : %s\n' "tcp_sack" "${CURRENT[net.ipv4.tcp_sack]}"
printf '%-24s : %s\n' "tcp_timestamps" "${CURRENT[net.ipv4.tcp_timestamps]}"
printf '%-24s : %s\n' "tcp_ecn" "${CURRENT[net.ipv4.tcp_ecn]}"
printf '%-24s : %s\n' "tcp_mtu_probing" "${CURRENT[net.ipv4.tcp_mtu_probing]}"
printf '%-24s : %s\n' "tcp_fin_timeout" "${CURRENT[net.ipv4.tcp_fin_timeout]}"
printf '%-24s : %s\n' "tcp_keepalive_time" "${CURRENT[net.ipv4.tcp_keepalive_time]}"
printf '%-24s : %s\n' "tcp_keepalive_intvl" "${CURRENT[net.ipv4.tcp_keepalive_intvl]}"
printf '%-24s : %s\n' "tcp_keepalive_probes" "${CURRENT[net.ipv4.tcp_keepalive_probes]}"
printf '%-24s : %s\n' "tcp_max_tw_buckets" "${CURRENT[net.ipv4.tcp_max_tw_buckets]}"
printf '%-24s : %s\n' "ip_local_port_range" "${CURRENT[net.ipv4.ip_local_port_range]}"

echo

# ------------------------------------------------------------
# [8/10] sysctl 文件
# ------------------------------------------------------------

echo "[8/10] systemd-sysctl 配置文件"

mapfile -t SYSCTL_FILES < <(
    get_sysctl_files |
    sort -V -u
)

for f in "${SYSCTL_FILES[@]}"; do
    echo "  $f"
done

echo

# ------------------------------------------------------------
# bpftune
# ------------------------------------------------------------

echo "------------------------------------------------------------"
echo " bpftune / BPF 自动调优能力"
echo "------------------------------------------------------------"

if command -v bpftune >/dev/null 2>&1; then
    echo "  bpftune : 已安装"
else
    echo "  bpftune : 未安装"
fi

echo "  不安装、不启动 bpftune"
echo

# ------------------------------------------------------------
# [9/10] 调优目标
# ------------------------------------------------------------

echo "[9/10] 自动生成调优目标"

declare -a TARGET_KEYS=()
declare -a TARGET_VALUES=()
declare -a TARGET_REASONS=()

add_target() {
    TARGET_KEYS+=("$1")
    TARGET_VALUES+=("$2")
    TARGET_REASONS+=("$3")
}

# BBR
if [ "${CURRENT[net.ipv4.tcp_congestion_control]}" = "bbr" ]; then
    echo "  ✓ BBR 已运行"
elif [ "$BBR_SUPPORTED" -eq 1 ]; then
    add_target \
        net.ipv4.tcp_congestion_control \
        bbr \
        "内核支持 BBR"
else
    echo "  - BBR 不可用"
fi

# FQ
if [ "${CURRENT[net.core.default_qdisc]}" = "fq" ]; then
    echo "  ✓ default_qdisc 已为 fq"
elif [ "$FQ_SUPPORTED" -eq 1 ]; then
    add_target \
        net.core.default_qdisc \
        fq \
        "BBR 推荐使用 fq"
fi

# TFO
if [ "${CURRENT[net.ipv4.tcp_fastopen]}" = "3" ]; then
    echo "  ✓ TCP Fast Open 已为 3"
else
    case "${CURRENT[net.ipv4.tcp_fastopen]}" in
        0|1|2)
            add_target \
                net.ipv4.tcp_fastopen \
                3 \
                "启用 TCP client/server Fast Open"
            ;;
    esac
fi

# SYN backlog
BACKLOG="${CURRENT[net.ipv4.tcp_max_syn_backlog]}"

if is_number "$BACKLOG" && [ "$BACKLOG" -lt 4096 ]; then
    add_target \
        net.ipv4.tcp_max_syn_backlog \
        4096 \
        "提高公网服务 SYN backlog"
else
    echo "  ✓ tcp_max_syn_backlog 无需调整"
fi

# somaxconn
SOMAX="${CURRENT[net.core.somaxconn]}"

if is_number "$SOMAX" && [ "$SOMAX" -lt 4096 ]; then
    add_target \
        net.core.somaxconn \
        4096 \
        "提高监听队列上限"
else
    echo "  ✓ somaxconn 无需调整"
fi

# netdev backlog
if is_number "$softnet_delta" &&
   [ "$softnet_delta" -gt 0 ] &&
   is_number "${CURRENT[net.core.netdev_max_backlog]}" &&
   [ "${CURRENT[net.core.netdev_max_backlog]}" -lt 4096 ]; then

    add_target \
        net.core.netdev_max_backlog \
        4096 \
        "检测到 softnet drops"
else
    echo "  ✓ netdev_max_backlog 无需调整"
fi

# MTU probing
MTU_PROBING="${CURRENT[net.ipv4.tcp_mtu_probing]}"

if [ "$MTU_PROBING" = "1" ]; then
    echo "  ✓ tcp_mtu_probing 已为 1"
elif [ "$MTU_PROBING" = "0" ]; then
    add_target \
        net.ipv4.tcp_mtu_probing \
        1 \
        "降低 PMTU black-hole 导致连接异常的风险"
else
    echo "  - tcp_mtu_probing 当前值异常，不修改"
fi

# 临时端口
PORT_RANGE="${CURRENT[net.ipv4.ip_local_port_range]}"
PORT_HIGH="$(printf '%s\n' "$PORT_RANGE" | awk '{print $2}')"

if is_number "$PORT_HIGH" && [ "$PORT_HIGH" -lt 60999 ]; then
    add_target \
        net.ipv4.ip_local_port_range \
        "1024 65535" \
        "扩大临时端口范围"
else
    echo "  ✓ ip_local_port_range 无需调整"
fi

echo
echo "  不自动调整："
echo "    TCP/UDP buffer"
echo "    tcp_mem"
echo "    keepalive"
echo "    tcp_fin_timeout"
echo "    tcp_max_tw_buckets"
echo "    ECN"
echo "    timestamps / SACK / window scaling"
echo

# ------------------------------------------------------------
# [10/10] 来源审计
# ------------------------------------------------------------

echo "[10/10] 参数最终审计"
echo
echo "============================================================"
echo "                 参数实际持久化配置来源"
echo "============================================================"
echo

SOURCE_KEYS=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_syncookies
    net.ipv4.tcp_max_syn_backlog
    net.core.somaxconn
    net.core.netdev_max_backlog
    net.ipv4.tcp_mtu_probing
    net.ipv4.ip_local_port_range
)

for key in "${SOURCE_KEYS[@]}"; do
    echo "[$key]"

    result="$(find_source "$key")"

    if [[ "$result" == NOT_FOUND* ]]; then
        echo "  配置来源 : 未找到"
    else
        file="${result%%|*}"
        rest="${result#*|}"
        line="${rest%%|*}"
        value="${rest#*|}"

        echo "  配置文件 : $file"
        echo "  配置行   : $line"
        echo "  文件值   : $value"
    fi

    echo "  运行值   : ${CURRENT[$key]}"
    echo
done

# ------------------------------------------------------------
# 修改清单
# ------------------------------------------------------------

echo "============================================================"
echo "                      调优审计结果"
echo "============================================================"
echo

CHANGES=0

for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do
    key="${TARGET_KEYS[$i]}"
    value="${TARGET_VALUES[$i]}"
    reason="${TARGET_REASONS[$i]}"
    current="${CURRENT[$key]}"

    if [ "$(norm "$current")" = "$(norm "$value")" ]; then
        continue
    fi

    echo "⚠ $key"
    echo "    当前 : $current"
    echo "    目标 : $value"
    echo "    原因 : $reason"

    if file_has_active_key "$key"; then
        echo "    50-default : 已存在 → 修改"
    elif file_has_commented_key "$key"; then
        echo "    50-default : 注释项 → 解除注释"
    else
        echo "    50-default : 不存在 → 追加"
    fi

    echo
    CHANGES=$((CHANGES + 1))
done

echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo

if [ "$CHANGES" -eq 0 ]; then
    echo -e "${GREEN}没有需要修改的项目。${NC}"
    exit 0
fi

echo "本次待修改：$CHANGES 项"
echo
echo "只修改：$TARGET"
echo
echo "不会："
echo "  sysctl -w"
echo "  systemd-sysctl reload"
echo "  modprobe"
echo "  重启网络"
echo "  重启 SSH"
echo "  重启 VPS"
echo "  创建新的 sysctl.d 文件"
echo

read -r -p "确认执行以上修改？[y/N] " ANSWER

case "$ANSWER" in
    y|Y|yes|YES)
        ;;
    *)
        echo
        echo "已取消，没有修改。"
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 精准修改
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                       开始修改"
echo "============================================================"
echo

for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do
    key="${TARGET_KEYS[$i]}"
    value="${TARGET_VALUES[$i]}"
    current="${CURRENT[$key]}"

    if [ "$(norm "$current")" = "$(norm "$value")" ]; then
        continue
    fi

    echo "  → $key = $value"

    set_target_value "$key" "$value"

    # 修改后立即检查文件内容，不应用 sysctl
    if file_has_active_key "$key"; then
        echo "      ✓ 已写入 $TARGET"
    else
        die "参数 $key 写入验证失败"
    fi
done

echo
echo "============================================================"
echo "                         修改完成"
echo "============================================================"
echo
echo "配置文件：$TARGET"
echo
echo "注意："
echo "  当前运行中的 sysctl 未改变。"
echo "  本脚本没有 reload systemd-sysctl。"
echo "  本脚本没有重启任何服务。"
echo
echo "后续由系统正常的 systemd-sysctl 配置加载机制应用。"
