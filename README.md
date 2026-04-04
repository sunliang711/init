# init

Personal shell and workstation bootstrap repo with a shared core plus machine-local overrides.

## Install Flow

Clone the repo to `~/.local/apps/init`, then use the componentized installer:

```bash
bash install.sh components
bash install.sh install
```

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

Extra smoke checks:

```bash
bash tools/verify-init.sh smoke
bash install.sh install --all --dry-run
bash install.sh install --dry-run git,zsh --proxy http://127.0.0.1:7890
```

## Task Tracking

- [docs/refactor-tasks.md](docs/refactor-tasks.md)
- [docs/progress.md](docs/progress.md)
