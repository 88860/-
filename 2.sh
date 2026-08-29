#!/bin/bash
set -u
export LC_ALL=C

TARGET_MAX="20M"
TARGET_BYTES=$((20 * 1024 * 1024))

LOGROTATE_MAIN="/etc/logrotate.conf"
LOGROTATE_DIR="/etc/logrotate.d"

JOURNAL_MAIN="/etc/systemd/journald.conf"
JOURNAL_DIR="/etc/systemd/journald.conf.d"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

die() {
    echo -e "${RED}错误：$1${NC}"
    exit 1
}

info() {
    echo -e "${CYAN}$1${NC}"
}

ok() {
    echo -e "${GREEN}✓ $1${NC}"
}

warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

command -v awk >/dev/null 2>&1 || die "awk 不存在"
command -v sed >/dev/null 2>&1 || die "sed 不存在"
command -v grep >/dev/null 2>&1 || die "grep 不存在"
command -v find >/dev/null 2>&1 || die "find 不存在"
command -v stat >/dev/null 2>&1 || die "stat 不存在"
command -v systemctl >/dev/null 2>&1 || die "systemctl 不存在"

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行"

echo "============================================================"
echo " Debian 13 日志大小审计与精准限制"
echo " 扫描 → 识别控制关系 → 人工确认 → 精准修改 → 验证"
echo "============================================================"
echo
echo "目标：单个可管理日志文件最大 ${TARGET_MAX}"
echo "原则："
echo "  ✓ 只修改已经存在的配置文件"
echo "  ✓ 必须确认配置实际控制目标日志"
echo "  ✓ 不创建任何配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不直接删除现有日志"
echo "  ✓ 无明确控制关系的日志跳过"
echo

# ------------------------------------------------------------
# 基础检查
# ------------------------------------------------------------

[ -f "$LOGROTATE_MAIN" ] || warn "$LOGROTATE_MAIN 不存在"
[ -d "$LOGROTATE_DIR" ] || warn "$LOGROTATE_DIR 不存在"

# ------------------------------------------------------------
# 日志大小转换
# ------------------------------------------------------------

human_size() {
    local bytes="$1"

    if [ "$bytes" -ge $((1024*1024*1024)) ]; then
        awk -v n="$bytes" 'BEGIN {printf "%.2fG", n/1073741824}'
    elif [ "$bytes" -ge $((1024*1024)) ]; then
        awk -v n="$bytes" 'BEGIN {printf "%.2fM", n/1048576}'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v n="$bytes" 'BEGIN {printf "%.2fK", n/1024}'
    else
        echo "${bytes}B"
    fi
}

# ------------------------------------------------------------
# [1/8] 系统信息
# ------------------------------------------------------------

echo "[1/8] 系统检测"

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    PRETTY_NAME="unknown"
fi

echo "  OS       : ${PRETTY_NAME:-unknown}"
echo "  Kernel   : $(uname -r)"
echo "  /var/log : $(du -sh /var/log 2>/dev/null | awk '{print $1}')"
echo "  /run/log : $(du -sh /run/log 2>/dev/null | awk '{print $1}')"
echo

# ------------------------------------------------------------
# [2/8] 检测实际日志文件
# ------------------------------------------------------------

echo "[2/8] 扫描实际日志文件"

declare -a LOG_FILES=()
declare -a LOG_SIZES=()

while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue

    case "$file" in
        *.log|*.log.*|/var/log/syslog|/var/log/messages|/var/log/auth.log|\
        /var/log/daemon.log|/var/log/kern.log|/var/log/user.log|\
        /var/log/mail.log|/var/log/mail.err|/var/log/mail.warn|\
        /var/log/debug|/var/log/cron.log|/var/log/ufw.log|\
        /var/log/wtmp|/var/log/btmp|/var/log/lastlog)
            ;;
        *)
            continue
            ;;
    esac

    size="$(stat -c '%s' "$file" 2>/dev/null || echo 0)"

    LOG_FILES+=("$file")
    LOG_SIZES+=("$size")
