#!/bin/bash
# =============================================================================
# Debian 13 新装系统一站式优化 + XanMod 内核替换脚本
# 运行方式：root 权限执行，需运行两次：
#   第1次：系统初始化 + 安装 XanMod → 自动重启
#   第2次：重启后再次运行，执行 cleanup（删除旧内核/QEMU/审计）
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 颜色与输出
# ---------------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; GRAY='\033[1;37m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; }
step() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

handle_error() {
    local line=$1 code=$2
    echo -e "${RED}[FATAL] 第 $line 行发生错误，退出码：$code${NC}" >&2
    exit "$code"
}
trap 'handle_error $LINENO $?' ERR

# ---------------------------------------------------------------------------
# 必须 root
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: 请使用 root 执行。${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 阶段判断
# ---------------------------------------------------------------------------
CURRENT_KERNEL="$(uname -r)"

if [[ "$CURRENT_KERNEL" == *xanmod* ]]; then
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN} 检测到当前运行 XanMod 内核，进入 Cleanup 阶段${NC}"
    echo -e "${CYAN}==================================================${NC}"
    RUN_CLEANUP=1
else
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN} 当前运行 Stock 内核，进入初始化 + XanMod 安装${NC}"
    echo -e "${CYAN}==================================================${NC}"
    RUN_CLEANUP=0
fi

