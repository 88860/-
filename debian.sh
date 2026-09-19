#!/bin/bash
set -uo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

if [ -t 1 ]; then
    R=$'\033[38;5;203m'
    O=$'\033[38;5;215m'
    Y=$'\033[38;5;227m'
    G=$'\033[38;5;120m'
    C=$'\033[38;5;117m'
    B=$'\033[38;5;111m'
    P=$'\033[38;5;183m'
    M=$'\033[38;5;218m'

    BR=$'\033[1;38;5;203m'
    BO=$'\033[1;38;5;215m'
    BY=$'\033[1;38;5;227m'
    BG=$'\033[1;38;5;120m'
    BC=$'\033[1;38;5;117m'
    BB=$'\033[1;38;5;111m'
    BP=$'\033[1;38;5;183m'
    BM=$'\033[1;38;5;218m'

    DIM=$'\033[2m'
    BLD=$'\033[1m'
    RST=$'\033[0m'
    INV=$'\033[7m'
else
    R=''; O=''; Y=''; G=''; C=''; B=''; P=''; M=''
    BR=''; BO=''; BY=''; BG=''; BC=''; BB=''; BP=''; BM=''
    DIM=''; BLD=''; RST=''; INV=''
fi

LOG_FILE="/var/log/debian-optimizer.log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

_info() { echo -e "  ${C}◆${RST} $*" | tee -a "$LOG_FILE"; }
_ok()   { echo -e "  ${BG}✔${RST} $*" | tee -a "$LOG_FILE"; }
_warn() { echo -e "  ${BY}▲${RST} $*" | tee -a "$LOG_FILE"; }
_bad()  { echo -e "  ${BR}✘${RST} $*" | tee -a "$LOG_FILE"; }

_rainbow_sep() {
    local chars="━"
    printf '  '
    for c in R O Y G C B P M; do
        printf '%s%s' "${!c}" "$chars"
    done
    printf '%s\n' "$RST"
}

_step() {
    local tag="$1" color="$2"; shift 2
    echo
    printf '%s  ┏━[%s%s%s%s]%s' "$DIM" "$RST" "$BLD" "$color" "$tag" "$RST"
    printf '%s %s%s\n' "$DIM" "$*" "$RST"
    printf '%s  ┗' "$DIM"
    _rainbow_sep
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${BR}✘ 错误：必须使用 root 权限运行。${RST}"
    exit 1
fi

echo
echo -e "  ${BR}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "  ${BO}║${RST}                                                          ${BO}║${RST}"
echo -e "  ${BO}║${RST}   ${BR}█▀▄${BO} █▀▀${BY} █▀▄${BG} ▀█▀${BC} ▄▀█${BB} █▄░█${BP}${RST}   ${BM}◆${RST} ${BLD}ADVANCED${RST} ${BM}◆${RST}         ${BO}║${RST}"
echo -e "  ${BO}║${RST}   ${BR}█▄▀${BO} ██▄${BY} █▄▀${BG} ░█░${BC} █▀█${BB} █░▀█${BP}${RST}                       ${BO}║${RST}"
echo -e "  ${BO}║${RST}                                                          ${BO}║${RST}"
echo -e "  ${BY}║${RST}              ${BM}D E B I A N${RST}  ${C}1 3${RST}  ${BG}O P T I M I Z E R${RST}                ${BY}║${RST}"
echo -e "  ${BY}║${RST}                                                          ${BY}║${RST}"
echo -e "  ${BG}╚══════════════════════════════════════════════════════════╝${RST}"
echo

_os_name="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-未知}" )"

printf '  %s┌─ 系统信息 ─────────────────────────────────────────────┐%s\n' "$DIM" "$RST"
printf '  %s│%s  %s%s主机%s  %s\n' "$DIM" "$RST" "$BC" "$BLD" "$RST" "$(hostname)"
printf '  %s│%s  %s%s系统%s  %s\n' "$DIM" "$RST" "$BG" "$BLD" "$RST" "$_os_name"
printf '  %s│%s  %s%s内核%s  %s\n' "$DIM" "$RST" "$BY" "$BLD" "$RST" "$(uname -r)"
printf '  %s│%s  %s%s根盘%s  %s\n' "$DIM" "$RST" "$BM" "$BLD" "$RST" "$(df -h / | awk 'NR==2 {print $2" 已用 "$3" ("$5")"}')"
printf '  %s│%s  %s%s日志%s  %s%s%s\n' "$DIM" "$RST" "$BB" "$BLD" "$RST" "$DIM" "$LOG_FILE" "$RST"
printf '  %s└────────────────────────────────────────────────────────┘%s\n' "$DIM" "$RST"
echo
_rainbow_sep

