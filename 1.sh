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

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

for cmd in awk sed grep sysctl ip ss free nproc systemctl mktemp; do
    need_cmd "$cmd"
done

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
[ -f "$TARGET" ] || die "$TARGET 不存在，拒绝创建"
[ -w "$TARGET" ] || die "$TARGET 不可写"
[ -L "$TARGET" ] && die "$TARGET 是符号链接，拒绝修改"

get_sysctl() {
    sysctl -n "$1" 2>/dev/null || echo "unknown"
}

trim() {
    printf '%s\n' "$1" | awk '{$1=$1; print}'
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

has_key_in_target() {
    local key="$1"

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
            found=1
    }
    END {
        exit(found ? 0 : 1)
    }
    ' "$TARGET"
}

has_commented_key_in_target() {
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
    END {
        exit(found ? 0 : 1)
    }
    ' "$TARGET"
}

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

find_effective_source() {
    local key="$1"
    local result=""
    local f
    local line_no
    local line
    local lhs
    local rhs

    while IFS= read -r f; do
        [ -r "$f" ] || continue

        while IFS=$'\t' read -r line_no line; do
            [ -n "$line_no" ] || continue

            lhs="${line%%=*}"
            rhs="${line#*=}"

            lhs="$(printf '%s' "$lhs" | sed 's/[[:space:]]//g')"
            rhs="$(printf '%s' "$rhs" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

            if [ "$lhs" = "$key" ] || [ "$lhs" = "/$key" ]; then
                result="$f|$line_no|$rhs"
            fi
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
    done < <(
        get_sysctl_files |
        awk -F/ '
        {
            file=$0
            n=split(file,a,"/")
            dir=""
            for(i=1;i<n;i++)
                dir=dir "/" a[i]

            if (dir == "/etc/sysctl.d")
                p=4
            else if (dir == "/run/sysctl.d")
                p=3
            else if (dir == "/usr/local/lib/sysctl.d")
                p=2
            else if (dir == "/usr/lib/sysctl.d")
                p=1
            else
                p=0

            printf "%d\t%s\n",p,file
        }
        ' |
        sort -n -k1,1 -k2,2 |
        cut -f2-
    )

    if [ -n "$result" ]; then
        printf '%s\n' "$result"
    else
        printf 'NOT_FOUND||\n'
    fi
}

set_target_values() {
    local tmp
    local mode
    local owner
    local group

    tmp="$(mktemp "${TARGET}.tmp.XXXXXX")" || die "无法创建临时文件"

    mode="$(stat -c '%a' "$TARGET" 2>/dev/null || echo 644)"
    owner="$(stat -c '%u' "$TARGET" 2>/dev/null || echo 0)"
    group="$(stat -c '%g' "$TARGET" 2>/dev/null || echo 0)"

    # 完整拷贝原文件
    cp -p "$TARGET" "$tmp"

    # 动态遍历所有目标参数，使用 sed 强力清洗旧参数及特殊符号
    for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do
        local key="${TARGET_KEYS[$i]}"
        local val="${TARGET_VALUES[$i]}"

        sed -i -E "/^[[:space:]]*[#;-]*[[:space:]]*${key//./\.}[[:space:]]*=/d" "$tmp"
        echo "$key = $val" >> "$tmp"
    done

    chmod "$mode" "$tmp" || die "设置文件权限失败"
    chown "$owner:$group" "$tmp" 2>/dev/null || true

    if ! mv -f "$tmp" "$TARGET"; then
        rm -f "$tmp"
        die "修改 $TARGET 失败"
    fi
}


show_source() {
    local key="$1"
    local result

    result="$(find_effective_source "$key")"

    if [[ "$result" == NOT_FOUND* ]]; then
        echo "  持久化配置 : 未找到"
    else
        local file="${result%%|*}"
        local rest="${result#*|}"
        local line="${rest%%|*}"
        local value="${rest#*|}"

        echo "  配置文件   : $file"
        echo "  配置行     : $line"
        echo "  文件值     : $value"
    fi

    echo "  运行值     : $(get_sysctl "$key")"
}

