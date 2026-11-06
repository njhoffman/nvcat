#!/usr/bin/python3
"""Check code-fence highlighting for every supported language and alias.

Renders one document with a fenced block per label, finds each block's code row in the screen grid, and checks
it has at least three foreground colors including the theme's String color. Prints one line per label; exits 1
on the first failure. Usage: languages.py WIDTH
"""

import shutil
import sys
import tempfile
from pathlib import Path

from common import load_nvcat
from has_parser import available

SNIPPETS = {
  "c": 'const char *message = "hello"; // comment',
  "cpp": 'std::string message = "hello"; // comment',
  "rust": 'let message = "hello"; // comment',
  "bash": 'echo "hello" # comment',
  "go": 'var message = "hello" // comment',
  "python": 'message = "hello" # comment',
  "javascript": 'const message = "hello"; // comment',
  "sql": "SELECT 'hello' AS message; -- comment",
}
ALIASES = {"c++": "cpp", "cxx": "cpp", "cc": "cpp", "sh": "bash", "shell": "bash", "js": "javascript",
           "py": "python"}
# A language with no parser here has plain code fences, which is correct on such a machine.
INSTALLED = available(SNIPPETS)
CASES = {**SNIPPETS, **{alias: SNIPPETS[target] for alias, target in ALIASES.items()}}
for name in list(CASES):
  if ALIASES.get(name, name) not in INSTALLED:
    print(f"skip {name} no parser")
    del CASES[name]

module = load_nvcat()
width = int(sys.argv[1])
marker = lambda name: f"VERIFY_{name}_CASE"
with tempfile.TemporaryDirectory(prefix="nvcat-languages-") as work:
  path = Path(work) / "languages.md"
  path.write_text("".join(f"## {marker(name)}\n\n```{name}\n{code}\n```\n\n" for name, code in CASES.items())
                  + "END_LANGUAGES\n")
  renderer = module.Renderer(shutil.which("nvim"), module.find_paths(), work, width, 40, 8)
  try:
    renderer.render(path, width, 40, all_rows=True)
    string = renderer.request("nvim_exec_lua", 'return vim.api.nvim_get_hl(0, {name = "String", link = false}).fg', [])
    text = ["".join(cell[0] for cell in row).strip() for row in renderer.grid]
    assert any("END_LANGUAGES" in line for line in text), "document tail missing"
    for name, code in CASES.items():
      begin = next(i for i, line in enumerate(text) if marker(name) in line)
      end = next((i for i in range(begin + 1, len(text)) if "VERIFY_" in text[i]), len(text))
      row = next((renderer.grid[i] for i in range(begin + 1, end) if text[i] == code), None)
      assert row is not None, f"{name}: code row not found"
      colors = {renderer.highlights.get(group, {}).get("foreground", renderer.defaults[0])
                for value, group in row if value.strip()}
      assert len(colors) >= 3, f"{name}: only {len(colors)} colors"
      assert string is None or string in colors, f"{name}: String color #{string:06x} missing"
      print(f"ok {name} {len(colors)} colors")
    assert not renderer.errors, renderer.errors
  finally:
    renderer.close()
