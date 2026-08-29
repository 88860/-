#!/bin/bash
# Debian 13 日志大小审计与精准限制
# 无 Python3 / 不备份 / 不删除日志 / 不创建配置文件

set -u

LOGROTATE_CONF="/etc/logrotate.conf"
LOGROTATE_DIR="/etc/logrotate.d"
JOURNAL_CONF="/etc/systemd/journald.conf"

declare -A TARGET
TARGET["/var/log/alternatives.log"]="2M"
TARGET["/var/log/apt/history.log"]="3M"
TARGET["/var/log/apt/term.log"]="5M"
TARGET["/var/log/btmp"]="5M"
TARGET["/var/log/dpkg.log"]="5M"
TARGET["/var/log/wtmp"]="5M"

declare -A FILE ST EN RULE PLAN
declare -a LOGS

die(){ echo "错误：$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "请使用 root 运行"
command -v awk >/dev/null || die "系统缺少 awk"
command -v sed >/dev/null || die "系统缺少 sed"
command -v logrotate >/dev/null || die "系统缺少 logrotate"

echo "============================================================"
echo " Debian 13 日志大小审计与精准限制"
echo " 扫描 → 识别 → 分类 → 建议 → 确认 → 修改 → 验证"
echo "============================================================"
echo
echo "目标：普通日志按用途设置 2M–5M；journald 单文件 8M"
echo
echo "原则："
echo "  ✓ 只修改真实存在且实际控制日志的配置"
echo "  ✓ 以完整 logrotate stanza 为唯一修改单位"
echo "  ✓ 同一配置文件多个 stanza 独立处理"
echo "  ✓ 同一 stanza 多日志路径统一处理"
echo "  ✓ 正确区分 size / minsize / maxsize"
echo "  ✓ 控制关系不唯一 → 跳过"
echo "  ✓ 不创建配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除日志"
echo "  ✓ 不依赖 Python3"
echo

echo "[1/8] 系统检测"

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "  OS       : ${PRETTY_NAME:-unknown}"
else
    echo "  OS       : unknown"
fi

echo "  Kernel   : $(uname -r)"
echo "  CPU      : $(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')"
echo "  RAM      : $(awk '/MemTotal:/ {printf "%.0f MB",$2/1024}' /proc/meminfo)"
echo "  Swap     : $(awk '/SwapTotal:/ {printf "%.0f MB",$2/1024}' /proc/meminfo)"
echo "  Python3  : 不需要"
echo

echo "[2/8] 扫描实际日志文件"

while IFS= read -r -d '' f; do
    LOGS+=("$f")
done < <(
    find /var/log -type f \
        ! -path '/var/log/journal/*' \
        -print0 2>/dev/null
)

JOURNALS=()
while IFS= read -r -d '' f; do
    JOURNALS+=("$f")
done < <(
    find /var/log/journal /run/log/journal \
        -type f \( -name '*.journal' -o -name '*.journal~' \) \
        -print0 2>/dev/null
)

echo "  找到 ${#LOGS[@]} 个普通日志文件"
echo "  找到 ${#JOURNALS[@]} 个 journal 文件"
echo

echo "[3/8] 精确检测 logrotate 控制关系"
echo

declare -a CFGS

[[ -f "$LOGROTATE_CONF" ]] && CFGS+=("$LOGROTATE_CONF")

if [[ -d "$LOGROTATE_DIR" ]]; then
    while IFS= read -r -d '' f; do
        CFGS+=("$f")
    done < <(
        find "$LOGROTATE_DIR" -maxdepth 1 -type f -print0 2>/dev/null |
        sort -z
    )
fi

echo "  找到 ${#CFGS[@]} 个真实 logrotate 配置文件"
echo

# ------------------------------------------------------------
# 解析配置：
# 输出：
# file<TAB>start<TAB>end<TAB>patterns<TAB>rule
#
# rule = none / size X / minsize X / maxsize X
#
# 重要：
# 一个 stanza 从“日志路径 + {”开始，到对应 } 结束。
# 所有检测、修改、验证都基于此结构。
# ------------------------------------------------------------

parse_cfg()
{
    local cfg="$1"

    awk '
    function trim(s){
        sub(/^[[:space:]]+/,"",s)
        sub(/[[:space:]]+$/,"",s)
        return s
    }

    function clean(s){
        s=trim(s)
        sub(/[[:space:]]+\{[[:space:]]*$/,"",s)
        return s
    }

    function rule_of(i,   x,a){
        for(i=1;i<=n;i++){
            x=lines[i]
            sub(/^[[:space:]]+/,"",x)

            if(x ~ /^(size|minsize|maxsize)([[:space:]]+|=)/){
                split(x,a,/([[:space:]]+|=)/)
                return a[1] " " a[2]
            }
        }
        return "none"
    }

    {
        raw=$0
        lines[++n]=raw
    }

    END{
        in=0
        start=0
        pats=""

        for(i=1;i<=n;i++){
            x=trim(lines[i])

            if(!in){
                if(x=="" || x ~ /^#/) continue

                # stanza 起始必须包含 {
                if(x ~ /\{[[:space:]]*$/){
                    in=1
                    start=i
                    pats=clean(x)
                }
                continue
            }

            if(x ~ /^\}/){
                print FILENAME "\t" start "\t" i "\t" pats "\t" rule_of(i)
                in=0
                start=0
                pats=""
                continue
            }
        }
    }' "$cfg"
}

TMP_PARSE=$(mktemp)
trap 'rm -f "$TMP_PARSE" "$TMP_EDIT" "$TMP_JOURNAL"' EXIT

for cfg in "${CFGS[@]}"; do
    parse_cfg "$cfg" >> "$TMP_PARSE"
done

# ------------------------------------------------------------
# 判断实际日志是否匹配 stanza 中的某个 pattern
# 支持：
#   /var/log/foo.log
#   /var/log/foo/*.log
#   /var/log/foo-*
#
# 不把模糊匹配当成唯一控制关系。
# ------------------------------------------------------------

match_pattern()
{
    local log="$1"
    local patterns="$2"
    local p

    for p in $patterns; do
        p="${p#\"}"
        p="${p%\"}"
        p="${p#\'}"
        p="${p%\'}"

        case "$log" in
            $p) return 0 ;;
        esac
    done

    return 1
}

# ------------------------------------------------------------
# 为指定日志寻找唯一 stanza
# ------------------------------------------------------------

find_control()
{
    local log="$1"
    local count=0
    local result cfg s e pats rule

    while IFS=$'\t' read -r cfg s e pats rule; do
        [[ -n "$cfg" ]] || continue

        if match_pattern "$log" "$pats"; then
            count=$((count+1))
            result="$cfg"$'\t'"$s"$'\t'"$e"$'\t'"$pats"$'\t'"$rule"
        fi
    done < "$TMP_PARSE"

    if [[ $count -eq 1 ]]; then
        printf '%s\n' "$result"
    elif [[ $count -eq 0 ]]; then
        return 1
    else
        return 2
    fi
}

declare -A CTRL_COUNT
declare -A CTRL_DATA

for log in "${LOGS[@]}"; do
    if data=$(find_control "$log"); then
        CTRL_COUNT["$log"]=1
        CTRL_DATA["$log"]="$data"
    else
        rc=$?
        if [[ $rc -eq 2 ]]; then
            CTRL_COUNT["$log"]=-1
        else
            CTRL_COUNT["$log"]=0
        fi
    fi
done

echo "  已识别明确控制关系：$(for x in "${LOGS[@]}"; do [[ ${CTRL_COUNT[$x]:-0} == 1 ]] && echo x; done | wc -l)"
echo "  未找到控制关系    ：$(for x in "${LOGS[@]}"; do [[ ${CTRL_COUNT[$x]:-0} == 0 ]] && echo x; done | wc -l)"
echo "  存在歧义          ：$(for x in "${LOGS[@]}"; do [[ ${CTRL_COUNT[$x]:-0} == -1 ]] && echo x; done | wc -l)"
echo

echo "[4/8] 检测 systemd-journald"

persistent=0
runtime=0

[[ -d /var/log/journal ]] && persistent=1
[[ -d /run/log/journal ]] && runtime=1

journal_get()
{
    local key="$1"

    if [[ -f "$JOURNAL_CONF" ]]; then
        awk -v k="$key" '
        /^[[:space:]]*#/ {next}
        {
            x=$0
            sub(/^[[:space:]]+/,"",x)
            if(x ~ ("^" k "[[:space:]]*=")){
                sub(("^" k "[[:space:]]*=[[:space:]]*"),"",x)
                print x
            }
        }' "$JOURNAL_CONF" | tail -n1
    fi
}

SYS_FILE=$(journal_get SystemMaxFileSize)
RUN_FILE=$(journal_get RuntimeMaxFileSize)

echo "  persistent journal : $persistent"
echo "  runtime journal    : $runtime"
echo "  SystemMaxFileSize  : ${SYS_FILE:-未设置}"
echo "  RuntimeMaxFileSize : ${RUN_FILE:-未设置}"
echo

echo "[5/8] 所有日志及控制关系"
echo

printf '%-42s %-20s %-10s %-36s %-16s %s\n' \
"日志" "类型" "大小" "真实控制文件" "当前规则" "建议"
printf '%s\n' "$(printf '%0.s-' {1..150})"

log_type()
{
    case "$1" in
        /var/log/alternatives.log) echo alternatives ;;
        /var/log/apt/history.log) echo apt-history ;;
        /var/log/apt/term.log) echo apt-terminal ;;
        /var/log/btmp) echo failed-login-history ;;
        /var/log/dpkg.log) echo dpkg ;;
        /var/log/wtmp) echo login-history ;;
        /var/log/wtmp.db) echo wtmp-db ;;
        /var/log/installer/*) echo installer ;;
        /var/log/apt/eipp.log.xz) echo apt-eipp ;;
        /var/log/lastlog) echo lastlog ;;
        *) echo unknown ;;
    esac
}

human_size()
{
    stat -c '%s' "$1" 2>/dev/null |
    awk '
    function h(n){
        if(n>=1073741824) return sprintf("%.1fG",n/1073741824)
        if(n>=1048576) return sprintf("%.1fM",n/1048576)
        if(n>=1024) return sprintf("%.1fK",n/1024)
        return n "B"
    }
    {print h($1)}'
}

for log in "${LOGS[@]}"; do
    type=$(log_type "$log")
    size=$(human_size "$log")

    if [[ ${CTRL_COUNT[$log]:-0} == 1 ]]; then
        IFS=$'\t' read -r cfg s e pats rule <<< "${CTRL_DATA[$log]}"
        base="${cfg#/etc/}"
        target="${TARGET[$log]:-}"
        [[ -n "$target" ]] || target="SKIP"

        if [[ "$rule" == "none" && "$target" != SKIP ]]; then
            suggest="$target"
        else
            suggest="$rule"
        fi

        printf '%-42s %-20s %-10s %-36s %-16s %s\n' \
            "$log" "$type" "$size" "$cfg" "$rule" "$suggest"

        FILE["$log"]="$cfg"
        ST["$log"]="$s"
        EN["$log"]="$e"
        RULE["$log"]="$rule"
    elif [[ ${CTRL_COUNT[$log]:-0} == -1 ]]; then
        printf '%-42s %-20s %-10s %-36s %-16s %s\n' \
            "$log" "$type" "$size" "歧义" "未确定" "SKIP"
    else
        printf '%-42s %-20s %-10s %-36s %-16s %s\n' \
            "$log" "$type" "$size" "未找到" "未设置" "SKIP"
    fi
done

for j in "${JOURNALS[@]}"; do
    printf '%-42s %-20s %-10s %-36s %-16s %s\n' \
        "$j" "journald" "$(human_size "$j")" \
        "$JOURNAL_CONF" "journal" "8M"
done

echo
echo "[6/8] 修改建议"
echo
echo "规则："
echo "  ✓ 已有 size / minsize / maxsize → 保持现有语义"
echo "  ✓ 目标日志没有大小规则 → 添加 maxsize"
echo "  ✓ 已有规则与用途目标不符 → 精确调整该 stanza"
echo "  ✓ 控制关系不唯一 → 跳过"
echo

declare -a CHANGES
declare -A CHANGE_TARGET
declare -A CHANGE_CFG
declare -A CHANGE_ST
declare -A CHANGE_EN

for log in "${LOGS[@]}"; do
    [[ ${CTRL_COUNT[$log]:-0} == 1 ]] || continue
    [[ -n ${TARGET[$log]:-} ]] || continue

    target="${TARGET[$log]}"
    rule="${RULE[$log]}"
    cfg="${FILE[$log]}"
    s="${ST[$log]}"
    e="${EN[$log]}"

    # 同一 stanza 多日志路径：
    # 只有当所有已知目标一致时才允许修改。
    key="$cfg:$s:$e"

    if [[ "$rule" == "none" ]]; then
        action="add"
    else
        current="${rule#* }"
        current_type="${rule%% *}"

        if [[ "$log" == "/var/log/wtmp" && "$current_type" == "minsize" ]]; then
            action="keep"
        elif [[ "$current" == "$target" ]]; then
            action="keep"
        else
            action="replace"
        fi
    fi

    if [[ "$action" == "keep" ]]; then
        echo "$log"
        echo "  控制 : $cfg"
        echo "  stanza: $s-$e"
        echo "  当前 : $rule"
        echo "  操作 : 保持"
        echo
        continue
    fi

    # 同一 stanza 只能建立一次修改计划
    if [[ -z ${CHANGE_TARGET[$key]:-} ]]; then
        CHANGES+=("$key")
        CHANGE_TARGET["$key"]="$target"
        CHANGE_CFG["$key"]="$cfg"
        CHANGE_ST["$key"]="$s"
        CHANGE_EN["$key"]="$e"
    elif [[ ${CHANGE_TARGET[$key]} != "$target" ]]; then
        echo "⚠ stanza $cfg:$s-$e 同时对应不同目标，跳过"
        unset 'CHANGE_TARGET[$key]'
    fi

    echo "$log"
    echo "  控制 : $cfg"
    echo "  stanza: $s-$e"
    echo "  当前 : $rule"
    echo "  操作 : ${action} maxsize $target"
    echo
done

journal_changes=0
if [[ -f "$JOURNAL_CONF" ]]; then
    [[ "$SYS_FILE" == "8M" ]] || journal_changes=$((journal_changes+1))
    [[ "$RUN_FILE" == "8M" ]] || journal_changes=$((journal_changes+1))
fi

echo "journald："
echo "  SystemMaxFileSize  : ${SYS_FILE:-未设置} → 8M"
echo "  RuntimeMaxFileSize : ${RUN_FILE:-未设置} → 8M"
echo

echo "[7/8] 安全确认"
echo
echo "本次准备修改："
echo "  logrotate：${#CHANGES[@]} 个 stanza"
echo "  journald ：$journal_changes 项"
echo
echo "⚠ 不创建任何系统配置文件"
echo "⚠ 不备份"
echo "⚠ 不删除当前日志"
echo

if [[ ${#CHANGES[@]} -eq 0 && $journal_changes -eq 0 ]]; then
    echo "没有需要修改的配置。"
    echo "审计完成，系统无需修改。"
    exit 0
fi

read -r -p "确认执行精准修改？[y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || {
    echo "已取消，没有修改任何配置。"
    exit 0
}

echo
echo "============================================================"
echo "                       修改前验证"
echo "============================================================"

logrotate -d "$LOGROTATE_CONF" >/dev/null 2>&1 ||
    die "修改前 logrotate 配置语法检查失败"

echo "✓ 修改前 logrotate 配置语法正常"

# ------------------------------------------------------------
# 修改 stanza
# 每个 stanza 只处理一次。
# ------------------------------------------------------------

modify_stanza()
{
    local cfg="$1"
    local start="$2"
    local end="$3"
    local target="$4"

    local tmp
    tmp=$(mktemp)

    awk -v S="$start" -v E="$end" -v T="$target" '
    BEGIN { in=0; done=0 }

    {
        if(NR==S) in=1

        if(in && !done && $0 ~ /^[[:space:]]*}[[:space:]]*$/){
            print "    maxsize " T
            done=1
        }

        if(in && !done &&
           $0 ~ /^[[:space:]]*(size|minsize|maxsize)([[:space:]]+|=)/){
            print "    maxsize " T
            done=1
            next
        }

        print

        if(NR==E) in=0
    }' "$cfg" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    if ! cmp -s "$cfg" "$tmp"; then
        cat "$tmp" > "$cfg" || {
            rm -f "$tmp"
            return 1
        }
    fi

    rm -f "$tmp"
}

for key in "${CHANGES[@]}"; do
    [[ -n ${CHANGE_CFG[$key]:-} ]] || continue

    cfg="${CHANGE_CFG[$key]}"
    s="${CHANGE_ST[$key]}"
    e="${CHANGE_EN[$key]}"
    target="${CHANGE_TARGET[$key]}"

    echo
    echo "修改：$cfg"
    echo "  stanza : $s-$e"
    echo "  目标   : maxsize $target"

    modify_stanza "$cfg" "$s" "$e" "$target" ||
        die "修改失败：$cfg stanza $s-$e"

    echo "✓ 写入成功"
done

# ------------------------------------------------------------
# journald：
# 只修改已经存在的 /etc/systemd/journald.conf
# 不创建文件。
# ------------------------------------------------------------

if [[ $journal_changes -gt 0 ]]; then
    echo
    echo "修改：$JOURNAL_CONF"

    TMP_JOURNAL=$(mktemp)

    awk '
    BEGIN{
        a=0
        b=0
    }

    /^[[:space:]]*#/ {print; next}

    {
        x=$0

        if(x ~ /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/){
            print "SystemMaxFileSize=8M"
            a=1
            next
        }

        if(x ~ /^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/){
            print "RuntimeMaxFileSize=8M"
            b=1
            next
        }

        print
    }

    END{
        if(!a) print "SystemMaxFileSize=8M"
        if(!b) print "RuntimeMaxFileSize=8M"
    }' "$JOURNAL_CONF" > "$TMP_JOURNAL" ||
        die "journald 配置生成失败"

    cat "$TMP_JOURNAL" > "$JOURNAL_CONF" ||
        die "journald 配置写入失败"

    echo "✓ SystemMaxFileSize=8M"
    echo "✓ RuntimeMaxFileSize=8M"
fi

echo
echo "============================================================"
echo "                       修改后验证"
echo "============================================================"

echo
echo "------------------------------------------------------------"
echo "                    验证 logrotate"
echo "------------------------------------------------------------"

logrotate -d "$LOGROTATE_CONF" >/dev/null 2>&1 ||
    die "修改后 logrotate 配置语法失败"

echo "✓ logrotate 配置语法正常"

# 重新解析，绝不读取修改计划作为验证依据
TMP_PARSE2=$(mktemp)
trap 'rm -f "$TMP_PARSE" "$TMP_PARSE2" "$TMP_EDIT" "$TMP_JOURNAL"' EXIT

for cfg in "${CFGS[@]}"; do
    parse_cfg "$cfg" >> "$TMP_PARSE2"
done

TMP_PARSE_OLD="$TMP_PARSE"
TMP_PARSE="$TMP_PARSE2"

fail=0

echo
echo "------------------------------------------------------------"
echo "                 精确重新解析控制 stanza"
echo "------------------------------------------------------------"

for key in "${CHANGES[@]}"; do
    cfg="${CHANGE_CFG[$key]}"
    s="${CHANGE_ST[$key]}"
    e="${CHANGE_EN[$key]}"
    target="${CHANGE_TARGET[$key]}"

    found=0
    actual=""

    while IFS=$'\t' read -r c ss ee pats rule; do
        if [[ "$c" == "$cfg" && "$ss" == "$s" && "$ee" == "$e" ]]; then
            found=1
            actual="$rule"
            break
        fi
    done < "$TMP_PARSE"

    if [[ $found -ne 1 ]]; then
        echo "✗ $cfg stanza $s-$e：重新解析失败"
        fail=1
    elif [[ "$actual" != "maxsize $target" ]]; then
        echo "✗ $cfg stanza $s-$e：期望 maxsize $target，实际 $actual"
        fail=1
    else
        echo "✓ $cfg stanza $s-$e → maxsize $target"
    fi
done

echo
echo "------------------------------------------------------------"
echo "                    验证 systemd-journald"
echo "------------------------------------------------------------"

verify_journal()
{
    local key="$1"
    local want="$2"
    local got

    got=$(journal_get "$key")

    if [[ "$got" == "$want" ]]; then
        echo "✓ $key = $got"
    else
        echo "✗ $key：期望 $want，实际 ${got:-未设置}"
        fail=1
    fi
}

verify_journal SystemMaxFileSize 8M
verify_journal RuntimeMaxFileSize 8M

echo
echo "============================================================"

if [[ $fail -eq 0 ]]; then
    echo "                         验证成功"
    echo "============================================================"
    echo
    echo "✓ 所有实际修改均已重新解析并验证"
    echo "✓ logrotate 配置语法正常"
    echo "✓ journald 配置正常"
    echo
    echo "修改完成。"
    exit 0
else
    echo "                         验证失败"
    echo "============================================================"
    echo
    echo "⚠ 存在验证失败项目，请不要忽略。"
    exit 1
fi
