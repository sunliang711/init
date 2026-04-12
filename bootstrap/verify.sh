#!/bin/bash

set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-all}"
ORIGINAL_HOME="${HOME}"
ORIGINAL_PATH="${PATH}"
ORIGINAL_USER="$(id -un)"
TEMP_DIRS=()
RUNTIME_PATH_FILES=(
    "${ROOT_DIR}/install.sh"
    "${ROOT_DIR}/bootstrap/lib/runtime.sh"
    "${ROOT_DIR}/bootstrap/components/zsh-setup.sh"
    "${ROOT_DIR}/bootstrap/jobs/repo-update.sh"
    "${ROOT_DIR}/config/shell/init.sh"
    "${ROOT_DIR}/config/shell/shared/environment.sh"
    "${ROOT_DIR}/config/zsh/zshrc"
    "${ROOT_DIR}/config/ssh/config.template"
)
BASH_SYNTAX_FILES=(
    "${ROOT_DIR}/install.sh"
    "${ROOT_DIR}/bootstrap/lib/runtime.sh"
    "${ROOT_DIR}/bootstrap/verify.sh"
    "${ROOT_DIR}/bootstrap/components/git-config.sh"
    "${ROOT_DIR}/bootstrap/components/zsh-setup.sh"
    "${ROOT_DIR}/bootstrap/components/fzf.sh"
    "${ROOT_DIR}/bootstrap/components/tmux-setup.sh"
    "${ROOT_DIR}/bootstrap/components/vim-setup.sh"
    "${ROOT_DIR}/bootstrap/jobs/repo-update.sh"
    "${ROOT_DIR}/config/shell/init.sh"
    "${ROOT_DIR}/config/shell/local.example.sh"
    "${ROOT_DIR}/config/shell/shared/colors.sh"
    "${ROOT_DIR}/config/shell/shared/functions.sh"
    "${ROOT_DIR}/config/shell/shared/environment.sh"
    "${ROOT_DIR}/config/shell/shared/aliases.sh"
    "${ROOT_DIR}/config/shell/shared/extras.sh"
    "${ROOT_DIR}/config/shell/shared/shelllib.sh"
    "${ROOT_DIR}/bin/newsh"
    "${ROOT_DIR}/bin/newrust"
    "${ROOT_DIR}/bin/newsolanaprogram"
)
SHFMT_FILES=(
    "${BASH_SYNTAX_FILES[@]}"
)
SHELLCHECK_FILES=(
    "${ROOT_DIR}/bootstrap/lib/runtime.sh"
    "${ROOT_DIR}/bootstrap/verify.sh"
    "${ROOT_DIR}/bootstrap/components/git-config.sh"
    "${ROOT_DIR}/bootstrap/components/zsh-setup.sh"
    "${ROOT_DIR}/bootstrap/components/fzf.sh"
    "${ROOT_DIR}/bootstrap/components/tmux-setup.sh"
    "${ROOT_DIR}/bootstrap/components/vim-setup.sh"
    "${ROOT_DIR}/bootstrap/jobs/repo-update.sh"
    "${ROOT_DIR}/install.sh"
)

cleanup() {
    local dir

    for dir in "${TEMP_DIRS[@]:-}"; do
        [ -n "${dir}" ] || continue
        /bin/rm -rf "${dir}"
    done
}

trap cleanup EXIT

run() {
    printf '==> %s\n' "$*"
    "$@"
}

fail() {
    echo "verify-init: $*" >&2
    exit 1
}

assert_exists() {
    local path="${1:?missing path}"
    [ -e "${path}" ] || fail "expected path to exist: ${path}"
}

assert_not_exists() {
    local path="${1:?missing path}"
    [ ! -e "${path}" ] || fail "expected path to be absent: ${path}"
}

assert_symlink_target() {
    local path="${1:?missing path}"
    local expected="${2:?missing expected target}"
    local actual

    [ -L "${path}" ] || fail "expected symlink: ${path}"
    actual="$(readlink "${path}")"
    [ "${actual}" = "${expected}" ] || fail "expected ${path} -> ${expected}, got ${actual}"
}

