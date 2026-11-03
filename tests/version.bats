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

@test "the nvcat command is a thin entry point whose code Python caches as bytecode" {
  [ "$(grep -cv '^\s*$' "$ROOT/nvcat")" -le 6 ]
  grep -q '^from nvcat_cli import command$' "$ROOT/nvcat"
  # A run through the entry point leaves nvcat_cli's bytecode in __pycache__ (unless writing it is off).
  [ -n "${PYTHONDONTWRITEBYTECODE-}" ] && skip "PYTHONDONTWRITEBYTECODE is set"
  rm -f "$ROOT"/__pycache__/nvcat_cli.*.pyc
  "$ROOT/nvcat" --version >/dev/null
  compgen -G "$ROOT/__pycache__/nvcat_cli.*.pyc" >/dev/null
}
