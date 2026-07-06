#!/usr/bin/env python3
import socket, time, sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/tmp/qemu-monitor.sock')
s.recv(1024)

M = {
    '\n': 'ret', ' ': 'spc', '/': 'slash', '.': 'dot', '-': 'minus',
    ':': 'shift-semicolon', "'": "apostrophe", '|': 'shift-backslash',
    '=': 'equal', '#': 'shift-3', '!': 'shift-1', '@': 'shift-2',
    '$': 'shift-4', '%': 'shift-5', '^': 'shift-6', '&': 'shift-7',
    '*': 'shift-8', '(': 'shift-9', ')': 'shift-0', '_': 'shift-minus',
    '+': 'shift-equal', '{': 'shift-bracket_left', '}': 'shift-bracket_right',
    '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
    ';': 'semicolon', '"': 'shift-apostrophe', '<': 'shift-comma',
    '>': 'shift-dot', '?': 'shift-slash', '~': 'shift-grave_accent',
    '`': 'grave_accent', '\t': 'tab',
}

def sendkey(k):
    s.send(f"sendkey {k}\n".encode())
    time.sleep(0.02)

def type(t):
    for ch in t:
        if ch in M:
            sendkey(M[ch])
        elif 'A' <= ch <= 'Z':
            sendkey(f"shift-{ch.lower()}")
        elif 'a' <= ch <= 'z' or '0' <= ch <= '9':
            sendkey(ch)
        else:
            pass  # skip unknown chars

def cmd(text, delay=3):
    for line in text.split('\n'):
        type(line + '\n')
        time.sleep(delay)

# Wait for ISO boot
print("Waiting 60s for Arch ISO to boot...")
time.sleep(60)

print("Network + SSH setup...")
cmd("dhcpcd", 5)
cmd("systemctl start sshd")
cmd("echo 'root:root' | chpasswd")
cmd("sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config")
cmd("systemctl restart sshd")
print("SSH should be ready")
s.close()
