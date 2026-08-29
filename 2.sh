#!/bin/bash

set -u
export LC_ALL=C

CONFIG_MAIN="/etc/logrotate.conf"
CONFIG_DIR="/etc/logrotate.d"
JOURNAL_CONF="/etc/systemd/journald.conf"

declare -a LOG_FILES
declare -a LOG_TYPES
declare -a LOG_SIZES
declare -a LOG_CONTROLS
declare -a LOG_STANZAS
declare -a LOG_RULES
declare -a LOG_CURRENT
declare -a LOG_RECOMMEND

declare -a CHANGE_FILE
declare -a CHANGE_LINE
declare -a CHANGE_VALUE
declare -a CHANGE_LOG
declare -a CHANGE_TYPE
declare -a CHANGE_RULE
declare -a CHANGE_STANZA

CHANGE_COUNT=0

TMPDIR_RUNTIME="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUNTIME"' EXIT

die() {
    echo "错误：$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

size_human() {
    local b="$1"

    if [ "$b" -ge $((1024*1024*1024)) ]; then
        awk -v b="$b" 'BEGIN {printf "%.2fG", b/1073741824}'
    elif [ "$b" -ge $((1024*1024)) ]; then
        awk -v b="$b" 'BEGIN {printf "%.2fM", b/1048576}'
    elif [ "$b" -ge 1024 ]; then
        awk -v b="$b" 'BEGIN {printf "%.2fK", b/1024}'
    else
        printf "%sB" "$b"
    fi
}

file_size() {
    stat -c '%s' -- "$1" 2>/dev/null || echo 0
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
        /var/log/btmp)
            echo "failed-login-history"
            ;;
        /var/log/wtmp)
            echo "login-history"
            ;;
        /var/log/lastlog)
            echo "lastlog"
            ;;
        /var/log/installer/*)
            echo "installer"
            ;;
        /var/log/journal/*/*.journal)
            echo "journald"
            ;;
        /run/log/journal/*/*.journal)
            echo "journald-runtime"
            ;;
        /var/log/syslog)
            echo "syslog"
            ;;
        /var/log/messages)
            echo "messages"
            ;;
        /var/log/auth.log)
            echo "auth"
            ;;
        /var/log/kern.log)
            echo "kernel"
            ;;
        /var/log/daemon.log)
            echo "daemon"
            ;;
        /var/log/user.log)
            echo "user"
            ;;
        /var/log/mail.log)
            echo "mail"
            ;;
        /var/log/mail.err)
            echo "mail-error"
            ;;
        /var/log/mail.warn)
            echo "mail-warning"
            ;;
        /var/log/debug)
            echo "debug"
            ;;
        /var/log/faillog)
            echo "faillog"
            ;;
        /var/log/cron)
            echo "cron"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

recommend_size() {
    local type="$1"

    case "$type" in
        dpkg)
            echo "5M"
            ;;
        alternatives)
            echo "2M"
            ;;
        apt-history)
            echo "3M"
            ;;
        apt-terminal)
            echo "5M"
            ;;
        failed-login-history)
            echo "5M"
            ;;
        login-history)
            echo "5M"
            ;;
        lastlog)
            echo "5M"
            ;;
        syslog|messages|auth|kernel|daemon|user|cron)
            echo "10M"
            ;;
        mail|mail-error|mail-warning)
            echo "10M"
            ;;
        debug)
            echo "10M"
            ;;
        *)
            echo ""
            ;;
    esac
}

parse_size_value() {
    local v="$1"

    v="${v//[[:space:]]/}"

    if [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "$v"
        return
    fi

    if [[ "$v" =~ ^([0-9]+)([kKmMgGtTpP])$ ]]; then
        local n="${BASH_REMATCH[1]}"
        local u="${BASH_REMATCH[2]}"

        case "$u" in
            k|K) echo $((n*1024)) ;;
            m|M) echo $((n*1024*1024)) ;;
            g|G) echo $((n*1024*1024*1024)) ;;
            t|T) echo $((n*1024*1024*1024*1024)) ;;
            p|P) echo $((n*1024*1024*1024*1024*1024)) ;;
        esac
        return
    fi

    echo ""
}

get_directive_from_stanza() {
    local file="$1"
    local start="$2"
    local end="$3"
    local directive="$4"

    sed -n "${start},${end}p" "$file" |
        sed 's/#.*//' |
        awk -v d="$directive" '
            $1 == d {
                print $2
                exit
            }
        '
}

