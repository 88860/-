#!/bin/bash
set -Eeuo pipefail

###############################################################################
# Debian 13 systemd-journald 日志优化 - Production
#
# 目标：
#   - 仅修改现有 /etc/systemd/journald.conf
#   - 不创建任何 journald drop-in
#   - 不修改 rsyslog / logrotate
#   - 不主动删除历史 journal
#   - 支持取消注释
#   - 支持重复项清理
#   - 完全幂等
#   - 修改后验证 systemd effective configuration
#
# Debian 13 / systemd 257
###############################################################################

umask 022

readonly SCRIPT_NAME="${0##*/}"

readonly JOURNAL_CONF="/etc/systemd/journald.conf"
readonly LOCK_DIR="/run/lock"
readonly LOCK_FILE="${LOCK_DIR}/debian-journald-optimize.lock"
readonly TEMP_DIR="/run"
readonly SERVICE="systemd-journald.service"

###############################################################################
# 目标配置
###############################################################################

readonly COMPRESS_VALUE="yes"

readonly SYSTEM_MAX_USE="32M"
readonly SYSTEM_MAX_FILE_SIZE="4M"
readonly SYSTEM_MAX_FILES="8"

readonly RUNTIME_MAX_USE="8M"
readonly RUNTIME_MAX_FILE_SIZE="2M"
readonly RUNTIME_MAX_FILES="4"

readonly MAX_RETENTION="7day"

declare -ar JOURNAL_KEYS=(
    "Compress"
    "SystemMaxUse"
    "SystemMaxFileSize"
    "SystemMaxFiles"
    "RuntimeMaxUse"
    "RuntimeMaxFileSize"
    "RuntimeMaxFiles"
)

declare -ar JOURNAL_VALUES=(
    "$COMPRESS_VALUE"
    "$SYSTEM_MAX_USE"
    "$SYSTEM_MAX_FILE_SIZE"
    "$SYSTEM_MAX_FILES"
    "$RUNTIME_MAX_USE"
    "$RUNTIME_MAX_FILE_SIZE"
    "$RUNTIME_MAX_FILES"
    "$MAX_RETENTION"
)

###############################################################################
# 全局状态
###############################################################################

LOCK_FD=9
TEMP_FILE=""
CONFIG_CHANGED=0

###############################################################################
# 日志
###############################################################################

log() {
    printf '[%(%F %T)T] %s\n' -1 "$*"
}

warn() {
    printf '[%(%F %T)T] WARNING: %s\n' -1 "$*" >&2
}

die() {
    printf '[%(%F %T)T] ERROR: %s\n' -1 "$*" >&2
    exit 1
}

###############################################################################
# 清理
###############################################################################

cleanup() {
    local rc=$?

    if [[ -n "${TEMP_FILE:-}" && -e "$TEMP_FILE" ]]; then
        rm -f -- "$TEMP_FILE" || true
    fi

    exit "$rc"
}

trap cleanup EXIT

###############################################################################
# 必要命令
###############################################################################

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "缺少必要命令：$1"
}

###############################################################################
# Debian 13 / root / 文件检查
###############################################################################

require_system() {
    (( EUID == 0 )) ||
        die "必须以 root 身份运行。"

    [[ -r /etc/os-release ]] ||
        die "无法读取 /etc/os-release。"

    # shellcheck disable=SC1091
    . /etc/os-release

    [[ "${ID:-}" == "debian" ]] ||
        die "本脚本只支持 Debian。当前：${PRETTY_NAME:-unknown}"

    [[ "${VERSION_ID:-}" == "13" ]] ||
        die "本脚本只支持 Debian 13。当前：${PRETTY_NAME:-unknown}"

    [[ -f "$JOURNAL_CONF" ]] ||
        die "现有配置文件不存在：$JOURNAL_CONF"

    [[ -r "$JOURNAL_CONF" ]] ||
        die "无法读取：$JOURNAL_CONF"

    [[ -w "$JOURNAL_CONF" ]] ||
        die "无法写入：$JOURNAL_CONF"

    require_command awk
    require_command cmp
    require_command find
    require_command flock
    require_command mktemp
    require_command mv
    require_command rm
    require_command stat
    require_command systemctl
    require_command systemd-analyze
    require_command journalctl

    mkdir -p "$LOCK_DIR"

    exec "$LOCK_FD>"$LOCK_FILE""

    flock -n "$LOCK_FD" ||
        die "已有另一个 $SCRIPT_NAME 正在运行。"

    log "系统检查通过：${PRETTY_NAME:-Debian 13}"
}

###############################################################################
# 检查 journald 服务
###############################################################################

