#!/usr/bin/env bats
# Ported from the historical verify.py: document tails, viewports, unusual names, stdin, empty files,
# modelines, errors, terminal round trip, cancellation, source immutability, and the write sandbox.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  REFERENCE=$BATS_TEST_DIRNAME/fixtures/reference
  HELPERS=$BATS_TEST_DIRNAME/helpers
}

plain() {
  sed 's/\x1b\[[0-9;]*m//g' <<<"$1"
}

@test "complete output includes each reference document's first and last lines" {
  for name in syntax tables extended; do
    upper=$(tr a-z A-Z <<<"$name")
    for width in 80 120; do
      run --separate-stderr "$NVCAT" --paging=never --columns "$width" --all "$REFERENCE/$name.md"
      [ "$status" -eq 0 ] || { echo "$name $width: $stderr"; return 1; }
      text=$(plain "$output")
      [[ $text == *"REFERENCE_${upper}_TOP"* ]] || { echo "$name $width: top missing"; return 1; }
      [[ $text == *"REFERENCE_${upper}_BOTTOM"* ]] || { echo "$name $width: tail missing"; return 1; }
    done
  done
}

@test "viewports never exceed the requested height" {
  for name in syntax tables extended; do
    for size in 80x24 120x40 40x5; do
      run "$NVCAT" --paging=never --columns "${size%x*}" --lines "${size#*x}" "$REFERENCE/$name.md"
      [ "$status" -eq 0 ]
      [ "${#lines[@]}" -le "${size#*x}" ] || { echo "$name $size: ${#lines[@]} lines"; return 1; }
    done
  done
}

@test "a one-row viewport renders one row (Neovim's grid is at least two)" {
  run --separate-stderr "$NVCAT" --paging=never --fallback none --timeout 8 --columns 40 --lines 1 \
    "$REFERENCE/extended.md"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "${#lines[@]}" -eq 1 ]
  [[ $(plain "$output") == *REFERENCE_EXTENDED_TOP* ]]
  run --separate-stderr "$NVCAT" --paging=never --fallback none --timeout 8 --columns 40 --lines 1 \
    --start-line 18 "$REFERENCE/extended.md"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "${#lines[@]}" -eq 1 ]
  [[ $(plain "$output") == *Emanote* ]]
  FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=1 run --separate-stderr "$NVCAT" --fallback none --timeout 8 \
    "$REFERENCE/syntax.md"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "${#lines[@]}" -eq 1 ]
}

@test "literal filenames with spaces, pipes, hashes, percents and brackets, plus Unicode" {
  special="$BATS_TEST_TMPDIR/name with spaces | # % [brackets].md"
  printf '# Unicode preview\n\n日本語 café e\xcc\x81 🙂\n\nEND_UNICODE\n' > "$special"
  run --separate-stderr "$NVCAT" --paging=never --columns 80 "$special"
  [ "$status" -eq 0 ]
  text=$(plain "$output")
  [[ $text == *$'日本語 café e\xcc\x81 🙂'* ]]
  [[ $text == *END_UNICODE* ]]
}

@test "finite stdin with Unicode" {
  run --separate-stderr bash -c "printf '# Stdin\n\n日本語 🙂\n\nEND_STDIN\n' | '$NVCAT' --paging=never --columns 80 -"
  [ "$status" -eq 0 ]
  [[ $(plain "$output") == *'日本語 🙂'*END_STDIN* ]]
}

@test "an empty file renders as nothing" {
  : > "$BATS_TEST_TMPDIR/empty.md"
  run --separate-stderr "$NVCAT" --paging=never --columns 80 "$BATS_TEST_TMPDIR/empty.md"
  [ "$status" -eq 0 ]
  [ -z "$(plain "$output" | tr -d '[:space:]')" ]
}