extract_patterns() {
    local file="$1"
    local start="$2"
    local end="$3"

    sed -n "${start},${end}p" "$file" |
        sed 's/#.*//' |
        awk '
        BEGIN { in_script=0 }

        /^[[:space:]]*(prerotate|postrotate|firstaction|lastaction|preremove)[[:space:]]*$/ {
            in_script=1
            next
        }

        /^[[:space:]]*endscript[[:space:]]*$/ {
            in_script=0
            next
        }

        in_script { next }

        /^[[:space:]]*$/ { next }

        /^[[:space:]]*(daily|weekly|monthly|yearly|hourly|size|maxsize|minsize|rotate|compress|delaycompress|missingok|notifempty|ifempty|copytruncate|nocopytruncate|create|su|sharedscripts|nosharedscripts|dateext|nodateext|dateformat|olddir|mail|nomail|mailfirst|maillast|maxage|minage|minsize|maxsize|include|tabooext|taboopat|start|extension|addextension|dateyesterday|datehourago|allowhardlink|dontcompress|shred|shredcycles|prerotate|postrotate|firstaction|lastaction|preremove)[[:space:]]/ {
            next
        }

        {
            print
            exit
        }'
}

match_log_pattern() {
    local log="$1"
    local pattern="$2"

    pattern="${pattern#\"}"
    pattern="${pattern%\"}"
    pattern="${pattern#\'}"
    pattern="${pattern%\'}"

    [[ "$log" == $pattern ]]
}

