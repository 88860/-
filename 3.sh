#!/bin/bash
# ============================================================
# Debian 13 Server Safe Deep Cleaner
# ============================================================

set -u
set -o pipefail

[[ $EUID -eq 0 ]] || {
    echo "错误：请使用 root 运行"
    exit 1
}

# ============================================================
# 配置
# ============================================================

LOG_ROTATE_DAYS=14
TMP_DAYS=7
CACHE_DAYS=30
BACKUP_DAYS=0
BIG_LOG_MB=100

WORKDIR="$(mktemp -d /tmp/debian-clean.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

LOG_LIST="$WORKDIR/logs"
BACKUP_LIST="$WORKDIR/backups"
TMP_LIST="$WORKDIR/tmp"
CACHE_LIST="$WORKDIR/cache"

touch "$LOG_LIST" "$BACKUP_LIST" "$TMP_LIST" "$CACHE_LIST"


# ============================================================
# 工具
# ============================================================

human() {
    numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"
}

size_of() {
    stat -c '%s' -- "$1" 2>/dev/null || echo 0
}

count_list() {
    awk 'END { print NR+0 }' "$1"
}

sum_list() {
    local total=0
    local f s

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        s=$(size_of "$f")
        total=$((total + s))
    done < "$1"

    echo "$total"
}

free_bytes() {
    df -B1 / 2>/dev/null | awk 'NR==2 {print $4+0}'
}

is_open() {
    local f="$1"

    command -v lsof >/dev/null 2>&1 || return 1

    lsof -- "$f" >/dev/null 2>&1
}

add_find() {
    local dir="$1"
    shift

    [[ -d "$dir" ]] || return

    find "$dir" -xdev -type f "$@" -print 2>/dev/null
}

remove_file() {
    local f="$1"

    [[ -f "$f" ]] || return 0

    if is_open "$f"; then
        echo "  跳过正在使用：$f"
        return 1
    fi

    rm -f -- "$f" 2>/dev/null
}


# ============================================================
# 开始
# ============================================================

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


# ============================================================
# 1. 日志
# ============================================================

echo "[1/6] 扫描日志..."

# 当前日志
add_find /var/log \
    \( \
        -name '*.log' \
        -o -name 'syslog' \
        -o -name 'auth.log' \
        -o -name 'kern.log' \
        -o -name 'daemon.log' \
        -o -name 'messages' \
        -o -name 'mail.log' \
        -o -name 'debug' \
    \) >> "$LOG_LIST"

# 轮转日志
add_find /var/log \
    -mtime +"$LOG_ROTATE_DAYS" \
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
    \) >> "$LOG_LIST"

sort -u "$LOG_LIST" -o "$LOG_LIST"


# ============================================================
# 2. 备份
# ============================================================

echo "[2/6] 扫描备份..."

for dir in \
    /backup \
    /backups \
    /var/backups \
    /root \
    /home \
    /var/www \
    /srv \
    /opt
do
    [[ -d "$dir" ]] || continue

    find "$dir" -xdev -type f \
        \( \
        -iname '*.bak' \
        -o -iname '*.backup' \
        -o -iname '*.bkp' \
        -o -iname '*.old' \
        -o -iname '*.orig' \
        -o -iname '*.save' \
        -o -iname '*.sql' \
        -o -iname '*.sql.gz' \
        -o -iname '*.sql.xz' \
        -o -iname '*.sql.bz2' \
        -o -iname '*.dump' \
        -o -iname '*.dump.gz' \
        -o -iname '*.tar' \
        -o -iname '*.tar.gz' \
        -o -iname '*.tgz' \
        -o -iname '*.tar.xz' \
        -o -iname '*.tar.bz2' \
        -o -iname '*.zip' \
        -o -iname '*.7z' \
        -o -iname '*.rar' \
        -o -iname '*backup*' \
        \) \
        -print 2>/dev/null >> "$BACKUP_LIST"
done

sort -u "$BACKUP_LIST" -o "$BACKUP_LIST"


# ============================================================
# 3. 临时文件
# ============================================================

echo "[3/6] 扫描临时文件..."

