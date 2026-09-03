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

declare -a ALL_KERNELS=()
declare -a DEBIAN_KERNELS=()
declare -a THIRD_KERNELS=()
declare -a CLEANUP=()
declare -a SKIP=()
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

is_packaged_kernel() {
    kernel_image_pkgs "$1" | grep -q .
}

find_higher() {
    local current="$1"
    local list="$2"
    local current_base
    local r
    local b
    local higher=""

    current_base="$(kernel_base "$current")"

    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        [[ "$r" == "$current" ]] && continue

        b="$(kernel_base "$r")"

        if [[ "$b" == "$current_base" ]]; then
            continue
        fi

        if [[ "$(printf '%s\n%s\n' "$current_base" "$b" | sort -V | tail -n1)" != "$b" ]]; then
            continue
        fi

        if [[ -z "$higher" ||
              "$(printf '%s\n%s\n' "$(kernel_base "$higher")" "$b" | sort -V | tail -n1)" == "$b" ]]; then
            higher="$r"
        fi
    done <<< "$list"

    echo "$higher"
}

for d in /lib/modules/*; do
    [[ -d "$d" ]] || continue

    r="${d##*/}"

    ALL_KERNELS+=("$r")

    if [[ "$(kernel_type "$r")" == "debian" ]]; then
        DEBIAN_KERNELS+=("$r")
    else
        THIRD_KERNELS+=("$r")
    fi
done

mapfile -t ALL_KERNELS < <(
    printf '%s\n' "${ALL_KERNELS[@]}" |
    awk 'NF' |
    sort -V -u
)

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

CURRENT_PACKAGED=0

if is_packaged_kernel "$CURRENT"; then
    CURRENT_PACKAGED=1
fi

CURRENT_TYPE="$(kernel_type "$CURRENT")"

if [[ "$CURRENT_TYPE" == "debian" && "$CURRENT_PACKAGED" -eq 1 ]]; then

    HIGHER="$(find_higher "$CURRENT" "$(printf '%s\n' "${DEBIAN_KERNELS[@]}")")"

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

    if [[ "$CURRENT_PACKAGED" -eq 0 ]]; then
        CURRENT_MODE="自编译"
    else
        CURRENT_MODE="第三方"
    fi

    HIGHER="$(find_higher "$CURRENT" "$(printf '%s\n' "${THIRD_KERNELS[@]}")")"

    if [[ -n "$HIGHER" ]]; then
        echo "当前内核 : $CURRENT"
        echo "发现更高第三方内核 : $HIGHER"
        echo "请重启后重新运行脚本"
        exit 0
    fi

    for r in "${THIRD_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue

        if is_packaged_kernel "$r"; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && CLEANUP+=("$p")
            done < <(kernel_image_pkgs "$r")
        else
            SKIP+=("$r")
        fi
    done

    if [[ "${#DEBIAN_KERNELS[@]}" -gt 0 ||
          "${#DEBIAN_META[@]}" -gt 0 ]]; then

        echo "当前内核 : $CURRENT"
        echo "类型     : $CURRENT_MODE"
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

if [[ "${#SKIP[@]}" -gt 0 ]]; then
    mapfile -t SKIP < <(
        printf '%s\n' "${SKIP[@]}" |
        awk 'NF' |
        sort -V -u
    )

    echo
    echo "未被软件包管理，跳过:"
    printf '  %s\n' "${SKIP[@]}"
fi

if [[ "${#CLEANUP[@]}" -eq 0 ]]; then
    echo
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
