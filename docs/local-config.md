# Local Config Boundary

This repository is shared across multiple machines, so tracked config should stay machine-agnostic.

## Local-Only Files

- `config/shell/local.sh`
  - Ignored by git.
  - Sourced automatically by `config/shell/init.sh`.
  - Use it for machine-local environment variables, private registry settings, secrets, proxy opt-ins, and other host-specific shell behavior.
  - Startup flags such as `ENABLE_SDKMAN`, `ENABLE_NOMAD_COMPLETION`, `AUTO_DETECT_PROXY_ENV`, and `AUTO_SCREENFETCH` belong here.
  - Git identity defaults such as `INIT_GIT_USER_NAME` and `INIT_GIT_USER_EMAIL` also belong here when they differ by machine or account.
  - Start from `config/shell/local.example.sh`.

- `config/ssh/local.conf`
  - Ignored by git.
  - Included by the generated `~/.ssh/config` wrapper written by `bootstrap/components/zsh-setup.sh install`.
  - Use it for machine-local SSH hosts, agent sockets, OrbStack includes, and network-specific host aliases.
  - Start from `config/ssh/local.example.conf`.

- `~/.ssh/config.local`
  - Also included by the generated `~/.ssh/config` wrapper.
  - Useful when you want local SSH overrides outside this repo.

## Shared Files

- `config/shell/init.sh`
  - Loads the tracked shared shell modules, then `config/shell/local.sh`.

- `config/shell/shared/functions.sh`
  - Keeps the tracked shared shell helpers and lazy-load registrations.

- `config/zsh/zshrc`
  - Keeps shared shell behavior only.
  - Machine-specific startup features should be enabled from `config/shell/local.sh`.
  - SDKMAN and Nomad completion are now opt-in instead of unconditional shared defaults.

- `config/ssh/config.template`
  - Documents the wrapper layout used when `bootstrap/components/zsh-setup.sh install` writes `~/.ssh/config`.
  - The live wrapper uses the current repo path, so the repo no longer has to live under `~/.local/apps/init`.

- `config/ssh/shared.conf`
  - Keeps cross-machine SSH defaults and host aliases that are genuinely shared.
  - This is the right place for stable public VPS hosts that should exist on every machine.
  - It should not contain local network topology, machine-only agent config, or LAN-only aliases.

- `config/editors/zed/settings.json`
  - Should keep only shareable editor preferences.
  - Machine-local SSH connections and local project paths should stay out of the tracked file.

## Recommended Practice

- Keep secrets and internal endpoints out of tracked files.
- Prefer opt-in flags in `config/shell/local.sh` over unconditional startup work in shared config.
- When a setting depends on a specific machine, network, or installed app, put it in a local file instead of the shared layer.
- If the repo moves, rerun the relevant install step so generated wrappers point at the new location.
