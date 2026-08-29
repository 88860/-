#!/bin/bash
# ==============================================================================
# Debian 13 (Trixie) Native Optimizer
# 中文输出 / 四阶段架构 / 零新建 Debian 原生优化配置
#
# 1. 更换 XanMod 内核
# 2. 系统更新 + TCP/BBR/FQ + Journald/Logrotate 优化
# 3. 一键清理日志、垃圾、旧内核及常见残留
# 4. 只读真实性审计
#
# 设计原则：
# - Debian 原生优化模块不创建新的 sysctl/journald/logrotate 配置文件。
# - 只有当目标参数已经存在于实际配置链中时，才进行原位精准修改。
# - 不把 runtime-only 的 sysctl -w 当成“持久化成功”。
# - XanMod 是唯一明确允许创建第三方 APT keyring/source 文件的模块。
# - 选项 4 完全只读，不修改系统。
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

# ------------------------------ 安全执行 --------------------------------------

run_cmd() {
    local description="$1"
    shift
    log "$description"
    if "$@"; then
        pass "命令执行成功"
        return 0
    fi
    fail "命令执行失败: $*"
    return 1
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 权限运行。"
}

check_os() {
    log "检测操作系统..."
    [[ -r /etc/os-release ]] || die "找不到 /etc/os-release。"
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]; then
        die "本脚本仅支持 Debian 13 (Trixie)。检测到: ${PRETTY_NAME:-未知}"
    fi
    pass "确认 Debian 13 (Trixie): ${PRETTY_NAME:-Debian GNU/Linux 13 (trixie)}"

    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || true)"
    [[ "$arch" == "amd64" ]] || die "当前架构为 ${arch:-未知}，本脚本 XanMod 部分针对 amd64。"
    pass "架构: amd64"
}

check_systemd() {
    log "检测 systemd..."
    command -v systemctl >/dev/null 2>&1 || die "systemctl 不存在。"
    systemctl list-unit-files systemd-sysctl.service >/dev/null 2>&1 ||
        die "systemd-sysctl.service 不存在。"
    systemctl list-unit-files systemd-journald.service >/dev/null 2>&1 ||
        die "systemd-journald.service 不存在。"

    found "systemd-sysctl.service"
    found "systemd-journald.service"

    local sysctl_bin=""
    for p in /usr/lib/systemd/systemd-sysctl /lib/systemd/systemd-sysctl; do
        if [[ -x "$p" ]]; then sysctl_bin="$p"; break; fi
    done
    [[ -n "$sysctl_bin" ]] && found "真实 systemd-sysctl 程序: $sysctl_bin"

    local journald_bin=""
    for p in /usr/lib/systemd/systemd-journald /lib/systemd/systemd-journald; do
        if [[ -x "$p" ]]; then journald_bin="$p"; break; fi
    done
    [[ -n "$journald_bin" ]] && found "真实 systemd-journald 程序: $journald_bin"

    pass "systemd 环境检测通过"
}

check_dpkg() {
    log "检查 DPKG..."
    if dpkg --audit >/dev/null 2>&1; then
        pass "DPKG 状态正常"
    else
        warn "DPKG 存在待处理状态；后续会尝试 dpkg --configure -a。"
    fi
}

