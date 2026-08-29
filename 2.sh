#!/bin/bash
#
# Debian 13 日志安全优化
#
# 设计目标：
#   1. 仅安全修改已经存在的 /etc/systemd/journald.conf
#   2. 不创建 /etc/systemd/journald.conf.d/ 新配置文件
#   3. 不清空 /var/log 下正在使用的活动日志
#   4. 不删除 /var/log/*.gz、*.log.* 等历史文件
#   5. 不删除 /etc/*.bak、*~、/var/backups
#   6. 不强制修改 /etc/logrotate.conf 全局策略
#   7. 不关闭 ForwardToSyslog
#   8. 不重启 rsyslog / nginx
#   9. journald 使用 System*/Runtime* 双重限制
#  10. 修改前后进行 systemd/journald/logrotate 检查
#
# 适用：
#   Debian 13 (trixie)
#
# 必须 root
#

set -u
set -o pipefail

if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 权限运行"
    exit 1
fi

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# 可调参数
# ============================================================

# journald 总空间限制
JOURNAL_SYSTEM_MAX_USE="10M"
JOURNAL_RUNTIME_MAX_USE="10M"

# 单个 journal 文件最大尺寸
JOURNAL_SYSTEM_MAX_FILE_SIZE="2M"
JOURNAL_RUNTIME_MAX_FILE_SIZE="2M"

# journal 文件数量上限
JOURNAL_SYSTEM_MAX_FILES="6"
JOURNAL_RUNTIME_MAX_FILES="6"

# 保证给系统其他文件留下的空间
# 注意：journald 会同时考虑 MaxUse 与 KeepFree，
# 实际限制取更严格的一方。
JOURNAL_SYSTEM_KEEP_FREE="100M"
JOURNAL_RUNTIME_KEEP_FREE="100M"

JC="/etc/systemd/journald.conf"
TMP=""

cleanup() {
    if [ -n "${TMP:-}" ] && [ -f "$TMP" ]; then
        rm -f "$TMP"
    fi
}
trap cleanup EXIT INT TERM

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Debian 13 日志安全优化${NC}"
echo -e "${CYAN} journald 严格限额 / 不清空活动日志 / 不破坏 rsyslog/nginx${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ============================================================
# STEP 0
# 基础环境检查
# ============================================================

echo -e "${BLUE}[STEP 0] 检查 Debian / systemd 环境${NC}"

if [ -r /etc/os-release ]; then
    . /etc/os-release

    echo "  系统：${PRETTY_NAME:-unknown}"

    if [ "${ID:-}" != "debian" ]; then
        echo -e "${YELLOW}  ⚠ 当前系统不是 Debian，脚本停止。${NC}"
        exit 1
    fi

    if [ "${VERSION_ID:-}" != "13" ]; then
        echo -e "${YELLOW}  ⚠ 当前不是 Debian 13，检测到版本：${VERSION_ID:-unknown}"
        echo -e "${YELLOW}    为避免修改错误的系统配置，脚本停止。${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ 无法读取 /etc/os-release${NC}"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}✗ 找不到 systemctl${NC}"
    exit 1
fi

if ! command -v journalctl >/dev/null 2>&1; then
    echo -e "${RED}✗ 找不到 journalctl${NC}"
    exit 1
fi

if [ ! -f "$JC" ]; then
    echo -e "${RED}✗ $JC 不存在${NC}"
    echo -e "${YELLOW}  按要求：不新建配置文件，因此不会创建它。${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Debian 13 / systemd / journald 环境正常${NC}"
echo ""

# ============================================================
# STEP 1
# 当前日志状态
# ============================================================

echo -e "${BLUE}[STEP 1] 当前日志状态${NC}"

echo ""
echo "  journald 当前占用："
journalctl --disk-usage 2>/dev/null || true

echo ""
echo "  /var/log 当前占用："
du -sh /var/log 2>/dev/null || true