done < <(
    find /var/log -xdev -type f -print0 2>/dev/null
)

echo "  找到 ${#LOG_FILES[@]} 个可识别日志文件"
echo

if [ "${#LOG_FILES[@]}" -eq 0 ]; then
    warn "没有找到可识别日志文件"
fi

# ------------------------------------------------------------
# [3/8] logrotate 配置收集
# ------------------------------------------------------------

echo "[3/8] 扫描 logrotate 配置"

declare -a ROTATE_FILES=()

if [ -f "$LOGROTATE_MAIN" ]; then
    ROTATE_FILES+=("$LOGROTATE_MAIN")
fi

if [ -d "$LOGROTATE_DIR" ]; then
    while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        ROTATE_FILES+=("$f")
    done < <(
        find "$LOGROTATE_DIR" -maxdepth 1 -type f -print0 2>/dev/null |
        sort -z
    )
fi

echo "  找到 ${#ROTATE_FILES[@]} 个 logrotate 配置文件"
echo

# ------------------------------------------------------------
# logrotate stanza 解析
# ------------------------------------------------------------

# 输出：
# 文件|起始行|结束行|路径模式|size|size_value|maxsize|maxsize_value|rotate
declare -a STANZA_FILE=()
declare -a STANZA_START=()
declare -a STANZA_END=()
declare -a STANZA_PATTERN=()
declare -a STANZA_SIZE=()
declare -a STANZA_MAXSIZE=()
declare -a STANZA_ROTATE=()

