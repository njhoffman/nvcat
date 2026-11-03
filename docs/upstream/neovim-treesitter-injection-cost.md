# Draft Neovim issue: Tree-sitter highlighting cost grows with lines x injected trees

Status: not filed yet (`gh` was not authenticated). File at https://github.com/neovim/neovim/issues after
searching for duplicates.

## Title

treesitter: per-line highlighter work scales with the number of injected trees (large Markdown tables)

## Problem

Markdown injects one `markdown_inline` tree per paragraph and per `pipe_table_cell`, so a 600-row, 4-column
table produces 2,405 trees. Two paths in `runtime/lua/vim/treesitter/highlighter.lua` do work proportional to
the number of trees for every screen line:

1. `conceal_lines`: the bundled `queries/markdown/highlights.scm` sets `conceal_lines` on fenced code block
   delimiters and info strings. That enables `TSHighlighter._on_conceal_line`, which for each line calls
   `tree:parse({row, row + 1})`, `prepare_highlight_states(row, row)` and `on_range_impl`, all of which visit
   every tree. `nvim_win_text_height()` therefore grows roughly quadratically with table size.
2. Redraw: `on_range_impl` runs `for_each_highlight_state` over all trees for each drawn line, checking
   `Range.intercepts` against each tree root (line ~374 in this build). Combined injections avoid the tree
   count but `included_ranges(true)` is rebuilt per call and walked per capture (lines ~391 and ~430), so the
   cost moves rather than disappears.

## Reproduction

`nvim --clean`, NVIM v0.13.0-dev-1915+gc5641b2bfb, Linux x86-64. Generate a table with N rows:

```sh
n=600
{ echo '| a | b | c | d |'; echo '|---|---|---|---|'
  for i in $(seq 1 $n); do echo "| \`f$i\` | \`.e$i\`, x | \`p\` | y |"; done; } > table$n.md
nvim --clean -l measure-text-height.lua table$n.md                    # conceal_lines path
NO_CONCEAL_LINES=1 nvim --clean -l measure-text-height.lua table$n.md # same, query without conceal_lines
OUT=out.txt nvim --clean -S measure-redraw.lua table$n.md             # run in a terminal with ~300 rows
```

Scripts: [measure-text-height.lua](measure-text-height.lua), [measure-redraw.lua](measure-redraw.lua).

## Measurements

`nvim_win_text_height(0, {})`, headless, `conceallevel=2`:

| Table rows | Injected trees | Stock query | Without `conceal_lines` |
|---|---|---|---|
| 150 | 605 | 113 ms | 0 ms |
| 300 | 1,205 | 337 ms | 0 ms |
| 600 | 2,405 | 1,978 ms | 0 ms |

`redraw!` of a 300-row screen (average of 3), with or without `conceal_lines`:

| Table rows | Injected trees | `redraw!` |
|---|---|---|
| 150 | 605 | 174 ms |
| 300 | 1,205 | 860 ms |
| 600 | 2,405 | 746 ms (only the first 300 rows drawn) |

## Expected

Per-line work proportional to the trees that intersect the line, e.g. an interval index over tree root ranges
built once per `on_win`, and `_on_conceal_line` limited to trees containing the row.

## Prototype

nvcat patches this at runtime (`index_highlighter` in nvcat's `profile.lua`): per list of highlight states it
indexes the rows each tree root covers, and `on_range_impl` sees only the states on the range's rows plus the
next tree to start, in their original order. Output is byte-identical with and without the patch on every
document tried. A side effect: the stock loop includes trees that end above the range when it computes the
skip-ahead position, so the position it returns is behind the range and the provider is called again for
the next line; with the narrowed list the position is the next capture or tree start, and there are fewer
`on_range` calls (352 to 286 on a 353-line document).

Measured with nvcat's `benchmarks/highlighter` (complete renders at 100 columns through an embedded Neovim with
render-markdown.nvim, NVIM v0.13.0-dev-1915+gc5641b2bfb); the full table is in nvcat's docs/PERFORMANCE.md:

| Document | Lines | Highlight states | on_range calls, stock / indexed | on_range, stock | on_range, indexed | Render, stock | Render, indexed | Change |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| benchmarks/medium.md | 353 | 309 | 352 / 286 | 126 | 25 | 727 | 542 | -25% |
| benchmarks/large.md | 888 | 707 | 887 / 716 | 603 | 41 | 1397 | 646 | -54% |
| benchmarks/code.md | 546 | 125 | 545 / 504 | 79 | 30 | 523 | 495 | -5% |
| 600-row table (generated) | 604 | 2,406 | 603 / 603 | 1750 | 64 | 2336 | 634 | -73% |

## Context

Found while rendering Markdown to ANSI through an embedded Neovim with render-markdown.nvim
(https://github.com/njhoffman/nvcat); a 1,000-row document with large tables did not render within 120 s.