# =========================================================================
# PHASE 1: 系统初始化 + XanMod 安装（仅在非 XanMod 内核时执行）
# =========================================================================
if [ "$RUN_CLEANUP" -eq 0 ]; then

    # ---------------------------------------------------------------------------
    # STEP 1/8: 软件源更新与全系统升级
    # ---------------------------------------------------------------------------
    step "[STEP 1/8] 系统软件源更新与安全升级"

    echo -e "${YELLOW}  更新 apt 索引...${NC}"
    if apt-get update -qq; then
        ok "软件包索引更新完成"
    else
        fail "apt-get update 失败，请检查网络或软件源配置。"
        exit 1
    fi

    echo -e "${YELLOW}  执行非交互式全系统升级...${NC}"
    if DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"; then
        ok "系统及内核升级完成"
    else
        fail "系统升级失败，请检查软件包依赖或网络。"
        exit 1
    fi

    # ---------------------------------------------------------------------------
    # STEP 2/8: 清理孤立依赖、缓存及残留配置
    # ---------------------------------------------------------------------------
    step "[STEP 2/8] 清理孤立依赖与残留配置"

    echo -e "${YELLOW}  清理孤立包与缓存...${NC}"
    if apt-get autoremove --purge -y -qq && apt-get autoclean -y -qq && apt-get clean -qq; then
        ok "孤立包与缓存已清理"
    else
        warn "部分清理操作失败，但不影响主流程。"
    fi

    RC_PKGS=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' || true)
    if [ -n "$RC_PKGS" ]; then
        echo -e "${YELLOW}  清除残留配置包...${NC}"
        if echo "$RC_PKGS" | xargs -r apt-get purge -y -qq; then
            ok "残留配置文件已清除"
        else
            warn "部分残留配置清除失败。"
        fi
    else
        ok "无残留配置文件"
    fi

    # ---------------------------------------------------------------------------
    # STEP 3/8: 内核网络参数与系统资源调优
    # ---------------------------------------------------------------------------
    step "[STEP 3/8] 内核网络参数优化"

    # 3a. 确保 tcp_bbr / sch_fq 模块加载
    if [ -f /etc/modules ]; then
        echo -e "${YELLOW}  检查 /etc/modules ...${NC}"
        if ! grep -qE '^\s*tcp_bbr\s*$' /etc/modules; then
            if echo "tcp_bbr" >> /etc/modules; then
                ok "已添加 tcp_bbr 到 /etc/modules"
            else
                warn "无法写入 /etc/modules"
            fi
        else
            ok "tcp_bbr 已存在于 /etc/modules"
        fi
        if ! grep -qE '^\s*sch_fq\s*$' /etc/modules; then
            if echo "sch_fq" >> /etc/modules; then
                ok "已添加 sch_fq 到 /etc/modules"
            else
                warn "无法写入 /etc/modules"
            fi
        else
            ok "sch_fq 已存在于 /etc/modules"
        fi
    else
        warn "/etc/modules 不存在，跳过模块加载配置。"
    fi

    # 3b. 更新 sysctl 配置（只修改已有的 /usr/lib/sysctl.d/50-default.conf）
    NATIVE_SYSCTL="/usr/lib/sysctl.d/50-default.conf"
    if [ ! -f "$NATIVE_SYSCTL" ]; then
        fail "未找到 $NATIVE_SYSCTL，无法进行 sysctl 优化。"
        exit 1
    fi

    echo -e "${YELLOW}  更新 $NATIVE_SYSCTL ...${NC}"

    set_sysctl_param() {
        local key="$1" val="$2"
        local key_escaped="${key//./\\.}"
        if grep -qE "^[[:space:]-]*${key_escaped}[[:space:]]*=" "$NATIVE_SYSCTL"; then
            # 替换已存在的键（可能被注释）
            sed -i "s/^[[:space:]-]*${key_escaped}[[:space:]]*=.*/${key} = ${val}/g" "$NATIVE_SYSCTL"
        else
            # 追加到文件末尾
            echo "${key} = ${val}" >> "$NATIVE_SYSCTL"
        fi
    }

    # 文件描述符与内存
    set_sysctl_param "fs.file-max" "2097152"
    set_sysctl_param "fs.inotify.max_user_instances" "8192"
    set_sysctl_param "fs.inotify.max_user_watches" "524288"
    set_sysctl_param "kernel.pid_max" "4194304"
    set_sysctl_param "vm.overcommit_memory" "1"
    set_sysctl_param "vm.swappiness" "1"

    # 网络核心
    set_sysctl_param "net.core.somaxconn" "32768"
    set_sysctl_param "net.core.netdev_max_backlog" "100000"
    set_sysctl_param "net.core.netdev_budget" "600"
    set_sysctl_param "net.core.netdev_budget_usecs" "8000"
    set_sysctl_param "net.core.optmem_max" "65536"
    set_sysctl_param "net.core.rmem_default" "1048576"
    set_sysctl_param "net.core.wmem_default" "1048576"
    set_sysctl_param "net.core.rmem_max" "268435456"
    set_sysctl_param "net.core.wmem_max" "268435456"
    set_sysctl_param "net.ipv4.udp_rmem_min" "8192"
    set_sysctl_param "net.ipv4.udp_wmem_min" "8192"
    set_sysctl_param "net.ipv4.tcp_rmem" "8192 1048576 268435456"
    set_sysctl_param "net.ipv4.tcp_wmem" "8192 1048576 268435456"
    set_sysctl_param "net.ipv4.tcp_mem" "786432 1048576 1572864"
    set_sysctl_param "net.core.default_qdisc" "fq"
    set_sysctl_param "net.ipv4.tcp_congestion_control" "bbr"
    set_sysctl_param "net.ipv4.tcp_slow_start_after_idle" "0"
    set_sysctl_param "net.ipv4.tcp_mtu_probing" "1"
    set_sysctl_param "net.ipv4.tcp_base_mss" "1024"
    set_sysctl_param "net.ipv4.tcp_ecn" "0"
    set_sysctl_param "net.ipv4.ip_local_port_range" "1024 65535"
    set_sysctl_param "net.ipv4.tcp_max_syn_backlog" "32768"
    set_sysctl_param "net.ipv4.tcp_max_tw_buckets" "262144"
    set_sysctl_param "net.ipv4.tcp_syncookies" "1"
    set_sysctl_param "net.ipv4.tcp_rfc1337" "1"
    set_sysctl_param "net.ipv4.tcp_fin_timeout" "30"
    set_sysctl_param "net.ipv4.tcp_keepalive_time" "600"
    set_sysctl_param "net.ipv4.tcp_keepalive_intvl" "15"
    set_sysctl_param "net.ipv4.tcp_keepalive_probes" "5"
    set_sysctl_param "net.ipv4.tcp_fastopen" "3"
    set_sysctl_param "net.ipv4.tcp_window_scaling" "1"
    set_sysctl_param "net.ipv4.tcp_sack" "1"
    set_sysctl_param "net.ipv4.tcp_timestamps" "1"
    set_sysctl_param "net.ipv4.tcp_notsent_lowat" "131072"
    set_sysctl_param "net.ipv4.tcp_no_metrics_save" "1"
    set_sysctl_param "net.ipv4.ip_forward" "1"
    set_sysctl_param "net.ipv4.conf.all.forwarding" "1"
    set_sysctl_param "net.ipv4.conf.default.forwarding" "1"
    set_sysctl_param "net.ipv6.conf.all.forwarding" "1"
    set_sysctl_param "net.ipv6.conf.default.forwarding" "1"
    set_sysctl_param "net.ipv6.conf.lo.forwarding" "1"
    set_sysctl_param "net.ipv6.conf.all.disable_ipv6" "0"
    set_sysctl_param "net.ipv6.conf.default.disable_ipv6" "0"

    # 重新加载模块和 sysctl
    if modprobe tcp_bbr 2>/dev/null; then
        ok "tcp_bbr 模块加载成功"
    else
        warn "tcp_bbr 模块加载失败（可能已内置）"
    fi
    if modprobe sch_fq 2>/dev/null; then
        ok "sch_fq 模块加载成功"
    else
        warn "sch_fq 模块加载失败（可能已内置）"
    fi
    if systemctl restart systemd-sysctl >/dev/null 2>&1; then
        ok "sysctl 参数已重新加载"
    else
        warn "systemd-sysctl 重启失败，参数可能未完全生效"
    fi

    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$CURRENT_QDISC" = "fq" ] && [ "$CURRENT_CC" = "bbr" ]; then
        ok "BBR/FQ 验证通过"
    else
        warn "BBR/FQ 验证异常: qdisc=$CURRENT_QDISC cc=$CURRENT_CC"
    fi
    # ---------------------------------------------------------------------------
