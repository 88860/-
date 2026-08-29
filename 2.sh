#!/bin/bash
#
# Debian 13 (trixie) journald 精准日志空间优化
#
# ============================================================
# 核心原则
# ============================================================
#
# 1. 只允许修改已经存在的：
#       /etc/systemd/journald.conf
#
# 2. 严禁创建：
#       /etc/systemd/journald.conf.d/
#       /etc/systemd/journald.conf.d/*.conf
#
# 3. 不创建：
#       /etc/systemd/journald.conf.bak
#       /etc/systemd/journald.conf.tmp
#
# 4. 临时审计/候选文件只放在 /run
#
# 5. 修改前完整检查 journald 配置链：
#       /etc/systemd/journald.conf
#       /run/systemd/journald.conf
#       /usr/local/lib/systemd/journald.conf
#       /usr/lib/systemd/journald.conf
#
#       以及：
#       /etc/systemd/journald.conf.d/*.conf
#       /run/systemd/journald.conf.d/*.conf
#       /usr/local/lib/systemd/journald.conf.d/*.conf
#       /usr/lib/systemd/journald.conf.d/*.conf
#
# 6. 如果任何 drop-in 正在覆盖本脚本管理的参数：
#       默认停止
#       不擅自修改其他配置文件
#
# 7. 不修改：
#       rsyslog.conf
#       /etc/rsyslog.d/*
#       nginx.conf
#       /etc/nginx/*
#       /etc/logrotate.conf
#       /etc/logrotate.d/*
#
# 8. 不删除：
#       /var/log/syslog
#       /var/log/auth.log
#       /var/log/kern.log
#       /var/log/*.gz
#       /var/log/*.log.*
#       /var/log/nginx/*
#       /var/backups/*
#       /etc/*.bak
#       /etc/*~
#
# 9. journald 仅使用官方支持的：
#       SystemMaxUse
#       RuntimeMaxUse
#       SystemKeepFree
#       RuntimeKeepFree
#       SystemMaxFileSize
#       RuntimeMaxFileSize
#       SystemMaxFiles
#       RuntimeMaxFiles
#
# 10. vacuum 只针对 journal：
#       --rotate
#       --vacuum-size
#       --vacuum-files
#
# 11. 不使用 --vacuum-time
#     避免脚本偷偷引入“日志最多保存 N 天”的策略。
#
# 12. 不修改 ForwardToSyslog
#
# 13. 不 restart rsyslog / nginx
#
# 14. 修改后必须检查：
#       systemd-analyze cat-config
#       journald effective configuration
#       journald service state
#       journalctl --disk-usage
#       logrotate -d
#
# ============================================================
# Debian 13 / systemd 257
# ============================================================

set -u
set -o pipefail

# ============================================================
# Root
# ============================================================

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: 请使用 root 权限运行。"
    exit 1
fi

# ============================================================
# Colors
# ============================================================

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# 可调参数
#
# 这些参数只会写入已经存在的：
# /etc/systemd/journald.conf
# ============================================================

JOURNAL_SYSTEM_MAX_USE="10M"
JOURNAL_RUNTIME_MAX_USE="10M"

JOURNAL_SYSTEM_KEEP_FREE="100M"
JOURNAL_RUNTIME_KEEP_FREE="100M"

JOURNAL_SYSTEM_MAX_FILE_SIZE="2M"
JOURNAL_RUNTIME_MAX_FILE_SIZE="2M"

JOURNAL_SYSTEM_MAX_FILES="6"
JOURNAL_RUNTIME_MAX_FILES="6"

JC="/etc/systemd/journald.conf"

# ============================================================
# 临时文件
#
# 只允许在 /run 创建。
# 不在 /etc 创建 .tmp/.bak。
# ============================================================

TMP_DIR=""
TMP_CANDIDATE=""
TMP_EFFECTIVE_BEFORE=""
TMP_EFFECTIVE_AFTER=""
TMP_JOURNAL_RESULT=""
TMP_LOGROTATE_RESULT=""

cleanup() {
    [ -n "${TMP_CANDIDATE:-}" ] &&
        [ -f "$TMP_CANDIDATE" ] &&
        rm -f -- "$TMP_CANDIDATE"

    [ -n "${TMP_EFFECTIVE_BEFORE:-}" ] &&
        [ -f "$TMP_EFFECTIVE_BEFORE" ] &&
        rm -f -- "$TMP_EFFECTIVE_BEFORE"

    [ -n "${TMP_EFFECTIVE_AFTER:-}" ] &&
        [ -f "$TMP_EFFECTIVE_AFTER" ] &&
        rm -f -- "$TMP_EFFECTIVE_AFTER"

    [ -n "${TMP_JOURNAL_RESULT:-}" ] &&
        [ -f "$TMP_JOURNAL_RESULT" ] &&
        rm -f -- "$TMP_JOURNAL_RESULT"

    [ -n "${TMP_LOGROTATE_RESULT:-}" ] &&
        [ -f "$TMP_LOGROTATE_RESULT" ] &&
        rm -f -- "$TMP_LOGROTATE_RESULT"

    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rmdir -- "$TMP_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM HUP

# ============================================================
# 工具检查
# ============================================================

require_cmd() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}ERROR: 找不到命令：$cmd${NC}"
        exit 1
    fi
}

require_cmd systemctl
require_cmd journalctl
require_cmd systemd-analyze
require_cmd awk
require_cmd grep
require_cmd sed
require_cmd stat
require_cmd mktemp
require_cmd cp
require_cmd cmp

