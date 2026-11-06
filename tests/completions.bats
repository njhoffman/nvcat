#!/usr/bin/env bats
# `nvcat completions SHELL`: each script loads in its shell and completes in it. fish is optional.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  PATH=$ROOT:$PATH
  HELPERS=$BATS_TEST_DIRNAME/helpers
  SCRIPT=$BATS_TEST_TMPDIR/script
}

# Runs bash's completion function for a command line, one COMPREPLY per line. The last word is completed.
bash_complete() {
  bash -c 'source "$1"; shift; COMP_WORDS=("$@"); COMP_CWORD=$((${#COMP_WORDS[@]} - 1)); _nvcat; printf "%s\n" "${COMPREPLY[@]}"' \
    _ "$SCRIPT" "$@"
}

@test "completions: a missing or unknown shell is a usage error" {
  cd "$BATS_TEST_TMPDIR"
  run "$NVCAT" completions
  [ "$status" -eq 2 ]
  [[ $output == *'completions needs one shell: bash, zsh, fish'* ]]
  run "$NVCAT" completions tcsh
  [ "$status" -eq 2 ]
  [[ $output == *'completions needs one shell'* ]]
}

@test "completions: a file named completions still opens, except with a shell after it" {
  cd "$BATS_TEST_TMPDIR"
  printf 'FILE_NAMED_COMPLETIONS\n' > completions
  run --separate-stderr "$NVCAT" --paging=never --filetype text --columns 40 completions
  [ "$status" -eq 0 ]
  [[ $output == *FILE_NAMED_COMPLETIONS* ]]
  run "$NVCAT" completions bash
  [ "$status" -eq 0 ]
  [[ $output == *'complete -F _nvcat nvcat'* ]]
}

@test "completions: every script lists every option of the parser" {
  flags=$("$NVCAT" --help | grep -oE '(^|[ \[])--?[a-z][a-z-]*' | tr -d ' [' | sort -u)
  [[ $flags == *--hyperlinks* && $flags == *--timings-json* ]]
  for shell in bash zsh fish; do
    "$NVCAT" completions "$shell" > "$SCRIPT"
    for flag in $flags; do
      if [ "$shell" = fish ]; then
        case $flag in --*) pattern="-l ${flag#--}\b" ;; *) pattern="-s ${flag#-}\b" ;; esac
      else
        pattern="(^|[ ()'])$flag\b"
      fi
      grep -qE -- "$pattern" "$SCRIPT" || { echo "$shell lacks $flag"; return 1; }
    done
  done
}

@test "completions: the module is not imported by other commands" {
  run bash -c "python3 -X importtime '$NVCAT' --version 2>&1"
  [ "$status" -eq 0 ]
  [[ $output == *nvcat_cli* ]]
  [[ $output != *' completions'* ]]
}

@test "completions bash: options, values, the = form, shells and files" {
  "$NVCAT" completions bash > "$SCRIPT"
  bash -n "$SCRIPT"
  [ "$(bash_complete nvcat --pagi)" = --paging ]
  [ "$(bash_complete nvcat --paging al)" = always ]
  [ "$(bash_complete nvcat --paging = al)" = always ]
  [ "$(bash_complete nvcat --paging = | tr '\n' ' ')" = 'auto always never ' ]
  [ "$(bash_complete nvcat --hyperlinks ne)" = never ]
  [ "$(bash_complete nvcat --pager le)" = less ]
  [ "$(bash_complete nvcat completions z)" = zsh ]
  [ -z "$(bash_complete nvcat --columns '' | tr -d '\n')" ]
  [[ $(bash_complete nvcat --filetype markd) == *markdown* ]]
  [[ $(bash_complete nvcat --filetype au) == *auto* ]]
  cd "$BATS_TEST_TMPDIR"
  touch 'with space.md'
  [ "$(bash_complete nvcat comp)" = completions ]
  [ "$(bash_complete nvcat with)" = 'with space.md' ]
  bash_complete nvcat -- | grep -q -- --timings-json
}

@test "completions zsh: Tab in a real zsh completes options, values, shells and filetypes" {
  command -v zsh >/dev/null || skip "zsh not installed"
  "$NVCAT" completions zsh > "$SCRIPT"
  zsh -n "$SCRIPT"
  run timeout 60 python3 "$HELPERS/zsh_complete.py" "$SCRIPT" 'nvcat --pagi' 'nvcat --paging=al' 'nvcat completions z' \
    'nvcat --filetype markdow' 'nvcat --hyperlinks ne'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  echo "$output"
  [[ ${lines[0]} == 'nvcat --paging'* ]]
  [[ ${lines[1]} == 'nvcat --paging=always'* ]]
  [[ ${lines[2]} == 'nvcat completions zsh'* ]]
  [[ ${lines[3]} == 'nvcat --filetype markdown'* ]]
  [[ ${lines[4]} == 'nvcat --hyperlinks never'* ]]
}

@test "completions zsh: sourcing it before compinit is quiet" {
  command -v zsh >/dev/null || skip "zsh not installed"
  "$NVCAT" completions zsh > "$SCRIPT"
  run --separate-stderr zsh -f -c "source '$SCRIPT'; print -r -- sourced"
  [ "$status" -eq 0 ]
  [ "$output" = sourced ]
  [ -z "$stderr" ]
}

@test "just completions writes a current script where each shell looks, and can run again" {
  command -v just >/dev/null || skip "just is not installed"
  home=$BATS_TEST_TMPDIR/home
  mkdir -p "$home"
  for _ in 1 2; do
    run env -u XDG_DATA_HOME -u XDG_CONFIG_HOME HOME="$home" just --justfile "$ROOT/justfile" completions
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  done
  "$NVCAT" completions bash | diff - "$home/.local/share/bash-completion/completions/nvcat"
  if command -v zsh >/dev/null; then
    # A home with no zshrc has nothing of its own on fpath, so it is told what to add.
    "$NVCAT" completions zsh | diff - "$home/.local/share/zsh/site-functions/_nvcat"
    [[ $output == *"fpath=($home/.local/share/zsh/site-functions"* ]]
    # A zshrc that adds a directory of the user's gets the script there, with nothing to add.
    mkdir -p "$home/zfunc"
    printf 'fpath=(%s $fpath)\n' "$home/zfunc" > "$home/.zshrc"
    run env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u ZDOTDIR HOME="$home" just --justfile "$ROOT/justfile" completions
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    "$NVCAT" completions zsh | diff - "$home/zfunc/_nvcat"
    [[ $output != *'add to ~/.zshrc'* ]]
  fi
  if command -v fish >/dev/null; then
    "$NVCAT" completions fish | diff - "$home/.config/fish/completions/nvcat.fish"
  fi
}

@test "completions fish: complete -C offers options, values, shells and filetypes" {
  command -v fish >/dev/null || skip "fish not installed"
  "$NVCAT" completions fish > "$SCRIPT"
  fish --no-execute "$SCRIPT"
  ask() { fish --no-config -c 'source $argv[1]; complete -C $argv[2]' "$SCRIPT" "$1" | cut -f1; }
  [ "$(ask 'nvcat --pagi')" = --paging ]
  [[ $(ask 'nvcat --paging=al') == *always* ]]
  [ "$(ask 'nvcat --hyperlinks ne')" = never ]
  [ "$(ask 'nvcat completions z')" = zsh ]
  [[ $(ask 'nvcat --filetype markdow') == *markdown* ]]
  [[ $(ask 'nvcat comp') == *completions* ]]
  [[ $(ask 'nvcat -') == *--timings-json* ]]
}
