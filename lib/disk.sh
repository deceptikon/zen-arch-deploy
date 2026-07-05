#!/bin/bash
# =============================================================================
# lib/disk.sh — Disk and mount helpers
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Verify we are in UEFI mode
# ---------------------------------------------------------------------------
verify_uefi() {
  if [[ ! -d /sys/firmware/efi ]]; then
    die "Not in UEFI mode. This script is designed for UEFI only."
  fi
  log_ok "UEFI mode confirmed."
}

# ---------------------------------------------------------------------------
# Verify a block device exists
# ---------------------------------------------------------------------------
verify_disk() {
  local disk="$1"
  [[ -b "$disk" ]] || die "Block device not found: $disk"
  log_ok "Disk found: $disk"
}

# ---------------------------------------------------------------------------
# Mount subvolumes per profile
# ---------------------------------------------------------------------------
mount_subvols() {
  local root_dev
  root_dev=$(profile_get_or_die "storage.partitions.root_pool.device")

  local mnt="${1:-/mnt}"

  # Collect subvolume definitions from profile env vars
  # They look like: PROFILE_storage__partitions__root_pool__subvolumes__0__name
  # We iterate by index

  local i=0
  while true; do
    local name_var="PROFILE_storage__partitions__root_pool__subvolumes__${i}__name"
    local name="${!name_var:-}"
    [[ -n "$name" ]] || break

    local mount_var="PROFILE_storage__partitions__root_pool__subvolumes__${i}__mount"
    local mpoint="${!mount_var:-}"

    local opts_var="PROFILE_storage__partitions__root_pool__subvolumes__${i}__options"
    local extra_opts="${!opts_var:-}"

    local target="$mnt$mpoint"
    local opts="rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=${name}"
    [[ -n "$extra_opts" ]] && opts="${opts},${extra_opts}"

    run mkdir -p "$target"
    run mount -o "$opts" "$root_dev" "$target"

    ((i++))
  done

  # Mount EFI
  local efi_dev
  efi_dev=$(profile_get_or_die "storage.partitions.efi.device")
  local efi_mpoint
  efi_mpoint=$(profile_get_or_die "storage.partitions.efi.mount")
  local efi_target="$mnt$efi_mpoint"
  run mkdir -p "$efi_target"
  run mount -o rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro "$efi_dev" "$efi_target"
}

# ---------------------------------------------------------------------------
# Generate fstab from profile
# ---------------------------------------------------------------------------
generate_fstab() {
  local mnt="${1:-/mnt}"
  local fstab="$mnt/etc/fstab"

  local root_dev
  root_dev=$(profile_get_or_die "storage.partitions.root_pool.device")
  local root_uuid
  root_uuid=$(blkid -s UUID -o value "$root_dev")
  [[ -n "$root_uuid" ]] || die "Could not determine UUID of $root_dev"

  local efi_dev
  efi_dev=$(profile_get_or_die "storage.partitions.efi.device")
  local efi_uuid
  efi_uuid=$(blkid -s UUID -o value "$efi_dev")

  run mkdir -p "$(dirname "$fstab")"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would write $fstab"
    return 0
  fi

  local efi_mpoint
  efi_mpoint=$(profile_get_or_die "storage.partitions.efi.mount")
  local efi_fstype
  efi_fstype=$(profile_get "storage.partitions.efi.fstype")
  efi_fstype="${efi_fstype:-vfat}"

  # Build subvolume fstab entries from profile
  local fstab_body=""
  fstab_body+="# BTRFS root pool"$'\n'
  local i=0
  while true; do
    local name_var="PROFILE_storage__partitions__root_pool__subvolumes__${i}__name"
    local name="${!name_var:-}"
    [[ -n "$name" ]] || break

    local mount_var="PROFILE_storage__partitions__root_pool__subvolumes__${i}__mount"
    local mpoint="${!mount_var:-/}"
    [[ "$mpoint" == "/" ]] && mpoint=""
    [[ -n "$mpoint" ]] && mpoint="$mpoint"

    local opts_var="PROFILE_storage__partitions__root_pool__subvolumes__${i}__options"
    local extra_opts="${!opts_var:-}"

    local opts="rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/${name}"
    [[ -n "$extra_opts" ]] && opts="rw,relatime,${extra_opts},subvol=/${name}"

    local pad
    pad=$(printf '%*s' $((45 - ${#mpoint})) '')
    fstab_body+="UUID=${root_uuid}  ${mpoint:-/}${pad}btrfs  ${opts}  0 0"$'\n'
    ((i++))
  done

  fstab_body+=$'\n'"# EFI partition"$'\n'
  local efi_pad
  efi_pad=$(printf '%*s' $((45 - ${#efi_mpoint})) '')
  fstab_body+="UUID=${efi_uuid}   ${efi_mpoint}${efi_pad}${efi_fstype}   rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro  0 2"$'\n'

  fstab_body+=$'\n'"# Swapfile"$'\n'
  fstab_body+="/.swap/swapfile    none     swap   defaults  0 0"$'\n'

  printf '%s\n' "$fstab_body" > "$fstab"
  log_ok "Generated $fstab"
}
