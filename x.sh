#!/bin/bash
# ==============================================================================
# Debian 13 (Trixie) Native Optimizer
# 目标：
#   1. 只支持 Debian 13
#   2. 先发现 systemd 实际使用的配置链，再修改
#   3. 不创建任何 sysctl/journald/logrotate 配置文件
#   4. 不创建 drop-in
#   5. 不把 BBR 当作需要额外写入的“优化项”；只验证运行内核是否提供
#   6. 网络参数仅保留少量、明确可验证的项目
#   7. 日志通过 journald/logrotate 原生机制清理；活动日志只截断已存在的日志文件
#   8. 每一步输出 FOUND / MODIFY / VERIFY / SKIP
#
# Debian 13 systemd 257.x：
#   systemd-sysctl 实际程序通常为 /usr/lib/systemd/systemd-sysctl，
#   配置目录由 sysctl.d(5) 定义。
#   journald 使用 journald.conf 及其配置目录。
# ==============================================================================

set -Eeuo pipefail
shopt -s nullglob

readonly BLUE='\033[1;34m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[1;37m'
readonly RED='\033[1;31m'
readonly NC='\033[0m'

export DEBIAN_FRONTEND=noninteractive

info(){ echo -e "${CYAN}>> $*${NC}"; }
pass(){ echo -e "  ${GREEN}[PASS] $*${NC}"; }
found(){ echo -e "  ${CYAN}[FOUND] $*${NC}"; }
modify(){ echo -e "  ${BLUE}[MODIFY] $*${NC}"; }
verify(){ echo -e "  ${GREEN}[VERIFY] $*${NC}"; }
skip(){ echo -e "  ${GRAY}[SKIP] $*${NC}"; }
warn(){ echo -e "  ${YELLOW}[WARN] $*${NC}"; }
fail(){ echo -e "  ${RED}[FAIL] $*${NC}" >&2; }

die(){ fail "$*"; exit 1; }

trap 'fail "命令失败: ${BASH_COMMAND} (line ${LINENO})"; exit 1' ERR

require_root(){
    [[ ${EUID:-999} -eq 0 ]] || die "必须使用 root"
}

check_os(){
    info "检测操作系统..."
    [[ -r /etc/os-release ]] || die "/etc/os-release 不存在"
    # shellcheck disable=SC1091
    . /etc/os-release

    [[ ${ID:-} == debian && ${VERSION_CODENAME:-} == trixie ]] ||
        die "只允许 Debian 13 (Trixie)，当前为: ${PRETTY_NAME:-unknown}"

    pass "确认 Debian 13 (Trixie): ${PRETTY_NAME}"
    pass "架构: $(dpkg --print-architecture)"
}

check_systemd(){
    info "检测 systemd..."

    command -v systemctl >/dev/null 2>&1 ||
        die "systemctl 不存在"

    systemctl show systemd-sysctl.service >/dev/null 2>&1 ||
        die "systemd-sysctl.service 不存在"

    systemctl show systemd-journald.service >/dev/null 2>&1 ||
        die "systemd-journald.service 不存在"

    found "systemd-sysctl.service"
    found "systemd-journald.service"

    local sysctl_exec journal_exec
    sysctl_exec="$(systemctl show -p ExecStart --value systemd-sysctl.service 2>/dev/null || true)"
    journal_exec="$(systemctl show -p ExecStart --value systemd-journald.service 2>/dev/null || true)"

    echo -e "      ${GRAY}systemd-sysctl ExecStart: ${sysctl_exec}${NC}"
    echo -e "      ${GRAY}systemd-journald ExecStart: ${journal_exec}${NC}"

    [[ -x /usr/lib/systemd/systemd-sysctl ]] &&
        found "真实 systemd-sysctl 程序: /usr/lib/systemd/systemd-sysctl" ||
        warn "未发现 /usr/lib/systemd/systemd-sysctl，可继续使用 systemctl 服务接口"

    pass "systemd 环境检测通过"
}

