#!/bin/bash
# =============================================================================
# Stage 01: INSPECT
# =============================================================================
# Run this on your CURRENT host system before any wipe.
# Collects deep system state for profile generation and security baseline.
#
# Usage:
#   ./stages/01-inspect.sh [--output DIR]
#
# Output:
#   inspect-out/
#     hardware.txt
#     storage.txt
#     btrfs.txt
#     packages.txt
#     services.txt
#     security/
#       hashes.txt
#       listeners.txt
#       setuid.txt
#       pacman.log.tail
#     sway.txt
#     dotfiles/
#       config-dirs.txt
#       home-dotfiles.txt
# =============================================================================

# NOTE: NO set -e here. inspect is a data collector; one failed command
# should not kill the entire scan. We check exits explicitly where needed.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/profile.sh"
set +e  # restore NO set -e after common.sh sets it

OUTPUT_DIR="${1:-./inspect-out}"
[[ "$OUTPUT_DIR" == --output ]] && OUTPUT_DIR="${2:-./inspect-out}"

mkdir -p "$OUTPUT_DIR/security" "$OUTPUT_DIR/dotfiles"

log_info "Starting deep inspection. Output: $OUTPUT_DIR"

# Detect if running from Arch ISO
if [[ -f /run/archiso/bootmnt/arch/pkglist.x86_64.txt ]]; then
  log_warn "Detected Arch ISO environment. Some inspect features will be limited."
  log_warn "  - No pacman package database (pacman -Q will fail)"
  log_warn "  - Root filesystem is overlayfs, not your target disk"
  log_warn "  - Disk layout discovery should still work via lsblk/blkid"
fi

# ---------------------------------------------------------------------------
# Hardware
# ---------------------------------------------------------------------------
{
  echo "=== MACHINE ==="
  if [[ -r /sys/class/dmi/id/product_name ]]; then
    cat /sys/class/dmi/id/product_name
  else
    echo "MISSING: DMI product_name not readable"
  fi
  if [[ -r /sys/class/dmi/id/product_version ]]; then
    cat /sys/class/dmi/id/product_version
  else
    echo "MISSING: DMI product_version not readable"
  fi
  echo "=== CPU ==="
  if command -v lscpu; then
    lscpu | grep -E "Vendor ID|Model name|Thread|Core"
  else
    echo "MISSING: lscpu"
  fi
  echo "=== RAM ==="
  if command -v free; then
    free -h
  else
    echo "MISSING: free"
  fi
  echo "=== DISKS ==="
  # Primary: blkid reads superblocks directly (works even when kernel hasn't probed)
  if command -v blkid; then
    blkid -o export
  else
    echo "MISSING: blkid"
  fi
  echo "---"
  echo "=== DISK TOPOLOGY ==="
  # Secondary: lsblk for partition tree (topology only; fs info from blkid)
  if command -v lsblk; then
    lsblk --pairs
  else
    echo "MISSING: lsblk"
  fi
  echo "=== PCI ==="
  if command -v lspci; then
    lspci -nnk | grep -A2 -E "VGA|Audio|Network|Ethernet|Wireless"
  else
    echo "MISSING: lspci"
  fi
  echo "=== USB ==="
  if command -v lsusb; then
    lsusb
  else
    echo "MISSING: lsusb"
  fi
  echo "=== FIRMWARE ==="
  if [[ -d /sys/firmware/efi ]]; then
    echo "UEFI mode"
  else
    echo "Legacy BIOS"
  fi
  if command -v efibootmgr; then
    efibootmgr -v
  else
    echo "MISSING: efibootmgr"
  fi
} > "$OUTPUT_DIR/hardware.txt"
log_ok "hardware.txt written"

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

# Discover all BTRFS filesystems on the system, not just at /
# This handles: host systems, ISO environments, external drives, etc.

declare -a BTRFS_DEVICES=()
declare -a BTRFS_MOUNTS=()