find_control() {
    local target="$1"
    local file
    local line
    local start
    local end
    local patterns
    local p
    local best_file=""
    local best_start=""
    local best_end=""
    local best_rule=""

    declare -a cfgs

    if [ -f "$CONFIG_MAIN" ]; then
        cfgs+=("$CONFIG_MAIN")
    fi

    if [ -d "$CONFIG_DIR" ]; then
        while IFS= read -r file; do
            cfgs+=("$file")
        done < <(
            find "$CONFIG_DIR" -maxdepth 1 -type f \
                ! -name '*.dpkg-*' \
                ! -name '*~' \
                ! -name '*.disabled' \
                ! -name '*.ucf-*' \
                -print | sort
        )
    fi

    for file in "${cfgs[@]}"; do
        [ -r "$file" ] || continue

        start=""
        end=""

        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^[[:space:]]*$ ]]; then
                continue
            fi

            if [[ "$line" =~ ^[[:space:]]*# ]]; then
                continue
            fi

            if [ -z "$start" ]; then
                patterns="$(printf '%s\n' "$line" |
                    sed 's/#.*//' |
                    awk '
                    BEGIN { in_script=0 }

                    /^[[:space:]]*(prerotate|postrotate|firstaction|lastaction|preremove)[[:space:]]*$/ {
                        exit
                    }

                    {
                        print
                        exit
                    }'
                )"

                if [ -n "$patterns" ]; then
                    start="$(grep -nF "$line" "$file" | head -n1 | cut -d: -f1)"
                fi
            else
                if [[ "$line" =~ ^[^[:space:]].*\{[[:space:]]*$ ]]; then
                    end=$(( $(grep -nF "$line" "$file" | head -n1 | cut -d: -f1) - 1 ))
                fi
            fi
        done < "$file"

        # 使用更可靠的 awk 重新解析 stanza
        while IFS=$'\t' read -r s e rule; do
            [ -n "$s" ] || continue

            read -r -a arr <<< "$rule"

            for p in "${arr[@]}"; do
                if match_log_pattern "$target" "$p"; then
                    best_file="$file"
                    best_start="$s"
                    best_end="$e"
                    best_rule="$rule"
                    break 2
                fi
            done
        done < <(
            awk '
            function flush(endline) {
                if (start != "" && rule != "")
                    print start "\t" endline "\t" rule
                start=""
                rule=""
            }

            BEGIN {
                inblock=0
                depth=0
            }

            /^[[:space:]]*#/ { next }

            {
                line=$0
                sub(/[[:space:]]*#.*/, "", line)

                if (line ~ /^[[:space:]]*$/)
                    next

                if (!inblock && line ~ /\{[[:space:]]*$/) {
                    x=line
                    sub(/[[:space:]]*\{[[:space:]]*$/, "", x)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", x)

                    start=NR
                    rule=x
                    inblock=1
                    next
                }

                if (inblock) {
                    if (line ~ /\}/) {
                        flush(NR)
                        inblock=0
                    }
                }
            }

            END {
                if (inblock)
                    flush(NR)
            }
            ' "$file"
        )
    done

    if [ -n "$best_file" ]; then
        printf '%s\t%s\t%s\t%s\n' \
            "$best_file" \
            "$best_start" \
            "$best_end" \
            "$best_rule"
    fi
}

find_maxsize_in_stanza() {
    local file="$1"
    local start="$2"
    local end="$3"

    sed -n "${start},${end}p" "$file" |
        sed 's/#.*//' |
        awk '
            $1=="maxsize" {
                print $2
                exit
            }
        '
}

find_size_in_stanza() {
    local file="$1"
    local start="$2"
    local end="$3"

    sed -n "${start},${end}p" "$file" |
        sed 's/#.*//' |
        awk '
            $1=="size" {
                print $2
                exit
            }
        '
}

find_maxsize_line() {
    local file="$1"
    local start="$2"
    local end="$3"

    awk -v s="$start" -v e="$end" '
        NR>=s && NR<=e && $0 !~ /^[[:space:]]*#/ && $1=="maxsize" {
            print NR
            exit
        }
    ' "$file"
}

find_size_line() {
    local file="$1"
    local start="$2"
    local end="$3"

    awk -v s="$start" -v e="$end" '
        NR>=s && NR<=e && $0 !~ /^[[:space:]]*#/ && $1=="size" {
            print NR
            exit
        }
    ' "$file"
}

insert_before_closing_brace() {
    local file="$1"
    local start="$2"
    local end="$3"
    local value="$4"

    awk -v s="$start" -v e="$end" -v v="$value" '
    NR==e {
        print "    maxsize " v
    }
    { print }
    ' "$file" > "$TMPDIR_RUNTIME/new"

    cat "$TMPDIR_RUNTIME/new" > "$file"
}

update_existing_line() {
    local file="$1"
    local line="$2"
    local value="$3"

    awk -v target="$line" -v v="$value" '
    NR==target {
        print "    maxsize " v
        next
    }
    { print }
    ' "$file" > "$TMPDIR_RUNTIME/new"

    cat "$TMPDIR_RUNTIME/new" > "$file"
}

collect_logs() {
    LOG_FILES=()
    LOG_TYPES=()
    LOG_SIZES=()
    LOG_CONTROLS=()
    LOG_STANZAS=()
    LOG_RULES=()
    LOG_CURRENT=()
    LOG_RECOMMEND=()

    while IFS= read -r f; do
        [ -f "$f" ] || continue

        case "$f" in
            /var/log/journal/*/*.journal)
                ;;
            /var/log/journal/*/*.journal~)
                ;;
            /run/log/journal/*/*.journal)
                ;;
        esac

        LOG_FILES+=("$f")
        LOG_TYPES+=("$(classify_log "$f")")
        LOG_SIZES+=("$(file_size "$f")")
    done < <(
        find /var/log -xdev -type f \
            ! -path '/var/log/journal/*/*.journal~' \
            -print 2>/dev/null | sort
    )

    if [ -d /run/log/journal ]; then
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            LOG_FILES+=("$f")
            LOG_TYPES+=("$(classify_log "$f")")
            LOG_SIZES+=("$(file_size "$f")")
        done < <(
            find /run/log/journal -xdev -type f -name '*.journal' \
                -print 2>/dev/null | sort
        )
    fi
}

