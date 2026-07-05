#!/bin/bash
# =============================================================================
# Stage 03: VALIDATE
# =============================================================================
# Run this from a CLEAN USB / Arch ISO before any install.
# Performs read-only security audit against the profile baseline.
#
# Usage:
#   ./stages/03-validate.sh --profile profiles/my-machine.yaml [--mount /mnt/target]
#
# Checks:
#   - Critical binary SHA256 hashes
#   - Orphaned setuid binaries
#   - Pacman hooks integrity
#   - Pacnew/pacsave drift
#   - Recent pacman log anomalies
# =============================================================================

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/profile.sh"
source "$SCRIPT_DIR/lib/security.sh"

MOUNT_POINT="/mnt/target"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --mount) MOUNT_POINT="$2"; shift 2 ;;
    --help|-h)
      cat <<'EOF'
Usage: 03-validate.sh --profile PATH [--mount /mnt/target]
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

_dev=$(profile_get_or_die "storage.partitions.root_pool.device")

log_info "╔═══════════════════════════════════════════════════════════════╗"
log_info "║          SECURITY VALIDATION (READ-ONLY)                      ║"
log_info "╚═══════════════════════════════════════════════════════════════╝"

# ---------------------------------------------------------------------------
# Mount target RO
# ---------------------------------------------------------------------------
if mountpoint -q "$MOUNT_POINT"; then
  log_warn "$MOUNT_POINT is already mounted. Ensure it is read-only."
else
  mount_target_ro "$_dev" "$MOUNT_POINT"
fi

# Verify it is actually RO
if grep -q " $MOUNT_POINT " /proc/mounts | grep -q "\bro\b"; then
  log_ok "Confirmed: $MOUNT_POINT is mounted read-only"
else
  log_warn "Could not confirm read-only mount. Continuing carefully."
fi

# ---------------------------------------------------------------------------
# Run audits
# ---------------------------------------------------------------------------
FAILED=0

verify_hashes "$MOUNT_POINT" || FAILED=$((FAILED + $?))
audit_setuid "$MOUNT_POINT" || FAILED=$((FAILED + $?))
audit_hooks "$MOUNT_POINT"
audit_pacnew "$MOUNT_POINT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_info "═══════════════════════════════════════════════════════════════"
if [[ $FAILED -eq 0 ]]; then
  log_ok  "VALIDATION PASSED — No anomalies detected."
else
  log_err "VALIDATION FAILED — $FAILED checks failed. Review output above."
fi
log_info "═══════════════════════════════════════════════════════════════"

exit $FAILED
