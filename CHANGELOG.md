# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses Semantic Versioning with
annotated `vMAJOR.MINOR.PATCH` Git tags.

## [Unreleased]

## [0.14.0] - 2026-11-03

### Added

- `examples/fzf-files [DIR]`: an fzf file picker with the mixed nvcat/bat preview, resize refresh and a
  `ctrl-/` preview toggle, tested in `tests/fzf.bats`.

### Fixed

- `nvcat-dispatch` accepts `--` before the file (`nvcat-dispatch -- {}`, `nvcat-dispatch --print -- FILE`), so
  a file named `--print` is routed instead of read as the flag.

## [0.13.0] - 2026-11-03

### Added

- `./gen-filetypes` regenerates the rest of SYNTAX.md's coverage lists ("Neovim treesitter filetypes not in
  bat", "Neovim regex syntax filetypes not in bat" and the summary line) from nvcat's own Neovim, with the
  hand review kept as data (`NOT_COVERED`, `BAT_ALIASES`, nvim-treesitter's parser filetypes). They now
  describe what nvcat can load: syntaxes from plugins and the user's config are gone, parsers whose files
  only a plugin detects move to "Parsers with no file mapping", and the file lists include globs Neovim
  decides by content and those of filetypes.json. `--syntax PATH` writes to another copy of SYNTAX.md, and
  `tests/dispatch.bats` fails while the sections are stale.
- 10 more content-detected globs route to `nvcat --filetype auto` (85 in all): the scan of Neovim's
  detection functions now follows nested `detect.*` calls and the results passed as arguments, which adds
  `*.com`, `*.dcl`, `*.dsl`, `*.ms`, `*.pro`, `*.xpm`, `.tcshrc`, `tcsh.login`, `tcsh.tcshrc` and
  `indent.pro`. `README` and `*.map` are skipped: Neovim's content checks almost never give them an nvcat
  filetype.

### Changed

- A justfile replaces the Makefile, with the same recipe names (`just install`, `just test`, `just filetypes`,
  ...); `just` lists them, and `just test` and `just bench-filetypes` pass their arguments on.

## [0.12.0] - 2026-11-03

### Added

- `--filetype auto`: Neovim detects the filetype by content, and nvcat renders the file only when the result
  is one of its filetypes; anything else goes to bat without a notice (an error with `--fallback=none`).
- 75 globs Neovim assigns by content (`*.w` cweb or Progress, `*.e` Eiffel or Specman, `*.bas`, `*.csh`,
  `.cshrc`, `termcap`, `xorg.conf`, `*.y`, ...) now route to nvcat: `./gen-filetypes` scans Neovim's detection
  functions and writes them as `auto` entries, and `nvcat-dispatch --print` prints `auto` for them, so
  `bat-dynamic` and fzf previews pass `--filetype auto`. SYNTAX.md lists them with their possible filetypes.
- `nvcat --filetypes` has a fourth column, the content-detected globs that can give each filetype, and lists
  filetypes only content detection gives (such as `cweb`) after the others.

### Changed

- `./gen-dispatch` also writes `filetypes.bat.json`, bat's names and globs that a table entry would
  otherwise take.
- `./gen-filetypes` skips binary formats Neovim maps to a regex syntax (`*.mo`, `*.bc`, `*.pdb`, `*.class`),
  which leaves bat to show them.

### Fixed

- `nvcat FILE` without `--filetype` no longer applies a generated glob to a file bat claims: `go.sum` is
  Neovim's `gosum`, not `hercules`, and `go.mod` is no longer taken by the new `*.mod` glob.

## [0.11.0] - 2026-11-02

### Added

- 397 more filetypes: every filetype Neovim highlights with a regex syntax file that bat has no syntax for
  (`sed`, `sudoers`, `sysctl`, `screenrc`, `mailcap`, `expect`, Debian control files, linker scripts, ...),
  matched by the extensions, file names and paths Neovim's filetype registry gives them. They are generated
  into `filetypes.regex.json` by the new `./gen-filetypes` (also `make filetypes`), which updates their table
  in SYNTAX.md, and are checked after `filetypes.json` and before its catch-all `conf`. Globs bat claims stay
  with bat.
- `nvcat --filetypes` lists every filetype nvcat matches by name, in match order, as `filetype`, table
  (`filetypes.json` or `regex`) and globs, tab-separated.

### Changed

- `nvcat-dispatch` checks the generated filetypes in a second stage that bash parses only for files the
  first stage does not match, so Markdown and `filetypes.json` files route as fast as before; other files
  take about 5 ms longer.
- Detection by file name in nvcat indexes the globs once and loads the generated table only when
  `filetypes.json` has no match.

### Fixed

- Binary input (a NUL byte in the first 8 KiB) falls back to bat, which prints a notice, instead of being
  rendered as raw control bytes.

## [0.10.1] - 2026-10-31

### Fixed

- Every render is about 6 ms faster: the row-limit check added in 0.8.0 asked Neovim for its `lines` after
  attaching and after each resize, a round trip while Neovim was still drawing. The limit (1,000 rows, Neovim's
  own) is now checked without asking; a Neovim with a lower cap still falls back to bat, through `--timeout`,
  with the row-limit notice.

## [0.10.0] - 2026-10-31

### Added

- Without a file argument nvcat reads stdin when it is not a terminal, like cat and bat
  (`... | nvcat -c --filetype yaml`); on a terminal that is a usage error. `--check` no longer needs a file
  when given other options, and `--check --all` works in any order.

### Changed

- Renamed from mdpreview to nvcat, with no compatibility aliases: the commands are `nvcat` and
  `nvcat-dispatch`, environment variables are `NVCAT_*` (for example `NVCAT_PAGER`, `NVCAT_CONFIG`,
  `NVCAT_PARSER_DIR`), the config file is `~/.config/nvcat/config.toml`, run directories are `/tmp/nvcat-*`,
  and `tests/nvim-versions` caches Neovim in `~/.cache/nvcat/nvim`. Move an existing
  `~/.config/mdpreview/config.toml` to `~/.config/nvcat/` and rerun `make install`. The GitHub repository is
  now `njhoffman/nvcat`; the old URL redirects.

## [0.9.0] - 2026-10-31

### Added

- `-f`/`--follow`: the Neovim pager opens at the end of the file and reloads it as it changes (inotify plus a
  one-second poll), staying at the end while the cursor is on the last line; `G` or `F` resumes following.
  Truncated or replaced files reload. Needs the nvim pager, a terminal and a file; no 10 MiB limit.

### Changed

- The write sandbox allows writes only in the per-run `/tmp/mdpreview-*` directory instead of all of `/tmp`.
  External pagers get that directory as `TMPDIR` and can write nowhere else (before, anywhere under `/tmp`). A child forked before the sandbox removes it when
  mdpreview exits, so a SIGKILL no longer leaves it behind; it first stops any of the run's Neovims still
  running (Neovim 0.12 does not exit when its run directory is removed under it).
- The Neovim pager draws its first screen rendered using only render-markdown's public API
  (`api.render()` and its `on.render` callback) instead of an internal updater.
- Neovim 0.11 is the supported minimum (tested with 0.11.7 and 0.12.6); an older Neovim is refused with one
  line instead of failing on its first parser. `tests/nvim-versions` runs the suite on released versions.
- `tests/render.bats` skips, naming the missing dependency, when `mdpreview --check` fails, and skips by name the
  filetypes with neither a parser nor a Vim syntax file on the machine.

### Fixed

- A parser file that fails to load (built for another Tree-sitter ABI, or corrupt) aborted the render with a
  Lua error. That language now gets regex syntax (Vim's markdown syntax for a Markdown parser, plain text in a
  code fence) and one warning naming the parser file.
- A Tree-sitter query warning in the Neovim pager stopped at "Press ENTER" before the document was shown; it
  is now one line on the command line naming the failed queries, with the details in `mdpreview --check`.

## [0.8.0] - 2026-10-31

### Added

- `-v` as a short form of `--version`, and `-c`/`--cat` for `--paging=never`.
- `--version` prints `mdpreview X.Y.Z` from the `VERSION` file; `--check` lists it with the other versions.
- `tests/version.bats`: `--version`, `VERSION`, the newest CHANGELOG release and a tagged HEAD agree.
- `--check` compiles the Tree-sitter highlights and injections queries of every `filetypes.json` language,
  reports failures as warnings and lists the languages shown with regex syntax; `--check --all` covers every
  installed parser (code fence languages; about 20 s with 300 parsers).
- `tests/dependencies.bats`: query mismatches, a missing or broken Neovim, a missing msgpack, Lua errors.
- `tests/inputs.bats`: every Markdown extension in lower, upper and mixed case, uppercase extensions of other
  filetypes, symbolic links and chains, unreadable inputs, empty files and stdin in each mode, and a Neovim
  killed mid-render.
- `tests/fzf.bats`: names with `|`, `:`, quotes, spaces, `$(...)`, glob characters and a leading `-` pass
  through fzf's `{}` to mdpreview and mdpreview-dispatch, and a tab-separated grep match jumps to its line.
- `docs/RELEASING.md`: one commit and tag per changelog version, and the full test suite before each release.
- README: memory and time limits by input size; mdpreview does not stream and is not meant for large files.

### Changed

- Every render limit now falls back to bat with a one-line notice naming the limit and the flag that changes
  it: input over 10 MiB (Neovim is not started; stdin is passed on in full) and a `--timeout` now join the
  4,096-row limit and `--budget`. A timeout falls back in viewports and fzf previews too, showing the same
  viewport of bat's output instead of an error. `--fallback=none` still turns each into an error.
- Fallback output for the `nvim` pager is paged with `less -R`.
- A Tree-sitter query that does not compile against its parser ("Invalid node type"), whether for the file's
  language, Markdown, or a language in a code fence, no longer aborts the render with a Lua stack trace. That
  language loses Tree-sitter highlighting (a whole file falls back to regex syntax) and one warning on stderr
  names the query file and what to update. The Neovim pager shows the warning as a notification.
- Errors from Neovim are reduced to their innermost message, without stack traces or autocommand chains.

### Fixed

- A `FZF_PREVIEW_COLUMNS` or `FZF_PREVIEW_LINES` that is not a whole number is a usage error naming the variable
  (exit 2) instead of a Python `ValueError` traceback; an empty value counts as unset.
- Complete output never finished for documents over 1,000 screen rows, or ones whose resize asked for more
  (from about 500 source lines up): Neovim clamps its grid to 1,000 rows and mdpreview waited for a taller
  frame until `--budget` or `--timeout` ran out, then blamed the budget. The row limit is now 1,000 (it was
  documented as 4,096, which could never be reached), output over it falls back to bat at once with the
  row-limit notice, and `--lines` accepts at most 1000.
- The README no longer repeats the version number, which had fallen behind.
- A failing bat during a fallback is reported with its exit status instead of a Python traceback, and a
  missing bat is named in the error.
- A timeout while Neovim was starting skipped the fallback.
- `--syntax regex` now applies to filetypes whose Neovim ftplugin starts Tree-sitter itself, such as Lua.
- A missing Python msgpack, and an `--nvim` or `nvim` setting that is not an executable, are reported in one
  line instead of a traceback or `[Errno 2]`.
- A symbolic link whose own name matches no `filetypes.json` entry is matched by its target's name, so an
  extensionless link to a `.ebnf` file no longer renders as Markdown.
- Unreadable inputs name the file and the reason (`no such file`, `broken symbolic link to X`, `too many
  levels of symbolic links`, `permission denied`, `not a regular file`) instead of `[Errno N]` text.
- The README fzf example failed for a filename starting with `-`; it now passes `--` before `{}`. A new grep
  example splits matches on a tab, since a `:` in a filename broke `{1}`/`{2}`.

## [0.7.0] - 2026-10-31

### Added

- `--timings` and `--timings-json`: per-phase timings and peak memory on stderr after rendering (Python
  imports, config, Neovim startup with each setup step, edit, filetype, parser load, query compilation, parse,
  render-markdown, redraw, resize rounds, Python's RPC handling, ANSI encoding, close), also on failure.
- `--syntax auto|regex`: force Vim's regex syntax instead of Tree-sitter; regex Markdown skips
  render-markdown. The built-in pager honours it.
- `benchmarks/filetypes` (`make bench-filetypes`): hyperfine timings for every `filetypes.json` entry on its
  fixture and a 500-line version, comparing complete output, `--syntax regex`, a viewport, bat and the
  dispatch overhead, with a phase split per file. Records `benchmarks/filetypes.tsv` and the table in
  `docs/PERFORMANCE.md`; `--check` exits 1 on a regression (25% and 50 ms by default).
- `docs/PERFORMANCE.md`: where the time goes, from the profile, and the per-filetype table.
- `tests/timings.bats` and `tests/benchmarks.bats`; a pager test for `--syntax regex`.

### Changed

- `benchmarks/run` also measures an fzf mode (fzf's preview variables, the time to the first usable preview)
  and records the startup time and the peak RSS of Neovim and of mdpreview's Python in `history.tsv` and the
  SYNTAX.md table. Shared helpers moved to `benchmarks/common.py`.
- `make check-dev` lists hyperfine.

## [0.6.0] - 2026-10-31

### Added

- Built-in Neovim pager, now the default for `--paging`: the document opens in a read-only Neovim on the
  terminal with the same profile and render-markdown options, live rendering, Neovim search and motions,
  re-wrap on resize, no 4,096-row limit, and less-style `q`, `space`/`f`, `b`, `d`, `u`. The cursor line
  never shows raw Markdown, and the first frame is already rendered. In auto mode one screen is rendered
  first to measure the document, so short documents are still printed.
- `--pager nvim|less|COMMAND` and a `pager` config key (`MDPREVIEW_PAGER`) to choose the pager; `less` means
  `less -R`. `--check` lists it.
- `tests/pager.bats` and `tests/helpers/pager_session.py`, which drive the pager in a pseudo-terminal: keys,
  search, resize, SIGTERM/SIGHUP cleanup, stdin documents, the auto-mode probe, and pager selection.

### Changed

- The default pager is the built-in Neovim pager instead of `less -R`. An existing `MDPREVIEW_PAGER` command
  still selects that command; set `pager = "less"` or pass `--pager less` to keep less.
- SIGHUP now cancels a render or pager cleanly, like SIGTERM.

## [0.5.4] - 2026-10-31

### Fixed

- Paged output showed Nerd Font icons (render-markdown's heading icons and other Private Use Area glyphs) as
  `<U+F0CA3>` in less. The pager now gets `LESSUTFCHARDEF` marking those ranges printable and single-width,
  as Neovim laid them out; a `LESSUTFCHARDEF` already in the environment is kept.

## [0.5.3] - 2026-10-31

### Added

- README "Output modes" section: how complete-document and viewport output are chosen, their limits and
  paging, and how scrolling, resizing, `--start-line`, and fzf line offsets behave in each.

## [0.5.2] - 2026-10-31

### Added

- Portable tests ported from the historical harnesses: `robustness.bats`, `languages.bats` and `fzf.bats`,
  with Python helpers in `tests/helpers/` and self-contained reference documents in
  `tests/fixtures/reference/`. Paths resolve from the checkout, output goes to temporary directories, child
  processes are found through `/proc`, and the code-color check reads the theme's String color.

### Removed

- The historical harness scripts and their captures, and their `.gitignore` entries.

### Changed

- `docs/DEVELOPMENT.md` updated for dispatch, filetype support, and the test suite.

## [0.5.1] - 2026-10-31

### Added

- `Makefile`: `install`/`uninstall` (symlinks into `$(PREFIX)/bin`, refusing to replace real files),
  `check`, `check-dev`, `deps`, `test`, `bench`, `dispatch`.
- `requirements.txt`, and a README dependency table with the versions tested.

## [0.5.0] - 2026-10-31

Configurable dependencies instead of hardcoded personal paths.

### Added

- Configuration file `~/.config/mdpreview/config.toml` (or `$MDPREVIEW_CONFIG`) with `MDPREVIEW_<KEY>`
  overrides, replacing the hardcoded editor, theme, plugin, and parser paths. See `config.example.toml`.
- `mdpreview --check`: resolved settings and their sources, dependency versions, warnings, and errors.

### Changed

- Only Neovim and render-markdown.nvim are required. A missing theme, render-markdown options file,
  `mini.icons`, or parser directory is skipped (Neovim's default colors, render-markdown's defaults, bundled
  parsers). Existing setups need a config file to keep their theme and options: set `lua_path`, `theme` and
  `markdown_options`.
- `markdown_options` may return the options table instead of calling `setup()`.

### Removed

- `readonly.py`'s command-line entry point (an experiment-only `--verify` mode with hardcoded paths).

## [0.4.1] - 2026-10-31

### Added

- `benchmarks/run`: waits for a low load average, times small, medium, large and code-fence-heavy Markdown
  samples in complete and viewport mode, appends to `benchmarks/history.tsv`, and updates a comparison table
  against the running averages in `SYNTAX.md`. `benchmarks/generate.py` writes the samples.

## [0.4.0] - 2026-10-31

Large-table fixes, faster complete output, and a bat fallback.

### Fixed

- Large Markdown tables no longer hang: Neovim's `conceal_lines` highlight hook did per-line work over every
  injected tree, so even a 20-line view of a 600-row table never finished. A 600-row viewport now takes
  about 0.4 s. Complete output of very large tables is still slow (see Known limits).
- Complete output (`mdpreview FILE` in a terminal, `--all`) of short documents could time out at random:
  render-markdown's debounce dropped the update after the resize. mdpreview now disables it.
- Timeouts report any errors Neovim raised while rendering.

### Added

- `--budget SECONDS` (default 5) for complete output, and `--fallback=bat|none`: documents that take longer
  or exceed 4,096 rows are shown with bat (paged as usual) instead of failing. `mdpreview-dispatch` uses
  `--budget=2`.
- `docs/upstream/`: a draft Neovim issue with `nvim --clean` reproduction scripts for the highlighter cost.

### Changed

- Complete output is 2-3x faster on large documents: two forced full redraws per render were removed and the
  grid starts at the document's line count instead of the screen height (300-row table 5.3 s to 1.8 s,
  600-row 19 s to 5.3 s). Output is byte-identical.

Known limits: complete output still grows with rows x table cells inside Neovim's Tree-sitter highlighter;
`SYNTAX.md` (about 1,000 rows) falls back to bat.

## [0.3.0] - 2026-10-31

Pages long documents with less by default on a terminal.

### Added

- `--paging=auto|always|never`. The default, `auto`, pages the complete document with
  `$MDPREVIEW_PAGER` (default `less -R`) on a terminal when it is taller than the screen, and prints it
  in pipes, viewports, fzf previews, and Neovim terminal buffers (Telescope).

### Changed

- Running `mdpreview FILE` in a terminal now opens long documents in less instead of printing them; use
  `--paging=never` for the old behavior. `mdpreview-dispatch` passes `--paging=never`.

## [0.2.0] - 2026-10-31

Renders non-Markdown filetypes and adds an fzf dispatcher.

### Added

- `SYNTAX.md`: the filetypes mdpreview renders (Markdown and its verified code-fence languages), and the
  filetypes the local Neovim highlights that bat has no syntax for, split into Tree-sitter parsers (189)
  and regex syntax files (667), each with the file extensions and names Neovim maps to it.

- Render non-Markdown files: about 40 filetypes bat cannot highlight (tmux, kitty, hyprlang, i3, sxhkd,
  mutt, just, kdl, json5, helm, Go templates, Django HTML, and more), using Tree-sitter when a highlights
  query is installed and Neovim regex syntax otherwise. The list lives in `filetypes.json`.
- `--filetype FT` to choose the Neovim filetype; without it the `filetypes.json` table is used, then
  Neovim's detection, then Markdown.
- `mdpreview-dispatch`, a generated bash router for fzf previews: matching files go to mdpreview, the rest
  (and any mdpreview failure) to bat. `--print` reports the decision. Regenerate with `./gen-dispatch`.
  systemd unit files go to mdpreview even though bat highlights them as INI.
- Bats test suite (`bats tests/`) for routing and for rendering every listed filetype.

### Fixed

- README install instructions: link `~/.local/bin/mdpreview` to the checkout instead of copying it. A copy
  cannot find `readonly.py`, `profile.lua`, or `queries/` and fails on startup. Corrected the checkout path.

## [0.1.0] - 2026-10-22

Initial standalone Markdown renderer.

### Added

- Capture Neovim's rendered character grid and emit RGB ANSI terminal output.
- Load selected editor colors, render-markdown options, icons, and installed Tree-sitter parser/query pairs.
- Support complete output, a viewport, explicit width, starting line, and finite stdin.
- Preserve Markdown decorations, nested bullets, tables, code backgrounds, and language labels.
- Highlight C/C++, Rust, Bash, Go, Python, JavaScript, SQL, and common fence aliases.
- Restrict writes with Linux Landlock and clean up Neovim on normal completion or cancellation.
- Document terminal and fzf usage, architecture, compatibility limits, and follow-up work.

Known limits: personal installation paths, Linux/x86-64, no persistent worker, a 10 MiB input limit, and a
4,096-row complete-output limit. Released-Neovim compatibility and portable CI remain unverified.
