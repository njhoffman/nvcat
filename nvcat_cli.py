"""Isolated, one-shot Neovim screen-to-ANSI renderer for Markdown and the filetypes in filetypes.json.

The `nvcat` command imports command() from here: a module's bytecode is cached in __pycache__, a script's is
compiled on every start."""

import time

STARTED = time.monotonic_ns()  # Before the other imports, so --timings can report their cost.

import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

try:
  import msgpack
except ImportError:
  sys.exit("nvcat: the Python package msgpack is missing; install python3-msgpack or run 'just deps'")
import resource

import config
import filetypes
from readonly import landlock_abi, restrict_writes

ROOT = Path(__file__).resolve().parent
# Neovim clamps 'lines', and so the UI grid, to 1000 rows; a taller nvim_ui_try_resize never produces the
# requested grid. Renderer.wait_ready() names the row limit if a Neovim with a lower cap times out on it.
MAX_ROWS = 1000
MIN_GRID_ROWS = 2  # Neovim's smallest 'lines': a one-row viewport renders on two and emits one.
MAX_BYTES = 10 * 1024 * 1024
BINARY_PROBE = 8192  # Bytes checked for a NUL, as git and grep do, to treat the input as binary.
VERSION_FILE = ROOT / "VERSION"


class PreviewError(Exception):
  pass


class TooLarge(PreviewError):
  """A limit was reached (input size, binary input, rows, --budget, --timeout); a fallback renderer can take over."""


class TimedOut(TooLarge):
  pass


class Unsupported(TooLarge):
  """--filetype auto: Neovim detected a filetype that nvcat has no table entry for, so bat renders the file."""


class Cancelled(Exception):
  pass


def concise(error):
  """One readable message from a Neovim error: no stack trace, and only the innermost error of a chain such as
  "BufReadPost Autocommands for ...: Vim(append):Lua callback: ...: E5113: ...". nvcat's own assertions in
  profile.lua lose their location; errors elsewhere keep it."""
  if isinstance(error, (list, tuple)) and len(error) == 2 and isinstance(error[1], str):
    error = error[1]  # RPC errors are [type, message].
  text = str(error).split("stack traceback:")[0].strip()
  located = list(re.finditer(r"(?:\.\.\.|/)?[\w./-]*\.lua:\d+: ", text))
  if located:
    last = located[-1]
    text = text[last.end():] if "profile.lua:" in last.group() else text[last.start():]
  return re.sub(r"^Error executing lua: ", "", text.strip())


class Timings:
  """Phase durations for --timings. Phases are kept in the order first recorded; repeats add up.

  Names with ": " are sub-phases of the part before it. Neovim reports its own phases (profile.lua) the same way.
  """

  def __init__(self):
    self.phases = {}
    self.facts = {}

  def add(self, name, milliseconds):
    self.phases[name] = self.phases.get(name, 0.0) + milliseconds

  def since(self, name, start):
    """Add the time since start (time.monotonic_ns()) to name; return now."""
    now = time.monotonic_ns()
    self.add(name, (now - start) / 1e6)
    return now

  @contextlib.contextmanager
  def phase(self, name):
    start = time.monotonic_ns()
    try:
      yield
    finally:
      self.since(name, start)

  def ordered(self):
    """Phases in first-recorded order, each sub-phase directly after its parent."""
    names = list(self.phases)
    parents = [name for name in names if ": " not in name]
    order = []
    for parent in parents:
      order.append(parent)
      order += [name for name in names if name.startswith(parent + ": ")]
    order += [name for name in names if name not in order]
    return [name for name in order if name != RPC_PHASE] + [name for name in order if name == RPC_PHASE]

  def report(self):
    """The phases, facts, total, and peak resident memory, as a JSON-ready dict."""
    children = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    return {
      **self.facts,
      "total_ms": round((time.monotonic_ns() - STARTED) / 1e6, 2),
      "peak_rss_kb": {"python": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss, "children": children},
      "phases": {name: round(self.phases[name], 2) for name in self.ordered()},
    }

  def table(self):
    report = self.report()
    facts = ", ".join(f"{key} {report[key]}" for key in
                      ["filetype", "engine", "highlight_index", "grid", "resizes", "ready_callbacks", "render_passes",
                       "redraw_bytes"]
                      if key in report)
    lines = [f"nvcat timings (ms){': ' + facts if facts else ''}"]
    for name, value in report["phases"].items():
      parent, _, child = name.partition(": ")
      label = f"  {child}" if child else parent
      lines.append(f"  {label:<40} {value:9.1f}")
    lines.append(f"  {'total (since the first import)':<40} {report['total_ms']:9.1f}")
    rss = report["peak_rss_kb"]
    lines.append(f"  peak RSS: python {rss['python'] / 1024:.0f} MiB, largest child (nvim or bat) "
                 f"{rss['children'] / 1024:.0f} MiB")
    lines.append(f"  {RPC_PHASE!r} is the Python share of the Neovim waits above, not extra time")
    return "\n".join(lines) + "\n"


RPC_PHASE = "rpc handling (python)"


def find_paths(settings=None):
  """Resolve the configured dependencies for profile.lua, or raise PreviewError naming what is missing."""
  try:
    settings = settings or config.load()[0]
  except config.ConfigError as error:
    raise PreviewError(str(error)) from error
  errors, _ = config.problems(settings)
  if errors:
    raise PreviewError("; ".join(errors) + " (see nvcat --check)")
  return dict(config.runtime_paths(settings), root=str(ROOT))


DISPATCH_INPUTS = ["filetypes.json", "filetypes.regex.json", "filetypes.py", "gen-dispatch"]


def dispatch_problem(root=ROOT):
  """Why root's nvcat-dispatch needs regenerating (just dispatch), or None. It is generated per machine from
  bat, so a checkout has none until just install, and an update leaves it older than its inputs."""
  script = root / "nvcat-dispatch"
  if not script.exists():
    return "nvcat-dispatch is not generated: run `just dispatch` (`just install` does too)"
  built = script.stat().st_mtime
  newer = [name for name in DISPATCH_INPUTS if (root / name).exists() and (root / name).stat().st_mtime > built]
  if newer:
    return f"nvcat-dispatch is older than {', '.join(newer)}: run `just dispatch`"
  return None


