#!/usr/bin/env bash
set -u
export LC_ALL=C

TARGET="/usr/lib/sysctl.d/50-default.conf"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}✗ 请使用 root 运行。${NC}"
    exit 1
fi

clear 2>/dev/null || true

echo "============================================================"
echo " Debian 13 双栈 TCP/UDP 网络调优"
echo " 自动审计 → 实际配置来源 → 人工确认 → 精准持久化"
echo "============================================================"
echo

# ------------------------------------------------------------
# 基础函数
# ------------------------------------------------------------

get_sysctl() {
    local key="$1"
    sysctl -n "$key" 2>/dev/null || echo "unknown"
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

version_ge() {
    [ "$1" -ge "$2" ]
}

# ------------------------------------------------------------
# [1/8] 系统检测
# ------------------------------------------------------------

echo "[1/8] 系统检测"

OS_NAME="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
KERNEL="$(uname -r)"
CPU_CORES="$(nproc 2>/dev/null || echo 1)"
RAM_MB="$(awk '/MemTotal:/ {printf "%d\n",$2/1024}' /proc/meminfo 2>/dev/null || echo 0)"

SWAP_MB="$(
    awk 'NR>1 {sum+=$3} END {printf "%d\n",sum+0}' /proc/swaps 2>/dev/null
)"

echo "  OS       : $OS_NAME"
echo "  Kernel   : $KERNEL"
echo "  CPU      : ${CPU_CORES} cores"
echo "  RAM      : ${RAM_MB} MB"
echo "  Swap     : ${SWAP_MB} MB（不修改）"
echo

# ------------------------------------------------------------
# [2/8] 双栈 / TCP / UDP
# ------------------------------------------------------------

echo "[2/8] IPv4 / IPv6 / TCP / UDP 检测"

IPV4_COUNT="$(ip -4 addr show scope global 2>/dev/null | grep -c 'inet ' || true)"
IPV6_COUNT="$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6 ' || true)"

IPV6_DISABLED="$(get_sysctl net.ipv6.conf.all.disable_ipv6)"

TCP_LISTEN="$(ss -Hlt 2>/dev/null | wc -l || echo 0)"
TCP_ESTABLISHED="$(ss -Htan state established 2>/dev/null | wc -l || echo 0)"
UDP_SOCKETS="$(ss -Huan 2>/dev/null | wc -l || echo 0)"

DEFAULT_IFACE="$(
    ip route show default 2>/dev/null |
    awk 'NR==1 {print $5}'
)"

echo "  IPv4 地址        : $IPV4_COUNT"
echo "  IPv6 地址        : $IPV6_COUNT"
echo "  IPv6 disabled    : $IPV6_DISABLED"
echo "  TCP LISTEN       : $TCP_LISTEN"
echo "  TCP established  : $TCP_ESTABLISHED"
echo "  UDP sockets      : $UDP_SOCKETS"
echo "  默认网卡         : ${DEFAULT_IFACE:-unknown}"
echo

# ------------------------------------------------------------
# [3/8] SSH 检测
# ------------------------------------------------------------

echo "[3/8] SSH 会话检测"

SSH_REMOTE=""
SSH_LOCAL=""

if [ -n "${SSH_CONNECTION:-}" ]; then
    read -r SSH_REMOTE SSH_REMOTE_PORT SSH_LOCAL SSH_LOCAL_PORT <<< "$SSH_CONNECTION"

    echo -e "${GREEN}✓ 检测到当前 SSH 远程会话${NC}"
    echo "  远端 IP     : $SSH_REMOTE"
    echo "  远端端口    : $SSH_REMOTE_PORT"
    echo "  本地地址    : $SSH_LOCAL"
    echo "  本地端口    : $SSH_LOCAL_PORT"
else
    echo "  当前未检测到 SSH_CONNECTION"
fi

echo

# ------------------------------------------------------------
# [4/8] BBR / FQ / TFO
# ------------------------------------------------------------

echo "[4/8] BBR / FQ / TCP Fast Open 检测"

CURRENT_CC="$(get_sysctl net.ipv4.tcp_congestion_control)"
AVAILABLE_CC="$(get_sysctl net.ipv4.tcp_allowed_congestion_control)"
CURRENT_QDISC="$(get_sysctl net.core.default_qdisc)"
CURRENT_TFO="$(get_sysctl net.ipv4.tcp_fastopen)"

BBR_SUPPORTED="no"
FQ_SUPPORTED="no"

