#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================================
# Debian 13 日志大小审计与精准限制
# 扫描 → 识别 → 分类 → 建议 → 确认 → 修改 → 验证
#
# 规则：
#   - 不依赖 Python3
#   - 不创建配置文件
#   - 不备份
#   - 不删除现有日志
#   - 只修改真实存在且确认控制目标日志的配置
#   - logrotate：只修改对应 stanza
#   - journald：只修改已存在的 /etc/systemd/journald.conf
# ============================================================

TARGET_MIN=1
TARGET_MAX=10

LOGROTATE_DIR="/etc/logrotate.d"
JOURNALD_CONF="/etc/systemd/journald.conf"

TMP_ROOT="$(mktemp -d /tmp/log-audit.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

LOG_LIST="$TMP_ROOT/logs"
ROTATE_LIST="$TMP_ROOT/rotate_files"
RELATIONS="$TMP_ROOT/relations"
CHANGES="$TMP_ROOT/changes"

: > "$LOG_LIST"
: > "$ROTATE_LIST"
: > "$RELATIONS"
: > "$CHANGES"

die() {
    echo "错误：$*" >&2
    exit 1
}

warn() {
    echo "⚠ $*" >&2
}

ok() {
    echo "✓ $*"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少命令：$1"
}

is_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
}

# ------------------------------------------------------------
# 基础命令
# ------------------------------------------------------------

is_root

for cmd in \
    awk sed grep find stat sort uniq \
    systemctl logrotate df du getent \
    readlink dirname basename
do
    need_cmd "$cmd"
done

# ------------------------------------------------------------
# 通用函数
# ------------------------------------------------------------

human_size() {
    local f="$1"
    local s

    if [ ! -e "$f" ]; then
        echo "不存在"
        return
    fi

    s=$(stat -c '%s' "$f" 2>/dev/null || echo 0)

    if [ "$s" -ge $((1024*1024*1024)) ]; then
        awk -v s="$s" 'BEGIN { printf "%.2fG", s/1073741824 }'
    elif [ "$s" -ge $((1024*1024)) ]; then
        awk -v s="$s" 'BEGIN { printf "%.2fM", s/1048576 }'
    elif [ "$s" -ge 1024 ]; then
        awk -v s="$s" 'BEGIN { printf "%.2fK", s/1024 }'
    else
        printf '%sB' "$s"
    fi
}

bytes() {
    stat -c '%s' "$1" 2>/dev/null || echo 0
}

print_line() {
    printf '%*s\n' 60 '' | tr ' ' '-'
}

