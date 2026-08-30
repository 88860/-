#!/bin/bash
# debian13自用 - Debian 13 自用一键菜单
# 1 = 安装 XanMod LTS 内核并自动重启
# 2 = 一键配置
# 3 = 一键 DD 全新 Debian
set -Eeuo pipefail

SCRIPT_NAME="debian13自用"
TMP_DIR="$(mktemp -d /tmp/debian13-self.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "错误：请使用 root 运行。"
        exit 1
    fi
}

run_b64() {
    local num="$1" data="$2" file
    file="$TMP_DIR/${num}.sh"
    printf '%s' "$data" | base64 -d > "$file"
    chmod 700 "$file"
    echo
    echo "============================================================"
    echo "正在执行：$num"
    echo "============================================================"
    bash "$file"
}

install_kernel() {
    echo "============================================================"
    echo " 1. 安装 XanMod LTS 内核"
    echo "============================================================"
    echo "将执行你提供的 1换内核脚本；成功后自动重启。"
    echo
    read -r -p "确认安装内核并自动重启？[y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "已取消。"; return 0 ;;
    esac

    local file="$TMP_DIR/1.sh"
    printf '%s' "$KERNEL_B64" | base64 -d > "$file"
    chmod 700 "$file"
    bash "$file"
    echo
    echo "内核安装命令执行成功，5 秒后自动重启。"
    sleep 5
    systemctl reboot
}

run_all() {
    echo "============================================================"
    echo " 2. 一键配置"
    echo "============================================================"
    echo "注意：2 会删除旧内核/元包；3 会删除 qemu*、os-prober、"
    echo "laptop-detect、pciutils、dmidecode 等软件及依赖。"
    echo
    read -r -p "确认开始执行？[y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "已取消。"; return 0 ;;
    esac

    run_b64 "2" "$STEP2_B64"
    run_b64 "3" "$STEP3_B64"
    run_b64 "4" "$STEP4_B64"
    run_b64 "5" "$STEP5_B64"
    run_b64 "6" "$STEP6_B64"

    echo
    echo "============================================================"
    echo "已全部执行完成。"
    echo "============================================================"
}

dd_debian() {
    echo "============================================================"
echo " 3. 一键 DD 为全新 Debian"
echo "============================================================"
echo "警告：此操作会重装系统并清除当前系统数据。"
echo
read -r -p "确认继续 DD？请输入 y/Y：" ans

if [[ "$ans" =~ ^[Yy]$ ]]; then
    echo
    echo "开始下载 reinstall.sh..."

    if command -v curl >/dev/null 2>&1; then
        curl -fL -o reinstall.sh \
            https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
    elif command -v wget >/dev/null 2>&1; then
        wget -O reinstall.sh \
            https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
    else
        echo "错误：系统中没有 curl 或 wget。"
        return 1
    fi

    if [[ ! -s reinstall.sh ]]; then
        echo "错误：reinstall.sh 下载失败。"
        return 1
    fi

    echo
    echo "开始 DD Debian..."
    echo "============================================================"

    bash reinstall.sh debian

    echo
    echo "============================================================"
    echo "DD 命令执行结束，准备自动重启..."
    echo "============================================================"

    sleep 3
    reboot
else
    echo "已取消。"
    return 0
fi
    echo "============================================================"
    echo "                 $SCRIPT_NAME"
    echo "============================================================"
    echo "  1. 换内核（XanMod LTS）→ 成功后自动重启"
    echo "  2. 一键配置"
    echo "  3. 一键 DD 为全新 Debian"
    echo "  0. 退出"
    echo "============================================================"
}

need_root
留空我自己填

while true; do
    show_menu
    read -r -p "请选择 [0-3]：" choice
    case "$choice" in
        1) install_kernel ;;
        2) run_all ;;
        3) dd_debian ;;
        0) echo "退出。"; exit 0 ;;
        *) echo "无效选择。"; sleep 1 ;;
    esac
    echo
    read -r -p "按回车返回菜单..." _
done
