#!/usr/bin/env bats
# Routing in the generated nvcat-dispatch, and its agreement with filetypes.py.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  DISPATCH=$ROOT/nvcat-dispatch
  FIXTURES=$BATS_TEST_DIRNAME/fixtures
  STUBS=$BATS_TEST_TMPDIR/stubs
  mkdir -p "$STUBS"
  printf '#!/bin/sh\necho "nvcat $*"\n' > "$STUBS/nvcat-ok"
  printf '#!/bin/sh\necho partial; echo boom >&2; exit 1\n' > "$STUBS/nvcat-fail"
  printf '#!/bin/sh\necho "bat $*"\n' > "$STUBS/bat"
  chmod +x "$STUBS"/*
}

route() {
  run "$DISPATCH" --print "$1"
}

@test "generated script is current with filetypes.json and bat" {
  run diff <("$ROOT/gen-dispatch" --output - --claims -) "$DISPATCH"
  [ "$status" -eq 0 ]
}

@test "filetypes.bat.json is current with bat" {
  "$ROOT/gen-dispatch" --output "$BATS_TEST_TMPDIR/dispatch" --claims "$BATS_TEST_TMPDIR/claims.json" 2>/dev/null
  run diff "$BATS_TEST_TMPDIR/claims.json" "$ROOT/filetypes.bat.json"
  [ "$status" -eq 0 ]
}

@test "every filetype entry has a fixture that routes to it" {
  missing=$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import filetypes
print(" ".join(e["filetype"] for e in filetypes.load()))' "$ROOT")
  for filetype in $missing; do
    [ -d "$FIXTURES/$filetype" ] || { echo "no fixture directory for $filetype"; return 1; }
  done
}

@test "fixtures route to the filetype named by their directory" {
  while IFS= read -r file; do
    expected=${file#"$FIXTURES"/}
    expected=${expected%%/*}
    case $expected in bat | reference) continue ;; esac  # reference/: Markdown documents, not a filetype
    case $file in */plain.html | */nochart/* | */Chart.yaml) continue ;; esac
    route "$file"
    [ "$status" -eq 0 ] || { echo "$file: not routed"; return 1; }
    [ "$output" = "$expected" ] || { echo "$file: got $output, expected $expected"; return 1; }
  done < <(find "$FIXTURES" -type f | sort)
}

@test "Markdown extensions match case-insensitively" {
  cp "$FIXTURES/markdown/sample.md" "$BATS_TEST_TMPDIR/UPPER.MD"
  route "$BATS_TEST_TMPDIR/UPPER.MD"
  [ "$output" = markdown ]
}

@test "relative paths match path globs" {
  cd "$FIXTURES/kitty"
  route kitty/kitty.conf
  [ "$output" = kitty ]
  cd "$FIXTURES/helm/chart"
  route templates/deployment.yaml
  [ "$output" = helm ]
}

@test "helm needs Chart.yaml above templates/" {
  route "$FIXTURES/helm/nochart/templates/plain.yaml"
  [ "$status" -eq 1 ]
}

@test "html without Django tags goes to bat" {
  route "$FIXTURES/htmldjango/plain.html"
  [ "$status" -eq 1 ]
}

@test "names bat claims go to bat even when a glob matches" {
  route "$FIXTURES/bat/nginx/nginx.conf"
  [ "$status" -eq 1 ]
}

@test "prefer_over_bat entries win over bat's patterns" {
  route "$FIXTURES/systemd/app.service"
  [ "$output" = systemd ]
  route "$FIXTURES/markdown/sample.md"
  [ "$output" = markdown ]
}

@test "languages bat has go to bat" {
  route "$FIXTURES/bat/script.py"
  [ "$status" -eq 1 ]
}

@test "missing files and directories go to bat" {
  route "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 1 ]
  mkdir "$BATS_TEST_TMPDIR/dir.md"
  route "$BATS_TEST_TMPDIR/dir.md"
  [ "$status" -eq 1 ]
}

@test "filenames with spaces and leading dashes" {
  cp "$FIXTURES/markdown/sample.md" "$BATS_TEST_TMPDIR/-a b.md"
  NVCAT=$STUBS/nvcat-ok BAT=$STUBS/bat run "$DISPATCH" "$BATS_TEST_TMPDIR/-a b.md"
  [ "$output" = "nvcat --all --paging=never --budget=2 --filetype markdown -- $BATS_TEST_TMPDIR/-a b.md" ]
}