# ------------------------------------------------------------
# 日志分类
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
        /var/log/journal/*/system.journal)
            echo "journald"
            ;;
        /var/log/journal/*/user-*.journal)
            echo "journald"
            ;;
        /run/log/journal/*/system.journal)
            echo "journald"
            ;;
        /run/log/journal/*/user-*.journal)
            echo "journald"
            ;;
        /var/log/installer/*)
            echo "installer"
            ;;
        /var/log/apt/eipp.log.xz)
            echo "apt-eipp"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

recommended_limit() {
    local type="$1"

    case "$type" in
        alternatives)
            echo "2M"
            ;;
        apt-history)
            echo "3M"
            ;;
        apt-terminal)
            echo "5M"
            ;;
        dpkg)
            echo "5M"
            ;;
        failed-login-history)
            echo "5M"
            ;;
        login-history)
            echo "5M"
            ;;
        lastlog)
            echo "跳过"
            ;;
        *)
            echo "跳过"
            ;;
    esac
}

# ------------------------------------------------------------
# 精确读取 logrotate stanza
#
# 输出：
#   BEGIN|起始行
#   END|结束行
#   PATH|路径
#   OPTION|size/maxsize 等
#
# 不使用临时修改文件。
# ------------------------------------------------------------

parse_logrotate_file() {
    local file="$1"

    awk '
    function flush() {
        if (active) {
            print "STANZA|" start "|" NR-1
        }
        active=0
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

        # stanza 的第一行：
        # 非空、非注释，并且不以空白开头
        if (line !~ /^[[:space:]]/) {
            if (active)
                print "STANZA|" start "|" NR-1

            active=1
            start=NR

            path=$0
            sub(/[[:space:]].*$/, "", path)

            # 一个 stanza 可能有多个日志路径
            n=split($0, a, /[[:space:]]+/)

            for (i=1; i<=n; i++) {
                if (a[i] != "")
                    print "PATH|" NR "|" a[i]
            }

            next
        }

        if (active) {
            t=$0
            sub(/^[[:space:]]+/, "", t)

            if (t ~ /^maxsize[[:space:]]+/) {
                print "MAXSIZE|" NR "|" t
            }

            if (t ~ /^size[[:space:]]+/) {
                print "SIZE|" NR "|" t
            }
        }
    }

    END {
        if (active)
            print "STANZA|" start "|" NR
    }
    ' "$file"
}

# ------------------------------------------------------------
# 解析 size 单位
# 返回字节
# ------------------------------------------------------------

size_to_bytes() {
    local value="$1"

    awk -v v="$value" '
    BEGIN {
        gsub(/[[:space:]]+/, "", v)

        if (v ~ /^[0-9]+[Kk]$/) {
            sub(/[Kk]$/, "", v)
            printf "%.0f\n", v * 1024
        }
        else if (v ~ /^[0-9]+[Mm]$/) {
            sub(/[Mm]$/, "", v)
            printf "%.0f\n", v * 1048576
        }
        else if (v ~ /^[0-9]+[Gg]$/) {
            sub(/[Gg]$/, "", v)
            printf "%.0f\n", v * 1073741824
        }
        else if (v ~ /^[0-9]+$/) {
            print v
        }
        else {
            print 0
        }
    }'
}

# ------------------------------------------------------------
# 读取指定 stanza 的限制
# 参数：
#   file
#   start
#   end
# 输出：
#   MAXSIZE|...
#   SIZE|...
# ------------------------------------------------------------

get_stanza_limit() {
    local file="$1"
    local start="$2"
    local end="$3"

    sed -n "${start},${end}p" "$file" |
        sed 's/^[[:space:]]*//' |
        awk '
        /^maxsize[[:space:]]+/ {
            print "MAXSIZE|" $2
        }
        /^size[[:space:]]+/ {
            print "SIZE|" $2
        }
        '
}

# ------------------------------------------------------------
# 检查某个日志是否真实属于某个 stanza
#
# 只接受：
#   - 精确路径
#   - glob 匹配
#
# 不接受：
#   - 仅仅因为文件名相似
#   - 配置文件名字相似
# ------------------------------------------------------------

path_matches() {
    local log="$1"
    local pattern="$2"

    case "$pattern" in
        "$log")
            return 0
            ;;
    esac

    # logrotate 支持 shell glob。
    # 使用 bash case 判断。
    case "$log" in
        $pattern)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# 获取日志对应的真实 logrotate stanza
#
# 输出：
# file|start|end|pattern|limit_type|limit
# ------------------------------------------------------------

find_logrotate_relation() {
    local logfile="$1"
    local rf
    local parsed
    local start
    local end
    local pattern
    local limit_type
    local limit
    local line

    while IFS= read -r rf; do
        [ -f "$rf" ] || continue

        parsed="$TMP_ROOT/parsed"

        parse_logrotate_file "$rf" > "$parsed"

        start=""
        end=""

        while IFS='|' read -r kind a b; do
            case "$kind" in
                STANZA)
                    start="$a"
                    end="$b"
                    ;;

                PATH)
                    pattern="$b"

                    if [ -n "$start" ] &&
                       path_matches "$logfile" "$pattern"; then

                        limit_type="none"
                        limit=""

                        while IFS='|' read -r lk lv rest; do
                            case "$lk" in
                                MAXSIZE)
                                    limit_type="maxsize"
                                    limit="$lv"
                                    ;;
                                SIZE)
                                    if [ "$limit_type" = "none" ]; then
                                        limit_type="size"
                                        limit="$lv"
                                    fi
                                    ;;
                            esac
                        done < <(
                            get_stanza_limit "$rf" "$start" "$end"
                        )

                        printf '%s|%s|%s|%s|%s|%s\n' \
                            "$rf" "$start" "$end" "$pattern" \
                            "$limit_type" "$limit"

                        return 0
                    fi
                    ;;
            esac
        done < "$parsed"

    done < "$ROTATE_LIST"

    return 1
}

