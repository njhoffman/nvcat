# Next Steps

nvcat renders Markdown and about 400 other filetypes with the user's Neovim appearance, as cat, pager and fzf
preview. Preserve that output while cutting preview latency and keeping it portable to other machines.

Reviewed: 2026-11-03

## CLI and fzf integration

- [x] **Large tables hang rendering: `nvcat SYNTAX.md` times out.** (p1) [bug] Two causes, both fixed for
  viewports: Neovim's `conceal_lines` hook (dropped from the Markdown highlights query in `profile.lua`) and
  render-markdown's debounce dropping the post-resize update (`config.debounce = 0`).
- [x] **Complete output of very large tables is still too slow.** (p1) [perf] Mitigated: two forced redraws
  removed and the grid pre-sized (2-3x faster), and output over `--budget` falls back to bat. The underlying
  cost is in Neovim (rows x injected trees); see the two items below.
- [x] **Patch the Tree-sitter highlighter at runtime.** (p3) [perf] In `profile.lua`, wrap
  `TSHighlighter`'s per-line path (`for_each_highlight_state` from `on_range_impl`) with a row-indexed lookup
  of tree root ranges built once per `on_win`, so each line visits only intersecting trees. Would let
  `SYNTAX.md`-sized tables render instead of falling back. Fragile: private internals of a dev build, so
  feature-detect the fields, keep the unpatched path as fallback, and add a test that fails loudly when the
  internals change. Prefer the upstream fix if it lands.
- [x] **File the Neovim issue.** (p2) [chore] Filed 2026-11-03 as
  https://github.com/neovim/neovim/issues/42675 (the redraw path; the `conceal_lines` half is already #39699).
  Text and scripts in `docs/upstream/neovim-treesitter-injection-cost.md`.
- [ ] **Drop `index_highlighter` once Neovim fixes #42675.** (p3) [chore] Keep it off for the fixed versions
  (`tests/highlighter.bats` expects `on` for 0.12+) and drop the workaround notes.
- [x] **Non-numeric fzf size variables give a raw ValueError.** (p3) [bug] `int(os.environ["FZF_PREVIEW_COLUMNS"])`
  in `nvcat` main() prints `invalid literal for int()`; report which variable was bad instead.
- [x] **less shows Nerd Font icons as `<U+F0CA3>`.** (p1) [bug] less treats Private Use Area code points as
  non-printable; `page()` now sets `LESSUTFCHARDEF` for those ranges unless the user has one.
- [x] (p2) [feature] Add `--version` and keep its output consistent with the release tag.
- [x] (p3) [docs] Provide a checked-in mixed-file fzf integration example with bat fallback and resize refresh.
  `examples/fzf-files`.
- [x] (p2) [test] Verify Markdown aliases, uppercase extensions, symlinks, empty files, and renderer failures.
- [x] (p2) [bug] Review selection parsing for filenames containing literal pipes or display separators.
  nvcat parses no selection; fzf quotes `{}`. A leading `-` needed `--` in the README example, and grep
  matches are split on a tab instead of `:` (`tests/fzf.bats`).
- [x] **nvcat-dispatch takes a file named `--print` as its flag.** (p3) [bug] `gen-dispatch` checks
  `$1 == --print` and accepts no `--`; have it skip a leading `--` and document `nvcat-dispatch -- {}`.
- [x] (p2) [docs] Clarify full-document versus viewport behavior and how scrolling interacts with each mode.
- [x] (p2) [feature] Define readable fallbacks for input, row, and timeout limits.
- [x] **`cat` sends only Markdown to nvcat.** (p2) [bug] The `cat` alias runs `~/.shell/scripts/bat-dynamic`,
  which hard-codes `*.md | *.markdown | *.mdown | *.mkd` and never consults `nvcat-dispatch`, so
  `cat justfile` (and every other filetypes.json entry, plus `.mdwn`/`.mkdn`) goes to bat as plain text even
  though `nvcat-dispatch --print justfile` answers `just`. Fix in bat-dynamic (dotbare): ask
  `nvcat-dispatch --print "$1"` and exec `nvcat --all --filetype "$ft"` on a match. Done in bat-dynamic
  (~/.shell 0.50.0; `--` before the file since 0.62.1).
