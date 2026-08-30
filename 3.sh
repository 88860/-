#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限运行此脚本 (例如: sudo ./cleanup.sh)"
  exit 1
fi

echo "======================================="
echo "      开始清理 Debian 系统垃圾文件      "
echo "======================================="

# 记录清理前的磁盘空间
echo -e "\n📊 清理前的磁盘空间状况:"
df -h /

# 1. 清理 APT 缓存和无用的依赖包
echo -e "\n[1/6] 📦 正在清理 APT 缓存和孤立的安装包..."
apt-get autoremove --purge -y
apt-get autoclean -y
apt-get clean -y

# 2. 清理 Systemd Journal 日志
echo -e "\n[2/6] 📓 正在清理 Systemd 日志..."
# 仅保留最近 7 天的日志
journalctl --vacuum-time=7d
# 或限制日志最大占用 50M
journalctl --vacuum-size=50M

# 3. 清理旧的系统日志文件
echo -e "\n[3/6] 🗑️ 正在清理归档的系统旧日志..."
# 删除 /var/log 目录下所有经过 gzip 压缩的日志文件 (*.gz) 和旧日志 (*.1)
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.1" -delete

# 4. 清理系统临时文件
echo -e "\n[4/6] 🧹 正在清理系统临时文件..."
# 安全起见，仅删除 1 天前修改过的临时文件，避免影响正在运行的服务
find /tmp -type f -mtime +1 -delete
find /var/tmp -type f -mtime +1 -delete
# 强制清理崩溃报告
rm -rf /var/crash/*

# 5. 清理用户的缩略图缓存和回收站
echo -e "\n[5/6] 🖼️ 正在清理所有用户的缩略图缓存和回收站..."
for user_dir in /home/*; do
    if [ -d "$user_dir/.cache/thumbnails" ]; then
        rm -rf "$user_dir/.cache/thumbnails/*"
    fi
    if [ -d "$user_dir/.local/share/Trash" ]; then
        rm -rf "$user_dir/.local/share/Trash/*"
    fi
done
# 清理 root 用户的缓存和回收站
rm -rf /root/.cache/thumbnails/* 2>/dev/null
rm -rf /root/.local/share/Trash/* 2>/dev/null

# 6. 清理各种临时备份文件 (*~, *.bak, *.swp)
echo -e "\n[6/6] ♻️ 正在清理常见的临时和备份文件..."
# 搜索并删除文本编辑器产生的波浪号备份文件 (*~) 和 vim 交换文件 (*.swp)
find /var -type f -name "*~" -exec rm -f {} \;
find /var -type f -name "*.swp" -exec rm -f {} \;
find /home -type f -name "*~" -exec rm -f {} \;

# [可选] 全局清理 .bak 备份文件 (存在误删风险，默认注释)
# 如果你确定不需要任何 .bak 文件，可以取消下面这行的注释
# find / -type f -name "*.bak" -delete

echo "======================================="
echo "          ✨ 系统清理完成！✨          "
echo "======================================="

# 记录清理后的磁盘空间
echo -e "\n📊 清理后的磁盘空间状况:"
df -h /

