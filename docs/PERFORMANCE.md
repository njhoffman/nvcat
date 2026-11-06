# Performance

Where a render's time goes, measured with `nvcat --timings` (see the README) on 2026-10-31, NVIM
v0.13.0-dev, 8 CPUs at a 1-minute load of about 2. Each figure is a median of three runs; expect +-20% from
the load on this desktop. Regenerate the per-filetype table with `benchmarks/filetypes`; the Markdown samples
are tracked by `benchmarks/run` in [SYNTAX.md](../SYNTAX.md#markdown-rendering-benchmarks).

## Phases

| Document | Mode | Total | Python imports | Startup | Open | Frames | of which render / redraw | RPC (Python) | ANSI | Neovim RSS |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| tmux fixture, 4 lines | `--all` | 88 | 36 | 23 | 19 | 2 | 0 / 2 | 7 | 0 | 18 MiB |
| benchmarks/medium.md, 353 lines | `--all` | 1031 | 41 | 33 | 55 | 861 | 329 / 479 | 33 | 21 | 59 MiB |
| benchmarks/large.md, 888 lines | `--all` | 2043 | 45 | 65 | 53 | 1815 | 422 / 1241 | 79 | 49 | 67 MiB |
| benchmarks/large.md | `--lines 40` | 487 | 39 | 23 | 46 | 371 | 230 / 129 | 7 | 2 | 43 MiB |

Milliseconds. Python's interpreter start (about 17 ms, `python3 -c pass`) comes before the first import and is
not in the totals.

Findings, in order of what they cost:

1. **Frames dominate Markdown.** Everything up to a ready Neovim (imports, startup, open) is about 130 ms for
   any document; the rest is render-markdown's render and Neovim's redraw, which grow with the grid. Redraw is
   the larger part on tall grids: 1.2 s of large.md's 2 s.
2. **A Markdown frame signals three times but redraws once.** render-markdown calls `on.render` for three
   updates: its forced `Initial` on attach, `BufWinEnter`, and nvcat's `Preview`. All three run before the first
   scheduled `notify_ready`, so the first redraw does the work and the other two take about 0.1 ms
   (`ready_callbacks` in `--timings` shows the count). Notifying once per token would save almost nothing, and
   a signal sent between setting a new token and the resize would use up that token's only one. The cost was a
   forced `Preview` running every handler a second time, 72 ms of large.md's 583 ms; since 0.26.0 it is not
   forced, and `render_passes` in `--timings` is 1 plus one per resize.
3. **Query compilation dominates cuda.** `vim.treesitter.start` takes about 390 ms for cuda (its highlights
   query inherits cpp's and c's), against 1-10 ms for most languages; `--syntax regex` renders the same file
   in about 130 ms. nu, fennel and cue pay 30-40 ms the same way.
4. **Injected languages load during parsing.** astro's 5-line fixture spends about 140 ms in `parse` loading
   and compiling the TypeScript and CSS parsers and queries it injects; `parser load` covers only the root
   language. pug, sxhkdrc, just and hyprlang show the same pattern at a smaller scale.
5. **Startup is a fixed ~75 ms, half of it Python.** Python imports take about 40 ms (argparse and tomllib are
   the largest, 8-9 ms each under `-X importtime`), Neovim before the profile 8 ms, setup 15 ms (theme 4,
   render-markdown 5, icons 2-3, runtimepath 3). For the small files fzf previews mostly show, startup is
   about 60% of the time, which is the case for a persistent worker (TODO.md).
6. **Python's share is small.** Decoding redraw events and maintaining the grid is 7-80 ms, ANSI encoding up
   to 50 ms on 900 rows: under 10% of a complete render.
7. **Dispatch overhead is below the noise.** `nvcat-dispatch` minus `nvcat --all` ranges from -41 to
   +71 ms with no pattern; the detection itself is a bash `case`.
8. **Memory is modest.** Neovim peaks at 18-28 MiB for small files and about 60-70 MiB for 350-900-line
   Markdown, Python at 18-33 MiB.

## Render time per filetype

<!-- filetypes:start -->

Recorded 2026-11-01T01:37Z, version 0.10.1 (33cdf70-dirty), load 2.08, NVIM v0.13.0-dev-1915+gc5641b2bfb, 5 runs per command. 80 columns, medians from hyperfine; regenerate with `benchmarks/filetypes`. Fixture: the file in `tests/fixtures/<filetype>`; large: that file repeated. Overhead is dispatch minus complete on the fixture. Query is `vim.treesitter.start` (query compilation), parse is the synchronous parse or the regex syntax load, frames is render and redraw, all from one `--timings-json` run of the large file.

| Filetype | Engine | Fixture (ms) | Large lines | Large (ms) | Large regex (ms) | Large viewport (ms) | bat large (ms) | Dispatch overhead (ms) | Startup (ms) | Query (ms) | Parse (ms) | Frames (ms) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| markdown | render-markdown | 271 | 504 | 536 | 283 | 368 | 60 | -4 | 94 | 0 | 0 | 379 |
| helm | treesitter | 159 | 504 | 263 | 168 | 194 | 40 | 10 | 85 | 4 | 25 | 64 |
| htmldjango | treesitter | 159 | 500 | 277 | 269 | 191 | 17 | 9 | 83 | 2 | 8 | 62 |
| tmux | syntax | 134 | 500 | 214 | - | 139 | 12 | 45 | 92 | 0 | 10 | 29 |
| kitty | treesitter | 146 | 500 | 340 | 204 | 197 | 12 | -14 | 82 | 6 | 54 | 79 |
| hyprlang | treesitter | 217 | 504 | 383 | 181 | 229 | 14 | -3 | 86 | 1 | 45 | 146 |
| i3config | syntax | 123 | 500 | 235 | - | 203 | 19 | 17 | 91 | 0 | 4 | 15 |
| sxhkdrc | treesitter | 265 | 500 | 456 | 190 | 253 | 13 | -23 | 88 | 1 | 49 | 235 |
| zathurarc | syntax | 120 | 500 | 176 | - | 128 | 12 | 10 | 87 | 0 | 3 | 9 |
| neomuttrc | syntax | 170 | 500 | 223 | - | 162 | 13 | -13 | 81 | 0 | 13 | 38 |
| muttrc | syntax | 147 | 500 | 250 | - | 148 | 13 | -13 | 81 | 0 | 7 | 34 |
| rasi | treesitter | 134 | 500 | 197 | 184 | 147 | 14 | -4 | 83 | 2 | 2 | 17 |
| readline | treesitter | 146 | 504 | 238 | 188 | 139 | 13 | -9 | 96 | 1 | 6 | 66 |
| udevrules | treesitter | 135 | 500 | 389 | 235 | 203 | 16 | 2 | 84 | 2 | 16 | 162 |
| xdefaults | syntax | 157 | 500 | 182 | - | 128 | 13 | 4 | 97 | 0 | 3 | 10 |
| xcompose | treesitter | 120 | 501 | 302 | 203 | 158 | 13 | 8 | 85 | 1 | 9 | 116 |
| systemd | syntax | 131 | 504 | 176 | - | 138 | 14 | 8 | 84 | 0 | 3 | 6 |
| just | treesitter | 247 | 504 | 386 | 213 | 225 | 13 | -28 | 80 | 2 | 43 | 159 |
| kdl | treesitter | 135 | 504 | 247 | 184 | 143 | 12 | 8 | 83 | 4 | 8 | 66 |
| json5 | treesitter | 149 | 504 | 240 | 179 | 143 | 12 | -17 | 85 | 1 | 5 | 61 |
| hjson | treesitter | 131 | 504 | 305 | 227 | 158 | 15 | 43 | 109 | 1 | 5 | 53 |
| gotmpl | treesitter | 160 | 500 | 385 | 185 | 163 | 13 | 9 | 96 | 4 | 14 | 185 |
| prisma | treesitter | 125 | 500 | 288 | 170 | 145 | 14 | 18 | 92 | 2 | 6 | 92 |
| astro | treesitter | 481 | 500 | 728 | 574 | 509 | 12 | 22 | 79 | 4 | 145 | 237 |
| mermaid | treesitter | 129 | 500 | 265 | 183 | 186 | 19 | 11 | 81 | 2 | 12 | 83 |
| meson | treesitter | 157 | 501 | 303 | 172 | 172 | 15 | -21 | 83 | 3 | 10 | 128 |
| nu | treesitter | 178 | 500 | 305 | 240 | 198 | 13 | -18 | 82 | 31 | 21 | 91 |
| gleam | treesitter | 150 | 504 | 245 | 207 | 156 | 12 | -11 | 97 | 10 | 7 | 67 |
| fennel | treesitter | 167 | 500 | 249 | 109 | 118 | 9 | -54 | 50 | 27 | 6 | 103 |
| cuda | treesitter | 354 | 500 | 429 | 133 | 356 | 8 | -1 | 51 | 266 | 9 | 56 |
| po | treesitter | 82 | 504 | 150 | 112 | 84 | 8 | -2 | 55 | 1 | 3 | 32 |
| pug | treesitter | 166 | 504 | 310 | 107 | 183 | 8 | -5 | 58 | 4 | 50 | 163 |
| ledger | treesitter | 85 | 500 | 162 | 106 | 92 | 9 | -4 | 59 | 1 | 8 | 59 |
| beancount | treesitter | 81 | 500 | 151 | 118 | 100 | 8 | 7 | 53 | 1 | 4 | 42 |
| dts | treesitter | 81 | 504 | 152 | 132 | 99 | 8 | 2 | 51 | 2 | 3 | 35 |
| ebnf | treesitter | 87 | 500 | 180 | 118 | 96 | 8 | -7 | 51 | 1 | 4 | 71 |
| cue | treesitter | 99 | 504 | 192 | 112 | 114 | 8 | 11 | 54 | 21 | 4 | 41 |
| dhall | treesitter | 81 | 501 | 145 | 117 | 98 | 8 | 3 | 56 | 3 | 16 | 22 |
| handlebars | treesitter | 110 | 504 | 180 | 154 | 116 | 8 | 1 | 63 | 2 | 5 | 58 |
| conf | syntax | 84 | 501 | 110 | - | 79 | 8 | 1 | 53 | 0 | 2 | 4 |

<!-- filetypes:end -->

## Against the Markdown-only release

v0.1.0 (mdpreview, Markdown only) against 0.15.0, measured 2026-11-03 at a load of 1.3-1.7 with the same
Neovim, parsers, theme and render-markdown. 100 columns; milliseconds, 40 interleaved runs per command
(minimum and median); a viewport is `--lines 40`, complete output `--all`.

| Document | Mode | v0.1.0 min / median | 0.15.0 min / median |
|---|---|---:|---:|
| 3-line Markdown | viewport | 82 / 111 | 98 / 134 |
| 3-line Markdown | complete | 99 / 109 | 116 / 128 |
| benchmarks/small.md | viewport | 236 / 265 | 254 / 294 |
| benchmarks/small.md | complete | 264 / 326 | 269 / 319 |

On larger documents 0.15.0 is 2-4 times faster (hyperfine medians, 7 runs): medium.md complete 1370 against
662, large.md complete 4649 against 1072, large.md viewport 1427 against 412. Peak memory is the same within
2 MiB (Neovim 17 against 19 MiB on the 3-line file, 65 against 66 MiB on large.md).

Support for other filetypes costs Markdown 16-23 ms of fixed startup, all of it in Python: Neovim's own run
(spawn to exit, traced) is 76-79 ms in both. The parts: compiling the 1,010-line `nvcat` script, which Python
does on every start because a script gets no `.pyc` (7 ms against 2 ms for v0.1.0's 319 lines);
importing tomllib and reading the config (4 ms); json and the filetype tables (2-3 ms). The filetype
detection itself is under 2 ms. None of this is per-filetype work; the config file and the larger CLI would
cost the same in a Markdown-only nvcat.

## Tree-sitter highlighter index

For each drawn line, Neovim's Tree-sitter highlighter (`on_range_impl` in
`runtime/lua/vim/treesitter/highlighter.lua`, 0.12 and later) walks every highlight state in the window, one
per tree. Markdown injects a tree per inline span and per code block, so a 900-line table document has about
2,650 states, and counting the visits on `large.md` showed 0.4% of them touch the line being drawn. This walk
was most of the redraw time on large documents.

`index_highlighter` in `profile.lua` builds, per list of states, the rows each tree covers and the trees in
start order, and narrows the list each call sees to the trees on its rows plus the next tree to start. The
states keep their order, so extmark priorities and the output are unchanged; `tests/highlighter.bats`
compares the output with the index on and off. One behavior differs: the stock loop counts trees above the
line toward the skip-ahead position it returns, so that position is behind the line and Neovim calls again for
the next line. Narrowed, it is the next capture or tree start, so Neovim makes fewer calls.

The upstream fix is the same index inside Neovim ([neovim#42675](https://github.com/neovim/neovim/issues/42675)).
Until then the patch depends on private internals: it checks each one, stays off when one is missing, and
reports the reason as `highlight_index` in `--timings`. Rerun `benchmarks/highlighter` after a Neovim upgrade.

<!-- highlighter:start -->

Recorded 2026-11-03T16:11Z by `benchmarks/highlighter` (nvcat 0.15.0, 49a798e-dirty), NVIM v0.13.0-dev-1915+gc5641b2bfb, load 4.16. Complete renders at 100 columns, medians of 3 runs per mode, the modes alternating. Milliseconds; on_range is the time inside Neovim's per-range highlighter callbacks.

| Document | Lines | Highlight states | on_range calls, stock / indexed | on_range, stock | on_range, indexed | Render, stock | Render, indexed | Change |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| benchmarks/medium.md | 353 | 309 | 352 / 286 | 126 | 25 | 727 | 542 | -25% |
| benchmarks/large.md | 888 | 707 | 887 / 716 | 603 | 41 | 1397 | 646 | -54% |
| benchmarks/code.md | 546 | 125 | 545 / 504 | 79 | 30 | 523 | 495 | -5% |
| 600-row table (generated) | 604 | 2,406 | 603 / 603 | 1750 | 64 | 2336 | 634 | -73% |

<!-- highlighter:end -->