if printf '%s\n' "$AVAILABLE_CC" | grep -qw bbr; then
    BBR_SUPPORTED="yes"
fi

if modinfo sch_fq >/dev/null 2>&1; then
    FQ_SUPPORTED="yes"
elif [ -e /lib/modules/"$(uname -r)"/kernel/net/sched/sch_fq.ko ] ||
     [ -e /lib/modules/"$(uname -r)"/kernel/net/sched/sch_fq.ko.xz ] ||
     [ -e /lib/modules/"$(uname -r)"/kernel/net/sched/sch_fq.ko.zst ]; then
    FQ_SUPPORTED="yes"
fi

echo "  当前拥塞控制      : $CURRENT_CC"
echo "  可用拥塞控制      : ${AVAILABLE_CC:-unknown}"
echo "  当前默认 qdisc    : $CURRENT_QDISC"
echo "  当前 TCP Fast Open : $CURRENT_TFO"
echo "  BBR 内核支持      : $BBR_SUPPORTED"
echo "  FQ 内核支持       : $FQ_SUPPORTED"
echo

# ------------------------------------------------------------
# [5/8] 网络压力检测
# ------------------------------------------------------------

echo "[5/8] 网络实际压力检测"

softnet_before="$(
    awk '{sum += $2} END {print sum+0}' /proc/net/softnet_stat 2>/dev/null
)"

rx_before="$(
    awk -F: '
    /:/ {
        split($2,a," ");
        rx += a[4]
    }
    END {print rx+0}
    ' /proc/net/dev 2>/dev/null
)"

tx_before="$(
    awk -F: '
    /:/ {
        split($2,a," ");
        tx += a[12]
    }
    END {print tx+0}
    ' /proc/net/dev 2>/dev/null
)"

sleep 3

softnet_after="$(
    awk '{sum += $2} END {print sum+0}' /proc/net/softnet_stat 2>/dev/null
)"

rx_after="$(
    awk -F: '
    /:/ {
        split($2,a," ");
        rx += a[4]
    }
    END {print rx+0}
    ' /proc/net/dev 2>/dev/null
)"

tx_after="$(
    awk -F: '
    /:/ {
        split($2,a," ");
        tx += a[12]
    }
    END {print tx+0}
)"

SOFTNET_DROP=$((softnet_after - softnet_before))
RX_DROP=$((rx_after - rx_before))
TX_DROP=$((tx_after - tx_before))

echo "  softnet drops / 3s : $SOFTNET_DROP"
echo "  RX drops / 3s      : $RX_DROP"
echo "  TX drops / 3s      : $TX_DROP"
echo

# ------------------------------------------------------------
# [6/8] 当前关键 sysctl
# ------------------------------------------------------------

echo "[6/8] 当前网络参数"

declare -A CURRENT

CURRENT[tcp_syncookies]="$(get_sysctl net.ipv4.tcp_syncookies)"
CURRENT[somaxconn]="$(get_sysctl net.core.somaxconn)"
CURRENT[tcp_max_syn_backlog]="$(get_sysctl net.ipv4.tcp_max_syn_backlog)"
CURRENT[netdev_max_backlog]="$(get_sysctl net.core.netdev_max_backlog)"
CURRENT[tcp_window_scaling]="$(get_sysctl net.ipv4.tcp_window_scaling)"
CURRENT[tcp_sack]="$(get_sysctl net.ipv4.tcp_sack)"

echo "  tcp_syncookies      : ${CURRENT[tcp_syncookies]}"
echo "  somaxconn            : ${CURRENT[somaxconn]}"
echo "  tcp_max_syn_backlog  : ${CURRENT[tcp_max_syn_backlog]}"
echo "  netdev_max_backlog   : ${CURRENT[netdev_max_backlog]}"
echo "  tcp_window_scaling   : ${CURRENT[tcp_window_scaling]}"
echo "  tcp_sack             : ${CURRENT[tcp_sack]}"
echo

# ------------------------------------------------------------
# [7/8] systemd-sysctl 实际配置文件
# ------------------------------------------------------------

echo "[7/8] 检测 systemd-sysctl 实际配置文件"

SYSCTL_DIRS=(
    /etc/sysctl.d
    /run/sysctl.d
    /usr/local/lib/sysctl.d
    /usr/lib/sysctl.d
    /lib/sysctl.d
)

declare -a SYSCTL_FILES=()

