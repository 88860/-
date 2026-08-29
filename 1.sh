#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C

[[ $EUID -eq 0 ]] || {
    echo "错误：请使用 root 运行。"
    exit 1
}

source /etc/os-release

if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "13" ]]; then
    echo "错误：此脚本仅支持 Debian 13。"
    echo "当前系统：${PRETTY_NAME:-unknown}"
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
CYAN=$'\033[36m'
RESET=$'\033[0m'

info() {
    printf '%b\n' "${CYAN}$*${RESET}"
}

ok() {
    printf '%b\n' "${GREEN}✓ $*${RESET}"
}

warn() {
    printf '%b\n' "${YELLOW}⚠ $*${RESET}"
}

fail() {
    printf '%b\n' "${RED}✗ $*${RESET}"
}

sysctl_get() {
    sysctl -n "$1" 2>/dev/null || true
}

is_number() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

echo
echo "============================================================"
echo " Debian 13 / sing-box 双栈网络调优"
echo " 只读审计 → 确认 → 持久化修改"
echo "============================================================"
echo

# ============================================================
# 1. 系统检测
# ============================================================

info "[1/8] 系统检测"

KERNEL=$(uname -r)
CPU=$(nproc 2>/dev/null || echo 1)
MEM_KB=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
MEM_MB=$((MEM_KB / 1024))
SWAP_KB=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo)
SWAP_MB=$((SWAP_KB / 1024))

printf "  OS       : %s\n" "${PRETTY_NAME:-unknown}"
printf "  Kernel   : %s\n" "$KERNEL"
printf "  CPU      : %s cores\n" "$CPU"
printf "  RAM      : %s MB\n" "$MEM_MB"
printf "  Swap     : %s MB（不修改）\n" "$SWAP_MB"

# ============================================================
# 2. 双栈 / TCP / UDP
# ============================================================

info "[2/8] IPv4 / IPv6 / TCP / UDP 检测"

IPV4_COUNT=$(ip -4 addr show scope global 2>/dev/null | grep -c 'inet ' || true)
IPV6_COUNT=$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6 ' || true)

IPV6_DISABLED=$(sysctl_get net.ipv6.conf.all.disable_ipv6)

TCP_LISTEN=$(ss -Hlt 2>/dev/null | wc -l)
TCP_ESTABLISHED=$(ss -Htan state established 2>/dev/null | wc -l)
UDP_SOCKET=$(ss -Huan 2>/dev/null | wc -l)

DEFAULT_IF=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')

printf "  IPv4 地址        : %s\n" "$IPV4_COUNT"
printf "  IPv6 地址        : %s\n" "$IPV6_COUNT"
printf "  IPv6 disabled    : %s\n" "${IPV6_DISABLED:-unknown}"
printf "  TCP LISTEN       : %s\n" "$TCP_LISTEN"
printf "  TCP established  : %s\n" "$TCP_ESTABLISHED"
printf "  UDP sockets      : %s\n" "$UDP_SOCKET"
printf "  默认网卡         : %s\n" "${DEFAULT_IF:-unknown}"

# ============================================================
# 3. SSH 检测
# ============================================================

info "[3/8] SSH 会话检测"

SSH_ACTIVE=0

if [[ -n "${SSH_CONNECTION:-}" ]]; then
    SSH_ACTIVE=1

    SSH_REMOTE_IP=$(awk '{print $1}' <<< "$SSH_CONNECTION")
    SSH_REMOTE_PORT=$(awk '{print $2}' <<< "$SSH_CONNECTION")
    SSH_LOCAL_IP=$(awk '{print $3}' <<< "$SSH_CONNECTION")
    SSH_LOCAL_PORT=$(awk '{print $4}' <<< "$SSH_CONNECTION")

    ok "检测到当前 SSH 远程会话"

    printf "  远端 IP     : %s\n" "$SSH_REMOTE_IP"
    printf "  远端端口    : %s\n" "$SSH_REMOTE_PORT"
    printf "  本地地址    : %s\n" "$SSH_LOCAL_IP"
    printf "  本地端口    : %s\n" "$SSH_LOCAL_PORT"
else
    warn "当前不是 SSH 会话。"
fi

# ============================================================
# 4. BBR / FQ / TFO
# ============================================================

info "[4/8] BBR / FQ / TCP Fast Open 检测"

