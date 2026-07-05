#!/bin/bash
# =============================================================================
# Stage 02: GENERATE-PROFILE
# =============================================================================
# Converts 01-inspect output into a machine profile (.yaml + .env).
# Run on host system (needs python3 with PyYAML, or falls back to basic parsing).
#
# Usage:
#   ./stages/02-generate-profile.sh [--inspect-dir DIR] [--out-dir DIR]
# =============================================================================

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$SCRIPT_DIR/lib/common.sh"

INSPECT_DIR="${1:-./inspect-out}"
OUT_DIR="./profiles"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inspect-dir) INSPECT_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -d "$INSPECT_DIR" ]] || die "Inspect directory not found: $INSPECT_DIR"
mkdir -p "$OUT_DIR"

PROFILE_NAME="my-machine"
YAML_OUT="$OUT_DIR/${PROFILE_NAME}.yaml"
ENV_OUT="$OUT_DIR/${PROFILE_NAME}.env"

log_info "Generating profile from $INSPECT_DIR"

# ---------------------------------------------------------------------------
# Extract values from inspect data
# ---------------------------------------------------------------------------
HOSTNAME="$(hostname 2>/dev/null || echo archbox)"

# CPU vendor
cpu_vendor="$(grep "Vendor ID" "$INSPECT_DIR/hardware.txt" | head -n1 | awk '{print $3}' | tr '[:upper:]' '[:lower:]')"
[[ "$cpu_vendor" == *"amd"* ]] && UCODE="amd-ucode" || UCODE="intel-ucode"

# Kernel
kernel_pkg="$(grep -oP 'vmlinuz-\K[^ ]+' "$INSPECT_DIR/storage.txt" | head -n1 | sed 's/^vmlinuz-//')"
[[ -z "$kernel_pkg" ]] && kernel_pkg="linux-zen"

# Root partition UUID
root_part_uuid="$(grep "root=UUID" "$INSPECT_DIR/storage.txt" | grep -oP 'root=UUID=\K[^ ]+' | head -n1)"

# Resume offset
resume_offset="$(grep -oP 'resume_offset=\K[0-9]+' "$INSPECT_DIR/storage.txt" | head -n1)"

# BTRFS detection from inspect output
if grep -q "=== BTRFS DETECTED: YES ===" "$INSPECT_DIR/storage.txt" 2>/dev/null; then
  btrfs_detected=true
  # Try to extract the BTRFS device from inspect output
  btrfs_dev="$(grep "^=== BTRFS DEVICE:" "$INSPECT_DIR/storage.txt" | head -n1 | awk '{print $4}')"
  log_info "BTRFS detected on device: ${btrfs_dev:-unknown}"
else
  btrfs_detected=false
  log_warn "No BTRFS detected in inspect output. Will generate fresh-install profile."
fi

# Extract base packages from explicit list
pkg_list=""
if [[ -f "$INSPECT_DIR/packages.txt" ]]; then
  # Extract lines between "EXPLICIT PACKAGES" and next "==="
  pkg_list=$(awk '/EXPLICIT PACKAGES/{flag=1;next}/^===/{flag=0}flag' "$INSPECT_DIR/packages.txt" | grep -v '^$' | sort -u)
fi

# Extract services
svc_list=""
if [[ -f "$INSPECT_DIR/services.txt" ]]; then
  svc_list=$(awk '/ENABLED SERVICES/{flag=1;next}/^===/{flag=0}flag' "$INSPECT_DIR/services.txt" | awk 'NR>1 && $1 ~ /\.service$/ {print $1}' | sed 's/\.service$//' | sort -u)
fi

# Security hashes
hashes=""
if [[ -f "$INSPECT_DIR/security/hashes.txt" ]]; then
  while read -r line; do
    [[ "$line" == MISSING:* ]] && continue
    hash_val="$(echo "$line" | awk '{print $1}')"
    path_val="$(echo "$line" | awk '{print $2}')"
    [[ -n "$hash_val" && -n "$path_val" ]] || continue
    hashes="${hashes}  - path: \"$path_val\"\n    sha256: \"$hash_val\"\n"
  done < <(grep "^" "$INSPECT_DIR/security/hashes.txt" | grep -v "^===")
fi

# ---------------------------------------------------------------------------
# Write YAML
# ---------------------------------------------------------------------------

# Determine wipe strategy and storage layout based on BTRFS detection
if [[ "$btrfs_detected" == true ]]; then
  wipe_strategy="subvol-reset"
  root_fstype="btrfs"
  root_preserve="true"
  root_device="${btrfs_dev:-/dev/nvme0n1p2}"
