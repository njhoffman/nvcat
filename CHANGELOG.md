# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses Semantic Versioning with
annotated `vMAJOR.MINOR.PATCH` Git tags.

## [Unreleased]

## [0.34.4] - 2026-11-07

### Fixed

- The built-in pager no longer shows a paragraph's raw Markdown (`**bold**`, backticks, link syntax) for a moment
  after a jump or a large scroll: it parses synchronously, like rendering. `--follow` keeps asynchronous parsing.

## [0.34.3] - 2026-11-07

### Fixed

- Complete output whose grid grows past its first height no longer loses some paragraphs' inline formatting (bold,
  italic, hidden link syntax). Rendering now parses synchronously; the built-in pager is unchanged.

### Changed

- `cylc` files are no longer listed as a Tree-sitter filetype: nvim-treesitter dropped its parser and queries.

## [0.34.2] - 2026-11-06

### Added

- `benchmarks/run` records worker previews as the modes `worker` and `worker-all`.

### Fixed

- The benchmarks' fresh renders no longer come from a worker when `NVCAT_WORKER=1` is set in the environment.

## [0.34.1] - 2026-11-06

### Fixed

- On Neovim 0.11, Tree-sitter renders waited for the highlighter until the timeout and then fell back to bat. This came in
  with 0.34.0, which took a per-window flag for a single one.

## [0.34.0] - 2026-11-06

### Added

- `NVCAT_WORKER=1` now also serves `--all`, `--paging=never`, `--budget` and `--filetype`, so previews through
  `nvcat-dispatch` come from the worker too. A document over its budget goes to the fallback at once, without spending the
  budget a second time.

### Fixed

- A preview could show no Tree-sitter colors at all when it was captured while Neovim's highlighter was still parsing.
  nvcat now waits for the parse to finish. `--timings-json` reports the waits as `parse_waits`.

## [0.33.0] - 2026-11-06

### Added

- `NVCAT_WORKER=1` serves fzf previews from a Neovim that stays running: about 100 ms for the Markdown samples, against
  about 450 ms, and the same bytes. It covers `nvcat FILE` inside an fzf preview, not `--all`, other flags or
  `nvcat-dispatch`. The first preview starts the worker and renders by itself, and anything the worker cannot serve
  renders the usual way. It restarts Neovim when the theme, config, parsers or `NVCAT_*` variables change, or past
  200 MiB, cancels a preview whose client has gone, and exits after `NVCAT_WORKER_IDLE` seconds without a request
  (default 600).

## [0.32.0] - 2026-11-06

### Added

- `--timings` and `--timings-json` report the time spent loading parsers and queries for injected languages as
  `injected languages`, under both open and frames.

## [0.31.1] - 2026-11-06

### Fixed

- Logs have color under any theme when a `log` parser captures `@log.*` groups; a theme's own groups still win.
- `tests/fzf.bats` keeps reading the terminal after ESC, since fzf cannot exit while its output sits unread.

## [0.31.0] - 2026-11-06

### Added

- CI: `.github/workflows/ci.yml` runs the suite on a clean Ubuntu 24.04 against Neovim 0.11.7 and 0.12.6, with pinned
  tools and plugins from `tests/ci-setup`.

### Changed

- Only `http`, `https` and `mailto` links become hyperlinks, because rendering hides the target behind the text: links
  such as `file:///etc/passwd`, `javascript:` and `ssh://`, and links with no scheme, stay plain text. The `link_schemes`
  config key and `NVCAT_LINK_SCHEMES` set the list, and `all` allows any.

### Fixed

- A symbolic link loop gives the same error on every Python, where before 3.13 it read differently.
- Tests that need a Tree-sitter parser skip without it, and the suite runs where `TERM` is not set.

## [0.30.0] - 2026-11-06

### Added

- `just completions` installs the completion scripts for the shells on this machine.

### Fixed

- The test that `filetypes.regex.json` and `SYNTAX.md` are current skips, and says how to regenerate them, on a machine
  whose Neovim, bat or parsers differ from those they were generated with, instead of failing.

## [0.29.0] - 2026-11-06

### Added

- The `pager_init` config key names a Lua file whose `apply()` runs in the nvim pager after it sets its keys, for smooth
  scrolling or keys of your own. If it fails the pager still opens, with a warning. `less` is not affected.