# ============================================================
# 标题
# ============================================================

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Debian 13 journald 精准日志空间优化${NC}"
echo -e "${CYAN} 只修改现有 /etc/systemd/journald.conf${NC}"
echo -e "${CYAN} 不创建 drop-in / 不创建 .bak / 不碰 rsyslog/nginx${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ============================================================
# STEP 0
# Debian 13 检查
# ============================================================

echo -e "${BLUE}[STEP 0] 检查 Debian 13 环境${NC}"

if [ ! -r /etc/os-release ]; then
    echo -e "${RED}ERROR: /etc/os-release 不存在。${NC}"
    exit 1
fi

. /etc/os-release

echo "  OS       : ${PRETTY_NAME:-unknown}"
echo "  ID       : ${ID:-unknown}"
echo "  VERSION  : ${VERSION_ID:-unknown}"

if [ "${ID:-}" != "debian" ]; then
    echo -e "${RED}ERROR: 当前不是 Debian。${NC}"
    exit 1
fi

if [ "${VERSION_ID:-}" != "13" ]; then
    echo -e "${RED}ERROR: 当前不是 Debian 13。${NC}"
    exit 1
fi

if [ ! -f "$JC" ]; then
    echo -e "${RED}ERROR: $JC 不存在。${NC}"
    echo "按照要求，本脚本绝不创建该文件。"
    exit 1
fi

echo -e "${GREEN}✓ Debian 13${NC}"
echo -e "${GREEN}✓ $JC 已存在${NC}"
echo ""

# ============================================================
# STEP 1
# systemd / journald 基础状态
# ============================================================

echo -e "${BLUE}[STEP 1] 检查 systemd / journald${NC}"

echo "  systemd:"
systemd --version | head -1

echo ""

if ! systemctl cat systemd-journald.service >/dev/null 2>&1; then
    echo -e "${RED}ERROR: systemd-journald.service 不可用。${NC}"
    exit 1
fi

if systemctl is-active --quiet systemd-journald.service; then
    echo -e "${GREEN}✓ systemd-journald 正在运行${NC}"
else
    echo -e "${YELLOW}⚠ systemd-journald 当前不是 active${NC}"
fi

echo ""

# ============================================================
# STEP 2
# 检查 journald 主配置文件来源
#
# 官方规则：
# /etc
# /run
# /usr/local/lib
# /usr/lib
#
# 只有优先级最高的第一个主配置文件会被使用。
# ============================================================

echo -e "${BLUE}[STEP 2] 检查 journald 主配置文件来源${NC}"

MAIN_CANDIDATES=(
    "/etc/systemd/journald.conf"
    "/run/systemd/journald.conf"
    "/usr/local/lib/systemd/journald.conf"
    "/usr/lib/systemd/journald.conf"
)

MAIN_SELECTED=""

for f in "${MAIN_CANDIDATES[@]}"; do
    if [ -e "$f" ]; then
        echo "  存在：$f"

        if [ -z "$MAIN_SELECTED" ]; then
            MAIN_SELECTED="$f"
        fi
    fi
done

echo ""

if [ "$MAIN_SELECTED" != "$JC" ]; then
    echo -e "${RED}ERROR: journald 当前实际优先级最高的主配置不是：${JC}${NC}"
    echo "  实际最高优先级文件：${MAIN_SELECTED:-none}"
    echo ""
    echo "为避免修改一个不会生效的文件，脚本停止。"
    exit 1
fi

echo -e "${GREEN}✓ /etc/systemd/journald.conf 是主配置文件${NC}"
echo ""

# ============================================================
# STEP 3
# 建立 /run 临时目录
# ============================================================

echo -e "${BLUE}[STEP 3] 建立临时审计环境${NC}"

TMP_DIR="$(mktemp -d /run/journald-audit.XXXXXX)" || {
    echo -e "${RED}ERROR: 无法创建 /run 临时目录。${NC}"
    exit 1
}

chmod 0700 "$TMP_DIR"

TMP_CANDIDATE="$TMP_DIR/journald.conf.candidate"
TMP_EFFECTIVE_BEFORE="$TMP_DIR/effective-before.txt"
TMP_EFFECTIVE_AFTER="$TMP_DIR/effective-after.txt"
TMP_JOURNAL_RESULT="$TMP_DIR/journal-result.txt"
TMP_LOGROTATE_RESULT="$TMP_DIR/logrotate-result.txt"

echo -e "${GREEN}✓ 临时文件仅位于：$TMP_DIR${NC}"
echo ""

# ============================================================
# STEP 4
# 扫描所有 journald drop-in
#
# 非常重要：
#
# 官方规则：
# *.conf.d 中的配置优先于主配置。
#
# 本脚本不允许创建 drop-in。
#
# 如果现有 drop-in 修改了我们管理的参数，
# 则不能通过修改 /etc/systemd/journald.conf
# 保证最终 effective value。
#
# 因此：
# 发现冲突 → STOP
#
# 不自动修改 drop-in。
# ============================================================

echo -e "${BLUE}[STEP 4] 审计 journald.conf.d 配置链${NC}"

DROPIN_DIRS=(
    "/etc/systemd/journald.conf.d"
    "/run/systemd/journald.conf.d"
    "/usr/local/lib/systemd/journald.conf.d"
    "/usr/lib/systemd/journald.conf.d"
)

TARGET_KEYS=(
    "SystemMaxUse"
    "RuntimeMaxUse"
    "SystemKeepFree"
    "RuntimeKeepFree"
    "SystemMaxFileSize"
    "RuntimeMaxFileSize"
    "SystemMaxFiles"
    "RuntimeMaxFiles"
)

CONFLICT_FOUND=0

