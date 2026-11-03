#!/usr/bin/env bats
# The reference documents' features at several widths, and the cell layout of wide glyphs, combining
# characters, emoji and transparent backgrounds. render-markdown runs with its defaults
# (NVCAT_MARKDOWN_OPTIONS empty), so the assertions do not depend on the user's options file.

bats_require_minimum_version 1.5.0

setup_file() {
  local report
  report=$("$BATS_TEST_DIRNAME/../nvcat" --check 2>&1) ||
    skip "nvcat --check failed: $(grep -E '^(error|  error)' <<<"$report" | head -3 | tr '\n' ' ')"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  REFERENCE=$BATS_TEST_DIRNAME/fixtures/reference
  CELLS=$BATS_TEST_DIRNAME/helpers/cells.py
  export NVCAT_MARKDOWN_OPTIONS=
}

plain() {
  sed 's/\x1b\[[0-9;:]*m//g; s/\x1b\]8;[^\x1b]*\x1b\\//g' <<<"$1"
}

# Renders a reference document completely at a width into $text, and fails on a line wider than the width.
render_at() {
  run --separate-stderr "$NVCAT" --paging=never --fallback none --columns "$2" --all "$REFERENCE/$1.md"
  [ "$status" -eq 0 ] || { echo "$1 at $2: $stderr"; return 1; }
  "$CELLS" "$2" <<<"$output" || { echo "$1 at $2: lines wider than the output"; return 1; }
  text=$(plain "$output")
}

# Fails, naming the document and width, when $text lacks (has) a string.
has() { [[ $text == *"$1"* ]] || { echo "$name at $width: missing '$1'"; return 1; }; }
lacks() { [[ $text != *"$1"* ]] || { echo "$name at $width: shows '$1'"; return 1; }; }

@test "extended syntax at 40, 80 and 120 columns: footnotes, wiki links, comments, callouts, code labels" {
  name=extended
  for width in 40 80 120; do
    render_at extended "$width"
    [ "$(grep -o '¹' <<<"$text" | wc -l)" -ge 2 ] || { echo "$width: footnote reference or definition missing"; return 1; }
    lacks '[^1]'
    has 'Some Page'
    lacks '[['
    lacks REFERENCE_HIDDEN_COMMENT
    lacks '<!--'
    has Note
    has Warning
    lacks '[!NOTE]'
    lacks '[!WARNING]'
    lacks '==text=='
    has mermaid
    has json
    lacks '```'
    has REFERENCE_EXTENDED_TOP
    has REFERENCE_EXTENDED_BOTTOM
  done
}

@test "basic syntax at 40, 80 and 120 columns: headings, emphasis, links and code labels" {
  name=syntax
  for width in 40 80 120; do
    render_at syntax "$width"
    if grep -n '^#' <<<"$text"; then
      echo "$width: a heading shows its raw # marker"
      return 1
    fi
    lacks '**'
    lacks '~~'
    lacks '](https:'
    has python
    has bash
    has rust
    lacks '```'
    has REFERENCE_SYNTAX_CODE
    has REFERENCE_SYNTAX_BOTTOM
  done
}

@test "tables at 40, 80 and 120 columns: borders and wide and combining cells" {
  name=tables
  for width in 40 80 120; do
    render_at tables "$width"
    has '┬'
    has '│ Left'
    has '日本語'
    has 'combining é'
    has REFERENCE_TABLES_BOTTOM
  done
}

@test "the first row of a render or viewport is rendered, not shown as raw Markdown (anti-conceal off)" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --lines 3 "$REFERENCE/extended.md"
  [ "$status" -eq 0 ]
  first=$(plain "$output" | head -1)
  [[ $first == *REFERENCE_EXTENDED_TOP* && $first != '# '* ]] || { echo "first row: $first"; return 1; }
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --lines 2 --start-line 18 "$REFERENCE/extended.md"
  [ "$status" -eq 0 ]
  first=$(plain "$output" | head -1)
  [[ $first == *Emanote* && $first != '## '* ]] || { echo "viewport first row: $first"; return 1; }
}

@test "wide glyphs, emoji and combining characters take their cells once" {
  printf '日本語|\n🙂|\ne\xcc\x81|\nEND\n' > "$BATS_TEST_TMPDIR/glyphs.txt"
  run --separate-stderr "$NVCAT" --paging=never --columns 40 "$BATS_TEST_TMPDIR/glyphs.txt"
  [ "$status" -eq 0 ]
  [ "$(plain "$output")" = "$(printf '日本語|\n🙂|\ne\xcc\x81|\nEND')" ]
  [ "$("$CELLS" --widths <<<"$output" | tr '\n' ' ')" = "7 3 2 3 " ]
}

@test "a wide glyph that does not fit at the end of a row wraps whole" {
  { printf a; for _ in $(seq 25); do printf '日'; done; printf '\n'; } > "$BATS_TEST_TMPDIR/wide.txt"
  run --separate-stderr "$NVCAT" --paging=never --columns 40 "$BATS_TEST_TMPDIR/wide.txt"
  [ "$status" -eq 0 ]
  "$CELLS" 40 <<<"$output"
  [ "$(plain "$output" | grep -o '日' | wc -l)" -eq 25 ]
}

@test "the default background stays transparent" {
  printf 'plain text\n\nmore text\n' > "$BATS_TEST_TMPDIR/plain.txt"
  run --separate-stderr "$NVCAT" --paging=never --columns 40 "$BATS_TEST_TMPDIR/plain.txt"
  [ "$status" -eq 0 ]
  [[ $output == *$'\e[0;'*';49m'plain* ]]
  [[ $output != *'48;2;'* ]]
}