CURRENT_CC=$(sysctl_get net.ipv4.tcp_congestion_control)
AVAILABLE_CC=$(sysctl_get net.ipv4.tcp_available_congestion_control)
CURRENT_QDISC=$(sysctl_get net.core.default_qdisc)
CURRENT_TFO=$(sysctl_get net.ipv4.tcp_fastopen)

BBR_SUPPORTED=0
FQ_SUPPORTED=0

if grep -qw 'bbr' <<< "${AVAILABLE_CC:-}"; then
    BBR_SUPPORTED=1
fi

if modinfo tcp_bbr >/dev/null 2>&1; then
    BBR_SUPPORTED=1
fi

if modinfo sch_fq >/dev/null 2>&1; then
    FQ_SUPPORTED=1
fi

printf "  当前拥塞控制      : %s\n" "${CURRENT_CC:-unknown}"
printf "  可用拥塞控制      : %s\n" "${AVAILABLE_CC:-unknown}"
printf "  当前默认 qdisc    : %s\n" "${CURRENT_QDISC:-unknown}"
printf "  当前 TCP Fast Open : %s\n" "${CURRENT_TFO:-unknown}"
printf "  BBR 内核支持      : %s\n" "$([[ $BBR_SUPPORTED == 1 ]] && echo yes || echo no)"
printf "  FQ 内核支持       : %s\n" "$([[ $FQ_SUPPORTED == 1 ]] && echo yes || echo no)"

# ============================================================
# 5. 实际网络压力
# ============================================================

info "[5/8] 网络实际压力检测"

read_softnet_dropped() {
    awk '
    {
        if (NF >= 2) {
            v = "0x" $2
            cmd = "printf \"%d\" " v
            cmd | getline n
            close(cmd)
            total += n
        }
    }
    END {
        print total + 0
    }
    ' /proc/net/softnet_stat 2>/dev/null || echo 0
}

SOFTNET_1=$(read_softnet_dropped)

if [[ -n "${DEFAULT_IF:-}" &&
      -d "/sys/class/net/$DEFAULT_IF/statistics" ]]; then

    IFSTAT="/sys/class/net/$DEFAULT_IF/statistics"

    RX_DROP_1=$(cat "$IFSTAT/rx_dropped" 2>/dev/null || echo 0)
    TX_DROP_1=$(cat "$IFSTAT/tx_dropped" 2>/dev/null || echo 0)
else
    RX_DROP_1=0
    TX_DROP_1=0
fi

sleep 3

SOFTNET_2=$(read_softnet_dropped)

if [[ -n "${DEFAULT_IF:-}" &&
      -d "/sys/class/net/$DEFAULT_IF/statistics" ]]; then

    RX_DROP_2=$(cat "$IFSTAT/rx_dropped" 2>/dev/null || echo 0)
    TX_DROP_2=$(cat "$IFSTAT/tx_dropped" 2>/dev/null || echo 0)
else
    RX_DROP_2=0
    TX_DROP_2=0
fi

SOFTNET_DELTA=$((SOFTNET_2 - SOFTNET_1))
RX_DROP_DELTA=$((RX_DROP_2 - RX_DROP_1))
TX_DROP_DELTA=$((TX_DROP_2 - TX_DROP_1))

(( SOFTNET_DELTA < 0 )) && SOFTNET_DELTA=0
(( RX_DROP_DELTA < 0 )) && RX_DROP_DELTA=0
(( TX_DROP_DELTA < 0 )) && TX_DROP_DELTA=0

printf "  softnet drops / 3s : %s\n" "$SOFTNET_DELTA"
printf "  RX drops / 3s      : %s\n" "$RX_DROP_DELTA"
printf "  TX drops / 3s      : %s\n" "$TX_DROP_DELTA"

# ============================================================
# 6. 当前参数
# ============================================================

info "[6/8] 当前网络参数"

CURRENT_SYNCOOKIES=$(sysctl_get net.ipv4.tcp_syncookies)
CURRENT_SOMAX=$(sysctl_get net.core.somaxconn)
CURRENT_SYN_BACKLOG=$(sysctl_get net.ipv4.tcp_max_syn_backlog)
CURRENT_NETDEV_BACKLOG=$(sysctl_get net.core.netdev_max_backlog)

