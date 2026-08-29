#!/bin/bash
set -u
export LC_ALL=C

###############################################################################
# Debian 13 日志大小审计与精准限制
# 扫描 → 识别 → 分类 → 建议 → 确认 → 修改 → 验证
#
# 原则：
#   - 不创建任何配置文件
#   - 不备份
#   - 不删除现有日志
#   - 只修改已经存在的配置文件
#   - 必须确认配置 stanza 实际匹配目标日志
#   - 不依赖 Python3
###############################################################################

TARGET_MAX_DEFAULT="5M"
JOURNAL_MAX="8M"

LOGROTATE_MAIN="/etc/logrotate.conf"
LOGROTATE_DIR="/etc/logrotate.d"
JOURNALD_CONF="/etc/systemd/journald.conf"

TMP_ROOT=""
MODIFIED=0
FAIL=0

declare -a LOG_FILES=()
declare -a CONTROL_FILE=()
declare -a CONTROL_START=()
declare -a CONTROL_END=()
declare -a CONTROL_PATTERN=()
declare -a LOG_TYPE=()
declare -a LOG_SIZE=()
declare -a LOG_LIMIT=()
declare -a LOG_ACTION=()

declare -A SEEN_LOG
declare -A RELATION_KEY

cleanup() {
    if [[ -n "${TMP_ROOT:-}" && -d "$TMP_ROOT" ]]; then
        rm -rf -- "$TMP_ROOT"
    fi
}
trap cleanup EXIT

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

command -v awk >/dev/null 2>&1 || die "系统缺少 awk"
command -v sed >/dev/null 2>&1 || die "系统缺少 sed"
command -v grep >/dev/null 2>&1 || die "系统缺少 grep"
command -v find >/dev/null 2>&1 || die "系统缺少 find"
command -v stat >/dev/null 2>&1 || die "系统缺少 stat"

if [[ $EUID -ne 0 ]]; then
    die "请使用 root 运行"
fi

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
echo "  ✓ 正确处理多个 stanza / 多个日志路径 / glob"
echo "  ✓ 不创建任何配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除现有日志"
echo "  ✓ 控制关系无法确认 → 跳过"
echo "  ✓ 不依赖 Python3"
echo

###############################################################################
# 工具函数
###############################################################################

human_size() {
    local f="$1"
    local s

    [[ -e "$f" ]] || {
        echo "不存在"
        return
    }

    s=$(stat -c '%s' -- "$f" 2>/dev/null) || {
        echo "未知"
        return
    }

    if (( s >= 1073741824 )); then
        awk -v n="$s" 'BEGIN {printf "%.2fG", n/1073741824}'
    elif (( s >= 1048576 )); then
        awk -v n="$s" 'BEGIN {printf "%.2fM", n/1048576}'
    elif (( s >= 1024 )); then
        awk -v n="$s" 'BEGIN {printf "%.2fK", n/1024}'
    else
        echo "${s}B"
    fi
}

is_regular_log_candidate() {
    local f="$1"

    [[ -f "$f" ]] || return 1

    case "$f" in
        /var/log/*|/run/log/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

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
        /var/log/apt/eipp.log*)
            echo "apt-eipp"
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
        /var/log/journal/*/*.journal)
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
        *)
            echo "SKIP"
            ;;
    esac
}

###############################################################################
# 获取 logrotate 配置文件
###############################################################################