echo "============================================================"
echo " Debian 13 双栈 TCP/UDP 网络调优"
echo " 审计 → 判断 → 确认 → 修改 → 应用 → 网络重启 → 验证"
echo "============================================================"
echo
echo "配置文件：$TARGET"
echo "不备份，不创建新的 sysctl.d 文件"
echo

# ============================================================
# 1. 系统
# ============================================================

echo "[1/10] 系统检测"

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    PRETTY_NAME="unknown"
fi

CPU="$(nproc 2>/dev/null || echo 1)"
RAM_KB="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
RAM_MB=$((RAM_KB / 1024))
SWAP_MB="$(free -m | awk '/^Swap:/ {print $3; exit}')"
KERNEL="$(uname -r)"

echo "  OS       : ${PRETTY_NAME:-unknown}"
echo "  Kernel   : $KERNEL"
echo "  CPU      : $CPU cores"
echo "  RAM      : $RAM_MB MB"
echo "  Swap     : $SWAP_MB MB（不修改）"
echo

# ============================================================
# 2. 网络
# ============================================================

echo "[2/10] IPv4 / IPv6 / TCP / UDP 检测"

IPV4_COUNT="$(ip -4 addr 2>/dev/null | awk '/inet / {c++} END {print c+0}')"
IPV6_COUNT="$(ip -6 addr 2>/dev/null | awk '/inet6 / {c++} END {print c+0}')"
IPV6_DISABLED="$(get_sysctl net.ipv6.conf.all.disable_ipv6)"

TCP_LISTEN="$(ss -Hln 2>/dev/null | awk '$1 ~ /^tcp/ {c++} END {print c+0}')"
TCP_EST="$(ss -Hnt 2>/dev/null | awk '$1 == "ESTAB" {c++} END {print c+0}')"
UDP_COUNT="$(ss -Hun 2>/dev/null | awk 'END {print NR+0}')"

DEFAULT_IF="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5; exit}')"

echo "  IPv4 地址        : $IPV4_COUNT"
echo "  IPv6 地址        : $IPV6_COUNT"
echo "  IPv6 disabled    : $IPV6_DISABLED"
echo "  TCP LISTEN       : $TCP_LISTEN"
echo "  TCP established   : $TCP_EST"
echo "  UDP sockets      : $UDP_COUNT"
echo "  默认网卡         : ${DEFAULT_IF:-unknown}"
echo

# ============================================================
# 3. SSH
# ============================================================

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

# ============================================================
# 4. CPU / RAM
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

# ============================================================
# 5. BBR / FQ / TFO
# ============================================================

echo "[5/10] BBR / FQ / TCP Fast Open"

CC="$(get_sysctl net.ipv4.tcp_congestion_control)"
AVAILABLE_CC="$(get_sysctl net.ipv4.tcp_available_congestion_control)"
QDISC="$(get_sysctl net.core.default_qdisc)"
TFO="$(get_sysctl net.ipv4.tcp_fastopen)"

BBR_SUPPORTED=0
BBR_SOURCE="no"

# 1. 检测当前可用算法中是否已包含 bbr (内核内置或已经挂载)
if echo "$AVAILABLE_CC" | tr ' ' '\n' | grep -qx bbr; then
    BBR_SUPPORTED=1
    BBR_SOURCE="yes (原生自带或已挂载)"
else
    # 2. 如果没有 bbr，尝试静默动态加载 tcp_bbr 模块
    if command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr 2>/dev/null; then
        AVAILABLE_CC="$(get_sysctl net.ipv4.tcp_available_congestion_control)"
        
        # 3. 再次校验，如果加载成功，说明是原版 Debian 的动态模块
        if echo "$AVAILABLE_CC" | tr ' ' '\n' | grep -qx bbr; then
            BBR_SUPPORTED=1
            BBR_SOURCE="yes (动态挂载成功)"
            
            # 4. 精准修改系统原生文件 /etc/modules 实现持久化
            if [ -w /etc/modules ]; then
                if ! grep -q "^tcp_bbr$" /etc/modules 2>/dev/null; then
                    echo "tcp_bbr" >> /etc/modules
                    BBR_SOURCE="yes (动态挂载，并已追加至 /etc/modules 持久化)"
                fi
            fi
        fi
    fi
fi

