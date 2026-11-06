"""Helpers shared by the benchmark scripts: the samples and modes, the load gate, run metadata, and git."""

import datetime
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SAMPLES = ["small", "medium", "large", "code"]
COLUMNS, LINES = 100, 40
# fzf: no size flags; nvcat takes the size from fzf's variables and emits one viewport, as in a preview.
MODES = {
  "complete": (["--all", "--budget", "0"], {}),
  "viewport": (["--lines", str(LINES)], {}),
  "fzf": ([], {"FZF_PREVIEW_COLUMNS": str(COLUMNS), "FZF_PREVIEW_LINES": str(LINES)}),
}


def render_command(root, sample, mode, timeout, extra=()):
  """The command line and environment rendering a sample in a mode with the nvcat in root."""
  flags, variables = MODES[mode]
  size = [] if variables else ["--columns", str(COLUMNS)]
  command = [str(Path(root) / "nvcat"), "--paging=never", *size, "--timeout", str(timeout), *extra,
             *flags, str(HERE / f"{sample}.md")]
  environment = {name: value for name, value in os.environ.items()
                 if name not in ("FZF_PREVIEW_COLUMNS", "FZF_PREVIEW_LINES", "NVIM")}
  environment.update(variables)
  return command, environment


def load1():
  return float(Path("/proc/loadavg").read_text().split()[0])


def wait_for_load(limit, max_wait, interval):
  deadline = time.monotonic() + max_wait
  while (current := load1()) > limit:
    if time.monotonic() >= deadline:
      return False
    print(f"load {current:.2f} > {limit:.2f}; waiting {interval:.0f}s", file=sys.stderr, flush=True)
    time.sleep(interval)
  return True


def git(*arguments):
  return subprocess.run(["git", "-C", str(ROOT), *arguments], capture_output=True, text=True).stdout.strip()


def metadata():
  """Date, version, commit (with -dirty for uncommitted tracked changes), load, and the Neovim version."""
  dirty = "-dirty" if git("status", "--porcelain", "--untracked-files=no") else ""
  return {
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
    "version": (ROOT / "VERSION").read_text().strip(),
    "commit": git("rev-parse", "--short", "HEAD") + dirty,
    "load1": f"{load1():.2f}",
    "nvim": subprocess.run(["nvim", "--version"], capture_output=True, text=True).stdout.splitlines()[0],
  }
