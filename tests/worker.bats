#!/usr/bin/env bats
# NVCAT_WORKER=1: fzf previews from a Neovim that stays running, always the same bytes as without it.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
  NVCAT=$ROOT/nvcat
  HELPERS=$ROOT/tests/helpers
  SAMPLE=$ROOT/benchmarks/small.md
  DIR=$BATS_TEST_TMPDIR/worker
  SOCKET=$DIR/worker.socket
  export FZF_PREVIEW_COLUMNS=100 FZF_PREVIEW_LINES=40
  FRESH=$BATS_TEST_TMPDIR/fresh
  "$NVCAT" "$SAMPLE" >"$FRESH"
  export NVCAT_WORKER=1 NVCAT_WORKER_DIR=$DIR
}

teardown() {
  ask '{"quit": true}' >/dev/null 2>&1 || true
  wait_gone
}

ask() { python3 "$HELPERS/worker_ask.py" "$SOCKET" "$1"; }
stat_of() { ask '{"stats": true}' | python3 -c "import json, sys; print(json.load(sys.stdin)[sys.argv[1]])" "$1"; }
# The run directory's cleaner, a fork of the worker, has the same command line: count those whose parent is not one.
workers() {
  local pids pid count=0
  pids=" $(pgrep -f "nvcat_worker.py $SOCKET" | tr '\n' ' ') "
  for pid in $pids; do
    [[ $pids == *" $(ps -o ppid= -p "$pid" | tr -d ' ') "* ]] || count=$((count + 1))
  done
  echo "$count"
}
leftover() {
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from common import embedded_nvims; print(len(embedded_nvims()))' "$HELPERS"
}

wait_gone() {
  for _ in $(seq 1 100); do
    [ "$(workers)" -eq 0 ] && return 0
    sleep 0.05
  done
  return 1
}

answering() {
  for _ in $(seq 1 200); do
    ask '{"stats": true}' >/dev/null 2>&1 && return 0
    sleep 0.02
  done
  return 1
}

# Start one through the first preview, which renders by itself.
started() {
  "$NVCAT" "$SAMPLE" >/dev/null
  answering
}

@test "off unless NVCAT_WORKER=1: no worker and no directory" {
  unset NVCAT_WORKER
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  [ ! -e "$DIR" ]
}

@test "the first preview renders by itself and starts a worker; the next comes from it, the same bytes" {
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  answering
  [ "$(stat_of previews)" -eq 0 ]
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  [ "$(stat_of previews)" -eq 1 ]
  [ "$(stat -c %a "$DIR")" = 700 ]
  [ "$(stat -c %a "$SOCKET")" = 700 ] || [ "$(stat -c %a "$SOCKET")" = 755 ]
}

@test "a relative path is the client's, whatever the worker's directory" {
  started
  (cd "$ROOT/benchmarks" && "$NVCAT" small.md) | cmp - "$FRESH"
  [ "$(stat_of previews)" -eq 1 ]
}

@test "anything but one file in a preview goes the usual way" {
  started
  run --separate-stderr "$NVCAT" --lines 5 "$SAMPLE"
  [ "$status" -eq 0 ]
  "$NVCAT" --columns 80 -- "$SAMPLE" >/dev/null
  unset FZF_PREVIEW_COLUMNS FZF_PREVIEW_LINES
  "$NVCAT" --paging=never "$SAMPLE" >/dev/null
  [ "$(stat_of previews)" -eq 0 ]
}

@test "complete output with the router's flags: the same bytes, repeated and between sizes" {
  large=$ROOT/benchmarks/large.md
  flags=(--all --paging=never --budget=20 --filetype markdown --)
  NVCAT_WORKER=0 "$NVCAT" "${flags[@]}" "$large" >"$BATS_TEST_TMPDIR/complete"
  started
  for _ in 1 2 3 4 5 6; do
    "$NVCAT" "${flags[@]}" "$large" | cmp - "$BATS_TEST_TMPDIR/complete"
  done
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"  # The viewport after a grid grown for complete output.
  "$NVCAT" --all --paging=never --budget=20 --filetype markdown -- "$large" | cmp - "$BATS_TEST_TMPDIR/complete"
  [ "$(stat_of previews)" -eq 8 ]
}

