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

# NOTE: NO set -e. generate-profile is a config generator; missing data
# should produce defaults, not crash the pipeline.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/profile.sh"
set +e  # restore NO set -e after common.sh sets it

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

# Verify required inspect output files exist
for req in hardware.txt storage.txt packages.txt services.txt; do
  if [[ ! -f "$INSPECT_DIR/$req" ]]; then
    die "Missing inspect output file: $INSPECT_DIR/$req\nRun './stages/01-inspect.sh' first."
  fi
done

if ! inspect_validate "$INSPECT_DIR"; then
  die "Inspect data validation failed. Run './stages/01-inspect.sh' first."
fi

PROFILE_NAME="my-machine"
YAML_OUT="$OUT_DIR/${PROFILE_NAME}.yaml"
ENV_OUT="$OUT_DIR/${PROFILE_NAME}.env"

log_info "Generating profile from $INSPECT_DIR"

# ---------------------------------------------------------------------------
# Extract values from inspect data
# ---------------------------------------------------------------------------
if command -v hostname; then
  HOSTNAME="$(hostname)"
elif [[ -r /proc/sys/kernel/hostname ]]; then
  HOSTNAME="$(cat /proc/sys/kernel/hostname)"
elif [[ -r /etc/hostname ]]; then
  HOSTNAME="$(cat /etc/hostname)"
else
  HOSTNAME="unknown"
  log_warn "Cannot determine hostname — hostname command not found, /proc/sys/kernel/hostname not readable, /etc/hostname not readable. Using 'unknown'."
fi

# CPU vendor
cpu_vendor="$(grep "Vendor ID" "$INSPECT_DIR/hardware.txt" | head -n1 | awk '{print $3}' | tr '[:upper:]' '[:lower:]')"
if [[ "$cpu_vendor" == *"amd"* ]]; then
  UCODE="amd-ucode"
else
  UCODE="intel-ucode"
fi

# Kernel (from /proc/cmdline in inspect output)
kernel_pkg=""
if grep -q "vmlinuz-" "$INSPECT_DIR/storage.txt"; then
  kernel_pkg="$(grep -oP 'vmlinuz-\K[^ ]+' "$INSPECT_DIR/storage.txt" | head -n1 | sed 's/^vmlinuz-//')"
fi
[[ -z "$kernel_pkg" ]] && kernel_pkg="linux-zen"

# Root partition UUID (from cmdline in inspect output)
root_part_uuid=""
if grep -q "root=UUID" "$INSPECT_DIR/storage.txt"; then
  root_part_uuid="$(grep "root=UUID" "$INSPECT_DIR/storage.txt" | grep -oP 'root=UUID=\K[^ ]+' | head -n1)"
fi

# Resume offset (from cmdline in inspect output)
resume_offset=""
if grep -q "resume_offset=" "$INSPECT_DIR/storage.txt"; then
  resume_offset="$(grep -oP 'resume_offset=\K[0-9]+' "$INSPECT_DIR/storage.txt" | head -n1)"
fi

# BTRFS detection from inspect output
if grep -q "=== BTRFS DETECTED: YES ===" "$INSPECT_DIR/storage.txt"; then
  btrfs_detected=true
  btrfs_dev="$(grep "^=== BTRFS DEVICE:" "$INSPECT_DIR/storage.txt" | head -n1 | awk '{print $4}')"
  log_info "BTRFS detected on device: ${btrfs_dev:-unknown}"
else
  btrfs_detected=false
  log_warn "No BTRFS detected in inspect output. Will generate fresh-install profile."
fi

# Extract base packages from explicit list
pkg_list=""
if [[ -f "$INSPECT_DIR/packages.txt" ]]; then
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

# ---------------------------------------------------------------------------
# Disk layout discovery from inspect data
# ---------------------------------------------------------------------------
log_info "Discovering disk layout from inspect data..."

# blkid format: /dev/vda1: UUID="..." TYPE="vfat" PARTUUID="..."
# blkid reads superblocks directly — works even when kernel hasn't probed the device
# (e.g., fresh virtio disk in VM where lsblk -f shows blank FSTYPE)
_disk=""
_efi_dev=""
_root_dev=""

if [[ -f "$INSPECT_DIR/storage.txt" ]]; then
  blkid_data=$(awk '/^=== BLKID ===$/{flag=1;next}/^=== *$|^---$/{flag=0}flag' "$INSPECT_DIR/storage.txt")

  # Extract device with TYPE="btrfs" (root pool) and TYPE="vfat" (EFI)
  _root_dev=$(echo "$blkid_data" | sed -n 's|^ *\(/dev/[^:]*\):.* TYPE="btrfs".*|\1|p' | head -n1)
  _efi_dev=$(echo "$blkid_data" | sed -n 's|^ *\(/dev/[^:]*\):.* TYPE="vfat".*|\1|p' | head -n1)

  # Infer parent disk from partition name
  # vda5 -> /dev/vda, nvme0n1p2 -> /dev/nvme0n1, sda1 -> /dev/sda
  if [[ -n "$_root_dev" ]]; then
    _part_name="${_root_dev##*/}"
    if [[ "$_part_name" =~ ^nvme ]]; then
      _disk="/dev/${_part_name%p*}"
    else
      _disk="/dev/${_part_name%%[0-9]*}"
    fi
  elif [[ -n "$_efi_dev" ]]; then
    _part_name="${_efi_dev##*/}"
    if [[ "$_part_name" =~ ^nvme ]]; then
      _disk="/dev/${_part_name%p*}"
    else
      _disk="/dev/${_part_name%%[0-9]*}"
    fi
  fi
fi

# Validate we found something — use explicit placeholders so failures are obvious
# rather than silently inserting a wrong device path.
if [[ -z "$_disk" || -z "$_root_dev" ]]; then
  log_warn "Could not auto-detect disk layout from inspect data."
  log_warn "Falling back to defaults — YOU MUST EDIT THE GENERATED PROFILE."
  _disk="<DISK_DEVICE>"
  _efi_dev="<EFI_PARTITION>"
  _root_dev="<ROOT_PARTITION>"
fi

log_info "Detected disk: $_disk"
log_info "Detected EFI: $_efi_dev"
log_info "Detected root pool: $_root_dev"

# Determine wipe strategy and storage layout based on BTRFS detection
if [[ "$btrfs_detected" == true ]]; then
  wipe_strategy="subvol-reset"
  root_fstype="btrfs"
  root_preserve="true"
  root_device="${btrfs_dev:-$_root_dev}"
else
  wipe_strategy="format-full"
  root_fstype="ext4"
  root_preserve="false"
  root_device="$_root_dev"
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
  disk: $_disk
  wipe_strategy: $wipe_strategy
  purge_snapshots: true
  partitions:
    efi:
      device: $_efi_dev
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

# ---------------------------------------------------------------------------
# Boundary Validation
# ---------------------------------------------------------------------------
log_info "Validating generated profile boundaries..."
profile_load "$YAML_OUT"
profile_validate

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  GENERATED PROFILE: $YAML_OUT"
echo "═══════════════════════════════════════════════════════════════════"
cat "$YAML_OUT"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  GENERATED ENV: $ENV_OUT"
echo "═══════════════════════════════════════════════════════════════════"
head -20 "$ENV_OUT"
echo "... ($(wc -l < "$ENV_OUT") lines total)"
echo ""
log_warn "IMPORTANT: Edit $YAML_OUT and set dotfiles.repo before running configure stage!"
