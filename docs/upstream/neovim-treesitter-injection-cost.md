# Neovim issue: Tree-sitter redraw cost grows with lines x injected trees

Filed 2026-11-03 as https://github.com/neovim/neovim/issues/42675. Duplicate search that day: #39699 (open)
covers the `conceal_lines` / `_on_conceal_line` half of the original draft, so the issue is limited to the
redraw path and links it. #22426 is the general Tree-sitter performance tracking issue.

Scripts: [measure-redraw.lua](measure-redraw.lua) (inlined in the issue) and
[measure-text-height.lua](measure-text-height.lua) (the `conceal_lines` measurement, now #39699's subject).

## Title

treesitter: highlighter visits every injected tree for every drawn line (slow redraw of large Markdown tables)

## Body

### Problem

Markdown injects one `markdown_inline` tree per paragraph and per `pipe_table_cell`, so a 600-row, 4-column
table has 2,405 trees. For every drawn line, `on_range_impl` in `runtime/lua/vim/treesitter/highlighter.lua`
runs `for_each_highlight_state` over all of them and tests each tree root against the range, so a redraw
costs drawn lines x trees, whether or not the trees are anywhere near the screen.

This is separate from #39699 (`conceal_lines` making `_on_conceal_line` parse and walk every tree per line):
the redraw cost below is the same with `conceal_lines` removed from the query.

A second effect of the same loop: trees that end above the range still take part in computing the
skip-ahead position, so the position returned is behind the range and the provider is called again for the
next line.

### Steps to reproduce

```sh
n=600
{ echo '| a | b | c | d |'; echo '|---|---|---|---|'
  for i in $(seq 1 $n); do echo "| \`f$i\` | \`.e$i\`, x | \`p\` | y |"; done; } > table$n.md
# in a terminal with about 300 rows:
OUT=out.txt nvim --clean -S redraw.lua table$n.md
NO_CONCEAL_LINES=1 OUT=out.txt nvim --clean -S redraw.lua table$n.md
cat out.txt
```

`redraw.lua`:

```lua
if (os.getenv("NO_CONCEAL_LINES") or "") ~= "" then
  local src = {}
  for _, f in ipairs(vim.treesitter.query.get_files("markdown", "highlights")) do
    src[#src + 1] = io.open(f):read("*a"):gsub('%(#set! conceal_lines ""%)', "")
  end
  vim.treesitter.query.set("markdown", "highlights", table.concat(src, "\n"))
end
vim.treesitter.start(0, "markdown")
vim.wo.conceallevel = 2
vim.treesitter.get_parser(0):parse(true)
vim.cmd("redraw")
local t0 = vim.uv.hrtime()
for _ = 1, 3 do vim.cmd("redraw!") end
local f = io.open(os.getenv("OUT"), "a")
f:write(string.format("%s rows=%d conceal_lines=%s redraw!=%.0f ms (avg of 3)\n", vim.fn.expand("%"), vim.o.lines,
  (os.getenv("NO_CONCEAL_LINES") or "") ~= "" and "removed" or "stock", (vim.uv.hrtime() - t0) / 3e6))
f:close()
vim.cmd("qa!")
```

`redraw!` of a 300-row screen, average of 3:

| Table rows | Injected trees | Stock query | Without `conceal_lines` |
|---|---:|---:|---:|
| 150 | 605 | 242 ms | 299 ms |
| 300 | 1,205 | 992 ms | 966 ms |
| 600 | 2,405 | 983 ms | 1,279 ms |

(600 rows: only the first 300 are drawn. The machine was loaded, so the absolute times vary; the growth with
the tree count and the lack of difference between the two queries hold across runs.)

### Expected behavior

Per-line work proportional to the trees that intersect the line.

A prototype, applied at runtime by replacing `on_range_impl` (https://github.com/njhoffman/nvcat, `profile.lua`
`index_highlighter`): per list of highlight states, index the rows each tree root covers, and give
`on_range_impl` only the states on the range's rows plus the next tree to start, in their original order. The
output is byte-identical with and without it on every document tried, and the skip-ahead position becomes the
next capture or tree start, so there are fewer `on_range` calls. Complete renders at 100 columns through an
embedded Neovim with render-markdown.nvim:

| Document | Lines | Highlight states | on_range calls, stock / indexed | on_range ms, stock / indexed | Render ms, stock / indexed |
|---|---:|---:|---:|---:|---:|
| Markdown, 353 lines | 353 | 309 | 352 / 286 | 126 / 25 | 727 / 542 (-25%) |
| Markdown, 888 lines | 888 | 707 | 887 / 716 | 603 / 41 | 1397 / 646 (-54%) |
| Markdown with code fences | 546 | 125 | 545 / 504 | 79 / 30 | 523 / 495 (-5%) |
| 600-row table above | 604 | 2,406 | 603 / 603 | 1750 / 64 | 2336 / 634 (-73%) |

### Nvim version (nvim -v)

NVIM v0.13.0-dev-1915+gc5641b2bfb

### Vim (not Nvim) behaves the same?

N/A (Tree-sitter)

### Operating system/version

Linux 6.17, x86-64

### Terminal name/version

Any; measured with `nvim --clean` in a 300-row pty

### $TERM environment variable

xterm-256color

### Installation

Built from source
