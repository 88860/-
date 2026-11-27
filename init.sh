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
SWAP_MB=0
VIRT_TYPE=""
VIRT_LABEL="物理机/VM"
SYSCTL_TARGET=""
MODULES_TARGET=""
RUN_LOG=""
TMP_WORK=""
AUTO_YES=0
INITRAMFS_DIRTY=0

NETPLAN_ACTIVE=0
NM_ACTIVE=0
RDNSSD_ACTIVE=0
RESOLVCONF_ACTIVE=0

NET_MANAGERS=()
DNS_PUSH_SOURCES=()
HOST_PUSH_SOURCES=()
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

add_unique_item() {
    local arr_name="$1"
    local val="$2"
    local -n arr_ref="$arr_name"
    local item=""
    for item in "${arr_ref[@]}"; do
        [ "$item" = "$val" ] && return 0
    done
    arr_ref+=("$val")
}

has_array_item() {
    local arr_name="$1"
    local needle="$2"
    local -n ref_arr="$arr_name"
    local item=""
    for item in "${ref_arr[@]}"; do
        [ "$item" = "$needle" ] && return 0
    done
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

upsert_sysctl_min_kv() {
    local file="$1"
    local key="$2"
    local min_val="$3"
    local cur_live="" cur_cfg=""
    cur_live="$(sysctl -n "$key" 2>/dev/null || true)"
    if [ -f "$file" ]; then
        cur_cfg="$(awk -v tkey="$key" '
            {
                raw = $0; sub(/^[[:space:]]+/, "", raw)
                if (raw ~ /^[#;]/) next
                eq = index(raw, "=")
                if (eq > 0) {
                    k = substr(raw, 1, eq - 1); sub(/[[:space:]]+$/, "", k); gsub(/\//, ".", k)
                    if (k == tkey) {
                        v = substr(raw, eq + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                        val = v
                    }
                }
            }
            END { print val }
        ' "$file")"
    fi
    if [ -n "$cur_cfg" ]; then
        if [[ "$cur_cfg" =~ ^[0-9]+$ ]] && [ "$cur_cfg" -ge "$min_val" ]; then
            return 1
        fi
        upsert_sysctl_kv "$file" "$key" "$min_val"
        return $?
    fi
    if [[ "$cur_live" =~ ^[0-9]+$ ]] && [ "$cur_live" -ge "$min_val" ]; then
        return 1
    fi
    upsert_sysctl_kv "$file" "$key" "$min_val"
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

is_multipath_in_use() {
    findmnt -no SOURCE / 2>/dev/null | grep -qiE 'mpath|dm-.*multipath' && return 0
    compgen -G "/dev/mapper/mpath*" >/dev/null 2>&1 && return 0
    return 1
}

detect_sysctl_target() {
    if [ -L /etc/sysctl.d/99-sysctl.conf ] && [ -f /etc/sysctl.conf ]; then
        local major="${OS_VER_ID%%.*}"
        if [ "$OS_ID" = "debian" ] && [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -le 12 ]; then
            SYSCTL_TARGET="/etc/sysctl.conf"
            return 0
        elif [ "$OS_ID" = "ubuntu" ]; then
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

get_default_net_iface() {
    local dev=""
    dev="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [ -z "$dev" ]; then
        dev="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    fi
    printf '%s' "$dev"
}

get_live_nic_qdisc() {
    local dev="$1"
    [ -n "$dev" ] && command -v tc >/dev/null 2>&1 || return 0
    local line="" q=""
    line="$(tc qdisc show dev "$dev" 2>/dev/null | awk '/root/{print $2; exit}')"
    if [ "$line" = "mq" ]; then
        q="$(tc qdisc show dev "$dev" 2>/dev/null | awk '!/root/ && NR<=4 {print $2}' | sort -u | paste -sd ',' -)"
        if [ -n "$q" ]; then
            printf 'mq(%s)' "$q"
        else
            printf 'mq'
        fi
    elif [ -n "$line" ]; then
        printf '%s' "$line"
    fi
}

get_cloudinit_effective_bool() {
    local key="$1"
    local val="" f="" hit=""
    for f in /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d/*.cfg; do
        [ -f "$f" ] || continue
        hit="$(awk -v k="$key" '
            /^[[:space:]]*#/ { next }
            $0 ~ "^[[:space:]]*" k ":[[:space:]]*" {
                line = $0
                sub("^[[:space:]]*" k ":[[:space:]]*", "", line)
                sub(/[[:space:]]*#.*/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                res = tolower(line)
            }
            END { if (res != "") print res }
        ' "$f")"
        [ -n "$hit" ] && val="$hit"
    done
    printf '%s' "$val"
}

ifupdown_has_dhcp() {
    local -a files=()
    [ -f /etc/network/interfaces ] && files+=(/etc/network/interfaces)
    local f=""
    for f in /etc/network/interfaces.d/*; do
        [ -f "$f" ] && files+=("$f")
    done
    [ "${#files[@]}" -gt 0 ] || return 1
    grep -qE '^[[:space:]]*iface[[:space:]]+[^[:space:]]+[[:space:]]+inet6?[[:space:]]+dhcp([[:space:]]|$)' "${files[@]}" 2>/dev/null
}

check_netplan_push_flags() {
    local file="$1"
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        python3 - "$file" 2>/dev/null <<'PYEOF'
import sys, yaml
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
net = data.get('network', {}) if isinstance(data, dict) else {}
if not isinstance(net, dict):
    sys.exit(0)
push_dns = False
push_host = False
for sec in ('ethernets', 'wifis'):
    devs = net.get(sec)
    if not isinstance(devs, dict):
        continue
    for _, cfg in devs.items():
        if not isinstance(cfg, dict):
            continue
        for ver in ('4', '6'):
            if str(cfg.get(f'dhcp{ver}', '')).lower() in ('true', 'yes', '1'):
                ov = cfg.get(f'dhcp{ver}-overrides') or {}
                if ov.get('use-dns') is not False:
                    push_dns = True
                if ov.get('use-hostname') is not False:
                    push_host = True
        if str(cfg.get('accept-ra', '')).lower() in ('true', 'yes', '1'):
            ov6 = cfg.get('dhcp6-overrides') or {}
            if ov6.get('use-dns') is not False:
                push_dns = True
if push_dns:
    print('DNS')
if push_host:
    print('HOST')
PYEOF
        return 0
    fi
    if grep -qE '^[[:space:]]*dhcp[46]:[[:space:]]*(true|yes)' "$file" 2>/dev/null; then
        grep -qE '^[[:space:]]*use-dns:[[:space:]]*(false|no)' "$file" 2>/dev/null || echo "DNS"
        grep -qE '^[[:space:]]*use-hostname:[[:space:]]*(false|no)' "$file" 2>/dev/null || echo "HOST"
    fi
}

detect_network_and_push_status() {
    NETPLAN_ACTIVE=0
    NM_ACTIVE=0
    RDNSSD_ACTIVE=0
    RESOLVCONF_ACTIVE=0

    NET_MANAGERS=()
    DNS_PUSH_SOURCES=()
    HOST_PUSH_SOURCES=()

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

    local has_ifup_dhcp=0
    if ifupdown_has_dhcp; then
        has_ifup_dhcp=1
    fi

    if pgrep -x dhcpcd >/dev/null 2>&1 || \
       { [ "$HAS_SYSTEMD" -eq 1 ] && systemctl list-units --state=active --no-legend 'dhcpcd*' 2>/dev/null | grep -q .; } || \
       { [ "$has_ifup_dhcp" -eq 1 ] && is_pkg_installed dhcpcd-base && ! is_pkg_installed isc-dhcp-client; }; then
        add_unique_item NET_MANAGERS "dhcpcd"
        if [ -f /etc/dhcpcd.conf ]; then
            if ! grep -qE '^[[:space:]]*nohook[[:space:]].*resolv\.conf' /etc/dhcpcd.conf 2>/dev/null; then
                add_unique_item DNS_PUSH_SOURCES "dhcpcd"
            fi
            if ! grep -qE '^[[:space:]]*nohook[[:space:]].*hostname' /etc/dhcpcd.conf 2>/dev/null; then
                add_unique_item HOST_PUSH_SOURCES "dhcpcd"
            fi
        fi
    fi

    if pgrep -x dhclient >/dev/null 2>&1 || \
       { [ "$has_ifup_dhcp" -eq 1 ] && is_pkg_installed isc-dhcp-client; }; then
        add_unique_item NET_MANAGERS "dhclient"
        if [ -f /etc/dhcp/dhclient.conf ]; then
            local clean_dhc=""
            clean_dhc="$(sed 's/#.*$//' /etc/dhcp/dhclient.conf 2>/dev/null | tr '\n' ' ')"
            if grep -qE '\brequest\b[^;]*(domain-name-servers|domain-name|domain-search|dhcp6\.name-servers)' <<< "$clean_dhc" && \
               ! grep -qE '\bsupersede[[:space:]]+domain-name-servers\b' <<< "$clean_dhc"; then
                add_unique_item DNS_PUSH_SOURCES "dhclient"
            fi
            if grep -qE '\brequest\b[^;]*host-name' <<< "$clean_dhc"; then
                add_unique_item HOST_PUSH_SOURCES "dhclient"
            fi
        fi
        if [ -f /etc/dhcp/dhclient.d/google_hostname.sh ]; then
            add_unique_item HOST_PUSH_SOURCES "gcp-dhcp"
        fi
    fi

    if compgen -G "/etc/netplan/*.yaml" >/dev/null 2>&1; then
        NETPLAN_ACTIVE=1
        add_unique_item NET_MANAGERS "netplan"
        local yf="" flags=""
        for yf in /etc/netplan/*.yaml; do
            [ -f "$yf" ] || continue
            flags="$(check_netplan_push_flags "$yf")"
            grep -qx 'DNS' <<< "$flags" && add_unique_item DNS_PUSH_SOURCES "netplan"
            grep -qx 'HOST' <<< "$flags" && add_unique_item HOST_PUSH_SOURCES "netplan"
        done
    fi

    if [ "$HAS_SYSTEMD" -eq 1 ] && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        add_unique_item NET_MANAGERS "networkd"
        local nf=""
        for nf in /etc/systemd/network/*.network /run/systemd/network/*.network; do
            [ -f "$nf" ] || continue
            if grep -qiE '^[[:space:]]*DHCP[[:space:]]*=[[:space:]]*(yes|true|1|ipv4|ipv6|both)' "$nf" 2>/dev/null || \
               grep -qiE '^[[:space:]]*IPv6AcceptRA[[:space:]]*=[[:space:]]*(yes|true|1)' "$nf" 2>/dev/null; then
                grep -qiE '^[[:space:]]*UseDNS[[:space:]]*=[[:space:]]*(no|false|0)' "$nf" 2>/dev/null || add_unique_item DNS_PUSH_SOURCES "networkd"
                if grep -qiE '^[[:space:]]*DHCP[[:space:]]*=[[:space:]]*(yes|true|1|ipv4|ipv6|both)' "$nf" 2>/dev/null; then
                    grep -qiE '^[[:space:]]*UseHostname[[:space:]]*=[[:space:]]*(no|false|0)' "$nf" 2>/dev/null || add_unique_item HOST_PUSH_SOURCES "networkd"
                fi
            fi
        done
    fi

    if [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf 2>/dev/null | grep -q 'systemd/resolve'; then
        add_unique_item NET_MANAGERS "resolved"
        add_unique_item DNS_PUSH_SOURCES "systemd-resolved"
    elif [ "$HAS_SYSTEMD" -eq 1 ] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        add_unique_item NET_MANAGERS "resolved"
        if grep -qE '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.53([[:space:]]|$)' /etc/resolv.conf 2>/dev/null || [ ! -s /etc/resolv.conf ]; then
            add_unique_item DNS_PUSH_SOURCES "systemd-resolved"
        fi
    fi

    if pgrep -x rdnssd >/dev/null 2>&1 || { [ "$HAS_SYSTEMD" -eq 1 ] && systemctl is-active --quiet rdnssd 2>/dev/null; }; then
        RDNSSD_ACTIVE=1
        add_unique_item DNS_PUSH_SOURCES "rdnssd-RA"
    fi

    if [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf 2>/dev/null | grep -q 'resolvconf'; then
        RESOLVCONF_ACTIVE=1
        add_unique_item DNS_PUSH_SOURCES "resolvconf"
    fi

    if [ -f /etc/NetworkManager/NetworkManager.conf ] && [ "$HAS_SYSTEMD" -eq 1 ] && \
       systemctl is-active --quiet NetworkManager 2>/dev/null; then
        NM_ACTIVE=1
        add_unique_item NET_MANAGERS "NetworkManager"
        if ! grep -qE '^[[:space:]]*dns[[:space:]]*=[[:space:]]*none' /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            add_unique_item DNS_PUSH_SOURCES "NetworkManager"
        fi
    fi

    if command -v cloud-init >/dev/null 2>&1 && [ -f /etc/cloud/cloud.cfg ] && [ ! -f /etc/cloud/cloud-init.disabled ] && \
       { [ "$HAS_SYSTEMD" -eq 0 ] || systemctl is-enabled cloud-init.service >/dev/null 2>&1 || systemctl is-enabled cloud-init-local.service >/dev/null 2>&1; }; then
        add_unique_item NET_MANAGERS "cloud-init"
        local ci_pres="" ci_dns=""
        ci_pres="$(get_cloudinit_effective_bool "preserve_hostname")"
        if [ "$ci_pres" != "true" ]; then
            add_unique_item HOST_PUSH_SOURCES "cloud-init"
        fi
        ci_dns="$(get_cloudinit_effective_bool "manage_resolv_conf")"
        if [ "$ci_dns" = "true" ]; then
            add_unique_item DNS_PUSH_SOURCES "cloud-init"
        fi
    fi

    if [ -f /etc/waagent.conf ] && grep -qE '^[[:space:]]*Provisioning\.MonitorHostName[[:space:]]*=[[:space:]]*y' /etc/waagent.conf 2>/dev/null && \
       { [ "$HAS_SYSTEMD" -eq 0 ] || systemctl is-active --quiet walinuxagent 2>/dev/null || systemctl is-enabled walinuxagent >/dev/null 2>&1; }; then
        add_unique_item HOST_PUSH_SOURCES "waagent"
    fi

    if [ -s /etc/resolv.conf ] && grep -qE '^[[:space:]]*nameserver[[:space:]]+[^[:space:]]+' /etc/resolv.conf 2>/dev/null; then
        if grep -qiE 'Generated by (dhcpcd|resolvconf|NetworkManager|systemd-resolved|cloud-init)' /etc/resolv.conf 2>/dev/null; then
            add_unique_item DNS_PUSH_SOURCES "resolv.conf标记"
        elif grep -qE '^[[:space:]]*nameserver[[:space:]]+(127\.0\.0\.53|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.|183\.60\.83\.19)([[:space:]]|$)' /etc/resolv.conf 2>/dev/null; then
            add_unique_item DNS_PUSH_SOURCES "内网/云DNS"
        fi
    else
        add_unique_item DNS_PUSH_SOURCES "缺失"
    fi

    if [ "${#NET_MANAGERS[@]}" -eq 0 ]; then
        NET_MANAGERS=("static/ifupdown")
    fi
}

probe_bbr_capability_summary() {
    local kver avail_cc cur_cc
    kver="$(uname -r)"
    if [ ! -w /proc/sys/net/ipv4/tcp_congestion_control ] || [ ! -w /proc/sys/net/core/default_qdisc ]; then
        printf '%s' "容器只读/不可写"
        return 0
    fi
    cur_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    avail_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if [[ "$cur_cc" == bbr* ]]; then
        printf '%s' "已实时开启 (${cur_cc})"
    elif grep -qwE 'bbr3?' <<< "$avail_cc"; then
        if is_builtin_mod tcp_bbr; then
            printf '%s' "已内置 (未开启)"
        else
            printf '%s' "模块已加载 (未开启)"
        fi
    elif is_loadable_mod tcp_bbr; then
        printf '%s' "已编译为模块 (待开启)"
    else
        printf '%s' "未编译 (${kver})"
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
        elif { [ -z "$virt" ] || [ "$virt" = "none" ]; } && grep -qi 'microsoft' /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null; then
            virt="microsoft"
        fi
    fi
    VIRT_TYPE="$virt"
    if [ "$IS_CONTAINER" -eq 1 ]; then
        VIRT_LABEL="容器 (${virt:-container})"
    elif [ -n "$virt" ] && [ "$virt" != "none" ]; then
        VIRT_LABEL="虚机 (${virt})"
    else
        VIRT_LABEL="物理机"
    fi

    MEM_MB="$(awk '/^MemTotal:/ {printf "%d", int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    SWAP_MB="$(awk '/^SwapTotal:/ {printf "%d", int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
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
    local disk_info bbr_stat host_now mem_note="" dns_push_str="" host_push_str=""
    disk_info="$(df -Ph / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')"
    host_now="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
    bbr_stat="$(probe_bbr_capability_summary)"
    if [ "${#DNS_PUSH_SOURCES[@]}" -gt 0 ]; then
        dns_push_str="${C_BYLW}有 (${DNS_PUSH_SOURCES[*]})${C_RST}"
    else
        dns_push_str="${C_GRN}静态受控${C_RST}"
    fi
    if [ "${#HOST_PUSH_SOURCES[@]}" -gt 0 ]; then
        host_push_str="${C_BYLW}有 (${HOST_PUSH_SOURCES[*]})${C_RST}"
    else
        host_push_str="${C_GRN}静态受控${C_RST}"
    fi
    if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 1024 ] && [ "$SWAP_MB" -eq 0 ] && [ "$IS_CONTAINER" -eq 0 ]; then
        mem_note=" ${C_BYLW}(无Swap)${C_RST}"
    elif [ "$SWAP_MB" -gt 0 ]; then
        mem_note=" · Swap ${SWAP_MB} MB"
    fi

    echo ""
    hr
    echo -e "  ${C_BCYN}Debian / Ubuntu 新机优化${C_RST}"
    hr
    echo -e "  ${C_DIM}系统:${C_RST} ${C_BWHT}${OS_PRETTY}${C_RST}"
    echo -e "  ${C_DIM}内核:${C_RST} $(uname -r)"
    echo -e "  ${C_DIM}主机:${C_RST} ${host_now} · ${VIRT_LABEL}"
    echo -e "  ${C_DIM}内存:${C_RST} ${MEM_MB} MB${mem_note}"
    echo -e "  ${C_DIM}磁盘:${C_RST} ${disk_info}"
    echo -e "  ${C_DIM}网管:${C_RST} ${NET_MANAGERS[*]}"
    format_dns_lines
    echo -e "  ${C_DIM}DNS下发:${C_RST} ${dns_push_str}"
    echo -e "  ${C_DIM}主机下发:${C_RST} ${host_push_str}"
    echo -e "  ${C_DIM}BBR :${C_RST} ${bbr_stat}"
    echo -e "  ${C_DIM}参数:${C_RST} ${SYSCTL_TARGET}"
    hr
}

patch_dhcpcd_conf() {
    local file="${1:-/etc/dhcpcd.conf}"
    local mode="${2:-both}"
    [ -f "$file" ] || return 1
    local do_dns=0 do_host=0
    { [ "$mode" = "both" ] || [ "$mode" = "dns" ]; } && do_dns=1
    { [ "$mode" = "both" ] || [ "$mode" = "host" ]; } && do_host=1
    [ "$do_dns" -eq 1 ] || [ "$do_host" -eq 1 ] || return 1
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/dhcpcd.XXXXXX")"

    awk -v do_dns="$do_dns" -v do_host="$do_host" '
        {
            raw = $0
            if (raw ~ /^[[:space:]]*nohook[[:space:]]+/) {
                line = raw
                sub(/^[[:space:]]*nohook[[:space:]]+/, "", line)
                n = split(line, toks, /,[[:space:]]*|[[:space:]]+/)
                kept = ""
                for (i = 1; i <= n; i++) {
                    if (toks[i] == "") continue
                    if (do_dns == 1 && toks[i] == "resolv.conf") continue
                    if (do_host == 1 && toks[i] == "hostname") continue
                    kept = (kept == "" ? toks[i] : kept ", " toks[i])
                }
                if (kept != "") print "nohook " kept
                next
            }
            print raw
        }
        END {
            if (do_dns == 1) print "nohook resolv.conf"
            if (do_host == 1) print "nohook hostname"
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

patch_dhclient_conf() {
    local file="${1:-/etc/dhcp/dhclient.conf}"
    local mode="${2:-both}"
    [ -f "$file" ] || return 1
    local do_dns=0 do_host=0
    { [ "$mode" = "both" ] || [ "$mode" = "dns" ]; } && do_dns=1
    { [ "$mode" = "both" ] || [ "$mode" = "host" ]; } && do_host=1
    [ "$do_dns" -eq 1 ] || [ "$do_host" -eq 1 ] || return 1
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/dhc.XXXXXX")"

    awk -v do_dns="$do_dns" -v do_host="$do_host" '
        BEGIN { in_req = 0; req_buf = ""; indent = "" }
        function flush_req(    s, n, arr, i, tok, out) {
            s = req_buf
            sub(/^[[:space:]]*request[[:space:]]*/, "", s)
            sub(/;[[:space:]]*$/, "", s)
            n = split(s, arr, /[[:space:]]*,[[:space:]]*/)
            out = ""
            for (i = 1; i <= n; i++) {
                tok = arr[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", tok)
                if (tok == "") continue
                if (do_dns == 1 && (tok == "domain-name-servers" || tok == "domain-name" || \
                    tok == "domain-search" || tok == "dhcp6.name-servers" || tok == "dhcp6.domain-search")) continue
                if (do_host == 1 && tok == "host-name") continue
                out = (out == "" ? tok : out ", " tok)
            }
            if (out != "") print indent "request " out ";"
            in_req = 0
            req_buf = ""
            indent = ""
        }
        {
            line = $0
            if (in_req) {
                sub(/[[:space:]]*#.*/, "", line)
                req_buf = req_buf " " line
                if (req_buf ~ /;[[:space:]]*$/) flush_req()
                next
            }
            if (line ~ /^[[:space:]]*request([[:space:]]|$)/) {
                match(line, /^[[:space:]]*/)
                indent = substr(line, RSTART, RLENGTH)
                sub(/[[:space:]]*#.*/, "", line)
                in_req = 1
                req_buf = line
                if (req_buf ~ /;[[:space:]]*$/) flush_req()
                next
            }
            print $0
        }
        END {
            if (in_req) flush_req()
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
}

patch_netplan_yaml() {
    local file="$1"
    local mode="${2:-both}"
    [ -f "$file" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c 'import yaml' >/dev/null 2>&1 || return 1

    local dns_csv=""
    dns_csv="$(IFS=,; printf '%s' "${DNS_ORDER[*]}")"

    python3 - "$file" "$dns_csv" "$mode" <<'PYEOF'
import sys, yaml

path, dns_csv, mode = sys.argv[1], sys.argv[2], sys.argv[3]
dns_addrs = [x for x in dns_csv.split(',') if x]
do_dns = mode in ('both', 'full', 'dns_only')
do_host = mode in ('both', 'full', 'host_only')

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
    for _, cfg in devs.items():
        if not isinstance(cfg, dict):
            continue
        has4 = str(cfg.get('dhcp4', '')).lower() in ('true', 'yes', '1')
        has6 = str(cfg.get('dhcp6', '')).lower() in ('true', 'yes', '1')
        has_ra = str(cfg.get('accept-ra', '')).lower() in ('true', 'yes', '1')
        if not (has4 or has6 or has_ra):
            continue
        if has4:
            ov = cfg.setdefault('dhcp4-overrides', {})
            if do_dns and ov.get('use-dns') is not False:
                ov['use-dns'] = False
                changed = True
            if do_host and ov.get('use-hostname') is not False:
                ov['use-hostname'] = False
                changed = True
        if has6 or has_ra:
            ov6 = cfg.setdefault('dhcp6-overrides', {})
            if do_dns and ov6.get('use-dns') is not False:
                ov6['use-dns'] = False
                changed = True
            if has6 and do_host and ov6.get('use-hostname') is not False:
                ov6['use-hostname'] = False
                changed = True
        if do_dns:
            ns = cfg.setdefault('nameservers', {})
            if ns.get('addresses') != dns_addrs:
                ns['addresses'] = dns_addrs
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
    local mode="${2:-both}"
    [ -f "$file" ] || return 1
    local -a kv4=() kv6=()
    if [ "$mode" = "both" ] || [ "$mode" = "dns" ]; then
        kv4+=("UseDNS=no")
        kv6+=("UseDNS=no")
    fi
    if [ "$mode" = "both" ] || [ "$mode" = "host" ]; then
        kv4+=("UseHostname=no")
        kv6+=("UseHostname=no")
    fi
    local changed=1
    if [ "${#kv4[@]}" -gt 0 ] && grep -qiE '^[[:space:]]*DHCP[[:space:]]*=[[:space:]]*(yes|true|1|ipv4|both)' "$file" 2>/dev/null; then
        upsert_ini_section "$file" "[DHCPv4]" "${kv4[@]}" && changed=0
    fi
    if [ "${#kv6[@]}" -gt 0 ] && grep -qiE '^[[:space:]]*DHCP[[:space:]]*=[[:space:]]*(yes|true|1|ipv6|both)' "$file" 2>/dev/null; then
        upsert_ini_section "$file" "[DHCPv6]" "${kv6[@]}" && changed=0
    fi
    if { [ "$mode" = "both" ] || [ "$mode" = "dns" ]; } && \
       { grep -qiE '^[[:space:]]*IPv6AcceptRA[[:space:]]*=[[:space:]]*(yes|true|1)' "$file" 2>/dev/null || \
         grep -qE '^\[IPv6AcceptRA\]' "$file" 2>/dev/null; }; then
        upsert_ini_section "$file" "[IPv6AcceptRA]" "UseDNS=no" && changed=0
    fi
    return $changed
}

patch_cloud_cfg() {
    local file="${1:-/etc/cloud/cloud.cfg}"
    local mode="${2:-both}"
    [ -f "$file" ] || return 1
    local do_dns=0 do_host=0
    { [ "$mode" = "both" ] || [ "$mode" = "dns" ]; } && do_dns=1
    { [ "$mode" = "both" ] || [ "$mode" = "host" ]; } && do_host=1
    [ "$do_dns" -eq 1 ] || [ "$do_host" -eq 1 ] || return 1
    local tmp_f=""
    ensure_tmp_work
    tmp_f="$(mktemp "${TMP_WORK}/cloud.XXXXXX")"

    awk -v do_dns="$do_dns" -v do_host="$do_host" '
        BEGIN { seen_p = 0 }
        /^[[:space:]]*preserve_hostname:[[:space:]]*/ {
            if (do_host == 1) {
                if (!seen_p) {
                    print "preserve_hostname: true"
                    seen_p = 1
                }
                next
            }
        }
        /^[[:space:]]*manage_resolv_conf:[[:space:]]*/ {
            if (do_dns == 1) {
                print "manage_resolv_conf: false"
                next
            }
        }
        { print }
        END {
            if (do_host == 1 && !seen_p) print "preserve_hostname: true"
        }
    ' "$file" > "$tmp_f"

    atomic_replace_if_changed "$tmp_f" "$file" 0644
    local main_rc=$?

    local cf="" drop_rc=1
    for cf in /etc/cloud/cloud.cfg.d/*.cfg; do
        [ -f "$cf" ] || continue
        if { [ "$do_host" -eq 1 ] && grep -qE '^[[:space:]]*preserve_hostname:' "$cf" 2>/dev/null; } || \
           { [ "$do_dns" -eq 1 ] && grep -qE '^[[:space:]]*manage_resolv_conf:' "$cf" 2>/dev/null; }; then
            tmp_f="$(mktemp "${TMP_WORK}/cloudd.XXXXXX")"
            awk -v do_dns="$do_dns" -v do_host="$do_host" '
                /^[[:space:]]*preserve_hostname:[[:space:]]*/ {
                    if (do_host == 1) { print "preserve_hostname: true"; next }
                }
                /^[[:space:]]*manage_resolv_conf:[[:space:]]*/ {
                    if (do_dns == 1) { print "manage_resolv_conf: false"; next }
                }
                { print }
            ' "$cf" > "$tmp_f"
            if atomic_replace_if_changed "$tmp_f" "$cf" 0644; then
                drop_rc=0
            fi
        fi
    done

    [ "$main_rc" -eq 0 ] || [ "$drop_rc" -eq 0 ]
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

wait_default_route_ready() {
    [ "$IS_CONTAINER" -eq 1 ] && return 0
    local i=0
    while [ "$i" -lt 6 ]; do
        if ip -4 route show default 2>/dev/null | grep -q . || ip -6 route show default 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
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

resolve_push_mode() {
    local src="$1"
    local d=0 h=0
    has_array_item DNS_PUSH_SOURCES "$src" && d=1
    has_array_item HOST_PUSH_SOURCES "$src" && h=1
    if [ "$d" -eq 1 ] && [ "$h" -eq 1 ]; then
        printf 'both'
    elif [ "$d" -eq 1 ]; then
        printf 'dns'
    elif [ "$h" -eq 1 ]; then
        printf 'host'
    fi
}

step_dns_and_anti_dhcp() {
    step_title "1/7" "检测并锁定 DNS 与主机名"

    local has_dns_push=0 has_host_push=0
    [ "${#DNS_PUSH_SOURCES[@]}" -gt 0 ] && has_dns_push=1
    [ "${#HOST_PUSH_SOURCES[@]}" -gt 0 ] && has_host_push=1

    ensure_hosts_entry

    if [ "$has_dns_push" -eq 0 ] && [ "$has_host_push" -eq 0 ]; then
        ok "未检测到 DNS 或主机名下发，保持现有静态配置不变"
        return 0
    fi

    local m=""
    m="$(resolve_push_mode "dhcpcd")"
    if [ -n "$m" ] && [ -f /etc/dhcpcd.conf ]; then
        if patch_dhcpcd_conf /etc/dhcpcd.conf "$m"; then
            ok "dhcpcd 已阻止下发 (${m})"
        fi
    fi

    m="$(resolve_push_mode "dhclient")"
    if [ -n "$m" ] && [ -f /etc/dhcp/dhclient.conf ]; then
        if patch_dhclient_conf /etc/dhcp/dhclient.conf "$m"; then
            ok "dhclient 已移除动态请求 (${m})"
        fi
    fi

    m="$(resolve_push_mode "netplan")"
    if [ -n "$m" ] && [ "$NETPLAN_ACTIVE" -eq 1 ]; then
        local np_mode="both"
        [ "$m" = "dns" ] && np_mode="dns_only"
        [ "$m" = "host" ] && np_mode="host_only"
        local yf="" yname="" netplan_changed=0
        for yf in /etc/netplan/*.yaml; do
            [ -f "$yf" ] || continue
            yname="$(basename "$yf")"
            if patch_netplan_yaml "$yf" "$np_mode"; then
                netplan_changed=1
                ok "Netplan 已锁定策略 (${yname})"
            fi
        done
        if [ "$netplan_changed" -eq 1 ] && [ "$IS_CONTAINER" -eq 0 ] && command -v netplan >/dev/null 2>&1; then
            netplan generate >/dev/null 2>&1 || true
            netplan apply >/dev/null 2>&1 || true
            wait_default_route_ready || true
        fi
    fi

    m="$(resolve_push_mode "networkd")"
    if [ -n "$m" ] && compgen -G "/etc/systemd/network/*.network" >/dev/null 2>&1; then
        local nf="" nname="" networkd_changed=0
        for nf in /etc/systemd/network/*.network; do
            [ -f "$nf" ] || continue
            nname="$(basename "$nf")"
            if patch_systemd_network_file "$nf" "$m"; then
                ok "networkd 已阻止下发 (${nname})"
                networkd_changed=1
            fi
        done
        if [ "$networkd_changed" -eq 1 ] && [ "$HAS_SYSTEMD" -eq 1 ]; then
            systemctl reload systemd-networkd >/dev/null 2>&1 || true
            wait_default_route_ready || true
        fi
    fi

    m="$(resolve_push_mode "cloud-init")"
    if [ -n "$m" ] && [ -f /etc/cloud/cloud.cfg ]; then
        if patch_cloud_cfg /etc/cloud/cloud.cfg "$m"; then
            ok "cloud-init 已锁定主机名与解析策略"
        fi
    fi

    if has_array_item HOST_PUSH_SOURCES "waagent" && [ -f /etc/waagent.conf ]; then
        sed -i -E 's/^[[:space:]]*Provisioning\.MonitorHostName[[:space:]]*=.*/Provisioning.MonitorHostName=n/' /etc/waagent.conf
        ok "waagent 已关闭主机名覆写"
    fi

    if [ "$has_dns_push" -eq 1 ]; then
        if [ "$RDNSSD_ACTIVE" -eq 1 ] && [ "$HAS_SYSTEMD" -eq 1 ]; then
            systemctl disable --now rdnssd >/dev/null 2>&1 || true
            ok "已停用 rdnssd (IPv6 RA DNS)"
        fi

        if [ "$RESOLVCONF_ACTIVE" -eq 1 ] && command -v resolvconf >/dev/null 2>&1; then
            resolvconf --disable-updates >/dev/null 2>&1 || true
            ok "已停止 resolvconf 自动覆盖"
        fi

        if [ "$NM_ACTIVE" -eq 1 ] && [ -f /etc/NetworkManager/NetworkManager.conf ]; then
            if upsert_ini_section /etc/NetworkManager/NetworkManager.conf "[main]" "dns=none"; then
                systemctl reload NetworkManager >/dev/null 2>&1 || true
                ok "NetworkManager 已禁用写 resolv.conf"
            fi
        fi

        if has_array_item DNS_PUSH_SOURCES "systemd-resolved"; then
            if [ -f /etc/systemd/resolved.conf ]; then
                local r_dns=""
                r_dns="${DNS_ORDER[*]}"
                upsert_ini_section /etc/systemd/resolved.conf "[Resolve]" "DNS=${r_dns}" "FallbackDNS=" "MulticastDNS=no" >/dev/null 2>&1 || true
            fi
            if [ "$HAS_SYSTEMD" -eq 1 ] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
                systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
                ok "已停用 systemd-resolved stub"
            fi
        fi

        if write_static_resolv_conf; then
            if test_dns_resolution; then
                ok "静态 DNS 已写入并验证可用 (${DNS_ORDER[*]})"
            else
                warn "静态 DNS 已写入，当前暂未通过在线解析验证"
            fi
        else
            ok "静态 DNS 文件已处于目标状态"
        fi
    else
        ok "未检测到 DNS 下发，保持现有 /etc/resolv.conf 不变"
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

pin_critical_packages() {
    local -a critical_pkgs=(
        openssh-server openssh-client netplan.io netplan-generator networkd-dispatcher ifupdown ifupdown2
        dhcpcd-base dhcpcd5 isc-dhcp-client isc-dhcp-common
        systemd-resolved resolvconf openresolv
        iproute2 iputils-ping netbase nftables iptables ethtool
        ca-certificates curl wget gnupg sudo udev systemd kmod
        initramfs-tools cloud-init python3-yaml linux-base linux-sysctl-defaults
        efibootmgr open-iscsi amazon-ec2-net-utils google-guest-agent walinuxagent
    )
    if [ "$VIRT_TYPE" = "microsoft" ]; then
        critical_pkgs+=(hyperv-daemons)
    fi
    if [ "$NM_ACTIVE" -eq 1 ]; then
        critical_pkgs+=(network-manager)
    fi
    local -a to_pin=()
    local p=""
    for p in "${critical_pkgs[@]}"; do
        if is_pkg_installed "$p"; then
            to_pin+=("$p")
        fi
    done
    while IFS= read -r p; do
        [ -n "$p" ] && to_pin+=("$p")
    done < <(dpkg-query -W -f='${Status}\t${Package}\n' 'grub*' 'shim*' 'linux-firmware*' 'libnetplan*' 2>/dev/null | awk -F'\t' '$1=="install ok installed"{print $2}' || true)

    if [ "${#to_pin[@]}" -gt 0 ]; then
        apt-mark manual "${to_pin[@]}" >/dev/null 2>&1 || true
    fi
}

filter_safe_purge_pkgs() {
    local out_arr_name="$1"
    shift
    local -a raw_pkgs=("$@")
    local -n out_ref="$out_arr_name"
    out_ref=()

    local extra_prot=""
    [ "$VIRT_TYPE" = "microsoft" ] && extra_prot="${extra_prot}|hyperv-daemons"
    [ "$NM_ACTIVE" -eq 1 ] && extra_prot="${extra_prot}|network-manager"
    local protected_rx="^(openssh-server|openssh-client|netplan\\.io|netplan-generator|networkd-dispatcher|libnetplan.*|ifupdown|ifupdown2|dhcpcd-base|dhcpcd5|isc-dhcp-client|isc-dhcp-common|systemd-resolved|iproute2|iputils-ping|netbase|systemd|udev|kmod|sudo|ca-certificates|initramfs-tools|cloud-init|python3-yaml|open-iscsi|grub.*|shim.*|efibootmgr|amazon-ec2-net-utils|google-guest-agent|walinuxagent|linux-image-.*|linux-headers-.*|linux-modules-.*${extra_prot})\$"
    local p="" sim_out=""
    for p in "${raw_pkgs[@]}"; do
        [ -z "$p" ] && continue
        is_pkg_installed "$p" || continue
        if ! sim_out="$(apt-get purge -s --no-install-recommends "$p" 2>&1)"; then
            warn "跳过卸载 ${p} (模拟依赖校验未通过)"
            continue
        fi
        if grep -qE '^Inst ' <<< "$sim_out"; then
            warn "跳过卸载 ${p} (会触发安装替代新包)"
            continue
        fi
        if grep -E '^(Purg|Remv) ' <<< "$sim_out" | awk '{print $2}' | grep -qE "$protected_rx"; then
            warn "跳过卸载 ${p} (会连带移除关键网络/系统组件)"
            continue
        fi
        out_ref+=("$p")
    done
}

strip_cron_pattern() {
    local pat="$1"
    local f="" tmp_f=""
    ensure_tmp_work
    for f in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/* /etc/rc.local; do
        [ -f "$f" ] || continue
        if grep -qE "$pat" "$f" 2>/dev/null; then
            tmp_f="$(mktemp "${TMP_WORK}/cron.XXXXXX")"
            grep -vE "$pat" "$f" > "$tmp_f" || true
            atomic_replace_if_changed "$tmp_f" "$f" 0600 || true
        fi
    done
}

step_provider_agent_prune() {
    local found=0

    if [ -f /etc/init.d/aegis ] || compgen -G "/usr/local/aegis*" >/dev/null 2>&1 || [ -d /usr/local/cloudmonitor ] || \
       [ -d /usr/local/share/aliyun-assist ] || [ -d /usr/local/share/assist-daemon ] || \
       is_pkg_installed aliyun-assist || is_pkg_installed aliyun_assist || is_pkg_installed ecs-assist; then
        found=1
        if [ -x /usr/local/share/assist-daemon/assist_daemon ]; then
            /usr/local/share/assist-daemon/assist_daemon --stop >/dev/null 2>&1 || true
        fi
        if [ -x /usr/local/cloudmonitor/cloudmonitorCtl.sh ]; then
            /usr/local/cloudmonitor/cloudmonitorCtl.sh stop >/dev/null 2>&1 || true
            /usr/local/cloudmonitor/cloudmonitorCtl.sh remove >/dev/null 2>&1 || true
        elif [ -x /usr/local/cloudmonitor/wrapper/bin/cloudmonitor.sh ]; then
            /usr/local/cloudmonitor/wrapper/bin/cloudmonitor.sh stop >/dev/null 2>&1 || true
            /usr/local/cloudmonitor/wrapper/bin/cloudmonitor.sh remove >/dev/null 2>&1 || true
        fi
        if [ "$HAS_SYSTEMD" -eq 1 ]; then
            systemctl disable --now aliyun.service assist-daemon.service CmsGoAgent.service aegis.service cloudmonitor.service argusagent.service >/dev/null 2>&1 || true
        fi
        if [ -x /etc/init.d/aegis ]; then
            /etc/init.d/aegis stop >/dev/null 2>&1 || true
            /etc/init.d/aegis uninstall >/dev/null 2>&1 || true
        fi
        pkill -9 -f 'AliYunDun|AliHids|aegis_quartz|aliyun-service|assist_daemon|CmsGoAgent|cloudmonitor|argusagent' >/dev/null 2>&1 || true
        rm -rf /usr/local/aegis* /usr/local/cloudmonitor /usr/local/share/aliyun-assist /usr/local/share/assist-daemon \
               /usr/sbin/aliyun_installer /usr/sbin/aliyun-service \
               /etc/systemd/system/aliyun.service /etc/systemd/system/assist-daemon.service \
               /etc/systemd/system/CmsGoAgent.service /etc/systemd/system/cloudmonitor.service /etc/systemd/system/argusagent.service \
               /etc/init.d/aegis /var/log/aegis* 2>/dev/null || true
        strip_cron_pattern 'aegis|aliyun|cloudmonitor|assist_daemon|argusagent'
        ok "已清理阿里云监控/云助手服务"
    fi

    if [ -d /usr/local/qcloud ] || [ -d /usr/local/tat ] || [ -d /usr/local/ta ] || [ -d /usr/local/sa ] || [ -d /usr/local/agenttools ] || \
       [ -f /etc/cron.d/sgagenttask ] || is_pkg_installed tat-agent || is_pkg_installed tat_agent || \
       { [ "$HAS_SYSTEMD" -eq 1 ] && systemctl list-unit-files 'tat_agent*' 'YD*' --no-legend 2>/dev/null | grep -q .; }; then
        found=1
        local sh_u=""
        for sh_u in /usr/local/qcloud/stargate/admin/uninstall.sh \
                    /usr/local/qcloud/YunJing/uninst.sh \
                    /usr/local/qcloud/monitor/barad/admin/uninstall.sh \
                    /usr/local/qcloud/tat_agent/uninstall.sh; do
            if [ -x "$sh_u" ]; then
                bash "$sh_u" >/dev/null 2>&1 || true
            fi
        done
        if [ "$HAS_SYSTEMD" -eq 1 ]; then
            systemctl disable --now tat_agent.service tat_agent_service.service stargate.service barad_agent.service YDService.service >/dev/null 2>&1 || true
        fi
        pkill -9 -f 'tat_agent|secu-tcs-agent|sgagent|barad_agent|YDService|YDLive|ydservice|sap100|sap_daemon' >/dev/null 2>&1 || true
        rm -rf /usr/local/qcloud /usr/local/tat /usr/local/ta /usr/local/sa /usr/local/agenttools /etc/cron.d/sgagenttask \
               /etc/systemd/system/tat_agent.service /etc/systemd/system/tat_agent_service.service /etc/systemd/system/YDService.service 2>/dev/null || true
        strip_cron_pattern 'qcloud|stargate|sgagent|barad|tat_agent|YDService'
        ok "已清理腾讯云监控/云镜/TAT助手"
    fi

    if [ -d /usr/local/telescope ] || [ -d /usr/local/hostguard ] || [ -d /usr/local/uniagent ] || [ -d /opt/uniagent ] || \
       [ -d /usr/local/hss ] || [ -d /usr/local/agentguard ] || [ -f /etc/init.d/hostguard ] || is_pkg_installed hostguard; then
        found=1
        local hw_u=""
        for hw_u in /usr/local/telescope/uninstall.sh /usr/local/telescope/bin/uninstall.sh \
                    /usr/local/uniagent/bin/uninstall.sh /opt/uniagent/bin/uninstall.sh \
                    /usr/local/hss/uninstall.sh /usr/local/agentguard/uninstall.sh; do
            if [ -x "$hw_u" ]; then
                bash "$hw_u" >/dev/null 2>&1 || true
            fi
        done
        if [ -x /etc/init.d/hostguard ]; then
            /etc/init.d/hostguard stop >/dev/null 2>&1 || true
        fi
        if [ "$HAS_SYSTEMD" -eq 1 ]; then
            systemctl disable --now uniagent.service telescoped.service telescope.service hostguard.service hss.service >/dev/null 2>&1 || true
        fi
        pkill -9 -f 'telescope|hostguard|uniagent|agentguard' >/dev/null 2>&1 || true
        if is_pkg_installed hostguard && ! apt-get purge -s --no-install-recommends hostguard 2>/dev/null | grep -qE '^Inst '; then
            apt-get purge -y --no-install-recommends hostguard >/dev/null 2>&1 || true
        fi
        rm -rf /usr/local/telescope /usr/local/hostguard /usr/local/uniagent /opt/uniagent /usr/local/hss /usr/local/agentguard /etc/init.d/hostguard 2>/dev/null || true
        strip_cron_pattern 'telescope|hostguard|uniagent|agentguard'
        ok "已清理华为云监控/主机安全代理"
    fi

    if [ -d /opt/ucloud/uagent ] || [ -d /usr/lib/ucloud/uagent ] || [ -d /usr/local/uagent ] || [ -d /etc/uagent ] || \
       [ -d /usr/local/cloud-monitor ] || [ -d /opt/linode/longview ] || [ -d /usr/local/bce ] || [ -d /opt/bcm-agent ] || \
       { [ "$HAS_SYSTEMD" -eq 1 ] && systemctl list-unit-files cloud-monitor-agent.service uagent.service bce-agent.service bcm-agent.service longview.service noderig.service beamium.service --no-legend 2>/dev/null | grep -q .; }; then
        found=1
        if [ "$HAS_SYSTEMD" -eq 1 ]; then
            systemctl disable --now cloud-monitor-agent.service uagent.service bce-agent.service bcm-agent.service longview.service noderig.service beamium.service >/dev/null 2>&1 || true
        fi
        rm -rf /opt/ucloud/uagent /usr/lib/ucloud/uagent /usr/local/uagent /etc/uagent /usr/local/cloud-monitor \
               /opt/linode/longview /usr/local/bce /etc/bce /opt/bcm-agent 2>/dev/null || true
        ok "已清理其它云监控代理"
    fi

    if [ -f /etc/apt/sources.list.d/ovh-metrics.list ] || [ -f /etc/apt/sources.list.d/ovh-rtm.list ]; then
        rm -f /etc/apt/sources.list.d/ovh-metrics.list /etc/apt/sources.list.d/ovh-rtm.list 2>/dev/null || true
        found=1
    fi

    if command -v snap >/dev/null 2>&1; then
        local sp=""
        for sp in amazon-ssm-agent oracle-cloud-agent; do
            if snap list "$sp" >/dev/null 2>&1; then
                if snap remove --purge "$sp" >/dev/null 2>&1; then
                    found=1
                fi
            fi
        done
    fi

    if [ "$found" -eq 0 ]; then
        ok "未检测到厂家常驻监控代理"
    fi
}

is_versioned_kernel_pkg() {
    local pkg="$1"
    [[ "$pkg" =~ ^linux-([a-z0-9.-]+-)?(image|image-unsigned|headers|modules|modules-extra)-[0-9]+\.[0-9]+ ]]
}

get_protected_kernel_pkgs() {
    local current="$1"
    local -A installed=() deps_map=() seen=()
    local -a pkgs=() queue=()
    local st="" p="" dep="" d="" mod_owner=""

    while IFS=$'\t' read -r st p dep; do
        [ "$st" = "install ok installed" ] || continue
        [ -z "$p" ] && continue
        pkgs+=("$p")
        installed["$p"]=1
        deps_map["$p"]="$dep"
        if [[ "$p" == *"$current"* ]]; then
            seen["$p"]=1
            queue+=("$p")
        fi
    done < <(dpkg-query -W -f='${Status}\t${Package}\t${Depends}, ${Recommends}\n' 'linux-*' 2>/dev/null || true)

    if [ -d "/lib/modules/${current}" ]; then
        mod_owner="$(dpkg-query -S "/lib/modules/${current}" 2>/dev/null | awk -F: '{print $1}' | tr ',' '\n' | awk '{$1=$1; if($0!="") print}' || true)"
        for p in $mod_owner; do
            if [ -n "${installed[$p]:-}" ] && [ -z "${seen[$p]:-}" ]; then
                seen["$p"]=1
                queue+=("$p")
            fi
        done
    fi

    local changed=1
    while [ "$changed" -eq 1 ]; do
        changed=0
        local idx=0
        while [ "$idx" -lt "${#queue[@]}" ]; do
            p="${queue[$idx]}"
            idx=$((idx + 1))
            for d in $(tr ',|()' '\n' <<< "${deps_map[$p]:-}" | awk '{print $1}'); do
                [[ "$d" == linux-* ]] || continue
                if [ -n "${installed[$d]:-}" ] && [ -z "${seen[$d]:-}" ]; then
                    seen["$d"]=1
                    queue+=("$d")
                    changed=1
                fi
            done
        done
        for p in "${pkgs[@]}"; do
            [ -z "${seen[$p]:-}" ] || continue
            for d in $(tr ',|()' '\n' <<< "${deps_map[$p]:-}" | awk '{print $1}'); do
                if [ -n "${seen[$d]:-}" ]; then
                    seen["$p"]=1
                    queue+=("$p")
                    changed=1
                    break
                fi
            done
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
    local st=""
    while IFS=$'\t' read -r st p; do
        [ "$st" = "install ok installed" ] || continue
        [ -z "$p" ] && continue
        [ -n "${protected[$p]:-}" ] && continue
        is_versioned_kernel_pkg "$p" || continue
        if dpkg-query -W -f='${Depends} ${Recommends}\n' "$p" 2>/dev/null | grep -qF "$current"; then
            continue
        fi
        cleanup+=("$p")
    done < <(dpkg-query -W -f='${Status}\t${Package}\n' 'linux-*' 2>/dev/null || true)

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
    step_title "3/7" "移除监控、精简包与全局升级"

    pin_critical_packages
    step_provider_agent_prune

    local -a rc_pkgs=()
    mapfile -t rc_pkgs < <(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}')
    if [ "${#rc_pkgs[@]}" -gt 0 ]; then
        run_logged "清理 ${#rc_pkgs[@]} 个 rc 残留包" apt-get purge -y -q "${rc_pkgs[@]}" || true
    fi

    local -a raw_candidates=(
        man-db manpages manpages-dev groff-base info install-info
        dictionaries-common emacsen-common ispell iamerican ibritish
        ienglish-common wamerican installation-report popularity-contest
        reportbug debian-faq doc-debian util-linux-locales
        packagekit packagekit-tools command-not-found python3-commandnotfound
        os-prober laptop-detect pcp pcp-conf
        bluez cups cups-browsed cups-common cups-client cups-daemon
        avahi-daemon modemmanager wpasupplicant brltty telnet
        rpcbind nfs-common exim4 exim4-base exim4-config exim4-daemon-light
        qemu-utils qemu-guest-agent xe-guest-utilities open-vm-tools
        do-agent droplet-agent oracle-cloud-agent osms-agent
        amazon-ssm-agent amazon-cloudwatch-agent codedeploy-agent aws-codedeploy-agent
        google-cloud-ops-agent stackdriver-agent google-osconfig-agent google-fluentd
        azuremonitoragent omsagent mdsd linode-longview
        ovh-rtm-binaries ovh-rtm-metrics-toolkit noderig beamium
        aliyun-assist aliyun_assist ecs-assist tat-agent tat_agent
        bce-agent bcm-agent uagent vultr-agent
    )
    if [ "$VIRT_TYPE" != "microsoft" ]; then
        raw_candidates+=(hyperv-daemons)
    fi
    if [ "$OS_ID" = "ubuntu" ]; then
        raw_candidates+=(
            snapd apport whoopsie ubuntu-report landscape-common
            ubuntu-pro-client ubuntu-advantage-tools ubuntu-advantage-desktop-daemon
            fwupd motd-news-config
        )
        if ! is_multipath_in_use; then
            raw_candidates+=(multipath-tools)
        fi
    fi

    local pkg=""
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && raw_candidates+=("$pkg")
    done < <(dpkg-query -W -f='${Status}\t${Package}\n' 'qemu-system*' 'plymouth*' 2>/dev/null | awk -F'\t' '$1=="install ok installed"{print $2}' || true)

    local -a to_purge=()
    filter_safe_purge_pkgs to_purge "${raw_candidates[@]}"

    if [ "${#to_purge[@]}" -gt 0 ]; then
        if [ "$OS_ID" = "ubuntu" ] && printf '%s\n' "${to_purge[@]}" | grep -qx 'snapd' && command -v snap >/dev/null 2>&1; then
            local s=""
            for s in $(snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -vE '^(bare|core|core[0-9]+|snapd)$' || true); do
                snap remove --purge "$s" >/dev/null 2>&1 || true
            done
        fi
        run_logged "卸载 ${#to_purge[@]} 个冗余与监控软件包" apt-get purge -y --no-install-recommends "${to_purge[@]}" || true
        if [ "$OS_ID" = "ubuntu" ] && ! is_pkg_installed snapd; then
            rm -rf /var/cache/snapd /var/lib/snapd /var/snap /snap /root/snap /home/*/snap 2>/dev/null || true
        fi
    else
        ok "无待卸载冗余软件包"
    fi

    run_logged "刷新软件源索引" apt-get update -q || true
    run_logged "执行系统已有包就地升级" apt-get upgrade -y -q --without-new-pkgs \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" || true

    if [ "${#DNS_PUSH_SOURCES[@]}" -gt 0 ] || [ ! -s /etc/resolv.conf ] || \
       { [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf 2>/dev/null | grep -qE 'systemd/resolve|resolvconf'; }; then
        if [ -L /etc/resolv.conf ] || [ ! -s /etc/resolv.conf ] || { [ -f /etc/resolv.conf ] && ! grep -qF "${DNS_ORDER[0]}" /etc/resolv.conf 2>/dev/null; }; then
            if [ "$HAS_SYSTEMD" -eq 1 ] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
                systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
            fi
            if write_static_resolv_conf; then
                ok "升级后已复核锁定静态 DNS"
            fi
        fi
    fi

    prune_old_kernels

    if [ -d /usr/share/doc ]; then
        find /usr/share/doc -type f ! -name 'copyright' -delete 2>/dev/null || true
        find /usr/share/doc -type d -empty -delete 2>/dev/null || true
    fi
    local sd=""
    for sd in /usr/share/man /usr/share/info /usr/share/lintian /usr/share/linda; do
        [ -d "$sd" ] || continue
        find "$sd" -type f -delete 2>/dev/null || true
        find "$sd" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    done
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
    ok "现存文档、手册与冗余多语言已清理"
}

step_service_prune() {
    step_title "4/7" "禁用冗余与遥测服务/定时器"
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
        apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
        packagekit.service
        snapd.service snapd.socket snapd.seeded.service
        apport.service whoopsie.service fwupd.service
        motd-news.timer ua-timer.timer ubuntu-advantage.service
        qemu-guest-agent.service
        do-agent.service droplet-agent.service
        oracle-cloud-agent.service osms-agent.service
        amazon-ssm-agent.service amazon-cloudwatch-agent.service codedeploy-agent.service
        google-cloud-ops-agent.service stackdriver-agent.service google-osconfig-agent.service google-fluentd.service
        azuremonitoragent.service omsagent.service mdsd.service
        noderig.service beamium.service ovh-rtm.service longview.service
        rdnssd.service
    )
    if ! is_multipath_in_use; then
        units+=(multipathd.service multipathd.socket)
    fi

    local disabled_cnt=0
    local u=""
    for u in "${units[@]}"; do
        if disable_unit_if_exists "$u"; then
            disabled_cnt=$((disabled_cnt + 1))
        fi
    done

    if [ "$disabled_cnt" -gt 0 ]; then
        ok "已禁用 ${disabled_cnt} 个冗余/监控服务"
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

    local def_dev="" cur_root_qdisc="" ph=""
    def_dev="$(get_default_net_iface)"
    if [ -n "$def_dev" ] && [ -n "$chosen_qdisc" ] && command -v tc >/dev/null 2>&1; then
        cur_root_qdisc="$(tc qdisc show dev "$def_dev" 2>/dev/null | awk '/root/{print $2; exit}')"
        if [ "$cur_root_qdisc" = "mq" ]; then
            while IFS= read -r ph; do
                [ -n "$ph" ] || continue
                tc qdisc replace dev "$def_dev" parent "$ph" "$chosen_qdisc" >/dev/null 2>&1 || true
            done < <(tc qdisc show dev "$def_dev" 2>/dev/null | awk -v q="$chosen_qdisc" '!/root/ && /parent / && $2 != q {for(i=1;i<=NF;i++) if($i=="parent"){print $(i+1)}}' | sort -u || true)
        elif [ -n "$cur_root_qdisc" ] && [ "$cur_root_qdisc" != "$chosen_qdisc" ] && [ "$cur_root_qdisc" != "noqueue" ]; then
            tc qdisc replace dev "$def_dev" root "$chosen_qdisc" >/dev/null 2>&1 || true
        fi
    fi

    local target_real="" sf="" sf_real=""
    target_real="$(readlink -f "$SYSCTL_TARGET" 2>/dev/null || printf '%s' "$SYSCTL_TARGET")"
    for sf in /etc/sysctl.d/*.conf; do
        if [ ! -f "$sf" ] || [ -L "$sf" ]; then
            continue
        fi
        sf_real="$(readlink -f "$sf" 2>/dev/null || printf '%s' "$sf")"
        [ "$sf_real" = "$target_real" ] && continue
        delete_sysctl_kv "$sf" "net.core.default_qdisc" || true
        delete_sysctl_kv "$sf" "net.ipv4.tcp_congestion_control" || true
    done

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
        ok "BBR 已实时开启 (${chosen_cc}) · 默认队列 ${chosen_qdisc:-default}"
    else
        remove_module_line "$MODULES_TARGET" "tcp_bbr" || true
        if [ -n "$chosen_qdisc" ]; then
            upsert_sysctl_kv "$SYSCTL_TARGET" "net.core.default_qdisc" "$chosen_qdisc" || true
        fi
        delete_sysctl_kv "$SYSCTL_TARGET" "net.ipv4.tcp_congestion_control" || true
        warn "内核 $(uname -r) 未编译 BBR，已保持现有拥塞算法"
    fi
}

apply_sysctl_optimizations() {
    if [ ! -w /proc/sys/net/ipv4/tcp_fastopen ] 2>/dev/null && [ "$IS_CONTAINER" -eq 1 ]; then
        warn "容器环境无 sysctl 写权限，跳过内核参数"
        return 0
    fi

    local syn_backlog=4096 sock_max=16777216 tcp_max=16777216 tcp_wmem_def=65536
    local notsent_lowat=131072 udp_min=16384 inotify_watches=524288 default_buf=262144
    if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 768 ]; then
        syn_backlog=1024
        sock_max=4194304
        tcp_max=4194304
        tcp_wmem_def=16384
        notsent_lowat=65536
        udp_min=8192
        inotify_watches=131072
        default_buf=212992
    elif [ "$MEM_MB" -ge 3584 ]; then
        syn_backlog=8192
        sock_max=67108864
        tcp_max=33554432
    elif [ "$MEM_MB" -ge 1536 ]; then
        syn_backlog=8192
        sock_max=33554432
        tcp_max=33554432
    fi

    local -a sysctl_pairs=(
        "net.core.somaxconn=4096"
        "net.core.netdev_max_backlog=4096"
        "net.core.rmem_max=${sock_max}"
        "net.core.wmem_max=${sock_max}"
        "net.ipv4.tcp_rmem=4096 131072 ${tcp_max}"
        "net.ipv4.tcp_wmem=4096 ${tcp_wmem_def} ${tcp_max}"
        "net.ipv4.udp_rmem_min=${udp_min}"
        "net.ipv4.udp_wmem_min=${udp_min}"
        "net.ipv4.tcp_max_syn_backlog=${syn_backlog}"
        "net.ipv4.ip_local_port_range=10000 65535"
        "net.ipv4.tcp_timestamps=1"
        "net.ipv4.tcp_sack=1"
        "net.ipv4.tcp_window_scaling=1"
        "net.ipv4.tcp_moderate_rcvbuf=1"
        "net.ipv4.tcp_fastopen=3"
        "net.ipv4.tcp_mtu_probing=1"
        "net.ipv4.tcp_slow_start_after_idle=0"
        "net.ipv4.tcp_notsent_lowat=${notsent_lowat}"
        "net.ipv4.tcp_fin_timeout=30"
        "net.ipv4.tcp_keepalive_time=600"
        "net.ipv4.tcp_keepalive_intvl=30"
        "net.ipv4.tcp_keepalive_probes=3"
        "net.ipv4.tcp_rfc1337=1"
        "net.ipv4.tcp_syncookies=1"
        "net.ipv4.icmp_echo_ignore_broadcasts=1"
        "net.ipv4.icmp_ignore_bogus_error_responses=1"
        "net.ipv4.conf.all.accept_redirects=0"
        "net.ipv4.conf.default.accept_redirects=0"
        "net.ipv4.conf.all.send_redirects=0"
        "net.ipv4.conf.default.send_redirects=0"
        "net.ipv6.conf.all.accept_redirects=0"
        "net.ipv6.conf.default.accept_redirects=0"
        "vm.vfs_cache_pressure=50"
        "vm.dirty_background_ratio=5"
        "vm.dirty_ratio=10"
        "fs.inotify.max_user_instances=1024"
        "fs.suid_dumpable=0"
        "fs.protected_hardlinks=1"
        "fs.protected_symlinks=1"
        "kernel.kptr_restrict=1"
        "kernel.dmesg_restrict=1"
    )
    if [ "$HAS_ZRAM" -eq 0 ]; then
        sysctl_pairs+=("vm.swappiness=10")
    fi

    local -a sysctl_min_pairs=(
        "net.core.optmem_max=65536"
        "fs.inotify.max_user_watches=${inotify_watches}"
        "net.core.rmem_default=${default_buf}"
        "net.core.wmem_default=${default_buf}"
    )

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

    for item in "${sysctl_min_pairs[@]}"; do
        k="${item%%=*}"
        v="${item#*=}"
        ppath="/proc/sys/${k//./\/}"
        if [ -e "$ppath" ] && [ -w "$ppath" ]; then
            if upsert_sysctl_min_kv "$SYSCTL_TARGET" "$k" "$v"; then
                changed=1
            fi
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
    local ssh_body=$'UseDNS no\nGSSAPIAuthentication no\nClientAliveInterval 60\nClientAliveCountMax 3'
    if upsert_block_file "$ssh_conf" "# >>> sys-opt-ssh >>>" "# <<< sys-opt-ssh <<<" "$ssh_body" '^[[:space:]]*Include[[:space:]]+'; then
        [ -d /run/sshd ] || mkdir -p /run/sshd 2>/dev/null || true
        if command -v sshd >/dev/null 2>&1 && [ -d /run/sshd ] && ! sshd -t >/dev/null 2>&1; then
            warn "sshd -t 检查未通过，未重载 SSH，请检查 ${ssh_conf}"
            return 0
        fi
        if [ "$HAS_SYSTEMD" -eq 1 ]; then
            systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
        fi
        ok "SSH 已更新防超时/免反查并重载"
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
        local -a j_opts=(
            "Compress=yes" "SystemMaxUse=32M" "SystemMaxFileSize=4M" "SystemMaxFiles=8"
            "RuntimeMaxUse=8M" "RuntimeMaxFileSize=2M" "RuntimeMaxFiles=4" "MaxRetentionSec=7day"
        )
        if ! is_pkg_installed rsyslog; then
            j_opts+=("ForwardToSyslog=no")
        fi
        if upsert_ini_section /etc/systemd/journald.conf "[Journal]" "${j_opts[@]}"; then
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

    if [ "$IS_CONTAINER" -eq 0 ] && [ "$HAS_SYSTEMD" -eq 1 ] && command -v timedatectl >/dev/null 2>&1; then
        if systemctl list-unit-files systemd-timesyncd.service chrony.service --no-legend 2>/dev/null | grep -q .; then
            timedatectl set-ntp true >/dev/null 2>&1 || true
            ok "NTP 时间同步已启用"
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
    step_title "6/7" "彻底清理备份、日志与垃圾文件"

    sync
    local -a auto_sim=()
    local cur_kern=""
    cur_kern="$(uname -r)"
    mapfile -t auto_sim < <(apt-get autoremove -s 2>/dev/null | awk '/^Remv /{print $2}' || true)
    if [ "${#auto_sim[@]}" -gt 0 ]; then
        local ap=""
        for ap in "${auto_sim[@]}"; do
            if [[ "$ap" =~ ^(openssh-|netplan|ifupdown|dhcpcd|isc-dhcp|iproute2|iputils-|netbase|systemd|udev|kmod|sudo|ca-certificates|initramfs|cloud-init|grub|efibootmgr) ]] || \
               { [[ "$ap" =~ ^linux-(image|image-unsigned|headers|modules|modules-extra|generic|virtual|aws|gcp|azure|oracle|kvm|xanmod|liquorix) ]] && { [[ "$ap" == *"$cur_kern"* ]] || ! is_versioned_kernel_pkg "$ap"; }; }; then
                apt-mark manual "$ap" >/dev/null 2>&1 || true
            fi
        done
    fi
    run_logged "清理孤立依赖包" apt-get autoremove --purge -y -q --no-install-recommends || true
    apt-get clean -qq >/dev/null 2>&1 || true
    find /var/lib/apt/lists -type f ! -name 'lock' -delete 2>/dev/null || true
    find /var/lib/apt/periodic /var/cache/apt -type f ! -name 'lock' -delete 2>/dev/null || true
    find /var/cache/debconf /var/lib/dpkg -maxdepth 1 -type f -name '*-old' -delete 2>/dev/null || true
    find /var/cache/man /var/cache/fontconfig -type f -delete 2>/dev/null || true
    rm -f /var/cache/motd-news 2>/dev/null || true
    find /var/backups -mindepth 1 -type f -delete 2>/dev/null || true
    ok "APT 索引、缓存与系统备份已清理"

    if [ "$IS_CONTAINER" -eq 0 ]; then
        local cur_k="" mdir="" mver=""
        cur_k="$(uname -r)"
        for mdir in /lib/modules/[0-9]*; do
            [ -d "$mdir" ] || continue
            mver="$(basename "$mdir")"
            if [ "$mver" != "$cur_k" ] && [ ! -f "/boot/vmlinuz-${mver}" ]; then
                rm -rf "$mdir" 2>/dev/null || true
            fi
        done
    fi

    find /etc /var /opt /srv /root /home \
        -type d \( -name '.git' -o -name '.ssh' -o -path '/var/lib/docker' -o -path '/var/lib/containerd' -o -path '/var/lib/dpkg' -o -path '/var/lib/apt' -o -path '/etc/ssl' \) -prune -o \
        -type f \( -name '*.dpkg-old' -o -name '*.dpkg-dist' -o -name '*.dpkg-new' \
        -o -name '*.ucf-old' -o -name '*.ucf-dist' -o -name '*.ucf-new' \
        -o -name '*.bak' -o -name '*.old' -o -name '*.tmp' \
        -o -name '*.swp' -o -name '*.swo' -o -name '*~' \
        -o -name '*.orig' -o -name '*.rej' \) -delete 2>/dev/null || true
    rm -f /vmlinuz.old /initrd.img.old /boot/vmlinuz.old /boot/initrd.img.old /boot/*.old /boot/*.bak 2>/dev/null || true
    ok "配置残留与备份文件已清理"

    find /var/crash /var/lib/systemd/coredump /var/lib/apport/coredump /var/lib/systemd/pstore /var/lib/whoopsie -type f -delete 2>/dev/null || true
    find /var/mail /var/spool/mail -type f -exec truncate -s 0 {} \; 2>/dev/null || true
    if command -v file >/dev/null 2>&1; then
        find /var /opt /srv /root /home -type f \( -name 'core' -o -name 'core.[0-9]*' \) -exec sh -c '
            for f in "$@"; do
                file "$f" 2>/dev/null | grep -qi "core file" && rm -f "$f" 2>/dev/null || true
            done
        ' sh {} + 2>/dev/null || true
    fi

    local self_path=""
    self_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
    find /var/tmp -mindepth 1 -type f -delete 2>/dev/null || true
    find /var/tmp -mindepth 1 -type d -empty -delete 2>/dev/null || true
    if [ -n "$self_path" ] && [ -e "$self_path" ]; then
        find /tmp -mindepth 1 \
            \( -path '/tmp/.X11-unix' -o -path '/tmp/.ICE-unix' -o -path '/tmp/.font-unix' -o -path '/tmp/.Test-unix' -o -name 'systemd-private-*' -o -path "${TMP_WORK:-/nonexistent}" \) -prune -o \
            -type f ! -samefile "$self_path" -delete 2>/dev/null || true
    else
        find /tmp -mindepth 1 \
            \( -path '/tmp/.X11-unix' -o -path '/tmp/.ICE-unix' -o -path '/tmp/.font-unix' -o -path '/tmp/.Test-unix' -o -name 'systemd-private-*' -o -path "${TMP_WORK:-/nonexistent}" \) -prune -o \
            -type f -delete 2>/dev/null || true
    fi
    find /tmp -mindepth 1 -maxdepth 2 -type d -empty ! -name '.X11-unix' ! -name '.ICE-unix' ! -name '.font-unix' ! -name '.Test-unix' ! -name 'systemd-private-*' ! -path "${TMP_WORK:-/nonexistent}" -delete 2>/dev/null || true
    ok "临时文件与崩溃转储已清理"

    local d=""
    for d in /home/* /root; do
        [ -d "$d" ] || continue
        find "$d/.cache" "$d/.local/share/Trash" -type f -delete 2>/dev/null || true
        find "$d" -maxdepth 1 -type f \( -name ".bash_history" -o -name ".zsh_history" -o -name ".python_history" -o -name ".lesshst" -o -name ".viminfo" -o -name ".wget-hsts" \) -delete 2>/dev/null || true
        rm -rf "${d}/.npm/_cacache" "${d}/.m2/repository" "${d}/.gradle/caches" 2>/dev/null || true
    done

    if [ "$HAS_SYSTEMD" -eq 1 ] && command -v journalctl >/dev/null 2>&1; then
        journalctl --rotate >/dev/null 2>&1 || true
        journalctl --vacuum-time=1s >/dev/null 2>&1 || journalctl --vacuum-size=1M >/dev/null 2>&1 || true
    fi
    find /var/log/journal -type f -name '*.journal~' -delete 2>/dev/null || true
    if [ -d /var/log ]; then
        rm -rf /var/log/installer /var/log/apt/* /var/log/unattended-upgrades/* /var/log/aegis* 2>/dev/null || true
        find /var/log -path '/var/log/journal' -prune -o \
            -type f \( -name '*.log.*' -o -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' -o -name '*.old' -o -name '*.[0-9]' -o -name 'cloud-init*.log*' -o -name 'waagent.log*' \) -delete 2>/dev/null || true
        find /var/log -path '/var/log/journal' -prune -o \
            -type f ! -name '*.db' ! -name '*.sqlite*' -exec truncate -s 0 {} \; 2>/dev/null || true
    fi
    ok "全部日志与用户历史缓存已清理"

    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1 && docker system prune -a -f >/dev/null 2>&1; then
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
    step_title "7/7" "终态实测核验"
    local cc_now="" qdisc_def="" def_dev="" live_qdisc="" disk_now="" bbr_real="" fq_real=""
    cc_now="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    qdisc_def="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    def_dev="$(get_default_net_iface)"
    live_qdisc="$(get_live_nic_qdisc "$def_dev")"
    disk_now="$(df -Ph / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')"

    if [[ "$cc_now" == bbr* ]] && { grep -qw tcp_bbr /proc/modules 2>/dev/null || is_builtin_mod tcp_bbr; }; then
        bbr_real="${C_BGRN}已实时开启 (${cc_now})${C_RST}"
    elif [[ "$cc_now" == bbr* ]]; then
        bbr_real="${C_BGRN}已开启 (${cc_now})${C_RST}"
    else
        bbr_real="${C_BYLW}未开启 (当前: ${cc_now})${C_RST}"
    fi

    if [ -n "$def_dev" ] && [ -n "$live_qdisc" ]; then
        if [[ "$live_qdisc" =~ (^|[,(])fq([,)]|$) ]]; then
            fq_real="${C_BGRN}默认 ${qdisc_def} · ${def_dev} 实时 ${live_qdisc}${C_RST}"
        elif [ "$qdisc_def" = "fq" ]; then
            fq_real="${C_BYLW}默认 ${qdisc_def} · ${def_dev} 当前 ${live_qdisc} (重启生效)${C_RST}"
        else
            fq_real="${C_BYLW}默认 ${qdisc_def} · ${def_dev} 实时 ${live_qdisc}${C_RST}"
        fi
    else
        fq_real="默认 ${qdisc_def}"
    fi

    echo -e "  ${C_DIM}系统:${C_RST} ${OS_PRETTY}"
    echo -e "  ${C_DIM}BBR :${C_RST} ${bbr_real}"
    echo -e "  ${C_DIM}FQ  :${C_RST} ${fq_real}"
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
