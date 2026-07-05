#!/bin/bash
# =============================================================================
# Stage 05: EXECUTE
# =============================================================================
# Run this in the Arch ISO live environment AFTER prepare.
# Performs subvol-reset, pacstrap, fstab, GRUB install, mkinitcpio.
#
# Usage:
#   ./stages/05-execute.sh --profile profiles/my-machine.yaml [--dry-run]
#
# SAFETY:
#   - --dry-run shows every command without executing
#   - Without --dry-run, asks for 'yes' confirmation before destructive ops
# =============================================================================

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/profile.sh"
source "$SCRIPT_DIR/lib/disk.sh"
source "$SCRIPT_DIR/lib/btrfs.sh"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      cat <<'EOF'
Usage: 05-execute.sh --profile PATH [--dry-run]
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
log_info "║          STAGE 05: EXECUTE                                    ║"
log_info "║          BASE INSTALLATION                                    ║"
log_info "╚═══════════════════════════════════════════════════════════════╝"

# ---------------------------------------------------------------------------
# Resolve devices
# ---------------------------------------------------------------------------
DISK=$(profile_get_or_die "storage.disk")
EFI_DEV=$(profile_get_or_die "storage.partitions.efi.device")
ROOT_DEV=$(profile_get_or_die "storage.partitions.root_pool.device")
HOSTNAME=$(profile_get_or_die "machine.hostname")
KERNEL_PKG=$(profile_get_or_die "kernel.pkg")

# ---------------------------------------------------------------------------
# Determine wipe strategy
# ---------------------------------------------------------------------------
WIPE_STRATEGY=$(profile_get_or_die "storage.wipe_strategy")
log_info "Wipe strategy: $WIPE_STRATEGY"

# ---------------------------------------------------------------------------
# Dry-run preview
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "=== DRY-RUN PREVIEW ==="
  echo "Disk:       $DISK"
  echo "EFI:        $EFI_DEV"
  echo "Root pool:  $ROOT_DEV"
  echo "Hostname:   $HOSTNAME"
  echo "Kernel:     $KERNEL_PKG"
  echo "Strategy:   $WIPE_STRATEGY"
  echo ""
  if [[ "$WIPE_STRATEGY" == "format-full" ]]; then
    echo "Steps that would execute:"
    echo "  1. mkfs.vfat $EFI_DEV"
    echo "  2. mkfs.btrfs $ROOT_DEV"
    echo "  3. create subvolumes (@, @home, @swap, @snapshots)"
    echo "  4. mount subvolumes -> /mnt"
    echo "  5. pacstrap base system"
    echo "  6. generate fstab"
    echo "  7. arch-chroot: timezone, locale, hostname"
    echo "  8. mkinitcpio"
    echo "  9. grub-install + grub-mkconfig"
  else
    echo "Steps that would execute:"
    echo "  1. mount $ROOT_DEV -> /mnt (top-level)"
    echo "  2. btrfs subvolume delete @ (or rename to @.bak-*)"
    echo "  3. btrfs subvolume create @"
    echo "  4. mount @ -> /mnt"
    echo "  5. mount @home -> /mnt/home"
    echo "  6. mount @swap -> /mnt/.swap"
    echo "  7. mount $EFI_DEV -> /mnt/efi"
    echo "  8. pacstrap base system"
    echo "  9. generate fstab"
    echo " 10. arch-chroot: timezone, locale, hostname"
    echo " 11. mkinitcpio"
    echo " 12. grub-install + grub-mkconfig"
  fi
  echo ""
  log_ok "Dry-run preview complete."
  exit 0
fi

# ---------------------------------------------------------------------------
# Confirm destructive operation
# ---------------------------------------------------------------------------
if [[ "$WIPE_STRATEGY" == "format-full" ]]; then
  confirm_critical "This will FORMAT $ROOT_DEV as BTRFS and $EFI_DEV as FAT32, then install Arch. Are you sure?"
else
  confirm_critical "This will RESET the @ subvolume on $ROOT_DEV and install Arch. Are you sure?"
fi

# ---------------------------------------------------------------------------
# 1. Wipe / format per strategy
# ---------------------------------------------------------------------------
if [[ "$WIPE_STRATEGY" == "format-full" ]]; then
  log_info "Performing full format (new BTRFS pool + subvolumes)..."

  # Format EFI partition
  log_info "Formatting EFI partition $EFI_DEV..."
  run mkfs.vfat -F32 -n "EFI" "$EFI_DEV"
  log_ok "EFI partition formatted."

  # Format root pool as BTRFS
  log_info "Formatting root pool $ROOT_DEV as BTRFS..."
  run mkfs.btrfs -f -L "ArchPool" "$ROOT_DEV"
  log_ok "Root pool formatted as BTRFS."

  # Create subvolumes
  log_info "Creating subvolumes..."
  create_subvols "$ROOT_DEV"
  log_ok "Subvolumes created."