def check(installed=False):
  """Print the resolved configuration, versions, and problems; return 1 if a required piece is missing.

  installed: compile the queries of every installed parser, not only the filetype table's languages."""
  try:
    settings, sources = config.load()
  except config.ConfigError as error:
    print(f"config: {error}")
    return 1
  path = config.config_file()
  print(f"config file: {path}{'' if path.is_file() else ' (not found; using defaults)'}")
  for key, (_, description) in config.KEYS.items():
    value = settings[key]
    shown = ", ".join(map(str, value)) if isinstance(value, list) else value
    print(f"  {key:16} {shown if shown not in (None, '') else '-'}  [{sources[key]}]")
  def tool_version(command):
    try:
      result = subprocess.run(command, capture_output=True, text=True, timeout=10)
      return (result.stdout or result.stderr).splitlines()[0].strip()
    except (OSError, IndexError, subprocess.TimeoutExpired):
      return "not found"
  def git_version(path):
    return tool_version(["git", "-C", str(path), "describe", "--tags", "--always"]) if path else "not found"
  print("versions:")
  print(f"  nvcat        {version()}")
  print(f"  python           {sys.version.split()[0]}, msgpack {'.'.join(map(str, msgpack.version))}")
  print(f"  neovim           {tool_version([settings['nvim'], '--version']) if settings['nvim'] else 'not found'}")
  print(f"  render-markdown  {git_version(settings['render_markdown'])}")
  print(f"  mini.icons       {git_version(settings['icons'])}")
  print(f"  bat              {tool_version(['bat', '--version'])}")
  print(f"  less             {tool_version(['less', '--version'])}")
  try:
    print(f"  landlock         ABI {landlock_abi()}")
  except OSError as error:
    print(f"  landlock         unavailable: {error}")
  errors, warnings = config.problems(settings)
  problem = dispatch_problem()
  if problem:
    warnings.append(problem)
  print("tree-sitter queries:")
  if errors:
    print("  not checked: required dependencies are missing")
  else:
    try:
      report = check_queries(settings, installed)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
      print(f"  not checked: {error}")
    else:
      scope = "installed parsers" if installed else "filetypes.json languages (--check --all: every parser)"
      print(f"  compiled         {len(report['ok'])} languages; checked {scope}")
      for key, label in [("no_parser", "no parser"), ("no_highlights", "no highlights query")]:
        if report[key]:
          print(f"  regex syntax     {', '.join(report[key])} ({label})")
      warnings += report["warnings"]
  for warning in warnings:
    print(f"warning: {warning}")
  for error in errors:
    print(f"error: {error}")
  print("ok" if not errors else "missing required dependencies")
  return 1 if errors else 0


def check_queries(settings, installed=False):
  """Compile each table language's highlights and injections queries in a headless Neovim; see profile.lua."""
  langs = ["markdown", "markdown_inline"]
  for entry in filetypes.load():
    lang = entry.get("lang", entry["filetype"])
    if lang not in langs:
      langs.append(lang)
  paths = dict(config.runtime_paths(settings), root=str(ROOT))
  with tempfile.TemporaryDirectory(prefix="nvcat-", dir="/tmp") as temporary:
    env = isolated_environment(temporary)
    env["NVCAT_SESSION"] = json.dumps({"paths": paths, "langs": langs, "installed": installed})
    command = nvim_command(settings["nvim"], "--headless", "-c",
                           "lua local s = vim.json.decode(vim.env.NVCAT_SESSION); nvcat.setup(nil, s.paths); "
                           "nvcat.check_queries(s.langs, s.installed)", "-c", "qa!")
    result = subprocess.run(command, cwd=temporary, env=env, capture_output=True, text=True,
                            timeout=300 if installed else 60)
  try:
    return json.loads(result.stdout)
  except ValueError:
    raise ValueError(concise(result.stderr.strip() or f"Neovim exited with status {result.returncode}")) from None


def isolated_environment(temporary):
  """Environment for a private Neovim: no editor config, state, or parent-Neovim variables leak in."""
  env = dict(os.environ)
  for name in ["NVIM", "NVIM_LISTEN_ADDRESS", "VIMINIT", "EXINIT", "GVIMINIT", "NVIM_APPNAME"]:
    env.pop(name, None)
  for name, subdir in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                       ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")]:
    env[name] = str(Path(temporary) / subdir)
  env.update(TMPDIR=temporary, NVIM_LOG_FILE=str(Path(temporary) / "nvim.log"))
  return env


def nvim_command(executable, *extra):
  return [executable, *extra, "--noplugin", "-n", "-i", "NONE", "-u", str(ROOT / "profile.lua")]


# Neovim's underline attributes and their SGR codes, in the order one is chosen when a highlight sets several.
UNDERLINES = {"underline": "4", "underdouble": "4:2", "undercurl": "4:3", "underdotted": "4:4",
              "underdashed": "4:5"}


