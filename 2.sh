#!/bin/bash
set -Eeuo pipefail

readonly JOURNAL_CONF="/etc/systemd/journald.conf"
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
readonly LOGROTATE_ROTATE="1"

# validate_journald() 与 show_status() 共用同一份期望值列表，避免两处重复维护
readonly JOURNAL_EXPECTED="Compress $COMPRESS_VALUE
SystemMaxUse $SYSTEM_MAX_USE
SystemMaxFileSize $SYSTEM_MAX_FILE_SIZE
SystemMaxFiles $SYSTEM_MAX_FILES
RuntimeMaxUse $RUNTIME_MAX_USE
RuntimeMaxFileSize $RUNTIME_MAX_FILE_SIZE
RuntimeMaxFiles $RUNTIME_MAX_FILES
MaxRetentionSec $MAX_RETENTION"


log() {
    printf '[%(%F %T)T] %s\n' -1 "$*"
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}


require_system() {
    (( EUID == 0 )) ||
        die "必须以 root 身份运行。"

    [[ -r /etc/os-release ]] ||
        die "无法读取 /etc/os-release。"

    # shellcheck disable=SC1091
    . /etc/os-release

    [[ "$ID" == "debian" && "$VERSION_ID" == "13" ]] ||
        die "本脚本只支持 Debian 13，当前：${PRETTY_NAME:-unknown}"

    local cmd
    for cmd in systemctl journalctl systemd-analyze awk mktemp flock; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "缺少必要命令：$cmd"
    done

    [[ -f "$JOURNAL_CONF" ]] ||
        die "文件不存在：$JOURNAL_CONF"

    exec 9>"$LOCK_FILE"
    flock -n 9 ||
        die "已有另一个日志优化脚本正在运行。"
}


replace_file() {
    local tmp="$1" target="$2"

    chmod --reference="$target" "$tmp" &&
        chown --reference="$target" "$tmp" &&
        mv -f -- "$tmp" "$target" || {
        rm -f -- "$tmp"
        die "无法替换文件：$target"
    }
}


configure_journald() {
    local tmp

    tmp="$(mktemp "${JOURNAL_CONF}.tmp.XXXXXX")" ||
        die "无法创建 journald 临时文件。"

    awk \
        -v compress="$COMPRESS_VALUE" \
        -v system_max_use="$SYSTEM_MAX_USE" \
        -v system_max_file_size="$SYSTEM_MAX_FILE_SIZE" \
        -v system_max_files="$SYSTEM_MAX_FILES" \
        -v runtime_max_use="$RUNTIME_MAX_USE" \
        -v runtime_max_file_size="$RUNTIME_MAX_FILE_SIZE" \
        -v runtime_max_files="$RUNTIME_MAX_FILES" \
        -v max_retention="$MAX_RETENTION" '
        function add_defaults() {
            if (!seen["Compress"])
                print "Compress=" compress
            if (!seen["SystemMaxUse"])
                print "SystemMaxUse=" system_max_use
            if (!seen["SystemMaxFileSize"])
                print "SystemMaxFileSize=" system_max_file_size
            if (!seen["SystemMaxFiles"])
                print "SystemMaxFiles=" system_max_files
            if (!seen["RuntimeMaxUse"])
                print "RuntimeMaxUse=" runtime_max_use
            if (!seen["RuntimeMaxFileSize"])
                print "RuntimeMaxFileSize=" runtime_max_file_size
            if (!seen["RuntimeMaxFiles"])
                print "RuntimeMaxFiles=" runtime_max_files
            if (!seen["MaxRetentionSec"])
                print "MaxRetentionSec=" max_retention
        }

        /^[[:space:]]*\[/ {
            section = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)

            if (section == "[Journal]") {
                in_journal = 1
                found_journal = 1
            } else {
                if (in_journal)
                    add_defaults()

                in_journal = 0
            }

            print
            next
        }

        in_journal &&
        /^[[:space:]]*(Compress|SystemMaxUse|SystemMaxFileSize|SystemMaxFiles|RuntimeMaxUse|RuntimeMaxFileSize|RuntimeMaxFiles|MaxRetentionSec)[[:space:]]*=/ {
            key = $0
            sub(/^[[:space:]]*/, "", key)
            sub(/[[:space:]]*=.*$/, "", key)

            if (key == "Compress")
                print "Compress=" compress
            else if (key == "SystemMaxUse")
                print "SystemMaxUse=" system_max_use
            else if (key == "SystemMaxFileSize")
                print "SystemMaxFileSize=" system_max_file_size
            else if (key == "SystemMaxFiles")
                print "SystemMaxFiles=" system_max_files
            else if (key == "RuntimeMaxUse")
                print "RuntimeMaxUse=" runtime_max_use
            else if (key == "RuntimeMaxFileSize")
                print "RuntimeMaxFileSize=" runtime_max_file_size
            else if (key == "RuntimeMaxFiles")
                print "RuntimeMaxFiles=" runtime_max_files
            else if (key == "MaxRetentionSec")
                print "MaxRetentionSec=" max_retention

            seen[key] = 1
            next
        }

        {
            print
        }

        END {
            if (in_journal)
                add_defaults()
            else if (!found_journal) {
                print ""
                print "[Journal]"
                add_defaults()
            }
        }
    ' "$JOURNAL_CONF" >"$tmp" || {
        rm -f -- "$tmp"
        die "生成 journald 配置失败。"
    }

    replace_file "$tmp" "$JOURNAL_CONF"
}