@test "routed files call nvcat with the filetype" {
  NVCAT=$STUBS/nvcat-ok BAT=$STUBS/bat run "$DISPATCH" "$FIXTURES/tmux/.tmux.conf"
  [ "$status" -eq 0 ]
  [ "$output" = "nvcat --all --paging=never --budget=2 --filetype tmux -- $FIXTURES/tmux/.tmux.conf" ]
}

@test "other files go to bat" {
  NVCAT=$STUBS/nvcat-ok BAT=$STUBS/bat run "$DISPATCH" "$FIXTURES/bat/script.py"
  [ "$output" = "bat --color=always --paging=never -- $FIXTURES/bat/script.py" ]
}

@test "nvcat failure falls back to bat and hides nvcat stderr" {
  NVCAT=$STUBS/nvcat-fail BAT=$STUBS/bat run --separate-stderr "$DISPATCH" "$FIXTURES/kdl/config.kdl"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "bat --color=always --paging=never -- $FIXTURES/kdl/config.kdl" ]
  [ -z "$stderr" ]
}

@test "missing nvcat falls back to bat" {
  NVCAT=$BATS_TEST_TMPDIR/none BAT=$STUBS/bat run "$DISPATCH" "$FIXTURES/kdl/config.kdl"
  [ "$output" = "bat --color=always --paging=never -- $FIXTURES/kdl/config.kdl" ]
}

@test "usage errors" {
  run "$DISPATCH"
  [ "$status" -eq 2 ]
  run "$DISPATCH" a b
  [ "$status" -eq 2 ]
}

@test "filetypes.py agrees with the script on every routed fixture" {
  while IFS= read -r file; do
    route "$file"
    [ "$status" -eq 0 ] || continue
    expected=$output
    actual=$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import filetypes
entry = filetypes.detect(sys.argv[2]); print(entry["filetype"] if entry else "")' "$ROOT" "$file")
    [ "$actual" = "$expected" ] || { echo "$file: python $actual, bash $expected"; return 1; }
  done < <(find "$FIXTURES" -type f | sort)
}

@test "routing is fast" {
  start=$(date +%s%N)
  for _ in 1 2 3 4 5 6 7 8 9 10; do "$DISPATCH" --print "$FIXTURES/conf/app.conf" >/dev/null; done
  elapsed=$(( ($(date +%s%N) - start) / 10000000 ))
  echo "average ${elapsed}ms"
  [ "$elapsed" -lt 20 ]
}

@test "filetypes.regex.json and SYNTAX.md's generated sections are current with Neovim and bat" {
  cp "$ROOT/SYNTAX.md" "$BATS_TEST_TMPDIR/SYNTAX.md"
  run diff <("$ROOT/gen-filetypes" --syntax "$BATS_TEST_TMPDIR/SYNTAX.md" --output - 2>/dev/null) "$ROOT/filetypes.regex.json"
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/SYNTAX.md" "$ROOT/SYNTAX.md"
  [ "$status" -eq 0 ]
}

@test "SYNTAX.md's pool sections place parsers and syntaxes by bat coverage" {
  pools=$(sed -n '/<!-- pools:start -->/,/<!-- pools:end -->/p' "$ROOT/SYNTAX.md")
  # nvim-treesitter's filetype names and bat's differently named syntaxes count as coverage.
  for covered in c_sharp tsx objc vimdoc; do
    ! grep -q "^| \`$covered\` |" <<<"$pools" || { echo "$covered listed"; return 1; }
  done
  # Hand-reviewed extension collisions do not.
  for listed in fsh v liquid; do
    grep -q "^| \`$listed\` |" <<<"$pools" || { echo "$listed missing"; return 1; }
  done
  # Globs from detection functions and from filetypes.json are listed.
  grep -q '^| `cdrtoc` | `.toc` |' <<<"$pools"
  grep -q '^| `sxhkdrc` | sxhkdrc | `\*.sxhkdrc`, `sxhkdrc` |' <<<"$pools"
}