if [ -r /proc/sys/net/core/default_qdisc ]; then
    FQ_SUPPORTED=1
else
    FQ_SUPPORTED=0
fi

echo "  当前拥塞控制      : $CC"
echo "  可用拥塞控制      : $AVAILABLE_CC"
echo "  当前默认 qdisc    : $QDISC"
echo "  当前 TCP Fast Open : $TFO"
echo "  BBR 内核支持      : $BBR_SOURCE"


if [ "$FQ_SUPPORTED" -eq 1 ]; then
    echo "  FQ 配置接口       : yes"
else
    echo "  FQ 配置接口       : no"
fi

echo

# ============================================================
# 6. 网络压力
# ============================================================

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

# ============================================================
# 7. 当前参数
# ============================================================

echo "[7/10] 当前运行参数"

declare -A CURRENT

PARAMS=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_syncookies
    net.core.somaxconn
    net.ipv4.tcp_max_syn_backlog
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

printf '  default_qdisc       : %s\n' "${CURRENT[net.core.default_qdisc]}"
printf '  congestion_control  : %s\n' "${CURRENT[net.ipv4.tcp_congestion_control]}"
printf '  tcp_fastopen        : %s\n' "${CURRENT[net.ipv4.tcp_fastopen]}"
printf '  tcp_syncookies      : %s\n' "${CURRENT[net.ipv4.tcp_syncookies]}"
printf '  tcp_max_syn_backlog : %s\n' "${CURRENT[net.ipv4.tcp_max_syn_backlog]}"
printf '  somaxconn            : %s\n' "${CURRENT[net.core.somaxconn]}"
printf '  netdev_max_backlog   : %s\n' "${CURRENT[net.core.netdev_max_backlog]}"
printf '  tcp_window_scaling   : %s\n' "${CURRENT[net.ipv4.tcp_window_scaling]}"
printf '  tcp_sack             : %s\n' "${CURRENT[net.ipv4.tcp_sack]}"
printf '  tcp_timestamps       : %s\n' "${CURRENT[net.ipv4.tcp_timestamps]}"
printf '  tcp_ecn              : %s\n' "${CURRENT[net.ipv4.tcp_ecn]}"
printf '  tcp_mtu_probing      : %s\n' "${CURRENT[net.ipv4.tcp_mtu_probing]}"
printf '  tcp_fin_timeout      : %s\n' "${CURRENT[net.ipv4.tcp_fin_timeout]}"
printf '  tcp_keepalive_time   : %s\n' "${CURRENT[net.ipv4.tcp_keepalive_time]}"
printf '  tcp_max_tw_buckets   : %s\n' "${CURRENT[net.ipv4.tcp_max_tw_buckets]}"
printf '  ip_local_port_range  : %s\n' "${CURRENT[net.ipv4.ip_local_port_range]}"
echo

# ============================================================
# 8. sysctl 文件
# ============================================================

echo "[8/10] systemd-sysctl 配置文件"

mapfile -t SYSCTL_FILES < <(
    get_sysctl_files | sort -V -u
)

for f in "${SYSCTL_FILES[@]}"; do
    echo "    $f"
done

echo

echo "  bpftune : $(command -v bpftune >/dev/null 2>&1 && echo 已安装 || echo 未安装)"
echo

# ============================================================
# 9. 自动目标
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
        net.ipv4.tcp_congestion_control \
        bbr \
        "内核支持 BBR，当前不是 BBR"
else
    echo "  - BBR 不可用"
fi

# FQ
if [ "$QDISC" = "fq" ]; then
    echo "  ✓ default_qdisc 已为 fq"
elif [ "$FQ_SUPPORTED" -eq 1 ]; then
    add_target \
        net.core.default_qdisc \
        fq \
        "BBR 推荐配合 fq"
else
    echo "  - 无法确认 fq 支持"
fi

# TFO
if [ "$TFO" = "3" ]; then
    echo "  ✓ tcp_fastopen 已为 3"
elif [ "$TFO" = "0" ] || [ "$TFO" = "1" ] || [ "$TFO" = "2" ]; then
    add_target \
        net.ipv4.tcp_fastopen \
        3 \
        "启用 TCP client/server Fast Open"
