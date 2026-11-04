-- Usage: [NO_CONCEAL_LINES=1] OUT=FILE nvim --clean -S measure-redraw.lua TABLE.md  (in a terminal with ~300 rows)
-- Appends the average time of three full redraws to $OUT.
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
