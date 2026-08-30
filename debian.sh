#!/bin/bash
# debian13自用 - Debian 13 自用一键菜单
# 1 = 安装 XanMod LTS 内核并自动重启
# 2 = 一键配置
# 3 = 一键 DD 全新 Debian

set -Eeuo pipefail

SCRIPT_NAME="debian13自用"

# ============================================================
# 临时目录
# ============================================================

TMP_DIR="$(mktemp -d /tmp/debian13-self.XXXXXX)"

trap 'rm -rf "$TMP_DIR"' EXIT


# ============================================================
# 这里留给你自己填写
# ============================================================

KERNEL_B64=""

STEP2_B64=""

STEP3_B64=""

STEP4_B64=""

STEP5_B64=""

STEP6_B64=""


# ============================================================
# 检查 root
# ============================================================

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "错误：请使用 root 运行。"
        exit 1
    fi
}


# ============================================================
# 执行 Base64 脚本
# ============================================================

run_b64() {
    local num="$1"
    local data="$2"
    local file

    file="$TMP_DIR/${num}.sh"

    printf '%s' "$data" | base64 -d > "$file"

    chmod 700 "$file"

    echo
    echo "============================================================"
    echo "正在执行：$num"
    echo "============================================================"

    bash "$file"
}


# ============================================================
# 1. 安装 XanMod LTS 内核
# ============================================================

install_kernel() {

    echo "============================================================"
    echo " 1. 安装 XanMod LTS 内核"
    echo "============================================================"
    echo "将执行你提供的 1 换内核脚本；成功后自动重启。"
    echo

    read -r -p "确认安装内核并自动重启？[y/N] " ans

    case "$ans" in
        y|Y|yes|YES)
            ;;
        *)
            echo "已取消。"
            return 0
            ;;
    esac

    local file="$TMP_DIR/1.sh"

    printf '%s' "$KERNEL_B64" | base64 -d > "$file"

    chmod 700 "$file"

    bash "$file"

    echo
    echo "============================================================"
    echo "内核安装命令执行成功"
    echo "5 秒后自动重启..."
    echo "============================================================"

    sleep 5

    systemctl reboot
}


# ============================================================
# 2. 一键配置
# ============================================================

run_all() {

    echo "============================================================"
    echo " 2. 一键配置"
    echo "============================================================"
    echo "注意：2 会删除旧内核/元包；3 会删除 qemu*、os-prober、"
    echo "laptop-detect、pciutils、dmidecode 等软件及依赖。"
    echo

    read -r -p "确认开始执行？[y/N] " ans

    case "$ans" in
        y|Y|yes|YES)
            ;;
        *)
            echo "已取消。"
            return 0
            ;;
    esac

