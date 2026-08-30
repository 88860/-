#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限运行此脚本 (sudo ./cleanup.sh)"
  exit 1
fi

echo "======================================="
echo "    🚀 正在执行系统深度清理与扫描..."
echo "======================================="

# 同步磁盘并获取清理前的已用空间 (KB)
sync
USED_BEFORE=$(df -k / | awk 'NR==2 {print $3}')

# 初始化统计变量
SCAN_LOGS=0
DEL_LOGS=0
SCAN_FILES=0
DEL_FILES=0

# ---------------------------------------------------------
# 1. 清理系统日志
# ---------------------------------------------------------
echo "[1/6] 📓 扫描并清理系统日志..."
# 统计 /var/log 下的所有日志文件
SCAN_LOGS=$(find /var/log -type f 2>/dev/null | wc -l)
# 统计并删除归档日志
DEL_LOGS=$(find /var/log -type f \( -name "*.gz" -o -name "*.1" \) 2>/dev/null | wc -l)
find /var/log -type f \( -name "*.gz" -o -name "*.1" \) -delete 2>/dev/null

# 处理 systemd journal (对比清理前后的文件数变化)
J_BEFORE=$(find /var/log/journal -type f 2>/dev/null | wc -l)
journalctl --vacuum-time=7d --quiet >/dev/null 2>&1
J_AFTER=$(find /var/log/journal -type f 2>/dev/null | wc -l)
DEL_LOGS=$((DEL_LOGS + (J_BEFORE - J_AFTER)))

# ---------------------------------------------------------
# 2. 清理旧内核软链接 (.old)
# ---------------------------------------------------------
echo "[2/6] 🐧 扫描并清理旧内核备份文件..."
# 扫描根目录和 /boot 下的文件和链接
K_SCAN=$(find / /boot -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + K_SCAN))

# 统计并删除指定的旧内核链接
K_DEL=$(find / /boot -maxdepth 1 -type l \( -name "vmlinuz.old" -o -name "initrd.img.old" \) 2>/dev/null | wc -l)
DEL_FILES=$((DEL_FILES + K_DEL))
find / /boot -maxdepth 1 -type l \( -name "vmlinuz.old" -o -name "initrd.img.old" \) -delete 2>/dev/null

# ---------------------------------------------------------
# 3. 清理系统临时文件
# ---------------------------------------------------------
echo "[3/6] 🧹 扫描并清理系统临时文件..."
T_SCAN=$(find /tmp /var/tmp /var/crash -type f 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + T_SCAN))

T_DEL=$(find /tmp /var/tmp /var/crash -type f -mtime +1 2>/dev/null | wc -l)
DEL_FILES=$((DEL_FILES + T_DEL))
find /tmp /var/tmp /var/crash -type f -mtime +1 -delete 2>/dev/null

# ---------------------------------------------------------
# 4. 清理 APT 包管理缓存
# ---------------------------------------------------------
echo "[4/6] 📦 扫描并清理 APT 缓存和无用依赖..."
APT_SCAN=$(find /var/cache/apt/archives -type f 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + APT_SCAN))

# 静默执行 apt 清理
apt-get autoremove --purge -y -q >/dev/null 2>&1
apt-get clean -y -q >/dev/null 2>&1

APT_AFTER=$(find /var/cache/apt/archives -type f 2>/dev/null | wc -l)
DEL_FILES=$((DEL_FILES + (APT_SCAN - APT_AFTER)))

# ---------------------------------------------------------
# 5. 清理用户缓存和回收站
# ---------------------------------------------------------
echo "[5/6] 🖼️ 扫描并清理缩略图与回收站..."
for d in /home/* /root; do
  if [ -d "$d/.cache/thumbnails" ]; then
    C_SCAN=$(find "$d/.cache/thumbnails" -type f 2>/dev/null | wc -l)
    SCAN_FILES=$((SCAN_FILES + C_SCAN))
    DEL_FILES=$((DEL_FILES + C_SCAN))
    rm -rf "$d/.cache/thumbnails/"*
  fi
  if [ -d "$d/.local/share/Trash" ]; then
    TR_SCAN=$(find "$d/.local/share/Trash" -type f 2>/dev/null | wc -l)
    SCAN_FILES=$((SCAN_FILES + TR_SCAN))
    DEL_FILES=$((DEL_FILES + TR_SCAN))
    rm -rf "$d/.local/share/Trash/"*
  fi
done

# ---------------------------------------------------------
# 6. 清理临时备份垃圾文件 (*~, *.swp)
# ---------------------------------------------------------
echo "[6/6] ♻️ 扫描并清理文本备份文件..."
B_SCAN=$(find /var /home -type f \( -name "*~" -o -name "*.swp" -o -name "*.bak" \) 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + B_SCAN))
DEL_FILES=$((DEL_FILES + B_SCAN))
find /var /home -type f \( -name "*~" -o -name "*.swp" -o -name "*.bak" \) -delete 2>/dev/null

# ---------------------------------------------------------
# 计算并输出结果
# ---------------------------------------------------------
sync
USED_AFTER=$(df -k / | awk 'NR==2 {print $3}')
FREED_KB=$((USED_BEFORE - USED_AFTER))

# 避免因为系统后台写入导致出现负数
if [ "$FREED_KB" -lt 0 ]; then
    FREED_KB=0
fi

FREED_MB=$(echo "scale=2; $FREED_KB / 1024" | bc 2>/dev/null || echo $((FREED_KB / 1024)))

echo ""
echo "======================================="
echo "             ✨ 清理统计报告 ✨             "
echo "======================================="
echo -e "📄 目标文件扫描数:\t$SCAN_FILES 个"
echo -e "🗑️ 普通文件删除数:\t$DEL_FILES 个 (含包缓存、旧内核链接、备份等)"
echo -e "📓 目标日志扫描数:\t$SCAN_LOGS 个"
echo -e "🗑️ 历史日志删除数:\t$DEL_LOGS 个"
echo -e "💾 此次共释放空间:\t$FREED_MB MB"
echo "======================================="