- `--pace[=RATE]`, the `pace` config key and `NVCAT_PACE` print to a terminal a line at a time at a readable pace, in
  visible characters per second (default 800), instead of opening the pager. Long lines linger and blank lines pass
  quickly. Pipes, files and fzf previews are never paced. Ctrl-C stops it.

### Fixed

- `benchmarks/compare` works against a ref older than a key in your config file: that side gets the keys it knows.
- A long warning in the nvim pager no longer stops at "Press ENTER" before the document is shown.

## [0.28.0] - 2026-11-06

### Added

- `benchmarks/compare REF` compares a Git ref with the working tree on the benchmark samples, also on a machine in use.
  The two trees take turns, a row counts as slower or faster only when the middle 50% of the differences is on one side
  of zero, and it says whether the output changed. It records nothing.

## [0.27.1] - 2026-11-05

### Added

- `just test-defaults` runs the test suite with no config file, as on a fresh machine.

### Fixed

- The rendering tests pass with any theme: they use their own instead of whichever this machine has configured.

## [0.27.0] - 2026-11-05

### Added

- A Vim modeline in stdin's first or last line names its filetype, as it does for a named file: `ft=` renders with
  Tree-sitter and a `syn=`-only modeline with Vim's regex syntax. `--filetype` overrides it, and without either stdin
  stays Markdown.

### Changed

- The generated `nvcat-dispatch` drops globs that another glob of the same entry already covers, and is clean under
  `shellcheck`. Routing is unchanged.

## [0.26.1] - 2026-11-05

### Fixed

- The test suite no longer fails for reasons unrelated to the code: the routing speed tests hold up on a busy machine,
  and the "Neovim left running" checks ignore renders from other shells.

## [0.26.0] - 2026-11-05

### Added

- `--timings` and `--timings-json` report `render_passes`, how many times render-markdown ran its handlers.
- The `benchmarks/run` table compares each result with the median of the last 5 runs as well as the all-time average,
  which spans every version and so hides a recent change.

### Changed

- Complete Markdown output is up to 8% faster, and viewports up to 4%: render-markdown no longer renders each document
  twice. The output is byte-identical.
- `benchmarks/run` exits 2 when the load never drops low enough to start, instead of 1 like a failed render.

### Fixed

- Sourcing the zsh completion before `compinit` no longer prints `command not found: compdef`.

## [0.25.0] - 2026-11-03

### Added

- `--help` has color: headings, options and their values. On a terminal unless `NO_COLOR` or a setting turns it off, and
  with `--color=always` in a pipe.

### Fixed

- `--help` described nvcat's code (bytecode and `__pycache__`, since 0.20.0); it now says what the command does.
- `benchmarks/filetypes` failed with hyperfine 2, which moved its statistics in the exported JSON. Both versions work.

## [0.24.0] - 2026-11-03

### Added

- `--color auto|always|never`, the `color` config key and `NVCAT_COLOR`, and nvcat honors `NO_COLOR` when none of them is
  set. Color stays on by default, also when piped. With it off, output has no escape sequences, and the `nvim` pager gives
  way to `less` (except `--follow`).

### Security

- Output through bat no longer carries a file's escape sequences, in the fallback and in `nvcat-dispatch`. These
  were passed to the terminal unchanged. `gen-dispatch` warns when bat is older than 0.25.0, which lacks `--strip-ansi`.
- Error messages show control characters in file names and in Neovim's stderr as `\xNN`, instead of sending them to the
  terminal.

## [0.23.0] - 2026-11-03

### Added

- `nvcat completions bash|zsh|fish` prints a shell completion script, generated from nvcat's own options. The bash
  and zsh scripts are tested by completing in those shells; the fish script has a test that runs only where fish is
  installed, and has not been run yet.
- A link wrapped over rows is one link to the terminal: each URI has an OSC 8 `id`, so hover and underline cover
  all of it.

### Changed

- Link targets are normalized, in printed output and in the `nvim` pager: `[t](<http://x/a b>)` loses its angle
  brackets, and spaces and non-ASCII characters are percent-encoded, so those links now open the right address.
- `examples/fzf-files` without a generated `nvcat-dispatch` says what to run and exits, instead of showing an error
  in every preview.

