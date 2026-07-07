# Handover: Devnull Purge + Boundary Validation

## Gained Knowledge

**Rule #1 (blood-written):** `>/dev/null` / `&>/dev/null` / `|| true` — never, zero tolerance. Все логи открыто. Ошибки видны. Degrade gracefully with explicit `if/else` checks. `command -v foo` → capture path, check `-n`. `id user` → let stderr flow, branch on exit code. `pacman -Qo` → capture stdout to variable.

**Rule #2:** Boundary validation between pipeline stages is non-negotiable. Each stage consumer must validate its input before proceeding. TDD mindset: fail early, fail loud, fail with exact reason.

## What Changed

### Devnull eliminated (16 instances across 6 files)
- `require_command()` / `load_profile()` dead code removed from `lib/common.sh`
- `pacman -Qo` audit in `lib/security.sh`
- `id` checks in `lib/pkg.sh`, `stages/06-configure.sh`
- `command -v` checks in `stages/06-configure.sh`, `stages/07-verify.sh`, `vm-test/run-qemu.sh`
- `systemctl is-enabled` / `pacman -Q` in `stages/07-verify.sh`

### Bugs fixed
- `02-generate-profile.sh` — `hostname` cmd not found on Arch ISO → 4-level fallback (cmd → /proc → /etc → warn), no devnull
- `lib/profile.sh` — `.env.env` double extension on non-`.yaml` inputs → `profile_env_path()` strips `.yaml`/`.yml` only, handles direct `.env` pass-through

### Boundary validations added (TDD edge gates)
- `profile_validate()` in `lib/profile.sh` — checks 7 required keys, dies with list of missing
- `inspect_validate()` in `lib/profile.sh` — checks files exist + non-empty + required sections present
- Called in every consuming stage: `inspect_validate` before `02-generate-profile`, `profile_validate` after every `profile_load` in `03-07`

### VM QEMU flow
- Detector (inspect) + generator (generate-profile) work without preset profiles
- VM `--formatted` mode creates pre-populated BTRFS subvolumes for subvol-reset testing
- 9p VirtFS shared directory for transferring scripts into VM

## For Next Session
1. Run full auto-detect flow in QEMU VM: `inspect → generate-profile → prepare → execute`
2. Verify generated VM profile matches actual `/dev/vda` layout
3. Test stage 06 (configure) on booted system
4. Real Zenbook: run `inspect` on host, then Arch ISO pipeline with generated profile
5. Dotfiles refactor for chezmoi integration (waybar 567 files need attention)

## Zero Tolerance Policy
- Any `>/dev/null` in .sh files → immediate revert
- Any `|| true` → same
- Explicit checks only: `[[ -f ]]`, `[[ -n "$(command -v x)" ]]`, `local x; if x=$(cmd); then ...`

## TODO: Curate dotfiles/.chezmoiignore
Decide what should NOT be deployed to a fresh machine via chezmoi.
Candidates to exclude (needs deliberate decision, not done blindly):
- `dot_config/zsh/history` — personal shell history, massive & machine-specific. Currently deploying to preserve it on reformat. Reconsider after first successful reformat.
- `dot_config/zsh/.zcompdump` — zsh completion cache, always regenerated on first zsh start. Safe to exclude.
- `dot_config/waybar/feeds/` — runtime JSON state files, written by daemons. `run_once_00-setup-waybar-runtime.sh` already creates empty placeholders. Excluding would save space but empty files are fine too.
- `dot_config/waybar/logs/` — runtime log files, definitely exclude eventually.
- `dot_config/waybar/docs/`, `**/AGENTS.md`, `**/.qwen/` — dev/AI workspace files, not part of user config.
Note: `chmod -R o+rX` in `06-configure.sh` prevents permission errors during chezmoi init so 600-mode files (like history) no longer block deployment.