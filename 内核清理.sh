#!/usr/bin/env bash

# Debian / Third-party Kernel Cleanup

set -u
set -o pipefail

SCRIPT_VERSION="2.0.0"

if [[ -t 1 ]]; then
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    BLUE='\033[34m'
    CYAN='\033[36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    RESET=''
fi

DRY_RUN=0

CURRENT_KERNEL=""
CURRENT_FAMILY=""
CURRENT_VERSION=""

declare -a Y_KERNELS=()
declare -a X_KERNELS=()
declare -a Y_PACKAGES=()
declare -a X_PACKAGES=()
declare -a Y_META_PACKAGES=()
declare -a CLEANUP_PACKAGES=()
declare -a PENDING_KERNELS=()

info() {
    echo -e "${BLUE}[INFO]${RESET} $*"
}

success() {
    echo -e "${GREEN}[OK]${RESET} $*"
}

warning() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

die() {
    error "$*"
    exit 1
}

separator() {
    echo
    echo "============================================================"
    echo
}

usage() {
    cat <<EOF

Kernel Cleanup Script ${SCRIPT_VERSION}

用法：
    sudo $0
    sudo $0 --dry-run
    sudo $0 --help

参数：
    --dry-run, -n    仅检测，不执行删除
    --help, -h       显示帮助

EOF
}

parse_args() {
    case "${1:-}" in
        "")
            ;;
        --dry-run|-n)
            DRY_RUN=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "未知参数：$1"
            ;;
    esac
}

check_root() {
    [[ "${EUID}" -eq 0 ]] || die "必须使用 root 权限运行。"
}

check_commands() {
    local cmd

    for cmd in uname dpkg dpkg-query apt-get find grep sed awk sort; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "缺少必要命令：$cmd"
    done
}

get_current_kernel() {
    CURRENT_KERNEL="$(uname -r)"
    [[ -n "$CURRENT_KERNEL" ]] ||
        die "无法获取当前运行内核。"

    CURRENT_VERSION="$CURRENT_KERNEL"
}

is_debian_kernel_release() {
    local release="$1"

    case "$release" in
        *-amd64)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

detect_current_family() {
    if is_debian_kernel_release "$CURRENT_KERNEL"; then
        CURRENT_FAMILY="Y"
    else
        CURRENT_FAMILY="X"
    fi
}

show_current_kernel() {
    separator

    echo -e "${BOLD}当前运行内核${RESET}"
    echo
    echo "Kernel Release : ${CURRENT_KERNEL}"

    if [[ "$CURRENT_FAMILY" == "Y" ]]; then
        echo -e "Kernel Family  : ${GREEN}Y / Debian 官方内核${RESET}"
    else
        echo -e "Kernel Family  : ${CYAN}X / 第三方内核${RESET}"
    fi

    echo
}

collect_y_kernel_packages() {
    Y_PACKAGES=()

    local pkg

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue

        case "$pkg" in
            linux-image-amd64)
                continue
                ;;
            linux-image-cloud-amd64)
                continue
                ;;
            linux-image-rt-amd64)
                continue
                ;;
            linux-image-*-amd64)
                Y_PACKAGES+=("$pkg")
                ;;
        esac
    done < <(
        dpkg-query \
            -W \
            -f='${binary:Package}\n' \
            'linux-image*' \
            2>/dev/null |
        sort -u
    )
}

image_package_to_release() {
    local pkg="$1"

    case "$pkg" in
        linux-image-*-amd64)
            echo "${pkg#linux-image-}"
            ;;
        *)
            echo ""
            ;;
    esac
}

kernel_exists() {
    local release="$1"

    [[ -e "/boot/vmlinuz-${release}" ]] ||
    [[ -d "/lib/modules/${release}" ]]
}

collect_y_kernels() {
    Y_KERNELS=()

    local pkg
    local release

    for pkg in "${Y_PACKAGES[@]}"; do
        release="$(image_package_to_release "$pkg")"

        [[ -z "$release" ]] && continue

        if kernel_exists "$release"; then
            Y_KERNELS+=("$release")
        fi
    done

    mapfile -t Y_KERNELS < <(
        printf '%s\n' "${Y_KERNELS[@]}" |
        sort -u
    )
}

collect_all_kernel_releases() {
    find /lib/modules \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' 2>/dev/null |
    sort -u
}

