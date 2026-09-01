#!/bin/bash
set -e

echo "正在获取 CloudPassenger 最新内核版本..."
LATEST_TAG=$(curl -s https://api.github.com/repos/CloudPassenger/Cloud-Kernel-BBRv3/releases \
  | grep -o '"tag_name": "[^"]*"' | head -n 1 | cut -d '"' -f 4)

if [ -z "$LATEST_TAG" ]; then
  echo "获取版本失败，请检查网络"
  exit 1
fi
echo "成功匹配到最新版: $LATEST_TAG"

# 提取 arm64 架构的 image 和 headers 下载链接
IMAGE_URL=$(curl -s "https://api.github.com/repos/CloudPassenger/Cloud-Kernel-BBRv3/releases/tags/$LATEST_TAG" \
  | grep -o '"browser_download_url": "[^"]*linux-image[^"]*arm64\.deb"' | cut -d '"' -f 4)

HEADERS_URL=$(curl -s "https://api.github.com/repos/CloudPassenger/Cloud-Kernel-BBRv3/releases/tags/$LATEST_TAG" \
  | grep -o '"browser_download_url": "[^"]*linux-headers[^"]*arm64\.deb"' | cut -d '"' -f 4)

# 创建临时目录并下载
WORKDIR=/tmp/cloud-kernel-install
mkdir -p "$WORKDIR" && cd "$WORKDIR"

curl -L -o linux-image.deb "https://ghproxy.net/$IMAGE_URL"
curl -L -o linux-headers.deb "https://ghproxy.net/$HEADERS_URL"

# 安装内核包
apt install -y ./*.deb

# 更新引导
update-grub

# 清理临时目录
cd ~ && rm -rf "$WORKDIR"

echo -e "\n=== 内核替换完成！安装包已销毁无残留。请手动执行 reboot 重启系统使 BBRv3 生效 ==="
