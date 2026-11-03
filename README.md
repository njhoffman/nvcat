# nvcat

Render Markdown to ANSI terminal output using Neovim, Tree-sitter, and render-markdown.nvim. It also renders
about 40 config and source filetypes that bat has no syntax for, using Tree-sitter or Neovim regex syntax.
The command captures rendered characters and styles, including headings, icons, nested lists, code backgrounds,
and tables. Formerly `mdpreview` (renamed in 0.10.0).

The current version is in [VERSION](VERSION) and printed by `nvcat --version` (`-v`); each release has a matching
annotated Git tag (`vX.Y.Z`).
See [CHANGELOG.md](CHANGELOG.md), [TODO.md](TODO.md), [SYNTAX.md](SYNTAX.md) (filetype coverage), and the
[release process](docs/RELEASING.md).

## Requirements

Runtime (`just check`, or `nvcat --check`, verifies these and prints the versions found):

| Dependency | Required | Tested with | Notes |
|---|---|---|---|
| Linux with Landlock | yes | kernel 6.17, ABI 7 | x86-64 |
| Python | yes | 3.13.7 | 3.11 or later (`tomllib`); run as `/usr/bin/python3` |
| msgpack (Python) | yes | 1.0.3 | `apt install python3-msgpack`, or `just deps` (pip, user install) |
| Neovim | yes | 0.11.7, 0.12.6, v0.13.0-dev-1915+gc5641b2bfb | 0.11 or later; older versions are refused. `tests/nvim-versions` runs the suite on released versions |
| render-markdown.nvim | yes | v8.14.0-2-g8e87953 | any plugin manager; found under `plugin_dirs` |
| mini.icons | no | v0.18.0-5-g9e4c164 | icons need a Nerd Font |
| Tree-sitter parsers | no | | Neovim bundles markdown and markdown_inline; code fences and other filetypes need their parsers |
| bat | no | 0.26.1 | fallback renderer and `nvcat-dispatch` |
| less | no | 668 | `--pager less` (the default pager is the built-in Neovim one) |

