#!/bin/bash

set -u

export DEBIAN_FRONTEND=noninteractive

CURRENT="$(uname -r)"
ARCH="$(dpkg --print-architecture)"

declare -a DEBIAN_KERNELS=()
declare -a THIRD_KERNELS=()
declare -a CLEANUP=()
declare -a DEBIAN_META=()

kernel_type() {
    local r="$1"

    if [[ "$r" == *"+deb"*"-"* ]]; then
        echo "debian"
        return
    fi

    if [[ "$r" == *xanmod* ]]; then
        echo "third"
        return
    fi

    echo "unknown"
}

kernel_base() {
    local r="$1"

    if [[ "$r" == *"+deb"* ]]; then
        echo "${r%%+*}"
        return
    fi

    if [[ "$r" == *-xanmod* ]]; then
        echo "${r%%-xanmod*}"
        return
    fi

    echo "$r"
}

kernel_image_pkg() {
    local r="$1"
    local p

    for p in \
        "linux-image-$r" \
        "linux-image-unsigned-$r"
    do
        if dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qx installed; then
            echo "$p"
            return 0
        fi
    done

    return 1
}

is_installed() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed
}

CURRENT_TYPE="$(kernel_type "$CURRENT")"

if [[ "$CURRENT_TYPE" == "unknown" ]]; then
    echo "无法识别当前内核"
    echo "$CURRENT"
    exit 1
fi

for d in /lib/modules/*; do
    [[ -d "$d" ]] || continue

    r="${d##*/}"

    t="$(kernel_type "$r")"

    case "$t" in
        debian)
            DEBIAN_KERNELS+=("$r")
            ;;
        third)
            THIRD_KERNELS+=("$r")
            ;;
    esac
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

if [[ "$CURRENT_TYPE" == "debian" ]]; then
    CURRENT_BASE="$(kernel_base "$CURRENT")"
    HIGHER=""

    for r in "${DEBIAN_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue

        b="$(kernel_base "$r")"

        if [[ "$(printf '%s\n%s\n' "$CURRENT_BASE" "$b" | sort -V | tail -n1)" == "$b" &&
              "$b" != "$CURRENT_BASE" ]]; then
            HIGHER="$r"
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

        p="$(kernel_image_pkg "$r" || true)"

        [[ -n "$p" ]] && CLEANUP+=("$p")
    done

    if [[ "${#CLEANUP[@]}" -eq 0 ]]; then
        echo "没有需要清理的 Debian 内核"
        exit 0
    fi

    echo "当前内核 : $CURRENT"
    echo "类型     : Debian 内核"
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

else
    CURRENT_BASE="$(kernel_base "$CURRENT")"
    HIGHER=""

    for r in "${THIRD_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue

        b="$(kernel_base "$r")"

        if [[ "$(printf '%s\n%s\n' "$CURRENT_BASE" "$b" | sort -V | tail -n1)" == "$b" &&
              "$b" != "$CURRENT_BASE" ]]; then
            HIGHER="$r"
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

        p="$(kernel_image_pkg "$r" || true)"

        [[ -n "$p" ]] && CLEANUP+=("$p")
    done

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

    if [[ "${#DEBIAN_KERNELS[@]}" -gt 0 ]]; then
        echo "当前内核 : $CURRENT"
        echo "类型     : 第三方内核"
        echo

        if [[ "${#THIRD_KERNELS[@]}" -gt 0 ]]; then
            echo "第三方内核:"
            printf '  %s\n' "${THIRD_KERNELS[@]}"
            echo
        fi

        echo "Debian 内核:"
        printf '  %s\n' "${DEBIAN_KERNELS[@]}"
        echo

        if [[ "${#DEBIAN_META[@]}" -gt 0 ]]; then
            echo "Debian 元包:"
            printf '  %s\n' "${DEBIAN_META[@]}"
            echo
        fi

        read -r -p "删除 Debian 内核和元包？ [y/N] " ANSWER

        if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
            for r in "${DEBIAN_KERNELS[@]}"; do
                p="$(kernel_image_pkg "$r" || true)"

                [[ -n "$p" ]] && CLEANUP+=("$p")
            done

            CLEANUP+=("${DEBIAN_META[@]}")
        fi
    fi

    if [[ "${#CLEANUP[@]}" -eq 0 ]]; then
        echo "没有需要清理的内核"
        exit 0
    fi

    CLEANUP=($(printf '%s\n' "${CLEANUP[@]}" | awk 'NF && !seen[$0]++'))

    for p in "${CLEANUP[@]}"; do
        if [[ "$p" == "linux-image-$CURRENT" ||
              "$p" == "linux-image-unsigned-$CURRENT" ]]; then
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
fi

NOW="$(uname -r)"

if [[ "$NOW" != "$CURRENT" ]]; then
    echo "运行内核发生变化"
    echo "未执行任何操作"
    exit 1
fi

if [[ "${#CLEANUP[@]}" -eq 0 ]]; then
    echo "没有需要清理的内核"
    exit 0
fi

apt-get purge -y --no-install-recommends "${CLEANUP[@]}"