analyze_controls() {
    local i
    local result
    local cf
    local cs
    local ce
    local rule
    local maxsize
    local size_directive
    local type
    local rec

    for i in "${!LOG_FILES[@]}"; do
        result="$(find_control "${LOG_FILES[$i]}")"

        cf=""
        cs=""
        ce=""
        rule=""

        if [ -n "$result" ]; then
            IFS=$'\t' read -r cf cs ce rule <<< "$result"
        fi

        if [ -n "$cf" ]; then
            maxsize="$(find_maxsize_in_stanza "$cf" "$cs" "$ce")"
            size_directive="$(find_size_in_stanza "$cf" "$cs" "$ce")"

            if [ -n "$maxsize" ]; then
                rec="$maxsize"
            elif [ -n "$size_directive" ]; then
                rec="size:$size_directive"
            else
                rec="未设置"
            fi
        else
            rec="未设置"
        fi

        LOG_CONTROLS+=("${cf:-未找到}")
        LOG_STANZAS+=("${cs:-}-${ce:-}")
        LOG_RULES+=("${rule:-未找到}")
        LOG_CURRENT+=("$rec")

        type="${LOG_TYPES[$i]}"
        LOG_RECOMMEND+=("$(recommend_size "$type")")
    done
}

print_header() {
    echo "============================================================"
    echo " Debian 13 日志大小审计与精准限制"
    echo " 扫描 → 识别 → 分类 → 建议 → 确认 → 修改 → 验证"
    echo "============================================================"
    echo
    echo "目标：普通日志 1M–10M；journald 单文件 8M"
    echo
    echo "原则："
    echo "  ✓ 只修改真实存在且实际控制日志的配置文件"
    echo "  ✓ 精确修改对应 stanza"
    echo "  ✓ 不创建任何配置文件"
    echo "  ✓ 不备份"
    echo "  ✓ 不删除现有日志"
    echo "  ✓ 控制关系无法确认 → 跳过"
    echo
}

print_system() {
    echo "[1/8] 系统检测"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "  OS       : ${PRETTY_NAME:-unknown}"
    fi

    echo "  Kernel   : $(uname -r)"

    if [ -d /var/log ]; then
        echo "  /var/log : $(du -sh /var/log 2>/dev/null | awk '{print $1}')"
    fi

    if [ -d /run/log ]; then
        echo "  /run/log : $(du -sh /run/log 2>/dev/null | awk '{print $1}')"
    fi

    echo
}

print_scan_summary() {
    echo "[2/8] 扫描实际日志文件"
    echo "  找到 ${#LOG_FILES[@]} 个当前日志文件"
    echo
}

print_controls_summary() {
    local i
    local found=0
    local notfound=0

    for i in "${!LOG_FILES[@]}"; do
        if [ "${LOG_CONTROLS[$i]}" = "未找到" ]; then
            ((notfound++))
        else
            ((found++))
        fi
    done

    echo "[3/8] 精确检测 logrotate 控制关系"
    echo
    echo "  已识别明确控制关系：$found"
    echo "  未找到控制关系    ：$notfound"
    echo
}

print_journal() {
    local system_files runtime_files
    local system_max runtime_max

    echo "[4/8] 检测 systemd-journald"

    system_files="$(find /var/log/journal -type f -name '*.journal' 2>/dev/null | wc -l)"
    runtime_files="$(find /run/log/journal -type f -name '*.journal' 2>/dev/null | wc -l)"

    echo "  persistent journal : $system_files"
    echo "  runtime journal    : $runtime_files"

    system_max="$(awk -F= '
        /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/ {
            gsub(/[[:space:]]/, "", $2)
            print $2
            exit
        }
    ' "$JOURNAL_CONF" 2>/dev/null)"

    runtime_max="$(awk -F= '
        /^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/ {
            gsub(/[[:space:]]/, "", $2)
            print $2
            exit
        }
    ' "$JOURNAL_CONF" 2>/dev/null)"

    if [ -z "$system_max" ]; then
        system_max="未设置"
    fi

    if [ -z "$runtime_max" ]; then
        runtime_max="未设置"
    fi

    echo "  SystemMaxFileSize  : $system_max"
    echo "  RuntimeMaxFileSize : $runtime_max"

    if [ ! -f "$JOURNAL_CONF" ]; then
        echo "  操作：跳过，/etc/systemd/journald.conf 不存在"
    fi

    echo
}