for dir in "${DROPIN_DIRS[@]}"; do

    if [ ! -d "$dir" ]; then
        continue
    fi

    echo "  检查：$dir"

    found_any=0

    while IFS= read -r -d '' conf; do

        found_any=1

        echo "    drop-in：$conf"

        while IFS= read -r line; do

            # 去除前导空格
            clean="${line#"${line%%[![:space:]]*}"}"

            # 忽略空行
            [ -z "$clean" ] && continue

            # 忽略注释
            case "$clean" in
                \#*|\;*)
                    continue
                    ;;
            esac

            for key in "${TARGET_KEYS[@]}"; do

                if printf '%s\n' "$clean" |
                    grep -Eq "^${key}[[:space:]]*="; then

                    echo -e "      ${RED}冲突：${key}${NC}"
                    echo "      $clean"

                    CONFLICT_FOUND=1
                fi

            done

        done < "$conf"

    done < <(
        find "$dir" \
            -maxdepth 1 \
            -type f \
            -name '*.conf' \
            -print0 2>/dev/null |
        sort -z
    )

    if [ "$found_any" -eq 0 ]; then
        echo "    无 *.conf drop-in"
    fi

done

echo ""

if [ "$CONFLICT_FOUND" -ne 0 ]; then

    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}检测到 journald drop-in 覆盖目标参数${NC}"
    echo -e "${RED}============================================================${NC}"
    echo ""
    echo "本脚本不会："
    echo "  - 删除 drop-in"
    echo "  - 修改 drop-in"
    echo "  - 创建新的 drop-in"
    echo ""
    echo "原因："
    echo "  /etc/systemd/journald.conf 的值可能不会成为最终 effective value。"
    echo ""
    echo "为了遵守“只精准修改指定现有配置文件”的要求，脚本停止。"
    exit 1
fi

echo -e "${GREEN}✓ 没有发现覆盖目标参数的 journald drop-in${NC}"
echo ""

# ============================================================
# STEP 5
# 检查 journald namespace 配置
#
# 本脚本只处理默认 namespace：
# /etc/systemd/journald.conf
#
# 不修改：
# /etc/systemd/journald@*.conf
#
# 因为它们属于其他 journal namespace。
# ============================================================

echo -e "${BLUE}[STEP 5] 检查 journal namespace 配置${NC}"

NAMESPACE_CONFIGS=(
    "/etc/systemd/journald@*.conf"
    "/etc/systemd/journald@*.conf.d"
)

namespace_found=0

for pattern in "${NAMESPACE_CONFIGS[@]}"; do
    for item in $pattern; do
        if [ -e "$item" ]; then
            echo "  发现 namespace 配置：$item"
            namespace_found=1
        fi
    done
done

if [ "$namespace_found" -eq 0 ]; then
    echo "  未发现额外 namespace 配置"
else
    echo -e "${YELLOW}  注意：这些配置属于其他 journal namespace，本脚本不修改。${NC}"
fi

echo ""

# ============================================================
# STEP 6
# 当前 effective config
# ============================================================

echo -e "${BLUE}[STEP 6] 获取当前 effective journald 配置${NC}"

if ! systemd-analyze cat-config systemd/journald.conf \
    > "$TMP_EFFECTIVE_BEFORE" 2>&1; then

    echo -e "${RED}ERROR: 无法读取 journald effective configuration。${NC}"
    cat "$TMP_EFFECTIVE_BEFORE"
    exit 1
fi

echo "  当前相关 effective 参数："

grep -E \
    '^[[:space:]]*(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|RuntimeKeepFree|SystemMaxFileSize|RuntimeMaxFileSize|SystemMaxFiles|RuntimeMaxFiles)[[:space:]]*=' \
    "$TMP_EFFECTIVE_BEFORE" \
    || echo "  当前未显式设置上述参数，将使用 systemd 默认值。"

echo ""

# ============================================================
# STEP 7
# 检查 ForwardToSyslog
#
# 本脚本绝不修改它。
# 这里只记录当前 effective 配置。
# ============================================================

echo -e "${BLUE}[STEP 7] 检查 ForwardToSyslog${NC}"

CURRENT_FORWARD_TO_SYSLOG="$(
    grep -E \
        '^[[:space:]]*ForwardToSyslog[[:space:]]*=' \
        "$TMP_EFFECTIVE_BEFORE" |
    tail -1 |
    sed -E 's/^[[:space:]]*//'
)"

if [ -n "$CURRENT_FORWARD_TO_SYSLOG" ]; then
    echo "  当前 effective：$CURRENT_FORWARD_TO_SYSLOG"
else
    echo "  当前没有显式 ForwardToSyslog 配置。"
    echo "  本脚本不会新增或修改它。"
fi

echo ""

# ============================================================
# STEP 8
# 检查 Storage / journal 实际存储
# ============================================================

echo -e "${BLUE}[STEP 8] 检查 journal 存储位置${NC}"

if [ -d /var/log/journal ]; then
    echo -e "${GREEN}  /var/log/journal 存在${NC}"
    echo "  → persistent System* 限制会适用。"
else
    echo -e "${YELLOW}  /var/log/journal 不存在${NC}"
    echo "  → 当前可能主要使用 Runtime* 限制。"
    echo "  → 本脚本不会创建 /var/log/journal。"
fi

if [ -d /run/log/journal ]; then
    echo -e "${GREEN}  /run/log/journal 存在${NC}"
else
    echo "  /run/log/journal 当前不存在。"
    echo "  journald 会按其 Storage / 当前运行状态管理。"
fi

echo ""

echo "  journalctl --disk-usage："
journalctl --disk-usage 2>/dev/null || true

echo ""

# ============================================================
# STEP 9
# 显示原始 journald.conf 中相关内容
# ============================================================