# A link's URL comes from the document and goes to the terminal: with a control byte in it (C0, DEL or C1) it could
# end the OSC 8 sequence and send any other, so such a link is left out.
CONTROL_BYTES = re.compile(r"[\x00-\x1f\x7f-\x9f]")
# What bat's output may not carry: controls (bat's --strip-ansi leaves BEL and C1 alone), ESC except in SGR when colored.
UNSAFE_COLORED = re.compile(rb"\xc2[\x80-\x9f]|[\x00-\x08\x0b\x0c\x0e-\x1a\x1c-\x1f\x7f]|\x1b(?!\[[0-9;:]*m)")
UNSAFE_PLAIN = re.compile(rb"\xc2[\x80-\x9f]|\x1b\[[0-9;:]*m|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
NOT_URI_BYTES = re.compile(rb"[^\x21-\x7e]")  # OSC 8 allows bytes 32-126; a space is not valid in a URI either.


def link_target(url):
  """The URI to write in an OSC 8 hyperlink for a link's url, or None to leave the link out: without its
  Markdown <angle brackets>, the rest percent-encoded."""
  if not url or CONTROL_BYTES.search(url):
    return None
  if url.startswith("<") and url.endswith(">"):
    url = url[1:-1]
  return NOT_URI_BYTES.sub(lambda byte: b"%%%02X" % byte[0][0], url.encode()).decode() or None


class SafeStderr:
  """sys.stderr with control characters shown as \\xNN: messages quote file names, link targets and Neovim's stderr."""
  UNSAFE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")

  def __init__(self, stream):
    self.stream = stream

  def write(self, text):
    return self.stream.write(self.UNSAFE.sub(lambda match: f"\\x{ord(match[0]):02x}", text))

  def __getattr__(self, name):
    return getattr(self.stream, name)


class Renderer:
  def __init__(self, executable, paths, temporary, width, height, timeout, timings=None, syntax="auto",
               hyperlinks=True, color=True):
    self.timings = timings or Timings()
    self.syntax = syntax
    self.color = color
    self.hyperlinks = hyperlinks  # OSC 8 links for cells whose highlight carries a url (Markdown links)
    self.process = None
    self.errors = []
    self.stderr = tempfile.TemporaryFile(dir=temporary)
    self.grid = []
    self.highlights = {0: {}}
    self.defaults = [-1, -1, -1]
    self.ready = []
    self.responses = {}
    self.serial = 0
    self.token = 0
    self.timeout = timeout
    self.budget_deadline = None  # Overall deadline for complete output, see render(budget=...)
    self.flushes = 0
    self.unpacker = msgpack.Unpacker(raw=False, strict_map_key=False)
    env = isolated_environment(temporary)
    env.update(TERM="xterm-256color", COLORTERM="truecolor")
    try:
      self.spawned = time.monotonic_ns()
      self.process = subprocess.Popen(
        nvim_command(executable, "--embed"),
        cwd=temporary, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=self.stderr, start_new_session=True,
      )
      register_child(self.process.pid)
      # --embed answers RPC at once but sources startup files only after nvim_ui_attach, so Neovim's startup
      # finishes inside the setup request; record() splits this phase with Neovim's own marks.
      channel = self.request("nvim_get_api_info")[0]
      self.request("nvim_ui_attach", width, max(height, MIN_GRID_ROWS),
                   {"rgb": True, "ext_linegrid": True, "ext_messages": True})
      self.request("nvim_exec_lua", "nvcat.setup(...)", [channel, paths])
      self.timings.since("startup", self.spawned)
    except BaseException:
      self.close()
      raise

  def request(self, method, *arguments):
    self.serial += 1
    serial = self.serial
    try:
      self.process.stdin.write(msgpack.packb([0, serial, method, list(arguments)], use_bin_type=True))
      self.process.stdin.flush()
    except BrokenPipeError:
      raise self.exited() from None
    deadline = time.monotonic() + self.timeout
    while serial not in self.responses:
      self.pump(deadline)
    error, result = self.responses.pop(serial)
    if error:
      raise PreviewError(concise(error))
    return result

  def exited(self):
    """The error for a Neovim that has gone, with what it wrote to stderr."""
    self.stderr.seek(0)
    diagnostic = self.stderr.read().decode(errors="replace")[-2000:]
    return PreviewError("Neovim exited before completing the preview. " + diagnostic)

  def pump(self, deadline):
    budgeted = self.budget_deadline is not None and self.budget_deadline < deadline
    remaining = (self.budget_deadline if budgeted else deadline) - time.monotonic()
    if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
      detail = ("; Neovim reported: " + "; ".join(self.errors)) if self.errors else ""
      if budgeted:
        raise TooLarge("complete output took longer than the budget (--budget)" + detail)
      raise TimedOut(f"Neovim did not answer within the {self.timeout} s timeout (--timeout)" + detail)
    received = time.monotonic_ns()
    data = os.read(self.process.stdout.fileno(), 65536)
    self.timings.facts["redraw_bytes"] = self.timings.facts.get("redraw_bytes", 0) + len(data)
    if not data:
      raise self.exited()
    self.unpacker.feed(data)
    for message in self.unpacker:
      if message[0] == 1:
        self.responses[message[1]] = message[2:]
      elif message[0] == 2:
        name, arguments = message[1:]
        if name == "nvcat_ready":
          self.ready.append(arguments[0])
        elif name == "nvim_error_event":
          self.errors.append(concise(arguments))
        elif name == "redraw":
          for event in arguments:
            for args in event[1:]:
              self.event(event[0], args)
    self.timings.since(RPC_PHASE, received)

  def event(self, name, args):
    if name == "grid_resize" and args[0] == 1:
      self.grid = [[[" ", 0] for _ in range(args[1])] for _ in range(args[2])]
    elif name == "grid_clear" and args[0] == 1:
      self.grid = [[[" ", 0] for _ in row] for row in self.grid]
    elif name == "grid_line" and args[0] == 1:
      _, row, column, cells, *_ = args
      highlight = 0
      for cell in cells:
        text = cell[0]
        if len(cell) > 1:
          highlight = cell[1]
        for _ in range(cell[2] if len(cell) > 2 else 1):
          self.grid[row][column] = [text, highlight]
          column += 1
    elif name == "grid_scroll" and args[0] == 1:
      _, top, bottom, left, right, rows, columns = args
      previous = [[cell[:] for cell in row] for row in self.grid]
      for row in range(top, bottom):
        for column in range(left, right):
          source_row, source_column = row + rows, column + columns
          self.grid[row][column] = (
            previous[source_row][source_column]
            if top <= source_row < bottom and left <= source_column < right else [" ", 0]
          )
    elif name == "hl_attr_define":
      self.highlights[args[0]] = args[1]
    elif name == "default_colors_set":
      self.defaults = args[:3]
    elif name == "flush":
      self.flushes += 1
    elif name == "msg_show" and args[0] in {"emsg", "echoerr", "lua_error"}:
      self.errors.append(concise("".join(part[1] for part in args[1])))

  def wait_ready(self, token, width, height):
    deadline = time.monotonic() + self.timeout
    try:
      while not any(item["token"] == token and item["width"] == width and item["height"] == height
                    for item in self.ready):
        self.pump(deadline)
    except TimedOut as error:
      # A Neovim that clamps its grid below MAX_ROWS never draws the requested height; name the row limit.
      shorter = [item["height"] for item in self.ready if item["token"] == token and item["height"] < height]
      if shorter:
        raise TooLarge(f"complete output needs {height} screen rows, over the {max(shorter)} Neovim allows "
                       "(--lines renders a viewport)") from error
      raise
    # notify_ready redrew just before signalling, and grid events precede the notification on the channel.
    with self.timings.phase("frames: info"):
      info = self.request("nvim_exec_lua", "return nvcat.info()", [])
    # Plugins may leave v:errmsg set after a caught API error. Unhandled RPC/UI errors are authoritative.
    if self.errors:
      raise PreviewError("; ".join(self.errors))
    return info

  def render(self, path, width, height, start_line=1, all_rows=False, filetype=None, budget=None):
    self.budget_deadline = time.monotonic() + budget if all_rows and budget else None
    self.token += 1
    with self.timings.phase("open"):
      opened = self.request("nvim_exec_lua", "return nvcat.open(...)",
                            [str(path), start_line, self.token, filetype, self.syntax])
    if isinstance(opened, dict) and "unsupported" in opened:
      raise Unsupported(f"Neovim detected {opened['unsupported'] or 'no filetype'}, which nvcat does not "
                        "render with --filetype auto")
    rows, height = height, max(height, MIN_GRID_ROWS)
    with self.timings.phase("frames: first"):
      info = self.wait_ready(self.token, width, height)
    resized = time.monotonic_ns()
    resizes = 0
    if all_rows:
      for _ in range(8):
        if info["total_height"] <= height and info["bottom_line"] == info["buffer_lines"]:
          break
        if info["total_height"] > MAX_ROWS or height == MAX_ROWS:
          raise TooLarge(f"complete output exceeds {MAX_ROWS} screen rows (--lines renders a viewport)")
        height = min(MAX_ROWS, max(height * 2, info["total_height"] + 4))
        resizes += 1
        self.token += 1
        self.request("nvim_exec_lua", "nvcat.token = ...", [self.token])
        self.request("nvim_ui_try_resize", width, height)
        self.request("nvim_exec_lua", "nvcat.resized(...)", [self.token])
        info = self.wait_ready(self.token, width, height)
      else:
        raise PreviewError("Document layout did not settle after resizing")
    if resizes:
      self.timings.since("frames: resizes", resized)
    self.record(info, width, height, resizes)
    for warning in info.get("warnings") or []:
      print(f"nvcat: warning: {warning}", file=sys.stderr)
    count = min(height if all_rows else rows, info["remaining_height"])
    with self.timings.phase("ansi encode"):
      output = self.ansi(count)
    return output, info

  def record(self, info, width, height, resizes):
    """Copy Neovim's own phase timings and the render facts into self.timings."""
    facts = self.timings.facts
    facts.update(filetype=info["filetype"], engine=info["engine"], highlight_index=info.get("highlight_index"),
                 grid=f"{width}x{height}",
                 resizes=facts.get("resizes", 0) + resizes, ready_callbacks=info.get("callbacks"),
                 render_passes=info.get("render_passes"))
    phases = self.timings.phases
    phases["frames"] = phases.get("frames: first", 0) + phases.get("frames: resizes", 0)
    marks = info.get("marks") or {}
    if "startup" in phases and {"profile", "setup"} <= marks.keys():
      # Both clocks are CLOCK_MONOTONIC on Linux, so Neovim's marks place on nvcat's timeline.
      phases["startup: neovim before profile.lua"] = (marks["profile"] - self.spawned) / 1e6
      phases["startup: neovim profile.lua to setup"] = (marks["setup"] - marks["profile"]) / 1e6
    # Neovim's figures are totals for its process, so they replace rather than add. render and redraw run once
    # per frame.
    for name, value in info.get("timings") or []:
      if name.startswith("setup: "):
        name = "startup: " + name
      elif ": " not in name:
        name = f"frames: neovim {name} (all frames)"
      phases[name] = value

  def plain(self, rows):
    """The text of the rows, as laid out, without any escape sequence."""
    return "".join("".join(text for text, _ in row).rstrip(" ") + "\n" for row in self.grid[:rows]).encode("utf-8")

  def ansi(self, rows):
    if not self.color:
      return self.plain(rows)
    output = []
    sequences = {}
    targets = {}
    # One id per URI: terminals treat the cells of a link wrapped over rows as one link only with an id.
    ids = {}
    for row in self.grid[:rows]:
      end = len(row)
      while end:
        text, highlight = row[end - 1]
        attrs = self.highlights.get(highlight, {})
        if text != " " or any(attrs.get(key) for key in ["reverse", "strikethrough", *UNDERLINES]) \
            or "background" in attrs:
          break
        end -= 1
      current = link = None
      for text, highlight in row[:end]:
        if not text:
          continue  # Continuation cell of a wide glyph; the glyph itself occupies both columns.
        if highlight != current:
          if highlight not in sequences:
            attrs = self.highlights.get(highlight, {})
            sequences[highlight] = self.sgr(attrs)
            targets[highlight] = link_target(attrs.get("url")) if self.hyperlinks else None
          url = targets[highlight]
          if url != link:
            output.append(f"\x1b]8;id={ids.setdefault(url, len(ids) + 1)};{url}\x1b\\" if url else "\x1b]8;;\x1b\\")
            link = url
          output.append(sequences[highlight])
          current = highlight
        output.append(text)
      if link:
        output.append("\x1b]8;;\x1b\\")
      output.append("\x1b[0m\n")
    return "".join(output).encode("utf-8")

  def sgr(self, attrs):
    """The SGR sequence for one of Neovim's highlight definitions: a full reset, then every attribute.

    Underline styles and the underline color use colon subparameters (4:3, 58:2::R:G:B), which terminals
    without them read as a plain underline or ignore, rather than misreading the color as other attributes."""
    codes = ["0"]
    codes += [str(value) for name, value in [("bold", 1), ("italic", 3), ("reverse", 7),
                                           ("strikethrough", 9)] if attrs.get(name)]
    style = next((code for name, code in UNDERLINES.items() if attrs.get(name)), None)
    if style:
      codes.append(style)
      special = attrs.get("special", -1)
      if special >= 0:
        codes.append(f"58:2::{special >> 16 & 255}:{special >> 8 & 255}:{special & 255}")
    foreground = attrs.get("foreground", self.defaults[0])
    if foreground >= 0:
      codes.append(f"38;2;{foreground >> 16 & 255};{foreground >> 8 & 255};{foreground & 255}")
    else:
      codes.append("39")
    background = attrs.get("background")
    if background is None or background < 0:
      codes.append("49")
    else:
      codes.append(f"48;2;{background >> 16 & 255};{background >> 8 & 255};{background & 255}")
    return "\x1b[" + ";".join(codes) + "m"

  def close(self):
    with self.timings.phase("close"):
      self._close()

  def _close(self):
    if self.process and self.process.poll() is None:
      try:
        self.process.stdin.write(msgpack.packb([2, "nvim_command", ["qa!"]], use_bin_type=True))
        self.process.stdin.flush()
        self.process.wait(timeout=1)
      except (OSError, subprocess.TimeoutExpired):
        try:
          os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
          pass
        self.process.wait()
    if self.process:
      try:
        self.process.stdin.close()
      except BrokenPipeError:  # Buffered bytes a Neovim that has gone did not read; must not hide the real error.
        pass
      self.process.stdout.close()
    self.stderr.close()


def input_path(argument):
  """The regular file argument names, symbolic links resolved, or PreviewError saying why it cannot be read."""
  path = argument.expanduser()
  try:
    resolved = path.resolve(strict=True)
    if not resolved.is_file():
      raise PreviewError(f"{argument}: not a regular file")
    with open(resolved, "rb"):
      pass
  except FileNotFoundError:
    if path.is_symlink():
      raise PreviewError(f"{argument}: broken symbolic link to {os.readlink(path)}") from None
    raise PreviewError(f"{argument}: no such file") from None
  except RuntimeError:  # Symbolic link loops before Python 3.13, which raises OSError (ELOOP) instead.
    raise PreviewError(f"{argument}: symbolic link loop") from None
  except OSError as error:
    raise PreviewError(f"{argument}: {(error.strerror or str(error)).lower()}") from None
  return resolved


def resolve_filetype(name, path):
  """Return {"filetype", "lang"} for Neovim, or None to let Neovim detect the filetype, or for --filetype auto
  {"accept": filetypes}: Neovim detects, and any other result goes to bat.

  A symbolic link is matched by its own name first, then by its target's."""
  if name == filetypes.AUTO:
    return {"accept": sorted(filetypes.accepted())}
  if name:
    entry = filetypes.find(name) or {"filetype": name}
  elif path is None:
    entry = {"filetype": "markdown"}
  else:
    entry = filetypes.detect(path)
    if entry is None and Path(path).is_symlink():
      entry = filetypes.detect(Path(path).resolve())
    if entry is None or entry["filetype"] == filetypes.AUTO:
      return None
  return {"filetype": entry["filetype"], "lang": entry.get("lang", entry["filetype"])}


def fallback_bat(path, width, filetype, start_line=1, height=None, color=True):
  """bat's rendering of path, without the file's own escape sequences; with height, only the viewport of that many
  rows from start_line."""
  command = ["bat", f"--color={'always' if color else 'never'}", "--paging=never", "--style=plain",
             f"--terminal-width={width}"]
  if filetypes.bat_strips_ansi():
    # bat copies the file through unfiltered with no color and no decorations; --style=plain still shows none.
    command += ["--strip-ansi=always", "--decorations=always"]
  if filetype == "markdown":
    command.append("--language=markdown")
  if height:
    command.append(f"--line-range={start_line}:{start_line + height - 1}")
  command += ["--", str(path)]
  output = subprocess.run(command, stdout=subprocess.PIPE, check=True).stdout
  output = (UNSAFE_COLORED if color else UNSAFE_PLAIN).sub(b"", output)
  return b"".join(output.splitlines(keepends=True)[:height]) if height else output


def wants_pager(mode, complete):
  """Whether complete output should go to a pager, before its height is known."""
  if mode != "auto":
    return mode == "always"
  if not complete or not sys.stdout.isatty():
    return False
  # fzf previews and Neovim terminal buffers (Telescope's previewer) give a TTY but want plain output.
  return not any(os.environ.get(name) for name in ["FZF_PREVIEW_COLUMNS", "FZF_PREVIEW_LINES", "NVIM"])


def should_page(mode, complete, output):
  if not wants_pager(mode, complete):
    return False
  return mode == "always" or output.count(b"\n") > shutil.get_terminal_size().lines


HYPERLINKS = ["auto", "always", "never"]
COLORS = ["auto", "always", "never"]


def use_color(mode):
  """Whether to emit color. An explicit setting wins; unset, NO_COLOR turns it off, and otherwise it is on, piped too,
  because previewers read a pipe. auto: on a terminal, in fzf previews and in Neovim terminal buffers."""
  if mode is None:
    return not os.environ.get("NO_COLOR")
  if mode not in COLORS:
    raise PreviewError(f"color must be one of {', '.join(COLORS)}, not {mode!r}")
  if mode != "auto":
    return mode == "always"
  return sys.stdout.isatty() or any(os.environ.get(name) for name in
                                    ["FZF_PREVIEW_COLUMNS", "FZF_PREVIEW_LINES", "NVIM"])


def hyperlinks(mode, pager, paging, complete=True):
  """Whether to emit OSC 8 hyperlinks. auto: yes, unless the output may go to a pager command other than less
  (less passes them on with -R; another pager may print them as text). The output's height is not known yet, so
  a short document that ends up printed is treated like one that is paged."""
  mode = mode or "auto"
  if mode not in HYPERLINKS:
    raise PreviewError(f"hyperlinks must be one of {', '.join(HYPERLINKS)}, not {mode!r}")
  if mode != "auto":
    return mode == "always"
  return pager == "nvim" or os.path.basename(pager[0]) == "less" or not wants_pager(paging, complete)


def resolve_pager(value):
  """"nvim" for the built-in pager, otherwise the external pager's argument list."""
  value = (value or "nvim").strip()
  if value == "nvim":
    return "nvim"
  return ["less", "-R"] if value == "less" else shlex.split(value)


# less shows Private Use Area code points (Nerd Font icons such as render-markdown's heading icons) as
# <U+F0CA3>. Neovim laid them out as one cell each, so declare them printable and single-width.
LESS_PRIVATE_USE = "e000-f8ff:p,f0000-ffffd:p,100000-10fffd:p"


CLEANUP_PIPE = None  # Write end of run_directory()'s pipe to its cleanup child, while one is running.
CLEANUP_GRACE = 2.0  # Seconds the cleanup child gives this run's Neovims to exit before killing them.


def register_child(pid):
  """Tell the cleanup child about a Neovim, so it does not outlive this process (see run_directory)."""
  if CLEANUP_PIPE is not None:
    os.write(CLEANUP_PIPE, f"{pid}\n".encode())


def cleanup_child(directory, pipe):
  """Body of run_directory()'s child: wait for the parent to exit (end-of-file on the pipe), give the
  registered Neovims CLEANUP_GRACE seconds to exit and kill those still running, then remove the directory.
  Neovim may stay running when its run directory is removed under it (0.12), so the order matters."""
  pidfds, pending = [], b""
  while chunk := os.read(pipe, 4096):
    pending += chunk
    *complete, pending = pending.split(b"\n")
    for line in complete:
      try:
        pidfds.append(os.pidfd_open(int(line)))  # Taken while the process exists, so its PID cannot be reused.
      except (OSError, ValueError):
        pass  # Already gone.
  deadline = time.monotonic() + CLEANUP_GRACE
  for pidfd in pidfds:
    if not select.select([pidfd], [], [], max(0, deadline - time.monotonic()))[0]:
      try:
        signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        select.select([pidfd], [], [], 1)
      except OSError:
        pass
  shutil.rmtree(directory, ignore_errors=True)


@contextlib.contextmanager
def run_directory():
  """The per-run directory under /tmp. restrict_writes() confines writes to it, and then this process may not
  remove it (that is a write to /tmp), so a child forked before the sandbox removes it once this process has
  exited: its pipe reaches end-of-file on any exit, including SIGKILL. Neovims passed to register_child() are
  stopped first."""
  global CLEANUP_PIPE
  directory = tempfile.mkdtemp(prefix="nvcat-", dir="/tmp")
  read_end, write_end = os.pipe()  # Not inherited by Neovim, bat or pagers (O_CLOEXEC).
  if os.fork() == 0:
    try:
      os.setsid()  # Out of the terminal's process group: Ctrl-C and a closing terminal must not stop cleanup.
      for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(number, signal.SIG_IGN)
      null = os.open(os.devnull, os.O_RDWR)
      for descriptor in (0, 1, 2):
        os.dup2(null, descriptor)  # Release stdout, so fzf and pipes see end-of-file when nvcat exits.
      os.closerange(3, read_end)
      os.closerange(read_end + 1, 1 << 16)
      cleanup_child(directory, read_end)
    finally:
      os._exit(0)
  os.close(read_end)
  CLEANUP_PIPE = write_end
  try:
    yield directory
  finally:
    CLEANUP_PIPE = None
    os.close(write_end)


def page(output, command, temporary):
  # Landlock allows writes only in the run directory: make it the pager's TMPDIR, and keep less from trying to
  # save its history file.
  environment = dict(os.environ, LESSHISTFILE="-", TMPDIR=temporary)
  environment.setdefault("LESSUTFCHARDEF", LESS_PRIVATE_USE)
  previous = signal.signal(signal.SIGINT, signal.SIG_IGN)  # Ctrl-C belongs to the pager, as with git.
  try:
    pager = subprocess.Popen(command, stdin=subprocess.PIPE, env=environment)
    try:
      pager.stdin.write(output)
      pager.stdin.close()
    except BrokenPipeError:
      pass  # The user quit before reading everything.
    return pager.wait()
  finally:
    signal.signal(signal.SIGINT, previous)


MIN_NVIM = (0, 11)  # Also checked by profile.lua's setup(), which covers every other path.


def require_nvim_version(executable):
  """Raise PreviewError for a Neovim older than MIN_NVIM. Used before the pager: an error in its -c command
  would wait for a key on a cleared screen instead of reaching stderr."""
  try:
    first = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=10).stdout
  except (OSError, subprocess.SubprocessError):
    return  # Starting Neovim itself reports these.
  found = re.match(r"NVIM v(\d+)\.(\d+)\.\S*", first)
  if found and (int(found[1]), int(found[2])) < MIN_NVIM:
    raise PreviewError(f"Neovim {'.'.join(map(str, MIN_NVIM))} or later is required, found {found[0][6:]}")


