#!/usr/bin/env bats
# --budget and --fallback: complete output that takes too long goes to bat instead of failing.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  FIXTURES=$BATS_TEST_DIRNAME/fixtures
}

@test "over budget, Markdown falls back to bat with a notice" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --budget 0.01 "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 0 ]
  [[ $stderr == *'showing bat output instead'* ]]
  [[ $output == *'Title'* ]]
  [[ $output == *$'\e['* ]]
}

@test "the fallback output matches bat's Markdown rendering" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --budget 0.01 "$FIXTURES/markdown/sample.md"
  expected=$(bat --color=always --paging=never --style=plain --terminal-width=80 --language=markdown -- \
    "$FIXTURES/markdown/sample.md")
  [ "$output" = "$expected" ]
}

@test "non-Markdown filetypes fall back to bat without forcing Markdown" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --budget 0.01 --filetype kdl -- \
    "$FIXTURES/kdl/config.kdl"
  [ "$status" -eq 0 ]
  expected=$(bat --color=always --paging=never --style=plain --terminal-width=80 -- "$FIXTURES/kdl/config.kdl")
  [ "$output" = "$expected" ]
}

@test "--fallback=none reports the budget error" {
  run "$NVCAT" --paging=never --columns 80 --budget 0.01 --fallback=none "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 1 ]
  [[ $output == *'longer than the budget'* ]]
}

@test "the budget does not apply to viewports" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --lines 5 --budget 0.01 \
    "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "--budget 0 disables the budget" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --budget 0 "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "stdin falls back too" {
  run --separate-stderr bash -c "'$NVCAT' --paging=never --columns 80 --budget 0.01 - < '$FIXTURES/markdown/sample.md'"
  [ "$status" -eq 0 ]
  [[ $output == *'Title'* ]]
}

@test "fallback output is paged like a normal render" {
  # The stub pager marks its output on stdout: Landlock lets it write only in the run directory.
  NVCAT_PAGER="sh -c 'echo ==PAGED==; cat'" run --separate-stderr \
    "$NVCAT" --paging=always --columns 80 --budget 0.01 "$FIXTURES/markdown/sample.md"
  [ "${lines[0]}" = ==PAGED== ]
  [[ $output == *'Title'* ]]
}

@test "a large table renders in full within the default budget or falls back, never errors" {
  table=$BATS_TEST_TMPDIR/table.md
  { echo '| a | b | c | d |'; echo '|---|---|---|---|'
    for i in $(seq 1 1500); do echo "| \`f$i\` | \`.e$i\`, 1 pattern | \`p\` |  |"; done; } > "$table"
  run --separate-stderr "$NVCAT" --paging=never --columns 120 "$table"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -ge 1500 ]
}

hanging_nvim() {
  printf '#!/bin/sh\nexec sleep 30\n' > "$BATS_TEST_TMPDIR/nvim"
  chmod +x "$BATS_TEST_TMPDIR/nvim"
  echo "$BATS_TEST_TMPDIR/nvim"
}

big_markdown() {
  # Just over 10 MiB: the heading, then filler lines.
  { echo '# Big'; yes 'filler line of text' | head -c $((10 * 1024 * 1024 + 4096)); echo; echo 'LAST'; } > "$1"
}

@test "a timeout falls back to bat for complete output" {
  run --separate-stderr "$NVCAT" --nvim "$(hanging_nvim)" --timeout 1 --paging=never --columns 80 \
    "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 0 ]
  [[ $stderr == *'1 s timeout (--timeout)'*'showing bat output instead'* ]]
  [[ $output == *'Title'* ]]
}

@test "a timeout falls back to bat for a viewport, cut to the viewport" {
  run --separate-stderr "$NVCAT" --nvim "$(hanging_nvim)" --timeout 1 --paging=never --columns 80 \
    --lines 3 --start-line 2 "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 0 ]
  expected=$(bat --color=always --paging=never --style=plain --terminal-width=80 --language=markdown \
    --line-range=2:4 -- "$FIXTURES/markdown/sample.md")
  [ "$output" = "$expected" ]
}

@test "fzf previews fall back on a timeout too" {
  run --separate-stderr env FZF_PREVIEW_COLUMNS=60 FZF_PREVIEW_LINES=4 \
    "$NVCAT" --nvim "$(hanging_nvim)" --timeout 1 "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -le 4 ]
  [[ $output == *'Title'* ]]
}

@test "--fallback=none reports the timeout and the flag" {
  run "$NVCAT" --nvim "$(hanging_nvim)" --timeout 1 --fallback=none --paging=never --columns 80 \
    "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 1 ]
  [[ $output == 'nvcat: Neovim did not answer within the 1 s timeout (--timeout)'* ]]
}

@test "input over 10 MiB falls back to bat without starting Neovim" {
  big_markdown "$BATS_TEST_TMPDIR/big.md"
  run --separate-stderr "$NVCAT" --nvim "$(hanging_nvim)" --paging=never --columns 80 "$BATS_TEST_TMPDIR/big.md"
  [ "$status" -eq 0 ]
  [[ $stderr == *'over the 10 MiB limit; showing bat output instead'* ]]
  [[ $output == *'Big'* ]]
  [[ $(tail -n 1 <<<"$output") == *'LAST'* ]]
}

