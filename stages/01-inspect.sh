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
{
  echo "=== BTRFS SUBVOLUMES ==="
  if command -v btrfs &>/dev/null && findmnt -o FSTYPE / | grep -q btrfs; then
    btrfs subvolume list /
  else
    log_warn "Root is not BTRFS — skipping subvolume list"
  fi
  echo "---"
  echo "=== BTRFS DF ==="
  btrfs filesystem df /
  echo "---"
  echo "=== BTRFS USAGE ==="
  btrfs filesystem usage /
  echo "---"
  echo "=== FINDMNT ==="
  findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS
  echo "---"
  echo "=== FSTAB ==="
  cat /etc/fstab
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
  pacman -Qqn | sort
  echo "---"
  echo "=== ALL FOREIGN (AUR) PACKAGES ==="
  pacman -Qqm | sort
  echo "---"
  echo "=== ORPHANS ==="
  if pacman -Qqdt &>/dev/null; then
    pacman -Qqdt | sort
  else
    log_warn "No orphaned packages found"
  fi
  echo "---"
  echo "=== EXPLICIT PACKAGES ==="
  pacman -Qqe | sort
  echo "---"
  echo "=== PACKAGE FILE INTEGRITY (non-zero altered) ==="
  local altered
  altered=$(pacman -Qkk | grep -v "0 altered files")
  if [[ -n "$altered" ]]; then
    echo "$altered"
  else
    log_warn "No altered files detected (or pacman -Qkk failed)"
  fi
} > "$OUTPUT_DIR/packages.txt"
log_ok "packages.txt written"

# ---------------------------------------------------------------------------
# Services & Units
# ---------------------------------------------------------------------------
{
  echo "=== ENABLED SERVICES ==="
  systemctl list-unit-files --state=enabled --no-pager
  echo "---"
  echo "=== ALL UNIT FILES ==="
  systemctl list-unit-files --no-pager
  echo "---"
  echo "=== TIMERS ==="
  systemctl list-timers --all --no-pager
  echo "---"
  echo "=== USER UNITS ==="
  if systemctl --user list-unit-files --no-pager &>/dev/null; then
    systemctl --user list-unit-files --no-pager
  else
    log_warn "User systemd session not available"
  fi
  echo "---"
  echo "=== MKINITCPIO ==="
  grep -E "^MODULES=|^HOOKS=|^BINARIES=|^FILES=" /etc/mkinitcpio.conf
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
