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
CURRENT_FAMILY=""
CURRENT_VERSION=""

DEBIAN_KERNELS=()
THIRD_PARTY_KERNELS=()

DEBIAN_PACKAGES=()
THIRD_PARTY_PACKAGES=()

DEBIAN_META_PACKAGES=()
THIRD_PARTY_META_PACKAGES=()

CLEANUP_PACKAGES=()

DRY_RUN=0


print_title() {
    echo
    echo "============================================================"
    echo
    echo "$1"
    echo
    echo "============================================================"
    echo
}


info() {
    echo -e "${CYAN}$1${RESET}"
}


success() {
    echo -e "${GREEN}$1${RESET}"
}


warn() {
    echo -e "${YELLOW}$1${RESET}"
}


error() {
    echo -e "${RED}$1${RESET}"
}


die() {
    error "$1"
    exit 1
}


check_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 运行此脚本。"
}


check_commands() {
    local cmd

    for cmd in uname dpkg dpkg-query apt-get find readlink sed awk grep sort tr; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
    done
}


parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                echo "内核清理脚本 $SCRIPT_VERSION"
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


get_current_kernel() {
    CURRENT_KERNEL="$(uname -r)"
    [[ -n "$CURRENT_KERNEL" ]] || die "无法获取当前运行内核。"
}


is_debian_release() {
    local release="$1"

    case "$release" in
        *+deb[0-9]*-amd64)
            return 0
            ;;
        *-amd64)
            if [[ "$release" == *xanmod* ]]; then
                return 1
            fi

            if [[ "$release" == *x64v* ]]; then
                return 1
            fi

            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


detect_current_family() {
    if is_debian_release "$CURRENT_KERNEL"; then
        CURRENT_FAMILY="Debian"
    else
        CURRENT_FAMILY="ThirdParty"
    fi
}


extract_kernel_version() {
    local release="$1"

    case "$release" in
        *+deb[0-9]*)
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


show_current_kernel() {
    print_title "当前运行内核"

    echo "Kernel Release : $CURRENT_KERNEL"

    if [[ "$CURRENT_FAMILY" == "Debian" ]]; then
        echo "Kernel Family  : Debian 内核"
    else
        echo "Kernel Family  : 第三方内核"
    fi
}


get_installed_packages() {
    dpkg-query -W -f='${binary:Package}\t${Status}\n' 2>/dev/null |
        awk '$2=="install" && $3=="ok" && $4=="installed" {print $1}'
}


collect_kernel_packages() {
    local pkg release

    DEBIAN_PACKAGES=()
    THIRD_PARTY_PACKAGES=()

    while read -r pkg; do
        [[ -n "$pkg" ]] || continue

        case "$pkg" in
            linux-image-*|linux-modules-*|linux-headers-*)
                ;;
            *)
                continue
                ;;
        esac

        case "$pkg" in
            linux-image-amd64|linux-image-cloud-amd64|linux-image-rt-amd64)
                continue
                ;;
            linux-headers-amd64|linux-headers-cloud-amd64|linux-headers-rt-amd64)
                continue
                ;;
            linux-image-*-amd64)
                release="${pkg#linux-image-}"

                if is_debian_release "$release"; then
                    DEBIAN_PACKAGES+=("$pkg")
                fi
                ;;
        esac
    done < <(get_installed_packages)


    while read -r release; do
        [[ -n "$release" ]] || continue

        [[ -d "/lib/modules/$release" ]] || continue

        if is_debian_release "$release"; then
            DEBIAN_KERNELS+=("$release")
        else
            THIRD_PARTY_KERNELS+=("$release")
        fi
    done < <(
        find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
            sort -V
    )


    DEBIAN_KERNELS=($(printf '%s\n' "${DEBIAN_KERNELS[@]}" | sort -Vu))
    THIRD_PARTY_KERNELS=($(printf '%s\n' "${THIRD_PARTY_KERNELS[@]}" | sort -Vu))
}


collect_kernel_package_by_release() {
    local release="$1"
    local pkg

    dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
        while read -r pkg; do
            case "$pkg" in
                *"$release"*)
                    echo "$pkg"
                    ;;
            esac
        done
}