# ------------------------------------------------------------
# 修改 stanza
#
# 规则：
#   已有 maxsize → 修改
#   没有 maxsize 但有 size → 在 size 后添加 maxsize
#   没有 size/maxsize → 在第一组 rotate 选项前添加
#
# 不创建文件。
# ------------------------------------------------------------

modify_stanza() {
    local file="$1"
    local start="$2"
    local end="$3"
    local target="$4"

    local tmp="$TMP_ROOT/modify.$RANDOM"
    local i
    local line
    local found=0
    local first_option=0

    [ -f "$file" ] || return 1

    awk \
        -v s="$start" \
        -v e="$end" \
        -v target="$target" '
    NR < s || NR > e {
        print
        next
    }

    {
        if ($0 ~ /^[[:space:]]*maxsize[[:space:]]+/) {
            sub(/maxsize[[:space:]]+.*/, "maxsize " target)
            print
            found=1
            next
        }

        print
    }

    END {
        if (!found) {
            exit 42
        }
    }
    ' "$file" > "$tmp"

    rc=$?

    if [ "$rc" -eq 42 ]; then
        rm -f "$tmp"

        awk \
            -v s="$start" \
            -v e="$end" \
            -v target="$target" '
        NR < s || NR > e {
            print
            next
        }

        NR == s {
            print
            next
        }

        {
            if ($0 ~ /^[[:space:]]*(rotate|daily|weekly|monthly|size|missingok|notifempty|compress|delaycompress|copytruncate|create|su|dateext|dateyesterday|sharedscripts|postrotate|prerotate|firstaction|lastaction)/) {
                if (!inserted) {
                    print "    maxsize " target
                    inserted=1
                }
            }

            print
        }

        ' "$file" > "$tmp"

        if ! grep -qE '^[[:space:]]*maxsize[[:space:]]+' "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
    fi

    if [ "$rc" -ne 0 ] && [ "$rc" -ne 42 ]; then
        rm -f "$tmp"
        return 1
    fi

    cat "$tmp" > "$file"
    rm -f "$tmp"

    return 0
}

# ------------------------------------------------------------
# journald 当前配置读取
# ------------------------------------------------------------

get_journald_value() {
    local key="$1"

    awk -v key="$key" '
    /^[[:space:]]*#/ {
        next
    }

    {
        line=$0
        sub(/^[[:space:]]+/, "", line)

        if (line ~ ("^" key "[[:space:]]*=")) {
            sub(/^[^=]*=[[:space:]]*/, "", line)
            print line
        }
    }
    ' "$JOURNALD_CONF" | tail -n 1
}

# ------------------------------------------------------------
# 修改 journald.conf
#
# 只允许修改已存在配置文件。
# 文件存在：
#   已有键 → 修改
#   没有键 → 在已有 [Journal] 段中加入
#
# 不创建 drop-in。
# ------------------------------------------------------------

