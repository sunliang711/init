# Progress

## Status

Current phase:
Task 7 completed. Refactor plan complete for the current scope, with post-plan hardening finished for `scripts/setGit.sh`.

## Completed

- Reduced shared `oh-my-zsh` plugins in `softlinks/zshrc`.
- Switched `nvm` loading to lazy loading in `softlinks/zshrc`.
- Prevented duplicate `sdkman` initialization by guarding the shared `zshrc` load path.
- Stopped automatic proxy detection on every shell startup unless `AUTO_DETECT_PROXY_ENV` is set locally.
- Stopped automatic `screenfetch` on every shell startup unless `AUTO_SCREENFETCH` is set locally.
- Completed Task 1 by making `install.sh` componentized with `install`, `uninstall`, `check`, and `components` command support.
- Added component selection, safer default install components, install summaries, and `--dry-run` support in `install.sh`.
- Completed Task 2 by shrinking uninstall scope to repo-managed artifacts only.
- Updated `scripts/zsh.sh` to remove repo-owned symlinks, managed blocks, and plugin clones instead of deleting entire user directories.
- Updated `scripts/installFzf.sh` and `scripts/tmux.sh` to track managed artifacts in local state files and uninstall only those artifacts.
- Updated `tools/updateInit.sh` to remove only the exact cron entry created by this repo.
- Updated `scripts/setGit.sh unset` to clear only the keys managed by the script instead of deleting the whole `~/.gitconfig`.
- Completed Task 3 by extracting shared shell helpers into `lib/init-common.sh`.
- Moved the main install flow and core component scripts to the shared shell library instead of duplicating bootstrap logic.
- Fixed shared home-path resolution so migrated scripts follow the target user environment and local temp-home verification works correctly.
- Added compatibility aliases for existing color variables and normalized symlink target matching for repo-managed links.
- Completed Task 4 by making the main install scripts stable across repeated runs.
- Updated `scripts/zsh.sh` to skip redundant oh-my-zsh/plugin installs and to back up unmanaged `.zshrc`, `ssh/config`, and conflicting theme files before linking repo-managed ones.
- Updated `scripts/tmux.sh` to back up unmanaged `~/.tmux.conf` once before writing the managed config and to skip redundant TPM clones.
- Updated `scripts/vim.sh` to back up unmanaged `~/.vimrc`, skip redundant nerdtree clones, and run helptags in silent batch mode.
- Updated `scripts/installFzf.sh` to repair missing shell integration files on rerun when the existing repo matches the expected fzf clone.
- Completed Task 5 by separating shared config from machine-local config more explicitly.
- Replaced the tracked SSH host inventory in `softlinks/sshconfig` with a shared wrapper that includes ignored local SSH files instead.
- Added tracked templates for machine-local shell overrides and SSH config in `shellConfigs/local.example` and `softlinks/sshconfig.local.example`.
- Added `docs/local-config.md` to document the shared/local boundary and the intended local extension points.
- Removed machine-local Zed SSH connections and project paths from the tracked `softlinks/zed/settings.json`.
- Moved Nomad shell completion in `softlinks/zshrc` behind the local opt-in flag `ENABLE_NOMAD_COMPLETION`.
- Completed Task 6 by profiling the remaining shell startup hotspots and tightening the remaining shared startup defaults.
- Confirmed the remaining dominant startup cost is `oh-my-zsh` completion setup (`compinit` and `compdump`), while the repo-managed additions are now comparatively small.
- Moved shared SDKMAN initialization in `softlinks/zshrc` behind the local opt-in flag `ENABLE_SDKMAN`.
- Aligned the current machine's ignored `shellConfigs/local` to the new `ENABLE_SDKMAN=1` flag instead of a hardcoded absolute SDKMAN source path.
- Completed Task 7 by adding top-level repo documentation and a reusable verification entrypoint.
- Added `README.md` with install usage, rollback notes, and shared/local config guidance.
- Added `tools/verify-init.sh` to run syntax and smoke checks for the current install chain.
- Further split SSH config into a tracked `softlinks/sshconfig.shared` layer for cross-machine public hosts plus ignored local override files for LAN and machine-specific entries.
- Hardened `scripts/setGit.sh set` so it now prefers CLI flags, then `INIT_GIT_USER_NAME` / `INIT_GIT_USER_EMAIL`, then existing global git config, and only falls back to interactive prompts when needed.
- Kept `whiptail` as an optional interactive UI layer instead of making it the primary input path.
- Removed the old hardcoded git identity defaults and added explicit validation/error handling for git config writes.
- Added `install.sh --all` as an explicit shorthand for selecting all components supported by the current action.
- Removed the active install chain's runtime dependency on `~/.local/apps/init` by deriving the repo root dynamically from the current script location.
- Updated `scripts/zsh.sh` to generate `~/.ssh/config` with absolute includes for the current repo instead of symlinking a fixed-path wrapper file.
- Updated `softlinks/zshrc` and `tools/updateInit.sh` to follow the repo's actual path, while keeping `~/.local/apps/init` as a documented default instead of a hard requirement.

## Verification

