-- packcount: child.lua against a local git repo, the module with
-- vim.system stubbed, the check loop, config validation and the
-- plugin/ entry point.

local H = { eq = MiniTest.expect.equality, expect = MiniTest.expect }

-- Plugin root, from this file's path.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local child_script = root .. '/lua/packcount/child.lua'

-- The real vim.system. Module cases replace vim.system with a stub; the
-- top-level post_case puts this back.
local system = vim.system

-- Per-case temp dir.
local tmp ---@type string

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			tmp = vim.fn.tempname()
			vim.fn.mkdir(tmp, 'p')
		end,
		post_case = function()
			vim.system = system
			vim.fn.delete(tmp, 'rf')
		end,
	},
})

-- child.lua ------------------------------------------------------------

-- Environment for a Neovim whose stdpaths live under `tmp`, so the test
-- plugin, its lockfile and its state never touch the sandbox.
---@return table<string, string>
local function scratch_env()
	return {
		XDG_CONFIG_HOME = tmp .. '/config',
		XDG_DATA_HOME = tmp .. '/data',
		XDG_STATE_HOME = tmp .. '/state',
		XDG_CACHE_HOME = tmp .. '/cache',
	}
end

-- Runs git in the test plugin's origin repo. Signing and hooks from the
-- user's git config are turned off, so commits can't prompt or fail.
---@param ... string
local function git(...)
	local cmd = {
		'git',
		'-C',
		tmp .. '/origin',
		'-c',
		'user.name=test',
		'-c',
		'user.email=test@example.com',
		'-c',
		'commit.gpgsign=false',
		'-c',
		'core.hooksPath=/dev/null',
		...,
	}
	local res = system(cmd, { text = true }):wait()
	assert(res.code == 0, res.stderr)
end

-- Runs a headless `nvim --clean` with `args` in the scratch environment.
---@param args string[]
---@return vim.SystemCompleted
local function scratch_nvim(args)
	local cmd = { vim.v.progpath, '--clean', '--headless' }
	vim.list_extend(cmd, args)
	return system(cmd, { env = scratch_env(), text = true }):wait(30000)
end

