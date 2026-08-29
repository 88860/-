#!/bin/bash

set -u
export LC_ALL=C

TARGET_MIN=1
TARGET_MAX=10
JOURNAL_MAX=8

LOGROTATE_DIR="/etc/logrotate.d"
LOGROTATE_MAIN="/etc/logrotate.conf"
JOURNAL_CONF="/etc/systemd/journald.conf"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
NC='\033[0m'

declare -a MODIFY_FILE=()
declare -a MODIFY_LOG=()
declare -a MODIFY_VALUE=()
declare -a MODIFY_KIND=()

declare -A LOG_SIZE
declare -A LOG_TYPE
declare -A LOG_CONTROL
declare -A LOG_STANZA
declare -A LOG_RULE
declare -A LOG_CURRENT
declare -A LOG_RECOMMEND

die() {
    echo -e "${RED}错误：$*${NC}"
    exit 1
}

info() {
    echo -e "${GREEN}✓${NC} $*"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $*"
}

human_size() {
    local f="$1"
    [ -e "$f" ] || {
        echo "不存在"
        return
    }

    stat -c '%s' "$f" 2>/dev/null |
    awk '
    {
        if ($1 >= 1073741824)
            printf "%.2fG", $1/1073741824
        else if ($1 >= 1048576)
            printf "%.2fM", $1/1048576
        else if ($1 >= 1024)
            printf "%.2fK", $1/1024
        else
            printf "%dB", $1
    }'
}

get_size_bytes() {
    stat -c '%s' "$1" 2>/dev/null || echo 0
}

command -v awk >/dev/null 2>&1 || die "缺少 awk"
command -v sed >/dev/null 2>&1 || die "缺少 sed"
command -v find >/dev/null 2>&1 || die "缺少 find"
command -v stat >/dev/null 2>&1 || die "缺少 stat"
command -v logrotate >/dev/null 2>&1 || die "未安装 logrotate"

[ "$(id -u)" -eq 0 ] || die "请使用 root 执行"

echo "============================================================"
echo " Debian 13 日志大小审计与精准限制"
echo " 扫描 → 识别 → 分类 → 建议 → 确认 → 精准修改 → 验证"
echo "============================================================"
echo
echo "目标：普通日志 1M–10M；journald 单文件 ${JOURNAL_MAX}M"
echo
echo "原则："
echo "  ✓ 只修改已经存在的控制配置"
echo "  ✓ 必须确认配置实际控制目标日志"
echo "  ✓ 不创建新的 logrotate 配置"
echo "  ✓ 不创建 journald drop-in"
echo "  ✓ 不备份"
echo "  ✓ 不删除现有日志"
echo "  ✓ 无明确控制关系的日志跳过"
echo

# ------------------------------------------------------------
# 1. 系统检测
# ------------------------------------------------------------

echo "[1/8] 系统检测"

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    die "无法读取 /etc/os-release"
fi

echo "  OS       : ${PRETTY_NAME:-unknown}"
echo "  Kernel   : $(uname -r)"
echo "  /var/log : $(du -sh /var/log 2>/dev/null | awk '{print $1}')"
echo "  /run/log : $(du -sh /run/log 2>/dev/null | awk '{print $1}' 2>/dev/null || echo 0)"
echo

# ------------------------------------------------------------
# 2. 日志分类
# ------------------------------------------------------------

