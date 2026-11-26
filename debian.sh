#!/bin/bash
set -uo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

OS_ID=""
OS_VER_ID=""
OS_PRETTY="Unknown Linux"
IS_CONTAINER=0
HAS_SYSTEMD=0
HAS_IPV4=0
HAS_IPV6=0
HAS_ZRAM=0
MEM_MB=0
VIRT_LABEL="物理机/VM"
SYSCTL_TARGET=""
MODULES_TARGET=""
RUN_LOG=""
TMP_WORK=""
AUTO_YES=0
INITRAMFS_DIRTY=0

NET_MANAGERS=()
DHCP_PUSH_REASONS=()
DNS_ORDER=()

init_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_RST=$'\033[0m'
        C_DIM=$'\033[2m'
        C_GRN=$'\033[0;32m'
        C_BLU=$'\033[0;34m'
        C_BRED=$'\033[1;31m'
        C_BGRN=$'\033[1;32m'
        C_BYLW=$'\033[1;33m'
        C_BCYN=$'\033[1;36m'
        C_BWHT=$'\033[1;37m'
    else
        C_RST="" C_DIM="" C_GRN="" C_BLU=""
        C_BRED="" C_BGRN="" C_BYLW="" C_BCYN="" C_BWHT=""
    fi
}

cleanup_all() {
    if [ -n "$TMP_WORK" ] && [ -d "$TMP_WORK" ]; then
        rm -rf "$TMP_WORK" 2>/dev/null || true
    fi
}

ensure_tmp_work() {
    if [ -z "$TMP_WORK" ] || [ ! -d "$TMP_WORK" ]; then
        TMP_WORK="$(mktemp -d)"
        chmod 0700 "$TMP_WORK" 2>/dev/null || true
        RUN_LOG="${TMP_WORK}/run.log"
    fi
}

term_rule_width() {
    local cols="${COLUMNS:-}"
    if [ -z "$cols" ] && command -v tput >/dev/null 2>&1; then
        cols="$(tput cols 2>/dev/null || true)"
    fi
    if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -le 0 ]; then
        cols=38
    fi
    if [ "$cols" -lt 28 ]; then
        cols=28
    elif [ "$cols" -gt 44 ]; then
        cols=44
    fi
    printf '%s' "$cols"
}

draw_rule() {
    local color="$1"
    local ch="$2"
    local w="" line=""
    w="$(term_rule_width)"
    printf -v line '%*s' "$w" ''
    line="${line// /$ch}"
    echo -e "${color}${line}${C_RST}"
}

hr() {
    draw_rule "$C_BLU" "━"
}

hr_thin() {
    draw_rule "$C_DIM" "─"
}

info() {
    echo -e "  ${C_BCYN}•${C_RST} $*"
}

ok() {
    echo -e "  ${C_BGRN}✔${C_RST} $*"
}

warn() {
    echo -e "  ${C_BYLW}!${C_RST} $*"
}

err() {
    echo -e "  ${C_BRED}✘${C_RST} $*" >&2
}

die() {
    err "$1"
    exit 1
}

step_title() {
    local idx="$1"
    local title="$2"
    echo ""
    hr_thin
    echo -e "  ${C_BCYN}[${idx}]${C_RST} ${C_BWHT}${title}${C_RST}"
}

