#!/bin/bash

set -euo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

if [ "$EUID" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行此套件。"
    exit 1
fi

echo "============================================================"
echo " Debian Advanced Optimizer"
echo "============================================================"
read -r -p "确认启动全自动优化与清理流程？[y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    exit 0
fi

sys_upgrade() {
    echo "[1/4] 正在精简系统组件并执行全局升级..."
    apt-get purge -y 'qemu*' os-prober laptop-detect pciutils dmidecode >/dev/null 2>&1 || true
    apt-get autoremove --purge -y >/dev/null 2>&1 || true
    apt-get clean -qq
    
    local rc_pkgs
    rc_pkgs=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}')
    if [ -n "$rc_pkgs" ]; then
        echo "$rc_pkgs" | xargs apt-get purge -y -qq
    fi
    
    apt-get update -qq
    apt-get full-upgrade -y -qq
    apt-get autoremove --purge -y -qq
}

kernel_prune() {
    echo "[2/4] 正在扫描并清理冗余系统内核..."
    local current
    current="$(uname -r)"
    local cleanup=()
    
    for pkg in $(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^linux-'); do
        if [[ "$pkg" =~ ^linux-(libc-dev|base|compiler|kbuild|doc|perf|source|tools) ]]; then
            continue
        fi
        if [[ "$pkg" == *"$current"* ]]; then
            continue
        fi
        if dpkg-query -W -f='${Depends} ${Recommends}\n' "$pkg" 2>/dev/null | grep -q "$current"; then
            continue
        fi
        if [[ "$pkg" =~ (image|headers|modules|xanmod|liquorix|bbr|zen|surface|joeyblog|mainline|custom) ]]; then
            cleanup+=("$pkg")
        fi
    done
    
    if [ ${#cleanup[@]} -gt 0 ]; then
        apt-get purge -y --no-install-recommends "${cleanup[@]}" >/dev/null 2>&1 || true
        update-grub >/dev/null 2>&1 || true
    fi
}

config_optimize() {
    echo "[3/4] 正在执行精准配置注入..."
    
    local sysctl_target="/etc/sysctl.d/99-default.conf"
    mkdir -p "/etc/sysctl.d"
    [ -f "$sysctl_target" ] || touch "$sysctl_target"
    
    if [ -w "$sysctl_target" ] && [ ! -L "$sysctl_target" ]; then
        local tmp_s
        tmp_s="$(mktemp)"
        cp -p "$sysctl_target" "$tmp_s"
        
        local keys=("net.core.default_qdisc" "net.ipv4.tcp_fastopen" "net.ipv4.tcp_max_syn_backlog" "net.core.somaxconn" "net.core.netdev_max_backlog" "net.ipv4.ip_local_port_range" "net.ipv4.tcp_mtu_probing")
        local vals=("fq" "3" "4096" "4096" "4096" "1024 65535" "1")
        
        local curr_cc
        curr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
        local avail_cc
        avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
        
        if [[ "$curr_cc" == "bbr3" ]]; then
            :
        elif [[ "$avail_cc" == *"bbr3"* ]]; then
            keys+=("net.ipv4.tcp_congestion_control")
            vals+=("bbr3")
        else
            keys+=("net.ipv4.tcp_congestion_control")
            vals+=("bbr")
            if command -v modprobe >/dev/null 2>&1; then
                modprobe tcp_bbr >/dev/null 2>&1 || true
                if [ -w /etc/modules ] && ! grep -q "^tcp_bbr$" /etc/modules 2>/dev/null; then
                    echo "tcp_bbr" >> /etc/modules
                fi
            fi
        fi

        for ((i=0; i<${#keys[@]}; i++)); do
            local k="${keys[$i]}"
            local v="${vals[$i]}"
            if grep -qE "^[[:space:]]*[#;]*[[:space:]]*${k//./\.}[[:space:]]*=" "$sysctl_target"; then
                sed -i -E "s/^[[:space:]]*[#;]*[[:space:]]*${k//./\.}[[:space:]]*=.*/$k = $v/" "$tmp_s"
            else
                echo "$k = $v" >> "$tmp_s"
            fi
        done
        
        chmod 644 "$tmp_s"
        mv -f "$tmp_s" "$sysctl_target"
        
        systemctl restart systemd-sysctl >/dev/null 2>&1 || true
        if systemctl is-active --quiet networking.service >/dev/null 2>&1; then
            systemctl restart networking >/dev/null 2>&1 || true
        fi
    fi

    local j_conf="/etc/systemd/journald.conf"
    if [ -f "$j_conf" ]; then
        local tmp_j
        tmp_j="$(mktemp)"
        awk '
            BEGIN {
                expected["Compress"] = "yes"
                expected["SystemMaxUse"] = "32M"
                expected["SystemMaxFileSize"] = "4M"
                expected["SystemMaxFiles"] = "8"
                expected["RuntimeMaxUse"] = "8M"
                expected["RuntimeMaxFileSize"] = "2M"
                expected["RuntimeMaxFiles"] = "4"
                expected["MaxRetentionSec"] = "7day"
                in_journal = 0; found_journal = 0
            }
            function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
            function emit_missing() {
                for (k in expected) { if (!done[k]) { print k "=" expected[k]; done[k] = 1 } }
            }
            /^[[:space:]]*\[/ {
                section = trim($0)
                if (in_journal && section != "[Journal]") { emit_missing() }
                in_journal = (section == "[Journal]")
                if (in_journal) found_journal = 1
                print; next
            }
            in_journal {
                line = trim($0); test_line = line; sub(/^#[[:space:]]*/, "", test_line)
                if (test_line ~ /^[A-Za-z]+[[:space:]]*=/) {
                    key = test_line; sub(/[[:space:]]*=.*/, "", key)
                    if (key in expected) {
                        if (!done[key]) { print key "=" expected[key]; done[key] = 1 }
                        next
                    }
                }
                print; next
            }
            { print }
            END {
                if (in_journal) { emit_missing() }
                else if (!found_journal) { print "\n[Journal]"; emit_missing() }
            }
        ' "$j_conf" > "$tmp_j"
        chmod --reference="$j_conf" "$tmp_j" 2>/dev/null || true
        mv -f "$tmp_j" "$j_conf"
        systemctl restart systemd-journald >/dev/null 2>&1 || true
    fi

    local r_conf="/etc/logrotate.d/rsyslog"
    if [ -f "$r_conf" ]; then
        local tmp_r
        tmp_r="$(mktemp)"
        awk '
            BEGIN { in_block = 0; in_header = 0; target_block = 0 }
            function reset_b() { in_block=0; in_header=0; target_block=0; size_d=0; rot_d=0; comp_d=0 }
            function emit_m() {
                if(target_block) {
                    if(!size_d) print "\tmaxsize 5M"; if(!rot_d) print "\trotate 2"; if(!comp_d) print "\tcompress"
                }
            }
            /^[[:space:]]*[^#{}]*\{[[:space:]]*$/ {
                target_block = ($0 ~ /\/var\/log\//); in_block = 1; in_header = 0; size_d=0; rot_d=0; comp_d=0
                print; next
            }
            !in_block && !in_header {
                line = $0; sub(/^[[:space:]]+/, "", line)
                if (line ~ /^#/ || line == "") { print; next }
                if (line ~ /\/var\/log\// && line !~ /\{/) { in_header = 1; target_block = 1; print; next }
            }
            in_header {
                if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) { in_header=0; in_block=1; size_d=0; rot_d=0; comp_d=0; print; next }
                if ($0 !~ /^[[:space:]]*#/ && $0 ~ /\/var\/log\//) target_block=1
                print; next
            }
            in_block {
                line = $0; sub(/^[[:space:]]+/, "", line)
                if (line ~ /^\}/) { emit_m(); print; reset_b(); next }
                if (!target_block) { print; next }
                test_line = line; sub(/^#[[:space:]]*/, "", test_line)
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
    fi
}

deep_prune() {
    echo "[4/4] 正在执行底层缓存与冗余文件全盘扫描清理..."
    sync
    apt-get autoremove --purge -y -q >/dev/null 2>&1 || true
    apt-get clean -y -q >/dev/null 2>&1 || true
    rm -rf /var/cache/apt/archives/* 2>/dev/null || true
    
    local prune="-type d \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /snap \) -prune -o"
    
    eval "find / $prune -type f \( -name '*.dpkg-old' -o -name '*.dpkg-dist' -o -name '*.dpkg-new' -o -name '*.ucf-old' -o -name '*.ucf-dist' \) -print -delete 2>/dev/null || true"
    eval "find / $prune -type f \( -name '*.bak' -o -name '*.swp' -o -name '*~' -o -name '*.old' -o -name '*.tmp' \) -print -delete 2>/dev/null || true"
    
    rm -f /vmlinuz.old /initrd.img.old /boot/vmlinuz.old /boot/initrd.img.old 2>/dev/null || true
    
    eval "find / $prune -type f -name 'core' -exec file {} \; 2>/dev/null | grep -i 'core file' | awk -F: '{print \$1}' | xargs -I {} rm -f {} 2>/dev/null || true"
    find /var/crash /var/lib/systemd/coredump /var/tmp -type f -print -delete 2>/dev/null || true
    
    for d in /home/* /root; do
        if [ -d "$d" ]; then
            find "$d/.cache" "$d/.local/share/Trash" -type f -print -delete 2>/dev/null || true
            find "$d" -maxdepth 1 -type f \( -name ".bash_history" -o -name ".viminfo" -o -name ".wget-hsts" \) -print -delete 2>/dev/null || true
        fi
    done
    
    rm -rf ~/.npm/_cacache ~/.m2/repository ~/.gradle/caches 2>/dev/null || true
    
    find /tmp -type f -print -delete 2>/dev/null || true
    
    eval "find / $prune -type f -name '*.log' -print -exec truncate -s 0 {} \; 2>/dev/null || true"
    eval "find / $prune -type f \( -name '*.log.*' -o -name '*.gz' \) -path '*/log/*' -print -delete 2>/dev/null || true"
    
    rm -rf /var/log/journal/* 2>/dev/null || true
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    
    command -v docker >/dev/null 2>&1 && docker system prune -a -f --volumes >/dev/null 2>&1 || true
    command -v flatpak >/dev/null 2>&1 && flatpak uninstall --unused -y >/dev/null 2>&1 || true
    
    sync
}

sys_upgrade
kernel_prune
config_optimize
deep_prune

echo "============================================================"
echo " 优化与清理流程已全部完成，建议执行 reboot 重启系统。"
echo "============================================================"