# STEP 4/8: 精简无用后台服务
# ---------------------------------------------------------------------------
step "[STEP 4/8] 精简无用后台服务"

disable_service() {
    local svc=$1 desc=$2
    if systemctl list-unit-files "$svc" &>/dev/null; then
        systemctl stop "$svc" 2>/dev/null && ok "已停止 $svc" || warn "停止 $svc 失败（可能未运行）"
        systemctl disable "$svc" 2>/dev/null && ok "已禁用 $svc" || warn "禁用 $svc 失败"
        systemctl mask "$svc" 2>/dev/null && ok "已 mask $svc" || warn "mask $svc 失败（可能已 mask）"
        echo -e "  ${GRAY}($desc)${NC}"
    else
        ok "$svc 未安装，跳过 ($desc)"
    fi
}

disable_service "bluetooth.service"        "蓝牙"
disable_service "bluetooth.target"         "蓝牙目标"
disable_service "avahi-daemon.service"     "局域网发现"
disable_service "avahi-daemon.socket"      "Avahi Socket"
disable_service "ModemManager.service"     "移动宽带"
disable_service "wpa_supplicant.service"   "Wi-Fi"
disable_service "cups.service"             "打印机"
disable_service "cups-browsed.service"     "打印机发现"
disable_service "alsa-state.service"       "声卡"
disable_service "systemd-networkd-wait-online.service" "等待网络"
disable_service "NetworkManager-wait-online.service"   "等待网络(NM)"

# ---------------------------------------------------------------------------
# STEP 5/8: 系统日志限制与清理
# ---------------------------------------------------------------------------
step "[STEP 5/8] 日志限制与清理"

