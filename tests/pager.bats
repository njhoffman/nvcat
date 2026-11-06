#!/usr/bin/env bats
# The built-in Neovim pager (--pager nvim, the default): keys, resize, signals, stdin, the auto-mode probe,
# and selecting it or an external pager through --pager, NVCAT_PAGER, and the config file.

bats_require_minimum_version 1.5.0

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  NVCAT=$ROOT/nvcat
  HELPERS=$BATS_TEST_DIRNAME/helpers
  FIXTURES=$BATS_TEST_DIRNAME/fixtures
  unset NVIM FZF_PREVIEW_COLUMNS FZF_PREVIEW_LINES NVCAT_PAGER
  export NVCAT_CONFIG=$BATS_TEST_TMPDIR/config.toml
  DOCUMENT=$BATS_TEST_TMPDIR/pager.md
  { echo '# PAGER_TOP'; echo
    for i in $(seq 1 30); do echo "- item $i"; done
    echo; echo 'PAGER_MIDDLE'; echo
    for i in $(seq 31 60); do echo "- item $i"; done
    echo; echo 'PAGER_BOTTOM'; } > "$DOCUMENT"
}

session() {
  run timeout 60 python3 "$HELPERS/pager_session.py" "$@"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = ok ]
}

@test "renders without raw Markdown; G, gg, search, space and q work" {
  session keys "$DOCUMENT"
}

@test "a link whose URL has control bytes sends no escapes; clean links stay links" {
  doc=$BATS_TEST_TMPDIR/evil.md
  printf '%b\n\n' '[one](http://a.example/\e]0;PWNED\ab)' '[two](http://b.example/\aPWNED)' \
    '[three](http://c.example/\xc2\x9dPWNED)' \
    '[spaced](<http://sp.example/a b>) [accent](http://ac.example/caf\xc3\xa9)' \
    '[fine](http://ok.example/)' 'END_LINKS' > "$doc"
  session unsafe-links "$doc" --paging=always
  # A byte that is not UTF-8 has Neovim read the whole file as Latin-1, so it is a document of its own.
  printf '%b\n\n' '[four](http://d.example/\x9dPWNED)' '[fine](http://ok.example/)' 'END_LINKS' > "$doc"
  session unsafe-links "$doc" --paging=always
}

@test "with color off the nvim pager gives way to less, whose text has no color" {
  NO_COLOR=1 session no-color "$DOCUMENT" --paging=always
}

@test "--syntax regex reaches the pager: raw Markdown with Vim's syntax" {
  session regex "$DOCUMENT" --syntax regex
}

@test "a broken highlights query is shown as a notification and the file falls back to regex syntax" {
  broken=$BATS_TEST_TMPDIR/broken
  mkdir -p "$broken/queries/lua"
  echo '(no_such_node) @keyword' > "$broken/queries/lua/highlights.scm"
  { echo '-- PAGER_TOP'; for i in $(seq 1 40); do echo "local x$i = \"item $i\""; done; } > "$BATS_TEST_TMPDIR/pager.lua"
  NVCAT_PARSER_DIR=$broken session warning "$BATS_TEST_TMPDIR/pager.lua"
  # The same file through the renderer reports the regex engine, so the pager is not the only evidence.
  NVCAT_PARSER_DIR=$broken run --separate-stderr "$NVCAT" --paging=never --timings-json "$BATS_TEST_TMPDIR/pager.lua"
  [[ $stderr == *'"engine": "syntax"'* ]]
}

@test "--follow shows appended lines, pauses while scrolled up, resumes on G, and reloads a truncated file" {
  session follow "$DOCUMENT" --follow
}

@test "--follow keeps a non-Markdown file's highlighting when it reloads" {
  json=$BATS_TEST_TMPDIR/follow.json
  printf '["KEEP_COLOR", 1]\n' > "$json"
  session follow-colors "$json" --follow
}

@test "--follow refuses stdin, an external pager, a viewport and a pipe in one line" {
  run --separate-stderr "$NVCAT" --follow - < "$DOCUMENT"
  [ "$status" -eq 1 ] && [ "$stderr" = 'nvcat: --follow needs a file, not stdin' ]
  run --separate-stderr "$NVCAT" --follow --pager less "$DOCUMENT"
  [ "$status" -eq 1 ] && [ "$stderr" = 'nvcat: --follow needs the nvim pager (--pager nvim)' ]
  run --separate-stderr "$NVCAT" --follow --lines 5 "$DOCUMENT"
  [ "$status" -eq 1 ] && [[ $stderr == 'nvcat: --follow pages the whole file;'* ]]
  run --separate-stderr "$NVCAT" --follow "$DOCUMENT"
  [ "$status" -eq 1 ] && [ "$stderr" = 'nvcat: --follow needs a terminal on stdout' ]
}

@test "--follow pages a file over the 10 MiB render limit" {
  big=$BATS_TEST_TMPDIR/big.log
  { echo 'PAGER_TOP'; head -c $((11 * 1024 * 1024)) /dev/zero | tr '\0' 'x' | fold -w 100; echo; echo 'PAGER_BOTTOM'; } > "$big"
  run timeout 60 python3 "$HELPERS/pager_session.py" follow-open "$big" --follow
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a terminal resize redraws" {
  session resize "$DOCUMENT"
}

@test "SIGTERM while paging exits 130 and leaves no Neovim behind" {
  session term "$DOCUMENT"
}

@test "SIGHUP while paging leaves no Neovim behind" {
  session hup "$DOCUMENT"
}

@test "a document on stdin is paged with keys from the terminal" {
  STDIN_FILE=$DOCUMENT session keys -
}

