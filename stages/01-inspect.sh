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

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$SCRIPT_DIR/lib/common.sh"

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
    log_warn "Cannot read DMI product_name"
  fi
  if [[ -r /sys/class/dmi/id/product_version ]]; then
    cat /sys/class/dmi/id/product_version
  else
    log_warn "Cannot read DMI product_version"
  fi
  echo "=== CPU ==="
  lscpu | grep -E "Vendor ID|Model name|Thread|Core"
  echo "=== RAM ==="
  free -h
  echo "=== DISKS ==="
  lsblk -f -o NAME,SIZE,FSTYPE,FSVER,MOUNTPOINT,PARTUUID,UUID
  echo "=== PCI ==="
  lspci -nnk | grep -A2 -E "VGA|Audio|Network|Ethernet|Wireless"
  echo "=== USB ==="
  lsusb
  echo "=== FIRMWARE ==="
  [ -d /sys/firmware/efi ] && echo "UEFI mode" || echo "Legacy BIOS"
  if command -v efibootmgr &>/dev/null; then
    efibootmgr -v
  else
    log_warn "efibootmgr not found"
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
  if command -v findmnt &>/dev/null && findmnt -o FSTYPE -n / 2>/dev/null | grep -q '^btrfs$'; then
    log_ok "Root filesystem is BTRFS"
    BTRFS_DEVICES+=("$(findmnt -o SOURCE -n /)")
    BTRFS_MOUNTS+=("/")
    return 0
  fi

  # Scan all block devices for btrfs filesystems
  if command -v blkid &>/dev/null; then
    while read -r dev; do
      [[ -n "$dev" ]] || continue
      # Skip if already in list
      local skip=false
      for d in "${BTRFS_DEVICES[@]}"; do
        [[ "$d" == "$dev" ]] && skip=true && break
      done
      if [[ "$skip" == false ]]; then
        log_info "Found BTRFS device: $dev"
        BTRFS_DEVICES+=("$dev")
        BTRFS_MOUNTS+=("")
      fi
    done < <(blkid -t TYPE=btrfs -o device 2>/dev/null)
  fi

  # Also check btrfs filesystem show as a secondary scan
  if command -v btrfs &>/dev/null; then
    while read -r dev; do
      [[ -n "$dev" ]] || continue
      local skip=false
      for d in "${BTRFS_DEVICES[@]}"; do
        [[ "$d" == "$dev" ]] && skip=true && break
      done
      if [[ "$skip" == false ]]; then
        log_info "Found BTRFS device (via btrfs show): $dev"
        BTRFS_DEVICES+=("$dev")
        BTRFS_MOUNTS+=("")
      fi
    done < <(btrfs filesystem show -d 2>/dev/null | awk '/dev/ {print $NF}')
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
  if command -v findmnt &>/dev/null; then
    mnt=$(findmnt -o TARGET -n "$dev" 2>/dev/null | head -n1)
  fi

  if [[ -n "$mnt" ]]; then
    log_info "BTRFS $dev already mounted at $mnt"
    was_mounted=true
  else
    # Temporarily mount to inspect
    mnt=$(mktemp -d)
    log_info "Temporarily mounting $dev at $mnt for inspection..."
    if ! mount -t btrfs "$dev" "$mnt" &>/dev/null; then
      log_warn "Failed to mount $dev — skipping BTRFS inspection for this device"
      rmdir "$mnt" 2>/dev/null || true
      return 1
    fi
    was_mounted=false
  fi

  echo "---"
  echo "=== BTRFS DEVICE: $dev ==="
  echo "Mountpoint: $mnt"
  echo "---"
  echo "=== SUBVOLUMES ==="
  if command -v btrfs &>/dev/null; then
    btrfs subvolume list "$mnt" 2>/dev/null || log_warn "Could not list subvolumes on $dev"
  else
    log_warn "btrfs tool not available"
  fi
  echo "---"
  echo "=== DF ==="
  btrfs filesystem df "$mnt" 2>/dev/null || log_warn "Could not get df for $dev"
  echo "---"
  echo "=== USAGE ==="
  btrfs filesystem usage "$mnt" 2>/dev/null || log_warn "Could not get usage for $dev"
  echo "---"
  echo "=== UUID ==="
  blkid -s UUID -o value "$dev" 2>/dev/null || log_warn "Could not get UUID for $dev"

  # Unmount if we mounted it
  if [[ "$was_mounted" == false ]]; then
    umount "$mnt" || log_warn "Failed to unmount $mnt"
    rmdir "$mnt" || true
  fi
}

{
  echo "=== BLOCK DEVICES ==="
  lsblk -f -o NAME,SIZE,FSTYPE,FSVER,MOUNTPOINT,PARTUUID,UUID
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
  findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || log_warn "findmnt not available or no mounts"
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
  if pacman -Qqn &>/dev/null; then
    pacman -Qqn | sort
  else
    echo "N/A — no local package database (running from ISO?)"
    log_warn "pacman -Qqn failed — likely on ISO or fresh install"
  fi
  echo "---"
  echo "=== ALL FOREIGN (AUR) PACKAGES ==="
  if pacman -Qqm &>/dev/null; then
    pacman -Qqm | sort
  else
    echo "N/A — no local package database"
  fi
  echo "---"
  echo "=== ORPHANS ==="
  if pacman -Qqdt &>/dev/null; then
    pacman -Qqdt | sort
  else
    echo "N/A"
    log_warn "No orphaned packages found (or pacman -Qqdt failed)"
  fi
  echo "---"
  echo "=== EXPLICIT PACKAGES ==="
  if pacman -Qqe &>/dev/null; then
    pacman -Qqe | sort
  else
    echo "N/A — no local package database"
  fi
  echo "---"
  echo "=== PACKAGE FILE INTEGRITY (non-zero altered) ==="
  local altered
  if altered=$(pacman -Qkk 2>/dev/null | grep -v "0 altered files"); then
    if [[ -n "$altered" ]]; then
      echo "$altered"
    else
      log_warn "No altered files detected"
    fi
  else
    log_warn "pacman -Qkk failed — no local package database"
  fi
} > "$OUTPUT_DIR/packages.txt"
log_ok "packages.txt written"

