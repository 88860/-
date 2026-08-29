#!/bin/bash

set -u
export LC_ALL=C

# ============================================================
# Debian 13 日志大小审计与精准限制
# 扫描 → 识别 → 分类 → 建议 → 确认 → 修改 → 验证
#
# 规则：
#   - 普通日志：按用途设置 1M–10M
#   - journald：单文件 8M
#   - 只修改真实存在且确认控制目标的配置
#   - 不创建配置文件
#   - 不备份
#   - 不删除现有日志
#   - 不安装软件
# ============================================================

TARGET_MIN=1
JOURNAL_MAX=8

LOGROTATE_MAIN="/etc/logrotate.conf"
LOGROTATE_DIR="/etc/logrotate.d"
JOURNALD_CONF="/etc/systemd/journald.conf"

TMPROOT="$(mktemp -d /tmp/log-audit.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

LOG_LIST="$TMPROOT/logs"
STANZAS="$TMPROOT/stanzas"
PLAN="$TMPROOT/plan"

: > "$LOG_LIST"
: > "$STANZAS"
: > "$PLAN"

# ------------------------------------------------------------
# 基础函数
# ------------------------------------------------------------

die() {
    echo "错误：$*"
    exit 1
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少 $1"
}

size_human() {
    local f="$1"
    local s

    s=$(stat -c '%s' "$f" 2>/dev/null || echo 0)

    if [ "$s" -ge 1073741824 ]; then
        awk -v x="$s" 'BEGIN{printf "%.2fG",x/1073741824}'
    elif [ "$s" -ge 1048576 ]; then
        awk -v x="$s" 'BEGIN{printf "%.2fM",x/1048576}'
    elif [ "$s" -ge 1024 ]; then
        awk -v x="$s" 'BEGIN{printf "%.2fK",x/1024}'
    else
        echo "${s}B"
    fi
}

get_bytes() {
    stat -c '%s' "$1" 2>/dev/null || echo 0
}

is_regular_log() {
    local f="$1"

    [ -f "$f" ] || return 1

    case "$f" in
        *.journal|*.journal~)
            return 1
            ;;
        /var/log/journal/*)
            return 1
            ;;
        /run/log/journal/*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ------------------------------------------------------------
# 1. 基础检测
# ------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"

for c in bash awk sed grep find stat systemctl logrotate; do
    need_cmd "$c"
done

[ -f /etc/os-release ] || die "无法读取 /etc/os-release"

. /etc/os-release

case "${ID:-}" in
    debian) ;;
    *)
        echo "警告：当前系统不是 Debian，继续执行前请确认。"
        ;;
esac

section "Debian 日志大小审计与精准限制"

echo "目标："
echo "  普通日志：按用途设置 1M–10M"
echo "  journald ：单个 journal 文件 8M"
echo
echo "原则："
echo "  ✓ 只修改真实存在的控制配置"
echo "  ✓ 必须确认配置实际控制目标日志"
echo "  ✓ 精确修改对应 stanza"
echo "  ✓ 不创建任何配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除现有日志"
echo "  ✓ 不安装软件"
echo "  ✓ 控制关系无法确认 → 跳过"

section "[1/8] 系统检测"

echo "  OS       : ${PRETTY_NAME:-unknown}"
echo "  Kernel   : $(uname -r)"

if [ -d /var/log ]; then
    echo "  /var/log : $(du -sh /var/log 2>/dev/null | awk '{print $1}')"
else
    echo "  /var/log : 不存在"
fi

if [ -d /run/log ]; then
    echo "  /run/log : $(du -sh /run/log 2>/dev/null | awk '{print $1}')"
else
    echo "  /run/log : 不存在"
fi

# ------------------------------------------------------------
# 2. 扫描日志
# ------------------------------------------------------------

section "[2/8] 扫描实际日志文件"

find /var/log -type f -print0 2>/dev/null |
while IFS= read -r -d '' f; do
    if is_regular_log "$f"; then
        printf '%s\n' "$f"
    fi
done | sort > "$LOG_LIST"

LOG_COUNT=$(wc -l < "$LOG_LIST")

echo "  找到 $LOG_COUNT 个普通日志文件"

# ------------------------------------------------------------
# 3. 解析 logrotate
#
# 每个 stanza 保存：
#   文件
#   起始行
#   结束行
#   匹配 pattern
# ------------------------------------------------------------

section "[3/8] 精确解析 logrotate 控制关系"

: > "$STANZAS"

parse_logrotate_file() {
    local file="$1"

    [ -f "$file" ] || return 0

    awk -v FILE="$file" '
    function trim(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
    }

    function flush_stanza(    i) {
        if (start == 0 || count == 0)
            return

        for (i = 1; i <= count; i++) {
            printf "%s\t%d\t%d\t%s\n",
                FILE, start, end, paths[i]
        }

        delete paths
        count = 0
        start = 0
        end = 0
    }

    {
        raw=$0
        line=$0

        # 去掉注释
        sub(/[[:space:]]*#.*/, "", line)
        line=trim(line)

        if (line == "")
            next

        # include 不属于 stanza
        if (line ~ /^include[[:space:]]+/)
            next

        # 新 stanza：必须以 { 结束
        if (line ~ /^[^{}]+[[:space:]]*\{[[:space:]]*$/) {
            flush_stanza()

            start=NR

            p=line
            sub(/[[:space:]]*\{[[:space:]]*$/, "", p)
            p=trim(p)

            # 多个日志路径
            n=split(p,a,/[[:space:]]+/)

            count=0

            for (i=1; i<=n; i++) {
                if (a[i] != "")
                    paths[++count]=a[i]
            }

            next
        }

        if (start > 0) {
            end=NR

            if (line == "}") {
                flush_stanza()
            }
        }
    }

    END {
        flush_stanza()
    }
    ' "$file" >> "$STANZAS"
}