def page_nvim(executable, paths, temporary, path, filetype, syntax, follow=False):
  """Open the document in a read-only Neovim on this terminal (q quits); return Neovim's exit status."""
  require_nvim_version(executable)
  env = isolated_environment(temporary)
  env["NVCAT_SESSION"] = json.dumps({"paths": paths, "path": str(path), "filetype": filetype,
                                           "syntax": syntax, "follow": follow})
  command = nvim_command(executable, "-c", "lua nvcat.pager(vim.json.decode(vim.env.NVCAT_SESSION))")
  # Keys come from the terminal even when the document came from stdin.
  keyboard = None if sys.stdin.isatty() else open("/dev/tty", "rb")
  # Neovim puts the terminal in raw mode, so Ctrl-C reaches it as a key; ignore any stray SIGINT here.
  previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
  process = None
  try:
    process = subprocess.Popen(command, cwd=temporary, env=env, stdin=keyboard)
    register_child(process.pid)
    return process.wait()
  finally:
    signal.signal(signal.SIGINT, previous)
    if process and process.poll() is None:  # Cancelled (SIGTERM/SIGHUP) while the pager was open.
      process.terminate()
      try:
        process.wait(timeout=2)
      except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    if keyboard:
      keyboard.close()


def version():
  try:
    return VERSION_FILE.read_text(encoding="utf-8").strip()
  except OSError:
    return "unknown"


