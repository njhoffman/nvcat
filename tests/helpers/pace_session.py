#!/usr/bin/python3
"""Run nvcat on a pseudo-terminal and report what a person would see, as JSON: exit status, the seconds from the first
line of output to the last, the output, and whether a Neovim is left. Usage: pace_session.py [--interrupt] ARGS..."""

import json
import os
import pty
import select
import signal
import subprocess
import sys
import time

from common import ROOT, embedded_nvims

arguments = sys.argv[1:]
interrupt = arguments[0] == "--interrupt"
if interrupt:
  arguments = arguments[1:]
baseline = embedded_nvims()
master, slave = pty.openpty()
environment = {name: value for name, value in os.environ.items() if name not in ("NVIM", "FZF_PREVIEW_COLUMNS",
                                                                                 "FZF_PREVIEW_LINES")}
environment.update(TERM="xterm-256color", COLORTERM="truecolor", **dict(item.split("=", 1) for item in
                                                                        os.environ.get("SESSION_ENV", "").split()))


def session():
  os.setsid()
  import fcntl, termios
  fcntl.ioctl(slave, termios.TIOCSCTTY, 0)


process = subprocess.Popen([str(ROOT / "nvcat"), *arguments], env=environment, stdin=slave, stdout=slave, stderr=slave,
                           preexec_fn=session)
os.close(slave)
captured = bytearray()
first = last = None
sent = False
deadline = time.monotonic() + 60
while time.monotonic() < deadline:
  if select.select([master], [], [], 0.05)[0]:
    try:
      chunk = os.read(master, 65536)
    except OSError:
      break
    if not chunk:
      break
    last = time.monotonic()
    first = first or last
    captured.extend(chunk)
    if interrupt and not sent and captured.count(b"\n") >= 2:
      os.write(master, b"\x03")
      sent = True
  elif process.poll() is not None:
    break
if process.poll() is None:
  try:
    process.wait(timeout=5)
  except subprocess.TimeoutExpired:
    process.send_signal(signal.SIGKILL)
    process.wait()
time.sleep(0.2)
print(json.dumps({"status": process.returncode, "elapsed": (last - first) if first else 0,
                  "output": captured.decode(errors="replace").replace("\r\n", "\n"),
                  "left": sorted(embedded_nvims() - baseline)}))
