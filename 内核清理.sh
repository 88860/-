#!/bin/bash

set -u

export DEBIAN_FRONTEND=noninteractive

if [[ "$EUID" -ne 0 ]]; then
    echo "请使用 root 运行"
    exit 1
fi

for cmd in uname dpkg dpkg-query apt-get awk sort grep sed; do
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
declare -a THIRD_META=()

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

is_real_kernel_package() {
    local p="$1"

    [[ "$p" == linux-image-* ]] || return 1
    [[ "$p" == *-dbg ]] && return 1

    case "$p" in
        linux-image-amd64|linux-image-arm64)
            return 1
            ;;
        linux-image-cloud-amd64|linux-image-cloud-arm64)
            return 1
            ;;
        linux-image-rt-amd64|linux-image-rt-arm64)
            return 1
            ;;
    esac

    return 0
}

is_debian_meta() {
    local p="$1"

    case "$p" in
        linux-image-amd64|linux-image-arm64)
            return 0
            ;;
        linux-image-cloud-amd64|linux-image-cloud-arm64)
            return 0
            ;;
        linux-image-rt-amd64|linux-image-rt-arm64)
            return 0
            ;;
    esac

    return 1
}

is_meta_package() {
    local p="$1"

    [[ "$p" == linux-image-* ]] || return 1
    is_real_kernel_package "$p" && return 1
    [[ "$p" != *-dbg ]] || return 1

    return 0
}

package_depends_on_kernel() {
    local p="$1"
    local r="$2"
    local deps

    deps="$(dpkg-query -W -f='${Depends} ${Pre-Depends} ${Recommends}' "$p" 2>/dev/null || true)"

    [[ "$deps" == *"linux-image-$r"* ||
       "$deps" == *"linux-image-$r-unsigned"* ]]
}

CURRENT_TYPE="$(kernel_type "$CURRENT")"

for d in /lib/modules/*; do
    [[ -d "$d" ]] || continue

    r="${d##*/}"

    kernel_image_pkgs "$r" >/dev/null || continue

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

mapfile -t INSTALLED_IMAGE_PACKAGES < <(
    dpkg-query -W -f='${Package}\t${db:Status-Status}\n' 'linux-image-*' 2>/dev/null |
    awk '$2=="installed"{print $1}'
)

for p in "${INSTALLED_IMAGE_PACKAGES[@]}"; do
    is_meta_package "$p" || continue

    if is_debian_meta "$p"; then
        DEBIAN_META+=("$p")
        continue
    fi

    case "$p" in
        linux-image-*-dbg)
            ;;
        *)
            if [[ "$p" == linux-image-* ]]; then
                THIRD_META+=("$p")
            fi
            ;;
    esac
done

mapfile -t DEBIAN_META < <(
    printf '%s\n' "${DEBIAN_META[@]}" |
    awk 'NF' |
    sort -u
)

mapfile -t THIRD_META < <(
    printf '%s\n' "${THIRD_META[@]}" |
    awk 'NF' |
    sort -u
)

declare -a REAL_THIRD_META=()

for p in "${THIRD_META[@]}"; do
    found=0

    for r in "${THIRD_KERNELS[@]}"; do
        if package_depends_on_kernel "$p" "$r"; then
            REAL_THIRD_META+=("$p")
            found=1
            break
        fi
    done

    [[ "$found" -eq 1 ]] || true
done

THIRD_META=("${REAL_THIRD_META[@]}")

CURRENT_BASE="$(kernel_base "$CURRENT")"

if [[ "$CURRENT_TYPE" == "debian" ]]; then
    HIGHER=""

    for r in "${DEBIAN_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue

        b="$(kernel_base "$r")"

        if [[ "$(printf '%s\n%s\n' "$CURRENT_BASE" "$b" | sort -V | tail -n1)" == "$b" &&
              "$b" != "$CURRENT_BASE" ]]; then

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

    [[ "$ANSWER" =~ ^[Yy]$ ]] || {
        echo "未执行任何操作"
        exit 0
    }

else
    HIGHER=""

    for r in "${THIRD_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue

        b="$(kernel_base "$r")"

        if [[ "$(printf '%s\n%s\n' "$CURRENT_BASE" "$b" | sort -V | tail -n1)" == "$b" &&
              "$b" != "$CURRENT_BASE" ]]; then

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

    declare -A SEEN=()
    declare -a UNIQUE_CLEANUP=()

    for p in "${CLEANUP[@]}"; do
        [[ -n "${SEEN[$p]+x}" ]] &&
