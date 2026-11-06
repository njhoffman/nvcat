"""Shared helpers for the Python parts of the bats suite: load nvcat as a module, find its Neovims."""

import importlib.machinery
import importlib.util
import os
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
# tests/setup_suite.bash sets this for the suite; a helper run alone tags its own children.
SESSION = os.environ.setdefault("NVCAT_TEST_SESSION", uuid.uuid4().hex)


def load_nvcat():
  loader = importlib.machinery.SourceFileLoader("nvcat_module", str(ROOT / "nvcat_cli.py"))
  spec = importlib.util.spec_from_loader("nvcat_module", loader)
  module = importlib.util.module_from_spec(spec)
  loader.exec_module(module)
  return module


def embedded_nvims():
  """PIDs of Neovim processes started under this test session by this checkout's nvcat (its profile.lua).

  The session tag is in the environment rather than the process tree: the installed nvcat links to this checkout,
  so a render in another shell also matches profile.lua, and a Neovim that outlives nvcat is reparented, which is
  the leak these checks are there to catch."""
  marker = str(ROOT / "profile.lua").encode()
  tag = f"NVCAT_TEST_SESSION={SESSION}".encode()
  pids = set()
  for entry in os.listdir("/proc"):
    if not entry.isdigit():
      continue
    try:
      arguments = Path(f"/proc/{entry}/cmdline").read_bytes().split(b"\0")
      state = Path(f"/proc/{entry}/stat").read_text().rsplit(")", 1)[1].split()[0]
      environment = Path(f"/proc/{entry}/environ").read_bytes().split(b"\0")
    except OSError:
      continue
    if b"--embed" in arguments and marker in arguments and state != "Z" and tag in environment:
      pids.add(int(entry))
  return pids