@test "generated filetypes come after filetypes.json and before its last entries" {
  route "$FIXTURES/sysctl/etc/sysctl.d/10-net.conf"
  [ "$output" = sysctl ]
  route "$FIXTURES/conf/app.conf"
  [ "$output" = conf ]
  cp "$FIXTURES/sed/strip.sed" "$BATS_TEST_TMPDIR/STRIP.SED"
  route "$BATS_TEST_TMPDIR/STRIP.SED"
  [ "$output" = sed ]
}

@test "generated file names and paths win over generated extensions" {
  mkdir -p "$BATS_TEST_TMPDIR/etc"
  printf 'x\n' > "$BATS_TEST_TMPDIR/etc/slp.spi"
  printf 'x\n' > "$BATS_TEST_TMPDIR/page.spi"
  route "$BATS_TEST_TMPDIR/etc/slp.spi"
  [ "$output" = slpspi ]
  route "$BATS_TEST_TMPDIR/page.spi"
  [ "$output" = spyce ]
}

@test "bat keeps the globs it claims even when Neovim maps them to a generated filetype" {
  printf 'module x\n' > "$BATS_TEST_TMPDIR/go.sum"
  route "$BATS_TEST_TMPDIR/go.sum"
  [ "$status" -eq 1 ]
}

@test "filetypes.py's indexed detect agrees with fnmatch on every glob" {
  run python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import filetypes
from fnmatch import fnmatchcase
entries = filetypes.ordered()
claimed = [glob.lower() for entry in filetypes.claims() for glob in entry["paths"]]
def slow(path):
  folded = path.lower()
  if any(fnmatchcase(folded, glob) for glob in claimed):
    return None
  for entry in entries:
    if any(fnmatchcase(folded, glob.lower()) for glob in filetypes.globs(entry)) and filetypes.requirement_met(entry, path):
      return entry
paths = [filetypes.sample(glob) for entry in entries for glob in filetypes.globs(entry)]
paths += ["/a/plain.txt", "/a/b.swift.gyb", "/a/Makefile", "/a/.config/kitty/x.conf", "/a/y.conf"]
bad = [path for path in paths if filetypes.detect(path) is not slow(path)]
print(len(paths), bad[:5])
sys.exit(1 if bad else 0)' "$ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "routing a file nvcat does not handle stays fast" {
  start=$(date +%s%N)
  for _ in 1 2 3 4 5 6 7 8 9 10; do "$DISPATCH" --print "$FIXTURES/bat/script.py" >/dev/null || true; done
  elapsed=$(( ($(date +%s%N) - start) / 10000000 ))
  echo "average ${elapsed}ms"
  [ "$elapsed" -lt 30 ]
}

@test "content-detected globs route to auto" {
  # Pins globs found by gen-filetypes' scan of Neovim's detection functions, which a Neovim change could break.
  for name in report.w x.e x.bas x.csh .cshrc termcap xorg.conf x.y; do
    printf 'x\n' > "$BATS_TEST_TMPDIR/$name"
    route "$BATS_TEST_TMPDIR/$name"
    [ "$output" = auto ] || { echo "$name: $output"; return 1; }
  done
}

@test "auto globs leave bat's claims and filetypes.json's globs alone" {
  printf 'module x\n' > "$BATS_TEST_TMPDIR/go.mod"
  route "$BATS_TEST_TMPDIR/go.mod"
  [ "$status" -eq 1 ]
  printf '# x\n' > "$BATS_TEST_TMPDIR/notes.mkdn"
  route "$BATS_TEST_TMPDIR/notes.mkdn"
  [ "$output" = markdown ]
}

@test "auto files call nvcat with --filetype auto" {
  run env NVCAT="$STUBS/nvcat-ok" BAT="$STUBS/bat" "$DISPATCH" "$FIXTURES/auto/report.w"
  [ "$output" = "nvcat --all --paging=never --budget=2 --filetype auto -- $FIXTURES/auto/report.w" ]
}

@test "binary formats Neovim maps to a regex filetype go to bat" {
  for name in x.mo x.bc x.pdb x.class; do
    printf 'x\n' > "$BATS_TEST_TMPDIR/$name"
    route "$BATS_TEST_TMPDIR/$name"
    [ "$status" -eq 1 ] || { echo "$name: $output"; return 1; }
  done
}
