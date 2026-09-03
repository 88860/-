#!/usr/bin/env bash

VERSION="4.1.0"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行。"
    exit 1
fi

for cmd in uname dpkg-query dpkg apt-get find sort awk grep sed mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "缺少命令: $cmd"
        exit 1
    }
done

CURRENT_KERNEL=$(uname -r)

is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null |
        grep -qx 'install ok installed'
}

kernel_image_pkg() {
    local r="$1"
    local p

    for p in \
        "linux-image-$r" \
        "linux-image-unsigned-$r"
    do
        if is_installed "$p"; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    return 1
}

pkg_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

pkg_source() {
    dpkg-query -W -f='${source:Package}' "$1" 2>/dev/null |
        sed 's/:.*//'
}

kernel_type() {
    local release="$1"
    local pkg="$2"
    local source

    source=$(pkg_source "$pkg")

    if [[ "$release" == *"+deb"*"-"* ]]; then
        echo "debian"
        return 0
    fi

    if [[ "$source" == *xanmod* ||
          "$pkg" == *xanmod* ||
          "$release" == *xanmod* ]]; then
        echo "third"
        return 0
    fi

    return 1
}

kernel_base() {
    local release="$1"

    case "$release" in
        *+*)
            printf '%s\n' "${release%%+*}"
            ;;
        *-xanmod*)
            printf '%s\n' "${release%%-xanmod*}"
            ;;
        *-x64v[0-9]*-xanmod*)
            printf '%s\n' "${release%%-x64v[0-9]*-xanmod*}"
            ;;
        *)
            printf '%s\n' "$release"
            ;;
    esac
}

release_newer() {
    dpkg --compare-versions "$1" gt "$2"
}

debian_meta_packages() {
    dpkg-query \
        -W \
        -f='${binary:Package}\t${Status}\n' \
        'linux-image-*' 2>/dev/null |
    awk -F '\t' '$2=="install ok installed"{print $1}' |
    while IFS= read -r p; do
        case "$p" in
            linux-image-amd64)
                echo "$p"
                ;;
            linux-image-arm64)
                echo "$p"
                ;;
            linux-image-cloud-amd64)
                echo "$p"
                ;;
            linux-image-cloud-arm64)
                echo "$p"
                ;;
            linux-image-rt-amd64)
                echo "$p"
                ;;
            linux-image-rt-arm64)
                echo "$p"
                ;;
        esac
    done
}

mapfile -t RELEASES < <(
    find /lib/modules \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' 2>/dev/null |
    sort -V
)

