"""Filetype table shared by nvcat, gen-dispatch and gen-filetypes; see filetypes.json, filetypes.regex.json and
filetypes.bat.json."""

from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re

TABLE = Path(__file__).resolve().parent / "filetypes.json"
GENERATED = Path(__file__).resolve().parent / "filetypes.regex.json"
CLAIMS = Path(__file__).resolve().parent / "filetypes.bat.json"
AUTO = "auto"  # The filetype of generated entries that Neovim detects by content (see gen-filetypes).
HEAD_LINES = 40
_cache = {}


def load(table=TABLE):
  """The entries of one table file, in file order: by default the hand-maintained filetypes.json."""
  table = Path(table)
  if table not in _cache:
    try:
      with open(table, encoding="utf-8") as handle:
        _cache[table] = json.load(handle)["filetypes"]
    except FileNotFoundError:
      if table == GENERATED:
        _cache[table] = []
      else:
        raise
  return _cache[table]


def ordered():
  """Every entry in match order: filetypes.json, then filetypes.regex.json, then the entries marked 'last'."""
  if "ordered" in _cache:
    return _cache["ordered"]
  curated = load()
  _cache["ordered"] = ([entry for entry in curated if not entry.get("last")] + load(GENERATED)
                        + [entry for entry in curated if entry.get("last")])
  return _cache["ordered"]


def globs(entry):
  """Bash case patterns for an entry, matched case-insensitively against an absolute path."""
  patterns = [f"*.{extension}" for extension in entry.get("extensions", [])]
  for name in entry.get("names", []):
    patterns += [name, f"*/{name}"]
  patterns += entry.get("paths", [])
  return patterns


def requirement_met(entry, path):
  requires = entry.get("requires", {})
  if "ancestor_file" in requires:
    if "/templates/" not in path:
      return False
    if not os.path.isfile(path.rsplit("/templates/", 1)[0] + "/" + requires["ancestor_file"]):
      return False
  if "head_regex" in requires:
    pattern = re.compile(requires["head_regex"], re.IGNORECASE)
    try:
      with open(path, encoding="utf-8", errors="replace") as handle:
        head = [line for _, line in zip(range(HEAD_LINES), handle)]
    except OSError:
      return False
    if not any(pattern.search(line) for line in head):
      return False
  return True


def absolute(path):
  path = os.fspath(path)
  return path if path.startswith("/") else os.path.join(os.getcwd(), path)


def _index(entries):
  """Lowercase globs by kind: {literal suffix: [entry indexes]} for '*literal' globs, and (index, head, tail,
  glob) for the rest, whose literal head and tail are checked before fnmatch compiles anything."""
  suffixes, others = {}, []
  for index, entry in enumerate(entries):
    for pattern in globs(entry):
      pattern = pattern.lower()
      wildcards = [position for position, character in enumerate(pattern) if character in "*?["]
      if wildcards == [0]:
        suffixes.setdefault(pattern[1:], []).append(index)
      elif not wildcards:
        others.append((index, pattern, pattern, None))
      else:
        tail = "" if "[" in pattern else pattern[wildcards[-1] + 1:]
        others.append((index, pattern[:wildcards[0]], tail, pattern))
  return suffixes, others


def detect(path, entries=None):
  """Return the first entry matching path, mirroring the generated nvcat-dispatch."""
  if entries is None:
    # As in nvcat-dispatch, bat's claims come first, then filetypes.json, whose matches need no generated table.
    if detect(path, claims()):
      return None
    curated = [entry for entry in load() if not entry.get("last")]
    return detect(path, curated) or detect(path, ordered())
  key = ("index", id(entries))
  if key not in _cache or _cache[key][0] is not entries:
    _cache[key] = (entries, _index(entries))
  suffixes, others = _cache[key][1]
  path = absolute(path)
  folded = path.lower()
  hits = set()
  for start in range(len(folded) + 1):
    hits.update(suffixes.get(folded[start:], ()))
  for index, head, tail, pattern in others:
    if index not in hits and folded.startswith(head) and folded.endswith(tail) and (
        folded == head if pattern is None else fnmatchcase(folded, pattern)):
      hits.add(index)
  for index in sorted(hits):
    if requirement_met(entries[index], path):
      return entries[index]
  return None


def claims():
  """bat's file names and globs that an entry would otherwise take, as written by gen-dispatch: entries with
  "paths" only, so detect can match them."""
  if "claims" not in _cache:
    try:
      with open(CLAIMS, encoding="utf-8") as handle:
        claimed = json.load(handle)["claims"]
    except FileNotFoundError:
      claimed = []
    _cache["claims"] = [{"filetype": syntax, "paths": [glob]} for syntax, glob in claimed]
  return _cache["claims"]


def accepted():
  """Filetypes nvcat renders for --filetype auto: every table filetype and every possible 'auto' result."""
  if "accepted" not in _cache:
    _cache["accepted"] = {"markdown"} | {name for entry in ordered()
                                         for name in [entry["filetype"], *entry.get("detect", [])]} - {AUTO}
  return _cache["accepted"]


def find(filetype, entries=None):
  for entry in ordered() if entries is None else entries:
    if entry["filetype"] == filetype:
      return entry
  return None


def bat_patterns():
  """Return (version, [(syntax, glob)]) for every file name, path, and glob bat claims, --map-syntax included."""
  import subprocess
  version = subprocess.run(["bat", "--version"], capture_output=True, text=True, check=True).stdout.split()[1]
  listing = subprocess.run(["bat", "--list-languages"], capture_output=True, text=True, check=True).stdout
  lines = [line.split(":", 1) for line in listing.splitlines() if ":" in line]
  config = subprocess.run(["bat", "--config-file"], capture_output=True, text=True, check=True).stdout.strip()
  if Path(config).is_file():
    for glob, syntax in re.findall(r'--map-syntax[= ]"?([^":\s]+):([^"\n]+)"?', Path(config).read_text()):
      lines.append([syntax.strip(), glob])
  patterns = []
  for syntax, tokens in lines:
    for token in tokens.split(","):
      token = token.strip()
      if not token:
        continue
      if "/" in token or "*" in token:
        glob = token.replace("/**/", "/*").replace("**/", "*/").replace("**", "*")
        patterns.append((syntax, glob if glob.startswith(("/", "*")) else "*/" + glob))
      else:
        patterns += [(syntax, f"*.{token}"), (syntax, token), (syntax, f"*/{token}")]
  return version, patterns


def sample(pattern):
  """An absolute path a glob matches, with every * replaced by x."""
  return ("/" if not pattern.startswith("/") else "") + pattern.replace("*", "x")