print_all_logs() {
    local i
    local name

    echo "[5/8] 所有日志及控制关系"
    echo
    printf "%-48s %-22s %-10s %-35s %-14s %-8s\n" \
        "日志" "类型" "大小" "真实控制文件" "当前限制" "建议"

    printf '%s\n' \
        "---------------------------------------------------------------------------------------------------------------"

    for i in "${!LOG_FILES[@]}"; do
        name="${LOG_FILES[$i]}"

        printf "%-48s %-22s %-10s %-35s %-14s %-8s\n" \
            "$name" \
            "${LOG_TYPES[$i]}" \
            "$(size_human "${LOG_SIZES[$i]}")" \
            "${LOG_CONTROLS[$i]}" \
            "${LOG_CURRENT[$i]}" \
            "${LOG_RECOMMEND[$i]:-跳过}"
    done

    echo
}

build_changes() {
    local i
    local type
    local rec
    local current
    local cf
    local cs
    local ce
    local rule
    local maxsize

    CHANGE_FILE=()
    CHANGE_LINE=()
    CHANGE_VALUE=()
    CHANGE_LOG=()
    CHANGE_TYPE=()
    CHANGE_RULE=()
    CHANGE_STANZA=()
    CHANGE_COUNT=0

    for i in "${!LOG_FILES[@]}"; do
        type="${LOG_TYPES[$i]}"
        rec="${LOG_RECOMMEND[$i]}"
        current="${LOG_CURRENT[$i]}"
        cf="${LOG_CONTROLS[$i]}"
        cs="${LOG_STANZAS[$i]%-*}"
        ce="${LOG_STANZAS[$i]#*-}"
        rule="${LOG_RULES[$i]}"

        [ -n "$rec" ] || continue
        [ "$cf" != "未找到" ] || continue
        [ "$type" != "journald" ] || continue
        [ "$type" != "journald-runtime" ] || continue

        maxsize="$(find_maxsize_in_stanza "$cf" "$cs" "$ce")"

        if [ -n "$maxsize" ] && [ "$maxsize" = "$rec" ]; then
            continue
        fi

        CHANGE_FILE+=("$cf")
        CHANGE_LINE+=("$(find_maxsize_line "$cf" "$cs" "$ce")")
        CHANGE_VALUE+=("$rec")
        CHANGE_LOG+=("${LOG_FILES[$i]}")
        CHANGE_TYPE+=("$type")
        CHANGE_RULE+=("$rule")
        CHANGE_STANZA+=("${LOG_STANZAS[$i]}")
        ((CHANGE_COUNT++))
    done
}

print_changes() {
    local i

    echo "[6/8] 修改建议"
    echo
    echo "建议依据：日志用途，不依据当前文件大小。"
    echo

    if [ "$CHANGE_COUNT" -eq 0 ]; then
        echo "  无需要修改的普通日志。"
    else
        for i in "${!CHANGE_FILE[@]}"; do
            echo "[$((i+1))]"
            echo "  日志       : ${CHANGE_LOG[$i]}"
            echo "  类型       : ${CHANGE_TYPE[$i]}"
            echo "  控制文件   : ${CHANGE_FILE[$i]}"
            echo "  stanza     : ${CHANGE_STANZA[$i]}"
            echo "  匹配规则   : ${CHANGE_RULE[$i]}"
            echo "  修改目标   : maxsize ${CHANGE_VALUE[$i]}"
            echo
        done
    fi

    echo "[journald]"

    if [ -f "$JOURNAL_CONF" ]; then
        local sm rm

        sm="$(awk -F= '
            /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/ {
                gsub(/[[:space:]]/, "", $2)
                print $2
                exit
            }
        ' "$JOURNAL_CONF")"

        rm="$(awk -F= '
            /^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/ {
                gsub(/[[:space:]]/, "", $2)
                print $2
                exit
            }
        ' "$JOURNAL_CONF")"

        echo "  控制文件 : $JOURNAL_CONF"
        echo "  SystemMaxFileSize  : ${sm:-未设置} → 8M"
        echo "  RuntimeMaxFileSize : ${rm:-未设置} → 8M"
    else
        echo "  /etc/systemd/journald.conf 不存在 → 跳过"
    fi

    echo
}