collect_real_kernel_packages() {
    local release pkg

    DEBIAN_PACKAGES=()
    THIRD_PARTY_PACKAGES=()

    for release in "${DEBIAN_KERNELS[@]}"; do
        while read -r pkg; do
            [[ -n "$pkg" ]] || continue

            case "$pkg" in
                linux-image-"$release"|linux-image-"$release":*)
                    DEBIAN_PACKAGES+=("$pkg")
                    ;;
                linux-modules-"$release"|linux-modules-"$release":*)
                    DEBIAN_PACKAGES+=("$pkg")
                    ;;
                linux-headers-"$release"|linux-headers-"$release":*)
                    DEBIAN_PACKAGES+=("$pkg")
                    ;;
                linux-headers-"$release"-*)
                    DEBIAN_PACKAGES+=("$pkg")
                    ;;
            esac
        done < <(collect_kernel_package_by_release "$release")
    done


    for release in "${THIRD_PARTY_KERNELS[@]}"; do
        while read -r pkg; do
            [[ -n "$pkg" ]] || continue

            case "$pkg" in
                *"$release"*)
                    THIRD_PARTY_PACKAGES+=("$pkg")
                    ;;
            esac
        done < <(collect_kernel_package_by_release "$release")
    done


    DEBIAN_PACKAGES=($(printf '%s\n' "${DEBIAN_PACKAGES[@]}" | sort -u))
    THIRD_PARTY_PACKAGES=($(printf '%s\n' "${THIRD_PARTY_PACKAGES[@]}" | sort -u))
}


collect_meta_packages() {
    DEBIAN_META_PACKAGES=()
    THIRD_PARTY_META_PACKAGES=()

    while read -r pkg; do
        case "$pkg" in
            linux-image-amd64|linux-image-cloud-amd64|linux-image-rt-amd64)
                DEBIAN_META_PACKAGES+=("$pkg")
                ;;
            linux-headers-amd64|linux-headers-cloud-amd64|linux-headers-rt-amd64)
                DEBIAN_META_PACKAGES+=("$pkg")
                ;;
        esac
    done < <(get_installed_packages)


    while read -r pkg; do
        case "$pkg" in
            *xanmod*)
                THIRD_PARTY_META_PACKAGES+=("$pkg")
                ;;
        esac
    done < <(get_installed_packages)


    DEBIAN_META_PACKAGES=($(printf '%s\n' "${DEBIAN_META_PACKAGES[@]}" | sort -u))
    THIRD_PARTY_META_PACKAGES=($(printf '%s\n' "${THIRD_PARTY_META_PACKAGES[@]}" | sort -u))
}


package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null |
        grep -q '^install ok installed$'
}


version_greater() {
    dpkg --compare-versions "$1" gt "$2"
}


kernel_release_greater() {
    local a="$1"
    local b="$2"

    local va vb

    va="$(extract_kernel_version "$a")"
    vb="$(extract_kernel_version "$b")"

    version_greater "$va" "$vb"
}


find_pending_kernel() {
    local release

    for release in "${DEBIAN_KERNELS[@]}"; do
        [[ "$CURRENT_FAMILY" == "Debian" ]] || continue

        if kernel_release_greater "$release" "$CURRENT_KERNEL"; then
            echo "$release"
            return 0
        fi
    done


    for release in "${THIRD_PARTY_KERNELS[@]}"; do
        [[ "$CURRENT_FAMILY" == "ThirdParty" ]] || continue

        if kernel_release_greater "$release" "$CURRENT_KERNEL"; then
            echo "$release"
            return 0
        fi
    done

    return 1
}


handle_pending_kernel() {
    local pending="$1"

    print_title "检测到尚未运行的新内核"

    echo "当前运行："
    echo "  $CURRENT_KERNEL"
    echo

    echo "已安装的更高版本："
    echo "  $pending"
    echo

    warn "当前运行内核不是系统中该内核族的最高版本。"
    warn "本次不会删除任何内核或元包。"
    echo
    echo "请先重启系统，使新内核生效。"
    echo "重启后再次运行本脚本。"
    echo

    read -r -p "现在重启系统？ [y/N] " answer

    case "$answer" in
        y|Y)
            systemctl reboot
            ;;
        *)
            echo "已取消。"
            ;;
    esac
}