set_journald_value() {
    local key="$1"
    local value="$2"
    local tmp="$TMP_ROOT/journal.$RANDOM"

    [ -f "$JOURNALD_CONF" ] || return 1

    awk \
        -v key="$key" \
        -v value="$value" '
    BEGIN {
        found=0
    }

    {
        line=$0
        test=line
        sub(/^[[:space:]]+/, "", test)

        if (test ~ ("^" key "[[:space:]]*=")) {
            print key "=" value
            found=1
            next
        }

        print
    }

    END {
        if (!found)
            exit 42
    }
    ' "$JOURNALD_CONF" > "$tmp"

    rc=$?

    if [ "$rc" -eq 42 ]; then
        rm -f "$tmp"

        awk \
            -v key="$key" \
            -v value="$value" '
        BEGIN {
            in_journal=0
            inserted=0
        }

        {
            line=$0

            if (line ~ /^[[:space:]]*\[Journal\][[:space:]]*$/) {
                in_journal=1
                print
                next
            }

            if (line ~ /^[[:space:]]*\[/ && line !~ /^[[:space:]]*\[Journal\]/) {
                if (in_journal && !inserted) {
                    print key "=" value
                    inserted=1
                }
                in_journal=0
            }

            print
        }

        END {
            if (in_journal && !inserted)
                print key "=" value
        }
        ' "$JOURNALD_CONF" > "$tmp"
    fi

    [ -s "$tmp" ] || {
        rm -f "$tmp"
        return 1
    }

    cat "$tmp" > "$JOURNALD_CONF"
    rm -f "$tmp"

    return 0
}

# ------------------------------------------------------------
# 标题
# ------------------------------------------------------------

clear 2>/dev/null || true

echo "============================================================"
echo " Debian 13 日志大小审计与精准限制"
echo " 扫描 → 识别 → 分类 → 建议 → 确认 → 修改 → 验证"
echo "============================================================"
echo
echo "目标：普通日志 1M–10M；journald 单文件 8M"
echo
echo "原则："
echo "  ✓ 只修改真实存在且实际控制日志的配置"
echo "  ✓ 精确修改对应 stanza"
echo "  ✓ 不创建任何配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除现有日志"
echo "  ✓ 控制关系无法确认 → 跳过"
echo "  ✓ 不依赖 Python3"
echo

# ------------------------------------------------------------
# [1/8] 系统检测
# ------------------------------------------------------------

echo "[1/8] 系统检测"

if [ -r /etc/os-release ]; then
    . /etc/os-release
    echo "  OS       : ${PRETTY_NAME:-unknown}"
else
    echo "  OS       : unknown"
fi

echo "  Kernel   : $(uname -r)"
echo "  CPU      : $(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"

if [ -r /proc/meminfo ]; then
    awk '
    /^MemTotal:/ {
        printf "  RAM      : %.0f MB\n", $2/1024
    }
    ' /proc/meminfo
fi

swap_total=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
echo "  Swap     : $((swap_total / 1024)) MB（不修改）"

echo "  Python3  : 不需要"

echo

# ------------------------------------------------------------
# [2/8] 扫描日志
# ------------------------------------------------------------

echo "[2/8] 扫描实际日志文件"

find /var/log /run/log \
    -type f \
    -size +0c \
    -print 2>/dev/null |
    sort -u > "$LOG_LIST"

# 同时加入空日志，因为 btmp 等可能是 0B
find /var/log /run/log \
    -type f \
    -print 2>/dev/null |
    sort -u >> "$LOG_LIST"

sort -u "$LOG_LIST" -o "$LOG_LIST"

LOG_COUNT=$(wc -l < "$LOG_LIST" | tr -d ' ')

echo "  找到 $LOG_COUNT 个当前日志文件"
echo

# ------------------------------------------------------------
# [3/8] 扫描 logrotate
# ------------------------------------------------------------

echo "[3/8] 精确检测 logrotate 控制关系"

if [ -d "$LOGROTATE_DIR" ]; then
    find "$LOGROTATE_DIR" \
        -maxdepth 1 \
        -type f \
        -print 2>/dev/null |
        sort > "$ROTATE_LIST"
else
    : > "$ROTATE_LIST"
fi

ROTATE_COUNT=$(wc -l < "$ROTATE_LIST" | tr -d ' ')

echo
echo "  找到 $ROTATE_COUNT 个真实 logrotate 配置文件"
echo

# ------------------------------------------------------------
# 建立关系表
#
# path|type|size|control|start|end|pattern|limit_type|limit|suggest
# ------------------------------------------------------------

: > "$RELATIONS"

relation_count=0
unknown_count=0

while IFS= read -r logfile; do
    [ -f "$logfile" ] || continue

    type=$(classify_log "$logfile")
    size=$(human_size "$logfile")

    if [ "$type" = "journald" ]; then
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$logfile" "$type" "$size" \
            "journald" "-" "-" "-" "-" "-" "跳过" \
            >> "$RELATIONS"
        continue
    fi

    if rel=$(find_logrotate_relation "$logfile"); then
        IFS='|' read -r control start end pattern limit_type limit <<< "$rel"

        suggestion=$(recommended_limit "$type")

        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$logfile" "$type" "$size" \
            "$control" "$start" "$end" "$pattern" \
            "$limit_type" "$limit" "$suggestion" \
            >> "$RELATIONS"

        relation_count=$((relation_count + 1))
    else
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$logfile" "$type" "$size" \
            "未找到" "-" "-" "-" "-" "-" \
            "$(recommended_limit "$type")" \
            >> "$RELATIONS"

        unknown_count=$((unknown_count + 1))
    fi

done < "$LOG_LIST"

echo "  已识别明确控制关系：$relation_count"
echo "  未找到控制关系    ：$unknown_count"
echo

# ------------------------------------------------------------
# [4/8] journald
# ------------------------------------------------------------

echo "[4/8] 检测 systemd-journald"

persistent_count=0
runtime_count=0

if [ -d /var/log/journal ]; then
    persistent_count=$(find /var/log/journal \
        -type f \
        \( -name '*.journal' -o -name '*.journal~' \) \
        2>/dev/null | wc -l | tr -d ' ')
fi

if [ -d /run/log/journal ]; then
    runtime_count=$(find /run/log/journal \
        -type f \
        \( -name '*.journal' -o -name '*.journal~' \) \
        2>/dev/null | wc -l | tr -d ' ')
fi

echo "  persistent journal : $persistent_count"
echo "  runtime journal    : $runtime_count"

if [ -f "$JOURNALD_CONF" ]; then
    system_max=$(get_journald_value "SystemMaxFileSize")
    runtime_max=$(get_journald_value "RuntimeMaxFileSize")

    [ -n "$system_max" ] || system_max="未设置"
    [ -n "$runtime_max" ] || runtime_max="未设置"

    echo "  SystemMaxFileSize  : $system_max"
    echo "  RuntimeMaxFileSize : $runtime_max"
else
    echo "  /etc/systemd/journald.conf : 不存在"
    echo "  操作：跳过"
fi

echo

# ------------------------------------------------------------
# [5/8] 所有日志及控制关系
# ------------------------------------------------------------

echo "[5/8] 所有日志及控制关系"
echo

printf '%-48s %-20s %-10s %-32s %-12s %-8s\n' \
    "日志" "类型" "大小" "真实控制文件" "当前限制" "建议"

print_line

while IFS='|' read -r \
    logfile type size control start end pattern limit_type limit suggestion
do
    if [ "$limit_type" = "maxsize" ]; then
        current="${limit}"
    elif [ "$limit_type" = "size" ]; then
        current="size $limit"
    elif [ "$type" = "journald" ]; then
        current="journald"
    else
        current="未设置"
    fi

    printf '%-48s %-20s %-10s %-32s %-12s %-8s\n' \
        "$logfile" \
        "$type" \
        "$size" \
        "$control" \
        "$current" \
        "$suggestion"

done < "$RELATIONS"

echo

# ------------------------------------------------------------
# [6/8] 修改建议
# ------------------------------------------------------------

echo "[6/8] 修改建议"
echo
echo "建议依据：日志用途，不依据当前文件大小。"
echo "范围：普通日志 1M–10M；journald 单文件 8M。"
echo

change_count=0

while IFS='|' read -r \
    logfile type size control start end pattern limit_type limit suggestion
do
    [ "$control" != "未找到" ] || continue
    [ "$suggestion" != "跳过" ] || continue
    [ "$type" != "journald" ] || continue

    need_change=0

    if [ "$limit_type" = "maxsize" ]; then
        current_bytes=$(size_to_bytes "$limit")
        target_bytes=$(size_to_bytes "$suggestion")

        if [ "$current_bytes" -gt "$target_bytes" ]; then
            need_change=1
        elif [ "$current_bytes" -lt "$target_bytes" ]; then
            need_change=1
        fi
    else
        need_change=1
    fi

    if [ "$need_change" -eq 1 ]; then
        change_count=$((change_count + 1))

        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$logfile" "$type" "$control" \
            "$start" "$end" "$pattern" \
            "$limit_type" "$suggestion" \
            >> "$CHANGES"

        echo "[$change_count]"
        echo "  日志       : $logfile"
        echo "  类型       : $type"
        echo "  控制文件   : $control"
        echo "  stanza     : $start-$end"
        echo "  匹配规则   : $pattern"

        if [ "$limit_type" = "maxsize" ]; then
            echo "  当前限制   : maxsize $limit"
        elif [ "$limit_type" = "size" ]; then
            echo "  当前限制   : size $limit"
        else
            echo "  当前限制   : 未设置"
        fi

        echo "  修改目标   : maxsize $suggestion"
        echo
    fi

done < "$RELATIONS"

# ------------------------------------------------------------
# journald 修改判断
# ------------------------------------------------------------

JOURNAL_CHANGE=0

if [ -f "$JOURNALD_CONF" ]; then
    system_max=$(get_journald_value "SystemMaxFileSize")
    runtime_max=$(get_journald_value "RuntimeMaxFileSize")

    if [ "$system_max" != "8M" ]; then
        JOURNAL_CHANGE=1
    fi

    if [ "$runtime_max" != "8M" ]; then
        JOURNAL_CHANGE=1
    fi
fi

if [ "$JOURNAL_CHANGE" -eq 1 ]; then
    echo "[journald]"
    echo "  控制文件 : $JOURNALD_CONF"

    echo "  SystemMaxFileSize  : ${system_max:-未设置} → 8M"
    echo "  RuntimeMaxFileSize : ${runtime_max:-未设置} → 8M"
    echo
fi

if [ "$change_count" -eq 0 ] && [ "$JOURNAL_CHANGE" -eq 0 ]; then
    echo "没有需要修改的配置。"
    echo
    echo "审计完成。"
    exit 0
fi

# ------------------------------------------------------------
# 修改原则
# ------------------------------------------------------------

echo "[7/8] 修改原则"
echo
echo "  ✓ 只修改真实存在的 /etc/logrotate.d/*"
echo "  ✓ 只修改真实匹配目标日志的 stanza"
echo "  ✓ maxsize 按日志用途设置"
echo "  ✓ journald 单文件限制 8M"
echo "  ✓ 不创建任何配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除当前日志"
echo "  ✓ 不使用 Python3"
echo

echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo

echo "本次准备修改：$change_count 个 logrotate stanza"

if [ "$JOURNAL_CHANGE" -eq 1 ]; then
    echo "journald：需要修改 /etc/systemd/journald.conf"
else
    echo "journald：无需修改"
fi

echo
echo "⚠ 不创建任何配置文件"
echo "⚠ 不备份"
echo "⚠ 不删除现有日志"
echo

read -r -p "确认执行精准修改？[y/N] " answer

case "$answer" in
    y|Y|yes|YES)
        ;;
    *)
        echo
        echo "已取消，未修改任何配置。"
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 修改
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                         开始修改"
echo "============================================================"
echo

