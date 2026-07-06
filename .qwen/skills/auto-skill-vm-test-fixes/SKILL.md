---
name: vm-test-fixes
description: Fix common pitfalls when testing arch-deploy on QEMU VM — hardcoded nvme paths, Arch ISO network setup, blkid-based disk discovery, empty disk signatures, and data extraction from VM
source: auto-skill
extracted_at: '2026-07-05T13:17:46.538Z'
---

## Problem

The arch-deploy pipeline failed on QEMU VMs with virtio disks (`/dev/vda`). Three layered issues, found through visual inspection of VM terminal screenshots:

### Issue 1: Hardcoded nvme fallbacks (already known)
When auto-detect from `lsblk` fails, `stages/02-generate-profile.sh` assumed nvme device names, causing "device not found" on virtio/VM disks.

### Issue 2: No filesystem signatures detected (the real blocker)
`lsblk` inside the fresh VM shows **empty FSTYPE/TYPE columns** for all `/dev/vda` partitions. `blkid` output also reports **no `TYPE=` field** on `/dev/vda*` partitions — only `PARTLABEL` and `PARTUUID`. The partitions have correct GPT layout but **zero filesystem data**. This means either:
- The disk image was created but `mkfs` + subvolume creation was skipped (e.g., pre-existing .img file triggered the skip guard in `run-qemu.sh`)
- The fresh ISO environment hasn't probed filesystem signatures yet (kernel-level, not fixable in userspace)

### Issue 3: Error suppression masked all failures
~100 instances of `2>/dev/null`, `|| true`, `|| echo "N/A"` across every file turned real errors into silent nothing.

## Fixes Applied

### 1. blkid as primary disk discovery (stages/01-inspect.sh + stages/02-generate-profile.sh)
- `01-inspect.sh` now captures `blkid` output (superblock reader, works without kernel probing) as `=== BLKID ===` section
- `01-inspect.sh` uses `lsblk --pairs` for topology only (no FSTYPE dependency)
- `02-generate-profile.sh` parses `=== BLKID ===` via `sed` for `TYPE="btrfs"` (root) and `TYPE="vfat"` (EFI)
- Fallback to `<DISK_DEVICE>` placeholders when nothing is found — explicit failure is better than wrong device

### 2. Remove hardcoded nvme fallbacks (stages/02-generate-profile.sh)
```bash
# Before (WRONG — assumes only nvme hosts exist):
_disk="/dev/nvme0n1"
_efi_dev="/dev/nvme0n1p1"
_root_dev="/dev/nvme0n1p2"

# After (correct — makes the problem obvious):
_disk="<DISK_DEVICE>"
_efi_dev="<EFI_PARTITION>"
_root_dev="<ROOT_PARTITION>"
```

### 3. Full suppression sweep (all files)
Every instance of `2>/dev/null`, `|| true`, `|| echo "N/A"`, `|| log_warn` removed and replaced with:
- `if command -v tool; then ... else echo "MISSING: tool"; fi`
- `if ! cmd; then log_warn "..."; fi`
- Explicit nested `if` blocks for diagnostic commands

### 4. Modern Arch ISO network setup (stages/04-prepare.sh)
`dhcpcd` was removed from Arch ISO. Replaced with `systemd-networkd` first, `dhcpcd` fallback.

### 5. VM disk setup reliability (vm-test/run-qemu.sh)
- **9p VirtFS**: `-virtfs local,path=${SCRIPT_DIR}/shared,mount_tag=hostshare,...` → `mkdir -p` ensures directory exists before QEMU starts
- **SSH hostfwd**: `-netdev user,id=net0,hostfwd=tcp::2222-:22`
- **Headless fallback**: `QEMU_HEADLESS=true` uses `-display none -nographic -serial mon:stdio`
- Subvolume creation uses `mktemp -d /dev/shm/zenbook-btrfs.XXXXXX` instead of `/tmp`

## Diagnostic Checklist

When a stage fails in the QEMU VM:
1. Run `blkid` — if `/dev/vda*` partitions show no `TYPE=` field, the disk was formatted on the host but signatures didn't persist, or the VM's kernel hasn't attached filesystem drivers to the virtio disk
2. Run `lsblk -f` inside the VM — if FSTYPE columns are empty, same issue as above
3. Check `/sys/firmware/efi` exists — VM must boot with UEFI firmware (OVMF)
4. Check network — `ping archlinux.org` after `systemctl start systemd-networkd`
5. Check profile env vars — `env | grep PROFILE_storage` → verify `PROFILE_storage__partitions__*__device` matches actual devices
6. If disk image was reused from a prior incomplete run, delete it: `rm vm-test/zenbook-test.img vm-test/OVMF_VARS.fd` then re-run
