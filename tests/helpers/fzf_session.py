#!/usr/bin/python3
"""Drive fzf in a pseudo-terminal with nvcat as the previewer.

Checks preview scrolling to the bottom and back, moving between files, a re-render with smaller dimensions
after a terminal resize, rapid selection changes, and that no embedded Neovim outlives fzf.
Usage: fzf_session.py FILE... (at least three; each must contain <NAME>_TOP and <NAME>_BOTTOM markers,
where the markers are given as MARKERS=TOP1,BOTTOM1;TOP2,BOTTOM2;... in the environment).
"""

import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

from common import ROOT, embedded_nvims

files = [str(Path(name).resolve()) for name in sys.argv[1:]]
markers = [pair.split(",") for pair in os.environ["MARKERS"].split(";")]
assert len(files) >= 3 and len(markers) == len(files), "need three files and a marker pair for each"
baseline = embedded_nvims()
work = Path(tempfile.mkdtemp(prefix="nvcat-fzf-"))
log = work / "dimensions.jsonl"
wrapper = work / "preview"
wrapper.write_text(f"""#!/usr/bin/python3
import json, os, sys
with open({str(log)!r}, "a") as handle:
  handle.write(json.dumps({{"columns": os.environ.get("FZF_PREVIEW_COLUMNS"),
                            "lines": os.environ.get("FZF_PREVIEW_LINES"), "path": sys.argv[1]}}) + "\\n")
os.execv({str(ROOT / 'nvcat')!r}, ["nvcat", "--all", sys.argv[1]])
""")
wrapper.chmod(0o700)
log.write_text("")

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))


def session():
  os.setsid()
  fcntl.ioctl(slave, termios.TIOCSCTTY, 0)


environment = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", FZF_DEFAULT_OPTS="",
                   FZF_DEFAULT_OPTS_FILE="/dev/null", FZF_DEFAULT_COMMAND="")
environment.pop("NVIM", None)
fzf = subprocess.Popen(
  ["fzf", "--no-sort", "--no-mouse", "--layout=reverse", "--preview", f"{wrapper} {{}}",
   "--preview-window", "right:75%:nowrap",
   "--bind", "esc:abort,resize:refresh-preview,ctrl-e:preview-bottom,ctrl-y:preview-top"],
  env=environment, stdin=subprocess.PIPE, stdout=slave, stderr=slave, preexec_fn=session)
os.close(slave)
fzf.stdin.write(("\n".join(files) + "\n").encode())
fzf.stdin.close()
captured = bytearray()


def read(timeout):
  if select.select([master], [], [], timeout)[0]:
    try:
      chunk = os.read(master, 65536)
    except OSError:
      return False
    captured.extend(chunk)
    return bool(chunk)
  return True


def until(marker, start, what):
  deadline = time.monotonic() + 15
  while marker.encode() not in captured[start:]:
    if time.monotonic() > deadline or not read(0.1):
      raise SystemExit(f"fzf preview did not show {marker} ({what})")
  print(f"ok {what}", flush=True)


def links():
  """The OSC 8 sequence of the link in the second file must come through fzf with its id and URI."""
  deadline = time.monotonic() + 15
  while not re.search(rb"\x1b\]8;id=\d+;https?://", captured):
    if time.monotonic() > deadline or not read(0.1):
      raise SystemExit("fzf preview dropped the OSC 8 hyperlinks")
  print("ok fzf passes OSC 8 hyperlinks with their id", flush=True)


def press(keys):
  """Send keys, then Ctrl-L (fzf's clear-screen): fzf repaints only changed cells, which can split a marker
  across escape sequences, so force a full repaint before searching the output."""
  os.write(master, keys)
  time.sleep(0.3)
  offset = len(captured)
  os.write(master, b"\x0c")
  return offset


try:
  until(markers[0][0], 0, "first file previewed")
  until(markers[0][1], press(b"\x05"), "preview scrolled to the bottom")
  until(markers[0][0], press(b"\x19"), "preview scrolled back to the top")
  until(markers[1][0], press(b"\x1b[B"), "second file previewed")
  links()
  until(markers[2][0], press(b"\x1b[B"), "third file previewed")
  before = len(log.read_text().splitlines())
  fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
  os.kill(fzf.pid, signal.SIGWINCH)
  deadline = time.monotonic() + 15
  while len(log.read_text().splitlines()) <= before:
    if time.monotonic() > deadline:
      raise SystemExit("preview was not re-rendered after the terminal resize")
    read(0.1)
  entries = [json.loads(line) for line in log.read_text().splitlines()]
  assert int(entries[-1]["columns"]) < int(entries[0]["columns"]), entries
  assert int(entries[-1]["lines"]) < int(entries[0]["lines"]), entries
  print("ok preview re-rendered smaller after resize", flush=True)
  for key in [b"\x1b[A", b"\x1b[A", b"\x1b[B", b"\x1b[B", b"\x1b[A"]:
    os.write(master, key)
    time.sleep(0.04)
  time.sleep(1)
  until(markers[1][0], press(b""), "rapid selection changes settle on the second file")
  os.write(master, b"\x1b")
  fzf.wait(timeout=10)
  deadline = time.monotonic() + 5
  while (leftover := embedded_nvims() - baseline) and time.monotonic() < deadline:
    time.sleep(0.1)
  assert not leftover, f"embedded Neovim still running after fzf exited: {sorted(leftover)}"
  print("ok no embedded Neovim left after fzf exits", flush=True)
finally:
  if fzf.poll() is None:
    fzf.kill()
  os.close(master)