assert_file_contains() {
    local path="${1:?missing path}"
    local needle="${2:?missing pattern}"

    grep -Fq "${needle}" "${path}" || fail "expected '${needle}' in ${path}"
}

assert_file_not_contains() {
    local path="${1:?missing path}"
    local needle="${2:?missing pattern}"

    if grep -Fq "${needle}" "${path}"; then
        fail "did not expect '${needle}' in ${path}"
    fi
}

assert_equals() {
    local expected="${1:?missing expected value}"
    local actual="${2:-}"
    local label="${3:-value}"

    [ "${expected}" = "${actual}" ] || fail "expected ${label} '${expected}', got '${actual}'"
}

assert_find_count() {
    local root="${1:?missing root}"
    local name="${2:?missing name}"
    local expected="${3:?missing expected count}"
    local actual

    actual="$(find "${root}" -name "${name}" | wc -l | tr -d '[:space:]')"
    assert_equals "${expected}" "${actual}" "count for ${name}"
}

assert_same_file() {
    local left="${1:?missing left file}"
    local right="${2:?missing right file}"

    cmp -s "${left}" "${right}" || fail "expected files to match: ${left} ${right}"
}

setup_test_env() {
    local name="${1:?missing test name}"

    TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/init-verify.${name}.XXXXXX")"
    TEMP_DIRS+=("${TEST_ROOT}")
    TEST_HOME="${TEST_ROOT}/home"
    TEST_BIN="${TEST_ROOT}/bin"
    TEST_STATE_DIR="${TEST_ROOT}/state"

    mkdir -p "${TEST_HOME}" "${TEST_BIN}" "${TEST_STATE_DIR}"

    export HOME="${TEST_HOME}"
    export INIT_HOME="${TEST_HOME}"
    export PATH="${TEST_BIN}:${ORIGINAL_PATH}"
    export TEST_STATE_DIR
    export ZSH="${TEST_HOME}/.oh-my-zsh"
    unset ZSH_CUSTOM
}

write_noop_stub() {
    local name="${1:?missing stub name}"

    cat >"${TEST_BIN}/${name}" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TEST_BIN}/${name}"
}

install_fake_root_id() {
    cat >"${TEST_BIN}/id" <<'EOF'
#!/bin/sh
set -eu

case "${1:-}" in
-u)
    printf '0\n'
    ;;
-un)
    printf 'root\n'
    ;;
*)
    exec /usr/bin/id "$@"
    ;;
esac
EOF
    chmod +x "${TEST_BIN}/id"
}

write_runtime_probe() {
    local probe_path="${1:?missing probe path}"
    local runtime_lib="${2:?missing runtime lib}"

    cat >"${probe_path}" <<EOF
#!/bin/bash

INIT_CALLER_SOURCE="\${BASH_SOURCE[0]}"
source "${runtime_lib}"

printf 'INIT_TARGET_USER=%s\n' "\${INIT_TARGET_USER}"
printf 'INIT_TARGET_HOME=%s\n' "\${INIT_TARGET_HOME}"
printf 'INIT_REPO_ROOT=%s\n' "\${INIT_REPO_ROOT}"
EOF
    chmod +x "${probe_path}"
}

install_fake_git() {
    cat >"${TEST_BIN}/git" <<'EOF'
#!/bin/sh
set -eu

state_dir="${TEST_STATE_DIR:?missing TEST_STATE_DIR}"

write_remote() {
    repo_dir="$1"
    remote_url="$2"
    mkdir -p "${repo_dir}/.git"
    printf '%s\n' "${remote_url}" >"${repo_dir}/.git/init-remote"
}

if [ "$#" -ge 1 ] && [ "$1" = "clone" ]; then
    shift
    while [ "$#" -gt 0 ] && [ "${1#-}" != "$1" ]; do
        if [ "$1" = "--depth" ]; then
            shift 2
            continue
        fi
        shift
    done

    remote_url="$1"
    repo_dir="$2"

    write_remote "${repo_dir}" "${remote_url}"

    case "${remote_url}" in
    *fzf.git)
        cat >"${repo_dir}/install" <<'INNER'