printf "  tcp_syncookies      : %s\n" "${CURRENT_SYNCOOKIES:-unknown}"
printf "  somaxconn            : %s\n" "${CURRENT_SOMAX:-unknown}"
printf "  tcp_max_syn_backlog  : %s\n" "${CURRENT_SYN_BACKLOG:-unknown}"
printf "  netdev_max_backlog   : %s\n" "${CURRENT_NETDEV_BACKLOG:-unknown}"

# ============================================================
# 7. systemd-sysctl 配置文件
# ============================================================

info "[7/8] 检测 systemd-sysctl 配置来源"

declare -A CONFIG_FILES

SYSCTL_DIRS=(
    "/etc/sysctl.d"
    "/run/sysctl.d"
    "/usr/local/lib/sysctl.d"
    "/usr/lib/sysctl.d"
)

for DIR in "${SYSCTL_DIRS[@]}"; do
    [[ -d "$DIR" ]] || continue

    while IFS= read -r FILE; do
        NAME=$(basename "$FILE")

        # 同名文件：
        # /etc > /run > /usr/local/lib > /usr/lib
        if [[ -z "${CONFIG_FILES[$NAME]+x}" ]]; then
            CONFIG_FILES["$NAME"]="$FILE"
        fi
    done < <(
        find "$DIR" \
            -maxdepth 1 \
            -type f \
            -name '*.conf' \
            -print 2>/dev/null
    )
done

EFFECTIVE_LIST="$TMP_DIR/effective.list"

for NAME in "${!CONFIG_FILES[@]}"; do
    printf '%s\t%s\n' "$NAME" "${CONFIG_FILES[$NAME]}"
done |
    sort -k1,1 > "$EFFECTIVE_LIST"

echo
echo "  systemd-sysctl 配置文件："

while IFS=$'\t' read -r NAME FILE; do
    printf "    %-35s %s\n" "$NAME" "$FILE"
done < "$EFFECTIVE_LIST"

# ============================================================
# 8. 精确寻找最终生效配置
# ============================================================

info "[8/8] 精确解析参数来源"

declare -A ACTIVE_FILE
declare -A ACTIVE_LINE
declare -A COMMENT_FILE
declare -A COMMENT_LINE