echo -e "${BLUE}[STEP 9] 审计现有 /etc/systemd/journald.conf${NC}"

echo ""
echo "  当前 [Journal] 中相关参数："

awk '
BEGIN {
    in_journal=0
}

/^[[:space:]]*\[Journal\][[:space:]]*$/ {
    in_journal=1
    next
}

/^[[:space:]]*\[/ {
    in_journal=0
}

in_journal &&
/^[[:space:]]*#?[[:space:]]*(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|RuntimeKeepFree|SystemMaxFileSize|RuntimeMaxFileSize|SystemMaxFiles|RuntimeMaxFiles)[[:space:]]*=/ {
    print
}
' "$JC"

echo ""

# ============================================================
# STEP 10
# 生成候选配置
#
# 规则：
#
# - 只修改 [Journal] section
# - 只处理 8 个目标 key
# - 不删除其他配置
# - 不修改 ForwardToSyslog
# - 不修改 Storage
# - 不修改 Compress
# - 不修改 Seal
# - 不修改其他 journald 参数
#
# 如果 [Journal] 中已经有活动配置：
#     修改其值
#
# 如果只有官方注释：
#     保留注释，并在 [Journal] 中加入活动配置
#
# 如果 [Journal] 不存在：
#     在现有文件末尾加入 [Journal]
#
# 注意：
# 候选文件只存在于 /run。
# ============================================================

echo -e "${BLUE}[STEP 10] 生成候选 journald.conf${NC}"

awk \
    -v smu="$JOURNAL_SYSTEM_MAX_USE" \
    -v rmu="$JOURNAL_RUNTIME_MAX_USE" \
    -v skf="$JOURNAL_SYSTEM_KEEP_FREE" \
    -v rkf="$JOURNAL_RUNTIME_KEEP_FREE" \
    -v smfs="$JOURNAL_SYSTEM_MAX_FILE_SIZE" \
    -v rmfs="$JOURNAL_RUNTIME_MAX_FILE_SIZE" \
    -v smf="$JOURNAL_SYSTEM_MAX_FILES" \
    -v rmf="$JOURNAL_RUNTIME_MAX_FILES" '

function emit(key, value) {
    print key "=" value
}

/^[[:space:]]*\[Journal\][[:space:]]*$/ {

    if (in_journal) {
        # 防止异常重复 [Journal] section
        if (!seen_smu)  emit("SystemMaxUse", smu)
        if (!seen_rmu)  emit("RuntimeMaxUse", rmu)
        if (!seen_skf)  emit("SystemKeepFree", skf)
        if (!seen_rkf)  emit("RuntimeKeepFree", rkf)
        if (!seen_smfs) emit("SystemMaxFileSize", smfs)
        if (!seen_rmfs) emit("RuntimeMaxFileSize", rmfs)
        if (!seen_smf)  emit("SystemMaxFiles", smf)
        if (!seen_rmf)  emit("RuntimeMaxFiles", rmf)
    }

    in_journal=1
    seen_section=1

    print
    next
}