# ---------------------------------------------------------------------------
# Services & Units
# ---------------------------------------------------------------------------
{
  echo "=== ENABLED SERVICES ==="
  if command -v systemctl &>/dev/null; then
    systemctl list-unit-files --state=enabled --no-pager 2>/dev/null || echo "N/A — systemctl failed"
  else
    echo "N/A — systemctl not available"
  fi
  echo "---"
  echo "=== ALL UNIT FILES ==="
  if command -v systemctl &>/dev/null; then
    systemctl list-unit-files --no-pager 2>/dev/null || echo "N/A"
  else
    echo "N/A"
  fi
  echo "---"
  echo "=== TIMERS ==="
  if command -v systemctl &>/dev/null; then
    systemctl list-timers --all --no-pager 2>/dev/null || echo "N/A"
  else
    echo "N/A"
  fi
  echo "---"
  echo "=== USER UNITS ==="
  if systemctl --user list-unit-files --no-pager &>/dev/null; then
    systemctl --user list-unit-files --no-pager
  else
    echo "N/A — user systemd session not available"
  fi
  echo "---"
  echo "=== MKINITCPIO ==="
  if [[ -f /etc/mkinitcpio.conf ]]; then
    grep -E "^MODULES=|^HOOKS=|^BINARIES=|^FILES=" /etc/mkinitcpio.conf 2>/dev/null || echo "N/A — could not read mkinitcpio.conf"
  else
    echo "N/A — /etc/mkinitcpio.conf not found (running from ISO?)"
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
    [[ -f "$f" ]] && sha256sum "$f" || echo "MISSING: $f"
  done
} > "$OUTPUT_DIR/security/hashes.txt"

{
  echo "=== LISTENING SOCKETS ==="
  if command -v ss &>/dev/null; then
    ss -tulpn
  else
    log_warn "ss not available"
  fi
  echo "---"
  echo "=== ESTABLISHED CONNECTIONS ==="
  if command -v ss &>/dev/null; then
    ss -tpn state established
  else
    log_warn "ss not available"
  fi
} > "$OUTPUT_DIR/security/listeners.txt"

{
  echo "=== SETUID BINARIES ==="
  if command -v find &>/dev/null; then
    find /usr/bin /usr/lib -perm -4000 ! -type d -exec ls -la {} \; || log_warn "Some paths in setuid search were inaccessible"
  else
    log_warn "find not available"
  fi
  echo "---"
  echo "=== ORPHANED SETUID ==="
  find /usr/bin /usr/lib -perm -4000 ! -type d -print | while read -r f; do
    if ! pacman -Qo "$f" &>/dev/null; then
      echo "ORPHAN: $f"
    fi
  done
} > "$OUTPUT_DIR/security/setuid.txt"

if [[ -r /var/log/pacman.log ]]; then
  tail -n 1000 /var/log/pacman.log > "$OUTPUT_DIR/security/pacman.log.tail"
else
  log_warn "/var/log/pacman.log not readable"
fi

{
  echo "=== SUDOERS ==="
  cat /etc/sudoers
  echo "---"
  echo "=== SUDOERS.D ==="
  find /etc/sudoers.d/ -type f -exec echo "==> {}" \; -exec cat {} \;
} > "$OUTPUT_DIR/security/sudoers.txt"

log_ok "Security baseline written"

# ---------------------------------------------------------------------------
# Sway / Desktop
# ---------------------------------------------------------------------------
{
  echo "=== SWAY OUTPUTS ==="
  if command -v swaymsg &>/dev/null; then
    swaymsg -t get_outputs
  else
    log_warn "swaymsg not found (Sway not running?)"
  fi
  echo "---"
  echo "=== SWAY INPUTS ==="
  if command -v swaymsg &>/dev/null; then
    swaymsg -t get_inputs
  else
    log_warn "swaymsg not found (Sway not running?)"
  fi
  echo "---"
  echo "=== WAYLAND ENVS ==="
  local env_matches
  env_matches=$(env | grep -iE "wayland|sway|xdg|cursor")
  if [[ -n "$env_matches" ]]; then
    echo "$env_matches"
  else
    log_warn "No Wayland/Sway environment variables found"
  fi
  echo "---"
  echo "=== GPU DRIVER ==="
  if command -v glxinfo &>/dev/null; then
    glxinfo -B | grep "OpenGL renderer"
  else
    log_warn "glxinfo not found"
  fi
} > "$OUTPUT_DIR/sway.txt"
log_ok "sway.txt written"

# ---------------------------------------------------------------------------
# Dotfiles
# ---------------------------------------------------------------------------
find ~/.config -maxdepth 1 -type d | sort > "$OUTPUT_DIR/dotfiles/config-dirs.txt"
find ~ -maxdepth 1 -name ".*" -type f | sort > "$OUTPUT_DIR/dotfiles/home-dotfiles.txt"

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
