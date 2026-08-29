#!/bin/bash
#
# Debian 13 日志大小审计与精准限制
#
# 特点：
#   - 不依赖 Python3
#   - 不安装任何软件
#   - 不创建新的配置文件
#   - 不备份
#   - 不删除日志
#   - 只修改已经存在的配置文件
#   - 以 logrotate stanza 为单位识别控制关系
#   - 正确处理同一配置中的多个 stanza
#   - 修改后重新解析同一 stanza
#   - 使用 logrotate 自身进行最终语法/解析验证
#

set -u
export LC_ALL=C

TARGET_SYSTEM=8
TARGET_RUNTIME=8

declare -a LOG_FILES
declare -a ROTATE_FILES
declare -a ROTATE_STANZA_START
declare -a ROTATE_STANZA_END
declare -a ROTATE_PATTERN
declare -a ROTATE_TARGET
declare -a ROTATE_RECOMMEND

TMPROOT="/tmp/log-audit-$$"
mkdir -p "$TMPROOT" || exit 1

cleanup() {
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

die() {
    echo
    echo "错误：$*"
    exit 1
}

command -v awk >/dev/null 2>&1 || die "系统缺少 awk"
command -v sed >/dev/null 2>&1 || die "系统缺少 sed"
command -v grep >/dev/null 2>&1 || die "系统缺少 grep"
command -v find >/dev/null 2>&1 || die "系统缺少 find"
command -v stat >/dev/null 2>&1 || die "系统缺少 stat"
command -v logrotate >/dev/null 2>&1 || die "系统缺少 logrotate"

if [ "$(id -u)" != "0" ]; then
    die "必须使用 root 运行"
fi

echo "============================================================"
echo " Debian 13 日志大小审计与精准限制"
echo " 扫描 → 识别 → 分类 → 建议 → 确认 → 修改 → 验证"
echo "============================================================"
echo
echo "目标：普通日志按用途设置 2M–5M；journald 单文件 8M"
echo
echo "原则："
echo "  ✓ 只修改真实存在且实际控制日志的配置"
echo "  ✓ 以 logrotate stanza 为单位精确处理"
echo "  ✓ 正确处理多个 stanza"
echo "  ✓ 正确处理同一 stanza 中多个日志路径"
echo "  ✓ 不创建任何配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除现有日志"
echo "  ✓ 控制关系无法确认 → 跳过"
echo "  ✓ 不依赖 Python3"
echo

# ------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------

human_size() {
    local bytes="$1"

    if [ "$bytes" -ge $((1024*1024*1024)) ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2fG", b/1073741824}'
    elif [ "$bytes" -ge $((1024*1024)) ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2fM", b/1048576}'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2fK", b/1024}'
    else
        printf "%sB" "$bytes"
    fi
}

recommend_for_log() {
    case "$1" in
        /var/log/alternatives.log)
            echo "2M"
            ;;
        /var/log/apt/history.log)
            echo "3M"
            ;;
        /var/log/apt/term.log)
            echo "5M"
            ;;
        /var/log/dpkg.log)
            echo "5M"
            ;;
        /var/log/btmp)
            echo "5M"
            ;;
        /var/log/wtmp)
            echo "5M"
            ;;
        *)
            echo ""
            ;;
    esac
}