parse_logrotate_file "$LOGROTATE_MAIN"

if [ -d "$LOGROTATE_DIR" ]; then
    find "$LOGROTATE_DIR" -maxdepth 1 -type f -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
        parse_logrotate_file "$f"
    done
fi

# ------------------------------------------------------------
# 处理 logrotate include / glob 的实际关系
# ------------------------------------------------------------

# 当前 Debian 默认 /etc/logrotate.conf 通常 include /etc/logrotate.d
# 这里不把 include 文件本身当作日志 stanza。
#
# STANZAS 格式：
# file<TAB>start<TAB>end<TAB>pattern

STANZA_COUNT=$(wc -l < "$STANZAS")

echo
echo "  解析到 $STANZA_COUNT 个日志 stanza"

# ------------------------------------------------------------
# glob 匹配辅助
# ------------------------------------------------------------

glob_match() {
    local pattern="$1"
    local path="$2"

    # 处理 logrotate 常见路径 glob
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
# 判断 stanza 是否真的控制目标
#
# 只接受：
#   1. 精确路径
#   2. shell glob 实际匹配目标
#
# 不接受：
#   - basename 推测
#   - 配置文件名称推测
#   - 仅仅同目录推测
# ------------------------------------------------------------

find_controller() {
    local target="$1"
    local result

    result=$(
        while IFS=$'\t' read -r file start end pattern; do

            [ -n "$file" ] || continue

            # 去除可能的引号
            pattern="${pattern#\"}"
            pattern="${pattern%\"}"
            pattern="${pattern#\'}"
            pattern="${pattern%\'}"

            if glob_match "$pattern" "$target"; then
                printf '%s\t%s\t%s\t%s\n' \
                    "$file" "$start" "$end" "$pattern"
            fi

        done < "$STANZAS"
    )

    printf '%s\n' "$result"
}

# ------------------------------------------------------------
# 分类
# ------------------------------------------------------------

classify_log() {
    local f="$1"

    case "$f" in
        /var/log/dpkg.log)
            echo "dpkg"
            ;;
        /var/log/alternatives.log)
            echo "alternatives"
            ;;
        /var/log/apt/history.log)
            echo "apt-history"
            ;;
        /var/log/apt/term.log)
            echo "apt-terminal"
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
        /var/log/auth.log|/var/log/auth.log.*)
            echo "authentication"
            ;;
        /var/log/syslog|/var/log/syslog.*)
            echo "system"
            ;;
        /var/log/kern.log|/var/log/kern.log.*)
            echo "kernel"
            ;;
        /var/log/daemon.log|/var/log/daemon.log.*)
            echo "daemon"
            ;;
        /var/log/debug|/var/log/debug.*)
            echo "debug"
            ;;
        /var/log/messages|/var/log/messages.*)
            echo "messages"
            ;;
        /var/log/mail.log|/var/log/mail.log.*)
            echo "mail"
            ;;
        /var/log/mail.err|/var/log/mail.err.*)
            echo "mail-error"
            ;;
        /var/log/mail.warn|/var/log/mail.warn.*)
            echo "mail-warning"
            ;;
        /var/log/user.log|/var/log/user.log.*)
            echo "user"
            ;;
        /var/log/faillog)
            echo "failed-login"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# ------------------------------------------------------------
