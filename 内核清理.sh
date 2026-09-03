#!/usr/bin/env bash

VERSION="4.0.0"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行。"
    exit 1
fi

if ! command -v dpkg-query >/dev/null 2>&1 ||
   ! command -v apt-get >/dev/null 2>&1; then
    echo "缺少 dpkg-query 或 apt-get。"
    exit 1
fi

CURRENT_KERNEL=$(uname -r)

kernel_pkg() {
    local r="$1"
    local p

    for p in "linux-image-$r" "linux-image-unsigned-$r"; do
        if dpkg-query -W -f='${Status}' "$p" 2>/dev/null |
            grep -qx 'install ok installed'; then
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

classify_kernel() {
    local r="$1"
    local p="$2"
    local src

    src=$(pkg_source "$p")

    case "$r" in
        *+deb[0-9]*-*)
            echo "debian"
            return
            ;;
    esac

    case "$src:$p:$r" in
        *xanmod*)
            echo "third"
            return
            ;;
    esac

    echo "third"
}

kernel_base() {
    local r="$1"

    case "$r" in
        *+*)
            printf '%s\n' "${r%%+*}"
            ;;
        *-xanmod*)
            printf '%s\n' "${r%%-xanmod*}"
            ;;
        *-x64v[0-9]*)
            printf '%s\n' "${r%%-x64v[0-9]*}"
            ;;
        *-*)
            printf '%s\n' "${r%%-*}"
            ;;
        *)
            printf '%s\n' "$r"
            ;;
    esac
}

is_newer() {
    dpkg --compare-versions "$1" gt "$2"
}

mapfile -t RELEASES < <(
    find /lib/modules \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' 2>/dev/null |
    sort -V
)

DEBIAN_RELEASES=()
DEBIAN_PKGS=()

THIRD_RELEASES=()
THIRD_PKGS=()

CURRENT_PKG=$(kernel_pkg "$CURRENT_KERNEL" || true)

if [[ -z "$CURRENT_PKG" ]]; then
    echo "无法确定当前运行内核对应的内核包。"
    exit 1
fi

CURRENT_TYPE=$(classify_kernel "$CURRENT_KERNEL" "$CURRENT_PKG")
CURRENT_BASE=$(kernel_base "$CURRENT_KERNEL")
CURRENT_PKG_VERSION=$(pkg_version "$CURRENT_PKG")

for r in "${RELEASES[@]}"; do
    [[ "$r" == "$CURRENT_KERNEL" ]] && continue

    p=$(kernel_pkg "$r" || true)
    [[ -z "$p" ]] && continue

    type=$(classify_kernel "$r" "$p")

    if [[ "$type" == "debian" ]]; then
        DEBIAN_RELEASES+=("$r")
        DEBIAN_PKGS+=("$p")
    else
        THIRD_RELEASES+=("$r")
        THIRD_PKGS+=("$p")
    fi
done

if [[ "$CURRENT_TYPE" == "debian" ]]; then
    for i in "${!DEBIAN_RELEASES[@]}"; do
        r="${DEBIAN_RELEASES[$i]}"
        p="${DEBIAN_PKGS[$i]}"

        b=$(kernel_base "$r")
        v=$(pkg_version "$p")

        if is_newer "$b" "$CURRENT_BASE" ||
           {
               [[ "$b" == "$CURRENT_BASE" ]] &&
               is_newer "$v" "$CURRENT_PKG_VERSION"
           }; then

            echo
            echo "============================================================"
            echo "需要重启"
            echo "============================================================"
            echo
            echo "当前   : $CURRENT_KERNEL"
            echo "新版本 : $r"
            echo
            echo "请先重启，进入新内核后再运行脚本。"
            echo

            read -r -p "现在重启？ [y/N] " ans

            if [[ "$ans" =~ ^[Yy]$ ]]; then
                systemctl reboot
            fi

            exit 0
        fi
    done
fi

if [[ "$CURRENT_TYPE" == "third" ]]; then
    for i in "${!THIRD_RELEASES[@]}"; do
        r="${THIRD_RELEASES[$i]}"
        p="${THIRD_PKGS[$i]}"

        b=$(kernel_base "$r")
        v=$(pkg_version "$p")

        if is_newer "$b" "$CURRENT_BASE" ||
           {
               [[ "$b" == "$CURRENT_BASE" ]] &&
               is_newer "$v" "$CURRENT_PKG_VERSION"
           }; then

            echo
            echo "============================================================"
            echo "需要重启"
            echo "============================================================"
            echo
            echo "当前   : $CURRENT_KERNEL"
            echo "新版本 : $r"
            echo
            echo "请先重启，进入新内核后再运行脚本。"
            echo

            read -r -p "现在重启？ [y/N] " ans

            if [[ "$ans" =~ ^[Yy]$ ]]; then
                systemctl reboot
            fi

            exit 0
        fi
    done
