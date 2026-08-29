#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C

# ============================================================
# Debian 13 双栈 TCP/UDP 网络调优
# 只读审计 → 显示实际配置来源 → 人工确认 → 精准修改
#
# 重要：
# 1. 绝不创建新的 sysctl 配置文件
# 2. 只修改现有的 systemd-sysctl 配置文件
# 3. 不执行 sysctl -w
# 4. 不 reload systemd-sysctl
# 5. 不 modprobe
# 6. 不重启网络/SSH
# ============================================================

[[ $EUID -eq 0 ]] || {
    echo "错误：必须使用 root 运行。"
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

ok() {
    printf '%b\n' "${GREEN}✓ $*${RESET}"
}

warn() {
    printf '%b\n' "${YELLOW}⚠ $*${RESET}"
}

info() {
    printf '%b\n' "${CYAN}$*${RESET}"
}

error() {
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
echo " Debian 13 双栈 TCP/UDP 网络调优"
echo " 只读审计 → 配置来源 → 人工确认 → 精准持久化修改"
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
# 2. IPv4 / IPv6 / TCP / UDP
# ============================================================

info "[2/8] IPv4 / IPv6 / TCP / UDP 检测"

IPV4_COUNT=$(ip -4 addr show scope global 2>/dev/null | grep -c 'inet ' || true)
IPV6_COUNT=$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6 ' || true)

IPV6_DISABLED=$(sysctl_get net.ipv6.conf.all.disable_ipv6)

TCP_LISTEN=$(ss -Hlt 2>/dev/null | wc -l)
TCP_ESTABLISHED=$(ss -Htan state established 2>/dev/null | wc -l)
UDP_SOCKETS=$(ss -Huan 2>/dev/null | wc -l)

DEFAULT_IF=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')

printf "  IPv4 地址        : %s\n" "$IPV4_COUNT"
printf "  IPv6 地址        : %s\n" "$IPV6_COUNT"
printf "  IPv6 disabled    : %s\n" "${IPV6_DISABLED:-unknown}"
printf "  TCP LISTEN       : %s\n" "$TCP_LISTEN"
printf "  TCP established  : %s\n" "$TCP_ESTABLISHED"
printf "  UDP sockets      : %s\n" "$UDP_SOCKETS"
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
    warn "当前未检测到 SSH_CONNECTION。"
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
# 5. 网络压力
# ============================================================

info "[5/8] 网络实际压力检测"

read_softnet_dropped() {
    awk '
    {
        if (NF >= 2) {
            value = strtonum("0x" $2)
            total += value
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
# 7. 构建 systemd-sysctl 实际读取的文件列表
# ============================================================

info "[7/8] 检测 systemd-sysctl 实际配置文件"

# systemd-sysctl 默认搜索目录：
#
# /etc/sysctl.d
# /run/sysctl.d
# /usr/local/lib/sysctl.d
# /usr/lib/sysctl.d
#
# /usr/lib/sysctl.d 还可能通过 /lib/sysctl.d 对应。
#
# 同名文件按目录优先级覆盖：
# /etc > /run > /usr/local/lib > /usr/lib

declare -A SYSCTL_FILES

add_sysctl_files() {
    local DIR="$1"

    [[ -d "$DIR" ]] || return 0

    while IFS= read -r FILE; do
        local BASE
        BASE=$(basename "$FILE")

        # 高优先级目录已经有同名文件时，不使用低优先级同名文件。
        if [[ -z "${SYSCTL_FILES[$BASE]+x}" ]]; then
            SYSCTL_FILES["$BASE"]="$FILE"
        fi

    done < <(
        find "$DIR" \
            -maxdepth 1 \
            -type f \
            -name '*.conf' \
            -print 2>/dev/null |
        sort
    )
}

add_sysctl_files "/usr/lib/sysctl.d"
add_sysctl_files "/usr/local/lib/sysctl.d"
add_sysctl_files "/run/sysctl.d"
add_sysctl_files "/etc/sysctl.d"

SYSCTL_LIST="$TMP_DIR/sysctl.list"

for BASE in "${!SYSCTL_FILES[@]}"; do
    printf '%s\t%s\n' "$BASE" "${SYSCTL_FILES[$BASE]}"
done |
sort -k1,1 > "$SYSCTL_LIST"

echo
echo "  当前 systemd-sysctl 配置文件："

if [[ -s "$SYSCTL_LIST" ]]; then

    while IFS=$'\t' read -r BASE FILE; do
        printf "    %-35s %s\n" "$BASE" "$FILE"
    done < "$SYSCTL_LIST"

else

    warn "未发现现有 sysctl.d 配置文件。"

fi

# ============================================================
# 参数解析
# ============================================================

# systemd-sysctl 对配置文件的基本处理是：
# 文件按词法顺序处理；
# 后出现的参数可以覆盖前面的参数。
#
# 这里不修改 /proc。
# 只解析现有配置文件。
#
# 同时识别：
#   key = value
#   -key = value
#   # key = value
#
# 被注释的参数只作为候选，不视为当前有效配置。

declare -A ACTIVE_FILE
declare -A ACTIVE_LINE
declare -A ACTIVE_VALUE

declare -A COMMENT_FILE
declare -A COMMENT_LINE
declare -A COMMENT_VALUE

extract_key_lines() {
    local KEY="$1"
    local FILE="$2"

    awk -v key="$KEY" '
    {
        original=$0
        line=$0

        # 删除前导空白
        sub(/^[[:space:]]+/, "", line)

        commented=0

        # 识别 # 注释
        if (line ~ /^#/) {
            commented=1
            sub(/^#[[:space:]]*/, "", line)
        }

        # systemd-sysctl 支持忽略失败前缀 -
        sub(/^-/, "", line)

        # 精确匹配 key =
        if (line ~ ("^" key "[[:space:]]*=")) {

            value=line

            sub(("^" key "[[:space:]]*=[[:space:]]*"), "", value)

            # 删除行尾注释
            sub(/[[:space:]]+#.*$/, "", value)

            gsub(/[[:space:]]+$/, "", value)

            print NR "|" commented "|" value
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

for KEY in "${TARGET_KEYS[@]}"; do

    ACTIVE_FILE["$KEY"]=""
    ACTIVE_LINE["$KEY"]=""
    ACTIVE_VALUE["$KEY"]=""

    COMMENT_FILE["$KEY"]=""
    COMMENT_LINE["$KEY"]=""
    COMMENT_VALUE["$KEY"]=""

done

# ============================================================
# 按文件实际加载顺序解析
# ============================================================

while IFS=$'\t' read -r BASE FILE; do

    [[ -f "$FILE" ]] || continue

    for KEY in "${TARGET_KEYS[@]}"; do

        while IFS='|' read -r LINE COMMENTED VALUE; do

            [[ -n "$LINE" ]] || continue

            if [[ "$COMMENTED" == "0" ]]; then

                # 后加载的有效配置覆盖前面的配置。
                ACTIVE_FILE["$KEY"]="$FILE"
                ACTIVE_LINE["$KEY"]="$LINE"
                ACTIVE_VALUE["$KEY"]="$VALUE"

            else

                # 仅记录一个现有注释配置作为候选。
                if [[ -z "${COMMENT_FILE[$KEY]}" ]]; then
                    COMMENT_FILE["$KEY"]="$FILE"
                    COMMENT_LINE["$KEY"]="$LINE"
                    COMMENT_VALUE["$KEY"]="$VALUE"
                fi

            fi

        done < <(
            extract_key_lines "$KEY" "$FILE"
        )

    done

done < "$SYSCTL_LIST"

# ============================================================
# 显示真实配置来源
# ============================================================

echo
echo "------------------------------------------------------------"
echo " 参数实际持久化配置来源"
echo "------------------------------------------------------------"

for KEY in "${TARGET_KEYS[@]}"; do

    echo
    echo "[$KEY]"

    if [[ -n "${ACTIVE_FILE[$KEY]}" ]]; then

        printf "  有效配置 : %s:%s\n" \
            "${ACTIVE_FILE[$KEY]}" \
            "${ACTIVE_LINE[$KEY]}"

        printf "  文件值   : %s\n" \
            "${ACTIVE_VALUE[$KEY]}"

    elif [[ -n "${COMMENT_FILE[$KEY]}" ]]; then

        printf "  注释配置 : %s:%s\n" \
            "${COMMENT_FILE[$KEY]}" \
            "${COMMENT_LINE[$KEY]}"

        printf "  注释值   : %s\n" \
            "${COMMENT_VALUE[$KEY]}"

    else

        echo "  现有配置文件中不存在此参数。"

    fi

done

# ============================================================
# 生成修改计划
# ============================================================

declare -a CHANGES=()

add_change() {

    local KEY="$1"
    local CURRENT="$2"
    local TARGET="$3"

    if [[ "$CURRENT" == "$TARGET" ]]; then
        ok "$KEY：当前已经是 $TARGET，不修改。"
        return
    fi

    # 只有存在现有有效配置才能修改。
    if [[ -n "${ACTIVE_FILE[$KEY]}" ]]; then

        CHANGES+=(
            "$KEY|$CURRENT|$TARGET|${ACTIVE_FILE[$KEY]}|${ACTIVE_LINE[$KEY]}|active"
        )

        warn "$KEY：$CURRENT → $TARGET"
        echo "    精准修改：${ACTIVE_FILE[$KEY]}:${ACTIVE_LINE[$KEY]}"

        return
    fi

    # 有注释配置：
    # 解除注释并修改。
    if [[ -n "${COMMENT_FILE[$KEY]}" ]]; then

        CHANGES+=(
            "$KEY|$CURRENT|$TARGET|${COMMENT_FILE[$KEY]}|${COMMENT_LINE[$KEY]}|commented"
        )

        warn "$KEY：$CURRENT → $TARGET"
        echo "    解除注释并修改：${COMMENT_FILE[$KEY]}:${COMMENT_LINE[$KEY]}"

        return
    fi

    # 完全没有配置：
    # 严格按照用户要求：不创建文件、不新增参数。
    warn "$KEY：$CURRENT → $TARGET"
    echo "    未找到现有持久化配置 → 不修改"

}

echo
echo "============================================================"
echo "                      审计结果"
echo "============================================================"

echo
echo "[BBR / FQ / TFO]"

if [[ "$BBR_SUPPORTED" == 1 ]]; then

    add_change \
        "net.ipv4.tcp_congestion_control" \
        "$CURRENT_CC" \
        "bbr"

else

    warn "内核不支持 BBR，不修改。"

fi

if [[ "$FQ_SUPPORTED" == 1 ]]; then

    add_change \
        "net.core.default_qdisc" \
        "$CURRENT_QDISC" \
        "fq"

else

    warn "内核不支持 sch_fq，不修改。"

fi

add_change \
    "net.ipv4.tcp_fastopen" \
    "$CURRENT_TFO" \
    "3"

echo
echo "[TCP 连接参数]"

add_change \
    "net.ipv4.tcp_syncookies" \
    "$CURRENT_SYNCOOKIES" \
    "1"

if is_number "$CURRENT_SOMAX"; then

    if (( CURRENT_SOMAX < 4096 )); then

        add_change \
            "net.core.somaxconn" \
            "$CURRENT_SOMAX" \
            "4096"

    else

        ok "net.core.somaxconn：$CURRENT_SOMAX，不修改。"

    fi

else

    warn "无法读取 net.core.somaxconn，不修改。"

fi

if is_number "$CURRENT_SYN_BACKLOG"; then

    if (( CURRENT_SYN_BACKLOG < 4096 )); then

        add_change \
            "net.ipv4.tcp_max_syn_backlog" \
            "$CURRENT_SYN_BACKLOG" \
            "4096"

    else

        ok "net.ipv4.tcp_max_syn_backlog：$CURRENT_SYN_BACKLOG，不修改。"

    fi

else

    warn "无法读取 net.ipv4.tcp_max_syn_backlog，不修改。"

fi

echo
echo "[网络队列]"

if (( SOFTNET_DELTA > 0 )); then

    warn "检测到 softnet drops：$SOFTNET_DELTA / 3s"
    echo "    不根据单次短采样自动修改 netdev_max_backlog。"

else

    ok "没有检测到 softnet drops，不修改 net.core.netdev_max_backlog。"

fi

# ============================================================
# 明确不修改
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
echo "  当前运行中的 sysctl"
echo "  当前运行中的 qdisc"
echo "  当前运行中的拥塞控制"
echo
echo "  不创建新的 sysctl 配置文件"
echo "  不创建新的网络调优文件"

# ============================================================
# 没有修改
# ============================================================

if (( ${#CHANGES[@]} == 0 )); then

    echo
    ok "审计完成：没有可修改项目。"
    echo
    echo "系统没有发生任何修改。"
    exit 0

fi

# ============================================================
# 最终确认
# ============================================================

echo
echo "============================================================"
echo "                       待修改项目"
echo "============================================================"

for ITEM in "${CHANGES[@]}"; do

    IFS='|' read -r KEY CURRENT TARGET FILE LINE TYPE <<< "$ITEM"

    printf "  %-38s %s → %s\n" \
        "$KEY" \
        "$CURRENT" \
        "$TARGET"

    case "$TYPE" in

        active)
            echo "    精准修改：$FILE:$LINE"
            ;;

        commented)
            echo "    解除注释并精准修改：$FILE:$LINE"
            ;;

    esac

done

echo
echo "============================================================"
echo "                         安全模式"
echo "============================================================"
echo
echo "确认后："
echo "  ✓ 只修改现有配置文件"
echo "  ✓ 只修改目标参数所在行"
echo "  ✓ 注释参数只解除对应注释"
echo "  ✓ 不创建新的 sysctl 配置文件"
echo "  ✓ 不执行 sysctl -w"
echo "  ✓ 不执行 modprobe"
echo "  ✓ 不 reload systemd-sysctl"
echo "  ✓ 不重启网络"
echo "  ✓ 不重启 SSH"
echo "  ✓ 不重启 VPS"
echo
echo "因此当前 SSH 会话不会被脚本主动切换网络参数。"
echo
echo "修改后的配置将在系统下次启动时由 systemd-sysctl 应用。"
echo

read -r -p "确认执行以上修改？[y/N] " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then

    echo
    ok "已取消。系统没有发生任何修改。"
    exit 0

fi

# ============================================================
# 精准修改函数
# ============================================================

write_precise() {

    local KEY="$1"
    local VALUE="$2"
    local FILE="$3"
    local LINE="$4"
    local TYPE="$5"

    [[ -f "$FILE" ]] || {
        error "文件不存在，跳过：$FILE"
        return 1
    }

    local BEFORE
    BEFORE=$(sed -n "${LINE}p" "$FILE")

    [[ -n "$BEFORE" ]] || {
        error "目标行不存在，跳过：$FILE:$LINE"
        return 1
    }

    # 使用 awk 按行号修改。
    # 只修改指定行，不对其他内容进行全局替换。

    awk \
        -v target_line="$LINE" \
        -v key="$KEY" \
        -v value="$VALUE" '

    NR == target_line {

        indent=$0
        sub(/[^[:space:]].*$/, "", indent)

        print indent key " = " value
        next
    }

    {
        print
    }

    ' "$FILE" > "$TMP_DIR/modified"

    # 再次确认目标行确实包含目标 key。
    AFTER=$(sed -n "${LINE}p" "$TMP_DIR/modified")

    if ! grep -qE \
        "^[[:space:]]*${KEY//./\\.}[[:space:]]*=" \
        <<< "$AFTER"; then

        error "安全检查失败，拒绝修改：$FILE:$LINE"
        return 1

    fi

    # 原子替换：
    # 先生成临时文件，再覆盖原文件。
    cat "$TMP_DIR/modified" > "$FILE"

    ok "$KEY → $VALUE"
    echo "    文件：$FILE"
    echo "    行号：$LINE"
    echo "    原值：$BEFORE"
    echo "    新值：$AFTER"

    return 0
}

# ============================================================
# 执行精准修改
# ============================================================

echo
echo "============================================================"
echo "                       开始精准修改"
echo "============================================================"

MODIFY_FAILED=0

for ITEM in "${CHANGES[@]}"; do

    IFS='|' read -r KEY CURRENT TARGET FILE LINE TYPE <<< "$ITEM"

    if ! write_precise \
        "$KEY" \
        "$TARGET" \
        "$FILE" \
        "$LINE" \
        "$TYPE"; then

        MODIFY_FAILED=1

    fi

done

# ============================================================
# 最终文件验证
# ============================================================

echo
echo "============================================================"
echo "                     持久化配置验证"
echo "============================================================"

for ITEM in "${CHANGES[@]}"; do

    IFS='|' read -r KEY CURRENT TARGET FILE LINE TYPE <<< "$ITEM"

    if [[ -f "$FILE" ]]; then

        VALUE=$(sed -n "${LINE}p" "$FILE" 2>/dev/null || true)

        if grep -qE \
            "^[[:space:]]*${KEY//./\\.}[[:space:]]*=[[:space:]]*${TARGET//./\\.}([[:space:]]|$)" \
            <<< "$VALUE"; then

            ok "$KEY：持久化配置确认 → $TARGET"

        else

            warn "$KEY：请人工检查 $FILE:$LINE"

        fi

    fi

done

echo
echo "============================================================"
echo "                     当前运行状态"
echo "============================================================"

echo "注意：本脚本没有重新加载 sysctl。"
echo "下面显示的是当前正在运行的内核值。"
echo

printf "  当前 BBR          : %s\n" \
    "$(sysctl_get net.ipv4.tcp_congestion_control)"

printf "  当前 qdisc         : %s\n" \
    "$(sysctl_get net.core.default_qdisc)"

printf "  当前 TCP Fast Open : %s\n" \
    "$(sysctl_get net.ipv4.tcp_fastopen)"

printf "  当前 SYN cookies   : %s\n" \
    "$(sysctl_get net.ipv4.tcp_syncookies)"

printf "  当前 somaxconn     : %s\n" \
    "$(sysctl_get net.core.somaxconn)"

printf "  当前 syn backlog   : %s\n" \
    "$(sysctl_get net.ipv4.tcp_max_syn_backlog)"

echo
echo "============================================================"

if (( MODIFY_FAILED == 0 )); then

    ok "持久化配置修改完成。"

else

    error "部分项目修改失败，请根据上面的错误检查。"

fi

echo
echo "重要："
echo "  当前 SSH / 网络没有被脚本重启。"
echo "  当前运行中的 qdisc / BBR / sysctl 没有被强制切换。"
echo "  新配置将在下一次系统启动时由 systemd-sysctl 应用。"
echo

if [[ "$SSH_ACTIVE" == 1 ]]; then
    ok "当前 SSH 会话未被脚本主动重启。"
fi

echo
