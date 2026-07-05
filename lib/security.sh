#!/bin/bash
# =============================================================================
# lib/security.sh — Security audit helpers
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Mount target disk read-only for inspection
# ---------------------------------------------------------------------------
mount_target_ro() {
  local dev="$1"
  local mnt="${2:-/mnt/target}"
  run mkdir -p "$mnt"
  run mount -o ro,subvol=@ "$dev" "$mnt"
  log_ok "Mounted $dev (subvol @) read-only at $mnt"
}

# ---------------------------------------------------------------------------
# Verify critical binary hashes against profile baseline
# ---------------------------------------------------------------------------
verify_hashes() {
  local mnt="${1:-/mnt/target}"
  local failed=0

  log_info "Checking critical binary hashes..."

  local i=0
  while true; do
    local path_var="PROFILE_security__known_hashes__${i}__path"
    local path="${!path_var:-}"
    [[ -n "$path" ]] || break

    local expected_var="PROFILE_security__known_hashes__${i}__sha256"
    local expected="${!expected_var:-}"

    local fullpath="$mnt$path"
    if [[ ! -f "$fullpath" ]]; then
      log_warn "File missing: $fullpath"
      ((failed++))
      ((i++))
      continue
    fi

    local actual
    actual=$(sha256sum "$fullpath" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
      log_err "HASH MISMATCH: $path"
      log_err "  Expected: $expected"
      log_err "  Actual:   $actual"
      ((failed++))
    else
      log_ok "Hash OK: $path"
    fi

    ((i++))
  done

  return $failed
}

# ---------------------------------------------------------------------------
# Audit pacman hooks
# ---------------------------------------------------------------------------
audit_hooks() {
  local mnt="${1:-/mnt/target}"
  local hooks_dir="$mnt/etc/pacman.d/hooks"

  log_info "Auditing pacman hooks..."
  if [[ ! -d "$hooks_dir" ]]; then
    log_warn "No hooks directory found."
    return 0
  fi

  find "$hooks_dir" -type f | while read -r f; do
    log_info "Hook: $f"
  done
}

# ---------------------------------------------------------------------------
# Find setuid binaries not owned by packages
# ---------------------------------------------------------------------------
audit_setuid() {
  local mnt="${1:-/mnt/target}"
  log_info "Scanning for orphaned setuid binaries..."

  local orphans
  orphans=$(find "$mnt/usr/bin" "$mnt/usr/lib" -perm -4000 ! -type d | while read -r f; do
local rel="${f#$mnt}"
      local owner_info
      if owner_info=$(pacman -Qo "$rel"); then
        : # owned by a package, skip
      else
        echo "$rel"
      fi
  done)

  if [[ -n "$orphans" ]]; then
    log_err "Orphaned setuid binaries found:"
    echo "$orphans"
    return 1
  else
    log_ok "No orphaned setuid binaries found."
    return 0
  fi
}

# ---------------------------------------------------------------------------
# Check for pacnew / pacsave drift
# ---------------------------------------------------------------------------
audit_pacnew() {
  local mnt="${1:-/mnt/target}"
  log_info "Checking for .pacnew / .pacsave files..."

  local files
  files=$(find "$mnt/etc" -type f \( -name "*.pacnew" -o -name "*.pacsave" \))

  if [[ -n "$files" ]]; then
    log_warn "Drift files found:"
    echo "$files"
  else
    log_ok "No drift files."
  fi
}