else
    echo "  - tcp_fastopen 当前值异常：$TFO"
fi

# SYN backlog
BACKLOG="${CURRENT[net.ipv4.tcp_max_syn_backlog]}"

if is_number "$BACKLOG" && [ "$BACKLOG" -lt 4096 ]; then
    add_target \
        net.ipv4.tcp_max_syn_backlog \
        4096 \
        "SYN backlog 偏低"
else
    echo "  ✓ tcp_max_syn_backlog 不调整"
fi

# somaxconn
SOMAX="${CURRENT[net.core.somaxconn]}"

if is_number "$SOMAX" && [ "$SOMAX" -lt 4096 ]; then
    add_target \
        net.core.somaxconn \
        4096 \
        "监听队列上限偏低"
else
    echo "  ✓ somaxconn 不调整"
fi

# netdev backlog
NETDEV="${CURRENT[net.core.netdev_max_backlog]}"

if is_number "$softnet_delta" &&
   [ "$softnet_delta" -gt 0 ] &&
   is_number "$NETDEV" &&
   [ "$NETDEV" -lt 4096 ]; then

    add_target \
        net.core.netdev_max_backlog \
        4096 \
        "检测到 softnet drops"
else
    echo "  ✓ netdev_max_backlog 不调整"
fi

# 临时端口
PORT_RANGE="${CURRENT[net.ipv4.ip_local_port_range]}"
PORT_HIGH="$(printf '%s\n' "$PORT_RANGE" | awk '{print $2}')"

if is_number "$PORT_HIGH" && [ "$PORT_HIGH" -lt 60999 ]; then
    add_target \
        net.ipv4.ip_local_port_range \
        "1024 65535" \
        "临时端口范围偏小"
else
    echo "  ✓ ip_local_port_range 不调整"
fi

# MTU probing
MTU="${CURRENT[net.ipv4.tcp_mtu_probing]}"

if [ "$MTU" = "1" ]; then
    echo "  ✓ tcp_mtu_probing 已为 1"
elif [ "$MTU" = "0" ] || [ "$MTU" = "2" ]; then
    add_target \
        net.ipv4.tcp_mtu_probing \
        1 \
        "降低 PMTU black-hole 导致连接异常的风险"
else
    echo "  - tcp_mtu_probing 当前值异常：$MTU"
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
# 10. 持久化来源审计
# ============================================================

echo "[10/10] 参数持久化来源审计"
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

for key in "${SOURCE_KEYS[@]}"; do
    echo "[$key]"
    show_source "$key"
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

    if has_key_in_target "$key"; then
        echo "    配置文件   : 已存在 → 修改"
    elif has_commented_key_in_target "$key"; then
        echo "    配置文件   : 注释项 → 启用并修改"
    else
        echo "    配置文件   : 不存在 → 追加"
    fi

    echo
    CHANGES=$((CHANGES + 1))
done

if [ "$CHANGES" -eq 0 ]; then
    echo -e "${GREEN}✓ 没有需要修改的参数。${NC}"
    exit 0
fi

echo "============================================================"
echo "                         不会修改"
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
echo "  ✓ 不执行 sysctl -w"
echo "  ✓ 不创建新的 sysctl.d 文件"
echo "  ✓ 不备份"
echo

# ============================================================
# 确认
# ============================================================

echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo
echo "本次需要修改：$CHANGES 项"
echo
echo "确认后："
echo "  1. 修改 $TARGET"
echo "  2. 校验目标参数"
echo "  3. systemctl restart systemd-sysctl"
echo "  4. 检查 networking.service"
echo "  5. 如 networking.service 正在运行 → restart networking"
echo "  6. 验证最终运行值"
echo
echo -e "${YELLOW}⚠ 当前为 SSH 远程会话，重启网络可能导致 SSH 短暂断开。${NC}"
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
echo "                         开始修改"
echo "============================================================"
echo

set_target_values

echo "✓ $TARGET 修改完成"

# ============================================================
# 修改后检查
# ============================================================

echo
echo "检查配置："

CONFIG_OK=1