Development (`just check-dev`; the recipes need [just](https://github.com/casey/just)): bats 1.5 or later, `script` (util-linux), fzf, git; curl for `tests/nvim-versions`.

Tree-sitter parsers must match the Neovim that loads them: a parser built for a newer Tree-sitter ABI (or
any parser file that fails to load) gives one warning and regex syntax for that language instead of an error.

Dependencies are read from an existing installation; no plugin manager runs.

## Install

```sh
just check     # dependencies and resolved configuration
just install   # symlink nvcat and nvcat-dispatch into ~/.local/bin (PREFIX=... to change)
just uninstall
```

The commands are linked, not copied: nvcat finds `profile.lua`, `readonly.py`, `config.py`,
`filetypes.*` and `queries/` next to its real path, so keep the checkout in place. `just test`, `just bench`
and `just dispatch` run the tests, the benchmarks and the dispatch generator.

## Configuration

nvcat reads `~/.config/nvcat/config.toml` (or `$NVCAT_CONFIG`); every key is optional and
`NVCAT_<KEY>` environment variables override single keys. See [config.example.toml](config.example.toml).
Without a file it finds plugins in lazy.nvim's and the packpath's directories, uses
`~/.local/share/nvim/site` for parsers when present, Neovim's default colorscheme, and render-markdown's
default options. Point `theme` (a Lua file returning a table with `apply()`, with `lua_path` for its modules)
or `colorscheme`, and `markdown_options` (your editor's render-markdown config file, or a file returning the
options) at an editor setup to match its appearance.

```sh
nvcat --check        # resolved settings and their sources, versions, warnings; exit 1 if something required is missing
nvcat --check --all  # also compile the queries of every installed parser (code fences can use any; slow)
```

Missing optional pieces are skipped with a warning in `--check`; a missing Neovim or render-markdown is an
error. `--check` also compiles the Tree-sitter highlights and injections queries of each `filetypes.json`
language and lists those shown with regex syntax.

A query written for a different version of its parser ("Invalid node type") does not stop a render: that
language loses Tree-sitter highlighting (a whole file of it uses Vim's regex syntax instead) and one warning on
stderr names the query file. Update the parser and its queries together, usually by pointing `parser_dir` at
the directory that has both.

## Usage

Run from the checkout or after `just install`:

```sh
./nvcat README.md
./nvcat --columns 120 README.md
./nvcat --columns 80 --lines 24 README.md
./nvcat --start-line 20 --lines 40 README.md
cat README.md | ./nvcat            # no file: stdin when it is not a terminal (or pass -)
helm template . | ./nvcat -c --filetype yaml
./nvcat --filetype tmux ~/.tmux.conf
./nvcat --paging=always README.md
./nvcat --syntax regex config.kdl   # Vim's regex syntax instead of Tree-sitter
./nvcat --timings README.md         # per-phase timings and peak memory on stderr
./nvcat --filetype auto notes.w     # Neovim detects by content; bat when it is not an nvcat filetype
./nvcat --filetypes                 # filetype, table, globs and content-detected globs of every filetype
```

Without `--filetype`, the file's name is matched against [filetypes.json](filetypes.json), then the generated
[filetypes.regex.json](filetypes.regex.json) (Neovim's regex-syntax filetypes that bat has no syntax for),
then the `last` entries of filetypes.json (case-insensitively, so `README.MD` is Markdown); then Neovim's own
detection is used, then Markdown. Names bat claims ([filetypes.bat.json](filetypes.bat.json), such as
`go.sum`) skip the tables and go straight to Neovim's detection. Some generated globs (`*.w`, `*.bas`,
`.cshrc`, ...) are ones Neovim assigns by content; nvcat renders whatever Neovim picks for them, and
`--filetype auto` (used by `nvcat-dispatch`) renders the file only when Neovim's choice is one of nvcat's
filetypes and hands it to bat otherwise, without a notice. Input with a NUL byte in its first 8 KiB is binary and goes to the bat
fallback. A symbolic link is matched by
its own name first and by its target's name when its own matches nothing. stdin is Markdown unless
`--filetype` is given.

### Output modes

nvcat emits either the **complete document** or one **viewport**:

| | Complete document | Viewport |
|---|---|---|
| Chosen by | `--all`; also the default when none of `--lines`, `--start-line` or `$FZF_PREVIEW_LINES` is given | `--lines N`, `--start-line N`, or `$FZF_PREVIEW_LINES` (fzf previews without `--all`) |
| Rows emitted | every screen row of the rendered document, up to 1,000 | at most the viewport height (`--lines`, else `$FZF_PREVIEW_LINES`, else the terminal height) |
| Time limit | `--budget` (default 5 s) overall and `--timeout` (default 8 s) per render step, then the bat fallback | `--timeout` per render step, then the bat fallback |
| Paging | `--paging=auto` pages it when it is taller than the terminal (see [Paging](#paging)) | never paged; `--paging=always` with `--lines` or `--start-line` is an error |

Both modes load and parse the whole file, but a viewport draws only one screen, so it is faster on longer
documents (see the [benchmarks](SYNTAX.md#markdown-rendering-benchmarks)) and is the safer choice for very
large tables, which can exceed the complete-output budget.

Scrolling works differently in each mode:

- **Complete document.** Scroll in the pager, or in the fzf preview window (mouse, `shift-up`/`shift-down`).
  The output is static: wrapping was done by Neovim at the width given, so resizing needs a fresh render
  (`--bind 'resize:refresh-preview'` in fzf).
- **Viewport.** The output is exactly one screen; scrolling the fzf preview reveals nothing more. To show
  another part, run again with a different `--start-line`. `--start-line` counts **source lines**, not screen
  rows: wrapped lines, rendered tables, and render-markdown's virtual rows (heading padding, code borders)
  take more or fewer screen rows than source lines, so stepping `--start-line` by the viewport height does not
  move by exactly one screen.
- **Jumping to a line in fzf** (for example a grep match): with a viewport, pass the line number as
  `--start-line {2}` so the match is the first row (see [fzf](#fzf) for splitting a match safely). With the
  complete document, fzf's `--preview-window '+{2}'` offset counts screen rows, so it drifts from the source
  line wherever rows wrap or are added.

### Paging

`--paging=auto` (the default) pages the complete document when stdout is a terminal and the document is
taller than the screen, and prints it otherwise. It always prints when stdout is piped, for a viewport
(`--lines`, `--start-line`), inside fzf previews (`FZF_PREVIEW_COLUMNS`/`FZF_PREVIEW_LINES` set), and inside
Neovim terminal buffers (`$NVIM` set), which covers Telescope's previewer even though it provides a terminal.
`--paging=always` pages even short documents; `--paging=never` (or `-c`/`--cat`) always prints. When
both `--cat` and `--paging` are given, the last one wins.

The pager is chosen by `--pager`, else the `pager` config key (`NVCAT_PAGER`), else `nvim`:

- **`nvim`** (default): the document opens in a read-only Neovim on your terminal, with the same profile,
  theme, and render-markdown options as the printed output. render-markdown stays live, Neovim search,
  motions, and visual yank work, and resizing the terminal re-wraps the text. There is no 1,000-row limit
  and no `--budget`, since Neovim only draws what is on screen. The raw Markdown of the cursor line is
  never revealed. Keys added on top of Neovim's: `q` quits, `space`/`f` and `b` page down/up, `d`/`u`
  scroll half a page. `--columns` does not apply: the pager uses the terminal's width. In auto mode,
  nvcat first renders one screen to measure the document, so a short document is printed instead of
  opening the pager. When stdout is not a terminal, `--paging=always` prints.

  `-f`/`--follow` opens the pager at the end of the file and reloads it as it changes, like `less +F` or
  `tail -f`: while the cursor is on the last line the view stays at the end; moving up pauses that and `G` or
  `F` resumes it. A truncated, replaced or recreated file is reloaded. It needs the `nvim` pager, a terminal
  and a file (not stdin), cannot be combined with `--paging=never`, `--lines` or `--start-line`, and is not
  subject to the 10 MiB input limit.
- **`less`**: the rendered output is piped into `less -R` (`$LESS` applies). less runs with
  `LESSHISTFILE=-` because Landlock blocks writes outside the run directory, and with
  `LESSUTFCHARDEF=e000-f8ff:p,f0000-ffffd:p,100000-10fffd:p` (unless you set your own) so it shows Nerd Font
  icons in the Private Use Areas instead of `<U+F0CA3>`.
- **any other value**: a pager command line that reads ANSI text on stdin, run like less.

Ctrl-C is left to the pager.

### Limits and fallback

When a render reaches one of these limits, the file is shown with bat instead (`--language=markdown` for
Markdown, bat's own detection otherwise), with a one-line notice on stderr naming the limit:

| Limit | Applies to | Change it with |
|---|---|---|
| Input over 10 MiB | both modes; Neovim is not started | fixed |
| Over 1,000 screen rows (Neovim's maximum `lines`) | complete output | `--lines` renders a viewport; the `nvim` pager has no row limit |
| Over `--budget` seconds (default 5; `0` disables it) | complete output | `--budget` |
| Neovim silent for `--timeout` seconds (default 8) | both modes, each render step | `--timeout` |

A viewport falls back to the same viewport of bat's output (`--start-line` and the height select bat's lines),
so fzf previews show text instead of an error. Complete fallback output is paged like a normal render; with
the `nvim` pager it goes to `less -R`, since it is already ANSI text. `--fallback=none` reports the limit as an
error (exit 1) instead, as does a missing or failing bat. Very large Markdown tables
hit this: Neovim's Tree-sitter highlighter does per-line work for every injected tree, and each table cell is
one tree (see [docs/upstream](docs/upstream/neovim-treesitter-injection-cost.md)). `nvcat-dispatch`
uses `--budget=2` so fzf previews stay responsive.

There is no streaming. The whole input is read into memory and loaded into one Neovim buffer, and
Tree-sitter parses all of it, even for a one-screen viewport, so time and memory grow with the input size,
not the output. A 40-row viewport of plain prose, measured 2026-10-31 under load 6 (times are high):

| Input | Time | Neovim peak RSS |
|---|---|---|
| 0.1 MiB | 0.6 s | 25 MiB |
| 1 MiB | 1.8 s | 80 MiB |
| 5 MiB | 6 s | 320 MiB |
| 9.9 MiB | 13 s | 615 MiB |

Large files are therefore not a supported use: the practical limit is time, well before the 10 MiB cap, and
Markdown tables cost much more per byte than prose (see above). Complete output stops at 1,000 rows, roughly
a few hundred source lines of prose.

### Syntax engine

`--syntax auto` (the default) highlights with Tree-sitter when the language has a highlights query and with
Vim's regex syntax files otherwise. `--syntax regex` always uses the regex syntax; for Markdown that also
skips render-markdown, so the raw Markdown is shown with Vim's markdown syntax. It is mainly a comparison and
an escape hatch for a slow or broken parser (Tree-sitter's query compilation dominates some filetypes, see
[docs/PERFORMANCE.md](docs/PERFORMANCE.md)). The built-in pager honours it too.

### Timings

`--timings` prints, after the output, how long each phase took and the peak memory, on stderr; stdout is
unchanged. `--timings-json` prints the same as one JSON object for scripts. Phases: Python imports, config,
input, Neovim startup (split into Neovim's own start, the profile, and each setup step: theme, render-markdown,
icons, query tuning), `open` (edit, filetype, parser load, `vim.treesitter.start`, which compiles the queries,
and the synchronous parse, or the regex syntax load), frames (the first frame and any resize rounds for
complete output, with render-markdown's render, the wait in Neovim's event queue, and Neovim's redraw summed
over all ready callbacks; `ready_callbacks` counts those), ANSI encoding,
close, and output. `rpc handling (python)` is the part of the waits that Python spent decoding redraw events,
not extra time. The Neovim pager is not timed. Timings are printed on failures too.

Install with `just install` (see [Install](#install)).

## fzf

```sh
printf '%s\n' ./*.md |
  fzf --preview 'nvcat --all -- {}' \
      --preview-window 'right:75%:nowrap' \
      --bind 'resize:refresh-preview'
```

fzf quotes `{}` for the shell, so names with spaces, quotes, `|` or `$` arrive intact; the `--` keeps a
name that starts with `-` from being read as an option. To preview grep matches, split them on a tab rather
than `:`, which filenames can contain (`c:d.md` would otherwise become the file `c`):

```sh
rg --line-number --with-filename --field-match-separator=$'\t' PATTERN |
  fzf --delimiter '\t' --preview 'nvcat --start-line {2} -- {1}'
```

Names containing a tab or newline cannot be represented as fzf lines this way.

`--all` emits the complete document for scrolling. Omit it for a single viewport, sized using
`FZF_PREVIEW_COLUMNS` and `FZF_PREVIEW_LINES` (see [Output modes](#output-modes)). Neovim performs wrapping; refreshing on resize recomputes layout.
For a mixed-file preview, use `nvcat-dispatch`: it sends Markdown and the other filetypes in
[SYNTAX.md](SYNTAX.md) to nvcat and everything else to bat, and falls back to bat if nvcat fails:

```sh
fzf --preview 'nvcat-dispatch {}' --preview-window 'right:75%:nowrap' --bind 'resize:refresh-preview'
nvcat-dispatch --print path/to/file   # print the filetype; exit 1 when bat would handle it
```

For a glob Neovim assigns by content, `--print` prints `auto` and the file goes to `nvcat --filetype auto`,
which costs a Neovim start before bat takes over when the content is not one of nvcat's filetypes.

The script is a generated bash `case` (a few milliseconds, no Neovim or Python start-up); the generated
filetypes sit in a second stage that bash only parses for files the first stage does not match. Regenerate it
with `./gen-dispatch` (which also writes `filetypes.bat.json`) after editing [filetypes.json](filetypes.json) or changing bat's syntaxes or
`--map-syntax` config, and run `./gen-filetypes` (which also regenerates SYNTAX.md's coverage lists) first when Neovim, its syntax
files or parsers, or bat change (`just filetypes` runs both); `tests/dispatch.bats` fails while either is stale. Link it onto PATH like `nvcat`. See
[development and integration notes](docs/DEVELOPMENT.md).

## Benchmarks

```sh
benchmarks/run            # waits for load <= 0.6 x CPUs, records, updates SYNTAX.md
benchmarks/run --dry-run  # print the table only
```

Renders four generated samples ([benchmarks/](benchmarks/): small, medium, large, and a code-fence-heavy
one; regenerate them with `benchmarks/generate.py`) in complete, viewport, and fzf mode (fzf's preview
variables, which is the time to the first usable preview), appends the medians of wall time, startup and peak
Neovim and Python RSS to `benchmarks/history.tsv`, and rewrites the comparison table in
[SYNTAX.md](SYNTAX.md#markdown-rendering-benchmarks) against the average of all earlier runs. Run it after
every change.

```sh
benchmarks/filetypes                    # every filetypes.json entry; records; several minutes
benchmarks/filetypes --only cuda,astro  # some filetypes
benchmarks/filetypes --quick --check    # fixtures only, compare with the baseline, record nothing
```

Times each filetype on its fixture and on that fixture repeated to 500 lines with hyperfine: complete output,
`--syntax regex`, a viewport, bat, and `nvcat-dispatch`, plus one `--timings-json` run for the phase
split. Results go to `benchmarks/filetypes.tsv` and [docs/PERFORMANCE.md](docs/PERFORMANCE.md). `--check`
exits 1 when a filetype got slower than the baseline by 25% and 50 ms (`--threshold`, `--min-ms`). Needs
hyperfine. `just bench-filetypes` runs it.

## Tests

```sh
bats tests/
```

`just test` runs the same. Files: `dispatch.bats` (routing, with stub commands), `render.bats` (every table
filetype through the configured Neovim), `pager.bats` (the built-in Neovim pager, driven in a pty),
`paging.bats` (external pagers), `fallback.bats` (every limit), `config.bats`, `timings.bats` (`--timings`,
`--syntax`), `dependencies.bats` (query mismatches, missing dependencies), `inputs.bats` (extension case,
symbolic links, unreadable and empty inputs), `version.bats`,
`benchmarks.bats` (the benchmark scripts), `robustness.bats`
(tails, viewports, filenames, stdin, modelines, errors, terminal round trip, signal cleanup, immutability,
sandbox), `languages.bats` (code-fence colors), and `fzf.bats` (a real fzf session; skipped without fzf).
Python helpers live in `tests/helpers/`; fixtures in `tests/fixtures/`. Tests that need a configured theme
skip without one.

## Code highlighting

Label fenced blocks with `c`, `cpp`, `rust`, `bash`, `go`, `python`, `javascript`, or `sql`:

````markdown
```rust
let message = "hello";
```
````

Verified aliases include `c++`, `cxx`, `cc`, `sh`, `shell`, `js`, and `py`.
Single-backtick spans retain inline-code styling without identifying a programming language.

## Architecture and limits

Python starts a private embedded Neovim with `profile.lua`, temporary XDG directories, and plugin managers
disabled. The profile loads selected editor settings and parser/query pairs. After render-markdown signals
readiness, Python converts the RGB screen grid into ANSI output and closes Neovim.

`readonly.py` restricts filesystem writes with Linux Landlock to the per-run `/tmp/nvcat-*` directory
(and terminal devices), which is also `TMPDIR` for Neovim and external pagers. A small child forked before
the sandbox removes that directory once nvcat exits, however it exits. The query extension handles C++ fence labels.
Each invocation starts a new Neovim; there is no persistent worker. Width is limited to 10–500 columns;
input over 10 MiB and complete output over 1,000 screen rows fall back to bat (see
[Limits and fallback](#limits-and-fallback)). A viewport still loads the whole input file.

Released-Neovim compatibility remains unverified (see TODO.md).
