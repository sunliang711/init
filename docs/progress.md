# Progress

## Status

Current phase:
Startup optimization completed, refactor planning pending confirmation.

## Completed

- Reduced shared `oh-my-zsh` plugins in `softlinks/zshrc`.
- Switched `nvm` loading to lazy loading in `softlinks/zshrc`.
- Prevented duplicate `sdkman` initialization by guarding the shared `zshrc` load path.
- Stopped automatic proxy detection on every shell startup unless `AUTO_DETECT_PROXY_ENV` is set locally.
- Stopped automatic `screenfetch` on every shell startup unless `AUTO_SCREENFETCH` is set locally.

## Verification

- `zsh -n softlinks/zshrc` passed.
- Measured `zsh -i -c exit` improved from about `0.42s` to about `0.29s` in the current sandboxed environment.
- Remaining startup hotspots are still dominated by `oh-my-zsh` completion initialization.

## Pending Confirmation

- Task 1: Make `install.sh` componentized.
- Task 2: Reduce destructive uninstall behavior.
- Task 3: Extract shared shell library.
- Task 4: Make install scripts idempotent.
- Task 5: Separate shared config from machine-local config.
- Task 6: Continue shell startup optimization.
- Task 7: Add repo documentation and verification.

## Notes

- This repo is shared across multiple machines, so tracked files should stay machine-agnostic.
- Files excluded by `.gitignore`, especially `shellConfigs/local`, should be treated as machine-local extension points.
- Progress in this file should be updated whenever a confirmed task starts, changes status, or finishes.
