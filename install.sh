#!/bin/bash

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/lib/init-common.sh"
# shellcheck disable=SC2034
INIT_CALLER_SOURCE="${BASH_SOURCE[0]}"
# shellcheck source=lib/init-common.sh
source "${COMMON_LIB}"
unset COMMON_LIB INIT_CALLER_SOURCE

# ------------------------------------------------------------
ALL_COMPONENTS=("git" "zsh" "fzf" "tmux" "vim" "update")
DEFAULT_INSTALL_COMPONENTS=("zsh" "fzf" "tmux" "vim")
DEFAULT_UNINSTALL_COMPONENTS=("zsh" "fzf" "tmux")
DEFAULT_CHECK_COMPONENTS=("${ALL_COMPONENTS[@]}")

ACTION_PROXY=""
DRY_RUN=0
RAW_COMPONENTS=()
SELECTED_COMPONENTS=()

join_by() {
    local sep="$1"
    shift
    local output=""
    local item

    for item in "$@"; do
        if [ -n "$output" ]; then
            output="${output}${sep}${item}"
        else
            output="${item}"
        fi
    done

    printf '%s' "$output"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

add_component_once() {
    local candidate="$1"
    local existing
    for existing in "${SELECTED_COMPONENTS[@]}"; do
        if [ "$existing" = "$candidate" ]; then
            return 0
        fi
    done
    SELECTED_COMPONENTS+=("$candidate")
}

append_component_tokens() {
    local raw="$1"
    local token
    local IFS=','
    local -a parts=()

    read -r -a parts <<< "$raw"
    for token in "${parts[@]}"; do
        token="$(trim "$token")"
        [ -z "$token" ] && continue
        token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
        RAW_COMPONENTS+=("$token")
    done
}

component_exists() {
    local candidate="$1"
    case "$candidate" in
    git | zsh | fzf | tmux | vim | update)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

component_supports_action() {
    local action="$1"
    local component="$2"

    case "${action}:${component}" in
    install:git | check:git | \
        install:zsh | uninstall:zsh | check:zsh | \
        install:fzf | uninstall:fzf | check:fzf | \
        install:tmux | uninstall:tmux | check:tmux | \
        install:vim | check:vim | \
        install:update | uninstall:update | check:update)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

component_description() {
    case "$1" in
    git)
        echo "Git identity and global defaults"
        ;;
    zsh)
        echo "oh-my-zsh, plugins, shared zshrc, ssh config"
        ;;
    fzf)
        echo "fzf clone and shell integration"
        ;;
    tmux)
        echo "tmux config and TPM plugin manager"
        ;;
    vim)
        echo "user vimrc and nerdtree plugin"
        ;;
    update)
        echo "daily repo auto-update cron job"
        ;;
    esac
}

component_change_summary() {
    local action="$1"
    local component="$2"

    case "${action}:${component}" in
    install:git)
        echo "Sets global git identity and defaults in ~/.gitconfig."
        ;;
    install:zsh)
        echo "Installs oh-my-zsh plugins and links ~/.zshrc plus ~/.ssh/config."
        ;;
    install:fzf)
        echo "Clones ~/.fzf and runs its shell integration installer."
        ;;
    install:tmux)
        echo "Clones TPM and writes ~/.tmux.conf."
        ;;
    install:vim)
        echo "Copies ~/.vimrc and installs nerdtree under ~/.vim/pack."
        ;;
    install:update)
        echo "Adds a crontab entry to update this repo every day."
        ;;
    uninstall:zsh)
        echo "Removes zsh artifacts managed by scripts/zsh.sh."
        ;;
    uninstall:fzf)
        echo "Runs ~/.fzf/uninstall and removes ~/.fzf."
        ;;
    uninstall:tmux)
        echo "Removes ~/.tmux.conf and ~/.tmux."
        ;;
    uninstall:update)
        echo "Removes the repo auto-update crontab entry."
        ;;
    check:git)
        echo "Checks Git prerequisites."
        ;;
    check:zsh)
        echo "Checks shell bootstrap prerequisites."
        ;;
    check:fzf)
        echo "Checks fzf install prerequisites."
        ;;
    check:tmux)
        echo "Checks tmux prerequisites."
        ;;
    check:vim)
        echo "Checks vim prerequisites."
        ;;
    check:update)
        echo "Checks cron availability for repo auto-update."
        ;;
    *)
        echo "No summary available."
        ;;
    esac
}