# 根据日志用途确定建议
#
# 注意：
# 不是根据当前文件大小决定。
# ------------------------------------------------------------

recommend_size() {
    local type="$1"

    case "$type" in
        alternatives)
            echo "2"
            ;;
        apt-history)
            echo "3"
            ;;
        apt-terminal)
            echo "5"
            ;;
        dpkg)
            echo "5"
            ;;
        failed-login-history)
            echo "5"
            ;;
        login-history)
            echo "5"
            ;;
        authentication)
            echo "10"
            ;;
        system)
            echo "10"
            ;;
        kernel)
            echo "10"
            ;;
        daemon)
            echo "10"
            ;;
        messages)
            echo "10"
            ;;
        mail)
            echo "10"
            ;;
        mail-error)
            echo "5"
            ;;
        mail-warning)
            echo "5"
            ;;
        user)
            echo "5"
            ;;
        failed-login)
            echo "5"
            ;;
        lastlog)
            echo "5"
            ;;
        *)
            echo "0"
            ;;
    esac
}

# ------------------------------------------------------------
# 读取 stanza 内当前限制
# ------------------------------------------------------------

get_stanza_option() {
    local file="$1"
    local start="$2"
    local end="$3"
    local option="$4"

    sed -n "${start},${end}p" "$file" |
        sed 's/[[:space:]]*#.*$//' |
        awk -v opt="$option" '
        $1 == opt {
            print $2
            exit
        }
        '
}

# ------------------------------------------------------------
# 建立审计结果
# 格式：
# log
# type
# size
# controller
# start
# end
# pattern
# current
# recommendation
# ------------------------------------------------------------

RESULTS="$TMPROOT/results"
: > "$RESULTS"

section "[4/8] 检测日志实际控制关系"

FOUND=0
UNKNOWN=0
JOURNAL_COUNT=0

while IFS= read -r log; do

    type=$(classify_log "$log")
    size=$(size_human "$log")
    rec=$(recommend_size "$type")

    controller=$(find_controller "$log")

    if [ -n "$controller" ]; then

        # 一个日志理论上可能匹配多个 stanza。
        # 只有唯一明确控制关系才自动进入修改计划。
        matches=$(printf '%s\n' "$controller" | sed '/^$/d' | wc -l)

        if [ "$matches" -eq 1 ]; then

            IFS=$'\t' read -r cfile start end pattern <<EOF
