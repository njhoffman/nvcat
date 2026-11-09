#!/usr/bin/env bats
# The row index profile.lua adds to Neovim's Tree-sitter highlighter (NVCAT_HIGHLIGHT_INDEX): it applies on
# Neovim 0.12 and later until neovim#42735 (where NVCAT_HIGHLIGHT_INDEX=1 still forces it), reports why when it
# cannot, and never changes the output.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  NVIM=${NVCAT_NVIM:-$(command -v nvim)}
  FIXTURES=$BATS_TEST_DIRNAME/fixtures
}

# Run Lua in a clean headless Neovim with profile.lua loaded; LUA's io.write output is the result.
profile_lua() {
  local script=$BATS_TEST_TMPDIR/probe.lua
  printf '%s\n' "$1" "dofile('$ROOT/profile.lua')" "$2" >"$script"
  run "$NVIM" --clean --headless -l "$script"
}

# 0 when this Neovim is 0.12 or later, the first release with the highlighter's on_range path.
on_range_neovim() {
  "$NVIM" --version | head -1 | awk '{ split(substr($2, 2), v, "."); exit !(v[1] > 0 || v[2] >= 12) }'
}

# The same render with the index on and off.
same_output() {
  local indexed plain
  indexed=$(NVCAT_HIGHLIGHT_INDEX=1 "$NVCAT" --paging=never --columns 100 "$@") || return 1
  plain=$(NVCAT_HIGHLIGHT_INDEX=0 "$NVCAT" --paging=never --columns 100 "$@") || return 1
  [ -n "$indexed" ] || { echo "empty output: $*"; return 1; }
  [ "$indexed" = "$plain" ] || { echo "output differs with the index: $*"; return 1; }
}

# A Markdown table of n rows whose cells inject markdown_inline trees, as in docs/upstream.
table() {
  local n=$1 i
  printf '# Table\n\nSome `inline` text before it.\n\n| a | b | c | d |\n|---|---|---|---|\n'
  for ((i = 1; i <= n; i++)); do
    printf '| `f%d` | `.e%d`, *x* | `p` | **y** |\n' "$i" "$i"
  done
  printf '\n```lua\nlocal x = 1\n```\n\nAfter the `table`.\n'
}

@test "the highlighter internals the index relies on are present (fails when Neovim changes them)" {
  on_range_neovim || skip "Neovim before 0.12 has no on_range highlighter path"
  NVCAT_HIGHLIGHT_INDEX=1 profile_lua '' 'io.write(nvcat.index_highlighter())'
  [ "$status" -eq 0 ]
  [ "$output" = on ] || { echo "Neovim's highlighter changed: $output; update index_highlighter in profile.lua"; return 1; }
}

@test "before Neovim 0.12 the index reports itself unavailable" {
  on_range_neovim && skip "Neovim 0.12 or later"
  profile_lua '' 'io.write(nvcat.index_highlighter())'
  [ "$status" -eq 0 ]
  [ "$output" = "unavailable: TSHighlighter._on_range is missing" ]
}

@test "a highlighter without on_range_impl is left alone" {
  NVCAT_HIGHLIGHT_INDEX=1 profile_lua "package.loaded['vim.treesitter.highlighter'] = {
      _on_range = function() end, prepare_highlight_states = function() end,
      for_each_highlight_state = function() end }" \
    'io.write(nvcat.index_highlighter())'
  [ "$status" -eq 0 ]
  [ "$output" = "unavailable: TSHighlighter._on_range does not call on_range_impl" ]
}