/^[[:space:]]*\[/ {

    if (in_journal) {

        if (!seen_smu)  emit("SystemMaxUse", smu)
        if (!seen_rmu)  emit("RuntimeMaxUse", rmu)
        if (!seen_skf)  emit("SystemKeepFree", skf)
        if (!seen_rkf)  emit("RuntimeKeepFree", rkf)
        if (!seen_smfs) emit("SystemMaxFileSize", smfs)
        if (!seen_rmfs) emit("RuntimeMaxFileSize", rmfs)
        if (!seen_smf)  emit("SystemMaxFiles", smf)
        if (!seen_rmf)  emit("RuntimeMaxFiles", rmf)

    }

    in_journal=0

    print
    next
}

{
    if (in_journal) {

        if ($0 ~ /^[[:space:]]*SystemMaxUse[[:space:]]*=/) {
            if (!seen_smu) {
                emit("SystemMaxUse", smu)
                seen_smu=1
            }
            next
        }

        if ($0 ~ /^[[:space:]]*RuntimeMaxUse[[:space:]]*=/) {
            if (!seen_rmu) {
                emit("RuntimeMaxUse", rmu)
                seen_rmu=1
            }
            next
        }

        if ($0 ~ /^[[:space:]]*SystemKeepFree[[:space:]]*=/) {
            if (!seen_skf) {
                emit("SystemKeepFree", skf)
                seen_skf=1
            }
            next
        }

        if ($0 ~ /^[[:space:]]*RuntimeKeepFree[[:space:]]*=/) {
            if (!seen_rkf) {
                emit("RuntimeKeepFree", rkf)
                seen_rkf=1
            }
            next
        }

        if ($0 ~ /^[[:space:]]*SystemMaxFileSize[[:space:]]*=/) {
            if (!seen_smfs) {
                emit("SystemMaxFileSize", smfs)
                seen_smfs=1
            }
            next
        }

        if ($0 ~ /^[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/) {
            if (!seen_rmfs) {
                emit("RuntimeMaxFileSize", rmfs)
                seen_rmfs=1
            }
            next
        }

        if ($0 ~ /^[[:space:]]*SystemMaxFiles[[:space:]]*=/) {
            if (!seen_smf) {
                emit("SystemMaxFiles", smf)
                seen_smf=1
            }
            next
        }

        if ($0 ~ /^[[:space:]]*RuntimeMaxFiles[[:space:]]*=/) {
            if (!seen_rmf) {
                emit("RuntimeMaxFiles", rmf)
                seen_rmf=1
            }
            next
        }
    }

    print
}

END {

    if (in_journal) {

        if (!seen_smu)  emit("SystemMaxUse", smu)
        if (!seen_rmu)  emit("RuntimeMaxUse", rmu)
        if (!seen_skf)  emit("SystemKeepFree", skf)
        if (!seen_rkf)  emit("RuntimeKeepFree", rkf)
        if (!seen_smfs) emit("SystemMaxFileSize", smfs)
        if (!seen_rmfs) emit("RuntimeMaxFileSize", rmfs)
        if (!seen_smf)  emit("SystemMaxFiles", smf)
        if (!seen_rmf)  emit("RuntimeMaxFiles", rmf)

    }

    if (!seen_section) {

        print ""

        print "[Journal]"

        emit("SystemMaxUse", smu)
        emit("RuntimeMaxUse", rmu)

        emit("SystemKeepFree", skf)
        emit("RuntimeKeepFree", rkf)

        emit("SystemMaxFileSize", smfs)
        emit("RuntimeMaxFileSize", rmfs)

        emit("SystemMaxFiles", smf)
        emit("RuntimeMaxFiles", rmf)
    }
}
' "$JC" > "$TMP_CANDIDATE"

if [ $? -ne 0 ] || [ ! -s "$TMP_CANDIDATE" ]; then
    echo -e "${RED}ERROR: 候选配置生成失败。${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 候选配置生成成功${NC}"
echo ""

# ============================================================
# STEP 11
# 候选文件静态检查
# ============================================================

echo -e "${BLUE}[STEP 11] 静态检查候选配置${NC}"

if ! grep -qE '^[[:space:]]*\[Journal\][[:space:]]*$' "$TMP_CANDIDATE"; then
    echo -e "${RED}ERROR: 候选文件没有 [Journal] section。${NC}"
    exit 1
fi

for key in "${TARGET_KEYS[@]}"; do

    count="$(
        grep -Ec "^${key}=" "$TMP_CANDIDATE"
    )"

    if [ "$count" -ne 1 ]; then
        echo -e "${RED}ERROR: $key 在候选文件中不是唯一配置。${NC}"
        echo "  count=$count"
        exit 1
    fi

done

echo "  候选值："

grep -E \
    '^(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|RuntimeKeepFree|SystemMaxFileSize|RuntimeMaxFileSize|SystemMaxFiles|RuntimeMaxFiles)=' \
    "$TMP_CANDIDATE"

echo ""

# ============================================================
# STEP 12
# 确认候选配置只修改目标参数
#
# 使用 diff：
#
# 如果出现其他配置变化 → STOP
#
# ============================================================

echo -e "${BLUE}[STEP 12] 检查修改范围${NC}"

DIFF_OUTPUT="$TMP_DIR/diff.txt"

if diff -u "$JC" "$TMP_CANDIDATE" > "$DIFF_OUTPUT"; then

    echo -e "${GREEN}✓ 文件内容无需修改${NC}"

else

    echo "  预计修改："
    cat "$DIFF_OUTPUT"

    echo ""

    # 检查 diff 中是否出现目标以外的实际配置变化。
    #
    # 删除/增加的非注释配置行必须属于目标 key。
    BAD_DIFF=0

    while IFS= read -r line; do

        case "$line" in
            +++*|---*)
                continue
                ;;
            +*|-*)
                content="${line:1}"

                case "$content" in
                    \#*|"")
                        continue
                        ;;
                esac

                if ! printf '%s\n' "$content" |
                    grep -Eq \
                    '^[[:space:]]*(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|RuntimeKeepFree|SystemMaxFileSize|RuntimeMaxFileSize|SystemMaxFiles|RuntimeMaxFiles)[[:space:]]*='; then

                    echo -e "${RED}ERROR: 检测到目标参数之外的实际配置变化：${NC}"
                    echo "  $line"

                    BAD_DIFF=1
                fi
                ;;
        esac

    done < "$DIFF_OUTPUT"

    if [ "$BAD_DIFF" -ne 0 ]; then
        echo ""
        echo -e "${RED}为保证“精准修改”，脚本停止。${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ diff 中只有目标 journald 参数发生变化${NC}"
fi

echo ""

# ============================================================
# STEP 13
# 检查候选配置的 effective configuration
#
# systemd-analyze cat-config 本身读取系统真实配置，
# 因此候选文件不能直接喂给它。
#
# 这里做两件事：
#
# 1. 候选语法结构检查
# 2. 修改后再做真正 effective validation
# ============================================================

echo -e "${BLUE}[STEP 13] 候选配置结构检查${NC}"

# systemd-analyze verify 对 journald.conf 并不是专用 parser，
# 因此这里只做基础文本结构验证。
#
# 真正验证以修改后的 systemd-analyze cat-config
# + journald restart 为准。

if grep -Eq '^[^#[:space:]].*=' "$TMP_CANDIDATE"; then
    echo -e "${GREEN}✓ 候选文件包含有效配置项${NC}"
else
    echo -e "${RED}ERROR: 候选文件没有有效配置项。${NC}"
    exit 1
fi

echo ""

# ============================================================
# STEP 14
# 保存现有内容到 /run
#
# 注意：
# 这不是 /etc 备份文件。
#
# 只用于：
#   如果直接写入过程中出现错误，
#   可以尽力恢复原内容。
#
# ============================================================

echo -e "${BLUE}[STEP 14] 保存当前内容到临时恢复区${NC}"

TMP_ORIGINAL="$TMP_DIR/journald.conf.original"

if ! cp -- "$JC" "$TMP_ORIGINAL"; then
    echo -e "${RED}ERROR: 无法读取当前配置用于恢复。${NC}"
    exit 1
fi

chmod 0600 "$TMP_ORIGINAL"