find_key_in_file() {
    local KEY="$1"
    local FILE="$2"

    awk -v key="$KEY" '
    {
        line=$0
        trimmed=line

        sub(/^[[:space:]]+/, "", trimmed)

        commented=0

        if (trimmed ~ /^#/) {
            commented=1
            sub(/^#[[:space:]]*/, "", trimmed)
        }
        else if (trimmed ~ /^;/) {
            commented=1
            sub(/^;[[:space:]]*/, "", trimmed)
        }

        # systemd-sysctl 支持前导 "-"
        sub(/^-[[:space:]]*/, "", trimmed)

        if (
            trimmed ~ (
                "^[[:space:]]*" key "[[:space:]]*="
            )
        ) {
            print NR "|" commented
        }
    }
    ' "$FILE"
}

TARGET_KEYS=(
    "net.ipv4.tcp_congestion_control"
    "net.core.default_qdisc"
    "net.ipv4.tcp_fastopen"
    "net.ipv4.tcp_syncookies"
    "net.core.somaxconn"
    "net.ipv4.tcp_max_syn_backlog"
)

TARGET_BBR="bbr"
TARGET_QDISC="fq"
TARGET_TFO="3"
TARGET_SYNCOOKIES="1"
TARGET_SOMAX="4096"
TARGET_SYN_BACKLOG="4096"

for KEY in "${TARGET_KEYS[@]}"; do

    ACTIVE_FILE["$KEY"]=""
    ACTIVE_LINE["$KEY"]=""

    COMMENT_FILE["$KEY"]=""
    COMMENT_LINE["$KEY"]=""

    while IFS=$'\t' read -r NAME FILE; do

        [[ -f "$FILE" ]] || continue

        while IFS='|' read -r LINE COMMENTED; do

            [[ -n "$LINE" ]] || continue

            if [[ "$COMMENTED" == "0" ]]; then

                # 后面的配置覆盖前面的配置
                ACTIVE_FILE["$KEY"]="$FILE"
                ACTIVE_LINE["$KEY"]="$LINE"

            elif [[ -z "${COMMENT_FILE[$KEY]}" ]]; then

                COMMENT_FILE["$KEY"]="$FILE"
                COMMENT_LINE["$KEY"]="$LINE"

            fi

        done < <(
            find_key_in_file "$KEY" "$FILE"
        )

    done < "$EFFECTIVE_LIST"

done

echo
echo "------------------------------------------------------------"
echo " 参数最终配置来源"
echo "------------------------------------------------------------"

for KEY in "${TARGET_KEYS[@]}"; do

    echo
    echo "[$KEY]"

    if [[ -n "${ACTIVE_FILE[$KEY]}" ]]; then

        printf "  生效配置 : %s:%s\n" \
            "${ACTIVE_FILE[$KEY]}" \
            "${ACTIVE_LINE[$KEY]}"

    elif [[ -n "${COMMENT_FILE[$KEY]}" ]]; then

        printf "  注释配置 : %s:%s\n" \
            "${COMMENT_FILE[$KEY]}" \
            "${COMMENT_LINE[$KEY]}"

    else

        echo "  配置文件 : 未找到"

    fi

done

# ============================================================
# 生成修改计划
# ============================================================

echo
echo "============================================================"
echo "                      审计结果"
echo "============================================================"

declare -a CHANGES=()

add_change() {

    local KEY="$1"
    local CURRENT="$2"
    local TARGET="$3"

    local FILE="${ACTIVE_FILE[$KEY]:-}"
    local LINE="${ACTIVE_LINE[$KEY]:-}"

    local CFILE="${COMMENT_FILE[$KEY]:-}"
    local CLINE="${COMMENT_LINE[$KEY]:-}"

    if [[ "$CURRENT" == "$TARGET" ]]; then

        ok "$KEY：当前已经是 $TARGET，不修改。"
        return

    fi

    if [[ -n "$FILE" ]]; then

        CHANGES+=(
            "$KEY|$CURRENT|$TARGET|$FILE|$LINE|active"
        )

        warn "$KEY：$CURRENT → $TARGET"
        echo "    精准修改：$FILE:$LINE"

    elif [[ -n "$CFILE" ]]; then

        CHANGES+=(
            "$KEY|$CURRENT|$TARGET|$CFILE|$CLINE|commented"
        )

        warn "$KEY：$CURRENT → $TARGET"
        echo "    解除注释并修改：$CFILE:$CLINE"

    else

        CHANGES+=(
            "$KEY|$CURRENT|$TARGET|/etc/sysctl.d/90-singbox.conf|0|new"
        )

        warn "$KEY：$CURRENT → $TARGET"
        echo "    新增：/etc/sysctl.d/90-singbox.conf"

    fi
}

echo
echo "[BBR / FQ / TFO]"

if [[ "$BBR_SUPPORTED" == 1 ]]; then
    add_change \
        "net.ipv4.tcp_congestion_control" \
        "$CURRENT_CC" \
        "$TARGET_BBR"
else
    warn "内核不支持 BBR，不修改。"
fi

if [[ "$FQ_SUPPORTED" == 1 ]]; then
    add_change \
        "net.core.default_qdisc" \
        "$CURRENT_QDISC" \
        "$TARGET_QDISC"
else
    warn "内核不支持 sch_fq，不修改。"
fi

add_change \
    "net.ipv4.tcp_fastopen" \
    "$CURRENT_TFO" \
    "$TARGET_TFO"

echo
echo "[TCP 连接参数]"

add_change \
    "net.ipv4.tcp_syncookies" \
    "$CURRENT_SYNCOOKIES" \
    "$TARGET_SYNCOOKIES"

if is_number "$CURRENT_SOMAX" &&
   (( CURRENT_SOMAX < 4096 )); then

    add_change \
        "net.core.somaxconn" \
        "$CURRENT_SOMAX" \
        "$TARGET_SOMAX"

else

    ok "net.core.somaxconn：$CURRENT_SOMAX，不修改。"

fi

if is_number "$CURRENT_SYN_BACKLOG" &&
   (( CURRENT_SYN_BACKLOG < 4096 )); then

    add_change \
        "net.ipv4.tcp_max_syn_backlog" \
        "$CURRENT_SYN_BACKLOG" \
        "$TARGET_SYN_BACKLOG"

else

    ok "net.ipv4.tcp_max_syn_backlog：$CURRENT_SYN_BACKLOG，不修改。"

fi

echo
echo "[网络队列]"

if is_number "$CURRENT_NETDEV_BACKLOG"; then

    if (( SOFTNET_DELTA > 0 )); then

        warn "检测到 softnet drops：$SOFTNET_DELTA / 3s"
        echo "    当前 netdev_max_backlog：$CURRENT_NETDEV_BACKLOG"
        echo "    本脚本不会根据一次短采样自动修改。"

    else

        ok "没有检测到 softnet drops，不修改 netdev_max_backlog。"

    fi

else

    warn "无法读取 net.core.netdev_max_backlog。"

fi

# ============================================================
# 明确不会修改
# ============================================================

echo
echo "------------------------------------------------------------"
echo " 本脚本明确不会修改"
echo "------------------------------------------------------------"

echo "  swap"
echo "  vm.*"
echo "  IPv4 forwarding"
echo "  IPv6 forwarding"
echo "  IPv6 disable"
echo "  TCP rmem / wmem / tcp_mem"
echo "  UDP rmem / wmem"
echo "  TCP keepalive"
echo "  TCP FIN timeout"
echo "  TCP MTU probing"
echo "  TCP ECN"
echo "  netdev_budget"
echo "  netdev_budget_usecs"
echo "  SSH 服务"
echo "  网络服务"
echo "  systemd-sysctl 重载"
echo "  VPS 重启"

# ============================================================
# 无修改
# ============================================================

if (( ${#CHANGES[@]} == 0 )); then

    echo
    ok "审计完成：没有需要修改的核心参数。"
    echo
    echo "系统没有发生任何修改。"
    exit 0

fi

# ============================================================
# 修改确认
# ============================================================

echo
echo "============================================================"
echo "                       待修改项目"
echo "============================================================"

for ITEM in "${CHANGES[@]}"; do

    IFS='|' read -r \
        KEY CURRENT TARGET FILE LINE TYPE <<< "$ITEM"

    printf "  %-38s %s → %s\n" \
        "$KEY" \
        "$CURRENT" \
        "$TARGET"

    case "$TYPE" in

        active)
            echo "    修改：$FILE:$LINE"
            ;;

        commented)
            echo "    解除注释并修改：$FILE:$LINE"
            ;;

        new)
            echo "    新增：$FILE"
            ;;

    esac

done

echo
echo "============================================================"
echo "重要：确认后只修改持久化配置。"
echo
echo "本脚本不会执行："
echo "  sysctl -w"
echo "  modprobe"
echo "  systemctl restart systemd-sysctl"
echo "  systemctl restart networking"
echo "  systemctl restart NetworkManager"
echo "  systemctl restart ssh"
echo "  reboot"
echo "============================================================"
echo

read -r -p "确认执行以上修改？[y/N] " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

    echo
    ok "已取消。系统没有发生任何修改。"
    exit 0

fi

# ============================================================
# 精准写入函数
# ============================================================

write_precise() {

    local KEY="$1"
    local VALUE="$2"

    local FILE="${ACTIVE_FILE[$KEY]:-}"
    local LINE="${ACTIVE_LINE[$KEY]:-}"

    local CFILE="${COMMENT_FILE[$KEY]:-}"
    local CLINE="${COMMENT_LINE[$KEY]:-}"

    # --------------------------------------------------------
    # 已存在有效配置
    # --------------------------------------------------------

    if [[ -n "$FILE" && -n "$LINE" ]]; then

        awk \
            -v target="$LINE" \
            -v key="$KEY" \
            -v value="$VALUE" '

        NR == target {

            indent=$0
            sub(/[^[:space:]].*$/, "", indent)

            print indent key " = " value
            next
        }

        {
            print
        }

        ' "$FILE" > "$TMP_DIR/modified"

        cat "$TMP_DIR/modified" > "$FILE"

        ok "$KEY → $VALUE"
        echo "    已精准修改：$FILE:$LINE"

        return
    fi

    # --------------------------------------------------------
    # 已存在注释配置
    # --------------------------------------------------------

    if [[ -n "$CFILE" && -n "$CLINE" ]]; then

        awk \
            -v target="$CLINE" \
            -v key="$KEY" \
            -v value="$VALUE" '

        NR == target {

            indent=$0
            sub(/[^[:space:]].*$/, "", indent)

            print indent key " = " value
            next
        }

        {
            print
        }

        ' "$CFILE" > "$TMP_DIR/modified"

        cat "$TMP_DIR/modified" > "$CFILE"

        ACTIVE_FILE["$KEY"]="$CFILE"
        ACTIVE_LINE["$KEY"]="$CLINE"

        ok "$KEY → $VALUE"
        echo "    已解除注释并精准修改：$CFILE:$CLINE"

        return
    fi

    # --------------------------------------------------------
    # 完全不存在
    # --------------------------------------------------------

    FILE="/etc/sysctl.d/90-singbox.conf"

    touch "$FILE"

    if grep -qE \
        "^[[:space:]]*${KEY//./\\.}[[:space:]]*=" \
        "$FILE"; then

        sed -i -E \
            "s|^[[:space:]]*${KEY//./\\.}[[:space:]]*=.*$|${KEY} = ${VALUE}|" \
            "$FILE"

    else

        printf '%s = %s\n' \
            "$KEY" \
            "$VALUE" >> "$FILE"

    fi

    ok "$KEY → $VALUE"
    echo "    已写入：$FILE"
}

# ============================================================
# 开始持久化修改
# ============================================================

echo
echo "============================================================"
echo "                       开始修改"
echo "============================================================"

for ITEM in "${CHANGES[@]}"; do

    IFS='|' read -r \
        KEY CURRENT TARGET FILE LINE TYPE <<< "$ITEM"

    case "$KEY" in

        net.ipv4.tcp_congestion_control)

            [[ "$BBR_SUPPORTED" == 1 ]] || continue
            ;;

        net.core.default_qdisc)

            [[ "$FQ_SUPPORTED" == 1 ]] || continue
            ;;

    esac

    write_precise "$KEY" "$TARGET"

