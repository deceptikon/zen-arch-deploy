#!/bin/bash
# =============================================================================
# Stage 04: PREPARE
# =============================================================================
# Run this in the Arch ISO live environment.
# Verifies UEFI, sets up network, and prepares mount points.
# Safe to run with --dry-run.
#
# Usage:
#   ./stages/04-prepare.sh --profile profiles/my-machine.yaml [--dry-run]
# =============================================================================

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/profile.sh"
source "$SCRIPT_DIR/lib/disk.sh"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      cat <<'EOF'
Usage: 04-prepare.sh --profile PATH [--dry-run]
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

require_root

log_info "╔═══════════════════════════════════════════════════════════════╗"
log_info "║          STAGE 04: PREPARE                                    ║"
log_info "╚═══════════════════════════════════════════════════════════════╝"

# ---------------------------------------------------------------------------
# 1. Verify UEFI
# ---------------------------------------------------------------------------
verify_uefi

# ---------------------------------------------------------------------------
# 2. Verify disk exists
# ---------------------------------------------------------------------------
_dev=$(profile_get_or_die "storage.disk")
verify_disk "$_dev"

# ---------------------------------------------------------------------------
# 3. Network
# ---------------------------------------------------------------------------
log_info "Checking network connectivity..."
if ping -c 1 -W 3 archlinux.org &>/dev/null; then
  log_ok "Network OK"
else
  log_warn "No network. Attempting DHCP via systemd-networkd..."
  # Modern Arch ISO uses systemd-networkd, not dhcpcd
  if command -v networkctl &>/dev/null; then
    run systemctl start systemd-networkd || log_warn "systemd-networkd start failed"
    sleep 3
  elif command -v dhcpcd &>/dev/null; then
    run dhcpcd || log_warn "dhcpcd failed (network may already be configured)"
    sleep 2
  else
    log_warn "No DHCP client found (systemd-networkd or dhcpcd)"
  fi
  ping -c 1 -W 3 archlinux.org &>/dev/null || die "Network unreachable. Fix before proceeding."
fi

# ---------------------------------------------------------------------------
# 4. Update system clock
# ---------------------------------------------------------------------------
run timedatectl set-ntp true
log_ok "NTP enabled"

# ---------------------------------------------------------------------------
# 5. Verify partitions exist
# ---------------------------------------------------------------------------
efi_dev=$(profile_get_or_die "storage.partitions.efi.device")
root_dev=$(profile_get_or_die "storage.partitions.root_pool.device")

[[ -b "$efi_dev" ]] || die "EFI partition not found: $efi_dev"
[[ -b "$root_dev" ]] || die "Root pool partition not found: $root_dev"

log_ok "Partitions verified:"
log "  EFI : $efi_dev"
log "  Root: $root_dev"

# ---------------------------------------------------------------------------
# 6. Check existing subvolumes (dry-run safe preview)
# ---------------------------------------------------------------------------
log_info "Current BTRFS subvolumes on $root_dev:"
if [[ "$DRY_RUN" == "false" ]]; then
  tmpmnt=$(mktemp -d)
  if mount "$root_dev" "$tmpmnt"; then
    if btrfs subvolume list "$tmpmnt" &>/dev/null; then
      btrfs subvolume list "$tmpmnt"
    else
      log_warn "Could not list subvolumes on $root_dev"
    fi
    umount "$tmpmnt" || log_warn "Failed to unmount $tmpmnt"
  else
    log_warn "Failed to mount $root_dev for subvolume preview"
  fi
  rmdir "$tmpmnt"
fi

# ---------------------------------------------------------------------------
# 7. Confirm wipe strategy
# ---------------------------------------------------------------------------
strategy=$(profile_get_or_die "storage.wipe_strategy")
log_info "Configured wipe strategy: $strategy"

if [[ "$strategy" == "subvol-reset" ]]; then
  log_warn "This will DELETE the @ subvolume and create a fresh one."
  log_warn "@home and @swap will be PRESERVED."
else
  log_warn "Unknown wipe strategy: $strategy"
fi

if [[ "$DRY_RUN" == "false" ]]; then
  confirm_critical "Proceed with PREPARE stage?"
fi

log_ok "Stage 04 PREPARE complete. Ready for EXECUTE."