parse_rotate_file() {
    local file="$1"

    awk -v F="$file" '
    function trim(s) {
        gsub(/^[ \t]+/, "", s)
        gsub(/[ \t]+$/, "", s)
        return s
    }

    function firstword(s, a) {
        s=trim(s)
        split(s,a,/[\t ]+/)
        return a[1]
    }

    BEGIN {
        inblock=0
        start=0
        depth=0
        pattern=""
        size=""
        maxsize=""
        rotate=""
    }

    {
        raw=$0
        line=raw
        sub(/^[ \t]+/, "", line)

        if (line == "" || line ~ /^#/)
            next

        if (!inblock) {
            if (line ~ /\{$/) {
                start=NR
                inblock=1
                depth=1

                pattern=line
                sub(/[ \t]*\{[ \t]*$/, "", pattern)
                pattern=trim(pattern)

                size=""
                maxsize=""
                rotate=""
            }
            next
        }

        if (line == "}") {
            print F "|" start "|" NR "|" pattern "|" size "|" maxsize "|" rotate

            inblock=0
            start=0
            pattern=""
            size=""
            maxsize=""
            rotate=""
            next
        }

        word=firstword(line)

        if (word == "size") {
            val=line
            sub(/^[^ \t]+[ \t]+/, "", val)
            size=trim(val)
        }

        if (word == "maxsize") {
            val=line
            sub(/^[^ \t]+[ \t]+/, "", val)
            maxsize=trim(val)
        }

        if (word == "rotate") {
            val=line
            sub(/^[^ \t]+[ \t]+/, "", val)
            rotate=trim(val)
        }
    }
    ' "$file"
}

for f in "${ROTATE_FILES[@]}"; do
    while IFS='|' read -r file start end pattern size maxsize rotate; do
        [ -n "$file" ] || continue

        STANZA_FILE+=("$file")
        STANZA_START+=("$start")
        STANZA_END+=("$end")
        STANZA_PATTERN+=("$pattern")
        STANZA_SIZE+=("$size")
        STANZA_MAXSIZE+=("$maxsize")
        STANZA_ROTATE+=("$rotate")
    done < <(parse_rotate_file "$f")
done

echo "  找到 ${#STANZA_FILE[@]} 个 logrotate stanza"
echo

# ------------------------------------------------------------
# glob 匹配
# ------------------------------------------------------------

glob_match() {
    local pattern="$1"
    local file="$2"

    python3 - "$pattern" "$file" >/dev/null 2>&1 <<'PY'
import sys, fnmatch
sys.exit(0 if fnmatch.fnmatchcase(sys.argv[2], sys.argv[1]) else 1)
PY
}

# Python 不存在时使用 shell glob 备用方法
if ! command -v python3 >/dev/null 2>&1; then
    glob_match() {
        local pattern="$1"
        local file="$2"

        case "$file" in
            $pattern) return 0 ;;
            *) return 1 ;;
        esac
    }
fi

# ------------------------------------------------------------
# [4/8] 日志 → 控制配置关系
# ------------------------------------------------------------

echo "[4/8] 检测日志实际控制关系"
echo

declare -a CHANGE_FILE=()
declare -a CHANGE_START=()
declare -a CHANGE_END=()
declare -a CHANGE_PATTERN=()
declare -a CHANGE_LOG=()
declare -a CHANGE_SIZE=()
declare -a CHANGE_MAXSIZE=()

FOUND_MANAGED=0
FOUND_UNMANAGED=0
FOUND_OK=0

for ((i=0; i<${#LOG_FILES[@]}; i++)); do

    log="${LOG_FILES[$i]}"
    bytes="${LOG_SIZES[$i]}"

    case "$log" in
        /var/log/journal/*|/run/log/journal/*)
            continue
            ;;
    esac

    matched=-1

    for ((j=0; j<${#STANZA_FILE[@]}; j++)); do

        pattern="${STANZA_PATTERN[$j]}"

        # 多路径 stanza：逐个 token 检查
        for token in $pattern; do
            case "$token" in
                /dev/null)
                    continue
                    ;;
            esac

            if glob_match "$token" "$log"; then
                matched="$j"
            fi
        done
    done

    if [ "$matched" -lt 0 ]; then
        FOUND_UNMANAGED=$((FOUND_UNMANAGED + 1))

        if [ "$bytes" -gt "$TARGET_BYTES" ]; then
            warn "$log"
            echo "    当前大小 : $(human_size "$bytes")"
            echo "    控制配置 : 未找到明确匹配"
            echo "    操作     : 跳过，不创建配置"
            echo
        fi

        continue
    fi

    FOUND_MANAGED=$((FOUND_MANAGED + 1))

    rf="${STANZA_FILE[$matched]}"
    rs="${STANZA_START[$matched]}"
    re="${STANZA_END[$matched]}"
    rp="${STANZA_PATTERN[$matched]}"
    rsize="${STANZA_SIZE[$matched]}"
    rmax="${STANZA_MAXSIZE[$matched]}"

    if [ -n "$rmax" ]; then
        limit="$rmax"
    elif [ -n "$rsize" ]; then
        limit="$rsize"
    else
        limit="none"
    fi

    # 当前已有 maxsize <= 20M，认为符合要求
    if [ "$bytes" -le "$TARGET_BYTES" ] && [ "$limit" = "20M" ]; then
        FOUND_OK=$((FOUND_OK + 1))
        continue
    fi

    echo "日志：$log"
    echo "  当前大小       : $(human_size "$bytes")"
    echo "  控制配置       : $rf"
    echo "  控制 stanza    : ${rs}-${re}"
    echo "  匹配规则       : $rp"
    echo "  当前 size      : ${rsize:-未设置}"
    echo "  当前 maxsize   : ${rmax:-未设置}"

    if [ "$bytes" -gt "$TARGET_BYTES" ]; then
        warn "当前日志已经超过 ${TARGET_MAX}"
    fi

    if [ "$limit" = "none" ]; then
        echo "  建议修改       : 添加 maxsize ${TARGET_MAX}"
    elif [ "$rmax" != "20M" ]; then
        echo "  建议修改       : maxsize ${TARGET_MAX}"
    else
        echo "  建议检查       : 当前 maxsize 已为 ${TARGET_MAX}"
    fi

    echo

    CHANGE_FILE+=("$rf")
    CHANGE_START+=("$rs")
    CHANGE_END+=("$re")
    CHANGE_PATTERN+=("$rp")
    CHANGE_LOG+=("$log")
    CHANGE_SIZE+=("$rsize")
    CHANGE_MAXSIZE+=("$rmax")
done

# ------------------------------------------------------------
# [5/8] journald
# ------------------------------------------------------------

echo "[5/8] 检测 systemd-journald"

JOURNAL_FOUND=0
JOURNAL_BYTES=0

if command -v journalctl >/dev/null 2>&1; then
    JOURNAL_FOUND=1
    JOURNAL_SIZE_TEXT="$(journalctl --disk-usage 2>/dev/null | tail -n 1)"
    echo "  journal 实际占用 : ${JOURNAL_SIZE_TEXT:-unknown}"
else
    echo "  journalctl       : 不存在"
fi

JOURNAL_SOURCE=""
JOURNAL_VALUE=""

get_journal_value() {
    local key="$1"
    local f
    local result=""

    local -a files=()

    [ -f "$JOURNAL_MAIN" ] && files+=("$JOURNAL_MAIN")

    if [ -d "$JOURNAL_DIR" ]; then
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(
            find "$JOURNAL_DIR" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null |
            sort -z
        )
    fi

    for f in "${files[@]}"; do
        value="$(
            awk -v k="$key" '
                /^[[:space:]]*#/ {next}
                {
                    line=$0
                    sub(/^[[:space:]]+/, "", line)

                    if (line ~ "^" k "[[:space:]]*=") {
                        sub(/^[^=]*=[[:space:]]*/, "", line)
                        gsub(/[[:space:]]+$/, "", line)
                        print line
                    }
                }
            ' "$f" | tail -n 1
        )"

        if [ -n "$value" ]; then
            result="$f|$value"
        fi
    done

    echo "$result"
}

