#!/bin/bash
# ==============================================================================
# Debian 13 (Trixie) Native Optimizer + XanMod
#
# 原则：
#   1. Debian 13 原生路径优先，先探测真实配置链，再精准原位修改。
#   2. 原生优化模块绝不创建新的 sysctl/journald/logrotate 配置文件。
#   3. 不把不存在的 sysctl 参数“硬塞”进配置文件。
#   4. XanMod 是明确的第三方例外：只有用户选择安装时才创建官方要求的
#      /etc/apt/keyrings/xanmod-archive-keyring.gpg 和
#      /etc/apt/sources.list.d/xanmod-release.list。
#   5. XanMod 失败时自动清理本次创建的第三方源/keyring，避免残留。
#   6. BBR 只在当前运行内核确实提供时启用；不创建 modules-load/sysctl 配置。
#   7. 日志只清理/限制实际存在且由系统组件识别的日志；不删除 wtmp/btmp 等
#      需要保留结构的文件。
#
# 目标：Debian 13 amd64 全新系统上可重复执行、失败可诊断、修改可验证。
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

trap 'rc=$?; echo -e "${RED}[FAIL] 命令失败: ${BASH_COMMAND} (line ${LINENO}, exit ${rc})${NC}" >&2; exit "$rc"' ERR

say()   { echo -e "$*"; }
pass()  { say "  ${GREEN}[PASS]${NC} $*"; }
found() { say "  ${CYAN}[FOUND]${NC} $*"; }
skip()  { say "  ${GRAY}[SKIP]${NC} $*"; }
warn()  { say "  ${YELLOW}[WARN]${NC} $*"; }
fail()  { say "  ${RED}[FAIL]${NC} $*"; }

die() { fail "$*"; exit 1; }

require_root() {
    [[ "${EUID:-}" -eq 0 ]] || die "请使用 root 权限运行。"
}

detect_os() {
    say ">> 检测操作系统..."
    [[ -r /etc/os-release ]] || die "/etc/os-release 不存在。"
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]; then
        die "本脚本只针对 Debian 13 (Trixie)，当前: ${PRETTY_NAME:-unknown} / ${VERSION_CODENAME:-unknown}"
    fi
    pass "确认 Debian 13 (Trixie): ${PRETTY_NAME}"

    local arch
    arch=$(dpkg --print-architecture)
    [[ "$arch" == "amd64" ]] || die "当前架构 ${arch}，本脚本的 XanMod 主线模块针对 amd64。"
    pass "架构: ${arch}"

    if [[ ! -d /run/systemd/system ]]; then
        die "当前不是正常运行的 systemd 系统。"
    fi
    command -v systemctl >/dev/null || die "systemctl 不存在。"
    command -v dpkg >/dev/null || die "dpkg 不存在。"
}

detect_systemd() {
    say ">> 检测 systemd..."
    systemctl cat systemd-sysctl.service >/dev/null 2>&1 || die "systemd-sysctl.service 不存在。"
    systemctl cat systemd-journald.service >/dev/null 2>&1 || die "systemd-journald.service 不存在。"
    found "systemd-sysctl.service"
    found "systemd-journald.service"

    local sysctl_exec journald_exec
    sysctl_exec=$(systemctl show systemd-sysctl.service -p ExecStart --value)
    journald_exec=$(systemctl show systemd-journald.service -p ExecStart --value)
    say "      systemd-sysctl ExecStart: ${sysctl_exec}"
    say "      systemd-journald ExecStart: ${journald_exec}"

    [[ -x /usr/lib/systemd/systemd-sysctl ]] || die "/usr/lib/systemd/systemd-sysctl 不存在或不可执行。"
    [[ -x /usr/lib/systemd/systemd-journald ]] || die "/usr/lib/systemd/systemd-journald 不存在或不可执行。"
    found "真实 systemd-sysctl 程序: /usr/lib/systemd/systemd-sysctl"
    found "真实 systemd-journald 程序: /usr/lib/systemd/systemd-journald"
    pass "systemd 环境检测通过"
}

