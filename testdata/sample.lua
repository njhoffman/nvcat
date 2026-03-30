local M = {}

--- Greet someone by name
---@param name string
---@return string
function M.greet(name)
    return "Hello, " .. name .. "!"
end

return M
