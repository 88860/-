#!/bin/bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ==============================================================================
# Debian 13 (trixie) 日志优化脚本
#
# 核心原则：
#   1. 不新建任何配置文件（不创建 drop-in，不创建新文件）
#   2. 只修改 /etc 下已有的配置文件
#   3. 精准修改和取消注释，保留所有非目标配置
#   4. 如果配置由 /run 或 /usr* 控制，拒绝覆盖，直接失败
# ==============================================================================

# ------------------------------------------------------------------------------
# 常量定义
# ------------------------------------------------------------------------------

readonly JOURNAL_CONF="/etc/systemd/journald.conf"
readonly JOURNAL_DROPIN_DIR="/etc/systemd/journald.conf.d"

readonly RSYSLOG_ROTATE="/etc/logrotate.d/rsyslog"

readonly LOCK_FILE="/run/lock/debian-log-optimize.lock"

# journald 目标配置
readonly COMPRESS_VALUE="yes"
readonly SYSTEM_MAX_USE="32M"
readonly SYSTEM_MAX_FILE_SIZE="4M"
readonly SYSTEM_MAX_FILES="8"
readonly RUNTIME_MAX_USE="8M"
readonly RUNTIME_MAX_FILE_SIZE="2M"
readonly RUNTIME_MAX_FILES="4"
readonly MAX_RETENTION="7day"

# logrotate 目标配置
readonly LOGROTATE_MAX_SIZE="5M"
readonly LOGROTATE_ROTATE="2"

# journald 需要确保的 key 列表（顺序固定）
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

# journald 期望的最终值
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

# 临时文件列表，退出时自动清理
TMP_FILES=()

# ------------------------------------------------------------------------------
# 基础工具函数
# ------------------------------------------------------------------------------

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
        [[ -n "$file" && -e "$file" ]] && rm -f -- "$file"
    done
}

trap cleanup EXIT

# 创建临时文件（与目标文件同目录）
make_temp() {
    local target="$1"
    local tmp

    tmp="$(mktemp "${target}.tmp.XXXXXX")" ||
        die "无法创建临时文件：$target"

    TMP_FILES+=("$tmp")
    printf '%s\n' "$tmp"
}

# 原子替换文件（继承权限，拒绝符号链接）
atomic_replace() {
    local tmp="$1"
    local target="$2"

    [[ -f "$target" ]] || die "目标配置文件不存在：$target"
    [[ -L "$target" ]] && die "目标配置文件是符号链接，拒绝操作：$target"

    # 内容无变化则跳过
    if cmp -s "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi

    chmod --reference="$target" "$tmp" ||
        die "无法继承文件权限：$target"

    chown --reference="$target" "$tmp" ||
        die "无法继承文件属主：$target"

    mv -f -- "$tmp" "$target" ||
        die "无法替换配置文件：$target"

    # 从清理列表中移除
    local i
    for i in "${!TMP_FILES[@]}"; do
        if [[ "${TMP_FILES[i]}" == "$tmp" ]]; then
            unset 'TMP_FILES[i]'
            break
        fi
    done

    return 0
}

# ------------------------------------------------------------------------------
# 系统环境检查
# ------------------------------------------------------------------------------

require_system() {
    (( EUID == 0 )) ||
        die "必须以 root 身份运行。"

    [[ -r /etc/os-release ]] ||
        die "无法读取 /etc/os-release。"

    # shellcheck disable=SC1091
    . /etc/os-release

    [[ "${ID:-}" == "debian" ]] ||
        die "本脚本只支持 Debian，当前：${PRETTY_NAME:-unknown}"

    local major_version
    major_version="${VERSION_ID%%.*}"
    [[ "$major_version" == "13" ]] ||
        die "本脚本只支持 Debian 13 (trixie)，当前：${PRETTY_NAME:-unknown} (VERSION_ID=${VERSION_ID:-unknown})"

    local cmd
    for cmd in awk mktemp flock systemctl journalctl systemd-analyze chmod chown cmp logrotate; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "缺少必要命令：$cmd"
    done

    [[ -f "$JOURNAL_CONF" ]] ||
        die "不存在：$JOURNAL_CONF（本脚本不创建新配置文件）"

    # 文件锁，防止并发执行
    exec 9>"$LOCK_FILE"
    flock -n 9 ||
        die "已有另一个日志优化脚本正在运行（锁文件：$LOCK_FILE）"
}

