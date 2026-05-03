#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
RULE_FILE="/etc/sudoers.d/init-nopasswd"
RULE_HEADER="# Managed by tools/enableSudo.sh. Do not edit manually."
DRY_RUN=0
PARSED_ARGS=()

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} enable [options] USER
  ${SCRIPT_NAME} disable [options] USER
  ${SCRIPT_NAME} status USER
  ${SCRIPT_NAME} list

Options:
  --dry-run                Print planned changes without writing sudoers files.
  -h, --help               Show this help.

Examples:
  ${SCRIPT_NAME} enable alice --dry-run
  ${SCRIPT_NAME} enable alice
  ${SCRIPT_NAME} disable alice
  ${SCRIPT_NAME} status alice
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*"
}

quote_cmd() {
    local arg
    printf '+'
    for arg in "$@"; do
        printf ' %q' "${arg}"
    done
    printf '\n'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Command is required: $1"
}

require_root_for_write() {
    if [ "${DRY_RUN}" -eq 0 ] && [ "${EUID}" -ne 0 ]; then
        die "Root privilege is required when not using --dry-run."
    fi
}

parse_common_options() {
    PARSED_ARGS=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                PARSED_ARGS+=("$1")
                shift
            done
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            PARSED_ARGS+=("$1")
            shift
            ;;
        esac
    done
}

normalize_user() {
    local user="${1:-}"

    [ -n "${user}" ] || die "Missing USER."

    case "${user}" in
    ALL | all)
        die "Refuse unsafe user name: ${user}"
        ;;
    esac

    if ! printf '%s\n' "${user}" | grep -Eq '^[A-Za-z0-9._-]+$'; then
        die "Invalid USER: ${user}"
    fi

    if ! id "${user}" >/dev/null 2>&1; then
        die "User does not exist: ${user}"
    fi

    printf '%s\n' "${user}"
}

sudoers_line_for_user() {
    local user="$1"
    printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "${user}"
}

load_managed_users() {
    local line
    local user

    if [ -e "${RULE_FILE}" ] && [ ! -r "${RULE_FILE}" ]; then
        die "Cannot read ${RULE_FILE}. Run as root."
    fi

    [ -r "${RULE_FILE}" ] || return 0

    while IFS= read -r line; do
        case "${line}" in
        "" | \#*)
            continue
            ;;
        esac
        user="${line%%[[:space:]]*}"
        if [ -n "${user}" ]; then
            printf '%s\n' "${user}"
        fi
    done <"${RULE_FILE}"
}

user_is_enabled() {
    local user="$1"
    local managed_user

    while IFS= read -r managed_user; do
        [ "${managed_user}" = "${user}" ] && return 0
    done < <(load_managed_users)

    return 1
}

write_rule_content() {
    local user

    printf '%s\n' "${RULE_HEADER}"
    for user in "$@"; do
        sudoers_line_for_user "${user}"
    done
}

validate_sudoers_file() {
    local file="$1"

    require_command sudo
    require_command visudo
    visudo -cf "${file}" >/dev/null
}

install_rule_file() {
    local source_file="$1"

    require_command install
    quote_cmd install -m 0440 "${source_file}" "${RULE_FILE}"
    if [ "${DRY_RUN}" -eq 0 ]; then
        install -m 0440 "${source_file}" "${RULE_FILE}"
    fi
}

remove_rule_file() {
    quote_cmd rm -f "${RULE_FILE}"
    if [ "${DRY_RUN}" -eq 0 ]; then
        rm -f "${RULE_FILE}"
    fi
}

apply_users() {
    local user_count="$#"
    local tmp_file=""

    require_command mktemp
    require_root_for_write

    if [ "${user_count}" -eq 0 ]; then
        remove_rule_file
        return 0
    fi

    tmp_file="$(mktemp)"
    write_rule_content "$@" >"${tmp_file}"

    validate_sudoers_file "${tmp_file}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log "Dry-run sudoers content for ${RULE_FILE}:"
        cat "${tmp_file}"
    fi

    install_rule_file "${tmp_file}"
    rm -f "${tmp_file}"
}

enable() {
    local user
    local managed_users=()
    local managed_user

    parse_common_options "$@"
    if [ "${#PARSED_ARGS[@]}" -gt 0 ]; then
        set -- "${PARSED_ARGS[@]}"
    else
        set --
    fi
    [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} enable [options] USER"

    user="$(normalize_user "$1")"
    if user_is_enabled "${user}"; then
        log "Already enabled: ${user}"
        return 0
    fi

    while IFS= read -r managed_user; do
        managed_users+=("${managed_user}")
    done < <(load_managed_users)
    managed_users+=("${user}")
    apply_users "${managed_users[@]}"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log "Dry-run: would enable passwordless sudo for: ${user}"
    else
        log "Enabled passwordless sudo for: ${user}"
    fi
}

disable() {
    local user
    local managed_user
    local next_users=()
    local found=0

    parse_common_options "$@"
    if [ "${#PARSED_ARGS[@]}" -gt 0 ]; then
        set -- "${PARSED_ARGS[@]}"
    else
        set --
    fi
    [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} disable [options] USER"

    user="$(normalize_user "$1")"
    while IFS= read -r managed_user; do
        if [ "${managed_user}" != "${user}" ]; then
            next_users+=("${managed_user}")
        else
            found=1
        fi
    done < <(load_managed_users)

    if [ "${found}" -eq 0 ]; then
        log "Already disabled: ${user}"
        return 0
    fi

    if [ "${#next_users[@]}" -gt 0 ]; then
        apply_users "${next_users[@]}"
    else
        apply_users
    fi
    if [ "${DRY_RUN}" -eq 1 ]; then
        log "Dry-run: would disable passwordless sudo for: ${user}"
    else
        log "Disabled passwordless sudo for: ${user}"
    fi
}

status() {
    local user

    parse_common_options "$@"
    if [ "${#PARSED_ARGS[@]}" -gt 0 ]; then
        set -- "${PARSED_ARGS[@]}"
    else
        set --
    fi
    [ "$#" -eq 1 ] || die "Usage: ${SCRIPT_NAME} status USER"

    user="$(normalize_user "$1")"
    if user_is_enabled "${user}"; then
        log "enabled: ${user}"
    else
        log "disabled: ${user}"
        return 1
    fi
}

list() {
    local managed_users=()
    local user

    parse_common_options "$@"
    if [ "${#PARSED_ARGS[@]}" -gt 0 ]; then
        set -- "${PARSED_ARGS[@]}"
    else
        set --
    fi
    [ "$#" -eq 0 ] || die "Usage: ${SCRIPT_NAME} list"

    while IFS= read -r user; do
        managed_users+=("${user}")
    done < <(load_managed_users)
    if [ "${#managed_users[@]}" -eq 0 ]; then
        log "No managed passwordless sudo users."
        return 0
    fi

    log "Managed passwordless sudo users:"
    for user in "${managed_users[@]}"; do
        log "  ${user}"
    done
}

main() {
    local command="${1:-}"

    case "${command}" in
    "" | -h | --help | help)
        usage
        ;;
    enable | disable | status | list)
        shift
        "${command}" "$@"
        ;;
    *)
        die "Unknown command: ${command}"
        ;;
    esac
}

main "$@"
