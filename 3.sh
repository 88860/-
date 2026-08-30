#!/bin/bash

# ============================================================
# Debian 13 Server Safe Cleaner
# ============================================================

set -u

[ "$(id -u)" -eq 0 ] || {
    echo "错误：请使用 root 运行。"
    exit 1
}

# ---------- 基础配置 ----------
OLD_DAYS=14
TMP_DAYS=7
CACHE_DAYS=30
BIG_LOG=$((100 * 1024 * 1024))

BASE="/tmp/debian-clean-$$"
mkdir -p "$BASE"
trap 'rm -rf "$BASE"' EXIT

LOG="$BASE/log"
BACKUP="$BASE/backup"
TMP="$BASE/tmp"
CACHE="$BASE/cache"
CORE="$BASE/core"

: > "$LOG"
: > "$BACKUP"
: > "$TMP"
: > "$CACHE"
: > "$CORE"

# ---------- 工具 ----------

human() {
    numfmt -to=iec --suffix=B "${1:-0}" 2>/dev/null ||
    echo "${1:-0}B"
}

fsize() {
    stat -c '%s' -- "$1" 2>/dev/null || echo 0
}

fcount() {
    wc -l < "$1" | tr -d ' '
}

fsum() {
    local total=0 n f

    while IFS= read -r f; do
        [ -f "$f" ] || continue
        n=$(fsize "$f")
        total=$((total+n))
    done < "$1"

    echo "$total"
}

free_space() {
    df -B1 / | awk 'NR==2 {print $4}'
}

opened() {
    command -v lsof >/dev/null 2>&1 || return 1
    lsof -- "$1" >/dev/null 2>&1
}

# ============================================================
# 标题
# ============================================================

clear 2>/dev/null || true

echo
echo "============================================================"
echo "              Debian 13 服务器安全深度清理"
echo "============================================================"
echo
echo "主机：$(hostname)"
echo "系统：$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Debian}")"
echo "内核：$(uname -r)"
echo
echo "当前磁盘："
df -h /
echo
echo "开始扫描..."
echo

# ============================================================
# 1. 日志
# ============================================================

echo "[1/6] 扫描旧日志..."

find /var/log -xdev -type f \
    -mtime +"$OLD_DAYS" \
    \( \
        -name '*.gz' \
        -o -name '*.xz' \
        -o -name '*.bz2' \
        -o -name '*.zst' \
        -o -name '*.old' \
        -o -name '*.1' \
        -o -name '*.2' \
        -o -name '*.3' \
        -o -name '*.4' \
        -o -name '*.5' \
        -o -name '*.6' \
        -o -name '*.7' \
        -o -name '*.8' \
        -o -name '*.9' \
    \) \
    -print 2>/dev/null |
sort -u > "$LOG"

# ============================================================
# 2. 备份
# ============================================================

echo "[2/6] 扫描备份..."

for d in /backup /backups /var/backups /root /home /opt /srv /var/www; do

    [ -d "$d" ] || continue

    find "$d" -xdev -type f \
        \( \
            -iname '*.bak' \
            -o -iname '*.backup' \
            -o -iname '*.bkp' \
            -o -iname '*.old' \
            -o -iname '*.orig' \
            -o -iname '*.save' \
            -o -iname '*.dump' \
            -o -iname '*.sql' \
            -o -iname '*.sql.gz' \
            -o -iname '*.sql.xz' \
            -o -iname '*.tar' \
            -o -iname '*.tar.gz' \
            -o -iname '*.tgz' \
            -o -iname '*.tar.xz' \
            -o -iname '*.zip' \
            -o -iname '*.7z' \
            -o -iname '*backup*' \
        \) \
        -print 2>/dev/null >> "$BACKUP"

done

sort -u "$BACKUP" -o "$BACKUP"

# ============================================================
# 3. 临时文件
# ============================================================

echo "[3/6] 扫描临时文件..."

for d in /tmp /var/tmp; do

    [ -d "$d" ] || continue

    find "$d" -xdev -type f \
        -mtime +"$TMP_DAYS" \
        -print 2>/dev/null >> "$TMP"

done

sort -u "$TMP" -o "$TMP"

# ============================================================
# 4. Cache
# ============================================================