log_type() {
    case "$1" in
        /var/log/alternatives.log)
            echo "alternatives"
            ;;
        /var/log/apt/history.log)
            echo "apt-history"
            ;;
        /var/log/apt/term.log)
            echo "apt-terminal"
            ;;
        /var/log/dpkg.log)
            echo "dpkg"
            ;;
        /var/log/btmp)
            echo "failed-login-history"
            ;;
        /var/log/wtmp)
            echo "login-history"
            ;;
        /var/log/lastlog)
            echo "lastlog"
            ;;
        /var/log/wtmp.db)
            echo "wtmp-db"
            ;;
        /var/log/apt/eipp.log.xz)
            echo "apt-eipp"
            ;;
        /var/log/journal/*)
            echo "journald"
            ;;
        /var/log/installer/*)
            echo "installer"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# 判断一行是否是 logrotate option
is_option_line() {
    case "$1" in
        ""|"#"*) return 1 ;;
        "}"*) return 1 ;;
        "{"*) return 1 ;;
        "/*") return 1 ;;
    esac

    return 0
}

# ------------------------------------------------------------
# 1/8 系统检测
# ------------------------------------------------------------

echo "[1/8] 系统检测"

OS_NAME="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
KERNEL="$(uname -r)"
CPU="$(nproc 2>/dev/null || echo 1)"
RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
RAM_MB=$((RAM_KB / 1024))
SWAP="$(free -m 2>/dev/null | awk '/^Swap:/ {print $2}' || echo 0)"

echo "  OS       : $OS_NAME"
echo "  Kernel   : $KERNEL"
echo "  CPU      : $CPU"
echo "  RAM      : ${RAM_MB} MB"
echo "  Swap     : ${SWAP} MB（不修改）"
echo "  Python3  : 不需要"
echo

# ------------------------------------------------------------
# 2/8 扫描实际日志
# ------------------------------------------------------------

echo "[2/8] 扫描实际日志文件"

LOG_LIST="$TMPROOT/logs"

find /var/log -type f -size +0c -o -type f -size 0c 2>/dev/null |
while IFS= read -r f; do
    case "$f" in
        /var/log/journal/*)
            ;;
        *)
            printf '%s\n' "$f"
            ;;
    esac
done |
sort -u > "$LOG_LIST"

# journald 单独处理
JOURNAL_LIST="$TMPROOT/journals"
find /var/log/journal /run/log/journal \
    -type f \( -name '*.journal' -o -name '*.journal~' \) \
    2>/dev/null |
sort -u > "$JOURNAL_LIST"

LOG_COUNT="$(wc -l < "$LOG_LIST" | tr -d ' ')"
JOURNAL_COUNT="$(wc -l < "$JOURNAL_LIST" | tr -d ' ')"

echo "  找到 ${LOG_COUNT} 个普通日志文件"
echo "  找到 ${JOURNAL_COUNT} 个 journal 文件"
echo

# ------------------------------------------------------------
# 3/8 找到真实 logrotate 配置
# ------------------------------------------------------------

echo "[3/8] 精确检测 logrotate 控制关系"
echo

ROTATE_CONFIGS="$TMPROOT/rotate-configs"

{
    [ -f /etc/logrotate.conf ] && printf '%s\n' /etc/logrotate.conf

    if [ -d /etc/logrotate.d ]; then
        find /etc/logrotate.d -type f -readable 2>/dev/null
    fi
} | sort -u > "$ROTATE_CONFIGS"

ROTATE_CONFIG_COUNT="$(wc -l < "$ROTATE_CONFIGS" | tr -d ' ')"

echo "  找到 ${ROTATE_CONFIG_COUNT} 个真实 logrotate 配置文件"
echo

# ------------------------------------------------------------
# 解析一个配置文件中的 stanza
#
# 输出：
# START|END|PATTERN
#
# 支持：
# /var/log/a.log {
#
# /var/log/a.log /var/log/b.log {
#
# /var/log/*.log {
#
# ------------------------------------------------------------

parse_stanzas() {
    local file="$1"

    awk '
    function flush() {
        if (inblock && pattern != "") {
            print start "|" NR "|" pattern
        }
        inblock=0
        pattern=""
        start=0
    }

    /^[[:space:]]*#/ {
        next
    }

    /^[[:space:]]*$/ {
        next
    }

    {
        line=$0

        if (!inblock) {
            pos=index(line,"{")

            if (pos > 0) {
                left=substr(line,1,pos-1)
                gsub(/^[[:space:]]+/, "", left)
                gsub(/[[:space:]]+$/, "", left)

                if (left != "") {
                    inblock=1
                    start=NR
                    pattern=left
                }
            }
            next
        }

        if (line ~ /^[[:space:]]*}/) {
            print start "|" NR "|" pattern
            inblock=0
            pattern=""
            start=0
        }
    }

    END {
        if (inblock && pattern != "")
            print start "|" NR "|" pattern
    }
    ' "$file"
}

# ------------------------------------------------------------
# path matching
#
# 这里不直接用 grep。
# 使用 shell case 做 glob 匹配。
# 对绝对路径进行安全匹配。
# ------------------------------------------------------------

pattern_matches_path() {
    local pattern="$1"
    local path="$2"

    case "$path" in
        $pattern)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# 获取 stanza 内有效的大小条件
#
# 注意：
#   size
#   minsize
#   maxsize
#
# 这里返回配置中最后出现的对应指令。
#
# 输出：
# RULE|VALUE
# ------------------------------------------------------------

get_size_rule() {
    local file="$1"
    local start="$2"
    local end="$3"

    awk -v s="$start" -v e="$end" '
    NR >= s && NR <= e {
        line=$0

        sub(/^[[:space:]]+/, "", line)

        if (line ~ /^#/)
            next

        if (line ~ /^size[[:space:]]+/) {
            val=line
            sub(/^size[[:space:]]+/, "", val)
            sub(/[[:space:]]+#.*$/, "", val)
            size_rule="size"
            size_value=val
        }

        if (line ~ /^minsize[[:space:]]+/) {
            val=line
            sub(/^minsize[[:space:]]+/, "", val)
            sub(/[[:space:]]+#.*$/, "", val)
            min_rule="minsize"
            min_value=val
        }

        if (line ~ /^maxsize[[:space:]]+/) {
            val=line
            sub(/^maxsize[[:space:]]+/, "", val)
            sub(/[[:space:]]+#.*$/, "", val)
            max_rule="maxsize"
            max_value=val
        }
    }

    END {
        if (size_rule != "")
            print "size|" size_value
        else if (max_rule != "")
            print "maxsize|" max_value
        else if (min_rule != "")
            print "minsize|" min_value
        else
            print "none|"
    }
    ' "$file"
}

# ------------------------------------------------------------
# 字节转换
# ------------------------------------------------------------

size_to_bytes() {
    local v="$1"

    case "$v" in
        *K|*k)
            echo $(( ${v%[Kk]} * 1024 ))
            ;;
        *M|*m)
            echo $(( ${v%[Mm]} * 1024 * 1024 ))
            ;;
        *G|*g)
            echo $(( ${v%[Gg]} * 1024 * 1024 * 1024 ))
            ;;
        *T|*t)
            echo $(( ${v%[Tt]} * 1024 * 1024 * 1024 * 1024 ))
            ;;
        ''|*[!0-9]*)
            echo 0
            ;;
        *)
            echo "$v"
            ;;
    esac
}

# ------------------------------------------------------------
# 找到控制 stanza
# ------------------------------------------------------------

find_control_for_log() {
    local target="$1"
    local file
    local info
    local start
    local end
    local pattern
    local p
    local matched=0

    while IFS= read -r file; do

        while IFS='|' read -r start end pattern; do
            [ -n "$pattern" ] || continue

            for p in $pattern; do
                if pattern_matches_path "$p" "$target"; then

                    # 如果已经有控制关系，不接受第二个不同 stanza
                    if [ "$matched" -eq 1 ]; then
                        echo "AMBIGUOUS"
                        return 0
                    fi

                    matched=1
                    echo "${file}|${start}|${end}|${pattern}"
                fi
            done

        done < <(parse_stanzas "$file")

    done < "$ROTATE_CONFIGS"

    if [ "$matched" -eq 0 ]; then
        echo "NONE"
    fi
}

# ------------------------------------------------------------
# 类型/建议
# ------------------------------------------------------------

declare -A CONTROL_FILE
declare -A CONTROL_START
declare -A CONTROL_END
declare -A CONTROL_PATTERN
declare -A CURRENT_RULE
declare -A CURRENT_VALUE
declare -A RECOMMEND

CONTROL_COUNT=0
UNKNOWN_COUNT=0

while IFS= read -r log; do

    result="$(find_control_for_log "$log")"

    if [ "$result" = "NONE" ]; then
        UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
        continue
    fi

    if [ "$result" = "AMBIGUOUS" ]; then
        UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
        continue
    fi

    IFS='|' read -r cf cs ce cp <<EOF
$result
EOF

    CONTROL_FILE["$log"]="$cf"
    CONTROL_START["$log"]="$cs"
    CONTROL_END["$log"]="$ce"
    CONTROL_PATTERN["$log"]="$cp"

    rule="$(get_size_rule "$cf" "$cs" "$ce")"
    IFS='|' read -r rtype rval <<EOF
$rule
EOF

    CURRENT_RULE["$log"]="$rtype"
    CURRENT_VALUE["$log"]="$rval"

    rec="$(recommend_for_log "$log")"
    RECOMMEND["$log"]="$rec"

    CONTROL_COUNT=$((CONTROL_COUNT + 1))

done < "$LOG_LIST"

echo "  已识别明确控制关系：${CONTROL_COUNT}"
echo "  其余日志：未找到明确控制关系 / 存在歧义"
echo

# ------------------------------------------------------------
# 4/8 journald
# ------------------------------------------------------------

echo "[4/8] 检测 systemd-journald"

JOURNAL_CONF="/etc/systemd/journald.conf"

if [ -f "$JOURNAL_CONF" ]; then

    SYSTEM_LINE="$(grep -E '^[[:space:]]*SystemMaxFileSize[[:space:]]*=' "$JOURNAL_CONF" | tail -n 1 || true)"
    RUNTIME_LINE="$(grep -E '^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=' "$JOURNAL_CONF" | tail -n 1 || true)"

    SYSTEM_VALUE="$(printf '%s\n' "$SYSTEM_LINE" | sed -n 's/^[^=]*=[[:space:]]*//p')"
    RUNTIME_VALUE="$(printf '%s\n' "$RUNTIME_LINE" | sed -n 's/^[^=]*=[[:space:]]*//p')"

    [ -n "$SYSTEM_VALUE" ] || SYSTEM_VALUE="未设置"
    [ -n "$RUNTIME_VALUE" ] || RUNTIME_VALUE="未设置"

