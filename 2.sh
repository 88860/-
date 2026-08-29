#!/bin/bash
set -u

# ============================================================
# Debian 13 日志大小审计与精准限制
# 纯 Bash / 无 Python / 不创建系统配置 / 不备份 / 不删除日志
# ============================================================

[ "$(id -u)" = 0 ] || {
    echo "错误：必须以 root 运行。"
    exit 1
}

command -v logrotate >/dev/null 2>&1 || {
    echo "错误：系统缺少 logrotate。"
    exit 1
}

ROOT=/etc/logrotate.conf
JCONF=/etc/systemd/journald.conf
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------

die() {
    echo "错误：$*"
    exit 1
}

sz() {
    stat -c '%s' "$1" 2>/dev/null || echo 0
}

human() {
    numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"
}

# ------------------------------------------------------------
# 日志建议
# ------------------------------------------------------------

recommend() {
    case "$1" in
        /var/log/alternatives.log) echo 2M ;;
        /var/log/apt/history.log) echo 3M ;;
        /var/log/apt/term.log) echo 5M ;;
        /var/log/btmp) echo 5M ;;
        /var/log/dpkg.log) echo 5M ;;
        /var/log/wtmp) echo 5M ;;
        *) echo SKIP ;;
    esac
}

type_of() {
    case "$1" in
        /var/log/alternatives.log) echo alternatives ;;
        /var/log/apt/eipp.log.xz) echo apt-eipp ;;
        /var/log/apt/history.log) echo apt-history ;;
        /var/log/apt/term.log) echo apt-terminal ;;
        /var/log/btmp) echo failed-login-history ;;
        /var/log/dpkg.log) echo dpkg ;;
        /var/log/wtmp) echo login-history ;;
        /var/log/wtmp.db) echo wtmp-db ;;
        /var/log/lastlog) echo lastlog ;;
        /var/log/installer/*) echo installer ;;
        *) echo unknown ;;
    esac
}

# ------------------------------------------------------------
# 收集真实存在的 logrotate 配置
# ------------------------------------------------------------

: > "$TMP/configs"

[ -f "$ROOT" ] && echo "$ROOT" >> "$TMP/configs"

if [ -d /etc/logrotate.d ]; then
    find /etc/logrotate.d -maxdepth 1 -type f -readable -print \
        | sort >> "$TMP/configs"
fi

sort -u "$TMP/configs" -o "$TMP/configs"

CFG_COUNT=$(wc -l < "$TMP/configs")

# ------------------------------------------------------------
# 解析 stanza
#
# 输出：
# 文件 TAB 起始行 TAB 结束行 TAB 日志路径列表 TAB 规则
#
# 规则只识别：
#   size
#   minsize
#   maxsize
# ------------------------------------------------------------

parse_file() {
    local f="$1"

    awk '
    function trim(s) {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        return s
    }

    function emit() {
        if (inside && paths != "") {
            printf "%s\t%d\t%d\t%s\t%s\n",
                   FILENAME, start, NR-1, paths, rule
        }
        paths=""
        rule=""
        inside=0
        start=0
    }

    {
        line=$0

        # 忽略纯注释
        if (line ~ /^[ \t]*#/) next

        if (!inside) {
            # stanza 开头：一行或多行路径，随后出现 {
            if (line ~ /{[ \t]*$/) {
                x=line
                sub(/[ \t]*{[ \t]*$/, "", x)
                x=trim(x)

                if (x != "") {
                    paths=x
                    start=NR
                    inside=1
                }
            }
            next
        }

        # stanza 内
        if (line ~ /^[ \t]*size[ \t]+[^ \t#]+/) {
            x=line
            sub(/^[ \t]*size[ \t]+/, "", x)
            sub(/[ \t#].*$/, "", x)
            rule="size " x
        }

        if (line ~ /^[ \t]*minsize[ \t]+[^ \t#]+/) {
            x=line
            sub(/^[ \t]*minsize[ \t]+/, "", x)
            sub(/[ \t#].*$/, "", x)
            rule="minsize " x
        }

        if (line ~ /^[ \t]*maxsize[ \t]+[^ \t#]+/) {
            x=line
            sub(/^[ \t]*maxsize[ \t]+/, "", x)
            sub(/[ \t#].*$/, "", x)
            rule="maxsize " x
        }

        if (line ~ /^[ \t]*}/) {
            emit()
        }
    }

    END {
        if (inside)
            printf "%s\t%d\t%d\t%s\t%s\n",
                   FILENAME, start, NR, paths, rule
    }
    ' "$f"
}

: > "$TMP/stanzas"

while IFS= read -r f; do
    parse_file "$f"
done < "$TMP/configs" > "$TMP/stanzas"

# ------------------------------------------------------------
# 匹配日志与 stanza
# ------------------------------------------------------------

match_path() {
    local log="$1"
    local pattern="$2"

    # 精确路径
    [ "$pattern" = "$log" ] && return 0

    # shell glob
    case "$log" in
        $pattern) return 0 ;;
    esac

    return 1
}

# ------------------------------------------------------------
# 扫描日志
# ------------------------------------------------------------

: > "$TMP/logs"

find /var/log -type f -readable 2>/dev/null \
    ! -path '/var/log/journal/*' \
    -print | sort > "$TMP/logs"

JOURNALS=$(find /var/log/journal /run/log/journal \
    -type f \( -name '*.journal' -o -name '*.journal~' \) \
    -readable 2>/dev/null | sort -u)

LOGCOUNT=$(wc -l < "$TMP/logs")
JCOUNT=$(printf '%s\n' "$JOURNALS" | sed '/^$/d' | wc -l)

echo
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
echo "  ✓ 正确处理多个 stanza / 多个日志路径"
echo "  ✓ 正确区分 size / minsize / maxsize"
echo "  ✓ 不创建任何系统配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除现有日志"
echo "  ✓ 控制关系无法确认 → 跳过"
echo "  ✓ 不依赖 Python3"

echo
echo "[1/8] 系统检测"
echo "  OS       : $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "  Kernel   : $(uname -r)"
echo "  CPU      : $(nproc)"
echo "  RAM      : $(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo)"
echo "  Swap     : $(awk '/SwapTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo)（不修改）"
echo "  Python3  : 不需要"

echo
echo "[2/8] 扫描实际日志文件"
echo "  找到 $LOGCOUNT 个普通日志文件"
echo "  找到 $JCOUNT 个 journal 文件"

echo
echo "[3/8] 精确检测 logrotate 控制关系"
echo
echo "  找到 $CFG_COUNT 个真实 logrotate 配置文件"

# ------------------------------------------------------------
# 建立日志 → stanza 唯一关系
#
# 格式：
# log | cfg | start | end | paths | rule
# ------------------------------------------------------------

: > "$TMP/relations"

while IFS= read -r log; do
    found=0
    rel=""

    while IFS=$'\t' read -r cfg start end paths rule; do
        [ -n "$cfg" ] || continue

        oldIFS="$IFS"
        IFS=' '
        for p in $paths; do
            if match_path "$log" "$p"; then
                found=$((found+1))
                rel="$cfg|$start|$end|$paths|$rule"
            fi
        done
        IFS="$oldIFS"
    done < "$TMP/stanzas"

    if [ "$found" -eq 1 ]; then
        printf '%s\t%s\n' "$log" "$rel" >> "$TMP/relations"
    elif [ "$found" -gt 1 ]; then
        printf '%s\tAMBIGUOUS\n' "$log" >> "$TMP/relations"
    else
        printf '%s\tNONE\n' "$log" >> "$TMP/relations"
    fi
done < "$TMP/logs"

CLEAR=$(awk -F '\t' '$2!="NONE" && $2!="AMBIGUOUS"{n++}END{print n+0}' "$TMP/relations")
NONE=$(awk -F '\t' '$2=="NONE"{n++}END{print n+0}' "$TMP/relations")
AMB=$(awk -F '\t' '$2=="AMBIGUOUS"{n++}END{print n+0}' "$TMP/relations")

echo
echo "  已识别明确控制关系：$CLEAR"
echo "  未找到控制关系    ：$NONE"
echo "  存在歧义          ：$AMB"

# ------------------------------------------------------------
# journald 当前值
# 只读取 /etc/systemd/journald.conf
# 不读取 drop-in 作为修改目标
# ------------------------------------------------------------

journal_value() {
    local key="$1"

    [ -f "$JCONF" ] || {
        echo "未找到"
        return
    }

    awk -v k="$key" '
    /^[ \t]*#/ {next}
    $0 ~ "^[ \t]*" k "[ \t]*=" {
        x=$0
        sub("^[ \t]*" k "[ \t]*=[ \t]*", "", x)
        sub(/[ \t#].*$/, "", x)
        v=x
    }
    END {
        if (v=="") print "未设置"
        else print v
    }
    ' "$JCONF"
}

SYSJ=$(journal_value SystemMaxFileSize)
RUNJ=$(journal_value RuntimeMaxFileSize)

echo
echo "[4/8] 检测 systemd-journald"
echo "  persistent journal : $(find /var/log/journal -type f -name '*.journal' 2>/dev/null | wc -l)"
echo "  runtime journal    : $(find /run/log/journal -type f -name '*.journal' 2>/dev/null | wc -l)"
echo "  SystemMaxFileSize  : $SYSJ"
echo "  RuntimeMaxFileSize : $RUNJ"

# ------------------------------------------------------------
# 展示所有日志
# ------------------------------------------------------------

echo
echo "[5/8] 所有日志及控制关系"
echo
printf '%-43s %-20s %-10s %-34s %-16s %-8s\n' \
"日志" "类型" "大小" "真实控制文件" "当前规则" "建议"
echo "---------------------------------------------------------------------------------------------------------------"

while IFS=$'\t' read -r log rel; do
    size=$(human "$(sz "$log")")
    typ=$(type_of "$log")
    rec=$(recommend "$log")

    cfg="未找到"
    rule="未设置"

    if [ "$rel" != "NONE" ] && [ "$rel" != "AMBIGUOUS" ]; then
        IFS='|' read -r cfg start end paths rule <<< "$rel"
        [ -n "$rule" ] || rule="none"
    elif [ "$rel" = "AMBIGUOUS" ]; then
        cfg="歧义"
    fi

    printf '%-43s %-20s %-10s %-34s %-16s %-8s\n' \
        "$log" "$typ" "$size" "$cfg" "$rule" "$rec"
done < "$TMP/relations"

if [ "$JCOUNT" -gt 0 ]; then
    while IFS= read -r j; do
        [ -n "$j" ] || continue
        printf '%-43s %-20s %-10s %-34s %-16s %-8s\n' \
            "$j" "journald" "$(human "$(sz "$j")")" "$JCONF" "journal" "8M"
    done <<< "$JOURNALS"
fi

# ------------------------------------------------------------
# 判断当前规则是否合理
#
# size/minsize/maxsize 都保留其语义。
# 已存在规则：
#   2M–5M → 保持
#   minsize 1M → 保持
#   其它 → 根据用途决定
# ------------------------------------------------------------

rule_state() {
    local rule="$1"
    local target="$2"

    [ "$rule" = "none" ] || [ -z "$rule" ] && {
        echo ADD
        return
    }

    case "$rule" in
        "maxsize "*)
            echo KEEP
            return
            ;;
        "size "*)
            echo KEEP
            return
            ;;
        "minsize "*)
            echo KEEP
            return
            ;;
    esac

    echo ADD
}

# ------------------------------------------------------------
# 生成修改计划
# ------------------------------------------------------------

: > "$TMP/plan"

echo
echo "[6/8] 修改建议"
echo
echo "建议依据：日志用途，而不是当前文件大小。"
echo
echo "logrotate："
echo "  size    → 按大小触发轮转"
echo "  minsize → 达到大小且满足时间条件"
echo "  maxsize → 在时间轮转条件下增加大小上限"
echo
echo "已存在大小规则不强制转换；只有没有大小规则时才添加 maxsize。"
echo

while IFS=$'\t' read -r log rel; do
    rec=$(recommend "$log")

    [ "$rec" != "SKIP" ] || continue
    [ "$rel" != "NONE" ] || continue
    [ "$rel" != "AMBIGUOUS" ] || continue

    IFS='|' read -r cfg start end paths rule <<< "$rel"

    [ -n "$rule" ] || rule="none"

    state=$(rule_state "$rule" "$rec")

    if [ "$state" = ADD ]; then
        echo "  $log"
        echo "    控制 : $cfg"
        echo "    stanza: $start-$end"
        echo "    当前 : $rule"
        echo "    操作 : 添加 maxsize $rec"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$log" "$cfg" "$start" "$end" "$rec" >> "$TMP/plan"
    else
        echo "  $log"
        echo "    当前 : $rule"
        echo "    操作 : 保持"
    fi
    echo
done < "$TMP/relations"

# journald
JPLAN=0

if [ -f "$JCONF" ]; then
    [ "$SYSJ" = "8M" ] || JPLAN=$((JPLAN+1))
    [ "$RUNJ" = "8M" ] || JPLAN=$((JPLAN+1))

    echo "journald："
    echo "  SystemMaxFileSize  : $SYSJ → 8M"
    echo "  RuntimeMaxFileSize : $RUNJ → 8M"
else
    echo "journald："
    echo "  /etc/systemd/journald.conf 不存在 → 跳过"
fi

PLANCOUNT=$(wc -l < "$TMP/plan")

echo
echo "[7/8] 安全确认"
echo
echo "本次准备修改："
echo "  logrotate：$PLANCOUNT 个 stanza"
echo "  journald ：$JPLAN 项"
echo
echo "⚠ 不创建任何系统配置文件"
echo "⚠ 不备份"
echo "⚠ 不删除当前日志"
echo

if [ "$PLANCOUNT" -eq 0 ] && [ "$JPLAN" -eq 0 ]; then
    echo "没有需要修改的配置。"
    echo
    echo "审计完成，系统无需修改。"
    exit 0
fi

printf "确认执行精准修改？[y/N] "
read -r ans

case "$ans" in
    y|Y|yes|YES) ;;
    *)
        echo
        echo "已取消，未修改系统。"
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 修改前验证
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                       修改前验证"
echo "============================================================"

if ! logrotate -d "$ROOT" >/dev/null 2>&1; then
    echo "✗ 修改前 logrotate 配置语法错误"
    exit 1
fi

echo "✓ 修改前 logrotate 配置语法正常"

# ------------------------------------------------------------
# 修改 stanza
#
# 每个文件只处理一次。
# 使用原始行号从后往前修改，避免行号偏移。
# 在 stanza 的 { 后插入 maxsize。
# ------------------------------------------------------------

modify_file() {
    local cfg="$1"

    awk -v plan="$TMP/plan" -v target="$cfg" '
    BEGIN {
        FS="\t"
        n=0
        while ((getline < plan) > 0) {
            if ($2 == target) {
                n++
                s[n]=$3
                e[n]=$4
                v[n]=$5
            }
        }
        close(plan)
    }

    {
        ins=0

        for (i=1;i<=n;i++) {
            if (NR==s[i]) {
                wanted[i]=1
            }
        }

        print

        if (wanted[1] && $0 ~ /{[ \t]*$/) {
            for (i=1;i<=n;i++) {
                if (wanted[i]) {
                    print "    maxsize " v[i]
                    wanted[i]=0
                }
            }
        }
    }
    ' "$cfg" > "$TMP/new"

    cat "$TMP/new" > "$cfg"
}

# 为了避免同一文件多次处理
cut -f2 "$TMP/plan" | sort -u | while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue

    echo
    echo "修改：$cfg"
    modify_file "$cfg"
    echo "✓ $cfg 已写入"
done

# ------------------------------------------------------------
# journald
#
# 只修改已存在的键。
# 如果键不存在则追加到现有文件末尾。
# 不创建 journald.conf。
# ------------------------------------------------------------

set_journal_key() {
    local key="$1"
    local value="$2"

    [ -f "$JCONF" ] || return 0

    if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$JCONF"; then
        sed -i -E \
            "s|^[[:space:]]*${key}[[:space:]]*=.*$|${key}=${value}|" \
            "$JCONF"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$JCONF"
    fi
}

if [ -f "$JCONF" ]; then
    if [ "$SYSJ" != "8M" ]; then
        set_journal_key SystemMaxFileSize 8M
    fi

    if [ "$RUNJ" != "8M" ]; then
        set_journal_key RuntimeMaxFileSize 8M
    fi
fi

# ------------------------------------------------------------
# 修改后验证
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                       修改后验证"
echo "============================================================"

FAIL=0

echo
echo "------------------------------------------------------------"
echo "                    验证 logrotate"
echo "------------------------------------------------------------"

if logrotate -d "$ROOT" >/dev/null 2>&1; then
    echo "✓ logrotate 配置语法正常"
else
    echo "✗ logrotate 配置语法错误"
    FAIL=1
fi

# ------------------------------------------------------------
# 重新解析同一个 stanza
# 不再 grep 整个配置文件。
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "                 精确重新解析控制 stanza"
echo "------------------------------------------------------------"

: > "$TMP/after"

while IFS= read -r cfg; do
    parse_file "$cfg"
done < "$TMP/configs" > "$TMP/after"

while IFS=$'\t' read -r log cfg start end target; do
    [ -n "$log" ] || continue

    actual="none"

    while IFS=$'\t' read -r af as ae ap ar; do
        [ "$af" = "$cfg" ] || continue
        [ "$as" = "$start" ] || continue

        [ -n "$ar" ] && actual="$ar"
        break
    done < "$TMP/after"

    if [ "$actual" = "maxsize $target" ]; then
        echo "✓ $log → $actual"
    else
        echo "✗ $log → 期望 maxsize $target，实际 $actual"
        FAIL=1
    fi
done < "$TMP/plan"

# ------------------------------------------------------------
# journald 验证
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "                    验证 systemd-journald"
echo "------------------------------------------------------------"

if [ -f "$JCONF" ]; then
    NS=$(journal_value SystemMaxFileSize)
    NR=$(journal_value RuntimeMaxFileSize)

    if [ "$NS" = "8M" ]; then
        echo "✓ SystemMaxFileSize = 8M"
    else
        echo "✗ SystemMaxFileSize = $NS"
        FAIL=1
    fi

    if [ "$NR" = "8M" ]; then
        echo "✓ RuntimeMaxFileSize = 8M"
    else
        echo "✗ RuntimeMaxFileSize = $NR"
        FAIL=1
    fi
else
    echo "✓ journald.conf 不存在，未修改"
fi

# ------------------------------------------------------------
# 最终控制关系
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                       最终结果"
echo "============================================================"

if [ "$FAIL" -eq 0 ]; then
    echo "✓ 全部验证通过"
else
    echo "✗ 存在验证失败项目"
fi

echo
echo "日志控制关系："

while IFS=$'\t' read -r log rel; do
    printf '%s : ' "$log"

    if [ "$rel" = "NONE" ]; then
        echo "未找到明确控制关系 → 跳过"
    elif [ "$rel" = "AMBIGUOUS" ]; then
        echo "控制关系存在歧义 → 跳过"
    else
        IFS='|' read -r cfg start end paths rule <<< "$rel"
        echo "$cfg / stanza $start-$end / $rule"
    fi
done < "$TMP/relations"

if [ "$JCOUNT" -gt 0 ]; then
    echo
    echo "journald："
    echo "  控制文件           : $JCONF"
    echo "  SystemMaxFileSize   : $(journal_value SystemMaxFileSize)"
    echo "  RuntimeMaxFileSize  : $(journal_value RuntimeMaxFileSize)"
fi

echo

if [ "$FAIL" -eq 0 ]; then
    echo "============================================================"
    echo "                         完成"
    echo "============================================================"
    exit 0
else
    echo "============================================================"
    echo "                         验证失败"
    echo "============================================================"
    exit 1
fi