KERNEL_B64='YXB0IHVwZGF0ZSAmJiBhcHQgaW5zdGFsbCAteSB3Z2V0IGdwZyBjYS1jZXJ0aWZpY2F0ZXMgJiYgaW5zdGFsbCAtZCAtbSAwNzU1IC9ldGMvYXB0L2tleXJpbmdzICYmIHdnZXQgLXFPIC0gaHR0cHM6Ly9kbC54YW5tb2Qub3JnL2FyY2hpdmUua2V5IHwgZ3BnIC0tZGVhcm1vciAtLXllcyAtbyAvZXRjL2FwdC9rZXlyaW5ncy94YW5tb2QtYXJjaGl2ZS1rZXlyaW5nLmdwZyAmJiBjaG1vZCAwNjQ0IC9ldGMvYXB0L2tleXJpbmdzL3hhbm1vZC1hcmNoaXZlLWtleXJpbmcuZ3BnICYmIC4gL2V0Yy9vcy1yZWxlYXNlICYmIHByaW50ZiAnJXNcbicgImRlYiBbc2lnbmVkLWJ5PS9ldGMvYXB0L2tleXJpbmdzL3hhbm1vZC1hcmNoaXZlLWtleXJpbmcuZ3BnXSBodHRwOi8vZGViLnhhbm1vZC5vcmcgJHtWRVJTSU9OX0NPREVOQU1FfSBtYWluIiA+IC9ldGMvYXB0L3NvdXJjZXMubGlzdC5kL3hhbm1vZC1yZWxlYXNlLmxpc3QgJiYgYXB0IHVwZGF0ZSAmJiBYQU5NT0RfVkVSPSQoaWYgL2xpYjY0L2xkLWxpbnV4LXg4Ni02NC5zby4yIC0taGVscCAyPi9kZXYvbnVsbCB8IGdyZXAgLXEgJ3g4Ni02NC12MyAoc3VwcG9ydGVkLCBzZWFyY2hlZCknOyB0aGVuIGVjaG8geDg2LTY0LXYzOyBlbGlmIC9saWI2NC9sZC1saW51eC14ODYtNjQuc28uMiAtLWhlbHAgMj4vZGV2L251bGwgfCBncmVwIC1xICd4ODYtNjQtdjIgKHN1cHBvcnRlZCwgc2VhcmNoZWQpJzsgdGhlbiBlY2hvIHg4Ni02NC12MjsgZWxzZSBlY2hvIHg4Ni02NC12MTsgZmkpICYmIGNhc2UgIiRYQU5NT0RfVkVSIiBpbiB4ODYtNjQtdjEpIFhBTk1PRF9QS0c9bGludXgteGFubW9kLWx0cy14NjR2MSA7OyB4ODYtNjQtdjIpIFhBTk1PRF9QS0c9bGludXgteGFubW9kLWx0cy14NjR2MiA7OyB4ODYtNjQtdjMpIFhBTk1PRF9QS0c9bGludXgteGFubW9kLWx0cy14NjR2MyA7OyAqKSBlY2hvICJFUlJPUjogVW5zdXBwb3J0ZWQgQ1BVIGxldmVsOiAkWEFOTU9EX1ZFUiI7IGV4aXQgMSA7OyBlc2FjICYmIGVjaG8gIkRldGVjdGVkIENQVTogJFhBTk1PRF9WRVIiICYmIGVjaG8gIkluc3RhbGxpbmc6ICRYQU5NT0RfUEtHIiAmJiBhcHQgaW5zdGFsbCAteSAiJFhBTk1PRF9QS0ci'
STEP2_B64='Q1VSUkVOVD0iJCh1bmFtZSAtcikiOyBLRUVQX01FVEE9IiQoZHBrZy1xdWVyeSAtVyAtZj0nJHtQYWNrYWdlfVx0JHtTdGF0dXN9XG4nICdsaW51eC14YW5tb2QtbHRzLSonIDI+L2Rldi9udWxsIHwgYXdrICckMj09Imluc3RhbGwiJiYkMz09Im9rIiYmJDQ9PSJpbnN0YWxsZWQie3ByaW50ICQxfScgfCB3aGlsZSByZWFkIC1yIHA7IGRvIGFwdC1jYWNoZSBkZXBlbmRzICIkcCIgMj4vZGV2L251bGwgfCBncmVwIC1GcSAiJENVUlJFTlQiICYmIGVjaG8gIiRwIjsgZG9uZSkiOyBlY2hvICLlvZPliY3ov5DooYzlhoXmoLg6ICRDVVJSRU5UIjsgZWNobyAi5b2T5YmNIFhhbk1vZCBMVFMg5YWD5YyFOiAke0tFRVBfTUVUQTot5pyq5qOA5rWL5YiwfSI7IE9MRF9LRVJORUxTPSIkKGRwa2ctcXVlcnkgLVcgLWY9JyR7UGFja2FnZX1cdCR7U3RhdHVzfVxuJyAnbGludXgtaW1hZ2UtKicgJ2xpbnV4LWhlYWRlcnMtKicgJ2xpbnV4LW1vZHVsZXMtKicgMj4vZGV2L251bGwgfCBhd2sgLXYgY3VyPSIkQ1VSUkVOVCIgJyQyPT0iaW5zdGFsbCImJiQzPT0ib2siJiYkND09Imluc3RhbGxlZCJ7cD0kMTtpZihpbmRleChwLGN1cik9PTApcHJpbnQgcH0nKSI7IE9MRF9NRVRBPSIkKGRwa2ctcXVlcnkgLVcgLWY9JyR7UGFja2FnZX1cdCR7U3RhdHVzfVxuJyAnbGludXgteGFubW9kLWx0cy0qJyAyPi9kZXYvbnVsbCB8IGF3ayAtdiBrZWVwPSIkS0VFUF9NRVRBIiAnJDI9PSJpbnN0YWxsIiYmJDM9PSJvayImJiQ0PT0iaW5zdGFsbGVkIntwPSQxO2lmKHAhPWtlZXApcHJpbnQgcH0nKSI7IGVjaG8gIuaXp+WGheaguOWMhToiOyBwcmludGYgJyVzXG4nICIke09MRF9LRVJORUxTOi3ml6B9IjsgZWNobyAi5penIFhhbk1vZCBMVFMg5YWD5YyFOiI7IHByaW50ZiAnJXNcbicgIiR7T0xEX01FVEE6LeaXoH0iOyB7IHByaW50ZiAnJXNcbicgIiRPTERfS0VSTkVMUyI7IHByaW50ZiAnJXNcbicgIiRPTERfTUVUQSI7IH0gfCBzZWQgJy9eJC9kJyB8IHhhcmdzIC1yIGFwdCBwdXJnZSAteTsgYXB0IGF1dG9yZW1vdmUgLS1wdXJnZSAteQ=='
STEP3_B64='YXB0IHB1cmdlIC15ICdxZW11Kicgb3MtcHJvYmVyIGxhcHRvcC1kZXRlY3QgcGNpdXRpbHMgZG1pZGVjb2RlICYmIGFwdCBhdXRvcmVtb3ZlIC0tcHVyZ2UgLXkgJiYgYXB0IGNsZWFuIC1xcSAmJiBSQ19QS0dTPSQoZHBrZyAtbCAyPi9kZXYvbnVsbCB8IGF3ayAnL15yYy8ge3ByaW50ICQyfScpOyBbIC16ICIkUkNfUEtHUyIgXSB8fCBlY2hvICIkUkNfUEtHUyIgfCB4YXJncyBhcHQgcHVyZ2UgLXkgLXFx'
STEP4_B64='YXB0IHVwZGF0ZSAmJiBhcHQgZnVsbC11cGdyYWRlIC15ICYmIGFwdCBhdXRvcmVtb3ZlIC0tcHVyZ2UgLXk='
STEP5_B64='IyEvYmluL2Jhc2gKc2V0IC11CmV4cG9ydCBMQ19BTEw9QwoKVEFSR0VUPSIvdXNyL2xpYi9zeXNjdGwuZC81MC1kZWZhdWx0LmNvbmYiCgpHUkVFTj0nXDAzM1swOzMybScKWUVMTE9XPSdcMDMzWzE7MzNtJwpSRUQ9J1wwMzNbMDszMW0nCkNZQU49J1wwMzNbMDszNm0nCk5DPSdcMDMzWzBtJwoKZGllKCkgewogICAgZWNobyAtZSAiJHtSRUR96ZSZ6K+v77yaJDEke05DfSIKICAgIGV4aXQgMQp9CgpuZWVkX2NtZCgpIHsKICAgIGNvbW1hbmQgLXYgIiQxIiA+L2Rldi9udWxsIDI+JjEgfHwgZGllICLnvLrlsJHlkb3ku6TvvJokMSIKfQoKZm9yIGNtZCBpbiBhd2sgc2VkIGdyZXAgc3lzY3RsIGlwIHNzIGZyZWUgbnByb2Mgc3lzdGVtY3RsIG1rdGVtcDsgZG8KICAgIG5lZWRfY21kICIkY21kIgpkb25lCgpbICIkKGlkIC11KSIgLWVxIDAgXSB8fCBkaWUgIuivt+S9v+eUqCByb290IOi/kOihjCIKWyAtZiAiJFRBUkdFVCIgXSB8fCBkaWUgIiRUQVJHRVQg5LiN5a2Y5Zyo77yM5ouS57ud5Yib5bu6IgpbIC13ICIkVEFSR0VUIiBdIHx8IGRpZSAiJFRBUkdFVCDkuI3lj6/lhpkiClsgLUwgIiRUQVJHRVQiIF0gJiYgZGllICIkVEFSR0VUIOaYr+espuWPt+mTvuaOpe+8jOaLkue7neS/ruaUuSIKCmdldF9zeXNjdGwoKSB7CiAgICBzeXNjdGwgLW4gIiQxIiAyPi9kZXYvbnVsbCB8fCBlY2hvICJ1bmtub3duIgp9Cgp0cmltKCkgewogICAgcHJpbnRmICclc1xuJyAiJDEiIHwgYXdrICd7JDE9JDE7IHByaW50fScKfQoKaXNfbnVtYmVyKCkgewogICAgW1sgIiQxIiA9fiBeWzAtOV0rJCBdXQp9CgpoYXNfa2V5X2luX3RhcmdldCgpIHsKICAgIGxvY2FsIGtleT0iJDEiCgogICAgYXdrIC12IGs9IiRrZXkiICcKICAgIHsKICAgICAgICBsaW5lPSQwCiAgICAgICAgc3ViKC9eW1s6c3BhY2U6XV0rLywgIiIsIGxpbmUpCgogICAgICAgIGlmIChsaW5lID09ICIiIHx8IGxpbmUgfiAvXiMvIHx8IGxpbmUgfiAvXjsvKQogICAgICAgICAgICBuZXh0CgogICAgICAgIHNwbGl0KGxpbmUsIGEsICI9IikKICAgICAgICBsaHM9YVsxXQogICAgICAgIGdzdWIoL1tbOnNwYWNlOl1dLywgIiIsIGxocykKCiAgICAgICAgaWYgKGxocyA9PSBrIHx8IGxocyA9PSAiLyIgaykKICAgICAgICAgICAgZm91bmQ9MQogICAgfQogICAgRU5EIHsKICAgICAgICBleGl0KGZvdW5kID8gMCA6IDEpCiAgICB9CiAgICAnICIkVEFSR0VUIgp9CgpoYXNfY29tbWVudGVkX2tleV9pbl90YXJnZXQoKSB7CiAgICBsb2NhbCBrZXk9IiQxIgoKICAgIGF3ayAtdiBrPSIka2V5IiAnCiAgICB7CiAgICAgICAgbGluZT0kMAogICAgICAgIHN1YigvXltbOnNwYWNlOl1dKy8sICIiLCBsaW5lKQoKICAgICAgICBpZiAobGluZSAhfiAvXiMvICYmIGxpbmUgIX4gL147LykKICAgICAgICAgICAgbmV4dAoKICAgICAgICBzdWIoL15bIztdW1s6c3BhY2U6XV0qLywgIiIsIGxpbmUpCgogICAgICAgIHNwbGl0KGxpbmUsIGEsICI9IikKICAgICAgICBsaHM9YVsxXQogICAgICAgIGdzdWIoL1tbOnNwYWNlOl1dLywgIiIsIGxocykKCiAgICAgICAgaWYgKGxocyA9PSBrIHx8IGxocyA9PSAiLyIgaykKICAgICAgICAgICAgZm91bmQ9MQogICAgfQogICAgRU5EIHsKICAgICAgICBleGl0KGZvdW5kID8gMCA6IDEpCiAgICB9CiAgICAnICIkVEFSR0VUIgp9CgpnZXRfc3lzY3RsX2ZpbGVzKCkgewogICAgbG9jYWwgZCBmCgogICAgZm9yIGQgaW4gXAogICAgICAgIC91c3IvbGliL3N5c2N0bC5kIFwKICAgICAgICAvdXNyL2xvY2FsL2xpYi9zeXNjdGwuZCBcCiAgICAgICAgL3J1bi9zeXNjdGwuZCBcCiAgICAgICAgL2V0Yy9zeXNjdGwuZAogICAgZG8KICAgICAgICBbIC1kICIkZCIgXSB8fCBjb250aW51ZQoKICAgICAgICBmb3IgZiBpbiAiJGQiLyouY29uZjsgZG8KICAgICAgICAgICAgWyAtZiAiJGYiIF0gfHwgY29udGludWUKICAgICAgICAgICAgcHJpbnRmICclc1xuJyAiJGYiCiAgICAgICAgZG9uZQogICAgZG9uZQp9CgpmaW5kX2VmZmVjdGl2ZV9zb3VyY2UoKSB7CiAgICBsb2NhbCBrZXk9IiQxIgogICAgbG9jYWwgcmVzdWx0PSIiCiAgICBsb2NhbCBmCiAgICBsb2NhbCBsaW5lX25vCiAgICBsb2NhbCBsaW5lCiAgICBsb2NhbCBsaHMKICAgIGxvY2FsIHJocwoKICAgIHdoaWxlIElGUz0gcmVhZCAtciBmOyBkbwogICAgICAgIFsgLXIgIiRmIiBdIHx8IGNvbnRpbnVlCgogICAgICAgIHdoaWxlIElGUz0kJ1x0JyByZWFkIC1yIGxpbmVfbm8gbGluZTsgZG8KICAgICAgICAgICAgWyAtbiAiJGxpbmVfbm8iIF0gfHwgY29udGludWUKCiAgICAgICAgICAgIGxocz0iJHtsaW5lJSU9Kn0iCiAgICAgICAgICAgIHJocz0iJHtsaW5lIyo9fSIKCiAgICAgICAgICAgIGxocz0iJChwcmludGYgJyVzJyAiJGxocyIgfCBzZWQgJ3MvW1s6c3BhY2U6XV0vL2cnKSIKICAgICAgICAgICAgcmhzPSIkKHByaW50ZiAnJXMnICIkcmhzIiB8IHNlZCAncy9eW1s6c3BhY2U6XV0qLy87cy9bWzpzcGFjZTpdXSokLy8nKSIKCiAgICAgICAgICAgIGlmIFsgIiRsaHMiID0gIiRrZXkiIF0gfHwgWyAiJGxocyIgPSAiLyRrZXkiIF07IHRoZW4KICAgICAgICAgICAgICAgIHJlc3VsdD0iJGZ8JGxpbmVfbm98JHJocyIKICAgICAgICAgICAgZmkKICAgICAgICBkb25lIDwgPCgKICAgICAgICAgICAgYXdrIC12IGs9IiRrZXkiICcKICAgICAgICAgICAgewogICAgICAgICAgICAgICAgbGluZT0kMAogICAgICAgICAgICAgICAgc3ViKC9eW1s6c3BhY2U6XV0rLywgIiIsIGxpbmUpCgogICAgICAgICAgICAgICAgaWYgKGxpbmUgPT0gIiIgfHwgbGluZSB+IC9eIy8gfHwgbGluZSB+IC9eOy8pCiAgICAgICAgICAgICAgICAgICAgbmV4dAoKICAgICAgICAgICAgICAgIHNwbGl0KGxpbmUsIGEsICI9IikKICAgICAgICAgICAgICAgIGxocz1hWzFdCiAgICAgICAgICAgICAgICBnc3ViKC9bWzpzcGFjZTpdXS8sICIiLCBsaHMpCgogICAgICAgICAgICAgICAgaWYgKGxocyA9PSBrIHx8IGxocyA9PSAiLyIgaykKICAgICAgICAgICAgICAgICAgICBwcmludCBOUiAiXHQiICQwCiAgICAgICAgICAgIH0KICAgICAgICAgICAgJyAiJGYiCiAgICAgICAgKQogICAgZG9uZSA8IDwoCiAgICAgICAgZ2V0X3N5c2N0bF9maWxlcyB8CiAgICAgICAgYXdrIC1GLyAnCiAgICAgICAgewogICAgICAgICAgICBmaWxlPSQwCiAgICAgICAgICAgIG49c3BsaXQoZmlsZSxhLCIvIikKICAgICAgICAgICAgZGlyPSIiCiAgICAgICAgICAgIGZvcihpPTE7aTxuO2krKykKICAgICAgICAgICAgICAgIGRpcj1kaXIgIi8iIGFbaV0KCiAgICAgICAgICAgIGlmIChkaXIgPT0gIi9ldGMvc3lzY3RsLmQiKQogICAgICAgICAgICAgICAgcD00CiAgICAgICAgICAgIGVsc2UgaWYgKGRpciA9PSAiL3J1bi9zeXNjdGwuZCIpCiAgICAgICAgICAgICAgICBwPTMKICAgICAgICAgICAgZWxzZSBpZiAoZGlyID09ICIvdXNyL2xvY2FsL2xpYi9zeXNjdGwuZCIpCiAgICAgICAgICAgICAgICBwPTIKICAgICAgICAgICAgZWxzZSBpZiAoZGlyID09ICIvdXNyL2xpYi9zeXNjdGwuZCIpCiAgICAgICAgICAgICAgICBwPTEKICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgcD0wCgogICAgICAgICAgICBwcmludGYgIiVkXHQlc1xuIixwLGZpbGUKICAgICAgICB9CiAgICAgICAgJyB8CiAgICAgICAgc29ydCAtbiAtazEsMSAtazIsMiB8CiAgICAgICAgY3V0IC1mMi0KICAgICkKCiAgICBpZiBbIC1uICIkcmVzdWx0IiBdOyB0aGVuCiAgICAgICAgcHJpbnRmICclc1xuJyAiJHJlc3VsdCIKICAgIGVsc2UKICAgICAgICBwcmludGYgJ05PVF9GT1VORHx8XG4nCiAgICBmaQp9CgpzZXRfdGFyZ2V0X3ZhbHVlcygpIHsKICAgIGxvY2FsIHRtcAogICAgbG9jYWwgbW9kZQogICAgbG9jYWwgb3duZXIKICAgIGxvY2FsIGdyb3VwCgogICAgdG1wPSIkKG1rdGVtcCAiJHtUQVJHRVR9LnRtcC5YWFhYWFgiKSIgfHwgZGllICLml6Dms5XliJvlu7rkuLTml7bmlofku7YiCgogICAgbW9kZT0iJChzdGF0IC1jICclYScgIiRUQVJHRVQiIDI+L2Rldi9udWxsIHx8IGVjaG8gNjQ0KSIKICAgIG93bmVyPSIkKHN0YXQgLWMgJyV1JyAiJFRBUkdFVCIgMj4vZGV2L251bGwgfHwgZWNobyAwKSIKICAgIGdyb3VwPSIkKHN0YXQgLWMgJyVnJyAiJFRBUkdFVCIgMj4vZGV2L251bGwgfHwgZWNobyAwKSIKCiAgICAjIOWujOaVtOaLt+i0neWOn+aWh+S7tgogICAgY3AgLXAgIiRUQVJHRVQiICIkdG1wIgoKICAgICMg5Yqo5oCB6YGN5Y6G5omA5pyJ55uu5qCH5Y+C5pWw77yM5L2/55SoIHNlZCDlvLrlipvmuIXmtJfml6flj4LmlbDlj4rnibnmrornrKblj7cKICAgIGZvciAoKGk9MDsgaTwkeyNUQVJHRVRfS0VZU1tAXX07IGkrKykpOyBkbwogICAgICAgIGxvY2FsIGtleT0iJHtUQVJHRVRfS0VZU1skaV19IgogICAgICAgIGxvY2FsIHZhbD0iJHtUQVJHRVRfVkFMVUVTWyRpXX0iCgogICAgICAgIHNlZCAtaSAtRSAiL15bWzpzcGFjZTpdXSpbIzstXSpbWzpzcGFjZTpdXSoke2tleS8vLi9cLn1bWzpzcGFjZTpdXSo9L2QiICIkdG1wIgogICAgICAgIGVjaG8gIiRrZXkgPSAkdmFsIiA+PiAiJHRtcCIKICAgIGRvbmUKCiAgICBjaG1vZCAiJG1vZGUiICIkdG1wIiB8fCBkaWUgIuiuvue9ruaWh+S7tuadg+mZkOWksei0pSIKICAgIGNob3duICIkb3duZXI6JGdyb3VwIiAiJHRtcCIgMj4vZGV2L251bGwgfHwgdHJ1ZQoKICAgIGlmICEgbXYgLWYgIiR0bXAiICIkVEFSR0VUIjsgdGhlbgogICAgICAgIHJtIC1mICIkdG1wIgogICAgICAgIGRpZSAi5L+u5pS5ICRUQVJHRVQg5aSx6LSlIgogICAgZmkKfQoKCnNob3dfc291cmNlKCkgewogICAgbG9jYWwga2V5PSIkMSIKICAgIGxvY2FsIHJlc3VsdAoKICAgIHJlc3VsdD0iJChmaW5kX2VmZmVjdGl2ZV9zb3VyY2UgIiRrZXkiKSIKCiAgICBpZiBbWyAiJHJlc3VsdCIgPT0gTk9UX0ZPVU5EKiBdXTsgdGhlbgogICAgICAgIGVjaG8gIiAg5oyB5LmF5YyW6YWN572uIDog5pyq5om+5YiwIgogICAgZWxzZQogICAgICAgIGxvY2FsIGZpbGU9IiR7cmVzdWx0JSV8Kn0iCiAgICAgICAgbG9jYWwgcmVzdD0iJHtyZXN1bHQjKnx9IgogICAgICAgIGxvY2FsIGxpbmU9IiR7cmVzdCUlfCp9IgogICAgICAgIGxvY2FsIHZhbHVlPSIke3Jlc3QjKnx9IgoKICAgICAgICBlY2hvICIgIOmFjee9ruaWh+S7tiAgIDogJGZpbGUiCiAgICAgICAgZWNobyAiICDphY3nva7ooYwgICAgIDogJGxpbmUiCiAgICAgICAgZWNobyAiICDmlofku7blgLwgICAgIDogJHZhbHVlIgogICAgZmkKCiAgICBlY2hvICIgIOi/kOihjOWAvCAgICAgOiAkKGdldF9zeXNjdGwgIiRrZXkiKSIKfQoKZWNobyAiPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09IgplY2hvICIgRGViaWFuIDEzIOWPjOagiCBUQ1AvVURQIOe9kee7nOiwg+S8mCIKZWNobyAiIOWuoeiuoSDihpIg5Yik5patIOKGkiDnoa7orqQg4oaSIOS/ruaUuSDihpIg5bqU55SoIOKGkiDnvZHnu5zph43lkK8g4oaSIOmqjOivgSIKZWNobyAiPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09IgplY2hvCmVjaG8gIumFjee9ruaWh+S7tu+8miRUQVJHRVQiCmVjaG8gIuS4jeWkh+S7ve+8jOS4jeWIm+W7uuaWsOeahCBzeXNjdGwuZCDmlofku7YiCmVjaG8KCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgMS4g57O757ufCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CgplY2hvICJbMS8xMF0g57O757uf5qOA5rWLIgoKaWYgWyAtciAvZXRjL29zLXJlbGVhc2UgXTsgdGhlbgogICAgLiAvZXRjL29zLXJlbGVhc2UKZWxzZQogICAgUFJFVFRZX05BTUU9InVua25vd24iCmZpCgpDUFU9IiQobnByb2MgMj4vZGV2L251bGwgfHwgZWNobyAxKSIKUkFNX0tCPSIkKGF3ayAnL15NZW1Ub3RhbDovIHtwcmludCAkMjsgZXhpdH0nIC9wcm9jL21lbWluZm8pIgpSQU1fTUI9JCgoUkFNX0tCIC8gMTAyNCkpClNXQVBfTUI9IiQoZnJlZSAtbSB8IGF3ayAnL15Td2FwOi8ge3ByaW50ICQzOyBleGl0fScpIgpLRVJORUw9IiQodW5hbWUgLXIpIgoKZWNobyAiICBPUyAgICAgICA6ICR7UFJFVFRZX05BTUU6LXVua25vd259IgplY2hvICIgIEtlcm5lbCAgIDogJEtFUk5FTCIKZWNobyAiICBDUFUgICAgICA6ICRDUFUgY29yZXMiCmVjaG8gIiAgUkFNICAgICAgOiAkUkFNX01CIE1CIgplY2hvICIgIFN3YXAgICAgIDogJFNXQVBfTUIgTULvvIjkuI3kv67mlLnvvIkiCmVjaG8KCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgMi4g572R57ucCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CgplY2hvICJbMi8xMF0gSVB2NCAvIElQdjYgLyBUQ1AgLyBVRFAg5qOA5rWLIgoKSVBWNF9DT1VOVD0iJChpcCAtNCBhZGRyIDI+L2Rldi9udWxsIHwgYXdrICcvaW5ldCAvIHtjKyt9IEVORCB7cHJpbnQgYyswfScpIgpJUFY2X0NPVU5UPSIkKGlwIC02IGFkZHIgMj4vZGV2L251bGwgfCBhd2sgJy9pbmV0NiAvIHtjKyt9IEVORCB7cHJpbnQgYyswfScpIgpJUFY2X0RJU0FCTEVEPSIkKGdldF9zeXNjdGwgbmV0LmlwdjYuY29uZi5hbGwuZGlzYWJsZV9pcHY2KSIKClRDUF9MSVNURU49IiQoc3MgLUhsbiAyPi9kZXYvbnVsbCB8IGF3ayAnJDEgfiAvXnRjcC8ge2MrK30gRU5EIHtwcmludCBjKzB9JykiClRDUF9FU1Q9IiQoc3MgLUhudCAyPi9kZXYvbnVsbCB8IGF3ayAnJDEgPT0gIkVTVEFCIiB7YysrfSBFTkQge3ByaW50IGMrMH0nKSIKVURQX0NPVU5UPSIkKHNzIC1IdW4gMj4vZGV2L251bGwgfCBhd2sgJ0VORCB7cHJpbnQgTlIrMH0nKSIKCkRFRkFVTFRfSUY9IiQoaXAgcm91dGUgc2hvdyBkZWZhdWx0IDI+L2Rldi9udWxsIHwgYXdrICdOUj09MSB7cHJpbnQgJDU7IGV4aXR9JykiCgplY2hvICIgIElQdjQg5Zyw5Z2AICAgICAgICA6ICRJUFY0X0NPVU5UIgplY2hvICIgIElQdjYg5Zyw5Z2AICAgICAgICA6ICRJUFY2X0NPVU5UIgplY2hvICIgIElQdjYgZGlzYWJsZWQgICAgOiAkSVBWNl9ESVNBQkxFRCIKZWNobyAiICBUQ1AgTElTVEVOICAgICAgIDogJFRDUF9MSVNURU4iCmVjaG8gIiAgVENQIGVzdGFibGlzaGVkICAgOiAkVENQX0VTVCIKZWNobyAiICBVRFAgc29ja2V0cyAgICAgIDogJFVEUF9DT1VOVCIKZWNobyAiICDpu5jorqTnvZHljaEgICAgICAgICA6ICR7REVGQVVMVF9JRjotdW5rbm93bn0iCmVjaG8KCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgMy4gU1NICiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CgplY2hvICJbMy8xMF0gU1NIIOS8muivneajgOa1iyIKCmlmIFsgLW4gIiR7U1NIX0NPTk5FQ1RJT046LX0iIF07IHRoZW4KICAgIHJlYWQgLXIgU1NIX1JFTU9URV9JUCBTU0hfUkVNT1RFX1BPUlQgU1NIX0xPQ0FMX0lQIFNTSF9MT0NBTF9QT1JUIDw8PCAiJFNTSF9DT05ORUNUSU9OIgoKICAgIGVjaG8gIiAg4pyTIOW9k+WJjSBTU0gg6L+c56iL5Lya6K+dIgogICAgZWNobyAiICDov5znq68gSVAgICAgIDogJFNTSF9SRU1PVEVfSVAiCiAgICBlY2hvICIgIOi/nOerr+err+WPoyAgICA6ICRTU0hfUkVNT1RFX1BPUlQiCiAgICBlY2hvICIgIOacrOWcsOWcsOWdgCAgICA6ICRTU0hfTE9DQUxfSVAiCiAgICBlY2hvICIgIOacrOWcsOerr+WPoyAgICA6ICRTU0hfTE9DQUxfUE9SVCIKZWxzZQogICAgZWNobyAiICDmnKrmo4DmtYvliLAgU1NIX0NPTk5FQ1RJT04iCmZpCgplY2hvCgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQojIDQuIENQVSAvIFJBTQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoKZWNobyAiWzQvMTBdIENQVSAvIFJBTSDosIPkvJjnrYnnuqciCgppZiBbICIkQ1BVIiAtbGUgMSBdOyB0aGVuCiAgICBDUFVfTEVWRUw9InNtYWxsIgplbGlmIFsgIiRDUFUiIC1sZSAyIF07IHRoZW4KICAgIENQVV9MRVZFTD0ibWVkaXVtIgplbHNlCiAgICBDUFVfTEVWRUw9ImxhcmdlIgpmaQoKaWYgWyAiJFJBTV9NQiIgLWxlIDE1MzYgXTsgdGhlbgogICAgUkFNX0xFVkVMPSJzbWFsbCIKZWxpZiBbICIkUkFNX01CIiAtbGUgNDA5NiBdOyB0aGVuCiAgICBSQU1fTEVWRUw9Im1lZGl1bSIKZWxzZQogICAgUkFNX0xFVkVMPSJsYXJnZSIKZmkKCmVjaG8gIiAgQ1BVIOetiee6pyA6ICRDUFVfTEVWRUwiCmVjaG8gIiAgUkFNIOetiee6pyA6ICRSQU1fTEVWRUwiCmVjaG8KCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgNS4gQkJSIC8gRlEgLyBURk8KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KCmVjaG8gIls1LzEwXSBCQlIgLyBGUSAvIFRDUCBGYXN0IE9wZW4iCgpDQz0iJChnZXRfc3lzY3RsIG5ldC5pcHY0LnRjcF9jb25nZXN0aW9uX2NvbnRyb2wpIgpBVkFJTEFCTEVfQ0M9IiQoZ2V0X3N5c2N0bCBuZXQuaXB2NC50Y3BfYXZhaWxhYmxlX2Nvbmdlc3Rpb25fY29udHJvbCkiClFESVNDPSIkKGdldF9zeXNjdGwgbmV0LmNvcmUuZGVmYXVsdF9xZGlzYykiClRGTz0iJChnZXRfc3lzY3RsIG5ldC5pcHY0LnRjcF9mYXN0b3BlbikiCgpCQlJfU1VQUE9SVEVEPTAKQkJSX1NPVVJDRT0ibm8iCgojIDEuIOajgOa1i+W9k+WJjeWPr+eUqOeul+azleS4reaYr+WQpuW3suWMheWQqyBiYnIgKOWGheaguOWGhee9ruaIluW3sue7j+aMgui9vSkKaWYgZWNobyAiJEFWQUlMQUJMRV9DQyIgfCB0ciAnICcgJ1xuJyB8IGdyZXAgLXF4IGJicjsgdGhlbgogICAgQkJSX1NVUFBPUlRFRD0xCiAgICBCQlJfU09VUkNFPSJ5ZXMgKOWOn+eUn+iHquW4puaIluW3suaMgui9vSkiCmVsc2UKICAgICMgMi4g5aaC5p6c5rKh5pyJIGJicu+8jOWwneivlemdmem7mOWKqOaAgeWKoOi9vSB0Y3BfYmJyIOaooeWdlwogICAgaWYgY29tbWFuZCAtdiBtb2Rwcm9iZSA+L2Rldi9udWxsIDI+JjEgJiYgbW9kcHJvYmUgdGNwX2JiciAyPi9kZXYvbnVsbDsgdGhlbgogICAgICAgIEFWQUlMQUJMRV9DQz0iJChnZXRfc3lzY3RsIG5ldC5pcHY0LnRjcF9hdmFpbGFibGVfY29uZ2VzdGlvbl9jb250cm9sKSIKICAgICAgICAKICAgICAgICAjIDMuIOWGjeasoeagoemqjO+8jOWmguaenOWKoOi9veaIkOWKn++8jOivtOaYjuaYr+WOn+eJiCBEZWJpYW4g55qE5Yqo5oCB5qih5Z2XCiAgICAgICAgaWYgZWNobyAiJEFWQUlMQUJMRV9DQyIgfCB0ciAnICcgJ1xuJyB8IGdyZXAgLXF4IGJicjsgdGhlbgogICAgICAgICAgICBCQlJfU1VQUE9SVEVEPTEKICAgICAgICAgICAgQkJSX1NPVVJDRT0ieWVzICjliqjmgIHmjILovb3miJDlip8pIgogICAgICAgICAgICAKICAgICAgICAgICAgIyA0LiDnsr7lh4bkv67mlLnns7vnu5/ljp/nlJ/mlofku7YgL2V0Yy9tb2R1bGVzIOWunueOsOaMgeS5heWMlgogICAgICAgICAgICBpZiBbIC13IC9ldGMvbW9kdWxlcyBdOyB0aGVuCiAgICAgICAgICAgICAgICBpZiAhIGdyZXAgLXEgIl50Y3BfYmJyJCIgL2V0Yy9tb2R1bGVzIDI+L2Rldi9udWxsOyB0aGVuCiAgICAgICAgICAgICAgICAgICAgZWNobyAidGNwX2JiciIgPj4gL2V0Yy9tb2R1bGVzCiAgICAgICAgICAgICAgICAgICAgQkJSX1NPVVJDRT0ieWVzICjliqjmgIHmjILovb3vvIzlubblt7Lov73liqDoh7MgL2V0Yy9tb2R1bGVzIOaMgeS5heWMlikiCiAgICAgICAgICAgICAgICBmaQogICAgICAgICAgICBmaQogICAgICAgIGZpCiAgICBmaQpmaQoKaWYgWyAtciAvcHJvYy9zeXMvbmV0L2NvcmUvZGVmYXVsdF9xZGlzYyBdOyB0aGVuCiAgICBGUV9TVVBQT1JURUQ9MQplbHNlCiAgICBGUV9TVVBQT1JURUQ9MApmaQoKZWNobyAiICDlvZPliY3mi6XloZ7mjqfliLYgICAgICA6ICRDQyIKZWNobyAiICDlj6/nlKjmi6XloZ7mjqfliLYgICAgICA6ICRBVkFJTEFCTEVfQ0MiCmVjaG8gIiAg5b2T5YmN6buY6K6kIHFkaXNjICAgIDogJFFESVNDIgplY2hvICIgIOW9k+WJjSBUQ1AgRmFzdCBPcGVuIDogJFRGTyIKZWNobyAiICBCQlIg5YaF5qC45pSv5oyBICAgICAgOiAkQkJSX1NPVVJDRSIKCgppZiBbICIkRlFfU1VQUE9SVEVEIiAtZXEgMSBdOyB0aGVuCiAgICBlY2hvICIgIEZRIOmFjee9ruaOpeWPoyAgICAgICA6IHllcyIKZWxzZQogICAgZWNobyAiICBGUSDphY3nva7mjqXlj6MgICAgICAgOiBubyIKZmkKCmVjaG8KCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgNi4g572R57uc5Y6L5YqbCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CgplY2hvICJbNi8xMF0g572R57uc5a6e6ZmF5Y6L5Yqb5qOA5rWLIgoKc29mdG5ldF9iZWZvcmU9IiQoYXdrICd7c3VtKz0kMn0gRU5EIHtwcmludCBzdW0rMH0nIC9wcm9jL25ldC9zb2Z0bmV0X3N0YXQgMj4vZGV2L251bGwpIgpyeF9iZWZvcmU9IiQoY2F0IC9zeXMvY2xhc3MvbmV0Lyovc3RhdGlzdGljcy9yeF9kcm9wcGVkIDI+L2Rldi9udWxsIHwgYXdrICd7c3VtKz0kMX0gRU5EIHtwcmludCBzdW0rMH0nKSIKdHhfYmVmb3JlPSIkKGNhdCAvc3lzL2NsYXNzL25ldC8qL3N0YXRpc3RpY3MvdHhfZHJvcHBlZCAyPi9kZXYvbnVsbCB8IGF3ayAne3N1bSs9JDF9IEVORCB7cHJpbnQgc3VtKzB9JykiCgpzbGVlcCAzCgpzb2Z0bmV0X2FmdGVyPSIkKGF3ayAne3N1bSs9JDJ9IEVORCB7cHJpbnQgc3VtKzB9JyAvcHJvYy9uZXQvc29mdG5ldF9zdGF0IDI+L2Rldi9udWxsKSIKcnhfYWZ0ZXI9IiQoY2F0IC9zeXMvY2xhc3MvbmV0Lyovc3RhdGlzdGljcy9yeF9kcm9wcGVkIDI+L2Rldi9udWxsIHwgYXdrICd7c3VtKz0kMX0gRU5EIHtwcmludCBzdW0rMH0nKSIKdHhfYWZ0ZXI9IiQoY2F0IC9zeXMvY2xhc3MvbmV0Lyovc3RhdGlzdGljcy90eF9kcm9wcGVkIDI+L2Rldi9udWxsIHwgYXdrICd7c3VtKz0kMX0gRU5EIHtwcmludCBzdW0rMH0nKSIKCnNvZnRuZXRfZGVsdGE9JCgoc29mdG5ldF9hZnRlciAtIHNvZnRuZXRfYmVmb3JlKSkKcnhfZGVsdGE9JCgocnhfYWZ0ZXIgLSByeF9iZWZvcmUpKQp0eF9kZWx0YT0kKCh0eF9hZnRlciAtIHR4X2JlZm9yZSkpCgpbICIkc29mdG5ldF9kZWx0YSIgLWx0IDAgXSAmJiBzb2Z0bmV0X2RlbHRhPTAKWyAiJHJ4X2RlbHRhIiAtbHQgMCBdICYmIHJ4X2RlbHRhPTAKWyAiJHR4X2RlbHRhIiAtbHQgMCBdICYmIHR4X2RlbHRhPTAKCmVjaG8gIiAgc29mdG5ldCBkcm9wcyAvIDNzIDogJHNvZnRuZXRfZGVsdGEiCmVjaG8gIiAgUlggZHJvcHMgLyAzcyAgICAgIDogJHJ4X2RlbHRhIgplY2hvICIgIFRYIGRyb3BzIC8gM3MgICAgICA6ICR0eF9kZWx0YSIKZWNobwoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KIyA3LiDlvZPliY3lj4LmlbAKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KCmVjaG8gIls3LzEwXSDlvZPliY3ov5DooYzlj4LmlbAiCgpkZWNsYXJlIC1BIENVUlJFTlQKClBBUkFNUz0oCiAgICBuZXQuY29yZS5kZWZhdWx0X3FkaXNjCiAgICBuZXQuaXB2NC50Y3BfY29uZ2VzdGlvbl9jb250cm9sCiAgICBuZXQuaXB2NC50Y3BfZmFzdG9wZW4KICAgIG5ldC5pcHY0LnRjcF9zeW5jb29raWVzCiAgICBuZXQuY29yZS5zb21heGNvbm4KICAgIG5ldC5pcHY0LnRjcF9tYXhfc3luX2JhY2tsb2cKICAgIG5ldC5jb3JlLm5ldGRldl9tYXhfYmFja2xvZwogICAgbmV0LmlwdjQudGNwX3dpbmRvd19zY2FsaW5nCiAgICBuZXQuaXB2NC50Y3Bfc2FjawogICAgbmV0LmlwdjQudGNwX3RpbWVzdGFtcHMKICAgIG5ldC5pcHY0LnRjcF9lY24KICAgIG5ldC5pcHY0LnRjcF9tdHVfcHJvYmluZwogICAgbmV0LmlwdjQudGNwX2Zpbl90aW1lb3V0CiAgICBuZXQuaXB2NC50Y3Bfa2VlcGFsaXZlX3RpbWUKICAgIG5ldC5pcHY0LnRjcF9rZWVwYWxpdmVfaW50dmwKICAgIG5ldC5pcHY0LnRjcF9rZWVwYWxpdmVfcHJvYmVzCiAgICBuZXQuaXB2NC50Y3BfbWF4X3R3X2J1Y2tldHMKICAgIG5ldC5pcHY0LmlwX2xvY2FsX3BvcnRfcmFuZ2UKKQoKZm9yIHAgaW4gIiR7UEFSQU1TW0BdfSI7IGRvCiAgICBDVVJSRU5UWyIkcCJdPSIkKGdldF9zeXNjdGwgIiRwIikiCmRvbmUKCnByaW50ZiAnICBkZWZhdWx0X3FkaXNjICAgICAgIDogJXNcbicgIiR7Q1VSUkVOVFtuZXQuY29yZS5kZWZhdWx0X3FkaXNjXX0iCnByaW50ZiAnICBjb25nZXN0aW9uX2NvbnRyb2wgIDogJXNcbicgIiR7Q1VSUkVOVFtuZXQuaXB2NC50Y3BfY29uZ2VzdGlvbl9jb250cm9sXX0iCnByaW50ZiAnICB0Y3BfZmFzdG9wZW4gICAgICAgIDogJXNcbicgIiR7Q1VSUkVOVFtuZXQuaXB2

    echo
    echo "============================================================"
    echo "已全部执行完成。"
    echo "============================================================"
}


