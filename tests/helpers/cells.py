#!/usr/bin/python3
"""Terminal cell widths of nvcat output read on stdin, with SGR and OSC 8 sequences removed.

cells.py WIDTH: print each line wider than WIDTH cells (with its width) and exit 1 if there is one.
cells.py --widths: print every line's width.

Widths follow Neovim's grid for the text the fixtures use: combining marks, variation selectors and
zero-width joiners take no cell, East Asian wide and fullwidth characters (emoji among them) take two, and
everything else, Nerd Font icons in the Private Use Area included, takes one."""

import re
import sys
import unicodedata

ESCAPES = re.compile(r"\x1b\[[0-9;:]*m|\x1b\]8;[^\x1b]*\x1b\\")


def width(text):
  total = 0
  for character in ESCAPES.sub("", text):
    if unicodedata.combining(character) or unicodedata.category(character) in ("Mn", "Me", "Cf"):
      continue
    total += 2 if unicodedata.east_asian_width(character) in ("W", "F") else 1
  return total


def main():
  lines = sys.stdin.read().split("\n")
  if lines and lines[-1] == "":
    lines.pop()
  if sys.argv[1:] == ["--widths"]:
    for line in lines:
      print(width(line))
    return 0
  limit = int(sys.argv[1])
  wide = [(number, width(line), line) for number, line in enumerate(lines, 1) if width(line) > limit]
  for number, cells, line in wide:
    print(f"line {number}: {cells} cells: {ESCAPES.sub('', line)}")
  return 1 if wide else 0


if __name__ == "__main__":
  raise SystemExit(main())
