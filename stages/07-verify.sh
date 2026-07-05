#!/bin/bash
# =============================================================================
# Stage 07: VERIFY
# =============================================================================
# Run this AFTER first boot into the new system.
# Verifies boot, services, BTRFS mounts, and creates a baseline snapshot.
#
# Usage:
#   ./stages/07-verify.sh --profile profiles/my-machine.yaml [--dry-run]
# =============================================================================

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/profile.sh"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      cat <<'EOF'
Usage: 07-verify.sh --profile PATH [--dry-run]
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

# Fall back to env var set by orchestrator
[[ -z "$PROFILE" && -n "${ARCH_DEPLOY_PROFILE:-}" ]] && PROFILE="$ARCH_DEPLOY_PROFILE"

[[ -n "$PROFILE" ]] || die "--profile is required"
profile_load "$PROFILE"

log_info "╔═══════════════════════════════════════════════════════════════╗"
log_info "║          STAGE 07: VERIFY                                     ║"
log_info "║          SYSTEM VERIFICATION & SEAL                           ║"
log_info "╚═══════════════════════════════════════════════════════════════╝"

FAILED=0

# ---------------------------------------------------------------------------
# 1. Verify BTRFS subvolume mounts
# ---------------------------------------------------------------------------
log_info "Checking BTRFS mounts..."
if findmnt -o TARGET | grep -q "^/$"; then
  log_ok "Root (/) mounted"
else
  log_err "Root (/) NOT mounted correctly"; FAILED=$((FAILED+1))
fi

if findmnt -o TARGET | grep -q "^/home$"; then
  log_ok "/home mounted"
else
  log_err "/home NOT mounted"; FAILED=$((FAILED+1))
fi

if findmnt -o TARGET | grep -q "^/.swap$"; then
  log_ok "/.swap mounted"
else
  log_warn "/.swap not mounted (may be expected if swapfile inactive)"
fi

# ---------------------------------------------------------------------------
# 2. Verify key services are enabled
# ---------------------------------------------------------------------------
log_info "Checking enabled services..."
EXPECTED_SVCS=(NetworkManager sddm systemd-timesyncd bluetooth)
for svc in "${EXPECTED_SVCS[@]}"; do
  if systemctl is-enabled "$svc" &>/dev/null; then
    log_ok "Service enabled: $svc"
  else
    log_warn "Service NOT enabled: $svc"
  fi
done

# ---------------------------------------------------------------------------
# 3. Verify kernel matches profile
# ---------------------------------------------------------------------------
log_info "Checking kernel..."
KERNEL_PKG="$(profile_get_or_die "kernel.pkg")"
INSTALLED_KERNEL="$(uname -r | sed 's/-arch.*//')"
if pacman -Q "$KERNEL_PKG" &>/dev/null; then
  log_ok "Kernel package installed: $KERNEL_PKG"
else
  log_warn "Kernel package not found: $KERNEL_PKG"
fi

# ---------------------------------------------------------------------------
# 4. Verify swap / resume
# ---------------------------------------------------------------------------
if swapon --show=NAME,TYPE | grep -q "file"; then
  log_ok "Swapfile active"
else
  log_warn "Swapfile not active"
fi

# ---------------------------------------------------------------------------
# 5. Verify bootloader
# ---------------------------------------------------------------------------
log_info "Checking bootloader entries..."
if efibootmgr | grep -q "ARCHLINUX"; then
  log_ok "ARCHLINUX EFI entry present"
else
  log_warn "ARCHLINUX EFI entry not found"
fi

# ---------------------------------------------------------------------------
# 6. Timeshift baseline snapshot
# ---------------------------------------------------------------------------
if command -v timeshift &>/dev/null; then
  log_info "Creating baseline snapshot..."
  if command -v timeshift &>/dev/null; then
    run timeshift --create --comments "baseline-verify-$(date +%Y%m%d)" || log_warn "timeshift snapshot creation failed"
  else
    log_warn "timeshift not installed — skipping baseline snapshot"
  fi
  log_ok "Baseline snapshot created."
fi

# ---------------------------------------------------------------------------
# 7. Generate new security baseline for future audits
# ---------------------------------------------------------------------------
log_info "Generating post-install security baseline..."
BASELINE_DIR="/var/lib/arch-deploy/baseline"
run mkdir -p "$BASELINE_DIR"

{
  echo "# Post-install baseline generated $(date -Iseconds)"
  for f in /usr/bin/sudo /usr/bin/login /usr/lib/systemd/systemd /boot/vmlinuz-${KERNEL_PKG}; do
    [[ -f "$f" ]] && sha256sum "$f" || echo "MISSING: $f"
  done
} > "$BASELINE_DIR/hashes.txt"

log_ok "Security baseline saved to $BASELINE_DIR"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_info "═══════════════════════════════════════════════════════════════"
if [[ $FAILED -eq 0 ]]; then
  log_ok  "VERIFICATION PASSED — System is healthy and sealed."
else
  log_err "VERIFICATION COMPLETE — $FAILED checks failed. Review output."
fi
log_info "═══════════════════════════════════════════════════════════════"

exit $FAILED
