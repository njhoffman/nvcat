-- A theme for tests that check highlighting happened: every standard group gets its own color, and comments are
-- italic. Neovim's default theme leaves most groups at the default foreground and a user's theme is anyone's, so
-- counting colors under either measures the theme.
local groups = {
  "Comment", "Constant", "String", "Character", "Number", "Boolean", "Float", "Identifier", "Function", "Statement",
  "Conditional", "Repeat", "Label", "Operator", "Keyword", "Exception", "PreProc", "Include", "Define", "Macro",
  "PreCondit", "Type", "StorageClass", "Structure", "Typedef", "Special", "SpecialChar", "Tag", "Delimiter",
  "SpecialComment", "Debug", "Underlined", "Error", "Todo", "Title", "Directory",
}

return {
  apply = function()
    vim.api.nvim_set_hl(0, "Normal", { fg = "#101010" })
    for index, name in ipairs(groups) do
      vim.api.nvim_set_hl(0, name, {
        fg = string.format("#%02x%02x%02x", 40 + index * 5, 220 - index * 5, 100 + index),
        italic = name == "Comment",
      })
    end
  end,
}