### Fixed

- `--hyperlinks auto` left links out whenever a pager command other than less was configured, even when no pager runs:
  piped output, `--lines` viewports and fzf previews now keep them.
- `requirements.txt` named `make deps`; it is `just deps`.
- The README overstated what was tested and gave the wrong fzf version: hyperlinks arrived in fzf 0.55. It no longer
  lists terminals; `tests/fzf.bats` now checks links through a real fzf.

## [0.22.0] - 2026-11-03

### Added

- `*.log` and `*_log` files render as `log`, with its Tree-sitter parser and query when `parser_dir` has them (Neovim's
  regex syntax otherwise), instead of falling through to Markdown, which struck through text between two `~`.

### Fixed

- `--follow` kept a non-Markdown file's Tree-sitter colors only until the first reload, then showed its regex syntax.

### Known limitations

- `log` uses Tree-sitter only where `parser_dir` has a `log` parser and query, which no parser manager installs today.
- `--follow` reparses the whole file on each reload, so a Tree-sitter file of several MiB that changes often stutters.

## [0.21.2] - 2026-11-03

### Fixed

- A Neovim that exits at start could end in exit status 0 and no output, about 1 run in 10, so a preview stayed
  blank and nothing fell back to bat. It is now always the error "Neovim exited before completing the preview",
  with what Neovim wrote to stderr.
- nvcat starts with `PYTHONSAFEPATH` set, which took its own directory off Python's module path.

### Changed

- `tests/nvim-versions` also runs `attributes.bats` and `reference.bats`. Checked with this release: Neovim 0.11.7
  and 0.12.6 pass, including the link and underline output added in 0.21.0.

## [0.21.1] - 2026-11-03

### Security

- A Markdown link could send terminal escape sequences: 0.21.0 wrote the link's URL into the OSC 8 hyperlink
  unfiltered, so previewing an untrusted file could, for example, change the window title. A link whose URL has
  a control byte (C0, DEL or C1) now stays plain text, whatever `--hyperlinks` says.
- The built-in `nvim` pager had the same problem in every earlier version with it, whatever `--hyperlinks` says.
  It now drops such URLs (and invalid UTF-8); clean links keep working. If you run an older nvcat, update.

### Fixed

- `--lines 1` (and a one-line fzf preview) timed out and fell back to bat on every file: Neovim's screen is at
  least two rows, so nvcat waited for a one-row frame that never came. It now renders two rows and prints one.

## [0.21.0] - 2026-11-03

### Added

- Markdown links are clickable: inline links and autolinks become OSC 8 hyperlinks in terminals that
  support them. `--hyperlinks auto|always|never` (config key `hyperlinks`, `NVCAT_HYPERLINKS`); `auto`, the
  default, leaves them out when a pager command other than less may show the output.
- Curly, double, dotted and dashed underlines keep their style (SGR `4:3`, `4:2`, `4:4`, `4:5`), and an
  underline color is kept (`58:2::R:G:B`); before, every style was a plain underline in the text color.
- Tests of the reference documents at 40, 80 and 120 columns (footnotes, wiki links, HTML comments, callouts,
  code labels, tables, and no line wider than the output), and of wide, emoji and combining cells and the
  transparent default background.

### Fixed

- With render-markdown's default options, the first row of every render and viewport showed its raw Markdown
  (`# Heading`): anti-conceal revealed the cursor line. It is now off for printed output too, not only in the
  `nvim` pager. Options files that already turned it off saw no difference.
- Trailing blank cells with a double, dotted or dashed underline were trimmed from the end of a row.

## [0.20.0] - 2026-11-03

### Changed

