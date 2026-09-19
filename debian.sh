#!/bin/bash
set -uo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

if [ -t 1 ]; then
    R=$'\033[38;5;203m'; O=$'\033[38;5;215m'; Y=$'\033[38;5;227m'; G=$'\033[38;5;120m'
    C=$'\033[38;5;117m'; B=$'\033[38;5;111m'; P=$'\033[38;5;183m'; M=$'\033[38;5;218m'
    BR=$'\033[1;38;5;203m'; BO=$'\033[1;38;5;215m'; BY=$'\033[1;38;5;227m'; BG=$'\033[1;38;5;120m'
    BC=$'\033[1;38;5;117m'; BB=$'\033[1;38;5;111m'; BP=$'\033[1;38;5;183m'; BM=$'\033[1;38;5;218m'
    DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'; TTY=1
else
    R=''; O=''; Y=''; G=''; C=''; B=''; P=''; M=''
    BR=''; BO=''; BY=''; BG=''; BC=''; BB=''; BP=''; BM=''
    DIM=''; BLD=''; RST=''; TTY=0
fi

_cursor_hide() { [ "$TTY" = 1 ] && printf '\033[?25l'; }
_cursor_show() { [ "$TTY" = 1 ] && printf '\033[?25h'; }
trap '_cursor_show' EXIT INT TERM

