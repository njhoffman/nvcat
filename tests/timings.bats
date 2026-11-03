#!/usr/bin/env bats
# --timings, --timings-json and --syntax: phase timings on stderr, output on stdout unchanged.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  FIXTURES=$BATS_TEST_DIRNAME/fixtures
  SAMPLE=$FIXTURES/markdown/sample.md
}

# Print FIELD of the JSON report in $stderr; FIELD is a Python expression on the parsed object `r`.
field() {
  python3 -c 'import json, sys; r = json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1" <<<"$stderr"
}

@test "--timings prints a phase table to stderr and leaves stdout unchanged" {
  expected=$("$NVCAT" --paging=never --columns 80 --all "$SAMPLE")
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --all --timings "$SAMPLE"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  [[ $stderr == 'nvcat timings (ms): filetype markdown, engine render-markdown'* ]]
  for phase in 'python imports' startup 'neovim before profile.lua' 'setup: theme' open frames \
               'neovim redraw (all frames)' 'ansi encode' 'total (since the first import)' 'peak RSS'; do
    [[ $stderr == *"$phase"* ]] || { echo "missing phase: $phase"; return 1; }
  done
}

@test "--timings-json reports phases, facts and peak memory as one JSON object" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --lines 20 --timings-json "$SAMPLE"
  [ "$status" -eq 0 ]
  [ "$(field 'r["filetype"], r["engine"], r["grid"], r["resizes"]')" = "('markdown', 'render-markdown', '80x20', 0)" ]
  [ "$(field 'all(v >= 0 for v in r["phases"].values())')" = True ]
  [ "$(field 'r["ready_callbacks"] >= 1 and "frames: neovim queued (all frames)" in r["phases"]')" = True ]
  [ "$(field 'r["peak_rss_kb"]["children"] > 1024 and r["peak_rss_kb"]["python"] > 1024')" = True ]
  # Sub-phases follow their parent, and the startup split covers Neovim's own marks.
  [ "$(field 'list(r["phases"]).index("startup: neovim before profile.lua") > list(r["phases"]).index("startup")')" = True ]
  [ "$(field 'r["phases"]["frames"] >= r["phases"]["frames: first"] > 0')" = True ]
  [ "$(field 'r["total_ms"] >= r["phases"]["startup"] + r["phases"]["open"] + r["phases"]["frames"]')" = True ]
}

@test "--all records resize rounds when the first grid is too short" {
  # Long wrapped lines at 20 columns need more rows than the source line count the grid starts with.
  file=$BATS_TEST_TMPDIR/wrapped.md
  for _ in 1 2 3 4 5 6; do printf '%s\n\n' "$(printf 'word %.0s' {1..40})"; done >"$file"
  run --separate-stderr "$NVCAT" --paging=never --columns 20 --all --timings-json "$file"
  [ "$status" -eq 0 ]
  [ "$(field 'r["resizes"] >= 1 and r["phases"]["frames: resizes"] > 0')" = True ]
}

@test "the bat fallback is reported as the engine" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --budget 0.000001 --timings-json "$SAMPLE"
  [ "$status" -eq 0 ]
  stderr=$(tail -1 <<<"$stderr")  # After the fallback notice
  [ "$(field 'r["engine"], "bat fallback" in r["phases"]')" = "('bat fallback', True)" ]
}

@test "timings are printed when the render fails" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --start-line 99999 --timings-json "$SAMPLE"
  [ "$status" -eq 1 ]
  [[ $stderr == *'"phases"'* ]]
  [[ $stderr == *'exceeds document length'* ]]
}

@test "--timings and --timings-json are mutually exclusive" {
  run "$NVCAT" --timings --timings-json "$SAMPLE"
  [ "$status" -eq 2 ]
  [[ $output == *'not allowed with'* ]]
}

@test "--syntax regex uses Vim's syntax files for a Tree-sitter filetype" {
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --all --timings-json -- "$FIXTURES/kdl/config.kdl"
  [ "$(field 'r["engine"], r["ready_callbacks"]')" = "('treesitter', 1)" ]
  treesitter=$output
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --all --syntax regex --timings-json -- \
    "$FIXTURES/kdl/config.kdl"
  [ "$status" -eq 0 ]
  [ "$(field 'r["engine"], "open: regex syntax" in r["phases"], "open: parse" in r["phases"]')" = \
    "('syntax', True, False)" ]
  [ "$output" != "$treesitter" ]
}

@test "--syntax regex renders Markdown without render-markdown" {
  rendered=$("$NVCAT" --paging=never --columns 80 --all "$SAMPLE")
  run --separate-stderr "$NVCAT" --paging=never --columns 80 --all --syntax regex --timings-json "$SAMPLE"
  [ "$status" -eq 0 ]
  [ "$(field 'r["engine"]')" = syntax ]
  [ "$output" != "$rendered" ]
  [[ $output == *'# '* ]]  # Raw heading markers, which render-markdown would conceal
  [[ $output == *$'\e[0;'* ]]
}

@test "--syntax rejects unknown engines" {
  run "$NVCAT" --syntax treesitter "$SAMPLE"
  [ "$status" -eq 2 ]
}
