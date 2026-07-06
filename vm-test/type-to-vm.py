#!/usr/bin/env python3
"""Send keystrokes to QEMU VM via monitor socket."""
import socket
import time
import sys

KEY_MAP = {
    'a':'a','b':'b','c':'c','d':'d','e':'e','f':'f','g':'g','h':'h',
    'i':'i','j':'j','k':'k','l':'l','m':'m','n':'n','o':'o','p':'p',
    'q':'q','r':'r','s':'s','t':'t','u':'u','v':'v','w':'w','x':'x',
    'y':'y','z':'z','0':'0','1':'1','2':'2','3':'3','4':'4','5':'5',
    '6':'6','7':'7','8':'8','9':'9',
}

SHIFT_MAP = {
    'A':'a','B':'b','C':'c','D':'d','E':'e','F':'f','G':'g','H':'h',
    'I':'i','J':'j','K':'k','L':'l','M':'m','N':'n','O':'o','P':'p',
    'Q':'q','R':'r','S':'s','T':'t','U':'u','V':'v','W':'w','X':'x',
    'Y':'y','Z':'z',
    '!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8',
    '(':'9',')':'0','_':'minus','+':'equal','{':'bracket_left','}':'bracket_right',
    '|':'backslash',':':'semicolon','"':'apostrophe','<':'comma','>':'dot',
    '?':'slash','~':'grave_accent',
}

SPECIAL = {
    '\n': 'ret', ' ': 'spc', '\t': 'tab',
    '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right',
    '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe',
    ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent',
}

def send_char(s, ch):
    if ch in SPECIAL:
        s.send(f"sendkey {SPECIAL[ch]}\n".encode())
    elif ch in KEY_MAP:
        s.send(f"sendkey {KEY_MAP[ch]}\n".encode())
    elif ch in SHIFT_MAP:
        s.send(f"sendkey shift-{SHIFT_MAP[ch]}\n".encode())
    else:
        print(f"SKIP: {ch!r}")
    time.sleep(0.03)

def type_text(s, text, delay=3):
    for ch in text:
        send_char(s, ch)
    time.sleep(delay)

def main():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect('/tmp/qemu-monitor.sock')
    s.recv(1024)

    print("Boot ISO, waiting for login prompt...")
    time.sleep(50)

    print("Starting DHCP...")
    type_text(s, "dhcpcd\n", 5)

    print("Starting SSH...")
    type_text(s, "systemctl start sshd\n", 2)

    print("Setting root password...")
    type_text(s, "echo 'root:root' | chpasswd\n", 1)

    print("Enabling PermitRootLogin...")
    type_text(s, "sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config\n", 1)

    print("Restarting SSH...")
    type_text(s, "systemctl restart sshd\n", 3)

    print("Mount 9p share...")
    type_text(s, "mount -t 9p -o trans=virtio hostshare /mnt/arch-deploy\n", 2)
    
    print("Done. SSH should be ready.")
    s.close()

if __name__ == '__main__':
    main()
