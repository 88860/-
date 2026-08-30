#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限运行此脚本"
  exit 1
fi

echo "======================================="
echo "   ☠️  警告: 开启终极暴力清理模式 ☠️"
echo "======================================="

sync
USED_BEFORE=$(df -k / | awk 'NR==2 {print $3}')
SCAN_LOGS=0; DEL_LOGS=0; SCAN_FILES=0; DEL_FILES=0

# =========================================================
# 顺序大调整：把会触发系统钩子的 APT 清理放在绝对的【第一步】
# =========================================================
echo "[1/6] 📦 第一步：深度清理 APT 缓存和无用依赖..."
APT_SCAN=$(find /var/cache/apt/archives -type f 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + APT_SCAN))
DEL_FILES=$((DEL_FILES + APT_SCAN))
# 这一步可能会重新生成 vmlinuz.old，也会产生新的日志
apt-get autoremove --purge -y -q >/dev/null 2>&1
apt-get clean -y -q >/dev/null 2>&1
rm -rf /var/cache/apt/archives/* 2>/dev/null

# ---------------------------------------------------------
echo "[2/6] 💣 第二步：强制清除 vmlinuz.old, initrd.img.old 等文件..."
# 现在再删，系统就不会自动重建了
K_SCAN=$(find / /boot -maxdepth 1 -name "*.old" 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + K_SCAN))
DEL_FILES=$((DEL_FILES + K_SCAN))
find / /boot -maxdepth 1 -name "*.old" -exec rm -f {} + 2>/dev/null
rm -f /vmlinuz.old /initrd.img.old /boot/vmlinuz.old /boot/initrd.img.old 2>/dev/null
rm -f /vmlinuz-*.old /initrd.img-*.old /boot/vmlinuz-*.old /boot/initrd.img-*.old 2>/dev/null

# ---------------------------------------------------------
echo "[3/6] 🧹 第三步：深度清空 /tmp 和 /var/tmp..."
T_SCAN=$(find /tmp /var/tmp /var/crash -type f 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + T_SCAN))
DEL_FILES=$((DEL_FILES + T_SCAN))
rm -rf /tmp/* /var/tmp/* /var/crash/* 2>/dev/null

# ---------------------------------------------------------
echo "[4/6] 🖼️ 第四步：暴力清空全用户的 Cache 与回收站..."
for d in /home/* /root; do
  if [ -d "$d" ]; then
    C_SCAN=$(find "$d/.cache" "$d/.local/share/Trash" -type f 2>/dev/null | wc -l)
    SCAN_FILES=$((SCAN_FILES + C_SCAN))
    DEL_FILES=$((DEL_FILES + C_SCAN))
    rm -rf "$d/.cache/"* 2>/dev/null
    rm -rf "$d/.local/share/Trash/"* 2>/dev/null
  fi
done

# ---------------------------------------------------------
echo "[5/6] ♻️ 第五步：全局清理常见垃圾备份 (*~, *.swp, *.bak)..."
B_SCAN=$(find /var /home /etc -type f \( -name "*~" -o -name "*.swp" -o -name "*.bak" \) 2>/dev/null | wc -l)
SCAN_FILES=$((SCAN_FILES + B_SCAN))
DEL_FILES=$((DEL_FILES + B_SCAN))
find /var /home /etc -type f \( -name "*~" -o -name "*.swp" -o -name "*.bak" \) -delete 2>/dev/null

# ---------------------------------------------------------
# 日志清理必须放在最后一步，因为上面 apt 卸载内核时会生成大量的 dpkg 日志
# ---------------------------------------------------------
echo "[6/6] 💀 第六步：扫描并暴力清空所有日志文件..."
SCAN_LOGS=$(find /var/log -type f 2>/dev/null | wc -l)
find /var/log -type f \( -name "*.gz" -o -regex ".*\.[0-9]$" -o -name "*.old" \) -delete 2>/dev/null
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null
rm -rf /var/log/journal/* 2>/dev/null
systemctl restart systemd-journald 2>/dev/null
DEL_LOGS=$SCAN_LOGS

# =========================================================
sync
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
echo -e "🗑️ 彻底删除的文件数:\t$DEL_FILES 个"
echo -e "📓 扫描到的日志文件:\t$SCAN_LOGS 个"
echo -e "🗑️ 清空/删除的日志数:\t$DEL_LOGS 个"
echo -e "💾 此次暴力释放空间:\t$FREED_MB MB"
echo "======================================="