@test "modelines are not executed" {
  marker=$BATS_TEST_TMPDIR/MODELINE_EXECUTED
  printf 'SAFE\n<!-- vim: set modelineexpr foldmethod=expr foldexpr=system("touch %s"): -->\n' "$marker" \
    > "$BATS_TEST_TMPDIR/modeline.md"
  run "$NVCAT" --paging=never --columns 80 "$BATS_TEST_TMPDIR/modeline.md"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "errors are reported without a traceback" {
  run "$NVCAT" --paging=never "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 1 ]
  [[ $output == nvcat:* ]]
  [[ $output != *Traceback* ]]
  run "$NVCAT" --paging=never --columns 80 --start-line 99999 "$REFERENCE/syntax.md"
  [ "$status" -eq 1 ]
  [[ $output != *Traceback* ]]
  mkdir "$BATS_TEST_TMPDIR/dir.md"
  run "$NVCAT" --paging=never "$BATS_TEST_TMPDIR/dir.md"
  [ "$status" -eq 1 ]
  [[ $output != *Traceback* ]]
}

@test "ANSI output round-trips through Neovim's terminal emulator" {
  special="$BATS_TEST_TMPDIR/unicode.md"
  printf '# Unicode preview\n\n日本語 café e\xcc\x81 🙂\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nEND_UNICODE\n' > "$special"
  run python3 "$HELPERS/roundtrip.py" "$special" END_UNICODE
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run python3 "$HELPERS/roundtrip.py" "$REFERENCE/tables.md" REFERENCE_TABLES_BOTTOM
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

nvims() {
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from common import embedded_nvims; print(" ".join(map(str, sorted(embedded_nvims()))))' "$HELPERS"
}

@test "the leak checks count this suite's Neovims, not another shell's" {
  decoy() { "$@" python3 -c 'import time; time.sleep(30)' --embed "$ROOT/profile.lua" & }
  decoy env; ours=$!
  decoy env -u NVCAT_TEST_SESSION; theirs=$!
  for pid in "$ours" "$theirs"; do
    for _ in $(seq 1 100); do
      grep -qa -- --embed "/proc/$pid/cmdline" && break
      sleep 0.02
    done
  done
  seen=" $(nvims) "
  kill "$ours" "$theirs"
  wait "$ours" "$theirs" || true
  [[ $seen == *" $ours "* ]]
  [[ $seen != *" $theirs "* ]]
}

cancel_during_render() {
  local signal=$1 before after pid
  before=$(nvims)
  source "$HELPERS/slow_input.sh"
  slow_input "$BATS_TEST_TMPDIR/slow.md"
  "$NVCAT" --paging=never --columns 100 --lines 40 --timeout 60 "$BATS_TEST_TMPDIR/slow.md" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ "$(nvims)" != "$before" ] && break
    sleep 0.05
  done
  [ "$(nvims)" != "$before" ] || { echo "no embedded Neovim observed"; return 1; }
  kill -s "$signal" "$pid"
  wait "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do
    after=$(nvims)
    [ "$after" = "$before" ] && return 0
    sleep 0.05
  done
  echo "embedded Neovim left after SIG$signal: before [$before] after [$after]"
  return 1
}

@test "SIGTERM during a render leaves no Neovim behind" {
  cancel_during_render TERM
}

@test "SIGINT during a render leaves no Neovim behind" {
  cancel_during_render INT
}

@test "SIGKILL during a render leaves no Neovim behind" {
  cancel_during_render KILL
}

@test "rendering never modifies the source file" {
  copy=$BATS_TEST_TMPDIR/source.md
  cp "$REFERENCE/syntax.md" "$copy"
  before=$(stat -c '%Y %s' "$copy"; sha256sum < "$copy")
  "$NVCAT" --paging=never --columns 80 "$copy" >/dev/null
  "$NVCAT" --paging=never --columns 80 --lines 10 "$copy" >/dev/null
  after=$(stat -c '%Y %s' "$copy"; sha256sum < "$copy")
  [ "$before" = "$after" ]
}

@test "the write sandbox allows writes only in the run directory" {
  run_dir=$(mktemp -d /tmp/nvcat-test.XXXXXX)
  sibling=$(mktemp -d /tmp/nvcat-sibling.XXXXXX)
  run python3 - "$ROOT" "$run_dir" "$sibling" <<'PY'
import os, sys
root, run_dir, sibling = sys.argv[1:]
sys.path.insert(0, root)
from readonly import restrict_writes
restrict_writes(run_dir)
for label, path in [("checkout", os.path.join(root, "SANDBOX_ESCAPE")), ("sibling", os.path.join(sibling, "x")),
                    ("tmp", "/tmp/nvcat-sandbox-escape")]:
    try:
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT))
        print(label, "escaped")
    except PermissionError:
        print(label, "blocked")