else
    SYSTEM_VALUE="不存在"
    RUNTIME_VALUE="不存在"
fi

echo "  persistent journal : $(grep -c '/var/log/journal' "$JOURNAL_LIST" 2>/dev/null || true)"
echo "  runtime journal    : $(grep -c '/run/log/journal' "$JOURNAL_LIST" 2>/dev/null || true)"
echo "  SystemMaxFileSize  : $SYSTEM_VALUE"
echo "  RuntimeMaxFileSize : $RUNTIME_VALUE"
echo

# ------------------------------------------------------------
# 5/8 所有日志及真实控制关系
# ------------------------------------------------------------

echo "[5/8] 所有日志及控制关系"
echo

printf "%-48s %-21s %-11s %-34s %-13s %-8s\n" \
"日志" "类型" "大小" "真实控制文件" "当前规则" "建议"

printf '%s\n' "---------------------------------------------------------------------------------------------------------------"

while IFS= read -r log; do

    bytes="$(stat -c '%s' "$log" 2>/dev/null || echo 0)"
    size="$(human_size "$bytes")"
    type="$(log_type "$log")"

    if [ -n "${CONTROL_FILE[$log]+x}" ]; then
        cf="${CONTROL_FILE[$log]}"
        rule="${CURRENT_RULE[$log]} ${CURRENT_VALUE[$log]}"
        rec="${RECOMMEND[$log]}"

        [ -n "$rec" ] || rec="跳过"

        printf "%-48s %-21s %-11s %-34s %-13s %-8s\n" \
        "$log" "$type" "$size" "$cf" "$rule" "$rec"
    else
        printf "%-48s %-21s %-11s %-34s %-13s %-8s\n" \
        "$log" "$type" "$size" "未找到" "未设置" "跳过"
    fi

