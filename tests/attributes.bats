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
  unset NVCAT_HYPERLINKS NVCAT_COLOR NO_COLOR
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
  [[ $output == *$'\e]8;id='*$';https://example.com/auto\e\\'* ]]
  while IFS= read -r line; do
    opened=$(grep -o $'\e]8;id=[^\e]\+\e' <<<"$line" | wc -l)
    closed=$(grep -o $'\e]8;;\e' <<<"$line" | wc -l)
    [ "$opened" -eq "$closed" ] || { echo "unbalanced: $line"; return 1; }
  done <<<"$output"
}

@test "a link whose URL has control bytes cannot send escapes: it stays text, other links still work" {
  doc=$BATS_TEST_TMPDIR/evil.md
  printf '%b\n\n' \
    '[osc](http://a.example/\e]0;PWNED\ab)' \
    '[bel](http://b.example/\aPWNED)' \
    '[st](http://c.example/\e\\PWNED)' \
    '[csi](http://d.example/\e[31mPWNED)' \
    '[c1](http://e.example/\xc2\x9d0;PWNED)' \
    '[del](http://f.example/\x7fPWNED)' \
    '<http://g.example/\e]0;PWNED\a>' \
    '[fine](http://ok.example/)' > "$doc"
  for mode in auto always; do
    run --separate-stderr "$NVCAT" --paging=never --fallback none --hyperlinks "$mode" --columns 80 --all "$doc"
    [ "$status" -eq 0 ] || { echo "$mode: $stderr"; return 1; }
    [[ $output != *$'\a'* ]] || { echo "$mode: BEL in output"; return 1; }
    [[ $output != *$'\e]0;'* ]] || { echo "$mode: OSC 0 in output"; return 1; }
    [[ $output != *$'\xc2\x9d'* ]] || { echo "$mode: C1 in output"; return 1; }
    [[ $output != *$'\x7f'* ]] || { echo "$mode: DEL in output"; return 1; }
    # The only OSC 8 targets left are the clean link's, and the link texts still show.
    targets=$(grep -ao $'\e]8;id=[^\e]\+' <<<"$output" | sort -u)
    [ "$targets" = $'\e]8;id=1;http://ok.example/' ] || { echo "$mode: targets: $targets" | cat -v; return 1; }
    for text in osc bel st csi c1 del fine; do
      [[ $output == *"$text"* ]] || { echo "$mode: '$text' missing"; return 1; }
    done
  done
}

@test "--color never, and NO_COLOR when nothing is configured: the text as laid out, with no escape at all" {
  run --separate-stderr "$NVCAT" --paging=never --color never --columns 80 --all "$SYNTAX"
  [ "$status" -eq 0 ]
  [[ $output != *$'\e'* ]]
  [[ $output == *REFERENCE_SYNTAX_BOTTOM* ]]
  [[ $(sed -n '/ $/p' <<<"$output") == "" ]] || { echo "trailing blanks"; return 1; }
  NO_COLOR=1 run --separate-stderr "$NVCAT" --paging=never --columns 80 --all "$SYNTAX"
  [[ $output != *$'\e'* ]]
  NVCAT_COLOR=never run --separate-stderr "$NVCAT" --paging=never --columns 80 --all "$SYNTAX"
  [[ $output != *$'\e'* ]]
}

@test "color stays on by default when piped; explicit settings beat NO_COLOR, and an empty NO_COLOR is unset" {
  unset NO_COLOR
  run --separate-stderr "$NVCAT" --paging=never --columns 80 "$SYNTAX"
  [[ $output == *$'\e['* ]]
  NO_COLOR= run --separate-stderr "$NVCAT" --paging=never --columns 80 "$SYNTAX"
  [[ $output == *$'\e['* ]]
  NO_COLOR=1 run --separate-stderr "$NVCAT" --paging=never --color always --columns 80 "$SYNTAX"
  [[ $output == *$'\e['* ]]
  NO_COLOR=1 NVCAT_COLOR=always run --separate-stderr "$NVCAT" --paging=never --columns 80 "$SYNTAX"
  [[ $output == *$'\e['* ]]
  printf 'color = "always"\n' > "$BATS_TEST_TMPDIR/config.toml"
  NO_COLOR=1 NVCAT_CONFIG=$BATS_TEST_TMPDIR/config.toml run --separate-stderr "$NVCAT" --paging=never --columns 80 "$SYNTAX"
  [[ $output == *$'\e['* ]]
}