classify_log() {
    local p="$1"
    local b
    b="$(basename "$p")"

    case "$p" in
        /var/log/dpkg.log)
            echo "dpkg|5"
            ;;
        /var/log/alternatives.log)
            echo "alternatives|2"
            ;;
        /var/log/apt/history.log)
            echo "apt-history|3"
            ;;
        /var/log/apt/term.log)
            echo "apt-terminal|5"
            ;;
        /var/log/unattended-upgrades/*)
            echo "unattended-upgrades|5"
            ;;
        /var/log/auth.log|/var/log/secure)
            echo "authentication|10"
            ;;
        /var/log/syslog)
            echo "system|10"
            ;;
        /var/log/messages)
            echo "system|10"
            ;;
        /var/log/daemon.log)
            echo "daemon|10"
            ;;
        /var/log/kern.log)
            echo "kernel|10"
            ;;
        /var/log/debug)
            echo "debug|5"
            ;;
        /var/log/mail.log)
            echo "mail|5"
            ;;
        /var/log/mail.err)
            echo "mail-error|3"
            ;;
        /var/log/mail.warn)
            echo "mail-warning|3"
            ;;
        /var/log/user.log)
            echo "user|5"
            ;;
        /var/log/wtmp)
            echo "login-history|5"
            ;;
        /var/log/btmp)
            echo "failed-login-history|5"
            ;;
        /var/log/lastlog)
            echo "lastlog|5"
            ;;
        /var/log/faillog)
            echo "login-failure|5"
            ;;
        /var/log/cron)
            echo "cron|5"
            ;;
        /var/log/firewalld)
            echo "firewall|5"
            ;;
        /var/log/ufw.log)
            echo "firewall|5"
            ;;
        /var/log/fail2ban.log)
            echo "security|5"
            ;;
        /var/log/nginx/*)
            echo "web-server|10"
            ;;
        /var/log/apache2/*)
            echo "web-server|10"
            ;;
        /var/log/caddy/*)
            echo "web-server|10"
            ;;
        /var/log/mysql/*)
            echo "database|10"
            ;;
        /var/log/mariadb/*)
            echo "database|10"
            ;;
        /var/log/postgresql/*)
            echo "database|10"
            ;;
        /var/log/redis/*)
            echo "database|5"
            ;;
        /var/log/samba/*)
            echo "samba|5"
            ;;
        /var/log/squid/*)
            echo "proxy|10"
            ;;
        /var/log/libvirt/*)
            echo "virtualization|5"
            ;;
        *)
            echo "unknown|0"
            ;;
    esac
}

# ------------------------------------------------------------
# 3. 精确解析 logrotate stanza
# ------------------------------------------------------------

TMP_ROTATE="$(mktemp)"
trap 'rm -f "$TMP_ROTATE"' EXIT

{
    [ -f "$LOGROTATE_MAIN" ] && cat "$LOGROTATE_MAIN"

    if [ -d "$LOGROTATE_DIR" ]; then
        find "$LOGROTATE_DIR" -maxdepth 1 -type f -readable -print0 2>/dev/null |
        while IFS= read -r -d '' f; do
            cat "$f"
            echo
        done
    fi
} > "$TMP_ROTATE"

# 返回匹配目标日志的 stanza 信息：
# file|start|end|rule|size|maxsize
find_stanza() {
    local target="$1"

    awk -v target="$target" '
    function trim(s) {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }

    function unquote(s) {
        gsub(/^"/, "", s)
        gsub(/"$/, "", s)
        return s
    }

    function glob_to_regex(g,    r) {
        r=g
        gsub(/\./, "\\.", r)
        gsub(/\*/, ".*", r)
        gsub(/\?/, ".", r)
        return "^" r "$"
    }

    BEGIN {
        inside=0
        start=0
        depth=0
        rule=""
        size=""
        maxsize=""
        file=""
    }

    {
        line=$0

        if (!inside) {
            if (line ~ /^[ \t]*[^# \t].*\{[ \t]*$/) {
                header=line
                sub(/[ \t]*\{[ \t]*$/, "", header)
                header=trim(header)

                n=split(header, paths, /[ \t]+/)

                matched=0

                for (i=1; i<=n; i++) {
                    p=unquote(paths[i])

                    if (p == target) {
                        matched=1
                        rule=p
                    }
                    else if (p ~ /[*?]/) {
                        rg=glob_to_regex(p)
                        if (target ~ rg) {
                            matched=1
                            rule=p
                        }
                    }
                }

                if (matched) {
                    inside=1
                    start=NR
                    depth=1
                    file=FILENAME
                    size=""
                    maxsize=""
                }
            }
        }
        else {
            if ($0 ~ /^[ \t]*size[ \t]+/) {
                x=$0
                sub(/^[ \t]*size[ \t]+/, "", x)
                sub(/[ \t#].*$/, "", x)
                size=x
            }

            if ($0 ~ /^[ \t]*maxsize[ \t]+/) {
                x=$0
                sub(/^[ \t]*maxsize[ \t]+/, "", x)
                sub(/[ \t#].*$/, "", x)
                maxsize=x
            }

            if ($0 ~ /\{[ \t]*$/)
                depth++

            if ($0 ~ /^[ \t]*\}/) {
                depth--

                if (depth == 0) {
                    print file "|" start "|" NR "|" rule "|" size "|" maxsize
                    exit
                }
            }
        }
    }
    ' "$TMP_ROTATE"
}

# ------------------------------------------------------------
# 4. 收集实际日志
# ------------------------------------------------------------

echo "[2/8] 扫描实际日志文件"

declare -a LOGS=()

while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue

    case "$f" in
        *.gz|*.xz|*.bz2|*.zst|*.lz4|*.old|*.1|*.2|*.3|*.4|*.5|*.6|*.7|*.8|*.9)
            continue
            ;;
    esac

    LOGS+=("$f")
done < <(
    find /var/log -type f -print0 2>/dev/null
)

echo "  找到 ${#LOGS[@]} 个当前日志文件"
echo

# ------------------------------------------------------------
# 5. 建立日志控制关系
# ------------------------------------------------------------

echo "[3/8] 精确检测 logrotate 控制关系"
echo

ROTATE_COUNT=0
MODIFY_COUNT=0
UNKNOWN_COUNT=0
VALID_COUNT=0

for log in "${LOGS[@]}"; do

    info_type="$(classify_log "$log")"
    type="${info_type%%|*}"
    rec="${info_type##*|}"

    LOG_SIZE["$log"]="$(human_size "$log")"
    LOG_TYPE["$log"]="$type"

    if [ "$rec" = "0" ]; then
        LOG_RECOMMEND["$log"]="跳过"
    else
        LOG_RECOMMEND["$log"]="${rec}M"
    fi

    match="$(find_stanza "$log" 2>/dev/null || true)"

    if [ -n "$match" ]; then
        IFS='|' read -r ctl start end rule size maxsize <<< "$match"

        LOG_CONTROL["$log"]="$ctl"
        LOG_STANZA["$log"]="${start}-${end}"
        LOG_RULE["$log"]="$rule"

        if [ -n "$maxsize" ]; then
            LOG_CURRENT["$log"]="maxsize $maxsize"
        elif [ -n "$size" ]; then
            LOG_CURRENT["$log"]="size $size"
        else
            LOG_CURRENT["$log"]="未设置"
        fi

        VALID_COUNT=$((VALID_COUNT + 1))

        if [ "$rec" != "0" ]; then
            current_num=0

            if [ -n "$maxsize" ]; then
                current_num="$(echo "$maxsize" | awk '
                BEGIN { IGNORECASE=1 }
                {
                    if ($0 ~ /[0-9]+[mM]/) {
                        x=$0
                        gsub(/[mM]/,"",x)
                        print x
                    }
                    else print 999
                }')"
            fi

            if [ -z "$maxsize" ] || [ "$current_num" -gt "$rec" ] 2>/dev/null; then
                MODIFY_FILE+=("$ctl")
                MODIFY_LOG+=("$log")
                MODIFY_VALUE+=("${rec}M")
                MODIFY_KIND+=("logrotate")
                MODIFY_COUNT=$((MODIFY_COUNT + 1))
            fi
        fi
    else
        LOG_CONTROL["$log"]="未找到"
        LOG_STANZA["$log"]="-"
        LOG_RULE["$log"]="-"
        LOG_CURRENT["$log"]="未设置"
        UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
    fi
done

echo "  已识别明确控制关系：${VALID_COUNT}"
echo "  未找到控制关系    ：${UNKNOWN_COUNT}"
echo

# ------------------------------------------------------------
# 6. journald
# ------------------------------------------------------------

echo "[4/8] 检测 systemd-journald"

JOURNAL_FILES=()
JOURNAL_TOTAL=0
JOURNAL_OVER=0

while IFS= read -r -d '' f; do
    JOURNAL_FILES+=("$f")
    JOURNAL_TOTAL=$((JOURNAL_TOTAL + 1))

    bytes="$(get_size_bytes "$f")"

    if [ "$bytes" -gt $((JOURNAL_MAX * 1024 * 1024)) ]; then
        JOURNAL_OVER=$((JOURNAL_OVER + 1))
    fi
done < <(
    find /var/log/journal /run/log/journal \
        -type f \
        \( -name '*.journal' -o -name '*.journal~' \) \
        -print0 2>/dev/null
)

if [ "$JOURNAL_TOTAL" -gt 0 ]; then
    echo "  journal 文件数 : $JOURNAL_TOTAL"
    echo "  >${JOURNAL_MAX}M ： $JOURNAL_OVER"
else
    echo "  journal 文件数 : 0"
fi

J_SYSTEM=""
J_RUNTIME=""

if [ -f "$JOURNAL_CONF" ]; then
    J_SYSTEM="$(awk '
        /^[ \t]*SystemMaxFileSize[ \t]*=/ {
            x=$0
            sub(/^[^=]*=[ \t]*/, "", x)
            sub(/[ \t#].*$/, "", x)
            print x
            exit
        }
    ' "$JOURNAL_CONF")"

    J_RUNTIME="$(awk '
        /^[ \t]*RuntimeMaxFileSize[ \t]*=/ {
            x=$0
            sub(/^[^=]*=[ \t]*/, "", x)
            sub(/[ \t#].*$/, "", x)
            print x
            exit
        }
    ' "$JOURNAL_CONF")"
fi

if [ -f "$JOURNAL_CONF" ]; then
    if [ -n "$J_SYSTEM" ]; then
        echo "  SystemMaxFileSize : $J_SYSTEM"
    else
        echo "  SystemMaxFileSize : 未设置"
    fi

    if [ -n "$J_RUNTIME" ]; then
        echo "  RuntimeMaxFileSize: $J_RUNTIME"
    else
        echo "  RuntimeMaxFileSize: 未设置"
    fi
else
    echo "  /etc/systemd/journald.conf : 不存在"
fi

echo

# ------------------------------------------------------------
# 7. 完整审计表
# ------------------------------------------------------------

echo "[5/8] 所有日志及控制关系"
echo

printf '%-42s %-18s %-12s %-28s %-12s %-10s\n' \
    "日志" "类型" "大小" "控制配置" "当前限制" "建议"

printf '%-42s %-18s %-12s %-28s %-12s %-10s\n' \
    "------------------------------------------" \
    "------------------" \
    "------------" \
    "----------------------------" \
    "------------" \
    "----------"

for log in "${LOGS[@]}"; do
    printf '%-42s %-18s %-12s %-28s %-12s %-10s\n' \
        "$log" \
        "${LOG_TYPE[$log]}" \
        "${LOG_SIZE[$log]}" \
        "${LOG_CONTROL[$log]}" \
        "${LOG_CURRENT[$log]}" \
        "${LOG_RECOMMEND[$log]}"
done

echo

# ------------------------------------------------------------
# 8. 修改清单
# ------------------------------------------------------------

echo "[6/8] 修改建议"
echo
echo "建议依据：日志用途，而不是当前文件大小。"
echo

if [ "$MODIFY_COUNT" -eq 0 ]; then
    info "没有需要修改的现有控制配置"
else
    for ((i=0; i<MODIFY_COUNT; i++)); do
        echo "[$((i+1))]"
        echo "  日志     : ${MODIFY_LOG[$i]}"
        echo "  类型     : ${LOG_TYPE[${MODIFY_LOG[$i]}]}"
        echo "  控制文件 : ${MODIFY_FILE[$i]}"
        echo "  stanza   : ${LOG_STANZA[${MODIFY_LOG[$i]}]}"
        echo "  匹配规则 : ${LOG_RULE[${MODIFY_LOG[$i]}]}"
        echo "  当前限制 : ${LOG_CURRENT[${MODIFY_LOG[$i]}]}"
        echo "  建议限制 : maxsize ${MODIFY_VALUE[$i]}"
        echo
    done
fi

# journald 只修改已经存在的 /etc/systemd/journald.conf
JOURNAL_MODIFY=0

if [ -f "$JOURNAL_CONF" ]; then
    if [ -n "$J_SYSTEM" ] && [ "$J_SYSTEM" != "$JOURNAL_MAX"M ]; then
        JOURNAL_MODIFY=1
    elif [ -n "$J_RUNTIME" ] && [ "$J_RUNTIME" != "$JOURNAL_MAX"M ]; then
        JOURNAL_MODIFY=1
    elif [ -z "$J_SYSTEM" ] || [ -z "$J_RUNTIME" ]; then
        JOURNAL_MODIFY=1
    fi
fi

if [ "$JOURNAL_MODIFY" -eq 1 ]; then
    echo "[journald]"
    echo "  控制文件 : $JOURNAL_CONF"
    echo "  SystemMaxFileSize  : ${J_SYSTEM:-未设置} → ${JOURNAL_MAX}M"
    echo "  RuntimeMaxFileSize : ${J_RUNTIME:-未设置} → ${JOURNAL_MAX}M"
    echo
fi

echo "[7/8] 修改原则"
echo
echo "  ✓ 只修改已经存在的 /etc/logrotate.d/*"
echo "  ✓ 只修改真正匹配目标日志的 stanza"
echo "  ✓ 不把未知日志强行归类"
echo "  ✓ 不创建新的 logrotate 配置"
echo "  ✓ 不创建 journald drop-in"
echo "  ✓ journald 只有 /etc/systemd/journald.conf 已存在时才考虑修改"
echo "  ✓ 不删除当前日志"
echo "  ✓ 不备份"
echo

TOTAL_MODIFY=$((MODIFY_COUNT + JOURNAL_MODIFY))

if [ "$TOTAL_MODIFY" -eq 0 ]; then
    echo "============================================================"
    echo "                     无需修改"
    echo "============================================================"
    exit 0
fi

echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo
echo "本次准备修改：$TOTAL_MODIFY 项"
echo
read -r -p "确认执行精准修改？[y/N] " answer

case "$answer" in
    y|Y|yes|YES)
        ;;
    *)
        echo
        echo "已取消，没有修改任何配置。"
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 修改 logrotate
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                     开始修改 logrotate"
echo "============================================================"
echo

for ((i=0; i<MODIFY_COUNT; i++)); do

    file="${MODIFY_FILE[$i]}"
    log="${MODIFY_LOG[$i]}"
    value="${MODIFY_VALUE[$i]}"

    echo "修改：$log"
    echo "  配置：$file"
    echo "  目标：maxsize $value"

    python3 - "$file" "$log" "$value" <<'PY'
import sys
from pathlib import Path

cfg = Path(sys.argv[1])
target = sys.argv[2]
value = sys.argv[3]

text = cfg.read_text()

lines = text.splitlines(True)

def normalize(s):
    return s.strip()

def glob_match(pattern, path):
    import fnmatch
    return fnmatch.fnmatchcase(path, pattern)

start = None
depth = 0
matched = False

for i, raw in enumerate(lines):

    line = raw.strip()

    if start is None:

        if not line or line.startswith("#"):
            continue

        if "{" not in line:
            continue

        header = line.rsplit("{", 1)[0].strip()

        paths = header.split()

        for p in paths:
            if glob_match(p, target):
                matched = True
                break

        if matched:
            start = i
            depth = line.count("{") - line.count("}")
            continue

    else:

        depth += raw.count("{")
        depth -= raw.count("}")

        if raw.lstrip().startswith("maxsize "):
            indent = raw[:len(raw)-len(raw.lstrip())]
            lines[i] = f"{indent}maxsize {value}\n"
            cfg.write_text("".join(lines))
            sys.exit(0)

        if raw.lstrip().startswith("size "):
            indent = raw[:len(raw)-len(raw.lstrip())]
            lines[i] = f"{indent}maxsize {value}\n"
            cfg.write_text("".join(lines))
            sys.exit(0)

        if depth == 0:
            indent = raw[:len(raw)-len(raw.lstrip())]
            lines.insert(i, f"{indent}maxsize {value}\n")
            cfg.write_text("".join(lines))
            sys.exit(0)

print("ERROR")
sys.exit(1)
PY

    rc=$?

    if [ "$rc" -eq 0 ]; then
        info "修改成功"
    else
        die "精准修改失败：$file → $log"
    fi

    echo
done

# ------------------------------------------------------------
# 修改 journald
# ------------------------------------------------------------

if [ "$JOURNAL_MODIFY" -eq 1 ]; then

    echo "============================================================"
    echo "                     修改 systemd-journald"
    echo "============================================================"
    echo

    python3 - "$JOURNAL_CONF" "$JOURNAL_MAX" <<'PY'
import sys
from pathlib import Path

cfg = Path(sys.argv[1])
value = sys.argv[2]

text = cfg.read_text()
lines = text.splitlines(True)

wanted = {
    "SystemMaxFileSize": False,
    "RuntimeMaxFileSize": False,
}

for i, raw in enumerate(lines):
    stripped = raw.lstrip()

    for key in list(wanted):
        if stripped.startswith(key + "="):
            indent = raw[:len(raw)-len(stripped)]
            lines[i] = f"{indent}{key}={value}M\n"
            wanted[key] = True

for key, found in wanted.items():
    if not found:
        raise SystemExit(
            f"{key} 不存在，拒绝追加：不允许创建/追加新的 journald 配置参数"
        )

cfg.write_text("".join(lines))
PY

    rc=$?

    if [ "$rc" -ne 0 ]; then
        die "journald 配置未修改"
    fi

    info "$JOURNAL_CONF 修改完成"
    echo
fi

# ------------------------------------------------------------
# 配置验证
# ------------------------------------------------------------

echo "============================================================"
echo "                     配置语法验证"
echo "============================================================"
echo

if logrotate -d "$LOGROTATE_MAIN" >/tmp/logrotate_check.$$ 2>&1; then
    info "logrotate 配置语法正常"
else
    cat /tmp/logrotate_check.$$
    rm -f /tmp/logrotate_check.$$
    die "logrotate 配置验证失败"
fi

rm -f /tmp/logrotate_check.$$

if [ "$JOURNAL_MODIFY" -eq 1 ]; then
    if command -v systemd-analyze >/dev/null 2>&1; then
        if systemd-analyze verify "$JOURNAL_CONF" >/dev/null 2>&1; then
            info "journald 配置验证正常"
        else
            warn "systemd-analyze 未通过，继续进行文本参数验证"
        fi
    fi
fi

# ------------------------------------------------------------
# 最终验证
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                       最终验证"
echo "============================================================"
echo

VERIFY_FAIL=0

for ((i=0; i<MODIFY_COUNT; i++)); do

    file="${MODIFY_FILE[$i]}"
    log="${MODIFY_LOG[$i]}"
    value="${MODIFY_VALUE[$i]}"

    result="$(python3 - "$file" "$log" <<'PY'
import sys
from pathlib import Path
import fnmatch

cfg = Path(sys.argv[1])
target = sys.argv[2]

lines = cfg.read_text().splitlines()

inside = False
depth = 0
matched = False

for line in lines:

    s = line.strip()

    if not inside:

        if not s or s.startswith("#"):
            continue

        if "{" not in s:
            continue

        header = s.rsplit("{", 1)[0].strip()

        for p in header.split():
            if fnmatch.fnmatchcase(target, p):
                matched = True
                break

        if matched:
            inside = True
            depth = s.count("{") - s.count("}")
            continue

    else:

        depth += line.count("{")
        depth -= line.count("}")

        if s.startswith("maxsize "):
            print(s.split(None, 1)[1])
            sys.exit(0)

        if depth == 0:
            break

sys.exit(1)
PY
)"

    if [ "$result" = "$value" ]; then
        info "$log → maxsize $result"
    else
        warn "$log → 验证失败"
        VERIFY_FAIL=1
    fi
done

if [ "$JOURNAL_MODIFY" -eq 1 ]; then

    s="$(awk -F= '
        /^[ \t]*SystemMaxFileSize[ \t]*=/ {
            gsub(/[ \t]/, "", $2)
            print $2
            exit
        }
    ' "$JOURNAL_CONF")"

    r="$(awk -F= '
        /^[ \t]*RuntimeMaxFileSize[ \t]*=/ {
            gsub(/[ \t]/, "", $2)
            print $2
            exit
        }
    ' "$JOURNAL_CONF")"

    if [ "$s" = "${JOURNAL_MAX}M" ]; then
        info "SystemMaxFileSize = $s"
    else
        warn "SystemMaxFileSize 验证失败"
        VERIFY_FAIL=1
    fi

    if [ "$r" = "${JOURNAL_MAX}M" ]; then
        info "RuntimeMaxFileSize = $r"
    else
        warn "RuntimeMaxFileSize 验证失败"
        VERIFY_FAIL=1
    fi
fi

echo
echo "============================================================"

if [ "$VERIFY_FAIL" -eq 0 ]; then
    echo -e "${GREEN}                    修改完成并验证通过${NC}"
else
    echo -e "${RED}                    存在验证失败项目${NC}"
fi

echo "============================================================"
echo
echo "说明："
echo "  logrotate 的 maxsize 是轮转触发阈值，不是文件系统硬性截断。"
echo "  journald 的 SystemMaxFileSize/RuntimeMaxFileSize 控制单个 journal 文件大小。"
echo "  未找到明确控制关系的日志未修改。"
echo "  本脚本没有删除现有日志，也没有创建新的配置文件。"
echo

exit "$VERIFY_FAIL"