JR="$(get_journal_value "SystemMaxFileSize")"

if [ -n "$JR" ]; then
    JOURNAL_SOURCE="${JR%%|*}"
    JOURNAL_VALUE="${JR#*|}"

    echo "  SystemMaxFileSize : $JOURNAL_VALUE"
    echo "  生效配置文件      : $JOURNAL_SOURCE"

    if [ "$JOURNAL_VALUE" != "20M" ]; then
        warn "SystemMaxFileSize 不是 20M"

        if [ -f "$JOURNAL_SOURCE" ]; then
            JOURNAL_CHANGE=1
        else
            JOURNAL_CHANGE=0
        fi
    else
        ok "journald 单文件限制已经是 20M"
        JOURNAL_CHANGE=0
    fi
else
    echo "  SystemMaxFileSize : 未找到现有配置"
    echo "  操作              : 跳过"
    JOURNAL_CHANGE=0
fi

echo

# ------------------------------------------------------------
# journald 文件实际大小
# ------------------------------------------------------------

echo "  journal 文件扫描："

JOURNAL_COUNT=0
JOURNAL_LARGE=0

while IFS= read -r -d '' jf; do
    [ -f "$jf" ] || continue

    js="$(stat -c '%s' "$jf" 2>/dev/null || echo 0)"
    JOURNAL_COUNT=$((JOURNAL_COUNT + 1))

    if [ "$js" -gt "$TARGET_BYTES" ]; then
        JOURNAL_LARGE=$((JOURNAL_LARGE + 1))
        echo "    $(human_size "$js")  $jf"
    fi
done < <(
    find /var/log/journal /run/log/journal \
        -type f \( -name '*.journal' -o -name '*.journal~' \) \
        -print0 2>/dev/null
)

echo "    journal 文件数 : $JOURNAL_COUNT"
echo "    >20M 文件数    : $JOURNAL_LARGE"
echo

# ------------------------------------------------------------
# [6/8] 结果汇总
# ------------------------------------------------------------

echo "[6/8] 审计结果"
echo
echo "============================================================"

echo "普通日志："
echo "  已找到明确控制关系 : $FOUND_MANAGED"
echo "  已符合目标          : $FOUND_OK"
echo "  未找到控制配置      : $FOUND_UNMANAGED"
echo "  待修改 stanza       : ${#CHANGE_FILE[@]}"

