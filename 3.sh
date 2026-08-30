#!/bin/bash
# Debian 13 Server Deep Cleaner
# 用法: sudo bash clean.sh

set -u

[[ $EUID -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }

KEEP_DAYS=14
LOG_DAYS=30
TMP_DAYS=7
CACHE_DAYS=30
DRY_RUN=0

# ---------- 工具 ----------
size_bytes() {
    du -sxB1 "$1" 2>/dev/null | awk '{print $1}'
}

human() {
    numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"
}

free_space() {
    df -B1 / | awk 'NR==2 {print $4}'
}

# ---------- 临时清单 ----------
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

add_file() {
    local f="$1"
    [[ -f "$f" ]] || return
    printf '%s\n' "$f" >> "$LIST"
}

add_find() {
    local dir="$1"
    shift
    [[ -d "$dir" ]] || return
    find "$dir" -xdev -type f "$@" -print 2>/dev/null >> "$LIST"
}

# ============================================================
# 扫描
# ============================================================

echo
echo "================================================"
echo " Debian 13 服务器深度清理"
echo "================================================"
echo
echo "正在扫描，请稍候..."
echo

# ---------- 日志 ----------
add_find /var/log \
    -mtime +"$LOG_DAYS" \
    \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' \
       -o -name '*.zst' -o -name '*.old' \
       -o -name '*.1' -o -name '*.2' -o -name '*.3' \
       -o -name '*.4' -o -name '*.5' -o -name '*.6' \
       -o -name '*.7' -o -name '*.8' -o -name '*.9' \)

# ---------- 临时 ----------
add_find /tmp \
    -mtime +"$TMP_DAYS"

add_find /var/tmp \
    -mtime +"$TMP_DAYS"

# ---------- 用户缓存 ----------
for d in /root /home/*; do
    [[ -d "$d/.cache" ]] || continue
    add_find "$d/.cache" -mtime +"$CACHE_DAYS"
done

# ---------- Trash ----------
for d in /root /home/*; do
    [[ -d "$d/.local/share/Trash" ]] || continue
    add_find "$d/.local/share/Trash" -mtime +"$CACHE_DAYS"
done

# ---------- Crash/Core ----------
add_find /var/crash -mtime +"$TMP_DAYS"
add_find /var/lib/systemd/coredump -mtime +"$TMP_DAYS"

# ---------- 常见备份 ----------
# root / home / 网站 / srv / opt / var/backups
for d in /root /home /var/www /srv /opt /backup /backups /var/backups; do
    [[ -d "$d" ]] || continue

    find "$d" -xdev -type f \
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
        -o -iname '*backup*' \
        \) \
        -print 2>/dev/null >> "$LIST"
done

# ---------- 编辑器垃圾 ----------
for d in /root /home; do
    [[ -d "$d" ]] || continue
    add_find "$d" -mtime +"$CACHE_DAYS" \
        \( -name '*~' -o -name '*.swp' -o -name '*.swo' -o -name '*.tmp' \)
done

# 去重
sort -u "$LIST" -o "$LIST"

# ============================================================
# 分类显示
# ============================================================

TOTAL=0
COUNT=0

echo "------------------------------------------------"
echo "扫描结果"
echo "------------------------------------------------"

if [[ ! -s "$LIST" ]]; then
    echo "没有发现符合条件的文件。"
else

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue

        s=$(stat -c%s "$f" 2>/dev/null || echo 0)
        TOTAL=$((TOTAL+s))
        COUNT=$((COUNT+1))

    done < "$LIST"

    echo "发现文件：$COUNT 个"
    echo "预计可清理：$(human "$TOTAL")"
    echo

    echo "文件列表（最大 200 个）："
    echo "------------------------------------------------"

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        printf '%s  %s\n' \
            "$(human "$(stat -c%s "$f" 2>/dev/null || echo 0)")" \
            "$f"
    done < <(
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            stat -c '%s %n' "$f" 2>/dev/null
        done < "$LIST" |
        sort -nr |
        head -200 |
        cut -d' ' -f2-
    )

    [[ "$COUNT" -gt 200 ]] && \
        echo "...还有 $((COUNT-200)) 个文件未展开显示。"
fi

# ============================================================
# 系统级可清理项目
# ============================================================

echo
echo "------------------------------------------------"
echo "其他可清理资源"
echo "------------------------------------------------"

echo "APT 缓存："
apt-get clean -s 2>/dev/null | tail -5 || true

echo
echo "Journal："
journalctl --disk-usage 2>/dev/null || true

echo
if command -v docker >/dev/null 2>&1; then
    echo "Docker："
    docker system df 2>/dev/null || true
fi

# ============================================================
# 没有东西
# ============================================================

if [[ "$COUNT" -eq 0 ]]; then
    echo
    echo "文件扫描没有发现可清理项目。"
    echo "仍可清理 APT / Journal / Docker 等缓存。"
fi

# ============================================================
# 确认
# ============================================================

echo
echo "================================================"
echo " 删除确认"
echo "================================================"

echo
echo "将执行："
echo "  • 清理 APT 缓存"
echo "  • 清理旧 Journal"
echo "  • 清理旧轮转日志"
echo "  • 清理 /tmp /var/tmp"
echo "  • 清理用户缓存"
echo "  • 清理 Trash"
echo "  • 清理 Core/Crash"
echo "  • 删除扫描到的备份文件"
echo "  • 清理 Docker 未使用资源（如存在）"
echo
echo "不会删除："
echo "  • 当前运行内核"
echo "  • MySQL/PostgreSQL/Redis 数据目录"
echo "  • 正在运行的 Docker 容器"
echo "  • /etc 配置"
echo "  • 正在被进程打开的文件"
echo

read -rp "确定继续？输入 YES 才会删除： " ANSWER

[[ "$ANSWER" == "YES" ]] || {
    echo
    echo "已取消，没有删除任何文件。"
    exit 0
}

# ============================================================
# 开始清理
# ============================================================

BEFORE=$(free_space)

echo
echo "================================================"
echo " 开始清理"
echo "================================================"

# ---------- APT ----------
echo "[1] APT..."
apt-get autoremove -y
apt-get autoclean -y
apt-get clean

# ---------- Journal ----------
echo "[2] Journal..."
journalctl --vacuum-time="${KEEP_DAYS}d"
journalctl --vacuum-size=500M

# ---------- 文件 ----------
echo "[3] 删除扫描文件..."

DELETED=0
SKIPPED=0

while IFS= read -r f; do

    [[ -f "$f" ]] || continue

    # 防止删除关键系统目录
    case "$f" in
        /etc/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*)
            SKIPPED=$((SKIPPED+1))
            continue
            ;;
    esac

    # 正在使用的文件跳过
    if command -v lsof >/dev/null 2>&1 &&
       lsof "$f" >/dev/null 2>&1; then

        echo "跳过（正在使用）：$f"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    rm -f -- "$f" 2>/dev/null && \
        DELETED=$((DELETED+1))

done < "$LIST"

# ---------- Docker ----------
if command -v docker >/dev/null 2>&1; then
    echo "[4] Docker 未使用资源..."
    docker container prune -f
    docker image prune -f
    docker network prune -f
    docker builder prune -f
fi

# ---------- Podman ----------
if command -v podman >/dev/null 2>&1; then
    echo "[5] Podman 未使用资源..."
    podman system prune -f
fi

# ---------- Flatpak ----------
if command -v flatpak >/dev/null 2>&1; then
    echo "[6] Flatpak..."
    flatpak uninstall --unused -y 2>/dev/null || true
fi

# ---------- tmpfiles ----------
if command -v systemd-tmpfiles >/dev/null 2>&1; then
    echo "[7] systemd tmpfiles..."
    systemd-tmpfiles --clean
fi

# ---------- 旧内核 ----------
echo "[8] 检查旧内核..."
apt-get autoremove --purge -y

# ============================================================
# 最终统计
# ============================================================

AFTER=$(free_space)

# 注意：如果清理过程中其他服务写入磁盘，
# 释放空间计算可能受到影响。
RELEASED=$((AFTER-BEFORE))

echo
echo "================================================"
echo " 清理完成"
echo "================================================"

echo
echo "删除文件：$DELETED 个"
echo "跳过文件：$SKIPPED 个"

if (( RELEASED > 0 )); then
    echo "实际释放空间：$(human "$RELEASED")"
else
    echo "实际释放空间：0B"
fi

echo
echo "磁盘状态："
df -h /

echo
echo "Journal："
journalctl --disk-usage 2>/dev/null || true

echo
if command -v docker >/dev/null 2>&1; then
    echo "Docker："
    docker system df 2>/dev/null || true
fi

echo
echo "完成。"