show_kernel_summary() {
    print_title "系统内核概况"

    echo "当前运行："
    echo "  $CURRENT_KERNEL"
    echo

    if [[ "$CURRENT_FAMILY" == "Debian" ]]; then
        echo "当前内核类型："
        echo "  Debian 内核"
    else
        echo "当前内核类型："
        echo "  第三方内核"
    fi

    echo

    echo "Debian 内核："
    if [[ ${#DEBIAN_KERNELS[@]} -eq 0 ]]; then
        echo "  无"
    else
        printf '  %s\n' "${DEBIAN_KERNELS[@]}"
    fi

    echo

    echo "第三方内核："
    if [[ ${#THIRD_PARTY_KERNELS[@]} -eq 0 ]]; then
        echo "  无"
    else
        printf '  %s\n' "${THIRD_PARTY_KERNELS[@]}"
    fi

    echo

    echo "Debian 元包："
    if [[ ${#DEBIAN_META_PACKAGES[@]} -eq 0 ]]; then
        echo "  无"
    else
        printf '  %s\n' "${DEBIAN_META_PACKAGES[@]}"
    fi

    echo

    echo "第三方元包："
    if [[ ${#THIRD_PARTY_META_PACKAGES[@]} -eq 0 ]]; then
        echo "  无"
    else
        printf '  %s\n' "${THIRD_PARTY_META_PACKAGES[@]}"
    fi
}


add_package_once() {
    local pkg="$1"

    [[ -n "$pkg" ]] || return

    if [[ "$pkg" == "$CURRENT_KERNEL" ]]; then
        return
    fi

    local existing

    for existing in "${CLEANUP_PACKAGES[@]}"; do
        [[ "$existing" == "$pkg" ]] && return
    done

    CLEANUP_PACKAGES+=("$pkg")
}


add_release_packages() {
    local release="$1"
    local pkg

    for pkg in "${DEBIAN_PACKAGES[@]}" "${THIRD_PARTY_PACKAGES[@]}"; do
        if [[ "$pkg" == *"$release"* ]]; then
            add_package_once "$pkg"
        fi
    done
}


build_debian_cleanup() {
    local release

    CLEANUP_PACKAGES=()

    for release in "${DEBIAN_KERNELS[@]}"; do
        [[ "$release" == "$CURRENT_KERNEL" ]] && continue

        if [[ "$CURRENT_FAMILY" == "Debian" ]]; then
            if kernel_release_greater "$release" "$CURRENT_KERNEL"; then
                continue
            fi
        fi

        add_release_packages "$release"
    done
}


build_third_party_cleanup() {
    local release

    for release in "${THIRD_PARTY_KERNELS[@]}"; do
        [[ "$release" == "$CURRENT_KERNEL" ]] && continue

        if kernel_release_greater "$release" "$CURRENT_KERNEL"; then
            continue
        fi

        add_release_packages "$release"
    done
}


final_safety_filter() {
    local filtered=()
    local pkg release

    for pkg in "${CLEANUP_PACKAGES[@]}"; do
        [[ -n "$pkg" ]] || continue

        for release in "$CURRENT_KERNEL"; do
            if [[ "$pkg" == *"$release"* ]]; then
                warn "安全保护：跳过当前运行内核相关软件包：$pkg"
                pkg=""
                break
            fi
        done

        [[ -n "$pkg" ]] && filtered+=("$pkg")
    done

    CLEANUP_PACKAGES=("${filtered[@]}")
}


show_cleanup_list() {
    print_title "计划清理的软件包"

    if [[ ${#CLEANUP_PACKAGES[@]} -eq 0 ]]; then
        echo "没有可以安全清理的软件包。"
        return 1
    fi

    printf '  - %s\n' "${CLEANUP_PACKAGES[@]}"
    echo

    return 0
}


apt_simulation_safe() {
    local output
    local tmpfile

    tmpfile="$(mktemp)"

    if ! apt-get -s purge \
        --no-install-recommends \
        "${CLEANUP_PACKAGES[@]}" >"$tmpfile" 2>&1; then

        cat "$tmpfile"
        rm -f "$tmpfile"

        error "APT 模拟失败，本次不会执行任何操作。"
        return 1
    fi

    output="$(cat "$tmpfile")"

    echo
    echo "APT 模拟结果："
    echo "------------------------------------------------------------"
    echo "$output"
    echo "------------------------------------------------------------"
    echo

    if echo "$output" |
        grep -Eqi \
        'newly installed|to install|will be installed|upgraded|to be upgraded|will be upgraded|reinstalled|to be reinstalled|will be reinstalled'; then

        error "APT 安全检查失败。"
        error "清理操作会触发安装、升级或重新安装软件包。"
        error "本次不会执行任何操作。"

        rm -f "$tmpfile"
        return 1
    fi

    if echo "$output" |
        grep -Eqi \
        'The following NEW packages will be installed|The following packages will be upgraded|The following packages will be reinstalled'; then

        error "APT 安全检查失败。"
        error "检测到安装、升级或重新安装操作。"
        error "本次不会执行任何操作。"

        rm -f "$tmpfile"
        return 1
    fi

    rm -f "$tmpfile"

    success "APT 安全检查通过：没有安装、升级或重新安装操作。"

    return 0
}


purge_packages() {
    local answer

    echo
    read -r -p "确认删除以上内核软件包？ [y/N] " answer

    case "$answer" in
        y|Y)
            ;;
        *)
            echo "已取消。"
            return 0
            ;;
    esac

    if ! apt_simulation_safe; then
        return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        success "Dry Run：不会执行实际删除。"
        return 0
    fi

    echo
    read -r -p "APT 安全检查已通过，确认执行删除？ [y/N] " answer

    case "$answer" in
        y|Y)
            ;;
        *)
            echo "已取消。"
            return 0
            ;;
    esac

    apt-get purge \
        --no-install-recommends \
        "${CLEANUP_PACKAGES[@]}"
}


ask_remove_debian_meta() {
    local answer
    local pkg

    [[ "$CURRENT_FAMILY" == "ThirdParty" ]] || return 0

    [[ ${#DEBIAN_META_PACKAGES[@]} -gt 0 ]] || return 0

    print_title "Debian 内核元包"

    echo "检测到 Debian 内核元包："
    printf '  - %s\n' "${DEBIAN_META_PACKAGES[@]}"
    echo

    echo "当前运行的是第三方内核。"
    echo "如果保留 Debian 元包，APT 可能要求安装新的 Debian 内核。"
    echo
    echo "本脚本禁止任何内核或元包安装、升级。"
    echo

    read -r -p "是否删除以上 Debian 内核元包？ [y/N] " answer

    case "$answer" in
        y|Y)
            for pkg in "${DEBIAN_META_PACKAGES[@]}"; do
                add_package_once "$pkg"
            done

            success "已将 Debian 内核元包加入本次清理。"
            ;;
        *)
            warn "保留 Debian 内核元包。"
            ;;
    esac
}


handle_last_debian_kernel() {
    local debian_count

    debian_count="${#DEBIAN_KERNELS[@]}"

    [[ "$CURRENT_FAMILY" == "ThirdParty" ]] || return 0
    [[ "$debian_count" -gt 0 ]] || return 0
    [[ "$debian_count" -gt 1 ]] || true

    if [[ ${#DEBIAN_META_PACKAGES[@]} -gt 0 ]]; then
        local release
        local removable_count=0

        for release in "${DEBIAN_KERNELS[@]}"; do
            [[ "$release" == "$CURRENT_KERNEL" ]] && continue
            removable_count=$((removable_count + 1))
        done

        if [[ "$removable_count" -le 1 ]]; then
            if printf '%s\n' "${CLEANUP_PACKAGES[@]}" |
                grep -q '^linux-image-' &&
                printf '%s\n' "${CLEANUP_PACKAGES[@]}" |
                grep -q '^linux-image-'; then
                :
            fi
        fi
    fi
}


cleanup_running_debian() {
    print_title "当前运行 Debian 内核"

    echo "当前：$CURRENT_KERNEL"
    echo
    echo "将处理："
    echo "  - 清理旧 Debian 内核"
    echo "  - 保留当前 Debian 内核"
    echo "  - 保留 Debian 内核元包"
    echo "  - 不处理第三方内核"
    echo "  - 不处理第三方元包"
    echo

    build_debian_cleanup
    final_safety_filter

    show_cleanup_list || return 0

    purge_packages
}


cleanup_running_third_party() {
    print_title "当前运行第三方内核"

    echo "当前：$CURRENT_KERNEL"
    echo
    echo "将处理："
    echo "  - 清理旧第三方内核"
    echo "  - 清理 Debian 内核"
    echo "  - 保留当前第三方内核"
    echo "  - 第三方内核元包不处理"
    echo

    build_third_party_cleanup

    ask_remove_debian_meta

    final_safety_filter

    if [[ ${#CLEANUP_PACKAGES[@]} -eq 0 ]]; then
        warn "没有可以安全清理的软件包。"
        return 0
    fi

    if ! show_cleanup_list; then
        return 0
    fi

    purge_packages
}


main() {
    parse_args "$@"

    check_root
    check_commands
    get_current_kernel
    detect_current_family

    collect_kernel_packages
    collect_meta_packages
    collect_real_kernel_packages

    show_current_kernel
    show_kernel_summary

    local pending

    pending="$(find_pending_kernel || true)"

    if [[ -n "$pending" ]]; then
        handle_pending_kernel "$pending"
        exit 0
    fi

    if [[ "$CURRENT_FAMILY" == "Debian" ]]; then
        cleanup_running_debian
    else
        cleanup_running_third_party
    fi
}


main "$@"