@test "--color auto: off when piped, on in fzf previews, in Neovim and on a terminal" {
  unset FZF_PREVIEW_COLUMNS FZF_PREVIEW_LINES NVIM
  run --separate-stderr "$NVCAT" --paging=never --color auto --columns 80 "$SYNTAX"
  [[ $output != *$'\e'* ]]
  FZF_PREVIEW_COLUMNS=80 FZF_PREVIEW_LINES=20 run --separate-stderr "$NVCAT" --color auto "$SYNTAX"
  [[ $output == *$'\e['* ]]
  NVIM=/tmp/socket run --separate-stderr "$NVCAT" --paging=never --color auto --columns 80 "$SYNTAX"
  [[ $output == *$'\e['* ]]
  run python3 -c "
import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/helpers')
from common import load_nvcat
nvcat = load_nvcat()
nvcat.sys.stdout.isatty = lambda: True
print(nvcat.use_color('auto'))" 2>&1
  [ "$output" = True ]
}

@test "an invalid color setting fails the render and --check" {
  NVCAT_COLOR=sometimes run --separate-stderr "$NVCAT" --paging=never --columns 80 "$SYNTAX"
  [ "$status" -ne 0 ]
  [[ $stderr == *"color must be one of auto, always, never, not 'sometimes'"* ]]
  NVCAT_COLOR=sometimes run "$NVCAT" --check
  [ "$status" -ne 0 ]
  [[ $output == *"color: 'sometimes' is not auto, always or never"* ]]
}

@test "a file's escapes do not pass through bat: not in the fallback, with color or without" {
  command -v bat >/dev/null || skip "bat not installed"
  printf 'keep \e]0;PWNED\a \e[31mred\e[0m \xc2\x9d0;C1\xc2\x9c \aBEL \ePdcs\e\\ END\n' > "$BATS_TEST_TMPDIR/evil.md"
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --all --budget 0.000001 "$BATS_TEST_TMPDIR/evil.md"
  [ "$status" -eq 0 ]
  [[ $output == *keep* && $output == *END* ]]
  [[ $output != *$'\a'* && $output != *$'\xc2\x9d'* && $output != *$'\e]'* && $output != *$'\eP'* ]]
  [[ $output != *$'\e[31m'* ]] || { echo "the file's own SGR passed"; return 1; }
  [[ $output == *$'\e['* ]]  # bat's own color stays.
  run --separate-stderr "$NVCAT" --paging=never --color never --columns 80 --all --budget 0.000001 \
    "$BATS_TEST_TMPDIR/evil.md"
  [ "$status" -eq 0 ]
  [[ $output == *keep* && $output == *END* ]]
  [[ $output != *$'\e'* && $output != *$'\a'* && $output != *$'\xc2\x9d'* ]]
}

@test "error messages show control characters in names as text" {
  name=$'nofile\e]0;PWNED\a.md'
  run --separate-stderr "$NVCAT" --paging=never "$name"
  [ "$status" -eq 1 ]
  [[ $stderr != *$'\e'* && $stderr != *$'\a'* ]]
  [[ $stderr == *'nofile\x1b]0;PWNED\x07.md: no such file'* ]]
  ln -s $'target\e]0;PWNED\a' "$BATS_TEST_TMPDIR/broken.md"
  run --separate-stderr "$NVCAT" --paging=never "$BATS_TEST_TMPDIR/broken.md"
  [ "$status" -eq 1 ]
  [[ $stderr != *$'\e'* && $stderr != *$'\a'* ]]
  [[ $stderr == *'target\x1b]0;PWNED\x07'* ]]
  # Messages keep their line breaks.
  run --separate-stderr "$NVCAT" --no-such-option
  [ "$status" -eq 2 ]
  [[ $stderr == *$'\n'* ]]
}

# The OSC 8 targets in $1, one per line, sorted.
link_targets() {
  grep -ao $'\e]8;id=[0-9]*;[^\e]*' <<<"$1" | sed 's/^.*;//' | LC_ALL=C sort -u
}

@test "only allowed URL schemes become hyperlinks, whatever their case, and link text always shows" {
  doc=$BATS_TEST_TMPDIR/schemes.md
  printf '%s\n\n' '[plain](http://a.example/)' '[secure](HTTPS://b.example/)' '[mail](mailto:c@example.com)' \
    '[hidden file](file:///etc/passwd)' '[script](javascript:alert)' '[remote](ssh://d.example/)' \
    '[relative](./other.md)' '[anchor](#section)' '[angle](<http://e.example/f>)' > "$doc"
  run --separate-stderr "$NVCAT" --paging=never --hyperlinks always --columns 80 --all "$doc"
  [ "$status" -eq 0 ]
  [ "$(link_targets "$output")" = "$(printf '%s\n' 'HTTPS://b.example/' 'http://a.example/' 'http://e.example/f' 'mailto:c@example.com' | LC_ALL=C sort)" ] ||
    { link_targets "$output"; return 1; }
  for text in plain secure mail 'hidden file' script remote relative anchor angle; do
    [[ $output == *"$text"* ]] || { echo "lost: $text"; return 1; }
  done
  # A key that names others replaces the list, in any spelling; "all" allows any scheme, but still needs one to be a URI.
  NVCAT_LINK_SCHEMES='SSH, file' run --separate-stderr "$NVCAT" --paging=never --hyperlinks always --columns 80 --all "$doc"
  [ "$status" -eq 0 ]
  [ "$(link_targets "$output")" = "$(printf '%s\n' 'file:///etc/passwd' 'ssh://d.example/' | LC_ALL=C sort)" ]
  NVCAT_LINK_SCHEMES=all run --separate-stderr "$NVCAT" --paging=never --hyperlinks always --columns 80 --all "$doc"
  [ "$status" -eq 0 ]
  [[ $(link_targets "$output") == *'javascript:alert'* ]]
  [[ $(link_targets "$output") == *'./other.md'* ]]
}