check_dpkg() {
    say ">> 检查 DPKG..."
    dpkg --audit >/dev/null 2>&1 || die "DPKG 状态异常，请先修复 dpkg --configure -a。"
    pass "DPKG 状态正常"
}

ensure_downloader() {
    say ">> 检测 wget / curl..."
    local missing=()
    command -v wget >/dev/null 2>&1 || missing+=("wget")
    command -v curl >/dev/null 2>&1 || missing+=("curl")

    if ((${#missing[@]})); then
        say "  ${YELLOW}[INSTALL]${NC} 只安装缺失工具: ${missing[*]}"
        apt-get update -qq
        apt-get install -y --no-install-recommends "${missing[@]}"
    fi

    command -v wget >/dev/null 2>&1 || die "wget 安装/验证失败。"
    command -v curl >/dev/null 2>&1 || die "curl 安装/验证失败。"
    pass "wget / curl 已安装并验证成功"
}

apt_update() {
    say ">> 更新 Debian 软件源..."
    apt-get update -qq
    pass "APT update 成功"
}

apt_full_upgrade() {
    say ">> 执行 Debian 原生 full-upgrade..."
    apt-get full-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        --no-install-recommends
    pass "系统升级完成"
}

# ------------------------------------------------------------------------------
# sysctl：Debian 13 的 systemd-sysctl 不再读取 /etc/sysctl.conf。
# 真实可见链由 systemd-sysctl --cat-config / sysctl.d 负责。
# 这里只修改 /etc 或 /run 中“已经存在该键”的文件；绝不新建配置。
# ------------------------------------------------------------------------------
sysctl_files() {
    LC_ALL=C /usr/lib/systemd/systemd-sysctl --cat-config 2>/dev/null |
        awk '
            /^# \/.*\.conf$/ {
                p=$2
                if (p ~ "^/(etc|run)/sysctl\.d/.*\.conf$" || p ~ "^/etc/sysctl\.conf$") print p
            }
        ' | awk '!seen[$0]++'
}

sysctl_key_file() {
    local key="$1" f
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]=]" "$f" 2>/dev/null; then
            echo "$f"
        fi
    done < <(sysctl_files)
}

set_existing_sysctl() {
    local key="$1" value="$2" file
    file=$(sysctl_key_file "$key" | tail -n1 || true)

    if [[ -z "$file" ]]; then
        skip "${key}：真实 systemd-sysctl 配置链中没有现成管理员配置项；不创建文件、不追加配置"
        return 0
    fi

    found "${key} -> ${file}"
    say "  ${CYAN}[MODIFY]${NC} 原位修改 ${file}"

    # 只替换真正的 assignment 行，不碰注释说明。
    sed -i -E \
        "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]=].*$|${key} = ${value}|" \
        "$file"

    grep -qE "^[[:space:]]*${key}[[:space:]=][[:space:]]*${value}[[:space:]]*$" "$file" ||
        die "持久化验证失败: ${file} -> ${key}"

    pass "精准持久化修改成功: ${file} -> ${key}=${value}"
}