@test "the real router's previews come from the worker, the same bytes" {
  [ -x "$ROOT/nvcat-dispatch" ] || skip "no generated router"
  export NVCAT=$ROOT/nvcat
  NVCAT_WORKER=0 "$ROOT/nvcat-dispatch" "$SAMPLE" >"$BATS_TEST_TMPDIR/routed"
  started
  "$ROOT/nvcat-dispatch" "$SAMPLE" | cmp - "$BATS_TEST_TMPDIR/routed"
  "$ROOT/nvcat-dispatch" -- "$SAMPLE" | cmp - "$BATS_TEST_TMPDIR/routed"
  [ "$(stat_of previews)" -eq 2 ]
}

@test "a file named with a leading dash is served after --" {
  dashed=$BATS_TEST_TMPDIR/-dashed.md
  cp "$SAMPLE" "$dashed"
  started
  cd "$BATS_TEST_TMPDIR"
  "$NVCAT" --all --budget=20 -- -dashed.md >"$BATS_TEST_TMPDIR/served"
  NVCAT_WORKER=0 "$NVCAT" --all --budget=20 -- -dashed.md | cmp - "$BATS_TEST_TMPDIR/served"
  [ "$(stat_of previews)" -eq 1 ]
}

@test "over the budget, nvcat goes to the fallback once, and the next preview is right" {
  command -v bat >/dev/null || skip "bat is not installed"
  large=$ROOT/benchmarks/large.md
  NVCAT_WORKER=0 "$NVCAT" --all --budget=0.001 "$large" >"$BATS_TEST_TMPDIR/expected" 2>"$BATS_TEST_TMPDIR/expected.err"
  started
  "$NVCAT" --all --budget=0.001 "$large" >"$BATS_TEST_TMPDIR/got" 2>"$BATS_TEST_TMPDIR/got.err"
  [ "$(stat_of over_limit)" -eq 1 ]
  [ "$(stat_of refused)" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/got" "$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/got.err" "$BATS_TEST_TMPDIR/expected.err"
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  [ "$(stat_of previews)" -eq 1 ]
}

@test "flags and values the worker does not serve go the usual way" {
  started
  "$NVCAT" --all --budget=0 "$SAMPLE" >/dev/null
  "$NVCAT" --all --budget=nonsense "$SAMPLE" >/dev/null 2>&1 || true
  "$NVCAT" --all --fallback=none "$SAMPLE" >/dev/null
  "$NVCAT" --all --timeout=5 "$SAMPLE" >/dev/null
  "$NVCAT" --all "$SAMPLE" "$SAMPLE" >/dev/null 2>&1 || true
  "$NVCAT" --filetype >/dev/null 2>&1 || true
  [ "$(stat_of previews)" -eq 0 ]
  [ "$(stat_of refused)" -eq 0 ]
}

@test "--filetype auto is left to nvcat" {
  started
  "$NVCAT" --all --filetype auto "$SAMPLE" >/dev/null
  [ "$(stat_of previews)" -eq 0 ]
  [ "$(stat_of refused)" -eq 1 ]
}

@test "a complete preview killed partway cancels it, and the next one is right" {
  large=$ROOT/benchmarks/large.md
  started
  "$NVCAT" --all --budget=20 "$large" >"$BATS_TEST_TMPDIR/complete"
  for delay in 0.02 0.08 0.15; do
    "$NVCAT" --all --budget=20 "$large" >/dev/null &
    client=$!
    sleep "$delay"
    kill "$client" 2>/dev/null || true
    wait "$client" 2>/dev/null || true
    "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
    "$NVCAT" --all --budget=20 "$large" | cmp - "$BATS_TEST_TMPDIR/complete"
  done
  [ "$(stat_of cancelled)" -ge 1 ]
}

@test "errors and the bat fallback are nvcat's own, unchanged" {
  started
  run --separate-stderr "$NVCAT" "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 1 ]
  [[ $stderr == nvcat:*missing.md* ]]
  binary=$BATS_TEST_TMPDIR/binary.md
  printf 'a\0b\n' >"$binary"
  NVCAT_WORKER=0 "$NVCAT" "$binary" >"$BATS_TEST_TMPDIR/expected" 2>&1
  "$NVCAT" "$binary" 2>&1 | cmp - "$BATS_TEST_TMPDIR/expected"
  [ "$(stat_of previews)" -eq 0 ]
  [ "$(stat_of refused)" -eq 2 ]
}

@test "a file edited between previews shows its new content" {
  started
  file=$BATS_TEST_TMPDIR/edited.md
  printf '# OLD_MARK\n' >"$file"
  [[ $("$NVCAT" "$file") == *OLD_MARK* ]]
  printf '# NEW_MARK\n' >"$file"
  output=$("$NVCAT" "$file")
  [[ $output == *NEW_MARK* && $output != *OLD_MARK* ]]
  [ "$(stat_of previews)" -eq 2 ]
}

@test "a worker killed outright: previews still print, a new one starts, no Neovim stays" {
  started
  before=$(leftover)
  [ "$before" -eq 1 ]
  pkill -9 -f "nvcat_worker.py $SOCKET"
  wait_gone
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  answering
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  [ "$(stat_of previews)" -eq 1 ]
  for _ in $(seq 1 100); do
    [ "$(leftover)" -le 1 ] && break
    sleep 0.05
  done
  [ "$(leftover)" -eq 1 ]
}

@test "a Neovim that dies is replaced at the next preview" {
  started
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  kill -9 "$(stat_of nvim)"
  sleep 0.1
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  [ "$(stat_of previews)" -ge 2 ]
}

@test "idle for NVCAT_WORKER_IDLE seconds, it exits and leaves no Neovim" {
  export NVCAT_WORKER_IDLE=1
  started
  "$NVCAT" "$SAMPLE" >/dev/null
  [ "$(workers)" -eq 1 ]
  [ "$(leftover)" -eq 1 ]
  sleep 1.2
  wait_gone
  for _ in $(seq 1 100); do
    [ "$(leftover)" -eq 0 ] && break
    sleep 0.05
  done
  [ "$(leftover)" -eq 0 ]
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"  # The socket it left behind does not get in the way.
}

@test "clients starting at once leave one worker" {
  for _ in 1 2 3 4 5 6; do "$NVCAT" "$SAMPLE" >/dev/null & done
  wait
  answering
  sleep 0.3
  [ "$(workers)" -eq 1 ]
}

@test "a directory other users can reach is not used" {
  mkdir -p "$DIR"
  chmod 755 "$DIR"
  "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  sleep 0.3
  [ ! -e "$SOCKET" ]
  [ "$(workers)" -eq 0 ]
  chmod 700 "$DIR"
}

@test "a client killed mid-preview cancels it, and the next preview is right" {
  started
  large=$ROOT/benchmarks/large.md
  "$NVCAT" "$large" >/dev/null
  for delay in 0.01 0.03 0.05 0.07 0.09 0.11; do
    "$NVCAT" "$large" >/dev/null &
    client=$!
    sleep "$delay"
    kill "$client" 2>/dev/null || true
    wait "$client" 2>/dev/null || true
    "$NVCAT" "$SAMPLE" | cmp - "$FRESH"
  done
  [ "$(stat_of cancelled)" -ge 1 ]
}

@test "real fzf: moving through files quickly kills previews, the last one shows, nothing stays" {
  command -v fzf >/dev/null || skip "fzf is not installed"
  for name in one two three; do
    printf '# %s_MARK\n\nText.\n' "$name" >"$BATS_TEST_TMPDIR/$name.md"
  done
  cd "$ROOT"
  run python3 "$HELPERS/worker_fzf.py" three_MARK "$BATS_TEST_TMPDIR/one.md" "$BATS_TEST_TMPDIR/two.md" "$BATS_TEST_TMPDIR/three.md"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stat_of previews)" -ge 1 ]
}