check_journald() {
    systemctl is-active --quiet "$SERVICE" ||
        die "$SERVICE 当前不是 active，拒绝修改配置。"

    log "$SERVICE 当前运行正常。"
}

###############################################################################
# 检查当前 journald.conf
###############################################################################

validate_current_config() {
    systemd-analyze cat-config systemd/journald.conf \
        >/dev/null 2>&1 ||
        die "当前 $JOURNAL_CONF 无法通过 systemd 配置解析。未修改任何内容。"

    log "当前 journald 配置语法检查通过。"
}

###############################################################################
# 判断某一行是否为指定目标参数
#
# 支持：
#
#   Compress=yes
#   Compress = yes
#   #Compress=yes
#   # Compress=yes
#   #Compress = yes
#
# 注意：
#   这里只判断参数名，不判断 value。
###############################################################################

line_is_key() {
    local line="$1"
    local key="$2"

    awk -v line="$line" -v key="$key" '
        BEGIN {
            s = line

            # 删除行首空白
            sub(/^[[:space:]]+/, "", s)

            # 删除注释符
            sub(/^#[[:space:]]*/, "", s)

            # 精确匹配 key
            if (s ~ ("^" key "[[:space:]]*="))
                exit 0

            exit 1
        }
    '
}

###############################################################################
# 检查所有 journald drop-in
#
# 如果目标参数已经在 drop-in 中定义，则不能只修改主配置后声称成功。
#
# 本脚本严格遵守：
#   只修改 /etc/systemd/journald.conf
#
# 因此：
#   发现目标参数被 drop-in 定义 -> 直接终止。
###############################################################################

check_target_dropins() {
    local dir
    local file
    local line
    local key
    local found=0

    local dirs=(
        "/etc/systemd/journald.conf.d"
        "/run/systemd/journald.conf.d"
        "/usr/local/lib/systemd/journald.conf.d"
        "/usr/lib/systemd/journald.conf.d"
    )

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue

        while IFS= read -r -d '' file; do
            [[ -f "$file" ]] || continue

            while IFS= read -r line || [[ -n "$line" ]]; do

                # 忽略空行
                [[ "$line" =~ ^[[:space:]]*$ ]] && continue

                # 忽略纯注释
                [[ "$line" =~ ^[[:space:]]*# ]] && continue

                for key in "${JOURNAL_KEYS[@]}"; do
                    if line_is_key "$line" "$key"; then
                        printf \
                            '    file=%s key=%s line=%s\n' \
                            "$file" "$key" "$line" >&2

                        found=1
                    fi
                done

            done < "$file"

        done < <(
            find "$dir" \
                -maxdepth 1 \
                -type f \
                -name '*.conf' \
                -print0 |
                sort -z
        )
    done

    if (( found != 0 )); then
        die "检测到 journald drop-in 定义了目标参数。由于本脚本严格只允许修改 $JOURNAL_CONF，因此拒绝继续。"
    fi

    log "drop-in 检查通过：没有发现目标参数覆盖。"
}

###############################################################################
# 从现有 /etc/systemd/journald.conf 读取目标参数
###############################################################################

read_file_value() {
    local target="$1"

    awk -v target="$target" '
        BEGIN {
            in_journal = 0
            found = 0
        }

        /^[[:space:]]*\[/ {
            section = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)

            in_journal = (section == "[Journal]")
            next
        }

        in_journal {
            line = $0

            sub(/^[[:space:]]+/, "", line)

            # 空行
            if (line ~ /^[[:space:]]*$/)
                next

            # 注释
            if (line ~ /^#/)
                next

            if (line ~ ("^" target "[[:space:]]*=")) {
                value = line
                sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]+$/, "", value)

                print value
                found = 1
            }
        }

        END {
            if (!found)
                exit 1
        }
    ' "$JOURNAL_CONF"
}

###############################################################################
# 生成修改后的配置
#
# 规则：
#
# 1. [Journal] 存在：
#      - 进入 [Journal]
#      - 对目标 key：
#          第一次出现 -> 写入目标值
#          后续出现   -> 删除
#      - 注释形式也视为该 key
#
# 2. [Journal] 不存在：
#      - 在文件末尾新增 [Journal]
#      - 只是在现有配置文件中增加 section
#
# 3. 其他 section：
#      - 完全原样保留
#
# 4. 其他行：
#      - 完全原样保留
###############################################################################

build_candidate() {
    local output="$1"

    awk \
        -v compress="$COMPRESS_VALUE" \
        -v system_max_use="$SYSTEM_MAX_USE" \
        -v system_max_file_size="$SYSTEM_MAX_FILE_SIZE" \
        -v system_max_files="$SYSTEM_MAX_FILES" \
        -v runtime_max_use="$RUNTIME_MAX_USE" \
        -v runtime_max_file_size="$RUNTIME_MAX_FILE_SIZE" \
        -v runtime_max_files="$RUNTIME_MAX_FILES" \
        -v max_retention="$MAX_RETENTION" '

        BEGIN {
            expected["Compress"] = compress
            expected["SystemMaxUse"] = system_max_use
            expected["SystemMaxFileSize"] = system_max_file_size
            expected["SystemMaxFiles"] = system_max_files
            expected["RuntimeMaxUse"] = runtime_max_use
            expected["RuntimeMaxFileSize"] = runtime_max_file_size
            expected["RuntimeMaxFiles"] = runtime_max_files
            expected["MaxRetentionSec"] = max_retention

            order[1] = "Compress"
            order[2] = "SystemMaxUse"
            order[3] = "SystemMaxFileSize"
            order[4] = "SystemMaxFiles"
            order[5] = "RuntimeMaxUse"
            order[6] = "RuntimeMaxFileSize"
            order[7] = "RuntimeMaxFiles"
            order[8] = "MaxRetentionSec"

            for (i = 1; i <= 8; i++)
                done[order[i]] = 0

            in_journal = 0
            found_journal = 0
        }

        function emit_missing(    i,k) {
            for (i = 1; i <= 8; i++) {
                k = order[i]

                if (!done[k]) {
                    print k "=" expected[k]
                    done[k] = 1
                }
            }
        }

        function target_key(line,    i,k,test) {
            test = line

            sub(/^[[:space:]]+/, "", test)
            sub(/^#[[:space:]]*/, "", test)

            for (i = 1; i <= 8; i++) {
                k = order[i]

                if (test ~ ("^" k "[[:space:]]*="))
                    return k
            }

            return ""
        }

        /^[[:space:]]*\[/ {
            section = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)

            # 离开 [Journal]
            if (in_journal && section != "[Journal]") {
                emit_missing()
                in_journal = 0
            }

            if (section == "[Journal]") {
                in_journal = 1
                found_journal = 1
            }

            print
            next
        }

        in_journal {
            key = target_key($0)

            if (key != "") {

                # 第一次出现：替换为标准形式
                if (!done[key]) {
                    print key "=" expected[key]
                    done[key] = 1
                }

                # 第二次及以后：直接删除
                next
            }
        }

        {
            print
        }

        END {
            # 文件末尾仍处于 [Journal]
            if (in_journal) {
                emit_missing()
            }

            # 完全没有 [Journal]
            else if (!found_journal) {
                print ""
                print "[Journal]"
                emit_missing()
            }
        }
    ' "$JOURNAL_CONF" > "$output" ||
        die "无法生成候选配置。"
}

###############################################################################
# 检查候选文件是否为普通文件
###############################################################################

validate_candidate_file() {
    local file="$1"

    [[ -f "$file" ]] ||
        die "候选配置不是普通文件。"

    [[ -r "$file" ]] ||
        die "候选配置不可读取。"

    [[ -s "$file" ]] ||
        die "候选配置为空，拒绝替换。"
}

###############################################################################
# 原子替换
#
# 临时文件只存在于 /run。
# /etc/systemd/journald.conf 只在最终 mv 时被替换。
###############################################################################

install_candidate() {
    local candidate="$1"

    if cmp -s "$JOURNAL_CONF" "$candidate"; then
        CONFIG_CHANGED=0
        log "当前配置已经符合目标值，无需修改。"
        return
    fi

    # 保留原文件权限和 owner/group
    chmod --reference="$JOURNAL_CONF" "$candidate" ||
        die "无法设置候选文件权限。"

    chown --reference="$JOURNAL_CONF" "$candidate" ||
        die "无法设置候选文件 owner/group。"

    mv -f -- "$candidate" "$JOURNAL_CONF" ||
        die "无法替换 $JOURNAL_CONF。"

    CONFIG_CHANGED=1

    log "已修改现有配置：$JOURNAL_CONF"
}

###############################################################################
# 修改 journald.conf
###############################################################################

configure_journald() {
    TEMP_FILE="$(
        mktemp "${TEMP_DIR}/debian-journald-optimize.XXXXXX"
    )" || die "无法在 /run 创建临时工作文件。"

    build_candidate "$TEMP_FILE"

    validate_candidate_file "$TEMP_FILE"

    install_candidate "$TEMP_FILE"

    rm -f -- "$TEMP_FILE"
    TEMP_FILE=""
}

###############################################################################
# 验证文件中的目标参数
###############################################################################

validate_file_values() {
    local i
    local key
    local expected
    local actual

    for ((i = 0; i < ${#JOURNAL_KEYS[@]}; i++)); do

        key="${JOURNAL_KEYS[i]}"
        expected="${JOURNAL_VALUES[i]}"

        actual="$(read_file_value "$key")" ||
            die "无法从 $JOURNAL_CONF 读取 $key。"

        [[ "$actual" == "$expected" ]] ||
            die \
                "文件验证失败：$key=$actual，期望=$expected"

    done

    log "journald.conf 文件值验证通过。"
}

###############################################################################
# 取得 systemd 实际解析结果
#
# 使用 systemd-analyze cat-config，而不是自己猜 systemd 的优先级。
###############################################################################

effective_value() {
    local target="$1"

    systemd-analyze cat-config systemd/journald.conf |
        awk -v target="$target" '
            BEGIN {
                in_journal = 0
                found = 0
            }

            /^[[:space:]]*\[/ {
                section = $0
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)

                in_journal = (section == "[Journal]")
                next
            }

            in_journal {
                line = $0

                sub(/^[[:space:]]+/, "", line)

                # 空行
                if (line ~ /^[[:space:]]*$/)
                    next

                # 注释
                if (line ~ /^#/)
                    next

                if (line ~ ("^" target "[[:space:]]*=")) {
                    value = line
                    sub(/^[^=]*=[[:space:]]*/, "", value)
                    sub(/[[:space:]]+$/, "", value)

                    print value
                    found = 1
                }
            }

            END {
                if (!found)
                    exit 1
            }
        ' |
        tail -n 1
}

###############################################################################
# 验证 systemd effective configuration
###############################################################################

validate_effective_values() {
    systemd-analyze cat-config systemd/journald.conf \
        >/dev/null 2>&1 ||
        die "systemd 无法解析最终 journald 配置。"

    local i
    local key
    local expected
    local actual

    for ((i = 0; i < ${#JOURNAL_KEYS[@]}; i++)); do

        key="${JOURNAL_KEYS[i]}"
        expected="${JOURNAL_VALUES[i]}"

        actual="$(effective_value "$key")" ||
            die "无法取得 systemd effective value：$key"

        [[ "$actual" == "$expected" ]] ||
            die \
                "effective value 验证失败：$key=$actual，期望=$expected"

    done

    log "systemd effective configuration 验证通过。"
}

###############################################################################
# 应用配置
#
# journald.conf 修改后，通过 restart 让运行中的 journald 重新读取配置。
###############################################################################

apply_configuration() {
    if (( CONFIG_CHANGED == 0 )); then
        log "配置没有发生变化，不重启 systemd-journald。"
        return
    fi

    log "正在重启 systemd-journald..."

    systemctl restart "$SERVICE" ||
        die "systemd-journald 重启失败。"

    systemctl is-active --quiet "$SERVICE" ||
        die "systemd-journald 重启后未处于 active 状态。"

    log "systemd-journald 重启成功。"
}

###############################################################################
# 最终服务状态
###############################################################################

validate_service() {
    systemctl is-active --quiet "$SERVICE" ||
        die "最终检查失败：$SERVICE 未运行。"

    log "服务状态验证通过：$SERVICE active。"
}

###############################################################################
# 状态输出
###############################################################################

show_status() {
    log "最终 effective journald 配置："

    local i
    local key
    local value

    for ((i = 0; i < ${#JOURNAL_KEYS[@]}; i++)); do

        key="${JOURNAL_KEYS[i]}"

        if value="$(effective_value "$key" 2>/dev/null)"; then
            printf '    %-22s = %s\n' "$key" "$value"
        else
            printf '    %-22s = <unavailable>\n' "$key"
        fi

    done

    printf '\n'

    log "Journal 磁盘占用："
    journalctl --disk-usage 2>/dev/null || true

    printf '\n'

    log "/var/log 占用："
    du -sh /var/log 2>/dev/null || true

    printf '\n'

    log "根文件系统："
    df -h / 2>/dev/null || true
}

###############################################################################
# 主流程
###############################################################################

main() {
    log "============================================================"
    log "Debian 13 systemd-journald 日志优化"
    log "============================================================"

    require_system

    check_journald

    validate_current_config

    # 如果任何 drop-in 覆盖目标参数，立即终止。
    check_target_dropins

    configure_journald

    # 文件级验证
    validate_file_values

    # systemd 实际解析结果验证
    validate_effective_values

    # 只有真正发生修改才重启
    apply_configuration

    # 重启后再次验证
    validate_service
    validate_effective_values

    show_status

    log "============================================================"
    log "日志优化完成。"
    log "============================================================"
}

main "$@"
