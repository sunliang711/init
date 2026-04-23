export SHELL_CONFIG_ROOT="${INIT_REPO_ROOT}/config/shell"
export SHELL_SHARED_ROOT="${SHELL_CONFIG_ROOT}/shared"
export SHELL_INIT_FILE="${SHELL_CONFIG_ROOT}/init.sh"
export SHELL_LOCAL_FILE="${SHELL_CONFIG_ROOT}/local.sh"

source "${SHELL_SHARED_ROOT}/colors.sh"
source "${SHELL_SHARED_ROOT}/functions.sh"

# Source() is defined in functions.sh.
Source "${SHELL_SHARED_ROOT}/environment.sh"
Source "${SHELL_SHARED_ROOT}/aliases.sh"
Source "${SHELL_SHARED_ROOT}/extras.sh"
Source "${SHELL_LOCAL_FILE}"

# Apply saved proxy only after machine-local opt-in flags are loaded.
[ -n "${AUTO_DETECT_PROXY_ENV:-}" ] && [ -e "${PROXY_FILE}" ] && detectProxyEnv
# vim: set ft=sh:
