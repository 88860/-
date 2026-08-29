#!/bin/bash
# ==============================================================================
# Debian 13 (Trixie) Native Optimizer
#
# 1. 更换 XanMod 内核 (已修复 CPU 架构探测，支持 v1 兜底)
# 2. 暴力清理旧内核 + 系统更新 + TCP/BBR/FQ + 日志优化
#    └─ 包含越权强改底层 vendor 队列为 fq，及强删非运行态老内核
# 3. 一键清理日志、垃圾、旧内核及常见残留
# 4. 一键 DD 全新 Debian 13 系统
# 5. 只读真实性详细审计
# ==============================================================================

set -Eeuo pipefail
shopt -s nullglob

export DEBIAN_FRONTEND=noninteractive
umask 022

readonly C_BLUE='\033[1;34m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[0;36m'
readonly C_RED='\033[1;31m'
readonly C_GRAY='\033[0;37m'
readonly C_WHITE='\033[1;37m'
readonly C_NC='\033[0m'

readonly JOURNAL_MAX_USE="100M"
readonly JOURNAL_MAX_FILE_SIZE="10M"
readonly JOURNAL_MAX_FILES="10"
readonly JOURNAL_MAX_RETENTION="7day"
readonly LOGROTATE_ROTATE="3"

# ------------------------------ 基础输出 --------------------------------------

log()      { printf '%b\n' "${C_CYAN}>>${C_NC} $*"; }
pass()     { printf '  %b\n' "${C_GREEN}[成功]${C_NC} $*"; }
warn()     { printf '  %b\n' "${C_YELLOW}[警告]${C_NC} $*"; }
fail()     { printf '  %b\n' "${C_RED}[失败]${C_NC} $*" >&2; }
skip()     { printf '  %b\n' "${C_GRAY}[跳过]${C_NC} $*"; }
found()    { printf '  %b\n' "${C_GREEN}[发现]${C_NC} $*"; }
modify()   { printf '  %b\n' "${C_YELLOW}[修改]${C_NC} $*"; }
verify()   { printf '  %b\n' "${C_GREEN}[验证]${C_NC} $*"; }
info()     { printf '  %b\n' "${C_GRAY}[信息]${C_NC} $*"; }

die() {
    fail "$*"
    exit 1
}

on_error() {
    local rc=$?
    fail "脚本在第 ${BASH_LINENO[0]:-未知} 行附近异常退出，返回码: $rc"
    exit "$rc"
}
trap on_error ERR

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 权限运行。"
}

check_os() {
    log "检测操作系统..."
    [[ -r /etc/os-release ]] || die "找不到 /etc/os-release。"
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]; then
        die "本脚本仅支持 Debian 13 (Trixie)。"
    fi
    pass "确认 Debian 13 (Trixie): ${PRETTY_NAME:-Debian GNU/Linux 13 (trixie)}"
}

check_systemd() {
    log "检测 systemd..."
    command -v systemctl >/dev/null 2>&1 || die "systemctl 不存在。"
    pass "systemd 环境检测通过"
}

check_dpkg() {
    log "检查 DPKG..."
    if dpkg --audit >/dev/null 2>&1; then
        pass "DPKG 状态正常"
    else
        warn "DPKG 存在待处理状态；尝试 dpkg --configure -a。"
        dpkg --configure -a >/dev/null 2>&1 || true
    fi
}

