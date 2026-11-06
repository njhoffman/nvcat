#!/usr/bin/python3
"""Drive real fzf over files with `nvcat {}` as the previewer and NVCAT_WORKER=1 inherited, moving through them quickly,
so that fzf kills previews in progress. Usage: worker_fzf.py MARKER FILE..., MARKER being in the last file."""
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time

marker, files = sys.argv[1].encode(), sys.argv[2:]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))


def session():
  os.setsid()
  fcntl.ioctl(slave, termios.TIOCSCTTY, 0)


environment = dict(os.environ, TERM="xterm-256color", FZF_DEFAULT_OPTS="", FZF_DEFAULT_OPTS_FILE="/dev/null")
fzf = subprocess.Popen(["fzf", "--no-sort", "--no-mouse", "--layout=reverse", "--preview", "./nvcat {}",
                        "--preview-window", "right:75%:nowrap", "--bind", "esc:abort"],
                       env=environment, stdin=subprocess.PIPE, stdout=slave, stderr=slave, preexec_fn=session)
os.close(slave)
fzf.stdin.write(("\n".join(files) + "\n").encode())
fzf.stdin.close()
captured = bytearray()


def drain(seconds):
  end = time.monotonic() + seconds
  while time.monotonic() < end:
    if select.select([master], [], [], 0.02)[0]:
      try:
        captured.extend(os.read(master, 65536))
      except OSError:
        return


drain(1.5)  # The worker starts on the first preview, which renders by itself.
for _ in range(3):  # Down and back quickly: fzf kills what is running.
  for key in [b"\x1b[B"] * (len(files) - 1) + [b"\x1b[A"] * (len(files) - 1):
    os.write(master, key)
    drain(0.03)
for key in [b"\x1b[B"] * (len(files) - 1):
  os.write(master, key)
  drain(0.03)
drain(1.5)
start = len(captured)
os.write(master, b"\x0c")  # A full repaint, so that fzf's cell updates cannot split the marker.
drain(1)
shown = marker in captured[start:]
os.write(master, b"\x1b")
deadline = time.monotonic() + 10
while fzf.poll() is None and time.monotonic() < deadline:
  drain(0.1)
if fzf.poll() is None:
  fzf.kill()
  sys.exit("fzf did not exit")
sys.exit(0 if shown else f"the preview of the last file did not show {marker.decode()}")
