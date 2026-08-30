#!/bin/bash

# ============================================================
# Debian 13 Server Cleaner
# 安全交互式深度清理
# ============================================================

set -u

[[ $EUID -eq 0 ]] || {
    echo "请使用 root 运行"
    exit 1
}

KEEP_LOG_DAYS=14
TMP_DAYS=7
CACHE_DAYS=30

TMP_LIST=$(mktemp)
LOG_LIST=$(mktemp)
BACKUP_LIST=$(mktemp)
CACHE_LIST=$(mktemp)

trap 'rm -f "$TMP_LIST" "$LOG_LIST" "$BACKUP_LIST" "$CACHE_LIST"' EXIT


# ============================================================
# 工具
# ============================================================

human() {
    numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"
}

filesize() {
    stat -c '%s' "$1" 2>/dev/null || echo 0
}

sum_list() {
    local file="$1"
    local total=0
    local size

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        size=$(filesize "$f")
        total=$((total + size))
    done < "$file"

    echo "$total"
}

count_list() {
    grep -c . "$1" 2>/dev/null || echo 0
}

free_space() {
    df -B1 / | awk 'NR==2 {print $4}'
}


# ============================================================
# 开始
# ============================================================

clear

echo
echo "============================================================"
echo "        Debian 13 服务器深度清理"
echo "============================================================"
echo
echo "主机：$(hostname)"
echo "内核：$(uname -r)"
echo

echo "当前磁盘："
df -h /

echo
echo "正在扫描服务器，请稍候..."
echo


# ============================================================
# 1. 日志扫描
# ============================================================

echo "[1/5] 扫描日志..."

# 当前日志：
# 只扫描 /var/log 普通日志文件
find /var/log -xdev -type f \
    \( \
    -name '*.log' \
    -o -name 'syslog' \
    -o -name 'auth.log' \
    -o -name 'kern.log' \
    -o -name 'daemon.log' \
    -o -name 'messages' \
    -o -name 'debug' \
    -o -name 'mail.log' \
    \) \
    -print 2>/dev/null |
sort -u > "$LOG_LIST"

# 已轮转日志也加入
find /var/log -xdev -type f \
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
    -mtime +"$KEEP_LOG_DAYS" \
    -print 2>/dev/null >> "$LOG_LIST"

sort -u "$LOG_LIST" -o "$LOG_LIST"


# ============================================================
# 2. 备份扫描
# ============================================================

echo "[2/5] 扫描备份..."

for DIR in \
    /backup \
    /backups \
    /var/backups \
    /root \
    /home \
    /var/www \
    /srv \
    /opt
do

    [[ -d "$DIR" ]] || continue

    find "$DIR" -xdev -type f \
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
        -iname '*.dump' \
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

echo "[3/5] 扫描临时文件..."

for DIR in /tmp /var/tmp; do

    [[ -d "$DIR" ]] || continue

    find "$DIR" -xdev -type f \
        -mtime +"$TMP_DAYS" \
        -print 2>/dev/null >> "$TMP_LIST"

done

sort -u "$TMP_LIST" -o "$TMP_LIST"


# ============================================================
# 4. 缓存
# ============================================================

echo "[4/5] 扫描用户缓存..."