journal_value() {
    systemd-analyze cat-config systemd/journald.conf |
        awk -F= -v key="$1" '
            /^[[:space:]]*[#;]/ {
                next
            }

            /^[[:space:]]*\[/ {
                section = $0
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
                in_journal = (section == "[Journal]")
                next
            }

            in_journal && $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
                value = $0
                sub(/^[^=]*=/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                result = value
            }

            END {
                if (result != "")
                    print result
                else
                    exit 1
            }
        '
}


validate_journald() {
    local key expected actual

    while read -r key expected; do
        actual="$(journal_value "$key")" ||
            die "无法读取 journald 最终配置：$key"

        [[ "$actual" == "$expected" ]] ||
            die "journald 配置错误：$key=$actual，期望 $expected"
    done <<<"$JOURNAL_EXPECTED"

    log "journald 配置验证通过。"
}


configure_rsyslog() {
    local tmp

    [[ -f "$RSYSLOG_ROTATE" ]] || {
        log "未发现 $RSYSLOG_ROTATE，跳过 rsyslog。"
        return
    }

    tmp="$(mktemp "${RSYSLOG_ROTATE}.tmp.XXXXXX")" ||
        die "无法创建 rsyslog 临时文件。"

    awk \
        -v maxsize="$LOGROTATE_MAX_SIZE" \
        -v rotate="$LOGROTATE_ROTATE" '
        BEGIN {
            in_block = 0
            found = 0
            inserted = 0
        }

        /^[[:space:]]*\/var\/log\/syslog([[:space:]]|$)/ {
            found = 1
            in_block = 1

            if (match($0, /\{[[:space:]]*$/)) {
                before = substr($0, 1, RSTART - 1)
                gsub(/[[:space:]]+$/, "", before)

                print before
                print "{"
                print "        maxsize " maxsize
                print "        rotate " rotate
                print "        compress"

                inserted = 1
                next
            }

            print
            next
        }

        in_block && /^[[:space:]]*\{[[:space:]]*$/ {
            print
            print "        maxsize " maxsize
            print "        rotate " rotate
            print "        compress"

            inserted = 1
            next
        }

        in_block &&
        /^[[:space:]]*(size|maxsize|maxage|rotate|compress|nocompress)([[:space:]]|$)/ {
            next
        }

        in_block && /^[[:space:]]*\}[[:space:]]*$/ {
            in_block = 0
            print
            next
        }

        {
            print
        }

        END {
            if (!found || !inserted)
                exit 1
        }
    ' "$RSYSLOG_ROTATE" >"$tmp" || {
        rm -f -- "$tmp"
        die "无法安全修改 $RSYSLOG_ROTATE。"
    }

    replace_file "$tmp" "$RSYSLOG_ROTATE"
    log "rsyslog logrotate 配置修改完成。"
}


validate_rsyslog() {
    [[ -f "$RSYSLOG_ROTATE" ]] || return 0

    awk \
        -v maxsize="$LOGROTATE_MAX_SIZE" \
        -v rotate="$LOGROTATE_ROTATE" '
        BEGIN {
            in_block = 0
            found = 0
            ok_size = 0
            ok_rotate = 0
            ok_compress = 0
        }

        /^[[:space:]]*\/var\/log\/syslog([[:space:]]|$)/ {
            found = 1
            in_block = 1
            next
        }

        in_block && /^[[:space:]]*\{[[:space:]]*$/ {
            next
        }

        in_block && /^[[:space:]]*maxsize[[:space:]]+/ {
            ok_size = ($0 ~ "^[[:space:]]*maxsize[[:space:]]+" maxsize "[[:space:]]*$")
        }

        in_block && /^[[:space:]]*rotate[[:space:]]+/ {
            ok_rotate = ($0 ~ "^[[:space:]]*rotate[[:space:]]+" rotate "[[:space:]]*$")
        }

        in_block && /^[[:space:]]*compress[[:space:]]*$/ {
            ok_compress = 1
        }

        in_block && /^[[:space:]]*\}[[:space:]]*$/ {
            exit
        }

        END {
            exit !(found && ok_size && ok_rotate && ok_compress)
        }
    ' "$RSYSLOG_ROTATE" ||
        die "rsyslog logrotate 配置验证失败。"

    log "rsyslog logrotate 配置验证通过。"
}


validate_logrotate() {
    command -v logrotate >/dev/null 2>&1 || return 0

    logrotate -d "$LOGROTATE_CONF" >/dev/null 2>&1 ||
        die "logrotate 配置验证失败。"

    log "logrotate 配置验证通过。"
}


restart_journald() {
    log "重新启动 systemd-journald..."

    systemctl restart systemd-journald.service ||
        die "systemd-journald 重启命令执行失败。"

    systemctl is-active --quiet systemd-journald.service ||
        die "systemd-journald 重启失败。"
}


vacuum_journals() {
    journalctl --rotate >/dev/null ||
        die "journal rotate 失败。"

    journalctl \
        --vacuum-size="$SYSTEM_MAX_USE" \
        --vacuum-time="$MAX_RETENTION" \
        >/dev/null ||
        die "journal vacuum 失败。"

    log "journal rotate/vacuum 完成。"
}


show_status() {
    log "最终 journald 配置："

    local key expected
    while read -r key expected; do
        printf '    %s=%s\n' "$key" "$(journal_value "$key")"
    done <<<"$JOURNAL_EXPECTED"

    log "journal 占用："
    journalctl --disk-usage 2>/dev/null || true

    log "/var/log 占用："
    du -sh /var/log 2>/dev/null || true

    log "根文件系统："
    df -h / 2>/dev/null || true
}


main() {
    require_system

    log "开始 Debian 13 日志优化（无备份模式）。"

    configure_journald
    validate_journald

    if command -v logrotate >/dev/null 2>&1; then
        configure_rsyslog
        validate_rsyslog
        validate_logrotate
    else
        log "未安装 logrotate，跳过 rsyslog/logrotate。"
    fi

    restart_journald

    vacuum_journals
    show_status

    log "日志优化完成。"
}

main "$@"