failed=0

while IFS='|' read -r \
    logfile type control start end pattern limit_type target
do
    echo "→ $control"
    echo "  $logfile → maxsize $target"

    if modify_stanza "$control" "$start" "$end" "$target"; then
        ok "修改成功"
    else
        warn "修改失败：$control / stanza $start-$end"
        failed=$((failed + 1))
    fi

    echo

done < "$CHANGES"

# ------------------------------------------------------------
# journald
# ------------------------------------------------------------

if [ "$JOURNAL_CHANGE" -eq 1 ]; then
    echo "→ $JOURNALD_CONF"

    if set_journald_value "SystemMaxFileSize" "8M"; then
        ok "SystemMaxFileSize=8M"
    else
        warn "SystemMaxFileSize 修改失败"
        failed=$((failed + 1))
    fi

    if set_journald_value "RuntimeMaxFileSize" "8M"; then
        ok "RuntimeMaxFileSize=8M"
    else
        warn "RuntimeMaxFileSize 修改失败"
        failed=$((failed + 1))
    fi

    echo
fi

if [ "$failed" -gt 0 ]; then
    echo "存在 $failed 项修改失败。"
    exit 1
fi

# ------------------------------------------------------------
# logrotate 语法验证
# ------------------------------------------------------------

echo "[8/8] 修改后验证"
echo
echo "============================================================"
echo "                     验证 logrotate"
echo "============================================================"

