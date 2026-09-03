#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_VERSION="3.0.0"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

CURRENT_KERNEL=""
CURRENT_TYPE=""

DEBIAN_KERNELS=()
THIRD_PARTY_KERNELS=()

DEBIAN_PACKAGES=()
THIRD_PARTY_PACKAGES=()

DEBIAN_META_PACKAGES=()
THIRD_PARTY_META_PACKAGES=()

CLEANUP_PACKAGES=()

DRY_RUN=0


title() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo
}


warn() {
    echo -e "${YELLOW}$1${RESET}"
}


error() {
    echo -e "${RED}$1${RESET}"
}


success() {
    echo -e "${GREEN}$1${RESET}"
}


die() {
    error "$1"
    exit 1
}


parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                echo "内核清理 $SCRIPT_VERSION"
                echo
                echo "用法："
                echo "  $0"
                echo "  $0 --dry-run"
                exit 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
        shift
    done
}


check_environment() {
    [[ $EUID -eq 0 ]] || die "请使用 root 运行。"

    local cmd
    for cmd in uname dpkg dpkg-query apt-get find awk grep sed sort mktemp; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "缺少命令：$cmd"
    done
}


get_current_kernel() {
    CURRENT_KERNEL="$(uname -r)"
    [[ -n "$CURRENT_KERNEL" ]] ||
        die "无法获取当前运行内核。"
}


is_debian_kernel() {
    local release="$1"

    case "$release" in
        *+deb[0-9]*-amd64)
            return 0
            ;;
        *+deb[0-9]*-cloud-amd64)
            return 0
            ;;
        *+deb[0-9]*-rt-amd64)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


detect_current_type() {
    if is_debian_kernel "$CURRENT_KERNEL"; then
        CURRENT_TYPE="Debian"
    else
        CURRENT_TYPE="ThirdParty"
    fi
}


get_installed_packages() {
    dpkg-query -W \
        -f='${binary:Package}\t${Status}\n' 2>/dev/null |
        awk '$2=="install" && $3=="ok" && $4=="installed" {print $1}'
}


collect_kernel_releases() {
    local release

    DEBIAN_KERNELS=()
    THIRD_PARTY_KERNELS=()

    while read -r release; do
        [[ -n "$release" ]] || continue

        if is_debian_kernel "$release"; then
            DEBIAN_KERNELS+=("$release")
        else
            THIRD_PARTY_KERNELS+=("$release")
        fi
    done < <(
        find /lib/modules \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -printf '%f\n' 2>/dev/null |
        sort -V
    )

    DEBIAN_KERNELS=(
        $(printf '%s\n' "${DEBIAN_KERNELS[@]}" | sort -Vu)
    )

    THIRD_PARTY_KERNELS=(
        $(printf '%s\n' "${THIRD_PARTY_KERNELS[@]}" | sort -Vu)
    )
}


collect_meta_packages() {
    local pkg

    DEBIAN_META_PACKAGES=()
    THIRD_PARTY_META_PACKAGES=()

    while read -r pkg; do
        case "$pkg" in
            linux-image-amd64)
                DEBIAN_META_PACKAGES+=("$pkg")
                ;;
            linux-image-cloud-amd64)
                DEBIAN_META_PACKAGES+=("$pkg")
                ;;
            linux-image-rt-amd64)
                DEBIAN_META_PACKAGES+=("$pkg")
                ;;
            linux-headers-amd64)
                DEBIAN_META_PACKAGES+=("$pkg")
                ;;
            linux-headers-cloud-amd64)
                DEBIAN_META_PACKAGES+=("$pkg")
                ;;
            linux-headers-rt-amd64)
                DEBIAN_META_PACKAGES+=("$pkg")
                ;;
            linux-xanmod-*)
                THIRD_PARTY_META_PACKAGES+=("$pkg")
                ;;
        esac
    done < <(get_installed_packages)

    DEBIAN_META_PACKAGES=(
        $(printf '%s\n' "${DEBIAN_META_PACKAGES[@]}" | sort -u)
    )

    THIRD_PARTY_META_PACKAGES=(
        $(printf '%s\n' "${THIRD_PARTY_META_PACKAGES[@]}" | sort -u)
    )
}


package_release_match() {
    local pkg="$1"
    local release="$2"

    case "$pkg" in
        "linux-image-$release")
            return 0
            ;;
        "linux-modules-$release")
            return 0
            ;;
        "linux-headers-$release")
            return 0
            ;;
        "linux-headers-$release"-*)
            return 0
            ;;
        "linux-image-$release"-*)
            return 0
            ;;
        "linux-modules-$release"-*)
            return 0
            ;;
    esac

    return 1
}


