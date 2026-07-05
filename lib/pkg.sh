#!/bin/bash
# =============================================================================
# lib/pkg.sh — Package management helpers
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Install packages from profile lists
# ---------------------------------------------------------------------------
install_base_packages() {
  local mnt="${1:-/mnt}"
  local pkglist="$mnt/tmp/base-packages.txt"

  log_info "Collecting base packages from profile..."

  local i=0
  while true; do
    local pkg_var="PROFILE_software__base_packages__${i}"
    local pkg="${!pkg_var:-}"
    [[ -n "$pkg" ]] || break
    echo "$pkg" >> "$pkglist"
    ((i++))
  done

  [[ -s "$pkglist" ]] || { log_warn "No base packages listed in profile."; return 0; }

  run pacman -S --needed --noconfirm - < "$pkglist"
}

# ---------------------------------------------------------------------------
# Install AUR helper (yay) then AUR packages
# ---------------------------------------------------------------------------
install_aur_packages() {
  local mnt="${1:-/mnt}"
  local build_user="${2:-builder}"

  # Install yay first
  log_info "Installing yay (AUR helper)..."
  run pacman -S --needed --noconfirm git base-devel

  # Create a temporary build user if not exists
  if ! id "$build_user" &>/dev/null; then
    run useradd -m -G wheel "$build_user"
    echo "$build_user ALL=(ALL) NOPASSWD: ALL" > "$mnt/etc/sudoers.d/99-${build_user}"
  fi

  local build_dir="/home/$build_user/yay-build"
  run mkdir -p "$mnt$build_dir"
  run chown "$build_user:$build_user" "$mnt$build_dir"

  # Clone and build yay in chroot
  run arch-chroot "$mnt" su - "$build_user" -c "
    set -e
    cd ~
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
  "

  # Install AUR packages from profile
  local i=0
  while true; do
    local pkg_var="PROFILE_software__aur_packages__${i}"
    local pkg="${!pkg_var:-}"
    [[ -n "$pkg" ]] || break
    log_info "Installing AUR package: $pkg"
    run arch-chroot "$mnt" su - "$build_user" -c "yay -S --needed --noconfirm $pkg"
    ((i++))
  done

  # Cleanup build user
  run userdel -r "$build_user"
  run rm -f "$mnt/etc/sudoers.d/99-${build_user}"
}

# ---------------------------------------------------------------------------
# Enable services listed in profile
# ---------------------------------------------------------------------------
enable_services() {
  local mnt="${1:-/mnt}"

  local i=0
  while true; do
    local svc_var="PROFILE_software__services__system__${i}"
    local svc="${!svc_var:-}"
    [[ -n "$svc" ]] || break
    log_info "Enabling service: $svc"
    run arch-chroot "$mnt" systemctl enable "$svc"
    ((i++))
  done
}