ensure_basic_tools() {
    log "检查基础工具..."
    local missing=()
    for pkg in ca-certificates wget curl gpg; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
    done

    if ((${#missing[@]})); then
        log "安装缺失基础工具: ${missing[*]}"
        apt-get update -qq
        apt-get install -y --no-install-recommends "${missing[@]}"
    fi
    pass "基础工具已就绪"
}

# ------------------------------ sysctl 动态探测 --------------------------------

SYSCTL_DIRS=(
    /etc/sysctl.d
    /run/sysctl.d
    /usr/local/lib/sysctl.d
    /usr/lib/sysctl.d
    /lib/sysctl.d
)

declare -A SYSCTL_SOURCE
declare -A SYSCTL_VALUE
declare -A SYSCTL_IS_ADMIN

sysctl_key_to_path() {
    local key="$1"
    printf '/proc/sys/%s\n' "${key//./\/}"
}

sysctl_effective_source() {
    local key="$1"
    local best="" f
    local -a ordered=()
    local d

    for d in "${SYSCTL_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.conf; do
            [[ -f "$f" ]] && ordered+=("$f")
        done
    done

    local line k v
    for f in "${ordered[@]}"; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$line" || "${line:0:1}" == "#" || "${line:0:1}" == ";" ]] && continue
            if [[ "$line" =~ ^-?[[:space:]]*([^[:space:]=]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                k="${BASH_REMATCH[1]}"
                v="${BASH_REMATCH[2]}"
                k="${k//\//.}"
                [[ "$k" == "$key" ]] || continue
                best="$f"
                SYSCTL_VALUE["$key"]="$v"
            fi
        done < "$f"
    done

    if [[ -n "$best" ]]; then
        SYSCTL_SOURCE["$key"]="$best"
        if [[ "$best" == /etc/* ]]; then
            SYSCTL_IS_ADMIN["$key"]=1
        else
            SYSCTL_IS_ADMIN["$key"]=0
        fi
    else
        SYSCTL_SOURCE["$key"]=""
        SYSCTL_IS_ADMIN["$key"]=0
    fi
}

replace_sysctl_existing_line() {
    local file="$1" key="$2" value="$3"
    local tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
        BEGIN { done=0 }
        {
            line=$0
            trimmed=line
            sub(/^[ \t]+/, "", trimmed)
            if (trimmed !~ /^[#;]/ && trimmed ~ "^[[:space:]]*"?key"?"?[[:space:]]*=") {
                if (!done) {
                    print key " = " value
                    done=1
                }
                next
            }
            print
        }
        END { if (!done) exit 2 }
    ' "$file" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    if cmp -s "$file" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# 增加了 force_vendor 参数，允许跨权限强改底层配置 (专为强制修改 fq 设计)
modify_existing_sysctl() {
    local key="$1" target="$2" force_vendor="${3:-0}"
    sysctl_effective_source "$key"

    local src="${SYSCTL_SOURCE[$key]:-}"
    if [[ -z "$src" ]]; then
        skip "$key：配置链中无现成配置项；不创建文件。"
        return 0
    fi

    found "$key -> $src"

    if [[ "${SYSCTL_IS_ADMIN[$key]:-0}" != 1 ]] && [[ "$force_vendor" != 1 ]]; then
        skip "$key：当前属于系统只读来源，原生优化模块不直接修改。"
        return 0
    fi

    modify "原位精准修改 $src：$key = $target"
    if replace_sysctl_existing_line "$src" "$key" "$target"; then
        pass "持久化修改成功: $src -> $key=$target"
    else
        fail "无法精准修改现有 sysctl 项: $src -> $key"
        return 1
    fi
}

reload_sysctl() {
    log "重新加载 systemd-sysctl..."
    if systemctl restart systemd-sysctl.service >/dev/null 2>&1; then
        pass "systemd-sysctl.service 重启成功"
    else
        warn "systemd-sysctl.service 重启失败。"
    fi
}

read_sysctl() {
    local key="$1"
    local p
    p="$(sysctl_key_to_path "$key")"
    if [[ -r "$p" ]]; then
        tr '\n' ' ' < "$p" | sed 's/[[:space:]]*$//'
    else
        printf '不可用'
    fi
}

# ------------------------------ Option 2 专属老内核强力清理 ------------------

force_cleanup_old_kernels() {
    log "正在彻底卸载非当前运行内核及内核元包..."
    local current
    current="$(uname -r)"
    pass "受保护的当前运行内核: $current"

    local targets=()
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        # 严格排除当前正在运行的内核
        [[ "$p" == *"$current"* ]] && continue
        targets+=("$p")
    done < <(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | grep -E '^linux-(image|headers|modules|kbuild|config)')

    if ((${#targets[@]})); then
        info "将卸载以下内核及元包 (包含旧版原生 Debian 内核等):"
        printf '      %s\n' "${targets[@]}"
        apt-get purge -y -qq "${targets[@]}"
        pass "多余内核及元包已彻底清理完毕。"
        if command -v update-grub >/dev/null 2>&1; then
            update-grub >/dev/null 2>&1 || true
            pass "GRUB 引导菜单已重建"
        fi
    else
        pass "未发现需要卸载的旧内核或元包。"
    fi
}

# ------------------------------ 网络优化 (TCP/BBR/FQ) -------------------------

optimize_tcp() {
    log "探测与调整 TCP/BBR/FQ..."

    local avail
    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    
    if grep -qw bbr <<<"$avail"; then
        modify_existing_sysctl "net.ipv4.tcp_congestion_control" "bbr"
    fi

    # 第三个参数 1 代表启用“强制修改 Vendor 底层文件”权限，精准修改实际调用的队列文件为 fq
    modify_existing_sysctl "net.core.default_qdisc" "fq" 1

    reload_sysctl

    log "TCP 运行状态验证..."
    verify "net.ipv4.tcp_congestion_control = $(read_sysctl net.ipv4/tcp_congestion_control)"
    verify "net.core.default_qdisc = $(read_sysctl net/core/default_qdisc)"
}

# ------------------------------ Journald 日志优化 -----------------------------

journald_dirs=(
    /etc/systemd/journald.conf.d
    /run/systemd/journald.conf.d
    /usr/local/lib/systemd/journald.conf.d
    /usr/lib/systemd/journald.conf.d
    /lib/systemd/journald.conf.d
)
declare -A JOURNAL_SOURCE

list_journald_files() {
    [[ -f /etc/systemd/journald.conf ]] && printf '%s\n' /etc/systemd/journald.conf
    local d f
    for d in "${journald_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.conf; do
            [[ -f "$f" ]] && printf '%s\n' "$f"
        done
    done
}

journald_effective_source() {
    local key="$1"
    local best=""
    local f line k v

    while IFS= read -r f; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$line" || "${line:0:1}" == "#" || "${line:0:1}" == ";" ]] && continue
            if [[ "$line" =~ ^[[:space:]]*([^#;[:space:]=]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                k="${BASH_REMATCH[1]}"
                v="${BASH_REMATCH[2]}"
                [[ "$k" == "$key" ]] || continue
                best="$f"
            fi
        done < "$f"
    done < <(list_journald_files)

    JOURNAL_SOURCE["$key"]="$best"
}

replace_journald_existing_line() {
    local file="$1" key="$2" value="$3"
    local tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
        BEGIN { done=0 }
        {
            line=$0
            trimmed=line
            sub(/^[ \t]+/, "", trimmed)
            if (trimmed !~ /^[#;]/ && trimmed ~ ("^" key "[[:space:]]*=")) {
                if (!done) {
                    print key "=" value
                    done=1
                }
                next
            }
            print
        }
        END { if (!done) exit 2 }
    ' "$file" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    if cmp -s "$file" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

modify_existing_journald() {
    local key="$1" value="$2"
    journald_effective_source "$key"
    local src="${JOURNAL_SOURCE[$key]:-}"

    if [[ -z "$src" ]]; then
        return 0
    fi

    if [[ "$src" != /etc/systemd/* ]]; then
        return 0
    fi

    if replace_journald_existing_line "$src" "$key" "$value"; then
        pass "持久化修改成功: $src -> $key=$value"
    fi
}

optimize_journald() {
    log "调整 journald 日志限制..."
    modify_existing_journald SystemMaxUse "$JOURNAL_MAX_USE"
    modify_existing_journald SystemMaxFileSize "$JOURNAL_MAX_FILE_SIZE"
    modify_existing_journald SystemMaxFiles "$JOURNAL_MAX_FILES"
    modify_existing_journald RuntimeMaxUse "$JOURNAL_MAX_USE"
    modify_existing_journald RuntimeMaxFileSize "$JOURNAL_MAX_FILE_SIZE"
    modify_existing_journald RuntimeMaxFiles "$JOURNAL_MAX_FILES"
    modify_existing_journald MaxRetentionSec "$JOURNAL_MAX_RETENTION"

    systemctl restart systemd-journald.service >/dev/null 2>&1 || true
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time="$JOURNAL_MAX_RETENTION" --vacuum-size="$JOURNAL_MAX_USE" >/dev/null 2>&1 || true
}

# ------------------------------ Logrotate 优化 --------------------------------

optimize_logrotate() {
    log "调整 logrotate 日志限制..."
    command -v logrotate >/dev/null 2>&1 || return 0

    local f
    while IFS= read -r f; do
        if grep -Eq '^[[:space:]]*rotate[[:space:]]+[0-9]+' "$f"; then
            sed -E -i "s/^[[:space:]]*rotate[[:space:]]+[0-9]+/rotate $LOGROTATE_ROTATE/" "$f"
        fi
    done < <(find /etc/logrotate.d -type f 2>/dev/null; echo /etc/logrotate.conf)
    logrotate -d /etc/logrotate.conf >/dev/null 2>&1 || true
}

# ------------------------------ 系统更新 --------------------------------------

system_update() {
    log "修复/完成未配置的软件包..."
    dpkg --configure -a >/dev/null 2>&1 || true

    log "更新 Debian 软件源..."
    apt-get update -qq || die "APT update 失败。"
    
    log "执行 Debian 原生 full-upgrade..."
    apt-get full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --no-install-recommends || die "系统 full-upgrade 失败。"
    ensure_basic_tools
}

# ------------------------------ Option 2 核心入口 -----------------------------

optimize_system() {
    printf '\n%b\n' "${C_BLUE}====================================================${C_NC}"
    printf '%b\n' "${C_BLUE} 系统更新 + 旧内核/元包强删 + TCP + 日志优化 ${C_NC}"
    printf '%b\n\n' "${C_BLUE}====================================================${C_NC}"

    force_cleanup_old_kernels
    system_update
    optimize_tcp
    optimize_journald
    optimize_logrotate

    printf '\n%b\n' "${C_GREEN}====================================================${C_NC}"
    printf '%b\n' "${C_GREEN} 选项 2 执行完成 ${C_NC}"
    printf '%b\n\n' "${C_GREEN}====================================================${C_NC}"
}

# ------------------------------ 一键清理 -----------------------------------------

cleanup_all() {
    printf '\n%b\n' "${C_BLUE}====================================================${C_NC}"
    printf '%b\n' "${C_BLUE} 一键清理：日志 / APT / 垃圾 ${C_NC}"
    printf '%b\n\n' "${C_BLUE}====================================================${C_NC}"

    # APT清理
    log "清理 APT / DPKG 垃圾..."
    apt-get autoremove --purge -y >/dev/null 2>&1 || true
    apt-get autoclean -y >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true
    local rc
    rc="$(dpkg -l 2>/dev/null | awk '$1=="rc"{print $2}')"
    if [[ -n "$rc" ]]; then
        # shellcheck disable=SC2086
        xargs -r apt-get purge -y -qq <<< "$rc" || true
    fi

    # 日志文件清理
    log "清理轮转日志及空普通活动日志..."
    find /var/log -xdev -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.old' -o -name '*.log.[0-9]' \) -delete 2>/dev/null || true
    while IFS= read -r -d '' f; do
        [[ "$f" == *journal* || "$f" == *wtmp || "$f" == *btmp || "$f" == *lastlog ]] && continue
        if file "$f" 2>/dev/null | grep -qiE 'text|empty'; then
            : > "$f"
        fi
    done < <(find /var/log -xdev -type f -size +0c -print0 2>/dev/null)

    pass "一键清理完成"
}

# ------------------------------ 一键 DD ---------------------------------------

reinstall_debian13() {
    printf '\n%b\n' "${C_RED}====================================================${C_NC}"
    printf '%b\n' "${C_RED} 危险操作：一键 DD 全新 Debian 13 ${C_NC}"
    printf '%b\n\n' "${C_RED}====================================================${C_NC}"

    warn "此操作将重新安装系统为官方纯净 Debian 13，全盘数据将被销毁！"
    local confirm=""
    read -r -p "确认执行重装？请输入 YES 并回车: " confirm < /dev/tty || return 0
    if [[ "$confirm" != "YES" ]]; then
        skip "已取消重装系统。"
        return 0
    fi

    ensure_basic_tools
    log "下载 reinstall 重装脚本..."
    curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O "${_##*/}" "$_"
    log "启动一键重装到 Debian 13..."
    bash reinstall.sh debian13
}

# ------------------------------ XanMod ----------------------------------------

cpu_level() {
    if [[ -x /lib64/ld-linux-x86-64.so.2 ]]; then
        local detected
        detected="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -oE 'x86-64-v[1-4]' | sort -V | tail -n1 || true)"
        if [[ "$detected" == "x86-64-v4" || "$detected" == "x86-64-v3" ]]; then
            echo "x64v3"
        elif [[ "$detected" == "x86-64-v2" ]]; then
            echo "x64v2"
        else
            echo "x64v1"
        fi
    else
        echo "x64v1"
    fi
}

install_xanmod() {
    printf '\n%b\n' "${C_BLUE}====================================================${C_NC}"
    printf '%b\n' "${C_BLUE} XanMod：官方第三方内核安装 ${C_NC}"
    printf '%b\n\n' "${C_BLUE}====================================================${C_NC}"

    ensure_basic_tools
    local codename="${VERSION_CODENAME:-trixie}"
    [[ "$codename" == "trixie" ]] || die "当前系统非 trixie。"

    local level
    level="$(cpu_level)"
    info "CPU ABI 检测结果: ${level} (完美向下兼容)"

    local keyring="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
    local repo="/etc/apt/sources.list.d/xanmod-release.list"

    log "准备 XanMod keyring 目录..."
    mkdir -p /etc/apt/keyrings

    log "获取 XanMod 官方签名密钥..."
    if wget -qO- https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o "$keyring"; then
        chmod 0644 "$keyring"
        pass "XanMod 官方 keyring 获取成功"
    else
        die "XanMod 官方签名密钥获取失败。"
    fi

    log "写入 XanMod 官方 Debian 13 Trixie APT 源..."
    printf 'deb [signed-by=%s arch=amd64] http://deb.xanmod.org %s main\n' "$keyring" "$codename" > "$repo"
    
    log "验证 XanMod APT 源..."
    if ! apt-get update -qq; then
        rm -f "$repo" "$keyring"
        die "XanMod APT 源不可用，已回滚。"
    fi

    local pkg="linux-xanmod-${level}"
    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        warn "未找到专属优化包 $pkg，自动安全降级至兼容包..."
        if apt-cache show "linux-xanmod-lts-x64v1" >/dev/null 2>&1; then
            pkg="linux-xanmod-lts-x64v1"
        else
            pkg="linux-xanmod-x64v2"
        fi
    fi

    log "安装 XanMod 内核: $pkg"
    apt-get install -y --no-install-recommends "$pkg" || die "XanMod 内核安装失败。"
    command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1 || true

    printf '\n%b\n' "${C_GREEN} XanMod 安装完成。现在必须 reboot。${C_NC}"
}

# ------------------------------ 完整版详细审计 --------------------------------

audit_sysctl_key() {
    local key="$1"
    sysctl_effective_source "$key"

    local source="${SYSCTL_SOURCE[$key]:-}"
    local value
    value="$(read_sysctl "$key")"

    printf '\n  %b\n' "${C_WHITE}$key${C_NC}"
    printf '      当前值: %s\n' "$value"

    if [[ -n "$source" ]]; then
        printf '      实际配置来源: %s\n' "$source"
        if [[ "${SYSCTL_IS_ADMIN[$key]:-0}" == 1 ]]; then
            printf '      持久化管理员配置: %b\n' "${C_GREEN}是${C_NC}"
        else
            printf '      持久化管理员配置: %b\n' "${C_GRAY}否（系统/发行版来源）${C_NC}"
        fi
    else
        printf '      实际配置来源: %b\n' "${C_GRAY}无现成配置项 / 内核默认${C_NC}"
    fi
}

audit_tcp() {
    printf '\n%b\n' "${C_BLUE}----------------------------------------------------${C_NC}"
    printf '%b\n' "${C_BLUE}[TCP / BBR / FQ 真实性审计]${C_NC}"

    local kernel
    kernel="$(uname -r)"
    printf '  当前运行内核: %s\n' "$kernel"

    if grep -qi xanmod <<<"$kernel"; then
        pass "当前确实正在运行 XanMod 内核"
    else
        warn "当前没有运行 XanMod 内核"
    fi

    local avail current qdisc
    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

    if grep -qw bbr <<<"$avail"; then
        pass "BBR：当前内核提供"
    else
        warn "BBR：当前内核没有提供"
    fi

    if [[ "$current" == "bbr" ]]; then
        pass "BBR：当前 TCP 实际正在使用 bbr"
    else
        warn "BBR：当前实际 congestion control = ${current:-未知}"
    fi

    if [[ "$qdisc" == "fq" ]]; then
        pass "FQ：当前默认 qdisc = fq"
    else
        warn "FQ：当前默认 qdisc = ${qdisc:-未知}"
    fi

    audit_sysctl_key "net.ipv4.tcp_congestion_control"
    audit_sysctl_key "net.core.default_qdisc"
    audit_sysctl_key "net.core.somaxconn"
    audit_sysctl_key "net.ipv4.tcp_max_syn_backlog"
    audit_sysctl_key "net.ipv4.ip_local_port_range"
}

JOURNAL_KEYS=( SystemMaxUse SystemMaxFileSize SystemMaxFiles RuntimeMaxUse RuntimeMaxFileSize RuntimeMaxFiles MaxRetentionSec )

audit_journald() {
    printf '\n%b\n' "${C_BLUE}----------------------------------------------------${C_NC}"
    printf '%b\n' "${C_BLUE}[Journald 真实性审计]${C_NC}"

    local key src
    for key in "${JOURNAL_KEYS[@]}"; do
        journald_effective_source "$key"
        src="${JOURNAL_SOURCE[$key]:-}"
        if [[ -n "$src" ]]; then
            found "$key -> $src"
        else
            info "$key -> 当前没有显式配置（使用 systemd 默认/计算值）"
        fi
    done
    printf '\n'
    journalctl --disk-usage 2>/dev/null || true
}

audit_logrotate() {
    printf '\n%b\n' "${C_BLUE}----------------------------------------------------${C_NC}"
    printf '%b\n' "${C_BLUE}[Logrotate 真实性审计]${C_NC}"

    if ! command -v logrotate >/dev/null 2>&1; then
        skip "logrotate 未安装"
        return
    fi

    local files=()
    local f
    while IFS= read -r f; do files+=("$f"); done < <(find /etc/logrotate.d -type f 2>/dev/null; echo /etc/logrotate.conf)

    found "logrotate 配置文件数量: ${#files[@]}"
    
    if logrotate -d /etc/logrotate.conf >/dev/null 2>&1; then
        pass "logrotate 配置语法正常"
    else
        warn "logrotate 配置语法异常"
    fi

    local rotate_found=0
    for f in "${files[@]}"; do
        if grep -Eq '^[[:space:]]*rotate[[:space:]]+[0-9]+' "$f"; then
            rotate_found=1
            printf '      %s: %s\n' "$f" "$(grep -E '^[[:space:]]*rotate[[:space:]]+[0-9]+' "$f" | head -n1 | sed 's/^[[:space:]]*//')"
        fi
    done
    ((rotate_found)) || info "没有现成 rotate 指令可审计。"
}

audit_kernel() {
    printf '\n%b\n' "${C_BLUE}----------------------------------------------------${C_NC}"
    printf '%b\n' "${C_BLUE}[内核更换真实性审计]${C_NC}"

    local xan
    xan="$(dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | grep '^linux-xanmod-' || true)"
    if [[ -n "$xan" ]]; then
        pass "系统已安装 XanMod:"
        printf '      %s\n' "$xan"
    else
        warn "系统没有安装 XanMod 内核包"
    fi

    if command -v grubby >/dev/null 2>&1; then
        grubby --default-kernel 2>/dev/null || true
    elif [[ -L /vmlinuz ]]; then
        printf '  /vmlinuz -> %s\n' "$(readlink -f /vmlinuz)"
    fi
}

audit_logs_size() {
    printf '\n%b\n' "${C_BLUE}----------------------------------------------------${C_NC}"
    printf '%b\n' "${C_BLUE}[系统容量占用审计]${C_NC}"

    printf '  /var/log: '
    du -sh /var/log 2>/dev/null || true
    printf '  文件系统 /: '
    df -h / | tail -n1 || true
}

audit_all() {
    printf '\n%b\n' "${C_CYAN}====================================================${C_NC}"
    printf '%b\n' "${C_CYAN} Debian 13 (Trixie) 真实性详细审计（完全只读） ${C_NC}"
    printf '%b\n\n' "${C_CYAN}====================================================${C_NC}"

    audit_kernel
    audit_tcp
    audit_journald
    audit_logrotate
    audit_logs_size

    printf '\n%b\n' "${C_GREEN}====================================================${C_NC}"
    printf '%b\n' "${C_GREEN} 审计完成：以上结果以当前运行内核、实际配置来源为准。 ${C_NC}"
    printf '%b\n\n' "${C_GREEN}====================================================${C_NC}"
}

# ------------------------------ 菜单交互 --------------------------------------

show_banner() {
    clear 2>/dev/null || true
    printf '%b\n' "${C_CYAN}====================================================${C_NC}"
    printf '%b\n' "${C_CYAN}        Debian 13 (Trixie) Native Optimizer${C_NC}"
    printf '%b\n' "${C_CYAN}        中文输出 / 真实配置链 / 精准持久化${C_NC}"
    printf '%b\n' "${C_CYAN}====================================================${C_NC}"
    printf '%b\n' "${C_GREEN}  1.${C_NC} 更换 XanMod 内核 (已修复 CPU 架构检测)"
    printf '%b\n' "${C_GREEN}     └─ 安装 → reboot → 再运行本脚本执行选项 2${C_NC}"
    printf '%b\n' "${C_GREEN}  2.${C_NC} 强删旧内核/元包 + 系统更新 + TCP/BBR/FQ"
    printf '%b\n' "${C_GREEN}     └─ 包含越权底层强制替换 fq${C_NC}"
    printf '%b\n' "${C_GREEN}  3.${C_NC} 一键清理日志 / 垃圾 / APT 残留"
    printf '%b\n' "${C_GREEN}  4.${C_NC} 一键 DD 重装全新 Debian 13 系统 (危险)"
    printf '%b\n' "${C_GREEN}  5.${C_NC} 真实性详细审计（完全只读）"
    printf '%b\n' "${C_RED}  0.${C_NC} 退出"
    printf '%b\n' "${C_CYAN}====================================================${C_NC}"
}

main() {
    require_root
    check_os
    check_systemd
    check_dpkg

    while true; do
        show_banner
        local choice=""
        read -r -p "请输入 [0-5]: " choice < /dev/tty || exit 0

        case "$choice" in
            1) install_xanmod ;;
            2) optimize_system ;;
            3) cleanup_all ;;
            4) reinstall_debian13 ;;
            5) audit_all ;;
            0)
                printf '%b\n' "${C_GRAY}已安全退出。${C_NC}"
                exit 0
                ;;
            *)
                fail "无效选项，请输入 0-5。"
                ;;
        esac

        printf '\n'
        read -r -p "按 Enter 返回主菜单..." _ < /dev/tty || true
    done
}

main "$@"
