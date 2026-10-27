NVIM ?= nvim

.PHONY: test integration
test:
	$(NVIM) --headless -u NONE -i NONE -l tests/unit.lua
	$(NVIM) --headless -u NONE -i NONE -l tests/automatic_install.lua

integration:
	$(NVIM) --headless -u NONE -i NONE -l tests/integration.lua
