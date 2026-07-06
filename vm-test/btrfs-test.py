#!/usr/bin/env python3
"""Automate btrfs-btrfs reinstall: boot ISO, mount 9p, run stages."""
import socket
import time
import sys

KEYS = {
    'a': 'a', 'b': 'b', 'c': 'c', 'd': 'd', 'e': 'e', 'f': 'f',
    'g': 'g', 'h': 'h', 'i': 'i', 'j': 'j', 'k': 'k', 'l': 'l',
    'm': 'm', 'n': 'n', 'o': 'o', 'p': 'p', 'q': 'q', 'r': 'r',
    's': 's', 't': 't', 'u': 'u', 'v': 'v', 'w': 'w', 'x': 'x',
    'y': 'y', 'z': 'z',
    '0': '0', '1': '1', '2': '2', '3': '3', '4': '4',
    '5': '5', '6': '6', '7': '7', '8': '8', '9': '9',
    '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right',
    '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe',
    ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent',
    ' ': 'spc', '\n': 'ret', '\t': 'tab',
}

SHIFT_KEYS = {
    'A': 'a', 'B': 'b', 'C': 'c', 'D': 'd', 'E': 'e', 'F': 'f',
    'G': 'g', 'H': 'h', 'I': 'i', 'J': 'j', 'K': 'k', 'L': 'l',
    'M': 'm', 'N': 'n', 'O': 'o', 'P': 'p', 'Q': 'q', 'R': 'r',
    'S': 's', 'T': 't', 'U': 'u', 'V': 'v', 'W': 'w', 'X': 'x',
    'Y': 'y', 'Z': 'z',
    '!': '1', '@': '2', '#': '3', '$': '4', '%': '5',
    '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
    '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right',
    '|': 'backslash', ':': 'semicolon', '"': 'apostrophe',
    '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent',
}

def send_key(s, key):
    if key in KEYS:
        s.send(f"sendkey {KEYS[key]}\n".encode())
    elif key in SHIFT_KEYS:
        s.send(f"sendkey shift-{SHIFT_KEYS[key]}\n".encode())
    else:
        print(f"Unknown key: {key!r}")
    time.sleep(0.02)

def type_string(s, text):
    for ch in text:
        send_key(s, ch)

def main():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect('/tmp/qemu-monitor.sock')
    s.recv(1024)
    
    phase = sys.argv[1] if len(sys.argv) > 1 else "all"
    
    if phase in ("wait", "all"):
        print("[Phase] Waiting for ISO boot...")
        time.sleep(50)
    
    if phase in ("ssh", "all"):
        print("[Phase] Setting up SSH on ISO...")
        # Type commands to set up networking and SSH
        type_string(s, "dhcpcd\n")
        time.sleep(5)
        type_string(s, "systemctl start sshd\n")
        time.sleep(2)
        type_string(s, "echo 'root:root' | chpasswd\n")
        time.sleep(1)
        type_string(s, "sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config\n")
        time.sleep(1)
        type_string(s, "systemctl restart sshd\n")
        time.sleep(2)
        print("[OK] SSH should be available on port 2222")
    
    if phase in ("mount", "all"):
        print("[Phase] Mounting 9p and running stages...")
        type_string(s, "mount -t 9p -o trans=virtio hostshare /mnt/arch-deploy\n")
        time.sleep(2)
        type_string(s, "cd /mnt/arch-deploy\n")
        time.sleep(1)
    
    s.close()
    print("Done")

if __name__ == '__main__':
    main()
