#!/bin/bash
set -u
export LC_ALL=C

TARGET="/usr/lib/sysctl.d/50-default.conf"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
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

# ------------------------------------------------------------
# 基础函数
# ------------------------------------------------------------

get_sysctl() {
    sysctl -n "$1" 2>/dev/null || echo "unknown"
}

normalize_value() {
    echo "$1" | awk '{$1=$1;print}'
}

file_has_active_key() {
    local key="$1"
    awk -v k="$key" '
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^#/ || line ~ /^;/ || line == "")
                next

            split(line, a, "=")
            lhs=a[1]
            gsub(/[[:space:]]/, "", lhs)

            if (lhs == k || lhs == "/" k)
                found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$TARGET"
}

file_has_commented_key() {
    local key="$1"

    awk -v k="$key" '
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)

            if (line !~ /^#/ && line !~ /^;/)
                next

            sub(/^[#;][[:space:]]*/, "", line)

            split(line, a, "=")
            lhs=a[1]
            gsub(/[[:space:]]/, "", lhs)

            if (lhs == k || lhs == "/" k)
                found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$TARGET"
}

# 找出 systemd-sysctl 实际可见配置文件
get_sysctl_files() {
    local dirs=(
        /etc/sysctl.d
        /run/sysctl.d
        /usr/local/lib/sysctl.d
        /usr/lib/sysctl.d
    )

    local d f
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue

        for f in "$d"/*.conf; do
            [ -f "$f" ] || continue
            echo "$f"
        done
    done
}

# 精确查找一个 key 在配置体系中的最后有效来源。
# 同名文件按 systemd sysctl.d 的目录优先级处理：
# /etc > /run > /usr/local/lib > /usr/lib
find_effective_source() {
    local key="$1"
    local found_file=""
    local found_line=""
    local found_value=""
    local files=()

    mapfile -t files < <(get_sysctl_files)

    local i f line_no line lhs rhs
    local -a ordered=()

    # 按低优先级 -> 高优先级处理
    # 同一目录内按文件名排序，后出现者覆盖前者。
    for f in "${files[@]}"; do
        ordered+=("$f")
    done

    for f in "${ordered[@]}"; do
        [ -r "$f" ] || continue

        while IFS=$'\t' read -r line_no line; do
            [ -n "$line_no" ] || continue

            lhs="${line%%=*}"
            rhs="${line#*=}"

            lhs="$(echo "$lhs" | sed 's/[[:space:]]//g')"
            rhs="$(echo "$rhs" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

            [ "$lhs" = "$key" ] || [ "$lhs" = "/$key" ] || continue

            found_file="$f"
            found_line="$line_no"
            found_value="$rhs"
        done < <(
            awk -v k="$key" '
                {
                    line=$0
                    sub(/^[[:space:]]+/, "", line)

                    if (line == "" || line ~ /^#/ || line ~ /^;/)
                        next

                    split(line, a, "=")
                    lhs=a[1]
                    gsub(/[[:space:]]/, "", lhs)

                    if (lhs == k || lhs == "/" k)
                        print NR "\t" $0
                }
            ' "$f"
        )
    done

    if [ -n "$found_file" ]; then
        echo "$found_file|$found_line|$found_value"
    else
        echo "NOT_FOUND||"
    fi
}

# 当前配置文件精准修改：
# 1. 有 active 参数 -> 修改
# 2. 只有注释参数 -> 解除注释并修改
# 3. 完全不存在 -> 追加
set_target_value() {
    local key="$1"
    local value="$2"
    local tmp

    tmp="$(mktemp)"

    awk -v k="$key" -v v="$value" '
        BEGIN {
            changed=0
        }

        {
            original=$0
            line=$0
            sub(/^[[:space:]]+/, "", line)

            # active parameter
            if (line !~ /^#/ && line !~ /^;/ && line != "") {
                split(line, a, "=")
                lhs=a[1]
                gsub(/[[:space:]]/, "", lhs)

                if (lhs == k || lhs == "/" k) {
                    print k " = " v
                    changed=1
                    next
                }
            }

            # commented parameter
            if (line ~ /^#/ || line ~ /^;/) {
                commented=line
                sub(/^[#;][[:space:]]*/, "", commented)

                split(commented, b, "=")
                lhs2=b[1]
                gsub(/[[:space:]]/, "", lhs2)

                if (lhs2 == k || lhs2 == "/" k) {
                    print k " = " v
                    changed=1
                    next
                }
            }

            print original
        }

        END {
            if (!changed)
                print k " = " v
        }
    ' "$TARGET" > "$tmp"

    cat "$tmp" > "$TARGET"
    rm -f "$tmp"
}

# ------------------------------------------------------------
# [1/10] 系统检测
# ------------------------------------------------------------