for dir in /tmp /var/tmp; do
    [[ -d "$dir" ]] || continue

    add_find "$dir" \
        -mtime +"$TMP_DAYS" >> "$TMP_LIST"
done

sort -u "$TMP_LIST" -o "$TMP_LIST"


# ============================================================
# 4. 用户缓存
# ============================================================

echo "[4/6] 扫描用户缓存..."

for dir in /root /home/*; do
    [[ -d "$dir/.cache" ]] || continue

    add_find "$dir/.cache" \
        -mtime +"$CACHE_DAYS" >> "$CACHE_LIST"
done

sort -u "$CACHE_LIST" -o "$CACHE_LIST"


# ============================================================
# 5. Crash / Core
# ============================================================

echo "[5/6] 扫描 Crash / Core..."

CORE_LIST="$WORKDIR/core"
touch "$CORE_LIST"

for dir in \
    /var/crash \
    /var/lib/systemd/coredump \
    /tmp \
    /var/tmp \
    /root \
    /home
do
    [[ -d "$dir" ]] || continue

    find "$dir" -xdev -type f \
        \( \
        -name 'core' \
        -o -name 'core.*' \
        -o -name '*.core' \
        \) \
        -mtime +"$TMP_DAYS" \
        -print 2>/dev/null >> "$CORE_LIST"
done

sort -u "$CORE_LIST" -o "$CORE_LIST"


# ============================================================
# 6. 统计
# ============================================================

echo "[6/6] 统计空间..."
echo


LOG_COUNT=$(count_list "$LOG_LIST")
LOG_SIZE=$(sum_list "$LOG_LIST")

BACKUP_COUNT=$(count_list "$BACKUP_LIST")
BACKUP_SIZE=$(sum_list "$BACKUP_LIST")

TMP_COUNT=$(count_list "$TMP_LIST")
TMP_SIZE=$(sum_list "$TMP_LIST")

CACHE_COUNT=$(count_list "$CACHE_LIST")
CACHE_SIZE=$(sum_list "$CACHE_LIST")

CORE_COUNT=$(count_list "$CORE_LIST")
CORE_SIZE=$(sum_list "$CORE_LIST")


# ============================================================
# 当前大日志检查
# ============================================================

BIG_LOG_COUNT=0
BIG_LOG_SIZE=0

while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    s=$(size_of "$f")

    if (( s >= BIG_LOG_MB * 1024 * 1024 )); then
        BIG_LOG_COUNT=$((BIG_LOG_COUNT + 1))
        BIG_LOG_SIZE=$((BIG_LOG_SIZE + s))
    fi
done < "$LOG_LIST"


# ============================================================
# Journal
# ============================================================

echo "Journal："

if command -v journalctl >/dev/null 2>&1; then
    journalctl --disk-usage 2>/dev/null || true
else
    echo "未安装 journalctl"
fi

echo


# ============================================================
# Docker
# ============================================================

if command -v docker >/dev/null 2>&1; then
    echo "Docker："
    docker system df 2>/dev/null || true
    echo
fi


# ============================================================
# 扫描结果
# ============================================================

TOTAL=$((LOG_SIZE + BACKUP_SIZE + TMP_SIZE + CACHE_SIZE + CORE_SIZE))

echo
echo "============================================================"
echo "                       扫描结果"
echo "============================================================"
echo

printf "日志文件        : %8d 个   %12s\n" \
    "$LOG_COUNT" "$(human "$LOG_SIZE")"

printf "备份文件        : %8d 个   %12s\n" \
    "$BACKUP_COUNT" "$(human "$BACKUP_SIZE")"

printf "临时文件        : %8d 个   %12s\n" \
    "$TMP_COUNT" "$(human "$TMP_SIZE")"

printf "用户缓存        : %8d 个   %12s\n" \
    "$CACHE_COUNT" "$(human "$CACHE_SIZE")"

printf "Core/Crash       : %8d 个   %12s\n" \
    "$CORE_COUNT" "$(human "$CORE_SIZE")"

echo
echo "------------------------------------------------------------"

printf "扫描文件总数    : %8d 个\n" \
    "$((LOG_COUNT + BACKUP_COUNT + TMP_COUNT + CACHE_COUNT + CORE_COUNT))"

printf "文件预计释放    : %12s\n" \
    "$(human "$TOTAL")"

echo "------------------------------------------------------------"

if (( BIG_LOG_COUNT > 0 )); then
    echo
    echo "发现超大当前日志："
    printf "数量：%d 个，合计：%s\n" \
        "$BIG_LOG_COUNT" "$(human "$BIG_LOG_SIZE")"
fi


# ============================================================
# 最大日志
# ============================================================

if (( LOG_COUNT > 0 )); then

    echo
    echo "日志占用最大的 20 个："
    echo "------------------------------------------------------------"

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        printf "%s\t%s\n" "$(size_of "$f")" "$f"
    done < "$LOG_LIST" |
    sort -nr |
    head -20 |
    while IFS=$'\t' read -r size f; do
        printf "%12s  %s\n" "$(human "$size")" "$f"
    done

fi


# ============================================================
# 最大备份
# ============================================================

if (( BACKUP_COUNT > 0 )); then

    echo
    echo "备份占用最大的 20 个："
    echo "------------------------------------------------------------"

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        printf "%s\t%s\n" "$(size_of "$f")" "$f"
    done < "$BACKUP_LIST" |
    sort -nr |
    head -20 |
    while IFS=$'\t' read -r size f; do
        printf "%12s  %s\n" "$(human "$size")" "$f"
    done

fi


# ============================================================
# 确认菜单
# ============================================================

echo
echo "============================================================"
echo "                       清理菜单"
echo "============================================================"
echo
echo "1) 清理全部"
echo "2) 只清理日志"
echo "3) 只清理备份"
echo "4) 只清理缓存/临时文件"
echo "5) 清理日志 + 备份"
echo "6) 清理日志 + 缓存 + Docker"
echo "0) 退出"
echo

read -rp "请选择 [0-6]： " CHOICE

case "$CHOICE" in
    1)
        DO_LOG=1
        DO_BACKUP=1
        DO_TMP=1
        DO_CACHE=1
        DO_CORE=1
        DO_APT=1
        DO_JOURNAL=1
        DO_DOCKER=1
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
        ;;
    4)
        DO_LOG=0
        DO_BACKUP=0
        DO_TMP=1
        DO_CACHE=1
        DO_CORE=1
        DO_APT=1
        DO_JOURNAL=0
        DO_DOCKER=0
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
        ;;
    6)
        DO_LOG=1
        DO_BACKUP=0
        DO_TMP=1
        DO_CACHE=1
        DO_CORE=1
        DO_APT=1
        DO_JOURNAL=1
        DO_DOCKER=1
        ;;
    0)
        echo "已退出，没有删除任何文件。"
        exit 0
        ;;
    *)
        echo "无效选择。"
        exit 1
        ;;
esac


# ============================================================
# 最终确认
# ============================================================

echo
echo "============================================================"
echo "                       最终确认"
echo "============================================================"
echo

[[ "$DO_LOG" == 1 ]] && \
    echo "✓ 日志"

[[ "$DO_BACKUP" == 1 ]] && \
    echo "✓ 备份"

[[ "$DO_TMP" == 1 ]] && \
    echo "✓ 临时文件"

[[ "$DO_CACHE" == 1 ]] && \
    echo "✓ 用户缓存"

[[ "$DO_CORE" == 1 ]] && \
    echo "✓ Core / Crash"

[[ "$DO_APT" == 1 ]] && \
    echo "✓ APT"

[[ "$DO_JOURNAL" == 1 ]] && \
    echo "✓ Journal"

[[ "$DO_DOCKER" == 1 ]] && \
    echo "✓ Docker 未使用资源"

echo
echo "保护："
echo "✓ 数据库数据目录"
echo "✓ 当前运行的 Docker 容器"
echo "✓ /etc 系统配置"
echo "✓ 当前运行内核"
echo "✓ 正在被进程打开的文件"
echo

read -rp "确定执行？输入 YES： " YES

[[ "$YES" == "YES" ]] || {
    echo "已取消。"
    exit 0
}


# ============================================================
# 清理前空间
# ============================================================

BEFORE=$(free_bytes)

echo
echo "============================================================"
echo "                       开始清理"
echo "============================================================"
echo


# ============================================================
# 日志
# ============================================================

if [[ "$DO_LOG" == 1 ]]; then

    echo "[1] 清理日志..."

    while IFS= read -r f; do

        [[ -f "$f" ]] || continue

        case "$f" in

            *.gz|*.xz|*.bz2|*.zst|*.old|*.1|*.2|*.3|*.4|*.5|*.6|*.7|*.8|*.9)

                remove_file "$f" >/dev/null

                ;;

            *.log|*/syslog|*/auth.log|*/kern.log|*/daemon.log|*/messages|*/mail.log|*/debug)

                s=$(size_of "$f")

                # 当前日志只有超过阈值才清空
                if (( s >= BIG_LOG_MB * 1024 * 1024 )); then

                    if is_open "$f"; then
                        echo "  清空超大当前日志：$f"
                        truncate -s 0 -- "$f" 2>/dev/null || true
                    else
                        # 不删除日志文件，只清空内容
                        echo "  清空日志：$f"
                        truncate -s 0 -- "$f" 2>/dev/null || true
                    fi
                fi

                ;;

        esac

    done < "$LOG_LIST"

