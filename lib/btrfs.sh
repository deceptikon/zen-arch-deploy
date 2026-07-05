#!/bin/bash
# =============================================================================
# lib/btrfs.sh — BTRFS subvolume operations
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Validate that a block device is formatted as BTRFS
# ---------------------------------------------------------------------------
validate_device_is_btrfs() {
  local dev="$1"
  log_info "Validating $dev is a BTRFS filesystem..."

  if ! command -v blkid; then
    log_warn "blkid not available — skipping BTRFS validation"
    return 0
  fi

  local fstype
  fstype=$(blkid -s TYPE -o value "$dev")

  if [[ "$fstype" != "btrfs" ]]; then
    log_err "Device $dev is type '$fstype', not BTRFS."
    log_err "Profile requests 'subvol-reset' but target is not a BTRFS pool."
    log_err "Options:"
    log_err "  1. Change profile wipe_strategy to 'format-full' for a fresh install"
    log_err "  2. Or ensure the correct BTRFS device path is in your profile"
    die "BTRFS validation failed for $dev"
  fi

  log_ok "$dev confirmed as BTRFS"
}

# ---------------------------------------------------------------------------
# Wipe only the @ subvolume, preserving @home, @swap, etc.
# ---------------------------------------------------------------------------
wipe_subvol_reset() {
  local dev="$1"
  local backup="${2:-true}"

  validate_device_is_btrfs "$dev"

  local mnt_tmp
  mnt_tmp=$(mktemp -d)

  log_info "Mounting $dev to $mnt_tmp for subvolume operations..."
  mount -t btrfs "$dev" "$mnt_tmp" || die "Failed to mount $dev"

  # Verify expected subvolumes exist
  if [[ ! -d "$mnt_tmp/@" ]]; then
    umount "$mnt_tmp" && rmdir "$mnt_tmp"
    die "Subvolume @ not found on $dev. Aborting to prevent accidental damage."
  fi

  if [[ "$backup" == "true" ]]; then
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    log_warn "Renaming @ to @.bak-$ts for safety..."
    local old_backups=("$mnt_tmp/@.bak-"*)
    if [[ -e "${old_backups[0]}" ]]; then
      if ! run btrfs subvolume delete "$mnt_tmp/@.bak-"*; then
        log_warn "Failed to delete old @.bak subvolumes"
      fi
    fi
    run mv "$mnt_tmp/@" "$mnt_tmp/@.bak-$ts"
  else
    log_warn "Deleting @ subvolume permanently..."
    run btrfs subvolume delete "$mnt_tmp/@"
  fi

  log_info "Creating fresh @ subvolume..."
  run btrfs subvolume create "$mnt_tmp/@"

  # Purge @snapshots if requested (we'll check profile)
  local should_purge
  should_purge=$(profile_get "storage.partitions.root_pool.purge_snapshots")
  if [[ "$should_purge" == "true" ]] && [[ -d "$mnt_tmp/@snapshots" ]]; then
    log_warn "Purging @snapshots contents..."
    run rm -rf "$mnt_tmp/@snapshots"/*
  fi

  umount "$mnt_tmp" && rmdir "$mnt_tmp"
  log_ok "Subvolume reset complete."
}

# ---------------------------------------------------------------------------
# Verify a subvolume exists
# ---------------------------------------------------------------------------
verify_subvol() {
  local dev="$1"
  local subvol="$2"
  local mnt_tmp
  mnt_tmp=$(mktemp -d)
  mount -t btrfs "$dev" "$mnt_tmp" || return 1
  local ret=0
  [[ -d "$mnt_tmp/$subvol" ]] || ret=1
  umount "$mnt_tmp" && rmdir "$mnt_tmp"
  return $ret
}

# ---------------------------------------------------------------------------
# Create missing subvolumes (for brand-new installs, not subvol-reset)
# ---------------------------------------------------------------------------
create_subvols() {
  local dev="$1"
  local mnt_tmp
  mnt_tmp=$(mktemp -d)
  mount -t btrfs "$dev" "$mnt_tmp" || die "Failed to mount $dev"

  local subvols=("@" "@home" "@swap" "@snapshots")
  for sv in "${subvols[@]}"; do
    if [[ ! -d "$mnt_tmp/$sv" ]]; then
      log_info "Creating subvolume $sv..."
      run btrfs subvolume create "$mnt_tmp/$sv"
    fi
  done

  umount "$mnt_tmp" && rmdir "$mnt_tmp"
}