done

# ============================================================
# 模块持久化
# ============================================================

MODULE_FILE="/etc/modules-load.d/singbox-network.conf"

{
    echo "# sing-box network modules"

    if [[ "$BBR_SUPPORTED" == 1 ]]; then
        echo "tcp_bbr"
    fi

    if [[ "$FQ_SUPPORTED" == 1 ]]; then
        echo "sch_fq"
    fi

} > "$MODULE_FILE"

ok "内核模块持久化配置：$MODULE_FILE"

# ============================================================
# 验证持久化文件
# ============================================================

echo
echo "============================================================"
echo "                     持久化配置验证"
echo "============================================================"

VERIFY_FILE="/etc/sysctl.d/90-singbox.conf"

if [[ -f "$VERIFY_FILE" ]]; then

    echo
    echo "[$VERIFY_FILE]"

    grep -E \
        '^(net\.ipv4\.tcp_congestion_control|net\.core\.default_qdisc|net\.ipv4\.tcp_fastopen|net\.ipv4\.tcp_syncookies|net\.core\.somaxconn|net\.ipv4\.tcp_max_syn_backlog)[[:space:]]*=' \
        "$VERIFY_FILE" 2>/dev/null || true

fi

echo
echo "[$MODULE_FILE]"

cat "$MODULE_FILE"