$controller
EOF

            current=$(get_stanza_option \
                "$cfile" "$start" "$end" "maxsize")

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$log" \
                "$type" \
                "$size" \
                "$cfile" \
                "$start" \
                "$end" \
                "$pattern" \
                "${current:-未设置}" \
                "$rec" >> "$RESULTS"

            FOUND=$((FOUND + 1))

        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$log" \
                "$type" \
                "$size" \
                "多个匹配" \
                "-" \
                "-" \
                "-" \
                "无法唯一确认" \
                "跳过" >> "$RESULTS"

            UNKNOWN=$((UNKNOWN + 1))
        fi

    else

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$log" \
            "$type" \
            "$size" \
            "未找到" \
            "-" \
            "-" \
            "-" \
            "未设置" \
            "跳过" >> "$RESULTS"

        UNKNOWN=$((UNKNOWN + 1))
    fi

done < "$LOG_LIST"

echo
echo "  已确认唯一控制关系：$FOUND"
echo "  未确认控制关系    ：$UNKNOWN"

# ------------------------------------------------------------
# journald
# ------------------------------------------------------------

section "[5/8] 检测 systemd-journald"

PERSISTENT_JOURNAL=0
RUNTIME_JOURNAL=0

if [ -d /var/log/journal ]; then
    PERSISTENT_JOURNAL=$(find /var/log/journal \
        -type f \( -name '*.journal' -o -name '*.journal~' \) \
        2>/dev/null | wc -l)
fi

if [ -d /run/log/journal ]; then
    RUNTIME_JOURNAL=$(find /run/log/journal \
        -type f \( -name '*.journal' -o -name '*.journal~' \) \
        2>/dev/null | wc -l)
fi

echo "  persistent journal : $PERSISTENT_JOURNAL"
echo "  runtime journal    : $RUNTIME_JOURNAL"

J_SYSTEM=""
J_RUNTIME=""

if [ -f "$JOURNALD_CONF" ]; then

    J_SYSTEM=$(
        sed 's/[[:space:]]*#.*$//' "$JOURNALD_CONF" |
        awk '
        $1 ~ /^SystemMaxFileSize=/ {
            sub(/^SystemMaxFileSize=/,"",$1)
            print $1
            exit
        }
        '
    )

    J_RUNTIME=$(
        sed 's/[[:space:]]*#.*$//' "$JOURNALD_CONF" |
        awk '
        $1 ~ /^RuntimeMaxFileSize=/ {
            sub(/^RuntimeMaxFileSize=/,"",$1)
            print $1
            exit
        }
        '
    )

    echo "  配置文件          : $JOURNALD_CONF"
    echo "  SystemMaxFileSize  : ${J_SYSTEM:-未设置}"
    echo "  RuntimeMaxFileSize : ${J_RUNTIME:-未设置}"

else

    echo "  配置文件          : 不存在"
    echo "  SystemMaxFileSize  : 跳过"
    echo "  RuntimeMaxFileSize : 跳过"
fi

# ------------------------------------------------------------
# 所有日志关系表
# ------------------------------------------------------------

section "[6/8] 所有日志及控制关系"

printf "%-42s %-20s %-10s %-34s %-10s %-8s\n" \
    "日志" "类型" "大小" "真实控制文件" "当前限制" "建议"

printf '%*s\n' 130 '' | tr ' ' '-'

while IFS=$'\t' read -r \
    log type size controller start end pattern current rec; do

    [ -n "$log" ] || continue

    printf "%-42s %-20s %-10s %-34s %-10s %-8s\n" \
        "$log" \
        "$type" \
        "$size" \
        "$controller" \
        "$current" \
        "${rec:-跳过}"

done < "$RESULTS"

# ------------------------------------------------------------
# 建立最终修改计划
#
# 重要：
#   当前 maxsize 已存在时：
#       - 如果已经 <= 建议值 → 不修改
#       - 如果 > 建议值 → 修改
#   未设置 → 添加
#
# maxsize 只是轮转触发条件，不是硬性截断。
# ------------------------------------------------------------

: > "$PLAN"