else
  wipe_strategy="format-full"
  root_fstype="ext4"
  root_preserve="false"
  root_device="/dev/nvme0n1p2"
fi

cat > "$YAML_OUT" <<EOF
# =============================================================================
# Profile: $PROFILE_NAME
# Auto-generated from inspect data on $(date -Iseconds)
# =============================================================================

machine:
  id: $PROFILE_NAME
  hostname: $HOSTNAME
  uefi: true
  secure_boot: disabled

cpu:
  vendor: ${cpu_vendor:-amd}
  ucode_pkg: $UCODE

gpu:
  driver: amdgpu
  opengl_vendor: AMD

storage:
  disk: /dev/nvme0n1
  wipe_strategy: $wipe_strategy
  purge_snapshots: true
  partitions:
    efi:
      device: /dev/nvme0n1p1
      fstype: vfat
      mount: /efi
      preserve: true
    root_pool:
      device: $root_device
      fstype: $root_fstype
      preserve: $root_preserve
      subvolumes:
EOF

if [[ "$btrfs_detected" == true ]]; then
  cat >> "$YAML_OUT" <<'EOF'
        - name: "@"
          mount: "/"
          reset: true
          options: ""
        - name: "@home"
          mount: "/home"
          reset: false
          options: ""
        - name: "@swap"
          mount: "/.swap"
          reset: false
          options: "nodatacow,compress=no"
        - name: "@snapshots"
          mount: "/.snapshots"
          reset: true
          options: ""
EOF
fi

cat >> "$YAML_OUT" <<EOF

bootloader:
  type: grub
  target: x86_64-efi
  efi_directory: /efi
  bootloader_id: ARCHLINUX
  os_prober: true

kernel:
  pkg: $kernel_pkg
  cmdline: "rw rootflags=subvol=@ loglevel=3 quiet resume=UUID=${root_part_uuid} resume_offset=${resume_offset} rtc_cmos.use_acpi_alarm=1"
  hooks:
    - base
    - systemd
    - autodetect
    - microcode
    - modconf
    - kms
    - keyboard
    - keymap
    - sd-vconsole
    - block
    - resume
    - filesystems
    - fsck

software:
  base_packages:
EOF

# Write packages from inspect
while IFS= read -r pkg; do
  [[ -n "$pkg" ]] && echo "    - $pkg" >> "$YAML_OUT"
done <<< "$pkg_list"

# Fallback defaults if list is empty
if [[ -z "$pkg_list" ]]; then
  cat >> "$YAML_OUT" <<'EOF'
    - base
    - base-devel
    - linux-zen
    - linux-zen-headers
    - amd-ucode
    - grub
    - efibootmgr
    - os-prober
    - btrfs-progs
    - networkmanager
    - pipewire
    - pipewire-pulse
    - wireplumber
    - sway
    - waybar
    - dunst
    - foot
    - ghostty
    - zsh
    - git
    - vim
    - firefox
EOF
fi

cat >> "$YAML_OUT" <<EOF

  aur_packages:
    - yay
    - zsh-antidote

  services:
    system:
EOF

while IFS= read -r svc; do
  [[ -n "$svc" ]] && echo "      - $svc" >> "$YAML_OUT"
done <<< "$svc_list"

# Fallback services
if [[ -z "$svc_list" ]]; then
  cat >> "$YAML_OUT" <<'EOF'
      - NetworkManager
      - sddm
      - systemd-timesyncd
      - bluetooth
      - acpid
EOF
fi

cat >> "$YAML_OUT" <<EOF

  aur_helper: yay

desktop:
  session: sway
  display_manager: sddm
  scale: 1.5
  output: eDP-1
  resolution: 2880x1800
  refresh_rate: 120

dotfiles:
  manager: chezmoi
  repo: ""
  branch: main

security:
  known_hashes:
$(echo -e "$hashes")
EOF

log_ok "YAML written: $YAML_OUT"

# ---------------------------------------------------------------------------
# Generate .env companion file (pure bash, sourced by stages)
# ---------------------------------------------------------------------------
python3 - "$YAML_OUT" "$ENV_OUT" <<'PYEOF'
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
        # Escape quotes in value
        safe_v = v.replace('"', '\\"')
        out.write(f'PROFILE_{safe_k}="{safe_v}"\n')

print(f"Generated: {sys.argv[2]}")
PYEOF

log_ok "Environment file written: $ENV_OUT"
log_info "Profile generation complete."
log_warn "IMPORTANT: Edit $YAML_OUT and set dotfiles.repo before running configure stage!"
