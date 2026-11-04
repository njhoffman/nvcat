-- Draft-issue repro. Usage: [NO_CONCEAL_LINES=1] nvim --clean -l measure.lua FILE
local file = arg[1]
if (os.getenv("NO_CONCEAL_LINES") or "") ~= "" then
  local src = {}
  for _, f in ipairs(vim.treesitter.query.get_files("markdown", "highlights")) do
    src[#src + 1] = io.open(f):read("*a"):gsub('%(#set! conceal_lines ""%)', "")
  end
  vim.treesitter.query.set("markdown", "highlights", table.concat(src, "\n"))
end
vim.cmd.edit(file)
vim.treesitter.start(0, "markdown")
local parser = vim.treesitter.get_parser(0)
parser:parse(true)
local trees = 0
parser:for_each_tree(function() trees = trees + 1 end)
vim.wo.conceallevel = 2
local t0 = vim.uv.hrtime()
local height = vim.api.nvim_win_text_height(0, {}).all
local ms = (vim.uv.hrtime() - t0) / 1e6
io.write(string.format("%s lines=%d trees=%d text_height=%d %.0f ms\n", file, vim.api.nvim_buf_line_count(0), trees, height, ms))
