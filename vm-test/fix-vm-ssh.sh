#!/bin/bash
# Fix VM SSH access and test connectivity
set -e

echo "=== Step 1: Enable sshd ==="
if [[ ! -L /mnt/vm-fix/etc/systemd/system/multi-user.target.wants/sshd.service ]]; then
    sudo mkdir -p /mnt/vm-fix/etc/systemd/system/multi-user.target.wants
    sudo ln -sf /usr/lib/systemd/system/sshd.service /mnt/vm-fix/etc/systemd/system/multi-user.target.wants/sshd.service
    echo "  sshd enabled"
else
    echo "  sshd already enabled"
fi

echo "=== Step 2: Create network config ==="
if [[ ! -f /mnt/vm-fix/etc/systemd/network/20-wired.network ]]; then
    sudo mkdir -p /mnt/vm-fix/etc/systemd/network
    sudo tee /mnt/vm-fix/etc/systemd/network/20-wired.network >/dev/null <<'EOF'
[Match]
Name=en*

[Network]
DHCP=yes
EOF
    echo "  Network config created"
else
    echo "  Network config exists"
fi

echo "=== Step 3: Ensure PermitRootLogin ==="
if ! grep -q "^PermitRootLogin" /mnt/vm-fix/etc/ssh/sshd_config 2>/dev/null; then
    echo "PermitRootLogin yes" | sudo tee -a /mnt/vm-fix/etc/ssh/sshd_config >/dev/null
    echo "  PermitRootLogin added"
else
    echo "  PermitRootLogin already set"
fi

echo "=== Step 4: Unmount ==="
sudo umount /mnt/vm-fix 2>/dev/null || true
sudo losetup -d /dev/loop1 2>/dev/null || true

echo "=== Step 5: Wait for VM network (10s) ==="
sleep 10

echo "=== Step 6: Test SSH ==="
expect -c '
set timeout 20
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@localhost "echo VM_REACHABLE"
expect "password:"
send "root\r"
expect {
  "VM_REACHABLE" { puts "\nSUCCESS: VM is reachable"; exit 0 }
  timeout { puts "\nTIMEOUT"; exit 1 }
  eof { puts "\nEOF"; exit 1 }
}
'
