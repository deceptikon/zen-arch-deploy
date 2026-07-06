---
name: arch-deploy-security-audit
description: Security audit findings, known vulnerability patterns, and safe coding rules for arch-deploy (shell scripts, profile configs, dotfiles)
source: auto-skill
extracted_at: '2026-07-06T08:00:47.113Z'
---

# Arch-Deploy Security Audit — Persistent Findings

When reviewing, editing, or writing code in this project, follow these rules to avoid known vulnerabilities.

## Credential Handling

- **Never hardcode passwords.** The root password `root:root` in `stages/05-execute.sh` and `echo "${USERNAME}:${USERNAME}" | chpasswd` in `stages/06-configure.sh` must be replaced with interactive prompts or random passwords stored in a secure location before any production use.
- VM test scripts in `vm-test/` embed `root:root` — acceptable for isolated loopback tests only, but never propagate this pattern to production scripts.

## Sudoers File Permissions

**Rule:** Every file written to `/etc/sudoers.d/` **must** have `chmod 440` applied immediately after creation.

Found broken in `stages/06-configure.sh` — the `99-zzz-${USERNAME}` and `99-zzz-${BUILD_USER}` files lack `chmod 440`, which causes `sudo` to refuse them entirely (sudo requires mode ≤ 0640 and must not be group/world-writable).

```bash
echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-zzz-${USERNAME}
chmod 440 /etc/sudoers.d/99-zzz-${USERNAME}   # MANDATORY
```

## sed Injection via Profile Values

**Rule:** Never interpolate unescaped strings into `sed` replacement patterns. Found in `stages/05-execute.sh` where `HOOKS_LINE` (assembled from profile hook names) is used directly in `sed -i "s/^HOOKS=.*/${HOOKS_LINE}/"`. If any hook name contains `/`, `&`, or `\`, the sed command breaks or can be hijacked.

**Fix:** Use a different delimiter (e.g., `|` or `@`) and escape `&` and `\` in the replacement string, or use a non-sed approach (e.g., write the whole file with a heredoc, or use `awk`).

## eval with jq — Missing Quotes

**Rule:** Always quote the command substitution in `eval "$(jq ...)"`. Found unquoted in `dotfiles/dot_config/waybar/scripts/sysmon/formatter.sh:26` — `eval $(jq -r '...' <<< "$data")` is vulnerable to word-splitting and globbing before eval processes it. The `@sh` output format is safe, but the missing quotes around `$(...)` negate that protection.

## SSH Host Key Verification

**Rule:** `StrictHostKeyChecking=no` and `UserKnownHostsFile=/dev/null` are acceptable **only** for loopback test VMs (`localhost:2222`). Never use this pattern when connecting to remote machines.

## 9p VirtFS security_model

`security_model=none` in `vm-test/run-qemu.sh` is acceptable for test VMs. Never adapt this for production or non-loopback scenarios — use `security_model=mapped` or `passthrough` with proper ID mapping.

## Profile .env Sourcing

The `.env` companion file is blindly `source`-ed in `lib/profile.sh:112`. If the profiles directory is writable by an attacker, arbitrary command execution is possible. Guard this with file ownership/permission checks if the threat model includes profile tampering.

## Read-Only Mount Verification Bug

In `stages/03-validate.sh`, the RO mount check is broken:
```bash
if grep -q " $MOUNT_POINT " /proc/mounts | grep -q "\bro\b"; then
```
The `-q` flag makes `grep` output nothing, so the pipe to the second `grep` always fails. Fix:
```bash
if grep " $MOUNT_POINT " /proc/mounts | grep -q "\bro\b"; then
```

## AUR Supply Chain

Building AUR packages with `makepkg -si --noconfirm` skips package review and signature verification. Consider `makepkg -s` (without `-i` or `--noconfirm`) for reviewable builds, or use a pinned checksum/signature verification step.

## Positive Patterns to Keep

- `python yaml.safe_load` (not `yaml.load`) — safe against YAML deserialization attacks
- `set -euo pipefail` consistently across stages
- `read -rp ...; [[ "$ans" == "yes" ]]` confirmations for destructive operations
- `jq -nc --arg` for JSON output (injects-safe)
- `jq @sh` quoting pattern (safe when the command substitution is properly quoted)
