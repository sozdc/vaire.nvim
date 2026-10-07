.PHONY: check

check:
	nvim --headless --clean -l tests/run.lua
