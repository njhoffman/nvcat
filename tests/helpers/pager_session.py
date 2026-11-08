#!/usr/bin/python3
"""Drive nvcat's built-in Neovim pager in a pseudo-terminal.

Usage: pager_session.py SCENARIO FILE [NVCAT-ARGS...]
FILE "-" sends the file named by $STDIN_FILE on nvcat's stdin. The document must be taller than the 20-row terminal and contain the markers PAGER_TOP (a level-one heading on the
first line), PAGER_MIDDLE, and PAGER_BOTTOM (on the last line). Scenarios:
  keys    first screen shows the rendered heading, not '# PAGER_TOP'; G reaches PAGER_BOTTOM; g g returns to
          the top; /PAGER_MIDDLE finds it; space pages down; q exits 0
  resize  a narrower terminal makes Neovim redraw; q still exits 0
  term    SIGTERM to nvcat while the pager is open exits 130
  hup     SIGHUP to nvcat while the pager is open exits non-zero
  follow  --follow: appended lines appear, scrolling up pauses, G resumes, truncation reloads
  warning a broken lua highlights query is reported on screen, the file is colored, q exits 0
  shows   the screen shows the text in $PAGER_EXPECT (from a pager_init, say); q exits 0
Every scenario also checks that no Neovim started by this checkout outlives nvcat.
Prints "ok" on success; otherwise the reason and the tail of the screen output, and exits 1.
"""

import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

from common import ROOT, embedded_nvims

ROWS, COLUMNS = 20, 80
scenario, path, *extra = sys.argv[1:]
baseline = embedded_nvims()
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))


def session():
  os.setsid()
  fcntl.ioctl(slave, termios.TIOCSCTTY, 0)


environment = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor")
for name in ["NVIM", "FZF_PREVIEW_COLUMNS", "FZF_PREVIEW_LINES"]:
  environment.pop(name, None)
# FILE "-" reads the document from $STDIN_FILE on a pipe, so keys must come from /dev/tty.
document = open(os.environ["STDIN_FILE"], "rb") if path == "-" else slave
process = subprocess.Popen([str(ROOT / "nvcat"), "--pager", "nvim", *extra, path], env=environment,
                           stdin=document, stdout=slave, stderr=slave, preexec_fn=session)
os.close(slave)
captured = bytearray()
answered = {}
# Terminal queries Neovim's TUI sends at start-up; answering them avoids its "did not respond" warnings.
ANSWERS = {b"\x1b]11;?": b"\x1b]11;rgb:0000/0000/0000\x1b\\", b"\x1b[c": b"\x1b[?62;22c",
           b"\x1b[5n": b"\x1b[0n", b"\x1b[6n": b"\x1b[1;1R"}


def plain(data):
  text = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", bytes(data))
  # Colors (SGR) and charset selection (xterm's sgr0 is "\x1b(B\x1b[m") sit between characters of one word;
  # drop them. Other CSI sequences move the cursor, so they become a space.
  text = re.sub(rb"\x1b[()*+][0-9A-Za-z]|\x1b\[[0-9;:]*m", b"", text)
  text = re.sub(rb"\x1b\[[0-9;?<>=! ]*[a-zA-Z@`~]", b" ", text)
  return re.sub(rb"\x1b.", b"", text).decode(errors="replace")


def read(timeout):
  if not select.select([master], [], [], timeout)[0]:
    return True
  try:
    chunk = os.read(master, 65536)
  except OSError:
    return False
  captured.extend(chunk)
  for query, answer in ANSWERS.items():
    # Count in everything read so far: a query can be split across reads.
    if captured.count(query) > answered.get(query, 0):
      answered[query] = captured.count(query)
      os.write(master, answer)
  return bool(chunk)


def fail(reason):
  print(reason)
  print(plain(captured)[-1500:])
  if process.poll() is None:
    process.kill()
  sys.exit(1)