btrfs_discover() {
  log_info "Discovering BTRFS filesystems..."

  # Fast path: root filesystem is btrfs
  if command -v findmnt; then
    if findmnt -o FSTYPE -n / | grep -q '^btrfs$'; then
      log_ok "Root filesystem is BTRFS"
      BTRFS_DEVICES+=("$(findmnt -o SOURCE -n /)")
      BTRFS_MOUNTS+=("/")
      return 0
    fi
  fi

  # Scan all block devices for btrfs filesystems via blkid
  if command -v blkid; then
    while read -r dev; do
      [[ -n "$dev" ]] || continue
      local skip=false
      for d in "${BTRFS_DEVICES[@]+"${BTRFS_DEVICES[@]}"}"; do
        [[ "$d" == "$dev" ]] && skip=true && break
      done
      if [[ "$skip" == false ]]; then
        log_info "Found BTRFS device: $dev"
        BTRFS_DEVICES+=("$dev")
        BTRFS_MOUNTS+=("")
      fi
    done < <(blkid -t TYPE=btrfs -o device)
  fi

  # Also check btrfs filesystem show as a secondary scan
  if command -v btrfs; then
    while read -r dev; do
      [[ -n "$dev" ]] || continue
      local skip=false
      for d in "${BTRFS_DEVICES[@]+"${BTRFS_DEVICES[@]}"}"; do
        [[ "$d" == "$dev" ]] && skip=true && break
      done
      if [[ "$skip" == false ]]; then
        log_info "Found BTRFS device (via btrfs show): $dev"
        BTRFS_DEVICES+=("$dev")
        BTRFS_MOUNTS+=("")
      fi
    done < <(btrfs filesystem show -d | awk '/dev/ {print $NF}')
  fi

  if [[ ${#BTRFS_DEVICES[@]} -eq 0 ]]; then
    log_warn "No BTRFS filesystems found on any block device"
    return 1
  fi

  return 0
}

btrfs_inspect_device() {
  local dev="$1"
  local idx="$2"
  local was_mounted=false
  local mnt=""

  # Check if already mounted somewhere
  if command -v findmnt; then
    mnt=$(findmnt -o TARGET -n "$dev" | head -n1)
  fi

  if [[ -n "$mnt" ]]; then
    log_info "BTRFS $dev already mounted at $mnt"
    was_mounted=true
  else
    # Temporarily mount to inspect
    mnt=$(mktemp -d)
    log_info "Temporarily mounting $dev at $mnt for inspection..."
    if ! mount -t btrfs "$dev" "$mnt"; then
      log_warn "Failed to mount $dev — skipping BTRFS inspection for this device"
      rmdir "$mnt"
      return 1
    fi
    was_mounted=false
  fi

  echo "---"
  echo "=== BTRFS DEVICE: $dev ==="
  echo "Mountpoint: $mnt"
  echo "---"
  echo "=== SUBVOLUMES ==="
  if command -v btrfs; then
    if ! btrfs subvolume list "$mnt"; then
      log_warn "Could not list subvolumes on $dev"
    fi
  else
    log_warn "btrfs tool not available"
  fi
  echo "---"
  echo "=== DF ==="
  if ! btrfs filesystem df "$mnt"; then
    log_warn "Could not get df for $dev"
  fi
  echo "---"
  echo "=== USAGE ==="
  if ! btrfs filesystem usage "$mnt"; then
    log_warn "Could not get usage for $dev"
  fi
  echo "---"
  echo "=== UUID ==="
  if ! blkid -s UUID -o value "$dev"; then
    log_warn "Could not get UUID for $dev"
  fi

  # Unmount if we mounted it
  if [[ "$was_mounted" == false ]]; then
    if ! umount "$mnt"; then
      log_warn "Failed to unmount $mnt"
    fi
    rmdir "$mnt"
  fi
}

{
  echo "=== BLOCK DEVICES ==="
  # lsblk --pairs for topology (NAME, SIZE, type, parent/child); NOT for FSTYPE
  # FSTYPE comes from === BLKID === below — blkid reads superblocks directly
  if command -v lsblk; then
    lsblk --pairs
  else
    echo "MISSING: lsblk"
  fi
  echo "---"
  echo "=== BLKID ==="
  # blkid reads filesystem signatures directly from disk — works even when
  # the kernel block layer hasn't probed the device (e.g., fresh VM virtio disk)
  if command -v blkid; then
    blkid
  else
    echo "MISSING: blkid"
  fi
  echo "---"

  if btrfs_discover; then
    echo "=== BTRFS DETECTED: YES ==="
    for i in "${!BTRFS_DEVICES[@]}"; do
      btrfs_inspect_device "${BTRFS_DEVICES[$i]}" "$i"
    done
  else
    echo "=== BTRFS DETECTED: NO ==="
    echo "No BTRFS filesystems found on any block device."
    echo "If this is intentional (fresh install), generate-profile will use format-full strategy."
  fi

  echo "---"
  echo "=== FINDMNT ==="
  if command -v findmnt; then
    findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS
  else
    echo "MISSING: findmnt"
  fi
  echo "---"
  echo "=== FSTAB ==="
  if [[ -f /etc/fstab ]]; then
    cat /etc/fstab
  else
    echo "No /etc/fstab (running from ISO?)"
  fi
  echo "---"
  echo "=== KERNEL CMDLINE ==="
  cat /proc/cmdline
} > "$OUTPUT_DIR/storage.txt"
log_ok "storage.txt written"

# ---------------------------------------------------------------------------
# Packages (deep scan)
# ---------------------------------------------------------------------------
{
  echo "=== ALL NATIVE PACKAGES ==="
  if pacman -Qqn; then
    pacman -Qqn | sort
  else
    echo "MISSING: pacman package database (running from ISO?)"
    log_warn "pacman -Qqn failed — likely on ISO or fresh install"
  fi
  echo "---"
  echo "=== ALL FOREIGN (AUR) PACKAGES ==="
  if pacman -Qqm; then
    pacman -Qqm | sort
  else
    echo "MISSING: pacman package database"
  fi
  echo "---"
  echo "=== ORPHANS ==="
  if pacman -Qqdt; then
    pacman -Qqdt | sort
  else
    echo "NO ORPHANS (or pacman -Qqdt unavailable)"
  fi
  echo "---"
  echo "=== EXPLICIT PACKAGES ==="
  if pacman -Qqe; then
    pacman -Qqe | sort
  else
    echo "MISSING: pacman package database"
  fi
  echo "---"
  echo "=== PACKAGE FILE INTEGRITY (non-zero altered) ==="
  if command -v timeout && pacman -Qkk; then
    altered=$(timeout 10 pacman -Qkk | grep -v "0 altered files")
    if [[ -n "$altered" ]]; then
      echo "$altered"
    else
      echo "No altered files detected"
    fi
  else
    echo "MISSING: timeout or pacman -Qkk unavailable"
  fi
} > "$OUTPUT_DIR/packages.txt"
log_ok "packages.txt written"

# ---------------------------------------------------------------------------
# Services & Units
# ---------------------------------------------------------------------------
{
  echo "=== ENABLED SERVICES ==="
  if command -v systemctl; then
    systemctl list-unit-files --state=enabled --no-pager
  else
    echo "MISSING: systemctl"
  fi
  echo "---"
  echo "=== ALL UNIT FILES ==="
  if command -v systemctl; then
    systemctl list-unit-files --no-pager
  else
    echo "MISSING: systemctl"
  fi
  echo "---"
  echo "=== TIMERS ==="
  if command -v systemctl; then
    systemctl list-timers --all --no-pager
  else
    echo "MISSING: systemctl"
  fi
  echo "---"
  echo "=== USER UNITS ==="
  if systemctl --user list-unit-files --no-pager; then
    systemctl --user list-unit-files --no-pager
  else
    echo "MISSING: user systemd session (expected on ISO)"
  fi
  echo "---"
  echo "=== MKINITCPIO ==="
  if [[ -f /etc/mkinitcpio.conf ]]; then
    grep -E "^MODULES=|^HOOKS=|^BINARIES=|^FILES=" /etc/mkinitcpio.conf
  else
    echo "MISSING: /etc/mkinitcpio.conf (running from ISO?)"
  fi
} > "$OUTPUT_DIR/services.txt"
log_ok "services.txt written"

# ---------------------------------------------------------------------------
# Security Baseline
# ---------------------------------------------------------------------------
{
  echo "=== CRITICAL BINARY HASHES ==="
  for f in /usr/bin/sudo /usr/bin/login /usr/bin/pacman /usr/lib/systemd/systemd \
           /boot/vmlinuz-linux-zen /boot/grub/x86_64-efi/core.efi; do
    if [[ -f "$f" ]]; then
      sha256sum "$f"
    else
      echo "MISSING: $f"
    fi
  done
} > "$OUTPUT_DIR/security/hashes.txt"

{
  echo "=== LISTENING SOCKETS ==="
  if command -v ss; then
    ss -tulpn
  else
    echo "MISSING: ss"
  fi
  echo "---"
  echo "=== ESTABLISHED CONNECTIONS ==="
  if command -v ss; then
    ss -tpn state established
  else
    echo "MISSING: ss"
  fi
} > "$OUTPUT_DIR/security/listeners.txt"

{
  echo "=== SETUID BINARIES ==="
  if command -v find; then
    timeout 10 find /usr/bin -maxdepth 1 -perm -4000 ! -type d -exec ls -la {} \;
    timeout 10 find /usr/lib -maxdepth 2 -perm -4000 ! -type d -exec ls -la {} \;
  else
    echo "MISSING: find"
  fi
  echo "---"
  echo "=== ORPHANED SETUID ==="
  if command -v find && command -v pacman; then
    timeout 10 find /usr/bin /usr/lib -maxdepth 2 -perm -4000 ! -type d -print | while read -r f; do
      if ! pacman -Qo "$f"; then
        echo "ORPHAN: $f"
      fi
    done
  else
    echo "MISSING: find or pacman"
  fi
} > "$OUTPUT_DIR/security/setuid.txt"

if [[ -r /var/log/pacman.log ]]; then
  tail -n 1000 /var/log/pacman.log > "$OUTPUT_DIR/security/pacman.log.tail"
else
  log_warn "/var/log/pacman.log not readable"
fi

{
  echo "=== SUDOERS ==="
  if [[ -f /etc/sudoers ]]; then
    cat /etc/sudoers
  else
    echo "MISSING: /etc/sudoers"
  fi
  echo "---"
  echo "=== SUDOERS.D ==="
  if [[ -d /etc/sudoers.d/ ]]; then
    find /etc/sudoers.d/ -type f -exec echo "==> {}" \; -exec cat {} \;
  else
    echo "MISSING: /etc/sudoers.d/"
  fi
} > "$OUTPUT_DIR/security/sudoers.txt"

log_ok "Security baseline written"

# ---------------------------------------------------------------------------
# Sway / Desktop
# ---------------------------------------------------------------------------
{
  echo "=== SWAY OUTPUTS ==="
  if command -v swaymsg; then
    swaymsg -t get_outputs
  else
    echo "MISSING: swaymsg (Sway not running?)"
  fi
  echo "---"
  echo "=== SWAY INPUTS ==="
  if command -v swaymsg; then
    swaymsg -t get_inputs
  else
    echo "MISSING: swaymsg (Sway not running?)"
  fi
  echo "---"
  echo "=== WAYLAND ENVS ==="
  env_matches=$(env | grep -iE "wayland|sway|xdg|cursor")
  if [[ -n "$env_matches" ]]; then
    echo "$env_matches"
  else
    echo "NO WAYLAND ENVS"
  fi
  echo "---"
  echo "=== GPU DRIVER ==="
  if command -v glxinfo; then
    glxinfo -B | grep "OpenGL renderer"
  else
    echo "MISSING: glxinfo"
  fi
} > "$OUTPUT_DIR/sway.txt"
log_ok "sway.txt written"

# ---------------------------------------------------------------------------
# Dotfiles
# ---------------------------------------------------------------------------
{
  if [[ -d ~/.config ]]; then
    find ~/.config -maxdepth 1 -type d | sort
  else
    echo "N/A — ~/.config not found"
  fi
} > "$OUTPUT_DIR/dotfiles/config-dirs.txt"

{
  if [[ -d ~ ]]; then
    find ~ -maxdepth 1 -name ".*" -type f | sort
  else
    echo "N/A — HOME not found"
  fi
} > "$OUTPUT_DIR/dotfiles/home-dotfiles.txt"

# Optional: archive ~/.local/bin scripts
if [[ -d ~/.local/bin ]]; then
  if ! cp -r ~/.local/bin "$OUTPUT_DIR/dotfiles/local-bin"; then
    log_warn "Failed to copy ~/.local/bin"
  fi
fi

log_ok "Dotfiles inventory written"

# ---------------------------------------------------------------------------
# Final archive
# ---------------------------------------------------------------------------
tar czf "inspect-$(date +%Y%m%d_%H%M%S).tar.gz" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"
log_ok "Inspection complete. Archive created."

if ! inspect_validate "$OUTPUT_DIR"; then
  log_err "Boundary validation failed: inspection data is incomplete."
  exit 1
fi

log_info "Inspect output: $OUTPUT_DIR"
log_info "Log file: $LOG_FILE"
