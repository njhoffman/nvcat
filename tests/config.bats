#!/usr/bin/env bats
# Configuration: defaults, config.toml, NVCAT_* overrides, --check, and degraded rendering.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  SAMPLE=$BATS_TEST_DIRNAME/fixtures/markdown/sample.md
  CONFIG=$BATS_TEST_TMPDIR/config.toml
  export NVCAT_CONFIG=$CONFIG
}

render() {
  run --separate-stderr "$NVCAT" --paging=never --columns 60 --all "$@" "$SAMPLE"
}

colors() {
  grep -o '38;2;[0-9;]*m' <<<"$1" | sort -u | wc -l
}

@test "no config file: defaults render with render-markdown's own options" {
  render
  [ "$status" -eq 0 ]
  [[ $output == *Title* ]]
  [ "$(colors "$output")" -ge 3 ]
}

@test "--check reports defaults and succeeds" {
  run "$NVCAT" --check
  [ "$status" -eq 0 ]
  [[ $output == *'(not found; using defaults)'* ]]
  [[ $output == *'render_markdown'*'[plugin_dirs]'* ]]
  [[ ${lines[-1]} == ok ]]
}

@test "config file values are used and reported with their source" {
  printf 'colorscheme = "habamax"\n' > "$CONFIG"
  run "$NVCAT" --check
  [[ $output == *"colorscheme      habamax  [$CONFIG]"* ]]
  render
  [ "$status" -eq 0 ]
}

@test "a colorscheme changes the colors" {
  render
  default=$output
  printf 'colorscheme = "habamax"\n' > "$CONFIG"
  render
  [ "$status" -eq 0 ]
  [ "$output" != "$default" ]
}

@test "environment variables override the file" {
  printf 'colorscheme = "habamax"\n' > "$CONFIG"
  NVCAT_COLORSCHEME=default run "$NVCAT" --check
  [[ $output == *'colorscheme      default  [NVCAT_COLORSCHEME]'* ]]
}

@test "unknown keys and invalid TOML are errors" {
  printf 'colourscheme = "x"\n' > "$CONFIG"
  render
  [ "$status" -eq 1 ]
  [[ $stderr == *'unknown keys: colourscheme'* ]]
  printf 'colorscheme = \n' > "$CONFIG"
  render
  [ "$status" -eq 1 ]
  [[ $stderr == *"$CONFIG"* ]]
}

@test "missing render-markdown is a clear error" {
  NVCAT_RENDER_MARKDOWN=$BATS_TEST_TMPDIR/none render
  [ "$status" -eq 1 ]
  [[ $stderr == *'render-markdown.nvim not found'*'nvcat --check'* ]]
  NVCAT_RENDER_MARKDOWN=$BATS_TEST_TMPDIR/none run "$NVCAT" --check
  [ "$status" -eq 1 ]
  [[ $output == *'error: render-markdown.nvim not found'* ]]
}

@test "missing optional files are skipped with a warning" {
  printf 'theme = "%s/none.lua"\nmarkdown_options = "%s/none.lua"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$CONFIG"
  run "$NVCAT" --check
  [ "$status" -eq 0 ]
  [[ $output == *'warning: markdown_options:'*'does not exist; skipped'* ]]
  [[ $output == *'warning: theme:'*'does not exist; skipped'* ]]
  render
  [ "$status" -eq 0 ]
}

@test "icons can be disabled" {
  NVCAT_ICONS= run "$NVCAT" --check
  [[ $output == *'warning: icons: mini.icons not found'* ]]
  NVCAT_ICONS= render
  [ "$status" -eq 0 ]
  [[ $output == *Title* ]]
}

@test "markdown_options may return the options table" {
  printf 'return { heading = { enabled = false } }\n' > "$BATS_TEST_TMPDIR/opts.lua"
  printf 'markdown_options = "%s/opts.lua"\n' "$BATS_TEST_TMPDIR" > "$CONFIG"
  render
  [ "$status" -eq 0 ]
  [[ $(sed 's/\x1b\[[0-9;]*m//g' <<<"$output" | head -1) == '# Title'* ]]
}

@test "markdown_options may call setup() like an editor config" {
  printf 'require("render-markdown").setup({ heading = { enabled = false } })\n' > "$BATS_TEST_TMPDIR/opts.lua"
  printf 'markdown_options = "%s/opts.lua"\n' "$BATS_TEST_TMPDIR" > "$CONFIG"
  render
  [ "$status" -eq 0 ]
  [[ $(sed 's/\x1b\[[0-9;]*m//g' <<<"$output" | head -1) == '# Title'* ]]
}

@test "a markdown_options file that does neither is an error" {
  printf 'local x = 1\n' > "$BATS_TEST_TMPDIR/opts.lua"
  printf 'markdown_options = "%s/opts.lua"\n' "$BATS_TEST_TMPDIR" > "$CONFIG"
  render
  [ "$status" -eq 1 ]
  [[ $stderr == *'neither called setup() nor returned a table'* ]]
}

@test "a theme file with apply() is used, with lua_path for its modules" {
  mkdir -p "$BATS_TEST_TMPDIR/lua/mytheme"
  printf 'return { red = "#ff0000" }\n' > "$BATS_TEST_TMPDIR/lua/mytheme/palette.lua"
  printf 'return { apply = function() vim.api.nvim_set_hl(0, "Normal", { fg = require("mytheme.palette").red }) end }\n' \
    > "$BATS_TEST_TMPDIR/lua/mytheme/init.lua"
  printf 'lua_path = "%s/lua"\ntheme = "%s/lua/mytheme/init.lua"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$CONFIG"
  render
  [ "$status" -eq 0 ]
  [[ $output == *'38;2;255;0;0'* ]]
}

@test "--nvim overrides the configured executable" {
  run "$NVCAT" --paging=never --nvim "$BATS_TEST_TMPDIR/no-nvim" "$SAMPLE"
  [ "$status" -eq 1 ]
}

@test "without a config file, tomllib is not imported" {
  run --separate-stderr python3 -X importtime "$NVCAT" --check
  [ "$status" -eq 0 ]
  [[ $stderr != *tomllib* ]]
  printf 'icons = false\n' > "$CONFIG"
  run --separate-stderr python3 -X importtime "$NVCAT" --check
  [[ $stderr == *tomllib* ]]
}
