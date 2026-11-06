#!/usr/bin/python3
"""The worker behind NVCAT_WORKER=1: one embedded Neovim that serves fzf previews over a Unix socket.

nvcat_client.py starts it, and it exits after NVCAT_WORKER_IDLE seconds without a request (default 600). A preview it
cannot serve gets an E reply, and nvcat renders that one itself. Usage: nvcat_worker.py SOCKET
"""

import contextlib
import fcntl
import io
import json
import os
import shutil
import signal
import socket
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import config
import filetypes
import nvcat_cli as nvcat
from nvcat_client import client_variable

ROOT = Path(__file__).resolve().parent
COLUMNS, LINES = 100, 40
IDLE_SECONDS = 600
REQUEST_SECONDS = 2  # For a client to send its one line, or take its reply.
GRACE_SECONDS = 0.3  # A cancelled render that Neovim cannot leave by then is cheaper to kill than to wait out.
MAX_RSS_MIB = 200  # Neovim grows with what it has cached, and restarting it costs one slower preview.


def tracked(settings, paths):
  """The files a running Neovim has already read: when one changes it is stale, and its colors would be silently old."""
  files = [config.config_file(), ROOT / "profile.lua", ROOT / "nvcat_cli.py", ROOT / "config.py",
           Path(shutil.which(settings["nvim"]) or settings["nvim"])]
  for value in (paths.get("theme"), paths.get("markdown_options")):
    if value:
      files += sorted(Path(value).parent.rglob("*.lua"))  # A theme or an options file can require its neighbours.
  for value in (paths.get("parser_dir"), paths.get("render_markdown"), paths.get("icons")):
    if value:
      files += [Path(value), *sorted(Path(value).glob("*"))]
      files += sorted((Path(value) / "parser").glob("*"))
  return files


def fingerprint(files):
  stamps = []
  for file in files:
    try:
      status = file.stat()
      stamps.append((status.st_mtime_ns, status.st_size))
    except OSError:
      stamps.append(None)
  return stamps


def rss_mib(pid):
  with contextlib.suppress(OSError):
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
      if line.startswith("VmRSS:"):
        return int(line.split()[1]) / 1024
  return 0.0


def kill(renderer):
  with contextlib.suppress(ProcessLookupError):
    os.killpg(renderer.process.pid, signal.SIGKILL)
  renderer.process.wait()
  renderer.close()


def settle(renderer):
  """After a cancelled render: True when Neovim answers within the grace period, else kill it and return False.
  Lua that is running cannot be interrupted over RPC, and a large file can hold Neovim for seconds."""
  renderer.watch = None
  timeout, renderer.timeout = renderer.timeout, GRACE_SECONDS
  try:
    # Wiping can be the slow part, and work queued for the document follows it, so answer only after both.
    renderer.request("nvim_exec_lua", "nvcat.reset()", [])
    renderer.request("nvim_exec_lua", "return 0", [])
    return True
  except nvcat.TimedOut:
    kill(renderer)
    return False
  finally:
    renderer.timeout = timeout