journal_needs_change() {
    [ -f "$JOURNAL_CONF" ] || return 1

    local sm rm
    sm="$(awk -F= '
        /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/ {
            gsub(/[[:space:]]/, "", $2)
            print $2
            exit
        }
    ' "$JOURNAL_CONF")"

    rm="$(awk -F= '
        /^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/ {
            gsub(/[[:space:]]/, "", $2)
            print $2
            exit
        }
    ' "$JOURNAL_CONF")"

    [ "$sm" != "8M" ] || [ "$rm" != "8M" ]
}

modify_journal() {
    local tmp="$TMPDIR_RUNTIME/journald.conf"

    awk '
    BEGIN {
        sm=0
        rm=0
    }

    /^[[:space:]]*#/ {
        print
        next
    }

    /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/ {
        print "SystemMaxFileSize=8M"
        sm=1
        next
    }

    /^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/ {
        print "RuntimeMaxFileSize=8M"
        rm=1
        next
    }

    {
        print
    }

    END {
        if (!sm)
            print "SystemMaxFileSize=8M"

        if (!rm)
            print "RuntimeMaxFileSize=8M"
    }
    ' "$JOURNAL_CONF" > "$tmp"

    cat "$tmp" > "$JOURNAL_CONF"
}

modify_changes() {
    local i
    local line
    local cf
    local cs
    local ce
    local value

    echo "============================================================"
    echo "                         开始修改"
    echo "============================================================"
    echo

    for i in "${!CHANGE_FILE[@]}"; do
        cf="${CHANGE_FILE[$i]}"
        cs="${CHANGE_STANZA[$i]%-*}"
        ce="${CHANGE_STANZA[$i]#*-}"
        value="${CHANGE_VALUE[$i]}"

        line="$(find_maxsize_line "$cf" "$cs" "$ce")"

        if [ -n "$line" ]; then
            update_existing_line "$cf" "$line" "$value"
            echo "✓ $cf"
            echo "  ${CHANGE_LOG[$i]} → maxsize $value"
        else
            insert_before_closing_brace "$cf" "$cs" "$ce" "$value"
            echo "✓ $cf"
            echo "  ${CHANGE_LOG[$i]} → 添加 maxsize $value"
        fi
    done

    if journal_needs_change; then
        modify_journal
        echo "✓ $JOURNAL_CONF"
        echo "  SystemMaxFileSize=8M"
        echo "  RuntimeMaxFileSize=8M"
    fi

    echo
}

validate_logrotate() {
    echo "============================================================"
    echo "                     验证 logrotate"
    echo "============================================================"

    if command -v logrotate >/dev/null 2>&1; then
        if logrotate -d "$CONFIG_MAIN" >/dev/null 2>&1; then
            echo "✓ logrotate 配置语法正常"
        else
            echo "✗ logrotate 配置检查失败"
            return 1
        fi
    else
        echo "⚠ logrotate 未安装，跳过"
    fi

    echo
}

validate_journal() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return
    fi

    if journal_needs_change; then
        return
    fi

    echo "============================================================"
    echo "                 应用 systemd-journald"
    echo "============================================================"

    if systemctl restart systemd-journald; then
        echo "✓ systemd-journald 重启成功"
    else
        echo "✗ systemd-journald 重启失败"
        return 1
    fi

    echo
}