done < "$LOG_LIST"

if [ "$JOURNAL_COUNT" -gt 0 ]; then
    while IFS= read -r journal; do
        bytes="$(stat -c '%s' "$journal" 2>/dev/null || echo 0)"
        size="$(human_size "$bytes")"

        printf "%-48s %-21s %-11s %-34s %-13s %-8s\n" \
        "$journal" "journald" "$size" "$JOURNAL_CONF" \
        "journal" "8M"
    done < "$JOURNAL_LIST"
fi

echo

# ------------------------------------------------------------
# 6/8 修改建议
# ------------------------------------------------------------

echo "[6/8] 修改建议"
echo
echo "建议依据：日志用途，而不是当前文件大小。"
echo
echo "logrotate 规则说明："
echo "  size    → 按大小触发轮转"
echo "  maxsize → 在时间轮转条件存在时增加大小触发条件"
echo "  minsize → 只有达到大小且满足时间条件时才轮转"
echo
echo "因此："
echo "  ✓ 已存在合理 size → 不强制改成 maxsize"
echo "  ✓ 已存在合理 maxsize → 不修改"
echo "  ✓ 未设置大小条件 → 才考虑添加 maxsize"
echo "  ✓ 控制关系不明确 → 跳过"
echo

CHANGE_COUNT=0