@test "stdin over 10 MiB reaches bat in full" {
  big_markdown "$BATS_TEST_TMPDIR/big.md"
  run --separate-stderr bash -c "'$NVCAT' --paging=never --columns 80 - < '$BATS_TEST_TMPDIR/big.md'"
  [ "$status" -eq 0 ]
  [[ $(tail -n 1 <<<"$output") == *'LAST'* ]]
}

@test "input over 10 MiB in a viewport shows only the viewport" {
  big_markdown "$BATS_TEST_TMPDIR/big.md"
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --lines 2 "$BATS_TEST_TMPDIR/big.md"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "--fallback=none rejects input over 10 MiB by size" {
  big_markdown "$BATS_TEST_TMPDIR/big.md"
  run "$NVCAT" --fallback=none --paging=never --columns 80 "$BATS_TEST_TMPDIR/big.md"
  [ "$status" -eq 1 ]
  [[ $output == 'nvcat: input is 10.0 MiB, over the 10 MiB limit' ]]
}

@test "the row limit names --lines and falls back" {
  rows=$BATS_TEST_TMPDIR/rows.md
  # Few source lines that wrap to over 1000 rows, so the limit trips on the first frame.
  for i in $(seq 1 50); do printf 'word%.0s ' $(seq 1 1600); echo; echo; done > "$rows"
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --budget 0 "$rows"
  [ "$status" -eq 0 ]
  [[ $stderr == *'exceeds 1000 screen rows (--lines renders a viewport)'* ]]
}

@test "over 1000 source lines fall back at once instead of waiting for a grid Neovim never makes" {
  # Neovim clamps 'lines' to 1000; a taller grid request used to wait for the budget or --timeout.
  seq 1 1010 > "$BATS_TEST_TMPDIR/long.txt"
  SECONDS=0
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --budget 0 --timeout 30 --filetype text \
    "$BATS_TEST_TMPDIR/long.txt"
  [ "$status" -eq 0 ]
  [[ $stderr == *'exceeds 1000 screen rows'* ]]
  [ "$(wc -l <<<"$output")" -eq 1010 ]
  [ "$SECONDS" -lt 15 ]
}

@test "a document that needs a resize past 1000 rows still renders when it fits" {
  # 500 source lines start a 504-row grid; wrapping needs about 750 rows, and doubling asked for 1008.
  for i in $(seq 1 250); do printf 'Paragraph %s %s\n\n' "$i" "$(printf 'lorem ipsum %.0s' $(seq 1 6))"; done \
    > "$BATS_TEST_TMPDIR/wrapped.md"
  run --separate-stderr "$NVCAT" --paging=never --columns 40 --budget 0 --timeout 30 --fallback=none \
    "$BATS_TEST_TMPDIR/wrapped.md"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [[ $output == *'Paragraph 250'* ]]
}

@test "--lines over 1000 is rejected" {
  run "$NVCAT" --lines 1001 "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 1 ]
  [[ $output == *'1–1000 lines'* ]]
}

@test "a missing bat is named when a fallback is needed" {
  mkdir "$BATS_TEST_TMPDIR/bin"
  ln -s "$(command -v python3)" "$BATS_TEST_TMPDIR/bin/python3"
  run env PATH="$BATS_TEST_TMPDIR/bin" /usr/bin/python3 "$NVCAT" --nvim "$(command -v nvim)" \
    --paging=never --columns 80 --budget 0.01 "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 1 ]
  [[ $output == *'bat, the fallback renderer, is not installed' ]]
}

@test "a failing bat is reported without a traceback" {
  mkdir "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 3\n' > "$BATS_TEST_TMPDIR/bin/bat"
  chmod +x "$BATS_TEST_TMPDIR/bin/bat"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$NVCAT" --paging=never --columns 80 --budget 0.01 \
    "$FIXTURES/markdown/sample.md"
  [ "$status" -eq 1 ]
  [[ $output == *'the bat fallback failed with exit status 3' ]]
  [[ $output != *Traceback* ]]
}

@test "binary input falls back to bat instead of showing raw control bytes" {
  printf 'GDMO\0\1\2\3binary\n' > "$BATS_TEST_TMPDIR/catalog.mo"
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --all --filetype gdmo -- "$BATS_TEST_TMPDIR/catalog.mo"
  [ "$status" -eq 0 ]
  [[ $stderr == *'binary input; showing bat output instead'* ]]
  [[ $output != *$'\e[0;'* ]]
}

@test "--fallback=none rejects binary input" {
  printf 'x\0y\n' > "$BATS_TEST_TMPDIR/blob.sed"
  run --separate-stderr "$NVCAT" --paging=never --fallback=none --all -- "$BATS_TEST_TMPDIR/blob.sed"
  [ "$status" -ne 0 ]
  [[ $stderr == *'binary input'* ]]
}

@test "a NUL after the first 8 KiB does not count as binary" {
  { head -c 9000 /dev/zero | tr '\0' 'a'; printf '\n\0\n'; } > "$BATS_TEST_TMPDIR/late.sed"
  run --separate-stderr "$NVCAT" --paging=never --fallback=none --columns 80 --lines 3 -- "$BATS_TEST_TMPDIR/late.sed"
  [ "$status" -eq 0 ]
}