get_logrotate_files() {
    local f

    [[ -f "$LOGROTATE_MAIN" ]] && echo "$LOGROTATE_MAIN"

    if [[ -d "$LOGROTATE_DIR" ]]; then
        while IFS= read -r -d '' f; do
            [[ -f "$f" ]] || continue
            [[ -L "$f" ]] && continue
            echo "$f"
        done < <(find "$LOGROTATE_DIR" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
    fi
}

###############################################################################
# 扫描日志
###############################################################################

scan_logs() {
    local f

    LOG_FILES=()

    while IFS= read -r -d '' f; do
        is_regular_log_candidate "$f" || continue

        case "$f" in
            /var/log/journal/*/*.journal)
                ;;
            /var/log/installer/*)
                ;;
            *)
                LOG_FILES+=("$f")
                ;;
        esac
    done < <(
        find /var/log /run/log \
            -type f \
            -print0 2>/dev/null |
        sort -z
    )

    # journald 单独加入
    while IFS= read -r -d '' f; do
        LOG_FILES+=("$f")
    done < <(
        find /var/log/journal /run/log/journal \
            -type f \
            -name '*.journal' \
            -print0 2>/dev/null |
        sort -z
    )

    # 去重
    local -a uniq=()
    SEEN_LOG=()

    for f in "${LOG_FILES[@]}"; do
        [[ -n "${SEEN_LOG[$f]+x}" ]] && continue
        SEEN_LOG["$f"]=1
        uniq+=("$f")
    done

    LOG_FILES=("${uniq[@]}")
}

###############################################################################
# 判断 logrotate pattern 是否实际匹配日志
#
# 支持：
#   /var/log/foo.log
#   /var/log/*.log
#   /var/log/apt/*.log
#
# 不把“配置文件存在”直接当成控制关系。
###############################################################################

pattern_matches_log() {
    local pattern="$1"
    local log="$2"

    # 去除常见转义
    pattern="${pattern//\\ / }"

    # logrotate 的通配符由 shell pattern 规则表达。
    case "$log" in
        $pattern)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

###############################################################################
# 解析 logrotate
#
# 输出：
# FILE<TAB>START<TAB>END<TAB>PATTERN<TAB>SIZE<TAB>MAXSIZE
#
# parser 不依赖 Python。
###############################################################################

parse_logrotate_file() {
    local file="$1"

    awk -v FILE="$file" '
    function trim(s) {
        gsub(/^[ \t]+/, "", s)
        gsub(/[ \t]+$/, "", s)
        return s
    }

    function strip_comment(s) {
        # logrotate 注释从未转义的 # 开始
        sub(/[ \t]*#.*/, "", s)
        return s
    }

    function emit(   i,p) {
        if (!active)
            return

        end = NR

        for (i = 1; i <= np; i++) {
            p = patterns[i]
            if (p != "")
                print FILE "\t" start "\t" end "\t" p "\t" size "\t" maxsize
        }

        active = 0
        np = 0
        size = ""
        maxsize = ""
        start = 0
        delete patterns
    }

    {
        raw = $0
        line = strip_comment(raw)
        t = trim(line)

        # 空行
        if (t == "")
            next

        # 如果已经在 stanza 中
        if (active) {

            # 记录 size
            if (t ~ /^size[ \t]+/) {
                x = t
                sub(/^size[ \t]+/, "", x)
                size = x
            }

            # 记录 maxsize
            if (t ~ /^maxsize[ \t]+/) {
                x = t
                sub(/^maxsize[ \t]+/, "", x)
                maxsize = x
            }

            # stanza 结束
            if (t ~ /^}/) {
                emit()
                next
            }

            next
        }

        #######################################################################
        # stanza header
        #
        # 支持：
        #   /var/log/foo.log {
        #   /var/log/foo.log /var/log/bar.log {
        #   /var/log/foo.log
        #   /var/log/bar.log {
        #######################################################################

        if (t ~ /[{]$/) {
            x = t
            sub(/[ \t]*[{][ \t]*$/, "", x)

            n = split(x, a, /[ \t]+/)

            np = 0
            for (i = 1; i <= n; i++) {
                if (a[i] == "")
                    continue

                # 排除明显不是路径的 token
                if (a[i] ~ /^\// || a[i] ~ /[*?[]/) {
                    patterns[++np] = a[i]
                }
            }

            if (np > 0) {
                active = 1
                start = NR
                size = ""
                maxsize = ""
            }

            next
        }

        #######################################################################
        # 处理：
        #   /var/log/foo.log
        #   {
        #######################################################################

        if (t ~ /^[^{}]+$/) {
            save = t

            getline nextline

            nt = trim(strip_comment(nextline))

            if (nt == "{") {
                n = split(save, a, /[ \t]+/)
                np = 0

                for (i = 1; i <= n; i++) {
                    if (a[i] == "")
                        continue

                    if (a[i] ~ /^\// || a[i] ~ /[*?[]/)
                        patterns[++np] = a[i]
                }

                if (np > 0) {
                    active = 1
                    start = NR
                    size = ""
                    maxsize = ""
                }

                next
            }

            # getline 消耗了下一行，因此这里不能简单回退。
            # 该写法只针对极少见的多行 header。
            next
        }
    }

    END {
        emit()
    }
    ' "$file"
}

###############################################################################
# 建立真实控制关系
###############################################################################

find_control_for_log() {
    local log="$1"
    local file
    local rec
    local start
    local end
    local pattern
    local size
    local maxsize

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue

        while IFS=$'\t' read -r rec_file start end pattern size maxsize; do
            [[ -n "$pattern" ]] || continue

            if pattern_matches_log "$pattern" "$log"; then
                echo "$rec_file"$'\t'"$start"$'\t'"$end"$'\t'"$pattern"$'\t'"$size"$'\t'"$maxsize"
                return 0
            fi
        done < <(parse_logrotate_file "$file")

    done < <(get_logrotate_files)

    return 1
}

###############################################################################
# 获取指定 stanza 当前限制
###############################################################################

get_stanza_limit() {
    local file="$1"
    local start="$2"
    local end="$3"

    awk -v s="$start" -v e="$end" '
    NR >= s && NR <= e {
        line=$0
        sub(/^[ \t]+/, "", line)

        if (line ~ /^maxsize[ \t]+/) {
            sub(/^maxsize[ \t]+/, "", line)
            print "maxsize:" line
        }

        if (line ~ /^size[ \t]+/) {
            sub(/^size[ \t]+/, "", line)
            print "size:" line
        }
    }
    ' "$file"
}

###############################################################################
# 输出日志与控制关系
###############################################################################

declare -a REL_LOG=()
declare -a REL_FILE=()
declare -a REL_START=()
declare -a REL_END=()
declare -a REL_PATTERN=()
declare -a REL_CURRENT=()
declare -a REL_RECOMMEND=()

build_relations() {
    local log
    local result
    local file
    local start
    local end
    local pattern
    local size
    local maxsize
    local type
    local rec
    local key

    REL_LOG=()
    REL_FILE=()
    REL_START=()
    REL_END=()
    REL_PATTERN=()
    REL_CURRENT=()
    REL_RECOMMEND=()

    for log in "${LOG_FILES[@]}"; do

        type=$(classify_log "$log")

        [[ "$type" == "journald" ]] && continue

        result=$(find_control_for_log "$log" 2>/dev/null || true)

        if [[ -n "$result" ]]; then
            IFS=$'\t' read -r file start end pattern size maxsize <<< "$result"

            if [[ -n "$maxsize" ]]; then
                current="maxsize $maxsize"
            elif [[ -n "$size" ]]; then
                current="size $size"
            else
                current="未设置"
            fi

            rec=$(recommended_limit "$type")

            REL_LOG+=("$log")
            REL_FILE+=("$file")
            REL_START+=("$start")
            REL_END+=("$end")
            REL_PATTERN+=("$pattern")
            REL_CURRENT+=("$current")
            REL_RECOMMEND+=("$rec")
        fi
    done
}

###############################################################################
# Journald
###############################################################################

journal_persistent_count() {
    find /var/log/journal \
        -type f \
        -name '*.journal' \
        2>/dev/null |
        wc -l |
        awk '{print $1}'
}

journal_runtime_count() {
    find /run/log/journal \
        -type f \
        -name '*.journal' \
        2>/dev/null |
        wc -l |
        awk '{print $1}'
}

journal_get_value() {
    local key="$1"

    [[ -f "$JOURNALD_CONF" ]] || return 1

    awk -v key="$key" '
    {
        line=$0
        sub(/^[ \t]+/, "", line)

        if (line ~ ("^" key "[ \t]*=")) {
            sub(("^" key "[ \t]*=[ \t]*"), "", line)
            print line
        }
    }
    ' "$JOURNALD_CONF" |
    tail -n 1
}

journal_config_source() {
    local key="$1"

    [[ -f "$JOURNALD_CONF" ]] || return 1

    awk -v key="$key" '
    {
        line=$0
        sub(/^[ \t]+/, "", line)

        if (line ~ ("^" key "[ \t]*=")) {
            print "explicit"
            exit
        }

        if (line ~ ("^#" key "[ \t]*=")) {
            print "commented"
            exit
        }
    }
    ' "$JOURNALD_CONF"
}

###############################################################################
# 系统检测
###############################################################################

echo "[1/8] 系统检测"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "  OS       : ${PRETTY_NAME:-unknown}"
else
    echo "  OS       : unknown"
fi

echo "  Kernel   : $(uname -r)"
echo "  CPU      : $(nproc 2>/dev/null || echo unknown)"
echo "  RAM      : $(awk '/MemTotal:/ {printf "%.0f MB", $2/1024}' /proc/meminfo 2>/dev/null)"
echo "  Swap     : $(free -m 2>/dev/null | awk '/^Swap:/ {print $3 " MB"}')（不修改）"

if command -v python3 >/dev/null 2>&1; then
    echo "  Python3  : 可用（本脚本不使用）"
else
    echo "  Python3  : 不需要"
fi

echo

###############################################################################
# 扫描日志
###############################################################################

echo "[2/8] 扫描实际日志文件"

scan_logs

echo "  找到 ${#LOG_FILES[@]} 个当前日志文件"
echo

###############################################################################
# 扫描 logrotate
###############################################################################

echo "[3/8] 精确检测 logrotate 控制关系"

LOGROTATE_COUNT=0

while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    LOGROTATE_COUNT=$((LOGROTATE_COUNT + 1))
done < <(get_logrotate_files)

echo
echo "  找到 $LOGROTATE_COUNT 个真实 logrotate 配置文件"

build_relations

echo
echo "  已识别明确控制关系：${#REL_LOG[@]}"
echo "  其余日志：未找到明确控制关系"
echo

###############################################################################
# journald
###############################################################################

echo "[4/8] 检测 systemd-journald"

PERSISTENT_COUNT=$(journal_persistent_count)
RUNTIME_COUNT=$(journal_runtime_count)

SYSTEM_MAX=$(journal_get_value "SystemMaxFileSize" 2>/dev/null || true)
RUNTIME_MAX=$(journal_get_value "RuntimeMaxFileSize" 2>/dev/null || true)

echo "  persistent journal : $PERSISTENT_COUNT"
echo "  runtime journal    : $RUNTIME_COUNT"

if [[ -n "$SYSTEM_MAX" ]]; then
    echo "  SystemMaxFileSize  : $SYSTEM_MAX"
else
    echo "  SystemMaxFileSize  : 未设置"
fi

if [[ -n "$RUNTIME_MAX" ]]; then
    echo "  RuntimeMaxFileSize : $RUNTIME_MAX"
else
    echo "  RuntimeMaxFileSize : 未设置"
fi

echo

###############################################################################
# 所有日志及控制关系
###############################################################################

echo "[5/8] 所有日志及控制关系"
echo
printf "%-48s %-21s %-10s %-34s %-15s %-8s\n" \
    "日志" "类型" "大小" "真实控制文件" "当前限制" "建议"
echo "---------------------------------------------------------------------------------------------------------------"

for log in "${LOG_FILES[@]}"; do

    type=$(classify_log "$log")
    size=$(human_size "$log")

    file="未找到"
    current="未设置"
    recommend="跳过"

    for ((i=0; i<${#REL_LOG[@]}; i++)); do
        if [[ "${REL_LOG[$i]}" == "$log" ]]; then
            file="${REL_FILE[$i]}"
            current="${REL_CURRENT[$i]}"
            recommend="${REL_RECOMMEND[$i]}"
            break
        fi
    done

    if [[ "$type" == "journald" ]]; then
        file="journald"
        current="journald"
        recommend="跳过"
    fi

    printf "%-48s %-21s %-10s %-34s %-15s %-8s\n" \
        "$log" \
        "$type" \
        "$size" \
        "$file" \
        "$current" \
        "$recommend"
done

echo

###############################################################################
# 修改建议
###############################################################################

echo "[6/8] 修改建议"
echo
echo "建议依据：日志用途，不依据当前文件大小。"
echo "普通日志范围：1M–10M。"
echo "journald 单文件：8M。"
echo

CHANGE_COUNT=0

for ((i=0; i<${#REL_LOG[@]}; i++)); do

    log="${REL_LOG[$i]}"
    type=$(classify_log "$log")
    recommend="${REL_RECOMMEND[$i]}"
    current="${REL_CURRENT[$i]}"

    [[ "$recommend" != "SKIP" ]] || continue

    # 已经有相同 maxsize
    if [[ "$current" == "maxsize $recommend" ]]; then
        continue
    fi

    CHANGE_COUNT=$((CHANGE_COUNT + 1))

    echo "[$CHANGE_COUNT]"
    echo "  日志       : $log"
    echo "  类型       : $type"
    echo "  控制文件   : ${REL_FILE[$i]}"
    echo "  stanza     : ${REL_START[$i]}-${REL_END[$i]}"
    echo "  匹配规则   : ${REL_PATTERN[$i]}"
    echo "  当前限制   : $current"
    echo "  修改目标   : maxsize $recommend"
    echo
done

JOURNAL_CHANGE=0

if [[ -f "$JOURNALD_CONF" ]]; then

    if [[ -z "$SYSTEM_MAX" || "$SYSTEM_MAX" != "$JOURNAL_MAX" ]]; then
        JOURNAL_CHANGE=1
    fi

    if [[ -z "$RUNTIME_MAX" || "$RUNTIME_MAX" != "$JOURNAL_MAX" ]]; then
        JOURNAL_CHANGE=1
    fi

    if (( JOURNAL_CHANGE )); then
        echo "[journald]"
        echo "  控制文件 : $JOURNALD_CONF"
        echo "  SystemMaxFileSize  : ${SYSTEM_MAX:-未设置} → $JOURNAL_MAX"
        echo "  RuntimeMaxFileSize : ${RUNTIME_MAX:-未设置} → $JOURNAL_MAX"
        echo
    fi
fi

###############################################################################
# 修改原则
###############################################################################

echo "[7/8] 修改原则"
echo
echo "  ✓ 只修改真实存在的 /etc/logrotate.conf 或 /etc/logrotate.d/*"
echo "  ✓ 只修改实际匹配目标日志的 stanza"
echo "  ✓ 正确区分同一配置文件中的不同 stanza"
echo "  ✓ maxsize 按日志用途设置"
echo "  ✓ journald 只修改已经存在的 /etc/systemd/journald.conf"
echo "  ✓ 不创建任何配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除当前日志"
echo "  ✓ 不使用 Python3"
echo

TOTAL_CHANGE=$((CHANGE_COUNT + JOURNAL_CHANGE))

if (( TOTAL_CHANGE == 0 )); then
    echo "============================================================"
    echo "                         无需修改"
    echo "============================================================"
    echo
    echo "当前已没有符合本脚本修改条件的项目。"
    exit 0
fi

echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo
echo "本次准备修改："

if (( CHANGE_COUNT > 0 )); then
    echo "  logrotate：$CHANGE_COUNT 个 stanza"
else
    echo "  logrotate：无需修改"
fi

if (( JOURNAL_CHANGE )); then
    echo "  journald ：/etc/systemd/journald.conf"
else
    echo "  journald ：无需修改"
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

###############################################################################
# 精确修改 logrotate stanza
###############################################################################

echo
echo "============================================================"
echo "                         开始修改"
echo "============================================================"
echo

for ((i=0; i<${#REL_LOG[@]}; i++)); do

    log="${REL_LOG[$i]}"
    file="${REL_FILE[$i]}"
    start="${REL_START[$i]}"
    end="${REL_END[$i]}"
    recommend="${REL_RECOMMEND[$i]}"
    current="${REL_CURRENT[$i]}"

    [[ "$recommend" != "SKIP" ]] || continue

    [[ "$current" == "maxsize $recommend" ]] && continue

    [[ -f "$file" ]] || {
        warn "$file 已不存在，跳过"
        FAIL=1
        continue
    }

    echo "修改：$file"
    echo "  日志   : $log"
    echo "  stanza : $start-$end"
    echo "  目标   : maxsize $recommend"

    ###########################################################################
    # 再次确认 stanza 当前确实匹配目标日志
    ###########################################################################

    verified=0

    while IFS=$'\t' read -r pfile pstart pend ppattern psize pmax; do
        [[ "$pfile" == "$file" ]] || continue
        [[ "$pstart" == "$start" ]] || continue
        [[ "$pend" == "$end" ]] || continue

        if pattern_matches_log "$ppattern" "$log"; then
            verified=1
            break
        fi
    done < <(parse_logrotate_file "$file")

    if (( ! verified )); then
        warn "二次控制关系验证失败，拒绝修改"
        FAIL=1
        continue
    fi

    ###########################################################################
    # 精确修改：
    #
    # 1. stanza 内已有 maxsize → 修改该行
    # 2. 没有 maxsize，但有 size → 将 size 改为 maxsize
    # 3. 都没有 → 在 stanza 开头追加 maxsize
    #
    # 使用 awk 生成新内容后覆盖原配置。
    # 不创建新的配置文件。
    ###########################################################################

    tmp="${file}.audit_tmp_$$"

    awk \
        -v s="$start" \
        -v e="$end" \
        -v val="$recommend" '
        BEGIN {
            changed=0
        }

        {
            if (NR >= s && NR <= e) {

                line=$0
                stripped=line
                sub(/^[ \t]+/, "", stripped)

                # 已存在 maxsize
                if (stripped ~ /^maxsize[ \t]+/) {
                    indent=line
                    sub(/[^ \t].*$/, "", indent)
                    print indent "maxsize " val
                    changed=1
                    next
                }

                # 没有 maxsize 时，size 是 logrotate 的大小触发条件。
                # 为避免同时存在 size 与 maxsize，精确替换。
                if (stripped ~ /^size[ \t]+/) {
                    indent=line
                    sub(/[^ \t].*$/, "", indent)
                    print indent "maxsize " val
                    changed=1
                    next
                }
            }

            print
        }

        END {
            if (changed == 0)
                exit 42
        }
    ' "$file" > "$tmp"

    rc=$?

    if (( rc == 42 )); then

        rm -f -- "$tmp"

        # stanza 没有 maxsize / size：
        # 在 stanza 的第一行之后插入。
        awk \
            -v s="$start" \
            -v val="$recommend" '
            NR == s {
                print
                print "    maxsize " val
                next
            }
            {
                print
            }
            ' "$file" > "$tmp"

        rc=$?
    fi

    if (( rc != 0 )); then
        rm -f -- "$tmp"
        warn "生成修改内容失败：$file"
        FAIL=1
        continue
    fi

    if [[ ! -s "$tmp" ]]; then
        rm -f -- "$tmp"
        warn "修改结果为空，拒绝覆盖：$file"
        FAIL=1
        continue
    fi

    # 覆盖原配置文件，不创建新的配置文件。
    cat "$tmp" > "$file"
    rm -f -- "$tmp"

    MODIFIED=$((MODIFIED + 1))
    ok "$log → maxsize $recommend"
done

###############################################################################
# journald 精确修改
###############################################################################

if (( JOURNAL_CHANGE )); then

    echo
    echo "修改：$JOURNALD_CONF"

    [[ -f "$JOURNALD_CONF" ]] || {
        warn "$JOURNALD_CONF 不存在，跳过"
        FAIL=1
    }

    if [[ -f "$JOURNALD_CONF" ]]; then

        tmp="${JOURNALD_CONF}.audit_tmp_$$"

        awk \
            -v target="$JOURNAL_MAX" '
            BEGIN {
                sys=0
                runtime=0
            }

            {
                line=$0
                stripped=line
                sub(/^[ \t]+/, "", stripped)

                if (stripped ~ /^SystemMaxFileSize[ \t]*=/) {
                    indent=line
                    sub(/[^ \t].*$/, "", indent)
                    print indent "SystemMaxFileSize=" target
                    sys=1
                    next
                }

                if (stripped ~ /^#SystemMaxFileSize[ \t]*=/) {
                    indent=line
                    sub(/[^ \t].*$/, "", indent)
                    print indent "SystemMaxFileSize=" target
                    sys=1
                    next
                }

                if (stripped ~ /^RuntimeMaxFileSize[ \t]*=/) {
                    indent=line
                    sub(/[^ \t].*$/, "", indent)
                    print indent "RuntimeMaxFileSize=" target
                    runtime=1
                    next
                }

                if (stripped ~ /^#RuntimeMaxFileSize[ \t]*=/) {
                    indent=line
                    sub(/[^ \t].*$/, "", indent)
                    print indent "RuntimeMaxFileSize=" target
                    runtime=1
                    next
                }

                print
            }

            END {
                if (!sys)
                    print "SystemMaxFileSize=" target

                if (!runtime)
                    print "RuntimeMaxFileSize=" target
            }
            ' "$JOURNALD_CONF" > "$tmp"

        if [[ ! -s "$tmp" ]]; then
            rm -f -- "$tmp"
            warn "journald 配置生成失败"
            FAIL=1
        else
            cat "$tmp" > "$JOURNALD_CONF"
            rm -f -- "$tmp"

            ok "SystemMaxFileSize=$JOURNAL_MAX"
            ok "RuntimeMaxFileSize=$JOURNAL_MAX"

            MODIFIED=$((MODIFIED + 1))
        fi
    fi
fi

###############################################################################
# 修改后验证 logrotate 语法
###############################################################################

echo
echo "============================================================"
echo "                         修改后验证"
echo "============================================================"
echo

if command -v logrotate >/dev/null 2>&1; then

    echo "------------------------------------------------------------"
    echo "                     验证 logrotate"
    echo "------------------------------------------------------------"

    if logrotate -d "$LOGROTATE_MAIN" >/dev/null 2>&1; then
        ok "logrotate 配置语法正常"
    else
        warn "logrotate 配置检查失败"
        FAIL=1
    fi
else
    warn "系统没有 logrotate，无法执行语法验证"
    FAIL=1
fi

###############################################################################
# 精确验证每个目标 stanza
###############################################################################

echo
echo "------------------------------------------------------------"
echo "                    精确验证控制关系"
echo "------------------------------------------------------------"

for ((i=0; i<${#REL_LOG[@]}; i++)); do

    log="${REL_LOG[$i]}"
    file="${REL_FILE[$i]}"
    recommend="${REL_RECOMMEND[$i]}"

    [[ "$recommend" != "SKIP" ]] || continue

    result=$(find_control_for_log "$log" 2>/dev/null || true)

    if [[ -z "$result" ]]; then
        echo "✗ $log : 修改后无法重新确认控制关系"
        FAIL=1
        continue
    fi

    IFS=$'\t' read -r vfile vstart vend vpattern vsize vmax <<< "$result"

    if [[ "$vfile" != "$file" ]]; then
        echo "✗ $log : 控制文件发生异常变化"
        FAIL=1
        continue
    fi

    if [[ -n "$vmax" && "$vmax" == "$recommend" ]]; then
        ok "$log : maxsize $recommend"
    else
        echo "✗ $log : 期望 maxsize $recommend，实际 ${vmax:-未设置}"
        FAIL=1
    fi
done

###############################################################################
# journald 精确验证
###############################################################################

if [[ -f "$JOURNALD_CONF" ]]; then

    echo
    echo "------------------------------------------------------------"
    echo "                    验证 systemd-journald"
    echo "------------------------------------------------------------"

    VSYS=$(journal_get_value "SystemMaxFileSize" 2>/dev/null || true)
    VRUN=$(journal_get_value "RuntimeMaxFileSize" 2>/dev/null || true)

    if [[ "$VSYS" == "$JOURNAL_MAX" ]]; then
        ok "SystemMaxFileSize = $VSYS"
    else
        echo "✗ SystemMaxFileSize : 期望 $JOURNAL_MAX，实际 ${VSYS:-未设置}"
        FAIL=1
    fi

    if [[ "$VRUN" == "$JOURNAL_MAX" ]]; then
        ok "RuntimeMaxFileSize = $VRUN"
    else
        echo "✗ RuntimeMaxFileSize : 期望 $JOURNAL_MAX，实际 ${VRUN:-未设置}"
        FAIL=1
    fi
fi

###############################################################################
# 最终报告
###############################################################################

echo
echo "============================================================"
echo "                         最终结果"
echo "============================================================"
echo

if (( FAIL == 0 )); then
    echo "✓ 所有实际修改项目均通过精确验证"
else
    echo "⚠ 存在验证失败项目，请检查上面的结果"
fi

echo
echo "修改数量：$MODIFIED"
echo
echo "最终日志控制关系："

for ((i=0; i<${#REL_LOG[@]}; i++)); do

    log="${REL_LOG[$i]}"
    type=$(classify_log "$log")

    result=$(find_control_for_log "$log" 2>/dev/null || true)

    if [[ -n "$result" ]]; then
        IFS=$'\t' read -r file start end pattern size maxsize <<< "$result"

        if [[ -n "$maxsize" ]]; then
            limit="maxsize $maxsize"
        elif [[ -n "$size" ]]; then
            limit="size $size"
        else
            limit="未设置"
        fi

        echo "  $log"
        echo "    类型     : $type"
        echo "    控制文件 : $file"
        echo "    stanza   : $start-$end"
        echo "    匹配规则 : $pattern"
        echo "    限制     : $limit"
    fi
done

echo
echo "journald："

if [[ -f "$JOURNALD_CONF" ]]; then
    echo "  控制文件            : $JOURNALD_CONF"
    echo "  SystemMaxFileSize    : $(journal_get_value SystemMaxFileSize 2>/dev/null || echo 未设置)"
    echo "  RuntimeMaxFileSize   : $(journal_get_value RuntimeMaxFileSize 2>/dev/null || echo 未设置)"
else
    echo "  /etc/systemd/journald.conf 不存在 → 跳过"
fi

echo
echo "============================================================"

if (( FAIL == 0 )); then
    echo "✓ 完成"
    exit 0
else
    echo "⚠ 完成，但存在验证失败"
    exit 1
fi