fi


# ============================================================
# 备份
# ============================================================

if [[ "$DO_BACKUP" == 1 ]]; then

    echo "[2] 删除备份..."

    while IFS= read -r f; do

        [[ -f "$f" ]] || continue

        if is_open "$f"; then

            echo "  跳过正在使用的备份：$f"

        else

            echo "  删除：$f"
            rm -f -- "$f" 2>/dev/null || true

        fi

    done < "$BACKUP_LIST"

fi


# ============================================================
# 临时
# ============================================================

if [[ "$DO_TMP" == 1 ]]; then

    echo "[3] 清理临时文件..."

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        remove_file "$f" >/dev/null || true
    done < "$TMP_LIST"

fi


# ============================================================
# Cache
# ============================================================

if [[ "$DO_CACHE" == 1 ]]; then

    echo "[4] 清理用户缓存..."

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        remove_file "$f" >/dev/null || true
    done < "$CACHE_LIST"

fi


# ============================================================
# Core
# ============================================================

if [[ "$DO_CORE" == 1 ]]; then

    echo "[5] 清理 Core / Crash..."

    if command -v coredumpctl >/dev/null 2>&1; then
        coredumpctl delete 2>/dev/null || true
    fi

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        remove_file "$f" >/dev/null || true
    done < "$CORE_LIST"

