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
      -- A boolean since Neovim 0.12, one per window in 0.11.
      local win = vim.api.nvim_get_current_win()
      local function set(value)
        if type(active.parsing) == "table" then
          active.parsing[win] = value
        else
          active.parsing = value
        end
      end
      set(true)
      vim.defer_fn(function()
        set(false)
        vim.api.nvim__redraw({ buf = buf, valid = false, flush = false })
      end, 1500)
    end
  end
end }
LUA
  document=$ROOT/benchmarks/code.md
  # --fallback=none: a wait that never ends must fail here, not print bat's output on both sides.
  NVCAT_CONFIG=$(config_for still) "$NVCAT" --fallback=none "$document" >"$BATS_TEST_TMPDIR/expected"
  NVCAT_CONFIG=$(config_for busy) "$NVCAT" --fallback=none "$document" | cmp - "$BATS_TEST_TMPDIR/expected"
  NVCAT_CONFIG=$(config_for busy) "$NVCAT" --fallback=none --timings-json "$document" 2>&1 >/dev/null | grep -Eq '"parse_waits": *[1-9]'
  NVCAT_CONFIG=$(config_for busy) "$NVCAT" --fallback=none --all --budget=20 "$document" >"$BATS_TEST_TMPDIR/complete.busy"
  NVCAT_CONFIG=$(config_for still) "$NVCAT" --fallback=none --all --budget=20 "$document" | cmp - "$BATS_TEST_TMPDIR/complete.busy"
}
