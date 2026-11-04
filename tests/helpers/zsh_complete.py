#!/usr/bin/python3
"""Press Tab in a real interactive zsh with nvcat's completion script loaded, and print what each line became.

Usage: zsh_complete.py SCRIPT LINE... Each output line is the command line after Tab."""

import fcntl
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time

script, *typed = sys.argv[1:]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))


def session():
  os.setsid()
  fcntl.ioctl(slave, termios.TIOCSCTTY, 0)


process = subprocess.Popen(["zsh", "-f", "-i"], stdin=slave, stdout=slave, stderr=slave, preexec_fn=session,
                           env=dict(os.environ, TERM="xterm", PS1="READY> "))
os.close(slave)


def read_until_quiet(seconds=0.5, limit=20):
  output, last, start = bytearray(), time.monotonic(), time.monotonic()
  while time.monotonic() - last < seconds and time.monotonic() - start < limit:
    if select.select([master], [], [], 0.05)[0]:
      output += os.read(master, 65536)
      last = time.monotonic()
  return output.decode(errors="replace")


# The widget prints the buffer itself, so nothing has to be scraped from redraws.
os.write(master, (f"bindkey -e; autoload -Uz compinit; compinit -u -D; source {script}; unsetopt zle_bracketed_paste; "
                  "nvcat_dump() { zle -I; print -r -- \"BUFFER=$BUFFER\"; BUFFER=; }; zle -N nvcat_dump; "
                  "bindkey '^X' nvcat_dump\n").encode())
read_until_quiet(1.5)
for line in typed:
  os.write(master, line.encode())
  read_until_quiet(0.2)
  os.write(master, b"\t")
  read_until_quiet(1.0)
  os.write(master, b"\x18")
  output = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", read_until_quiet(0.5))
  found = re.findall(r"BUFFER=(.*?)\r?$", output, re.M)
  print(found[-1] if found else "(nothing)")
process.kill()
process.wait()
