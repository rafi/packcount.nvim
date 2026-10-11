-- packcount.nvim: defines :Packcount and starts the check loop once a UI
-- attaches. Loads nothing until used.
-- https://github.com/rafi/packcount.nvim

if vim.g.loaded_packcount then
	return
end
vim.g.loaded_packcount = true

-- Reports the count and the last error with vim.notify.
local function notify_status()
	local packcount = require('packcount')
	local lines = {
		('%d plugin(s) with pending updates'):format(packcount.count()),
	}
	local names = packcount.names()
	if #names > 0 then
		lines[#lines + 1] = table.concat(names, ', ')
	end
	if packcount.last_error then
		lines[#lines + 1] = 'Last check failed: ' .. packcount.last_error
	end
	vim.notify(table.concat(lines, '\n'))
end

-- Runs a check (online fetch or offline recount) and reports when done.
---@param offline boolean
local function check(offline)
	local task = require('packcount').check({ offline = offline })
	if not task then
		vim.notify(
			'packcount: checks need Neovim 0.13+ and git, see :checkhealth packcount',
			vim.log.levels.WARN
		)
		return
	end
	task:on_complete(vim.schedule_wrap(notify_status))
end

---@class packcount.Subcommand
---@field impl fun()
---@field desc string

---@type table<string, packcount.Subcommand>
local subcommands = {
	check = {
		desc = 'Fetch every plugin and recount',
		impl = function()
			check(false)
		end,
	},
	recount = {
		desc = 'Recount from the last fetch',
		impl = function()
			check(true)
		end,
	},
	status = { desc = 'Show the count', impl = notify_status },
	start = {
		desc = 'Start the background check loop',
		impl = function()
			require('packcount').start()
		end,
	},
	stop = {
		desc = 'Stop the background check loop',
		impl = function()
			require('packcount').stop()
		end,
	},
}

vim.api.nvim_create_user_command('Packcount', function(opts)
	local name = opts.fargs[1] or 'status'
	local sub = subcommands[name]
	if not sub then
		vim.notify('packcount: unknown subcommand ' .. name, vim.log.levels.ERROR)
		return
	end
	sub.impl()
end, {
	nargs = '?',
	desc = 'Pending vim.pack updates: check, recount, status, start, stop',
	complete = function(lead, line)
		-- Only the first argument has completions.
		if line:match('^%S+%s+%S+%s') then
			return {}
		end
		local names = vim.tbl_keys(subcommands)
		table.sort(names)
		return vim.tbl_filter(function(name)
			return vim.startswith(name, lead)
		end, names)
	end,
})

-- Starts the loop unless `vim.g.packcount.autostart` is false. Scheduled,
-- so a check never delays the first redraw.
local function autostart()
	vim.schedule(function()
		if require('packcount.config').get().autostart then
			require('packcount').start()
		end
	end)
end

-- UIEnter, not VimEnter, so headless runs (`nvim --headless +qa`, plugin
-- installers) never fetch. If a UI already attached (loaded on demand),
-- start now.
if vim.v.vim_did_enter == 1 and #vim.api.nvim_list_uis() > 0 then
	autostart()
else
	vim.api.nvim_create_autocmd('UIEnter', {
		group = vim.api.nvim_create_augroup('packcount.autostart', {}),
		once = true,
		desc = 'Start packcount update checks',
		callback = autostart,
	})
end