repair_dpkg(){
    info "检查 DPKG..."
    if dpkg --audit >/dev/null 2>&1; then
        pass "DPKG 状态正常"
    else
        warn "DPKG 有未完成状态，执行 dpkg --configure -a"
        dpkg --configure -a
        dpkg --audit >/dev/null 2>&1 || die "DPKG 仍异常"
        pass "DPKG 修复成功"
    fi
}

ensure_wget_curl(){
    info "检测 wget / curl..."

    local missing=()
    command -v wget >/dev/null 2>&1 || missing+=("wget")
    command -v curl >/dev/null 2>&1 || missing+=("curl")

    if ((${#missing[@]} == 0)); then
        pass "wget: $(command -v wget)"
        pass "curl: $(command -v curl)"
        return
    fi

    echo -e "  ${YELLOW}[INSTALL] 只安装缺失工具: ${missing[*]}${NC}"
    apt-get update -qq
    apt-get install -y --no-install-recommends "${missing[@]}"

    command -v wget >/dev/null 2>&1 || die "wget 安装失败"
    command -v curl >/dev/null 2>&1 || die "curl 安装失败"
    pass "wget / curl 安装并验证成功"
}

apt_update(){
    info "更新 Debian 软件源..."
    apt-get update -qq
    pass "APT update 成功"

    info "执行 Debian 原生 full-upgrade..."
    apt-get full-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        --no-install-recommends
    pass "系统升级完成"
}

# ==============================================================================
# sysctl
# ==============================================================================

declare -a SYSCTL_CHAIN=()

discover_sysctl_chain(){
    SYSCTL_CHAIN=()

    info "解析 systemd-sysctl 实际配置链..."

    # systemd-sysctl --cat-config is the authoritative way to ask systemd
    # which merged sysctl configuration it sees.
    local cat
    if [[ -x /usr/lib/systemd/systemd-sysctl ]]; then
        cat="$(/usr/lib/systemd/systemd-sysctl --cat-config --no-pager 2>/dev/null || true)"
    else
        cat="$(systemd-sysctl --cat-config --no-pager 2>/dev/null || true)"
    fi

    if [[ -n "$cat" ]]; then
        mapfile -t SYSCTL_CHAIN < <(
            printf '%s\n' "$cat" |
            awk '
                /^# \/.*\.conf$/ {
                    x=$0
                    sub(/^# /,"",x)
                    print x
                }
            ' | awk '!seen[$0]++'
        )
    fi

    # Fallback: enumerate the official sysctl.d search directories.
    if ((${#SYSCTL_CHAIN[@]} == 0)); then
        local d f
        for d in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d; do
            [[ -d "$d" ]] || continue
            for f in "$d"/*.conf; do
                [[ -f "$f" ]] && SYSCTL_CHAIN+=("$f")
            done
        done
        mapfile -t SYSCTL_CHAIN < <(printf '%s\n' "${SYSCTL_CHAIN[@]}" | sort -u)
    fi

    if ((${#SYSCTL_CHAIN[@]} == 0)); then
        warn "systemd-sysctl 没有发现可读取的 .conf；零新文件原则下不创建"
        return 1
    fi

    found "systemd-sysctl 实际读取/可见配置:"
    printf '      %s\n' "${SYSCTL_CHAIN[@]}"
    return 0
}

sysctl_target_for_key(){
    local key="$1"
    local target="" f

    # Because later lexicographic assignments win, scan in the order presented
    # by systemd and retain the last file containing an assignment.
    for f in "${SYSCTL_CHAIN[@]}"; do
        [[ -f "$f" ]] || continue
        if grep -qE "^[[:space:]]*${key}[[:space:]=]" "$f" 2>/dev/null; then
            target="$f"
        fi
    done

    printf '%s' "$target"
}

set_existing_sysctl(){
    local key="$1" value="$2"
    local target current

    if ! sysctl -n "$key" >/dev/null 2>&1; then
        skip "$key：当前内核不支持"
        return 0
    fi

    target="$(sysctl_target_for_key "$key")"

    if [[ -z "$target" ]]; then
        skip "$key：实际配置链中没有现成配置项；不创建文件、不追加配置"
        return 0
    fi

    current="$(sysctl -n "$key" 2>/dev/null || true)"
    found "$key"
    echo -e "      ${GRAY}当前 runtime: ${current}${NC}"
    echo -e "      ${GRAY}实际持久化目标: ${target}${NC}"

    modify "原位修改 $target"

    sed -i -E \
        "s|^[[:space:]]*${key}[[:space:]=].*$|${key} = ${value}|" \
        "$target"

    grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*${value}[[:space:]]*$" "$target" ||
        die "持久化文件修改验证失败: $target"

    pass "精准持久化修改成功: $target"

    sysctl -w "${key}=${value}" >/dev/null

    current="$(sysctl -n "$key" 2>/dev/null || true)"
    [[ "$current" == "$value" ]] ||
        die "runtime 验证失败: $key=$current，期望 $value"

    verify "$key runtime = $current"
}

network_optimize(){
    echo
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE} 网络优化：只修改实际存在的持久化项目${NC}"
    echo -e "${BLUE}====================================================${NC}"

    discover_sysctl_chain || return 0

    info "检查 BBR..."
    local available current
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"

    if [[ "$available" == *bbr* ]]; then
        pass "运行内核已提供 BBR"
        echo -e "      ${GRAY}available: $available${NC}"
        echo -e "      ${GRAY}current:   $current${NC}"
        echo -e "      ${GRAY}不额外写入 BBR 配置${NC}"
    else
        skip "运行内核没有 BBR；不创建模块或 sysctl 配置"
    fi

    # 删除上一版本中的大量 speculative TCP tuning.
    # Only these conservative values remain.
    set_existing_sysctl "net.core.default_qdisc" "fq"
    set_existing_sysctl "net.core.somaxconn" "8192"
    set_existing_sysctl "net.ipv4.tcp_max_syn_backlog" "8192"
    set_existing_sysctl "net.ipv4.ip_local_port_range" "1024 65535"

    info "通过 systemd-sysctl.service 重新加载持久化配置..."
    systemctl restart systemd-sysctl.service
    pass "systemd-sysctl.service 重启成功"

    local key
    for key in \
        net.core.default_qdisc \
        net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog \
        net.ipv4.ip_local_port_range
    do
        if sysctl -n "$key" >/dev/null 2>&1; then
            verify "$key = $(sysctl -n "$key")"
        fi
    done
}

# ==============================================================================
# journald
# ==============================================================================

declare -a JOURNAL_CHAIN=()

discover_journald_chain(){
    JOURNAL_CHAIN=()
    info "解析 journald 实际配置链..."

    local cat
    cat="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null || true)"

    if [[ -n "$cat" ]]; then
        mapfile -t JOURNAL_CHAIN < <(
            printf '%s\n' "$cat" |
            awk '
                /^# \/.*journald.*\.conf$/ {
                    x=$0
                    sub(/^# /,"",x)
                    print x
                }
            ' | awk '!seen[$0]++'
        )
    fi

    if ((${#JOURNAL_CHAIN[@]} == 0)); then
        # Official main-file lookup, only as a fallback.
        local f
        for f in \
            /etc/systemd/journald.conf \
            /run/systemd/journald.conf \
            /usr/local/lib/systemd/journald.conf \
            /usr/lib/systemd/journald.conf
        do
            [[ -f "$f" ]] && JOURNAL_CHAIN+=("$f")
        done
    fi

    if ((${#JOURNAL_CHAIN[@]} == 0)); then
        warn "没有找到 journald 主配置；只执行 journalctl 原生清理，不创建配置"
        return 1
    fi

    found "journald 实际配置:"
    printf '      %s\n' "${JOURNAL_CHAIN[@]}"

    return 0
}

journal_target_for_key(){
    local key="$1"
    local target="" f

    for f in "${JOURNAL_CHAIN[@]}"; do
        [[ -f "$f" ]] || continue
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$f" 2>/dev/null; then
            # Only /etc is considered a persistent administrator target.
            case "$f" in
                /etc/*) target="$f" ;;
            esac
        fi
    done

    printf '%s' "$target"
}

set_existing_journal(){
    local key="$1" value="$2"
    local target

    target="$(journal_target_for_key "$key")"

    if [[ -z "$target" ]]; then
        skip "$key：没有现有 /etc 管理员配置项；不创建 journald 配置"
        return 0
    fi

    found "$key -> $target"
    modify "原位修改 $target"

    sed -i -E \
        "s|^[[:space:]]*#?[[:space:]]*${key}=.*$|${key}=${value}|" \
        "$target"

    grep -qE "^[[:space:]]*${key}=${value}$" "$target" ||
        die "journald 持久化验证失败: $key"

    pass "精准持久化修改成功: $target -> $key=$value"
}

journal_cleanup(){
    echo
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE} Journald：真实配置探测 / 精准修改 / 暴力清理${NC}"
    echo -e "${BLUE}====================================================${NC}"

    discover_journald_chain || true

    if ((${#JOURNAL_CHAIN[@]} > 0)); then
        # Only modify parameters that already exist.
        set_existing_journal "SystemMaxUse" "100M"
        set_existing_journal "SystemMaxFileSize" "10M"
        set_existing_journal "RuntimeMaxUse" "100M"
        set_existing_journal "RuntimeMaxFileSize" "10M"
        set_existing_journal "SystemMaxFiles" "10"
        set_existing_journal "RuntimeMaxFiles" "10"
        set_existing_journal "MaxRetentionSec" "7day"

        info "重新加载 journald..."
        systemctl restart systemd-journald.service
        pass "systemd-journald.service 重启成功"
    fi

    info "rotate journald..."
    journalctl --rotate >/dev/null
    pass "journal rotate 成功"

    info "暴力清理旧 journal..."
    journalctl --vacuum-time=7d >/dev/null
    journalctl --vacuum-size=100M >/dev/null
    pass "journal 已清理至时间/容量策略"

    journalctl --disk-usage
}

# ==============================================================================
# logrotate
# ==============================================================================

declare -a LOGROTATE_CHAIN=()

discover_logrotate_chain(){
    LOGROTATE_CHAIN=()

    if ! command -v logrotate >/dev/null 2>&1; then
        skip "logrotate 未安装；不额外安装"
        return 1
    fi

    [[ -f /etc/logrotate.conf ]] || {
        skip "/etc/logrotate.conf 不存在；不创建"
        return 1
    }

    LOGROTATE_CHAIN+=("/etc/logrotate.conf")

    local dirs=() d f
    mapfile -t dirs < <(
        awk '
            /^[[:space:]]*include[[:space:]]+/ {
                if ($2 ~ /^\//) print $2
            }
        ' /etc/logrotate.conf
    )

    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' f; do
            LOGROTATE_CHAIN+=("$f")
        done < <(find "$d" -maxdepth 1 -type f -print0 2>/dev/null)
    done

    mapfile -t LOGROTATE_CHAIN < <(
        printf '%s\n' "${LOGROTATE_CHAIN[@]}" | sort -u
    )

    found "logrotate 实际主配置/包含文件:"
    printf '      %s\n' "${LOGROTATE_CHAIN[@]}"
}

logrotate_cleanup(){
    echo
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE} Logrotate：真实配置探测 / 清理${NC}"
    echo -e "${BLUE}====================================================${NC}"

    discover_logrotate_chain || return 0

    # Do not invent global directives. Only modify an existing global rotate.
    local target="" f
    for f in "${LOGROTATE_CHAIN[@]}"; do
        if grep -qE '^[[:space:]]*rotate[[:space:]]+[0-9]+' "$f" 2>/dev/null; then
            target="$f"
        fi
    done

    if [[ -n "$target" ]]; then
        found "现有 rotate 指令: $target"
        modify "将现有 rotate 精准改为 3"
        sed -i -E \
            's|^[[:space:]]*rotate[[:space:]]+[0-9]+.*$|rotate 3|' \
            "$target"
        grep -qE '^[[:space:]]*rotate[[:space:]]+3[[:space:]]*$' "$target" ||
            die "logrotate rotate 持久化验证失败"
        pass "logrotate rotate=3 修改成功"
    else
        skip "没有现成全局 rotate 指令；不创建新配置"
    fi

    info "验证 logrotate 配置..."
    logrotate -d /etc/logrotate.conf >/dev/null 2>&1
    pass "logrotate 配置语法通过"

    info "删除已经轮转/压缩的历史日志..."
    local f count=0
    while IFS= read -r -d '' f; do
        rm -f -- "$f"
        count=$((count + 1))
        echo -e "  ${GREEN}[DELETE] $f${NC}"
    done < <(
        find /var/log -xdev -type f \
            \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o \
               -name '*.zst' -o -name '*.lz4' -o \
               -name '*.log.[0-9]*' \) -print0 2>/dev/null
    )

    pass "历史轮转/压缩日志删除: $count 个"
}

truncate_active_logs(){
    info "扫描并清空已有活动日志文件..."

    local f count=0
    while IFS= read -r -d '' f; do
        case "$f" in
            *.journal|*.journal~) continue ;;
        esac

        case "$f" in
            *.log|*.log.*|*/syslog|*/auth.log|*/kern.log|*/daemon.log|*/messages|*/user.log|*/debug)
                if [[ -s "$f" ]]; then
                    : > "$f"
                    count=$((count + 1))
                    echo -e "  ${GREEN}[TRUNCATE] $f -> 0 bytes${NC}"
                fi
                ;;
        esac
    done < <(find /var/log -xdev -type f -print0 2>/dev/null)

    pass "活动日志清空完成: $count 个"
}

logs_all(){
    journal_cleanup
    logrotate_cleanup
    truncate_active_logs
}

# ==============================================================================
# APT 清理
# ==============================================================================

apt_cleanup(){
    info "清理 APT..."
    apt-get autoremove --purge -y -qq
    apt-get autoclean -y -qq
    apt-get clean -qq

    local rc
    rc="$(
        dpkg-query -W -f='${binary:Package} ${Status}\n' 2>/dev/null |
        awk '$2=="deinstall" && $4=="config-files" {print $1}'
    )"

    if [[ -n "$rc" ]]; then
        echo "$rc" | xargs -r apt-get purge -y -qq
        pass "DPKG rc 配置残留已清理"
    else
        pass "无 DPKG rc 残留"
    fi
}

# ==============================================================================
# XanMod
# ==============================================================================

install_xanmod(){
    echo
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE} XanMod 第三方内核${NC}"
    echo -e "${BLUE}====================================================${NC}"

    warn "此操作必然需要第三方 APT 源/密钥配置，违反零新配置原则。"
    read -r -p "输入 YES 才允许继续: " answer < /dev/tty
    [[ "$answer" == "YES" ]] || {
        skip "取消 XanMod"
        return
    }

    ensure_wget_curl

    command -v gpg >/dev/null 2>&1 || {
        warn "缺少 gpg，仅安装 gpg"
        apt-get update -qq
        apt-get install -y --no-install-recommends gpg
    }

    local keyring=/etc/apt/keyrings/xanmod-archive-keyring.gpg
    local repo=/etc/apt/sources.list.d/xanmod.list

    mkdir -p /etc/apt/keyrings

    info "获取 XanMod 官方签名密钥..."
    curl -fsSL https://dl.xanmod.org/archive.key |
        gpg --dearmor --yes -o "$keyring"
    pass "XanMod keyring 获取成功"

    echo "deb [arch=amd64 signed-by=$keyring] http://deb.xanmod.org releases main" > "$repo"
    pass "XanMod APT 源已写入: $repo"

    apt-get update -qq

    local variant=x64v1 detected
    if [[ -x /lib64/ld-linux-x86-64.so.2 ]]; then
        detected="$(
            /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null |
            grep -oE 'x86-64-v[1-4]' |
            sort -V | tail -n1 |
            sed 's/x86-64-/x64/'
        )"
        [[ -n "$detected" ]] && variant="$detected"
    fi

    found "CPU ABI: $variant"

    apt-cache show "linux-xanmod-$variant" >/dev/null 2>&1 ||
        die "没有找到 linux-xanmod-$variant"

    apt-get install -y --no-install-recommends "linux-xanmod-$variant"
    pass "XanMod 安装完成"
    warn "重启后再次运行本脚本验证 BBR；不会额外写 BBR 配置"
}

cleanup_old_kernels(){
    echo
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE} 安全清理旧内核${NC}"
    echo -e "${BLUE}====================================================${NC}"

    local current
    current="$(uname -r)"
    found "当前运行内核: $current"

    apt-get autoremove --purge -y -qq
    pass "APT autoremove 完成"

    local old=() pkg
    while IFS= read -r pkg; do
        [[ "$pkg" == *"$current"* ]] && continue
        old+=("$pkg")
    done < <(
        dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
        grep -E '^linux-(image|headers|modules)-' || true
    )

    if ((${#old[@]} == 0)); then
        pass "没有发现非当前内核包"
        return
    fi

    echo -e "${YELLOW}发现以下非当前内核包:${NC}"
    printf '  %s\n' "${old[@]}"

    read -r -p "输入 YES 删除: " answer < /dev/tty
    [[ "$answer" == YES ]] || {
        skip "保留旧内核"
        return
    }

    apt-get purge -y -- "${old[@]}"

    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null
        pass "GRUB 已更新"
    fi
}

final_audit(){
    echo
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE} 最终验证${NC}"
    echo -e "${BLUE}====================================================${NC}"

    info "DPKG"
    dpkg --audit >/dev/null 2>&1
    pass "DPKG 正常"

    info "APT"
    apt-get check >/dev/null 2>&1
    pass "APT 依赖正常"

    info "Kernel"
    echo -e "      ${GREEN}$(uname -r)${NC}"

    info "BBR"
    local available current
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"

    if [[ "$available" == *bbr* ]]; then
        pass "内核提供 BBR；当前: $current"
    else
        skip "当前运行内核没有 BBR"
    fi

    info "journald"
    journalctl --disk-usage 2>/dev/null || true

    info "/var/log"
    du -sh /var/log 2>/dev/null || true

    echo
    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}✓ 完成：没有通过原生优化模块创建新配置文件${NC}"
    echo -e "${GREEN}✓ 只对发现的现有配置项进行原位修改${NC}"
    echo -e "${GREEN}✓ 修改后进行了 runtime / 配置文件验证${NC}"
    echo -e "${GREEN}====================================================${NC}"
}

full(){
    apt_update
    ensure_wget_curl
    network_optimize
    logs_all
    apt_cleanup
    final_audit
}

main(){
    require_root
    check_os
    check_systemd
    repair_dpkg

    while true; do
        echo
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${CYAN} Debian 13 (Trixie) Native Optimizer${NC}"
        echo -e "${CYAN} 真实调用链 / 零新原生配置 / 精准持久化${NC}"
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${GREEN} 1.${NC} 全部执行"
        echo -e "${GREEN} 2.${NC} 网络 + BBR 检测"
        echo -e "${GREEN} 3.${NC} 日志探测 + 限制 + 清理"
        echo -e "${GREEN} 4.${NC} 安装 XanMod（明确例外：会创建第三方 APT 配置）"
        echo -e "${GREEN} 5.${NC} 清理旧内核"
        echo -e "${GREEN} 6.${NC} APT 更新 + 垃圾清理"
        echo -e "${RED} 0.${NC} 退出"
        echo -e "${CYAN}====================================================${NC}"

        local choice
        read -r -p "请输入 [0-6]: " choice < /dev/tty

        case "$choice" in
            1) full ;;
            2) network_optimize ;;
            3) logs_all ;;
            4) install_xanmod ;;
            5) cleanup_old_kernels ;;
            6) apt_update; apt_cleanup; final_audit ;;
            0) echo -e "${GRAY}已退出。${NC}"; exit 0 ;;
            *) fail "无效输入" ;;
        esac
    done
}

main "$@"