collect_kernel_packages() {
    local pkg release

    DEBIAN_PACKAGES=()
    THIRD_PARTY_PACKAGES=()

    while read -r pkg; do
        [[ -n "$pkg" ]] || continue

        for release in "${DEBIAN_KERNELS[@]}"; do
            if package_release_match "$pkg" "$release"; then
                DEBIAN_PACKAGES+=("$pkg")
                break
            fi
        done

        for release in "${THIRD_PARTY_KERNELS[@]}"; do
            if package_release_match "$pkg" "$release"; then
                THIRD_PARTY_PACKAGES+=("$pkg")
                break
            fi
        done
    done < <(get_installed_packages)

    DEBIAN_PACKAGES=(
        $(printf '%s\n' "${DEBIAN_PACKAGES[@]}" | sort -u)
    )

    THIRD_PARTY_PACKAGES=(
        $(printf '%s\n' "${THIRD_PARTY_PACKAGES[@]}" | sort -u)
    )
}


kernel_base_version() {
    local release="$1"

    case "$release" in
        *+deb*)
            echo "${release%%+deb*}"
            ;;
        *-xanmod*)
            echo "${release%%-xanmod*}"
            ;;
        *-x64v*)
            echo "${release%%-x64v*}"
            ;;
        *)
            echo "$release"
            ;;
    esac
}


kernel_version_gt() {
    local a b

    a="$(kernel_base_version "$1")"
    b="$(kernel_base_version "$2")"

    dpkg --compare-versions "$a" gt "$b"
}


find_pending_kernel() {
    local release

    if [[ "$CURRENT_TYPE" == "Debian" ]]; then
        for release in "${DEBIAN_KERNELS[@]}"; do
            [[ "$release" == "$CURRENT_KERNEL" ]] && continue

            if kernel_version_gt "$release" "$CURRENT_KERNEL"; then
                echo "$release"
                return 0
            fi
        done
    else
        for release in "${THIRD_PARTY_KERNELS[@]}"; do
            [[ "$release" == "$CURRENT_KERNEL" ]] && continue

            if kernel_version_gt "$release" "$CURRENT_KERNEL"; then
                echo "$release"
                return 0
            fi
        done
    fi

    return 1
}


show_header() {
    title "内核清理"

    echo "当前内核 : $CURRENT_KERNEL"

    if [[ "$CURRENT_TYPE" == "Debian" ]]; then
        echo "类型     : Debian 内核"
    else
        echo "类型     : 第三方内核"
    fi

    echo
}