# 5a. journald.conf
JC="/etc/systemd/journald.conf"
if [ -f "$JC" ]; then
    echo -e "${YELLOW}  更新 $JC ...${NC}"
    awk '
        BEGIN {
            smv="SystemMaxUse=5M"; rmv="RuntimeMaxUse=5M"; skf="SystemKeepFree=100M"
            sms="SystemMaxFileSize=5M"; cmp="Compress=yes"; fts="ForwardToSyslog=no"
            s_smv=0; s_rmv=0; s_skf=0; s_sms=0; s_cmp=0; s_fts=0; in_journal=0
        }
        /^\[Journal\]/ { in_journal=1; print; next }
        /^\[.*\]/ { in_journal=0; print; next }
        {
            if (in_journal) {
                if ($0 ~ /^#?SystemMaxUse=/) { print smv; s_smv=1; next }
                else if ($0 ~ /^#?RuntimeMaxUse=/) { print rmv; s_rmv=1; next }
                else if ($0 ~ /^#?SystemKeepFree=/) { print skf; s_skf=1; next }
                else if ($0 ~ /^#?SystemMaxFileSize=/) { print sms; s_sms=1; next }
                else if ($0 ~ /^#?Compress=/) { print cmp; s_cmp=1; next }
                else if ($0 ~ /^#?ForwardToSyslog=/) { print fts; s_fts=1; next }
            }
            print
        }
        END {
            if (in_journal) {
                if (!s_smv) print smv; if (!s_rmv) print rmv; if (!s_skf) print skf
                if (!s_sms) print sms; if (!s_cmp) print cmp; if (!s_fts) print fts
            }
        }
    ' "$JC" > "${JC}.tmp" && mv "${JC}.tmp" "$JC"
    ok "journald.conf 已更新"
else
    warn "未找到 $JC，跳过 journald 配置优化。"
fi

if systemctl restart systemd-journald 2>/dev/null; then
    ok "systemd-journald 已重启"
else
    warn "systemd-journald 重启失败"
fi

sleep 1
if journalctl --vacuum-size=5M --vacuum-time=3d 2>/dev/null; then
    ok "journald 日志已按大小/时间清理"
else
    warn "journalctl 清理失败（可能无日志或权限不足）"
fi

# 5b. logrotate.conf
LR="/etc/logrotate.conf"
if [ -f "$LR" ]; then
    echo -e "${YELLOW}  更新 $LR ...${NC}"
    awk -v nw="weekly" -v nr="rotate 3" -v nc="create" \
        -v nde="dateext" -v ncomp="compress" -v ndc="delaycompress" -v ns="size 5M" '
        BEGIN {
            seen_weekly=0; seen_rotate=0; seen_create=0; seen_dateext=0;
            seen_compress=0; seen_delaycompress=0; seen_size=0
        }
        {
            if ($1=="weekly") { if (!seen_weekly) { print nw; seen_weekly=1 } else next }
            else if ($1=="rotate" && $2+0>0) { if (!seen_rotate) { print nr; seen_rotate=1 } else next }
            else if ($1=="create") { if (!seen_create) { print nc; seen_create=1 } else next }
            else if ($1=="dateext") { if (!seen_dateext) { print nde; seen_dateext=1 } else next }
            else if ($1=="compress") { if (!seen_compress) { print ncomp; seen_compress=1 } else next }
            else if ($1=="delaycompress") { if (!seen_delaycompress) { print ndc; seen_delaycompress=1 } else next }
            else if ($1=="size") { if (!seen_size) { print ns; seen_size=1 } else next }
            else print
        }
        END {
            if (!seen_weekly) print nw; if (!seen_rotate) print nr; if (!seen_create) print nc
            if (!seen_dateext) print nde; if (!seen_compress) print ncomp
            if (!seen_delaycompress) print ndc; if (!seen_size) print ns
        }
    ' "$LR" > "${LR}.tmp" && mv "${LR}.tmp" "$LR"
    ok "logrotate.conf 已更新"
else
    warn "未找到 $LR，跳过 logrotate 优化。"
fi

# 5c. 清理历史日志
echo -e "${YELLOW}  清理历史日志...${NC}"
if [ -d /var/log/installer ]; then
    rm -rf /var/log/installer && ok "已删除 /var/log/installer"
fi
find /var/log -type f \( -name "*.log.1" -o -name "*.log.*" -o -name "*.log.gz" -o -name "*.gz" \) -delete 2>/dev/null && ok "已删除压缩/轮转日志"
find /etc -type f \( -name "*~" -o -name "*.bak" \) -delete 2>/dev/null && ok "已删除备份文件"
if [ -d /var/backups ]; then
    find /var/backups -type f -mtime +30 -delete 2>/dev/null && ok "已清理过期备份"
fi
if logrotate -f /etc/logrotate.conf 2>/dev/null; then
    ok "logrotate 已执行"
else
    warn "logrotate 执行失败"
fi

ACTIVE_LOGS=(
    "/var/log/syslog" "/var/log/auth.log" "/var/log/kern.log"
    "/var/log/daemon.log" "/var/log/messages" "/var/log/user.log"
    "/var/log/debug" "/var/log/mail.log" "/var/log/mail.err"
    "/var/log/dpkg.log" "/var/log/alternatives.log"
)
for f in "${ACTIVE_LOGS[@]}"; do
    if [ -f "$f" ]; then
        : > "$f" && ok "已清空 $f"
    fi
done

if systemctl is-enabled --quiet rsyslog 2>/dev/null || systemctl status rsyslog >/dev/null 2>&1; then
    if systemctl restart rsyslog 2>/dev/null; then
        ok "rsyslog 已重启"
    else
        warn "rsyslog 重启失败"
    fi
fi

if [ -d /var/log/nginx ]; then
    for f in /var/log/nginx/*.log; do
        [ -f "$f" ] && : > "$f"
    done
    if nginx -s reopen 2>/dev/null; then
        ok "nginx 日志已清空并重开"
    else
        warn "nginx 未运行或命令失败"
    fi
fi

# 5d. 清理临时文件
find /tmp -mindepth 1 -delete 2>/dev/null && ok "/tmp 已清理"
find /var/tmp -mindepth 1 -delete 2>/dev/null && ok "/var/tmp 已清理"

# 5e. SSD TRIM
if systemctl list-unit-files "fstrim.timer" &>/dev/null; then
    if systemctl enable --now fstrim.timer 2>/dev/null; then
        ok "fstrim.timer 已激活"
    else
        warn "fstrim.timer 启用失败"
    fi
fi
# ---------------------------------------------------------------------------
# STEP 6/8: Secure Boot 检测
# ---------------------------------------------------------------------------
step "[STEP 6/8] Secure Boot 检测"

# 尝试从 efivarfs 读取 SecureBoot 状态，避免依赖 mokutil
SB_EFIVAR="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
if [ -f "$SB_EFIVAR" ]; then
    # 文件内容为 5 字节，最后一个字节 0x01 表示启用
    SB_STATUS=$(od -An -t u1 "$SB_EFIVAR" 2>/dev/null | tr -d ' ' | tail -c 2)
    if [ "$SB_STATUS" = "1" ]; then
        fail "Secure Boot 已开启。XanMod 内核未签名，无法启动。"
        echo -e "${RED}       请先在 BIOS/UEFI 中关闭 Secure Boot 后重试。${NC}"
        exit 1
    else
        ok "Secure Boot 未启用，可以继续安装。"
    fi
else
    warn "无法检测 Secure Boot 状态（可能不是 UEFI 或 efivarfs 未挂载）。请手动确认 Secure Boot 已关闭。"
fi

# ---------------------------------------------------------------------------
# STEP 7/8: XanMod 安装
# ---------------------------------------------------------------------------
step "[STEP 7/8] XanMod 内核安装"

# 7a. /boot 空间检查
BOOT_AVAIL=$(df -m /boot | awk 'NR==2{print $4}')
if [ "${BOOT_AVAIL:-0}" -lt 150 ]; then
    fail "/boot 剩余空间不足 150MB (${BOOT_AVAIL}MB)，安装可能失败。"
    exit 1
fi
ok "/boot 空间充足 (${BOOT_AVAIL}MB)"

# 7b. 安装仓库工具（尽量少）
echo -e "${YELLOW}  安装仓库工具...${NC}"
if apt-get install -y -qq --no-install-recommends wget gpg ca-certificates; then
    ok "wget/gpg/ca-certificates 安装完成"
else
    fail "无法安装 wget/gpg/ca-certificates。"
    exit 1
fi

# 7c. GPG Key 下载与指纹校验
XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_KEY_TMP="/tmp/xanmod-archive-key.tmp"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_FP_EXPECTED="D38D7D1DA1349567ADED882D86F7D09EE734E623"

echo -e "${YELLOW}  下载并校验 XanMod GPG Key...${NC}"
if ! wget -qO "$XANMOD_KEY_TMP" "$XANMOD_KEY_URL"; then
    fail "下载 GPG Key 失败。"
    exit 1
fi

XANMOD_FP_FOUND=$(gpg --with-colons --show-keys "$XANMOD_KEY_TMP" 2>/dev/null | \
    awk -F: '/^fpr/ {print $10; exit}')
if [ -z "$XANMOD_FP_FOUND" ]; then
    fail "无法提取 GPG Key 指纹。"
    rm -f "$XANMOD_KEY_TMP"
    exit 1
fi
if [ "$XANMOD_FP_FOUND" != "$XANMOD_FP_EXPECTED" ]; then
    fail "GPG Key 指纹不匹配！预期 $XANMOD_FP_EXPECTED，实际 $XANMOD_FP_FOUND"
    rm -f "$XANMOD_KEY_TMP"
    exit 1
fi
ok "GPG Key 指纹校验通过"

mkdir -p /etc/apt/keyrings
if gpg --dearmor --yes -o "$XANMOD_KEYRING" "$XANMOD_KEY_TMP"; then
    rm -f "$XANMOD_KEY_TMP"
    chmod 644 "$XANMOD_KEYRING"
    ok "GPG Key 已导入到 $XANMOD_KEYRING"
else
    fail "GPG Key 导入失败。"
    rm -f "$XANMOD_KEY_TMP"
    exit 1
fi

# 7d. 添加仓库
. /etc/os-release
if [ -z "${VERSION_CODENAME:-}" ]; then
    fail "无法确定 VERSION_CODENAME。"
    exit 1
fi
echo "deb [signed-by=$XANMOD_KEYRING] http://deb.xanmod.org ${VERSION_CODENAME} main" \
    > /etc/apt/sources.list.d/xanmod-release.list
ok "XanMod 源已添加"

if apt-get update -qq; then
    ok "apt 索引更新成功（含 XanMod 源）"
else
    fail "添加 XanMod 源后 apt-get update 失败。"
    exit 1
fi

# 7e. CPU 检测
FLAGS="$(grep -m1 '^flags' /proc/cpuinfo || true)"
has_flag() { echo "$FLAGS" | grep -qw "$1"; }

if has_flag avx && has_flag avx2 && has_flag bmi1 && has_flag bmi2 && \
   has_flag f16c && has_flag fma && has_flag lzcnt && has_flag movbe && has_flag xsave; then
    XANMOD_VER="x64v3"
elif has_flag cx16 && has_flag lahf_lm && has_flag popcnt && \
     has_flag ssse3 && has_flag sse4_1 && has_flag sse4_2; then
    XANMOD_VER="x64v2"
else
    fail "CPU 不满足 x86-64-v2，停止安装。"
    exit 1
fi
ok "CPU 兼容性: $XANMOD_VER"
    # 7f. 安装 XanMod
    echo -e "${YELLOW}  安装 linux-xanmod-$XANMOD_VER ...${NC}"
    if apt-get install -y -qq --no-install-recommends "linux-xanmod-$XANMOD_VER"; then
        ok "linux-xanmod-$XANMOD_VER 安装成功"
    else
        fail "XanMod 内核安装失败。"
        exit 1
    fi

    XANMOD_KERNELS=$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | grep '^linux-image-.*xanmod' | sort -u || true)
    if [ -z "$XANMOD_KERNELS" ]; then
        fail "XanMod kernel package 未安装成功。"
        exit 1
    fi
    ok "已安装: $XANMOD_KERNELS"

    LATEST_XANMOD_KERNEL=$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -E 'xanmod' | sort -V | tail -n1)
    if [ -z "$LATEST_XANMOD_KERNEL" ]; then
        fail "找不到 XanMod /lib/modules。"
        exit 1
    fi
    ok "内核版本: $LATEST_XANMOD_KERNEL"

    # 7h. 更新 initramfs / bootloader
    echo -e "${YELLOW}  更新 initramfs 与 bootloader...${NC}"
    if command -v update-initramfs >/dev/null 2>&1; then
        if update-initramfs -u -k "$LATEST_XANMOD_KERNEL"; then
            ok "initramfs 已更新"
        else
            fail "initramfs 更新失败。"
            exit 1
        fi
    fi
    if command -v update-grub >/dev/null 2>&1; then
        if update-grub; then
            ok "GRUB 配置已更新"
        else
            fail "GRUB 更新失败。"
            exit 1
        fi
    fi

    # 7i. 确保下次启动进入 XanMod
    GRUB_CFG="/etc/default/grub"
    if [ -f "$GRUB_CFG" ]; then
        if grep -q '^GRUB_DEFAULT=' "$GRUB_CFG"; then
            CURRENT_DEFAULT=$(grep '^GRUB_DEFAULT=' "$GRUB_CFG" | cut -d= -f2 | tr -d '"')
            if [ "$CURRENT_DEFAULT" != "0" ] && [ "$CURRENT_DEFAULT" != "saved" ]; then
                sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' "$GRUB_CFG"
                update-grub
                ok "GRUB_DEFAULT 已设为 0（XanMod 将默认启动）"
            else
                ok "GRUB_DEFAULT 已是 $CURRENT_DEFAULT，无需修改"
            fi
        else
            echo "GRUB_DEFAULT=0" >> "$GRUB_CFG"
            update-grub
            ok "GRUB_DEFAULT 已追加为 0（XanMod 将默认启动）"
        fi
    else
        warn "未找到 /etc/default/grub，请手动确认启动顺序。"
    fi

    # ---------------------------------------------------------------------------
    # STEP 8/8: 重启提示
    # ---------------------------------------------------------------------------
    step "[STEP 8/8] 准备重启"

    echo -e "${GREEN}XanMod 安装完成，系统将在 5 秒后重启。${NC}"
    echo -e "${YELLOW}重启后请再次运行此脚本，将自动执行 cleanup。${NC}"
    sync
    sleep 5
    reboot

fi  # RUN_CLEANUP == 0

# =========================================================================
# PHASE 2: Cleanup（仅在 XanMod 内核运行时执行）
# =========================================================================
if [ "$RUN_CLEANUP" -eq 1 ]; then

    # ---------------------------------------------------------------------------
    # STEP 1/6: 验证当前内核
    # ---------------------------------------------------------------------------
    step "[STEP 1/6] 验证当前内核"

    if [[ "$CURRENT_KERNEL" == *xanmod* ]]; then
        ok "当前运行 XanMod 内核: $CURRENT_KERNEL"
    else
        fail "当前内核不是 XanMod: $CURRENT_KERNEL，请重启并选择 XanMod 内核后重试。"
        exit 1
    fi

    # ---------------------------------------------------------------------------
    # STEP 2/6: 删除所有非 XanMod 内核及元包
    # ---------------------------------------------------------------------------
    step "[STEP 2/6] 删除旧内核与元包"

    echo -e "${YELLOW}  查找所有已安装的内核和头文件包...${NC}"
    OLD_KERNEL_PKGS=$(dpkg --list | awk '/^ii/ && $2 ~ /^linux-image|^linux-headers|^linux-modules/ && $2 !~ /xanmod/ {print $2}')
    OLD_META_PKGS=$(dpkg --list | awk '/^ii/ && $2 ~ /^linux-image-amd64|^linux-headers-amd64|^linux-image-rt|^linux-headers-rt|^linux-image-cloud|^linux-headers-cloud/ {print $2}')

    REMOVE_PKGS=$(echo "$OLD_KERNEL_PKGS $OLD_META_PKGS" | tr ' ' '\n' | sort -u | grep -v '^$')

    if [ -z "$REMOVE_PKGS" ]; then
        ok "未发现需要删除的旧内核或元包"
    else
        echo -e "${YELLOW}  即将删除以下包：${NC}"
        echo "$REMOVE_PKGS" | sed 's/^/    /'
        if apt-get purge -y -qq $REMOVE_PKGS; then
            ok "旧内核及元包已删除"
        else
            fail "删除旧内核失败，请检查包管理器状态。"
            exit 1
        fi
    fi

    # ---------------------------------------------------------------------------
    # STEP 3/6: 删除 QEMU 虚拟化相关包
    # ---------------------------------------------------------------------------
    step "[STEP 3/6] 删除 QEMU 虚拟化相关包"

    QEMU_PKGS=$(dpkg --list | awk '/^ii/ && $2 ~ /^qemu/ {print $2}')
    if [ -z "$QEMU_PKGS" ]; then
        ok "未发现 QEMU 相关包"
    else
        echo -e "${YELLOW}  即将删除 QEMU 相关包：${NC}"
        echo "$QEMU_PKGS" | sed 's/^/    /'
        if apt-get purge -y -qq $QEMU_PKGS; then
            ok "QEMU 相关包已删除"
        else
            fail "删除 QEMU 包失败。"
            exit 1
        fi
    fi

    # ---------------------------------------------------------------------------
    # STEP 4/6: 最终系统清理
    # ---------------------------------------------------------------------------
    step "[STEP 4/6] 最终系统清理"

    echo -e "${YELLOW}  清理孤立包、缓存及残留配置...${NC}"
    if apt-get autoremove --purge -y -qq && apt-get autoclean -y -qq && apt-get clean -qq; then
        ok "孤立包与缓存已清理"
    else
        warn "部分清理失败，但不影响主流程。"
    fi

    RC_PKGS=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}' || true)
    if [ -n "$RC_PKGS" ]; then
        if echo "$RC_PKGS" | xargs -r apt-get purge -y -qq; then
            ok "残留配置文件已清除"
        else
            warn "部分残留配置清除失败。"
        fi
    else
        ok "无残留配置文件"
    fi

    # ---------------------------------------------------------------------------
    # STEP 5/6: 清理所有日志
    # ---------------------------------------------------------------------------
    step "[STEP 5/6] 清理所有日志"

    echo -e "${YELLOW}  清理 journald 日志...${NC}"
    if journalctl --vacuum-size=5M --vacuum-time=1d 2>/dev/null; then
        ok "journald 日志已清理"
    else
        warn "journald 清理失败（可能无日志）"
    fi

    echo -e "${YELLOW}  清空所有常规日志文件...${NC}"
    find /var/log -type f -name "*.log" -exec sh -c 'echo > "$1"' _ {} \; 2>/dev/null
    find /var/log -type f \( -name "*.log.1" -o -name "*.log.*" -o -name "*.gz" \) -delete 2>/dev/null
    if [ -d /var/log/installer ]; then rm -rf /var/log/installer; fi
    find /var/backups -type f -delete 2>/dev/null

    # 重启日志服务
    if systemctl is-enabled --quiet rsyslog 2>/dev/null || systemctl status rsyslog >/dev/null 2>&1; then
        systemctl restart rsyslog 2>/dev/null || warn "rsyslog 重启失败"
    fi
    if systemctl is-enabled --quiet systemd-journald 2>/dev/null; then
        systemctl restart systemd-journald 2>/dev/null || warn "systemd-journald 重启失败"
    fi

    ok "所有日志已清理"

    # ---------------------------------------------------------------------------
    # STEP 6/6: 最终验证
    # ---------------------------------------------------------------------------
    step "[STEP 6/6] 最终验证"

    if [[ "$(uname -r)" == *xanmod* ]]; then
        ok "内核验证通过: $(uname -r)"
    else
        fail "内核验证失败！"
    fi

    # 验证旧内核包是否已删除
    if dpkg --list | awk '/^ii/ && $2 ~ /^linux-image/ && $2 !~ /xanmod/ {print $2}' | grep -q .; then
        warn "仍存在非 XanMod 的 linux-image 包，请检查。"
    else
        ok "无残留旧内核包"
    fi

    # 验证 QEMU 是否删除
    if dpkg --list | awk '/^ii/ && $2 ~ /^qemu/ {print $2}' | grep -q .; then
        warn "仍存在 QEMU 相关包，请检查。"
    else
        ok "无 QEMU 相关包残留"
    fi

    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN} Cleanup 完成，系统已极度精简。${NC}"
    echo -e "${GREEN}=============================================${NC}"
fi
