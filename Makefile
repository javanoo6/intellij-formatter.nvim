NVIM ?= nvim

.PHONY: test integration
test:
	$(NVIM) --headless -u NONE -i NONE -l tests/unit.lua

integration:
	$(NVIM) --headless -u NONE -i NONE -l tests/integration.lua