# ============================================================
# 3. 一键 DD 为全新 Debian
# ============================================================

dd_debian() {

    echo "============================================================"
    echo " 3. 一键 DD 为全新 Debian"
    echo "============================================================"
    echo
    echo "警告：此操作会重装系统并清除当前系统数据。"
    echo "请确认你已经做好数据备份。"
    echo

    read -r -p "确认继续 DD？请输入 y/Y：" ans

    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        return 0
    fi


    # --------------------------------------------------------
    # 下载 reinstall.sh
    # --------------------------------------------------------

    echo
    echo "============================================================"
    echo "开始下载 reinstall.sh..."
    echo "============================================================"

    local reinstall_script="$TMP_DIR/reinstall.sh"


    if command -v curl >/dev/null 2>&1; then

        curl -fL \
            -o "$reinstall_script" \
            "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"

    elif command -v wget >/dev/null 2>&1; then

        wget \
            -O "$reinstall_script" \
            "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"

    else

        echo "错误：系统中没有 curl 或 wget。"
        return 1

    fi


    # --------------------------------------------------------
    # 检查下载结果
    # --------------------------------------------------------

    if [[ ! -s "$reinstall_script" ]]; then
        echo "错误：reinstall.sh 下载失败。"
        return 1
    fi


    chmod 700 "$reinstall_script"


    echo
    echo "============================================================"
    echo "reinstall.sh 下载成功"
    echo "============================================================"

    sleep 2


    # --------------------------------------------------------
    # 开始 DD
    # --------------------------------------------------------

    echo
    echo "============================================================"
    echo "开始 DD Debian..."
    echo "============================================================"
    echo

    bash "$reinstall_script" debian


    # --------------------------------------------------------
    # DD 脚本正常返回后自动重启
    # --------------------------------------------------------

    echo
    echo "============================================================"
    echo "DD 命令执行结束"
    echo "============================================================"
    echo
    echo "3 秒后自动重启..."
    echo

    sleep 3

    systemctl reboot
}


# ============================================================
# 菜单
# ============================================================

show_menu() {

    clear 2>/dev/null || true

    echo "============================================================"
    echo "                 $SCRIPT_NAME"
    echo "============================================================"
    echo
    echo "  1. 换内核（XanMod LTS）→ 成功后自动重启"
    echo "  2. 一键配置"
    echo "  3. 一键 DD 为全新 Debian"
    echo "  0. 退出"
    echo
    echo "============================================================"
}


# ============================================================
# 主程序
# ============================================================

need_root


while true; do

    show_menu

    read -r -p "请选择 [0-3]：" choice

    case "$choice" in

        1)
            install_kernel
            ;;

        2)
            run_all
            ;;

        3)
            dd_debian
            ;;

        0)
            echo "退出。"
            exit 0
            ;;

        *)
            echo "无效选择。"
            sleep 1
            ;;

    esac


    echo

    read -r -p "按回车返回菜单..." _

done