def until(marker, start, what, timeout=15):
  deadline = time.monotonic() + timeout
  while marker not in plain(captured[start:]):
    if time.monotonic() > deadline or not read(0.1):
      fail(f"timed out waiting for {what}")


def quiet(seconds=0.4):
  """Read until the terminal has been idle for the given time."""
  last = time.monotonic()
  while time.monotonic() - last < seconds:
    size = len(captured)
    if not read(0.05):
      return
    if len(captured) != size:
      last = time.monotonic()


def press(keys):
  start = len(captured)
  os.write(master, keys.encode())
  return start


def finish(expected):
  deadline = time.monotonic() + 10
  while process.poll() is None:
    if time.monotonic() > deadline:
      fail("nvcat did not exit")
    read(0.1)
  if not expected(process.returncode):
    fail(f"unexpected exit status {process.returncode}")
  deadline = time.monotonic() + 5
  while embedded_nvims() - baseline:
    if time.monotonic() > deadline:
      fail(f"Neovim left running: {sorted(embedded_nvims() - baseline)}")
    time.sleep(0.05)


if scenario == "no-color":
  until("PAGER_TOP", 0, "the first screen")
  quiet()
  if re.search(rb"\x1b\[[0-9;:]*(38|48)[;:]", captured):
    fail("the pager shows color")
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

if scenario == "unsafe-links":
  # A URL's control bytes must not reach the terminal, and clean links still must.
  until("END_LINKS", 0, "the document")
  quiet()
  document = Path(path).read_bytes()
  for uri in [b"http://ok.example/", b"http://sp.example/a%20b", b"http://ac.example/caf%C3%A9"]:
    if uri.split(b"/")[2] in document and b";" + uri not in captured:
      fail(f"no OSC 8 sequence for {uri.decode()}")
  if b"<http://sp" in captured:
    fail("a URL kept its angle brackets")
  if b"javascript:" in captured:
    fail("a link with a scheme outside link_schemes became a hyperlink")
  if b"PWNED" in captured or b"\x1b]0;" in captured:
    fail("a URL's control bytes reached the terminal")
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

if scenario == "shows":
  # Any start, --follow's included: the text may appear wherever the pager opens.
  until(os.environ["PAGER_EXPECT"], 0, repr(os.environ["PAGER_EXPECT"]))
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

if scenario == "follow-open":
  # --follow on a large file opens at its end.
  until("PAGER_BOTTOM", 0, "the end of the file", timeout=40)
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

if scenario == "follow-colors":
  # A reload must keep a non-Markdown buffer's highlighting: the marker's color stays the same after a line is
  # appended. The marker is resent because the appended line above it scrolls the view.
  def color_of(marker):
    found = re.findall(r"\x1b\[([0-9;]*)m[^\x1b]*" + marker, captured.decode("utf-8", "replace"))
    return found[-1] if found else None

  until("KEEP_COLOR", 0, "the first screen")
  quiet()
  before = color_of("KEEP_COLOR")
  with open(path) as handle:
    original = handle.read()
  start = len(captured)
  with open(path, "w") as handle:
    handle.write('["APPENDED_LINE",\n' + original.lstrip("["))
  until("APPENDED_LINE", start, "the reloaded file", timeout=5)
  quiet()
  after = color_of("KEEP_COLOR")
  if not before or before != after:
    fail(f"the color changed on reload: {before!r} -> {after!r}")
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

