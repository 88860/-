#!/bin/bash

set -u

export DEBIAN_FRONTEND=noninteractive

if [[ "$EUID" -ne 0 ]]; then
    echo "请使用 root 运行"
    exit 1
fi

for cmd in uname dpkg dpkg-query apt-get awk sort grep tail; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "缺少命令: $cmd"
        exit 1
    }
done

CURRENT="$(uname -r)"
ARCH="$(dpkg --print-architecture)"

declare -a DEBIAN_KERNELS=()
declare -a THIRD_KERNELS=()
declare -a CLEANUP=()
declare -a DEBIAN_META=()

kernel_type() {
    local r="$1"

    if [[ "$r" =~ \+deb[0-9]+- ]]; then
        echo "debian"
    else
        echo "third"
    fi
}

kernel_base() {
    local r="$1"

    if [[ "$r" =~ ^[0-9]+(\.[0-9]+)* ]]; then
        echo "${BASH_REMATCH[0]}"
    else
        echo "$r"
    fi
}

is_installed() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed
}

kernel_image_pkgs() {
    local r="$1"
    local p

    for p in \
        "linux-image-$r" \
        "linux-image-$r-unsigned"
    do
        if is_installed "$p"; then
            echo "$p"
        fi
    done
}

CURRENT_TYPE="$(kernel_type "$CURRENT")"

for d in /lib/modules/*; do
    [[ -d "$d" ]] || continue

    r="${d##*/}"

    if ! kernel_image_pkgs "$r" | grep -q .; then
        continue
    fi

    if [[ "$(kernel_type "$r")" == "debian" ]]; then
        DEBIAN_KERNELS+=("$r")
    else
        THIRD_KERNELS+=("$r")
    fi
done

mapfile -t DEBIAN_KERNELS < <(
    printf '%s\n' "${DEBIAN_KERNELS[@]}" |
    awk 'NF' |
    sort -V -u
)

mapfile -t THIRD_KERNELS < <(
    printf '%s\n' "${THIRD_KERNELS[@]}" |
    awk 'NF' |
    sort -V -u
)

case "$ARCH" in
    amd64)
        META_LIST=(
            linux-image-amd64
            linux-image-cloud-amd64
            linux-image-rt-amd64
        )
        ;;
    arm64)
        META_LIST=(
            linux-image-arm64
            linux-image-cloud-arm64
            linux-image-rt-arm64
        )
        ;;
    *)
        META_LIST=()
        ;;
esac

for p in "${META_LIST[@]}"; do
    if is_installed "$p"; then
        DEBIAN_META+=("$p")
    fi
done

if [[ "$CURRENT_TYPE" == "debian" ]]; then

    CURRENT_BASE="$(kernel_base "$CURRENT")"
    HIGHER=""

    for r in "${DEBIAN_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue

        b="$(kernel_base "$r")"

        if [[ "$b" != "$CURRENT_BASE" &&
              "$(printf '%s\n%s\n' "$CURRENT_BASE" "$b" | sort -V | tail -n1)" == "$b" ]]; then

            if [[ -z "$HIGHER" ||
                  "$(printf '%s\n%s\n' "$(kernel_base "$HIGHER")" "$b" | sort -V | tail -n1)" == "$b" ]]; then
                HIGHER="$r"
            fi
        fi
    done

    if [[ -n "$HIGHER" ]]; then
        echo "当前内核 : $CURRENT"
        echo "发现更高 Debian 内核 : $HIGHER"
        echo "请重启后重新运行脚本"
        exit 0
    fi

    for r in "${DEBIAN_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue

        while IFS= read -r p; do
            [[ -n "$p" ]] && CLEANUP+=("$p")
        done < <(kernel_image_pkgs "$r")
    done

else

    CURRENT_BASE="$(kernel_base "$CURRENT")"
    HIGHER=""

    for r in "${THIRD_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue

        b="$(kernel_base "$r")"

        if [[ "$b" != "$CURRENT_BASE" &&
              "$(printf '%s\n%s\n' "$CURRENT_BASE" "$b" | sort -V | tail -n1)" == "$b" ]]; then

            if [[ -z "$HIGHER" ||
                  "$(printf '%s\n%s\n' "$(kernel_base "$HIGHER")" "$b" | sort -V | tail -n1)" == "$b" ]]; then
                HIGHER="$r"
            fi
        fi
    done

    if [[ -n "$HIGHER" ]]; then
        echo "当前内核 : $CURRENT"
        echo "发现更高第三方内核 : $HIGHER"
        echo "请重启后重新运行脚本"
        exit 0
    fi

    for r in "${THIRD_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue

        while IFS= read -r p; do
            [[ -n "$p" ]] && CLEANUP+=("$p")
        done < <(kernel_image_pkgs "$r")
    done

    if [[ "${#DEBIAN_KERNELS[@]}" -gt 0 ||
          "${#DEBIAN_META[@]}" -gt 0 ]]; then

        echo "当前内核 : $CURRENT"
        echo "类型     : 第三方内核"
        echo

        if [[ "${#DEBIAN_KERNELS[@]}" -gt 0 ]]; then
            echo "Debian 内核:"
            printf '  %s\n' "${DEBIAN_KERNELS[@]}"
            echo
        fi

        if [[ "${#DEBIAN_META[@]}" -gt 0 ]]; then
            echo "Debian 元包:"
            printf '  %s\n' "${DEBIAN_META[@]}"
            echo
        fi

        read -r -p "删除 Debian 内核和元包？ [y/N] " ANSWER

        if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
            for r in "${DEBIAN_KERNELS[@]}"; do
                [[ "$r" == "$CURRENT" ]] && continue

                while IFS= read -r p; do
                    [[ -n "$p" ]] && CLEANUP+=("$p")
                done < <(kernel_image_pkgs "$r")
            done

            CLEANUP+=("${DEBIAN_META[@]}")
        fi
    fi
fi

declare -A SEEN=()
declare -a UNIQUE_CLEANUP=()

for p in "${CLEANUP[@]}"; do
    [[ -n "${SEEN[$p]+x}" ]] && continue

    SEEN["$p"]=1
    UNIQUE_CLEANUP+=("$p")
done

CLEANUP=("${UNIQUE_CLEANUP[@]}")

if [[ "${#CLEANUP[@]}" -eq 0 ]]; then
    echo "没有需要清理的内核"
    exit 0
fi

for p in "${CLEANUP[@]}"; do
    if [[ "$p" == "linux-image-$CURRENT" ||
          "$p" == "linux-image-$CURRENT-unsigned" ]]; then
        echo "检测到当前运行内核，停止"
        exit 1
    fi
done

echo
echo "将删除:"
printf '  %s\n' "${CLEANUP[@]}"
echo
echo "保留:"
echo "  $CURRENT"
echo

read -r -p "继续删除？ [y/N] " ANSWER

if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
    echo "未执行任何操作"
    exit 0
fi

NOW="$(uname -r)"

if [[ "$NOW" != "$CURRENT" ]]; then
    echo "运行内核发生变化"
    echo "未执行任何操作"
    exit 1
fi

apt-get purge -y --no-install-recommends "${CLEANUP[@]}"