@test "link_schemes reads as a TOML list too, and a bad scheme is reported" {
  doc=$BATS_TEST_TMPDIR/schemes.md
  printf '[remote](ssh://d.example/)\n\n[plain](http://a.example/)\n' > "$doc"
  config=$BATS_TEST_TMPDIR/config.toml
  printf 'link_schemes = ["ssh"]\n' > "$config"
  NVCAT_CONFIG=$config run --separate-stderr "$NVCAT" --paging=never --hyperlinks always --columns 80 --all "$doc"
  [ "$status" -eq 0 ]
  [ "$(link_targets "$output")" = 'ssh://d.example/' ]
  NVCAT_LINK_SCHEMES='http bad!scheme' run --separate-stderr "$NVCAT" --paging=never --columns 80 --all "$doc"
  [ "$status" -ne 0 ]
  [[ $stderr == *"link_schemes: 'bad!scheme' is not a URL scheme"* ]]
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
  [[ $output == *$'\e]8;id='*';https://'* ]]
}

@test "auto hyperlinks stay on when a configured pager command does not run" {
  unset FZF_PREVIEW_COLUMNS FZF_PREVIEW_LINES NVIM
  NVCAT_PAGER=more run --separate-stderr "$NVCAT" --columns 80 "$SYNTAX"  # Piped.
  [[ $output == *$'\e]8;id='* ]]
  NVCAT_PAGER=more FZF_PREVIEW_COLUMNS=80 FZF_PREVIEW_LINES=40 run --separate-stderr "$NVCAT" "$SYNTAX"
  [[ $output == *$'\e]8;id='* ]]
  NVCAT_PAGER=more run --separate-stderr "$NVCAT" --columns 80 --lines 40 "$SYNTAX"
  [[ $output == *$'\e]8;id='* ]]
}

@test "OSC 8 targets lose Markdown's angle brackets and percent-encode the rest" {
  printf '%b\n' '[a](<http://a.example/x y>) [b](http://b.example/caf\xc3\xa9) [c](http://c.example/\xe2\x80\xaeZ)' \
    '[d](http://d.example/a%20b?q=1;r=2#f)' > "$BATS_TEST_TMPDIR/uris.md"
  run --separate-stderr "$NVCAT" --paging=never --columns 100 "$BATS_TEST_TMPDIR/uris.md"
  [ "$status" -eq 0 ]
  targets=$(grep -ao $'\e]8;id=[0-9]*;[^\e]\+' <<<"$output" | sed 's/^.*id=[0-9]*;//')
  [ "$targets" = 'http://a.example/x%20y
http://b.example/caf%C3%A9
http://c.example/%E2%80%AEZ
http://d.example/a%20b?q=1;r=2#f' ] || { echo "$targets"; return 1; }
}

@test "a link wrapped over rows has one id; different URIs have different ids" {
  printf '[a long link text that wraps over the row boundary of this narrow output](http://w.example/) and [o](http://o.example/)\n' \
    > "$BATS_TEST_TMPDIR/wrap.md"
  run --separate-stderr "$NVCAT" --paging=never --columns 30 "$BATS_TEST_TMPDIR/wrap.md"
  [ "$status" -eq 0 ]
  wrapped=$(grep -ao $'\e]8;id=[0-9]*;http://w.example/' <<<"$output" | sort | uniq -c | awk '{print $1}')
  [ "$wrapped" -ge 2 ] || { echo "wrapped: $wrapped"; return 1; }
  [ "$(grep -ao $'\e]8;id=[0-9]*;http://w.example/' <<<"$output" | sort -u | wc -l)" -eq 1 ]
  [[ $output == *$'\e]8;id=1;http://w.example/'* ]]
  [[ $output == *$'\e]8;id=2;http://o.example/'* ]]
}

@test "auto hyperlinks are off only when a pager command other than less may show the output" {
  run python3 -c "
import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/helpers')
from common import load_nvcat
nvcat = load_nvcat()
nvcat.wants_pager = lambda mode, complete: mode != 'never'  # As on a terminal, for a complete document.
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