if scenario == "follow":
  # --follow on a file taller than the screen: starts at the end, shows appended lines, pauses while the
  # cursor is above the last line, resumes on G, and survives truncation.
  # Markers start differently: Neovim redraws only changed cells, so a shared prefix may never be resent.
  def append(text, mode="a"):
    with open(path, mode) as handle:
      handle.write(text + "\n")

  until("PAGER_BOTTOM", 0, "the end of the file")
  quiet()
  start = len(captured)
  append("APPENDED_FIRST")
  until("APPENDED_FIRST", start, "the first appended line", timeout=5)
  quiet()
  if re.search(r"- item \d", plain(captured[start:])):
    fail("the reloaded Markdown shows raw list markers")
  press("k" * 5)
  quiet()
  start = len(captured)
  append("\n".join(f"filler {i}" for i in range(30)) + "\nZEBRA_PAUSED")
  deadline = time.monotonic() + 2.5
  while time.monotonic() < deadline:
    read(0.1)
  if "ZEBRA_PAUSED" in plain(captured[start:]):
    fail("the view followed the file while the cursor was above the last line")
  start = press("G")
  until("ZEBRA_PAUSED", start, "the appended lines after G")
  quiet()
  start = len(captured)
  append("QUOKKA_REWRITTEN", "w")
  until("QUOKKA_REWRITTEN", start, "the rewritten file", timeout=5)
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

if scenario == "warning":
  # A broken highlights query (NVCAT_PARSER_DIR set by the caller): the document still opens with regex
  # syntax, the warning is shown as a notification, and the keys still work.
  until("PAGER_TOP", 0, "the first screen")
  quiet()
  screen = re.sub(r"\s+", " ", plain(captured))
  if "nvcat: lua highlights query failed (details: nvcat --check)" not in screen:
    fail("no query warning on the screen")
  if "Press ENTER" in screen:
    fail("the warning needs a key press")
  if b"\x1b[38;2;" not in captured:
    fail("no syntax colors")
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

if scenario == "init-key":
  # pager_init maps f to G, where the pager's own f pages down: the bottom marker is not one page away.
  until("PAGER_TOP", 0, "the first screen")
  quiet()
  until("PAGER_BOTTOM", press("f"), "pager_init's mapping of f")
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

if scenario in ("init-broken", "init-broken-syntax"):
  until("PAGER_TOP", 0, "the first screen")
  quiet()
  screen = re.sub(r"\s+", " ", plain(captured))
  if "pager_init:" not in screen:
    fail("no pager_init warning on the screen")
  if scenario == "init-broken" and ("BROKEN_INIT" not in screen or "second line" in screen):
    fail("the warning is not the error's first line")
  if "Press ENTER" in screen:
    fail("the warning needs a key press")
  until("PAGER_BOTTOM", press("G"), "G after the warning")
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

if scenario == "regex":
  # --syntax regex: Vim's Markdown syntax keeps the raw heading marker. Wait for a list item, which is drawn
  # after the heading.
  until("item 5", 0, "the first screen")
  quiet()
  if "# PAGER" not in plain(captured):
    fail("--syntax regex still rendered the heading")
  press("q")
  finish(lambda status: status == 0)
  print("ok")
  sys.exit(0)

until("PAGER_TOP", 0, "the first screen")
quiet()
first = plain(captured)
if "# PAGER_TOP" in first:
  fail("the cursor line shows raw Markdown (anti_conceal)")
if "PAGER_BOTTOM" in first:
  fail("the bottom marker is on the first screen; the file is too short")

if scenario == "keys":
  until("PAGER_BOTTOM", press("G"), "G to reach the bottom")
  quiet()
  until("PAGER_TOP", press("gg"), "gg to return to the top")
  quiet()
  until("PAGER_MIDDLE", press("/PAGER_MIDDLE\r"), "a search")
  quiet()
  press("gg")
  quiet()
  start = press(" ")
  quiet()
  if "PAGER_TOP" in plain(captured[start:]) or len(captured) == start:
    fail("space did not page down")
  press("q")
  finish(lambda status: status == 0)
elif scenario == "resize":
  start = len(captured)
  fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, 40, 0, 0))
  process.send_signal(signal.SIGWINCH)
  quiet(0.8)
  if len(captured) == start:
    fail("no redraw after the terminal was resized")
  press("q")
  finish(lambda status: status == 0)
elif scenario == "term":
  process.send_signal(signal.SIGTERM)
  finish(lambda status: status == 130)
elif scenario == "hup":
  process.send_signal(signal.SIGHUP)
  finish(lambda status: status != 0)
else:
  fail(f"unknown scenario {scenario}")
print("ok")
