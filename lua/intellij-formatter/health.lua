local M = {}

function M.check()
	local health = vim.health
	local formatter = require("intellij-formatter")
	local config = formatter.options()
	health.start("intellij-formatter.nvim")
	if vim.fn.has("nvim-0.10") == 1 then
		health.ok("Neovim 0.10+ is available")
	else
		health.error("Neovim 0.10+ is required")
	end
	if pcall(require, "conform") then
		health.ok("conform.nvim is installed")
	else
		health.error("Install stevearc/conform.nvim")
	end
	if vim.fn.executable(config.java) == 1 then
		local result = vim.system({ config.java, "-version" }, { text = true, timeout = 5000 }):wait()
		local version = (result.stderr or "") .. (result.stdout or "")
		if result.code == 0 and version:match('version "21[%."-]') then
			health.ok("JDK 21 is available: " .. config.java)
		else
			health.warn("Use JDK 21 for the pinned formatter engine: " .. vim.trim(version))
		end
	else
		health.error("JDK 21 is missing; configure java or put it on PATH")
	end
	if vim.fn.filereadable(formatter.jar_path()) == 1 then
		health.ok("Formatter JAR: " .. formatter.jar_path())
	elseif config.auto_install and not config.jar then
		health.info("The formatter engine will download automatically on the first formatting request")
	elseif config.jar then
		health.warn("Configured JAR missing: " .. config.jar)
	else
		health.warn("Formatter JAR missing; run :IntellijFormatterInstall")
	end
	if
		vim.fn.executable("curl") == 1 and require("intellij-formatter.engine").checksum_command(formatter.jar_path())
	then
		health.ok("Engine download and checksum tools are available")
	else
		health.warn(
			"Managed installation requires curl and sha256sum, shasum, openssl, or certutil; a local JAR can also be configured"
		)
	end
end

return M
