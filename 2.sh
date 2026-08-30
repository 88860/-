#!/bin/bash
set -Eeuo pipefail

readonly JOURNAL_CONF="/etc/systemd/journald.conf"
readonly JOURNAL_DROPIN_DIR="/etc/systemd/journald.conf.d"

readonly LOGROTATE_CONF="/etc/logrotate.conf"
readonly RSYSLOG_ROTATE="/etc/logrotate.d/rsyslog"

readonly LOCK_FILE="/run/lock/debian-log-optimize.lock"

readonly COMPRESS_VALUE="yes"
readonly SYSTEM_MAX_USE="32M"
readonly SYSTEM_MAX_FILE_SIZE="4M"
readonly SYSTEM_MAX_FILES="8"
readonly RUNTIME_MAX_USE="8M"
readonly RUNTIME_MAX_FILE_SIZE="2M"
readonly RUNTIME_MAX_FILES="4"
readonly MAX_RETENTION="7day"

readonly LOGROTATE_MAX_SIZE="5M"
readonly LOGROTATE_ROTATE="2"

readonly JOURNAL_KEYS=(
    Compress
    SystemMaxUse
    SystemMaxFileSize
    SystemMaxFiles
    RuntimeMaxUse
    RuntimeMaxFileSize
    RuntimeMaxFiles
    MaxRetentionSec
)

declare -Ar JOURNAL_EXPECTED=(
    [Compress]="$COMPRESS_VALUE"
    [SystemMaxUse]="$SYSTEM_MAX_USE"
    [SystemMaxFileSize]="$SYSTEM_MAX_FILE_SIZE"
    [SystemMaxFiles]="$SYSTEM_MAX_FILES"
    [RuntimeMaxUse]="$RUNTIME_MAX_USE"
    [RuntimeMaxFileSize]="$RUNTIME_MAX_FILE_SIZE"
    [RuntimeMaxFiles]="$RUNTIME_MAX_FILES"
    [MaxRetentionSec]="$MAX_RETENTION"
)

TMP_FILES=()

log() {
    printf '[%(%F %T)T] %s\n' -1 "$*"
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local file
    for file in "${TMP_FILES[@]:-}"; do
        [[ -n "$file" ]] && rm -f -- "$file"
    done
}

trap cleanup EXIT

require_system() {
    (( EUID == 0 )) ||
        die "必须以 root 身份运行。"

    [[ -r /etc/os-release ]] ||
        die "无法读取 /etc/os-release。"

    # shellcheck disable=SC1091
    . /etc/os-release

    [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] ||
        die "本脚本只支持 Debian 13，当前：${PRETTY_NAME:-unknown}"

    local cmd
    for cmd in awk mktemp flock systemctl journalctl systemd-analyze; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "缺少必要命令：$cmd"
    done

    [[ -f "$JOURNAL_CONF" ]] ||
        die "不存在：$JOURNAL_CONF"

    exec 9>"$LOCK_FILE"

    flock -n 9 ||
        die "已有另一个日志优化脚本正在运行。"
}

make_temp() {
    local target="$1"
    local tmp

    tmp="$(mktemp "${target}.tmp.XXXXXX")" ||
        die "无法创建临时文件：$target"

    TMP_FILES+=("$tmp")
    printf '%s\n' "$tmp"
}

replace_file() {
    local tmp="$1"
    local target="$2"

    [[ -f "$target" ]] ||
        die "目标配置文件不存在：$target"

    chmod --reference="$target" "$tmp" ||
        die "无法继承文件权限：$target"

    chown --reference="$target" "$tmp" ||
        die "无法继承文件属主：$target"

    mv -f -- "$tmp" "$target" ||
        die "无法替换配置文件：$target"

    local i
    for i in "${!TMP_FILES[@]}"; do
        if [[ "${TMP_FILES[i]}" == "$tmp" ]]; then
            unset 'TMP_FILES[i]'
            break
        fi
    done
}