-- Runs child.lua the way the module does and decodes its last line.
---@param mode 'online'|'offline'
---@return table
local function run_child(mode)
	local res = scratch_nvim({ '-l', child_script, mode })
	H.eq(res.code, 0)
	local lines = vim.split(vim.trim(res.stdout), '\n')
	return vim.json.decode(lines[#lines])
end

-- Installs plugin `packcount-test` from a local origin repo at commit A into the
-- scratch environment, then adds commit B to the origin, so a fetch finds
-- one pending update.
local function install_test_plugin()
	vim.fn.mkdir(tmp .. '/origin', 'p')
	git('init', '-q', '-b', 'main')
	git('commit', '-q', '--allow-empty', '-m', 'A')
	local add = (
		"lua vim.pack.add({ { src = 'file://%s/origin', name = 'packcount-test' } },"
		.. ' { confirm = false })'
	):format(tmp)
	H.eq(scratch_nvim({ '-c', add, '-c', 'qa!' }).code, 0)
	git('commit', '-q', '--allow-empty', '-m', 'B')
end

-- The scratch environment's plugin dir and lockfile, as vim.pack uses them.
---@return string plug_dir, string lock_path
local function scratch_pack_paths()
	return tmp .. '/data/nvim/site/pack/core/opt',
		tmp .. '/config/nvim/nvim-pack-lock.json'
end

T['child.lua'] = MiniTest.new_set()

T['child.lua']['reports pending updates, also when the fetch fails'] = function()
	install_test_plugin()

	-- Not fetched yet: vim.pack only knows commit A.
	H.eq(run_child('offline'), { pending = {}, unknown = {} })
	-- Fetching finds commit B.
	H.eq(run_child('online'), { pending = { 'packcount-test' }, unknown = {} })
	-- Without its remote the fetch fails; the last fetch still counts.
	vim.fn.rename(tmp .. '/origin', tmp .. '/origin.gone')
	H.eq(run_child('online'), { pending = { 'packcount-test' }, unknown = {} })
end

-- vim.pack.get() first syncs the lockfile with the plugin dir. A background
-- count must not install the plugin a freshly pulled lockfile lists.
T['child.lua']['installs nothing the lockfile lists but the disk lacks'] = function()
	install_test_plugin()
	local plug_dir, lock_path = scratch_pack_paths()
	local lock = vim.json.decode(table.concat(vim.fn.readfile(lock_path), '\n'))
	lock.plugins.ghost = vim.deepcopy(lock.plugins['packcount-test'])
	vim.fn.writefile({ vim.json.encode(lock) }, lock_path)
	local before = vim.fn.readfile(lock_path)

	local result = run_child('offline')
	H.eq(vim.fn.isdirectory(plug_dir .. '/ghost'), 0)
	H.eq(vim.fn.readfile(lock_path), before)
	-- The count can't be trusted, so the check reports why instead.
	H.expect.no_equality((result.error or ''):find('ghost', 1, true), nil)
end

-- ... nor rewrite the git-tracked lockfile for a plugin dir it doesn't list.
T['child.lua']['leaves the lockfile alone for an unlisted plugin dir'] = function()
	install_test_plugin()
	local plug_dir, lock_path = scratch_pack_paths()
	local clone = system({
		'git',
		'-c',
		'core.hooksPath=/dev/null',
		'clone',
		'-q',
		tmp .. '/origin',
		plug_dir .. '/stray',
	}):wait()
	H.eq(clone.code, 0)
	local before = vim.fn.readfile(lock_path)

	local result = run_child('offline')
	H.eq(vim.fn.readfile(lock_path), before)
	H.expect.no_equality((result.error or ''):find('stray', 1, true), nil)
end

T['child.lua']['refuses to run inside an editor session'] = function()
	local res = scratch_nvim({
		'-c',
		("lua dofile('%s')"):format(child_script),
		'-c',
		'qa!',
	})
	local output = res.stderr .. res.stdout
	H.expect.no_equality(output:find('run with nvim -l', 1, true), nil)
end

-- The test runner is itself an `nvim -l` script, so `arg[0]` alone is not
-- proof that child.lua is the script being run.
T['child.lua']['refuses to run from another nvim -l script'] = function()
	local other = tmp .. '/other.lua'
	vim.fn.writefile({ ("dofile('%s')"):format(child_script) }, other)
	local res = scratch_nvim({ '-l', other })
	H.eq(res.code, 1)
	H.expect.no_equality(res.stderr:find('run with nvim -l', 1, true), nil)
end

-- Module ---------------------------------------------------------------

local M ---@type packcount

-- vim.system calls the stub received, oldest first.
---@type { cmd: string[], opts: table, killed: boolean, started: integer, ended?: integer }[]
local calls

-- Counts from `User PackcountChanged` events, oldest first.
local events ---@type integer[]

-- vim.notify messages, so reported errors can be asserted.
local notified ---@type string[]
local notify = vim.notify

-- Unloads packcount's modules, so the next require reads vim.g.packcount
-- again and starts with an empty count.
local function unload()
	package.loaded['packcount'] = nil
	package.loaded['packcount.config'] = nil
end

-- A fresh module per case, its state file under `tmp`, and recorders for
-- events and notifications.
local module_hooks = {
	pre_case = function()
		unload()
		vim.g.packcount = { state_path = tmp .. '/state/packcount.json' }
		M = require('packcount')
		calls, events, notified = {}, {}, {}
		vim.notify = function(msg)
			table.insert(notified, msg)
		end
		vim.api.nvim_create_autocmd('User', {
			group = vim.api.nvim_create_augroup('packcount.test', {}),
			pattern = 'PackcountChanged',
			callback = function(ev)
				table.insert(events, ev.data.count)
			end,
		})
	end,
	post_case = function()
		M.stop()
		vim.g.packcount = nil
		vim.notify = notify
		pcall(vim.api.nvim_del_augroup_by_name, 'packcount.test')
	end,
}

-- Replaces vim.system with a fake child. `reply(cmd)` returns the
-- vim.SystemCompleted to report after `delay` ms (default 20), or nil for a
-- child that never exits. Every call is recorded in `calls`.
---@param reply fun(cmd: string[]): vim.SystemCompleted?
---@param delay? integer
local function stub(reply, delay)
	vim.system = function(cmd, opts, on_exit)
		local call = {
			cmd = cmd,
			opts = opts,
			killed = false,
			started = vim.uv.now(),
		}
		table.insert(calls, call)
		local res = reply(cmd)
		if res then
			vim.defer_fn(function()
				call.ended = vim.uv.now()
				on_exit(res)
			end, delay or 20)
		end
		return {
			is_closing = function()
				return call.ended ~= nil or call.killed
			end,
			kill = function()
				call.killed = true
			end,
		}
	end
end

-- A fake child result with these pending and unknown plugin names.
---@param pending string[]
---@param unknown? string[]
---@return fun(): vim.SystemCompleted
local function reply_with(pending, unknown)
	return function()
		local line = vim.json.encode({ pending = pending, unknown = unknown or {} })
		return { code = 0, signal = 0, stdout = line .. '\n', stderr = '' }
	end
end

-- Last argument of call `i`: 'online' or 'offline'.
---@param i integer
---@return string
local function mode(i)
	return calls[i].cmd[#calls[i].cmd]
end

-- vim.pack.PlugData with only the fields the module reads.
---@param name string
---@param rev string
---@param rev_to? string
local function plug(name, rev, rev_to)
	return { spec = { name = name }, rev = rev, rev_to = rev_to }
end

T['check()'] = MiniTest.new_set({ hooks = module_hooks })

T['check()']['runs child.lua and counts pending plugins'] = function()
	stub(reply_with({ 'a', 'b' }))
	M.check({ offline = true }):wait(5000)
	local cmd = calls[1].cmd
	H.eq({ cmd[1], cmd[2], cmd[3] }, { vim.v.progpath, '--clean', '--headless' })
	H.eq({ cmd[#cmd - 2], cmd[#cmd] }, { '-l', 'offline' })
	H.eq(vim.fn.resolve(cmd[#cmd - 1]), vim.fn.resolve(child_script))
	H.eq(calls[1].opts.timeout, 150000)
	H.eq(M.count(), 2)
	H.eq(events, { 2 })
	H.eq(M.last_error, nil)
	M.check({ offline = false }):wait(5000)
	H.eq(mode(2), 'online')
end

T['check()']['checks offline when called without opts'] = function()
	stub(reply_with({ 'a' }))
	M.check():wait(5000)
	H.eq(mode(1), 'offline')
	H.eq(M.count(), 1)
end

T['check()']['passes packlockfile escaped'] = function()
	if vim.fn.exists('+packlockfile') == 0 then
		MiniTest.skip('this Neovim has no packlockfile option')
	end
	local saved = vim.go.packlockfile
	local path = tmp .. '/with space/lock.json'
	vim.go.packlockfile = path
	stub(reply_with({}))
	local ok, err = pcall(function()
		M.check({ offline = true }):wait(5000)
	end)
	vim.go.packlockfile = saved
	assert(ok, err)
	local cmd = calls[1].cmd
	local at = vim.fn.index(cmd, '--cmd') + 1
	H.eq(cmd[at + 1], 'set packlockfile=' .. vim.fn.fnameescape(path))
end

T['check()']['keeps unknown plugins at their previous status'] = function()
	stub(reply_with({ 'a', 'b' }))
	M.check({ offline = true }):wait(5000)
	-- a's fetch failed (unknown), b is now up to date, c is unknown too.
	stub(reply_with({}, { 'a', 'c' }))
	M.check({ offline = false }):wait(5000)
	H.eq(M.count(), 1)
	H.eq(events, { 2, 1 })
end

T['check()']['reads the last line of the output'] = function()
	stub(function()
		return {
			code = 0,
			signal = 0,
			stdout = 'noise\n{"pending":["a"],"unknown":[]}\n',
			stderr = '',
		}
	end)
	M.check({ offline = true }):wait(5000)
	H.eq(M.count(), 1)
end

T['check()']['keeps the count when the child fails'] = MiniTest.new_set({
	parametrize = {
		{ { code = 1, signal = 0, stdout = '', stderr = 'boom' }, 'boom' },
		{
			{ code = 0, signal = 0, stdout = 'not json\n', stderr = '' },
			'invalid child output',
		},
		{
			{
				code = 0,
				signal = 0,
				stdout = '{"error":"git failed"}\n',
				stderr = '',
			},
			'git failed',
		},
		{ { code = 124, signal = 15, stdout = '', stderr = '' }, 'timed out' },
	},
})

T['check()']['keeps the count when the child fails']['and records why'] = function(
	res,
	message
)
	stub(reply_with({ 'a' }))
	M.check({ offline = true }):wait(5000)
	stub(function()
		return res
	end)
	M.check({ offline = false }):wait(5000)
	H.eq(M.count(), 1)
	H.expect.no_equality(M.last_error:find(message, 1, true), nil)
	H.eq(events, { 1 })
	H.eq(notified, {})
end

T['check()']['runs one child at a time'] = function()
	stub(reply_with({}), 100)
	local first = M.check({ offline = true })
	local second = M.check({ offline = true })
	first:wait(5000)
	second:wait(5000)
	H.eq(#calls, 2)
	H.eq(calls[2].started >= calls[1].ended, true)
end

T['check()']['stop() kills a running child quietly'] = function()
	stub(function()
		return nil
	end)
	M.check({ offline = true })
	vim.wait(1000, function()
		return #calls == 1
	end)
	M.stop()
	vim.wait(1000, function()
		return calls[1].killed
	end)
	H.eq(calls[1].killed, true)
	vim.wait(100)
	H.eq(notified, {})
end

T['set()'] = MiniTest.new_set({ hooks = module_hooks })

T['set()']['counts pending and keeps plugins without rev_to'] = function()
	M.set({ plug('a', '1', '2'), plug('b', '1', '1') })
	H.eq(M.count(), 1)
	M.set({ plug('a', '1', nil), plug('b', '1', '1') })
	H.eq(M.count(), 1)
	M.set({ plug('a', '1', '1'), plug('b', '1', nil) })
	H.eq(M.count(), 0)
	H.eq(events, { 1, 1, 0 })
end

T['statusline'] = MiniTest.new_set({ hooks = module_hooks })

T['statusline']['shows the icon and count only while updates are pending'] = function()
	vim.g.packcount = { state_path = tmp .. '/state.json', icon = 'U:' }
	unload()
	M = require('packcount')
	H.eq({ M.has_updates(), M.updates() }, { false, '' })
	M.set({ plug('a', '1', '2'), plug('b', '1', '2'), plug('c', '1', '1') })
	-- lualine passes the component and focus state; both are ignored.
	H.eq({ M.has_updates(), M.updates({}, true) }, { true, 'U:2' })
end

T['refresh()'] = MiniTest.new_set({ hooks = module_hooks })

T['refresh()']['recounts once for a burst of calls'] = function()
	stub(reply_with({ 'a' }))
	for _ = 1, 5 do
		M.refresh()
	end
	vim.wait(1000, function()
		return #events == 1
	end)
	vim.wait(200)
	H.eq(#calls, 1)
	H.eq(mode(1), 'offline')
	H.eq(M.count(), 1)
end

T['refresh()']['recounts again for calls during a recount'] = function()
	stub(reply_with({}), 200)
	M.refresh()
	vim.wait(1000, function()
		return #calls == 1
	end)
	M.refresh()
	M.refresh()
	vim.wait(2000, function()
		return #events == 2
	end)
	vim.wait(300)
	H.eq(#calls, 2)
end

T['refresh()']['recounts again after a crashed worker'] = function()
	stub(reply_with({ 'a' }))
	M.refresh()
	-- check() now returns nil inside the worker, which makes it crash.
	M.can_check = false
	vim.wait(200)
	H.eq(#calls, 0)
	M.can_check = true
	M.refresh()
	vim.wait(1000, function()
		return M.count() == 1
	end)
	H.eq(#calls, 1)
end

T['unsupported'] = MiniTest.new_set({ hooks = module_hooks })

T['unsupported']['check() and refresh() do nothing'] = function()
	M.can_check = false
	stub(reply_with({ 'a' }))
	H.eq(M.check({ offline = true }), nil)
	M.refresh()
	vim.wait(200)
	H.eq(#calls, 0)
	M.set({ plug('a', '1', '2') })
	H.eq(M.count(), 1)
end

-- Loop -----------------------------------------------------------------

-- The module's state file.
---@return string
local function state_path()
	return require('packcount.config').get().state_path
end

-- Writes `last_check` into the module's state file.
---@param time integer
local function write_state(time)
	vim.fn.mkdir(vim.fs.dirname(state_path()), 'p')
	vim.fn.writefile({ vim.json.encode({ last_check = time }) }, state_path())
end

-- Reads `last_check` back from the module's state file.
---@return integer?
local function read_state()
	local ok, data = pcall(function()
		local text = table.concat(vim.fn.readfile(state_path()), '\n')
		return vim.json.decode(text)
	end)
	return ok and data.last_check or nil
end

T['loop'] = MiniTest.new_set({ hooks = module_hooks })

T['loop']['recent check: recounts offline only'] = function()
	write_state(os.time() - 10)
	stub(reply_with({ 'a' }))
	M.start()
	vim.wait(1000, function()
		return #calls == 1
	end)
	vim.wait(300)
	H.eq(#calls, 1)
	H.eq(mode(1), 'offline')
	H.eq(M.count(), 1)
end

-- `ago` is how long ago the last check was, false for no state file. A
-- negative value is a last check in the future (the clock was wrong).
T['loop']['due, missing or future check'] = MiniTest.new_set({
	parametrize = { { 7200 }, { false }, { -7200 } },
})

T['loop']['due, missing or future check']['fetches and writes the state'] = function(
	ago
)
	if ago then
		write_state(os.time() - ago)
	end
	stub(reply_with({}))
	M.start()
	vim.wait(1000, function()
		return #calls == 1
	end)
	H.eq(mode(1), 'online')
	H.eq(math.abs(read_state() - os.time()) <= 2, true)
end

T['loop']['another instance fetched: recounts offline without fetching'] = function()
	vim.g.packcount = { state_path = state_path(), frequency = 3 }
	unload()
	M = require('packcount')
	-- The next fetch is due in about 2 seconds.
	write_state(os.time() - 1)
	stub(reply_with({}))
	M.start()
	vim.wait(1000, function()
		return #calls == 1
	end)
	H.eq(mode(1), 'offline')
	vim.wait(1000)
	-- Another instance fetched just now, while this loop sleeps.
	write_state(os.time())
	vim.wait(3000, function()
		return #calls == 2
	end)
	H.eq(mode(2), 'offline')
end

T['loop']['unwritable state: fetches once per interval'] = function()
	-- A file where the state directory should be.
	vim.fn.writefile({}, tmp .. '/file')
	vim.g.packcount = { state_path = tmp .. '/file/packcount.json' }
	unload()
	M = require('packcount')
	stub(reply_with({}))
	M.start()
	vim.wait(1000, function()
		return #calls == 1
	end)
	vim.wait(500)
	H.eq(#calls, 1)
	H.eq(mode(1), 'online')
end

T['loop']['PackChanged recounts offline'] = function()
	write_state(os.time())
	stub(reply_with({}))
	M.start()
	vim.wait(1000, function()
		return #calls == 1
	end)
	for _ = 1, 3 do
		vim.api.nvim_exec_autocmds('PackChanged', {
			pattern = tmp,
			data = { kind = 'update', spec = { name = 'x' }, path = tmp },
		})
	end
	vim.wait(1000, function()
		return #calls == 2
	end)
	vim.wait(200)
	H.eq(#calls, 2)
	H.eq(mode(2), 'offline')
end

T['loop']['start() twice runs one loop; stop() is quiet'] = function()
	write_state(os.time())
	stub(reply_with({}))
	M.start()
	M.start()
	vim.wait(1000, function()
		return #calls >= 1
	end)
	vim.wait(300)
	H.eq(#calls, 1)
	M.stop()
	vim.wait(100)
	H.eq(notified, {})
	H.eq(pcall(vim.api.nvim_get_autocmds, { group = 'packcount' }), false)
end

T['loop']['reports a crash once'] = function()
	-- Arithmetic on this fails inside the loop. Set on the resolved config,
	-- past validation.
	require('packcount.config').get().frequency = 'not a number' ---@diagnostic disable-line: assign-type-mismatch
	write_state(os.time())
	stub(reply_with({}))
	M.start()
	vim.wait(1000, function()
		return #notified > 0
	end)
	vim.wait(200)
	H.eq(#notified, 1)
	H.expect.no_equality(notified[1]:find('packcount', 1, true), nil)
end

T['loop']['start() runs again after a crash'] = function()
	require('packcount.config').get().frequency = 'not a number' ---@diagnostic disable-line: assign-type-mismatch
	write_state(os.time())
	stub(reply_with({ 'a' }))
	M.start()
	vim.wait(1000, function()
		return not M.running()
	end)
	H.eq(M.running(), false)
	require('packcount.config').get().frequency = 3600
	M.start()
	H.eq(M.running(), true)
	vim.wait(1000, function()
		return M.count() == 1
	end)
	H.eq(M.count(), 1)
end

T['loop']['start() does nothing when unsupported'] = function()
	M.can_check = false
	stub(reply_with({}))
	M.start()
	vim.wait(200)
	H.eq(#calls, 0)
	H.eq(pcall(vim.api.nvim_get_autocmds, { group = 'packcount' }), false)
end

-- Config ---------------------------------------------------------------

T['config'] = MiniTest.new_set({ hooks = module_hooks })

T['config']['merges vim.g.packcount over the defaults'] = function()
	vim.g.packcount = { frequency = 60 }
	unload()
	local cfg = require('packcount.config').get()
	H.eq(cfg.frequency, 60)
	H.eq(cfg.autostart, true)
	H.eq(cfg.timeout, 150000)
	H.eq(notified, {})
end

T['config']['bad values'] = MiniTest.new_set({
	parametrize = {
		{
			{ frequency = 'hourly' },
			'vim.g.packcount.frequency: expected positive number',
		},
		{ { timeout = -1 }, 'vim.g.packcount.timeout: expected positive number' },
		{ { autostart = 1 }, 'vim.g.packcount.autostart: expected boolean' },
		{ 'yes', 'vim.g.packcount: expected table, got string' },
	},
})

T['config']['bad values']['fall back to defaults with one message'] = function(
	value,
	message
)
	vim.g.packcount = value
	unload()
	local Config = require('packcount.config')
	H.eq(Config.get(), Config.defaults)
	Config.get()
	H.eq(#notified, 1)
	H.expect.no_equality(notified[1]:find(message, 1, true), nil)
	H.expect.no_equality(Config.error:find(message, 1, true), nil)
end

T['config']['lists unknown keys'] = function()
	vim.g.packcount = { frequncy = 60, timeout = 10 }
	unload()
	H.eq(require('packcount.config').unknown(), { 'frequncy' })
end

-- Entry point ----------------------------------------------------------

local child = MiniTest.new_child_neovim()

-- Runs in the child before plugin/ files load: records vim.system calls
-- instead of spawning, so no real check runs.
local child_stub = [[lua
	_G.calls = {}
	vim.system = function(cmd)
		table.insert(_G.calls, cmd)
		return {
			is_closing = function() return true end,
			kill = function() end,
		}
	end
]]

-- Starts a child Neovim with this plugin on 'runtimepath' and the state
-- file under `tmp`. `opts` becomes vim.g.packcount, set before plugin/
-- files load.
---@param opts? table
local function start_child(opts)
	opts =
		vim.tbl_extend('force', { state_path = tmp .. '/state.json' }, opts or {})
	child.start({
		'--cmd',
		'set rtp^=' .. vim.fn.fnameescape(root),
		'--cmd',
		'lua vim.g.packcount = ' .. vim.inspect(opts, { newline = ' ' }),
		'--cmd',
		(child_stub:gsub('\n', ' ')),
	})
end

T['entry point'] = MiniTest.new_set({
	hooks = {
		post_case = function()
			child.stop()
		end,
	},
})

T['entry point']['requires nothing until used'] = function()
	start_child({ autostart = false })
	H.eq(child.lua_get([[package.loaded['packcount'] == nil]]), true)
	H.eq(child.fn.exists(':Packcount'), 2)
end

T['entry point']['completes subcommands'] = function()
	start_child({ autostart = false })
	H.eq(
		child.fn.getcompletion('Packcount ', 'cmdline'),
		{ 'check', 'recount', 'start', 'status', 'stop' }
	)
	H.eq(child.fn.getcompletion('Packcount st', 'cmdline'), {
		'start',
		'status',
		'stop',
	})
	H.eq(child.fn.getcompletion('Packcount stop ', 'cmdline'), {})
end

T['entry point']['reports an unknown subcommand'] = function()
	start_child({ autostart = false })
	child.lua([[
		_G.msgs = {}
		vim.notify = function(msg) table.insert(_G.msgs, msg) end
	]])
	child.cmd('Packcount nope')
	H.eq(child.lua_get('_G.msgs'), { 'packcount: unknown subcommand nope' })
end

-- mini.test's child starts without a UI; attaching one fires UIEnter.
T['entry point']['starts the loop when a UI attaches'] = function()
	start_child()
	H.eq(child.lua_get([[package.loaded['packcount'] == nil]]), true)
	child.api.nvim_ui_attach(80, 24, {})
	child.lua('vim.wait(1000, function() return #_G.calls > 0 end)')
	H.eq(child.lua_get([[package.loaded['packcount'] ~= nil]]), true)
	if child.lua_get([[require('packcount').supported()]]) then
		H.eq(child.lua_get([[require('packcount').running()]]), true)
		H.eq(child.lua_get('#_G.calls'), 1)
	end
end

-- Sourced again (e.g. a plugin manager loading it on demand) after the UI
-- attached: starts right away.
T['entry point']['starts when loaded after the UI attached'] = function()
	child.start({ '--cmd', (child_stub:gsub('\n', ' ')) })
	child.api.nvim_ui_attach(80, 24, {})
	child.lua('vim.g.packcount = ...', { { state_path = tmp .. '/state.json' } })
	child.cmd('set rtp^=' .. vim.fn.fnameescape(root))
	child.cmd('runtime plugin/packcount.lua')
	child.lua('vim.wait(1000, function() return #_G.calls > 0 end)')
	if child.lua_get([[require('packcount').supported()]]) then
		H.eq(child.lua_get([[require('packcount').running()]]), true)
	end
end

T['entry point']['autostart = false keeps the loop off'] = function()
	start_child({ autostart = false })
	child.api.nvim_ui_attach(80, 24, {})
	child.lua('vim.wait(300)')
	H.eq(child.lua_get([[package.loaded['packcount'] == nil]]), true)
	H.eq(child.lua_get('#_G.calls'), 0)
end

return T
