# packcount.nvim

See your pending plugin updates right in your statusline. It works with Neovim's
built-in plugin manager, [`vim.pack`](https://neovim.io/doc/user/pack.html#vim.pack).
It runs `vim.pack.get()` for you in a separate headless Neovim, so fetching
never blocks your editor.

<img src="https://raw.githubusercontent.com/rafi/assets/main/repo/packcount.nvim/statusline.png" alt="packcount.nvim count in the statusline" width="90%">

- Fetches at most once per `frequency` (default 1 hour), shared by every
  running Neovim through a state file.
- Recounts offline after `vim.pack.update()` (`PackChanged`).
- Starts by itself once a UI attaches; headless scripts never fetch.

## Light-weight

- Neovim's own `vim.pack`, `vim.async` and `vim.system` do the work.
- Built-in all the way down: a plugin counts when `vim.pack.get()` reports
  a `rev_to` other than its `rev`, the count follows vim.pack's
  `PackChanged` event, and you apply the updates with `:packupdate` (or
  [packman.nvim](https://github.com/rafi/packman.nvim)).
- Never touches your plugins or lockfile. When the lockfile and the plugin
  directory disagree, the check reports it instead of letting
  `vim.pack.get()` sync them in the background. A fetch only moves git's
  remote-tracking refs, and the one file packcount writes holds the time
  of the last fetch.
- Its `plugin/` file only defines `:Packcount` and a `UIEnter` autocmd
  that starts the loop.

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

Or in a plain `'statusline'`, redrawn when the count changes:

```lua
vim.o.statusline = "%f %m%=%{v:lua.require'packcount'.updates()} "
vim.api.nvim_create_autocmd('User', {
	pattern = 'PackcountChanged',
	command = 'redrawstatus',
})
```

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

| Function                           | Description                                                                                     |
| ---------------------------------- | ----------------------------------------------------------------------------------------------- |
| `count()`                          | Number of plugins with a pending update                                                         |
| `names()`                          | Their names, sorted                                                                             |
| `has_updates()`                    | Whether any update is pending                                                                   |
| `updates()`                        | Statusline text: `icon` and the count, `''` when none                                           |
| `set(plugins)`                     | Recount from `vim.pack.get()` data you already have                                             |
| `check({ offline })`               | One check, offline unless `offline = false`; returns a `vim.async.Task` or nil when unsupported |
| `refresh()`                        | Coalesced offline recount                                                                       |
| `start()` / `stop()` / `running()` | Background loop                                                                                 |
| `last_error`                       | Message of the last failed check                                                                |

See `:h packcount` and `:checkhealth packcount`.

## Development

```sh
make test   # nvim -l tests/minit.lua, sandboxed under .tests/
make lint   # stylua --check
make demo   # re-take the screenshot with vhs, sandboxed under .demo/, into $ASSETS
```
