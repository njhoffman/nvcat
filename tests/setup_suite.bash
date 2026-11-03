# Runs once before the test files. nvcat-dispatch and filetypes.bat.json are generated per machine from bat
# and not tracked, so build them from this checkout's tables and this machine's bat for the tests that run
# the router or read bat's claims (dispatch, fzf, inputs, render, benchmarks).
setup_suite() {
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gen-dispatch" >/dev/null 2>&1 || {
    echo "setup_suite: ./gen-dispatch failed" >&2
    return 1
  }
}
