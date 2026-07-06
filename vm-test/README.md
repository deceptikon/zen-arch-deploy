# QEMU VM Test Environment — Session Recovery Guide

## Overview

The QEMU VM (`vm-test/zenbook-test.img`) is used to test the arch-deploy pipeline end-to-end without touching real hardware. It simulates an ASUS Zenbook 14 with dual-boot Windows/Arch layout.

## VM Specifications

| Property | Value |
|----------|-------|
| Disk | 40GB raw image (`vm-test/zenbook-test.img`) |
| Memory | 4GB |
| CPUs | 4 |
| Display | SDL window (VirtIO GPU) |
| SSH | Port 2222 forwarded to VM:22 |
| File share | 9p VirtFS at `/mnt/arch-deploy` |
| UEFI | OVMF firmware with persistent vars |

## Partition Layout (Inside VM)

```
p1  100M  vfat   ← Windows EFI (sacred, untouched)
p2   16M         ← Windows MSR
p3  ~10G  ntfs   ← Windows C: drive
p4  555M  vfat   ← Shared EFI /boot/efi (Arch GRUB lives here)
p5  ~29G  btrfs  ← Arch root pool (@, @home, @swap, @snapshots)
```

## Quick Start

### Start the VM

```bash
./vm-test/run-qemu.sh
```

Options:
- `--formatted` — Use pre-formatted disk (for subvol-reset testing)
- `--no-disk`   — Don't create disk, just run QEMU

### SSH into the VM

```bash
ssh -p 2222 root@localhost
# Password: root
```

### Mount the project share inside VM

```bash
mount -t 9p -o trans=virtio hostshare /mnt/arch-deploy
cd /mnt/arch-deploy
```

## Session Break Recovery

If a session breaks mid-test, the VM may be left in an inconsistent state. Here's how to recover:

### Scenario 1: VM is running, SSH works

Just reconnect:
```bash
ssh -p 2222 root@localhost
```

### Scenario 2: VM is running, SSH doesn't work

**DO NOT mount the disk image while QEMU is running** — this causes I/O errors and potential corruption.

Instead, use one of these approaches:

#### Option A: QEMU Monitor (if available)

If the VM was started with `-monitor unix:/tmp/qemu-monitor,server,nowait`:
```bash
socat - UNIX-CONNECT:/tmp/qemu-monitor
# Then type: sendkey ctrl-alt-f2
```

#### Option B: Reboot with ISO

1. Download Arch ISO to `vm-test/archlinux.iso`
2. Start VM with ISO attached (run-qemu.sh does this automatically)
3. Boot from ISO
4. Mount the installed system:
   ```bash
   mount -o subvol=@ /dev/vda5 /mnt
   mount /dev/vda4 /mnt/efi
   arch-chroot /mnt
   ```
5. Fix whatever is broken (password, sshd, networking)
6. Exit, unmount, reboot

#### Option C: Graceful shutdown + disk mount

```bash
# 1. Shutdown the VM cleanly (from inside or via monitor)
# 2. Wait for QEMU process to exit
# 3. Now safe to mount:
sudo losetup -fP vm-test/zenbook-test.img
LOOP=$(losetup -j vm-test/zenbook-test.img | head -1 | cut -d: -f1)
sudo mount -o subvol=@ "${LOOP}p5" /mnt/vm-fix
# 4. Make fixes
# 5. Unmount:
sudo umount /mnt/vm-fix
sudo losetup -d "$LOOP"
```

### Scenario 3: Disk is corrupted

Recreate from scratch:
```bash
rm vm-test/zenbook-test.img vm-test/OVMF_VARS.fd
./vm-test/run-qemu.sh
```

## Testing Stages

### Fresh install test (format-full)

```bash
# 1. Boot from ISO
./vm-test/run-qemu.sh

# 2. Inside ISO, run stages 01-05
./arch-deploy.sh --profile profiles/zenbook-vm.yaml

# 3. Reboot into installed system
# 4. SSH in and run stages 06-07
ssh -p 2222 root@localhost
mount -t 9p -o trans=virtio hostshare /mnt/arch-deploy
cd /mnt/arch-deploy
./stages/06-configure.sh --profile profiles/zenbook-vm.yaml
./stages/07-verify.sh --profile profiles/zenbook-vm.yaml
```

### Reinstall test (subvol-reset)

```bash
# 1. Create formatted disk once
./vm-test/run-qemu.sh --formatted
# 2. Run stages 01-05 inside ISO
# 3. Reboot and test
```

## Common Issues

### SSH connection refused
- sshd not installed or not enabled
- Network not configured
- Root password not set
- Firewall blocking

### GRUB not booting
- OVMF_VARS.fd may need regeneration
- Boot from ISO and re-run `grub-install`

### 9p share not mounting
- Check `dmesg | grep 9p` inside VM
- Ensure `CONFIG_NET_9P_VIRTIO` is in kernel

## Files

| File | Purpose |
|------|---------|
| `vm-test/run-qemu.sh` | VM launcher script |
| `vm-test/zenbook-test.img` | 40GB raw disk image |
| `vm-test/OVMF_VARS.fd` | UEFI variables (persistent boot entries) |
| `vm-test/archlinux.iso` | Arch Linux install ISO (optional) |
| `vm-test/shared/` | 9p mount point on host |

## Requirements

```bash
sudo pacman -S qemu-full edk2-ovmf parted dosfstools btrfs-progs
```

## Strict Rules (No Exceptions)

1. **Never suppress errors with `|| true` or `2>/dev/null`** — always handle errors explicitly
2. **Never mount the disk image while QEMU is running** — shutdown first
3. **Always verify commands succeeded** — check exit codes
4. **Document all fixes** — add to this file, not session logs