if [[ ${#RELEASES[@]} -eq 0 ]]; then
    echo "未发现已安装的内核。"
    exit 1
fi

CURRENT_PKG=$(kernel_image_pkg "$CURRENT_KERNEL" || true)

if [[ -z "$CURRENT_PKG" ]]; then
    echo
    echo "无法确定当前运行内核对应的内核包。"
    echo "为避免误删，本次停止。"
    exit 1
fi

CURRENT_TYPE=$(kernel_type "$CURRENT_KERNEL" "$CURRENT_PKG" || true)

if [[ -z "$CURRENT_TYPE" ]]; then
    echo
    echo "无法准确识别当前运行内核类型。"
    echo "为避免误删，本次停止。"
    exit 1
fi

CURRENT_BASE=$(kernel_base "$CURRENT_KERNEL")

DEBIAN_RELEASES=()
DEBIAN_PKGS=()

THIRD_RELEASES=()
THIRD_PKGS=()

for release in "${RELEASES[@]}"; do
    pkg=$(kernel_image_pkg "$release" || true)

    [[ -z "$pkg" ]] && continue

    type=$(kernel_type "$release" "$pkg" || true)

    if [[ -z "$type" ]]; then
        echo
        echo "无法准确识别内核:"
        echo "  $release"
        echo
        echo "为避免误删，本次停止。"
        exit 1
    fi

    if [[ "$type" == "debian" ]]; then
        DEBIAN_RELEASES+=("$release")
        DEBIAN_PKGS+=("$pkg")
    else
        THIRD_RELEASES+=("$release")
        THIRD_PKGS+=("$pkg")
    fi
done

if [[ "$CURRENT_TYPE" == "debian" ]]; then

    for release in "${DEBIAN_RELEASES[@]}"; do
        [[ "$release" == "$CURRENT_KERNEL" ]] && continue

        base=$(kernel_base "$release")

        if release_newer "$base" "$CURRENT_BASE"; then
            echo
            echo "============================================================"
            echo "需要重启"
            echo "============================================================"
            echo
            echo "当前   : $CURRENT_KERNEL"
            echo "新版本 : $release"
            echo
            echo "请先重启，进入新内核后再运行脚本。"
            echo

            read -r -p "现在重启？ [y/N] " answer

            if [[ "$answer" =~ ^[Yy]$ ]]; then
                systemctl reboot
            fi

            exit 0
        fi
    done

else

    for release in "${THIRD_RELEASES[@]}"; do
        [[ "$release" == "$CURRENT_KERNEL" ]] && continue

        base=$(kernel_base "$release")

        if release_newer "$base" "$CURRENT_BASE"; then
            echo
            echo "============================================================"
            echo "需要重启"
            echo "============================================================"
            echo
            echo "当前   : $CURRENT_KERNEL"
            echo "新版本 : $release"
            echo
            echo "请先重启，进入新内核后再运行脚本。"
            echo

            read -r -p "现在重启？ [y/N] " answer

            if [[ "$answer" =~ ^[Yy]$ ]]; then
                systemctl reboot
            fi

            exit 0
        fi
    done

fi

DEBIAN_META=()

if [[ "$CURRENT_TYPE" == "third" ]]; then
    mapfile -t DEBIAN_META < <(debian_meta_packages)
fi

CLEANUP=()

if [[ "$CURRENT_TYPE" == "debian" ]]; then

    for i in "${!DEBIAN_RELEASES[@]}"; do
        release="${DEBIAN_RELEASES[$i]}"
        pkg="${DEBIAN_PKGS[$i]}"

        [[ "$release" == "$CURRENT_KERNEL" ]] && continue

        base=$(kernel_base "$release")

        if ! release_newer "$base" "$CURRENT_BASE"; then
            CLEANUP+=("$pkg")
        fi
    done

else

    for i in "${!THIRD_RELEASES[@]}"; do
        release="${THIRD_RELEASES[$i]}"
        pkg="${THIRD_PKGS[$i]}"

        [[ "$release" == "$CURRENT_KERNEL" ]] && continue

        CLEANUP+=("$pkg")
    done

    for i in "${!DEBIAN_RELEASES[@]}"; do
        release="${DEBIAN_RELEASES[$i]}"
        pkg="${DEBIAN_PKGS[$i]}"

        [[ "$release" == "$CURRENT_KERNEL" ]] && continue

        CLEANUP+=("$pkg")
    done

fi

mapfile -t CLEANUP < <(
    printf '%s\n' "${CLEANUP[@]}" |
    awk 'NF' |
    sort -u
)

if [[ "$CURRENT_TYPE" == "third" ]]; then

    echo
    echo "============================================================"
    echo "内核清理"
    echo "============================================================"
    echo
    echo "当前内核 : $CURRENT_KERNEL"
    echo "类型     : 第三方内核"
    echo

    echo "Debian 内核:"
    if [[ ${#DEBIAN_RELEASES[@]} -gt 0 ]]; then
        printf '  %s\n' "${DEBIAN_RELEASES[@]}"
    else
        echo "  无"
    fi

    echo
    echo "第三方内核:"
    printf '  %s\n' "$CURRENT_KERNEL"

    for release in "${THIRD_RELEASES[@]}"; do
        [[ "$release" == "$CURRENT_KERNEL" ]] && continue
        printf '  %s\n' "$release"
    done

    echo

    if [[ ${#DEBIAN_META[@]} -gt 0 ]]; then
        echo "Debian 元包:"
        printf '  %s\n' "${DEBIAN_META[@]}"
        echo
        read -r -p "删除 Debian 内核和元包？ [y/N] " answer

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            CLEANUP+=("${DEBIAN_META[@]}")
        fi
    else
        echo "Debian 元包:"
        echo "  无"
    fi

    mapfile -t CLEANUP < <(
        printf '%s\n' "${CLEANUP[@]}" |
        awk 'NF' |
        sort -u
    )

else

    if [[ ${#CLEANUP[@]} -eq 0 ]]; then
        echo
        echo "无需清理。"
        exit 0
    fi

    echo
    echo "============================================================"
    echo "内核清理"
    echo "============================================================"
    echo
    echo "当前内核 : $CURRENT_KERNEL"
    echo "类型     : Debian 内核"
    echo

    echo "Debian 内核:"
    printf '  %s\n' "${DEBIAN_RELEASES[@]}"

    echo
    echo "第三方内核:"
    if [[ ${#THIRD_RELEASES[@]} -gt 0 ]]; then
        printf '  %s\n' "${THIRD_RELEASES[@]}"
    else
        echo "  无"
    fi

fi

if [[ ${#CLEANUP[@]} -eq 0 ]]; then
    echo
    echo "无需清理。"
    exit 0
fi

for pkg in "${CLEANUP[@]}"; do
    if [[ "$pkg" == "$CURRENT_PKG" ]]; then
        echo
        echo "安全检查失败："
        echo "清理列表包含当前运行内核。"
        echo "本次未执行任何操作。"
        exit 1
    fi
done

echo
echo "将删除:"
printf '  %s\n' "${CLEANUP[@]}"

echo
echo "保留:"
echo "  $CURRENT_KERNEL"

echo
echo "APT 安全检查..."

SIMULATION=$(mktemp)

trap 'rm -f "$SIMULATION"' EXIT

if ! apt-get -s \
    --no-install-recommends \
    purge \
    "${CLEANUP[@]}" >"$SIMULATION" 2>&1; then

    echo
    echo "APT 安全检查失败"
    echo
    echo "模拟 purge 未成功。"
    echo "本次未执行任何操作。"
    exit 1
fi

if grep -Eiq \
    'newly installed|to install|will be installed|upgraded|to be upgraded|will be upgraded|reinstalled|to be reinstalled|will be reinstalled|^Inst ' \
    "$SIMULATION"; then

    echo
    echo "APT 安全检查失败"
    echo
    echo "检测到安装、升级或重新安装操作。"
    echo "本次未执行任何操作。"
    exit 1
fi

if ! grep -Eq \
    '^(Remv|The following packages will be REMOVED:)' \
    "$SIMULATION"; then

    echo
    echo "APT 安全检查失败"
    echo
    echo "模拟结果不是纯删除操作。"
    echo "本次未执行任何操作。"
    exit 1
fi

echo "安全检查通过：仅允许删除。"
echo

read -r -p "确认执行？ [y/N] " answer

if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    exit 0
fi

if [[ "$(uname -r)" != "$CURRENT_KERNEL" ]]; then
    echo
    echo "安全检查失败：运行内核已发生变化。"
    echo "本次未执行任何操作。"
    exit 1
fi

apt-get \
    --no-install-recommends \
    purge \
    "${CLEANUP[@]}"
