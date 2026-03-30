local function load_config()
	local joinpath = vim.fs.joinpath
	local config_dir = joinpath(vim.fn.fnamemodify(vim.fn.stdpath('config'), ':h'), 'nvcat')
	vim.opt.rtp:append(config_dir)
	if vim.fn.filereadable(joinpath(config_dir, 'init.lua')) == 1 then
		vim.cmd.source(joinpath(config_dir, 'init.lua'))
		return
	end
	if vim.fn.filereadable(joinpath(config_dir, 'init.vim')) == 1 then
		vim.cmd.source(joinpath(config_dir, 'init.vim'))
	end
end

load_config()

local _normal_bg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg

local function strip_normal_bg(hl)
	if _normal_bg and hl.bg == _normal_bg then
		hl.bg = nil
	end
	return hl
end

function NvcatNormalHasBg()
	return _normal_bg ~= nil
end

function NvcatGetHl(row, col)
	local captures = vim.treesitter.get_captures_at_pos(0, row, col)
	if #captures > 0 then
		local hl_name = '@' .. captures[#captures].capture
		return strip_normal_bg(vim.api.nvim_get_hl(0, { name = hl_name, link = false, create = false }))
	end
	local hl_id = vim.fn.synID(row + 1, col + 1, 1)
	if hl_id == 0 then
		return vim.empty_dict()
	end
	return strip_normal_bg(vim.api.nvim_get_hl(0, { id = hl_id, link = false, create = false }))
end