print_component_list() {
    local component
    local install_supported
    local uninstall_supported
    local check_supported

    echo "Available components:"
    for component in "${ALL_COMPONENTS[@]}"; do
        install_supported="no"
        uninstall_supported="no"
        check_supported="no"
        component_supports_action install "$component" && install_supported="yes"
        component_supports_action uninstall "$component" && uninstall_supported="yes"
        component_supports_action check "$component" && check_supported="yes"
        printf "  %-8s install=%-3s uninstall=%-3s check=%-3s %s\n" \
            "$component" "$install_supported" "$uninstall_supported" "$check_supported" \
            "$(component_description "$component")"
    done
}

# 显示帮助信息
show_help() {
    cat <<EOF
Usage: $0 [-l LOG_LEVEL] <command> [options] [components...]

Commands:
  help         Show this help
  install      Install selected components
  uninstall    Uninstall selected components when supported
  check        Check prerequisites for selected components
  components   Show the component matrix

Component selection:
  Pass components as positional args: install zsh fzf
  Or use a comma-separated list:      install --components zsh,fzf
  Or use the explicit full-selection flag: install --all
  Use "all" to select all supported components for that action.

Defaults:
  install      $(join_by ', ' "${DEFAULT_INSTALL_COMPONENTS[@]}")
  uninstall    $(join_by ', ' "${DEFAULT_UNINSTALL_COMPONENTS[@]}")
  check        $(join_by ', ' "${DEFAULT_CHECK_COMPONENTS[@]}")

Options:
  -l LOG_LEVEL       Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)
  --components LIST  Comma-separated component list
  --all              Select all components supported by the action
  --dry-run          Show the action summary without applying install or uninstall changes
  --proxy URL        Install only. Also updates global git proxy settings for this machine

Examples:
  $0 install
  $0 install --all
  $0 install --components zsh,fzf
  $0 install git zsh --proxy http://127.0.0.1:7890
  $0 uninstall --components tmux
  $0 check all
  $0 components
EOF
}

configure_install_proxy() {
    local proxy="$1"
    [ -n "$proxy" ] || return 0

    _require_command git

    log INFO "Apply install proxy and update global git proxy settings"
    git config --global http.proxy "$proxy"
    git config --global https.proxy "$proxy"
    export http_proxy="$proxy"
    export HTTP_PROXY="$proxy"
    export https_proxy="$proxy"
    export HTTPS_PROXY="$proxy"
}

normalize_action_components() {
    local action="$1"
    local component
    local candidate
    local -a input_components=()

    SELECTED_COMPONENTS=()

    if [ "${#RAW_COMPONENTS[@]}" -eq 0 ]; then
        case "$action" in
        install)
            input_components=("${DEFAULT_INSTALL_COMPONENTS[@]}")
            ;;
        uninstall)
            input_components=("${DEFAULT_UNINSTALL_COMPONENTS[@]}")
            ;;
        check)
            input_components=("${DEFAULT_CHECK_COMPONENTS[@]}")
            ;;
        *)
            log FATAL "Unknown action: $action"
            ;;
        esac
    else
        input_components=("${RAW_COMPONENTS[@]}")
    fi

    for component in "${input_components[@]}"; do
        if [ "$component" = "all" ]; then
            for candidate in "${ALL_COMPONENTS[@]}"; do
                if component_supports_action "$action" "$candidate"; then
                    add_component_once "$candidate"
                fi
            done
            continue
        fi

        if ! component_exists "$component"; then
            log FATAL "Unknown component: $component"
        fi
        if ! component_supports_action "$action" "$component"; then
            log FATAL "Component '$component' does not support action '$action'"
        fi
        add_component_once "$component"
    done

    if [ "${#SELECTED_COMPONENTS[@]}" -eq 0 ]; then
        log FATAL "No components selected for action '$action'"
    fi
}

parse_action_args() {
    local action="$1"
    shift

    ACTION_PROXY=""
    DRY_RUN=0
    RAW_COMPONENTS=()

    while [ $# -gt 0 ]; do
        case "$1" in
        --components | --component | --only)
            shift
            [ $# -gt 0 ] || log FATAL "Missing value for --components"
            append_component_tokens "$1"
            ;;
        --all)
            append_component_tokens "all"
            ;;
        --proxy)
            [ "$action" = "install" ] || log FATAL "--proxy is only supported for install"
            shift
            [ $# -gt 0 ] || log FATAL "Missing value for --proxy"
            ACTION_PROXY="$1"
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        --)
            shift
            while [ $# -gt 0 ]; do
                append_component_tokens "$1"
                shift
            done
            break
            ;;
        -*)
            log FATAL "Unknown option: $1"
            ;;
        *)
            if [ "$action" = "install" ] && [ -z "$ACTION_PROXY" ] && echo "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*://'; then
                ACTION_PROXY="$1"
            else
                append_component_tokens "$1"
            fi
            ;;
        esac
        shift
    done

    normalize_action_components "$action"
}

