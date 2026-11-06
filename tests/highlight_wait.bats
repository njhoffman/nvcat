#!/usr/bin/env bats
# A screen captured while Neovim's highlighter parses asynchronously has no Tree-sitter colors at all.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
  NVCAT=$ROOT/nvcat
  export FZF_PREVIEW_COLUMNS=100 FZF_PREVIEW_LINES=40
  mkdir -p "$BATS_TEST_TMPDIR/still" "$BATS_TEST_TMPDIR/busy"
}

config_for() {
  printf 'theme = "%s"\n' "$BATS_TEST_TMPDIR/$1/theme.lua" >"$BATS_TEST_TMPDIR/$1/config.toml"
  echo "$BATS_TEST_TMPDIR/$1/config.toml"
}

@test "the screen waits for a highlighter that is still parsing" {
  highlights='vim.api.nvim_set_hl(0, "@keyword", { fg = "#ff0000" }); vim.api.nvim_set_hl(0, "@keyword.rust", { fg = "#ff0000" })'
  printf 'return { apply = function() %s end }\n' "$highlights" >"$BATS_TEST_TMPDIR/still/theme.lua"
  # As Neovim does while a parse runs: until the flag clears, the highlighter draws nothing.
  cat >"$BATS_TEST_TMPDIR/busy/theme.lua" <<LUA
return { apply = function()
  $highlights
  local start = vim.treesitter.start
  vim.treesitter.start = function(buf, lang)
    start(buf, lang)
    buf = vim.api.nvim_get_current_buf()
    local active = vim.treesitter.highlighter.active[buf]
    if active then
      active.parsing = true
      vim.defer_fn(function()
        active.parsing = false
        vim.api.nvim__redraw({ buf = buf, valid = false, flush = false })
      end, 1500)
    end
  end
end }
LUA
  document=$ROOT/benchmarks/code.md
  NVCAT_CONFIG=$(config_for still) "$NVCAT" "$document" >"$BATS_TEST_TMPDIR/expected"
  NVCAT_CONFIG=$(config_for busy) "$NVCAT" "$document" | cmp - "$BATS_TEST_TMPDIR/expected"
  # Neovim 0.11 parses synchronously, with no flag to wait for.
  if nvim --version | head -1 | grep -qv 'v0\.11\.'; then
    NVCAT_CONFIG=$(config_for busy) "$NVCAT" --timings-json "$document" 2>&1 >/dev/null | grep -Eq '"parse_waits": *[1-9]'
  fi
  NVCAT_CONFIG=$(config_for busy) "$NVCAT" --all --budget=20 "$document" >"$BATS_TEST_TMPDIR/complete.busy"
  NVCAT_CONFIG=$(config_for still) "$NVCAT" --all --budget=20 "$document" | cmp - "$BATS_TEST_TMPDIR/complete.busy"
}