- [x] **Filetype from modelines.** (p2) [feature] `notes.txt` ending in `# vim: ft=markdown` goes to bat:
  `profile.lua` sets `modeline=false` (a modeline can set any option) and `vim.filetype.match` ignores
  modelines. Parse `vim:`/`vi:`/`ex:` modelines for `ft`/`filetype` (else `syn`/`syntax`) ourselves, in both
  `nvcat-dispatch` and `filetypes.detect()`, passing only the filetype. Done in 0.17.0: first and last line,
  the modeline beats the name and bat's claims, `syn=` when there is no `ft=`, and a filetype nvcat does not
  render is ignored. The router reads files under 512 lines with `mapfile` (a `tail` fork cost 2-3 ms).
  0.18.0: "does not render" became "Neovim cannot highlight", after `fzfrc`'s `# vim:syn=bash:ft=` went to
  bat as plain text (bash is bat's, not one of nvcat's filetypes).
- [x] **examples/fzf-files without a generated router.** (p3) [bug] Since 0.16.0 a checkout has no
  `nvcat-dispatch` until `just install` or `just dispatch`; the example then shows a "No such file" error
  in every preview. Check for it at start and print the command to run (or run `./gen-dispatch`).
  Done in 0.23.0: it says what to run and exits 1 before fzf starts.
- [x] **`--lines 1` always times out.** (p2) [bug] Neovim's smallest grid is two rows ('lines' minimum 2), so
  `wait_ready` waits for a one-row frame that never comes and the render falls back to bat after `--timeout`
  (any file; also in 0.18.0). A one-line fzf preview window hits it. Attach and resize with at least two rows
  and emit the requested count, with a test for `--lines 1`.
  Done in 0.21.1: the grid has at least two rows (`MIN_GRID_ROWS`) and one is emitted.