for log in "${!CONTROL_FILE[@]}"; do

    rec="${RECOMMEND[$log]}"

    [ -n "$rec" ] || continue

    cf="${CONTROL_FILE[$log]}"
    cs="${CONTROL_START[$log]}"
    ce="${CONTROL_END[$log]}"
    cp="${CONTROL_PATTERN[$log]}"

    cr="${CURRENT_RULE[$log]}"
    cv="${CURRENT_VALUE[$log]}"

    action=""

    if [ "$cr" = "none" ]; then
        action="添加 maxsize $rec"
    elif [ "$cr" = "maxsize" ]; then
        if [ "$cv" = "$rec" ]; then
            action="无需修改"
        else
            action="调整 maxsize $cv → $rec"
        fi
    elif [ "$cr" = "size" ]; then
        # 已经有 size 时不强制转换
        action="保持现有 size $cv"
    elif [ "$cr" = "minsize" ]; then
        action="保持现有 minsize $cv（不强制覆盖）"
    fi

    echo "日志       : $log"
    echo "类型       : $(log_type "$log")"
    echo "控制文件   : $cf"
    echo "stanza     : ${cs}-${ce}"
    echo "匹配规则   : $cp"
    echo "当前规则   : ${cr} ${cv}"
    echo "处理建议   : $action"
    echo

    case "$action" in
        添加*|调整*)
            CHANGE_COUNT=$((CHANGE_COUNT + 1))
            ;;
    esac

done

# journald
JOURNAL_CHANGE=0

if [ -f "$JOURNAL_CONF" ]; then

    if [ "$SYSTEM_VALUE" != "8M" ]; then
        JOURNAL_CHANGE=1
    fi

    if [ "$RUNTIME_VALUE" != "8M" ]; then
        JOURNAL_CHANGE=1
    fi

fi

echo "journald："

if [ -f "$JOURNAL_CONF" ]; then
    echo "  控制文件          : $JOURNAL_CONF"
    echo "  SystemMaxFileSize  : $SYSTEM_VALUE → 8M"
    echo "  RuntimeMaxFileSize : $RUNTIME_VALUE → 8M"
else
    echo "  /etc/systemd/journald.conf 不存在 → 跳过"
fi

echo

# ------------------------------------------------------------
# 7/8 安全确认
# ------------------------------------------------------------

echo "[7/8] 修改原则"
echo
echo "  ✓ 只修改真实存在的 logrotate 配置"
echo "  ✓ 只修改真实匹配目标日志的 stanza"
echo "  ✓ 已有合理 size 不转换"
echo "  ✓ 已有合理 maxsize 不重复添加"
echo "  ✓ 不修改无法确认控制关系的日志"
echo "  ✓ 不创建任何配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除当前日志"
echo "  ✓ 不使用 Python3"
echo

echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo
echo "本次准备修改："
echo "  logrotate：${CHANGE_COUNT} 个 stanza"
echo "  journald ：${JOURNAL_CHANGE} 项"
echo

if [ "$CHANGE_COUNT" -eq 0 ] && [ "$JOURNAL_CHANGE" -eq 0 ]; then
    echo "没有需要修改的配置。"
    echo
    echo "审计完成，系统无需修改。"
    exit 0
fi

echo "⚠ 不创建任何配置文件"
echo "⚠ 不备份"
echo "⚠ 不删除现有日志"
echo

read -r -p "确认执行精准修改？[y/N] " ANSWER

case "$ANSWER" in
    y|Y|yes|YES)
        ;;
    *)
        echo
        echo "已取消，没有修改任何配置。"
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 修改前做语法验证
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                       修改前验证"
echo "============================================================"

