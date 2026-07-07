#!/bin/bash
set -euo pipefail

# =============================================================================
# arch-deploy — Zenbook 14 Reinstall Pipeline
# =============================================================================
# Master orchestrator. Each stage can also be run standalone.
#
# Usage:
#   ./arch-deploy.sh [global-opts] <stage> [stage-opts]
#
# Stages:
#   inspect          Run on host system. Deep scan → inspect-out/
#   generate-profile Convert inspect data → profiles/*.yaml + *.env
#   validate         Run from USB. RO security audit.
#   prepare          ISO env: network, disk verification, mount (dry-run safe)
#   execute          Base install: wipe @ subvol, pacstrap, GRUB, mkinitcpio
#   configure        Chroot / first-boot: yay, pkgs, dotfiles, services
#   verify           Health checks, baseline snapshot, seal
#
# Global Options:
#   --profile PATH   Path to profile YAML (required for most stages)
#   --dry-run        Show what would be done; do not modify anything
#   --help           Show this help
#
# Examples:
#   ./arch-deploy.sh --profile profiles/my-machine.yaml prepare --dry-run
#   ./arch-deploy.sh --profile profiles/my-machine.yaml execute
# =============================================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# Parse global flags
# ---------------------------------------------------------------------------
PROFILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      die "Unknown global option: $1"
      ;;
    *)
      break
      ;;
  esac
done

STAGE="${1:-}"
[[ $# -gt 0 ]] && shift

[[ -z "$STAGE" ]] && { usage; exit 1; }

# Auto-detect profile if not specified and exactly one non-example profile exists
if [[ -z "$PROFILE" ]]; then
  shopt -s nullglob
  local_profiles=("$SCRIPT_DIR"/profiles/*.yaml)
  shopt -u nullglob
  
  # Filter out example profiles
  valid_profiles=()
  for p in "${local_profiles[@]}"; do
    [[ "$(basename "$p")" != "example.yaml" && "$(basename "$p")" != "zenbook-vm.yaml" ]] && valid_profiles+=("$p")
  done

  if [[ ${#valid_profiles[@]} -eq 1 ]]; then
    PROFILE="${valid_profiles[0]}"
    log_info "Auto-detected profile: $PROFILE"
  fi
fi

# ---------------------------------------------------------------------------
# Resolve stage script
# ---------------------------------------------------------------------------
STAGE_NUM=""
case "$STAGE" in
  inspect)          STAGE_NUM="01" ;;
  generate-profile) STAGE_NUM="02" ;;
  validate)         STAGE_NUM="03" ;;
  prepare)          STAGE_NUM="04" ;;
  execute)          STAGE_NUM="05" ;;
  configure)        STAGE_NUM="06" ;;
  verify)           STAGE_NUM="07" ;;
  *) die "Unknown stage: $STAGE. Run with --help for usage." ;;
esac

STAGE_SCRIPT="$SCRIPT_DIR/stages/${STAGE_NUM}-${STAGE}.sh"
[[ -x "$STAGE_SCRIPT" ]] || die "Stage script not found or not executable: $STAGE_SCRIPT"

# Export globals so standalone stages see them too
export ARCH_DEPLOY_ROOT="$SCRIPT_DIR"
export ARCH_DEPLOY_PROFILE="$PROFILE"
export ARCH_DEPLOY_DRY_RUN="$DRY_RUN"

log_info "Running stage: $STAGE (dry-run=$DRY_RUN)"
exec "$STAGE_SCRIPT" "$@"
