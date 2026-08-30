#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 只有 root 才有权限执行全盘绞杀。"
  exit 1
fi

echo "====================================================="
echo "   ☢️  警告: 已启动【核武级】全盘扫描与暴力清理 ☢️   "
echo "====================================================="
echo "⚠️ 这将扫描整块硬盘，耗时取决于硬盘大小和文件数量..."

sync
USED_BEFORE=$(df -k / | awk 'NR==2 {print $3}')
TOTAL_FILES=0; TOTAL_LOGS=0

# 设置全局搜索时的排除目录（防止摧毁虚拟文件系统导致系统立即死机）
PRUNE="-type d \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /snap \) -prune -o"

# =========================================================
echo -n "[1/6] 📦 第一阶段: 绞杀系统底层的包管理冗余 (APT/Dpkg)..."
apt-get autoremove --purge -y -q >/dev/null 2>&1
apt-get clean -y -q >/dev/null 2>&1
rm -rf /var/cache/apt/archives/* 2>/dev/null
# 全局查找更新残留的 dpkg 和 ucf 备份配置文件并删除
PKG_DEL=$(find / $PRUNE -type f \( -name "*.dpkg-old" -o -name "*.dpkg-dist" -o -name "*.dpkg-new" -o -name "*.ucf-old" -o -name "*.ucf-dist" \) -print -delete 2>/dev/null | wc -l)
TOTAL_FILES=$((TOTAL_FILES + PKG_DEL))
echo " 完成 (销毁 $PKG_DEL 个包冗余)"

# =========================================================
echo -n "[2/6] 💣 第二阶段: 全局搜索并粉碎所有 .old, .bak, 临时文件..."
# 暴力查找并删除全局备份 (*.bak), 交换文件 (*.swp), 临时备份 (*~, *.tmp), 旧文件 (*.old)
BAK_DEL=$(find / $PRUNE -type f \( -name "*.bak" -o -name "*.swp" -o -name "*~" -o -name "*.old" -o -name "*.tmp" \) -print -delete 2>/dev/null | wc -l)
# 兜底强制干掉旧内核
rm -f /vmlinuz.old /initrd.img.old /boot/vmlinuz.old /boot/initrd.img.old 2>/dev/null
TOTAL_FILES=$((TOTAL_FILES + BAK_DEL + 4))
echo " 完成 (销毁 $BAK_DEL 个全局备份)"

# =========================================================
echo -n "[3/6] 💥 第三阶段: 剿灭全盘崩溃报告与核心转储(Core Dump)..."
CORE_DEL=$(find / $PRUNE -type f -name "core" -exec file {} \; 2>/dev/null | grep -i "core file" | awk -F: '{print $1}' | xargs -I {} rm -f {} 2>/dev/null | wc -l)
CRASH_DEL=$(find /var/crash /var/lib/systemd/coredump /var/tmp -type f -print -delete 2>/dev/null | wc -l)
TOTAL_FILES=$((TOTAL_FILES + CORE_DEL + CRASH_DEL))
echo " 完成 (销毁 $((CORE_DEL + CRASH_DEL)) 个崩溃转储)"

# =========================================================
echo -n "[4/6] 🖼️ 第四阶段: 地毯式抹除全用户的 Cache, 历史记录..."
CACHE_DEL=0
for d in /home/* /root; do
  if [ -d "$d" ]; then
    # 强制清空 .cache 和 .local/share/Trash
    C1=$(find "$d/.cache" "$d/.local/share/Trash" -type f -print -delete 2>/dev/null | wc -l)
    # 删除 bash 历史记录、vim 历史记录等
    C2=$(find "$d" -maxdepth 1 -type f \( -name ".bash_history" -o -name ".viminfo" -o -name ".wget-hsts" \) -print -delete 2>/dev/null | wc -l)
    CACHE_DEL=$((CACHE_DEL + C1 + C2))
  fi
done
# 物理毁灭 /tmp
TMP_DEL=$(find /tmp -type f -print -delete 2>/dev/null | wc -l)
TOTAL_FILES=$((TOTAL_FILES + CACHE_DEL + TMP_DEL))
echo " 完成 (销毁 $((CACHE_DEL + TMP_DEL)) 个缓存及临时文件)"

# =========================================================
echo -n "[5/6] 💀 第五阶段: 全局搜索并【截断】所有 .log 文件..."
# 在整个硬盘寻找以 .log 结尾的文件，全部暴力清空内容 (截断为0)
LOG_TRUNC=$(find / $PRUNE -type f -name "*.log" -print -exec truncate -s 0 {} \; 2>/dev/null | wc -l)
# 在整个硬盘寻找已经被轮转压缩的旧日志 (*.log.1, *.log.gz) 并彻底删除
LOG_DEL=$(find / $PRUNE -type f \( -name "*.log.*" -o -name "*.gz" \) -path "*/log/*" -print -delete 2>/dev/null | wc -l)
TOTAL_LOGS=$((LOG_TRUNC + LOG_DEL))
echo " 完成 (抽干 $LOG_TRUNC 个存活日志，摧毁 $LOG_DEL 个历史日志)"

# =========================================================
echo -n "[6/6] 📓 第六阶段: 摧毁底层 Systemd Journal 数据库..."
# 暴力清除 journal 二进制日志库
rm -rf /var/log/journal/* 2>/dev/null
systemctl restart systemd-journald 2>/dev/null
echo " 完成"

# =========================================================
sync
sleep 2
USED_AFTER=$(df -k / | awk 'NR==2 {print $3}')
FREED_KB=$((USED_BEFORE - USED_AFTER))
if [ "$FREED_KB" -lt 0 ]; then FREED_KB=0; fi
FREED_MB=$(echo "scale=2; $FREED_KB / 1024" | bc 2>/dev/null || echo $((FREED_KB / 1024)))

echo ""
echo "====================================================="
echo "               ☢️  全盘清理战损报告 ☢️               "
echo "====================================================="
echo -e "🗑️  被粉碎的垃圾/备份/旧文件总计:  $TOTAL_FILES 个"
echo -e "📓 被截断或物理摧毁的日志总计:  $TOTAL_LOGS 个"
echo -e "💾 此次全盘掠夺释放的空间:      $FREED_MB MB"
echo "====================================================="
