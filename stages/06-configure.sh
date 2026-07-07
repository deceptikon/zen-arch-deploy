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
# Ensure ARCH_DEPLOY_ROOT is set even when this stage runs standalone (not via arch-deploy.sh)
ARCH_DEPLOY_ROOT="${ARCH_DEPLOY_ROOT:-$SCRIPT_DIR}"
export ARCH_DEPLOY_ROOT
PROFILE=""

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
[[ -z "${PROFILE:-}" && -n "${ARCH_DEPLOY_PROFILE:-}" ]] && PROFILE="$ARCH_DEPLOY_PROFILE"

[[ -n "${PROFILE:-}" ]] || die "--profile is required"
profile_load "$PROFILE"
profile_validate

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
  if [[ -t 0 ]]; then
    read -rp "Enter username for primary account: " USERNAME
  fi
  [[ -n "$USERNAME" ]] || die "Profile key 'software.user' is not set and no username was provided interactively. Add 'user: <name>' under the 'software:' section in your profile YAML."
fi

if id "$USERNAME" &>/dev/null; then
    log_info "User $USERNAME already exists."
  else
    log_info "Creating user: $USERNAME"
    run useradd -m -G wheel,audio,video,input,storage,power,docker -s /bin/zsh "$USERNAME"
    log_warn "Set password for $USERNAME:"
    echo "${USERNAME}:${USERNAME}" | run chpasswd
  fi

# Sudoers for wheel group
if [[ ! -f /etc/sudoers.d/99-wheel ]]; then
  echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99-wheel
  chmod 440 /etc/sudoers.d/99-wheel
  log_ok "Wheel sudoers configured."
fi

# User-specific sudoers: !requiretty + NOPASSWD (zzz prefix overrides wheel group entry)
echo "Defaults:${USERNAME} !requiretty" > /etc/sudoers.d/99-zzz-${USERNAME}
echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/99-zzz-${USERNAME}
log_ok "User sudoers configured (!requiretty + NOPASSWD)."

# ---------------------------------------------------------------------------
# 2. Ensure base deps for building
# ---------------------------------------------------------------------------
run pacman -S --needed --noconfirm --overwrite '*' git base-devel

# ---------------------------------------------------------------------------
# 3. Install AUR helper (yay) as build user
# ---------------------------------------------------------------------------
BUILD_USER="aurbuilder"

  yay_path=$(command -v yay || true)
  if [[ -z "$yay_path" ]]; then
  log_info "Installing yay (AUR helper)..."

  if id "$BUILD_USER"; then
    log_info "Build user $BUILD_USER already exists"
  else
    run useradd -m -G wheel "$BUILD_USER"
  fi
  # Ensure sudoers config (rewrite even if exists)
  # Use zzz prefix so this sorts after 99-wheel to avoid group override
  echo "Defaults:${BUILD_USER} !requiretty" > /etc/sudoers.d/99-zzz-${BUILD_USER}
  echo "${BUILD_USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/99-zzz-${BUILD_USER}

  run su - "$BUILD_USER" -c "
    set -e
    cd /tmp
    [[ -d yay ]] && rm -rf yay
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
  "

  # Cleanup
  if id "$BUILD_USER"; then
    if ! run userdel -r "$BUILD_USER"; then
      log_warn "Failed to remove build user $BUILD_USER"
    fi
  fi
  if [[ -f /etc/sudoers.d/99-zzz-${BUILD_USER} ]]; then
    run rm -f /etc/sudoers.d/99-zzz-${BUILD_USER}
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
  run su - "$USERNAME" -c "yay -S --needed --noconfirm --overwrite '*' $pkg"
   i=$((i+1))
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
   i=$((i+1))
done

# ---------------------------------------------------------------------------
# 6. Deploy dotfiles (chezmoi)
# ---------------------------------------------------------------------------
DOTFILES_REPO="$(profile_get "dotfiles.repo")"
DOTFILES_MANAGER="$(profile_get "dotfiles.manager")"
# Default manager to chezmoi if not explicitly set in profile
[[ -n "$DOTFILES_MANAGER" ]] || DOTFILES_MANAGER="chezmoi"

BUNDLED_DOTFILES_DIR="$ARCH_DEPLOY_ROOT/dotfiles"

if [[ -z "$DOTFILES_REPO" ]]; then
  if [[ -d "$BUNDLED_DOTFILES_DIR" ]]; then
    # Check the submodule is actually populated — a bare `git clone` without
    # --recurse-submodules leaves dotfiles/ as an empty directory.
    if [[ ! -f "$BUNDLED_DOTFILES_DIR/.chezmoi.toml.tmpl" ]]; then
      log_warn "  dotfiles/ dir exists but appears empty (submodule not initialized)."
      log_info "  Running: git submodule update --init -- dotfiles"
      run git -C "$ARCH_DEPLOY_ROOT" submodule update --init -- dotfiles
    fi
    log_info "No external dotfiles.repo configured in profile."
    log_info "  → Falling back to BUNDLED dotfiles: $BUNDLED_DOTFILES_DIR"
    DOTFILES_REPO="bundled"
  else
    log_warn "No external dotfiles.repo configured AND no bundled dotfiles found at $BUNDLED_DOTFILES_DIR."
    log_warn "  → Dotfiles installation SKIPPED."
    log_warn "  → To fix: either set 'dotfiles.repo: <url>' in your profile, or ensure the dotfiles/ directory exists in the deploy repo."
  fi
