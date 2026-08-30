#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限运行此脚本 (sudo ./cleanup.sh)"
  exit 1
fi

echo "======================================="
echo "   ☠️  警告: 开启终极暴力清理模式 ☠️"
echo "======================================="

# 同步磁盘并获取清理前的已用空间 (KB)
sync
USED_BEFORE=$(df -k / | awk 'NR==2 {print $3}')

SCAN_LOGS=0
DEL_LOGS=0
SCAN_FILES=0
DEL_FILES=0

# ---------------------------------------------------------
# 1. 暴力清空所有系统日志
# ---------------------------------------------------------
echo "[1/6] 💀 扫描并暴力清空所有日志文件..."
# 统计 /var/log 下的所有日志文件数量
SCAN_LOGS=$(find /var/log -type f 2>/dev/null | wc -l)

# 直接删除所有压缩包(.gz)和历史轮转日志(.1, .2, .old)
find /var/log -type f \( -name "*.gz" -o -regex ".*\.[0-9]$" -o -name "*.old" \) -delete 2>/dev/null

# 对于正在使用的存活日志，暴力截断（清空内容但保留空文件，防止系统服务报错）
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null

# 暴力摧毁 systemd 的底层日志并重启日志服务
rm -rf /var/log/journal/* 2>/dev/null
systemctl restart systemd-journald 2>/dev/null

# 因为是全清空，所以处理的日志数等于扫描到的日志数
DEL_LOGS=$SCAN_LOGS

# ---------------------------------------------------------
# 2. 暴力删除旧内核与各种 .old 备份
# ---------------------------------------------------------
echo "[2/6] 💣 强制清除 vmlinuz.old, initrd.img.old 等文件..."
# 不管是文件还是软链接，只要在 / 或 /boot 下以 .old 结尾全部锁定
K_SCAN=$(find / /boot -maxdepth 1 -name "*.old" 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + K_SCAN))
DEL_FILES=$((DEL_FILES + K_SCAN))

# 暴力删除查找出的 .old 文件
find / /boot -maxdepth 1 -name "*.old" -exec rm -f {} + 2>/dev/null
# 额外兜底，硬编码指定强制删除，防止任何遗漏
rm -f /vmlinuz.old /initrd.img.old /boot/vmlinuz.old /boot/initrd.img.old 2>/dev/null
rm -f /vmlinuz-*.old /initrd.img-*.old /boot/vmlinuz-*.old /boot/initrd.img-*.old 2>/dev/null

# ---------------------------------------------------------
# 3. 无视时间，暴力清空所有临时文件
# ---------------------------------------------------------
echo "[3/6] 🧹 深度清空 /tmp 和 /var/tmp..."
T_SCAN=$(find /tmp /var/tmp /var/crash -type f 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + T_SCAN))
DEL_FILES=$((DEL_FILES + T_SCAN))
# 不再保留最近 1 天的文件，直接全部干掉
rm -rf /tmp/* /var/tmp/* /var/crash/* 2>/dev/null

# ---------------------------------------------------------
# 4. 暴力清理 APT 缓存
# ---------------------------------------------------------
echo "[4/6] 📦 清理所有 APT 缓存和无用依赖..."
APT_SCAN=$(find /var/cache/apt/archives -type f 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + APT_SCAN))
DEL_FILES=$((DEL_FILES + APT_SCAN))
apt-get autoremove --purge -y -q >/dev/null 2>&1
apt-get clean -y -q >/dev/null 2>&1
# 强制清空 APT 缓存目录兜底
rm -rf /var/cache/apt/archives/* 2>/dev/null

# ---------------------------------------------------------
# 5. 暴力清理所有用户的缓存与回收站
# ---------------------------------------------------------
echo "[5/6] 🖼️ 暴力清空全用户的 Cache 与回收站..."
for d in /home/* /root; do
  if [ -d "$d" ]; then
    C_SCAN=$(find "$d/.cache" "$d/.local/share/Trash" -type f 2>/dev/null | wc -l)
    SCAN_FILES=$((SCAN_FILES + C_SCAN))
    DEL_FILES=$((DEL_FILES + C_SCAN))
    # 暴力清空缓存（包含缩略图、应用缓存等所有东西）
    rm -rf "$d/.cache/"* 2>/dev/null
    rm -rf "$d/.local/share/Trash/"* 2>/dev/null
  fi
done

# ---------------------------------------------------------
# 6. 清理各种临时和备份文件
# ---------------------------------------------------------
echo "[6/6] ♻️ 全局清理常见垃圾备份 (*~, *.swp, *.bak)..."
B_SCAN=$(find /var /home /etc -type f \( -name "*~" -o -name "*.swp" -o -name "*.bak" \) 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + B_SCAN))
DEL_FILES=$((DEL_FILES + B_SCAN))
find /var /home /etc -type f \( -name "*~" -o -name "*.swp" -o -name "*.bak" \) -delete 2>/dev/null

# ---------------------------------------------------------
# 计算并输出结果
# ---------------------------------------------------------
# 确保所有写入操作完成
sync
# 休眠 1 秒给系统一点时间更新磁盘统计信息
sleep 1
USED_AFTER=$(df -k / | awk 'NR==2 {print $3}')
FREED_KB=$((USED_BEFORE - USED_AFTER))

if [ "$FREED_KB" -lt 0 ]; then
    FREED_KB=0
fi

FREED_MB=$(echo "scale=2; $FREED_KB / 1024" | bc 2>/dev/null || echo $((FREED_KB / 1024)))

echo ""
echo "======================================="
echo "            ☠️  暴力清理统计报告 ☠️             "
echo "======================================="
echo -e "📄 扫描到的目标文件:\t$SCAN_FILES 个"
echo -e "🗑️ 彻底删除的文件数:\t$DEL_FILES 个 (含包缓存、旧内核、临时文件等)"
echo -e "📓 扫描到的日志文件:\t$SCAN_LOGS 个"
echo -e "🗑️ 清空/删除的日志数:\t$DEL_LOGS 个"
echo -e "💾 此次暴力释放空间:\t$FREED_MB MB"
echo "======================================="