#!/bin/sh
set -eu
printf '# fake fzf zsh\n' >"${HOME}/.fzf.zsh"
printf '# fake fzf bash\n' >"${HOME}/.fzf.bash"
INNER
        cat >"${repo_dir}/uninstall" <<'INNER'
#!/bin/sh
set -eu
rm -f "${HOME}/.fzf.zsh" "${HOME}/.fzf.bash"
INNER
        chmod +x "${repo_dir}/install" "${repo_dir}/uninstall"
        ;;
    *nerdtree.git)
        mkdir -p "${repo_dir}/doc"
        printf 'nerdtree help\n' >"${repo_dir}/doc/nerdtree.txt"
        ;;
    esac

    exit 0
fi

if [ "$#" -ge 2 ] && [ "$1" = "-C" ]; then
    repo_dir="$2"
    shift 2

    case "$1 $2 ${3:-}" in
    "config --get remote.origin.url")
        cat "${repo_dir}/.git/init-remote"
        exit 0
        ;;
    "diff-index --quiet HEAD")
        exit 0
        ;;
    "pull --ff-only ")
        printf 'pulled %s\n' "${repo_dir}" >>"${state_dir}/git-pulls.log"
        exit 0
        ;;
    esac
fi

echo "fake git does not support: $*" >&2
exit 1
EOF
    chmod +x "${TEST_BIN}/git"
}

install_fake_curl() {
    cat >"${TEST_BIN}/curl" <<'EOF'
#!/bin/sh
set -eu

output_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    -o)
        shift
        output_file="$1"
        ;;
    esac
    shift
done

[ -n "${output_file}" ] || {
    echo "fake curl requires -o" >&2
    exit 1
}

cat >"${output_file}" <<'INNER'
#!/bin/sh
set -eu
omz_root="${ZSH:-${HOME}/.oh-my-zsh}"
mkdir -p "${omz_root}/custom"
printf '# fake oh-my-zsh\n' >"${omz_root}/oh-my-zsh.sh"
INNER
chmod +x "${output_file}"
EOF
    chmod +x "${TEST_BIN}/curl"
}

install_fake_crontab() {
    cat >"${TEST_BIN}/crontab" <<'EOF'
#!/bin/sh
set -eu

crontab_file="${TEST_STATE_DIR:?missing TEST_STATE_DIR}/crontab.txt"

if [ "$#" -gt 0 ] && [ "$1" = "-l" ]; then
    if [ -f "${crontab_file}" ]; then
        cat "${crontab_file}"
        exit 0
    fi
    exit 1
fi

cat >"${crontab_file}"
EOF
    chmod +x "${TEST_BIN}/crontab"
}

path_checks() {
    if rg -n '\.local/apps/init' "${RUNTIME_PATH_FILES[@]}" >/dev/null; then
        echo "Unexpected hardcoded init repo path found in runtime files:" >&2
        rg -n '\.local/apps/init' "${RUNTIME_PATH_FILES[@]}" >&2
        exit 1
    fi
}

shellcheck_checks() {
    if command -v shellcheck >/dev/null 2>&1; then
        run shellcheck "${SHELLCHECK_FILES[@]}"
    else
        echo "==> skip shellcheck (not installed)"
    fi
}

shfmt_checks() {
    if command -v shfmt >/dev/null 2>&1; then
        run shfmt -d "${SHFMT_FILES[@]}"
    else
        echo "==> skip shfmt (not installed)"
    fi
}

shfmt_write() {
    if command -v shfmt >/dev/null 2>&1; then
        run shfmt -w "${SHFMT_FILES[@]}"
    else
        fail "shfmt is not installed"
    fi
}

