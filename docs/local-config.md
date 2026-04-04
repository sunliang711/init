# Local Config Boundary

This repository is shared across multiple machines, so tracked config should stay machine-agnostic.

## Local-Only Files

- `shellConfigs/local`
  - Ignored by git.
  - Sourced automatically by `shellConfigs/index`.
  - Use it for machine-local environment variables, private registry settings, secrets, proxy opt-ins, and other host-specific shell behavior.
  - Startup flags such as `ENABLE_SDKMAN`, `ENABLE_NOMAD_COMPLETION`, `AUTO_DETECT_PROXY_ENV`, and `AUTO_SCREENFETCH` belong here.
  - Git identity defaults such as `INIT_GIT_USER_NAME` and `INIT_GIT_USER_EMAIL` also belong here when they differ by machine or account.
  - Start from `shellConfigs/local.example`.

- `softlinks/sshconfig.local`
  - Ignored by git.
  - Included by the shared `softlinks/sshconfig`.
  - Use it for machine-local SSH hosts, agent sockets, OrbStack includes, and network-specific host aliases.
  - Start from `softlinks/sshconfig.local.example`.

- `~/.ssh/config.local`
  - Also included by the shared `softlinks/sshconfig`.
  - Useful when you want local SSH overrides outside this repo.

## Shared Files

- `softlinks/zshrc`
  - Keeps shared shell behavior only.
  - Machine-specific startup features should be enabled from `shellConfigs/local`.
  - SDKMAN and Nomad completion are now opt-in instead of unconditional shared defaults.

- `softlinks/sshconfig`
  - Acts as the wrapper that composes local SSH config files with the tracked shared host list.
  - Local includes are loaded first so a machine can override a shared alias if needed.

- `softlinks/sshconfig.shared`
  - Keeps cross-machine SSH defaults and host aliases that are genuinely shared.
  - This is the right place for stable public VPS hosts that should exist on every machine.
  - It should not contain local network topology, machine-only agent config, or LAN-only aliases.

- `softlinks/zed/settings.json`
  - Should keep only shareable editor preferences.
  - Machine-local SSH connections and local project paths should stay out of the tracked file.

## Recommended Practice

- Keep secrets and internal endpoints out of tracked files.
- Prefer opt-in flags in `shellConfigs/local` over unconditional startup work in shared config.
- When a setting depends on a specific machine, network, or installed app, put it in a local file instead of the shared layer.