echo -e "${GREEN}✓ 原始内容仅临时保存于 /run${NC}"
echo ""

# ============================================================
# STEP 15
# 记录文件元数据
# ============================================================

echo -e "${BLUE}[STEP 15] 记录现有文件属性${NC}"

JC_UID="$(stat -c '%u' "$JC")"
JC_GID="$(stat -c '%g' "$JC")"
JC_MODE="$(stat -c '%a' "$JC")"

echo "  UID  : $JC_UID"
echo "  GID  : $JC_GID"
echo "  MODE : $JC_MODE"

echo ""

# ============================================================
# STEP 16
# 最终安全确认
# ============================================================

echo -e "${BLUE}[STEP 16] 最终安全确认${NC}"

echo ""
echo "本次允许修改："
echo "  $JC"
echo ""

echo "本次禁止修改："
echo "  /etc/systemd/journald.conf.d/*"
echo "  /run/systemd/journald.conf.d/*"
echo "  /usr/local/lib/systemd/journald.conf.d/*"
echo "  /usr/lib/systemd/journald.conf.d/*"
echo "  rsyslog"
echo "  nginx"
echo "  logrotate"
echo "  /var/log 普通日志"
echo ""

echo "目标值："

echo "  SystemMaxUse       = $JOURNAL_SYSTEM_MAX_USE"
echo "  RuntimeMaxUse      = $JOURNAL_RUNTIME_MAX_USE"

echo "  SystemKeepFree     = $JOURNAL_SYSTEM_KEEP_FREE"
echo "  RuntimeKeepFree    = $JOURNAL_RUNTIME_KEEP_FREE"

echo "  SystemMaxFileSize  = $JOURNAL_SYSTEM_MAX_FILE_SIZE"
echo "  RuntimeMaxFileSize = $JOURNAL_RUNTIME_MAX_FILE_SIZE"

echo "  SystemMaxFiles     = $JOURNAL_SYSTEM_MAX_FILES"
echo "  RuntimeMaxFiles    = $JOURNAL_RUNTIME_MAX_FILES"

echo ""

# ============================================================
# STEP 17
# 写入现有配置文件
#
# 非常重要：
#
# 不使用：
#   mv /run/... /etc/...
#
# 因为 /run 和 /etc 很可能不是同一个 filesystem。
#
# 这里直接写入已经存在的配置文件。
#
# 这是为了严格满足：
#   “只修改现有配置文件”
#
# 代价：
#   不能声称这是 rename() atomic replacement。
#
# 因此：
#   原文件已保存到 /run
#   写入后立即验证
#   验证失败则尝试恢复
#
# ============================================================

echo -e "${BLUE}[STEP 17] 精准修改现有 $JC${NC}"

if ! cp -- "$TMP_CANDIDATE" "$JC"; then

    echo -e "${RED}ERROR: 修改 $JC 失败。${NC}"

    if cp -- "$TMP_ORIGINAL" "$JC"; then
        echo -e "${YELLOW}已尝试恢复原配置。${NC}"
    else
        echo -e "${RED}CRITICAL: 原配置恢复失败！${NC}"
    fi

    exit 1
fi

# 恢复原 metadata
chown "$JC_UID:$JC_GID" "$JC"
chmod "$JC_MODE" "$JC"

echo -e "${GREEN}✓ 已修改现有配置文件${NC}"
echo ""

# ============================================================
# STEP 18
# 检查文件内容
# ============================================================

echo -e "${BLUE}[STEP 18] 检查修改后的文件${NC}"

if ! cmp -s "$JC" "$TMP_CANDIDATE"; then

    echo -e "${RED}ERROR: 写入后的文件与候选文件不一致。${NC}"

    echo "尝试恢复原配置："

    if cp -- "$TMP_ORIGINAL" "$JC"; then
        chown "$JC_UID:$JC_GID" "$JC"
        chmod "$JC_MODE" "$JC"
        echo -e "${YELLOW}✓ 原配置已恢复${NC}"
    else
        echo -e "${RED}CRITICAL: 恢复失败！${NC}"
    fi

    exit 1
fi

echo -e "${GREEN}✓ 文件内容验证一致${NC}"
echo ""

# ============================================================
# STEP 19
# 重新加载 journald
# ============================================================

echo -e "${BLUE}[STEP 19] 重新加载 systemd-journald${NC}"

if ! systemctl try-restart systemd-journald.service; then

    echo -e "${RED}ERROR: systemd-journald 重启失败。${NC}"

    echo ""
    echo "当前状态："
    systemctl --no-pager --full status systemd-journald.service || true

    echo ""
    echo "尝试恢复原 journald.conf："

    if cp -- "$TMP_ORIGINAL" "$JC"; then

        chown "$JC_UID:$JC_GID" "$JC"
        chmod "$JC_MODE" "$JC"

        if systemctl try-restart systemd-journald.service; then
            echo -e "${YELLOW}✓ 已恢复原配置并重新启动 journald${NC}"
        else
            echo -e "${RED}CRITICAL: 原配置已写回，但 journald 重新启动仍失败！${NC}"
        fi

    else
        echo -e "${RED}CRITICAL: 无法恢复原配置！${NC}"
    fi

    exit 1
fi

sleep 1

echo -e "${GREEN}✓ systemd-journald 已重新读取配置${NC}"
echo ""

# ============================================================
# STEP 20
# 检查 journald service
# ============================================================

echo -e "${BLUE}[STEP 20] 检查 journald service 状态${NC}"

