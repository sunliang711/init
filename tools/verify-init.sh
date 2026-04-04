#!/bin/bash

set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-all}"
RUNTIME_PATH_FILES=(
    "${ROOT_DIR}/install.sh"
    "${ROOT_DIR}/lib/init-common.sh"
    "${ROOT_DIR}/scripts/zsh.sh"
    "${ROOT_DIR}/tools/updateInit.sh"
    "${ROOT_DIR}/softlinks/zshrc"
    "${ROOT_DIR}/softlinks/sshconfig"
)

run() {
    printf '==> %s\n' "$*"
    "$@"
}

path_checks() {
    if rg -n '\.local/apps/init' "${RUNTIME_PATH_FILES[@]}" >/dev/null; then
        echo "Unexpected hardcoded init repo path found in runtime files:" >&2
        rg -n '\.local/apps/init' "${RUNTIME_PATH_FILES[@]}" >&2
        exit 1
    fi
}

syntax_checks() {
    run bash -n \
        "${ROOT_DIR}/lib/init-common.sh" \
        "${ROOT_DIR}/install.sh" \
        "${ROOT_DIR}/scripts/setGit.sh" \
        "${ROOT_DIR}/scripts/zsh.sh" \
        "${ROOT_DIR}/scripts/installFzf.sh" \
        "${ROOT_DIR}/scripts/tmux.sh" \
        "${ROOT_DIR}/scripts/vim.sh" \
        "${ROOT_DIR}/tools/updateInit.sh"
    run zsh -n "${ROOT_DIR}/softlinks/zshrc"
    run path_checks
}

smoke_checks() {
    run bash "${ROOT_DIR}/install.sh" help
    run bash "${ROOT_DIR}/install.sh" components
    run bash "${ROOT_DIR}/install.sh" install --all --dry-run
    run bash "${ROOT_DIR}/scripts/zsh.sh" help
    run bash "${ROOT_DIR}/scripts/installFzf.sh" help
    run bash "${ROOT_DIR}/scripts/tmux.sh" help
    run bash "${ROOT_DIR}/scripts/vim.sh" help
    run bash "${ROOT_DIR}/tools/updateInit.sh" help
}

case "${MODE}" in
all)
    syntax_checks
    smoke_checks
    ;;
syntax)
    syntax_checks
    ;;
smoke)
    smoke_checks
    ;;
*)
    echo "Usage: $0 [all|syntax|smoke]" >&2
    exit 1
    ;;
esac

printf 'All %s checks passed.\n' "${MODE}"
