-- packcount.nvim: count vim.pack plugins with pending updates.
-- https://github.com/rafi/packcount.nvim

-- vim.pack.get() blocks while it fetches, so checks run in a separate
-- headless Neovim (child.lua) that returns the names of plugins with
-- updates. The loop in M.start() decides when checks run.

local Config = require('packcount.config')

---@class packcount
local M = {}

-- Whether vim.pack can check for updates. `offline = false` and `rev_to` of
-- vim.pack.get() need Neovim 0.13. 0.12 ignores both, so checks find nothing.
M.can_check = vim.fn.has('nvim-0.13') == 1

-- Message of the last failed check, nil after a successful one. Shown by
-- `:Packcount status` and `:checkhealth packcount`.
---@type string?
M.last_error = nil

-- Names of plugins with a pending update.
local pending = {} ---@type table<string, true>

-- Running loop, refresh and check tasks, so M.stop() can close them.
local tasks = {} ---@type table<vim.async.Task, true>

local lock ---@type vim.async.Semaphore?
local refreshing, dirty = false, false
local loop ---@type vim.async.Task?
local refresher ---@type vim.async.Task?

local child_path = vim.fs.joinpath(
	vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)),
	'child.lua'
)

-- Whether checks can run: Neovim 0.13, vim.async (some 0.13-dev builds have
-- `rev_to` but not vim.async) and git.
---@return boolean
function M.supported()
	return M.can_check
		and pcall(require, 'vim.async')
		and vim.fn.executable('git') == 1
end

-- Whether the check loop runs (M.start() was called and not stopped).
---@return boolean
function M.running()
	return loop ~= nil
end

-- Keeps `task` until it ends so M.stop() can close it, and reports an
-- unexpected failure once. Closing a task ends it with 'closed', which is
-- not reported (raise_on_error() would print a traceback on every exit).
---@param task vim.async.Task
---@return vim.async.Task
local function track(task)
	tasks[task] = true
	task:on_complete(function(err)
		tasks[task] = nil
		if err ~= nil and err ~= 'closed' then
			vim.schedule(function()
				vim.notify('packcount: ' .. tostring(err), vim.log.levels.ERROR)
			end)
		end
	end)
	return task
end

-- Number of plugins with a pending update.
---@return integer
function M.count()
	return vim.tbl_count(pending)
end

-- Names of plugins with a pending update, sorted.
---@return string[]
function M.names()
	local ret = vim.tbl_keys(pending)
	table.sort(ret)
	return ret
end

-- Whether any update is pending. Works as a lualine `cond`.
---@return boolean
function M.has_updates()
	return M.count() > 0
end

-- Statusline text: `icon` and the count, or '' when nothing is pending.
-- Ignores its arguments, so lualine can use it as a component.
---@return string
function M.updates()
	local count = M.count()
	if count == 0 then
		return ''
	end
	return Config.get().icon .. count
end

-- Sets the pending names. `unknown` plugins keep their previous status,
-- since a missing `rev_to` (failed fetch, unresolved version) doesn't mean
-- up to date. Fires `User PackcountChanged`.
---@param names string[]
---@param unknown string[]
local function apply(names, unknown)
	local next_pending = {} ---@type table<string, true>
	for _, name in ipairs(names) do
		next_pending[name] = true
	end
	for _, name in ipairs(unknown) do
		next_pending[name] = pending[name]
	end
	pending = next_pending
	vim.api.nvim_exec_autocmds('User', {
		pattern = 'PackcountChanged',
		modeline = false,
		data = { count = M.count() },
	})
end