def positive(value):
  number = int(value)
  if number < 1:
    raise argparse.ArgumentTypeError("Expected a positive integer")
  return number


def environment_number(parser, name):
  """A whole number from the environment variable name, 0 when unset or empty; a usage error otherwise."""
  value = os.environ.get(name, "").strip()
  if not value:
    return 0
  if not value.isdecimal():
    parser.error(f"{name} must be a whole number, got {value!r}")
  return int(value)


def main():
  timings = Timings()
  timings.since("python imports", STARTED)
  parser = HelpParser(prog="nvcat", description="Print a file as Neovim shows it, with your theme and Markdown rendering: "
                      "a cat, a pager and an fzf preview.",
                      epilog="nvcat completions bash|zsh|fish prints a shell completion script.")
  if sys.argv[1:] == ["--check"]:
    return check()
  if sorted(sys.argv[1:]) == ["--all", "--check"]:
    return check(installed=True)
  parser.add_argument("-v", "--version", action="version", version=f"nvcat {version()}")
  parser.add_argument("file", type=Path, nargs="?",
                      help="File to render, or - for stdin; without one, stdin when it is not a terminal")
  parser.add_argument("--filetype", help="Neovim filetype; defaults to the filetypes.json match, then Neovim "
                      "detection, then markdown (stdin: markdown). auto: Neovim detects, and a filetype "
                      "outside nvcat's tables goes to bat (as for --fallback)")
  parser.add_argument("--columns", type=positive, help="Output width; defaults to fzf or terminal width")
  mode = parser.add_mutually_exclusive_group()
  mode.add_argument("--lines", type=positive, help="Emit one viewport with this many rows")
  mode.add_argument("--all", action="store_true", help=f"Emit the complete document, up to {MAX_ROWS} screen rows")
  parser.add_argument("--start-line", type=positive, default=1, help="First source line for a viewport")
  parser.add_argument("--paging", choices=["auto", "always", "never"], default="auto",
                      help="Page the complete document. auto pages when stdout is a terminal outside fzf and "
                      "Neovim and the output is taller than the screen")
  parser.add_argument("-c", "--cat", dest="paging", action="store_const", const="never",
                      help="Print without paging; the same as --paging=never (the last of the two wins)")
  parser.add_argument("-f", "--follow", action="store_true",
                      help="Page the file and reload it as it changes, staying at the end while the cursor is on "
                      "the last line (like less +F). Needs the nvim pager, a terminal and a file")
  parser.add_argument("--pager", help="nvim (built-in Neovim pager), less (less -R), or a pager command line; "
                      "defaults to the configured pager (NVCAT_PAGER), then nvim")
  parser.add_argument("--color", choices=COLORS,
                      help="Color and other escape sequences in the output. always: also when piped; never: the text as "
                      "laid out; auto: on a terminal, in fzf previews and in Neovim. Defaults to the configured color "
                      "(NVCAT_COLOR), then NO_COLOR, then always")
  parser.add_argument("--hyperlinks", choices=HYPERLINKS,
                      help="OSC 8 hyperlinks for Markdown links. auto (default): on, except when a pager command "
                      "other than less may show the output; defaults to the configured hyperlinks (NVCAT_HYPERLINKS)")
  parser.add_argument("--budget", type=float, default=5.0,
                      help="Seconds allowed for complete output before falling back (default: 5; 0 disables)")
  parser.add_argument("--fallback", choices=["bat", "none"], default="bat",
                      help="Renderer used when the input size, row, --budget or --timeout limit is reached "
                      "(default: bat)")
  parser.add_argument("--nvim", help="Neovim executable; defaults to the configured nvim, then PATH")
  parser.add_argument("--check", action="store_true",
                      help="Print the resolved configuration and dependency versions, compile the Tree-sitter "
                      "queries of the filetype table's languages (with --all: of every installed parser), then exit")
  parser.add_argument("--timeout", type=positive, default=8,
                      help="Seconds Neovim may take per render step before the fallback (default: 8)")
  parser.add_argument("--syntax", choices=["auto", "regex"], default="auto",
                      help="auto: Tree-sitter when the language has a highlights query, else Vim's regex syntax; "
                      "regex: always Vim's regex syntax (Markdown then skips render-markdown); a modeline "
                      "with only syn=FILETYPE selects regex for that filetype")
  parser.add_argument("--filetypes", action="store_true",
                      help="List the filetypes nvcat handles, then exit: filetype, table (filetypes.json, or "
                      "regex for the generated filetypes.regex.json), globs, and the globs Neovim may detect as "
                      "the filetype by content, tab-separated; filetypes with globs first, in match order")
  report = parser.add_mutually_exclusive_group()
  report.add_argument("--timings", dest="timings", action="store_const", const="table",
                      help="After rendering, print per-phase timings and peak memory to stderr")
  report.add_argument("--timings-json", dest="timings", action="store_const", const="json",
                      help="Like --timings, as one JSON object")
  # `completions SHELL` is two arguments, so it cannot be a file; `nvcat completions` alone still opens one of that name.
  if sys.argv[1:2] == ["completions"] and (len(sys.argv) == 3 or not os.path.exists("completions")):
    return print_completions(parser, sys.argv[2:])
  args = parser.parse_args()
  if args.filetypes:
    return list_filetypes()
  if args.file is None and not args.check:
    if sys.stdin.isatty():
      parser.error("a file is required (or pipe the input into nvcat)")
    args.file = Path("-")
  args.fzf_columns = environment_number(parser, "FZF_PREVIEW_COLUMNS")
  args.fzf_lines = environment_number(parser, "FZF_PREVIEW_LINES")
  try:
    return run(args, timings)
  finally:
    if args.timings:
      emit_timings(args.timings, timings)