for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do
    key="${TARGET_KEYS[$i]}"
    expected="${TARGET_VALUES[$i]}"

    actual="$(
        awk -v k="$key" '
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)

            if (line == "" || line ~ /^#/ || line ~ /^;/)
                next

            split(line,a,"=")
            lhs=a[1]
            rhs=a[2]

            gsub(/[[:space:]]/, "", lhs)

            if (lhs == k || lhs == "/" k) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
                value=rhs
            }
        }
        END {
            if (value != "")
                print value
        }
        ' "$TARGET"
    )"

    if [ "$(trim "$actual")" = "$(trim "$expected")" ]; then
        echo "  ✓ $key = $expected"
    else
        echo "  ✗ $key"
        echo "    期望：$expected"
        echo "    实际：$actual"
        CONFIG_OK=0
    fi
done

[ "$CONFIG_OK" -eq 1 ] || die "配置文件校验失败，停止执行"

# ============================================================
# 应用 systemd-sysctl
# ============================================================

echo
echo "============================================================"
echo "                     应用 sysctl 配置"
echo "============================================================"

if systemctl restart systemd-sysctl; then
    echo -e "${GREEN}✓ systemd-sysctl 应用成功${NC}"
else
    echo -e "${RED}✗ systemd-sysctl 应用失败${NC}"
    exit 1
fi

# ============================================================
# 网络服务判断
# ============================================================

echo
echo "============================================================"
echo "                     检查网络服务"
echo "============================================================"

NETWORKING_EXISTS=0
NETWORKING_ACTIVE=0

if systemctl cat networking.service >/dev/null 2>&1; then
    NETWORKING_EXISTS=1
fi

if [ "$NETWORKING_EXISTS" -eq 1 ] &&
   systemctl is-active --quiet networking.service; then
    NETWORKING_ACTIVE=1
fi

if [ "$NETWORKING_EXISTS" -eq 1 ]; then
    echo "  networking.service : 存在"
else
    echo "  networking.service : 不存在"
fi

if [ "$NETWORKING_ACTIVE" -eq 1 ]; then
    echo "  状态               : active"
else
    echo "  状态               : 非 active"
fi

if [ "$NETWORKING_ACTIVE" -eq 1 ]; then
    echo
    echo -e "${YELLOW}正在执行：systemctl restart networking${NC}"

    if systemctl restart networking; then
        echo -e "${GREEN}✓ networking 重启成功${NC}"
    else
        echo -e "${RED}✗ networking 重启失败${NC}"
        echo "  sysctl 配置已经写入并已由 systemd-sysctl 应用。"
        exit 1
    fi
else
    echo "  → 跳过 networking 重启"
fi

# ============================================================
# 最终验证
# ============================================================

echo
echo "============================================================"
echo "                         最终验证"
echo "============================================================"
echo

VERIFY_OK=1

for ((i=0; i<${#TARGET_KEYS[@]}; i++)); do
    key="${TARGET_KEYS[$i]}"
    expected="${TARGET_VALUES[$i]}"
    actual="$(get_sysctl "$key")"

    if [ "$(trim "$actual")" = "$(trim "$expected")" ]; then
        echo -e "${GREEN}✓ $key = $actual${NC}"
    else
        echo -e "${RED}✗ $key${NC}"
        echo "    期望 : $expected"
        echo "    实际 : $actual"
        VERIFY_OK=0
    fi
done

echo
echo "------------------------------------------------------------"

if [ "$VERIFY_OK" -eq 1 ]; then
    echo -e "${GREEN}✓ 所有本次修改参数均已生效${NC}"
else
    echo -e "${RED}✗ 部分参数未达到目标值${NC}"
    exit 1
fi

echo "------------------------------------------------------------"
echo
echo "最终状态："
echo "  default_qdisc      : $(get_sysctl net.core.default_qdisc)"
echo "  congestion_control : $(get_sysctl net.ipv4.tcp_congestion_control)"
echo "  tcp_fastopen       : $(get_sysctl net.ipv4.tcp_fastopen)"
echo "  syn_backlog        : $(get_sysctl net.ipv4.tcp_max_syn_backlog)"
echo "  mtu_probing        : $(get_sysctl net.ipv4.tcp_mtu_probing)"
echo
echo -e "${GREEN}完成。${NC}"
