#!/bin/bash
# =============================================================================
# vm-test/run-qemu.sh — QEMU/KVM Test Environment for arch-deploy
# =============================================================================
#
# WHAT THIS DOES:
#   Creates a virtual 2TB NVMe disk with the EXACT same partition layout
#   as your ASUS Zenbook 14:
#
#     p1  100M  vfat   ← Windows EFI (sacred, untouched)
#     p2   16M         ← Windows MSR
#     p3  ~10G  ntfs   ← Windows C: drive
#     p4  555M  vfat   ← Shared EFI /boot/efi (Arch GRUB lives here)
#     p5  ~29G  btrfs  ← Arch root pool (@, @home, @swap, @snapshots)
#
#   Then launches a QEMU VM with UEFI firmware so you can:
#     1. Boot Arch ISO
#     2. Run arch-deploy stages 03→04→05
#     3. Reboot and test stage 06→07
#
# HYPERVISOR: QEMU/KVM (qemu-system-x86_64)
# DISPLAY:    SDL window with VirtIO GPU
# RESULTS:    Watch the terminal for stage output, watch QEMU window for boot
#
# USAGE:
#   ./vm-test/run-qemu.sh           # creates disk (needs sudo) then runs QEMU
#   sudo ./vm-test/run-qemu.sh      # same, but you pre-authed
# =============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DISK_IMG="$SCRIPT_DIR/zenbook-test.img"
DISK_SIZE="40G"
ISO="$SCRIPT_DIR/archlinux.iso"
if [[ -f "/usr/share/edk2/x64/OVMF_CODE.4m.fd" ]]; then
  UEFI_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
  UEFI_VARS_SRC="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
else
  UEFI_CODE="/usr/share/OVMF/x64/OVMF_CODE.fd"
  UEFI_VARS_SRC="/usr/share/OVMF/x64/OVMF_VARS.fd"
fi
UEFI_VARS="$SCRIPT_DIR/OVMF_VARS.fd"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

info()  { echo -e "${BLUE}[VM-TEST]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()   { echo -e "${RED}[ERR]${RESET} $*"; }

# Privilege helper: use sudo if not root
SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo &>/dev/null; then
    SUDO="sudo"
  else
    err "Root or sudo is required for disk creation."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk-size) DISK_SIZE="$2"; shift 2 ;;
    --clean) rm -f "$DISK_IMG" "$UEFI_VARS"; ok "Cleaned virtual disk."; exit 0 ;;
    --help|-h)
      cat <<'EOF'
Usage: run-qemu.sh [OPTIONS]

Options:
  --disk-size SIZE   Virtual disk size (default: 40G)
  --clean            Delete virtual disk and start fresh
  --help             Show this help

Prerequisites (install on Arch host):
  sudo pacman -S qemu-full edk2-ovmf parted dosfstools btrfs-progs

Download Arch ISO:
  wget -P vm-test/ https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
  ln -s archlinux-x86_64.iso vm-test/archlinux.iso

Then run:
  ./vm-test/run-qemu.sh

EOF
      exit 0
      ;;
    *) shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
info "Checking prerequisites..."

missing=()
command -v qemu-system-x86_64 &>/dev/null || missing+=("qemu-system-x86_64 (package: qemu-full or qemu-base)")
[[ -f "$UEFI_CODE" ]]            || missing+=("OVMF UEFI firmware (package: edk2-ovmf)")
command -v parted &>/dev/null    || missing+=("parted")
command -v mkfs.vfat &>/dev/null || missing+=("dosfstools")
command -v mkfs.btrfs &>/dev/null|| missing+=("btrfs-progs")