syntax_checks() {
    run bash -n "${BASH_SYNTAX_FILES[@]}"
    run zsh -n "${ROOT_DIR}/config/zsh/zshrc"
    run path_checks
    shfmt_checks
    shellcheck_checks
}

smoke_checks() {
    run bash "${ROOT_DIR}/install.sh" help
    run bash "${ROOT_DIR}/install.sh" components
    run bash "${ROOT_DIR}/install.sh" install --all --dry-run
    run bash "${ROOT_DIR}/bootstrap/components/git-config.sh" help
    run bash "${ROOT_DIR}/bootstrap/components/zsh-setup.sh" help
    run bash "${ROOT_DIR}/bootstrap/components/fzf.sh" help
    run bash "${ROOT_DIR}/bootstrap/components/tmux-setup.sh" help
    run bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" help
    run bash "${ROOT_DIR}/bootstrap/jobs/repo-update.sh" help
}

test_set_git() {
    local state_file

    setup_test_env set-git
    state_file="${TEST_HOME}/.local/state/init/git.state"

    env HOME="${TEST_HOME}" git config --global user.name "Existing User"
    env HOME="${TEST_HOME}" git config --global core.editor "emacs"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${ORIGINAL_PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/git-config.sh" set \
        --name "Init Tester" \
        --email "init@example.com" \
        --non-interactive

    assert_equals "Init Tester" "$(env HOME="${TEST_HOME}" git config --global --get user.name)" "git user.name"
    assert_equals "init@example.com" "$(env HOME="${TEST_HOME}" git config --global --get user.email)" "git user.email"
    assert_exists "${state_file}"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${ORIGINAL_PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/git-config.sh" unset

    assert_equals "Existing User" "$(env HOME="${TEST_HOME}" git config --global --get user.name)" "restored git user.name"
    assert_equals "emacs" "$(env HOME="${TEST_HOME}" git config --global --get core.editor)" "restored git core.editor"
    if env HOME="${TEST_HOME}" git config --global --get user.email >/dev/null 2>&1; then
        fail "expected git user.email to be unset"
    fi
    assert_not_exists "${state_file}"
}

test_runtime_targets_sudo_user_repo() {
    local output_file
    local probe_path

    setup_test_env runtime-sudo-user
    install_fake_root_id

    probe_path="${TEST_ROOT}/runtime-probe.sh"
    output_file="${TEST_ROOT}/runtime-probe.out"
    write_runtime_probe "${probe_path}" "${ROOT_DIR}/bootstrap/lib/runtime.sh"

    env HOME="${TEST_HOME}" INIT_HOME= PATH="${PATH}" SUDO_USER="${ORIGINAL_USER}" \
        bash "${probe_path}" >"${output_file}"

    assert_file_contains "${output_file}" "INIT_TARGET_USER=${ORIGINAL_USER}"
    assert_file_contains "${output_file}" "INIT_TARGET_HOME=${ORIGINAL_HOME}"
    assert_file_contains "${output_file}" "INIT_REPO_ROOT=${ROOT_DIR}"
}

test_runtime_targets_current_user_repo() {
    local expected_home
    local expected_repo
    local output_file
    local probe_path
    local runtime_copy
    local root_repo

    setup_test_env runtime-current-user
    install_fake_root_id

    root_repo="${TEST_HOME}/.local/apps/init"
    runtime_copy="${root_repo}/bootstrap/lib/runtime.sh"
    probe_path="${root_repo}/runtime-probe.sh"
    output_file="${TEST_ROOT}/runtime-probe.out"
    expected_home="$(CDPATH='' cd -- "${TEST_HOME}" && pwd)"
    expected_repo="${expected_home}/.local/apps/init"

    mkdir -p "$(dirname "${runtime_copy}")"
    cp "${ROOT_DIR}/bootstrap/lib/runtime.sh" "${runtime_copy}"
    write_runtime_probe "${probe_path}" "${runtime_copy}"

    env HOME="${TEST_HOME}" INIT_HOME= PATH="${PATH}" SUDO_USER="${ORIGINAL_USER}" \
        bash "${probe_path}" >"${output_file}"

    assert_file_contains "${output_file}" "INIT_TARGET_USER=root"
    assert_file_contains "${output_file}" "INIT_TARGET_HOME=${expected_home}"
    assert_file_contains "${output_file}" "INIT_REPO_ROOT=${expected_repo}"
}

test_zsh_install_uninstall() {
    local state_file

    setup_test_env zsh
    install_fake_git
    install_fake_curl
    write_noop_stub zsh

    mkdir -p "${TEST_HOME}/.ssh"
    printf 'legacy zshrc\n' >"${TEST_HOME}/.zshrc"
    printf 'legacy ssh config\n' >"${TEST_HOME}/.ssh/config"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/zsh-setup.sh" install

    assert_symlink_target "${TEST_HOME}/.zshrc" "${ROOT_DIR}/config/zsh/zshrc"
    assert_find_count "${TEST_HOME}" ".zshrc.init.bak.*" 1
    assert_file_contains "${TEST_HOME}/.ssh/config" "# managed-by: init/sshconfig"
    assert_file_contains "${TEST_HOME}/.ssh/config" "Include ${ROOT_DIR}/config/ssh/local.conf"
    assert_find_count "${TEST_HOME}/.ssh" "config.init.bak.*" 1
    assert_file_contains "${TEST_HOME}/.editrc" "bind -v"
    assert_file_contains "${TEST_HOME}/.inputrc" "set editing-mode vi"
    assert_exists "${TEST_HOME}/.oh-my-zsh/oh-my-zsh.sh"
    assert_exists "${TEST_HOME}/.oh-my-zsh/custom/plugins/zsh-autosuggestions/.git"
    assert_exists "${TEST_HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/.git"
    assert_symlink_target \
        "${TEST_HOME}/.oh-my-zsh/custom/themes/agnoster-newline.zsh-theme" \
        "${ROOT_DIR}/config/zsh/themes/agnoster-newline.zsh-theme"

    state_file="${TEST_HOME}/.local/state/init/zsh.state"
    assert_exists "${state_file}"
    assert_file_contains "${state_file}" "MANAGED_AUTOSUGGESTIONS_DIR=1"
    assert_file_contains "${state_file}" "MANAGED_SYNTAX_HIGHLIGHTING_DIR=1"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/zsh-setup.sh" uninstall

    assert_not_exists "${TEST_HOME}/.zshrc"
    assert_not_exists "${TEST_HOME}/.ssh/config"
    assert_not_exists "${TEST_HOME}/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
    assert_not_exists "${TEST_HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"
    assert_not_exists "${TEST_HOME}/.oh-my-zsh/custom/themes/agnoster-newline.zsh-theme"
    assert_not_exists "${state_file}"
    assert_not_exists "${TEST_HOME}/.editrc"
    assert_not_exists "${TEST_HOME}/.inputrc"
}

test_fzf_install_uninstall() {
    local state_file

    setup_test_env fzf
    install_fake_git

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/fzf.sh" install

    assert_exists "${TEST_HOME}/.fzf/.git"
    assert_exists "${TEST_HOME}/.fzf.zsh"
    assert_exists "${TEST_HOME}/.fzf.bash"
    state_file="${TEST_HOME}/.local/state/init/fzf.state"
    assert_exists "${state_file}"
    assert_file_contains "${state_file}" "MANAGED_FZF_DIR=1"
    assert_file_contains "${state_file}" "MANAGED_FZF_ZSH=1"
    assert_file_contains "${state_file}" "MANAGED_FZF_BASH=1"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/fzf.sh" uninstall

    assert_not_exists "${TEST_HOME}/.fzf"
    assert_not_exists "${TEST_HOME}/.fzf.zsh"
    assert_not_exists "${TEST_HOME}/.fzf.bash"
    assert_not_exists "${state_file}"
}

test_tmux_install_uninstall() {
    local state_file

    setup_test_env tmux
    install_fake_git
    write_noop_stub tmux

    mkdir -p "${TEST_HOME}/.tmux/keep"
    printf 'keep\n' >"${TEST_HOME}/.tmux/keep/marker"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/tmux-setup.sh" install

    assert_file_contains "${TEST_HOME}/.tmux.conf" "# managed-by: init/tmux"
    assert_exists "${TEST_HOME}/.tmux/plugins/tpm/.git"
    state_file="${TEST_HOME}/.local/state/init/tmux.state"
    assert_file_contains "${state_file}" "MANAGED_TPM_DIR=1"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/tmux-setup.sh" uninstall

    assert_not_exists "${TEST_HOME}/.tmux.conf"
    assert_not_exists "${TEST_HOME}/.tmux/plugins/tpm"
    assert_exists "${TEST_HOME}/.tmux/keep/marker"
    assert_not_exists "${state_file}"
}

test_vim_user_install() {
    local state_file

    setup_test_env vim
    install_fake_git
    write_noop_stub vim
    state_file="${TEST_HOME}/.local/state/init/vim.state"

    printf 'legacy vimrc\n' >"${TEST_HOME}/.vimrc"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" user
    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" user

    assert_same_file "${TEST_HOME}/.vimrc" "${ROOT_DIR}/config/editors/vim/vimrc"
    assert_find_count "${TEST_HOME}" ".vimrc.init.bak.*" 1
    assert_exists "${TEST_HOME}/.vim/pack/vendor/start/nerdtree/.git"
    assert_exists "${TEST_HOME}/.vim/pack/vendor/start/nerdtree/doc/nerdtree.txt"
    assert_exists "${state_file}"
    assert_file_contains "${state_file}" "MANAGED_USER_VIMRC=1"
    assert_file_contains "${state_file}" "MANAGED_NERDTREE_DIR=1"
}

test_vim_user_uninstall() {
    local state_file

    setup_test_env vim-uninstall
    install_fake_git
    write_noop_stub vim
    state_file="${TEST_HOME}/.local/state/init/vim.state"

    printf 'legacy vimrc\n' >"${TEST_HOME}/.vimrc"
    mkdir -p "${TEST_HOME}/.vim/keep"
    printf 'keep\n' >"${TEST_HOME}/.vim/keep/marker"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" user
    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" uninstall

    assert_not_exists "${TEST_HOME}/.vimrc"
    assert_not_exists "${TEST_HOME}/.vim/pack/vendor/start/nerdtree"
    assert_exists "${TEST_HOME}/.vim/keep/marker"
    assert_not_exists "${state_file}"
}

test_vim_uninstall_preserves_unmanaged_resources() {
    local state_file

    setup_test_env vim-unmanaged
    install_fake_git
    write_noop_stub vim
    state_file="${TEST_HOME}/.local/state/init/vim.state"

    cp "${ROOT_DIR}/config/editors/vim/vimrc" "${TEST_HOME}/.vimrc"
    mkdir -p "${TEST_HOME}/.vim/pack/vendor/start/nerdtree/.git"
    mkdir -p "${TEST_HOME}/.vim/pack/vendor/start/nerdtree/doc"
    printf '%s\n' "https://github.com/preservim/nerdtree.git" >"${TEST_HOME}/.vim/pack/vendor/start/nerdtree/.git/init-remote"
    printf 'nerdtree help\n' >"${TEST_HOME}/.vim/pack/vendor/start/nerdtree/doc/nerdtree.txt"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" user
    assert_file_contains "${state_file}" "MANAGED_USER_VIMRC=0"
    assert_file_contains "${state_file}" "MANAGED_NERDTREE_DIR=0"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" uninstall

    assert_exists "${TEST_HOME}/.vimrc"
    assert_exists "${TEST_HOME}/.vim/pack/vendor/start/nerdtree/.git"
    assert_exists "${TEST_HOME}/.vim/pack/vendor/start/nerdtree/doc/nerdtree.txt"
    assert_not_exists "${state_file}"
}

test_vim_uninstall_cleans_empty_dirs_without_state() {
    setup_test_env vim-no-state
    mkdir -p "${TEST_HOME}/.vim/pack/vendor/start"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" uninstall

    assert_not_exists "${TEST_HOME}/.vim"
}

test_vim_user_stops_on_clone_failure() {
    local output_file

    setup_test_env vim-clone-failure
    write_noop_stub vim
    output_file="${TEST_ROOT}/vim-user.out"

    cat >"${TEST_BIN}/git" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${TEST_BIN}/git"

    if env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" user >"${output_file}" 2>&1; then
        fail "expected vim user command to fail when git clone fails"
    fi
    assert_file_not_contains "${output_file}" "[SUCCESS] Done"
}

test_vim_global_rejects_unsupported_os() {
    setup_test_env vim-global-unsupported
    write_noop_stub vim

    cat >"${TEST_BIN}/uname" <<'EOF'
#!/bin/sh
printf 'FreeBSD\n'
EOF
    chmod +x "${TEST_BIN}/uname"

    if env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/components/vim-setup.sh" global; then
        fail "expected vim global command to fail on unsupported os"
    fi
}

test_update_init() {
    local crontab_file
    local cron_fragment

    setup_test_env update
    install_fake_git
    install_fake_crontab

    crontab_file="${TEST_STATE_DIR}/crontab.txt"
    printf '15 3 * * * echo existing\n' >"${crontab_file}"
    cron_fragment="repo-update.sh update >/dev/null 2>&1"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/jobs/repo-update.sh" install
    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/jobs/repo-update.sh" install

    assert_file_contains "${crontab_file}" "15 3 * * * echo existing"
    assert_file_contains "${crontab_file}" "${cron_fragment}"
    assert_find_count "${TEST_STATE_DIR}" "git-pulls.log" 0

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/jobs/repo-update.sh" update
    assert_file_contains "${TEST_STATE_DIR}/git-pulls.log" "${ROOT_DIR}"

    run env HOME="${TEST_HOME}" INIT_HOME="${TEST_HOME}" PATH="${PATH}" \
        bash "${ROOT_DIR}/bootstrap/jobs/repo-update.sh" uninstall

    assert_file_contains "${crontab_file}" "15 3 * * * echo existing"
    assert_file_not_contains "${crontab_file}" "${cron_fragment}"
}

integration_checks() {
    run test_runtime_targets_sudo_user_repo
    run test_runtime_targets_current_user_repo
    run test_set_git
    run test_zsh_install_uninstall
    run test_fzf_install_uninstall
    run test_tmux_install_uninstall
    run test_vim_user_install
    run test_vim_user_uninstall
    run test_vim_uninstall_preserves_unmanaged_resources
    run test_vim_uninstall_cleans_empty_dirs_without_state
    run test_vim_user_stops_on_clone_failure
    run test_vim_global_rejects_unsupported_os
    run test_update_init
}

bats_checks() {
    if command -v bats >/dev/null 2>&1; then
        run bats "${ROOT_DIR}/tests"
    else
        echo "==> skip bats (not installed)"
    fi
}

case "${MODE}" in
all)
    syntax_checks
    smoke_checks
    integration_checks
    bats_checks
    ;;
syntax)
    syntax_checks
    ;;
smoke)
    smoke_checks
    ;;
integration)
    integration_checks
    ;;
fmt)
    shfmt_write
    ;;
fmt-check)
    shfmt_checks
    ;;
*)
    echo "Usage: $0 [all|syntax|smoke|integration|fmt|fmt-check]" >&2
    exit 1
    ;;
esac

printf 'All %s checks passed.\n' "${MODE}"