if ! systemctl is-active --quiet systemd-journald.service; then

    echo -e "${RED}ERROR: journald 不是 active 状态。${NC}"

    systemctl --no-pager --full status systemd-journald.service || true

    echo ""
    echo "尝试恢复原配置。"

    if cp -- "$TMP_ORIGINAL" "$JC"; then

        chown "$JC_UID:$JC_GID" "$JC"
        chmod "$JC_MODE" "$JC"

        systemctl try-restart systemd-journald.service >/dev/null 2>&1 || true

    fi

    exit 1
fi

echo -e "${GREEN}✓ systemd-journald active${NC}"
echo ""

# ============================================================
# STEP 21
# 获取修改后的 effective configuration
# ============================================================

echo -e "${BLUE}[STEP 21] 验证最终 effective configuration${NC}"

if ! systemd-analyze cat-config systemd/journald.conf \
    > "$TMP_EFFECTIVE_AFTER" 2>&1; then

    echo -e "${RED}ERROR: 无法读取修改后的 effective configuration。${NC}"

    cat "$TMP_EFFECTIVE_AFTER"

    exit 1
fi

echo "  最终 effective 参数："

grep -E \
    '^[[:space:]]*(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|RuntimeKeepFree|SystemMaxFileSize|RuntimeMaxFileSize|SystemMaxFiles|RuntimeMaxFiles)[[:space:]]*=' \
    "$TMP_EFFECTIVE_AFTER" \
    || true

echo ""

# ============================================================
# STEP 22
# 精确验证 effective values
# ============================================================

echo -e "${BLUE}[STEP 22] 精确验证 effective values${NC}"

EXPECTED_VALUES=(
    "SystemMaxUse=$JOURNAL_SYSTEM_MAX_USE"
    "RuntimeMaxUse=$JOURNAL_RUNTIME_MAX_USE"
    "SystemKeepFree=$JOURNAL_SYSTEM_KEEP_FREE"
    "RuntimeKeepFree=$JOURNAL_RUNTIME_KEEP_FREE"
    "SystemMaxFileSize=$JOURNAL_SYSTEM_MAX_FILE_SIZE"
    "RuntimeMaxFileSize=$JOURNAL_RUNTIME_MAX_FILE_SIZE"
    "SystemMaxFiles=$JOURNAL_SYSTEM_MAX_FILES"
    "RuntimeMaxFiles=$JOURNAL_RUNTIME_MAX_FILES"
)

VERIFY_FAILED=0

for expected in "${EXPECTED_VALUES[@]}"; do

    if grep -Fxq "$expected" "$TMP_EFFECTIVE_AFTER"; then
        echo -e "  ${GREEN}✓ $expected${NC}"
    else
        echo -e "  ${RED}✗ 未发现 effective：$expected${NC}"
        VERIFY_FAILED=1
    fi

done

echo ""

if [ "$VERIFY_FAILED" -ne 0 ]; then

    echo -e "${RED}ERROR: effective configuration 与目标不一致。${NC}"
    echo ""
    echo "原因可能包括："
    echo "  - systemd 配置链存在额外覆盖"
    echo "  - 其他运行时配置"
    echo "  - 配置解析异常"
    echo ""
    echo "本脚本不会继续修改其他配置文件。"

    exit 1
fi

echo -e "${GREEN}✓ effective configuration 完全符合目标${NC}"
echo ""

# ============================================================
# STEP 23
# 再次确认 ForwardToSyslog 没有被修改
# ============================================================

echo -e "${BLUE}[STEP 23] 验证 ForwardToSyslog 未被修改${NC}"

AFTER_FORWARD_TO_SYSLOG="$(
    grep -E \
        '^[[:space:]]*ForwardToSyslog[[:space:]]*=' \
        "$TMP_EFFECTIVE_AFTER" |
    tail -1 |
    sed -E 's/^[[:space:]]*//'
)"

if [ "$CURRENT_FORWARD_TO_SYSLOG" = "$AFTER_FORWARD_TO_SYSLOG" ]; then

    echo -e "${GREEN}✓ ForwardToSyslog effective 值未发生变化${NC}"

else

    if [ -z "$CURRENT_FORWARD_TO_SYSLOG" ] &&
       [ -z "$AFTER_FORWARD_TO_SYSLOG" ]; then

        echo -e "${GREEN}✓ ForwardToSyslog 均未显式设置${NC}"

    else

        echo -e "${RED}ERROR: ForwardToSyslog effective 状态发生变化。${NC}"
        echo "  before: ${CURRENT_FORWARD_TO_SYSLOG:-<unset>}"
        echo "  after : ${AFTER_FORWARD_TO_SYSLOG:-<unset>}"
        exit 1
    fi
fi

echo ""

# ============================================================
# STEP 24
# journald 当前空间
# ============================================================

echo -e "${BLUE}[STEP 24] 检查 journald 当前空间${NC}"

journalctl --disk-usage 2>/dev/null || true

echo ""

# ============================================================
# STEP 25
# 仅清理 archived journal
#
# 不使用 --vacuum-time
#
# 原因：
#   本脚本只负责空间限制，
#   不人为增加时间保留策略。
#
# --rotate：
#   先让当前 active journal 进入 archived 状态。
#
# --vacuum-size：
#   按空间回收 archived journal。
#
# --vacuum-files：
#   控制 archived journal 文件数量。
#
# 不触碰：
#   /var/log/syslog
#   /var/log/auth.log
#   nginx 日志
#   .gz
#   .log.*
# ============================================================

echo -e "${BLUE}[STEP 25] 按 journald 空间策略清理 archived journal${NC}"

