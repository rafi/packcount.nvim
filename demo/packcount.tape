# README close-up of the statusline count. Run with `make demo`.

Output .demo/statusline.gif
Require nvim
Require git

Set Shell "bash"
Set Width 1000
Set Height 460
Set WaitTimeout 60s

# morrow's background, so the padding blends in.
Set Theme { "name": "morrow-night", "background": "#1d1f21", "foreground": "#c5c8c6", "selection": "#373b41", "cursor": "#c5c8c6", "black": "#282a2e", "red": "#cc6666", "green": "#b5bd68", "yellow": "#f0c674", "blue": "#81a2be", "magenta": "#b294bb", "cyan": "#8abeb7", "white": "#b4b7b4", "brightBlack": "#7e8181", "brightRed": "#cc6666", "brightGreen": "#b5bd68", "brightYellow": "#f0c674", "brightBlue": "#81a2be", "brightMagenta": "#b294bb", "brightCyan": "#8abeb7", "brightWhite": "#c5c8c6" }
Set BorderRadius 14
Set WindowBar Colorful
Set WindowBarSize 40
Set Margin 20
Set MarginFill "#674EFF"
Set Padding 16

# Mono keeps icons one cell wide.
Set FontFamily "PragmataPro Mono, Symbols Nerd Font Mono"
Set FontSize 32
Set LetterSpacing 1
Set LineHeight 1.1

Hide
Type@0ms "clear; nvim -u demo/init.lua '+/^vim.pack.add' demo/init.lua"
Enter
Sleep 1s
Type@0ms ":set nowrap | nohlsearch | normal! zt"
Enter
# Statusline reads `<icon> 3  lua  24:1` once counted.
Wait+Screen /\d  lua  \d/
Show
Sleep 200ms
Screenshot .demo/statusline.png
Sleep 200ms
