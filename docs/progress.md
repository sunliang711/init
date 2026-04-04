# Progress

## Status

Current phase:
Task 4 completed. Ready for Task 5.

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

## Pending Confirmation

- Task 5: Separate shared config from machine-local config.
- Task 6: Continue shell startup optimization.
- Task 7: Add repo documentation and verification.

## Notes

- This repo is shared across multiple machines, so tracked files should stay machine-agnostic.
- Files excluded by `.gitignore`, especially `shellConfigs/local`, should be treated as machine-local extension points.
- `scripts/zed.sh` and `scripts/nvim.sh` are intentionally left outside Task 3 for now because they are not part of the current install chain.
- Progress in this file should be updated whenever a confirmed task starts, changes status, or finishes.
