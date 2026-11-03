"""Shared helpers for the Python parts of the bats suite: load nvcat as a module, find its Neovims."""

import importlib.machinery
import importlib.util
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))


def load_nvcat():
  loader = importlib.machinery.SourceFileLoader("nvcat_module", str(ROOT / "nvcat_cli.py"))
  spec = importlib.util.spec_from_loader("nvcat_module", loader)
  module = importlib.util.module_from_spec(spec)
  loader.exec_module(module)
  return module


def embedded_nvims():
  """PIDs of Neovim processes started by this checkout's nvcat (identified by its profile.lua)."""
  marker = str(ROOT / "profile.lua").encode()
  pids = set()
  for entry in os.listdir("/proc"):
    if not entry.isdigit():
      continue
    try:
      arguments = Path(f"/proc/{entry}/cmdline").read_bytes().split(b"\0")
      state = Path(f"/proc/{entry}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except OSError:
      continue
    if b"--embed" in arguments and marker in arguments and state != "Z":
      pids.add(int(entry))
  return pids
