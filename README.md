# init

Personal shell and workstation bootstrap repo with a shared core plus machine-local overrides.

## Install Flow

Clone the repo anywhere, then use the componentized installer. `~/.local/apps/init` is still a reasonable default:

```bash
bash install.sh components
bash install.sh install
```

If you move the repo later, rerun the relevant install step so managed symlinks and generated wrapper files can pick up the new path.

Useful examples:

```bash
bash install.sh install --components zsh,fzf
bash install.sh install --all --dry-run
bash install.sh install git zsh --proxy http://127.0.0.1:7890
bash install.sh uninstall --components zsh,fzf,tmux
bash install.sh check all
```

Default install components:

- `zsh`
- `fzf`
- `tmux`
- `vim`

Available components:

- `git`
- `zsh`
- `fzf`
- `tmux`
- `vim`
- `update`

## Shared Vs Local

This repo is used across multiple machines.

- Keep tracked files machine-agnostic.
- Put secrets, internal endpoints, private hosts, and machine-specific startup flags in ignored local files.
- Shared public SSH hosts can live in `softlinks/sshconfig.shared`.
- Main local extension points:
  - `shellConfigs/local`
  - `softlinks/sshconfig.local`
  - `~/.ssh/config.local`

See [docs/local-config.md](docs/local-config.md) for the current boundary and local templates.

## Lazy Shell Tools

Zsh-only lazy-loading helpers live in [shellConfigs/function](shellConfigs/function). They let machine-local toolchains load on first use instead of during every shell startup.

Keep actual registrations in `shellConfigs/local`, not in `softlinks/zshrc`. That keeps shared config machine-agnostic and avoids enabling toolchains on machines that do not have them installed.

Basic pattern:

```zsh
export TOOL_DIR="$HOME/.tool"
_lazy_register_source toolname "$TOOL_DIR/init.sh" "$TOOL_DIR/completion.sh" -- \
  toolname tool-subcommand another-command
```

- First argument: registration name used internally by the helper.
- Second argument: main script to `source` on first use.
- Extra arguments before `--`: optional extra scripts, such as completions.
- Arguments after `--`: commands that should trigger the lazy load.

If a machine needs eager startup after registration, load it explicitly:

```zsh
_lazy_load_registered toolname
```

Real examples for `shellConfigs/local`:

```zsh
# nvm and common Node.js commands
export NVM_DIR="$HOME/.nvm"
_lazy_register_source nvm "$NVM_DIR/nvm.sh" "$NVM_DIR/bash_completion" -- \
  nvm node npm npx pnpm yarn corepack

# SDKMAN, with optional eager startup when this machine needs it
export SDKMAN_DIR="$HOME/.sdkman"
_lazy_register_source sdkman "$SDKMAN_DIR/bin/sdkman-init.sh" -- sdk
if [[ "${ENABLE_SDKMAN:-}" == "1" ]]; then
  _lazy_load_registered sdkman
fi
```

Use this pattern for machine-specific toolchains such as `nvm`, `sdkman`, `pyenv`, or similar startup-heavy shells integrations.

## Rollback Notes

The install scripts now try to avoid destructive changes:

- `bash install.sh uninstall --components ...` removes only repo-managed artifacts for supported components.
- When a managed install needs to take over an existing user file, it backs that file up as `*.init.bak.<timestamp>`.
- `zsh`, `fzf`, `tmux`, and `update` support uninstall through `install.sh`.

## Verification

Run the lightweight verification script:

```bash
bash tools/verify-init.sh
```

It now covers:

- shell syntax checks for the active install chain
- `shellcheck` when available locally
- temp-home integration tests for the main component scripts

Extra smoke checks:

```bash
bash tools/verify-init.sh smoke
bash tools/verify-init.sh integration
bash install.sh install --all --dry-run
bash install.sh install --dry-run git,zsh --proxy http://127.0.0.1:7890
```

## Task Tracking

- [docs/refactor-tasks.md](docs/refactor-tasks.md)
- [docs/progress.md](docs/progress.md)