if logrotate -d /etc/logrotate.conf >/dev/null 2>&1; then
    ok "logrotate 配置语法正常"
else
    warn "logrotate 配置验证失败"
    logrotate -d /etc/logrotate.conf 2>&1 | tail -n 30
    exit 1
fi

echo

# ------------------------------------------------------------
# 精确验证
#
# 重新扫描真实文件与真实 stanza。
# 不相信修改阶段结果。
# ------------------------------------------------------------

echo "============================================================"
echo "                       最终精确验证"
echo "============================================================"

verify_failed=0

while IFS='|' read -r \
    logfile type control start end pattern old_limit_type old_limit target
do
    echo
    echo "日志：$logfile"
    echo "  控制文件 : $control"
    echo "  stanza   : $start-$end"
    echo "  匹配规则 : $pattern"

    # 再次确认当前配置确实仍控制这个日志
    if ! rel=$(find_logrotate_relation "$logfile"); then
        warn "真实控制关系验证失败"
        verify_failed=$((verify_failed + 1))
        continue
    fi

    IFS='|' read -r \
        actual_control actual_start actual_end \
        actual_pattern actual_type actual_limit <<< "$rel"

    if [ "$actual_control" != "$control" ] ||
       [ "$actual_start" != "$start" ] ||
       [ "$actual_end" != "$end" ] ||
       ! path_matches "$logfile" "$actual_pattern"
    then
        warn "控制关系发生变化或无法确认"
        verify_failed=$((verify_failed + 1))
        continue
    fi

    actual_value=""

    while IFS='|' read -r lk lv rest; do
        if [ "$lk" = "MAXSIZE" ]; then
            actual_value="$lv"
        fi
    done < <(
        get_stanza_limit "$actual_control" \
            "$actual_start" \
            "$actual_end"
    )

    if [ "$actual_value" = "$target" ]; then
        ok "$logfile : maxsize $target"
    else
        warn "$logfile : 期望 maxsize $target，实际 ${actual_value:-未设置}"
        verify_failed=$((verify_failed + 1))
    fi