# ============================================================
# 当前运行状态
# ============================================================

echo
echo "============================================================"
echo "                     当前运行状态"
echo "============================================================"

echo "注意：本脚本没有即时 reload sysctl。"
echo "因此下面显示的是当前内核运行值，而不是重启后的最终值。"
echo

printf "  当前 BBR              : %s\n" \
    "$(sysctl_get net.ipv4.tcp_congestion_control)"

printf "  当前 qdisc             : %s\n" \
    "$(sysctl_get net.core.default_qdisc)"

printf "  当前 TCP Fast Open     : %s\n" \
    "$(sysctl_get net.ipv4.tcp_fastopen)"

printf "  当前 SYN cookies       : %s\n" \
    "$(sysctl_get net.ipv4.tcp_syncookies)"

printf "  当前 somaxconn         : %s\n" \
    "$(sysctl_get net.core.somaxconn)"

printf "  当前 tcp_max_syn_backlog : %s\n" \
    "$(sysctl_get net.ipv4.tcp_max_syn_backlog)"

echo
echo "============================================================"
echo "                       修改完成"
echo "============================================================"

if [[ "$SSH_ACTIVE" == 1 ]]; then
    ok "当前 SSH 会话未被脚本主动重启或切断。"
fi

echo
echo "新的 sysctl 配置将在下次系统正常启动时由 systemd-sysctl 应用。"
echo "BBR/FQ 模块将在下次启动时由 modules-load.d 加载。"
echo
echo "当前会话无需重启。"
echo