@test "auto prints a document that fits the terminal instead of opening the pager" {
  run timeout 30 script -qec "stty rows 20 cols 80; '$NVCAT' '$FIXTURES/markdown/sample.md'; echo rc=\$?" /dev/null < /dev/null
  [[ $output == *Title* ]]
  [[ $output == *rc=0* ]]
  [[ $output != *$'\e[?1049h'* ]]  # Neovim's TUI switches to the alternate screen; printing does not.
}

@test "always opens the pager even for a short non-Markdown file, and q quits" {
  run timeout 30 bash -c "{ sleep 2; printf q; } | script -qec \"stty rows 20 cols 80; '$NVCAT' --paging=always '$FIXTURES/kdl/config.kdl'; echo rc=\\\$?\" /dev/null"
  [[ $output == *$'\e[?1049h'* ]]
  [[ $output == *package* ]]
  [[ $output == *rc=0* ]]
}

@test "always without a terminal prints the complete document" {
  run --separate-stderr "$NVCAT" --columns 80 --paging=always "$DOCUMENT"
  [ "$status" -eq 0 ]
  [[ $output == *PAGER_BOTTOM* ]]
}

@test "the pager never modifies the source file" {
  before=$(stat -c '%Y %s' "$DOCUMENT"; sha256sum < "$DOCUMENT")
  session keys "$DOCUMENT"
  after=$(stat -c '%Y %s' "$DOCUMENT"; sha256sum < "$DOCUMENT")
  [ "$before" = "$after" ]
}

pager_command() {
  # An external pager that marks its output on stdout (Landlock lets it write only in the run directory).
  echo "sh -c 'echo ==PAGED==; cat'"
}

externally_paged() { [ "${lines[0]}" = ==PAGED== ] && [[ $output == *PAGER_BOTTOM* ]]; }

@test "--pager with a command line uses that external pager" {
  run "$NVCAT" --columns 80 --paging=always --pager "$(pager_command)" "$DOCUMENT"
  externally_paged
}

@test "NVCAT_PAGER selects an external pager" {
  NVCAT_PAGER=$(pager_command) run "$NVCAT" --columns 80 --paging=always "$DOCUMENT"
  externally_paged
}

@test "the config file's pager key selects an external pager" {
  printf "pager = \"%s\"\n" "$(pager_command | sed 's/"/\\"/g')" > "$NVCAT_CONFIG"
  run "$NVCAT" --columns 80 --paging=always "$DOCUMENT"
  externally_paged
}

@test "--pager nvim overrides an external NVCAT_PAGER" {
  # The keys scenario only passes in the Neovim pager.
  NVCAT_PAGER=$(pager_command) session keys "$DOCUMENT"
}

@test "--pager less runs less -R" {
  mkdir "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "==PAGED== $*"\ncat\n' > "$BATS_TEST_TMPDIR/bin/less"
  chmod +x "$BATS_TEST_TMPDIR/bin/less"
  PATH=$BATS_TEST_TMPDIR/bin:$PATH run "$NVCAT" --columns 80 --paging=always --pager less "$DOCUMENT"
  [ "${lines[0]}" = '==PAGED== -R' ]
  [[ $output == *PAGER_BOTTOM* ]]
}

@test "--check reports the pager and its source" {
  run "$NVCAT" --check
  [[ $output == *'pager            nvim  [default]'* ]]
  NVCAT_PAGER=less run "$NVCAT" --check
  [[ $output == *'pager            less  [NVCAT_PAGER]'* ]]
}

@test "pager_init runs after the pager's keys, so its mappings win, and its modules come from lua_path" {
  mkdir -p "$BATS_TEST_TMPDIR/lua"
  printf 'return { target = "G" }\n' > "$BATS_TEST_TMPDIR/lua/init_module.lua"
  cat > "$BATS_TEST_TMPDIR/init.lua" <<'LUA'
return { apply = function()
  vim.keymap.set("n", "f", require("init_module").target, { buffer = true, nowait = true })
end }
LUA
  NVCAT_LUA_PATH=$BATS_TEST_TMPDIR/lua NVCAT_PAGER_INIT=$BATS_TEST_TMPDIR/init.lua session init-key "$DOCUMENT" --paging=always
}

@test "a pager_init that fails still opens the document, with one line saying why" {
  printf 'return { apply = function() error("BROKEN_INIT\\nsecond line") end }\n' > "$BATS_TEST_TMPDIR/init.lua"
  NVCAT_PAGER_INIT=$BATS_TEST_TMPDIR/init.lua session init-broken "$DOCUMENT" --paging=always
  printf 'this is not Lua (\n' > "$BATS_TEST_TMPDIR/init.lua"
  NVCAT_PAGER_INIT=$BATS_TEST_TMPDIR/init.lua session init-broken-syntax "$DOCUMENT" --paging=always
}

@test "with the example pager_init the pager's keys still work" {
  NVCAT_PAGER_INIT=$ROOT/examples/pager-init.lua session keys "$DOCUMENT" --paging=always
}

@test "pager_init does not run for printed output or for less" {
  printf 'io.stderr:write("INIT_RAN"); return { apply = function() error("INIT_RAN") end }\n' > "$BATS_TEST_TMPDIR/init.lua"
  NVCAT_PAGER_INIT=$BATS_TEST_TMPDIR/init.lua run --separate-stderr "$NVCAT" --paging=never --columns 80 "$DOCUMENT"
  [ "$status" -eq 0 ]
  [[ $stderr != *INIT_RAN* ]]
  [[ $output != *INIT_RAN* ]]
}