if [[ ${#missing[@]} -gt 0 ]]; then
  err "Missing prerequisites:"
  printf '  - %s\n' "${missing[@]}"
  echo ""
  info "Install them:"
  echo "  sudo pacman -S qemu-full edk2-ovmf parted dosfstools btrfs-progs"
  exit 1
fi
ok "All prerequisites found."

# Warn if user lacks KVM acceleration
if [[ ! -r /dev/kvm ]]; then
  warn "KVM acceleration unavailable (add your user to the 'kvm' group for faster VMs)"
  warn "  sudo usermod -aG kvm $(whoami)  # then log out and back in"
fi

# ---------------------------------------------------------------------------
# Check for Arch ISO
# ---------------------------------------------------------------------------
if [[ ! -f "$ISO" ]]; then
  warn "Arch ISO not found at: $ISO"
  info "Download it:"
  echo "  wget -O $ISO https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
  echo ""
  read -rp "Continue without ISO? (VM will try to boot from disk) [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

# ---------------------------------------------------------------------------
# Create virtual disk if missing
# ---------------------------------------------------------------------------
if [[ ! -f "$DISK_IMG" ]]; then
  info "Creating virtual disk..."
  echo "  File: $DISK_IMG"
  echo "  Size: $DISK_SIZE"
  echo ""

  qemu-img create -f raw "$DISK_IMG" "$DISK_SIZE"

  info "Partitioning disk (GPT with 5 partitions)..."
  parted -s "$DISK_IMG" mklabel gpt
  parted -s "$DISK_IMG" mkpart primary fat32   1MiB    101MiB
  parted -s "$DISK_IMG" mkpart primary         101MiB  117MiB   # 16M MSR-like
  parted -s "$DISK_IMG" mkpart primary ntfs    117MiB  10GiB    # ~10G "Windows"
  parted -s "$DISK_IMG" mkpart primary fat32   10GiB   10.5GiB  # 555M shared EFI
  parted -s "$DISK_IMG" mkpart primary btrfs   10.5GiB 100%     # Rest = Arch pool
  ok "Partition table created."

  info "Attaching disk to loop device for formatting..."
  LOOP_DEV=$($SUDO losetup -f --show -P "$DISK_IMG")
  sleep 2  # Wait for kernel to populate partitions

  ok "Attached to: $LOOP_DEV"

  info "Formatting partitions..."

  # p1: Windows EFI
  $SUDO mkfs.vfat -F32 -n "WIN_EFI" "${LOOP_DEV}p1"
  ok "  p1 → FAT32 (Windows EFI)"

  # p3: Fake Windows OS (ntfs if available, else ext4)
  if command -v mkfs.ntfs &>/dev/null; then
    $SUDO mkfs.ntfs -f -L "Windows" "${LOOP_DEV}p3"
    ok "  p3 → NTFS (Windows OS)"
  else
    $SUDO mkfs.ext4 -L "Windows" "${LOOP_DEV}p3"
    warn "  p3 → ext4 (Windows OS) — install ntfs-3g for real NTFS"
  fi

  # p4: Shared EFI (where Arch GRUB will live)
  $SUDO mkfs.vfat -F32 -n "EFI" "${LOOP_DEV}p4"
  ok "  p4 → FAT32 (Shared EFI)"

  # p5: BTRFS root pool with your exact subvolume layout
  $SUDO mkfs.btrfs -f -L "ArchPool" "${LOOP_DEV}p5"
  ok "  p5 → BTRFS (Arch root pool)"

  info "Creating BTRFS subvolumes (@, @home, @swap, @snapshots)..."
  $SUDO mkdir -p /tmp/zenbook-btrfs
  $SUDO mount "${LOOP_DEV}p5" /tmp/zenbook-btrfs
  $SUDO btrfs subvolume create /tmp/zenbook-btrfs/@
  $SUDO btrfs subvolume create /tmp/zenbook-btrfs/@home
  $SUDO btrfs subvolume create /tmp/zenbook-btrfs/@swap
  $SUDO btrfs subvolume create /tmp/zenbook-btrfs/@snapshots
  $SUDO umount /tmp/zenbook-btrfs
  $SUDO rmdir /tmp/zenbook-btrfs
  ok "Subvolumes created."

  $SUDO losetup -d "$LOOP_DEV"
  ok "Disk detached."

  echo ""
  ok "Virtual disk ready!"
  echo ""
fi

# ---------------------------------------------------------------------------
# Prepare UEFI vars (fresh copy for clean NVRAM)
# ---------------------------------------------------------------------------
if [[ -f "$UEFI_VARS_SRC" ]]; then
  cp "$UEFI_VARS_SRC" "$UEFI_VARS"
else
  err "UEFI vars source not found: $UEFI_VARS_SRC"
  exit 1
fi
ok "UEFI NVRAM initialized."

# ---------------------------------------------------------------------------
# Launch QEMU
# ---------------------------------------------------------------------------
echo ""
info "═══════════════════════════════════════════════════════════════"
info "  Starting QEMU/KVM Virtual Machine"
info "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Disk image:  $DISK_IMG"
echo "  ISO:         $ISO"
echo "  Firmware:    UEFI (OVMF)"
echo "  RAM:         4 GB"
echo "  CPUs:        4 cores"
echo "  Display:     SDL window"
echo ""
info "What you should see:"
echo "  1. QEMU window opens with TianoCore UEFI splash"
echo "  2. Arch ISO bootloader menu appears"
echo "  3. You land in Arch live environment"
echo ""
info "Next steps inside the VM:"
echo "  loadkeys us"
echo "  iwctl station wlan0 connect YOUR_WIFI   # or dhcpcd if wired"
echo "  git clone https://github.com/YOU/arch-deploy.git"
echo "  cd arch-deploy"
echo "  ./arch-deploy.sh --profile profiles/zenbook-vm.yaml execute --dry-run"
echo "  ./arch-deploy.sh --profile profiles/zenbook-vm.yaml execute"
echo ""
warn "Press Ctrl+A then X in the QEMU window to force-quit if needed."
echo ""

QEMU_ARGS=(
  -enable-kvm
  -m 4096
  -smp 4
  -cpu host
  -drive if=pflash,format=raw,readonly=on,file="$UEFI_CODE"
  -drive if=pflash,format=raw,file="$UEFI_VARS"
  -drive if=virtio,format=raw,file="$DISK_IMG"
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0
  -usb -device usb-tablet
  -vga virtio
  -display sdl,gl=on
)

if [[ -f "$ISO" ]]; then
  QEMU_ARGS+=(-cdrom "$ISO" -boot d)
  info "Booting from ISO (press Esc in QEMU for boot menu if needed)"
else
  info "Booting from disk (no ISO found)"
fi

qemu-system-x86_64 "${QEMU_ARGS[@]}"