_typewrite() {
    local text="$1" delay="${2:-0.005}"
    if [ "$TTY" = 0 ]; then echo "$text"; return; fi
    local i
    for ((i=0; i<${#text}; i++)); do
        printf '%s' "${text:$i:1}"
        sleep "$delay"
    done
    echo
}

_rainbow_flow() {
    if [ "$TTY" = 0 ]; then
        printf '  '
        for c in R O Y G C B P M; do printf '%s━' "${!c}"; done
        printf '%s\n' "$RST"
        return
    fi
    local width=58 cols=(R O Y G C B P M) f i
    for ((f=0; f<8; f++)); do
        printf '\r  '
        for ((i=0; i<width; i++)); do
            local c=${cols[(i+f)%8]}
            printf '%s━' "${!c}"
        done
        printf '%s' "$RST"
        sleep 0.025
    done
    echo
}

_pulse() {
    local text="$1"
    if [ "$TTY" = 0 ]; then echo "  ✔ $text"; return; fi
    local cols=(G C B P M R) i
    for ((i=0; i<6; i++)); do
        printf '\r  %s✔%s %s' "${!cols[i]}" "$RST" "$text"
        sleep 0.045
    done
    printf '\r  %s✔%s %s\n' "$BG" "$RST" "$text"
}

_info() { echo -e "  ${C}◆${RST} $*"; }
_ok()   { echo -e "  ${BG}✔${RST} $*"; }
_warn() { echo -e "  ${BY}▲${RST} $*"; }
_bad()  { echo -e "  ${BR}✘${RST} $*"; }

_run_spin() {
    local msg="$1"; shift
    if [ "$TTY" = 0 ]; then
        if "$@" >/dev/null 2>&1; then echo "  ✔ $msg"; return 0
        else echo "  ✘ $msg"; return 1; fi
    fi
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local cols=(C B P M R O Y G)
    "$@" >/dev/null 2>&1 &
    local pid=$!
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s%s%s' "${!cols[i%8]}" "${frames[i%10]}" "$RST" "$DIM" "$msg" "$RST"
        i=$((i+1))
        sleep 0.06
    done
    wait "$pid"
    local rc=$?
    if [ $rc -eq 0 ]; then
        printf '\r  %s✔%s %s%s%s\n' "$BG" "$RST" "$BLD" "$msg" "$RST"
    else
        printf '\r  %s✘%s %s%s%s\n' "$BR" "$RST" "$BLD" "$msg" "$RST"
    fi
    return $rc
}

_step() {
    local tag="$1" color="$2"; shift 2
    echo
    printf '%s  ┏━[%s%s%s%s]%s ' "$DIM" "$RST" "$BLD" "$color" "$tag" "$RST"
    _typewrite "$*" 0.005
    printf '%s  ┗%s' "$DIM" "$RST"
    _rainbow_flow
}

_banner() {
    local L=(
'  ╔══════════════════════════════════════════════════════════╗'
'  ║                                                          ║'
'  ║   █▀▄ █▀▀ █▀▄ ▀█▀ ▄▀█ █▄░█   ◆  A D V A N C E D  ◆      ║'
'  ║   █▄▀ ██▄ █▄▀ ░█░ █▀█ █░▀█                               ║'
'  ║                                                          ║'
'  ║          D E B I A N   1 3   O P T I M I Z E R           ║'
'  ║                                                          ║'
'  ╚══════════════════════════════════════════════════════════╝'
    )
    local CC=("$BR" "$BO" "$BY" "$BG" "$BC" "$BB" "$BP" "$BM")
    echo
    local i
    for i in "${!L[@]}"; do
        printf '%s%s%s\n' "${CC[$i]}" "${L[$i]}" "$RST"
        [ "$TTY" = 1 ] && sleep 0.05
    done
    echo
}

_finale() {
    if [ "$TTY" = 0 ]; then echo "  ✔ 全部任务已完成"; return; fi
    local cols=(R O Y G C B P M) i j
    for ((j=0; j<3; j++)); do
        for ((i=0; i<8; i++)); do
            printf '\r  %s%s✔  全 部 任 务 已 完 成  %s' "${!cols[i]}" "$BLD" "$RST"
            sleep 0.05
        done
    done
    printf '\r  %s✔  全 部 任 务 已 完 成  %s  \n' "$BG$BLD" "$RST"
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${BR}✘ 错误：必须使用 root 权限运行。${RST}"
    exit 1
fi

_cursor_hide
_banner

_os_name="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-未知}" )"

printf '  %s┌─ 系统信息 ─────────────────────────────────────────────┐%s\n' "$DIM" "$RST"
printf '  %s│%s  %s%s主机%s  %s\n' "$DIM" "$RST" "$BC" "$BLD" "$RST" "$(hostname)"
printf '  %s│%s  %s%s系统%s  %s\n' "$DIM" "$RST" "$BG" "$BLD" "$RST" "$_os_name"
printf '  %s│%s  %s%s内核%s  %s\n' "$DIM" "$RST" "$BY" "$BLD" "$RST" "$(uname -r)"
printf '  %s│%s  %s%s根盘%s  %s\n' "$DIM" "$RST" "$BM" "$BLD" "$RST" "$(df -h / | awk 'NR==2 {print $2" 已用 "$3" ("$5")"}')"
printf '  %s└────────────────────────────────────────────────────────┘%s\n' "$DIM" "$RST"
echo
_rainbow_flow

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
    local p
    for p in "${cleanup[@]}"; do echo -e "      ${BR}✂${RST} ${DIM}${p}${RST}"; done

    if _run_spin "正在卸载冗余内核..." apt-get purge -y --no-install-recommends "${cleanup[@]}"; then
        _pulse "内核与元包清理完成"
    else
        _bad "部分内核清理失败"
    fi
    command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1 && _ok "GRUB 已更新" || true
}

sys_upgrade() {
    _step "2/6" "$BO" "精简组件并全局升级"

    _info "移除冗余组件..."
    apt-get purge -y 'qemu*' os-prober laptop-detect pciutils dmidecode >/dev/null 2>&1 || true
    apt-get autoremove --purge -y >/dev/null 2>&1 || true
    _ok "组件精简完成"

    _info "清理 rc 残留包..."
    local rc_pkgs
    rc_pkgs="$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}')"
    if [ -n "$rc_pkgs" ]; then
        echo "$rc_pkgs" | xargs apt-get purge -y -qq >/dev/null 2>&1 || true
        _ok "残留包已清理"
    else
        _ok "无残留包"
    fi

    _info "刷新软件索引..."
    apt-get update -qq >/dev/null 2>&1 || true

    if _run_spin "执行 full-upgrade..." apt-get full-upgrade -y -q; then
        _pulse "全局升级完成"
    else
        _warn "升级有非致命错误"
    fi

    apt-get autoremove --purge -y -qq >/dev/null 2>&1 || true
    apt-get clean -qq >/dev/null 2>&1 || true
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
            if systemctl disable --now "$svc" >/dev/null 2>&1; then
                _ok "已禁用: ${DIM}${svc}${RST}"
            else
                _warn "禁用失败: ${svc}"
            fi
        fi
    done

    if dpkg -l pcp 2>/dev/null | grep -q '^ii'; then
        _info "检测到 PCP，正在清理..."
        for svc in pmcd pmproxy pmlogger; do
            systemctl disable --now "$svc" >/dev/null 2>&1 || true
        done
        _run_spin "卸载 PCP 组件..." apt-get purge -y pcp pcp-conf
        _pulse "PCP 已禁用并清理"
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
        if _run_spin "更新 initramfs..." update-initramfs -u; then
            _pulse "initramfs 已更新"
        else
            _warn "initramfs 更新失败"
        fi
    fi
}

deep_prune() {
    _step "6/6" "$BB" "深度清理缓存与冗余文件"

    sync

    _run_spin "清理孤立包..." apt-get autoremove --purge -y -q
    _pulse "孤立包清理完成"

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

    command -v docker >/dev/null 2>&1 && docker system prune -a -f --volumes >/dev/null 2>&1 && _ok "Docker 已清理" || true
    command -v flatpak >/dev/null 2>&1 && flatpak uninstall --unused -y >/dev/null 2>&1 && _ok "Flatpak 已清理" || true

    sync
}

kernel_prune
sys_upgrade
config_optimize
service_prune
module_blacklist
deep_prune

echo
_rainbow_flow
echo
_finale
echo
_rainbow_flow
_cursor_show
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