def list_filetypes():
  """Print one line per filetype: those with globs of their own in match order (a filetype split over several
  entries is merged), then those only Neovim's content detection gives, by name. The fourth column has the
  globs Neovim detects by content ('auto' entries) that can give the filetype."""
  generated = {id(entry) for entry in filetypes.load(filetypes.GENERATED)}
  rows, detected = {}, {}
  for entry in filetypes.ordered():
    patterns = ([f"*.{extension}" for extension in entry.get("extensions", [])] + entry.get("names", [])
                + entry.get("paths", []))
    if entry["filetype"] == filetypes.AUTO:
      for name in entry["detect"]:
        detected.setdefault(name, []).extend(patterns)
      continue
    table = "regex" if id(entry) in generated else "filetypes.json"
    globs = rows.setdefault(entry["filetype"], [table, []])[1]
    globs.extend(glob for glob in patterns if glob not in globs)
  for name in sorted(detected.keys() - rows.keys()):
    rows[name] = ["regex", []]
  try:
    for filetype, (table, globs) in rows.items():
      print(f"{filetype}\t{table}\t{' '.join(globs)}\t{' '.join(detected.get(filetype, []))}")
    sys.stdout.flush()
  except BrokenPipeError:
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
  return 0


HELP_HEADING, HELP_FLAG, HELP_VALUE, HELP_RESET = "\x1b[1;33m", "\x1b[36m", "\x1b[32m", "\x1b[0m"
HELP_FLAGS = re.compile(r"(?<![\w-])--?[a-zA-Z][\w-]*")


