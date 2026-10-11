-- :checkhealth packcount
-- https://github.com/rafi/packcount.nvim

local M = {}

function M.check()
	local health = vim.health
	local Config = require('packcount.config')
	local packcount = require('packcount')

	health.start('Requirements')
	if packcount.can_check then
		health.ok('Neovim 0.13+: vim.pack can fetch and report `rev_to`')
	else
		health.error('Neovim 0.13+ required: vim.pack.get() cannot check here')
	end
	if pcall(require, 'vim.async') then
		health.ok('vim.async is available')
	else
		health.error('vim.async is missing; update to a newer Neovim 0.13 build')
	end
	if vim.fn.executable('git') == 1 then
		health.ok('git is installed')
	else
		health.error('git not found in $PATH')
	end

	health.start('Configuration')
	local cfg = Config.get()
	if Config.error then
		health.error(Config.error, 'Fix vim.g.packcount; defaults are in use')
	else
		health.ok('vim.g.packcount is valid')
	end
	for _, key in ipairs(Config.unknown()) do
		health.warn(('Unknown option vim.g.packcount.%s'):format(key))
	end
	health.info(
		('Checks every %d s, child timeout %d ms'):format(
			cfg.frequency,
			cfg.timeout
		)
	)

	health.start('State')
	local dir = vim.fs.dirname(cfg.state_path)
	if vim.fn.isdirectory(dir) == 0 or vim.fn.filewritable(dir) == 2 then
		health.ok('State file: ' .. cfg.state_path)
	else
		health.warn(
			'State dir not writable: ' .. dir,
			'Every Neovim instance will fetch on its own schedule'
		)
	end
	if packcount.running() then
		health.ok('Check loop is running')
	elseif cfg.autostart then
		health.info('Check loop not running (starts once a UI attaches)')
	else
		health.info('Check loop not running (autostart = false)')
	end
	if packcount.last_error then
		health.warn('Last check failed: ' .. packcount.last_error)
	end
	health.info(('%d plugin(s) with pending updates'):format(packcount.count()))
end

return M
