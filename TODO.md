# Next Steps

The working prototype renders the reference Markdown documents with the user's Neovim appearance.
Preserve that behavior while improving portability and preview latency.

Reviewed: 2026-10-31

## Portability and repeatable validation

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

## CLI and fzf integration

- [x] **Large tables hang rendering: `nvcat SYNTAX.md` times out.** (p1) [bug] Two causes, both fixed for
  viewports: Neovim's `conceal_lines` hook (dropped from the Markdown highlights query in `profile.lua`) and
  render-markdown's debounce dropping the post-resize update (`config.debounce = 0`).
- [x] **Complete output of very large tables is still too slow.** (p1) [perf] Mitigated: two forced redraws
  removed and the grid pre-sized (2-3x faster), and output over `--budget` falls back to bat. The underlying
  cost is in Neovim (rows x injected trees); see the two items below.
- [ ] **Patch the Tree-sitter highlighter at runtime.** (p3) [perf] In `profile.lua`, wrap
  `TSHighlighter`'s per-line path (`for_each_highlight_state` from `on_range_impl`) with a row-indexed lookup
  of tree root ranges built once per `on_win`, so each line visits only intersecting trees. Would let
  `SYNTAX.md`-sized tables render instead of falling back. Fragile: private internals of a dev build, so
  feature-detect the fields, keep the unpatched path as fallback, and add a test that fails loudly when the
  internals change. Prefer the upstream fix if it lands.
- [ ] **File the Neovim issue.** (p2) [chore] Draft and `nvim --clean` repro in
  `docs/upstream/neovim-treesitter-injection-cost.md`. Needs `gh auth login`; search for duplicates first,
  then link the issue here and drop the workaround notes once fixed upstream.
- [x] **Non-numeric fzf size variables give a raw ValueError.** (p3) [bug] `int(os.environ["FZF_PREVIEW_COLUMNS"])`
  in `nvcat` main() prints `invalid literal for int()`; report which variable was bad instead.
- [x] **less shows Nerd Font icons as `<U+F0CA3>`.** (p1) [bug] less treats Private Use Area code points as
  non-printable; `page()` now sets `LESSUTFCHARDEF` for those ranges unless the user has one.
- [x] (p2) [feature] Add `--version` and keep its output consistent with the release tag.
- [ ] (p3) [docs] Provide a checked-in mixed-file fzf integration example with bat fallback and resize refresh.
- [x] (p2) [test] Verify Markdown aliases, uppercase extensions, symlinks, empty files, and renderer failures.
- [x] (p2) [bug] Review selection parsing for filenames containing literal pipes or display separators.
  nvcat parses no selection; fzf quotes `{}`. A leading `-` needed `--` in the README example, and grep
  matches are split on a tab instead of `:` (`tests/fzf.bats`).
- [ ] **nvcat-dispatch takes a file named `--print` as its flag.** (p3) [bug] `gen-dispatch` checks
  `$1 == --print` and accepts no `--`; have it skip a leading `--` and document `nvcat-dispatch -- {}`.
- [x] (p2) [docs] Clarify full-document versus viewport behavior and how scrolling interacts with each mode.
- [x] (p2) [feature] Define readable fallbacks for input, row, and timeout limits.
- [x] **`cat` sends only Markdown to nvcat.** (p2) [bug] The `cat` alias runs `~/.shell/scripts/bat-dynamic`,
  which hard-codes `*.md | *.markdown | *.mdown | *.mkd` and never consults `nvcat-dispatch`, so
  `cat justfile` (and every other filetypes.json entry, plus `.mdwn`/`.mkdn`) goes to bat as plain text even
  though `nvcat-dispatch --print justfile` answers `just`. Fix in bat-dynamic (dotbare): ask
  `nvcat-dispatch --print "$1"` and exec `nvcat --all --filetype "$ft"` on a match. Done in bat-dynamic
  (~/.shell, uncommitted).

## Replacing nvimpager

- [ ] **Remove the old nvimpager on or after 2026-11-07.** (p2) [chore] With the rename to nvcat (0.10.0)
  its aliases and scripts move to nvcat (`vimcat`/`vc`, `vimpage`, `vimtail`/`vt`, fzf-tab, lesspipe, tmux
  `viewer.sh`); nvimpager stays installed for a week as a fallback. Then delete `~/.config/nvimpager`, `~/.shell/deploy/recipes/nvimpager.sh` and the
  installed binary, and untrack them in dotbare.