# ----------------------------------------------------------------------
# 判断指定 journald 配置文件中是否存在某个有效 key。
#
# 只识别：
#   Key=value
#   Key = value
#
# 也识别被注释的：
#   #Key=value
#   # Key=value
#
# 注释配置只用于判断“这个文件是否明确声明过该 key”。
# ----------------------------------------------------------------------
journal_file_has_key() {
    local file="$1"
    local key="$2"

    awk -v target="$key" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        /^[[:space:]]*\[/ {
            section=trim($0)
            in_journal=(section=="[Journal]")
            next
        }

        in_journal {
            line=$0
            sub(/^[[:space:]]+/, "", line)

            # 去掉可选注释符，只用于识别配置形式。
            test=line
            sub(/^#[[:space:]]*/, "", test)

            if (test ~ /^[A-Za-z][A-Za-z0-9]*[[:space:]]*=/) {
                key=test
                sub(/[[:space:]]*=.*/, "", key)

                if (key == target)
                    found=1
            }
        }

        END {
            exit(found ? 0 : 1)
        }
    ' "$file"
}

# ----------------------------------------------------------------------
# 获取 journald drop-in 中所有实际参与解析的文件。
#
# 规则：
#   /etc
#   /run
#   /usr/local/lib
#   /usr/lib
#
# 同名文件由高优先级目录覆盖低优先级目录。
# 不创建任何文件。
# ----------------------------------------------------------------------
collect_journal_dropins() {
    local dir file base
    local -A selected=()

    local dirs=(
        "/etc/systemd/journald.conf.d"
        "/run/systemd/journald.conf.d"
        "/usr/local/lib/systemd/journald.conf.d"
        "/usr/lib/systemd/journald.conf.d"
    )

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue

        for file in "$dir"/*.conf; do
            [[ -e "$file" || -L "$file" ]] || continue

            base="${file##*/}"

            # 高优先级目录先处理。
            [[ -v "selected[$base]" ]] && continue

            selected["$base"]="$file"
        done
    done

    if ((${#selected[@]})); then
        printf '%s\n' "${selected[@]}" | sort
    fi
}

# ----------------------------------------------------------------------
# 获取 journald 主配置文件。
#
# systemd 只使用优先级最高且存在的那个主配置文件。
# ----------------------------------------------------------------------
journal_main_file() {
    local file

    for file in \
        /etc/systemd/journald.conf \
        /run/systemd/journald.conf \
        /usr/local/lib/systemd/journald.conf \
        /usr/lib/systemd/journald.conf
    do
        [[ -f "$file" ]] && {
            printf '%s\n' "$file"
            return 0
        }
    done

    return 1
}

# ----------------------------------------------------------------------
# 根据 systemd 的配置顺序，找出某个 key 的最终来源。
#
# 输出：
#   FILE<TAB>VALUE
#
# 如果 key 最终没有配置，则返回失败。
#
# 注意：
#   对单值选项，最后出现的配置生效。
# ----------------------------------------------------------------------
journal_effective_source() {
    local target="$1"
    local main
    local file
    local output

    main="$(journal_main_file)" ||
        die "无法确定 journald 主配置文件。"

    {
        printf '%s\n' "$main"
        collect_journal_dropins
    } |
    while IFS= read -r file; do
        awk -v target="$target" '
            function trim(s) {
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                return s
            }

            /^[[:space:]]*\[/ {
                section=trim($0)
                in_journal=(section=="[Journal]")
                next
            }

            in_journal {
                line=$0
                sub(/^[[:space:]]+/, "", line)

                # systemd 配置中的 # 行是注释。
                if (line ~ /^#/)
                    next

                if (line ~ /^[A-Za-z][A-Za-z0-9]*[[:space:]]*=/) {
                    key=line
                    sub(/[[:space:]]*=.*/, "", key)

                    if (key == target) {
                        value=line
                        sub(/^[^=]*=[[:space:]]*/, "", value)
                        sub(/[[:space:]]+$/, "", value)
                        print FILENAME "\t" value
                    }
                }
            }
        ' "$file"
    } |
    tail -n 1
}

# ----------------------------------------------------------------------
# 对一个现有 journald 配置文件进行一次性修改。
#
# 参数：
#   $1 = 文件
#
# 该函数统一修改所有目标 key，避免一个 key 改一次文件。
#
# 特性：
#   - 支持未注释配置
#   - 支持注释配置
#   - 删除重复目标 key
#   - 没有 [Journal] 时创建
#   - 不碰其他 section
#   - 不碰其他配置
# ----------------------------------------------------------------------
configure_journal_file() {
    local file="$1"
    local tmp

    tmp="$(make_temp "$file")"

    awk \
        -v compress="${JOURNAL_EXPECTED[Compress]}" \
        -v system_max_use="${JOURNAL_EXPECTED[SystemMaxUse]}" \
        -v system_max_file_size="${JOURNAL_EXPECTED[SystemMaxFileSize]}" \
        -v system_max_files="${JOURNAL_EXPECTED[SystemMaxFiles]}" \
        -v runtime_max_use="${JOURNAL_EXPECTED[RuntimeMaxUse]}" \
        -v runtime_max_file_size="${JOURNAL_EXPECTED[RuntimeMaxFileSize]}" \
        -v runtime_max_files="${JOURNAL_EXPECTED[RuntimeMaxFiles]}" \
        -v max_retention="${JOURNAL_EXPECTED[MaxRetentionSec]}" '
        BEGIN {
            expected["Compress"] = compress
            expected["SystemMaxUse"] = system_max_use
            expected["SystemMaxFileSize"] = system_max_file_size
            expected["SystemMaxFiles"] = system_max_files
            expected["RuntimeMaxUse"] = runtime_max_use
            expected["RuntimeMaxFileSize"] = runtime_max_file_size
            expected["RuntimeMaxFiles"] = runtime_max_files
            expected["MaxRetentionSec"] = max_retention

            in_journal=0
            found_journal=0
        }

        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        function is_target(k) {
            return (k in expected)
        }

        function append_missing(    k) {
            for (k in expected) {
                if (!done[k]) {
                    print k "=" expected[k]
                    done[k]=1
                }
            }
        }

        /^[[:space:]]*\[/ {
            section=trim($0)

            if (in_journal && section != "[Journal]")
                append_missing()

            in_journal=(section=="[Journal]")

            if (in_journal)
                found_journal=1

            print
            next
        }

        in_journal {
            original=$0
            line=original

            sub(/^[[:space:]]+/, "", line)

            # 允许：
            #   Key=value
            #   Key = value
            #   #Key=value
            #   # Key=value
            test=line
            sub(/^#[[:space:]]*/, "", test)

            if (test ~ /^[A-Za-z][A-Za-z0-9]*[[:space:]]*=/) {
                key=test
                sub(/[[:space:]]*=.*/, "", key)

                if (is_target(key)) {
                    # 第一次出现保留为有效配置。
                    if (!done[key]) {
                        print key "=" expected[key]
                        done[key]=1
                    }

                    # 后续重复项全部删除。
                    next
                }
            }
        }

        {
            print
        }

        END {
            if (in_journal) {
                append_missing()
            }
            else if (!found_journal) {
                print ""
                print "[Journal]"
                append_missing()
            }
        }
    ' "$file" >"$tmp" || {
        rm -f -- "$tmp"
        die "无法生成 journald 配置：$file"
    }

    replace_file "$tmp" "$file"
}

# ----------------------------------------------------------------------
# 修改 journald。
#
# 核心安全规则：
#
# 1. 已经由 /etc 配置控制的 key：
#      修改对应的 /etc 文件。
#
# 2. 如果 key 由 /run 或 /usr* 控制：
#      不修改 vendor/transient 文件。
#      不创建新 drop-in。
#      直接失败。
#
# 3. 如果 key 完全没有显式配置：
#      修改已经存在的 /etc/systemd/journald.conf。
# ----------------------------------------------------------------------
configure_journald() {
    local key source_file source_value
    local main
    local -A files=()

    main="$(journal_main_file)" ||
        die "无法确定 journald 主配置文件。"

    for key in "${JOURNAL_KEYS[@]}"; do
        if IFS=$'\t' read -r source_file source_value < <(
            journal_effective_source "$key"
        ) && [[ -n "$source_file" ]]; then

            case "$source_file" in
                /etc/systemd/journald.conf|/etc/systemd/journald.conf.d/*.conf)
                    files["$source_file"]=1
                    ;;

                /run/systemd/journald.conf|/run/systemd/journald.conf.d/*.conf)
                    die "$key 当前由运行时配置控制：$source_file。根据“不创建配置文件、不修改 transient 配置”的要求，拒绝强行覆盖。"

                    ;;

                /usr/local/lib/systemd/journald.conf|/usr/local/lib/systemd/journald.conf.d/*.conf)
                    die "$key 当前由 /usr/local/lib vendor/local 配置控制：$source_file。为避免修改非 /etc 配置，拒绝继续。"

                    ;;

                /usr/lib/systemd/journald.conf|/usr/lib/systemd/journald.conf.d/*.conf)
                    die "$key 当前由 vendor 配置控制：$source_file。不会修改 /usr/lib，也不会创建新的 drop-in。"

                    ;;

                *)
                    die "发现无法识别的 journald 配置来源：$source_file"
                    ;;
            esac

        else
            # 没有显式配置，使用已经存在的 /etc 主配置。
            files["$JOURNAL_CONF"]=1
        fi
    done

    for source_file in "${!files[@]}"; do
        [[ -f "$source_file" ]] ||
            die "目标 journald 配置文件不存在：$source_file"

        configure_journal_file "$source_file"
        log "已修改：$source_file"
    done
}

# ----------------------------------------------------------------------
# 获取最终有效值。
#
# 不直接解析某一个文件，而是按照 systemd 实际配置组合进行验证。
# ----------------------------------------------------------------------
journal_effective_value() {
    local key="$1"
    local line value

    line="$(journal_effective_source "$key")" ||
        return 1

    value="${line#*$'\t'}"

    printf '%s\n' "$value"
}

validate_journald() {
    local key expected actual

    for key in "${JOURNAL_KEYS[@]}"; do
        expected="${JOURNAL_EXPECTED[$key]}"

        actual="$(journal_effective_value "$key")" ||
            die "无法读取 journald 最终有效配置：$key"

        [[ "$actual" == "$expected" ]] ||
            die "journald 配置错误：$key=$actual，期望：$expected"
    done

    # 再让 systemd 自己解析一次完整配置。
    systemd-analyze cat-config systemd/journald.conf >/dev/null 2>&1 ||
        die "systemd 无法解析 journald 配置。"

    log "journald 最终有效配置验证通过。"
}

# ----------------------------------------------------------------------
# 比较文件是否真的发生变化。
# ----------------------------------------------------------------------
files_differ() {
    local before="$1"
    local after="$2"

    cmp -s "$before" "$after"
}

# ----------------------------------------------------------------------
# rsyslog logrotate 修改。
#
# 只修改：
#   maxsize / size
#   rotate
#   compress / nocompress
#
# 其他 Debian 原有内容全部保留。
#
# 目标 stanza：
#   header 中包含 /var/log/
#
# 支持：
#   /var/log/a
#   /var/log/b
#   {
#       ...
#   }
#
# 也支持：
#   /var/log/a {
#       ...
#   }
# ----------------------------------------------------------------------
configure_rsyslog() {
    [[ -f "$RSYSLOG_ROTATE" ]] || {
        log "不存在 $RSYSLOG_ROTATE，跳过 rsyslog。"
        return 0
    }

    local tmp
    tmp="$(make_temp "$RSYSLOG_ROTATE")"

    awk \
        -v maxsize="$LOGROTATE_MAX_SIZE" \
        -v rotate="$LOGROTATE_ROTATE" '
        BEGIN {
            in_header=0
            in_block=0
            target_block=0

            size_done=0
            rotate_done=0
            compress_done=0
        }

        function reset_block() {
            in_header=0
            in_block=0
            target_block=0

            size_done=0
            rotate_done=0
            compress_done=0
        }

        function emit_missing() {
            if (!target_block)
                return

            if (!size_done)
                print "\tmaxsize " maxsize

            if (!rotate_done)
                print "\trotate " rotate

            if (!compress_done)
                print "\tcompress"
        }

        # 单行 stanza：
        # /var/log/foo {
        /^[[:space:]]*[^#{}]*\{[[:space:]]*$/ {
            header=$0

            target_block=(header ~ /\/var\/log\//)

            in_block=1
            in_header=0

            size_done=0
            rotate_done=0
            compress_done=0

            print
            next
        }

        # 多行 stanza header：
        # /var/log/foo
        # /var/log/bar
        # {
        !in_block && !in_header {
            line=$0
            stripped=line
            sub(/^[[:space:]]+/, "", stripped)

            if (stripped ~ /^#/ || stripped == "") {
                print
                next
            }

            if (stripped ~ /\/var\/log\// && stripped !~ /\{/) {
                in_header=1
                target_block=1
                print
                next
            }
        }

        in_header {
            if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
                in_header=0
                in_block=1

                size_done=0
                rotate_done=0
                compress_done=0

                print
                next
            }

            if ($0 !~ /^[[:space:]]*#/ && $0 ~ /\/var\/log\//)
                target_block=1

            print
            next
        }

        in_block {
            line=$0
            stripped=line

            sub(/^[[:space:]]+/, "", stripped)

            # block 结束
            if (stripped ~ /^\}[[:space:]]*$/) {
                emit_missing
                print
                reset_block()
                next
            }

            # 非目标 stanza 完全原样保留
            if (!target_block) {
                print
                next
            }

            # 去掉注释，仅用于识别目标指令。
            test=stripped
            sub(/^#[[:space:]]*/, "", test)

            # maxsize 或 size → 统一为 maxsize。
            if (test ~ /^maxsize[[:space:]]+/ ||
                test ~ /^size[[:space:]]+/) {

                if (!size_done) {
                    print "\tmaxsize " maxsize
                    size_done=1
                }

                next
            }

            # rotate。
            if (test ~ /^rotate[[:space:]]+/) {
                if (!rotate_done) {
                    print "\trotate " rotate
                    rotate_done=1
                }

                next
            }

            # compress / nocompress。
            if (test ~ /^compress([[:space:]]|$)/ ||
                test ~ /^nocompress([[:space:]]|$)/) {

                if (!compress_done) {
                    print "\tcompress"
                    compress_done=1
                }

                next
            }

            print
            next
        }

        {
            print
        }

        END {
            if (in_block)
                emit_missing
        }
    ' "$RSYSLOG_ROTATE" >"$tmp" || {
        rm -f -- "$tmp"
        die "无法修改：$RSYSLOG_ROTATE"
    }

    if cmp -s "$tmp" "$RSYSLOG_ROTATE"; then
        rm -f -- "$tmp"
        log "rsyslog 配置已经符合要求，无需修改。"
        return 0
    fi

    replace_file "$tmp" "$RSYSLOG_ROTATE"

    log "已修改：$RSYSLOG_ROTATE"
}

# ----------------------------------------------------------------------
# rsyslog 精确验证。
# ----------------------------------------------------------------------
validate_rsyslog() {
    [[ -f "$RSYSLOG_ROTATE" ]] || return 0

    awk \
        -v maxsize="$LOGROTATE_MAX_SIZE" \
        -v rotate="$LOGROTATE_ROTATE" '
        BEGIN {
            in_header=0
            in_block=0
            target_block=0

            size_ok=0
            rotate_ok=0
            compress_ok=0

            errors=0
        }

        function reset() {
            in_header=0
            in_block=0
            target_block=0

            size_ok=0
            rotate_ok=0
            compress_ok=0
        }

        function check_block() {
            if (target_block &&
                (!size_ok || !rotate_ok || !compress_ok))
                errors++
        }

        # 单行 stanza
        /^[[:space:]]*[^#{}]*\{[[:space:]]*$/ {
            target_block=($0 ~ /\/var\/log\//)

            in_block=1
            in_header=0

            size_ok=0
            rotate_ok=0
            compress_ok=0
            next
        }

        # 多行 header
        !in_block && !in_header {
            line=$0
            stripped=line
            sub(/^[[:space:]]+/, "", stripped)

            if (stripped ~ /^#/ || stripped == "")
                next

            if (stripped ~ /\/var\/log\// && stripped !~ /\{/) {
                in_header=1
                target_block=1
                next
            }
        }

        in_header {
            if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
                in_header=0
                in_block=1

                size_ok=0
                rotate_ok=0
                compress_ok=0
                next
            }

            if ($0 !~ /^[[:space:]]*#/ && $0 ~ /\/var\/log\//)
                target_block=1

            next
        }

        in_block {
            stripped=$0
            sub(/^[[:space:]]+/, "", stripped)

            if (stripped ~ /^\}[[:space:]]*$/) {
                check_block
                reset()
                next
            }

            if (!target_block)
                next

            if (stripped ~ ("^maxsize[[:space:]]+" maxsize "([[:space:]]|$)"))
                size_ok=1

            if (stripped ~ ("^rotate[[:space:]]+" rotate "([[:space:]]|$)"))
                rotate_ok=1

            if (stripped ~ /^compress[[:space:]]*$/)
                compress_ok=1
        }

        END {
            if (in_block)
                check_block

            if (errors)
                exit 1
        }
    ' "$RSYSLOG_ROTATE" ||
        die "rsyslog logrotate 配置验证失败。"

    log "rsyslog logrotate 配置验证通过。"
}

validate_logrotate() {
    command -v logrotate >/dev/null 2>&1 || {
        log "未安装 logrotate，跳过 logrotate。"
        return 0
    }

    logrotate -d "$LOGROTATE_CONF" >/dev/null 2>&1 ||
        die "logrotate 配置验证失败。"

    log "logrotate 配置验证通过。"
}

restart_journald() {
    log "重新启动 systemd-journald..."

    systemctl restart systemd-journald.service ||
        die "systemd-journald 重启失败。"

    systemctl is-active --quiet systemd-journald.service ||
        die "systemd-journald 未处于 active 状态。"

    log "systemd-journald 已正常运行。"
}

vacuum_journals() {
    log "执行 journal rotate/vacuum..."

    journalctl \
        --rotate \
        --vacuum-size="$SYSTEM_MAX_USE" \
        --vacuum-time="$MAX_RETENTION" \
        >/dev/null ||
        die "journal rotate/vacuum 失败。"

    log "journal rotate/vacuum 完成。"
}

show_status() {
    local key value

    log "最终 journald 配置："

    for key in "${JOURNAL_KEYS[@]}"; do
        value="$(journal_effective_value "$key")" ||
            value="<unavailable>"

        printf '    %-22s = %s\n' "$key" "$value"
    done

    log "systemd-journald 状态："
    systemctl --no-pager --full status systemd-journald.service 2>/dev/null |
        sed -n '1,8p' ||
        true

    log "journal 占用："
    journalctl --disk-usage 2>/dev/null || true

    log "/var/log 占用："
    du -sh /var/log 2>/dev/null || true

    log "根文件系统："
    df -h / 2>/dev/null || true
}

main() {
    require_system

    log "开始 Debian 13 日志优化。"
    log "策略：journald 32M/7day，rsyslog 5M/2 rotations。"

    configure_journald
    validate_journald

    if command -v logrotate >/dev/null 2>&1 &&
       [[ -f "$RSYSLOG_ROTATE" ]]; then

        configure_rsyslog
        validate_rsyslog
        validate_logrotate
    else
        log "未检测到完整 rsyslog/logrotate 配置，跳过 rsyslog。"
    fi

    restart_journald
    validate_journald

    vacuum_journals
    show_status

    log "Debian 13 日志优化完成。"
}

main "$@"