fi

if [[ -n "$DOTFILES_REPO" ]]; then
  log_info "Deploying dotfiles with $DOTFILES_MANAGER..."

  if [[ "$DOTFILES_MANAGER" == "chezmoi" ]]; then
    chezmoi_path=$(command -v chezmoi || true)
    if [[ -z "$chezmoi_path" ]]; then
      log_info "chezmoi not found — installing via pacman..."
      run pacman -S --needed --noconfirm --overwrite '*' chezmoi
    fi

    if [[ "$DOTFILES_REPO" == "bundled" ]]; then
      # IMPORTANT: we must use `chezmoi init --apply --source` (NOT `chezmoi apply`)
      # because `chezmoi apply` skips processing `.chezmoi.toml.tmpl` — the config
      # template (which contains waybar_output, scale_factor, etc.) is ONLY processed
      # during `chezmoi init`. Running `apply` on a fresh system leaves all .tmpl
      # files rendered with empty template data, producing broken or empty configs.
      #
      # Also: make source world-readable so the new user (running via su) can access
      # it. Files like zsh/history may be 600 (owner-only) and silently block chezmoi.
      log_info "  Making bundled source readable by new user..."
      run chmod -R o+rX "$BUNDLED_DOTFILES_DIR"
      #
      # Also: the bundled dotfiles dir lives inside a git repo owned by a different
      # user (or root). Git's "dubious ownership" check blocks all git operations,
      # which causes chezmoi to silently exit 0 and deploy nothing. Register both
      # the dotfiles dir and its parent as safe directories for the target user.
      log_info "  Registering safe.directory for git (dubious ownership guard)..."
      run su - "$USERNAME" -c "
        git config --global --add safe.directory '$BUNDLED_DOTFILES_DIR'
        git config --global --add safe.directory '$(dirname "$BUNDLED_DOTFILES_DIR")'
      "
      log_info "  Running: chezmoi init --apply --source $BUNDLED_DOTFILES_DIR"
      run su - "$USERNAME" -c "
        set -e
        chezmoi init --apply --force --source '$BUNDLED_DOTFILES_DIR'
      "
    else
      log_info "Initialising chezmoi from remote repo: $DOTFILES_REPO ..."
      run su - "$USERNAME" -c "
        set -e
        chezmoi init --apply --force '$DOTFILES_REPO'
      "
    fi

    # Sanity check: chezmoi has a known quirk where it exits 0 even on internal
    # errors (e.g. git/permission failures). Verify deployment actually happened.
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
      if [[ ! -f "/home/$USERNAME/.config/chezmoi/chezmoi.toml" ]]; then
        die "Dotfiles deployment FAILED: ~/.config/chezmoi/chezmoi.toml not found after chezmoi init. Check stderr output above for the real error (chezmoi exits 0 even on failure)."
      fi
      log_ok "Dotfiles deployed via chezmoi (config file verified)."
    else
      log_ok "Dotfiles deployed via chezmoi."
    fi
  else
    log_warn "Unsupported dotfiles manager: '$DOTFILES_MANAGER'. Only 'chezmoi' is currently supported. Skipping dotfiles."
  fi
fi

# ---------------------------------------------------------------------------
# 7. Timeshift setup
# ---------------------------------------------------------------------------
if command -v timeshift; then
  log_info "Setting up timeshift..."
  # Ensure snapshot directory exists
  run mkdir -p /.snapshots
  # Create initial snapshot
  if ! run timeshift --create --comments "post-install baseline"; then
    log_warn "timeshift snapshot creation failed (may need initial config)"
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
  user_runtime_dir="/run/user/$(id -u "$USERNAME")"
  if [[ -d "$user_runtime_dir" ]]; then
    run chown "$USERNAME:$USERNAME" "$user_runtime_dir" || log_warn "Failed to chown $user_runtime_dir"
  else
    log_warn "User runtime dir $user_runtime_dir does not exist"
  fi

# ---------------------------------------------------------------------------
# 9. Final pacman hooks for timeshift snapshots on upgrade
# ---------------------------------------------------------------------------
tsnap_path=$(command -v timeshift-autosnap || true)
  if [[ -n "$tsnap_path" ]]; then
  log_info "timeshift-autosnap is installed. It will create snapshots before upgrades."
fi

log_ok "Stage 06 CONFIGURE complete."
log_info "Next steps:"
log_info "  1. Reboot if needed"
log_info "  2. Log in as $USERNAME via SDDM"
log_info "  3. Run stage 07 (VERIFY) to seal the system"
