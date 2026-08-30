#!/bin/bash
set -u
set -o pipefail

[[ $EUID -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }

# =========================
# 配置
# =========================
ROTATE_DAYS=14
TMP_DAYS=7
CACHE_DAYS=30
BIG_LOG_MB=100

WORKDIR="$(mktemp -d /tmp/debian-clean.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

LOG_OLD="$WORKDIR/log_old"
LOG_BIG="$WORKDIR/log_big"
BACKUP="$WORKDIR/backup"
TMP="$WORKDIR/tmp"
CACHE="$WORKDIR/cache"
CORE="$WORKDIR/core"

touch "$LOG_OLD" "$LOG_BIG" "$BACKUP" "$TMP" "$CACHE" "$CORE"

# =========================
# 工具
# =========================
human() {
    numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"
}

size() {
    stat -c '%s' -- "$1" 2>/dev/null || echo 0
}

count() {
    awk 'END{print NR+0}' "$1"
}

sum() {
    local n=0 f s
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        s=$(size "$f")
        n=$((n+s))
    done < "$1"
    echo "$n"
}

free_space() {
    df -B1 / | awk 'NR==2{print $4+0}'
}

is_open() {
    command -v lsof >/dev/null 2>&1 || return 1
    lsof -- "$1" >/dev/null 2>&1
}

# =========================
# 标题
# =========================
clear
echo
echo "============================================================"
echo "             Debian 13 服务器深度清理"
echo "============================================================"
echo
echo "主机：$(hostname)"
echo "系统：$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Debian}")"
echo "内核：$(uname -r)"
echo
echo "当前磁盘："
df -h /
echo
echo "正在扫描服务器，请稍候..."
echo

# =========================
# 日志：只把真正可删除的旧轮转日志加入 LOG_OLD
# 当前日志单独检查超大文件
# =========================
echo "[1/6] 扫描日志..."

find /var/log -xdev -type f \
    -mtime +"$ROTATE_DAYS" \
    \( \
      -name '*.gz' -o \
      -name '*.xz' -o \
      -name '*.bz2' -o \
      -name '*.zst' -o \
      -name '*.old' -o \
      -name '*.1' -o \
      -name '*.2' -o \
      -name '*.3' -o \
      -name '*.4' -o \
      -name '*.5' -o \
      -name '*.6' -o \
      -name '*.7' -o \
      -name '*.8' -o \
      -name '*.9' \
    \) \
    -print 2>/dev/null |
sort -u > "$LOG_OLD"

# 当前日志
while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    case "$f" in
        *.log|*/syslog|*/auth.log|*/kern.log|*/daemon.log|*/messages|*/mail.log|*/debug)
            s=$(size "$f")
            if (( s >= BIG_LOG_MB * 1024 * 1024 )); then
                echo "$f" >> "$LOG_BIG"
            fi
            ;;
    esac
done < <(
    find /var/log -xdev -type f \
        \( \
          -name '*.log' -o \
          -name 'syslog' -o \
          -name 'auth.log' -o \
          -name 'kern.log' -o \
          -name 'daemon.log' -o \
          -name 'messages' -o \
          -name 'mail.log' -o \
          -name 'debug' \
        \) \
        -print 2>/dev/null
)

sort -u "$LOG_BIG" -o "$LOG_BIG"

# =========================
# 备份
# =========================
echo "[2/6] 扫描备份..."

for dir in /backup /backups /var/backups /root /home /var/www /srv /opt; do
    [[ -d "$dir" ]] || continue

    find "$dir" -xdev -type f \
        \( \
        -iname '*.bak' -o \
        -iname '*.backup' -o \
        -iname '*.bkp' -o \
        -iname '*.orig' -o \
        -iname '*.save' -o \
        -iname '*.sql' -o \
        -iname '*.sql.gz' -o \
        -iname '*.sql.xz' -o \
        -iname '*.sql.bz2' -o \
        -iname '*.dump' -o \
        -iname '*.dump.gz' -o \
        -iname '*.tar' -o \
        -iname '*.tar.gz' -o \
        -iname '*.tgz' -o \
        -iname '*.tar.xz' -o \
        -iname '*.tar.bz2' -o \
        -iname '*.zip' -o \
        -iname '*.7z' -o \
        -iname '*.rar' -o \
        -iname '*backup*' \
        \) \
        -print 2>/dev/null >> "$BACKUP"
