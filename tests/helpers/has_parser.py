#!/usr/bin/python3
"""Exit 0 when nvcat's Neovim can load a Tree-sitter parser for every language named, for tests that need one: a machine
without it renders those filetypes with regex syntax, which is correct there. Usage: has_parser.py LANGUAGE..."""

import json
import subprocess
import sys

from common import ROOT  # Also puts the checkout on sys.path.
import config

# language.add returns nil for a parser it cannot find, and raises for a name it cannot use.
SCRIPT = """lua for _, name in ipairs(vim.json.decode(%r)) do
  local ok, loaded = pcall(vim.treesitter.language.add, name)
  if ok and loaded then io.stdout:write(name, " ") end
end"""


def available(languages):
  settings = config.load()[0]
  command = [settings["nvim"], "--clean", "--headless"]
  if settings["parser_dir"]:
    command += ["--cmd", f"set runtimepath^={settings['parser_dir']}"]
  command += ["-c", SCRIPT % json.dumps(list(languages)), "-c", "qa!"]
  return set(subprocess.run(command, capture_output=True, text=True, timeout=30, cwd=ROOT).stdout.split())


if __name__ == "__main__":
  raise SystemExit(0 if set(sys.argv[1:]) <= available(sys.argv[1:]) else 1)
