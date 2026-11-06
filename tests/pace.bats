#!/usr/bin/env bats
# --pace: a terminal gets the output a line at a time, at a rate that follows the text; everything else at once.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  HELPERS=$BATS_TEST_DIRNAME/helpers
  DOCUMENT=$BATS_TEST_TMPDIR/document.md
  for number in 1 2 3 4 5 6 7 8 9 10; do
    printf 'Line %s has enough words in it to take a measurable time.\n\n' "$number"
  done > "$DOCUMENT"
}

# Run nvcat on a terminal; then field EXPRESSION reads its report, a dict r.
session() {
  report=$(python3 "$HELPERS/pace_session.py" "$@")
}

field() {
  python3 -c 'import json, sys; r = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$report" "$1"
}

# Python with nvcat's module as m and a fake clock: sleeping advances it, and every write is logged with the time.
with_clock() {
  python3 - "$HELPERS" "$1" <<'PY'
import io, sys
sys.path.insert(0, sys.argv[1])
from common import load_nvcat
m = load_nvcat()
class Clock:
  now = 100.0
  def __call__(self): return self.now
  def sleep(self, seconds): self.now += seconds
clock = Clock()
class Stream(io.BytesIO):
  times = []
  def write(self, data):
    self.times.append((round(clock.now - 100, 3), bytes(data)))
    return super().write(data)
stream = Stream()
exec(sys.argv[2])
print("ok")
PY
}