for dir in "${SYSCTL_DIRS[@]}"; do
    [ -d "$dir" ] || continue

    while IFS= read -r file; do
        SYSCTL_FILES+=("$file")
    done < <(
        find "$dir" -maxdepth 1 -type f \
            \( -name '*.conf' -o -name '*.cfg' \) \
            -print 2>/dev/null |
        sort -V
    )
done

echo
echo "  systemd-sysctl 配置文件："

if [ "${#SYSCTL_FILES[@]}" -eq 0 ]; then
    echo "    未找到"
else
    for file in "${SYSCTL_FILES[@]}"; do
        echo "    $(basename "$file")    $file"
    done
fi

echo

# ------------------------------------------------------------
# 精确解析配置
# ------------------------------------------------------------

echo "------------------------------------------------------------"
echo " 参数实际持久化配置来源"
echo "------------------------------------------------------------"

# 返回最后一个有效配置项的位置。
# systemd-sysctl 按文件名排序处理，因此后面的配置覆盖前面的配置。
find_param_source() {
    local key="$1"
    local found=""

    for file in "${SYSCTL_FILES[@]}"; do
        [ -r "$file" ] || continue

        while IFS= read -r line; do
            # 删除 CR
            line="${line%$'\r'}"

            # 去除行首空白
            local trimmed="${line#"${line%%[![:space:]]*}"}"

            # 跳过空行和纯注释
            [[ -z "$trimmed" ]] && continue
            [[ "$trimmed" == \#* ]] && continue

            # 精确匹配 key =
            if [[ "$trimmed" =~ ^${key}[[:space:]]*= ]]; then
                found="$file"
            fi
        done < "$file"
    done

    printf '%s\n' "$found"
}

get_file_value() {
    local key="$1"
    local file="$2"

    awk -v k="$key" '
        {
            line=$0
            sub(/\r$/, "", line)

            if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
                sub(/^[[:space:]]*" k "[[:space:]]*=[[:space:]]*/, "", line)
                print line
            }
        }
    ' "$file" | tail -n1
}

declare -A SOURCE
declare -A FILE_VALUE

PARAM_KEYS=(
    "net.ipv4.tcp_congestion_control"
    "net.core.default_qdisc"
    "net.ipv4.tcp_fastopen"
    "net.ipv4.tcp_syncookies"
    "net.core.somaxconn"
    "net.ipv4.tcp_max_syn_backlog"
    "net.core.netdev_max_backlog"
    "net.ipv4.tcp_window_scaling"
    "net.ipv4.tcp_sack"
)

for key in "${PARAM_KEYS[@]}"; do
    SOURCE["$key"]="$(find_param_source "$key")"

    echo "[$key]"

    if [ -n "${SOURCE[$key]}" ]; then
        FILE_VALUE["$key"]="$(get_file_value "$key" "${SOURCE[$key]}")"
        echo "  有效配置 : ${SOURCE[$key]}"
        echo "  文件值   : ${FILE_VALUE[$key]}"
    else
        echo "  现有配置文件中不存在此参数。"
    fi

    echo
done

# ------------------------------------------------------------
# 调优目标
# ------------------------------------------------------------

declare -A TARGET

# BBR
if [ "$BBR_SUPPORTED" = "yes" ]; then
    TARGET[net.ipv4.tcp_congestion_control]="bbr"
fi

# FQ
if [ "$FQ_SUPPORTED" = "yes" ]; then
    TARGET[net.core.default_qdisc]="fq"
fi

# TCP Fast Open
TARGET[net.ipv4.tcp_fastopen]="3"

# 基础安全/连接能力
TARGET[net.ipv4.tcp_syncookies]="1"
TARGET[net.ipv4.tcp_window_scaling]="1"
TARGET[net.ipv4.tcp_sack]="1"

# backlog
TARGET[net.core.somaxconn]="4096"
TARGET[net.ipv4.tcp_max_syn_backlog]="4096"

# ------------------------------------------------------------
# 根据 CPU / RAM / 实际网络压力决定 netdev backlog
# ------------------------------------------------------------

if [ "$SOFTNET_DROP" -gt 0 ] || [ "$RX_DROP" -gt 0 ]; then
    if [ "$CPU_CORES" -le 1 ]; then
        TARGET[net.core.netdev_max_backlog]="4096"
    else
        TARGET[net.core.netdev_max_backlog]="8192"
    fi
fi

# ------------------------------------------------------------
# 结果判断
# ------------------------------------------------------------

declare -a CHANGE_KEYS=()
declare -a CHANGE_TARGETS=()
declare -a CHANGE_FILES=()
declare -a CHANGE_MODES=()

echo "============================================================"
echo "                      审计结果"
echo "============================================================"
echo

echo "[BBR / FQ / TFO]"

check_param() {
    local key="$1"
    local target="${TARGET[$key]:-}"
    local current="${CURRENT[$key]:-unknown}"
    local source="${SOURCE[$key]:-}"

    [ -n "$target" ] || return 0

    if [ "$current" = "$target" ]; then
        echo -e "✓ $key：当前已经是 $target，不修改。"
        return 0
    fi

    echo -e "⚠ $key：$current → $target"

    if [ -n "$source" ]; then
        echo "    精准修改：$source"

        CHANGE_KEYS+=("$key")
        CHANGE_TARGETS+=("$target")
        CHANGE_FILES+=("$source")
        CHANGE_MODES+=("existing")
    else
        echo "    不存在现有配置 → 追加到：$TARGET"

        CHANGE_KEYS+=("$key")
        CHANGE_TARGETS+=("$target")
        CHANGE_FILES+=("$TARGET")
        CHANGE_MODES+=("append")
    fi
}

check_param "net.ipv4.tcp_congestion_control"
check_param "net.core.default_qdisc"
check_param "net.ipv4.tcp_fastopen"

echo
echo "[TCP 连接参数]"

check_param "net.ipv4.tcp_syncookies"
check_param "net.core.somaxconn"
check_param "net.ipv4.tcp_max_syn_backlog"
check_param "net.ipv4.tcp_window_scaling"
check_param "net.ipv4.tcp_sack"

echo
echo "[网络队列]"

if [ -n "${TARGET[net.core.netdev_max_backlog]:-}" ]; then
    check_param "net.core.netdev_max_backlog"
else
    echo "✓ 没有检测到需要增加 netdev_max_backlog 的网络压力。"
fi

# ------------------------------------------------------------
# 明确不修改
# ------------------------------------------------------------

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
echo "  不创建 /etc/sysctl.d/90-singbox.conf"
echo "  不创建其他 sysctl 配置文件"
echo "  只修改：$TARGET"

# ------------------------------------------------------------
# 修改列表
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                       待修改项目"
echo "============================================================"

if [ "${#CHANGE_KEYS[@]}" -eq 0 ]; then
    echo
    echo -e "${GREEN}✓ 当前没有需要修改的项目。${NC}"
    echo
    echo "系统当前配置已经符合本脚本的调优策略。"
    exit 0
fi

for ((i=0; i<${#CHANGE_KEYS[@]}; i++)); do
    printf "  %-38s %s → %s\n" \
        "${CHANGE_KEYS[$i]}" \
        "$(get_sysctl "${CHANGE_KEYS[$i]}")" \
        "${CHANGE_TARGETS[$i]}"

    if [ "${CHANGE_MODES[$i]}" = "existing" ]; then
        echo "    精准修改：${CHANGE_FILES[$i]}"
    else
        echo "    追加到：$TARGET"
    fi
done

echo
echo "============================================================"
echo "                         安全模式"
echo "============================================================"
echo
echo "确认后："
echo "  ✓ 只修改现有配置文件"
echo "  ✓ 不创建新的 sysctl 配置文件"
echo "  ✓ 不创建 90-singbox.conf"
echo "  ✓ 已存在参数只修改对应参数"
echo "  ✓ 不执行 sysctl -w"
echo "  ✓ 不执行 modprobe"
echo "  ✓ 不 reload systemd-sysctl"
echo "  ✓ 不重启网络"
echo "  ✓ 不重启 SSH"
echo "  ✓ 不重启 VPS"
echo
echo "注意：配置写入后不会立即改变当前运行中的网络参数。"
echo "它将在 systemd-sysctl 下次正常应用配置时生效。"
echo
echo "============================================================"
printf "确认执行以上修改？[y/N] "
read -r CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo
    echo -e "${YELLOW}已取消，没有修改任何文件。${NC}"
    exit 0
fi

# ------------------------------------------------------------
# 精准修改
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                       开始修改"
echo "============================================================"

# 确保目标文件存在
if [ ! -f "$TARGET" ]; then
    echo -e "${RED}✗ $TARGET 不存在，已停止。${NC}"
    exit 1
fi

# 对每个参数进行精准处理。
#
# 规则：
# 1. 有有效配置：
#       只修改该参数的有效行。
#
# 2. 没有有效配置但存在注释参数：
#       解除目标参数对应注释并修改。
#
# 3. 完全不存在：
#       追加参数。
#
# 4. 不改动其他参数。
#

for ((i=0; i<${#CHANGE_KEYS[@]}; i++)); do

    key="${CHANGE_KEYS[$i]}"
    value="${CHANGE_TARGETS[$i]}"

    echo "  → $key = $value"

    # 只对 50-default.conf 操作
    #
    # 因为用户要求所有新增参数统一进入这个文件。
    #
    if [ "${CHANGE_MODES[$i]}" = "existing" ]; then
        FILE="${CHANGE_FILES[$i]}"
    else
        FILE="$TARGET"
    fi

    # --------------------------------------------------------
    # existing：修改有效配置行
    # --------------------------------------------------------

    if [ "${CHANGE_MODES[$i]}" = "existing" ]; then

        awk -v k="$key" -v v="$value" '
        BEGIN {
            changed=0
        }

        {
            line=$0

            # 精确匹配有效参数
            if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {

                # 保留缩进，只替换参数值
                match(line, /^[[:space:]]*/)
                indent=substr(line, RSTART, RLENGTH)

                print indent k " = " v
                changed=1
            }
            else {
                print line
            }
        }

        END {
            if (!changed)
                exit 2
        }
        ' "$FILE" > "$TMP"

        status=$?

        if [ "$status" -eq 0 ]; then
            cat "$TMP" > "$FILE"
            echo -e "    ${GREEN}✓ 已精准修改${NC}"
            continue
        fi
    fi

    # --------------------------------------------------------
    # 搜索注释形式：
    #
    # # net.ipv4.tcp_fastopen = 1
    # ; net.ipv4.tcp_fastopen = 1
    #
    # 只解除对应 key 的注释。
    # --------------------------------------------------------

    awk -v k="$key" -v v="$value" '
    BEGIN {
        changed=0
    }

    {
        line=$0

        if (line ~ "^[[:space:]]*[#;][[:space:]]*" k "[[:space:]]*=") {

            match(line, /^[[:space:]]*/)
            indent=substr(line, RSTART, RLENGTH)

            print indent k " = " v
            changed=1
        }
        else {
            print line
        }
    }

    END {
        if (!changed)
            exit 2
    }
    ' "$TARGET" > "$TMP"

    status=$?

    if [ "$status" -eq 0 ]; then
        cat "$TMP" > "$TARGET"
        echo -e "    ${GREEN}✓ 已解除注释并精准修改${NC}"
        continue
    fi

    # --------------------------------------------------------
    # 参数完全不存在 → 追加
    # --------------------------------------------------------

    printf '\n%s = %s\n' "$key" "$value" >> "$TARGET"

    echo -e "    ${GREEN}✓ 已追加至 $TARGET${NC}"

done

# ------------------------------------------------------------
# 最终只读验证
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                       修改完成"
echo "============================================================"

echo
echo "持久化配置文件："
echo "  $TARGET"

echo
echo "已写入参数："

for ((i=0; i<${#CHANGE_KEYS[@]}; i++)); do
    key="${CHANGE_KEYS[$i]}"
    value="${CHANGE_TARGETS[$i]}"

    final_value="$(
        awk -v k="$key" '
        {
            line=$0
            if (line ~ "^[[:space:]]*" k "[[:space:]]*=") {
                sub(/^[[:space:]]*" k "[[:space:]]*=[[:space:]]*/, "", line)
                val=line
            }
        }
        END {
            print val
        }
        ' "$TARGET"
    )"

    if [ "$final_value" = "$value" ]; then
        echo -e "  ${GREEN}✓ $key = $final_value${NC}"
    else
        echo -e "  ${RED}✗ $key 验证异常：$final_value${NC}"
    fi
done

echo
echo "============================================================"
echo "                         说明"
echo "============================================================"
echo
echo "本次脚本只修改了持久化配置文件，没有修改当前运行状态。"
echo
echo "没有执行："
echo "  sysctl -w"
echo "  modprobe"
echo "  systemctl restart systemd-sysctl"
echo "  restart networking"
echo "  restart NetworkManager"
echo "  restart ssh"
echo "  reboot"
echo
echo -e "${GREEN}✓ SSH / 网络连接不会被脚本主动重置。${NC}"
echo
echo "新的 sysctl 配置将在系统后续正常加载 sysctl 配置时生效。"
echo
