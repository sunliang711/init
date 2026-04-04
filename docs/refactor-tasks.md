# Refactor Tasks

## Context

This repository is shared across multiple machines.

- Tracked files should stay machine-agnostic whenever possible.
- Machine-specific behavior should live in untracked files such as `shellConfigs/local`.
- Startup performance work should prefer opt-in behavior over unconditional side effects.

## Completed Before Refactor

- Reduced default `oh-my-zsh` plugins in `softlinks/zshrc`.
- Switched `nvm` loading in `softlinks/zshrc` to lazy loading.
- Prevented duplicate `sdkman` initialization in `softlinks/zshrc`.
- Moved `detectProxyEnv` auto-run behind `AUTO_DETECT_PROXY_ENV`.
- Moved `screenfetch` auto-run behind `AUTO_SCREENFETCH`.

## Proposed Small Tasks

### Task 1: Make `install.sh` componentized

Status:
Completed.

Goal:
Split the current all-in-one install flow into explicit components.

Scope:

- Add CLI flags or subcommands for `zsh`, `fzf`, `tmux`, `vim`, `git`, and `update`.
- Keep current default behavior only if it remains safe and predictable.
- Document which components modify user-wide files.

Done when:

- `install.sh` can install a subset of components.
- The install summary clearly states what will be changed.

### Task 2: Reduce destructive uninstall behavior

Status:
Completed.

Goal:
Make uninstall operations remove only artifacts created by this repo.

Scope:

- Replace unconditional deletion of shared files with ownership checks or backups.
- Avoid deleting user-managed files such as `~/.gitconfig` or `~/.ssh/config` unless they were linked by this repo.
- Prefer unlinking repo-owned symlinks over removing entire directories.

Done when:

- Uninstall paths are idempotent and non-destructive for pre-existing user config.

### Task 3: Extract shared shell library

Goal:
Remove duplicated bootstrap code across scripts.

Scope:

- Consolidate path detection, color output, logging, root helpers, and command checks.
- Make install scripts source one shared library instead of copying boilerplate.
- Keep the public behavior of existing scripts stable.

Done when:

- Common helpers are defined once and reused across install scripts.

### Task 4: Make install scripts idempotent

Goal:
Allow repeated runs without failure or duplicate setup.

Scope:

- Skip or update existing clones safely.
- Avoid overwriting existing user config without backup or confirmation behavior.
- Make script checks reflect the real install preconditions.

Done when:

- Running the same install step twice produces a stable result.

### Task 5: Separate shared config from machine-local config

Goal:
Make the sync boundary explicit.

Scope:

- Audit tracked files for machine-specific values and move them behind opt-in or local overrides.
- Add a documented template for local-only settings.
- Keep `shellConfigs/local` as the main local extension point.

Done when:

- Shared files no longer assume machine-specific tools, secrets, or local paths by default.

### Task 6: Continue shell startup optimization

Goal:
Address the remaining major startup costs after the first round.

Scope:

- Review `compinit` and `compaudit` overhead.
- Gate `bashcompinit` and Nomad completion behind command existence or opt-in.
- Re-check `sdkman` and other heavyweight initializers for deferral opportunities.
- Record before/after timing for each change.

Done when:

- Startup cost is reduced further without breaking common workflows.

### Task 7: Add repo documentation and verification

Goal:
Make future changes safer and easier to understand.

Scope:

- Add a README for install flow, shared vs local config, and rollback notes.
- Add lightweight verification steps, at minimum syntax checks for shell files.
- Optionally add `shellcheck` guidance or CI later.

Done when:

- A new machine user can understand what the repo changes and how to test it.

## Execution Policy

- Only the startup optimization items above are already applied.
- The tasks in this document should be executed one by one after confirmation.
- Progress must be recorded in `docs/progress.md` as tasks move forward.