fi


# ============================================================
# APT
# ============================================================

if [[ "$DO_APT" == 1 ]]; then

    echo "[6] 清理 APT..."

    apt-get autoremove -y
    apt-get autoclean -y
    apt-get clean

fi


# ============================================================
# Journal
# ============================================================

if [[ "$DO_JOURNAL" == 1 ]]; then

    echo "[7] 清理 Journal..."

    journalctl --vacuum-time="${LOG_ROTATE_DAYS}d"
    journalctl --vacuum-size=500M

fi


# ============================================================
# Docker
# ============================================================

if [[ "$DO_DOCKER" == 1 ]] &&
   command -v docker >/dev/null 2>&1; then

    echo "[8] 清理 Docker 未使用资源..."

    # 不删除正在运行的容器
    docker container prune -f

    # dangling image
    docker image prune -f

    # unused network
    docker network prune -f

    # build cache
    docker builder prune -f

fi


# ============================================================
# systemd tmpfiles
# ============================================================

echo "[9] systemd tmpfiles..."

systemd-tmpfiles --clean 2>/dev/null || true


# ============================================================
# 旧内核
# ============================================================

echo "[10] 检查旧内核..."

CURRENT_KERNEL="$(uname -r)"

echo "当前运行内核：$CURRENT_KERNEL"

# 只交给 apt 判断，不手动删除 /boot
apt-get autoremove --purge -y


# ============================================================
# 清理后空间
# ============================================================

AFTER=$(free_bytes)

RELEASED=$((AFTER - BEFORE))


# ============================================================
# 最终报告
# ============================================================

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

    echo "磁盘空间增加：$(human "$((-RELEASED)")"
    echo "注意：清理期间可能有服务产生了新的文件。"

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