- Faster start: the code moved from the `nvcat` script into `nvcat_cli.py`, which the `nvcat` command imports,
  so Python caches its bytecode instead of compiling 1,000 lines on every run (7-9 ms less per start, 14 ms
  on a 3-line file's median). tomllib is imported only when a config file exists. Scripts that loaded the
  `nvcat` file as a module load `nvcat_cli.py` instead.

### Fixed

- The missing-msgpack message pointed at `make deps`; it is `just deps` since 0.13.0.

## [0.19.0] - 2026-11-03

### Changed

- `benchmarks/run` renders the samples and modes round-robin (one warm-up of each, then rounds that render
  every one once), so a burst of load from another process spreads over every row instead of ruining one.
- `benchmarks/run` does not record a noisy run: when the load ends above `--max-load`, or the typical startup
  is over 1.5 times its median of the last five recorded runs, it prints the table, says why, and exits 3.
  `--record-noisy` records it anyway, for a startup that really changed.

## [0.18.0] - 2026-11-03

### Changed

- A modeline may name any filetype nvcat's Neovim can highlight, not only nvcat's own: `~/.config/fzf/fzfrc`
  ending in `# vim:syn=bash:ft=` now renders as bash through nvcat instead of as plain text in bat, and
  `# vim: ft=zsh` beats bat's claim on `*.sh`. `./gen-filetypes` lists those filetypes (a syntax file, or a
  Tree-sitter parser with a highlights query; 985 here) as `highlighted` in filetypes.regex.json. Names
  Neovim cannot highlight are still ignored.
- A modeline with only `syn=`/`syntax=` renders with Vim's regex syntax, as Neovim shows that file, instead of
  Tree-sitter; with `--filetype` too when it names the same filetype (so through `nvcat-dispatch` and
  `bat-dynamic`). `ft=` keeps `--syntax auto`.
- `tests/benchmarks.bats` no longer fails when the machine is busy: the quick `benchmarks/filetypes` check
  accepts a regression verdict (exit 1), which load alone produced at 2.8, and still checks that every
  variant is measured and nothing recorded. Judge regressions with `benchmarks/filetypes --check` on a quiet
  machine.

## [0.17.0] - 2026-11-03

### Added

- Filetypes from Vim modelines: `ft=`/`filetype=` (else `syn=`/`syntax=`) in a `vim:`, `vi:`, `ex:` or
  `vim600:` modeline on a file's first or last line, in either of Vim's forms, decides the filetype in both
  `nvcat` and `nvcat-dispatch`, ahead of the name and bat's claims, when it names one of nvcat's filetypes;
  others are ignored. Nothing else in the modeline is applied. `notes.txt` ending in `# vim: ft=markdown`
  now renders as Markdown. nvcat-dispatch reads files under 512 lines with bash's `mapfile` and the end of
  longer ones with `tail`, about 1 ms (2-3 ms over 512 lines) per file.

## [0.16.0] - 2026-11-03

### Changed

- `nvcat-dispatch` and `filetypes.bat.json` are no longer tracked: they embed this machine's bat syntaxes
  and `--map-syntax` globs, so each machine generates its own. `just install` runs `./gen-dispatch` before
  linking; after updating the checkout or changing bat's config, run `just dispatch` (or `just install`).
  The test suite generates them first (`tests/setup_suite.bash`), so it passes on any machine.
- `gen-dispatch` works without bat: it writes a router with no bat claims and says so.

### Added

- `nvcat --check` warns when `nvcat-dispatch` is missing or older than the tables it is generated from.

## [0.15.1] - 2026-11-03

### Changed

- docs/PERFORMANCE.md compares 0.15.0 with the Markdown-only v0.1.0: 16-23 ms more fixed startup (Python
  only), the same memory, and 2-4 times faster renders of larger documents.
- The nvimpager configuration is gone, and docs/DEVELOPMENT.md no longer mentions it.

## [0.15.0] - 2026-11-03

### Changed

- Faster Markdown on Neovim 0.12 and later: `profile.lua` narrows the highlight states Neovim's Tree-sitter
  highlighter walks for each drawn line to the trees on that line. Output is unchanged; complete renders of
  documents with many inline spans, tables and code blocks take 5-73% less time (54% for benchmarks/large.md, 73% for a 600-row table). The patch checks the
  private internals it relies on and stays off when one has changed; `highlight_index` in `--timings` shows
  `on`, `off` or the reason, and `NVCAT_HIGHLIGHT_INDEX=0` turns it off. `tests/highlighter.bats` fails when
  Neovim's internals no longer match and compares output with the index on and off.

### Added

- `benchmarks/highlighter` (`just bench-highlighter`): renders documents with the index on and off, times
  Neovim's highlighter callbacks, fails when the outputs differ, and with `--update` records the table in
  docs/PERFORMANCE.md. The numbers are also in the drafted Neovim issue.

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
