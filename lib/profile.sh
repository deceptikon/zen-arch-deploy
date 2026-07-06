#!/bin/bash
# =============================================================================
# lib/profile.sh — Profile loading helpers
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ---------------------------------------------------------------------------
# Auto-generate .env from YAML
# ---------------------------------------------------------------------------
profile_generate_env() {
  local yaml_file="$1"
  local env_file="$2"

  log_info "Attempting to generate .env from YAML..."

  local python3_path
  python3_path=$(command -v python3)
  if [[ -n "$python3_path" ]]; then
    local has_yaml
    has_yaml=$("$python3_path" -c "import yaml; print('yes')")
    if [[ "$has_yaml" == "yes" ]]; then
      "$python3_path" - "$yaml_file" "$env_file" <<'PYEOF'
import sys, yaml

def flatten(d, parent_key='', sep='__'):
    items = []
    if isinstance(d, list):
        for i, v in enumerate(d):
            items.extend(flatten(v, f"{parent_key}{sep}{i}", sep))
    elif isinstance(d, dict):
        for k, v in d.items():
            new_key = f"{parent_key}{sep}{k}" if parent_key else k
            items.extend(flatten(v, new_key, sep))
    else:
        items.append((parent_key, str(d)))
    return items

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

with open(sys.argv[2], 'w') as out:
    out.write("# Auto-generated from profile YAML. Do not edit manually.\n")
    out.write(f"# Source: {sys.argv[1]}\n\n")
    for k, v in flatten(data):
        safe_k = k.replace('-', '_').replace('.', '_')
        safe_v = v.replace('"', '\\"')
        out.write(f'PROFILE_{safe_k}="{safe_v}"\n')
PYEOF
      log_ok "Generated .env via python3: $env_file"
      return 0
    fi
  fi

  # Fallback: yq (if installed)
  local yq_path
  yq_path=$(command -v yq)
  if [[ -n "$yq_path" ]]; then
    "$yq_path" -o=props "$yaml_file" > "$env_file"
    log_ok "Generated .env via yq: $env_file"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Resolve companion .env path from any profile path
# ---------------------------------------------------------------------------
profile_env_path() {
  local yaml_file="$1"
  local base="${yaml_file}"

  # Strip known YAML extensions: .yaml, .yml
  if [[ "$base" == *.yaml ]]; then
    base="${base%.yaml}"
  elif [[ "$base" == *.yml ]]; then
    base="${base%.yml}"
  fi

  # If the file itself already ends in .env (user passed .env directly), return as-is
  if [[ "$base" == *.env ]]; then
    echo "$base"
    return 0
  fi

  echo "${base}.env"
}

# ---------------------------------------------------------------------------
# Load profile (YAML → .env → source)
# ---------------------------------------------------------------------------
profile_load() {
  local yaml_file="${1:-$PROFILE}"
  [[ -f "$yaml_file" ]] || die "Profile not found: $yaml_file"

  local env_file
  env_file=$(profile_env_path "$yaml_file")

  if [[ ! -f "$env_file" ]]; then
    log_warn "Companion .env not found: $env_file"
    if ! profile_generate_env "$yaml_file" "$env_file"; then
      log_err "Cannot auto-generate .env: python3+PyYAML or yq is required."
      log_err "Options:"
      log_err "  1. Install python3 and PyYAML on the ISO: pacman -S python python-yaml"
      log_err "  2. Or copy a pre-generated .env file next to your .yaml profile"
      die "Cannot load profile without .env file."
    fi
  fi

  # shellcheck source=/dev/null
  source "$env_file"
  log_ok "Loaded profile: $yaml_file"
}

# ---------------------------------------------------------------------------
# Boundary validation: verify loaded profile has required keys
# Call after profile_load() in stages that consume the profile.
# Dies with clear list of missing keys.
# ---------------------------------------------------------------------------
profile_validate() {
  local required_keys=(
    "storage.disk"
    "storage.wipe_strategy"
    "storage.partitions.efi.device"
    "storage.partitions.efi.mount"
    "storage.partitions.root_pool.device"
    "machine.hostname"
    "kernel.pkg"
  )

  local missing=()
  for key in "${required_keys[@]}"; do
    local val
    val=$(profile_get "$key")
    [[ -n "$val" ]] || missing+=("$key")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_err "Profile validation FAILED. Missing required keys:"
    for k in "${missing[@]}"; do
      log_err "  - $k"
    done
    log_err "The profile is incomplete or corrupt."
    log_err "Regenerate it: ./stages/02-generate-profile.sh --inspect-dir ./inspect-out --out-dir ./profiles"
    die "Cannot proceed with incomplete profile."
  fi

  log_ok "Profile validation passed (${#required_keys[@]} required keys present)"
}

# ---------------------------------------------------------------------------
# Boundary validation: verify inspect output has expected structure
# Call BEFORE generate-profile to ensure data is usable.
# ---------------------------------------------------------------------------
inspect_validate() {
  local inspect_dir="$1"
  local required_files=(
    "hardware.txt"
    "storage.txt"
    "packages.txt"
    "services.txt"
  )
  local issues=0

  log_info "Validating inspect output in: $inspect_dir"

  for f in "${required_files[@]}"; do
    if [[ ! -f "$inspect_dir/$f" ]]; then
      log_err "Missing inspect output: $f"
      issues=$((issues+1))
    elif [[ ! -s "$inspect_dir/$f" ]]; then
      log_warn "Empty inspect output: $f"
      issues=$((issues+1))
    else
      log_ok "Found: $f ($(wc -l < "$inspect_dir/$f") lines)"
    fi
  done

  # Check that storage.txt has BLKID section (critical for disk discovery)
  if [[ -f "$inspect_dir/storage.txt" ]]; then
    if ! grep -q "^=== BLKID ===" "$inspect_dir/storage.txt"; then
      log_err "storage.txt missing === BLKID === section — disk discovery will fail"
      issues=$((issues+1))
    fi
    if ! grep -q "^=== BLOCK DEVICES ===" "$inspect_dir/storage.txt"; then
      log_err "storage.txt missing === BLOCK DEVICES === section — topology discovery will fail"
      issues=$((issues+1))
    fi
  fi

  if [[ $issues -gt 0 ]]; then
    log_err "Inspect validation found $issues issue(s)."
    log_err "Re-run inspect: ./stages/01-inspect.sh"
    return 1
  fi

  log_ok "Inspect data validated successfully."
  return 0
}