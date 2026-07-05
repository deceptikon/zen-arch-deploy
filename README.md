# arch-deploy — Reproducible Arch Linux Deployment

Machine-specific, auditable, dry-run-safe Arch Linux deployment pipeline.
Originally built for an ASUS Zenbook 14, but generic enough for any UEFI + BTRFS machine.

## Quick Start

```bash
# 1. On your current system — inspect and generate profile
make inspect
make generate

# 2. Edit the generated profile (set dotfiles repo!)
vim profiles/my-machine.yaml

# 3. Re-generate .env after editing
make generate

# 4. Boot Arch ISO from USB, clone this repo, then:
./arch-deploy.sh --profile profiles/my-machine.yaml validate   # security audit
./arch-deploy.sh --profile profiles/my-machine.yaml prepare --dry-run
./arch-deploy.sh --profile profiles/my-machine.yaml prepare
./arch-deploy.sh --profile profiles/my-machine.yaml execute --dry-run
./arch-deploy.sh --profile profiles/my-machine.yaml execute

# 5. Reboot into new system, log in as root
./arch-deploy.sh --profile profiles/my-machine.yaml configure

# 6. Seal & verify
./arch-deploy.sh --profile profiles/my-machine.yaml verify
```

## Stages

| # | Stage | Environment | Destructive? |
|---|-------|-------------|--------------|
| 01 | **inspect** | Current host | No |
| 02 | **generate-profile** | Current host | No |
| 03 | **validate** | Arch ISO (USB) | No (read-only) |
| 04 | **prepare** | Arch ISO (USB) | No |
| 05 | **execute** | Arch ISO (USB) | **Yes** (resets `@` subvol) |
| 06 | **configure** | Installed system | No |
| 07 | **verify** | Installed system | No |

## Wipe Strategy

- **subvol-reset** (default): Deletes and recreates only the `@` subvolume.
  `@home`, `@swap`, and the EFI partition are **preserved**.
- Old `@` is renamed to `@.bak-<timestamp>` for safety.

## VM Test (QEMU/KVM)

Test the entire reinstall pipeline safely in a virtual machine before touching your real Zenbook.

### What the VM simulates

- A 2TB NVMe disk with **your exact partition layout**
- UEFI firmware (not BIOS)
- Windows dual-boot partitions (p1–p3) that should remain untouched
- A BTRFS root pool (p5) with subvolumes `@`, `@home`, `@swap`, `@snapshots`

### Prerequisites on your host

```bash
sudo pacman -S qemu-full edk2-ovmf parted dosfstools btrfs-progs
```

### Step-by-step VM test

#### 1. Download the Arch ISO

```bash
cd /home/lexx/arch-deploy
wget -O vm-test/archlinux.iso https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
```

#### 2. Launch the VM

```bash
./vm-test/run-qemu.sh
```

**What you will see:**
- A QEMU window opens (TianoCore UEFI splash)
- Arch ISO bootloader appears
- You land at the Arch live environment prompt

#### 3. Inside the VM — test the pipeline

```bash
# Set keyboard
loadkeys us

# Connect network (the VM has virtio ethernet, usually auto-connected)
ping -c 3 archlinux.org

# Clone your repo (or mount it via virtio-9p if you prepared it)
# For testing, you can just copy the scripts into the VM via scp,
# or use curl to fetch a tarball. Quick-and-dirty test method:
curl -L https://github.com/YOURNAME/arch-deploy/archive/refs/heads/main.tar.gz | tar xz
cd arch-deploy-main

# Now run the stages (use the VM profile inside QEMU!):
./arch-deploy.sh --profile profiles/zenbook-vm.yaml prepare --dry-run
./arch-deploy.sh --profile profiles/zenbook-vm.yaml prepare
./arch-deploy.sh --profile profiles/zenbook-vm.yaml execute --dry-run
./arch-deploy.sh --profile profiles/zenbook-vm.yaml execute
```

**Watch for these confirmations:**
- `prepare` will say "Partitions verified" and show your EFI and BTRFS partitions
- `execute` will ask you to type `yes` before wiping the `@` subvolume
- After pacstrap, it will install GRUB to the EFI partition

#### 4. Reboot the VM and test configure

```bash
# Inside VM, after execute completes:
reboot

# VM restarts. You should see GRUB menu with Arch Linux.
# Select Arch, boot into the new system.
# Log in as root (password you set during execute stage).

# Run configure:
./arch-deploy.sh --profile profiles/zenbook-vm.yaml configure

# Run verify:
./arch-deploy.sh --profile profiles/zenbook-vm.yaml verify
```

#### 5. Success criteria

| Check | Expected Result |
|-------|-----------------|
| `findmnt /` | Shows `subvol=@` |
| `findmnt /home` | Shows `subvol=@home` (preserved) |
| `systemctl is-enabled sddm` | `enabled` |
| `efibootmgr` | Shows `ARCHLINUX` entry |
| `timeshift --list` | Shows at least one snapshot |

#### 6. Clean up and retry

If something breaks, wipe the virtual disk and start over:

```bash
./vm-test/run-qemu.sh --clean
./vm-test/run-qemu.sh
```

### Troubleshooting

| Problem | Fix |
|---------|-----|
| QEMU says "Could not initialize SDL" | Install `sdl2` or remove `-display sdl,gl=on` from the script |
| No network in VM | Run `dhcpcd` inside the VM |
| Cannot see EFI partition | Ensure you booted via UEFI, not legacy BIOS |
| Script says disk not found | In the VM, the disk is `/dev/vda`, not `/dev/nvme0n1`. Edit the profile or use `--profile` with a VM-specific override |

## Safety Rules

1. Always run with `--dry-run` first.
2. `execute` requires typing `yes` to confirm.
3. `validate` mounts the disk **read-only** from USB.
4. `prepare` verifies UEFI, network, and partition existence before any write.
# zen-arch-deploy