echo "[1/10] 系统检测"

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    ID="unknown"
    VERSION_ID="unknown"
    PRETTY_NAME="unknown"
fi

CPU="$(nproc 2>/dev/null || echo 1)"
RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
RAM_MB=$((RAM_KB / 1024))
SWAP_MB="$(free -m 2>/dev/null | awk '/^Swap:/ {print $3}' || echo 0)"
KERNEL="$(uname -r)"

echo "  OS       : ${PRETTY_NAME:-unknown}"
echo "  Kernel   : $KERNEL"
echo "  CPU      : $CPU cores"
echo "  RAM      : ${RAM_MB} MB"
echo "  Swap     : ${SWAP_MB} MB（不修改）"
echo

# ------------------------------------------------------------
# [2/10] IPv4 / IPv6 / TCP / UDP
# ------------------------------------------------------------

echo "[2/10] IPv4 / IPv6 / TCP / UDP 检测"

IPV4_COUNT="$(ip -4 addr 2>/dev/null | awk '/inet / {c++} END {print c+0}')"
IPV6_COUNT="$(ip -6 addr 2>/dev/null | awk '/inet6 / {c++} END {print c+0}')"

IPV6_DISABLED="$(get_sysctl net.ipv6.conf.all.disable_ipv6)"

TCP_LISTEN="$(ss -Hln 2>/dev/null | awk '$1 ~ /^tcp/ {c++} END {print c+0}')"
TCP_EST="$(ss -Hnt 2>/dev/null | awk '$1 == "ESTAB" {c++} END {print c+0}')"
UDP_COUNT="$(ss -Hun 2>/dev/null | awk 'END {print NR+0}')"

DEFAULT_IF="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"

echo "  IPv4 地址        : $IPV4_COUNT"
echo "  IPv6 地址        : $IPV6_COUNT"
echo "  IPv6 disabled    : $IPV6_DISABLED"
echo "  TCP LISTEN       : $TCP_LISTEN"
echo "  TCP established   : $TCP_EST"
echo "  UDP sockets      : $UDP_COUNT"
echo "  默认网卡         : ${DEFAULT_IF:-unknown}"
echo

# ------------------------------------------------------------
# [3/10] SSH 会话
# ------------------------------------------------------------

echo "[3/10] SSH 会话检测"

SSH_FOUND=0

if [ -n "${SSH_CONNECTION:-}" ]; then
    SSH_FOUND=1
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

# ------------------------------------------------------------
# [4/10] CPU / RAM 等级
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
echo
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

BBR_SUPPORTED=0
FQ_SUPPORTED=0

echo "$AVAILABLE_CC" | tr ' ' '\n' | grep -qx bbr && BBR_SUPPORTED=1

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

# ------------------------------------------------------------
# [6/10] 实际网络压力
# ------------------------------------------------------------

echo "[6/10] 网络实际压力检测"

softnet_before="$(awk '{sum+=$2} END {print sum+0}' /proc/net/softnet_stat 2>/dev/null)"
rx_before="$(cat /sys/class/net/*/statistics/rx_dropped 2>/dev/null | awk '{sum+=$1} END {print sum+0}')"
tx_before="$(cat /sys/class/net/*/statistics/tx_dropped 2>/dev/null | awk '{sum+=$1} END {print sum+0}')"

sleep 3

softnet_after="$(awk '{sum+=$2} END {print sum+0}' /proc/net/softnet_stat 2>/dev/null)"
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
# [7/10] 当前运行参数
# ------------------------------------------------------------

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
    "net.ipv4.ip_local_port_range"
)

for p in "${PARAMS[@]}"; do
    CURRENT["$p"]="$(get_sysctl "$p")"
done

echo "  default_qdisc       : ${CURRENT[net.core.default_qdisc]}"
echo "  congestion_control  : ${CURRENT[net.ipv4.tcp_congestion_control]}"
echo "  tcp_fastopen        : ${CURRENT[net.ipv4.tcp_fastopen]}"
echo "  tcp_syncookies      : ${CURRENT[net.ipv4.tcp_syncookies]}"
echo "  somaxconn            : ${CURRENT[net.core.somaxconn]}"
echo "  tcp_max_syn_backlog  : ${CURRENT[net.ipv4.tcp_max_syn_backlog]}"
echo "  netdev_max_backlog   : ${CURRENT[net.core.netdev_max_backlog]}"
echo "  tcp_window_scaling   : ${CURRENT[net.ipv4.tcp_window_scaling]}"
echo "  tcp_sack             : ${CURRENT[net.ipv4.tcp_sack]}"
echo "  tcp_timestamps       : ${CURRENT[net.ipv4.tcp_timestamps]}"
echo "  tcp_ecn              : ${CURRENT[net.ipv4.tcp_ecn]}"
echo "  tcp_mtu_probing      : ${CURRENT[net.ipv4.tcp_mtu_probing]}"
echo "  ip_local_port_range  : ${CURRENT[net.ipv4.ip_local_port_range]}"
echo