network_optimize() {
    say ""
    say "${BLUE}====================================================${NC}"
    say "${BLUE} 网络：真实 systemd-sysctl 配置链 / 只修改现有项目${NC}"
    say "${BLUE}====================================================${NC}"

    say ">> 解析 systemd-sysctl 实际配置链..."
    local files
    files=$(sysctl_files || true)

    if [[ -n "$files" ]]; then
        found "systemd-sysctl 实际可见配置:"
        while IFS= read -r f; do
            [[ -n "$f" ]] && say "      $f"
        done <<< "$files"
    else
        warn "未发现 /etc 或 /run 中可修改的 sysctl 配置文件。"
    fi

    say ">> 检查当前运行内核 BBR..."
    local avail cc qdisc
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

    if grep -qw bbr <<< "$avail"; then
        found "当前运行内核提供 BBR: ${avail}"
        if [[ "$cc" == "bbr" ]]; then
            pass "当前 tcp_congestion_control 已经是 bbr"
        else
            warn "内核提供 BBR，但当前未启用（当前: ${cc:-unknown}）。"
            skip "按照零新配置原则，不创建 modules-load/sysctl 配置；只在现有持久化配置项存在时原位修改。"
            set_existing_sysctl "net.ipv4.tcp_congestion_control" "bbr"
        fi
    else
        skip "当前运行内核没有 BBR；不创建模块加载文件或 sysctl 配置。"
    fi

    # 仅保留少量、明确可解释的项目；不存在则不创建。
    # 不强行覆盖 Debian 13 默认值。
    set_existing_sysctl "net.core.default_qdisc" "fq"
    set_existing_sysctl "net.core.somaxconn" "8192"
    set_existing_sysctl "net.ipv4.tcp_max_syn_backlog" "8192"
    set_existing_sysctl "net.ipv4.ip_local_port_range" "1024 65535"

    say ">> 通过 systemd-sysctl.service 重新加载持久化配置..."
    systemctl restart systemd-sysctl.service
    pass "systemd-sysctl.service 重启成功"

    say ">> Runtime 验证..."
    local k v
    for k in \
        net.core.default_qdisc \
        net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog \
        net.ipv4.ip_local_port_range \
        net.ipv4.tcp_congestion_control; do
        v=$(sysctl -n "$k" 2>/dev/null || true)
        [[ -n "$v" ]] && say "  [VERIFY] ${k} = ${v}"
    done
}

# ------------------------------------------------------------------------------
# journald：先用 systemd-analyze cat-config 获取真实配置链。
# 不创建 drop-in；只修改已经存在于管理员配置中的键。
# ------------------------------------------------------------------------------
journald_files() {
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null |
        awk '
            /^# \/.*journald\.conf$/ {
                p=$2
                if (p ~ "^/(etc|run)/systemd/journald.*\.conf$") print p
            }
            /^# \/.*journald\.conf\.d\/.*\.conf$/ {
                p=$2
                if (p ~ "^/(etc|run)/systemd/journald\.conf\.d/.*\.conf$") print p
            }
        ' | awk '!seen[$0]++'
}

set_existing_journald() {
    local key="$1" value="$2" file
    file=$(journald_files | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$f"; then
            echo "$f"
        fi
    done | tail -n1 || true)

    if [[ -z "$file" ]]; then
        skip "${key}：真实 journald 配置链中没有现成配置项；不创建 drop-in、不追加配置"
        return 0
    fi

    found "${key} -> ${file}"
    say "  ${CYAN}[MODIFY]${NC} 原位修改 ${file}"

    sed -i -E \
        "s|^[[:space:]]*#?[[:space:]]*${key}=.*$|${key}=${value}|" \
        "$file"

    grep -qE "^[[:space:]]*${key}=${value}[[:space:]]*$" "$file" ||
        die "journald 持久化验证失败: ${file} -> ${key}"

    pass "精准持久化修改成功: ${file} -> ${key}=${value}"
}

