#!/bin/bash

set -u
set -o pipefail
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

command -v sysctl >/dev/null 2>&1 || die "sysctl 不存在"
command -v awk >/dev/null 2>&1 || die "awk 不存在"
command -v sed >/dev/null 2>&1 || die "sed 不存在"
command -v grep >/dev/null 2>&1 || die "grep 不存在"
command -v ip >/dev/null 2>&1 || die "ip 不存在"
command -v ss >/dev/null 2>&1 || die "ss 不存在"
command -v systemctl >/dev/null 2>&1 || die "systemctl 不存在"

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
[ -f "$TARGET" ] || die "$TARGET 不存在，拒绝创建"

echo "============================================================"
echo " Debian 13 双栈 TCP/UDP 网络调优"
echo " 审计 → 判断 → 确认 → 修改 → 重启网络 → 应用 → 验证"
echo "============================================================"
echo
echo "配置文件：$TARGET"
echo "不备份，不创建新的 sysctl.d 文件"
echo

# ============================================================
# 基础函数
# ============================================================

get_sysctl() {
    local key="$1"
    sysctl -n "$key" 2>/dev/null || echo "unknown"
}

trim() {
    echo "$1" | awk '{$1=$1; print}'
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

file_active_key() {
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

file_commented_key() {
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

# ============================================================
# 精准修改目标文件
# ============================================================

set_sysctl_file_value() {
    local key="$1"
    local value="$2"
    local tmp

    tmp="$(mktemp)" || return 1

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
        return 1
    fi

    if ! cat "$tmp" > "$TARGET"; then
        rm -f "$tmp"
        return 1
    fi

    rm -f "$tmp"
    return 0
}

# ============================================================
# systemd-sysctl 配置文件
# ============================================================

get_sysctl_files() {
    local dir file

    for dir in \
        /etc/sysctl.d \
        /run/sysctl.d \
        /usr/local/lib/sysctl.d \
        /usr/lib/sysctl.d
    do
        [ -d "$dir" ] || continue

        for file in "$dir"/*.conf; do
            [ -f "$file" ] || continue
            echo "$file"
        done
    done
}

find_effective_source() {
    local key="$1"

    local best_file=""
    local best_line=""
    local best_value=""

    local file line_no line lhs rhs

    while IFS= read -r file; do
        [ -r "$file" ] || continue

        while IFS=$'\t' read -r line_no line; do
            [ -n "$line_no" ] || continue

            lhs="${line%%=*}"
            rhs="${line#*=}"

            lhs="$(echo "$lhs" | sed 's/[[:space:]]//g')"
            rhs="$(echo "$rhs" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

            if [ "$lhs" = "$key" ] || [ "$lhs" = "/$key" ]; then
                best_file="$file"
                best_line="$line_no"
                best_value="$rhs"
            fi
        done < <(
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
                        print NR "\t" $0
                }
            ' "$file"
        )

    done < <(get_sysctl_files | sort -V -u)

    if [ -n "$best_file" ]; then
        echo "$best_file|$best_line|$best_value"
    else
        echo "NOT_FOUND||"
    fi
}

# ============================================================
# [1/10] 系统检测
# ============================================================

echo "[1/10] 系统检测"

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    ID="unknown"
    VERSION_ID="unknown"
    PRETTY_NAME="unknown"
fi

CPU="$(nproc 2>/dev/null || echo 1)"

RAM_KB="$(
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null
)"

RAM_KB="${RAM_KB:-0}"
RAM_MB=$((RAM_KB / 1024))

SWAP_MB="$(
    free -m 2>/dev/null |
    awk '/^Swap:/ {print $3; exit}'
)"

SWAP_MB="${SWAP_MB:-0}"

KERNEL="$(uname -r)"

echo "  OS       : ${PRETTY_NAME:-unknown}"
echo "  Kernel   : $KERNEL"
echo "  CPU      : $CPU cores"
echo "  RAM      : $RAM_MB MB"
echo "  Swap     : $SWAP_MB MB（不修改）"
echo

# ============================================================
# [2/10] 网络检测
# ============================================================

echo "[2/10] IPv4 / IPv6 / TCP / UDP 检测"

IPV4_COUNT="$(
    ip -4 addr 2>/dev/null |
    awk '/inet / {c++} END {print c+0}'
)"

IPV6_COUNT="$(
    ip -6 addr 2>/dev/null |
    awk '/inet6 / {c++} END {print c+0}'
)"

IPV6_DISABLED="$(get_sysctl net.ipv6.conf.all.disable_ipv6)"

TCP_LISTEN="$(
    ss -Hln 2>/dev/null |
    awk '$1 ~ /^tcp/ {c++} END {print c+0}'
)"

TCP_EST="$(
    ss -Hnt 2>/dev/null |
    awk '$1 == "ESTAB" {c++} END {print c+0}'
)"

UDP_COUNT="$(
    ss -Hun 2>/dev/null |
    awk 'END {print NR+0}'
)"

DEFAULT_IF="$(
    ip route show default 2>/dev/null |
    awk 'NR==1 {print $5}'
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
# [3/10] SSH
# ============================================================

echo "[3/10] SSH 会话检测"

if [ -n "${SSH_CONNECTION:-}" ]; then
    read -r SSH_REMOTE SSH_RPORT SSH_LOCAL SSH_LPORT <<< "$SSH_CONNECTION"

    echo "  ✓ 当前 SSH 远程会话"
    echo "  远端 IP     : $SSH_REMOTE"
    echo "  远端端口    : $SSH_RPORT"
    echo "  本地地址    : $SSH_LOCAL"
    echo "  本地端口    : $SSH_LPORT"
else
    echo "  未检测到 SSH_CONNECTION"
fi

echo

# ============================================================
# [4/10] CPU / RAM
# ============================================================

echo "[4/10] CPU / RAM 调优等级"

if [ "$CPU" -le 1 ] 2>/dev/null; then
    CPU_LEVEL="small"
elif [ "$CPU" -le 2 ] 2>/dev/null; then
    CPU_LEVEL="medium"
else
    CPU_LEVEL="large"
fi

if [ "$RAM_MB" -le 1536 ] 2>/dev/null; then
    RAM_LEVEL="small"
elif [ "$RAM_MB" -le 4096 ] 2>/dev/null; then
    RAM_LEVEL="medium"
else
    RAM_LEVEL="large"
fi

echo "  CPU 等级 : $CPU_LEVEL"
echo "  RAM 等级 : $RAM_LEVEL"
echo

# ============================================================
# [5/10] BBR / FQ / TFO
# ============================================================

echo "[5/10] BBR / FQ / TCP Fast Open"

CC="$(get_sysctl net.ipv4.tcp_congestion_control)"
AVAILABLE_CC="$(get_sysctl net.ipv4.tcp_available_congestion_control)"
QDISC="$(get_sysctl net.core.default_qdisc)"
TFO="$(get_sysctl net.ipv4.tcp_fastopen)"

BBR_SUPPORTED=0
FQ_SUPPORTED=0

if echo "$AVAILABLE_CC" | tr ' ' '\n' | grep -qx "bbr"; then
    BBR_SUPPORTED=1
fi

if [ -e /proc/sys/net/core/default_qdisc ]; then
    FQ_SUPPORTED=1
fi

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
# [6/10] 网络压力
# ============================================================

echo "[6/10] 网络实际压力检测"

softnet_before="$(
    awk '{sum += $2} END {print sum+0}' \
    /proc/net/softnet_stat 2>/dev/null
)"

rx_before="$(
    cat /sys/class/net/*/statistics/rx_dropped 2>/dev/null |
    awk '{sum += $1} END {print sum+0}'
)"

tx_before="$(
    cat /sys/class/net/*/statistics/tx_dropped 2>/dev/null |
    awk '{sum += $1} END {print sum+0}'
)"

softnet_before="${softnet_before:-0}"
rx_before="${rx_before:-0}"
tx_before="${tx_before:-0}"

sleep 3

softnet_after="$(
    awk '{sum += $2} END {print sum+0}' \
    /proc/net/softnet_stat 2>/dev/null
)"

rx_after="$(
    cat /sys/class/net/*/statistics/rx_dropped 2>/dev/null |
    awk '{sum += $1} END {print sum+0}'
)"

tx_after="$(
    cat /sys/class/net/*/statistics/tx_dropped 2>/dev/null |
    awk '{sum += $1} END {print sum+0}'
)"

softnet_after="${softnet_after:-0}"
rx_after="${rx_after:-0}"
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
    "net.core.default_qdisc"
    "net.ipv4.tcp_congestion_control"
    "net.ipv4.tcp_fastopen"
    "net.ipv4.tcp_syncookies"
    "net.core.somaxconn"
    "net.ipv4.tcp_max_syn_backlog"
    "net.core.netdev_max_backlog"
    "net.ipv4.tcp_window_scaling"
    "net.ipv4.tcp_sack"
    "net.ipv4.tcp_timestamps"
    "net.ipv4.tcp_ecn"
    "net.ipv4.tcp_mtu_probing"
    "net.ipv4.tcp_fin_timeout"
    "net.ipv4.tcp_keepalive_time"
    "net.ipv4.tcp_keepalive_intvl"
    "net.ipv4.tcp_keepalive_probes"
    "net.ipv4.tcp_max_tw_buckets"
    "net.ipv4.ip_local_port_range"
)

for key in "${PARAMS[@]}"; do
    CURRENT["$key"]="$(get_sysctl "$key")"
done

printf "  default_qdisc       : %s\n" \
    "${CURRENT[net.core.default_qdisc]}"

printf "  congestion_control  : %s\n" \
    "${CURRENT[net.ipv4.tcp_congestion_control]}"

printf "  tcp_fastopen        : %s\n" \
    "${CURRENT[net.ipv4.tcp_fastopen]}"

printf "  tcp_syncookies      : %s\n" \
    "${CURRENT[net.ipv4.tcp_syncookies]}"

printf "  tcp_max_syn_backlog : %s\n" \
    "${CURRENT[net.ipv4.tcp_max_syn_backlog]}"

printf "  somaxconn            : %s\n" \
    "${CURRENT[net.core.somaxconn]}"

printf "  netdev_max_backlog   : %s\n" \
    "${CURRENT[net.core.netdev_max_backlog]}"

printf "  tcp_window_scaling   : %s\n" \
    "${CURRENT[net.ipv4.tcp_window_scaling]}"

printf "  tcp_sack             : %s\n" \
    "${CURRENT[net.ipv4.tcp_sack]}"

printf "  tcp_timestamps       : %s\n" \
    "${CURRENT[net.ipv4.tcp_timestamps]}"

printf "  tcp_ecn              : %s\n" \
    "${CURRENT[net.ipv4.tcp_ecn]}"

printf "  tcp_mtu_probing      : %s\n" \
    "${CURRENT[net.ipv4.tcp_mtu_probing]}"

printf "  tcp_fin_timeout      : %s\n" \
    "${CURRENT[net.ipv4.tcp_fin_timeout]}"

printf "  tcp_keepalive_time   : %s\n" \
    "${CURRENT[net.ipv4.tcp_keepalive_time]}"

printf "  tcp_keepalive_intvl  : %s\n" \
    "${CURRENT[net.ipv4.tcp_keepalive_intvl]}"

printf "  tcp_keepalive_probes : %s\n" \
    "${CURRENT[net.ipv4.tcp_keepalive_probes]}"

printf "  tcp_max_tw_buckets   : %s\n" \
    "${CURRENT[net.ipv4.tcp_max_tw_buckets]}"

printf "  ip_local_port_range  : %s\n" \
    "${CURRENT[net.ipv4.ip_local_port_range]}"

echo

# ============================================================
# [8/10] 配置文件
# ============================================================

echo "[8/10] systemd-sysctl 配置文件"

while IFS= read -r file; do
    echo "    $file"
done < <(get_sysctl_files | sort -V -u)

echo

# ============================================================
# bpftune
# ============================================================

echo "------------------------------------------------------------"
echo " bpftune / BPF 自动调优审计"
echo "------------------------------------------------------------"

if command -v bpftune >/dev/null 2>&1; then
    echo "  bpftune : 已安装"
else
    echo "  bpftune : 未安装"
fi

echo

# ============================================================
# [9/10] 自动生成目标
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

# BBR
if [ "$CC" = "bbr" ]; then
    echo "  ✓ BBR 已运行"
elif [ "$BBR_SUPPORTED" -eq 1 ]; then
    add_target \
        "net.ipv4.tcp_congestion_control" \
        "bbr" \
        "内核支持 BBR"
fi

# FQ
if [ "$QDISC" = "fq" ]; then
    echo "  ✓ default_qdisc 已是 fq"
elif [ "$FQ_SUPPORTED" -eq 1 ]; then
    add_target \
        "net.core.default_qdisc" \
        "fq" \
        "BBR 推荐配合 fq"
fi

# TFO
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
        echo "  - tcp_fastopen 异常，不修改"
        ;;
esac

# SYN backlog
BACKLOG="${CURRENT[net.ipv4.tcp_max_syn_backlog]}"

if is_number "$BACKLOG" && [ "$BACKLOG" -eq 128 ]; then
    add_target \
        "net.ipv4.tcp_max_syn_backlog" \
        "4096" \
        "当前 SYN backlog 为 128"
else
    echo "  ✓ tcp_max_syn_backlog 不调整"
fi

# somaxconn
SOMAX="${CURRENT[net.core.somaxconn]}"

if is_number "$SOMAX" && [ "$SOMAX" -lt 4096 ]; then
    add_target \
        "net.core.somaxconn" \
        "4096" \
        "监听队列上限偏低"
else
    echo "  ✓ somaxconn 不调整"
fi

# netdev backlog
NETDEV="${CURRENT[net.core.netdev_max_backlog]}"

if is_number "$NETDEV" && [ "$NETDEV" -lt 4096 ] &&
   [ "$softnet_delta" -gt 0 ]; then

    add_target \
        "net.core.netdev_max_backlog" \
        "4096" \
        "检测到 softnet drops"

else
    echo "  ✓ netdev_max_backlog 不调整"
fi

# MTU probing
MTU_PROBING="${CURRENT[net.ipv4.tcp_mtu_probing]}"

if [ "$MTU_PROBING" = "1" ]; then
    echo "  ✓ tcp_mtu_probing 已为 1"
elif [ "$MTU_PROBING" = "0" ]; then
    add_target \
        "net.ipv4.tcp_mtu_probing" \
        "1" \
        "降低 PMTU black-hole 导致连接异常的风险"
else
    echo "  - tcp_mtu_probing 当前值异常，不修改"
fi

# 临时端口
PORT_RANGE="${CURRENT[net.ipv4.ip_local_port_range]}"

PORT_LOW="$(echo "$PORT_RANGE" | awk '{print $1}')"
PORT_HIGH="$(echo "$PORT_RANGE" | awk '{print $2}')"

if is_number "$PORT_LOW" &&
   is_number "$PORT_HIGH" &&
   [ "$PORT_HIGH" -lt 60999 ]; then

    add_target \
        "net.ipv4.ip_local_port_range" \
        "1024 65535" \
        "临时端口上限偏低"

else
    echo "  ✓ ip_local_port_range 不调整"
fi

echo
echo "  ✓ 不修改 TCP keepalive"
echo "  ✓ 不修改 tcp_fin_timeout"
echo "  ✓ 不修改 tcp_max_tw_buckets"
echo "  ✓ 不修改 TCP/UDP buffer"
echo "  ✓ 不修改 tcp_mem"
echo "  ✓ 不修改 ECN"
echo "  ✓ 不修改 timestamps"
echo "  ✓ 不修改 SACK"
echo "  ✓ 不修改 window scaling"
echo

# ============================================================
# [10/10] 持久化来源审计
# ============================================================

echo "[10/10] 参数持久化来源审计"
echo

SOURCE_KEYS=(
    "net.ipv4.tcp_congestion_control"
    "net.core.default_qdisc"
    "net.ipv4.tcp_fastopen"
    "net.ipv4.tcp_syncookies"
    "net.core.somaxconn"
    "net.ipv4.tcp_max_syn_backlog"
    "net.core.netdev_max_backlog"
    "net.ipv4.tcp_mtu_probing"
    "net.ipv4.ip_local_port_range"
)

for key in "${SOURCE_KEYS[@]}"; do

    echo "[$key]"

    result="$(find_effective_source "$key")"

    if [[ "$result" == NOT_FOUND* ]]; then

        echo "  持久化配置 : 未找到"
        echo "  当前运行值 : ${CURRENT[$key]}"

    else

        file="${result%%|*}"
        rest="${result#*|}"
        line="${rest%%|*}"
        value="${rest#*|}"

        echo "  配置文件   : $file"
        echo "  配置行     : $line"
        echo "  文件值     : $value"
        echo "  当前运行值 : ${CURRENT[$key]}"

    fi

    echo
done

# ============================================================
# 调优结果
# ============================================================

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

    if [ "$(trim "$current")" = "$(trim "$value")" ]; then
        continue
    fi

    echo -e "${YELLOW}⚠ $key${NC}"
    echo "    当前运行值 : $current"
    echo "    建议值     : $value"
    echo "    原因       : $reason"

    if file_active_key "$key"; then
        echo "    配置文件   : 已存在 → 修改"

    elif file_commented_key "$key"; then
        echo "    配置文件   : 已注释 → 启用并修改"

    else
        echo "    配置文件   : 不存在 → 追加"
    fi

    echo
    CHANGES=$((CHANGES + 1))
done

echo "============================================================"
echo "                      不会修改"
echo "============================================================"
echo "  ✓ Swap / vm.*"
echo "  ✓ IPv4 / IPv6 forwarding"
echo "  ✓ IPv6 disable"
echo "  ✓ TCP/UDP buffer"
echo "  ✓ TCP keepalive"
echo "  ✓ tcp_fin_timeout"
echo "  ✓ tcp_max_tw_buckets"
echo "  ✓ tcp_mem / tcp_rmem / tcp_wmem"
echo "  ✓ ECN"
echo "  ✓ timestamps / SACK / window scaling"
echo "  ✓ SSH 配置"
echo "  ✓ modprobe"
echo "  ✓ 不执行 sysctl -w"
echo "  ✓ 不创建新的 sysctl.d 文件"
echo "  ✓ 不备份"
echo

if [ "$CHANGES" -eq 0 ]; then
    echo -e "${GREEN}✓ 没有需要修改的参数。${NC}"
    exit 0
fi

# ============================================================
# 确认
# ============================================================

echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo
echo "本次需要修改：$CHANGES 项"
echo
echo "确认后执行："
echo "  1. 修改 $TARGET"
echo "  2. 校验配置文件"
echo "  3. systemctl restart networking"
echo "  4. systemctl restart systemd-sysctl"
echo "  5. 验证最终运行值"
echo
echo "⚠ 不创建备份"
echo "⚠ 不执行 sysctl -w"
echo

read -r -p "确认执行？[y/N] " ANSWER

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
# 修改
# ============================================================

echo
echo "============================================================"
echo "                        修改配置"
echo "============================================================"
echo

for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do

    key="${TARGET_KEYS[$i]}"
    value="${TARGET_VALUES[$i]}"
    current="${CURRENT[$key]}"

    if [ "$(trim "$current")" = "$(trim "$value")" ]; then
        continue
    fi

    echo "  → $key = $value"

    if ! set_sysctl_file_value "$key" "$value"; then
        die "修改 $TARGET 失败"
    fi

    echo "    ✓ 已写入"
done

# ============================================================
# 配置文件校验
# ============================================================

echo
echo "============================================================"
echo "                        配置校验"
echo "============================================================"
echo

if ! awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*;/ {next}
    /^[[:space:]]*$/ {next}

    {
        if ($0 !~ /^[[:space:]]*[^=[:space:]]+[[:space:]]*=/) {
            print "非法配置行：" NR ": " $0
            bad=1
        }
    }

    END {
        exit(bad ? 1 : 0)
    }
' "$TARGET"; then

    die "配置文件格式校验失败"
fi

echo "  ✓ 配置文件格式正常"

# ============================================================
# 检查目标是否真的写入
# ============================================================

for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do

    key="${TARGET_KEYS[$i]}"
    value="${TARGET_VALUES[$i]}"

    if ! file_active_key "$key"; then
        die "$key 写入后未检测到有效配置"
    fi

    actual="$(
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
                rhs=substr(line, pos+1)

                gsub(/[[:space:]]/, "", lhs)
                gsub(/^[[:space:]]+/, "", rhs)
                gsub(/[[:space:]]+$/, "", rhs)

                if (lhs == k || lhs == "/" k) {
                    print rhs
                }
            }
        ' "$TARGET" | tail -n 1
    "

    if [ "$(trim "$actual")" != "$(trim "$value")" ]; then
        die "$key 配置校验失败：$actual != $value"
    fi
done

echo "  ✓ 所有目标参数写入校验通过"

# ============================================================
# 重启 networking
# ============================================================

echo
echo "============================================================"
echo "                    重启 networking"
echo "============================================================"
echo

if systemctl is-enabled networking.service >/dev/null 2>&1 ||
   systemctl is-active networking.service >/dev/null 2>&1; then

    echo "  → systemctl restart networking"

    if ! systemctl restart networking; then
        echo
        echo -e "${RED}错误：networking 重启失败${NC}"
        echo
        systemctl --no-pager --full status networking.service 2>&1 || true
        exit 1
    fi

    echo "  ✓ networking 重启成功"

else
    echo "  ⚠ networking.service 当前不可用"
    echo "  → 跳过 networking 重启"
fi

# ============================================================
# 应用 systemd-sysctl
# ============================================================

echo
echo "============================================================"
echo "                    应用 sysctl 配置"
echo "============================================================"
echo

echo "  → systemctl restart systemd-sysctl"

if ! systemctl restart systemd-sysctl; then
    echo
    echo -e "${RED}错误：systemd-sysctl 应用失败${NC}"
    echo
    systemctl --no-pager --full status systemd-sysctl.service 2>&1 || true
    exit 1
fi

echo "  ✓ systemd-sysctl 应用成功"

# ============================================================
# 最终验证
# ============================================================

echo
echo "============================================================"
echo "                       最终验证"
echo "============================================================"
echo

VERIFY_FAILED=0

for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do

    key="${TARGET_KEYS[$i]}"
    expected="${TARGET_VALUES[$i]}"

    actual="$(get_sysctl "$key")"

    printf "  %-38s : %s\n" "$key" "$actual"

    if [ "$(trim "$actual")" != "$(trim "$expected")" ]; then
        echo "    ✗ 期望值：$expected"
        VERIFY_FAILED=1
    else
        echo "    ✓ 生效"
    fi
done

echo

if [ "$VERIFY_FAILED" -ne 0 ]; then
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}              部分参数未达到预期运行值${NC}"
    echo -e "${RED}============================================================${NC}"
    exit 1
fi

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}                    调优完成${NC}"
echo -e "${GREEN}============================================================${NC}"
echo
echo "配置文件：$TARGET"
echo "已执行：networking restart"
echo "已执行：systemd-sysctl restart"
echo "所有本次修改参数已验证生效。"
echo