- [x] **A Markdown link can inject terminal escapes.** (p1) [bug] Since 0.21.0 `ansi()` writes the `url` from
  Neovim's highlight into the OSC 8 sequence unfiltered, and the URL comes from the document. A link such as
  `[x](http://a/<ESC>]0;PWNED<BEL>b)` reaches the terminal with its control bytes intact, so previewing an
  untrusted file can set the window title or send any other sequence, and BEL or `ESC \` ends the OSC early.
  Reproduced 2026-11-03. Omit the hyperlink for a URL with C0, DEL or C1 bytes, whatever `--hyperlinks` says,
  and test ESC, BEL and ST in inline links and autolinks.
  Done in 0.21.1: such a link stays plain text (`CONTROL_BYTES`, `tests/attributes.bats`), and
  `filter_link_urls` in `profile.lua` drops those URLs in the `nvim` pager (`tests/pager.bats`).
- [x] **A Neovim that dies at start can exit 0 with no output.** (p2) [bug] A request written to a Neovim that had
  exited raised `BrokenPipeError`, and so did `process.stdin.close()` in `_close()`; the top-level handler took it for a
  closed stdout and exited 0. About 1 run in 10 with a stub that exits at once (6 of 60, 2026-11-03), so a blank
  preview with no bat fallback, and `tests/dependencies.bats` flaked.
  Done in 0.21.2: both report "Neovim exited before completing the preview" with its stderr (60 of 60).
- [x] **`PYTHONSAFEPATH` breaks nvcat.** (p2) [bug] `PYTHONSAFEPATH=1` removes the script's directory from `sys.path`, so
  every run ended in `ModuleNotFoundError`, `--version` included (0.18 too, through `import config`).
  Done in 0.21.2: the entry point adds the directory of its real path. `gen-dispatch` and `gen-filetypes` still
  need it unset.
- [x] **`auto` hyperlinks are off when no pager runs.** (p3) [bug] `hyperlinks()` checks only the configured
  pager, so `NVCAT_PAGER=more` drops links from piped output, `--lines` viewports and fzf previews too. Use
  `wants_pager()`, which already knows these cases.
  Done in 0.23.0: `hyperlinks()` asks `wants_pager()`.
- [x] **OSC 8 URLs are not normalized.** (p3) [bug] The OSC 8 convention limits a URI to bytes 32-126, but
  non-ASCII URLs go out raw, bidi controls such as U+202E included. `[t](<http://c/a b>)` keeps its angle brackets
  and space, so the link is wrong. Strip the brackets and percent-encode the rest.
  Done in 0.23.0: `link_target()` strips the brackets and percent-encodes the rest; `filter_link_urls` does the same
  in the `nvim` pager.
- [x] **A wrapped link is several links.** (p3) [feature] A link wrapping over rows gets a separate OSC 8 pair on
  each row, so terminals underline and hover only one part. Add an `id=` per link, per the OSC 8 convention.
  Done in 0.23.0: one `id=` per URI. In the `nvim` pager Neovim writes its own `id`.
- [x] **Verify the README's hyperlink support claims.** (p3) [docs] "fzf previews (0.54 and later)" and the list
  of terminals came from memory, not a test; only less 668 was checked. Add OSC 8 to `tests/fzf.bats` or
  reword.
  Done in 0.23.0: fzf's changelog says 0.55, not 0.54; `tests/fzf.bats` checks OSC 8 with an id through fzf 0.74. The README no
  longer names terminals, since none was tested, and gives less 668 as tested instead of "566 and later".
- [ ] **Run the fish completion test.** (p3) [test] `nvcat completions fish` (0.23.0) has never been loaded in fish: it
  was not installed where it was written, so `tests/completions.bats` skips it. Run that test where fish is installed.
- [ ] **Install completions with `just install`.** (p3) [feature] `nvcat completions SHELL` only prints a script; each
  user wires it up by hand. Consider a `just completions` that writes it to the shell's standard directory.
- [x] **requirements.txt still says `make deps`.** (p3) [docs] It is `just deps` since 0.13.0.
- [x] **Output shown through bat can carry a file's terminal escapes.** (p2) [bug] Neovim's grid makes them harmless, but
  bat passes them on: a file with `ESC]0;...BEL` reaches stdout unchanged through `nvcat-dispatch` for a filetype nvcat
  does not handle, and through the fallback over the size limit (reproduced 2026-11-03, bat 0.26.1). The exposure is
  that of plain `cat` or `bat`, but previewing untrusted files is what nvcat is for. `bat --strip-ansi=always` removes
  them there; add it to `fallback_bat()` and `gen-dispatch`, check bat's minimum version for the flag, and test both.
  Done in 0.24.0: bat's flag only acts with color or decorations on and leaves BEL and C1, so nvcat also filters: in Python in
  the fallback, with `sed` in the router. Older bats lose the flag in the router, with a warning from `gen-dispatch`.
- [x] **Error messages print file names raw.** (p2) [bug] `nvcat: {argument}: no such file` and the broken-link message
  write control bytes from a name (or a link's target) to stderr, so a crafted name in a directory sends escapes when it
  fails to open (both reproduced 2026-11-03). Escape control characters where errors are printed, including what
  Neovim wrote to stderr.
  Done in 0.24.0: `SafeStderr` wraps `sys.stderr`, which covers argparse and tracebacks as well. The router filters bat's stderr.
- [x] **No way to turn color off.** (p2) [feature] `nvcat file | grep x` and `nvcat file > out` carry SGR codes, and
  `NO_COLOR` is ignored, unlike bat and most cat-like tools. Add `--color auto|always|never` and honor `NO_COLOR`. `auto`
  has to keep color in fzf previews, whose stdout is a pipe, and `nvcat-dispatch` has to keep working.
  Done in 0.24.0: default stays always, by decision, so previewers that read a pipe keep working; `auto` is opt-in.
- [ ] **Decide which link schemes are clickable.** (p3) [feature] `[text](file:///etc/passwd)`, `javascript:` and `ssh://`
  all become hyperlinks, and rendering hides the target behind the text. Consider allowing only http, https and mailto by
  default, with a setting for more. A trade-off, not a clear bug: terminals differ in what they open and whether they ask.
- [x] **Sourcing the zsh completion before compinit prints an error.** (p3) [bug] `source <(nvcat completions zsh)` without
  compinit says `command not found: compdef`. The README says to load it after compinit, but the script can check for
  `compdef` and stay quiet, as generated scripts usually do.
- [ ] **stdin ignores modelines.** (p3) [feature] `printf '# vim: ft=lua\n...' | nvcat -` renders Markdown, because stdin is
  always Markdown and only named files read modelines. Read the modeline from the saved stdin too; `--filetype` remains the
  way to override it.
- [ ] **The generated router has unreachable patterns.** (p3) [chore] `shellcheck` gives 32 warnings on `nvcat-dispatch`,
  among them `*/*_log` after `*_log` (line 66), which can never match. `gen-dispatch` could drop globs a previous pattern
  of the same `case` covers, for a shorter script and a clean lint.

## Performance

- [x] **Track Markdown benchmark averages.** (p2) [perf] `benchmarks/run` records small/medium/large/code samples
  in `benchmarks/history.tsv` and updates the SYNTAX.md table; run it after every change.
- [x] **Benchmark render time per filetype.** (p2) [perf] Time every `filetypes.json` entry with hyperfine (fixture
  plus a larger realistic file each): Tree-sitter vs regex syntax, `--all` vs a viewport, against bat on the
  same file, and the dispatch overhead. Rough one-off timings on 2026-10-31 at 80 columns: most filetypes
  100-350 ms, markdown about 530 ms, astro about 710 ms, cuda about 950 ms (likely parser or injection
  loading). Record results in a doc and add a check that flags regressions. Also: a plain 5,000-line list
  takes over 8 s at the 4,096-row grid even without tables. (0.8.0: that was a stall, not slowness; Neovim
  clamps the grid to 1,000 rows and nvcat waited for a taller frame.)
  Done: `benchmarks/filetypes` (`--check` flags regressions), results in docs/PERFORMANCE.md.
- [x] **Startup cost about 10-15 ms more than in 0.7.0.** (p3) [perf] Not the Tree-sitter guards (loading
  `vim.treesitter` costs about 2.5 ms and render-markdown loads it anyway) but the 0.8.0 row-limit check's
  `nvim_get_option_value("lines")` round trips after attaching and after each resize: 102.7 against 95.2 ms
  median on the kdl fixture (12 interleaved runs, load 1.5). Removed in 0.10.1.
- [ ] **grid_scroll copies the whole grid.** (p3) [perf] `Renderer.event` deep-copies every row on each
  `grid_scroll`, O(rows x columns) per scroll; at 1,000 rows this adds up. Copy only the scrolled region.
- [x] (p2) [perf] Measure startup, first usable fzf content, total render time, and peak memory on representative documents.
  `benchmarks/run` records an fzf mode, startup and peak RSS of Neovim and Python.
- [x] (p2) [perf] Profile before optimizing; identify theme loading, parser loading, rendering, and RPC costs separately.
  `--timings`/`--timings-json`; findings in docs/PERFORMANCE.md.
- [x] **Redraw once per Markdown frame.** (p2) [perf] render-markdown calls `on.render` three times per frame and
  each schedules a full `redraw` (`ready_callbacks` in `--timings`, still 3). With the highlighter index
  (0.15.0) redraw is 214 ms and render-markdown 246 ms of large.md's 672 ms (2026-11-03), down from 1.2 s of
  2 s. Trace which events fire them, then notify once per token after the explicit update, keeping the tail
  and viewport tests green.
  Done differently (0.26.0): the trace showed the later redraws take 0.1 ms; the waste was a forced update running
  every handler twice, so that update is no longer forced (`render_passes` 1). See docs/PERFORMANCE.md.
- [ ] **Injected-language loading is unattributed.** (p3) [perf] astro spends ~140 ms in `parse` loading the
  TypeScript and CSS parsers and queries; time `language.add`/query loads for injections as their own phase.
- [ ] **cuda query compilation.** (p3) [perf] `vim.treesitter.start` takes ~245 ms of cuda's ~300 ms (inherited
  cpp/c queries; 2026-11-03, was ~390 ms) against ~130 ms total with `--syntax regex`. Consider a per-filetype `syntax` key in filetypes.json, or
  a trimmed query.
- [x] **Cut Python's fixed startup.** (p3) [perf] Python compiles the 1,010-line `nvcat` script on every run
  (7 ms; a script gets no `.pyc`), and imports take ~20-24 ms (argparse, tomllib for the config). Move the
  code into a module that the `nvcat` entry point imports, so it is cached, and consider skipping tomllib when
  no config file exists. Worth about 5-10 ms per fzf preview, a quarter of the 16-23 ms nvcat costs a small file
  over the Markdown-only v0.1.0.
  Done in 0.20.0: `nvcat_cli.py` plus a 6-line entry point (7-9 ms less per start), tomllib only with a
  config file.
- [x] **benchmarks/run records noisy runs.** (p3) [perf] Its gate is the 1-minute load average (at most 0.6 per
  CPU), which a burst from another process slips under: on 2026-11-03 two runs had to be reverted by hand
  (startup 84-124 ms against 35-45 ms). Keep the threshold, and also refuse to record a run whose startup
  median is far above the recent history, or interleave the samples so a burst spreads across all of them.
  Done in 0.19.0: both. Round-robin rounds, and exit 3 without recording when the load ends above the gate
  or startup is over 1.5x its median of the last five runs (`--record-noisy` overrides).
- [ ] (p3) [perf] Trial an optional persistent Neovim worker if startup dominates, with cancellation and cleanup tests.
  `benchmarks/run` then records warm-worker results as their own mode, apart from fresh starts.
- [ ] (p3) [perf] Add caching only if measurements justify it; include viewport, file content, theme, configuration, and parser versions.
  `benchmarks/run` then records cache hits as their own mode, apart from renders.
- [x] **`benchmarks/run` cannot tell a load timeout from a failure.** (p3) [chore] Waiting out `--max-wait` exits 1,
  like a failed render, while `benchmarks/highlighter` exits 2 for the same case. Exit 2 here too. On
  2026-11-03 other processes held the load at 8-23 for the whole 15 minutes.
- [ ] **Add a `benchmarks/compare REF` for busy machines.** (p3) [perf] `benchmarks/run` refused three runs in a row on
  2026-11-03, and 0.22.0 and 0.23.0 have no history rows. Twice the check became a hand-written script timing two trees in
  alternation, which load affects equally. Make that a tool: a ref against the working tree, per sample and mode, with
  enough rounds to tell noise from change (9 rounds showed +14% on a row that 24 showed as -7%). It reports only, and does
  not replace recorded runs.
- [x] **The benchmark's `vs average` mixes every version.** (p3) [chore] `benchmarks/run` averages all earlier rows in
  `benchmarks/history.tsv`, including versions from before the large speedups and runs at load 4. On 2026-11-06 large/complete
  showed -56% against that average, but only -5% against the previous best (848 ms). Added `Recent` and `vs recent` columns (median of the
  last 5) beside the average, which stays.

## Rendering fidelity and larger documents

- [x] (p3) [test] Compare all reference features at multiple widths, including footnotes, wiki links, HTML comments, and code labels.
  Done in 0.21.0: `tests/reference.bats` at 40, 80 and 120 columns with render-markdown's defaults, plus
  no line wider than the output. It found the cursor row shown as raw Markdown under render-markdown's
  default anti-conceal (fixed). Code labels past a `code.min_width` wider than the output are cut off, as
  in Neovim.
- [ ] (p3) [test] Qualify transparent backgrounds, combining characters, emoji, and wide glyphs in more terminal/font combinations.
  0.21.0 tests the output cells (`tests/reference.bats`: one emission per wide glyph, combining marks on
  their base, a wide glyph wrapping whole, `49` for the default background). Left: looking at the output in
  each terminal and font, which needs a person; record the combinations in the README.
- [x] (p3) [feature] Preserve additional underline attributes and assess terminal hyperlink support.
  Done in 0.21.0: underline styles as `4:2`-`4:5` with `58:2::R:G:B` colors, and OSC 8 links from the
  `url` Neovim attaches to Markdown links (`--hyperlinks auto|always|never`). less 668 passes both through.
- [ ] (p3) [feature] Investigate complete-document export beyond one enlarged grid without duplicating or skipping virtual rows.
- [x] (p2) [docs] Define memory and parsing limits before claiming streaming or large-file support.
  README "Limits and fallback": no streaming, viewport time and memory by input size. Table-heavy input is
  measured by `benchmarks/highlighter` (a 600-row table, 0.15.0).
- [ ] **The routing speed tests fail under load.** (p3) [test] `tests/dispatch.bats` holds "routing is fast" to an
  absolute 20 ms average and "routing a file nvcat does not handle stays fast" to 30 ms. On 2026-11-03 the first
  failed at load 17, and both at load 20+ (the first passed alone at 4.7). Compare with a baseline measured in
  the same test, such as a `bash -c :` start, or use a looser limit.
- [ ] **"Neovim left running" can blame an unrelated nvcat.** (p3) [test] `embedded_nvims()` matches every embedded
  Neovim using this checkout's `profile.lua` on the machine, and the installed `nvcat` links to this checkout, so a
  render from another shell during a test probably explains the one failure of `--syntax regex reaches the
  pager` on 2026-11-03 (5 of 5 passed alone). Track only descendants of the test's own nvcat.
- [ ] **fzf sometimes does not exit in `tests/fzf.bats`.** (p3) [test] Once on 2026-11-03, fzf had not exited 10 s after
  ESC at the end of the session test, at load 3 (`TimeoutExpired` in `fzf_session.py`); every rendering check before
  it passed. It then passed 6 of 6, as did 0.21.0. Cause unknown: find out whether a preview ignores cancellation.
- [x] **Run `tests/nvim-versions` for 0.19.0-0.21.x.** (p2) [test] `docs/RELEASING.md` requires it for each release;
  it did not run for these, and its `DEFAULT_TESTS` lacked `attributes` and `reference`.
  Done in 0.21.2: both added; v0.11.7 190 of 190 and v0.12.6 191 of 191 ok, 1 skipped each.
- [ ] **The suite runs only on a configured machine.** (p3) [test] There is no CI, and most test files use the
  developer's `config.toml`, theme and render-markdown options; a default-options bug hid behind that until
  0.21.0. Run the suite with an empty config (as `reference.bats` does for options), then add a CI job with
  pinned Neovim and plugins.

## Filetype support

- [x] **SYNTAX.md has no regeneration script.** (p3) [chore] The Neovim-vs-bat comparison in `SYNTAX.md`
  was produced by an ad hoc Lua/Python scan plus hand review of extension collisions. `./gen-filetypes` now
  regenerates the generated regex-filetypes table and carries the collision overrides (`NOT_COVERED`); the
  two pool sections ("treesitter filetypes not in bat", "regex syntax filetypes not in bat") are still
  hand-made. Extend gen-filetypes to write them too.
- [x] **Content-detected regex filetypes are not routed.** (p3) [feature] About 45 regex-syntax filetypes
  bat lacks reach Neovim only through detection functions (`.w` cweb/progress, `.e` eiffel/specman, `.bas`,
  `.csh`, `.def`, `*.inc`, ...), so `gen-filetypes` skips them. Option: generated entries with a `detect`
  flag that dispatch hands to nvcat without `--filetype`, letting Neovim choose by content (needs a "no
  filetype found -> bat" path instead of the Markdown default).
- [x] **nvcat without --filetype ignores bat's claims.** (p3) [bug] `nvcat go.sum` renders as the generated
  `hercules` (and `nvcat nginx.conf` as `conf`) while `nvcat-dispatch` sends both to bat; `filetypes.detect`
  does not know bat's patterns. Have gen-dispatch emit the claimed globs into a JSON file nvcat checks, or
  document nvcat-dispatch as the bat-aware entry point.
- [x] **Generated globs can hit binary formats.** (p3) [chore] Neovim maps `*.mo` (gettext catalogs), `*.bc`
  (LLVM bitcode) and `*.pdb` statically; the NUL check sends these to bat, but costs an nvcat start first.
  Consider a SKIP list in gen-filetypes for known binary extensions.
- [x] (p3) [feature] Evaluate whether Neovim-specific source rendering adds value beyond the current bat integration.
- [x] (p3) [feature] If needed, add filetype detection or `--filetype`, on-demand parsers, and a general render-ready signal.
- [x] (p3) [perf] Compare startup, parsing time, and memory against the Markdown-only profile before enabling broader support.
  Done 2026-11-03 against v0.1.0 ([PERFORMANCE.md](docs/PERFORMANCE.md#against-the-markdown-only-release)):
  16-23 ms more fixed startup, all Python (script compilation, tomllib); same memory; 2-4x faster on
  larger documents.
- [x] **systemd entry is unreachable through dispatch.** (p3) [feature] bat's INI syntax claims `*.service`,
  `*.timer` and the other unit extensions, so `gen-dispatch` sends them to bat. Neovim's systemd syntax is
  more specific; set `"prefer_over_bat": true` on the entry in `filetypes.json` if it should win.
- [x] **Rename the project now that it is not Markdown-only.** (p3) [chore] Done in 0.10.0 (mdpreview to
  nvcat, repository `njhoffman/nvcat`, no compatibility aliases). `nvcat` renders ~40 filetypes.
  Candidates: `nvcat` (short, "cat through Neovim"), `nvim-cat` (matches the `nvcat` repo name),
  `nvpreview`, `vimprint`, `screencat` (describes the grid capture). Renaming touches the executable,
  `nvcat-dispatch`, the `nvcat_ready` RPC event, the `_G.nvcat` Lua module, the temp-dir prefix,
  docs, and the PATH links; keep an `nvcat` symlink for one release.
- [x] **Dispatch carries machine-specific paths.** (p3) [chore] `nvcat-dispatch` embeds bat's version and
  `--map-syntax`/home-directory globs from this machine's bat config; another machine must run
  `./gen-dispatch`, and `tests/dispatch.bats` fails until it does. Done in 0.16.0: neither file is tracked,
  `just install` generates them, the suite generates its own, and `nvcat --check` warns when stale.
- [ ] **filetypes.regex.json and SYNTAX.md are generated from this machine.** (p3) [chore] `./gen-filetypes`
  derives them from the local Neovim, its syntax files and parsers, and bat, and `tests/dispatch.bats` checks
  they are current, so another machine fails that test. Unlike the router they are worth committing (they are
  the documented coverage); consider skipping the check unless Neovim and bat match the versions recorded in
  the file.
  Seen on 2026-11-03: installing a parser made the "generated sections are current" test fail on a clean commit until the
  counts in SYNTAX.md were regenerated, so the test depends on the machine and not only on the change under test.
- [x] **Render tests depend on this machine's Neovim setup.** (p2) [test] `tests/render.bats` needs the
  personal parsers and theme; skip it with a clear message when `find_paths()` reports missing dependencies.

## Completed

### Portability and repeatable validation (completed 2026-10-31)

- [x] (p1) [refactor] Replace hardcoded editor, theme, plugin, and parser paths with explicit configuration and sensible defaults.
- [x] (p2) [feature] Provide a sample appearance profile so another user can run the tool without this personal Neovim setup.
- [x] (p1) [chore] Declare runtime and development dependencies; provide a reproducible installation method.
- [x] (p1) [test] Turn the historical harnesses into tests that resolve paths from the checkout and use temporary output directories.
- [x] (p2) [test] Add self-contained fixtures for Markdown structures, all supported code languages, aliases, Unicode, and long lines.
- [x] (p2) [test] Retain checks for complete-document tails, stdin, unusual filenames, modelines, cancellation, and source immutability.
- [x] (p2) [test] Exercise parser/query mismatches and missing dependencies with actionable errors.
- [x] (p2) [test] Test released Neovim versions and declare the supported minimum.
  0.11 (`tests/nvim-versions`); 0.10 cannot load current ABI-15 parsers and is refused in one line.
- [x] **`--check` with any other option demands a file.** (p3) [bug] Only a bare `--check` (and `--check --all`)
  bypasses argparse's required `file`, so `nvcat --check --nvim X` fails with a usage error.
- [x] **Landlock allows writes to all of /tmp.** (p3) [refactor] `readonly.py` grants full write rights on
  `/tmp` rather than only the per-run `nvcat-*` directory; scope the rule to that directory.
- [x] (p2) [docs] Document the Linux/Landlock requirement and remove experiment-only helper entrypoints.

### Replacing nvimpager (completed 2026-11-03)

- [x] **Remove the old nvimpager on or after 2026-11-07.** (p2) [chore] Done 2026-11-03, early on request:
  binary, man page, runtime, state, source checkout, `~/.config/nvimpager` (untracked in dotbare), the deploy
  recipe and the remaining references (~/.shell 0.62.2, tmux 0.27.1). With the rename to nvcat (0.10.0)
  its aliases and scripts move to nvcat (`vimcat`/`vc`, `vimpage`, `vimtail`/`vt`, fzf-tab, lesspipe, tmux
  `viewer.sh`); nvimpager stays installed for a week as a fallback. Then delete `~/.config/nvimpager`, `~/.shell/deploy/recipes/nvimpager.sh` and the
  installed binary, and untrack them in dotbare.
- [x] **Replace nvimpager uses and aliases with nvcat.** (p2) [chore] Depends on paging mode below.
  `~/.shell/aliases/nvimpager.sh` defines `nvimpager` (wrapper), `vimcat`/`vc`, `vimpage`, `vimtail`/`vt`
  (`vt.nvim-log`, `vt.syslog`, ...), `vc.syn FT`, and `vc.tmux-keys` (stdin with `ft=tmux`). Other callers:
  `~/.shell/scripts/{vim-fzf-preview.sh,bat-list-preview,grc-list}`, `~/.shell/scripts/tools/vim-preview/`,
  `~/.shell/zsh/{functions.zsh,plugin-configs/fzf-tab.zsh}`, `~/.shell/aliases/programs/hyperfine.sh`, and
  tmux (`conf.d/{patterns,tools}.conf`, `scripts/{viewer,nvim-layout}.sh`; `@pattern_nvimpager` pane
  detection must match the new command name). Then drop the deploy recipe
  (`~/.shell/deploy/recipes/nvimpager.sh`, `catalog.tsv`). Mapping: `-l/--language` -> `--filetype`,
  `-c` -> cat mode, `-p` -> paging mode. Gap: `-t/--tail` (follow a growing log) has no equivalent; decide
  whether nvcat gets a follow mode or `vimtail` stays on nvimpager. Done in ~/.shell 0.33.0 (aliases in `aliases/nvcat.sh`, `vimtail` on
  `nvcat -f`); only the deploy recipe and commented hyperfine examples still name nvimpager, for the removal
  item above.
- [x] **Add a paging mode through less.** (p2) [feature] Render the complete document (as `--all` does) and pipe
  it into `${NVCAT_PAGER:-less -R}`; respect `$LESS`, and keep wide glyphs and RGB sequences intact.
  Output over the row limit (1,000 since 0.8.0) should fall back to a clear error rather than a truncated page.
- [x] **Embedded Neovim pager.** (p3) [feature] Done in 0.6.0 as the default `--pager nvim`: Neovim runs on the
  terminal with the same profile (no RPC attach needed), read-only, with live render-markdown, search,
  re-wrap on resize, and less-style keys; `--pager less` or `pager = "less"` keeps less.
- [x] **Follow mode in the Neovim pager.** (p3) [feature] A tail/follow mode (`:checktime` on a timer, keep the
  view at the end) to replace `vimtail`; see the nvimpager item above. Done: `-f`/`--follow` (inotify plus a
  1 s poll). Not done: following with `--pager less`, which only ever receives finished output.
- [x] **The Neovim pager relies on render-markdown internals for its first frame.** (p3) [refactor]
  `profile.lua` calls `require("render-markdown.core.ui").updater.new(...):run()` so the first frame is
  rendered; `update()` defers through `vim.schedule` and shows raw text once. Falls back to `update()` if the
  internal changes; ask upstream for a synchronous render API.
- [x] **Pager query warnings are untested.** (p3) [test] `M.pager` in `profile.lua` shows Tree-sitter query
  warnings with `vim.notify`, but `tests/pager.bats` never breaks a query. Add a case with a broken
  `queries/lua/highlights.scm` under `NVCAT_PARSER_DIR` and assert the notification and the regex fallback.
- [x] **Auto paging by default.** (p2) [feature] Decided: `--paging=auto|always|never` (matching bat), default
  `auto`: page with less when stdout is a terminal and the render is taller than the screen, otherwise cat.
  Treat `$FZF_PREVIEW_COLUMNS`/`LINES` and a `$NVIM` parent (Neovim terminal buffers, where Telescope's
  previewer gives the command a real TTY) as cat. `nvcat-dispatch` keeps forcing cat output.

### Releases (completed 2026-10-31)

- [x] **No version file.** (p2) [chore] The version exists only as tag `v0.1.0` and README text. Add a
  top-level `VERSION` (and have `--version` read it) so bumps have one source of truth.
- [x] **README states a stale version.** (p3) [docs] `README.md:8` says `0.6.0` / `v0.6.0` while `VERSION` is
  `0.7.0`. Point at `VERSION` and `nvcat --version` instead of repeating the number, so bumps cannot drift.
