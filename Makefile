.PHONY: test lint demo
# Run tests/*_spec.lua, or one file with SPEC=tests/x_spec.lua.
test:
	nvim -l tests/minit.lua $(SPEC)

lint:
	stylua --check .

# Take the README screenshot in a .demo/ sandbox (needs network), into
# $(ASSETS).
DEMO := $(CURDIR)/.demo
ASSETS ?= $(HOME)/code/rafi/assets/repo/packcount.nvim
demo: export XDG_CONFIG_HOME = $(DEMO)/config
demo: export XDG_DATA_HOME = $(DEMO)/data
demo: export XDG_STATE_HOME = $(DEMO)/state
demo: export XDG_CACHE_HOME = $(DEMO)/cache
demo:
	rm -rf $(DEMO)
	nvim --headless -u demo/init.lua +'luafile demo/setup.lua' +qa
	nvim --headless -u demo/init.lua +'packupdate! ++offline ++lockfile' +qa
	vhs demo/packcount.tape
	mkdir -p "$(ASSETS)"
	pngquant --quality=70-90 --speed 1 --force \
		--output "$(ASSETS)/statusline.png" $(DEMO)/statusline.png