# ------------------------------------------------------------
# [8/10] systemd-sysctl 配置文件
# ------------------------------------------------------------

echo "[8/10] 检测 systemd-sysctl 实际配置文件"
echo

echo "  systemd-sysctl 配置文件："

mapfile -t SYSCTL_FILES < <(get_sysctl_files | sort -V -u)

for f in "${SYSCTL_FILES[@]}"; do
    echo "    $f"
done

echo

# ------------------------------------------------------------
# bpftune 审计
# ------------------------------------------------------------

echo "------------------------------------------------------------"
echo " bpftune / BPF 自动调优能力审计"
echo "------------------------------------------------------------"

if command -v bpftune >/dev/null 2>&1; then
    echo "  bpftune          : 已安装"

    BPFTUNE_SUPPORT="$(bpftune -S 2>&1 | tr '\n' ' ')"

    if echo "$BPFTUNE_SUPPORT" | grep -qi "works fully"; then
        echo "  BPF tuner        : fully supported"
    elif echo "$BPFTUNE_SUPPORT" | grep -qi "legacy mode"; then
        echo "  BPF tuner        : legacy mode supported"
    else
        echo "  BPF tuner        : 未确认支持"
    fi
else
    echo "  bpftune          : 未安装"
    echo "  本脚本不会安装或启动 bpftune"
fi

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

# 1. BBR
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

# 2. FQ
if [ "$QDISC" = "fq" ]; then
    echo "  ✓ default_qdisc 已经是 fq"
elif [ "$FQ_SUPPORTED" -eq 1 ]; then
    add_target \
        "net.core.default_qdisc" \
        "fq" \
        "BBR 推荐配合 fq；当前为 $QDISC"
else
    echo "  - 无法确认 FQ 支持，不修改"
fi

# 3. TFO
if [ "$TFO" = "3" ]; then
    echo "  ✓ TCP Fast Open 已为 3"
else
    case "$TFO" in
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
fi

# 4. SYN backlog
# 只在当前明显偏低时调整。
BACKLOG="${CURRENT[net.ipv4.tcp_max_syn_backlog]}"

if [ "$BACKLOG" -eq 128 ] 2>/dev/null; then
    add_target \
        "net.ipv4.tcp_max_syn_backlog" \
        "4096" \
        "当前为 Debian 默认 128；公网高并发服务端适当扩大 SYN backlog"
else
    echo "  ✓ tcp_max_syn_backlog 当前为 $BACKLOG，不强制修改"
fi

# 5. somaxconn
SOMAX="${CURRENT[net.core.somaxconn]}"

if [ "$SOMAX" -lt 4096 ] 2>/dev/null; then
    add_target \
        "net.core.somaxconn" \
        "4096" \
        "监听队列上限偏低"
else
    echo "  ✓ somaxconn 当前为 $SOMAX"
fi

# 6. netdev backlog
# 只有实际出现 softnet drop 才调。
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

# 7. 临时端口
# 只有范围明显偏小时才扩大，不强制把所有 VPS 改成 1024-65535。
PORT_RANGE="${CURRENT[net.ipv4.ip_local_port_range]}"

PORT_LOW="$(echo "$PORT_RANGE" | awk '{print $1}')"
PORT_HIGH="$(echo "$PORT_RANGE" | awk '{print $2}')"

if [ "$PORT_HIGH" -lt 60999 ] 2>/dev/null; then
    add_target \
        "net.ipv4.ip_local_port_range" \
        "1024 65535" \
        "当前临时端口上限偏低"
else
    echo "  ✓ ip_local_port_range 当前无需调整"
fi

# 明确不做：
# tcp_mem
# tcp_rmem
# tcp_wmem
# rmem_max
# wmem_max
# udp_rmem_min
# udp_wmem_min
# keepalive
# fin_timeout
# mtu_probing
# ECN
# tcp_notsent_lowat
# tcp_no_metrics_save
# timestamps
# sack
# window_scaling

echo

# ------------------------------------------------------------
# [10/10] 参数最终来源审计
# ------------------------------------------------------------

echo "[10/10] 参数最终审计"
echo
echo "============================================================"
echo "                 参数实际持久化配置来源"
echo "============================================================"
echo

SOURCE_KEYS=(
    "net.ipv4.tcp_congestion_control"
    "net.core.default_qdisc"
    "net.ipv4.tcp_fastopen"
    "net.ipv4.tcp_syncookies"
    "net.core.somaxconn"
    "net.ipv4.tcp_max_syn_backlog"
    "net.core.netdev_max_backlog"
    "net.ipv4.ip_local_port_range"
)

