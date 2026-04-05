# Machine-local shell overrides.
# Canonical template path: config/shell/local.example.sh
# Copy this file to config/shell/local.sh on each machine as needed.

# Startup behaviors that should stay opt-in per machine.
# export AUTO_DETECT_PROXY_ENV=1
# export AUTO_SCREENFETCH=1
# export ENABLE_NOMAD_COMPLETION=1

# Private registries or company-specific hosts.
# export GOPRIVATE='gitlab.example.com'
# export GIT_TERMINAL_PROMPT=1
# export INIT_GIT_USER_NAME='Your Name'
# export INIT_GIT_USER_EMAIL='you@example.com'

# Machine-local secrets or service endpoints.
# export DOCKER_USERNAME='your-username'
# export DOCKER_PASSWORD='your-password'
# export CROSSSHARE_SERVER='https://example.internal'

# Add extra machine-local PATH entries here if needed.
# append_paths "$HOME/.local/custom/bin"

# Lazy-load toolchains per machine instead of hardcoding them in config/zsh/zshrc.
#
# Example: nvm and common Node.js commands.
# export NVM_DIR="$HOME/.nvm"
# _lazy_register_source nvm "$NVM_DIR/nvm.sh" "$NVM_DIR/bash_completion" -- \
#   nvm node npm npx pnpm yarn corepack
#
# Example: SDKMAN with optional eager startup for machines that need it immediately.
# export SDKMAN_DIR="$HOME/.sdkman"
# _lazy_register_source sdkman "$SDKMAN_DIR/bin/sdkman-init.sh" -- sdk
# if [[ "${ENABLE_SDKMAN:-}" == "1" ]]; then
#   _lazy_load_registered sdkman
# fi