ensure_basic_tools() {
    log "检查基础工具..."
    local missing=()
    local cmd pkg
    for cmd in awk sed grep find xargs du df sort head tail cut tr; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    for pkg in ca-certificates wget curl gpg; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
            grep -q 'install ok installed' || missing+=("$pkg")
    done

    # 去重
    if ((${#missing[@]})); then
        local unique=()
        local x seen
        for x in "${missing[@]}"; do
            seen=0
            for pkg in "${unique[@]:-}"; do
                [[ "$pkg" == "$x" ]] && seen=1
            done
            ((seen==0)) && unique+=("$x")
        done

        local packages=()
        for x in "${unique[@]}"; do
            case "$x" in
                ca-certificates|wget|curl|gpg) packages+=("$x") ;;
            esac
        done

        if ((${#packages[@]})); then
            log "安装缺失基础工具: ${packages[*]}"
            apt-get update -qq
            apt-get install -y --no-install-recommends "${packages[@]}"
        fi
    fi

    command -v wget >/dev/null 2>&1 || die "wget 安装/验证失败。"
    command -v curl >/dev/null 2>&1 || die "curl 安装/验证失败。"
    command -v gpg  >/dev/null 2>&1 || die "gpg 安装/验证失败。"
    pass "wget / curl / gpg / ca-certificates 已验证"
}

# ------------------------------ sysctl ----------------------------------------

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

list_sysctl_files() {
    local d f
    for d in "${SYSCTL_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.conf; do
            [[ -f "$f" ]] && printf '%s\n' "$f"
        done
    done
}

sysctl_effective_source() {
    local key="$1"
    local best="" f base
    local key_re
    key_re="${key//./[.]}"
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(list_sysctl_files | sort -u)

    # systemd-sysctl/sysctl.d 的同名文件优先级：
    # /etc > /run > /usr/local/lib > /usr/lib > /lib
    # 对于不同文件名，按 basename 字典序，后加载者覆盖前者。
    # 这里按实际路径层级 + basename 排序，并保留最后命中的管理员文件。
    local -a ordered=()
    local d
    for d in "${SYSCTL_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.conf; do
            [[ -f "$f" ]] && ordered+=("$f")
        done
    done

    local i line k v
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

modify_existing_sysctl() {
    local key="$1" target="$2"
    sysctl_effective_source "$key"

    local src="${SYSCTL_SOURCE[$key]:-}"
    if [[ -z "$src" ]]; then
        skip "$key：实际 sysctl 配置链中没有现成配置项；不创建文件、不追加配置。"
        return 0
    fi

    found "$key -> $src"

    if [[ "${SYSCTL_IS_ADMIN[$key]:-0}" != 1 ]]; then
        skip "$key：当前最终来源属于 Debian/系统默认配置，不在原生优化模块中直接修改。"
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

show_sysctl_chain() {
    log "解析 systemd-sysctl 实际配置链..."
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(list_sysctl_files | sort -u)

    if ((${#files[@]}==0)); then
        warn "未发现 sysctl.d 配置文件。"
    else
        found "实际可见 sysctl 配置文件:"
        printf '      %s\n' "${files[@]}"
    fi
}

reload_sysctl() {
    log "重新加载 systemd-sysctl..."
    if systemctl restart systemd-sysctl.service >/dev/null 2>&1; then
        pass "systemd-sysctl.service 重启成功"
    else
        warn "systemd-sysctl.service 重启失败，将继续进行 runtime 审计。"
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

# ------------------------------ TCP -------------------------------------------

optimize_tcp() {
    printf '\n%b\n' "${C_BLUE}====================================================${C_NC}"
    printf '%b\n' "${C_BLUE} TCP：真实配置链 / BBR / FQ / 精准持久化 ${C_NC}"
    printf '%b\n\n' "${C_BLUE}====================================================${C_NC}"

    show_sysctl_chain

    log "检测当前运行内核..."
    pass "当前运行内核: $(uname -r)"

    local avail
    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if grep -qw bbr <<<"$avail"; then
        pass "当前运行内核提供 BBR: $avail"
    else
        skip "当前运行内核没有 BBR；不创建模块加载配置，不创建 sysctl 配置。"
    fi

    # 只优化已经存在的管理员配置项。
    # 如果不存在，绝不创建新文件。
    if grep -qw bbr <<<"$avail"; then
        modify_existing_sysctl "net.ipv4.tcp_congestion_control" "bbr"
    fi

    # FQ 只在已经存在管理员配置项时修改。
    # 不为了“优化”而新建 sysctl 配置。
    modify_existing_sysctl "net.core.default_qdisc" "fq"

    # 以下参数不作为强制优化项，避免把 Debian 默认值误称为性能优化。
    info "somaxconn / tcp_max_syn_backlog / ip_local_port_range 不强制改写；仅审计其实际值和来源。"

    reload_sysctl

    log "TCP 运行状态验证..."
    verify "net.ipv4.tcp_available_congestion_control = $(read_sysctl net.ipv4/tcp_available_congestion_control)"
    verify "net.ipv4.tcp_congestion_control = $(read_sysctl net.ipv4/tcp_congestion_control)"
    verify "net.core.default_qdisc = $(read_sysctl net/core/default_qdisc)"
    verify "net.core.somaxconn = $(read_sysctl net/core/somaxconn)"
    verify "net.ipv4.tcp_max_syn_backlog = $(read_sysctl net/ipv4/tcp_max_syn_backlog)"
    verify "net.ipv4.ip_local_port_range = $(read_sysctl net/ipv4/ip_local_port_range)"
}

# ------------------------------ journald --------------------------------------

JOURNAL_KEYS=(
    SystemMaxUse
    SystemMaxFileSize
    SystemMaxFiles
    RuntimeMaxUse
    RuntimeMaxFileSize
    RuntimeMaxFiles
    MaxRetentionSec
)

declare -A JOURNAL_SOURCE

journald_dirs=(
    /etc/systemd/journald.conf.d
    /run/systemd/journald.conf.d
    /usr/local/lib/systemd/journald.conf.d
    /usr/lib/systemd/journald.conf.d
    /lib/systemd/journald.conf.d
)

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
        skip "$key：实际 journald 配置链中没有现成管理员配置项；不创建配置文件。"
        return 0
    fi

    found "$key -> $src"

    if [[ "$src" != /etc/systemd/* ]]; then
        skip "$key：最终来源不是 /etc 下管理员配置，保持发行版/系统配置不动。"
        return 0
    fi

    modify "原位精准修改 $src：$key=$value"
    if replace_journald_existing_line "$src" "$key" "$value"; then
        pass "持久化修改成功: $src -> $key=$value"
    else
        fail "无法修改现有 journald 配置项: $src -> $key"
        return 1
    fi
}

optimize_journald() {
    printf '\n%b\n' "${C_BLUE}====================================================${C_NC}"
    printf '%b\n' "${C_BLUE} Journald：真实配置链 / 精准修改 / 容量限制 ${C_NC}"
    printf '%b\n\n' "${C_BLUE}====================================================${C_NC}"

    log "解析 journald 实际配置链..."
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(list_journald_files)

    if ((${#files[@]})); then
        found "实际可见 journald 配置:"
        printf '      %s\n' "${files[@]}"
    else
        warn "没有发现现有 journald 配置文件。"
    fi

    # 坚持“不新建配置文件”：只修改已存在的管理员项目。
    modify_existing_journald SystemMaxUse "$JOURNAL_MAX_USE"
    modify_existing_journald SystemMaxFileSize "$JOURNAL_MAX_FILE_SIZE"
    modify_existing_journald SystemMaxFiles "$JOURNAL_MAX_FILES"
    modify_existing_journald RuntimeMaxUse "$JOURNAL_MAX_USE"
    modify_existing_journald RuntimeMaxFileSize "$JOURNAL_MAX_FILE_SIZE"
    modify_existing_journald RuntimeMaxFiles "$JOURNAL_MAX_FILES"
    modify_existing_journald MaxRetentionSec "$JOURNAL_MAX_RETENTION"

    log "重新加载 journald..."
    if systemctl restart systemd-journald.service >/dev/null 2>&1; then
        pass "systemd-journald.service 重启成功"
    else
        warn "systemd-journald.service 重启失败。"
    fi

    log "执行 journal rotate + vacuum..."
    journalctl --rotate >/dev/null 2>&1 || warn "journal rotate 返回异常。"
    journalctl --vacuum-time="$JOURNAL_MAX_RETENTION" --vacuum-size="$JOURNAL_MAX_USE" >/dev/null 2>&1 ||
        warn "journal vacuum 返回异常。"
    pass "journal 清理命令执行完成"

    log "当前 journald 占用:"
    journalctl --disk-usage 2>/dev/null || true
}

# ------------------------------ logrotate -------------------------------------

list_logrotate_files() {
    [[ -f /etc/logrotate.conf ]] && printf '%s\n' /etc/logrotate.conf
    local f
    for f in /etc/logrotate.d/*; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
}

modify_existing_rotate() {
    local file="$1"
    local tmp
    tmp="$(mktemp)"

    if grep -Eq '^[[:space:]]*rotate[[:space:]]+[0-9]+' "$file"; then
        sed -E "s/^[[:space:]]*rotate[[:space:]]+[0-9]+/rotate $LOGROTATE_ROTATE/" "$file" > "$tmp"
        if cmp -s "$file" "$tmp"; then
            rm -f "$tmp"
            info "已有 rotate=$LOGROTATE_ROTATE，无需修改: $file"
        else
            cat "$tmp" > "$file"
            rm -f "$tmp"
            pass "精准修改 $file: rotate=$LOGROTATE_ROTATE"
        fi
        return 0
    fi

    rm -f "$tmp"
    skip "没有现成 rotate 指令，不创建新指令/新规则: $file"
}

optimize_logrotate() {
    printf '\n%b\n' "${C_BLUE}====================================================${C_NC}"
    printf '%b\n' "${C_BLUE} Logrotate：现有规则精准修改 ${C_NC}"
    printf '%b\n\n' "${C_BLUE}====================================================${C_NC}"

    command -v logrotate >/dev/null 2>&1 || {
        skip "系统没有安装 logrotate，不自动新增规则。"
        return 0
    }

    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(list_logrotate_files)

    if ((${#files[@]})); then
        found "实际存在的 logrotate 配置:"
        printf '      %s\n' "${files[@]}"
    fi

    local f
    for f in "${files[@]}"; do
        modify_existing_rotate "$f" || true
    done

    log "验证 logrotate 配置语法..."
    if logrotate -d /etc/logrotate.conf >/dev/null 2>&1; then
        pass "logrotate 配置语法通过"
    else
        warn "logrotate 配置语法检查返回异常，请人工检查。"
    fi
}

# ------------------------------ 系统更新 --------------------------------------

system_update() {
    printf '\n%b\n' "${C_BLUE}====================================================${C_NC}"
    printf '%b\n' "${C_BLUE} Debian 13 系统更新 ${C_NC}"
    printf '%b\n\n' "${C_BLUE}====================================================${C_NC}"

    log "修复/完成未配置的软件包..."
    dpkg --configure -a >/dev/null 2>&1 || warn "dpkg --configure -a 返回异常。"

    log "更新 Debian 软件源..."
    apt-get update -qq || die "APT update 失败。"
    pass "APT update 成功"

    log "执行 Debian 原生 full-upgrade..."
    if apt-get full-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        --no-install-recommends; then
        pass "系统升级完成"
    else
        die "系统 full-upgrade 失败。"
    fi

    ensure_basic_tools
}

# ------------------------------ 清理 -----------------------------------------

safe_remove_file() {
    local f="$1"
    [[ -f "$f" || -L "$f" ]] || return 0
    rm -f -- "$f"
}

cleanup_rotated_logs() {
    log "删除普通历史日志/压缩日志..."
    local count=0 f

    while IFS= read -r -d '' f; do
        # 只处理 /var/log 下常见轮转残留
        safe_remove_file "$f"
        ((count+=1))
        printf '  %b %s\n' "${C_YELLOW}[删除]${C_NC}" "$f"
    done < <(
        find /var/log -xdev -type f \
            \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' \
            -o -name '*.old' -o -name '*.log.[0-9]' \
            -o -name '*.log.[0-9][0-9]' \) \
            -print0 2>/dev/null
    )

    pass "普通历史日志删除完成: $count 个"
}

truncate_active_logs() {
    log "清空普通活动文本日志（保留文件本身和权限）..."
    local count=0 f base

    while IFS= read -r -d '' f; do
        base="$(basename "$f")"

        case "$f" in
            /var/log/journal/*|/run/log/journal/*) continue ;;
            /var/log/wtmp|/var/log/btmp|/var/log/lastlog) continue ;;
        esac

        # 只处理常见文本日志，不碰二进制数据库/目录。
        if file "$f" 2>/dev/null | grep -qiE 'text|empty|ASCII|UTF-8|JSON'; then
            if : > "$f"; then
                ((count+=1))
                printf '  %b %s -> 0 bytes\n' "${C_YELLOW}[清空]${C_NC}" "$f"
            fi
        fi
    done < <(
        find /var/log -xdev -type f -size +0c \
            \( -name '*.log' -o -name '*.txt' -o -name 'syslog' \
            -o -name 'messages' -o -name 'daemon.log' -o -name 'kern.log' \
            -o -name 'auth.log' -o -name 'debug' \) \
            -print0 2>/dev/null
    )

    pass "普通活动日志清空完成: $count 个"
}

cleanup_journal() {
    log "清理 journald 历史数据..."
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=1s --vacuum-size=1M >/dev/null 2>&1 || true
    pass "journald 历史归档清理命令执行完成"
}

cleanup_apt() {
    log "清理 APT / DPKG 垃圾..."
    apt-get autoremove --purge -y >/dev/null 2>&1 || warn "autoremove 返回异常。"
    apt-get autoclean -y >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true

    if [[ -d /var/cache/apt/archives ]]; then
        find /var/cache/apt/archives -maxdepth 1 -type f \
            \( -name '*.deb' -o -name '*.dsc' -o -name '*.tar.*' \) \
            -delete 2>/dev/null || true
    fi

    local rc
    rc="$(dpkg -l 2>/dev/null | awk '$1=="rc"{print $2}')"
    if [[ -n "$rc" ]]; then
        # shellcheck disable=SC2086
        xargs -r apt-get purge -y -qq <<< "$rc" || true
        pass "DPKG rc 残留已清理"
    else
        pass "无 DPKG rc 残留"
    fi
}

kernel_package_list() {
    dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
        grep -E '^linux-(image|headers|modules|kbuild|config)-' || true
}

cleanup_old_kernels() {
    log "检测当前运行内核与已安装内核..."
    local current
    current="$(uname -r)"
    pass "当前运行内核: $current"

    local packages=()
    local p ver base
    while IFS= read -r p; do
        [[ -n "$p" ]] && packages+=("$p")
    done < <(kernel_package_list)

    # 获取当前包的版本/名称关联；保守策略：
    # - 不删除任何与当前 uname -r 明确匹配的包
    # - 优先使用 apt autoremove 处理孤立内核
    # - 仅对明显旧的、非当前内核包做人工候选提示
    log "执行 APT 原生 autoremove 处理孤立旧内核..."
    apt-get autoremove --purge -y >/dev/null 2>&1 || true

    local candidates=()
    for p in "${packages[@]}"; do
        [[ "$p" == *"$current"* ]] && continue
        # 排除元包，避免误删 linux-image-amd64/linux-headers-amd64 等跟踪包
        case "$p" in
            linux-image-amd64|linux-headers-amd64|linux-image-cloud-amd64|linux-headers-cloud-amd64)
                continue ;;
        esac
        candidates+=("$p")
    done

    if ((${#candidates[@]})); then
        info "发现非当前内核相关包（不自动暴力删除元包）："
        printf '      %s\n' "${candidates[@]}"
        info "已优先交给 APT autoremove；如仍需删除，请在确认可启动后备内核后手工处理。"
    else
        pass "没有发现明显可疑的旧内核包"
    fi
}

cleanup_old_files() {
    log "清理明确的系统垃圾文件..."
    local count=0 f

    # 只在明确安全的临时/备份目录处理，不全盘扫描删除。
    local roots=(/tmp /var/tmp /var/backups)
    local root

    for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r -d '' f; do
            # 排除 socket / device 等特殊对象，只处理普通文件
            [[ -f "$f" ]] || continue
            rm -f -- "$f" && {
                ((count+=1))
                printf '  %b %s\n' "${C_YELLOW}[删除]${C_NC}" "$f"
            }
        done < <(
            find "$root" -xdev -type f \
                \( -name '*.old' -o -name '*.bak' -o -name '*~' \
                -o -name '*.tmp' -o -name '*.temp' \) \
                -print0 2>/dev/null
        )
    done

    pass "明确垃圾文件删除完成: $count 个"
}

cleanup_all() {
    printf '\n%b\n' "${C_BLUE}====================================================${C_NC}"
    printf '%b\n' "${C_BLUE} 一键清理：日志 / APT / 旧内核 / 垃圾 ${C_NC}"
    printf '%b\n\n' "${C_BLUE}====================================================${C_NC}"

    warn "此选项会删除历史日志和明确的缓存/垃圾文件；请确认无需保留审计记录。"

    cleanup_journal
    cleanup_rotated_logs
    truncate_active_logs
    cleanup_apt
    cleanup_old_kernels
    cleanup_old_files

    log "清理后的 /var/log 占用:"
    du -sh /var/log 2>/dev/null || true

    pass "一键清理完成"
}

# ------------------------------ XanMod ----------------------------------------

cpu_level() {
    if [[ -x /lib64/ld-linux-x86-64.so.2 ]]; then
        /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null |
            grep -oE 'x86-64-v[2-4]' | sort -V | tail -n1 || true
    fi
}

install_xanmod() {
    printf '\n%b\n' "${C_BLUE}====================================================${C_NC}"
    printf '%b\n' "${C_BLUE} XanMod：官方第三方内核安装 ${C_NC}"
    printf '%b\n\n' "${C_BLUE}====================================================${C_NC}"

    warn "本选项是唯一明确允许创建第三方 APT keyring/source 配置文件的模块。"
    warn "安装完成后必须重启；重启前不要把 BBR/FQ 结果当作 XanMod 已生效。"

    ensure_basic_tools

    local codename="${VERSION_CODENAME:-trixie}"
    [[ "$codename" == "trixie" ]] || die "当前 codename 不是 trixie。"

    local level
    level="$(cpu_level)"
    if [[ "$level" == "x86-64-v4" || "$level" == "x86-64-v3" ]]; then
        level="x64v3"
    else
        level="x64v2"
    fi
    info "CPU ABI 检测结果: ${level}"

    local keyring="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
    local repo="/etc/apt/sources.list.d/xanmod-release.list"

    log "准备 XanMod keyring 目录..."
    mkdir -p /etc/apt/keyrings

    log "获取 XanMod 官方签名密钥..."
    if wget -qO- https://dl.xanmod.org/archive.key |
        gpg --dearmor --yes -o "$keyring"; then
        [[ -s "$keyring" ]] || die "XanMod keyring 为空。"
        chmod 0644 "$keyring"
        pass "XanMod 官方 keyring 获取成功: $keyring"
    else
        rm -f "$keyring"
        die "XanMod 官方签名密钥获取失败。"
    fi

    log "写入 XanMod 官方 Debian 13 Trixie APT 源..."
    printf 'deb [signed-by=%s arch=amd64] http://deb.xanmod.org %s main\n' \
        "$keyring" "$codename" > "$repo"
    pass "XanMod APT 源已写入: $repo"

    log "验证 XanMod APT 源..."
    if ! apt-get update -qq; then
        fail "XanMod APT 源验证失败，开始回滚本次第三方源。"
        rm -f "$repo" "$keyring"
        apt-get update -qq >/dev/null 2>&1 || true
        die "XanMod APT 源不可用，已回滚。"
    fi
    pass "XanMod APT 源验证成功"

    local pkg="linux-xanmod-${level}"
    log "安装 XanMod 内核: $pkg"
    apt-get install -y --no-install-recommends "$pkg" ||
        die "XanMod 内核安装失败。"

    pass "XanMod 内核安装完成"

    log "检查已安装 XanMod 内核包..."
    dpkg-query -W -f='${Package} ${Version}\n' "$pkg" 2>/dev/null || true

    log "检查 GRUB 是否发现 XanMod..."
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null 2>&1 || warn "update-grub 返回异常。"
    fi

    local installed
    installed="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep '^linux-xanmod-' || true)"
    if [[ -n "$installed" ]]; then
        found "已安装 XanMod 包:"
        printf '      %s\n' "$installed"
    fi

    printf '\n%b\n' "${C_GREEN}====================================================${C_NC}"
    printf '%b\n' "${C_GREEN} XanMod 安装完成。现在必须 reboot。${C_NC}"
    printf '%b\n' "${C_GREEN} 重启后再次运行本脚本，然后使用选项 2 优化。${C_NC}"
    printf '%b\n' "${C_GREEN} 最后使用选项 4 做真实性审计。${C_NC}"
    printf '%b\n\n' "${C_GREEN}====================================================${C_NC}"
}

# ------------------------------ 审计 ------------------------------------------

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
            printf '      持久化管理员配置: ${C_GRAY}否（系统/发行版来源）${C_NC}\n'
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
        warn "当前没有运行 XanMod 内核；如果刚安装过 XanMod，请先 reboot。"
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
    while IFS= read -r f; do files+=("$f"); done < <(list_logrotate_files)

    found "logrotate 配置文件数量: ${#files[@]}"
    printf '      %s\n' "${files[@]}"

    if logrotate -d /etc/logrotate.conf >/dev/null 2>&1; then
        pass "logrotate 配置语法正常"
    else
        warn "logrotate 配置语法异常"
    fi

    local rotate_found=0 f
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

    local current
    current="$(uname -r)"
    printf '  当前运行内核: %s\n' "$current"

    local xan
    xan="$(dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | grep '^linux-xanmod-' || true)"
    if [[ -n "$xan" ]]; then
        pass "系统已安装 XanMod:"
        printf '      %s\n' "$xan"
    else
        warn "系统没有安装 XanMod 内核包"
    fi

    if grep -qi xanmod <<<"$current"; then
        pass "XanMod 已经实际运行"
    else
        info "XanMod 已安装但未必正在运行；以 uname -r 为准。"
    fi

    if command -v grubby >/dev/null 2>&1; then
        grubby --default-kernel 2>/dev/null || true
    elif [[ -L /vmlinuz ]]; then
        printf '  /vmlinuz -> %s\n' "$(readlink -f /vmlinuz)"
    fi
}

audit_logs_size() {
    printf '\n%b\n' "${C_BLUE}----------------------------------------------------${C_NC}"
    printf '%b\n' "${C_BLUE}[日志磁盘占用审计]${C_NC}"

    printf '  /var/log: '
    du -sh /var/log 2>/dev/null || true

    printf '  journald: '
    journalctl --disk-usage 2>/dev/null || true

    printf '  文件系统 /: '
    df -h / | tail -n1 || true
}

audit_all() {
    printf '\n%b\n' "${C_CYAN}====================================================${C_NC}"
    printf '%b\n' "${C_CYAN} Debian 13 (Trixie) 真实性审计（只读） ${C_NC}"
    printf '%b\n\n' "${C_CYAN}====================================================${C_NC}"

    log "审计原则：此选项不修改任何配置、不安装软件、不清理文件。"

    audit_kernel
    audit_tcp
    audit_journald
    audit_logrotate
    audit_logs_size

    printf '\n%b\n' "${C_GREEN}====================================================${C_NC}"
    printf '%b\n' "${C_GREEN} 审计完成：以上结果以当前运行内核、实际配置来源和 runtime 为准。 ${C_NC}"
    printf '%b\n\n' "${C_GREEN}====================================================${C_NC}"
}

# ------------------------------ 选项 2 ----------------------------------------

optimize_system() {
    system_update
    optimize_tcp
    optimize_journald
    optimize_logrotate

    printf '\n%b\n' "${C_GREEN}====================================================${C_NC}"
    printf '%b\n' "${C_GREEN} 系统更新 + TCP + 日志优化执行完成 ${C_NC}"
    printf '%b\n' "${C_GREEN} 注意：如果刚安装 XanMod，请先 reboot，再运行选项 2。 ${C_NC}"
    printf '%b\n\n' "${C_GREEN}====================================================${C_NC}"
}

# ------------------------------ 菜单 ------------------------------------------

show_banner() {
    clear 2>/dev/null || true
    printf '%b\n' "${C_CYAN}====================================================${C_NC}"
    printf '%b\n' "${C_CYAN}        Debian 13 (Trixie) Native Optimizer${C_NC}"
    printf '%b\n' "${C_CYAN}        中文输出 / 真实配置链 / 精准持久化${C_NC}"
    printf '%b\n' "${C_CYAN}====================================================${C_NC}"
    printf '%b\n' "${C_GREEN}  1.${C_NC} 更换 XanMod 内核"
    printf '%b\n' "${C_GREEN}     └─ 安装 → 验证 → reboot → 再运行本脚本${C_NC}"
    printf '%b\n' "${C_GREEN}  2.${C_NC} 系统更新 + TCP/BBR/FQ + 日志优化"
    printf '%b\n' "${C_GREEN}     └─ 只修改实际存在的管理员配置项${C_NC}"
    printf '%b\n' "${C_GREEN}  3.${C_NC} 一键清理日志 / 垃圾 / APT / 旧内核残留"
    printf '%b\n' "${C_GREEN}  4.${C_NC} 真实性审计（完全只读）"
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
        read -r -p "请输入 [0-4]: " choice < /dev/tty || exit 0

        case "$choice" in
            1) install_xanmod ;;
            2) optimize_system ;;
            3) cleanup_all ;;
            4) audit_all ;;
            0)
                printf '%b\n' "${C_GRAY}已安全退出。${C_NC}"
                exit 0
                ;;
            *)
                fail "无效选项，请输入 0-4。"
                ;;
        esac

        printf '\n'
        read -r -p "按 Enter 返回主菜单..." _ < /dev/tty || true
    done
}

main "$@"
