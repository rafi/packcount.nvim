-- packcount.nvim configuration: defaults merged with `vim.g.packcount`.
-- https://github.com/rafi/packcount.nvim

---@class packcount.Config
---@field autostart boolean Run the check loop once a UI attaches.
---@field frequency number Seconds between online checks (git fetch), shared by all Neovim instances.
---@field timeout number Milliseconds a check may run before it is killed.
---@field state_path string JSON file holding the time of the last online check.
---@field icon string Prefix of the statusline text `updates()` returns.

---User options; every field is optional.
---@class (partial) packcount.Opts: packcount.Config

---@type packcount.Opts?
vim.g.packcount = vim.g.packcount

local M = {}

---@type packcount.Config
M.defaults = {
	autostart = true,
	frequency = 3600,
	timeout = 150000,
	state_path = vim.fs.joinpath(vim.fn.stdpath('state'), 'packcount.json'),
	-- Nerd Font "package" glyph (nf-oct-package).
	icon = '\239\146\135 ',
}

-- Message of the last invalid `vim.g.packcount`, for :checkhealth.
---@type string?
M.error = nil

local resolved ---@type packcount.Config?

---@param value any
---@return boolean
local function positive(value)
	return type(value) == 'number' and value > 0
end

-- Checks the types of a merged config. Returns false and a message naming
-- the field, e.g. `vim.g.packcount.frequency: expected positive number`.
---@param cfg table
---@return boolean ok
---@return string? err
function M.validate(cfg)
	local ok, err = pcall(function()
		vim.validate('autostart', cfg.autostart, 'boolean')
		vim.validate('frequency', cfg.frequency, positive, 'positive number')
		vim.validate('timeout', cfg.timeout, positive, 'positive number')
		vim.validate('state_path', cfg.state_path, 'string')
		vim.validate('icon', cfg.icon, 'string')
	end)
	if ok then
		return true
	end
	-- Drop the "file:line: " prefix error() may add.
	local msg = tostring(err):gsub('^[^\n]-:%d+: ', '')
	return false, 'vim.g.packcount.' .. msg
end

-- Keys of `vim.g.packcount` that packcount doesn't know (typos).
---@return string[]
function M.unknown()
	local user = vim.g.packcount
	if type(user) ~= 'table' then
		return {}
	end
	local ret = {} ---@type string[]
	for key in pairs(user) do
		if M.defaults[key] == nil then
			ret[#ret + 1] = tostring(key)
		end
	end
	table.sort(ret)
	return ret
end

-- Merges `vim.g.packcount` over the defaults. An invalid value is reported
-- once and replaced by the defaults, so a typo can't break the statusline.
---@return packcount.Config
local function resolve()
	local user = vim.g.packcount
	local cfg = vim.deepcopy(M.defaults)
	local ok, err = true, nil ---@type boolean, string?
	if type(user) == 'table' then
		cfg = vim.tbl_deep_extend('force', cfg, user)
		ok, err = M.validate(cfg)
	elseif user ~= nil then
		ok, err = false, 'vim.g.packcount: expected table, got ' .. type(user)
	end
	M.error = err
	if not ok then
		vim.notify(
			('packcount: %s; using defaults'):format(err),
			vim.log.levels.ERROR
		)
		return vim.deepcopy(M.defaults)
	end
	return cfg
end

-- The resolved config, read on first use so `vim.g.packcount` can be set
-- anywhere, even after plugins load.
---@return packcount.Config
function M.get()
	resolved = resolved or resolve()
	return resolved
end

return M