for DIR in /root /home/*; do

    [[ -d "$DIR/.cache" ]] || continue

    find "$DIR/.cache" -xdev -type f \
        -mtime +"$CACHE_DAYS" \
        -print 2>/dev/null >> "$CACHE_LIST"

done

sort -u "$CACHE_LIST" -o "$CACHE_LIST"


# ============================================================
# 5. 统计
# ============================================================

echo "[5/5] 统计空间..."
echo


LOG_COUNT=$(count_list "$LOG_LIST")
LOG_SIZE=$(sum_list "$LOG_LIST")

BACKUP_COUNT=$(count_list "$BACKUP_LIST")
BACKUP_SIZE=$(sum_list "$BACKUP_LIST")

TMP_COUNT=$(count_list "$TMP_LIST")
TMP_SIZE=$(sum_list "$TMP_LIST")

CACHE_COUNT=$(count_list "$CACHE_LIST")
CACHE_SIZE=$(sum_list "$CACHE_LIST")


# ============================================================
# Docker
# ============================================================

DOCKER_RECLAIM=0

if command -v docker >/dev/null 2>&1; then

    DOCKER_INFO=$(docker system df 2>/dev/null || true)

    echo "Docker 当前占用："
    echo "$DOCKER_INFO"
    echo

    # Docker prune dry-run 不可靠，所以这里只显示 system df。
    # 实际 prune 后通过 df 精确计算释放空间。

fi


# ============================================================
# Journal
# ============================================================

JOURNAL_SIZE=0

if command -v journalctl >/dev/null 2>&1; then

    JOURNAL_TEXT=$(journalctl --disk-usage 2>/dev/null || true)

    echo "Journal："
    echo "$JOURNAL_TEXT"
    echo

fi


# ============================================================
# 扫描结果
# ============================================================

TOTAL=$((LOG_SIZE + BACKUP_SIZE + TMP_SIZE + CACHE_SIZE))

echo "============================================================"
echo "                    扫描结果"
echo "============================================================"
echo

printf "日志文件        : %8s 个   %10s\n" \
    "$LOG_COUNT" "$(human "$LOG_SIZE")"

printf "备份文件        : %8s 个   %10s\n" \
    "$BACKUP_COUNT" "$(human "$BACKUP_SIZE")"

printf "临时文件        : %8s 个   %10s\n" \
    "$TMP_COUNT" "$(human "$TMP_SIZE")"

printf "用户缓存        : %8s 个   %10s\n" \
    "$CACHE_COUNT" "$(human "$CACHE_SIZE")"

echo
echo "----------------------------------------------"
printf "扫描到的文件    : %8s 个\n" \
    "$((LOG_COUNT + BACKUP_COUNT + TMP_COUNT + CACHE_COUNT))"

printf "文件预计可释放  : %10s\n" \
    "$(human "$TOTAL")"

echo "----------------------------------------------"
echo


# ============================================================
# 日志详细情况
# ============================================================

if [[ "$LOG_COUNT" -gt 0 ]]; then

    echo "日志占用最大的文件："

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        printf "%s %s\n" "$(filesize "$f")" "$f"
    done < "$LOG_LIST" |
    sort -nr |
    head -20 |
    while read -r size file; do
        printf "%10s  %s\n" "$(human "$size")" "$file"
    done

    echo

fi


# ============================================================
# 备份详细情况
# ============================================================

if [[ "$BACKUP_COUNT" -gt 0 ]]; then

    echo "备份占用最大的文件："

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        printf "%s %s\n" "$(filesize "$f")" "$f"
    done < "$BACKUP_LIST" |
    sort -nr |
    head -20 |
    while read -r size file; do
        printf "%10s  %s\n" "$(human "$size")" "$file"
    done

    echo

fi


# ============================================================
# 确认
# ============================================================

echo "============================================================"
echo "                    清理确认"
echo "============================================================"
echo

echo "准备清理："
echo "  [1] 旧/当前日志"
echo "  [2] 备份文件"
echo "  [3] 临时文件"
echo "  [4] 用户缓存"
echo "  [5] APT 缓存"
echo "  [6] Journal"
echo "  [7] Docker 未使用资源"
echo

echo "保护："
echo "  ✓ 不删除数据库数据目录"
echo "  ✓ 不删除网站目录本身"
echo "  ✓ 不删除当前运行内核"
echo "  ✓ 不停止正在运行的 Docker 容器"
echo "  ✓ 正在使用的日志不 rm，使用 truncate"
echo "  ✓ 正在被进程打开的备份文件跳过"
echo

read -rp "确认开始清理？输入 YES： " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo
    echo "已取消，没有执行清理。"
    exit 0
fi


# ============================================================
# 清理前空间
# ============================================================

BEFORE=$(free_space)

echo
echo "============================================================"
echo "                    开始清理"
echo "============================================================"
echo


# ============================================================
# 日志
# ============================================================

echo "[1] 清理日志..."

# 当前日志：truncate，不删除
while IFS= read -r f; do

    [[ -f "$f" ]] || continue

    # 判断是否正在使用
    if command -v lsof >/dev/null 2>&1 &&
       lsof "$f" >/dev/null 2>&1; then

        echo "  清空正在使用的日志：$f"
        truncate -s 0 "$f" 2>/dev/null || true

    fi

done < "$LOG_LIST"


# 删除已经轮转的旧日志
while IFS= read -r f; do

    [[ -f "$f" ]] || continue

    case "$f" in
        *.gz|*.xz|*.bz2|*.zst|*.old|*.1|*.2|*.3|*.4|*.5|*.6|*.7|*.8|*.9)

            if ! command -v lsof >/dev/null 2>&1 ||
               ! lsof "$f" >/dev/null 2>&1; then

                rm -f -- "$f" 2>/dev/null || true

            else

                echo "  跳过正在使用：$f"

            fi

            ;;

    esac

done < "$LOG_LIST"


# ============================================================
# 备份
# ============================================================

echo "[2] 清理备份..."

while IFS= read -r f; do

    [[ -f "$f" ]] || continue

    if command -v lsof >/dev/null 2>&1 &&
       lsof "$f" >/dev/null 2>&1; then

        echo "  跳过正在使用：$f"

    else

        echo "  删除：$f"
        rm -f -- "$f" 2>/dev/null || true

    fi

done < "$BACKUP_LIST"


# ============================================================
# 临时文件
# ============================================================

echo "[3] 清理临时文件..."

while IFS= read -r f; do

    [[ -f "$f" ]] || continue

    if ! command -v lsof >/dev/null 2>&1 ||
       ! lsof "$f" >/dev/null 2>&1; then

        rm -f -- "$f" 2>/dev/null || true

    fi

done < "$TMP_LIST"


# ============================================================
# Cache
# ============================================================

echo "[4] 清理用户缓存..."

while IFS= read -r f; do

    [[ -f "$f" ]] || continue

    if ! command -v lsof >/dev/null 2>&1 ||
       ! lsof "$f" >/dev/null 2>&1; then

        rm -f -- "$f" 2>/dev/null || true

    fi

done < "$CACHE_LIST"


# ============================================================
# APT
# ============================================================

echo "[5] 清理 APT..."

apt-get autoremove -y
apt-get autoclean -y
apt-get clean


# ============================================================
# Journal
# ============================================================

echo "[6] 清理 Journal..."

journalctl --vacuum-time="${KEEP_LOG_DAYS}d"
journalctl --vacuum-size=500M


# ============================================================
# Docker
# ============================================================

if command -v docker >/dev/null 2>&1; then

    echo "[7] 清理 Docker 未使用资源..."

    docker container prune -f
    docker image prune -f
    docker network prune -f
    docker builder prune -f

fi


# ============================================================
# systemd tmpfiles
# ============================================================

echo "[8] 清理 systemd 临时文件..."

systemd-tmpfiles --clean 2>/dev/null || true


# ============================================================
# 最终统计
# ============================================================

AFTER=$(free_space)

RELEASED=$((AFTER - BEFORE))

echo
echo "============================================================"
echo "                    清理完成"
echo "============================================================"
echo

if (( RELEASED > 0 )); then

    echo "实际释放空间：$(human "$RELEASED")"

elif (( RELEASED < 0 )); then

    echo "磁盘空间变化：增加使用 $(
        human "$((-RELEASED))"
    )"

else

    echo "实际释放空间：0B"

fi

echo
echo "清理后磁盘："
df -h /

echo
echo "Journal："
journalctl --disk-usage 2>/dev/null || true

echo

if command -v docker >/dev/null 2>&1; then
    echo "Docker："
    docker system df 2>/dev/null || true
    echo
fi

echo "============================================================"
echo "完成"
echo "============================================================"
