#!/usr/bin/env bats
# --version agrees with VERSION, and a tagged checkout agrees with its tag.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  VERSION=$(<"$ROOT/VERSION")
}

@test "VERSION holds one semantic version" {
  [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "--version prints the VERSION file without needing a file argument" {
  run --separate-stderr "$NVCAT" --version
  [ "$status" -eq 0 ]
  [ "$output" = "nvcat $VERSION" ]
}

@test "-v is --version" {
  run --separate-stderr "$NVCAT" -v
  [ "$status" -eq 0 ]
  [ "$output" = "nvcat $VERSION" ]
}

@test "--check reports the same version" {
  run "$NVCAT" --check
  [[ $output == *"nvcat        $VERSION"* ]]
}

@test "a tagged HEAD carries the tag of VERSION" {
  tags=$(git -C "$ROOT" tag --points-at HEAD 'v*' 2>/dev/null) || skip "not a git checkout"
  [ -n "$tags" ] || skip "HEAD is not tagged"
  # Uncommitted changes may be the next release in progress; the tag check applies to the tagged state.
  git -C "$ROOT" diff --quiet HEAD -- VERSION || skip "VERSION changed since the tag"
  grep -qx "v$VERSION" <<<"$tags"
}

@test "the newest CHANGELOG release is VERSION" {
  newest=$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ROOT/CHANGELOG.md" | tr -d '#[] ')
  [ "$newest" = "$VERSION" ]
}

@test "--help describes the command and not its code" {
  run "$ROOT/nvcat" --help
  [ "$status" -eq 0 ]
  [[ $output == 'usage: nvcat '* ]]
  [[ $output != *__pycache__* && $output != *bytecode* && $output != *'command()'* ]]
  [[ $output == *'nvcat completions bash|zsh|fish'* ]]
}

@test "--help has color with --color always or on a terminal, none in a pipe or with NO_COLOR" {
  unset NO_COLOR NVCAT_COLOR
  export NVCAT_CONFIG=$BATS_TEST_TMPDIR/none.toml
  run "$ROOT/nvcat" --help
  [[ $output != *$'\e'* ]]
  plain=$output
  for flags in '--color=always --help' '--help --color always'; do
    # shellcheck disable=SC2086
    run "$ROOT/nvcat" $flags
    [ "$status" -eq 0 ]
    [[ $output == *$'\e[1;33moptions:\e[0m'* ]]
    [[ $output == *$'\e[1;33musage:\e[0m nvcat'* ]]
    [[ $output == *$'  \e[36m--paging\e[0m \e[32m{auto,always,never}\e[0m'* ]]
    [[ $output == *$'  \e[36m-h,\e[0m \e[36m--help\e[0m'* ]]
    # Only color was added: the layout is argparse's.
    [ "$(sed 's/\x1b\[[0-9;]*m//g' <<<"$output")" = "$plain" ]
  done
  run "$ROOT/nvcat" --color=never --help
  [[ $output != *$'\e'* ]]
  # On a terminal, unless NO_COLOR or a setting says otherwise.
  run python3 - "$BATS_TEST_DIRNAME/helpers" <<'EOF'
import os, sys
sys.path.insert(0, sys.argv[1])
from common import load_nvcat
nvcat = load_nvcat()
sys.argv = ["nvcat", "--help"]
sys.stdout.isatty = lambda: True
results = [nvcat.help_color()]
os.environ["NO_COLOR"] = "1"
results.append(nvcat.help_color())
sys.argv = ["nvcat", "--help", "--color=always"]
results.append(nvcat.help_color())
sys.argv = ["nvcat", "--help", "--color=sometimes"]
results.append(nvcat.help_color())
sys.stdout.write(" ".join(map(str, results)))
EOF
  [ "$output" = "True False True False" ]
}

@test "nvcat starts with PYTHONSAFEPATH set, directly and through a symbolic link" {
  run env PYTHONSAFEPATH=1 "$ROOT/nvcat" --version
  [ "$status" -eq 0 ]
  [ "$output" = "nvcat $(cat "$ROOT/VERSION")" ]
  ln -s "$ROOT/nvcat" "$BATS_TEST_TMPDIR/linked"
  run env PYTHONSAFEPATH=1 "$BATS_TEST_TMPDIR/linked" --version
  [ "$status" -eq 0 ]
  [ "$output" = "nvcat $(cat "$ROOT/VERSION")" ]
  # Past --version: the modules nvcat_cli imports load, and a render runs.
  printf '# Safe\n' > "$BATS_TEST_TMPDIR/safe.md"
  run --separate-stderr env PYTHONSAFEPATH=1 "$ROOT/nvcat" --paging=never --columns 40 "$BATS_TEST_TMPDIR/safe.md"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [[ $output == *Safe* ]]
}

@test "the nvcat command is a thin entry point whose code Python caches as bytecode" {
  [ "$(grep -cv '^\s*$' "$ROOT/nvcat")" -le 9 ]
  grep -q '^from nvcat_cli import command' "$ROOT/nvcat"
  # A run through the entry point leaves nvcat_cli's bytecode in __pycache__ (unless writing it is off).
  [ -n "${PYTHONDONTWRITEBYTECODE-}" ] && skip "PYTHONDONTWRITEBYTECODE is set"
  rm -f "$ROOT"/__pycache__/nvcat_cli.*.pyc
  "$ROOT/nvcat" --version >/dev/null
  compgen -G "$ROOT/__pycache__/nvcat_cli.*.pyc" >/dev/null
}
