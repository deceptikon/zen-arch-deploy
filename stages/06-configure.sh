#!/bin/bash
# =============================================================================
# Stage 06: CONFIGURE
# =============================================================================
# Run this AFTER first boot into the new system, as root.
# Do NOT run this from the Arch ISO chroot (AUR builds need a running system).
#
# Prerequisites:
#   - Stage 05 (EXECUTE) complete
#   - System has booted successfully
#   - Network is up (NetworkManager should be active)
#   - You have logged in as root
#
# Usage:
#   ./stages/06-configure.sh --profile profiles/my-machine.yaml [--dry-run]
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
Usage: 06-configure.sh --profile PATH [--dry-run]

Run this ON THE INSTALLED SYSTEM after first boot.
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

# Safety check: refuse to run if this looks like the Arch ISO
if [[ -d /run/archiso ]] || [[ -f /run/archiso/bootmnt/arch/boot/x86_64/vmlinuz-linux ]]; then
  die "This appears to be the Arch ISO. Reboot into your installed system first, then run this script."
fi

log_info "╔═══════════════════════════════════════════════════════════════╗"
log_info "║          STAGE 06: CONFIGURE                                  ║"
log_info "║          POST-INSTALL CONFIGURATION                           ║"
log_info "╚═══════════════════════════════════════════════════════════════╝"

# ---------------------------------------------------------------------------
# 1. Create primary user
# ---------------------------------------------------------------------------
USERNAME="$(profile_get "software.user")"
if [[ -z "$USERNAME" ]]; then
  read -rp "Enter username for primary account: " USERNAME
fi

if ! id "$USERNAME" &>/dev/null; then
  log_info "Creating user: $USERNAME"
  run useradd -m -G wheel,audio,video,input,storage,power,docker -s /bin/zsh "$USERNAME"
  log_warn "Set password for $USERNAME:"
  run passwd "$USERNAME"
else
  log_info "User $USERNAME already exists."
fi

# Sudoers
if [[ ! -f /etc/sudoers.d/99-wheel ]]; then
  echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99-wheel
  chmod 440 /etc/sudoers.d/99-wheel
  log_ok "Wheel sudoers configured."
fi

# ---------------------------------------------------------------------------
# 2. Ensure base deps for building
# ---------------------------------------------------------------------------
run pacman -S --needed --noconfirm git base-devel

# ---------------------------------------------------------------------------
# 3. Install AUR helper (yay) as build user
# ---------------------------------------------------------------------------
BUILD_USER="aurbuilder"

if ! command -v yay &>/dev/null; then
  log_info "Installing yay (AUR helper)..."

  if ! id "$BUILD_USER" &>/dev/null; then
    run useradd -m -G wheel "$BUILD_USER"
    echo "$BUILD_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-${BUILD_USER}
  fi

  run su - "$BUILD_USER" -c "
    set -e
    cd /tmp
    [[ -d yay ]] && rm -rf yay
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
  "

  # Cleanup
  if id "$BUILD_USER" &>/dev/null; then
    run userdel -r "$BUILD_USER" || log_warn "Failed to remove build user $BUILD_USER"
  fi
  if [[ -f /etc/sudoers.d/99-${BUILD_USER} ]]; then
    run rm -f /etc/sudoers.d/99-${BUILD_USER}
  fi
  log_ok "yay installed."
else
  log_ok "yay already installed."
fi

# ---------------------------------------------------------------------------
# 4. Install AUR packages from profile
# ---------------------------------------------------------------------------
log_info "Installing AUR packages from profile..."
i=0
while true; do
  pkg_var="PROFILE_software__aur_packages__${i}"
  pkg="${!pkg_var:-}"
  [[ -n "$pkg" ]] || break
  log_info "Installing AUR package: $pkg"
  run su - "$USERNAME" -c "yay -S --needed --noconfirm $pkg"
  ((i++))
done

# ---------------------------------------------------------------------------
# 5. Enable services from profile
# ---------------------------------------------------------------------------
log_info "Enabling services..."
i=0
while true; do
  svc_var="PROFILE_software__services__system__${i}"
  svc="${!svc_var:-}"
  [[ -n "$svc" ]] || break
  log_info "Enabling service: $svc"
  run systemctl enable "$svc"
  ((i++))
done

# ---------------------------------------------------------------------------
# 6. Deploy dotfiles (chezmoi)
# ---------------------------------------------------------------------------
DOTFILES_REPO="$(profile_get "dotfiles.repo")"
DOTFILES_MANAGER="$(profile_get "dotfiles.manager")"

if [[ -n "$DOTFILES_REPO" ]]; then
  log_info "Deploying dotfiles with $DOTFILES_MANAGER..."

  if [[ "$DOTFILES_MANAGER" == "chezmoi" ]]; then
    if ! command -v chezmoi &>/dev/null; then
      run pacman -S --needed --noconfirm chezmoi
    fi

    run su - "$USERNAME" -c "
      set -e
      chezmoi init --apply '$DOTFILES_REPO'
    "
    log_ok "Dotfiles deployed via chezmoi."
  else
    log_warn "Unsupported dotfiles manager: $DOTFILES_MANAGER. Skipping."
  fi
else
  log_warn "No dotfiles.repo configured in profile. Skipping dotfile deployment."
  log_warn "Edit your profile and set dotfiles.repo before re-running."
fi

# ---------------------------------------------------------------------------
# 7. Timeshift setup
# ---------------------------------------------------------------------------
if command -v timeshift &>/dev/null; then
  log_info "Setting up timeshift..."
  # Ensure snapshot directory exists
  run mkdir -p /.snapshots
  # Create initial snapshot
  if command -v timeshift &>/dev/null; then
    run timeshift --create --comments "post-install baseline" || log_warn "timeshift snapshot creation failed (may need initial config)"
  fi
  log_ok "Timeshift baseline snapshot created."
fi

# ---------------------------------------------------------------------------
# 8. Sway / Wayland session tweaks
# ---------------------------------------------------------------------------
log_info "Applying desktop tweaks..."

# SDDM wayland session config
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-wayland.conf <<'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_QPA_PLATFORM=wayland

[Wayland]
CompositorCommand=sway
EOF
log_ok "SDDM configured for Wayland."

# Ensure user runtime dir
run mkdir -p "/run/user/$(id -u "$USERNAME")"
  local user_runtime_dir="/run/user/$(id -u "$USERNAME")"
  if [[ -d "$user_runtime_dir" ]]; then
    run chown "$USERNAME:$USERNAME" "$user_runtime_dir" || log_warn "Failed to chown $user_runtime_dir"
  else
    log_warn "User runtime dir $user_runtime_dir does not exist"
  fi

# ---------------------------------------------------------------------------
# 9. Final pacman hooks for timeshift snapshots on upgrade
# ---------------------------------------------------------------------------
if command -v timeshift-autosnap &>/dev/null; then
  log_info "timeshift-autosnap is installed. It will create snapshots before upgrades."
fi

log_ok "Stage 06 CONFIGURE complete."
log_info "Next steps:"
log_info "  1. Reboot if needed"
log_info "  2. Log in as $USERNAME via SDDM"
log_info "  3. Run stage 07 (VERIFY) to seal the system"
