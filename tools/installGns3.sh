#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
WORKDIR="${GNS3_WORKDIR:-${HOME}/gns3-build}"
VPCS_VERSION="${GNS3_VPCS_VERSION:-0.8.3}"
DRY_RUN=0
SKIP_APT_UPDATE=0
RUN_SERVER=0

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} [options]

Options:
  --workdir DIR            Source build directory. Default: ${WORKDIR}
  --vpcs-version VERSION   VPCS version. Default: ${VPCS_VERSION}
  --skip-apt-update        Skip apt-get update
  --run-server             Start gns3server after installation
  --dry-run                Print planned commands without running them
  -h, --help               Show this help

Environment:
  GNS3_WORKDIR             Override default source build directory
  GNS3_VPCS_VERSION        Override default VPCS version

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --workdir /opt/gns3-build
  ${SCRIPT_NAME} --run-server
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log_info() {
    printf 'INFO: %s\n' "$*"
}

quote_cmd() {
    local arg

    printf '+'
    for arg in "$@"; do
        printf ' %q' "${arg}"
    done
    printf '\n'
}

quote_cd_cmd() {
    local dir="$1"
    local arg

    shift
    printf '+ cd %q &&' "${dir}"
    for arg in "$@"; do
        printf ' %q' "${arg}"
    done
    printf '\n'
}

run_cmd() {
    quote_cmd "$@"
    if [ "${DRY_RUN}" -eq 0 ]; then
        "$@"
    fi
}

run_root_cmd() {
    if [ "${EUID}" -eq 0 ]; then
        run_cmd "$@"
        return
    fi

    if [ "${DRY_RUN}" -eq 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "Command is required: sudo"
    fi

    quote_cmd sudo "$@"
    if [ "${DRY_RUN}" -eq 0 ]; then
        sudo "$@"
    fi
}

run_in_dir() {
    local dir="$1"

    shift
    quote_cd_cmd "${dir}" "$@"
    if [ "${DRY_RUN}" -eq 0 ]; then
        [ -d "${dir}" ] || die "Directory does not exist: ${dir}"
        (
            cd "${dir}"
            "$@"
        )
    fi
}

run_root_in_dir() {
    local dir="$1"

    shift
    if [ "${EUID}" -eq 0 ]; then
        run_in_dir "${dir}" "$@"
        return
    fi

    if [ "${DRY_RUN}" -eq 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "Command is required: sudo"
    fi

    quote_cd_cmd "${dir}" sudo "$@"
    if [ "${DRY_RUN}" -eq 0 ]; then
        [ -d "${dir}" ] || die "Directory does not exist: ${dir}"
        (
            cd "${dir}"
            sudo "$@"
        )
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --workdir)
            [ "$#" -ge 2 ] || die "--workdir requires an argument"
            WORKDIR="$2"
            shift 2
            ;;
        --vpcs-version)
            [ "$#" -ge 2 ] || die "--vpcs-version requires an argument"
            VPCS_VERSION="$2"
            shift 2
            ;;
        --skip-apt-update)
            SKIP_APT_UPDATE=1
            shift
            ;;
        --run-server)
            RUN_SERVER=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
        esac
    done
}

