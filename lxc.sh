#!/bin/sh

set -e


echo "=== LXC Alpine Latest Installer ==="


# root检查

if [ "$(id -u)" != "0" ]; then
    echo "请使用root运行"
    exit 1
fi


# 检查LXC

if ! grep -qaE "lxc|openvz" /proc/1/environ /proc/self/status 2>/dev/null; then
    echo "警告: 可能不是LXC/OpenVZ环境"
fi


ARCH=$(uname -m)

case $ARCH in

x86_64)
    ALPINE_ARCH="x86_64"
;;

aarch64)
    ALPINE_ARCH="aarch64"
;;

*)
    echo "不支持架构:$ARCH"
    exit 1
;;

esac



echo "架构:$ALPINE_ARCH"


# 获取最新版本

VERSION=$(wget -qO- \
https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$ALPINE_ARCH/latest-releases.yaml \
| grep version \
| head -1 \
| awk '{print $2}')


echo "Alpine版本:$VERSION"



URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$ALPINE_ARCH/alpine-minirootfs-$VERSION-$ALPINE_ARCH.tar.gz"


echo "下载:"
echo $URL



mkdir -p /alpine-new

cd /alpine-new


wget -O alpine.tar.gz "$URL"


echo "解压..."

tar xzf alpine.tar.gz



echo "复制系统..."

# 保留SSH

cp -a /etc/ssh /tmp/ssh-backup 2>/dev/null || true


# 清理旧系统

find / \
-mindepth 1 \
-maxdepth 1 \
-not -name alpine-new \
-exec rm -rf {} \;



cp -a /alpine-new/* /



# 恢复SSH

mkdir -p /etc/ssh

cp -a /tmp/ssh-backup/* /etc/ssh 2>/dev/null || true



# 初始化

setup-timezone -z Asia/Shanghai 2>/dev/null || true


# 设置root密码

echo "请输入新的root密码"

passwd root



# SSH启动

rc-update add sshd default 2>/dev/null || true


echo

echo "=========================="

echo " Alpine安装完成"

echo "版本:$VERSION"

echo "请重启"

echo "=========================="


reboot