def help_color():
  """Whether --help is in color: as for output, except that with nothing set a pipe gets plain text, since help is
  not a preview."""
  mode = None
  for index, argument in enumerate(sys.argv):
    if argument.startswith("--color="):
      mode = argument.split("=", 1)[1]
    elif argument == "--color" and index + 1 < len(sys.argv):
      mode = sys.argv[index + 1]
  try:
    mode = mode or config.load()[0]["color"]
    return use_color(mode) if mode else sys.stdout.isatty() and not os.environ.get("NO_COLOR")
  except (PreviewError, config.ConfigError):
    return False


def color_help(text):
  """Color finished help text; argparse's wrapping has already happened, so the codes cannot disturb its columns."""
  lines, usage = [], False
  for line in text.split("\n"):
    usage = line.startswith("usage:") or (usage and bool(line.strip()))
    entry = re.fullmatch(r"  (\S.*?)(\s{2,}\S.*|)", line)
    if usage:
      name, rest = line.split(":", 1) if line.startswith("usage:") else ("", line)
      rest = HELP_FLAGS.sub(lambda match: f"{HELP_FLAG}{match[0]}{HELP_RESET}", rest)
      line = f"{HELP_HEADING}{name}:{HELP_RESET}{rest}" if name else rest
    elif re.fullmatch(r"[a-z][a-z ]*:", line):
      line = f"{HELP_HEADING}{line}{HELP_RESET}"
    elif entry:
      words = [f"{HELP_FLAG if word[0] == '-' else HELP_VALUE}{word}{HELP_RESET}" for word in entry[1].split(" ")]
      line = f"  {' '.join(words)}{entry[2]}"
    lines.append(line)
  return "\n".join(lines)


class HelpParser(argparse.ArgumentParser):
  def __init__(self, *arguments, **keywords):
    super().__init__(*arguments, **keywords)
    self.color = False  # Python 3.14's own help color would color what color_help() colors.

  def format_help(self):
    text = super().format_help()
    return color_help(text) if help_color() else text


def print_completions(parser, arguments):
  import completions
  if len(arguments) != 1 or arguments[0] not in completions.SHELLS:
    parser.error(f"completions needs one shell: {', '.join(completions.SHELLS)}")
  sys.stdout.write(completions.script(arguments[0], parser))
  return 0


def emit_timings(form, timings):
  text = json.dumps(timings.report()) + "\n" if form == "json" else timings.table()
  sys.stderr.write(text)
  sys.stderr.flush()