elif [[ "$WIPE_STRATEGY" == "subvol-reset" ]]; then
  log_info "Performing subvolume reset on $ROOT_DEV..."
  wipe_subvol_reset "$ROOT_DEV" true
else
  die "Unknown wipe strategy: $WIPE_STRATEGY (expected 'format-full' or 'subvol-reset')"
fi

# ---------------------------------------------------------------------------
# 2. Mount fresh subvolumes
# ---------------------------------------------------------------------------
log_info "Mounting subvolumes..."
mount_subvols

# ---------------------------------------------------------------------------
# 3. Pacstrap base system
# ---------------------------------------------------------------------------
log_info "Installing base system via pacstrap..."

# Build package list from profile
BASE_PKGS=(base base-devel "$KERNEL_PKG" "${KERNEL_PKG}-headers" amd-ucode grub efibootmgr os-prober grub-btrfs inotify-tools mkinitcpio btrfs-progs)

# Add profile packages
i=0
while true; do
  pkg_var="PROFILE_software__base_packages__${i}"
  pkg="${!pkg_var:-}"
  [[ -n "$pkg" ]] || break
  BASE_PKGS+=("$pkg")
  ((i++))
done

# Deduplicate
declare -A SEEN
UNIQUE_PKGS=()
for p in "${BASE_PKGS[@]}"; do
  [[ -n "${SEEN[$p]:-}" ]] && continue
  SEEN[$p]=1
  UNIQUE_PKGS+=("$p")
done

run pacstrap -K /mnt "${UNIQUE_PKGS[@]}"
log_ok "Pacstrap complete."

# ---------------------------------------------------------------------------
# 4. Generate fstab
# ---------------------------------------------------------------------------
generate_fstab /mnt

# ---------------------------------------------------------------------------
# 5. Basic system configuration inside chroot
# ---------------------------------------------------------------------------
log_info "Configuring base system in chroot..."

# Timezone
run arch-chroot /mnt ln -sf /usr/share/zoneinfo/UTC /etc/localtime
run arch-chroot /mnt hwclock --systohc

# Locale
if [[ -f /mnt/etc/locale.gen ]]; then
  if ! grep -q "^en_US.UTF-8 UTF-8" /mnt/etc/locale.gen; then
    echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
  fi
else
  echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
fi
run arch-chroot /mnt locale-gen

# Hostname
echo "$HOSTNAME" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# ---------------------------------------------------------------------------
# 6. mkinitcpio
# ---------------------------------------------------------------------------
log_info "Configuring mkinitcpio..."

# Read hooks from profile and replace HOOKS line
HOOKS_LINE="HOOKS=("
h=0
while true; do
  hook_var="PROFILE_kernel__hooks__${h}"
  hook="${!hook_var:-}"
  [[ -n "$hook" ]] || break
  HOOKS_LINE+="$hook "
  ((h++))
done
HOOKS_LINE+=")"

# Backup original
run cp /mnt/etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf.bak

# Replace HOOKS line
sed -i "s/^HOOKS=.*/${HOOKS_LINE}/" /mnt/etc/mkinitcpio.conf

run arch-chroot /mnt mkinitcpio -P
log_ok "mkinitcpio complete."

# ---------------------------------------------------------------------------
# 7. GRUB
# ---------------------------------------------------------------------------
log_info "Installing bootloader (GRUB)..."

run arch-chroot /mnt grub-install \
  --target=x86_64-efi \
  --efi-directory=/efi \
  --bootloader-id=ARCHLINUX \
  --recheck

# Enable os-prober for Windows dual-boot
if [[ -f /mnt/etc/default/grub ]]; then
  if [[ -f /mnt/etc/default/grub ]]; then
    if ! sed -i 's/^#*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /mnt/etc/default/grub; then
      log_warn "Failed to update GRUB_DISABLE_OS_PROBER in /mnt/etc/default/grub"
    fi
  else
    log_warn "/mnt/etc/default/grub not found — cannot enable os-prober"
  fi
fi

run arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
log_ok "GRUB installed."

# ---------------------------------------------------------------------------
# 8. Root password
# ---------------------------------------------------------------------------
log_warn "Please set a root password for the new system."
run arch-chroot /mnt passwd

log_ok "Stage 05 EXECUTE complete."
log_info "You may now reboot, or proceed to CONFIGURE stage after first boot."
