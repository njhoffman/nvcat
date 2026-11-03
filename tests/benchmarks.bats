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
  recorded() { cat "$ROOT/benchmarks/filetypes.tsv" "$ROOT/docs/PERFORMANCE.md" 2>/dev/null || true; }
  before=$(recorded)
  run --separate-stderr "$ROOT/benchmarks/filetypes" --only kdl --quick --check --max-load 1000
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
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
  before=$(sha1sum <"$ROOT/docs/PERFORMANCE.md")
  run --separate-stderr "$ROOT/benchmarks/highlighter" --runs 1 --max-load 1000 "$ROOT/tests/fixtures/markdown/sample.md"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [[ $output == '<!-- highlighter:start -->'* && $output == *'<!-- highlighter:end -->' ]]
  grep -qE '^\| sample\.md \| [0-9]+ \| [0-9,]+ \| [0-9]+ / [0-9]+ \|' <<<"$output"
  [ "$(sha1sum <"$ROOT/docs/PERFORMANCE.md")" = "$before" ]
}
