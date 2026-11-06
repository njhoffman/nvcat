# Runs once before the test files. nvcat-dispatch and filetypes.bat.json are generated per machine from bat
# and not tracked, so build them from this checkout's tables and this machine's bat for the tests that run
# the router or read bat's claims (dispatch, fzf, inputs, render, benchmarks).
setup_suite() {
  # CI has no terminal type, and without one less and Neovim's TUI do not behave as they do for a person.
  if [ -z "${TERM:-}" ] || [ "$TERM" = dumb ]; then
    export TERM=xterm-256color
  fi
  # Tags this suite's Neovims, which inherit it, so tests/helpers/common.py ignores other shells' renders.
  export NVCAT_TEST_SESSION="suite-$$-$RANDOM"
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gen-dispatch" >/dev/null 2>&1 || {
    echo "setup_suite: ./gen-dispatch failed" >&2
    return 1
  }
}
