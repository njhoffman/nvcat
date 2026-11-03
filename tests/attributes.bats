#!/usr/bin/env bats
# Highlight attributes beyond color: underline styles with their color, and OSC 8 hyperlinks from the url
# Neovim attaches to Markdown links.

bats_require_minimum_version 1.5.0

setup_file() {
  local report
  report=$("$BATS_TEST_DIRNAME/../nvcat" --check 2>&1) ||
    skip "nvcat --check failed: $(grep -E '^(error|  error)' <<<"$report" | head -3 | tr '\n' ' ')"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  SYNTAX=$BATS_TEST_DIRNAME/fixtures/reference/syntax.md
  unset NVCAT_HYPERLINKS
}

@test "underline styles and the underline color become SGR 4:N and 58:2::R:G:B" {
  cat > "$BATS_TEST_TMPDIR/theme.lua" <<'EOF'
return { apply = function()
  vim.api.nvim_set_hl(0, "Comment", { fg = "#00ff00", undercurl = true, sp = "#ff0000" })
  vim.api.nvim_set_hl(0, "String", { fg = "#0000ff", underdouble = true })
  vim.api.nvim_set_hl(0, "Number", { underdotted = true, sp = "#010203" })
  vim.api.nvim_set_hl(0, "Keyword", { underdashed = true })
  vim.api.nvim_set_hl(0, "Statement", { underdashed = true })
  vim.api.nvim_set_hl(0, "Identifier", { underline = true })
end }
EOF
  printf 'local x = "s" -- c\nreturn 42\n' > "$BATS_TEST_TMPDIR/sample.lua"
  NVCAT_THEME=$BATS_TEST_TMPDIR/theme.lua run --separate-stderr "$NVCAT" --paging=never --syntax regex \
    --columns 40 "$BATS_TEST_TMPDIR/sample.lua"
  [ "$status" -eq 0 ]
  [[ $output == *$'\e[0;4:3;58:2::255:0:0;38;2;0;255;0;49m-- c'* ]]
  [[ $output == *$'\e[0;4:2;38;2;0;0;255;49m"s"'* ]]
  [[ $output == *$'\e[0;4:4;58:2::1:2:3;'*'42'* ]]
  [[ $output == *$'\e[0;4:5;'*'local'* ]]
}

@test "Markdown links are OSC 8 hyperlinks, each closed before its row ends" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --all "$SYNTAX"
  [ "$status" -eq 0 ]
  [[ $output == *$'\e]8;;https://example.com/auto\e\\'* ]]
  while IFS= read -r line; do
    opened=$(grep -o $'\e]8;;[^\e]\+\e' <<<"$line" | wc -l)
    closed=$(grep -o $'\e]8;;\e' <<<"$line" | wc -l)
    [ "$opened" -eq "$closed" ] || { echo "unbalanced: $line"; return 1; }
  done <<<"$output"
}

@test "--hyperlinks never and NVCAT_HYPERLINKS=never emit no OSC 8" {
  run --separate-stderr "$NVCAT" --paging=never --hyperlinks never --columns 80 --all "$SYNTAX"
  [ "$status" -eq 0 ]
  [[ $output != *$'\e]8;'* ]]
  NVCAT_HYPERLINKS=never run --separate-stderr "$NVCAT" --paging=never --columns 80 --all "$SYNTAX"
  [ "$status" -eq 0 ]
  [[ $output != *$'\e]8;'* ]]
  # The flag wins over the setting.
  NVCAT_HYPERLINKS=never run --separate-stderr "$NVCAT" --paging=never --hyperlinks always --columns 80 \
    --all "$SYNTAX"
  [[ $output == *$'\e]8;;https://'* ]]
}

@test "auto hyperlinks are off only when a pager command other than less may show the output" {
  run python3 -c "
import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/helpers')
from common import load_nvcat
nvcat = load_nvcat()
cases = [('auto', 'nvim', 'auto'), ('auto', ['less', '-R'], 'auto'), ('auto', ['/usr/bin/less', '-RS'], 'always'),
         ('auto', ['more'], 'auto'), ('auto', ['more'], 'never'), ('always', ['more'], 'auto'),
         ('never', 'nvim', 'never'), (None, 'nvim', 'auto')]
print(' '.join(str(nvcat.hyperlinks(*case)) for case in cases))"
  [ "$status" -eq 0 ]
  [ "$output" = "True True True False True True False True" ]
}

@test "an invalid hyperlinks setting fails the render and --check" {
  NVCAT_HYPERLINKS=sometimes run --separate-stderr "$NVCAT" --paging=never --columns 80 "$SYNTAX"
  [ "$status" -ne 0 ]
  [[ $stderr == *"hyperlinks must be one of auto, always, never, not 'sometimes'"* ]]
  NVCAT_HYPERLINKS=sometimes run "$NVCAT" --check
  [ "$status" -ne 0 ]
  [[ $output == *"hyperlinks: 'sometimes' is not auto, always or never"* ]]
}