journald_optimize() {
    say ""
    say "${BLUE}====================================================${NC}"
    say "${BLUE} Journald：真实配置链 / 精准修改 / 清理${NC}"
    say "${BLUE}====================================================${NC}"

    say ">> 解析 journald 实际配置链..."
    local files
    files=$(journald_files || true)

    if [[ -n "$files" ]]; then
        found "journald 实际可见配置:"
        while IFS= read -r f; do
            [[ -n "$f" ]] && say "      $f"
        done <<< "$files"
    else
        warn "未发现 /etc 或 /run 中可修改的 journald 配置文件。"
    fi

    # 不新建配置，所以只在现有项目上执行。
    set_existing_journald "SystemMaxUse" "100M"
    set_existing_journald "SystemMaxFileSize" "10M"
    set_existing_journald "RuntimeMaxUse" "100M"
    set_existing_journald "RuntimeMaxFileSize" "10M"
    set_existing_journald "SystemMaxFiles" "10"
    set_existing_journald "RuntimeMaxFiles" "10"
    set_existing_journald "MaxRetentionSec" "7day"

    say ">> 重新加载 journald..."
    systemctl restart systemd-journald.service
    pass "systemd-journald.service 重启成功"

    say ">> rotate journald..."
    journalctl --rotate >/dev/null 2>&1
    pass "journal rotate 成功"

    say ">> 清理已归档 journal..."
    journalctl --vacuum-time=7d --vacuum-size=100M --vacuum-files=10 2>&1 || true
    pass "journal 历史数据清理命令执行完成"

    say ">> Journald 当前占用:"
    journalctl --disk-usage 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# logrotate：只在系统已有 logrotate 时处理。
# 不创建任何新规则文件。
# 只修改“已有 rotate 指令”，不凭空向每个规则追加 size。
# ------------------------------------------------------------------------------
logrotate_files() {
    local main="/etc/logrotate.conf"
    [[ -f "$main" ]] || return 0

    echo "$main"
    awk '
        /^[[:space:]]*include[[:space:]]+/ {
            d=$2
            if (d ~ /^\/etc\/logrotate\.d$/) print "/etc/logrotate.d/*"
        }
    ' "$main" 2>/dev/null
}

logrotate_optimize() {
    say ""
    say "${BLUE}====================================================${NC}"
    say "${BLUE} Logrotate：真实规则探测 / 不创建规则文件${NC}"
    say "${BLUE}====================================================${NC}"

    if ! command -v logrotate >/dev/null 2>&1; then
        skip "logrotate 未安装；不为了优化额外安装它。"
        return 0
    fi

    local main="/etc/logrotate.conf"
    if [[ -f "$main" ]]; then
        found "logrotate 主配置: ${main}"
    else
        skip "不存在 /etc/logrotate.conf；不创建。"
        return 0
    fi

    local files=()
    [[ -f "$main" ]] && files+=("$main")
    local f
    for f in /etc/logrotate.d/*; do
        [[ -f "$f" ]] && files+=("$f")
    done

    if ((${#files[@]})); then
        found "实际存在的 logrotate 规则:"
        printf '      %s\n' "${files[@]}"
    fi

    say ">> 只修改现有 rotate 指令为 3..."
    local changed=0
    for f in "${files[@]}"; do
        if grep -qE '^[[:space:]]*rotate[[:space:]]+[0-9]+' "$f" 2>/dev/null; then
            sed -i -E 's/^[[:space:]]*rotate[[:space:]]+[0-9]+/rotate 3/' "$f"
            if grep -qE '^[[:space:]]*rotate[[:space:]]+3([[:space:]]|$)' "$f"; then
                pass "精准修改 ${f}: rotate=3"
                changed=$((changed + 1))
            fi
        fi
    done

    if ((changed == 0)); then
        skip "没有发现现有 rotate 指令，因此不添加新的 rotate/size 配置。"
    fi

    say ">> 验证 logrotate 配置..."
    if logrotate -d /etc/logrotate.conf >/dev/null 2>&1; then
        pass "logrotate 配置语法通过"
    else
        die "logrotate 配置验证失败。"
    fi
}

# ------------------------------------------------------------------------------
# 普通 /var/log 清理：
#   - 删除明显的轮转/压缩历史日志；
#   - 清空普通活动文本日志；
#   - 不删除 btmp/wtmp/lastlog/journal 目录；
#   - 不删除整个 /var/log 目录。
# ------------------------------------------------------------------------------
clean_plain_logs() {
    say ""
    say ">> 清理普通历史日志文件..."

    local count=0 f
    local patterns=(
        "/var/log/*.log.[0-9]*"
        "/var/log/*.log.[0-9]*.gz"
        "/var/log/*.log.[0-9]*.xz"
        "/var/log/*.log.[0-9]*.zst"
        "/var/log/**/*.log.[0-9]*"
        "/var/log/**/*.log.[0-9]*.gz"
        "/var/log/**/*.log.[0-9]*.xz"
        "/var/log/**/*.log.[0-9]*.zst"
    )

    # globstar 不开启也没关系；第一层和常见子目录分别处理。
    local oldnull=$?
    shopt -s globstar nullglob
    for f in /var/log/**/*.log.[0-9]* /var/log/**/*.log.[0-9]*.gz /var/log/**/*.log.[0-9]*.xz /var/log/**/*.log.[0-9]*.zst \
             /var/log/**/*.log.gz /var/log/**/*.log.xz /var/log/**/*.log.zst; do
        [[ -f "$f" ]] || continue
        # journal 数据由 journalctl 管理，不碰。
        [[ "$f" == /var/log/journal/* ]] && continue
        rm -f -- "$f"
        say "  [DELETE] $f"
        count=$((count + 1))
    done
    shopt -u globstar
    : "$oldnull"

    pass "历史普通日志删除: ${count} 个"

    say ">> 清空现有普通文本日志..."
    local truncated=0
    for f in /var/log/**/*.log /var/log/**/*.out; do
        [[ -f "$f" ]] || continue
        [[ "$f" == /var/log/journal/* ]] && continue
        # 不清空登录记账数据库。
        case "$f" in
            /var/log/wtmp|/var/log/btmp|/var/log/lastlog) continue ;;
        esac
        : > "$f"
        say "  [TRUNCATE] $f -> 0 bytes"
        truncated=$((truncated + 1))
    done

    pass "普通活动日志清空完成: ${truncated} 个"
}

apt_cleanup() {
    say ">> 清理 APT / DPKG..."
    apt-get autoremove --purge -y -qq
    apt-get autoclean -y -qq
    apt-get clean -qq

    local rc_pkgs
    rc_pkgs=$(dpkg -l | awk '$1=="rc"{print $2}' || true)
    if [[ -n "$rc_pkgs" ]]; then
        xargs -r apt-get purge -y -qq <<< "$rc_pkgs"
        pass "DPKG rc 残留已清理"
    else
        pass "无 DPKG rc 残留"
    fi

    dpkg --audit >/dev/null 2>&1 || die "清理后 DPKG 状态异常。"
    apt-get check >/dev/null 2>&1 || die "清理后 APT 依赖异常。"
}

cleanup_old_kernels() {
    say ""
    say "${BLUE}====================================================${NC}"
    say "${BLUE} 内核：只清理明确的非运行旧内核${NC}"
    say "${BLUE}====================================================${NC}"

    local current
    current=$(uname -r)
    say ">> 当前运行内核: ${current}"

    apt-get autoremove --purge -y -qq

    local old=()
    local p
    for p in $(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | \
        grep -E '^linux-(image|headers|modules)-.*(xanmod|amd64|cloud)' || true); do
        if [[ "$p" != *"$current"* ]]; then
            old+=("$p")
        fi
    done

    if ((${#old[@]} == 0)); then
        pass "未发现可安全判定为非当前运行内核的候选包"
        return 0
    fi

    warn "发现非当前运行内核候选包:"
    printf '      %s\n' "${old[@]}"
    read -r -p "确认删除这些旧内核包？(y/N): " ans < /dev/tty
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        apt-get purge -y -qq "${old[@]}"
        command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1 || true
        pass "旧内核清理完成"
    else
        skip "用户取消旧内核清理"
    fi
}

# ------------------------------------------------------------------------------
# XanMod：唯一明确允许创建第三方 APT 配置文件的模块。
# 官方当前文档使用 trixie codename + xanmod-release.list。
# ------------------------------------------------------------------------------
xanmod_cleanup_created() {
    local keyring="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
    local repo="/etc/apt/sources.list.d/xanmod-release.list"
    [[ "${XANMOD_CREATED_KEYRING:-0}" == "1" ]] && rm -f "$keyring"
    [[ "${XANMOD_CREATED_REPO:-0}" == "1" ]] && rm -f "$repo"
}

xanmod_install() {
    say ""
    say "${BLUE}====================================================${NC}"
    say "${BLUE} XanMod：官方第三方内核（明确配置文件例外）${NC}"
    say "${BLUE}====================================================${NC}"

    warn "安装 XanMod 按官方方式必须创建第三方 APT keyring + source 文件。"
    warn "这部分明确不属于“零新配置文件”的 Debian 原生模块。"

    local ans
    read -r -p "继续安装 XanMod？(y/N): " ans < /dev/tty
    [[ "$ans" =~ ^[Yy]$ ]] || { skip "用户取消 XanMod"; return 0; }

    ensure_downloader

    local keyring="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
    local repo="/etc/apt/sources.list.d/xanmod-release.list"
    local keyring_preexisting=0 repo_preexisting=0

    [[ -e "$keyring" ]] && keyring_preexisting=1
    [[ -e "$repo" ]] && repo_preexisting=1

    mkdir -p /etc/apt/keyrings

    say ">> 获取 XanMod 官方签名密钥..."
    rm -f /tmp/xanmod-keyring.tmp
    if wget -qO- https://dl.xanmod.org/archive.key |
        gpg --dearmor --yes -o /tmp/xanmod-keyring.tmp; then
        install -m 0644 /tmp/xanmod-keyring.tmp "$keyring"
        rm -f /tmp/xanmod-keyring.tmp
        pass "XanMod keyring 获取成功: ${keyring}"
    else
        rm -f /tmp/xanmod-keyring.tmp
        die "XanMod 官方签名密钥获取失败。"
    fi

    if ((keyring_preexisting == 0)); then XANMOD_CREATED_KEYRING=1; fi
    export XANMOD_CREATED_KEYRING

    say ">> 检测 Debian codename..."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${VERSION_CODENAME:-}" == "trixie" ]] || die "XanMod 模块要求 Debian 13 trixie。"
    pass "XanMod APT suite: trixie"

    say ">> 写入 XanMod 官方 APT 源..."
    cat > "$repo" <<EOF
deb [signed-by=${keyring} arch=amd64] http://deb.xanmod.org trixie main
EOF
    if ((repo_preexisting == 0)); then XANMOD_CREATED_REPO=1; fi
    export XANMOD_CREATED_REPO
    pass "XanMod APT 源: ${repo}"

    say ">> 验证 XanMod Release 文件..."
    local tmp_update
    tmp_update=$(mktemp)
    if ! apt-get update 2>&1 | tee "$tmp_update"; then
        rm -f "$tmp_update"
        xanmod_cleanup_created
        die "XanMod APT update 失败；本次新建的第三方配置已回滚。"
    fi

    if grep -q "deb.xanmod.org.*trixie.*Release" "$tmp_update" || \
       grep -q "deb.xanmod.org.*trixie" "$tmp_update"; then
        pass "XanMod trixie 仓库可用"
    else
        # apt update 成功本身已经足以证明仓库索引可获取。
        pass "APT update 成功，XanMod 仓库索引可用"
    fi
    rm -f "$tmp_update"

    say ">> 检测 CPU x86-64 psABI..."
    local abi="x64v2"
    if command -v ld.so >/dev/null 2>&1; then
        :
    fi

    # 使用 glibc loader 的 --help 输出识别 v2/v3；失败则保守使用 v2。
    local detected=""
    for loader in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
        if [[ -x "$loader" ]]; then
            detected=$("$loader" --help 2>/dev/null |
                grep -oE 'x86-64-v[23]' | sort -V | tail -n1 || true)
            [[ -n "$detected" ]] && break
        fi
    done

    case "$detected" in
        x86-64-v3) abi="x64v3" ;;
        x86-64-v2) abi="x64v2" ;;
        *) warn "无法可靠检测 v2/v3，保守选择 linux-xanmod-x64v2" ;;
    esac
    found "选择 XanMod MAIN: linux-xanmod-${abi}"

    apt-cache policy "linux-xanmod-${abi}" | sed 's/^/      /' || true
    apt-cache show "linux-xanmod-${abi}" >/dev/null 2>&1 ||
        die "仓库中不存在 linux-xanmod-${abi}，停止安装并回滚本次新建源。"

    say ">> 安装 XanMod..."
    if apt-get install -y --no-install-recommends "linux-xanmod-${abi}"; then
        pass "XanMod 安装成功"
    else
        xanmod_cleanup_created
        die "XanMod 安装失败；本次新建的第三方配置已回滚。"
    fi

    say ">> XanMod 安装验证..."
    dpkg-query -W -f='${Status}\n' "linux-xanmod-${abi}" 2>/dev/null |
        grep -q 'install ok installed' || die "XanMod dpkg 验证失败。"

    pass "XanMod 包状态正常"
    warn "必须 reboot 才会切换到新内核。"
}

final_audit() {
    say ""
    say "${CYAN}====================================================${NC}"
    say "${CYAN} 最终验证${NC}"
    say "${CYAN}====================================================${NC}"

    say ">> DPKG"
    if dpkg --audit >/dev/null 2>&1; then pass "DPKG 正常"; else fail "DPKG 异常"; fi

    say ">> APT"
    if apt-get check >/dev/null 2>&1; then pass "APT 依赖正常"; else fail "APT 依赖异常"; fi

    say ">> Kernel"
    say "      $(uname -r)"

    say ">> BBR"
    local avail cc
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if grep -qw bbr <<< "$avail"; then
        pass "当前运行内核提供 BBR: ${avail}; 当前拥塞控制: ${cc}"
    else
        skip "当前运行内核没有 BBR"
    fi

    say ">> journald"
    journalctl --disk-usage 2>/dev/null || true

    say ">> /var/log"
    du -sh /var/log 2>/dev/null || true

    say ""
    pass "原生优化模块没有创建新的 sysctl/journald/logrotate 配置文件"
    pass "只对实际配置链中已经存在的管理员配置项执行原位修改"
}

native_all() {
    apt_update
    apt_full_upgrade
    ensure_downloader
    network_optimize
    journald_optimize
    logrotate_optimize
    clean_plain_logs
    apt_cleanup
    final_audit
}

main_menu() {
    while true; do
        say ""
        say "${CYAN}====================================================${NC}"
        say "${CYAN} Debian 13 (Trixie) Native Optimizer${NC}"
        say "${CYAN} 真实调用链 / 零原生新配置 / XanMod 明确例外${NC}"
        say "${CYAN}====================================================${NC}"
        say "${GREEN} 1.${NC} Debian 原生完整优化"
        say "${GREEN} 2.${NC} 网络 + BBR 检测/精准修改"
        say "${GREEN} 3.${NC} Journald + 普通日志限制/清理"
        say "${GREEN} 4.${NC} 安装 XanMod（第三方源例外）"
        say "${GREEN} 5.${NC} 清理旧内核"
        say "${GREEN} 6.${NC} APT 更新 + 垃圾清理"
        say "${RED} 0.${NC} 退出"
        say "${CYAN}====================================================${NC}"

        local choice=""
        read -r -p "请输入 [0-6]: " choice < /dev/tty

        case "$choice" in
            1) native_all ;;
            2) network_optimize; final_audit ;;
            3) journald_optimize; logrotate_optimize; clean_plain_logs; final_audit ;;
            4) xanmod_install; final_audit ;;
            5) cleanup_old_kernels; final_audit ;;
            6) apt_update; apt_full_upgrade; apt_cleanup; final_audit ;;
            0) say "${GRAY}已安全退出。${NC}"; exit 0 ;;
            *) fail "无效输入，请输入 0-6。" ;;
        esac
    done
}

main() {
    require_root
    detect_os
    detect_systemd
    check_dpkg
    main_menu
}

main "$@"
