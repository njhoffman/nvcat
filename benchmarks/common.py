"""Helpers shared by the benchmark scripts: the samples and modes, the load gate, run metadata, and git."""

import contextlib
import datetime
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
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

# Previews from a worker of the run's own, in fzf's environment; the second has nvcat-dispatch's flags.
WORKER_MODES = {
  "worker": [],
  "worker-all": ["--all", "--paging=never", "--budget=20", "--filetype", "markdown", "--"],
}


def render_command(root, sample, mode, timeout, extra=()):
  """The command line and environment rendering a sample in a mode with the nvcat in root."""
  flags, variables = MODES[mode]
  size = [] if variables else ["--columns", str(COLUMNS)]
  command = [str(Path(root) / "nvcat"), "--paging=never", *size, "--timeout", str(timeout), *extra,
             *flags, str(HERE / f"{sample}.md")]
  environment = {name: value for name, value in os.environ.items()
                 if name not in ("FZF_PREVIEW_COLUMNS", "FZF_PREVIEW_LINES", "NVIM", "NVCAT_WORKER")}
  environment.update(variables)
  return command, environment


class Worker:
  """A worker of its own, reached as fzf reaches it: the nvcat command with NVCAT_WORKER=1."""

  def __init__(self, environment=None):
    self.environment = environment

  def __enter__(self):
    self.directory = tempfile.TemporaryDirectory(prefix="nvcat-worker-")
    os.chmod(self.directory.name, 0o700)
    self.socket = str(Path(self.directory.name) / "worker.socket")
    self.process = subprocess.Popen([sys.executable, str(ROOT / "nvcat_worker.py"), self.socket],
                                    env={**os.environ, **(self.environment or {})})
    deadline = time.monotonic() + 10
    while not Path(self.socket).exists():
      assert time.monotonic() < deadline, "the worker did not start"
      time.sleep(0.01)
    return self

  def __exit__(self, *_):
    with contextlib.suppress(OSError):
      self.ask({"quit": True})
    try:
      self.process.wait(timeout=5)
    except subprocess.TimeoutExpired:
      self.process.kill()
    self.directory.cleanup()

  def ask(self, request):
    with socket.socket(socket.AF_UNIX) as connection:
      connection.connect(self.socket)
      connection.sendall(json.dumps(request).encode() + b"\n")
      return connection.makefile().read()

  def command(self, path, width, height, environment, flags=()):
    return ([str(ROOT / "nvcat"), *flags, str(path)],
            {**os.environ, **(environment or {}), "NVCAT_WORKER": "1", "NVCAT_WORKER_DIR": self.directory.name,
             "FZF_PREVIEW_COLUMNS": str(width), "FZF_PREVIEW_LINES": str(height)})

  def preview(self, path, width=COLUMNS, height=LINES, environment=None, flags=()):
    command, variables = self.command(path, width, height, environment, flags)
    return subprocess.run(command, env=variables, capture_output=True, check=False)

  def router(self, path):
    """A preview as nvcat-dispatch makes it, which also runs its filetype match."""
    _, variables = self.command(path, COLUMNS, LINES, {"NVCAT": str(ROOT / "nvcat")})
    return subprocess.run([str(ROOT / "nvcat-dispatch"), str(path)], env=variables, capture_output=True, check=False)

  def abandon(self, path, after_ms):
    """Start a preview and kill its client after a delay, as fzf does when the selection moves."""
    command, variables = self.command(path, COLUMNS, LINES, None)
    client = subprocess.Popen(command, env=variables, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(after_ms / 1000)
    client.terminate()
    client.wait()

  def stats(self):
    return json.loads(self.ask({"stats": True}))

  def rss_mib(self):
    sys.path.insert(0, str(ROOT))
    from nvcat_worker import rss_mib  # Only here: it imports all of nvcat.

    return rss_mib(self.stats()["nvim"])


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