print_action_summary() {
    local action="$1"
    local component

    echo "Action: ${action}"
    echo "Components: $(join_by ', ' "${SELECTED_COMPONENTS[@]}")"

    if [ "$action" = "install" ] && [ -n "$ACTION_PROXY" ]; then
        echo "Proxy: ${ACTION_PROXY}"
        echo "  - proxy: sets global git http/https proxy and exports proxy env for this run."
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "Dry run: enabled"
    fi

    echo "Summary:"
    for component in "${SELECTED_COMPONENTS[@]}"; do
        echo "  - ${component}: $(component_change_summary "$action" "$component")"
    done
}

run_component_action() {
    local action="$1"
    local component="$2"

    case "${action}:${component}" in
    check:git)
        (cd "${SCRIPT_DIR}/scripts" && bash setGit.sh check)
        ;;
    install:git)
        (cd "${SCRIPT_DIR}/scripts" && bash setGit.sh set)
        ;;
    check:zsh)
        (cd "${SCRIPT_DIR}/scripts" && bash zsh.sh check)
        ;;
    install:zsh)
        (cd "${SCRIPT_DIR}/scripts" && bash zsh.sh install)
        ;;
    uninstall:zsh)
        (cd "${SCRIPT_DIR}/scripts" && bash zsh.sh uninstall)
        ;;
    check:fzf)
        (cd "${SCRIPT_DIR}/scripts" && bash installFzf.sh check)
        ;;
    install:fzf)
        (cd "${SCRIPT_DIR}/scripts" && bash installFzf.sh install)
        ;;
    uninstall:fzf)
        (cd "${SCRIPT_DIR}/scripts" && bash installFzf.sh uninstall)
        ;;
    check:tmux)
        (cd "${SCRIPT_DIR}/scripts" && bash tmux.sh check)
        ;;
    install:tmux)
        (cd "${SCRIPT_DIR}/scripts" && bash tmux.sh install)
        ;;
    uninstall:tmux)
        (cd "${SCRIPT_DIR}/scripts" && bash tmux.sh uninstall)
        ;;
    check:vim)
        (cd "${SCRIPT_DIR}/scripts" && bash vim.sh check)
        ;;
    install:vim)
        (cd "${SCRIPT_DIR}/scripts" && bash vim.sh user)
        ;;
    check:update)
        (cd "${SCRIPT_DIR}/tools" && bash updateInit.sh check)
        ;;
    install:update)
        (cd "${SCRIPT_DIR}/tools" && bash updateInit.sh install)
        ;;
    uninstall:update)
        (cd "${SCRIPT_DIR}/tools" && bash updateInit.sh uninstall)
        ;;
    *)
        log FATAL "Unsupported action '${action}' for component '${component}'"
        ;;
    esac
}

run_checks() {
    local component
    local error_checks=0

    for component in "${SELECTED_COMPONENTS[@]}"; do
        if ! run_component_action check "$component"; then
            error_checks=$((error_checks + 1))
        fi
    done

    if [ "$error_checks" -gt 0 ]; then
        log FATAL "Prerequisite checks failed for ${error_checks} component(s)"
    fi
}

install() {
    parse_action_args install "$@"
    print_action_summary install
    run_checks

    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "Dry run only. Skipping install."
        return 0
    fi

    configure_install_proxy "$ACTION_PROXY"

    local component
    for component in "${SELECTED_COMPONENTS[@]}"; do
        log INFO "Install component: ${component}"
        run_component_action install "$component"
    done
}

uninstall() {
    parse_action_args uninstall "$@"
    print_action_summary uninstall

    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "Dry run only. Skipping uninstall."
        return 0
    fi

    local component
    for component in "${SELECTED_COMPONENTS[@]}"; do
        log INFO "Uninstall component: ${component}"
        run_component_action uninstall "$component"
    done
}

check() {
    parse_action_args check "$@"
    print_action_summary check
    run_checks
}

components() {
    print_component_list
}

_dispatch_cli show_help _resolve_cli_handler "$@"
