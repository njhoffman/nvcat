#!/usr/bin/env bats
# End-to-end rendering through Neovim. Skipped when nvcat --check reports missing required dependencies;
# filetypes with neither a parser nor a Vim syntax file here are skipped by name.

bats_require_minimum_version 1.5.0

setup_file() {
  local report
  report=$("$BATS_TEST_DIRNAME/../nvcat" --check 2>&1) ||
    skip "nvcat --check failed: $(grep -E '^(error|  error)' <<<"$report" | head -3 | tr '\n' ' ')"
  # Languages --check shows with regex syntax (no parser or highlights query on this machine).
  REGEX_LANGS=" $(sed -n 's/^  regex syntax *\([^(]*\).*/\1/p' <<<"$report" | tr -d ',') "
  export REGEX_LANGS
  # These tests count colors, so they use a theme that has them whatever this machine's config is.
  export NVCAT_THEME=$BATS_TEST_DIRNAME/helpers/theme.lua
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  FIXTURES=$BATS_TEST_DIRNAME/fixtures
}

colors() {
  grep -o '38;2;[0-9;]*m' <<<"$1" | sort -u | wc -l
}

render_entry() {
  local filetype=$1 file
  file=$(find "$FIXTURES/$filetype" -type f ! -name Chart.yaml ! -name 'plain.*' | sort | head -1)
  run "$NVCAT" --columns 80 --all --filetype "$filetype" -- "$file" < /dev/null
  [ "$status" -eq 0 ] || { echo "$filetype: $output"; return 1; }
  checked=$((checked + 1))
  if [ "$(colors "$output")" -lt 3 ]; then
    # Regex syntax without a Vim syntax file for it: nothing to highlight with on this machine.
    if [[ $REGEX_LANGS == *" $2 "* ]]; then
      unsupported+=("$filetype")
      return 0
    fi
    echo "$filetype: only $(colors "$output") colors"
    return 1
  fi
}

@test "every filetype entry renders with highlighting" {
  unsupported=()
  checked=0
  while read -r filetype lang; do
    render_entry "$filetype" "$lang"
  done < <(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import filetypes
for e in filetypes.load(): print(e["filetype"], e.get("lang", e["filetype"]))' "$ROOT")
  [ "$checked" -eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import filetypes; print(len(filetypes.load()))' "$ROOT")" ]
  if ((${#unsupported[@]})); then
    skip "the rest rendered; no parser or Vim syntax here for: ${unsupported[*]}"
  fi
}

@test "regex-syntax filetypes highlight comments" {
  run "$NVCAT" --columns 80 --all --filetype tmux -- "$FIXTURES/tmux/.tmux.conf"
  [ "$status" -eq 0 ]
  first=$(head -1 <<<"$output")
  [[ $first == *$'\e[0;3;'* ]]  # Comment is italic in helpers/theme.lua
  [[ $first == *'# prefix'* ]]
}

@test "the table detects the filetype when --filetype is omitted" {
  run "$NVCAT" --columns 80 --all -- "$FIXTURES/kdl/config.kdl"
  [ "$status" -eq 0 ]
  [ "$(colors "$output")" -ge 3 ]
}

@test "files outside the table use Neovim detection" {
  run "$NVCAT" --columns 80 --all -- "$FIXTURES/bat/script.py"
  [ "$status" -eq 0 ]
  [ "$(colors "$output")" -ge 3 ]
}

@test "stdin renders as Markdown" {
  run bash -c "'$NVCAT' --columns 40 - < '$FIXTURES/markdown/sample.md'"
  [ "$status" -eq 0 ]
  [[ $output == *'Title'* ]]
  [[ $output == *'item'* ]]
}

@test "Markdown fixture renders headings and code" {
  run "$NVCAT" --columns 60 --all -- "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 0 ]
  [[ $output == *'Title'* ]]
  [[ $output == *'print'* ]]
}

@test "viewport rendering works for non-Markdown files" {
  run "$NVCAT" --columns 60 --lines 2 --filetype just -- "$FIXTURES/just/justfile"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "start line past the end fails cleanly" {
  run "$NVCAT" --columns 60 --lines 5 --start-line 999 --filetype kdl -- "$FIXTURES/kdl/config.kdl"
  [ "$status" -eq 1 ]
  [[ $output == *'exceeds document length'* ]]
}

@test "dispatch renders through the real nvcat" {
  NVCAT=$ROOT/nvcat run "$ROOT/nvcat-dispatch" "$FIXTURES/tmux/.tmux.conf"
  [ "$status" -eq 0 ]
  [ "$(colors "$output")" -ge 3 ]
}

@test "a viewport of a 600-row table renders (conceal_lines per-line hook disabled)" {
  table=$BATS_TEST_TMPDIR/table.md
  { echo '| a | b | c | d |'; echo '|---|---|---|---|'
    for i in $(seq 1 600); do echo "| \`f$i\` | \`.e$i\`, 1 pattern | \`p\` |  |"; done; } > "$table"
  run "$NVCAT" --paging=never --columns 120 --lines 20 --timeout 3 -- "$table"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 20 ]
}

@test "back-to-back renders are not dropped by render-markdown's debounce" {
  # Two renders on one Neovim land well inside a 50 ms debounce window; a throttled update never signals.
  run python3 - "$ROOT" "$FIXTURES/markdown/sample.md" <<'PY'
import importlib.machinery, importlib.util, shutil, sys, tempfile
root, path = sys.argv[1], sys.argv[2]
sys.path.insert(0, root)
loader = importlib.machinery.SourceFileLoader("nvcat_module", root + "/nvcat_cli.py")
spec = importlib.util.spec_from_loader("nvcat_module", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
    renderer = module.Renderer(shutil.which("nvim"), module.find_paths(), temporary, 80, 10, 4)
    try:
        for _ in range(3):
            renderer.render(path, 80, 10, 1, True, {"filetype": "markdown", "lang": "markdown"})
    finally:
        renderer.close()
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "--syntax regex applies to filetypes whose ftplugin starts Tree-sitter (Lua)" {
  printf -- '-- comment\nlocal x = "s"\n' > "$BATS_TEST_TMPDIR/sample.lua"
  treesitter=$("$NVCAT" --paging=never --columns 40 "$BATS_TEST_TMPDIR/sample.lua")
  run --separate-stderr "$NVCAT" --paging=never --columns 40 --syntax regex --timings-json \
    "$BATS_TEST_TMPDIR/sample.lua"
  [ "$status" -eq 0 ]
  [[ $stderr == *'"engine": "syntax"'* ]]
  [ "$output" != "$treesitter" ]
}