@test "paced lines wait in proportion to their visible text, and the last one does not wait" {
  run with_clock "
m.write_paced(b'x' * 100 + b'\n' + b'y' * 50 + b'\n' + b'z\n', 100.0, stream, clock, clock.sleep)
assert [time for time, _ in stream.times] == [0, 1.0, 1.5], stream.times
assert clock.now - 100 == 1.5, clock.now
assert stream.getvalue() == b'x' * 100 + b'\n' + b'y' * 50 + b'\n' + b'z\n'"
  [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "color and hyperlink sequences do not count as text, and a blank line waits only the floor" {
  run with_clock "
assert m.line_delay(b'\x1b[0;38;2;1;2;3;49mabcd\x1b[0m\n', 2) == 2.0
link = b'\x1b]8;id=1;http://a.example/long/target\x1b\\\\abcd\x1b]8;;\x1b\\\\\x1b[0m\n'
assert m.line_delay(link, 2) == 2.0, m.line_delay(link, 2)
assert m.line_delay(b'\n', 100) == m.PACE_FLOOR
assert m.line_delay(b'    \x1b[0m\n', 100) == m.PACE_FLOOR
assert m.line_delay('éé\n'.encode(), 2) == 1.0  # Characters, not bytes."
  [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "slow writes do not slow the pace, and a stop like Ctrl-Z does not end in a burst" {
  run with_clock "
class Slow(Stream):
  def write(self, data):
    result = super().write(data)
    clock.now += 0.25  # Half of each one-second line.
    return result
stream = Slow()
Stream.times = []
m.write_paced(b'x' * 100 + b'\n' + b'x' * 100 + b'\n' + b'x\n', 100.0, stream, clock, clock.sleep)
assert [time for time, _ in stream.times] == [0, 1.0, 2.0], stream.times
Stream.times = []
clock.now = 100.0
class Stopped(Stream):
  count = 0
  def write(self, data):
    result = super().write(data)
    self.count += 1
    if self.count == 1:
      clock.now += 60  # Suspended after the first line.
    return result
stream = Stopped()
m.write_paced(b'x' * 100 + b'\n' + b'x' * 100 + b'\n' + b'x\n', 100.0, stream, clock, clock.sleep)
assert [time for time, _ in stream.times] == [0, 60.0, 61.0], stream.times"
  [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "an interrupted paced write closes any open color and link, only when the output has escapes" {
  run with_clock "
def interrupted(_):
  raise KeyboardInterrupt
for output, expected in [(b'\x1b[1mone\n\x1b[1mtwo\n', b'\x1b[1mone\n\x1b]8;;\x1b\\\\\x1b[0m'), (b'one\ntwo\n', b'one\n')]:
  stream = Stream()
  try:
    m.write_paced(output, 100.0, stream, clock, interrupted)
  except KeyboardInterrupt:
    pass
  else:
    raise AssertionError('not interrupted')
  assert stream.getvalue() == expected, stream.getvalue()"
  [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "--pace on a terminal takes the time the text needs, prints what --paging=never prints, and opens no pager" {
  session --paging=never --columns 80 "$DOCUMENT"
  plain=$(field 'r["output"]')
  [ "$(field 'r["status"]')" = 0 ]
  [ "$(field 'r["elapsed"] < 0.3')" = True ]
  # 10 lines of about 56 characters at 800 per second, and the blank ones between them: about 0.9 s.
  session --pace=800 --columns 80 "$DOCUMENT"
  [ "$(field 'r["status"]')" = 0 ]
  [ "$(field '0.6 < r["elapsed"] < 5')" = True ] || field 'r["elapsed"]'
  [ "$(field 'r["output"]')" = "$plain" ]
  [ "$(field 'r["left"]')" = "[]" ]
}

@test "a bare --pace uses the default rate and leaves the next word as the file" {
  session --pace --columns 80 "$DOCUMENT"
  [ "$(field 'r["status"]')" = 0 ]
  [ "$(field '"Line 10" in r["output"]')" = True ]
  [ "$(field 'r["elapsed"] > 0.6')" = True ]
  # After --, it is a file name.
  : > "$BATS_TEST_TMPDIR/--pace"
  run "$NVCAT" --paging=never --columns 80 -- "$BATS_TEST_TMPDIR/--pace"
  [ "$status" -eq 0 ]
}

@test "Ctrl-C stops paced output with status 130 and leaves no color on, or a Neovim" {
  session --interrupt --pace=20 --columns 80 "$DOCUMENT"
  [ "$(field 'r["status"]')" = 130 ]
  [ "$(field '"Line 10" not in r["output"]')" = True ]
  [ "$(field 'r["output"].rstrip("\n").endswith("\x1b[0m")')" = True ]
  [ "$(field 'r["left"]')" = "[]" ]
}

@test "a pipe and an fzf preview are never paced, whether by flag or by config" {
  # One character per second would take minutes.
  run timeout 20 bash -c "'$NVCAT' --pace=1 --columns 80 '$DOCUMENT' | cat"
  [ "$status" -eq 0 ]
  [[ $output == *'Line 10'* ]]
  NVCAT_PACE=1 run timeout 20 bash -c "'$NVCAT' --columns 80 '$DOCUMENT' | cat"
  [ "$status" -eq 0 ]
  SESSION_ENV='FZF_PREVIEW_COLUMNS=80 FZF_PREVIEW_LINES=40' session --pace=1 "$DOCUMENT"
  [ "$(field 'r["status"]')" = 0 ]
  [ "$(field 'r["elapsed"] < 5')" = True ]
}

@test "the config key turns pacing on, and --pace=off and the pager modes turn it off" {
  SESSION_ENV='NVCAT_PACE=1' session --pace=off --paging=never --columns 80 "$DOCUMENT"
  [ "$(field 'r["status"], r["elapsed"] < 5')" = "(0, True)" ]
  SESSION_ENV='NVCAT_PACE=400' session --columns 80 "$DOCUMENT"
  [ "$(field 'r["status"], r["elapsed"] > 1.2')" = "(0, True)" ]
  # No error for the config key with --paging=always: the pager wins (here a terminal-less print).
  NVCAT_PACE=1 run timeout 20 bash -c "'$NVCAT' --paging=always --columns 80 '$DOCUMENT' | cat"
  [ "$status" -eq 0 ]
}

@test "--pace with a pager mode, or a bad rate, is an error" {
  run "$NVCAT" --pace --paging=always "$DOCUMENT"
  [ "$status" -eq 1 ]
  [[ $output == *'--pace prints the document as it goes'* ]]
  run "$NVCAT" --pace --follow "$DOCUMENT"
  [ "$status" -eq 1 ]
  [[ $output == *'--pace prints the document as it goes'* ]]
  for rate in 0 -5 abc inf nan; do
    run "$NVCAT" "--pace=$rate" "$DOCUMENT"
    [ "$status" -eq 2 ] || { echo "$rate: $output"; return 1; }
    [[ $output == *'is not on, off or a positive number'* ]]
  done
  NVCAT_PACE=abc run "$NVCAT" --columns 80 "$DOCUMENT"
  [ "$status" -eq 1 ]
  [[ $output == *'pace:'* ]]
  run "$NVCAT" --pace=off --paging=always --columns 80 "$DOCUMENT"
  [ "$status" -eq 0 ]
}
