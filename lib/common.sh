#!/bin/bash
# =============================================================================
# lib/common.sh — Shared utilities for arch-deploy
# =============================================================================

set -euo pipefail

# Colors
if [[ -t 2 ]]; then
  C_RED='\033[0;31m'
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[1;33m'
  C_BLUE='\033[0;34m'
  C_CYAN='\033[0;36m'
  C_RESET='\033[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_RESET=''
fi

# ---------------------------------------------------------------------------
# File logging setup
# ---------------------------------------------------------------------------
LOG_DIR="${ARCH_DEPLOY_LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

# Each invocation gets its own log file
LOG_FILE="$LOG_DIR/arch-deploy-$(date +%Y%m%d_%H%M%S).log"

# Initialize log file with header
{
  echo "================================"
  echo "arch-deploy log started: $(date -Iseconds)"
  echo "PWD: $(pwd)"
  echo "USER: $(whoami 2>/dev/null || echo unknown)"
  echo "================================"
} > "$LOG_FILE"

# ---------------------------------------------------------------------------
# Logging — tee everything to both stderr and log file
# ---------------------------------------------------------------------------
_log_write() {
  local level="$1"
  shift
  local msg="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

log()       { _log_write "DEPLOY" "$@"; echo -e "${C_CYAN}[arch-deploy]${C_RESET} $*" >&2; }
log_info()  { _log_write "INFO" "$@"; echo -e "${C_BLUE}[INFO]${C_RESET} $*" >&2; }
log_ok()    { _log_write "OK" "$@"; echo -e "${C_GREEN}[OK]${C_RESET} $*" >&2; }
log_warn()  { _log_write "WARN" "$@"; echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_err()   { _log_write "ERR" "$@"; echo -e "${C_RED}[ERR]${C_RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# Fatal error
# ---------------------------------------------------------------------------
die() {
  log_err "$*"
  _log_write "FATAL" "$*"
  echo ""
  echo "Log file: $LOG_FILE"
  echo ""
  exit 1
}

# ---------------------------------------------------------------------------
# Usage banner (stages should override if they want)
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
arch-deploy — ASUS Zenbook 14 Reinstall Pipeline

Usage:
  ./arch-deploy.sh [global-opts] <stage> [stage-opts]

Global Options:
  --profile PATH   Path to profile YAML (required for most stages)
  --dry-run        Show what would be done; do not modify anything
  --help           Show this help

Stages:
  inspect          Deep system scan on current host
  generate-profile Build machine profile from inspect data
  validate         RO security audit from USB
  prepare          ISO env setup (network, mounts)
  execute          Base installation (subvol-reset, pacstrap, GRUB)
  configure        Post-install (AUR, dotfiles, services)
  verify           Seal and verify new system

Examples:
  ./arch-deploy.sh inspect
  ./arch-deploy.sh --profile profiles/my-machine.yaml prepare --dry-run
  ./arch-deploy.sh --profile profiles/my-machine.yaml execute
EOF
}

# ---------------------------------------------------------------------------
# Dry-run guard
# ---------------------------------------------------------------------------
DRY_RUN="${ARCH_DEPLOY_DRY_RUN:-false}"

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} $*"
  else
    log_info "EXEC: $*"
    "$@"
  fi
}

run_shell() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${C_YELLOW}[DRY-RUN]${C_RESET} $1"
  else
    log_info "EXEC: $1"
    bash -c "$1"
  fi
}

# ---------------------------------------------------------------------------
# Confirmations
# ---------------------------------------------------------------------------
confirm() {
  local msg="${1:-Continue?}"
  local ans
  read -rp "$msg [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted by user."
}

confirm_critical() {
  local msg="${1:-This is a DESTRUCTIVE operation.}"
  echo -e "${C_RED}═══════════════════════════════════════════════════════════════${C_RESET}"
  echo -e "${C_RED}  $msg${C_RESET}"
  echo -e "${C_RED}═══════════════════════════════════════════════════════════════${C_RESET}"
  local ans
  read -rp "Type 'yes' to proceed: " ans
  [[ "$ans" == "yes" ]] || die "Aborted by user."
}

# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------
require_root() {
  [[ $EUID -eq 0 ]] || die "This stage must be run as root."
}

require_command() {
  command -v "$1" &>/dev/null || die "Required command not found: $1"
}

# ---------------------------------------------------------------------------
# Profile loader
# ---------------------------------------------------------------------------
PROFILE="${ARCH_DEPLOY_PROFILE:-}"
PROFILE_DIR=""
PROFILE_NAME=""

load_profile() {
  if [[ -z "$PROFILE" ]]; then
    # Allow stages to set it themselves
    return 0
  fi

  [[ -f "$PROFILE" ]] || die "Profile not found: $PROFILE"

  PROFILE_DIR=$(cd "$(dirname "$PROFILE")" && pwd)
  PROFILE_NAME=$(basename "$PROFILE" .yaml)

  # If a companion .env exists, source it for fast access
  local envfile="$PROFILE_DIR/${PROFILE_NAME}.env"
  if [[ -f "$envfile" ]]; then
    # shellcheck source=/dev/null
    source "$envfile"
  fi
}

# ---------------------------------------------------------------------------
# Profile accessors (flat env vars generated by 02-generate-profile)
# ---------------------------------------------------------------------------
profile_get() {
  local key="$1"
  local var="PROFILE_${key//./__}"
  var="${var//-/_}"
  printf '%s' "${!var:-}"
}

profile_get_or_die() {
  local val
  val=$(profile_get "$1")
  [[ -n "$val" ]] || die "Profile key missing: $1"
  printf '%s' "$val"
}