- `zsh -n softlinks/zshrc` passed.
- Measured `zsh -i -c exit` improved from about `0.42s` to about `0.29s` in the current sandboxed environment.
- Remaining startup hotspots are still dominated by `oh-my-zsh` completion initialization.
- `bash -n install.sh` passed.
- `bash install.sh help` passed.
- `bash install.sh components` passed.
- `bash install.sh check --components zsh,fzf` passed.
- `bash install.sh check all` passed.
- `bash install.sh install --dry-run git,zsh --proxy http://127.0.0.1:7890` passed.
- `bash -n scripts/zsh.sh` passed.
- `bash -n scripts/installFzf.sh` passed.
- `bash -n scripts/tmux.sh` passed.
- `bash -n tools/updateInit.sh` passed.
- `bash -n scripts/setGit.sh` passed.
- Simulated `scripts/zsh.sh uninstall` removed only repo-managed symlinks, theme links, plugin clones, and managed config blocks while preserving unrelated files.
- Simulated `scripts/installFzf.sh uninstall` removed only the managed `fzf` dir and generated shell files.
- Simulated `scripts/tmux.sh uninstall` removed only the managed tmux config and TPM clone while preserving unrelated tmux files.
- Simulated `scripts/setGit.sh unset` preserved unrelated git config entries.
- Simulated `tools/updateInit.sh install/uninstall` kept unrelated cron entries and removed only the exact repo-managed cron line.
- `bash -n lib/init-common.sh install.sh scripts/setGit.sh scripts/zsh.sh scripts/installFzf.sh scripts/tmux.sh scripts/vim.sh tools/updateInit.sh` passed after the shared-library extraction.
- `bash install.sh help`, `components`, `check --components zsh,fzf`, `check all`, and `install --dry-run git,zsh --proxy http://127.0.0.1:7890` all passed after Task 3 and Task 4 updates.
- `bash scripts/zsh.sh help`, `bash scripts/installFzf.sh help`, `bash scripts/tmux.sh help`, `bash scripts/vim.sh help`, and `bash tools/updateInit.sh help` all passed after the refactor.
- Simulated `scripts/zsh.sh install` backed up conflicting user files once, reused existing managed plugin repos, and stayed stable on the second run.
- Simulated `scripts/installFzf.sh install` repaired missing `~/.fzf.zsh` and `~/.fzf.bash` files from an existing matching repo and stayed stable on rerun.
- Simulated `scripts/tmux.sh install` backed up an unmanaged `~/.tmux.conf` once and stayed stable on rerun.
- Simulated `scripts/vim.sh user` backed up an unmanaged `~/.vimrc` once, reused an existing nerdtree clone, and stayed stable on rerun.
- `zsh -n softlinks/zshrc` passed after moving Nomad completion behind a local opt-in flag.
- `ssh -F softlinks/sshconfig -G localhost` passed with no local override files present, confirming the shared SSH wrapper stays parseable by default.
- Re-audited the shared SSH config and tracked Zed settings to confirm machine-specific host aliases and local project paths were removed from the tracked layer.
- Profiled zsh startup with `zprof`; the largest remaining costs were `compinit`, `compdef`, and `compdump` from `oh-my-zsh`, while repo-managed additions were much smaller.
- In a writable temp-home simulation without ignored local files, hot startup stabilized around `0.08s`.
- In a writable temp-home simulation with SDKMAN installed but not enabled locally, hot startup stabilized around `0.09s`.
- In the same simulation with `ENABLE_SDKMAN=1`, hot startup was about `0.10s` to `0.11s`, confirming the opt-in saves a small but measurable amount when SDKMAN is present but unnecessary.
- `bash tools/verify-init.sh` passed, covering syntax checks plus help/smoke checks for the main install scripts.
- `ssh -F softlinks/sshconfig -G bwg` resolved successfully after introducing `softlinks/sshconfig.shared`.
- `bash scripts/setGit.sh help` passed after the input-flow hardening.
- Simulated `scripts/setGit.sh set --name ... --email ... --non-interactive` wrote the expected git identity and aliases in a temp home.
- Simulated `scripts/setGit.sh set --non-interactive` with `INIT_GIT_USER_NAME` / `INIT_GIT_USER_EMAIL` fallback wrote the expected git identity in a temp home.
- Simulated `scripts/setGit.sh set --non-interactive` with existing global `user.name` / `user.email` fallback reused the expected values in a temp home.
- Simulated `scripts/setGit.sh set --non-interactive` without a usable email failed with a clear error.
- Simulated `scripts/setGit.sh set --email invalid-email --non-interactive` failed validation as expected.
- `bash install.sh install --all --dry-run` passed, confirming the new full-selection flag maps cleanly onto the existing component expansion flow.
- `bash tools/verify-init.sh` passed after removing hardcoded runtime repo-path assumptions from the active install chain.
- Simulated `scripts/zsh.sh install` in a temp home wrote `~/.ssh/config` with absolute includes pointing at the current repo path, and simulated uninstall removed the generated wrapper cleanly.

## Pending Confirmation

- None for the current refactor plan.

## Notes

- This repo is shared across multiple machines, so tracked files should stay machine-agnostic.
- Files excluded by `.gitignore`, especially `shellConfigs/local`, should be treated as machine-local extension points.
- `scripts/zed.sh` and `scripts/nvim.sh` are intentionally left outside Task 3 for now because they are not part of the current install chain.
- Progress in this file should be updated whenever a confirmed task starts, changes status, or finishes.