echo
read -r -p "$(echo -e "  ${BY}${BLD}❯ 确认启动全自动优化与清理？${RST} ${DIM}[y/N]${RST} ")" CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo -e "  ${BY}○ 已取消。${RST}"; exit 0; }

kernel_prune() {
    _step "1/6" "$BR" "清理冗余内核与元包"

    local current latest
    current="$(uname -r)"
    _info "当前运行内核: ${BY}${BLD}${current}${RST}"

    latest="$(ls -1 /usr/lib/modules 2>/dev/null | grep -E '^[0-9]' | sort -V | tail -n1)"
    if [ -n "$latest" ] && [ "$latest" != "$current" ]; then
        _warn "已安装更新内核 ${BY}${BLD}${latest}${RST}，当前运行 ${BY}${BLD}${current}${RST}"
        _warn "跳过内核清理，请重启后再运行。"
        return 0
    fi

    local cleanup=()
    while read -r pkg; do
        [ -z "$pkg" ] && continue
        [[ "$pkg" =~ ^linux-(libc-dev|base|compiler|kbuild|doc|perf|source|tools) ]] && continue
        [[ "$pkg" == *"$current"* ]] && continue
        dpkg-query -W -f='${Depends} ${Recommends}\n' "$pkg" 2>/dev/null | grep -q "$current" && continue
        [[ "$pkg" =~ (image|headers|modules|xanmod|liquorix|bbr|zen|surface|joeyblog|mainline|custom) ]] && cleanup+=("$pkg")
    done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^linux-')

    if [ ${#cleanup[@]} -eq 0 ]; then
        _ok "无冗余内核与元包"
        return 0
    fi

    _info "将清理以下内核包:"
    for p in "${cleanup[@]}"; do echo -e "      ${BR}✂${RST} ${DIM}${p}${RST}" | tee -a "$LOG_FILE"; done

    if apt-get purge -y --no-install-recommends "${cleanup[@]}" >>"$LOG_FILE" 2>&1; then
        _ok "内核与元包清理完成"
    else
        _bad "部分内核清理失败"
    fi
    command -v update-grub >/dev/null 2>&1 && update-grub >>"$LOG_FILE" 2>&1 && _ok "GRUB 已更新" || true
}

sys_upgrade() {
    _step "2/6" "$BO" "精简组件并全局升级"

    _info "移除冗余组件..."
    apt-get purge -y 'qemu*' os-prober laptop-detect pciutils dmidecode >>"$LOG_FILE" 2>&1 || true
    apt-get autoremove --purge -y >>"$LOG_FILE" 2>&1 || true
    _ok "组件精简完成"

    _info "清理 rc 残留包..."
    local rc_pkgs
    rc_pkgs="$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}')"
    if [ -n "$rc_pkgs" ]; then
        echo "$rc_pkgs" | xargs apt-get purge -y -qq >>"$LOG_FILE" 2>&1 || true
        _ok "残留包已清理"
    else
        _ok "无残留包"
    fi

    _info "刷新索引并执行 full-upgrade..."
    apt-get update -qq >>"$LOG_FILE" 2>&1 || true
    if apt-get full-upgrade -y -q >>"$LOG_FILE" 2>&1; then
        _ok "全局升级完成"
    else
        _warn "升级有非致命错误，详见日志"
    fi

    apt-get autoremove --purge -y -qq >>"$LOG_FILE" 2>&1 || true
    apt-get clean -qq >>"$LOG_FILE" 2>&1 || true
    _ok "升级后清理完成"
}

config_optimize() {
    _step "3/6" "$BY" "注入网络、日志与轮转配置"

    local sysctl_target="/etc/sysctl.d/99-default.conf"
    mkdir -p "/etc/sysctl.d"
    [ -f "$sysctl_target" ] || touch "$sysctl_target"

    if [ -w "$sysctl_target" ] && [ ! -L "$sysctl_target" ]; then
        local tmp_s; tmp_s="$(mktemp)"
        cp -p "$sysctl_target" "$tmp_s"

        local keys=("net.core.default_qdisc" "net.ipv4.tcp_fastopen" \
                    "net.ipv4.tcp_max_syn_backlog" "net.core.somaxconn" \
                    "net.core.netdev_max_backlog" "net.ipv4.ip_local_port_range" \
                    "net.ipv4.tcp_mtu_probing")
        local vals=("fq" "3" "4096" "4096" "4096" "1024 65535" "1")

        local curr_cc avail_cc
        curr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
        avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)

        if [[ "$curr_cc" == "bbr3" ]]; then
            :
        elif [[ "$avail_cc" == *"bbr3"* ]]; then
            keys+=("net.ipv4.tcp_congestion_control"); vals+=("bbr3")
        else
            keys+=("net.ipv4.tcp_congestion_control"); vals+=("bbr")
            if command -v modprobe >/dev/null 2>&1; then
                modprobe tcp_bbr >/dev/null 2>&1 || true
                if [ -w /etc/modules ] && ! grep -q "^tcp_bbr$" /etc/modules 2>/dev/null; then
                    echo "tcp_bbr" >> /etc/modules
                fi
            fi
        fi

        local i k v
        for ((i=0; i<${#keys[@]}; i++)); do
            k="${keys[$i]}"; v="${vals[$i]}"
            if grep -qE "^[[:space:]]*[#;]*[[:space:]]*${k//./\.}[[:space:]]*=" "$sysctl_target"; then
                sed -i -E "s|^[[:space:]]*[#;]*[[:space:]]*${k//./\.}[[:space:]]*=.*|$k = $v|" "$tmp_s"
            else
                echo "$k = $v" >> "$tmp_s"
            fi
        done
        chmod 644 "$tmp_s"
        mv -f "$tmp_s" "$sysctl_target"
        _ok "sysctl 已写入 ${DIM}${sysctl_target}${RST}"

        systemctl restart systemd-sysctl >/dev/null 2>&1 || true
        systemctl is-active --quiet networking.service >/dev/null 2>&1 && systemctl restart networking >/dev/null 2>&1 || true
        _ok "sysctl 已生效"
    else
        _warn "无法写入 ${sysctl_target}，跳过"
    fi

    local j_conf="/etc/systemd/journald.conf"
    if [ -f "$j_conf" ]; then
        local tmp_j; tmp_j="$(mktemp)"
        awk '
            BEGIN {
                expected["Compress"]="yes"; expected["SystemMaxUse"]="32M"
                expected["SystemMaxFileSize"]="4M"; expected["SystemMaxFiles"]="8"
                expected["RuntimeMaxUse"]="8M"; expected["RuntimeMaxFileSize"]="2M"
                expected["RuntimeMaxFiles"]="4"; expected["MaxRetentionSec"]="7day"
                in_journal=0; found_journal=0
            }
            function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
            function emit_missing(){ for (k in expected) if (!done[k]) { print k "=" expected[k]; done[k]=1 } }
            /^[[:space:]]*\[/ {
                section=trim($0)
                if (in_journal && section!="[Journal]") emit_missing()
                in_journal=(section=="[Journal]")
                if (in_journal) found_journal=1
                print; next
            }
            in_journal {
                line=trim($0); test_line=line; sub(/^#[[:space:]]*/,"",test_line)
                if (test_line ~ /^[A-Za-z]+[[:space:]]*=/) {
                    key=test_line; sub(/[[:space:]]*=.*/,"",key)
                    if (key in expected) { if(!done[key]){ print key "=" expected[key]; done[key]=1 } next }
                }
                print; next
            }
            { print }
            END {
                if (in_journal) emit_missing()
                else if (!found_journal) { print "\n[Journal]"; emit_missing() }
            }
        ' "$j_conf" > "$tmp_j"
        chmod --reference="$j_conf" "$tmp_j" 2>/dev/null || true
        mv -f "$tmp_j" "$j_conf"
        systemctl restart systemd-journald >/dev/null 2>&1 || true
        _ok "journald 已写入 ${DIM}${j_conf}${RST}"
    fi

    local r_conf="/etc/logrotate.d/rsyslog"
    if [ -f "$r_conf" ]; then
        local tmp_r; tmp_r="$(mktemp)"
        awk '
            BEGIN { in_block=0; in_header=0; target_block=0 }
            function reset_b(){ in_block=0; in_header=0; target_block=0; size_d=0; rot_d=0; comp_d=0 }
            function emit_m(){ if(target_block){ if(!size_d) print "\tmaxsize 5M"; if(!rot_d) print "\trotate 2"; if(!comp_d) print "\tcompress" } }
            /^[[:space:]]*[^#{}]*\{[[:space:]]*$/ {
                target_block=($0 ~ /\/var\/log\//); in_block=1; in_header=0; size_d=0; rot_d=0; comp_d=0
                print; next
            }
            !in_block && !in_header {
                line=$0; sub(/^[[:space:]]+/,"",line)
                if (line ~ /^#/ || line=="") { print; next }
                if (line ~ /\/var\/log\// && line !~ /\{/) { in_header=1; target_block=1; print; next }
            }
            in_header {
                if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) { in_header=0; in_block=1; size_d=0; rot_d=0; comp_d=0; print; next }
                if ($0 !~ /^[[:space:]]*#/ && $0 ~ /\/var\/log\//) target_block=1
                print; next
            }
            in_block {
                line=$0; sub(/^[[:space:]]+/,"",line)
                if (line ~ /^\}/) { emit_m(); print; reset_b(); next }
                if (!target_block) { print; next }
                test_line=line; sub(/^#[[:space:]]*/,"",test_line)
                if (test_line ~ /^(maxsize|size)[[:space:]]+/) { if(!size_d){ print "\tmaxsize 5M"; size_d=1 }; next }
                if (test_line ~ /^rotate[[:space:]]+/) { if(!rot_d){ print "\trotate 2"; rot_d=1 }; next }
                if (test_line ~ /^(compress|nocompress)([[:space:]]|$)/) { if(!comp_d){ print "\tcompress"; comp_d=1 }; next }
                print; next
            }
            { print }
            END { if (in_block) emit_m() }
        ' "$r_conf" > "$tmp_r"
        chmod --reference="$r_conf" "$tmp_r" 2>/dev/null || true
        mv -f "$tmp_r" "$r_conf"
        _ok "logrotate 已写入 ${DIM}${r_conf}${RST}"
    fi
}

service_prune() {
    _step "4/6" "$BG" "禁用无用系统服务"

    local services=(
        cups cups-browsed cups.socket
        bluetooth
        avahi-daemon avahi-daemon.socket
        ModemManager
        rpcbind
    )

    local svc
    for svc in "${services[@]}"; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
            if systemctl disable --now "$svc" >>"$LOG_FILE" 2>&1; then
                _ok "已禁用: ${DIM}${svc}${RST}"
            else
                _warn "禁用失败: ${svc}"
            fi
        fi
    done

    if dpkg -l pcp 2>/dev/null | grep -q '^ii'; then
        _info "检测到 PCP，正在清理..."
        for svc in pmcd pmproxy pmlogger; do
            systemctl disable --now "$svc" >>"$LOG_FILE" 2>&1 || true
        done
        apt-get purge -y pcp pcp-conf >>"$LOG_FILE" 2>&1 || true
        _ok "PCP 已禁用并清理"
    else
        _ok "未检测到 PCP"
    fi
}

module_blacklist() {
    _step "5/6" "$BC" "屏蔽无用内核模块"

    local bl_conf="/etc/modprobe.d/blacklist-server.conf"
    if [ -f "$bl_conf" ]; then
        _ok "黑名单已存在，跳过写入: ${DIM}${bl_conf}${RST}"
        return 0
    fi

    cat > "$bl_conf" <<'EOF'
blacklist snd
blacklist snd_pcm
blacklist snd_timer
blacklist soundcore
blacklist pcspkr
blacklist snd_pcsp
blacklist snd_hda_intel
blacklist bluetooth
blacklist btusb
blacklist uvcvideo
blacklist firewire_ohci
blacklist firewire_core
blacklist rtsx_usb_ms
install btusb /bin/true
install uvcvideo /bin/true
EOF

    _ok "黑名单已写入 ${DIM}${bl_conf}${RST}"

    if command -v update-initramfs >/dev/null 2>&1; then
        if update-initramfs -u >>"$LOG_FILE" 2>&1; then
            _ok "initramfs 已更新"
        else
            _warn "initramfs 更新失败"
        fi
    fi
}

deep_prune() {
    _step "6/6" "$BB" "深度清理缓存与冗余文件"

    sync

    _info "孤立包检测..."
    apt-get autoremove --purge -y -q >>"$LOG_FILE" 2>&1 || true
    _ok "孤立包清理完成"

    _info "清理 APT 缓存..."
    rm -rf /var/cache/apt/archives/* 2>/dev/null || true
    _ok "APT 缓存已清理"

    local prune="-type d \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /snap \) -prune -o"

    eval "find / $prune -type f \( -name '*.dpkg-old' -o -name '*.dpkg-dist' -o -name '*.dpkg-new' -o -name '*.ucf-old' -o -name '*.ucf-dist' \) -print -delete 2>/dev/null || true"
    eval "find / $prune -type f \( -name '*.bak' -o -name '*.swp' -o -name '*~' -o -name '*.old' -o -name '*.tmp' \) -print -delete 2>/dev/null || true"
    _ok "dpkg/ucf/备份残留已清理"

    rm -f /vmlinuz.old /initrd.img.old /boot/vmlinuz.old /boot/initrd.img.old 2>/dev/null || true

    eval "find / $prune -type f -name 'core' -exec file {} \; 2>/dev/null | grep -i 'core file' | awk -F: '{print \$1}' | xargs -I {} rm -f {} 2>/dev/null || true"
    find /var/crash /var/lib/systemd/coredump /var/tmp -type f -delete 2>/dev/null || true
    _ok "core dump 已清理"

    local d
    for d in /home/* /root; do
        [ -d "$d" ] || continue
        find "$d/.cache" "$d/.local/share/Trash" -type f -delete 2>/dev/null || true
        find "$d" -maxdepth 1 -type f \( -name ".bash_history" -o -name ".viminfo" -o -name ".wget-hsts" \) -delete 2>/dev/null || true
    done
    rm -rf ~/.npm/_cacache ~/.m2/repository ~/.gradle/caches 2>/dev/null || true
    _ok "用户缓存与历史已清理"

    find /tmp -type f -delete 2>/dev/null || true

    eval "find / $prune -type f -name '*.log' -exec truncate -s 0 {} \; 2>/dev/null || true"
    eval "find / $prune -type f \( -name '*.log.*' -o -name '*.gz' \) -path '*/log/*' -delete 2>/dev/null || true"
    _ok "日志已截断清理"

    rm -rf /var/log/journal/* 2>/dev/null || true
    systemctl restart systemd-journald >/dev/null 2>&1 || true

    command -v docker >/dev/null 2>&1 && docker system prune -a -f --volumes >>"$LOG_FILE" 2>&1 && _ok "Docker 已清理" || true
    command -v flatpak >/dev/null 2>&1 && flatpak uninstall --unused -y >>"$LOG_FILE" 2>&1 && _ok "Flatpak 已清理" || true

    sync
}

kernel_prune
sys_upgrade
config_optimize
service_prune
module_blacklist
deep_prune

echo
_rainbow_sep
echo
echo -e "  ${BG}${BLD}  ✔  全 部 任 务 已 完 成  ${RST}"
echo
echo -e "  ${DIM}  日志:${RST} ${BB}${LOG_FILE}${RST}"
echo
_rainbow_sep
echo

read -r -p "$(echo -e "  ${BM}${BLD}❯ 按 ${BG}回车${BM}${BLD} 键重启系统，或 Ctrl+C 取消... ${RST}")" _ || true

echo
echo -e "  ${BY}⚡ 系统将在 3 秒后重启...${RST}"
sleep 1
echo -e "  ${BO}⚡ 2${RST}"
sleep 1
echo -e "  ${BR}⚡ 1${RST}"
sleep 1

sync
systemctl reboot 2>/dev/null || reboot