# ------------------------------------------------------------------------------
# journald 配置解析与修改
# ------------------------------------------------------------------------------

# 获取 systemd 实际使用的主配置文件（优先级：/etc > /run > /usr/local/lib > /usr/lib）
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

# 收集所有参与解析的 drop-in 文件（高优先级覆盖低优先级同名文件，按文件名排序）
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
            [[ -v "selected[$base]" ]] && continue
            selected["$base"]="$file"
        done
    done

    if ((${#selected[@]})); then
        printf '%s\n' "${selected[@]}" | sort
    fi
}

# 查找某个 key 的最终来源和值
# 输出格式：FILENAME<TAB>VALUE
# 如果 key 未配置，返回失败
journal_effective_source() {
    local target="$1"
    local main output

    main="$(journal_main_file)" ||
        die "无法确定 journald 主配置文件。"

    output="$(
        {
            printf '%s\n' "$main"
            collect_journal_dropins
        } |
        while IFS= read -r file; do
            [[ -f "$file" ]] || continue
            awk -v target="$target" '
                function trim(s) {
                    sub(/^[[:space:]]+/, "", s)
                    sub(/[[:space:]]+$/, "", s)
                    return s
                }

                /^[[:space:]]*\[/ {
                    section = trim($0)
                    in_journal = (section == "[Journal]")
                    next
                }

                in_journal {
                    line = $0
                    sub(/^[[:space:]]+/, "", line)

                    # 跳过注释行和空行
                    if (line ~ /^#/ || line == "")
                        next

                    if (line ~ /^[A-Za-z][A-Za-z0-9]*[[:space:]]*=/) {
                        key = line
                        sub(/[[:space:]]*=.*/, "", key)

                        if (key == target) {
                            value = line
                            sub(/^[^=]*=[[:space:]]*/, "", value)
                            sub(/[[:space:]]+$/, "", value)
                            print FILENAME "\t" value
                        }
                    }
                }
            ' "$file"
        done | tail -n 1
    )"

    [[ -n "$output" ]] || return 1
    printf '%s\n' "$output"
}

# 获取某个 key 的最终生效值
journal_effective_value() {
    local key="$1"
    local line value

    line="$(journal_effective_source "$key")" ||
        return 1

    value="${line#*$'\t'}"
    printf '%s\n' "$value"
}

# 修改单个 journald 配置文件（统一修改所有目标 key）
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
            expected["Compress"]           = compress
            expected["SystemMaxUse"]       = system_max_use
            expected["SystemMaxFileSize"]  = system_max_file_size
            expected["SystemMaxFiles"]     = system_max_files
            expected["RuntimeMaxUse"]      = runtime_max_use
            expected["RuntimeMaxFileSize"] = runtime_max_file_size
            expected["RuntimeMaxFiles"]    = runtime_max_files
            expected["MaxRetentionSec"]    = max_retention

            in_journal    = 0
            found_journal = 0
        }

        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        function is_target_key(k) {
            return (k in expected)
        }

        # 按固定顺序补全缺失的 key，确保输出可预测
        function emit_missing_keys() {
            if (!done["Compress"])           { print "Compress="           expected["Compress"];           done["Compress"]           = 1 }
            if (!done["SystemMaxUse"])       { print "SystemMaxUse="       expected["SystemMaxUse"];       done["SystemMaxUse"]       = 1 }
            if (!done["SystemMaxFileSize"])  { print "SystemMaxFileSize="  expected["SystemMaxFileSize"];  done["SystemMaxFileSize"]  = 1 }
            if (!done["SystemMaxFiles"])     { print "SystemMaxFiles="     expected["SystemMaxFiles"];     done["SystemMaxFiles"]     = 1 }
            if (!done["RuntimeMaxUse"])      { print "RuntimeMaxUse="      expected["RuntimeMaxUse"];      done["RuntimeMaxUse"]      = 1 }
            if (!done["RuntimeMaxFileSize"]) { print "RuntimeMaxFileSize=" expected["RuntimeMaxFileSize"]; done["RuntimeMaxFileSize"] = 1 }
            if (!done["RuntimeMaxFiles"])    { print "RuntimeMaxFiles="    expected["RuntimeMaxFiles"];    done["RuntimeMaxFiles"]    = 1 }
            if (!done["MaxRetentionSec"])    { print "MaxRetentionSec="    expected["MaxRetentionSec"];    done["MaxRetentionSec"]    = 1 }
        }

        # Section 头
        /^[[:space:]]*\[/ {
            section = trim($0)

            # 离开 [Journal] 时补全缺失 key
            if (in_journal && section != "[Journal]") {
                emit_missing_keys()
            }

            in_journal = (section == "[Journal]")
            if (in_journal) found_journal = 1

            print
            next
        }

        # 在 [Journal] section 内
        in_journal {
            original = $0
            line = original
            sub(/^[[:space:]]+/, "", line)

            # 测试行：去掉可选注释符（仅用于识别配置形式）
            test_line = line
            sub(/^#[[:space:]]*/, "", test_line)

            # 匹配 Key=value 形式（包括被注释的）
            if (test_line ~ /^[A-Za-z][A-Za-z0-9]*[[:space:]]*=/) {
                key = test_line
                sub(/[[:space:]]*=.*/, "", key)

                if (is_target_key(key)) {
                    if (!done[key]) {
                        # 第一次出现：替换为期望值（取消注释）
                        print key "=" expected[key]
                        done[key] = 1
                    }
                    # 后续重复项全部删除
                    next
                }
            }

            # 非目标行：保留原样
            print
            next
        }

        # 其他 section 或非 section 行：原样保留
        {
            print
        }

        END {
            if (in_journal) {
                emit_missing_keys()
            } else if (!found_journal) {
                # 文件中没有 [Journal] section，在末尾创建
                print ""
                print "[Journal]"
                emit_missing_keys()
            }
        }
    ' "$file" > "$tmp" || {
        rm -f -- "$tmp"
        die "无法生成 journald 配置：$file"
    }

    if atomic_replace "$tmp" "$file"; then
        log "已修改：$file"
    else
        log "已是最新，无需修改：$file"
    fi
}

# 核心安全规则：
#   1. 已经由 /etc 配置控制的 key → 修改对应的 /etc 文件
#   2. 如果 key 由 /run 或 /usr* 控制 → 拒绝修改，直接失败
#   3. 如果 key 完全没有显式配置 → 修改 /etc/systemd/journald.conf
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
                    die "$key 当前由运行时配置控制：$source_file。根据"不创建配置文件、不修改 transient 配置"的要求，拒绝强行覆盖。"
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
            # 没有显式配置，使用 /etc 主配置（必须已存在）
            files["$JOURNAL_CONF"]=1
        fi
    done

    for source_file in "${!files[@]}"; do
        [[ -f "$source_file" ]] ||
            die "目标 journald 配置文件不存在：$source_file"

        configure_journal_file "$source_file"
    done
}

# 验证 journald 最终生效值
validate_journald() {
    local key expected actual

    for key in "${JOURNAL_KEYS[@]}"; do
        expected="${JOURNAL_EXPECTED[$key]}"

        actual="$(journal_effective_value "$key")" ||
            die "journald 配置验证失败：$key 没有生效的配置值（可能配置未被正确写入）"

        [[ "$actual" == "$expected" ]] ||
            die "journald 配置验证失败：$key=$actual，期望：$expected"
    done

    # 让 systemd 自己解析验证
    if ! systemd-analyze cat-config systemd/journald.conf >/dev/null 2>&1; then
        die "systemd 无法解析 journald 配置，可能存在语法错误。"
    fi

    log "journald 最终有效配置验证通过。"
}

# 重启 journald 以应用配置
restart_journald() {
    log "重启 systemd-journald 以应用新配置..."
    if systemctl restart systemd-journald; then
        log "systemd-journald 重启成功。"
    else
        die "systemd-journald 重启失败，请手动检查。"
    fi
}

# ------------------------------------------------------------------------------
# rsyslog logrotate 配置修改与验证
# ------------------------------------------------------------------------------

# 修改 rsyslog logrotate 配置
# 只修改包含 /var/log/ 的 stanza 中的 maxsize/size、rotate、compress/nocompress
configure_rsyslog() {
    [[ -f "$RSYSLOG_ROTATE" ]] || {
        log "不存在 $RSYSLOG_ROTATE，跳过 rsyslog 配置优化。"
        return 0
    }

    local tmp
    tmp="$(make_temp "$RSYSLOG_ROTATE")"

    awk \
        -v maxsize="$LOGROTATE_MAX_SIZE" \
        -v rotate="$LOGROTATE_ROTATE" '

        BEGIN {
            in_header = 0
            in_block  = 0
            target_block = 0

            size_done     = 0
            rotate_done   = 0
            compress_done = 0
        }

        function reset_block() {
            in_header = 0
            in_block  = 0
            target_block = 0

            size_done     = 0
            rotate_done   = 0
            compress_done = 0
        }

        function emit_missing() {
            if (!target_block) return

            if (!size_done)     print "\tmaxsize " maxsize
            if (!rotate_done)   print "\trotate " rotate
            if (!compress_done) print "\tcompress"
        }

        # 单行 stanza：/var/log/foo {
        /^[[:space:]]*[^#{}]*\{[[:space:]]*$/ {
            target_block = ($0 ~ /\/var\/log\//)

            in_block = 1
            in_header = 0

            size_done = 0; rotate_done = 0; compress_done = 0

            print
            next
        }

        # 多行 stanza header 的第一行
        !in_block && !in_header {
            line = $0
            stripped = line
            sub(/^[[:space:]]+/, "", stripped)

            if (stripped ~ /^#/ || stripped == "") {
                print
                next
            }

            if (stripped ~ /\/var\/log\// && stripped !~ /\{/) {
                in_header = 1
                target_block = 1
                print
                next
            }
        }

        # 多行 stanza header 的后续行
        in_header {
            if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
                in_header = 0
                in_block = 1

                size_done = 0; rotate_done = 0; compress_done = 0

                print
                next
            }

            if ($0 !~ /^[[:space:]]*#/ && $0 ~ /\/var\/log\//)
                target_block = 1

            print
            next
        }

        # block 内部
        in_block {
            line = $0
            stripped = line
            sub(/^[[:space:]]+/, "", stripped)

            # block 结束（允许 } 后面有注释）
            if (stripped ~ /^\}/) {
                emit_missing()
                print
                reset_block()
                next
            }

            # 非目标 stanza 完全原样保留
            if (!target_block) {
                print
                next
            }

            # 去掉注释，仅用于识别目标指令
            test_line = stripped
            sub(/^#[[:space:]]*/, "", test_line)

            # maxsize 或 size → 统一为 maxsize
            if (test_line ~ /^maxsize[[:space:]]+/ ||
                test_line ~ /^size[[:space:]]+/) {

                if (!size_done) {
                    print "\tmaxsize " maxsize
                    size_done = 1
                }
                next
            }

            # rotate
            if (test_line ~ /^rotate[[:space:]]+/) {
                if (!rotate_done) {
                    print "\trotate " rotate
                    rotate_done = 1
                }
                next
            }

            # compress / nocompress
            if (test_line ~ /^compress([[:space:]]|$)/ ||
                test_line ~ /^nocompress([[:space:]]|$)/) {

                if (!compress_done) {
                    print "\tcompress"
                    compress_done = 1
                }
                next
            }

            # 其他指令原样保留
            print
            next
        }

        # 全局行（不在任何 block 中）
        {
            print
        }

        END {
            if (in_block) emit_missing()
        }
    ' "$RSYSLOG_ROTATE" > "$tmp" || {
        rm -f -- "$tmp"
        die "无法生成 rsyslog logrotate 配置。"
    }

    if atomic_replace "$tmp" "$RSYSLOG_ROTATE"; then
        log "已修改：$RSYSLOG_ROTATE"
    else
        log "rsyslog 配置已经符合要求，无需修改。"
    fi
}

# 验证 rsyslog logrotate 配置
validate_rsyslog() {
    [[ -f "$RSYSLOG_ROTATE" ]] || return 0

    local -a errors=()
    local line

    while IFS= read -r line; do
        errors+=("$line")
    done < <(awk \
        -v maxsize="$LOGROTATE_MAX_SIZE" \
        -v rotate="$LOGROTATE_ROTATE" '

        BEGIN {
            in_header = 0
            in_block  = 0
            target_block = 0

            size_ok     = 0
            rotate_ok   = 0
            compress_ok = 0
            block_num   = 0
        }

        function reset_block() {
            in_header = 0
            in_block  = 0
            target_block = 0

            size_ok     = 0
            rotate_ok   = 0
            compress_ok = 0
        }

        function report_error() {
            if (target_block && (!size_ok || !rotate_ok || !compress_ok)) {
                msg = "Block " block_num " (/var/log/): "
                if (!size_ok)     msg = msg "缺少 maxsize " maxsize "; "
                if (!rotate_ok)   msg = msg "缺少 rotate " rotate "; "
                if (!compress_ok) msg = msg "缺少 compress; "
                print msg
            }
        }

        # 单行 stanza
        /^[[:space:]]*[^#{}]*\{[[:space:]]*$/ {
            block_num++
            target_block = ($0 ~ /\/var\/log\//)

            in_block = 1
            in_header = 0

            size_ok = 0; rotate_ok = 0; compress_ok = 0
            next
        }

        # 多行 header 第一行
        !in_block && !in_header {
            line = $0
            sub(/^[[:space:]]+/, "", line)

            if (line ~ /^#/ || line == "") next

            if (line ~ /\/var\/log\// && line !~ /\{/) {
                in_header = 1
                target_block = 1
                next
            }
        }

        # 多行 header 后续行
        in_header {
            if ($0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
                block_num++
                in_header = 0
                in_block = 1

                size_ok = 0; rotate_ok = 0; compress_ok = 0
                next
            }

            if ($0 !~ /^[[:space:]]*#/ && $0 ~ /\/var\/log\//)
                target_block = 1

            next
        }

        # block 内部
        in_block {
            line = $0
            sub(/^[[:space:]]+/, "", line)

            if (line ~ /^\}/) {
                report_error()
                reset_block()
                next
            }

            if (!target_block) next

            test_line = line
            sub(/^#[[:space:]]*/, "", test_line)

            if (test_line ~ /^maxsize[[:space:]]+/ || test_line ~ /^size[[:space:]]+/) {
                split(test_line, a, /[[:space:]]+/)
                if (a[2] == maxsize) size_ok = 1
                next
            }

            if (test_line ~ /^rotate[[:space:]]+/) {
                split(test_line, a, /[[:space:]]+/)
                if (a[2] == rotate) rotate_ok = 1
                next
            }

            if (test_line ~ /^compress([[:space:]]|$)/) {
                compress_ok = 1
                next
            }

            next
        }

        END {
            if (in_block) report_error()
        }
    ' "$RSYSLOG_ROTATE")

    if ((${#errors[@]} == 0)); then
        log "rsyslog logrotate 配置验证通过。"
    else
        local err
        for err in "${errors[@]}"; do
            log "[rsyslog 验证失败] $err"
        done
        die "rsyslog logrotate 配置验证失败，发现 ${#errors[@]} 个错误。"
    fi
}

# 使用 logrotate 自身测试配置语法
validate_logrotate_syntax() {
    [[ -f "$RSYSLOG_ROTATE" ]] || return 0

    log "测试 logrotate 配置语法..."
    if logrotate -d "$RSYSLOG_ROTATE" >/dev/null 2>&1; then
        log "logrotate 配置语法正确。"
    else
        die "logrotate 配置语法测试失败：$RSYSLOG_ROTATE"
    fi
}

# ------------------------------------------------------------------------------
# 主流程
# ------------------------------------------------------------------------------

main() {
    require_system

    log "========================================"
    log "开始 Debian 13 日志优化配置"
    log "========================================"

    # journald
    log "----- 配置 journald -----"
    configure_journald
    validate_journald
    restart_journald

    # rsyslog logrotate
    log "----- 配置 rsyslog logrotate -----"
    configure_rsyslog
    validate_rsyslog
    validate_logrotate_syntax

    log "========================================"
    log "日志优化配置全部完成"
    log "========================================"
}

main "$@"