with open(os.path.join(run_dir, "inside"), "w") as handle:
    handle.write("ok")
os.mkdir(os.path.join(run_dir, "sub"))
print("inside ok")
PY
  rm -rf "$run_dir" "$sibling"
  rm -f /tmp/nvcat-sandbox-escape
  [ "$output" = $'checkout blocked\nsibling blocked\ntmp blocked\ninside ok' ] || { echo "$output"; return 1; }
  [ ! -e "$ROOT/SANDBOX_ESCAPE" ]
}

@test "an external pager may write to its TMPDIR, the run directory" {
  pager=$BATS_TEST_TMPDIR/pager
  # The stub reports on stdout: the sandbox blocks the bats temporary directory too.
  printf '#!/bin/sh\nset -e\nf=$(mktemp)\ncat > "$f"\necho "pager tmp $f $(wc -c < "$f")"\n' > "$pager"
  chmod +x "$pager"
  run env NVCAT_PAGER="$pager" "$NVCAT" --paging=always --columns 80 \
    "$BATS_TEST_DIRNAME/fixtures/markdown/sample.md"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == "pager tmp /tmp/nvcat-"*' '[1-9]* ]] || { echo "$output"; return 1; }
}

run_dirs() {
  find /tmp -maxdepth 1 -name 'nvcat-*' -type d ! -name 'nvcat-test.*' ! -name 'nvcat-sibling.*' \
    2>/dev/null | sort
}

# Wait up to 5 s for the run directories not in $1 (an earlier run_dirs listing) to disappear.
run_dirs_removed() {
  local new
  for _ in $(seq 1 100); do
    new=$(comm -13 <(printf '%s\n' "$1") <(run_dirs))
    [ -z "$new" ] && return 0
    sleep 0.05
  done
  echo "run directories left: $new"
  return 1
}

@test "the run directory is removed after a render, stdin, and a fallback" {
  before=$(run_dirs)
  "$NVCAT" --paging=never --columns 80 "$REFERENCE/tables.md" >/dev/null
  echo '# stdin' | "$NVCAT" --paging=never --columns 80 - >/dev/null
  seq 1 1010 > "$BATS_TEST_TMPDIR/long.txt"
  "$NVCAT" --paging=never --columns 80 --filetype text "$BATS_TEST_TMPDIR/long.txt" >/dev/null 2>&1
  run_dirs_removed "$before"
}

@test "the run directory is removed even when nvcat is killed with SIGKILL" {
  before=$(run_dirs)
  "$NVCAT" --paging=never --columns 80 --all --budget 0 --timeout 30 "$REFERENCE/tables.md" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ -n "$(comm -13 <(printf '%s\n' "$before") <(run_dirs))" ] && break
    sleep 0.02
  done
  [ -n "$(comm -13 <(printf '%s\n' "$before") <(run_dirs))" ] || { echo "no run directory observed"; return 1; }
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null || true
  run_dirs_removed "$before"
}

@test "a Neovim that outlives a SIGKILLed nvcat is stopped before its run directory is removed" {
  # Neovim 0.12 stays running when its run directory disappears under it; the cleanup child waits for, then
  # kills, the Neovims nvcat registered, and removes the directory last.
  before_nvims=$(nvims)
  before_dirs=$(run_dirs)
  source "$HELPERS/slow_input.sh"
  slow_input "$BATS_TEST_TMPDIR/slow.md"
  "$NVCAT" --paging=never --columns 100 --lines 40 --timeout 60 "$BATS_TEST_TMPDIR/slow.md" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ "$(nvims)" != "$before_nvims" ] && break; sleep 0.05; done
  [ "$(nvims)" != "$before_nvims" ] || { echo "no embedded Neovim observed"; return 1; }
  kill -KILL "$pid"
  wait "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do [ "$(nvims)" = "$before_nvims" ] && break; sleep 0.05; done
  [ "$(nvims)" = "$before_nvims" ] || { echo "Neovim left: $(nvims)"; return 1; }
  run_dirs_removed "$before_dirs"
}
