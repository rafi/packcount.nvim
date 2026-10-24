-- Moves a few plugins some commits back in the lockfile, so the demo has
-- pending updates. `make demo` then applies it with
-- `:packupdate! ++offline ++lockfile`, vim.pack's documented way to revert
-- a plugin (`:h vim.pack-examples`).

local behind = {
	['flash.nvim'] = 3,
	['gitsigns.nvim'] = 6,
	['which-key.nvim'] = 4,
}

local path = vim.o.packlockfile
local lock = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
for _, plugin in ipairs(vim.pack.get(vim.tbl_keys(behind), { info = false })) do
	local name = plugin.spec.name
	local out = vim
		.system({ 'git', 'rev-parse', 'HEAD~' .. behind[name] }, {
			cwd = plugin.path,
			text = true,
		})
		:wait()
	assert(out.code == 0, out.stderr)
	lock.plugins[name].rev = vim.trim(out.stdout)
end
vim.fn.writefile(
	vim.split(vim.json.encode(lock, { indent = '  ' }), '\n'),
	path
)