final_verify() {
    local i
    local cf
    local cs
    local ce
    local actual
    local expected
    local ok=0

    echo "============================================================"
    echo "                         最终验证"
    echo "============================================================"
    echo

    for i in "${!CHANGE_FILE[@]}"; do
        cf="${CHANGE_FILE[$i]}"
        cs="${CHANGE_STANZA[$i]%-*}"
        ce="${CHANGE_STANZA[$i]#*-}"
        expected="${CHANGE_VALUE[$i]}"

        actual="$(find_maxsize_in_stanza "$cf" "$cs" "$ce")"

        if [ "$actual" = "$expected" ]; then
            echo "✓ ${CHANGE_LOG[$i]} : maxsize $actual"
        else
            echo "✗ ${CHANGE_LOG[$i]} : 期望 $expected，实际 ${actual:-未设置}"
            ok=1
        fi
    done

    if [ -f "$JOURNAL_CONF" ]; then
        local sm rm

        sm="$(awk -F= '
            /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/ {
                gsub(/[[:space:]]/, "", $2)
                print $2
                exit
            }
        ' "$JOURNAL_CONF")"

        rm="$(awk -F= '
            /^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/ {
                gsub(/[[:space:]]/, "", $2)
                print $2
                exit
            }
        ' "$JOURNAL_CONF")"

        if [ "$sm" = "8M" ]; then
            echo "✓ SystemMaxFileSize = 8M"
        else
            echo "✗ SystemMaxFileSize = ${sm:-未设置}"
            ok=1
        fi

        if [ "$rm" = "8M" ]; then
            echo "✓ RuntimeMaxFileSize = 8M"
        else
            echo "✗ RuntimeMaxFileSize = ${rm:-未设置}"
            ok=1
        fi
    fi

    echo

    if [ "$ok" -eq 0 ]; then
        echo "------------------------------------------------------------"
        echo "✓ 所有修改均已验证"
        echo "------------------------------------------------------------"
    else
        echo "------------------------------------------------------------"
        echo "⚠ 存在验证失败项目，请勿忽略"
        echo "------------------------------------------------------------"
        return 1
    fi
}

main() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"

    need_cmd awk
    need_cmd sed
    need_cmd find
    need_cmd stat

    print_header
    print_system

    collect_logs
    print_scan_summary

    analyze_controls
    print_controls_summary

    print_journal
    print_all_logs

    build_changes
    print_changes

    echo "[7/8] 修改原则"
    echo
    echo "  ✓ 只修改真实存在的控制配置"
    echo "  ✓ 只修改实际匹配目标日志的 stanza"
    echo "  ✓ maxsize 按日志用途设置 1M–10M"
    echo "  ✓ journald 单文件限制 8M"
    echo "  ✓ 未确认控制关系的日志跳过"
    echo "  ✓ 不创建配置文件"
    echo "  ✓ 不备份"
    echo "  ✓ 不删除现有日志"
    echo

    echo "============================================================"
    echo "                         安全确认"
    echo "============================================================"
    echo

    echo "本次准备修改：$CHANGE_COUNT 个 logrotate stanza"

    if journal_needs_change; then
        echo "journald：需要修改 /etc/systemd/journald.conf"
    else
        echo "journald：无需修改或配置文件不存在"
    fi

    echo
    echo "⚠ 不创建任何配置文件"
    echo "⚠ 不备份"
    echo "⚠ 不删除现有日志"
    echo

    printf "确认执行精准修改？[y/N] "
    read -r answer

    case "$answer" in
        y|Y|yes|YES)
            ;;
        *)
            echo
            echo "已取消，没有修改任何配置。"
            exit 0
            ;;
    esac

    modify_changes

    echo "[8/8] 修改后验证"
    echo

    validate_logrotate || exit 1

    if journal_needs_change; then
        validate_journal || exit 1
    fi

    final_verify || exit 1

    echo
    echo "完成。"
}

main "$@"=8M