needs_change() {
    local current="$1"
    local target="$2"

    [ "$current" = "未设置" ] && return 0

    # 只处理 M / K / G 等常见单位
    case "$current" in
        *M)
            cur="${current%M}"
            ;;
        *m)
            cur="${current%m}"
            ;;
        *K|*k|*G|*g)
            # 简单处理：存在不同单位时交给 awk
            echo "$current $target" >/dev/null
            return 0
            ;;
        *)
            return 0
            ;;
    esac

    awk -v c="$cur" -v t="$target" '
        BEGIN {
            if ((c+0) > (t+0)) exit 0
            exit 1
        }
    '
}

section "[7/8] 修改建议"

PLAN_COUNT=0

while IFS=$'\t' read -r \
    log type size controller start end pattern current rec; do

    [ -n "$log" ] || continue

    [ "$rec" != "0" ] || continue
    [ "$rec" != "跳过" ] || continue

    if [ "$controller" = "未找到" ]; then
        continue
    fi

    if [ "$controller" = "多个匹配" ]; then
        continue
    fi

    if needs_change "$current" "$rec"; then

        echo
        echo "[$((PLAN_COUNT + 1))]"
        echo "  日志       : $log"
        echo "  类型       : $type"
        echo "  控制文件   : $controller"
        echo "  stanza     : $start-$end"
        echo "  匹配规则   : $pattern"
        echo "  当前限制   : $current"
        echo "  修改目标   : maxsize ${rec}M"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$log" \
            "$type" \
            "$controller" \
            "$start" \
            "$end" \
            "$pattern" \
            "$current" \
            "$rec" \
            "change" >> "$PLAN"

        PLAN_COUNT=$((PLAN_COUNT + 1))
    fi

done < "$RESULTS"

# journald 是否修改
J_PLAN=0

if [ -f "$JOURNALD_CONF" ]; then

    if [ -z "$J_SYSTEM" ]; then
        J_PLAN=1
    elif [ "$J_SYSTEM" != "8M" ] && [ "$J_SYSTEM" != "8m" ]; then
        J_PLAN=1
    fi

    if [ -z "$J_RUNTIME" ]; then
        J_PLAN=1
    elif [ "$J_RUNTIME" != "8M" ] && [ "$J_RUNTIME" != "8m" ]; then
        J_PLAN=1
    fi
fi

echo
echo "------------------------------------------------------------"
echo "修改计划"
echo "------------------------------------------------------------"
echo "  logrotate stanza : $PLAN_COUNT"

if [ "$J_PLAN" -eq 1 ]; then
    echo "  journald         : /etc/systemd/journald.conf → 8M"
else
    echo "  journald         : 无需修改"
fi

echo
echo "跳过规则："
echo "  ✓ 没有明确控制关系 → 跳过"
echo "  ✓ 多个 stanza 同时匹配 → 跳过"
echo "  ✓ 未知日志类型 → 跳过"
echo "  ✓ 不创建配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除日志"

TOTAL_PLAN=$((PLAN_COUNT + J_PLAN))

if [ "$TOTAL_PLAN" -eq 0 ]; then
    echo
    echo "没有需要修改的配置。"
    exit 0
fi

# ------------------------------------------------------------
# 确认
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo
echo "本次准备修改："

if [ "$PLAN_COUNT" -gt 0 ]; then
    echo "  $PLAN_COUNT 个 logrotate stanza"
fi

if [ "$J_PLAN" -eq 1 ]; then
    echo "  journald：/etc/systemd/journald.conf"
fi

echo
echo "⚠ 不创建配置文件"
echo "⚠ 不备份"
echo "⚠ 不删除现有日志"
echo "⚠ 不执行 logrotate -f"
echo

printf "确认执行精准修改？[y/N] "
read -r answer

case "$answer" in
    y|Y|yes|YES)
        ;;
    *)
        echo "已取消，没有修改任何配置。"
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 修改 logrotate
# ------------------------------------------------------------

section "开始修改"