normalize_input() {
    local v="$1"
    v="${v//$'\r'/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

flush_tty_input() {
    [ -t 0 ] || return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import termios; termios.tcflush(0, termios.TCIFLUSH)' 2>/dev/null || true
        return 0
    fi
    local saved_stty=""
    saved_stty="$(stty -g 2>/dev/null || true)"
    if [ -n "$saved_stty" ]; then
        stty -icanon -echo min 0 time 0 2>/dev/null || true
        while IFS= read -r -t 0.01 -n 4096 _ 2>/dev/null; do :; done
        stty "$saved_stty" 2>/dev/null || true
    fi
}

read_input() {
    local out_var="$1"
    local prompt_str="$2"
    local raw=""
    printf '%b' "$prompt_str"
    if ! IFS= read -r raw; then
        [ -n "$out_var" ] && printf -v "$out_var" '%s' ""
        return 1
    fi
    [ -n "$out_var" ] && printf -v "$out_var" '%s' "$(normalize_input "$raw")"
    return 0
}

run_logged() {
    local label="$1"
    shift
    ensure_tmp_work
    if "$@" >"$RUN_LOG" 2>&1; then
        ok "$label"
        return 0
    fi
    warn "${label} 出现异常"
    if [ -s "$RUN_LOG" ]; then
        tail -n 5 "$RUN_LOG" | while IFS= read -r l; do
            echo -e "    ${C_DIM}${l}${C_RST}"
        done
    fi
    return 1
}

atomic_replace_if_changed() {
    local src="$1"
    local dst="$2"
    local mode="${3:-0644}"
    if [ -f "$dst" ] && cmp -s "$src" "$dst" 2>/dev/null; then
        rm -f "$src" 2>/dev/null || true
        return 1
    fi
    if [ -f "$dst" ]; then
        chmod --reference="$dst" "$src" 2>/dev/null || chmod "$mode" "$src" 2>/dev/null || true
    else
        chmod "$mode" "$src" 2>/dev/null || true
    fi
    mv -f "$src" "$dst"
    return 0
}

upsert_block_file() {
    local file="$1"
    local marker_start="$2"
    local marker_end="$3"
    local block_body="$4"
    local before_regex="${5:-}"
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/blk.XXXXXX")"
    [ -f "$file" ] || touch "$file"

    awk -v ms="$marker_start" -v me="$marker_end" -v body="$block_body" -v bpat="$before_regex" '
        BEGIN { in_blk=0; inserted=0 }
        function emit_blk() {
            print ms
            printf "%s\n", body
            print me
            inserted=1
        }
        $0 == ms { in_blk=1; next }
        in_blk {
            if ($0 == me) { in_blk=0 }
            next
        }
        !inserted && bpat != "" && $0 ~ bpat {
            emit_blk()
            print
            next
        }
        { print }
        END {
            if (!inserted) {
                if (NR > 0) print ""
                emit_blk()
            }
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

upsert_ini_section() {
    local file="$1"
    local target_sec="$2"
    shift 2
    local -a kv_pairs=("$@")
    local tmp_f="" pairs_str=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/ini.XXXXXX")"
    [ -f "$file" ] || touch "$file"
    pairs_str="$(printf '%s\n' "${kv_pairs[@]}")"

    awk -v tsec="$target_sec" -v pstr="$pairs_str" '
        BEGIN {
            n = split(pstr, arr, "\n")
            for (i = 1; i <= n; i++) {
                if (arr[i] == "") continue
                eq = index(arr[i], "=")
                if (eq > 1) {
                    k = substr(arr[i], 1, eq - 1)
                    v = substr(arr[i], eq + 1)
                    order[++cnt] = k
                    expected[k] = v
                }
            }
            in_sec = 0
            found_sec = 0
        }
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        function emit_missing(    i, k) {
            for (i = 1; i <= cnt; i++) {
                k = order[i]
                if (!done[k]) {
                    print k "=" expected[k]
                    done[k] = 1
                }
            }
        }
        /^[[:space:]]*\[/ {
            sec = trim($0)
            if (in_sec && sec != tsec) emit_missing()
            in_sec = (sec == tsec)
            if (in_sec) found_sec = 1
            print
            next
        }
        in_sec {
            line = trim($0)
            test_line = line
            sub(/^[#;][[:space:]]*/, "", test_line)
            if (test_line ~ /^[A-Za-z0-9_.-]+[[:space:]]*=/) {
                key = test_line
                sub(/[[:space:]]*=.*/, "", key)
                if (key in expected) {
                    if (!done[key]) {
                        print key "=" expected[key]
                        done[key] = 1
                    }
                    next
                }
            }
            print
            next
        }
        { print }
        END {
            if (in_sec) {
                emit_missing()
            } else if (!found_sec) {
                if (NR > 0) print ""
                print tsec
                emit_missing()
            }
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

upsert_sysctl_kv() {
    local file="$1"
    local key="$2"
    local val="$3"
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/sys.XXXXXX")"
    [ -f "$file" ] || touch "$file"

    awk -v tkey="$key" -v tval="$val" '
        BEGIN { written = 0 }
        {
            raw = $0
            sub(/^[[:space:]]+/, "", raw)
            is_cmt = (raw ~ /^[#;]/)
            clean = raw
            if (is_cmt) sub(/^[#;]+[[:space:]]*/, "", clean)
            eq = index(clean, "=")
            if (eq > 0) {
                k = substr(clean, 1, eq - 1)
                sub(/[[:space:]]+$/, "", k)
                gsub(/\//, ".", k)
                if (k == tkey) {
                    if (!written) {
                        print tkey " = " tval
                        written = 1
                    }
                    next
                }
            }
            print $0
        }
        END {
            if (!written) print tkey " = " tval
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

delete_sysctl_kv() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 1
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/dsys.XXXXXX")"

    awk -v tkey="$key" '
        {
            raw = $0
            sub(/^[[:space:]]+/, "", raw)
            if (raw ~ /^[#;]/) { print $0; next }
            eq = index(raw, "=")
            if (eq > 0) {
                k = substr(raw, 1, eq - 1)
                sub(/[[:space:]]+$/, "", k)
                gsub(/\//, ".", k)
                if (k == tkey) next
            }
            print $0
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

ensure_module_line() {
    local file="$1"
    local mod="$2"
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/mod.XXXXXX")"
    [ -f "$file" ] || touch "$file"

    awk -v m="$mod" '
        BEGIN { seen = 0 }
        {
            t = $0
            sub(/^[[:space:]]+/, "", t)
            sub(/[[:space:]]+$/, "", t)
            if (t == m) {
                if (!seen) { print m; seen = 1 }
                next
            }
            print $0
        }
        END {
            if (!seen) print m
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

remove_module_line() {
    local file="$1"
    local mod="$2"
    [ -f "$file" ] || return 1
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/rmod.XXXXXX")"

    awk -v m="$mod" '
        {
            t = $0
            sub(/^[[:space:]]+/, "", t)
            sub(/[[:space:]]+$/, "", t)
            if (t == m) next
            print $0
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

is_pkg_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -qx 'install ok installed'
}

disable_unit_if_exists() {
    local unit="$1"
    [ "$HAS_SYSTEMD" -eq 1 ] || return 1
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | awk '{print $1}' | grep -qxF "$unit"; then
        systemctl disable --now "$unit" >/dev/null 2>&1 && return 0
    fi
    return 1
}

detect_sysctl_target() {
    if [ -L /etc/sysctl.d/99-sysctl.conf ] || [ -f /etc/sysctl.conf ]; then
        local major="${OS_VER_ID%%.*}"
        if [ "$OS_ID" = "debian" ] && [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -le 12 ]; then
            SYSCTL_TARGET="/etc/sysctl.conf"
            return 0
        elif [ "$OS_ID" = "ubuntu" ] && [ -f /etc/sysctl.conf ]; then
            if dpkg --compare-versions "${OS_VER_ID:-0}" le "24.04" 2>/dev/null; then
                SYSCTL_TARGET="/etc/sysctl.conf"
                return 0
            fi
        fi
    fi
    mkdir -p /etc/sysctl.d
    SYSCTL_TARGET="/etc/sysctl.d/99-sysctl.conf"
}

detect_modules_target() {
    if [ -f /etc/modules ]; then
        MODULES_TARGET="/etc/modules"
    else
        mkdir -p /etc/modules-load.d
        MODULES_TARGET="/etc/modules-load.d/modules.conf"
    fi
}

is_builtin_mod() {
    local mod="$1"
    local kver
    kver="$(uname -r)"
    [ -f "/lib/modules/${kver}/modules.builtin" ] && \
        grep -qE "(^|/)${mod}\.ko(\.|$)" "/lib/modules/${kver}/modules.builtin" 2>/dev/null
}

is_loadable_mod() {
    local mod="$1"
    ! is_builtin_mod "$mod" && command -v modinfo >/dev/null 2>&1 && modinfo -n "$mod" >/dev/null 2>&1
}

detect_network_and_push_status() {
    NET_MANAGERS=()
    DHCP_PUSH_REASONS=()

    if ip -4 route show default 2>/dev/null | grep -q .; then
        HAS_IPV4=1
    elif ip -4 -o addr show scope global 2>/dev/null | grep -q .; then
        HAS_IPV4=1
    else
        HAS_IPV4=0
    fi

    if ip -6 route show default 2>/dev/null | grep -q .; then
        HAS_IPV6=1
    elif ip -6 -o addr show scope global 2>/dev/null | grep -q .; then
        HAS_IPV6=1
    else
        HAS_IPV6=0
    fi

    if [ "$HAS_IPV4" -eq 0 ] && [ "$HAS_IPV6" -eq 1 ]; then
        DNS_ORDER=("2606:4700:4700::1111" "2001:4860:4860::8888" "1.1.1.1" "8.8.8.8")
    else
        DNS_ORDER=("1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888")
    fi

    if [ -f /etc/dhcpcd.conf ]; then
        NET_MANAGERS+=("dhcpcd")
        if ! grep -qE '^[[:space:]]*nohook[[:space:]].*resolv\.conf' /etc/dhcpcd.conf 2>/dev/null || \
           ! grep -qE '^[[:space:]]*nohook[[:space:]].*hostname' /etc/dhcpcd.conf 2>/dev/null; then
            DHCP_PUSH_REASONS+=("dhcpcd 未禁用 resolv.conf/hostname hook")
        fi
    fi

    if [ -f /etc/dhcp/dhclient.conf ]; then
        NET_MANAGERS+=("dhclient")
        if grep -qE '^[[:space:]]*request[[:space:]].*(domain-name-servers|host-name)' /etc/dhcp/dhclient.conf 2>/dev/null; then
            DHCP_PUSH_REASONS+=("dhclient 请求了 DNS 或主机名")
        fi
    fi

    if compgen -G "/etc/netplan/*.yaml" >/dev/null 2>&1; then
        NET_MANAGERS+=("netplan")
        if grep -qE 'dhcp[46]:[[:space:]]*(true|yes)' /etc/netplan/*.yaml 2>/dev/null; then
            if ! grep -qE 'use-dns:[[:space:]]*(false|no)' /etc/netplan/*.yaml 2>/dev/null || \
               ! grep -qE 'use-hostname:[[:space:]]*(false|no)' /etc/netplan/*.yaml 2>/dev/null; then
                DHCP_PUSH_REASONS+=("netplan DHCP 未关闭 DNS/主机名接管")
            fi
        fi
    fi

    if compgen -G "/etc/systemd/network/*.network" >/dev/null 2>&1; then
        NET_MANAGERS+=("networkd")
        if grep -qE '^[[:space:]]*DHCP[[:space:]]*=[[:space:]]*(yes|true|ipv4|ipv6)' /etc/systemd/network/*.network 2>/dev/null; then
            if ! grep -qE '^[[:space:]]*UseDNS[[:space:]]*=[[:space:]]*(no|false)' /etc/systemd/network/*.network 2>/dev/null || \
               ! grep -qE '^[[:space:]]*UseHostname[[:space:]]*=[[:space:]]*(no|false)' /etc/systemd/network/*.network 2>/dev/null; then
                DHCP_PUSH_REASONS+=("systemd-networkd 未设置 UseDNS/UseHostname=no")
            fi
        fi
    fi

    if [ "$HAS_SYSTEMD" -eq 1 ] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        NET_MANAGERS+=("systemd-resolved")
        DHCP_PUSH_REASONS+=("systemd-resolved 正在接管 DNS")
    elif [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf 2>/dev/null | grep -q 'systemd/resolve'; then
        DHCP_PUSH_REASONS+=("/etc/resolv.conf 仍指向 systemd-resolved")
    fi

    if [ -f /etc/cloud/cloud.cfg ]; then
        NET_MANAGERS+=("cloud-init")
        if ! grep -qE '^[[:space:]]*preserve_hostname:[[:space:]]*true' /etc/cloud/cloud.cfg 2>/dev/null; then
            DHCP_PUSH_REASONS+=("cloud-init 未锁定 preserve_hostname")
        fi
    fi

    if [ -f /etc/NetworkManager/NetworkManager.conf ] && [ "$HAS_SYSTEMD" -eq 1 ] && \
       systemctl is-active --quiet NetworkManager 2>/dev/null; then
        NET_MANAGERS+=("NetworkManager")
        if ! grep -qE '^[[:space:]]*dns[[:space:]]*=[[:space:]]*none' /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            DHCP_PUSH_REASONS+=("NetworkManager 管理着 resolv.conf")
        fi
    fi

    if [ -f /etc/resolv.conf ]; then
        if grep -qiE 'Generated by (dhcpcd|resolvconf|NetworkManager|systemd-resolved)' /etc/resolv.conf 2>/dev/null; then
            DHCP_PUSH_REASONS+=("resolv.conf 带有动态生成标记")
        elif grep -qE '^[[:space:]]*nameserver[[:space:]]+(127\.0\.0\.53|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.)' /etc/resolv.conf 2>/dev/null; then
            DHCP_PUSH_REASONS+=("resolv.conf 含内网/本地动态 DNS")
        fi
    else
        DHCP_PUSH_REASONS+=("缺少 /etc/resolv.conf")
    fi

    if [ "${#NET_MANAGERS[@]}" -eq 0 ]; then
        NET_MANAGERS=("static/ifupdown")
    fi
}

probe_bbr_capability_summary() {
    local kver avail_cc
    kver="$(uname -r)"
    if [ ! -w /proc/sys/net/ipv4/tcp_congestion_control ] || [ ! -w /proc/sys/net/core/default_qdisc ]; then
        printf '%s' "容器只读/不可写"
        return 0
    fi
    avail_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if grep -qwE 'bbr3?' <<< "$avail_cc"; then
        if is_builtin_mod tcp_bbr; then
            printf '%s' "已内置可用"
        else
            printf '%s' "模块已加载可用"
        fi
    elif is_loadable_mod tcp_bbr; then
        printf '%s' "已编译为模块 (待加载)"
    else
        printf '%s' "当前内核(${kver})未编译"
    fi
}

detect_system_info() {
    local id_like=""
    if [ -r /etc/os-release ]; then
        local k="" v=""
        while IFS='=' read -r k v; do
            v="${v%\"}"
            v="${v#\"}"
            v="${v%\'}"
            v="${v#\'}"
            case "$k" in
                ID) OS_ID="$v" ;;
                ID_LIKE) id_like="$v" ;;
                VERSION_ID) OS_VER_ID="$v" ;;
                PRETTY_NAME) OS_PRETTY="$v" ;;
            esac
        done < /etc/os-release
    fi
    OS_ID="${OS_ID,,}"
    if [ "$OS_ID" != "debian" ] && [ "$OS_ID" != "ubuntu" ]; then
        if [[ "$id_like" == *debian* ]]; then
            OS_ID="debian"
        elif [[ "$id_like" == *ubuntu* ]]; then
            OS_ID="ubuntu"
        else
            die "仅支持 Debian / Ubuntu 系统 (当前: ${OS_PRETTY})"
        fi
    fi

    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        HAS_SYSTEMD=1
    fi

    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt 2>/dev/null || true)"
        if systemd-detect-virt --container >/dev/null 2>&1; then
            IS_CONTAINER=1
        fi
    fi
    if [ "$IS_CONTAINER" -eq 0 ]; then
        if [ -f /.dockerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
            IS_CONTAINER=1
            [ -z "$virt" ] && virt="container"
        fi
    fi
    if [ "$IS_CONTAINER" -eq 1 ]; then
        VIRT_LABEL="容器 (${virt:-container})"
    elif [ -n "$virt" ] && [ "$virt" != "none" ]; then
        VIRT_LABEL="虚机 (${virt})"
    else
        VIRT_LABEL="物理机"
    fi

    MEM_MB="$(awk '/^MemTotal:/ {printf "%d", int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    if grep -q 'zram' /proc/swaps 2>/dev/null; then
        HAS_ZRAM=1
    fi

    detect_sysctl_target
    detect_modules_target
    detect_network_and_push_status
}

format_dns_lines() {
    local -a ns_list=()
    mapfile -t ns_list < <(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf 2>/dev/null)
    if [ "${#ns_list[@]}" -eq 0 ]; then
        echo -e "  ${C_DIM}DNS :${C_RST} 未配置"
        return 0
    fi
    local first_line="" ns=""
    local -a extra=()
    for ns in "${ns_list[@]}"; do
        if [ -z "$first_line" ]; then
            first_line="$ns"
        elif [ $(( ${#first_line} + 1 + ${#ns} )) -le 26 ]; then
            first_line="${first_line} ${ns}"
        else
            extra+=("$ns")
        fi
    done
    echo -e "  ${C_DIM}DNS :${C_RST} ${first_line}"
    for ns in "${extra[@]}"; do
        echo -e "        ${ns}"
    done
}

print_detection_summary() {
    local disk_info bbr_stat host_now push_stat
    disk_info="$(df -Ph / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')"
    host_now="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
    bbr_stat="$(probe_bbr_capability_summary)"
    if [ "${#DHCP_PUSH_REASONS[@]}" -gt 0 ]; then
        push_stat="${C_BYLW}有下发风险 (${#DHCP_PUSH_REASONS[@]}项)${C_RST}"
    else
        push_stat="${C_GRN}静态受控${C_RST}"
    fi

    echo ""
    hr
    echo -e "  ${C_BCYN}Debian / Ubuntu 新机优化${C_RST}"
    hr
    echo -e "  ${C_DIM}系统:${C_RST} ${C_BWHT}${OS_PRETTY}${C_RST}"
    echo -e "  ${C_DIM}内核:${C_RST} $(uname -r)"
    echo -e "  ${C_DIM}主机:${C_RST} ${host_now} · ${VIRT_LABEL}"
    echo -e "  ${C_DIM}内存:${C_RST} ${MEM_MB} MB"
    echo -e "  ${C_DIM}磁盘:${C_RST} ${disk_info}"
    echo -e "  ${C_DIM}网管:${C_RST} ${NET_MANAGERS[*]}"
    format_dns_lines
    echo -e "  ${C_DIM}状态:${C_RST} ${push_stat}"
    echo -e "  ${C_DIM}BBR :${C_RST} ${bbr_stat}"
    echo -e "  ${C_DIM}参数:${C_RST} ${SYSCTL_TARGET}"
    hr
}

patch_dhcpcd_conf() {
    local file="${1:-/etc/dhcpcd.conf}"
    [ -f "$file" ] || return 1
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/dhcpcd.XXXXXX")"

    awk '
        {
            raw = $0
            if (raw ~ /^[[:space:]]*nohook[[:space:]]+/) {
                line = raw
                sub(/^[[:space:]]*nohook[[:space:]]+/, "", line)
                n = split(line, toks, /,[[:space:]]*|[[:space:]]+/)
                kept = ""
                for (i = 1; i <= n; i++) {
                    if (toks[i] == "" || toks[i] == "resolv.conf" || toks[i] == "hostname") continue
                    kept = (kept == "" ? toks[i] : kept ", " toks[i])
                }
                if (kept != "") print "nohook " kept
                next
            }
            print raw
        }
        END {
            print "nohook resolv.conf"
            print "nohook hostname"
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

patch_dhclient_conf() {
    local file="${1:-/etc/dhcp/dhclient.conf}"
    [ -f "$file" ] || return 1
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/dhc.XXXXXX")"

    awk '
        BEGIN { in_req = 0; req_buf = "" }
        function flush_req(    s, n, arr, i, tok, out) {
            s = req_buf
            sub(/^[[:space:]]*request[[:space:]]*/, "", s)
            sub(/;[[:space:]]*$/, "", s)
            n = split(s, arr, /[[:space:]]*,[[:space:]]*/)
            out = ""
            for (i = 1; i <= n; i++) {
                tok = arr[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", tok)
                if (tok == "" || tok == "domain-name-servers" || tok == "domain-name" || \
                    tok == "domain-search" || tok == "host-name" || \
                    tok == "dhcp6.name-servers" || tok == "dhcp6.domain-search") continue
                out = (out == "" ? tok : out ", " tok)
            }
            if (out != "") print "request " out ";"
            in_req = 0
            req_buf = ""
        }
        /^[[:space:]]*request([[:space:]]|$)/ && !in_req {
            in_req = 1
            req_buf = $0
            if (req_buf ~ /;[[:space:]]*$/) flush_req()
            next
        }
        in_req {
            req_buf = req_buf " " $0
            if ($0 ~ /;[[:space:]]*$/) flush_req()
            next
        }
        { print }
        END {
            if (in_req) flush_req()
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

patch_netplan_yaml() {
    local file="$1"
    [ -f "$file" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c 'import yaml' >/dev/null 2>&1 || return 1

    local changed=0
    python3 - "$file" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

if not isinstance(data, dict) or 'network' not in data or not isinstance(data['network'], dict):
    sys.exit(1)

net = data['network']
changed = False
for sec in ('ethernets', 'wifis'):
    devs = net.get(sec)
    if not isinstance(devs, dict):
        continue
    for name, cfg in devs.items():
        if not isinstance(cfg, dict):
            continue
        has4 = str(cfg.get('dhcp4', '')).lower() in ('true', 'yes', '1')
        has6 = str(cfg.get('dhcp6', '')).lower() in ('true', 'yes', '1')
        if has4:
            ov = cfg.setdefault('dhcp4-overrides', {})
            if ov.get('use-dns') is not False or ov.get('use-hostname') is not False:
                ov['use-dns'] = False
                ov['use-hostname'] = False
                changed = True
        if has6:
            ov6 = cfg.setdefault('dhcp6-overrides', {})
            if ov6.get('use-dns') is not False or ov6.get('use-hostname') is not False:
                ov6['use-dns'] = False
                ov6['use-hostname'] = False
                changed = True
        if has4 and has6:
            ov4 = cfg.get('dhcp4-overrides', {})
            ov6 = cfg.get('dhcp6-overrides', {})
            for k, v in ov4.items():
                if ov6.get(k) != v:
                    ov6[k] = v
                    changed = True

if not changed:
    sys.exit(2)

with open(path, 'w', encoding='utf-8') as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
PYEOF
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    return 1
}

patch_systemd_network_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    local changed=1
    if grep -qE '^[[:space:]]*DHCP[[:space:]]*=[[:space:]]*(yes|true|ipv4|both)' "$file" 2>/dev/null; then
        upsert_ini_section "$file" "[DHCPv4]" "UseDNS=no" "UseHostname=no" && changed=0
    fi
    if grep -qE '^[[:space:]]*DHCP[[:space:]]*=[[:space:]]*(yes|true|ipv6|both)' "$file" 2>/dev/null; then
        upsert_ini_section "$file" "[DHCPv6]" "UseDNS=no" "UseHostname=no" && changed=0
    fi
    if grep -qE '^[[:space:]]*IPv6AcceptRA[[:space:]]*=[[:space:]]*(yes|true|1)' "$file" 2>/dev/null || \
       grep -qE '^\[IPv6AcceptRA\]' "$file" 2>/dev/null; then
        upsert_ini_section "$file" "[IPv6AcceptRA]" "UseDNS=no" && changed=0
    fi
    return $changed
}

patch_cloud_cfg() {
    local file="${1:-/etc/cloud/cloud.cfg}"
    [ -f "$file" ] || return 1
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/cloud.XXXXXX")"

    awk '
        BEGIN { seen = 0 }
        /^[[:space:]]*preserve_hostname:[[:space:]]*/ {
            if (!seen) {
                print "preserve_hostname: true"
                seen = 1
            }
            next
        }
        { print }
        END {
            if (!seen) print "preserve_hostname: true"
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

ensure_hosts_entry() {
    local hn=""
    hn="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)"
    hn="$(normalize_input "$hn")"
    [ -n "$hn" ] || return 0
    [ -f /etc/hosts ] || touch /etc/hosts
    if ! grep -qwF "$hn" /etc/hosts 2>/dev/null; then
        local tmp_f=""
        ensure_tmp_work
        tmp_f="$(mktemp "${TMP_WORK}/hosts.XXXXXX")"
        cp -p /etc/hosts "$tmp_f"
        printf '127.0.1.1\t%s\n' "$hn" >> "$tmp_f"
        if atomic_replace_if_changed "$tmp_f" /etc/hosts 0644; then
            ok "已补全 /etc/hosts 本机映射"
        fi
    fi
}

test_dns_resolution() {
    if command -v getent >/dev/null 2>&1; then
        getent hosts deb.debian.org >/dev/null 2>&1 || \
        getent hosts archive.ubuntu.com >/dev/null 2>&1 || \
        getent hosts cloudflare.com >/dev/null 2>&1
        return $?
    fi
    return 0
}

write_static_resolv_conf() {
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/resolv.XXXXXX")"
    local ns=""
    for ns in "${DNS_ORDER[@]}"; do
        printf 'nameserver %s\n' "$ns" >> "$tmp_f"
    done

    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] && cmp -s "$tmp_f" /etc/resolv.conf 2>/dev/null; then
        rm -f "$tmp_f" 2>/dev/null || true
        return 1
    fi

    if [ -e /etc/resolv.conf ] && command -v lsattr >/dev/null 2>&1 && command -v chattr >/dev/null 2>&1; then
        if lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
            chattr -i /etc/resolv.conf 2>/dev/null || true
        fi
    fi

    rm -f /etc/resolv.conf 2>/dev/null || true
    chmod 0644 "$tmp_f"
    mv -f "$tmp_f" /etc/resolv.conf
    return 0
}

step_dns_and_anti_dhcp() {
    step_title "1/7" "检测并锁定 DNS 与主机名"

    local netplan_changed=0
    local networkd_changed=0
    local resolved_was_active=0

    if [ -f /etc/dhcpcd.conf ]; then
        if patch_dhcpcd_conf /etc/dhcpcd.conf; then
            ok "dhcpcd 已阻止下发 DNS 与主机名"
        fi
    fi

    if [ -f /etc/dhcp/dhclient.conf ]; then
        if patch_dhclient_conf /etc/dhcp/dhclient.conf; then
            ok "dhclient 已移除 DNS 与主机名请求"
        fi
    fi

    local yf=""
    for yf in /etc/netplan/*.yaml; do
        [ -f "$yf" ] || continue
        if patch_netplan_yaml "$yf"; then
            ok "Netplan 已关闭 DHCP DNS/主机名: $(basename "$yf")"
            netplan_changed=1
        fi
    done
    if [ "$netplan_changed" -eq 1 ] && [ "$IS_CONTAINER" -eq 0 ] && command -v netplan >/dev/null 2>&1; then
        netplan apply >/dev/null 2>&1 || true
    fi

    local nf=""
    for nf in /etc/systemd/network/*.network; do
        [ -f "$nf" ] || continue
        if patch_systemd_network_file "$nf"; then
            ok "networkd 已阻止下发: $(basename "$nf")"
            networkd_changed=1
        fi
    done
    if [ "$networkd_changed" -eq 1 ] && [ "$HAS_SYSTEMD" -eq 1 ]; then
        systemctl reload systemd-networkd >/dev/null 2>&1 || true
    fi

    if [ -f /etc/cloud/cloud.cfg ]; then
        if patch_cloud_cfg /etc/cloud/cloud.cfg; then
            ok "cloud-init 已开启 preserve_hostname"
        fi
    fi

    if [ -f /etc/NetworkManager/NetworkManager.conf ] && [ "$HAS_SYSTEMD" -eq 1 ] && \
       systemctl is-active --quiet NetworkManager 2>/dev/null; then
        if upsert_ini_section /etc/NetworkManager/NetworkManager.conf "[main]" "dns=none"; then
            systemctl reload NetworkManager >/dev/null 2>&1 || true
            ok "NetworkManager 已禁用自动写 DNS"
        fi
    fi

    if [ "$HAS_SYSTEMD" -eq 1 ] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        resolved_was_active=1
        systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
        ok "已停用 systemd-resolved stub"
    fi

    ensure_hosts_entry

    local resolv_bak=""
    ensure_tmp_work
    resolv_bak="${TMP_WORK}/resolv.conf.bak"
    if [ -e /etc/resolv.conf ]; then
        cp -a /etc/resolv.conf "$resolv_bak" 2>/dev/null || true
    fi

    if write_static_resolv_conf; then
        if test_dns_resolution; then
            ok "静态 DNS 已写入并验证可用"
        else
            warn "新 DNS 解析超时，还原原配置以保证升级"
            rm -f /etc/resolv.conf 2>/dev/null || true
            if [ -e "$resolv_bak" ]; then
                cp -a "$resolv_bak" /etc/resolv.conf 2>/dev/null || true
            fi
            if [ "$resolved_was_active" -eq 1 ] && [ "$HAS_SYSTEMD" -eq 1 ]; then
                systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
            fi
        fi
    else
        ok "DNS 与防下发策略均已就绪"
    fi
}

step_apt_dpkg_slimming() {
    step_title "2/7" "写入 dpkg 与 apt 长期瘦身策略"

    local dpkg_body
    dpkg_body=$'path-exclude=/usr/share/doc/*\npath-include=/usr/share/doc/*/copyright\npath-exclude=/usr/share/man/*\npath-exclude=/usr/share/info/*\npath-exclude=/usr/share/lintian/*\npath-exclude=/usr/share/linda/*\npath-exclude=/usr/share/locale/*\npath-include=/usr/share/locale/locale.alias\npath-include=/usr/share/locale/en*\npath-include=/usr/share/locale/zh_CN*'
    if upsert_block_file /etc/dpkg/dpkg.cfg "# >>> sys-opt-dpkg >>>" "# <<< sys-opt-dpkg <<<" "$dpkg_body"; then
        ok "已更新 /etc/dpkg/dpkg.cfg"
    else
        ok "/etc/dpkg/dpkg.cfg 无变化"
    fi

    local apt_body
    apt_body=$'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";\nAcquire::Languages "none";'
    if upsert_block_file /etc/apt/apt.conf "# >>> sys-opt-apt >>>" "# <<< sys-opt-apt <<<" "$apt_body"; then
        ok "已更新 /etc/apt/apt.conf"
    else
        ok "/etc/apt/apt.conf 无变化"
    fi
}

get_protected_kernel_pkgs() {
    local current="$1"
    local -a seeds=()
    local -a queue=()
    local -A seen=()
    local p="" dep="" d=""

    while IFS= read -r p; do
        [ -z "$p" ] && continue
        if [[ "$p" == *"$current"* ]]; then
            seeds+=("$p")
        fi
    done < <(dpkg-query -W -f='${Package}\n' 'linux-*' 2>/dev/null || true)

    for p in "${seeds[@]}"; do
        queue+=("$p")
        seen["$p"]=1
    done

    local idx=0
    while [ "$idx" -lt "${#queue[@]}" ]; do
        p="${queue[$idx]}"
        idx=$((idx + 1))
        dep="$(dpkg-query -W -f='${Depends}\n' "$p" 2>/dev/null || true)"
        for d in $(tr ',|()' '\n' <<< "$dep" | awk '{print $1}'); do
            [[ "$d" == linux-* ]] || continue
            if [ -z "${seen[$d]:-}" ]; then
                seen["$d"]=1
                queue+=("$d")
            fi
        done
    done

    for p in "${!seen[@]}"; do
        printf '%s\n' "$p"
    done
}

prune_old_kernels() {
    if [ "$IS_CONTAINER" -eq 1 ]; then
        info "容器环境跳过内核清理"
        return 0
    fi

    local current latest="" mod_dir="" ver=""
    current="$(uname -r)"

    for mod_dir in /lib/modules/[0-9]*; do
        [ -d "$mod_dir" ] || continue
        ver="$(basename "$mod_dir")"
        if [ -f "/boot/vmlinuz-${ver}" ] || [ -f "${mod_dir}/modules.dep" ]; then
            if [ -z "$latest" ] || dpkg --compare-versions "$ver" gt "$latest" 2>/dev/null; then
                latest="$ver"
            fi
        fi
    done

    if [ -n "$latest" ] && [ "$latest" != "$current" ]; then
        warn "检测到更新内核 ${latest}，当前运行 ${current}，跳过卸载"
        return 0
    fi

    local -A protected=()
    local p=""
    while IFS= read -r p; do
        [ -n "$p" ] && protected["$p"]=1
    done < <(get_protected_kernel_pkgs "$current")

    local -a cleanup=()
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [[ "$p" =~ ^linux-(libc-dev|base|compiler|kbuild|doc|perf|source|tools|sysctl-defaults|cpupower) ]] && continue
        [ -n "${protected[$p]:-}" ] && continue
        if dpkg-query -W -f='${Depends} ${Recommends}\n' "$p" 2>/dev/null | grep -qF "$current"; then
            continue
        fi
        if [[ "$p" =~ (image|headers|modules|xanmod|liquorix|bbr|zen|surface|mainline|custom) ]]; then
            cleanup+=("$p")
        fi
    done < <(dpkg-query -W -f='${Package}\n' 'linux-*' 2>/dev/null || true)

    if [ "${#cleanup[@]}" -eq 0 ]; then
        ok "无多余旧内核"
        return 0
    fi

    info "清理旧内核 (${#cleanup[@]} 个): ${cleanup[*]}"
    if run_logged "旧内核包卸载" apt-get purge -y --no-install-recommends "${cleanup[@]}"; then
        if command -v update-grub >/dev/null 2>&1; then
            if update-grub >/dev/null 2>&1; then
                ok "GRUB 已更新"
            fi
        fi
    fi
}

step_pkg_prune_and_upgrade() {
    step_title "3/7" "精简冗余包、全局升级与内核清理"

    if is_pkg_installed openssh-server; then
        apt-mark manual openssh-server >/dev/null 2>&1 || true
    fi

    local -a rc_pkgs=()
    mapfile -t rc_pkgs < <(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}')
    if [ "${#rc_pkgs[@]}" -gt 0 ]; then
        run_logged "清理 ${#rc_pkgs[@]} 个 rc 残留包" apt-get purge -y -q "${rc_pkgs[@]}" || true
    fi

    local -a candidates=(
        man-db manpages manpages-dev groff-base info install-info
        dictionaries-common emacsen-common ispell iamerican ibritish
        ienglish-common wamerican installation-report popularity-contest
        reportbug debian-faq doc-debian util-linux-locales
        os-prober laptop-detect pcp pcp-conf
        bluez cups cups-browsed cups-common cups-client cups-daemon
        avahi-daemon modemmanager wpasupplicant
        rpcbind nfs-common exim4 exim4-base exim4-config exim4-daemon-light
        qemu-utils
    )
    if [ "$OS_ID" = "ubuntu" ]; then
        candidates+=(
            snapd apport whoopsie landscape-common
            ubuntu-pro-client ubuntu-advantage-tools
            fwupd multipath-tools motd-news-config
        )
    fi

    local -a to_purge=()
    local pkg=""
    for pkg in "${candidates[@]}"; do
        if is_pkg_installed "$pkg"; then
            to_purge+=("$pkg")
        fi
    done
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && to_purge+=("$pkg")
    done < <(dpkg-query -W -f='${Status}\t${Package}\n' 'qemu-system*' 'plymouth*' 2>/dev/null | awk -F'\t' '$1=="install ok installed"{print $2}' || true)

    if [ "${#to_purge[@]}" -gt 0 ]; then
        if [ "$OS_ID" = "ubuntu" ] && is_pkg_installed snapd && command -v snap >/dev/null 2>&1; then
            local s=""
            for s in $(snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -vE '^(bare|core|snapd)$' || true); do
                snap remove --purge "$s" >/dev/null 2>&1 || true
            done
        fi
        run_logged "卸载 ${#to_purge[@]} 个冗余软件包" apt-get purge -y --no-install-recommends "${to_purge[@]}" || true
        if [ "$OS_ID" = "ubuntu" ] && ! is_pkg_installed snapd; then
            rm -rf /var/cache/snapd /root/snap /home/*/snap 2>/dev/null || true
        fi
    else
        ok "无待卸载冗余软件包"
    fi

    run_logged "刷新软件源索引" apt-get update -q || true
    run_logged "执行系统全局升级" apt-get full-upgrade -y -q \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" || true

    prune_old_kernels

    if [ -d /usr/share/doc ]; then
        find /usr/share/doc -type f ! -name 'copyright' -delete 2>/dev/null || true
        find /usr/share/doc -type d -empty -delete 2>/dev/null || true
    fi
    find /usr/share/man /usr/share/info /usr/share/lintian /usr/share/linda -type f -delete 2>/dev/null || true
    if [ -d /usr/share/locale ]; then
        local loc="" bname=""
        for loc in /usr/share/locale/*; do
            [ -e "$loc" ] || continue
            bname="$(basename "$loc")"
            case "$bname" in
                locale.alias|en|en_*|zh_CN|zh_CN.*) continue ;;
                *) rm -rf "$loc" 2>/dev/null || true ;;
            esac
        done
    fi
    ok "现存文档与冗余多语言已清理"
}

step_service_prune() {
    step_title "4/7" "禁用冗余系统服务与定时任务"
    if [ "$HAS_SYSTEMD" -eq 0 ]; then
        info "无 systemd 运行环境，跳过服务禁用"
        return 0
    fi

    local -a units=(
        cups.service cups.socket cups-browsed.service
        bluetooth.service
        avahi-daemon.service avahi-daemon.socket
        ModemManager.service
        rpcbind.service rpcbind.socket
        systemd-pstore.service
        e2scrub_all.timer e2scrub_reap.service
        man-db.timer
        apt-daily.timer apt-daily-upgrade.timer
        snapd.service snapd.socket snapd.seeded.service
        apport.service whoopsie.service fwupd.service
        multipathd.service multipathd.socket
        motd-news.timer
    )

    local disabled_cnt=0
    local u=""
    for u in "${units[@]}"; do
        if disable_unit_if_exists "$u"; then
            disabled_cnt=$((disabled_cnt + 1))
        fi
    done

    if [ "$disabled_cnt" -gt 0 ]; then
        ok "已禁用 ${disabled_cnt} 个冗余服务/定时器"
    else
        ok "无额外待禁用服务/定时器"
    fi
}

configure_bbr_fq() {
    if [ ! -w /proc/sys/net/ipv4/tcp_congestion_control ] || \
       [ ! -w /proc/sys/net/core/default_qdisc ]; then
        warn "无网络内核参数写权限，跳过 BBR/FQ 设置"
        return 0
    fi

    local chosen_qdisc=""
    modprobe sch_fq >/dev/null 2>&1 || true
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        chosen_qdisc="fq"
        if is_loadable_mod sch_fq; then
            if ensure_module_line "$MODULES_TARGET" "sch_fq"; then
                INITRAMFS_DIRTY=1
            fi
        else
            remove_module_line "$MODULES_TARGET" "sch_fq" || true
        fi
    else
        modprobe sch_fq_codel >/dev/null 2>&1 || true
        if sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1; then
            chosen_qdisc="fq_codel"
            if is_loadable_mod sch_fq_codel; then
                if ensure_module_line "$MODULES_TARGET" "sch_fq_codel"; then
                    INITRAMFS_DIRTY=1
                fi
            fi
        fi
    fi

    local avail_cc=""
    avail_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if ! grep -qwE 'bbr3?' <<< "$avail_cc"; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        avail_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    fi

    local chosen_cc=""
    if grep -qw 'bbr3' <<< "$avail_cc"; then
        chosen_cc="bbr3"
    elif grep -qw 'bbr' <<< "$avail_cc"; then
        chosen_cc="bbr"
    fi

    if [ -n "$chosen_cc" ] && sysctl -w "net.ipv4.tcp_congestion_control=${chosen_cc}" >/dev/null 2>&1; then
        if is_loadable_mod tcp_bbr; then
            if ensure_module_line "$MODULES_TARGET" "tcp_bbr"; then
                INITRAMFS_DIRTY=1
            fi
        else
            remove_module_line "$MODULES_TARGET" "tcp_bbr" || true
        fi
        if [ -n "$chosen_qdisc" ]; then
            upsert_sysctl_kv "$SYSCTL_TARGET" "net.core.default_qdisc" "$chosen_qdisc" || true
        fi
        upsert_sysctl_kv "$SYSCTL_TARGET" "net.ipv4.tcp_congestion_control" "$chosen_cc" || true
        ok "已启用 ${chosen_cc} + ${chosen_qdisc:-default}"
    else
        remove_module_line "$MODULES_TARGET" "tcp_bbr" || true
        if [ -n "$chosen_qdisc" ]; then
            upsert_sysctl_kv "$SYSCTL_TARGET" "net.core.default_qdisc" "$chosen_qdisc" || true
        fi
        delete_sysctl_kv "$SYSCTL_TARGET" "net.ipv4.tcp_congestion_control" || true
        warn "内核 $(uname -r) 未编译 BBR，已保留现有算法"
    fi
}

apply_sysctl_optimizations() {
    if [ ! -w /proc/sys/net/ipv4/tcp_fastopen ] 2>/dev/null && [ "$IS_CONTAINER" -eq 1 ]; then
        warn "容器环境无 sysctl 写权限，跳过内核参数"
        return 0
    fi

    local syn_backlog=4096 buf_max=16777216
    if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 512 ]; then
        syn_backlog=1024
    fi
    if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 768 ]; then
        buf_max=4194304
    fi

    local -a sysctl_pairs=(
        "net.core.somaxconn=4096"
        "net.core.netdev_max_backlog=4096"
        "net.core.rmem_max=${buf_max}"
        "net.core.wmem_max=${buf_max}"
        "net.ipv4.tcp_rmem=4096 87380 ${buf_max}"
        "net.ipv4.tcp_wmem=4096 16384 ${buf_max}"
        "net.ipv4.tcp_max_syn_backlog=${syn_backlog}"
        "net.ipv4.ip_local_port_range=10000 65535"
        "net.ipv4.tcp_fastopen=3"
        "net.ipv4.tcp_mtu_probing=1"
        "net.ipv4.tcp_slow_start_after_idle=0"
        "net.ipv4.tcp_notsent_lowat=16384"
    )
    if [ "$HAS_ZRAM" -eq 0 ]; then
        sysctl_pairs+=("vm.swappiness=10")
    fi

    local item="" k="" v="" ppath="" changed=0
    for item in "${sysctl_pairs[@]}"; do
        k="${item%%=*}"
        v="${item#*=}"
        ppath="/proc/sys/${k//./\/}"
        if [ -e "$ppath" ] && [ -w "$ppath" ]; then
            if upsert_sysctl_kv "$SYSCTL_TARGET" "$k" "$v"; then
                changed=1
            fi
        else
            delete_sysctl_kv "$SYSCTL_TARGET" "$k" || true
        fi
    done

    configure_bbr_fq

    if [ "$HAS_SYSTEMD" -eq 1 ]; then
        systemctl restart systemd-sysctl >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
    else
        sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_TARGET" >/dev/null 2>&1 || true
    fi
    if [ "$changed" -eq 1 ]; then
        ok "sysctl 已写入并生效 (${SYSCTL_TARGET})"
    else
        ok "sysctl 已是最新 (${SYSCTL_TARGET})"
    fi
}

patch_logrotate_rsyslog() {
    local r_conf="${1:-/etc/logrotate.d/rsyslog}"
    [ -f "$r_conf" ] || return 1
    local tmp_r=""
    ensure_tmp_work
    tmp_r="$(mktemp "${TMP_WORK}/logr.XXXXXX")"

    awk '
        BEGIN { in_block=0; in_header=0; target_block=0 }
        function reset_b() { in_block=0; in_header=0; target_block=0; size_d=0; rot_d=0; comp_d=0 }
        function emit_m() {
            if (target_block) {
                if (!size_d) print "\tmaxsize 5M"
                if (!rot_d) print "\trotate 2"
                if (!comp_d) print "\tcompress"
            }
        }
        /^[[:space:]]*[^#{}]*\{[[:space:]]*$/ {
            if (in_header) {
                in_header=0
                in_block=1
                if ($0 ~ /\/var\/log\//) target_block=1
            } else {
                target_block=($0 ~ /\/var\/log\//)
                in_block=1
            }
            size_d=0; rot_d=0; comp_d=0
            print; next
        }
        !in_block && !in_header {
            line=$0; sub(/^[[:space:]]+/, "", line)
            if (line ~ /^#/ || line == "") { print; next }
            if (line ~ /\/var\/log\// && line !~ /\{/) { in_header=1; target_block=1; print; next }
        }
        in_header {
            if ($0 !~ /^[[:space:]]*#/ && $0 ~ /\/var\/log\//) target_block=1
            print; next
        }
        in_block {
            line=$0; sub(/^[[:space:]]+/, "", line)
            if (line ~ /^\}/) { emit_m(); print; reset_b(); next }
            if (!target_block) { print; next }
            test_line=line; sub(/^#[[:space:]]*/, "", test_line)
            if (test_line ~ /^(maxsize|size)[[:space:]]+/) { if (!size_d) { print "\tmaxsize 5M"; size_d=1 }; next }
            if (test_line ~ /^rotate[[:space:]]+/) { if (!rot_d) { print "\trotate 2"; rot_d=1 }; next }
            if (test_line ~ /^(compress|nocompress)([[:space:]]|$)/) { if (!comp_d) { print "\tcompress"; comp_d=1 }; next }
            print; next
        }
        { print }
        END { if (in_block) emit_m() }
    ' "$r_conf" > "$tmp_r"

    atomic_replace_if_changed "$tmp_r" "$r_conf" 0644
}

patch_sshd_config() {
    local ssh_conf="/etc/ssh/sshd_config"
    [ -f "$ssh_conf" ] || return 0
    ensure_tmp_work
    local ssh_bak="${TMP_WORK}/sshd_config.bak"
    cp -p "$ssh_conf" "$ssh_bak" 2>/dev/null || true
    local ssh_body=$'UseDNS no\nGSSAPIAuthentication no'
    if upsert_block_file "$ssh_conf" "# >>> sys-opt-ssh >>>" "# <<< sys-opt-ssh <<<" "$ssh_body" '^[[:space:]]*Include[[:space:]]+'; then
        [ -d /run/sshd ] || mkdir -p /run/sshd 2>/dev/null || true
        if command -v sshd >/dev/null 2>&1; then
            if sshd -t >/dev/null 2>&1; then
                if [ "$HAS_SYSTEMD" -eq 1 ]; then
                    systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
                fi
                ok "SSH 已写入 UseDNS no 并重载"
            else
                cp -p "$ssh_bak" "$ssh_conf" 2>/dev/null || true
                warn "sshd -t 校验未通过，已还原原 SSH 配置"
            fi
        else
            ok "SSH 已写入 UseDNS no"
        fi
    else
        ok "SSH 配置已就绪"
    fi
}

patch_module_blacklist() {
    if [ "$IS_CONTAINER" -eq 1 ]; then
        info "容器环境跳过内核黑名单"
        return 0
    fi
    mkdir -p /etc/modprobe.d
    local bl_conf="/etc/modprobe.d/blacklist-server.conf"
    if [ ! -f "$bl_conf" ] && [ -f /etc/modprobe.d/blacklist.conf ]; then
        bl_conf="/etc/modprobe.d/blacklist.conf"
    fi

    local bl_body
    bl_body=$'blacklist snd\nblacklist snd_pcm\nblacklist snd_timer\nblacklist soundcore\nblacklist pcspkr\nblacklist snd_pcsp\nblacklist snd_hda_intel\nblacklist bluetooth\nblacklist btusb\nblacklist uvcvideo\nblacklist firewire_ohci\nblacklist firewire_core\nblacklist rtsx_usb_ms\ninstall btusb /bin/true\ninstall uvcvideo /bin/true'
    if upsert_block_file "$bl_conf" "# >>> sys-opt-blacklist >>>" "# <<< sys-opt-blacklist <<<" "$bl_body"; then
        INITRAMFS_DIRTY=1
        ok "已更新无用驱动黑名单 (${bl_conf})"
    else
        ok "驱动黑名单已是最新"
    fi
}

step_system_optimize() {
    step_title "5/7" "写入系统原生调优与 BBR/FQ"

    apply_sysctl_optimizations

    if [ -f /etc/systemd/journald.conf ]; then
        if upsert_ini_section /etc/systemd/journald.conf "[Journal]" \
            "Compress=yes" "SystemMaxUse=32M" "SystemMaxFileSize=4M" "SystemMaxFiles=8" \
            "RuntimeMaxUse=8M" "RuntimeMaxFileSize=2M" "RuntimeMaxFiles=4" "MaxRetentionSec=7day"; then
            if [ "$HAS_SYSTEMD" -eq 1 ]; then
                systemctl restart systemd-journald >/dev/null 2>&1 || true
            fi
            ok "journald 已限容 (32M)"
        else
            ok "journald 配置已就绪"
        fi
        if compgen -G "/etc/systemd/journald.conf.d/*.conf" >/dev/null 2>&1; then
            warn "检测到 journald.conf.d 存在外部覆盖项"
        fi
    fi

    if [ -f /etc/systemd/system.conf ]; then
        if upsert_ini_section /etc/systemd/system.conf "[Manager]" "DefaultLimitNOFILE=1024:524288"; then
            if [ "$HAS_SYSTEMD" -eq 1 ]; then
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi
            ok "system.conf 已放开 DefaultLimitNOFILE"
        else
            ok "system.conf 限额已就绪"
        fi
    fi

    if [ -f /etc/security/limits.conf ]; then
        local lim_body
        lim_body=$'* soft nofile 524288\n* hard nofile 524288\nroot soft nofile 524288\nroot hard nofile 524288'
        if upsert_block_file /etc/security/limits.conf "# >>> sys-opt-limits >>>" "# <<< sys-opt-limits <<<" "$lim_body" '^[[:space:]]*#[[:space:]]*End of file'; then
            ok "limits.conf 已放开文件句柄上限"
        else
            ok "limits.conf 限额已就绪"
        fi
    fi

    patch_sshd_config

    if [ -f /etc/logrotate.d/rsyslog ]; then
        if patch_logrotate_rsyslog /etc/logrotate.d/rsyslog; then
            ok "rsyslog 轮转已收紧"
        else
            ok "rsyslog 轮转已就绪"
        fi
    fi

    patch_module_blacklist

    if [ "$INITRAMFS_DIRTY" -eq 1 ] && [ "$IS_CONTAINER" -eq 0 ] && command -v update-initramfs >/dev/null 2>&1; then
        run_logged "更新 initramfs" update-initramfs -u || true
    fi
}

step_deep_cleanup() {
    step_title "6/7" "收尾清理缓存、日志与包索引"

    sync
    run_logged "清理孤立依赖包" apt-get autoremove --purge -y -q || true
    apt-get clean -qq >/dev/null 2>&1 || true
    find /var/lib/apt/lists -maxdepth 1 -type f -delete 2>/dev/null || true
    ok "APT 缓存与列表索引已清理"

    find /etc /var -type f \( -name '*.dpkg-old' -o -name '*.dpkg-dist' -o -name '*.dpkg-new' -o -name '*.ucf-old' -o -name '*.ucf-dist' \) -delete 2>/dev/null || true
    rm -f /vmlinuz.old /initrd.img.old /boot/vmlinuz.old /boot/initrd.img.old 2>/dev/null || true
    find /var/crash /var/lib/systemd/coredump /var/tmp -type f -delete 2>/dev/null || true

    local self_path=""
    self_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
    if [ -n "$self_path" ] && [ -e "$self_path" ]; then
        find /tmp -mindepth 1 -maxdepth 2 -type f ! -samefile "$self_path" ! -path "${TMP_WORK:-/nonexistent}/*" -delete 2>/dev/null || true
    else
        find /tmp -mindepth 1 -maxdepth 2 -type f ! -path "${TMP_WORK:-/nonexistent}/*" -delete 2>/dev/null || true
    fi

    local d=""
    for d in /home/* /root; do
        [ -d "$d" ] || continue
        find "$d/.cache" "$d/.local/share/Trash" -type f -delete 2>/dev/null || true
        find "$d" -maxdepth 1 -type f \( -name ".bash_history" -o -name ".viminfo" -o -name ".wget-hsts" \) -delete 2>/dev/null || true
        rm -rf "${d}/.npm/_cacache" "${d}/.m2/repository" "${d}/.gradle/caches" 2>/dev/null || true
    done

    if [ "$HAS_SYSTEMD" -eq 1 ] && command -v journalctl >/dev/null 2>&1; then
        journalctl --rotate >/dev/null 2>&1 || true
        journalctl --vacuum-size=1M >/dev/null 2>&1 || true
    fi
    if [ -d /var/log ]; then
        find /var/log -type f \( -name '*.log.*' -o -name '*.gz' -o -name '*.[0-9]' \) -delete 2>/dev/null || true
        find /var/log -type f -name '*.log' -exec truncate -s 0 {} \; 2>/dev/null || true
    fi
    ok "系统日志与历史缓存已清理"

    if command -v docker >/dev/null 2>&1; then
        if docker system prune -a -f >/dev/null 2>&1; then
            ok "Docker 未使用镜像与缓存已清理"
        fi
    fi
    if command -v flatpak >/dev/null 2>&1; then
        if flatpak uninstall --unused -y >/dev/null 2>&1; then
            ok "Flatpak 冗余运行时已清理"
        fi
    fi

    sync
}

print_final_summary() {
    step_title "7/7" "终态核验"
    local cc_now="" qdisc_now="" disk_now=""
    cc_now="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    qdisc_now="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    disk_now="$(df -Ph / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')"

    echo -e "  ${C_DIM}系统:${C_RST} ${OS_PRETTY}"
    echo -e "  ${C_DIM}网络:${C_RST} ${cc_now} + ${qdisc_now}"
    format_dns_lines
    echo -e "  ${C_DIM}主机:${C_RST} $(hostname 2>/dev/null || echo unknown)"
    echo -e "  ${C_DIM}磁盘:${C_RST} ${disk_now}"
}

prompt_enter_reboot() {
    echo ""
    hr
    ok "全部优化已完成"
    echo -e "  ${C_BYLW}按回车立即重启，Ctrl+C 取消${C_RST}"
    hr
    flush_tty_input
    if ! read_input "" "  > "; then
        return 0
    fi
    cleanup_all
    info "正在重启系统..."
    sync
    systemctl reboot 2>/dev/null || reboot || /sbin/reboot || die "重启失败，请手动执行 reboot"
}

main() {
    init_colors
    trap cleanup_all EXIT INT TERM

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -y|--yes) AUTO_YES=1 ;;
        esac
        shift
    done

    if [ "$EUID" -ne 0 ]; then
        die "必须使用 root 权限运行"
    fi

    detect_system_info
    print_detection_summary

    if [ "$AUTO_YES" -eq 0 ]; then
        local confirm=""
        flush_tty_input
        read_input confirm "  ${C_BYLW}确认开始无人值守优化？[y/N]: ${C_RST}" || exit 0
        if [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            [ ! -t 0 ] && echo ""
            info "已取消。"
            exit 0
        fi
    fi

    step_dns_and_anti_dhcp
    step_apt_dpkg_slimming
    step_pkg_prune_and_upgrade
    step_service_prune
    step_system_optimize
    step_deep_cleanup
    print_final_summary
    prompt_enter_reboot
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