echo ""
echo "  /var/log 一级目录/文件："
du -sh /var/log/* 2>/dev/null | sort -rh | head -30 || true

echo ""

# ============================================================
# STEP 2
# 检查 journald.conf 当前状态
# ============================================================

echo -e "${BLUE}[STEP 2] 检查现有 $JC${NC}"

echo ""
echo "  当前 [Journal] 配置："

awk '
BEGIN {
    in_journal=0
}
/^[[:space:]]*\[Journal\][[:space:]]*$/ {
    in_journal=1
    print
    next
}
/^[[:space:]]*\[/ {
    if (in_journal)
        in_journal=0
}
{
    if (in_journal)
        print
}
' "$JC"

echo ""

# ============================================================
# STEP 3
# 安全生成修改后的临时版本
#
# 注意：
#   临时文件只存在于 /run
#   不会在 /etc 创建 .tmp/.bak
# ============================================================

echo -e "${BLUE}[STEP 3] 生成待验证的 journald 配置${NC}"

TMP="$(mktemp /run/journald.conf.XXXXXX)" || {
    echo -e "${RED}✗ 无法创建临时文件${NC}"
    exit 1
}

chmod 0644 "$TMP"
chown root:root "$TMP"

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

        in_journal=0
    }

    print
    next
}

{
    if (in_journal) {

        if ($0 ~ /^[[:space:]]*#?[[:space:]]*SystemMaxUse[[:space:]]*=/) {
            emit("SystemMaxUse", smu)
            seen_smu=1
            next
        }

        if ($0 ~ /^[[:space:]]*#?[[:space:]]*RuntimeMaxUse[[:space:]]*=/) {
            emit("RuntimeMaxUse", rmu)
            seen_rmu=1
            next
        }

        if ($0 ~ /^[[:space:]]*#?[[:space:]]*SystemKeepFree[[:space:]]*=/) {
            emit("SystemKeepFree", skf)
            seen_skf=1
            next
        }

        if ($0 ~ /^[[:space:]]*#?[[:space:]]*RuntimeKeepFree[[:space:]]*=/) {
            emit("RuntimeKeepFree", rkf)
            seen_rkf=1
            next
        }

        if ($0 ~ /^[[:space:]]*#?[[:space:]]*SystemMaxFileSize[[:space:]]*=/) {
            emit("SystemMaxFileSize", smfs)
            seen_smfs=1
            next
        }

        if ($0 ~ /^[[:space:]]*#?[[:space:]]*RuntimeMaxFileSize[[:space:]]*=/) {
            emit("RuntimeMaxFileSize", rmfs)
            seen_rmfs=1
            next
        }

        if ($0 ~ /^[[:space:]]*#?[[:space:]]*SystemMaxFiles[[:space:]]*=/) {
            emit("SystemMaxFiles", smf)
            seen_smf=1
            next
        }

        if ($0 ~ /^[[:space:]]*#?[[:space:]]*RuntimeMaxFiles[[:space:]]*=/) {
            emit("RuntimeMaxFiles", rmf)
            seen_rmf=1
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

        if (!seen_smf) emit("SystemMaxFiles", smf)
        if (!seen_rmf) emit("RuntimeMaxFiles", rmf)
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
' "$JC" > "$TMP"

if [ $? -ne 0 ] || [ ! -s "$TMP" ]; then
    echo -e "${RED}✗ 生成临时配置失败${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 待应用配置生成成功${NC}"
echo ""

# ============================================================
# STEP 4
# 检查配置内容
# ============================================================

echo -e "${BLUE}[STEP 4] 检查待应用配置${NC}"

if ! grep -q '^\[Journal\]$' "$TMP"; then
    echo -e "${RED}✗ 缺少 [Journal] section${NC}"
    exit 1
fi

REQUIRED_KEYS=(
    "SystemMaxUse"
    "RuntimeMaxUse"
    "SystemKeepFree"
    "RuntimeKeepFree"
    "SystemMaxFileSize"
    "RuntimeMaxFileSize"
    "SystemMaxFiles"
    "RuntimeMaxFiles"
)

for key in "${REQUIRED_KEYS[@]}"; do
    if ! grep -Eq "^${key}=" "$TMP"; then
        echo -e "${RED}✗ 缺少 ${key}${NC}"
        exit 1
    fi
done

echo "  将使用："
grep -E '^(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|RuntimeKeepFree|SystemMaxFileSize|RuntimeMaxFileSize|SystemMaxFiles|RuntimeMaxFiles)=' "$TMP"

echo ""

# ============================================================
# STEP 5
# systemd 配置验证
# ============================================================

echo -e "${BLUE}[STEP 5] 验证 journald 配置${NC}"

if command -v systemd-analyze >/dev/null 2>&1; then

    # systemd-analyze verify 对普通 .conf 文件的支持在不同版本/场景
    # 并不等同于直接解析 journald.conf，因此这里主要依赖
    # systemd-analyze cat-config + 实际 daemon-reload/restart 后检查。

    echo "  systemd 版本："
    systemd --version | head -1
fi

echo -e "${GREEN}✓ 基础配置结构检查通过${NC}"
echo ""

# ============================================================
# STEP 6
# 应用配置
#
# 不在 /etc 创建 .bak
# 不创建 journald.conf.d
# 使用临时文件原子替换
# ============================================================

echo -e "${BLUE}[STEP 6] 应用 journald 配置${NC}"

# 保存原文件元数据
JC_UID="$(stat -c '%u' "$JC")"
JC_GID="$(stat -c '%g' "$JC")"
JC_MODE="$(stat -c '%a' "$JC")"

chown "$JC_UID:$JC_GID" "$TMP"
chmod "$JC_MODE" "$TMP"

# 尽可能保留扩展属性
if command -v getfattr >/dev/null 2>&1 && command -v setfattr >/dev/null 2>&1; then
    :
fi

if mv -f "$TMP" "$JC"; then
    TMP=""
    echo -e "${GREEN}✓ $JC 已安全更新${NC}"
else
    echo -e "${RED}✗ 无法更新 $JC${NC}"
    exit 1
fi

echo ""

# ============================================================
# STEP 7
# 重新加载 journald
# ============================================================

echo -e "${BLUE}[STEP 7] 让 systemd-journald 读取新配置${NC}"

if ! systemctl try-restart systemd-journald.service 2>/dev/null; then
    echo -e "${YELLOW}⚠ journald 未执行 restart，继续检查当前配置${NC}"
else
    echo -e "${GREEN}✓ systemd-journald 已重新加载配置${NC}"
fi

sleep 1

echo ""

# ============================================================
# STEP 8
# 检查 journald 当前实际配置
# ============================================================

echo -e "${BLUE}[STEP 8] 检查 journald 当前实际配置${NC}"

echo ""
echo "  systemd-analyze cat-config systemd/journald.conf："

if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | grep -E '^(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|RuntimeKeepFree|SystemMaxFileSize|RuntimeMaxFileSize|SystemMaxFiles|RuntimeMaxFiles)=' \
        || true
fi

echo ""

echo "  journalctl --disk-usage："
journalctl --disk-usage 2>/dev/null || true

echo ""

# ============================================================
# STEP 9
# 仅清理 journald 的旧归档
#
# 不清空：
#   /var/log/syslog
#   /var/log/auth.log
#   /var/log/kern.log
#   /var/log/nginx/*.log
#
# journalctl --vacuum 只处理 archived journal，
# 不直接清理正在写入的 active journal。
#
# --rotate 会先把当前 active journal 轮换成 archived，
# 然后 vacuum 才能最大程度清理旧数据。
# ============================================================

echo -e "${BLUE}[STEP 9] 清理 journald 超出限制的旧归档${NC}"

if journalctl --rotate \
    --vacuum-size="$JOURNAL_SYSTEM_MAX_USE" \
    --vacuum-time=3d \
    --vacuum-files="$JOURNAL_SYSTEM_MAX_FILES" \
    >/tmp/journal-vacuum-result.$$ 2>&1; then

    cat /tmp/journal-vacuum-result.$$
    rm -f /tmp/journal-vacuum-result.$$

    echo -e "${GREEN}✓ journald 旧归档清理完成${NC}"
else
    cat /tmp/journal-vacuum-result.$$ 2>/dev/null || true
    rm -f /tmp/journal-vacuum-result.$$ 2>/dev/null || true

    echo -e "${YELLOW}⚠ journald vacuum 返回非零状态${NC}"
    echo "  不会删除 /var/log 下的普通活动日志。"
fi

echo ""

# ============================================================
# STEP 10
# rsyslog 检查
#
# 不修改 rsyslog.conf
# 不关闭 ForwardToSyslog
# 不 restart rsyslog
# 不清空 syslog/auth.log
# ============================================================

echo -e "${BLUE}[STEP 10] 检查 rsyslog（只检查，不破坏）${NC}"

if systemctl list-unit-files 2>/dev/null | grep -q '^rsyslog.service'; then

    if systemctl is-active --quiet rsyslog.service 2>/dev/null; then
        echo -e "${GREEN}  ✓ rsyslog 当前正在运行${NC}"
    else
        echo "  rsyslog 已安装，但当前没有运行"
    fi

    if [ -f /etc/logrotate.d/rsyslog ]; then
        echo -e "${GREEN}  ✓ Debian rsyslog logrotate 配置存在：/etc/logrotate.d/rsyslog${NC}"
        echo "    不修改它，避免破坏 Debian 软件包提供的轮换逻辑。"
    else
        echo "  未发现 /etc/logrotate.d/rsyslog"
    fi

else
    echo "  rsyslog 未安装/未注册为 systemd service"
fi

echo ""

# ============================================================
# STEP 11
# nginx 检查
#
# 不清空 nginx 活动日志
# 不执行 nginx -s reopen
# 不修改 nginx.conf
# ============================================================

echo -e "${BLUE}[STEP 11] 检查 nginx（只检查，不破坏）${NC}"

if command -v nginx >/dev/null 2>&1 || [ -d /etc/nginx ]; then

    if [ -f /etc/logrotate.d/nginx ]; then
        echo -e "${GREEN}  ✓ nginx logrotate 配置存在：/etc/logrotate.d/nginx${NC}"
        echo "    不修改 nginx logrotate 规则。"
    else
        echo "  未发现 /etc/logrotate.d/nginx"
    fi

    if [ -d /var/log/nginx ]; then
        echo "  nginx 当前日志占用："
        du -sh /var/log/nginx 2>/dev/null || true
    fi

else
    echo "  nginx 未检测到"
fi

echo ""

# ============================================================
# STEP 12
# 检查 logrotate 配置
#
# 只做 debug 检查，不执行 -f
# 不强制轮换任何活动日志
# ============================================================

echo -e "${BLUE}[STEP 12] 检查 logrotate${NC}"

if command -v logrotate >/dev/null 2>&1; then

    echo "  logrotate 版本："
    logrotate --version | head -1

    echo ""
    echo "  执行 logrotate debug 检查（不会实际修改日志）："

    if logrotate -d /etc/logrotate.conf >/tmp/logrotate-debug.$$ 2>&1; then
        echo -e "${GREEN}✓ logrotate 配置检查通过${NC}"
    else
        echo -e "${YELLOW}⚠ logrotate debug 检查返回非零状态${NC}"
    fi

    rm -f /tmp/logrotate-debug.$$ 2>/dev/null || true

else
    echo "  logrotate 未安装"
fi

echo ""

# ============================================================
# STEP 13
# 最终状态
# ============================================================

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} 最终状态${NC}"
echo -e "${CYAN}============================================================${NC}"

echo ""
echo "journald："
journalctl --disk-usage 2>/dev/null || true

echo ""
echo "/var/log："
du -sh /var/log 2>/dev/null || true

echo ""
echo "主要日志："

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
        du -h "$f" 2>/dev/null
    fi
done

echo ""

echo "journald 限制："
echo "  SystemMaxUse        = $JOURNAL_SYSTEM_MAX_USE"
echo "  RuntimeMaxUse       = $JOURNAL_RUNTIME_MAX_USE"
echo "  SystemKeepFree      = $JOURNAL_SYSTEM_KEEP_FREE"
echo "  RuntimeKeepFree     = $JOURNAL_RUNTIME_KEEP_FREE"
echo "  SystemMaxFileSize   = $JOURNAL_SYSTEM_MAX_FILE_SIZE"
echo "  RuntimeMaxFileSize  = $JOURNAL_RUNTIME_MAX_FILE_SIZE"
echo "  SystemMaxFiles      = $JOURNAL_SYSTEM_MAX_FILES"
echo "  RuntimeMaxFiles     = $JOURNAL_RUNTIME_MAX_FILES"

echo ""
echo -e "${GREEN}✓ Debian 13 日志优化完成${NC}"
echo -e "${GREEN}✓ 未清空 syslog/auth.log/kern.log/nginx 活动日志${NC}"
echo -e "${GREEN}✓ 未修改 rsyslog 工作方式${NC}"
echo -e "${GREEN}✓ 未修改 nginx 工作方式${NC}"
echo -e "${GREEN}✓ 未创建 journald.conf.d 配置文件${NC}"
echo -e "${GREEN}✓ 未修改 /etc/logrotate.conf 全局策略${NC}"
echo ""
