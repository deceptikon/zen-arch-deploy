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
  sudo_path=$(command -v sudo)
if [[ -n "$sudo_path" ]]; then
    SUDO="sudo"
  else
    err "Root or sudo is required for disk creation."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
FORMATTED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk-size) DISK_SIZE="$2"; shift 2 ;;
    --formatted) FORMATTED=true; shift ;;
    --clean) rm -f "$DISK_IMG" "$UEFI_VARS"; ok "Cleaned virtual disk."; exit 0 ;;
    --help|-h)
      cat <<'EOF'
Usage: run-qemu.sh [OPTIONS]

Options:
  --disk-size SIZE   Virtual disk size (default: 40G)
  --formatted        Create disk with filesystems + BTRFS subvolumes (for subvol-reset testing)
  --clean            Delete virtual disk and start fresh
  --help             Show this help

Prerequisites (install on Arch host):
  sudo pacman -S qemu-full edk2-ovmf parted dosfstools btrfs-progs

Download Arch ISO:
  wget -P vm-test/ https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
  ln -s archlinux-x86_64.iso vm-test/archlinux.iso

Then run:
  # Fresh install test (raw disk → format-full in execute stage)
  ./vm-test/run-qemu.sh

  # Reinstall test (pre-formatted disk → subvol-reset in execute stage)
  ./vm-test/run-qemu.sh --formatted

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
qemu_path=$(command -v qemu-system-x86_64)
[[ -z "$qemu_path" ]] && missing+=("qemu-system-x86_64 (package: qemu-full or qemu-base)")
[[ -f "$UEFI_CODE" ]]            || missing+=("OVMF UEFI firmware (package: edk2-ovmf)")
parted_path=$(command -v parted)
[[ -z "$parted_path" ]] && missing+=("parted")
mkfs_vfat_path=$(command -v mkfs.vfat)
[[ -z "$mkfs_vfat_path" ]] && missing+=("dosfstools")
mkfs_btrfs_path=$(command -v mkfs.btrfs)
[[ -z "$mkfs_btrfs_path" ]] && missing+=("btrfs-progs")

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
  echo "  Mode: ${FORMATTED:+formatted (with filesystems)}${FORMATTED:-raw partitions only}"
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

  if [[ "$FORMATTED" == true ]]; then
    info "Attaching disk to loop device for formatting..."
    LOOP_DEV=$($SUDO losetup -f --show -P "$DISK_IMG")
    sleep 2  # Wait for kernel to populate partitions

    ok "Attached to: $LOOP_DEV"

    info "Formatting partitions..."

    # p1: Windows EFI
    $SUDO mkfs.vfat -F32 -n "WIN_EFI" "${LOOP_DEV}p1"
    ok "  p1 → FAT32 (Windows EFI)"

    # p3: Fake Windows OS (ntfs if available, else ext4)
    mkfs_ntfs_path=$(command -v mkfs.ntfs)
    if [[ -n "$mkfs_ntfs_path" ]]; then
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
    TMPMNT=$(mktemp -d /dev/shm/zenbook-btrfs.XXXXXX)
    $SUDO mount "${LOOP_DEV}p5" "$TMPMNT"
    $SUDO btrfs subvolume create "$TMPMNT"/@
    $SUDO btrfs subvolume create "$TMPMNT"/@home
    $SUDO btrfs subvolume create "$TMPMNT"/@swap
    $SUDO btrfs subvolume create "$TMPMNT"/@snapshots
    $SUDO umount "$TMPMNT"
    $SUDO rmdir "$TMPMNT"
    ok "Subvolumes created."

    $SUDO losetup -d "$LOOP_DEV"
    ok "Disk detached."
  fi

  echo ""
  ok "Virtual disk ready!"
  echo ""
else
  if [[ "$FORMATTED" == true ]]; then
    warn "Disk already exists at $DISK_IMG"
    warn "Use --clean first to recreate with filesystems, or run without --formatted to use the existing disk."
    exit 1
  fi
  info "Using existing disk: $DISK_IMG"
fi

# ---------------------------------------------------------------------------
# Prepare root directory for 9p VirtFS — share the whole arch-deploy project
# ---------------------------------------------------------------------------
PROJECT_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
mkdir -p "${SCRIPT_DIR}/shared"
ok "Shared root: ${PROJECT_ROOT} (mounted at /mnt/arch-deploy inside VM)"

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
echo "  dhcpcd                                        # or: iwctl station wlan0 connect YOUR_WIFI"
echo "  mount -t 9p -o trans=virtio hostshare /mnt/arch-deploy"
echo "  cd /mnt/arch-deploy"
echo "  ./stages/01-inspect.sh                        # detect disk layout"
echo "  ./stages/02-generate-profile.sh               # build profile from inspect data"
echo "  cat profiles/my-machine.yaml                  # verify auto-detected values"
echo "  ./arch-deploy.sh --profile profiles/my-machine.yaml prepare --dry-run"
echo "  ./arch-deploy.sh --profile profiles/my-machine.yaml execute --dry-run"
echo "  ./arch-deploy.sh --profile profiles/my-machine.yaml execute"
echo ""
echo "Directories inside VM:"
echo "  /mnt/arch-deploy          ← the full project (code + profiles + test fixture)"
echo "  /mnt/arch-deploy/profiles ← generated & reference profiles"
echo "  /mnt/arch-deploy/test-inspect ← reusable fixture for debug"
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
  -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0
  -usb -device usb-tablet
  -vga virtio
  -display sdl,gl=on
  # 9p VirtFS — share whole arch-deploy project root
  # Inside VM: mount -t 9p -o trans=virtio hostshare /mnt/arch-deploy
  -virtfs local,path=${PROJECT_ROOT},mount_tag=hostshare,security_model=none,multidevs=remap
)

# Headless fallback: use -display none + serial console for non-sandboxed agents
if [[ "${QEMU_HEADLESS:-}" == "true" ]]; then
  QEMU_ARGS=(-display none -nographic -serial mon:stdio)
fi

if [[ -f "$ISO" ]]; then
  QEMU_ARGS+=(-cdrom "$ISO" -boot d)
  info "Booting from ISO (press Esc in QEMU for boot menu if needed)"
else
  info "Booting from disk (no ISO found)"
fi

qemu-system-x86_64 "${QEMU_ARGS[@]}"