if ! logrotate -d -s "$TMPROOT/status-before" /etc/logrotate.conf \
        >"$TMPROOT/logrotate-before.out" 2>&1; then

    echo
    echo "✗ 修改前 logrotate 配置检查失败"
    echo
    cat "$TMPROOT/logrotate-before.out"
    exit 1
fi

echo "✓ 修改前 logrotate 配置语法正常"

# ------------------------------------------------------------
# 精确修改函数
#
# 只在指定 stanza 内操作。
#
# 添加：
#   在 { 后的第一条配置前插入 maxsize
#
# 修改：
#   只修改 stanza 内现有 maxsize
#
# 不碰其他 stanza。
# ------------------------------------------------------------

modify_stanza() {
    local file="$1"
    local start="$2"
    local end="$3"
    local target="$4"
    local wanted="$5"

    local tmp="$TMPROOT/modify.$$.tmp"
    local result

    awk \
        -v s="$start" \
        -v e="$end" \
        -v wanted="$wanted" '
    BEGIN {
        changed=0
        inside=0
    }

    NR < s {
        print
        next
    }

    NR > e {
        print
        next
    }

    {
        line=$0

        if (NR == s) {
            print line
            next
        }

        # 只处理 stanza 内
        if (line ~ /^[[:space:]]*maxsize[[:space:]]+/) {
            sub(/^[[:space:]]*maxsize[[:space:]]+.*/, "    maxsize " wanted, line)
            print line
            changed=1
            next
        }

        print line
    }

    END {
        if (changed == 0)
            exit 10
    }
    ' "$file" > "$tmp"

    result=$?

    if [ "$result" -eq 0 ]; then
        cat "$tmp" > "$file"
        rm -f "$tmp"
        return 0
    fi

    rm -f "$tmp"

    # 没有 maxsize → 在 stanza 开始后的下一行插入
    awk \
        -v s="$start" \
        -v e="$end" \
        -v wanted="$wanted" '
    NR == s {
        print
        inserted=0
        next
    }

    NR > s && NR <= e && inserted == 0 {
        if ($0 ~ /^[[:space:]]*$/)
            print
        else {
            print "    maxsize " wanted
            print
            inserted=1
        }
        next
    }

    {
        print
    }

    END {
        if (inserted == 0)
            exit 11
    }
    ' "$file" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    cat "$tmp" > "$file"
    rm -f "$tmp"

    return 0
}

# ------------------------------------------------------------
# 修改 logrotate
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                         开始修改"
echo "============================================================"
echo

MODIFIED_FILES="$TMPROOT/modified-files"
: > "$MODIFIED_FILES"

for log in "${!CONTROL_FILE[@]}"; do

    rec="${RECOMMEND[$log]}"
    [ -n "$rec" ] || continue

    cf="${CONTROL_FILE[$log]}"
    cs="${CONTROL_START[$log]}"
    ce="${CONTROL_END[$log]}"

    cr="${CURRENT_RULE[$log]}"
    cv="${CURRENT_VALUE[$log]}"

    case "$cr" in

        none)
            echo "修改：$cf"
            echo "  日志   : $log"
            echo "  stanza : ${cs}-${ce}"
            echo "  目标   : maxsize $rec"

            if modify_stanza "$cf" "$cs" "$ce" "$log" "$rec"; then
                echo "✓ $log → maxsize $rec"
                printf '%s\n' "$cf" >> "$MODIFIED_FILES"
            else
                echo "✗ $log → 修改失败"
            fi
            echo
            ;;

        maxsize)
            if [ "$cv" != "$rec" ]; then

                echo "修改：$cf"
                echo "  日志   : $log"
                echo "  stanza : ${cs}-${ce}"
                echo "  目标   : maxsize $rec"

                if modify_stanza "$cf" "$cs" "$ce" "$log" "$rec"; then
                    echo "✓ $log → maxsize $rec"
                    printf '%s\n' "$cf" >> "$MODIFIED_FILES"
                else
                    echo "✗ $log → 修改失败"
                fi
                echo
            else
                echo "✓ $log → 已经是 maxsize $rec，无需修改"
                echo
            fi
            ;;

        size)
            echo "✓ $log → 已存在 size $cv，不转换"
            echo
            ;;

        minsize)
            echo "✓ $log → 已存在 minsize $cv，不覆盖"
            echo
            ;;

    esac