-- Recounts from `vim.pack.get()` data the caller already has, without
-- starting another Neovim. Pass every plugin.
---@param plugins vim.pack.PlugData[]
function M.set(plugins)
	local names, unknown = {}, {} ---@type string[], string[]
	for _, plugin in ipairs(plugins) do
		if plugin.rev_to == nil then
			unknown[#unknown + 1] = plugin.spec.name
		elseif plugin.rev ~= plugin.rev_to then
			names[#names + 1] = plugin.spec.name
		end
	end
	apply(names, unknown)
end

-- Command line for the background Neovim. `--clean` skips the user's
-- config. The lockfile and plugin dir come from the environment, plus
-- 'packlockfile' when this Neovim has that option.
---@param offline boolean
---@return string[]
local function child_cmd(offline)
	local cmd = { vim.v.progpath, '--clean', '--headless' }
	if vim.fn.exists('+packlockfile') == 1 then
		local lockfile = vim.fn.fnameescape(vim.go.packlockfile)
		vim.list_extend(cmd, { '--cmd', 'set packlockfile=' .. lockfile })
	end
	vim.list_extend(cmd, { '-l', child_path, offline and 'offline' or 'online' })
	return cmd
end

-- Runs `cmd` with vim.system() in a task. A vim.SystemObj has no close(), so
-- vim.async gets a handle that kills the process, and stopping ends the
-- background Neovim too. vim.system() calls back in a fast event where most
-- API calls fail, so this resumes on the main loop first.
---@async
---@param cmd string[]
---@return vim.SystemCompleted
local function system(cmd)
	local opts = { text = true, timeout = Config.get().timeout }
	local result = vim.async.await(function(done)
		local proc = vim.system(cmd, opts, done)
		return {
			close = function(_, callback)
				if not proc:is_closing() then
					proc:kill('sigterm')
				end
				if callback then
					callback()
				end
			end,
		}
	end)
	vim.async.await(1, vim.schedule)
	return result
end

-- Reads the result line child.lua prints last. Raises a message for
-- `M.last_error` when it failed, timed out (exit code 124) or printed none.
---@param res vim.SystemCompleted
---@return { pending?: string[], unknown?: string[] }
local function decode(res)
	if res.code == 124 then
		error(('timed out after %d ms'):format(Config.get().timeout), 0)
	elseif res.code ~= 0 then
		local stderr = vim.trim(res.stderr or '')
		error(('exited with %d: %s'):format(res.code, stderr), 0)
	end
	local lines = vim.split(vim.trim(res.stdout or ''), '\n')
	local ok, data = pcall(vim.json.decode, lines[#lines])
	if not ok or type(data) ~= 'table' then
		error('invalid child output: ' .. vim.trim(res.stdout or ''), 0)
	end
	if data.error then
		error(tostring(data.error), 0)
	end
	return data
end

-- Runs child.lua once and applies the result. `opts.offline = false` fetches
-- remotes first (default: offline). Returns the task, or nil when checks
-- can't run. One check runs at a time, others wait. A failed check keeps
-- the count and sets `M.last_error`.
---@param opts? { offline?: boolean }
---@return vim.async.Task?
function M.check(opts)
	opts = opts or {}
	local offline = opts.offline ~= false
	if not M.supported() then
		return nil
	end
	local async = vim.async
	lock = lock or async.semaphore(1)
	return track(async.run('packcount.check', function()
		lock:with(function()
			local ok, result = async.pawait(async.run(function()
				return decode(system(child_cmd(offline)))
			end))
			if ok then
				M.last_error = nil
				apply(result.pending or {}, result.unknown or {})
			else
				M.last_error = tostring(result)
			end
		end)
	end))
end

-- Offline recount, e.g. after PackChanged. One worker yields to the main
-- loop before each recount, so the events of a bulk update (one per plugin)
-- cause one recount, and events during a recount at most one more.
-- Detached, because PackChanged can fire inside vim.pack's own tasks.
function M.refresh()
	if not M.supported() then
		return
	end
	dirty = true
	if refreshing then
		return
	end
	refreshing = true
	local async = vim.async
	-- Clear the flag on completion, since a crashed worker never reaches the
	-- end. Skip it if stop() and a new refresh() replaced the worker.
	local worker = track(async
		.run('packcount.refresh', function()
			while dirty do
				async.await(1, vim.schedule)
				dirty = false
				async.await(M.check({ offline = true }))
			end
		end)
		:detach())
	refresher = worker
	worker:on_complete(function()
		if refresher == worker then
			refresher, refreshing = nil, false
		end
	end)
end

-- Reads `last_check` (os.time() seconds) from the state file. Missing,
-- invalid or future values read as 0, so a wrong clock at write time can't
-- stall checks.
---@return integer
local function read_last_check()
	local ok, data = pcall(function()
		local text = table.concat(vim.fn.readfile(Config.get().state_path), '\n')
		return vim.json.decode(text)
	end)
	local last = ok and type(data) == 'table' and tonumber(data.last_check) or 0
	return last <= os.time() and last or 0
end

-- Writes `last_check` to the state file, ignoring failures.
---@param time integer
local function write_last_check(time)
	pcall(function()
		local path = Config.get().state_path
		vim.fn.mkdir(vim.fs.dirname(path), 'p')
		vim.fn.writefile({ vim.json.encode({ last_check = time }) }, path)
	end)
end

-- The check loop. Fetches when `frequency` seconds passed since the last
-- fetch by any instance, writing the time first as lazy.nvim does.
-- Otherwise recounts offline when that time changed (first pass or another
-- instance fetched), then sleeps until the next fetch. `memory_last` stands
-- in for an unwritable state file, so the loop doesn't fetch repeatedly.
---@async
local function run_loop()
	local async = vim.async
	local seen, memory_last = nil, 0
	while true do
		local last = math.max(read_last_check(), memory_last)
		local wait = last + Config.get().frequency - os.time()
		if wait <= 0 then
			memory_last = os.time()
			write_last_check(memory_last)
			seen = memory_last
			async.pawait(M.check({ offline = false }))
		else
			if last ~= seen then
				async.pawait(M.check({ offline = true }))
				seen = last
			end
			async.sleep(wait * 1000)
		end
	end
end

-- Starts the check loop and PackChanged recounts. Does nothing if started
-- or unsupported.
function M.start()
	if loop or not M.supported() then
		return
	end
	local group = vim.api.nvim_create_augroup('packcount', {})
	vim.api.nvim_create_autocmd('PackChanged', {
		group = group,
		desc = 'Recount pending plugin updates',
		callback = function()
			M.refresh()
		end,
	})
	vim.api.nvim_create_autocmd('VimLeavePre', {
		group = group,
		desc = 'Stop plugin update checks',
		callback = function()
			M.stop()
		end,
	})
	local task = track(vim.async.run('packcount', run_loop):detach())
	loop = task
	-- A crashed loop must not block a later start().
	task:on_complete(function()
		if loop == task then
			loop = nil
		end
	end)
end

-- Stops the loop, refreshes and checks, and kills a running check.
function M.stop()
	pcall(vim.api.nvim_del_augroup_by_name, 'packcount')
	for task in pairs(tasks) do
		task:close()
	end
	tasks, loop, refresher, refreshing, dirty = {}, nil, nil, false, false
end

return M