- [ ] **Replace nvimpager uses and aliases with nvcat.** (p2) [chore] Depends on paging mode below.
  `~/.shell/aliases/nvimpager.sh` defines `nvimpager` (wrapper), `vimcat`/`vc`, `vimpage`, `vimtail`/`vt`
  (`vt.nvim-log`, `vt.syslog`, ...), `vc.syn FT`, and `vc.tmux-keys` (stdin with `ft=tmux`). Other callers:
  `~/.shell/scripts/{vim-fzf-preview.sh,bat-list-preview,grc-list}`, `~/.shell/scripts/tools/vim-preview/`,
  `~/.shell/zsh/{functions.zsh,plugin-configs/fzf-tab.zsh}`, `~/.shell/aliases/programs/hyperfine.sh`, and
  tmux (`conf.d/{patterns,tools}.conf`, `scripts/{viewer,nvim-layout}.sh`; `@pattern_nvimpager` pane
  detection must match the new command name). Then drop the deploy recipe
  (`~/.shell/deploy/recipes/nvimpager.sh`, `catalog.tsv`). Mapping: `-l/--language` -> `--filetype`,
  `-c` -> cat mode, `-p` -> paging mode. Gap: `-t/--tail` (follow a growing log) has no equivalent; decide
  whether nvcat gets a follow mode or `vimtail` stays on nvimpager.
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
- [ ] (p3) [perf] Separate warm-process results from fresh-process measurements and rendered-output cache hits.
- [x] (p2) [perf] Profile before optimizing; identify theme loading, parser loading, rendering, and RPC costs separately.
  `--timings`/`--timings-json`; findings in docs/PERFORMANCE.md.
- [ ] **Redraw once per Markdown frame.** (p2) [perf] render-markdown calls `on.render` three times per frame and
  each schedules a full `redraw` (`ready_callbacks` in `--timings`); redraw is 1.2 s of large.md's 2 s. Trace
  which events fire them, then notify once per token after the explicit update, keeping the tail and viewport
  tests green.
- [ ] **Injected-language loading is unattributed.** (p3) [perf] astro spends ~140 ms in `parse` loading the
  TypeScript and CSS parsers and queries; time `language.add`/query loads for injections as their own phase.
- [ ] **cuda query compilation.** (p3) [perf] `vim.treesitter.start` takes ~390 ms for cuda (inherited cpp/c
  queries) against ~130 ms total with `--syntax regex`. Consider a per-filetype `syntax` key in filetypes.json, or
  a trimmed query.
- [ ] (p3) [perf] Python imports take ~40 ms of the ~75 ms startup (argparse, tomllib); lazy-import config
  parsing and measure.
- [ ] (p3) [perf] Trial an optional persistent Neovim worker if startup dominates, with cancellation and cleanup tests.
- [ ] (p3) [perf] Add caching only if measurements justify it; include viewport, file content, theme, configuration, and parser versions.

## Rendering fidelity and larger documents

- [ ] (p3) [test] Compare all reference features at multiple widths, including footnotes, wiki links, HTML comments, and code labels.
- [ ] (p3) [test] Qualify transparent backgrounds, combining characters, emoji, and wide glyphs in more terminal/font combinations.
- [ ] (p3) [feature] Preserve additional underline attributes and assess terminal hyperlink support.
- [ ] (p3) [feature] Investigate complete-document export beyond one enlarged grid without duplicating or skipping virtual rows.
- [x] (p2) [docs] Define memory and parsing limits before claiming streaming or large-file support.
  README "Limits and fallback": no streaming, viewport time and memory by input size. Table-heavy input is
  not measured yet.

## Releases

- [x] **No version file.** (p2) [chore] The version exists only as tag `v0.1.0` and README text. Add a
  top-level `VERSION` (and have `--version` read it) so bumps have one source of truth.
- [x] **README states a stale version.** (p3) [docs] `README.md:8` says `0.6.0` / `v0.6.0` while `VERSION` is
  `0.7.0`. Point at `VERSION` and `nvcat --version` instead of repeating the number, so bumps cannot drift.

## Optional support for other filetypes

- [ ] **SYNTAX.md has no regeneration script.** (p3) [chore] The Neovim-vs-bat comparison in `SYNTAX.md`
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
- [ ] (p3) [perf] Compare startup, parsing time, and memory against the Markdown-only profile before enabling broader support.
- [x] **systemd entry is unreachable through dispatch.** (p3) [feature] bat's INI syntax claims `*.service`,
  `*.timer` and the other unit extensions, so `gen-dispatch` sends them to bat. Neovim's systemd syntax is
  more specific; set `"prefer_over_bat": true` on the entry in `filetypes.json` if it should win.
- [ ] **Rename the project now that it is not Markdown-only.** (p3) [chore] `nvcat` renders ~40 filetypes.
  Candidates: `nvcat` (short, "cat through Neovim"), `nvim-cat` (matches the `nvcat` repo name),
  `nvpreview`, `vimprint`, `screencat` (describes the grid capture). Renaming touches the executable,
  `nvcat-dispatch`, the `nvcat_ready` RPC event, the `_G.nvcat` Lua module, the temp-dir prefix,
  docs, and the PATH links; keep an `nvcat` symlink for one release.
- [ ] **Dispatch carries machine-specific paths.** (p3) [chore] `nvcat-dispatch` embeds bat's version and
  `--map-syntax`/home-directory globs from this machine's bat config; another machine must run
  `./gen-dispatch`, and `tests/dispatch.bats` fails until it does.
- [x] **Render tests depend on this machine's Neovim setup.** (p2) [test] `tests/render.bats` needs the
  personal parsers and theme; skip it with a clear message when `find_paths()` reports missing dependencies.