modify_stanza() {
    local file="$1"
    local start="$2"
    local end="$3"
    local target="$4"

    awk -v s="$start" -v e="$end" -v target="$target" '
    NR == s {
        in_stanza=1
    }

    in_stanza {
        line=$0

        # 如果已经有 maxsize，精准替换
        stripped=line
        sub(/^[[:space:]]+/, "", stripped)

        if (stripped ~ /^maxsize[[:space:]]+/) {
            indent=line
            sub(/[^[:space:]].*$/, "", indent)
            print indent "maxsize " target "M"
            replaced=1
            next
        }

        if (NR == e && line ~ /^[[:space:]]*}[[:space:]]*$/ && !replaced) {
            print "    maxsize " target "M"
        }

        print

        if (NR == e) {
            in_stanza=0
        }

        next
    }

    {
        print
    }
    ' "$file" > "$TMPROOT/modified"

    cat "$TMPROOT/modified" > "$file"
}

while IFS=$'\t' read -r \
    log type controller start end pattern current target action; do

    [ "$action" = "change" ] || continue

    # 再次确认文件仍然存在
    [ -f "$controller" ] || {
        echo "✗ 控制文件消失：$controller"
        continue
    }

    # 再次确认 stanza 中仍然存在目标 pattern
    actual_pattern=$(
        awk -v s="$start" -v e="$end" '
        NR >= s && NR <= e {print}
        ' "$controller" |
        grep -F -- "$pattern" | head -n 1
    )

    if [ -z "$actual_pattern" ]; then
        echo "✗ 二次验证失败，跳过：$log"
        continue
    fi

    modify_stanza "$controller" "$start" "$end" "$target"

    echo "✓ $controller"
    echo "  $log → maxsize ${target}M"

done < "$PLAN"

# ------------------------------------------------------------
# journald
# ------------------------------------------------------------

if [ "$J_PLAN" -eq 1 ]; then

    if [ -f "$JOURNALD_CONF" ]; then

        awk '
        BEGIN {
            sys=0
            run=0
        }

        /^[[:space:]]*#/ {
            print
            next
        }

        /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/ {
            print "SystemMaxFileSize=8M"
            sys=1
            next
        }

        /^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/ {
            print "RuntimeMaxFileSize=8M"
            run=1
            next
        }

        {
            print
        }

        END {
            if (!sys)
                print "SystemMaxFileSize=8M"

            if (!run)
                print "RuntimeMaxFileSize=8M"
        }
        ' "$JOURNALD_CONF" > "$TMPROOT/journald.conf"

        cat "$TMPROOT/journald.conf" > "$JOURNALD_CONF"

        echo "✓ $JOURNALD_CONF"
        echo "  SystemMaxFileSize=8M"
        echo "  RuntimeMaxFileSize=8M"
    fi
fi

# ------------------------------------------------------------
# 语法验证
# ------------------------------------------------------------

section "[8/8] 修改后验证"

echo
echo "============================================================"
echo "                     验证 logrotate"
echo "============================================================"

if logrotate -d "$LOGROTATE_MAIN" >/dev/null 2>&1; then
    echo "✓ logrotate 配置语法正常"
else
    echo "✗ logrotate 配置语法检查失败"
    echo
    logrotate -d "$LOGROTATE_MAIN" 2>&1 | tail -n 30
    exit 1
fi

# ------------------------------------------------------------
# 重新解析！
#
# 这里不读取之前的 RESULTS / PLAN。
# 重新扫描配置文件，重新建立 stanza。
# 这是修复上一版验证错误的关键。
# ------------------------------------------------------------

VERIFY_STANZAS="$TMPROOT/verify.stanzas"
: > "$VERIFY_STANZAS"

