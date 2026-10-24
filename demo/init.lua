-- Config the README screenshot is taken with (`make demo`), in a sandbox
-- under .demo/ with its own stdpaths. morrow.nvim colors and a plain
-- 'statusline'.

local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
-- Only inside the `make demo` sandbox, so it never adds plugins to yours.
if not vim.startswith(vim.fn.stdpath('data'), root .. '/.demo/') then
	error('demo/init.lua runs only from `make demo`')
end
vim.opt.runtimepath:prepend(root)

pcall(function()
	require('vim._core.ui2').enable({})
end)
vim.o.termguicolors = true
vim.o.number = true
vim.o.laststatus = 3
vim.o.cmdheight = 0
vim.o.winborder = 'rounded'
vim.o.shortmess = vim.o.shortmess .. 'I'
vim.o.swapfile = false

-- `confirm = false` lets `make demo` install headless.
vim.pack.add({
	'https://github.com/rafi/morrow.nvim',
	'https://github.com/folke/flash.nvim',
	'https://github.com/lewis6991/gitsigns.nvim',
	'https://github.com/folke/which-key.nvim',
	'https://github.com/neovim/nvim-lspconfig',
	'https://github.com/stevearc/conform.nvim',
}, { confirm = false })
vim.cmd.colorscheme('morrow')

-- The count in the warning color, on the statusline background.
local stl = vim.api.nvim_get_hl(0, { name = 'StatusLine', link = false })
local warn = vim.api.nvim_get_hl(0, { name = 'DiagnosticWarn', link = false })
vim.api.nvim_set_hl(0, 'StatusLinePackcount', {
	fg = warn.fg,
	bg = stl.bg,
	bold = true,
})

vim.o.statusline = table.concat({
	' %f %m%=',
	"%#StatusLinePackcount#%{v:lua.require'packcount'.updates()}%*",
	'  %{&filetype}  %l:%c ',
})
vim.api.nvim_create_autocmd('User', {
	pattern = 'PackcountChanged',
	command = 'redrawstatus',
})
