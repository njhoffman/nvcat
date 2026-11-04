#!/usr/bin/env bats
# Ported from the historical fzf-check.py: nvcat as the previewer of a real fzf in a pseudo-terminal.

@test "fzf: scrolling, file changes, resize re-render, rapid selection, cleanup" {
  command -v fzf >/dev/null || skip "fzf not installed"
  reference=$BATS_TEST_DIRNAME/fixtures/reference
  MARKERS='REFERENCE_TABLES_TOP,REFERENCE_TABLES_BOTTOM;REFERENCE_SYNTAX_TOP,REFERENCE_SYNTAX_BOTTOM;REFERENCE_EXTENDED_TOP,REFERENCE_EXTENDED_BOTTOM' \
    run timeout 120 python3 "$BATS_TEST_DIRNAME/helpers/fzf_session.py" \
    "$reference/tables.md" "$reference/syntax.md" "$reference/extended.md"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^ok ' <<<"$output")" -eq 9 ]
}

# fzf quotes {} for the shell, so these names reach the previewer intact; `--` keeps a leading `-` from being
# read as an option. become() runs the preview command with the same placeholder expansion as --preview.
run_fzf() { # LIST_FILE COMMAND [FZF_OPTION...]: run COMMAND for the first line of LIST_FILE, output in $work/out
  local list=$1 command=$2
  shift 2
  rm -f "$work/out"
  options=
  if (( $# )); then printf -v options '%q ' "$@"; fi
  timeout 30 script -qec "fzf --sync $options --bind $(printf %q "start:become($command > $work/out 2>&1)") < $(printf %q "$list")" /dev/null >/dev/null
}

setup_names() {
  command -v fzf >/dev/null || skip "fzf not installed"
  command -v script >/dev/null || skip "script not installed"
  work=$(mktemp -d "$BATS_TEST_TMPDIR/names.XXXXXX")
  cd "$work"
  names=('a|b.md' 'c:d.md' "e'f.md" 'g h.md' '-i.md' 'j"k.md' '$(x).md' 'l\m.md' 'n;o&p.md' 'q*r?.md')
  for name in "${names[@]}"; do printf 'line\n# MARK_HEADING\n' > "$name"; done
}

@test "fzf: {} passes names with pipes, colons, quotes, spaces and a leading dash to nvcat" {
  setup_names
  for name in "${names[@]}"; do
    printf '%s\n' "$name" > "$work/list"
    run_fzf "$work/list" "$BATS_TEST_DIRNAME/../nvcat --lines 4 -- {}"
    grep -q MARK_HEADING "$work/out" || { echo "$name: $(<"$work/out")"; return 1; }
  done
}

@test "fzf: {} passes the same names to nvcat-dispatch" {
  setup_names
  for name in "${names[@]}"; do
    printf '%s\n' "$name" > "$work/list"
    run_fzf "$work/list" "NVCAT=$BATS_TEST_DIRNAME/../nvcat $BATS_TEST_DIRNAME/../nvcat-dispatch -- {}"
    grep -q MARK_HEADING "$work/out" || { echo "$name: $(<"$work/out")"; return 1; }
  done
}

@test "fzf: a tab-separated grep match keeps a colon in the filename and jumps to its line" {
  setup_names
  command -v rg >/dev/null || skip "rg not installed"
  rg --no-config --color=never --line-number --with-filename --field-match-separator=$'\t' MARK_HEADING 'c:d.md' > "$work/list"
  run_fzf "$work/list" "$BATS_TEST_DIRNAME/../nvcat --lines 1 --start-line {2} -- {1}" --delimiter '\t'
  grep -q MARK_HEADING "$work/out" || { cat "$work/out"; return 1; }
  ! grep -q '^line' "$work/out"
}

@test "examples/fzf-files: without a generated router it says what to run, and fzf does not start" {
  stubs=$BATS_TEST_TMPDIR/stubs
  mkdir -p "$stubs"
  printf '#!/bin/sh\necho fzf started\n' > "$stubs/fzf"
  chmod +x "$stubs/fzf"
  NVCAT_DISPATCH=$BATS_TEST_TMPDIR/missing PATH="$stubs:$PATH" run "$BATS_TEST_DIRNAME/../examples/fzf-files" \
    "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ $output == *"$BATS_TEST_TMPDIR/missing not found; run 'just dispatch'"* ]]
  [[ $output != *'fzf started'* ]]
}

@test "examples/fzf-files: fzf accepts its options and lists the directory's files" {
  command -v fzf >/dev/null || skip "fzf not installed"
  mkdir -p "$BATS_TEST_TMPDIR/tree/.git" "$BATS_TEST_TMPDIR/tree/docs"
  touch "$BATS_TEST_TMPDIR/tree/docs/notes.md" "$BATS_TEST_TMPDIR/tree/run.py" "$BATS_TEST_TMPDIR/tree/.git/HEAD"
  # --filter prints the matches without a terminal, after fzf has parsed every --bind and --preview-window.
  FZF_DEFAULT_OPTS=--filter=. run "$BATS_TEST_DIRNAME/../examples/fzf-files" "$BATS_TEST_TMPDIR/tree"
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output")" = $'docs/notes.md\nrun.py' ]
}

@test "examples/fzf-files: the preview routes through nvcat-dispatch with --, for any name" {
  stubs=$BATS_TEST_TMPDIR/stubs
  mkdir -p "$stubs" "$BATS_TEST_TMPDIR/tree"
  # A stand-in fzf that keeps its arguments, so the test can run the preview command as fzf would.
  printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s\\n" "$@" > "$ARGS"\n' > "$stubs/fzf"
  printf '#!/bin/sh\necho "nvcat $*"\n' > "$stubs/nvcat"
  printf '#!/bin/sh\necho "bat $*"\n' > "$stubs/bat"
  chmod +x "$stubs"/*
  ARGS=$BATS_TEST_TMPDIR/args PATH="$stubs:$PATH" run "$BATS_TEST_DIRNAME/../examples/fzf-files" "$BATS_TEST_TMPDIR/tree"
  [ "$status" -eq 0 ]
  preview=$(grep -A1 -x -- --preview "$BATS_TEST_TMPDIR/args" | tail -1)
  grep -qx 'resize:refresh-preview' "$BATS_TEST_TMPDIR/args"
  cd "$BATS_TEST_TMPDIR/tree"
  for name in '--print' '-a b.md' "it's.md" 'plain.py'; do
    printf '# x\n' > "./$name"
    printf -v quoted %q "$name"
    run env NVCAT="$stubs/nvcat" BAT="$stubs/bat" bash -c "${preview//\{\}/$quoted}"
    case $name in
      *.md) [ "$output" = "nvcat --all --paging=never --budget=2 --filetype markdown -- $name" ] ;;
      *) [ "$output" = "bat --color=always --paging=never -- $name" ] ;;
    esac || { echo "$name: $output"; return 1; }
  done
}
