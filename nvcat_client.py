"""The worker's client, for NVCAT_WORKER=1: an fzf preview of one file, from a Neovim that stays running.

Imported only when the variable is set, and kept to light imports: this runs before nvcat's own. preview() returns None
for anything it does not serve, and nvcat then renders as usual, which also gives the usual errors and bat fallback.
"""

import json
import os
import socket
import sys

# How long a preview waits for a busy worker before rendering by itself.
WAIT_SECONDS = 2.0
DEFAULT_BUDGET = 5.0  # As nvcat's --budget.


def client_variable(name):
  """The variables that decide the config and color. The worker's Neovim runs under the latest client's."""
  if name in ("NVCAT_WORKER", "NVCAT_WORKER_DIR", "NVCAT_WORKER_IDLE", "NVCAT_WORKER_LIMIT", "NVCAT_TEST_SESSION"):
    return False
  return name.startswith("NVCAT_") or name in ("NO_COLOR", "XDG_CONFIG_HOME", "HOME")


def directory():
  """A directory only this user can use for the socket, or None. Other users must not reach a process that reads files."""
  base = os.environ.get("NVCAT_WORKER_DIR")
  if not base:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    base = os.path.join(runtime, "nvcat") if runtime else f"/tmp/nvcat-worker-{os.getuid()}"
  try:
    os.makedirs(base, mode=0o700, exist_ok=True)
    status = os.lstat(base)
  except OSError:
    return None
  if not os.path.isdir(base) or os.path.islink(base) or status.st_uid != os.getuid() or status.st_mode & 0o077:
    return None
  return base


def start(path):
  """Start a worker for later previews. Its lock lets only one of several starters stay."""
  import subprocess  # Only here: importing it takes longer than the rest of a served preview's Python.

  root = os.path.dirname(os.path.realpath(__file__))
  with open(os.devnull, "r+b") as null:
    subprocess.Popen([sys.executable, os.path.join(root, "nvcat_worker.py"), path], stdin=null, stdout=null, stderr=null,
                     cwd="/", start_new_session=True)


def request_from(arguments):
  """What the worker needs from nvcat's arguments, or None when any of them is not one it serves. These are the flags
  of nvcat-dispatch, which previews through the router: --all --paging=never --budget=SECONDS --filetype FILETYPE."""
  file = filetype = None
  complete = False
  budget = DEFAULT_BUDGET
  remaining = list(arguments)
  while remaining:
    argument = remaining.pop(0)
    if argument == "--":
      if len(remaining) != 1 or file is not None:
        return None
      file = remaining.pop()
    elif argument == "--all":
      complete = True
    elif argument == "--paging=never":
      pass
    elif argument in ("--budget", "--filetype") or argument.startswith(("--budget=", "--filetype=")):
      name, equals, value = argument.partition("=")
      if not equals:
        if not remaining:
          return None
        value = remaining.pop(0)
      if name == "--filetype":
        filetype = value
      else:
        try:
          budget = float(value)
        except ValueError:
          return None
    elif argument.startswith("-") or file is not None:
      return None
    else:
      file = argument
  # nvcat decides the rest: stdin, and a budget that is off or makes no sense.
  if not file or file == "-" or not 0 < budget < 3600:
    return None
  return {"path": os.path.abspath(file), "filetype": filetype, "complete": complete, "budget": budget if complete else None}


def receive(connection):
  """The status and data of a whole reply, else None: a worker that died partway must leave nothing printed."""
  header = b""
  while not header.endswith(b"\n"):
    chunk = connection.recv(1)
    if not chunk or len(header) > 32:
      return None
    header += chunk
  status, _, size = header.strip().partition(b" ")
  if status not in (b"O", b"L"):
    return None
  wanted = int(size)
  parts = []
  while wanted > 0:
    chunk = connection.recv(min(wanted, 1 << 16))
    if not chunk:
      return None
    parts.append(chunk)
    wanted -= len(chunk)
  return status, b"".join(parts)


def preview(arguments):
  """The exit status of a preview the worker served, or None."""
  columns, lines = os.environ.get("FZF_PREVIEW_COLUMNS", ""), os.environ.get("FZF_PREVIEW_LINES", "")
  request = request_from(arguments)
  if request is None or not (columns.isdigit() and lines.isdigit()):
    return None
  base = directory()
  if base is None:
    return None
  path = os.path.join(base, "worker.socket")
  connection = socket.socket(socket.AF_UNIX)
  connection.settimeout(WAIT_SECONDS + (request["budget"] or 0))
  try:
    try:
      connection.connect(path)
    except (FileNotFoundError, ConnectionRefusedError):
      start(path)
      return None
    connection.sendall(json.dumps({
      **request, "width": int(columns), "height": int(lines),
      "environment": {name: value for name, value in os.environ.items() if client_variable(name)},
    }).encode() + b"\n")
    reply = receive(connection)
  except (OSError, ValueError):
    return None
  finally:
    connection.close()
  if reply is None:
    return None
  status, output = reply
  if status == b"L":  # Over a limit: nvcat goes straight to its fallback, rather than spend the budget a second time.
    os.environ["NVCAT_WORKER_LIMIT"] = output.decode()
    return None
  try:
    sys.stdout.buffer.write(output)
    sys.stdout.buffer.flush()
  except BrokenPipeError:
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
  return 0