done

# ------------------------------------------------------------
# journald 修改
# ------------------------------------------------------------

if [ "$JOURNAL_CHANGE" -eq 1 ] && [ -f "$JOURNAL_CONF" ]; then

    echo "修改：$JOURNAL_CONF"

    JOURNAL_TMP="$TMPROOT/journald.conf"

    awk '
    BEGIN {
        system_seen=0
        runtime_seen=0
    }

    /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/ {
        if (system_seen == 0) {
            print "SystemMaxFileSize=8M"
            system_seen=1
        }
        next
    }

    /^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/ {
        if (runtime_seen == 0) {
            print "RuntimeMaxFileSize=8M"
            runtime_seen=1
        }
        next
    }

    {
        print
    }

    END {
        if (system_seen == 0)
            print "SystemMaxFileSize=8M"

        if (runtime_seen == 0)
            print "RuntimeMaxFileSize=8M"
    }
    ' "$JOURNAL_CONF" > "$JOURNAL_TMP"

    if cmp -s "$JOURNAL_TMP" "$JOURNAL_CONF"; then
        echo "✓ journald 无需修改"
    else
        cat "$JOURNAL_TMP" > "$JOURNAL_CONF"
        echo "✓ SystemMaxFileSize=8M"
        echo "✓ RuntimeMaxFileSize=8M"
    fi

    echo
fi

# ------------------------------------------------------------
# 8/8 修改后验证
# ------------------------------------------------------------

echo
echo "[8/8] 修改后验证"
echo

echo "------------------------------------------------------------"
echo "                     验证 logrotate"
echo "------------------------------------------------------------"

if ! logrotate -d -s "$TMPROOT/status-after" /etc/logrotate.conf \
        >"$TMPROOT/logrotate-after.out" 2>&1; then

    echo "✗ logrotate 配置验证失败"
    echo
    cat "$TMPROOT/logrotate-after.out"
    exit 1
fi

echo "✓ logrotate 配置语法正常"
echo

# ------------------------------------------------------------
# 重新读取 stanza
#
# 这是本版最重要的验证：
#
# 不再相信修改函数自己的输出。
# 不再 grep 整个配置文件。
#
# 重新从磁盘解析目标 stanza。
# ------------------------------------------------------------

echo "------------------------------------------------------------"
echo "                 精确重新解析控制 stanza"
echo "------------------------------------------------------------"

VERIFY_FAIL=0

for log in "${!CONTROL_FILE[@]}"; do

    rec="${RECOMMEND[$log]}"
    [ -n "$rec" ] || continue

    cf="${CONTROL_FILE[$log]}"
    old_start="${CONTROL_START[$log]}"
    old_end="${CONTROL_END[$log]}"

    # 重新扫描文件
    found=""

    while IFS= read -r info; do

        IFS='|' read -r vs ve vp <<EOF
$info
EOF

        for p in $vp; do
            if pattern_matches_path "$p" "$log"; then
                found="${vs}|${ve}|${vp}"
                break
            fi
        done

        [ -n "$found" ] && break

    done < <(parse_stanzas "$cf")

    if [ -z "$found" ]; then
        echo "✗ $log : 修改后无法重新找到原控制 stanza"
        VERIFY_FAIL=1
        continue
    fi

    IFS='|' read -r vs ve vp <<EOF
$found
EOF

    rule="$(get_size_rule "$cf" "$vs" "$ve")"
    IFS='|' read -r vrule vvalue <<EOF