parse_verify_file() {
    local file="$1"

    [ -f "$file" ] || return 0

    awk -v FILE="$file" '
    function trim(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
    }

    function flush(    i) {
        if (start == 0)
            return

        for (i=1; i<=count; i++)
            printf "%s\t%d\t%d\t%s\n",
                FILE,start,end,paths[i]

        delete paths
        count=0
        start=0
        end=0
    }

    {
        line=$0
        sub(/[[:space:]]*#.*/, "", line)
        line=trim(line)

        if (line == "")
            next

        if (line ~ /^[^{}]+[[:space:]]*\{[[:space:]]*$/) {

            flush()

            start=NR

            p=line
            sub(/[[:space:]]*\{[[:space:]]*$/, "", p)
            p=trim(p)

            n=split(p,a,/[[:space:]]+/)
            count=0

            for(i=1;i<=n;i++)
                if(a[i]!="")
                    paths[++count]=a[i]

            next
        }

        if(start>0)
            end=NR

        if(line=="}")
            flush()
    }

    END {
        flush()
    }
    ' "$file" >> "$VERIFY_STANZAS"
}

parse_verify_file "$LOGROTATE_MAIN"

if [ -d "$LOGROTATE_DIR" ]; then
    find "$LOGROTATE_DIR" -maxdepth 1 -type f -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
        parse_verify_file "$f"
    done
fi

echo
echo "============================================================"
echo "                       最终验证"
echo "============================================================"

FAIL=0

while IFS=$'\t' read -r \
    log type controller start end pattern current target action; do

    [ "$action" = "change" ] || continue

    found=0

    while IFS=$'\t' read -r \
        vf vs ve vp; do

        [ "$vf" = "$controller" ] || continue

        case "$log" in
            $vp)
                v="$(
                    sed -n "${vs},${ve}p" "$vf" |
                    sed 's/[[:space:]]*#.*$//' |
                    awk '
                    $1=="maxsize" {
                        print $2
                        exit
                    }'
                )"

                if [ "$v" = "${target}M" ] || \
                   [ "$v" = "${target}m" ]; then
                    echo "✓ $log : maxsize ${v}"
                    found=1
                fi
                ;;
        esac

    done < "$VERIFY_STANZAS"

    if [ "$found" -eq 0 ]; then
        echo "✗ $log : 验证失败，期望 maxsize ${target}M"
        FAIL=$((FAIL + 1))
    fi

done < "$PLAN"

# ------------------------------------------------------------
# journald 验证
# ------------------------------------------------------------

if [ "$J_PLAN" -eq 1 ] && [ -f "$JOURNALD_CONF" ]; then

    VSYS=$(
        sed 's/[[:space:]]*#.*$//' "$JOURNALD_CONF" |
        awk '
        $1 ~ /^SystemMaxFileSize=/ {
            sub(/^SystemMaxFileSize=/,"",$1)
            print $1
            exit
        }'
    )

    VRUN=$(
        sed 's/[[:space:]]*#.*$//' "$JOURNALD_CONF" |
        awk '
        $1 ~ /^RuntimeMaxFileSize=/ {
            sub(/^RuntimeMaxFileSize=/,"",$1)
            print $1
            exit
        }'
    )

    if [ "$VSYS" = "8M" ] || [ "$VSYS" = "8m" ]; then
        echo "✓ SystemMaxFileSize = $VSYS"
    else
        echo "✗ SystemMaxFileSize = ${VSYS:-未设置}"
        FAIL=$((FAIL + 1))
    fi

    if [ "$VRUN" = "8M" ] || [ "$VRUN" = "8m" ]; then
        echo "✓ RuntimeMaxFileSize = $VRUN"
    else
        echo "✗ RuntimeMaxFileSize = ${VRUN:-未设置}"
        FAIL=$((FAIL + 1))
    fi
fi

echo
echo "------------------------------------------------------------"

if [ "$FAIL" -eq 0 ]; then
    echo "✓ 所有本次修改项目均已通过重新解析验证"
    echo "------------------------------------------------------------"
    echo
    echo "完成。"
    exit 0
else
    echo "✗ 有 $FAIL 项验证失败"
    echo "------------------------------------------------------------"
    echo
    echo "配置已经修改，但验证未全部通过，请勿忽略。"
    exit 1
fi