fi

DEBIAN_META=()

if [[ "$CURRENT_TYPE" == "third" ]]; then
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue

        case "$p" in
            linux-image-amd64|linux-image-arm64)
                DEBIAN_META+=("$p")
                ;;
            linux-image-cloud-amd64|linux-image-cloud-arm64)
                DEBIAN_META+=("$p")
                ;;
            linux-image-rt-amd64|linux-image-rt-arm64)
                DEBIAN_META+=("$p")
                ;;
        esac
    done < <(
        dpkg-query \
            -W \
            -f='${binary:Package}\t${Status}\n' \
            'linux-image-*' 2>/dev/null |
        awk -F '\t' '$2=="install ok installed"{print $1}' |
        sort -u
    )
fi

CLEANUP=()

if [[ "$CURRENT_TYPE" == "debian" ]]; then

    for i in "${!DEBIAN_PKGS[@]}"; do
        r="${DEBIAN_RELEASES[$i]}"
        p="${DEBIAN_PKGS[$i]}"

        b=$(kernel_base "$r")
        v=$(pkg_version "$p")

        if ! is_newer "$b" "$CURRENT_BASE" &&
           ! {
               [[ "$b" == "$CURRENT_BASE" ]] &&
               is_newer "$v" "$CURRENT_PKG_VERSION"
           }; then

            CLEANUP+=("$p")
        fi
    done

else

    CLEANUP+=("${THIRD_PKGS[@]}")
    CLEANUP+=("${DEBIAN_PKGS[@]}")

fi

mapfile -t CLEANUP < <(
    printf '%s\n' "${CLEANUP[@]}" |
    awk 'NF' |
    sort -u
)

if [[ "$CURRENT_TYPE" == "third" && ${#DEBIAN_META[@]} -gt 0 ]]; then

    echo
    echo "============================================================"
    echo "内核清理"
    echo "============================================================"
    echo
    echo "当前内核 : $CURRENT_KERNEL"
    echo "类型     : 第三方内核"
    echo
    echo "Debian 内核:"

    if [[ ${#DEBIAN_PKGS[@]} -gt 0 ]]; then
        printf '  %s\n' "${DEBIAN_RELEASES[@]}"
    else
        echo "  无"
    fi

    echo
    echo "第三方内核:"
    echo "  $CURRENT_KERNEL"

    if [[ ${#THIRD_RELEASES[@]} -gt 0 ]]; then
        printf '  %s\n' "${THIRD_RELEASES[@]}"
    fi

    echo
    echo "Debian 元包:"
    printf '  %s\n' "${DEBIAN_META[@]}"
    echo

    read -r -p "删除 Debian 元包？ [y/N] " ans

    if [[ "$ans" =~ ^[Yy]$ ]]; then
        CLEANUP+=("${DEBIAN_META[@]}")

        mapfile -t CLEANUP < <(
            printf '%s\n' "${CLEANUP[@]}" |
            awk 'NF' |
            sort -u
        )
    fi
fi

if [[ ${#CLEANUP[@]} -eq 0 ]]; then
    echo
    echo "无需清理。"
    exit 0
fi

for p in "${CLEANUP[@]}"; do
    if [[ "$p" == "$CURRENT_PKG" ]]; then
        echo "安全检查失败：清理列表包含当前运行内核。"
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

SIM=$(mktemp)
trap 'rm -f "$SIM"' EXIT

if ! apt-get -s purge \
    --no-install-recommends \
    "${CLEANUP[@]}" >"$SIM" 2>&1; then

    echo
    echo "APT 安全检查失败"
    echo
    echo "模拟 purge 未成功。"
    echo "本次未执行任何操作。"
    exit 1
fi

if grep -Eiq \
    'newly installed|to install|will be installed|upgraded|to be upgraded|will be upgraded|reinstalled|to be reinstalled|will be reinstalled|^Inst ' \
    "$SIM"; then

    echo
    echo "APT 安全检查失败"
    echo
    echo "检测到安装、升级或重新安装操作。"
    echo "本次未执行任何操作。"
    exit 1
fi

if ! grep -Eq \
    '^(Remv|The following packages will be REMOVED:)' \
    "$SIM"; then

    echo
    echo "APT 安全检查失败"
    echo
    echo "模拟结果不是纯删除操作。"
    echo "本次未执行任何操作。"
    exit 1
fi

echo "安全检查通过：仅允许删除。"
echo

read -r -p "确认执行？ [y/N] " ans

[[ "$ans" =~ ^[Yy]$ ]] || exit 0

if [[ "$(uname -r)" != "$CURRENT_KERNEL" ]]; then
    echo "安全检查失败：运行内核已发生变化。"
    exit 1
fi

apt-get purge \
    --no-install-recommends \
    "${CLEANUP[@]}"