$rule
EOF

    original_rule="${CURRENT_RULE[$log]}"
    original_value="${CURRENT_VALUE[$log]}"

    case "$original_rule" in

        none)
            if [ "$vrule" = "maxsize" ] && [ "$vvalue" = "$rec" ]; then
                echo "✓ $log : maxsize $vvalue"
            else
                echo "✗ $log : 期望 maxsize $rec，实际 ${vrule} ${vvalue}"
                VERIFY_FAIL=1
            fi
            ;;

        maxsize)
            if [ "$vvalue" = "$rec" ]; then
                echo "✓ $log : maxsize $vvalue"
            else
                echo "✗ $log : 期望 maxsize $rec，实际 ${vrule} ${vvalue}"
                VERIFY_FAIL=1
            fi
            ;;

        size)
            if [ "$vvalue" = "$original_value" ]; then
                echo "✓ $log : 保持原有 size $vvalue"
            else
                echo "✗ $log : 原 size $original_value 被意外改变为 ${vrule} ${vvalue}"
                VERIFY_FAIL=1
            fi
            ;;

        minsize)
            if [ "$vvalue" = "$original_value" ]; then
                echo "✓ $log : 保持原有 minsize $vvalue"
            else
                echo "✗ $log : 原 minsize $original_value 被意外改变"
                VERIFY_FAIL=1
            fi
            ;;

    esac

done

echo
echo "------------------------------------------------------------"
echo "                    验证 systemd-journald"
echo "------------------------------------------------------------"

if [ -f "$JOURNAL_CONF" ]; then

    SYSTEM_VERIFY="$(grep -E '^[[:space:]]*SystemMaxFileSize[[:space:]]*=' "$JOURNAL_CONF" |
        tail -n 1 |
        sed -n 's/^[^=]*=[[:space:]]*//p')"

    RUNTIME_VERIFY="$(grep -E '^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=' "$JOURNAL_CONF" |
        tail -n 1 |
        sed -n 's/^[^=]*=[[:space:]]*//p')"

    if [ "$SYSTEM_VERIFY" = "8M" ]; then
        echo "✓ SystemMaxFileSize = 8M"
    else
        echo "✗ SystemMaxFileSize = ${SYSTEM_VERIFY:-未设置}"
        VERIFY_FAIL=1
    fi

    if [ "$RUNTIME_VERIFY" = "8M" ]; then
        echo "✓ RuntimeMaxFileSize = 8M"
    else
        echo "✗ RuntimeMaxFileSize = ${RUNTIME_VERIFY:-未设置}"
        VERIFY_FAIL=1
    fi

else
    echo "✓ journald 配置文件不存在，未修改"
fi

echo
echo "------------------------------------------------------------"
echo "                    最终控制关系"
echo "------------------------------------------------------------"

while IFS= read -r log; do

    if [ -n "${CONTROL_FILE[$log]+x}" ]; then

        cf="${CONTROL_FILE[$log]}"
        cs="${CONTROL_START[$log]}"
        ce="${CONTROL_END[$log]}"
        cp="${CONTROL_PATTERN[$log]}"

        rule="$(get_size_rule "$cf" "$cs" "$ce")"
        IFS='|' read -r rr rv <<EOF
$rule
EOF

        echo "$log"
        echo "  类型     : $(log_type "$log")"
        echo "  控制文件 : $cf"
        echo "  stanza   : ${cs}-${ce}"
        echo "  匹配规则 : $cp"
        echo "  大小规则 : ${rr} ${rv}"
        echo

    else

        echo "$log"
        echo "  类型     : $(log_type "$log")"
        echo "  控制文件 : 未找到明确控制关系"
        echo "  状态     : 跳过"
        echo

    fi

done < "$LOG_LIST"

echo "journald："
echo "  控制文件           : $JOURNAL_CONF"
echo "  SystemMaxFileSize   : ${SYSTEM_VERIFY:-$SYSTEM_VALUE}"
echo "  RuntimeMaxFileSize  : ${RUNTIME_VERIFY:-$RUNTIME_VALUE}"
echo

echo "============================================================"

if [ "$VERIFY_FAIL" -eq 0 ]; then
    echo "                         完成"
    echo "============================================================"
    echo
    echo "✓ 所有修改均通过重新解析验证"
    echo "✓ logrotate 配置语法正常"
    echo "✓ 控制关系未被破坏"
    echo "✓ 未创建任何配置文件"
    echo "✓ 未备份"
    echo "✓ 未删除任何日志"
    echo
    exit 0
else
    echo "                         验证失败"
    echo "============================================================"
    echo
    echo "⚠ 存在验证失败项目，请不要忽略。"
    echo
    exit 2
fi