absolute_path() {
    local path="$1"

    case "${path}" in
    /*)
        printf '%s\n' "${path}"
        ;;
    *)
        printf '%s/%s\n' "$(pwd)" "${path}"
        ;;
    esac
}

validate_workdir() {
    WORKDIR="$(absolute_path "${WORKDIR}")"

    case "${WORKDIR}" in
    "" | "/" | "/usr" | "/usr/" | "/usr/local" | "/usr/local/" | "/etc" | "/etc/" | "/var" | "/var/")
        die "Unsafe workdir: ${WORKDIR}"
        ;;
    esac
}

require_debian_like() {
    local os_id=""

    if [ ! -r /etc/os-release ]; then
        die "No readable /etc/os-release"
    fi

    # 只读取系统发行版标识，避免在非 Debian 系系统上执行 apt 安装。
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"

    case "${os_id}" in
    debian | ubuntu)
        ;;
    *)
        die "Unsupported OS: ${os_id:-unknown}"
        ;;
    esac
}

preflight() {
    validate_workdir

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "Dry run mode: OS and command checks are skipped"
        return
    fi

    require_debian_like
    command -v apt-get >/dev/null 2>&1 || die "Command is required: apt-get"
}

apt_install() {
    [ "$#" -gt 0 ] || return 0
    run_root_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

install_system_packages() {
    local venv_package=""

    if [ "${SKIP_APT_UPDATE}" -eq 0 ]; then
        run_root_cmd apt-get update
    else
        log_info "Skipping apt-get update"
    fi

    apt_install \
        make \
        build-essential \
        unzip \
        curl \
        ca-certificates \
        git \
        libpcap-dev \
        libelf-dev \
        cmake \
        python3 \
        python3-setuptools \
        python3-pip

    if [ "${DRY_RUN}" -eq 1 ]; then
        venv_package="pythonX.Y-venv"
    else
        venv_package="$(python3 -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}-venv")')"
    fi
    apt_install "${venv_package}"
}

ensure_workdir() {
    run_cmd mkdir -p "${WORKDIR}"
}

clone_repo() {
    local repo_url="$1"
    local target_dir="$2"

    if [ -d "${target_dir}/.git" ]; then
        log_info "Using existing source: ${target_dir}"
        return
    fi

    if [ "${DRY_RUN}" -eq 0 ] && [ -e "${target_dir}" ]; then
        die "Target exists but is not a git repository: ${target_dir}"
    fi

    run_cmd git clone "${repo_url}" "${target_dir}"
}

install_ubridge() {
    local src_dir="${WORKDIR}/ubridge"

    log_info "Installing uBridge"
    clone_repo "https://github.com/GNS3/ubridge" "${src_dir}"
    run_in_dir "${src_dir}" make
    run_root_in_dir "${src_dir}" make install
}

install_vpcs() {
    local version="${VPCS_VERSION#v}"
    local tag="v${version}"
    local archive="${WORKDIR}/vpcs-${tag}.zip"
    local src_dir="${WORKDIR}/vpcs-${version}"
    local src_subdir="${src_dir}/src"

    log_info "Installing VPCS ${tag}"
    if [ ! -d "${src_dir}" ]; then
        if [ ! -f "${archive}" ]; then
            run_cmd curl -fL -o "${archive}" "https://github.com/GNS3/vpcs/archive/refs/tags/${tag}.zip"
        fi
        run_cmd unzip -q "${archive}" -d "${WORKDIR}"
    else
        log_info "Using existing source: ${src_dir}"
    fi

    run_in_dir "${src_subdir}" ./mk.sh
    if [ "${DRY_RUN}" -eq 0 ] && [ ! -x "${src_subdir}/vpcs" ]; then
        die "VPCS binary was not built: ${src_subdir}/vpcs"
    fi
    run_root_cmd install -m 0755 "${src_subdir}/vpcs" /usr/local/bin/vpcs
}

install_dynamips() {
    local src_dir="${WORKDIR}/dynamips"
    local build_dir="${src_dir}/build"

    log_info "Installing Dynamips"
    clone_repo "https://github.com/GNS3/dynamips" "${src_dir}"
    run_cmd mkdir -p "${build_dir}"
    run_cmd cmake -S "${src_dir}" -B "${build_dir}"
    run_cmd cmake --build "${build_dir}"
    run_root_cmd cmake --install "${build_dir}"
}

install_gns3_server() {
    local src_dir="${WORKDIR}/gns3-server"
    local venv_dir="${src_dir}/venv"
    local venv_python="${venv_dir}/bin/python"
    local gns3server_bin="${venv_dir}/bin/gns3server"

    log_info "Installing GNS3 server"
    clone_repo "https://github.com/GNS3/gns3-server" "${src_dir}"
    run_cmd python3 -m venv "${venv_dir}"
    run_in_dir "${src_dir}" "${venv_python}" -m pip install -r requirements.txt
    run_in_dir "${src_dir}" "${venv_python}" -m pip install .

    if [ "${RUN_SERVER}" -eq 1 ]; then
        run_cmd "${gns3server_bin}"
    else
        log_info "GNS3 server command: ${gns3server_bin}"
    fi
}

print_next_steps() {
    log_info "RouterOS appliance: https://gns3.com/marketplace/appliances/mikrotik-cloud-hosted-router"
    log_info "You can also create a RouterOS QEMU template manually in GNS3"
}

main() {
    parse_args "$@"
    preflight
    install_system_packages
    ensure_workdir
    install_ubridge
    install_vpcs
    install_dynamips
    install_gns3_server
    print_next_steps
}

main "$@"