def run(args, timings):
  start = time.monotonic_ns()
  if args.check:
    return check(installed=args.all)
  try:
    settings = config.load()[0]
  except config.ConfigError as error:
    raise PreviewError(str(error)) from error
  start = timings.since("config", start)
  if args.nvim:
    settings["nvim"] = args.nvim
  pager = resolve_pager(args.pager or settings["pager"])
  width = args.columns or args.fzf_columns or shutil.get_terminal_size().columns
  fzf_lines = args.fzf_lines
  all_rows = args.all or (args.lines is None and not fzf_lines and args.start_line == 1)
  height = args.lines or fzf_lines or shutil.get_terminal_size().lines
  if not 10 <= width <= 500 or not 1 <= height <= MAX_ROWS:
    raise PreviewError(f"Supported dimensions: 10–500 columns, 1–{MAX_ROWS} lines")
  if args.all and args.start_line != 1:
    raise PreviewError("--all cannot be combined with --start-line")
  if args.paging == "always":
    if args.lines is not None or args.start_line != 1:
      raise PreviewError("--paging=always pages the complete document; remove --lines and --start-line")
    all_rows = True
  args.use_color = use_color(args.color or settings["color"])
  links = args.use_color and hyperlinks(args.hyperlinks or settings["hyperlinks"], pager, args.paging, all_rows)
  if pager == "nvim" and not args.use_color and not args.follow:
    pager = resolve_pager("less")  # Neovim's own screen would be in color.
  paths = find_paths(settings)
  start = timings.since("config", start)
  with run_directory() as temporary:
    if str(args.file) == "-":
      path = Path(temporary) / "stdin.md"
      with open(path, "wb") as handle:
        handle.write(sys.stdin.buffer.read(MAX_BYTES + 1))
        if handle.tell() > MAX_BYTES:  # Keep the rest for the fallback renderer.
          shutil.copyfileobj(sys.stdin.buffer, handle)
    else:
      path = input_path(args.file)
    filetype = resolve_filetype(args.filetype, None if str(args.file) == "-" else args.file)
    auto = filetype is not None and "accept" in filetype
    # A syn=-only modeline naming the filetype shown: Vim's regex syntax, as Vim itself shows that file.
    if (args.syntax == "auto" and filetype and not auto and str(args.file) != "-"
        and filetypes.regex_modeline(args.file, filetype["filetype"])):
      args.syntax = "regex"
    timings.since("input and filetype", start)
    viewport = None if all_rows else height
    if args.follow:
      if str(args.file) == "-":
        raise PreviewError("--follow needs a file, not stdin")
      if pager != "nvim":
        raise PreviewError("--follow needs the nvim pager (--pager nvim)")
      if args.paging == "never" or args.lines or args.start_line != 1:
        raise PreviewError("--follow pages the whole file; it cannot be combined with --paging=never, --lines "
                           "or --start-line")
      if not sys.stdout.isatty():
        raise PreviewError("--follow needs a terminal on stdout")
      # The pager has no grid or row limits, and a followed log may grow past MAX_BYTES.
      restrict_writes(temporary)
      timings.facts["pager"] = "nvim (not timed)"
      # A followed file is shown whatever Neovim detects: there is no bat to hand it to once the pager runs.
      return page_nvim(settings["nvim"], paths, temporary, path, None if auto else filetype, args.syntax,
                       follow=True)
    size = path.stat().st_size
    if size > MAX_BYTES:
      error = TooLarge(f"input is {size / 1048576:.1f} MiB, over the {MAX_BYTES // 1048576} MiB limit")
      output = fall_back(error, args, path, width, filetype, viewport, timings)
      return emit(output, args, all_rows, pager, timings, temporary, fallback=True)
    with open(path, "rb") as handle:
      binary = b"\0" in handle.read(BINARY_PROBE)
    if binary:  # Neovim would show the raw control bytes; bat prints a notice instead.
      output = fall_back(TooLarge("binary input"), args, path, width, filetype, viewport, timings)
      return emit(output, args, all_rows, pager, timings, temporary, fallback=True)
    if pager == "nvim" and wants_pager(args.paging, all_rows) and sys.stdout.isatty():
      restrict_writes(temporary)
      if args.paging == "auto" or auto:
        # Probe with one screen: a document that fits is printed as is, a taller one opens the pager. With
        # --filetype auto the probe also checks Neovim's filetype before the pager, which cannot fall back.
        lines = shutil.get_terminal_size().lines
        renderer = None
        try:
          renderer = Renderer(settings["nvim"], paths, temporary, width, lines, args.timeout, timings, args.syntax,
                              links, args.use_color)
          output, info = renderer.render(path, width, lines, 1, False, filetype)
        except (TimedOut, Unsupported) as error:
          if renderer:
            renderer.close()
          output = fall_back(error, args, path, width, filetype, None, timings)
          return emit(output, args, all_rows, pager, timings, temporary, fallback=True)
        finally:
          if renderer:
            renderer.close()
        if args.paging == "auto" and info["total_height"] <= lines:
          sys.stdout.buffer.write(output)
          sys.stdout.buffer.flush()
          return 0
      timings.facts["pager"] = "nvim (not timed)"
      # The probe accepted Neovim's filetype, and the pager's own detection reaches the same one.
      return page_nvim(settings["nvim"], paths, temporary, path, None if auto else filetype, args.syntax)
    if all_rows:
      # Start near the final size: every full redraw costs rows x injected trees, and resizing a short grid to
      # fit adds one. Wrapping and virtual rows can still need a resize.
      with open(path, "rb") as handle:
        source_rows = sum(chunk.count(b"\n") for chunk in iter(lambda: handle.read(1 << 16), b"")) + 1
      height = max(height, min(MAX_ROWS, source_rows + 4))
    restrict_writes(temporary)
    renderer = None
    fallback = False
    try:
      renderer = Renderer(settings["nvim"], paths, temporary, width, height, args.timeout, timings, args.syntax,
                          links, args.use_color)
      output, _ = renderer.render(path, width, height, args.start_line, all_rows, filetype, args.budget)
    except TooLarge as error:
      if renderer:
        renderer.close()
      output = fall_back(error, args, path, width, filetype, viewport, timings, args.start_line)
      fallback = True
    finally:
      if renderer:
        renderer.close()
    # Inside the run directory's lifetime: an external pager gets it as TMPDIR, the only place it may write.
    return emit(output, args, all_rows, pager, timings, temporary, fallback)


def fall_back(error, args, path, width, filetype, viewport, timings, start_line=1):
  """bat's output in place of a render that hit a limit, with a notice; re-raise when there is no fallback."""
  if args.fallback == "none":
    raise error
  if not shutil.which("bat"):
    raise PreviewError(f"{error}; bat, the fallback renderer, is not installed")
  if not isinstance(error, Unsupported):  # --filetype auto asked for bat in that case; no notice.
    print(f"nvcat: {error}; showing bat output instead (--fallback=none to fail)", file=sys.stderr)
  with timings.phase("bat fallback"):
    try:
      output = fallback_bat(path, width, (filetype or {}).get("filetype"), start_line, viewport, args.use_color)
    except subprocess.CalledProcessError as failure:
      raise PreviewError(f"{error}; the bat fallback failed with exit status {failure.returncode}") from None
  timings.facts["engine"] = "bat fallback"
  return output


def emit(output, args, all_rows, pager, timings, temporary, fallback=False):
  if should_page(args.paging, all_rows, output):
    if pager == "nvim":
      if fallback and sys.stdout.isatty():  # bat's output is ANSI text, which the Neovim pager cannot show.
        return page(output, resolve_pager("less"), temporary)
      # --paging=always without a terminal: nothing to show a pager on, so print.
      sys.stdout.buffer.write(output)
      sys.stdout.buffer.flush()
      return 0
    return page(output, pager, temporary)
  with timings.phase("write output"):
    sys.stdout.buffer.write(output)
    sys.stdout.buffer.flush()
  return 0


def cancel(*_):
  raise Cancelled()


def command():
  """The nvcat command: main() with its signal handling and exit statuses."""
  sys.stderr = SafeStderr(sys.stderr)
  signal.signal(signal.SIGTERM, cancel)
  signal.signal(signal.SIGHUP, cancel)
  try:
    raise SystemExit(main())
  except BrokenPipeError:
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    raise SystemExit(0)
  except (KeyboardInterrupt, Cancelled):
    raise SystemExit(130)
  except (PreviewError, OSError, ValueError) as error:
    print(f"nvcat: {error}", file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
  command()