echo
echo "journald："
echo "  已有有效限制配置    : $([ -n "$JOURNAL_SOURCE" ] && echo yes || echo no)"
echo "  待修改              : $([ "${JOURNAL_CHANGE:-0}" -eq 1 ] && echo yes || echo no)"

echo
echo "目标：单个日志文件 ${TARGET_MAX}"
echo "============================================================"
echo

# ------------------------------------------------------------
# 没有修改
# ------------------------------------------------------------

if [ "${#CHANGE_FILE[@]}" -eq 0 ] && [ "${JOURNAL_CHANGE:-0}" -eq 0 ]; then
    ok "没有发现可以安全精准修改的配置。"
    echo
    echo "未找到控制配置的日志不会被创建新规则。"
    echo "脚本不会删除现有日志。"
    exit 0
fi

# ------------------------------------------------------------
# 最终修改清单
# ------------------------------------------------------------

echo "============================================================"
echo "                         修改清单"
echo "============================================================"
echo

for ((i=0; i<${#CHANGE_FILE[@]}; i++)); do
    echo "[$((i+1))]"
    echo "日志       : ${CHANGE_LOG[$i]}"
    echo "控制文件   : ${CHANGE_FILE[$i]}"
    echo "stanza     : ${CHANGE_START[$i]}-${CHANGE_END[$i]}"
    echo "匹配规则   : ${CHANGE_PATTERN[$i]}"
    echo "修改目标   : maxsize ${TARGET_MAX}"
    echo
done

if [ "${JOURNAL_CHANGE:-0}" -eq 1 ]; then
    echo "[journald]"
    echo "控制文件   : $JOURNAL_SOURCE"
    echo "修改目标   : SystemMaxFileSize=${TARGET_MAX}"
    echo
fi

echo "============================================================"
echo "注意："
echo "  ✓ 只修改上面列出的已有配置文件"
echo "  ✓ 不创建 logrotate 配置"
echo "  ✓ 不创建 journald drop-in"
echo "  ✓ 不删除现有日志"
echo "  ✓ 未找到控制关系的日志保持不变"
echo "============================================================"
echo

read -r -p "确认执行精准修改？[y/N] " ANSWER

case "$ANSWER" in
    y|Y|yes|YES)
        ;;
    *)
        echo
        echo "已取消，没有修改任何文件。"
        exit 0
        ;;
esac

# ------------------------------------------------------------
# [7/8] 修改 logrotate
# ------------------------------------------------------------

echo
echo "[7/8] 修改已有 logrotate 配置"
echo

# 按文件分组修改，避免同一个文件被重复处理
declare -a MODIFIED_FILES=()

for ((i=0; i<${#CHANGE_FILE[@]}; i++)); do

    file="${CHANGE_FILE[$i]}"
    start="${CHANGE_START[$i]}"
    end="${CHANGE_END[$i]}"

    # 防止同一个 stanza 被重复修改
    already=0

    for mf in "${MODIFIED_FILES[@]}"; do
        if [ "$mf" = "$file|$start|$end" ]; then
            already=1
            break
        fi
    done

    [ "$already" -eq 1 ] && continue

    tmp="$(mktemp)"

    awk -v s="$start" -v e="$end" '
        NR == s {
            inblock=1
            maxsize_found=0
        }

        inblock && /^[[:space:]]*maxsize[[:space:]]+/ {
            print "    maxsize 20M"
            maxsize_found=1
            next
        }

        NR == e && !maxsize_found {
            print "    maxsize 20M"
        }

        {
            print
        }

        NR == e {
            inblock=0
        }
    ' "$file" > "$tmp"

    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        die "生成修改内容失败：$file"
    fi

    cat "$tmp" > "$file"
    rm -f "$tmp"

    MODIFIED_FILES+=("$file|$start|$end")

    ok "$file stanza ${start}-${end} 已修改"
done

# ------------------------------------------------------------
# journald
# ------------------------------------------------------------

if [ "${JOURNAL_CHANGE:-0}" -eq 1 ]; then

    echo
    echo "修改 journald：$JOURNAL_SOURCE"

    tmp="$(mktemp)"

    awk '
        BEGIN {changed=0}

        /^[[:space:]]*#/ {
            print
            next
        }

        /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/ {
            print "SystemMaxFileSize=20M"
            changed=1
            next
        }

        {
            print
        }

        END {
            if (!changed)
                print "SystemMaxFileSize=20M"
        }
    ' "$JOURNAL_SOURCE" > "$tmp"

    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        die "journald 配置修改失败"
    fi

    cat "$tmp" > "$JOURNAL_SOURCE"
    rm -f "$tmp"

    ok "SystemMaxFileSize=20M"
fi

# ------------------------------------------------------------
# 修改后验证
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                         配置验证"
echo "============================================================"
echo

# logrotate dry-run
if command -v logrotate >/dev/null 2>&1 && [ -f "$LOGROTATE_MAIN" ]; then
    echo "logrotate 配置检查："

    if logrotate -d "$LOGROTATE_MAIN" >/tmp/logrotate-audit.$$ 2>&1; then
        ok "logrotate 配置语法正常"
    else
        cat /tmp/logrotate-audit.$$ 2>/dev/null
        rm -f /tmp/logrotate-audit.$$
        die "logrotate 配置检查失败"
    fi

    rm -f /tmp/logrotate-audit.$$
else
    warn "logrotate 不存在，跳过 logrotate 语法检查"
fi

# journald 配置检查
if [ "${JOURNAL_CHANGE:-0}" -eq 1 ]; then
    echo
    echo "journald 配置检查："

    if systemd-analyze verify "$JOURNAL_SOURCE" >/dev/null 2>&1; then
        ok "journald 配置检查正常"
    else
        warn "systemd-analyze verify 未通过或不支持该检查方式"
    fi
fi

# ------------------------------------------------------------
# 应用 journald
# ------------------------------------------------------------

if [ "${JOURNAL_CHANGE:-0}" -eq 1 ]; then
    echo
    echo "应用 journald 配置："

    if systemctl restart systemd-journald; then
        ok "systemd-journald 重启成功"
    else
        warn "systemd-journald 重启失败"
    fi
fi

# ------------------------------------------------------------
# [8/8] 最终验证
# ------------------------------------------------------------

echo
echo "[8/8] 最终验证"
echo

FAILED=0

for ((i=0; i<${#CHANGE_FILE[@]}; i++)); do

    file="${CHANGE_FILE[$i]}"
    start="${CHANGE_START[$i]}"
    end="${CHANGE_END[$i]}"

    value="$(
        sed -n "${start},${end}p" "$file" |
        awk '
            /^[[:space:]]*maxsize[[:space:]]+/ {
                v=$0
                sub(/^[[:space:]]*maxsize[[:space:]]+/, "", v)
                print v
                exit
            }
        '
    )"

    if [ "$value" = "20M" ]; then
        ok "$file [$start-$end] maxsize = 20M"
    else
        warn "$file [$start-$end] maxsize 验证失败：${value:-未找到}"
        FAILED=1
    fi
done

if [ "${JOURNAL_CHANGE:-0}" -eq 1 ]; then

    value="$(
        awk '
            /^[[:space:]]*#/ {next}
            /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, "")
                print
            }
        ' "$JOURNAL_SOURCE" | tail -n 1
    )"

    if [ "$value" = "20M" ]; then
        ok "journald SystemMaxFileSize = 20M"
    else
        warn "journald SystemMaxFileSize 验证失败"
        FAILED=1
    fi
fi

echo
echo "============================================================"

if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}完成：所有实际存在且已确认控制关系的配置均已精准修改。${NC}"
else
    echo -e "${RED}警告：部分配置验证失败，请检查上面的结果。${NC}"
fi

echo "============================================================"
echo
echo "说明："
echo "  • 未找到控制配置的日志没有被修改"
echo "  • 没有创建任何配置文件"
echo "  • 没有删除现有日志"
echo "  • 没有执行 logrotate 强制轮转"
echo "  • 现有超大日志不会被脚本直接删除"
echo