@test "a highlighter that stores root ranges (neovim#42735) does not need the index" {
  stub="package.loaded['vim.treesitter.highlighter'] = {
      _on_range = function() end, for_each_highlight_state = function() end,
      prepare_highlight_states = function(self) self._highlight_states = { { root_range = {} } } end }"
  profile_lua "$stub" 'io.write(nvcat.index_highlighter())'
  [ "$status" -eq 0 ]
  [ "$output" = "not needed: Neovim's highlighter has the neovim#42735 fix" ]
  NVCAT_HIGHLIGHT_INDEX=0 profile_lua "$stub" 'io.write(nvcat.index_highlighter())'
  [ "$output" = off ]
  # =1 goes on to the remaining checks; this stub has no on_range_impl to patch.
  NVCAT_HIGHLIGHT_INDEX=1 profile_lua "$stub" 'io.write(nvcat.index_highlighter())'
  [ "$output" = "unavailable: TSHighlighter._on_range does not call on_range_impl" ]
}

@test "Neovim's own highlighter is detected as fixed or not by its root_range field" {
  on_range_neovim || skip "Neovim before 0.12 has no on_range highlighter path"
  profile_lua '' "local fixed = string.dump(require('vim.treesitter.highlighter').prepare_highlight_states)
      :find('root_range', 1, true) ~= nil
    io.write(tostring(fixed), ' ', nvcat.index_highlighter())"
  [ "$status" -eq 0 ]
  [[ $output == "false on" || $output == "true not needed: Neovim's highlighter has the neovim#42735 fix" ]]
}

@test "an on_range_impl that no longer walks the highlight states is left alone" {
  NVCAT_HIGHLIGHT_INDEX=1 profile_lua "local function on_range_impl(self) return self.other end
    package.loaded['vim.treesitter.highlighter'] = {
      _on_range = function(...) return on_range_impl(...) end,
      prepare_highlight_states = function(self) self._highlight_states = { tstree = 1 } end,
      for_each_highlight_state = function(self) return self._highlight_states end }" \
    'io.write(nvcat.index_highlighter())'
  [ "$status" -eq 0 ]
  [ "$output" = "unavailable: the highlighter no longer uses for_each_highlight_state" ]
}

@test "--timings-json reports the index, and NVCAT_HIGHLIGHT_INDEX=0 turns it off" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --all --timings-json "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 0 ]
  reported=$(python3 -c 'import json, sys; print(json.loads(sys.stdin.read())["highlight_index"])' <<<"$stderr")
  if on_range_neovim; then
    [[ $reported == on || $reported == "not needed: Neovim's highlighter has the neovim#42735 fix" ]]
  else
    [ "$reported" = "unavailable: TSHighlighter._on_range is missing" ]
  fi
  NVCAT_HIGHLIGHT_INDEX=0 run --separate-stderr "$NVCAT" --paging=never --columns 80 --all --timings-json \
    "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 0 ]
  [ "$(python3 -c 'import json, sys; print(json.loads(sys.stdin.read())["highlight_index"])' <<<"$stderr")" = off ]
}

@test "the index leaves complete Markdown renders unchanged" {
  for file in "$FIXTURES/markdown/sample.md" "$ROOT/benchmarks/medium.md" "$ROOT/benchmarks/code.md"; do
    same_output --all "$file"
  done
}

@test "the index leaves table viewports unchanged, including the first and last rows" {
  file=$BATS_TEST_TMPDIR/table.md
  table 600 >"$file"
  for start in 1 5 300 590; do
    same_output --lines 30 --start-line "$start" "$file"
  done
}

@test "the index leaves a narrow, wrapping render unchanged" {
  file=$BATS_TEST_TMPDIR/table.md
  table 40 >"$file"
  indexed=$(NVCAT_HIGHLIGHT_INDEX=1 "$NVCAT" --paging=never --columns 24 --all "$file")
  plain=$(NVCAT_HIGHLIGHT_INDEX=0 "$NVCAT" --paging=never --columns 24 --all "$file")
  [ "$indexed" = "$plain" ]
}

@test "the index leaves Tree-sitter code renders unchanged" {
  for file in "$ROOT/gen-dispatch" "$ROOT/filetypes.py" "$FIXTURES/astro/"*; do
    same_output --all "$file"
  done
}