collect_x_kernels() {
    X_KERNELS=()

    local release

    while IFS= read -r release; do
        [[ -z "$release" ]] && continue

        if ! is_debian_kernel_release "$release"; then
            X_KERNELS+=("$release")
        fi
    done < <(collect_all_kernel_releases)

    mapfile -t X_KERNELS < <(
        printf '%s\n' "${X_KERNELS[@]}" |
        sort -u
    )
}

collect_y_meta_packages() {
    Y_META_PACKAGES=()

    local pkg

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue

        case "$pkg" in
            linux-image-amd64)
                Y_META_PACKAGES+=("$pkg")
                ;;
            linux-headers-amd64)
                Y_META_PACKAGES+=("$pkg")
                ;;
            linux-image-cloud-amd64)
                Y_META_PACKAGES+=("$pkg")
                ;;
            linux-headers-cloud-amd64)
                Y_META_PACKAGES+=("$pkg")
                ;;
            linux-image-rt-amd64)
                Y_META_PACKAGES+=("$pkg")
                ;;
            linux-headers-rt-amd64)
                Y_META_PACKAGES+=("$pkg")
                ;;
        esac
    done < <(
        dpkg-query \
            -W \
            -f='${binary:Package}\n' \
            2>/dev/null |
        sort -u
    )
}

package_installed() {
    local pkg="$1"

    dpkg-query \
        -W \
        -f='${Status}' \
        "$pkg" 2>/dev/null |
    grep -q '^install ok installed$'
}

version_gt() {
    local a="$1"
    local b="$2"

    dpkg --compare-versions "$a" gt "$b"
}

find_pending_kernel() {
    PENDING_KERNELS=()

    local kernel

    if [[ "$CURRENT_FAMILY" == "Y" ]]; then

        for kernel in "${Y_KERNELS[@]}"; do
            [[ "$kernel" == "$CURRENT_KERNEL" ]] && continue

            if version_gt "$kernel" "$CURRENT_KERNEL"; then
                PENDING_KERNELS+=("$kernel")
            fi
        done

    else

        for kernel in "${X_KERNELS[@]}"; do
            [[ "$kernel" == "$CURRENT_KERNEL" ]] && continue

            if version_gt "$kernel" "$CURRENT_KERNEL"; then
                PENDING_KERNELS+=("$kernel")
            fi
        done

    fi

    [[ "${#PENDING_KERNELS[@]}" -gt 0 ]]
}

handle_pending_reboot() {
    separator

    echo -e "${YELLOW}${BOLD}检测到当前内核族存在更新版本${RESET}"
    echo

    echo "当前运行："
    echo -e "  ${GREEN}${CURRENT_KERNEL}${RESET}"
    echo

    echo "检测到："

    local kernel

    for kernel in "${PENDING_KERNELS[@]}"; do
        echo -e "  ${YELLOW}${kernel}${RESET}"
    done

    echo
    echo "请先重启系统，再重新运行本脚本。"
    echo

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 不执行重启。"
        return 0
    fi

    read -r -p "是否现在重启？ [y/N] " answer

    case "$answer" in
        y|Y|yes|YES)
            info "系统即将重启..."
            sleep 2
            systemctl reboot
            ;;
        *)
            info "取消重启。"
            info "本次没有删除任何内核。"
            ;;
    esac
}

is_current_kernel() {
    local release="$1"

    [[ "$release" == "$CURRENT_KERNEL" ]]
}

build_y_cleanup_list() {
    CLEANUP_PACKAGES=()

    local pkg
    local release

    for pkg in "${Y_PACKAGES[@]}"; do

        release="$(image_package_to_release "$pkg")"

        [[ -z "$release" ]] && continue

        if is_current_kernel "$release"; then
            continue
        fi

        if version_gt "$release" "$CURRENT_KERNEL"; then
            continue
        fi

        CLEANUP_PACKAGES+=("$pkg")
    done

    mapfile -t CLEANUP_PACKAGES < <(
        printf '%s\n' "${CLEANUP_PACKAGES[@]}" |
        sort -u
    )
}

add_y_headers_for_release() {
    local release="$1"
    local base
    local pkg

    base="${release%-amd64}"

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue

        case "$pkg" in
            linux-headers-"${base}"*)
                CLEANUP_PACKAGES+=("$pkg")
                ;;
        esac
    done < <(
        dpkg-query \
            -W \
            -f='${binary:Package}\n' \
            'linux-headers*' \
            2>/dev/null |
        sort -u
    )
}

