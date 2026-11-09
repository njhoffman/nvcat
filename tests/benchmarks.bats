#!/usr/bin/env bats
# The benchmark scripts: fixture tiling, the regression rule, history migration, and a quick filetype run.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
}

# Run Python with the benchmark script $1 (no .py suffix) imported as `m`, then the code in $2.
with_script() {
  python3 - "$ROOT/benchmarks/$1" "$2" <<'PY'
import importlib.machinery, importlib.util, sys
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
loader = importlib.machinery.SourceFileLoader("m", sys.argv[1])
spec = importlib.util.spec_from_loader("m", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
exec(sys.argv[2])
PY
}

@test "tiling repeats a fixture to the requested length and keeps its directory" {
  run with_script filetypes "
import tempfile
from pathlib import Path
with tempfile.TemporaryDirectory() as temporary:
  path = m.tile(m.fixture('helm'), Path(temporary) / 'helm', 500)
  text = path.read_text()
  source = m.fixture('helm').read_text()
  assert text.count(chr(10)) >= 500, text.count(chr(10))
  assert text.startswith(source) and text.count(source) == len(text) // len(source)
  assert (path.parents[1] / 'Chart.yaml').is_file()
  assert '/templates/' in str(path)
print('ok')"
  [ "$output" = ok ]
}

@test "a regression needs both the percentage and the absolute slowdown" {
  run with_script filetypes "
base = {('tmux', 'fixture'): {'all_ms': '100', 'regex_ms': '', 'viewport_ms': '400', 'dispatch_ms': '100'}}
row = {'filetype': 'tmux', 'size': 'fixture', 'all_ms': 140, 'regex_ms': 900, 'viewport_ms': 460,
       'bat_ms': 999, 'dispatch_ms': 160}
found = m.regressions([row], base, 25, 50)
# all: +40% but only +40 ms; viewport: +60 ms but only +15%; regex: no baseline; bat is never checked.
assert found == ['tmux fixture dispatch: 100 -> 160 ms (+60%)'], found
assert m.regressions([dict(row, filetype='kdl')], base, 25, 50) == []
print('ok')"
  [ "$output" = ok ]
}

@test "history.tsv gains new columns without rewriting earlier rows" {
  run with_script run "
import tempfile
from pathlib import Path
with tempfile.TemporaryDirectory() as temporary:
  m.HISTORY = Path(temporary) / 'history.tsv'
  old = m.FIELDS[:10]
  m.HISTORY.write_text(chr(9).join(old) + chr(10) + chr(9).join(map(str, range(10))) + chr(10))
  m.append_history([{field: field for field in m.FIELDS}])
  lines = m.HISTORY.read_text().splitlines()
  assert lines[0] == chr(9).join(m.FIELDS), lines[0]
  assert lines[1] == chr(9).join(map(str, range(10)))
  rows = m.read_history()
  assert rows[0]['median_ms'] == '5' and 'startup_ms' not in rows[0]
  assert rows[1]['startup_ms'] == 'startup_ms'
print('ok')"
  [ "$output" = ok ]
}

@test "a quick check of one filetype measures every variant and records nothing" {
  command -v hyperfine >/dev/null || skip "needs hyperfine"
  python3 "$ROOT/tests/helpers/has_parser.py" kdl || skip "needs a kdl parser"
  recorded() { cat "$ROOT/benchmarks/filetypes.tsv" "$ROOT/docs/PERFORMANCE.md" 2>/dev/null || true; }
  before=$(recorded)
  run --separate-stderr "$ROOT/benchmarks/filetypes" --only kdl --quick --check --max-load 1000
  # The verdict is not judged here: --check exits 1 for a regression, and the suite's own load (or any other
  # process) turns a few runs into one (+47% at a load of 2.8, under the 0.6-per-CPU gate). Run
  # benchmarks/filetypes --check on a quiet machine for that; this checks that the run completes and reports.
  [ "$status" -eq 0 ] || { [ "$status" -eq 1 ] && [[ $output == *'regression: kdl '* ]]; } ||
    { echo "status $status: $output $stderr"; return 1; }
  [[ $stderr == *'kdl'*'treesitter'*'all '*'regex '*'viewport '*'bat '*'dispatch '* ]]
  [[ $output == *'regressions against the baseline'* ]]
  [ "$before" = "$(recorded)" ]
}

@test "--only rejects filetypes that are not in filetypes.json" {
  run "$ROOT/benchmarks/filetypes" --only kdl,nosuch --check --max-load 1000
  [ "$status" -eq 1 ]
  [[ $output == *'not in filetypes.json: nosuch'* ]]
}

@test "the highlighter benchmark compares one document in both modes and records nothing" {
  NVCAT_HIGHLIGHT_INDEX=1 "$ROOT/nvcat" --paging=never --columns 80 --lines 1 --timings-json "$ROOT/benchmarks/small.md" 2>&1 >/dev/null |
    python3 -c 'import json, sys; sys.exit(json.load(sys.stdin)["highlight_index"] != "on")' ||
    skip "this Neovim has no highlighter index to compare"
  before=$(sha1sum <"$ROOT/docs/PERFORMANCE.md")
  run --separate-stderr "$ROOT/benchmarks/highlighter" --runs 1 --max-load 1000 "$ROOT/tests/fixtures/markdown/sample.md"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [[ $output == '<!-- highlighter:start -->'* && $output == *'<!-- highlighter:end -->' ]]
  grep -qE '^\| sample\.md \| [0-9]+ \| [0-9,]+ \| [0-9]+ / [0-9]+ \|' <<<"$output"
  [ "$(sha1sum <"$ROOT/docs/PERFORMANCE.md")" = "$before" ]
}

@test "benchmarks/run records worker modes, from a worker that served them all" {
  history=$(md5sum "$ROOT/benchmarks/history.tsv")
  run --separate-stderr "$ROOT/benchmarks/run" --dry-run --runs 1 --max-load 1000
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(grep -c '| worker |' <<<"$output")" -eq 4 ]
  [ "$(grep -c '| worker-all |' <<<"$output")" -eq 4 ]
  [ "$history" = "$(md5sum "$ROOT/benchmarks/history.tsv")" ]
  run with_script run "
try:
  m.all_served({'previews': 3}, 4)
except SystemExit as error:
  print('refused', error)"
  [[ $output == refused*'served 3 of 4'* ]]
}

@test "the benchmarks' fresh renders ignore NVCAT_WORKER in the environment" {
  NVCAT_WORKER=1 run with_script run "
from common import render_command
print(render_command(m.ROOT, 'small', 'fzf', 5)[1].get('NVCAT_WORKER'))"
  [ "$output" = None ]
}

@test "benchmarks/run warms every sample and mode once, then renders them round-robin" {
  run with_script run "
calls = []
def fake(sample, mode, timeout):
  calls.append((sample, mode))
  return (len(calls), 10.0, 40.0, 20.0)
pairs = [('a', 'x'), ('a', 'y'), ('b', 'x')]
summary = m.measure(pairs, 2, 60, render=fake)
assert calls == pairs * 3, calls
# Rounds 2 and 3 (calls 4-9): a/x took 4 and 7 ms.
assert summary[('a', 'x')]['median_ms'] == round((4 + 7) / 2) and summary[('a', 'x')]['min_ms'] == 4, summary
assert summary[('b', 'x')]['startup_ms'] == 10 and summary[('b', 'x')]['nvim_rss_mib'] == 40
print('ok')"
  [ "$output" = ok ]
}

@test "benchmarks/run calls a run noisy when the load rose or startup is far above its history" {
  run with_script run "
history = [{'sample': 's', 'mode': 'm', 'startup_ms': str(v)} for v in (40, 42, 38, 41, 39, 400)]
history.append({'sample': 's', 'mode': 'm', 'startup_ms': ''})  # Before the column existed.
quiet = [{'sample': 's', 'mode': 'm', 'startup_ms': 50}]
busy = [{'sample': 's', 'mode': 'm', 'startup_ms': 90}]
# The last five recorded startups (42 38 41 39 400) have a median of 41.
assert m.noise(quiet, history, 2.0, 4.8) is None
assert 'startup is 2.2x' in m.noise(busy, history, 2.0, 4.8), m.noise(busy, history, 2.0, 4.8)
assert 'load rose to 6.10' in m.noise(quiet, history, 6.1, 4.8)
assert m.noise(busy, [], 2.0, 4.8) is None  # No history: nothing to compare with.
print('ok')"
  [ "$output" = ok ]
}

@test "benchmarks/run compares with the average of all runs and the median of recent ones" {
  run with_script run "
history = [{'sample': 'small', 'mode': 'm', 'median_ms': str(v)} for v in (1000, 1000, 100, 100, 100, 100, 100)]
row = dict(date='d', version='v', commit='c', load1='0', nvim='n', runs=3, sample='small', mode='m', median_ms=90,
           startup_ms=1, nvim_rss_mib=2, python_rss_mib=3)
cells = [cell.strip() for cell in m.table([row], history).splitlines()[-3].split('|')]
header = [cell.strip() for cell in m.table([row], history).splitlines()[4].split('|')]
assert len(cells) == len(header), (cells, header)
named = dict(zip(header, cells))
# The two old rows pull the average up; they are outside the last five, so the recent median ignores them.
assert named['Average (ms)'] == '357' and named['vs average'] == '-75%', named
assert named['Recent (ms)'] == '100' and named['vs recent'] == '-10%', named
first = dict(zip(header, [cell.strip() for cell in m.table([row], []).splitlines()[-3].split('|')]))
assert first['vs average'] == first['vs recent'] == 'first run', first
print('ok')"
  [ "$output" = ok ]
}

@test "benchmarks/run exits 2 when the load never drops, and records nothing" {
  run with_script run "
import contextlib, io
m.wait_for_load = lambda *arguments: False
m.append_history = m.update_syntax = lambda *arguments: (_ for _ in ()).throw(AssertionError('recorded'))
sys.argv = ['run', '--max-wait', '0']
errors = io.StringIO()
with contextlib.redirect_stderr(errors):
  status = m.main()
assert status == 2, status
assert 'nothing recorded' in errors.getvalue(), errors.getvalue()
print('ok')"
  [ "$output" = ok ]
}

@test "benchmarks/compare calls a change only when the middle of the differences is on one side of zero" {
  run with_script compare "
slower = m.summarize([(100, 120), (100, 118), (100, 122), (100, 119)])
assert slower['verdict'] == 'slower' and round(slower['change']) == 20, slower
faster = m.summarize([(120, 100), (118, 100), (122, 100), (119, 100)])
assert faster['verdict'] == 'faster', faster
# The median says +5%, as a burst on one side can, but the differences straddle zero.
noise = m.summarize([(100, 90), (100, 105), (100, 105), (100, 130), (100, 80)])
assert noise['verdict'] == 'noise' and noise['change'] == 5, noise
one = m.summarize([(100, 110)])
assert one['verdict'] == 'too few rounds' and one['low'] == one['high'] == 10, one
assert m.summarize([(100, 110)] * 2)['verdict'] == 'too few rounds'
assert m.summarize([(100, 110)] * 3)['verdict'] == 'slower'
print('ok')"
  [ "$output" = ok ]
}

@test "benchmarks/compare warms up, swaps which side goes first, and notices different output" {
  run with_script compare "
calls = []
def fake(side, sample, mode):
  calls.append((side, sample))
  return (1.0 if side == 'ref' else 2.0, b'same' if sample == 'a' else side.encode())
import contextlib, io
with contextlib.redirect_stderr(io.StringIO()):
  times, same = m.measure([('a', 'x'), ('b', 'x')], 2, fake)
warmup = [('ref', 'a'), ('tree', 'a'), ('ref', 'b'), ('tree', 'b')]
first = [('ref', 'a'), ('tree', 'a'), ('ref', 'b'), ('tree', 'b')]
second = [('tree', 'a'), ('ref', 'a'), ('tree', 'b'), ('ref', 'b')]
assert calls == warmup + first + second, calls
assert times[('a', 'x')] == [(1.0, 2.0), (1.0, 2.0)], times  # Paired by side, whichever ran first.
assert same == {('a', 'x'): True, ('b', 'x'): False}, same
print('ok')"
  [ "$output" = ok ]
}

@test "benchmarks/compare gives the ref the config keys it knows, and leaves the rest out" {
  run with_script compare "
import json, tempfile, tomllib
from pathlib import Path
with tempfile.TemporaryDirectory() as temporary:
  exported = Path(temporary)
  (exported / 'config.py').write_text('KEYS = dict(theme=1, plugin_dirs=1, pace=1)')
  source = exported / 'source.toml'
  values = dict(theme='~/a b' + chr(34) + 'quoted.lua', plugin_dirs=['~/one', '~/two'], pace=800, pager_init='~/new.lua')
  source.write_text(''.join(key + ' = ' + json.dumps(value) + chr(10) for key, value in values.items()))
  copy = m.ref_config(source, exported)
  del values['pager_init']
  assert tomllib.loads(copy.read_text()) == values, copy.read_text()
  assert m.ref_config(exported / 'none.toml', exported) is None
print('ok')"
  [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "benchmarks/compare reports a ref against the working tree and records nothing" {
  before=$(cksum "$ROOT/benchmarks/history.tsv" "$ROOT/SYNTAX.md")
  run --separate-stderr "$ROOT/benchmarks/compare" HEAD --rounds 1 --sample small --mode viewport
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [[ ${lines[0]} == '| Sample | Mode | HEAD (ms) | Tree (ms) |'* ]]
  [[ ${lines[2]} == '| small | viewport | '* ]]
  [ "$(cksum "$ROOT/benchmarks/history.tsv" "$ROOT/SYNTAX.md")" = "$before" ]
  run "$ROOT/benchmarks/compare" no-such-ref-here
  [ "$status" -eq 2 ]
  [[ $output == *'no such ref: no-such-ref-here'* ]]
}

