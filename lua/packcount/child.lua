-- Background script for packcount. Prints which plugins have a pending
-- vim.pack update as one JSON line. The editor runs it with
-- `nvim --clean --headless -l child.lua online|offline`, since
-- vim.pack.get() blocks while it fetches. Never require it.
-- https://github.com/rafi/packcount.nvim

-- `-l` sets arg[0] to the running script. In an editor session `arg` is
-- empty, and another `-l` script (like the test runner) has its own arg[0],
-- so only running this file directly continues.
if type(arg) ~= 'table' or not (arg[0] or ''):match('child%.lua$') then
	error('run with nvim -l', 0)
end

local offline = arg[1] == 'offline'

-- vim.pack.get() first syncs the lockfile with the plugin dir: it installs
-- missing plugins without asking, rewrites the lockfile for unlisted dirs
-- and deletes entries that aren't directories. A background count must
-- change nothing, so this returns why they differ, or nil when they match.
-- The editor syncs them on its next start or :packupdate.
---@return string?
local function out_of_sync()
	local plug_dir =
		vim.fs.joinpath(vim.fn.stdpath('data'), 'site', 'pack', 'core', 'opt')
	local lock_path = vim.fn.exists('+packlockfile') == 1 and vim.go.packlockfile
		or vim.fs.joinpath(vim.fn.stdpath('config'), 'nvim-pack-lock.json')
	local locked = {} ---@type table<string, table>
	local file = io.open(lock_path, 'r')
	if file then
		local ok, data = pcall(vim.json.decode, file:read('*a'))
		file:close()
		if not ok then
			return 'unreadable lockfile ' .. lock_path
		end
		if type(data) == 'table' and type(data.plugins) == 'table' then
			locked = data.plugins
		end
	end
	local names = {} ---@type string[]
	local installed = {} ---@type table<string, true>
	if vim.uv.fs_stat(plug_dir) then
		for name, kind in vim.fs.dir(plug_dir) do
			installed[name] = true
			local entry = locked[name]
			local valid = type(entry) == 'table'
				and type(entry.rev) == 'string'
				and type(entry.src) == 'string'
			if kind ~= 'directory' or not valid then
				names[#names + 1] = name
			end
		end
	end
	for name in pairs(locked) do
		if not installed[name] then
			names[#names + 1] = name
		end
	end
	if #names > 0 then
		table.sort(names)
		return 'lockfile and plugin dir out of sync: ' .. table.concat(names, ', ')
	end
end

local problem = out_of_sync()
if problem then
	io.stdout:write(vim.json.encode({ error = problem }) .. '\n')
	return
end

local ok, plugins = pcall(vim.pack.get, nil, { offline = offline })
if not ok then
	io.stdout:write(vim.json.encode({ error = tostring(plugins) }) .. '\n')
	return
end

-- A failed online fetch (no network, missing remote) leaves `rev_to` unset.
-- Re-read those offline, so they show what the last fetch found.
if not offline then
	local missing = {} ---@type string[]
	for _, plugin in ipairs(plugins) do
		if plugin.rev_to == nil then
			missing[#missing + 1] = plugin.spec.name
		end
	end
	if #missing > 0 then
		local ok_again, again = pcall(vim.pack.get, missing, { offline = true })
		if ok_again then
			local by_name = {} ---@type table<string, vim.pack.PlugData>
			for _, plugin in ipairs(again) do
				by_name[plugin.spec.name] = plugin
			end
			for i, plugin in ipairs(plugins) do
				plugins[i] = by_name[plugin.spec.name] or plugin
			end
		end
	end
end

-- Plugins still without `rev_to` are unknown, so the editor keeps their
-- previous status.
local result = { pending = {}, unknown = {} }
for _, plugin in ipairs(plugins) do
	if plugin.rev_to == nil then
		table.insert(result.unknown, plugin.spec.name)
	elseif plugin.rev ~= plugin.rev_to then
		table.insert(result.pending, plugin.spec.name)
	end
end
io.stdout:write(vim.json.encode(result) .. '\n')
