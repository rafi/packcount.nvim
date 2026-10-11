# packcount.nvim

Counts [`vim.pack`](https://neovim.io/doc/user/pack.html#vim.pack) plugins
with pending updates, for your statusline. Checks run in a separate headless
Neovim process, so fetching never blocks the editor.

- Fetches at most once per `frequency` (default 1 hour), shared by every
  running Neovim through a state file.
- Recounts offline after `vim.pack.update()` (`PackChanged`).
- Starts by itself once a UI attaches; headless scripts never fetch.

Requires Neovim 0.13+ (`vim.pack.get()` with `offline` and `rev_to`,
`vim.async`) and git.

## Install

```lua
vim.pack.add({ 'https://github.com/rafi/packcount.nvim' })
```

No `setup()` call is needed.

## Configuration

Set `vim.g.packcount` anywhere in your config; every field is optional:

```lua
vim.g.packcount = {
	autostart = true, -- run the check loop once a UI attaches
	frequency = 3600, -- seconds between online checks (git fetch)
	timeout = 150000, -- milliseconds before a check is killed
	state_path = vim.fn.stdpath('state') .. '/packcount.json',
	icon = '\239\146\135 ', -- prefix of updates() (Nerd Font package glyph)
}
```

## Statusline

`updates()` returns the `icon` option and the count (`' 3'`), or `''` when
nothing is pending. `has_updates()` tells whether anything is pending. Both
ignore their arguments, so lualine can use them as-is:

```lua
-- lualine
{
	require('packcount').updates,
	cond = require('packcount').has_updates,
}
```

Or in a plain `'statusline'`:
`%{v:lua.require'packcount'.updates()}`.

`User PackcountChanged` fires with `data.count` after every recount.

## Commands

`:Packcount {subcommand}`

| Subcommand | Action |
|---|---|
| `status` (default) | Show the count, pending plugin names and the last error |
| `check` | Fetch every plugin now and recount |
| `recount` | Recount from the last fetch |
| `start` / `stop` | Start or stop the background loop |

## API

| Function | |
|---|---|
| `count()` | Number of plugins with a pending update |
| `names()` | Their names, sorted |
| `has_updates()` | Whether any update is pending |
| `updates()` | Statusline text: `icon` and the count, `''` when none |
| `set(plugins)` | Recount from `vim.pack.get()` data you already have |
| `check({ offline })` | One check, offline unless `offline = false`; returns a `vim.async.Task` or nil when unsupported |
| `refresh()` | Coalesced offline recount |
| `start()` / `stop()` / `running()` | Background loop |
| `last_error` | Message of the last failed check |

See `:h packcount` and `:checkhealth packcount`.

## Development

```sh
make test   # nvim -l tests/minit.lua, sandboxed under .tests/
make lint   # stylua --check
```