done

sort -u "$BACKUP" -o "$BACKUP"

# =========================
# 临时
# =========================
echo "[3/6] 扫描临时文件..."

for dir in /tmp /var/tmp; do
    [[ -d "$dir" ]] || continue

    find "$dir" -xdev -type f \
        -mtime +"$TMP_DAYS" \
        -print 2>/dev/null >> "$TMP"
done

sort -u "$TMP" -o "$TMP"

# =========================
# Cache
# =========================
echo "[4/6] 扫描用户缓存..."

for dir in /root /home/*; do
    [[ -d "$dir/.cache" ]] || continue

    find "$dir/.cache" -xdev -type f \
        -mtime +"$CACHE_DAYS" \
        -print 2>/dev/null >> "$CACHE"
done

sort -u "$CACHE" -o "$CACHE"

# =========================
# Core
# =========================
echo "[5/6] 扫描 Crash / Core..."

for dir in /var/crash /var/lib/systemd/coredump /tmp /var/tmp /root /home; do
    [[ -d "$dir" ]] || continue

    find "$dir" -xdev -type f \
        \( -name 'core' -o -name 'core.*' -o -name '*.core' \) \
        -mtime +"$TMP_DAYS" \
        -print 2>/dev/null >> "$CORE"
done

sort -u "$CORE" -o "$CORE"

# =========================
# 统计
# =========================
echo "[6/6] 统计空间..."
echo

OLD_LOG_COUNT=$(count "$LOG_OLD")
OLD_LOG_SIZE=$(sum "$LOG_OLD")

BIG_LOG_COUNT=$(count "$LOG_BIG")
BIG_LOG_SIZE=$(sum "$LOG_BIG")

BACKUP_COUNT=$(count "$BACKUP")
BACKUP_SIZE=$(sum "$BACKUP")

TMP_COUNT=$(count "$TMP")
TMP_SIZE=$(sum "$TMP")

CACHE_COUNT=$(count "$CACHE")
CACHE_SIZE=$(sum "$CACHE")

CORE_COUNT=$(count "$CORE")
CORE_SIZE=$(sum "$CORE")

# 真正符合当前清理规则的文件
FILE_COUNT=$((OLD_LOG_COUNT + BIG_LOG_COUNT + BACKUP_COUNT + TMP_COUNT + CACHE_COUNT + CORE_COUNT))
FILE_SIZE=$((OLD_LOG_SIZE + BIG_LOG_SIZE + BACKUP_SIZE + TMP_SIZE + CACHE_SIZE + CORE_SIZE))

# =========================
# Journal
# =========================
echo "Journal："
journalctl --disk-usage 2>/dev/null || echo "不可用"
echo

# =========================
# Docker
# =========================
if command -v docker >/dev/null 2>&1; then
    echo "Docker 当前占用："
    docker system df 2>/dev/null || true
    echo
fi

# =========================
# 扫描结果
# =========================
echo "============================================================"
echo "                       扫描结果"
echo "============================================================"
echo

printf "旧轮转日志      : %8d 个   %12s\n" "$OLD_LOG_COUNT" "$(human "$OLD_LOG_SIZE")"
printf "超大当前日志    : %8d 个   %12s\n" "$BIG_LOG_COUNT" "$(human "$BIG_LOG_SIZE")"
printf "备份文件        : %8d 个   %12s\n" "$BACKUP_COUNT" "$(human "$BACKUP_SIZE")"
printf "临时文件        : %8d 个   %12s\n" "$TMP_COUNT" "$(human "$TMP_SIZE")"
printf "用户缓存        : %8d 个   %12s\n" "$CACHE_COUNT" "$(human "$CACHE_SIZE")"
printf "Core / Crash     : %8d 个   %12s\n" "$CORE_COUNT" "$(human "$CORE_SIZE")"

echo
echo "------------------------------------------------------------"
printf "真正可清理文件  : %8d 个\n" "$FILE_COUNT"
printf "文件预计释放    : %12s\n" "$(human "$FILE_SIZE")"
echo "------------------------------------------------------------"

# =========================
# 最大文件
# =========================
show_top() {
    local title="$1"
    local list="$2"

    local c
    c=$(count "$list")

    (( c > 0 )) || return

    echo
    echo "$title"
    echo "------------------------------------------------------------"

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        printf "%s\t%s\n" "$(size "$f")" "$f"
    done < "$list" |
    sort -nr |
    head -20 |
    while IFS=$'\t' read -r s f; do
        printf "%12s  %s\n" "$(human "$s")" "$f"
    done
}

show_top "旧日志最大的 20 个：" "$LOG_OLD"
show_top "备份最大的 20 个：" "$BACKUP"
show_top "超大当前日志：" "$LOG_BIG"

# =========================
# 菜单
# =========================
echo
echo "============================================================"
echo "                       清理菜单"
echo "============================================================"
echo
echo "  1) 清理全部"
echo "  2) 只清理日志"
echo "  3) 只清理备份"
echo "  4) 清理缓存 / 临时 / Core"
echo "  5) 日志 + 备份"
echo "  6) 缓存 + APT + Journal"
echo "  7) 全部 + Docker"
echo "  0) 退出"
echo

CHOICE=""

# 用明确的 /dev/tty 读取，避免某些 curl | bash 环境下 stdin 异常
if [[ -r /dev/tty ]]; then
    read -r -p "请选择 [0-7]： " CHOICE < /dev/tty
else
    read -r -p "请选择 [0-7]： " CHOICE
fi

case "$CHOICE" in
    1)
        DO_LOG=1; DO_BACKUP=1; DO_TMP=1; DO_CACHE=1
        DO_CORE=1; DO_APT=1; DO_JOURNAL=1; DO_DOCKER=1
        ;;
    2)
        DO_LOG=1; DO_BACKUP=0; DO_TMP=0; DO_CACHE=0
        DO_CORE=0; DO_APT=0; DO_JOURNAL=1; DO_DOCKER=0
        ;;
    3)
        DO_LOG=0; DO_BACKUP=1; DO_TMP=0; DO_CACHE=0
        DO_CORE=0; DO_APT=0; DO_JOURNAL=0; DO_DOCKER=0
        ;;
    4)
        DO_LOG=0; DO_BACKUP=0; DO_TMP=1; DO_CACHE=1
        DO_CORE=1; DO_APT=0; DO_JOURNAL=0; DO_DOCKER=0
        ;;
    5)
        DO_LOG=1; DO_BACKUP=1; DO_TMP=0; DO_CACHE=0
        DO_CORE=0; DO_APT=0; DO_JOURNAL=1; DO_DOCKER=0
        ;;
    6)
        DO_LOG=0; DO_BACKUP=0; DO_TMP=1; DO_CACHE=1
        DO_CORE=1; DO_APT=1; DO_JOURNAL=1; DO_DOCKER=0
        ;;
    7)
        DO_LOG=1; DO_BACKUP=1; DO_TMP=1; DO_CACHE=1
        DO_CORE=1; DO_APT=1; DO_JOURNAL=1; DO_DOCKER=1
        ;;
    0)
        echo
        echo "已退出，没有删除任何文件。"
        exit 0
        ;;
    *)
        echo
        echo "无效选择：[$CHOICE]"
        echo "请输入数字 0-7。"
        exit 1
        ;;
esac

# =========================
# 最终确认
# =========================
echo
echo "============================================================"
echo "                       最终确认"
echo "============================================================"
echo

[[ "$DO_LOG" == 1 ]]     && echo "✓ 日志"
[[ "$DO_BACKUP" == 1 ]]  && echo "✓ 备份"
[[ "$DO_TMP" == 1 ]]     && echo "✓ 临时文件"
[[ "$DO_CACHE" == 1 ]]   && echo "✓ 用户缓存"
[[ "$DO_CORE" == 1 ]]    && echo "✓ Core / Crash"
[[ "$DO_APT" == 1 ]]     && echo "✓ APT"
[[ "$DO_JOURNAL" == 1 ]] && echo "✓ Journal"
[[ "$DO_DOCKER" == 1 ]]  && echo "✓ Docker 未使用资源"

echo
echo "安全保护："
echo "  ✓ 不删除数据库数据目录"
echo "  ✓ 不停止正在运行的 Docker 容器"
echo "  ✓ 不删除 /etc 配置"
echo "  ✓ 不手动删除当前运行内核"
echo "  ✓ 正在使用的文件会跳过"
echo "  ✓ 当前超大日志使用 truncate，不 rm"
echo

CONFIRM=""

if [[ -r /dev/tty ]]; then
    read -r -p "确定执行？输入 YES： " CONFIRM < /dev/tty
else
    read -r -p "确定执行？输入 YES： " CONFIRM
fi

[[ "$CONFIRM" == "YES" ]] || {
    echo
    echo "已取消，没有删除任何文件。"
    exit 0
}

# =========================
# 清理前
# =========================
BEFORE=$(free_space)

echo
echo "============================================================"
echo "                       开始清理"
echo "============================================================"
echo

# =========================
# 日志
# =========================
if [[ "$DO_LOG" == 1 ]]; then

    echo "[1] 清理日志..."

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue

        if is_open "$f"; then
            echo "  跳过正在使用：$f"
        else
            echo "  删除：$f"
            rm -f -- "$f" 2>/dev/null || true
        fi
    done < "$LOG_OLD"

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue

        echo "  清空超大日志：$f"
        truncate -s 0 -- "$f" 2>/dev/null || true
    done < "$LOG_BIG"

fi

# =========================
# 备份
# =========================
if [[ "$DO_BACKUP" == 1 ]]; then

    echo "[2] 删除备份..."

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue

        if is_open "$f"; then
            echo "  跳过正在使用：$f"
        else
            echo "  删除：$f"
            rm -f -- "$f" 2>/dev/null || true
        fi
    done < "$BACKUP"

fi

# =========================
# 临时
# =========================
if [[ "$DO_TMP" == 1 ]]; then

    echo "[3] 清理临时文件..."

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue

        if ! is_open "$f"; then
            rm -f -- "$f" 2>/dev/null || true
        fi
    done < "$TMP"

fi

# =========================
# Cache
# =========================
if [[ "$DO_CACHE" == 1 ]]; then

    echo "[4] 清理用户缓存..."

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue

        if ! is_open "$f"; then
            rm -f -- "$f" 2>/dev/null || true
        fi
    done < "$CACHE"

fi

# =========================
# Core
# =========================
if [[ "$DO_CORE" == 1 ]]; then

    echo "[5] 清理 Core / Crash..."

    if command -v coredumpctl >/dev/null 2>&1; then
        coredumpctl delete 2>/dev/null || true
    fi

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue

        if ! is_open "$f"; then
            rm -f -- "$f" 2>/dev/null || true
        fi
    done < "$CORE"

fi

# =========================
# APT
# =========================
if [[ "$DO_APT" == 1 ]]; then

    echo "[6] 清理 APT..."

    apt-get autoclean -y
    apt-get clean
    apt-get autoremove --purge -y

fi

# =========================
# Journal
# =========================
if [[ "$DO_JOURNAL" == 1 ]]; then

    echo "[7] 清理 Journal..."

    journalctl --vacuum-time="${ROTATE_DAYS}d"
    journalctl --vacuum-size=500M

fi

# =========================
# Docker
# =========================
if [[ "$DO_DOCKER" == 1 ]] &&
   command -v docker >/dev/null 2>&1; then

    echo "[8] 清理 Docker 未使用资源..."

    docker container prune -f
    docker image prune -f
    docker network prune -f
    docker builder prune -f

fi

# =========================
# systemd
# =========================
echo "[9] 清理 systemd 临时文件..."

systemd-tmpfiles --clean 2>/dev/null || true

# =========================
# 最终空间
# =========================
AFTER=$(free_space)
RELEASED=$((AFTER - BEFORE))

echo
echo "============================================================"
echo "                       清理完成"
echo "============================================================"
echo

if (( RELEASED > 0 )); then
    echo "实际释放空间：$(human "$RELEASED")"
elif (( RELEASED == 0 )); then
    echo "实际释放空间：0B"
else
    echo "磁盘空间变化：增加 $(human "$((-RELEASED)")"
    echo "说明：清理期间可能有服务产生了新的文件。"
fi

echo
echo "清理后磁盘："
df -h /

echo
echo "Journal："
journalctl --disk-usage 2>/dev/null || true

if command -v docker >/dev/null 2>&1; then
    echo
    echo "Docker："
    docker system df 2>/dev/null || true
fi

echo
echo "============================================================"
echo "                    清理任务结束"
echo "============================================================"
