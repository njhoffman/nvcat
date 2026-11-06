-- An example for the pager_init config key: smooth scrolling in nvcat's nvim pager, using Neovim's built-in
-- 'smoothscroll' plus a small timer. nvcat runs apply() after it sets its own keys, so these mappings win. Plugins are
-- not started in the pager: anything you use has to be loaded here, from lua_path or by adding to 'runtimepath'.
local function scroll(key, steps)
  local keys = vim.keycode(key)
  return function()
    local count = 0
    local timer = vim.uv.new_timer()
    timer:start(0, 12, vim.schedule_wrap(function()
      count = count + 1
      if count > steps then
        timer:close()
      else
        vim.cmd.normal({ keys, bang = true })
      end
    end))
  end
end

return {
  apply = function()
    vim.o.smoothscroll = true
    local page = math.max(1, vim.o.lines - 2)
    for lhs, action in pairs({
      ["<Space>"] = scroll("<C-e>", page),
      f = scroll("<C-e>", page),
      b = scroll("<C-y>", page),
      d = scroll("<C-e>", math.floor(page / 2)),
      u = scroll("<C-y>", math.floor(page / 2)),
    }) do
      vim.keymap.set("n", lhs, action, { buffer = true, nowait = true, silent = true })
    end
  end,
}