add_y_headers() {
    local pkg
    local release

    local original=(
        "${CLEANUP_PACKAGES[@]}"
    )

    for pkg in "${original[@]}"; do

        case "$pkg" in
            linux-image-*-amd64)

                release="$(image_package_to_release "$pkg")"

                [[ -z "$release" ]] && continue

                add_y_headers_for_release "$release"

                ;;
        esac
    done

    mapfile -t CLEANUP_PACKAGES < <(
        printf '%s\n' "${CLEANUP_PACKAGES[@]}" |
        sort -u
    )
}

build_x_cleanup_list() {
    local kernel
    local pkg

    for kernel in "${X_KERNELS[@]}"; do

        if is_current_kernel "$kernel"; then
            continue
        fi

        if version_gt "$kernel" "$CURRENT_KERNEL"; then
            continue
        fi

        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            CLEANUP_PACKAGES+=("$pkg")
        done < <(
            dpkg-query \
                -W \
                -f='${binary:Package}\n' \
                2>/dev/null |
            grep -E \
                "^linux-(image|modules|headers)-${kernel}($|-)" |
            sort -u
        )
    done
}

build_all_y_cleanup_list() {
    local pkg
    local y_release

    for pkg in "${Y_PACKAGES[@]}"; do
        CLEANUP_PACKAGES+=("$pkg")
    done

    for y_release in "${Y_KERNELS[@]}"; do
        add_y_headers_for_release "$y_release"
    done

    mapfile -t CLEANUP_PACKAGES < <(
        printf '%s\n' "${CLEANUP_PACKAGES[@]}" |
        sort -u
    )
}

final_safety_check() {
    local pkg
    local release

    for pkg in "${CLEANUP_PACKAGES[@]}"; do

        case "$pkg" in

            linux-image-*-amd64)

                release="$(image_package_to_release "$pkg")"

                if [[ "$release" == "$CURRENT_KERNEL" ]]; then
                    die "安全检查失败：${pkg} 对应当前运行内核。"
                fi

                ;;

            linux-modules-*)

                if [[ "$pkg" == *"$CURRENT_KERNEL"* ]]; then
                    die "安全检查失败：${pkg} 可能属于当前运行内核。"
                fi

                ;;

        esac
    done
}

show_cleanup_list() {
    separator

    echo -e "${BOLD}计划清理的软件包${RESET}"
    echo

    if [[ "${#CLEANUP_PACKAGES[@]}" -eq 0 ]]; then
        echo "没有需要清理的软件包。"
        return
    fi

    local pkg

    for pkg in "${CLEANUP_PACKAGES[@]}"; do
        echo "  - ${pkg}"
    done

    echo
}

purge_packages() {

    [[ "${#CLEANUP_PACKAGES[@]}" -gt 0 ]] ||
        return 0

    final_safety_check
    show_cleanup_list

    read -r -p "确认删除以上内核软件包？ [y/N] " answer

    case "$answer" in

        y|Y|yes|YES)

            if [[ "$DRY_RUN" -eq 1 ]]; then

                echo
                echo -e "${CYAN}[dry-run] 不执行 apt purge。${RESET}"

            else

                apt-get purge "${CLEANUP_PACKAGES[@]}"

                echo
                info "运行 apt autoremove..."

                apt-get autoremove

            fi

            ;;

        *)
            warning "用户取消内核清理。"
            ;;

    esac
}

cleanup_when_running_y() {

    separator

    echo -e "${GREEN}${BOLD}当前运行 Debian 官方内核 Y${RESET}"
    echo
    echo "当前：${CURRENT_KERNEL}"
    echo

    build_y_cleanup_list
    add_y_headers

    if [[ "${#CLEANUP_PACKAGES[@]}" -eq 0 ]]; then
        echo "没有发现需要清理的旧 Debian 内核。"
        echo
        echo "Y 元包保持不变。"
        return 0
    fi

    purge_packages

    echo
    success "Y 旧内核清理流程完成。"
    echo "Y 元包未处理。"
}