for key in "${SOURCE_KEYS[@]}"; do
    echo "[$key]"

    RESULT="$(find_effective_source "$key")"

    if [[ "$RESULT" == NOT_FOUND* ]]; then
        echo "  实际持久化配置 : 未找到"
        echo "  当前运行值      : ${CURRENT[$key]}"
    else
        FILE="${RESULT%%|*}"
        REST="${RESULT#*|}"
        LINE="${REST%%|*}"
        VALUE="${REST#*|}"

        echo "  实际配置文件    : $FILE"
        echo "  配置行          : $LINE"
        echo "  文件值          : $VALUE"
        echo "  当前运行值      : ${CURRENT[$key]}"
    fi

    echo
done

# ------------------------------------------------------------
# 生成最终待修改清单
# ------------------------------------------------------------

echo "============================================================"
echo "                      调优审计结果"
echo "============================================================"
echo

CHANGES=0

if [ "${#TARGET_KEYS[@]}" -eq 0 ]; then
    echo "✓ 未发现需要修改的核心参数。"
else
    for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do
        key="${TARGET_KEYS[$i]}"
        val="${TARGET_VALUES[$i]}"
        reason="${TARGET_REASONS[$i]}"

        current="${CURRENT[$key]}"

        # 如果当前已经相等，绝对不修改。
        if [ "$(normalize_value "$current")" = "$(normalize_value "$val")" ]; then
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
fi

echo "============================================================"
echo "                   明确不会修改"
echo "============================================================"
echo "  ✓ Swap"
echo "  ✓ vm.*"
echo "  ✓ IPv4 forwarding"
echo "  ✓ IPv6 forwarding"
echo "  ✓ IPv6 disable"
echo "  ✓ tcp_mem"
echo "  ✓ tcp_rmem"
echo "  ✓ tcp_wmem"
echo "  ✓ rmem_max / wmem_max"
echo "  ✓ UDP buffer"
echo "  ✓ TCP keepalive"
echo "  ✓ TCP FIN timeout"
echo "  ✓ TCP MTU probing"
echo "  ✓ TCP ECN"
echo "  ✓ TCP notsent_lowat"
echo "  ✓ TCP timestamps"
echo "  ✓ TCP SACK"
echo "  ✓ TCP window scaling"
echo "  ✓ SSH 服务"
echo "  ✓ 网络服务"
echo "  ✓ 当前运行中的 sysctl"
echo "  ✓ 当前运行中的 qdisc"
echo "  ✓ 当前运行中的连接"
echo "  ✓ modprobe"
echo "  ✓ systemd-sysctl reload"
echo "  ✓ 网络重启"
echo "  ✓ SSH 重启"
echo "  ✓ VPS 重启"
echo
echo "  ✓ 不创建新的 sysctl.d 文件"
echo "  ✓ 唯一允许修改：$TARGET"
echo

if [ "$CHANGES" -eq 0 ]; then
    echo -e "${GREEN}没有需要修改的项目。${NC}"
    exit 0
fi

echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo
echo "本次共发现 $CHANGES 个待修改项目。"
echo
echo "确认后只会："
echo "  1. 精准修改 $TARGET"
echo "  2. 已存在参数 → 修改对应行"
echo "  3. 注释参数 → 解除对应注释并修改"
echo "  4. 完全不存在参数 → 追加到这个已有文件"
echo
echo "不会立即应用新的 sysctl。"
echo "不会执行 sysctl -w。"
echo "不会 reload systemd-sysctl。"
echo "不会重启 SSH / 网络 / VPS。"
echo
read -r -p "确认执行以上修改？[y/N] " ANSWER

case "$ANSWER" in
    y|Y|yes|YES)
        ;;
    *)
        echo
        echo "已取消，没有修改任何文件。"
        exit 0
        ;;
esac

echo
echo "============================================================"
echo "                       开始精准修改"
echo "============================================================"
echo

for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do
    key="${TARGET_KEYS[$i]}"
    val="${TARGET_VALUES[$i]}"

    current="$(get_sysctl "$key")"

    if [ "$(normalize_value "$current")" = "$(normalize_value "$val")" ]; then
        echo "✓ $key 已经是 $val，不修改"
        continue
    fi

    echo "→ $key = $val"
    set_target_value "$key" "$val"
done

echo
echo "============================================================"
echo "                       修改完成"
echo "============================================================"
echo
echo "✓ 已修改：$TARGET"
echo
echo "注意："
echo "  本脚本没有立即执行 sysctl -w。"
echo "  本脚本没有 reload systemd-sysctl。"
echo "  新配置将在 systemd-sysctl 下一次应用配置时生效。"
echo
echo "如果希望立即应用，请在确认 SSH 连接稳定后手动执行："
echo
echo "  systemctl restart systemd-sysctl"
echo
echo "当前脚本不会替你执行该操作，以避免主动影响当前 SSH 会话。"
echo