show_kernel_list() {
    echo "Debian 内核:"
    if [[ ${#DEBIAN_KERNELS[@]} -gt 0 ]]; then
        printf '  %s\n' "${DEBIAN_KERNELS[@]}"
    else
        echo "  无"
    fi

    echo
    echo "第三方内核:"
    if [[ ${#THIRD_PARTY_KERNELS[@]} -gt 0 ]]; then
        printf '  %s\n' "${THIRD_PARTY_KERNELS[@]}"
    else
        echo "  无"
    fi

    echo

    if [[ ${#DEBIAN_META_PACKAGES[@]} -gt 0 ]]; then
        echo "Debian 元包:"
        printf '  %s\n' "${DEBIAN_META_PACKAGES[@]}"
        echo
    fi
}


add_cleanup_package() {
    local pkg="$1"
    local item

    [[ -n "$pkg" ]] || return

    for item in "${CLEANUP_PACKAGES[@]}"; do
        [[ "$item" == "$pkg" ]] && return
    done

    CLEANUP_PACKAGES+=("$pkg")
}


add_release_to_cleanup() {
    local release="$1"
    local pkg

    for pkg in "${DEBIAN_PACKAGES[@]}"; do
        if package_release_match "$pkg" "$release"; then
            add_cleanup_package "$pkg"
        fi
    done

    for pkg in "${THIRD_PARTY_PACKAGES[@]}"; do
        if package_release_match "$pkg" "$release"; then
            add_cleanup_package "$pkg"
        fi
    done
}


build_cleanup_for_debian() {
    local release

    CLEANUP_PACKAGES=()

    for release in "${DEBIAN_KERNELS[@]}"; do
        [[ "$release" == "$CURRENT_KERNEL" ]] && continue

        if kernel_version_gt "$release" "$CURRENT_KERNEL"; then
            continue
        fi

        add_release_to_cleanup "$release"
    done
}


build_cleanup_for_third_party() {
    local release

    CLEANUP_PACKAGES=()

    for release in "${THIRD_PARTY_KERNELS[@]}"; do
        [[ "$release" == "$CURRENT_KERNEL" ]] && continue

        if kernel_version_gt "$release" "$CURRENT_KERNEL"; then
            continue
        fi

        add_release_to_cleanup "$release"
    done

    for release in "${DEBIAN_KERNELS[@]}"; do
        [[ "$release" == "$CURRENT_KERNEL" ]] && continue
        add_release_to_cleanup "$release"
    done
}


ask_debian_meta() {
    local answer pkg

    [[ "$CURRENT_TYPE" == "ThirdParty" ]] || return 0
    [[ ${#DEBIAN_META_PACKAGES[@]} -gt 0 ]] || return 0

    echo
    echo "Debian 元包:"
    printf '  %s\n' "${DEBIAN_META_PACKAGES[@]}"
    echo

    read -r -p "删除 Debian 元包？ [y/N] " answer

    case "$answer" in
        y|Y)
            for pkg in "${DEBIAN_META_PACKAGES[@]}"; do
                add_cleanup_package "$pkg"
            done
            ;;
        *)
            ;;
    esac
}


final_safety_check() {
    local pkg

    for pkg in "${CLEANUP_PACKAGES[@]}"; do

        if [[ "$pkg" == *"$CURRENT_KERNEL"* ]]; then
            error "安全检查失败：清理列表包含当前运行内核。"
            return 1
        fi
    done

    return 0
}


show_cleanup_plan() {
    title "清理计划"

    if [[ ${#CLEANUP_PACKAGES[@]} -eq 0 ]]; then
        echo "没有可清理的内核。"
        return 1
    fi

    echo "将删除:"
    printf '  %s\n' "${CLEANUP_PACKAGES[@]}"
    echo

    echo "保留:"
    echo "  $CURRENT_KERNEL"

    return 0
}


apt_safety_check() {
    local tmpfile output

    tmpfile="$(mktemp)" ||
        die "无法创建临时文件。"

    if ! apt-get -s purge \
        --no-install-recommends \
        "${CLEANUP_PACKAGES[@]}" \
        >"$tmpfile" 2>&1; then

        cat "$tmpfile"
        rm -f "$tmpfile"

        error "APT 模拟失败，未执行任何操作。"
        return 1
    fi

    output="$(cat "$tmpfile")"

    echo
    echo "APT 安全检查..."

    if echo "$output" |
        grep -Eqi \
        'newly installed|to install|will be installed|upgraded|to be upgraded|will be upgraded|reinstalled|to be reinstalled|will be reinstalled'; then

        echo
        error "安全检查失败：APT 计划包含安装、升级或重新安装。"
        echo
        echo "$output"

        rm -f "$tmpfile"
        return 1
    fi

    if echo "$output" |
        grep -Eqi \
        'The following NEW packages will be installed|The following packages will be upgraded|The following packages will be reinstalled'; then

        echo
        error "安全检查失败：检测到非删除操作。"
        echo

        rm -f "$tmpfile"
        return 1
    fi

    rm -f "$tmpfile"

    success "安全检查通过：仅允许删除。"

    return 0
}


execute_cleanup() {
    local answer

    if ! apt_safety_check; then
        return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        success "Dry Run：未执行删除。"
        return 0
    fi

    echo
    read -r -p "确认执行删除？ [y/N] " answer

    case "$answer" in
        y|Y)
            ;;
        *)
            echo "已取消。"
            return 0
            ;;
    esac

    if ! apt-get purge \
        --no-install-recommends \
        "${CLEANUP_PACKAGES[@]}"; then

        error "APT 删除过程中出现错误。"
        return 1
    fi

    success "内核清理完成。"
}


handle_pending_kernel() {
    local pending="$1"
    local answer

    title "需要重启"

    echo "当前 : $CURRENT_KERNEL"
    echo "新版本 : $pending"
    echo
    warn "检测到同类型的更高版本内核。"
    echo "请先重启，进入新内核后再运行本脚本。"
    echo

    read -r -p "现在重启？ [y/N] " answer

    case "$answer" in
        y|Y)
            systemctl reboot
            ;;
        *)
            echo "已取消。"
            ;;
    esac
}


cleanup_debian() {
    build_cleanup_for_debian

    if ! final_safety_check; then
        return 1
    fi

    if ! show_cleanup_plan; then
        return 0
    fi

    execute_cleanup
}


cleanup_third_party() {
    build_cleanup_for_third_party

    ask_debian_meta

    if ! final_safety_check; then
        return 1
    fi

    if ! show_cleanup_plan; then
        return 0
    fi

    execute_cleanup
}


main() {
    parse_args "$@"
    check_environment
    get_current_kernel
    detect_current_type

    collect_kernel_releases
    collect_meta_packages
    collect_kernel_packages

    show_header
    show_kernel_list

    local pending

    pending="$(find_pending_kernel || true)"

    if [[ -n "$pending" ]]; then
        handle_pending_kernel "$pending"
        exit 0
    fi

    if [[ "$CURRENT_TYPE" == "Debian" ]]; then
        cleanup_debian
    else
        cleanup_third_party
    fi
}


main "$@"