cleanup_when_running_x() {

    separator

    echo -e "${CYAN}${BOLD}当前运行第三方内核 X${RESET}"
    echo
    echo "当前：${CURRENT_KERNEL}"
    echo

    build_x_cleanup_list
    build_all_y_cleanup_list

    mapfile -t CLEANUP_PACKAGES < <(
        printf '%s\n' "${CLEANUP_PACKAGES[@]}" |
        sed '/^$/d' |
        sort -u
    )

    if [[ "${#CLEANUP_PACKAGES[@]}" -gt 0 ]]; then

        echo "将处理："
        echo "  - 清理旧 X 内核"
        echo "  - 清理全部 Y 内核"
        echo "  - 保留当前 X 内核"
        echo "  - 不处理 X 元包"
        echo

        purge_packages

    else

        info "没有发现需要删除的 X/Y 内核。"

    fi

    ask_remove_y_meta_packages

    separator

    success "X 内核清理流程完成。"
    echo
    echo "当前运行内核：${GREEN}${CURRENT_KERNEL}${RESET}"
    echo "X 元包：未处理。"
}

ask_remove_y_meta_packages() {

    [[ "${#Y_META_PACKAGES[@]}" -gt 0 ]] ||
        return 0

    local installed_meta=()
    local pkg

    for pkg in "${Y_META_PACKAGES[@]}"; do

        if package_installed "$pkg"; then
            installed_meta+=("$pkg")
        fi

    done

    [[ "${#installed_meta[@]}" -gt 0 ]] ||
        return 0

    separator

    echo -e "${BOLD}检测到 Debian 官方内核元包${RESET}"
    echo

    for pkg in "${installed_meta[@]}"; do
        echo -e "  ${YELLOW}${pkg}${RESET}"
    done

    echo
    echo "保留元包：以后可能自动安装新的 Debian 官方内核。"
    echo "删除元包：不再通过这些元包自动拉取 Debian 官方内核。"
    echo

    read -r -p "是否删除以上 Y 元包？ [y/N] " answer

    case "$answer" in

        y|Y|yes|YES)

            if [[ "$DRY_RUN" -eq 1 ]]; then

                echo
                echo -e "${CYAN}[dry-run] 以下 Y 元包将被删除：${RESET}"

                printf '  %s\n' "${installed_meta[@]}"

            else

                apt-get purge "${installed_meta[@]}"

                echo
                info "运行 apt autoremove..."

                apt-get autoremove

            fi

            ;;

        *)
            info "保留 Y 元包。"
            ;;

    esac
}

show_system_summary() {

    separator

    echo -e "${BOLD}系统内核概况${RESET}"
    echo

    echo "当前运行："
    echo "  ${CURRENT_KERNEL}"

    echo
    echo "当前内核族："

    if [[ "$CURRENT_FAMILY" == "Y" ]]; then
        echo -e "  ${GREEN}Y / Debian 官方${RESET}"
    else
        echo -e "  ${CYAN}X / 第三方${RESET}"
    fi

    echo
    echo "Y 内核："

    if [[ "${#Y_KERNELS[@]}" -eq 0 ]]; then
        echo "  无"
    else
        printf '  %s\n' "${Y_KERNELS[@]}"
    fi

    echo
    echo "X 内核："

    if [[ "${#X_KERNELS[@]}" -eq 0 ]]; then
        echo "  无"
    else
        printf '  %s\n' "${X_KERNELS[@]}"
    fi

    echo
    echo "Y 元包："

    if [[ "${#Y_META_PACKAGES[@]}" -eq 0 ]]; then
        echo "  无"
    else
        printf '  %s\n' "${Y_META_PACKAGES[@]}"
    fi

    echo

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "${CYAN}${BOLD}DRY-RUN：不会执行删除${RESET}"
        echo
    fi
}

main() {

    parse_args "$@"

    check_root
    check_commands

    get_current_kernel
    detect_current_family

    collect_y_kernel_packages
    collect_y_kernels
    collect_x_kernels
    collect_y_meta_packages

    show_current_kernel
    show_system_summary

    if find_pending_kernel; then
        handle_pending_reboot
        exit 0
    fi

    if [[ "$CURRENT_FAMILY" == "Y" ]]; then
        cleanup_when_running_y
    else
        cleanup_when_running_x
    fi

    echo
    success "全部处理完成。"
    echo
    echo "当前运行内核：${GREEN}${CURRENT_KERNEL}${RESET}"
    echo
}

main "$@"