class Worker:
  def __init__(self, temporary):
    self.temporary = temporary
    self.renderer = None
    self.environment = None
    self.files = []
    self.stamps = []
    self.width, self.height = COLUMNS, LINES
    self.stats = {"previews": 0, "skipped": 0, "cancelled": 0, "killed": 0, "stale": 0, "over_rss": 0, "refused": 0,
                  "stat_ms": []}

  def start(self, environment):
    """Read the config as the client's environment gives it, and start a Neovim with it."""
    for name in [name for name in os.environ if client_variable(name)]:
      del os.environ[name]
    os.environ.update(environment)
    # As in a preview: use_color() and hyperlinks() read these, and they differ per request only in value.
    os.environ.update(FZF_PREVIEW_COLUMNS=str(COLUMNS), FZF_PREVIEW_LINES=str(LINES))
    settings = config.load()[0]
    color = nvcat.use_color(settings["color"])
    links = color and nvcat.hyperlinks(settings["hyperlinks"], nvcat.resolve_pager(settings["pager"]), "auto", False)
    if links:
      links = settings["link_schemes"] or config.DEFAULT_LINK_SCHEMES
    paths = nvcat.find_paths(settings)
    self.environment = environment
    self.files = tracked(settings, paths)
    self.stamps = fingerprint(self.files)
    self.width, self.height = COLUMNS, LINES
    self.renderer = nvcat.Renderer(settings["nvim"], paths, self.temporary, COLUMNS, LINES, nvcat.DEFAULT_TIMEOUT,
                                   nvcat.Timings(), "auto", links, color)

  def stop(self):
    if self.renderer:
      self.renderer.close()
      self.renderer = None

  def current(self, environment):
    """Make the Neovim the one this request asks for: running, and not older than the files it read."""
    began = time.perf_counter()
    stale = fingerprint(self.files) != self.stamps or environment != self.environment
    self.stats["stat_ms"].append(round((time.perf_counter() - began) * 1000, 3))
    del self.stats["stat_ms"][:-100]
    if self.renderer and not stale and self.renderer.process.poll() is None:
      return
    self.stats["stale"] += 1 if self.renderer and stale else 0
    self.stop()
    self.start(environment)

  def render(self, request, connection):
    path = nvcat.input_path(Path(request["path"]))
    size = path.stat().st_size
    with open(path, "rb") as handle:
      binary = b"\0" in handle.read(nvcat.BINARY_PROBE)
    filetype = nvcat.resolve_filetype(None, Path(request["path"]))
    # What nvcat decides by itself: bat for these, and the notices that go with it.
    if size > nvcat.MAX_BYTES or binary or (filetype is not None and "accept" in filetype):
      raise nvcat.Unsupported("not for the worker")
    self.current({name: value for name, value in request["environment"].items() if client_variable(name)})
    renderer = self.renderer
    renderer.syntax = "regex" if filetype and filetypes.regex_modeline(Path(request["path"]), filetype["filetype"]) else "auto"
    renderer.timings = nvcat.Timings()
    renderer.ready.clear()
    renderer.errors.clear()
    renderer.request("nvim_exec_lua", "nvcat.reset()", [])
    if (request["width"], request["height"]) != (self.width, self.height):
      self.width, self.height = request["width"], request["height"]
      renderer.request("nvim_ui_try_resize", self.width, max(self.height, nvcat.MIN_GRID_ROWS))
    renderer.watch = connection
    warnings = io.StringIO()
    with contextlib.redirect_stderr(warnings):
      output, _ = renderer.render(path, self.width, self.height, 1, False, filetype)
    if warnings.getvalue():  # nvcat prints these to the user, so let it.
      raise nvcat.Unsupported("warnings")
    return output

  def handle(self, connection):
    connection.settimeout(REQUEST_SECONDS)
    request = json.loads(connection.makefile().readline())
    if request.get("quit"):
      raise SystemExit(0)
    if request.get("stats"):
      running = self.renderer.process.pid if self.renderer else None
      connection.sendall(json.dumps({**self.stats, "nvim": running}).encode())
      return
    if nvcat.client_gone(connection):  # Abandoned while it waited its turn.
      self.stats["skipped"] += 1
      return
    try:
      output = self.render(request, connection)
      connection.sendall(b"O %d\n" % len(output) + output)
      self.stats["previews"] += 1
    except nvcat.ClientGone:
      self.stats["cancelled"] += 1
      if not settle(self.renderer):
        self.stats["killed"] += 1
        self.renderer = None
    except OSError:
      pass
    except Exception as error:  # noqa: BLE001 - nvcat renders it instead, and reports whatever is wrong.
      self.stats["refused"] += 1
      if isinstance(error, nvcat.TimedOut) and self.renderer:
        kill(self.renderer)
        self.renderer = None
      with contextlib.suppress(OSError):
        connection.sendall(b"E\n")
    finally:
      if self.renderer:
        self.renderer.watch = None
    if self.renderer and rss_mib(self.renderer.process.pid) > MAX_RSS_MIB:
      self.stats["over_rss"] += 1
      self.stop()


def same_user(connection):
  credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
  return struct.unpack("3i", credentials)[1] == os.getuid()


def serve(path):
  lock = open(path + ".lock", "a")  # noqa: SIM115 - held for the life of the process.
  try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
  except OSError:
    return 0  # Another client started one first.
  with contextlib.suppress(FileNotFoundError):
    os.unlink(path)  # A worker that ended left it: once sandboxed, it cannot remove the file.
  os.umask(0o077)
  listener = socket.socket(socket.AF_UNIX)
  listener.bind(path)
  listener.listen(16)
  listener.settimeout(float(os.environ.get("NVCAT_WORKER_IDLE") or IDLE_SECONDS))
  signal.signal(signal.SIGPIPE, signal.SIG_IGN)
  signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
  signal.signal(signal.SIGHUP, signal.SIG_IGN)
  with nvcat.run_directory() as temporary:
    nvcat.restrict_writes(temporary)
    worker = Worker(temporary)
    try:
      # Ready before the next preview. Whatever fails here, a request meets again, and nvcat then reports it.
      with contextlib.suppress(Exception):
        worker.start({name: value for name, value in os.environ.items() if client_variable(name)})
      while True:
        try:
          connection, _ = listener.accept()
        except TimeoutError:
          return 0
        with connection:
          if same_user(connection):
            with contextlib.suppress(OSError, ValueError):
              worker.handle(connection)
    finally:
      worker.stop()


if __name__ == "__main__":
  sys.exit(serve(sys.argv[1]))