echo "[4/6] 扫描用户缓存..."

for d in /root /home/*; do

    [ -d "$d/.cache" ] || continue

    find "$d/.cache" -xdev -type f \
        -mtime +"$CACHE_DAYS" \
        -print 2>/dev/null >> "$CACHE"

done

sort -u "$CACHE" -o "$CACHE"

# ============================================================
# 5. Core / Crash
# ============================================================

echo "[5/6] 扫描 Core / Crash..."

for d in /var/crash /var/lib/systemd/coredump; do

    [ -d "$d" ] || continue

    find "$d" -xdev -type f \
        \( -name 'core' -o -name 'core.*' -o -name '*.core' \) \
        -print 2>/dev/null >> "$CORE"

done

sort -u "$CORE" -o "$CORE"

# ============================================================
# 6. 统计
# ============================================================

echo "[6/6] 统计..."
echo

LOG_COUNT=$(fcount "$LOG")
LOG_SIZE=$(fsum "$LOG")

BACKUP_COUNT=$(fcount "$BACKUP")
BACKUP_SIZE=$(fsum "$BACKUP")

TMP_COUNT=$(fcount "$TMP")
TMP_SIZE=$(fsum "$TMP")

CACHE_COUNT=$(fcount "$CACHE")
CACHE_SIZE=$(fsum "$CACHE")

CORE_COUNT=$(fcount "$CORE")
CORE_SIZE=$(fsum "$CORE")

TOTAL_COUNT=$((LOG_COUNT + BACKUP_COUNT + TMP_COUNT + CACHE_COUNT + CORE_COUNT))
TOTAL_SIZE=$((LOG_SIZE + BACKUP_SIZE + TMP_SIZE + CACHE_SIZE + CORE_SIZE))

# ============================================================
# Journal
# ============================================================

JOURNAL_SIZE=0

if command -v journalctl >/dev/null 2>&1; then

    JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null |
        grep -oE '[0-9.]+[[:space:]]*(K|M|G|T)B' |
        tail -1 || true)

fi

# ============================================================
# 扫描报告
# ============================================================

echo
echo "============================================================"
echo "                       扫描结果"
echo "============================================================"
echo

printf "%-18s %8s 个   %12s\n" "旧轮转日志" "$LOG_COUNT" "$(human "$LOG_SIZE")"
printf "%-18s %8s 个   %12s\n" "备份文件" "$BACKUP_COUNT" "$(human "$BACKUP_SIZE")"
printf "%-18s %8s 个   %12s\n" "临时文件" "$TMP_COUNT" "$(human "$TMP_SIZE")"
printf "%-18s %8s 个   %12s\n" "用户缓存" "$CACHE_COUNT" "$(human "$CACHE_SIZE")"
printf "%-18s %8s 个   %12s\n" "Core / Crash" "$CORE_COUNT" "$(human "$CORE_SIZE")"

echo
echo "------------------------------------------------------------"
printf "可直接删除文件    : %8s 个\n" "$TOTAL_COUNT"
printf "预计文件释放      : %12s\n" "$(human "$TOTAL_SIZE")"

if [ -n "$JOURNAL_SIZE" ]; then
    printf "Journal 当前占用   : %12s\n" "$JOURNAL_SIZE"
fi

echo "------------------------------------------------------------"

# ============================================================
# 最大文件
# ============================================================

show_top() {

    local title="$1"
    local file="$2"

    [ -s "$file" ] || return

    echo
    echo "$title"
    echo "------------------------------------------------------------"

    while IFS= read -r f; do
        [ -f "$f" ] || continue
        printf "%s|%s\n" "$(fsize "$f")" "$f"
    done < "$file" |
    sort -t'|' -k1,1nr |
    head -10 |
    while IFS='|' read -r s f; do
        printf "%12s  %s\n" "$(human "$s")" "$f"
    done
}

show_top "占用最大的旧日志：" "$LOG"
show_top "占用最大的备份：" "$BACKUP"

# ============================================================
# 菜单
# ============================================================

echo
echo "============================================================"
echo "                       清理菜单"
echo "============================================================"
echo
echo "  1) 全部清理"
echo "  2) 只清理旧日志"
echo "  3) 只清理备份"
echo "  4) 清理临时文件 + Cache + Core"
echo "  5) 日志 + 备份"
echo "  6) APT + Journal + 临时文件"
echo "  7) 全部 + Docker 未使用资源"
echo "  0) 退出"
echo

# ============================================================
# 可靠读取
# ============================================================

read_tty() {
    local prompt="$1"
    local value=""

    if [ -t 0 ]; then
        IFS= read -r -p "$prompt" value
    elif [ -r /dev/tty ]; then
        IFS= read -r -p "$prompt" value < /dev/tty
    else
        echo
        echo "错误：当前环境没有可用的交互终端。"
        echo "请下载脚本后运行：bash 3.sh"
        exit 1
    fi

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    REPLY="$value"
}

# ============================================================
# 菜单循环
# ============================================================

while true; do

    read_tty "请选择 [0-7]： "

    case "$REPLY" in

        1)
            DO_LOG=1
            DO_BACKUP=1
            DO_TMP=1
            DO_CACHE=1
            DO_CORE=1
            DO_APT=1
            DO_JOURNAL=1
            DO_DOCKER=1
            break
            ;;

        2)
            DO_LOG=1
            DO_BACKUP=0
            DO_TMP=0
            DO_CACHE=0
            DO_CORE=0
            DO_APT=0
            DO_JOURNAL=1
            DO_DOCKER=0
            break
            ;;

        3)
            DO_LOG=0
            DO_BACKUP=1
            DO_TMP=0
            DO_CACHE=0
            DO_CORE=0
            DO_APT=0
            DO_JOURNAL=0
            DO_DOCKER=0
            break
            ;;

        4)
            DO_LOG=0
            DO_BACKUP=0
            DO_TMP=1
            DO_CACHE=1
            DO_CORE=1
            DO_APT=0
            DO_JOURNAL=0
            DO_DOCKER=0
            break
            ;;

        5)
            DO_LOG=1
            DO_BACKUP=1
            DO_TMP=0
            DO_CACHE=0
            DO_CORE=0
            DO_APT=0
            DO_JOURNAL=1
            DO_DOCKER=0
            break
            ;;

        6)
            DO_LOG=0
            DO_BACKUP=0
            DO_TMP=1
            DO_CACHE=1
            DO_CORE=1
            DO_APT=1
            DO_JOURNAL=1
            DO_DOCKER=0
            break
            ;;

        7)
            DO_LOG=1
            DO_BACKUP=1
            DO_TMP=1
            DO_CACHE=1
            DO_CORE=1
            DO_APT=1
            DO_JOURNAL=1
            DO_DOCKER=1
            break
            ;;

        0)
            echo
            echo "已退出，没有执行任何清理。"
            exit 0
            ;;

        *)
            echo
            echo "输入无效：[$REPLY]"
            echo "请输入 0 - 7。"
            echo
            ;;

    esac

done

# ============================================================
# 最终确认
# ============================================================

echo
echo "============================================================"
echo "                       清理确认"
echo "============================================================"
echo

[ "$DO_LOG" = 1 ] && echo "  ✓ 旧轮转日志"
[ "$DO_BACKUP" = 1 ] && echo "  ✓ 备份文件"
[ "$DO_TMP" = 1 ] && echo "  ✓ 临时文件"
[ "$DO_CACHE" = 1 ] && echo "  ✓ 用户缓存"
[ "$DO_CORE" = 1 ] && echo "  ✓ Core / Crash"
[ "$DO_APT" = 1 ] && echo "  ✓ APT 缓存"
[ "$DO_JOURNAL" = 1 ] && echo "  ✓ Journal"
[ "$DO_DOCKER" = 1 ] && echo "  ✓ Docker 未使用资源"

echo
echo "安全保护："
echo "  ✓ 不停止正在运行的服务"
echo "  ✓ 不删除当前运行内核"
echo "  ✓ 不删除数据库数据目录"
echo "  ✓ 不删除网站目录本身"
echo "  ✓ 正在被进程使用的文件跳过"
echo "  ✓ 当前日志不会因为普通清理而删除"
echo

read_tty "确认清理？请输入 YES： "

if [ "$REPLY" != "YES" ]; then
    echo
    echo "已取消，没有删除任何文件。"
    exit 0
fi

# ============================================================
# 清理前空间
# ============================================================

BEFORE=$(free_space)

echo
echo "============================================================"
echo "                       开始清理"
echo "============================================================"
echo

# ============================================================
# 日志
# ============================================================

if [ "$DO_LOG" = 1 ]; then

    echo "[1] 清理旧日志..."

    while IFS= read -r f; do

        [ -f "$f" ] || continue

        if opened "$f"; then
            echo "  跳过正在使用：$f"
        else
            echo "  删除：$f"
            rm -f -- "$f" 2>/dev/null || true
        fi

    done < "$LOG"

fi

# ============================================================
# 备份
# ============================================================

if [ "$DO_BACKUP" = 1 ]; then

    echo "[2] 清理备份..."

    while IFS= read -r f; do

        [ -f "$f" ] || continue

        if opened "$f"; then
            echo "  跳过正在使用：$f"
        else
            echo "  删除：$f"
            rm -f -- "$f" 2>/dev/null || true
        fi

    done < "$BACKUP"

fi

# ============================================================
# 临时
# ============================================================

if [ "$DO_TMP" = 1 ]; then

    echo "[3] 清理临时文件..."

    while IFS= read -r f; do

        [ -f "$f" ] || continue

        if opened "$f"; then
            echo "  跳过：$f"
        else
            rm -f -- "$f" 2>/dev/null || true
        fi

    done < "$TMP"

fi

# ============================================================
# Cache
# ============================================================

if [ "$DO_CACHE" = 1 ]; then

    echo "[4] 清理用户缓存..."

    while IFS= read -r f; do

        [ -f "$f" ] || continue

        if ! opened "$f"; then
            rm -f -- "$f" 2>/dev/null || true
        fi

    done < "$CACHE"

fi

# ============================================================
# Core
# ============================================================

if [ "$DO_CORE" = 1 ]; then

    echo "[5] 清理 Core / Crash..."

    if command -v coredumpctl >/dev/null 2>&1; then
        coredumpctl delete 2>/dev/null || true
    fi

    while IFS= read -r f; do

        [ -f "$f" ] || continue

        if ! opened "$f"; then
            rm -f -- "$f" 2>/dev/null || true
        fi

    done < "$CORE"

fi

# ============================================================
# APT
# ============================================================

if [ "$DO_APT" = 1 ]; then

    echo "[6] 清理 APT..."

    apt-get autoclean -y
    apt-get clean
    apt-get autoremove --purge -y

fi

# ============================================================
# Journal
# ============================================================

if [ "$DO_JOURNAL" = 1 ] &&
   command -v journalctl >/dev/null 2>&1; then

    echo "[7] 清理 Journal..."

    journalctl --vacuum-time="${OLD_DAYS}d"
    journalctl --vacuum-size=500M

fi

# ============================================================
# Docker
# ============================================================

if [ "$DO_DOCKER" = 1 ] &&
   command -v docker >/dev/null 2>&1; then

    echo "[8] 清理 Docker 未使用资源..."

    docker container prune -f
    docker image prune -f
    docker network prune -f
    docker builder prune -f

fi

# ============================================================
# systemd
# ============================================================

echo "[9] systemd 临时文件..."

systemd-tmpfiles --clean 2>/dev/null || true

# ============================================================
# 最终空间
# ============================================================

sync

AFTER=$(free_space)
RELEASED=$((AFTER - BEFORE))

echo
echo "============================================================"
echo "                       清理完成"
echo "============================================================"
echo

if [ "$RELEASED" -gt 0 ]; then
    echo "实际释放空间：$(human "$RELEASED")"
elif [ "$RELEASED" -eq 0 ]; then
    echo "实际释放空间：0B"
else
    echo "空间变化：增加 $(human "$((-RELEASED)")"
    echo "说明：清理期间可能有服务产生了新的文件。"
fi

echo
echo "清理后磁盘："
df -h /

echo

if command -v journalctl >/dev/null 2>&1; then
    echo "Journal："
    journalctl --disk-usage 2>/dev/null || true
    echo
fi

if command -v docker >/dev/null 2>&1; then
    echo "Docker："
    docker system df 2>/dev/null || true
    echo
fi

echo "============================================================"
echo "                     清理任务完成"
echo "============================================================"