done < "$CHANGES"

# ------------------------------------------------------------
# journald 精确验证
# ------------------------------------------------------------

if [ "$JOURNAL_CHANGE" -eq 1 ]; then
    echo
    echo "journald："

    system_max=$(get_journald_value "SystemMaxFileSize")
    runtime_max=$(get_journald_value "RuntimeMaxFileSize")

    if [ "$system_max" = "8M" ]; then
        ok "SystemMaxFileSize = 8M"
    else
        warn "SystemMaxFileSize = ${system_max:-未设置}"
        verify_failed=$((verify_failed + 1))
    fi

    if [ "$runtime_max" = "8M" ]; then
        ok "RuntimeMaxFileSize = 8M"
    else
        warn "RuntimeMaxFileSize = ${runtime_max:-未设置}"
        verify_failed=$((verify_failed + 1))
    fi
fi

# ------------------------------------------------------------
# 验证结果
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"

if [ "$verify_failed" -eq 0 ]; then
    echo "✓ 所有修改均已通过精确验证"
else
    echo "⚠ 有 $verify_failed 项验证失败"
    exit 1
fi

echo "------------------------------------------------------------"
echo
echo "最终配置状态："
echo

for f in "$CHANGES"; do
    [ -s "$f" ] || continue

    while IFS='|' read -r \
        logfile type control start end pattern old_limit_type old_limit target
    do
        rel=$(find_logrotate_relation "$logfile" 2>/dev/null || true)

        if [ -n "$rel" ]; then
            IFS='|' read -r \
                actual_control actual_start actual_end \
                actual_pattern actual_limit_type actual_limit <<< "$rel"

            printf '  %-42s maxsize %s\n' \
                "$logfile" "$actual_limit"
        fi
    done < "$f"
done

if [ "$JOURNAL_CHANGE" -eq 1 ] && [ -f "$JOURNALD_CONF" ]; then
    echo
    echo "  journald SystemMaxFileSize  : $(get_journald_value SystemMaxFileSize)"
    echo "  journald RuntimeMaxFileSize : $(get_journald_value RuntimeMaxFileSize)"
fi

echo
echo "完成。"