if journalctl \
    --rotate \
    --vacuum-size="$JOURNAL_SYSTEM_MAX_USE" \
    --vacuum-files="$JOURNAL_SYSTEM_MAX_FILES" \
    > "$TMP_JOURNAL_RESULT" 2>&1; then

    cat "$TMP_JOURNAL_RESULT"

    echo ""
    echo -e "${GREEN}✓ journald archived journal 清理完成${NC}"

else

    cat "$TMP_JOURNAL_RESULT"

    echo ""
    echo -e "${YELLOW}⚠ journald vacuum 返回非零状态${NC}"
    echo "不会删除普通 /var/log 文件。"

fi

echo ""

# ============================================================
# STEP 26
# 检查 rsyslog
# ============================================================

echo -e "${BLUE}[STEP 26] 检查 rsyslog（不修改）${NC}"

if systemctl list-unit-files 2>/dev/null |
    grep -q '^rsyslog.service'; then

    if systemctl is-active --quiet rsyslog.service; then
        echo -e "${GREEN}✓ rsyslog active${NC}"
    else
        echo -e "${YELLOW}⚠ rsyslog 已安装但当前不是 active${NC}"
    fi

    if [ -f /etc/rsyslog.conf ]; then
        echo "  /etc/rsyslog.conf 存在"
    fi

    if [ -d /etc/rsyslog.d ]; then
        echo "  /etc/rsyslog.d 存在"
    fi

    if [ -f /etc/logrotate.d/rsyslog ]; then
        echo "  /etc/logrotate.d/rsyslog 存在"
    fi

else

    echo "  rsyslog service 未检测到"

fi

echo ""
echo "  本脚本没有修改任何 rsyslog 配置。"
echo ""

# ============================================================
# STEP 27
# 检查 nginx
# ============================================================

echo -e "${BLUE}[STEP 27] 检查 nginx（不修改）${NC}"

if command -v nginx >/dev/null 2>&1 ||
   [ -d /etc/nginx ]; then

    echo "  nginx 已检测到"

    if [ -f /etc/logrotate.d/nginx ]; then
        echo "  /etc/logrotate.d/nginx 存在"
    fi

    if [ -d /var/log/nginx ]; then
        echo "  nginx 日志占用："
        du -sh /var/log/nginx 2>/dev/null || true
    fi

else

    echo "  nginx 未检测到"

fi

echo ""
echo "  本脚本没有修改 nginx。"
echo ""

# ============================================================
# STEP 28
# logrotate debug
#
# -d：
#   不实际轮换
#   不删除日志
#   不强制执行
# ============================================================

echo -e "${BLUE}[STEP 28] 检查 logrotate${NC}"

if command -v logrotate >/dev/null 2>&1; then

    echo "  logrotate："
    logrotate --version | head -1

    if logrotate -d /etc/logrotate.conf \
        > "$TMP_LOGROTATE_RESULT" 2>&1; then

        echo -e "${GREEN}✓ logrotate debug 检查通过${NC}"

    else

        echo -e "${YELLOW}⚠ logrotate debug 返回非零${NC}"

    fi

    echo ""
    echo "  logrotate debug 输出摘要："

    sed -n '1,80p' "$TMP_LOGROTATE_RESULT"

else

    echo "  logrotate 未安装"

fi

echo ""

# ============================================================
# STEP 29
# 最终检查普通日志
#
# 只读取。
# 不删除。
# ============================================================

echo -e "${BLUE}[STEP 29] 检查普通日志（只读）${NC}"

for f in \
    /var/log/syslog \
    /var/log/auth.log \
    /var/log/kern.log \
    /var/log/daemon.log \
    /var/log/user.log \
    /var/log/dpkg.log \
    /var/log/nginx/access.log \
    /var/log/nginx/error.log
do

    if [ -f "$f" ]; then
        printf "  %-40s " "$f"
        du -h "$f" 2>/dev/null | awk '{print $1}'
    fi

done

echo ""

# ============================================================
# STEP 30
# 最终 journald effective config
# ============================================================

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} 最终 journald 配置${NC}"
echo -e "${CYAN}============================================================${NC}"

grep -E \
    '^[[:space:]]*(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|RuntimeKeepFree|SystemMaxFileSize|RuntimeMaxFileSize|SystemMaxFiles|RuntimeMaxFiles)[[:space:]]*=' \
    "$TMP_EFFECTIVE_AFTER" \
    || true

echo ""

# ============================================================
# STEP 31
# 最终空间
# ============================================================

echo "journald："
journalctl --disk-usage 2>/dev/null || true

echo ""

echo "/var/log："
du -sh /var/log 2>/dev/null || true

echo ""

# ============================================================
# STEP 32
# 完成
# ============================================================

echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN} journald 精准优化完成${NC}"
echo -e "${CYAN}============================================================${NC}"

echo ""
echo -e "${GREEN}✓ 只修改：$JC${NC}"
echo -e "${GREEN}✓ 未创建 journald.conf.d${NC}"
echo -e "${GREEN}✓ 未创建 /etc/systemd/journald.conf.bak${NC}"
echo -e "${GREEN}✓ 未创建 /etc/systemd/journald.conf.tmp${NC}"
echo -e "${GREEN}✓ 未修改 rsyslog${NC}"
echo -e "${GREEN}✓ 未修改 nginx${NC}"
echo -e "${GREEN}✓ 未修改 /etc/logrotate.conf${NC}"
echo -e "${GREEN}✓ 未强制执行 logrotate${NC}"
echo -e "${GREEN}✓ 未删除普通 /var/log 日志${NC}"
echo -e "${GREEN}✓ 未删除 .gz / .log.* 历史日志${NC}"
echo -e "${GREEN}✓ 未修改 ForwardToSyslog${NC}"
echo -e "${GREEN}✓ journald effective configuration 已验证${NC}"
echo ""
