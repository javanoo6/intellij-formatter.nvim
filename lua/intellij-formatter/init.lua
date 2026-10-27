local M = {}

local default_filetypes = {
	"html",
	"java",
	"json",
	"jsonc",
	"json5",
	"markdown",
	"python",
	"sh",
	"toml",
	"xhtml",
	"xml",
	"xslt",
	"yaml",
	"yaml.helm-values",
	"zsh",
}
local release = {
	version = "0.0.8",
	sha256 = "842b9e5bfbc4a8173a9b27d9f0f9fec67f7fcf114637945ebb59e25945dcc06f",
}
local defaults = {
	java = "java",
	version = release.version,
	sha256 = release.sha256,
	filetypes = default_filetypes,
	timeout_ms = 30000,
	install_timeout_ms = 240000,
	auto_install = true,
	daemon = true,
	optimize_imports = true,
	rearrange = true,
	format_on_save = false,
	conform = true,
	notify = true,
}
local config = vim.deepcopy(defaults)
local supported = {}
local previous_routes = {}
local configured_conform
local generation = 0
local function route()
	return { "intellij_formatter", lsp_format = "never", timeout_ms = M.timeout() }
end
local function index_filetypes()
	supported = {}
	for _, ft in ipairs(config.filetypes) do
		supported[ft] = true
	end
end
index_filetypes()

local function notify(message, level)
	if config.notify then
		vim.notify(message, level or vim.log.levels.INFO, { title = "IntelliJ formatter" })
	end
end

function M.jar_path()
	return config.jar
		or (vim.fn.stdpath("data") .. "/intellij-formatter/" .. config.version .. "/formatter-cli-full.jar")
end

function M.filetypes()
	return vim.deepcopy(config.filetypes)
end

function M.supports(filetype)
	return supported[filetype] == true
end

function M.options()
	return vim.deepcopy(config)
end

function M.available()
	if vim.fn.executable(config.java) ~= 1 then
		return false, "JDK 21 is required; configure java or put java on PATH"
	end
	if vim.fn.filereadable(M.jar_path()) ~= 1 then
		if config.auto_install and not config.jar then
			return false, "Formatter engine will download automatically on the first formatting request"
		end
		if config.jar then
			return false,
				"Configured formatter JAR is missing: " .. config.jar .. ". Build it or configure an existing JAR."
		end
		return false, "Formatter JAR missing; run :IntellijFormatterInstall or configure jar with a local build"
	end
	return true
end

function M.timeout()
	local installing = config.auto_install and not config.jar and vim.fn.filereadable(M.jar_path()) ~= 1
	return config.timeout_ms + (installing and config.install_timeout_ms or 0)
end

local function can_install()
	return config.auto_install and not config.jar and vim.fn.executable(config.java) == 1
end

function M.ensure(callback)
	local ready, error = M.available()
	if ready then
		callback(nil, M.jar_path())
		return
	end
	if can_install() then
		M.install({}, callback)
	else
		callback(error)
	end
end

function M.conform_formatter()
	return {
		format = function(_, ctx, lines, callback)
			local request_generation = generation
			local tick = vim.api.nvim_buf_get_changedtick(ctx.buf)
			local settings = M.options()
			local function unchanged()
				return generation == request_generation
					and vim.api.nvim_buf_is_valid(ctx.buf)
					and vim.api.nvim_buf_get_changedtick(ctx.buf) == tick
			end
			M.ensure(function(error, jar)
				if error then
					callback(error)
					return
				end
				require("intellij-formatter.runner").run(settings, ctx, jar, lines, unchanged, callback)
			end)
		end,
		condition = function()
			return M.available() or can_install()
		end,
	}
end

function M.format(opts, callback)
	opts = vim.tbl_extend("force", {
		bufnr = 0,
		timeout_ms = M.timeout(),
		lsp_format = "never",
		formatters = { "intellij_formatter" },
	}, opts or {})
	local bufnr = opts.bufnr == 0 and vim.api.nvim_get_current_buf() or opts.bufnr
	local ready, err = M.available()
	local ok = ready or can_install()
	if not M.supports(vim.bo[bufnr].filetype) then
		ok, err = false, "Unsupported filetype: " .. vim.bo[bufnr].filetype
	end
	local has_conform, conform = pcall(require, "conform")
	if not has_conform then
		ok, err = false, "Install stevearc/conform.nvim and enable the Conform integration"
	end
	if not ok then
		if callback then
			callback(err)
		else
			notify(err, vim.log.levels.ERROR)
		end
		return false
	end
	opts.bufnr = bufnr
	opts.quiet = true
	local on_complete = callback
		or function(error)
			if error then
				vim.schedule(function()
					notify(error, vim.log.levels.ERROR)
				end)
			end
		end
	return vim.api.nvim_buf_call(bufnr, function()
		return conform.format(opts, on_complete)
	end)
end

function M.install(opts, callback)
	opts = opts or {}
	if config.jar then
		local err =
			"A custom jar is configured; build or update that file yourself, or remove jar to use managed installation"
		if callback then
			callback(err)
		else
			notify(err, vim.log.levels.ERROR)
		end
		return
	end
	local engine = require("intellij-formatter.engine")
	local announce = not engine.installing(M.jar_path()) and (opts.force or vim.fn.filereadable(M.jar_path()) ~= 1)
	if announce then
		notify(
			"Downloading formatter engine "
				.. config.version
				.. " (347 MiB). Formatting will continue when it is ready…"
		)
	end
	engine.install({
		jar = M.jar_path(),
		url = "https://github.com/javanoo6/intellij-code-formatter/releases/download/"
			.. config.version
			.. "/formatter-cli-full.jar",
		sha256 = config.sha256,
		force = opts.force,
	}, function(err, path)
		if announce then
			notify(err or ("Formatter engine ready: " .. path), err and vim.log.levels.ERROR or vim.log.levels.INFO)
		end
		if callback then
			callback(err, path)
		end
	end)
end

function M.stop(callback)
	if vim.fn.executable(config.java) ~= 1 or vim.fn.filereadable(M.jar_path()) ~= 1 then
		local err = "Java or the formatter JAR is unavailable; run :checkhealth intellij-formatter"
		if callback then
			callback(err)
		else
			notify(err, vim.log.levels.ERROR)
		end
		return
	end
	return vim.system(
		{ config.java, "-jar", M.jar_path(), "--stop-daemon" },
		{ text = true, timeout = 10000 },
		vim.schedule_wrap(function(result)
			local err = result.code ~= 0 and vim.trim(result.stderr or "Could not stop formatter daemon") or nil
			notify(err or vim.trim(result.stdout), err and vim.log.levels.ERROR or vim.log.levels.INFO)
			if callback then
				callback(err)
			end
		end)
	)
end

function M.info()
	return table.concat({
		"Engine: " .. config.version .. (config.jar and " (custom JAR)" or " (managed)"),
		"JAR: " .. M.jar_path(),
		"JAR readable: " .. tostring(vim.fn.filereadable(M.jar_path()) == 1),
		"Java: " .. config.java,
		"EditorConfig: " .. (type(config.editorconfig) == "string" and config.editorconfig or "discovered per file"),
		"Filetypes: " .. table.concat(config.filetypes, ", "),
		"Format on save: " .. tostring(config.format_on_save),
		"Automatic engine installation: " .. tostring(config.auto_install),
	}, "\n")
end

function M.setup(opts)
	assert(vim.fn.has("nvim-0.10") == 1, "intellij-formatter.nvim requires Neovim 0.10+")
	opts = opts or {}
	assert(type(opts) == "table", "setup expects a table")
	if opts.version and opts.version ~= release.version then
		assert(opts.sha256, "A custom engine version requires its SHA-256 checksum")
	end
	local next_config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
	assert(type(next_config.java) == "string" and next_config.java ~= "", "java must be an executable path")
	assert(type(next_config.version) == "string" and next_config.version:match("^[%w._-]+$"), "Invalid engine version")
	assert(
		type(next_config.sha256) == "string" and #next_config.sha256 == 64 and next_config.sha256:match("^%x+$"),
		"sha256 must be a 64-digit hexadecimal checksum"
	)
	assert(type(next_config.filetypes) == "table", "filetypes must be a list")
	assert(type(next_config.timeout_ms) == "number" and next_config.timeout_ms > 0, "timeout_ms must be positive")
	assert(
		type(next_config.install_timeout_ms) == "number" and next_config.install_timeout_ms > 0,
		"install_timeout_ms must be positive"
	)
	assert(
		next_config.editorconfig == nil
			or type(next_config.editorconfig) == "string"
			or type(next_config.editorconfig) == "function",
		"editorconfig must be a path or function"
	)
	for _, key in ipairs({
		"auto_install",
		"daemon",
		"optimize_imports",
		"rearrange",
		"format_on_save",
		"conform",
		"notify",
	}) do
		assert(type(next_config[key]) == "boolean", key .. " must be a boolean")
	end
	if next_config.jar then
		assert(type(next_config.jar) == "string" and next_config.jar ~= "", "jar must be a path")
		next_config.jar = vim.fn.fnamemodify(vim.fn.expand(next_config.jar), ":p")
	end
	for _, ft in ipairs(next_config.filetypes) do
		assert(vim.tbl_contains(default_filetypes, ft), "Unsupported filetype: " .. tostring(ft))
	end
	local has_conform, conform
	if next_config.conform then
		has_conform, conform = pcall(require, "conform")
		assert(has_conform, "intellij-formatter.nvim requires stevearc/conform.nvim; install it or set conform = false")
	end
	-- Restore only routes still owned by this plugin, preserving later user overrides.
	if configured_conform then
		for ft, previous in pairs(previous_routes) do
			if vim.deep_equal(configured_conform.formatters_by_ft[ft], route) then
				configured_conform.formatters_by_ft[ft] = previous.value
			end
		end
	end
	previous_routes, configured_conform = {}, conform
	config = next_config
	generation = generation + 1
	index_filetypes()
	if config.conform then
		local by_ft = {}
		for _, ft in ipairs(config.filetypes) do
			previous_routes[ft] = { value = conform.formatters_by_ft[ft] }
			by_ft[ft] = route
		end
		conform.setup({ formatters = { intellij_formatter = M.conform_formatter() }, formatters_by_ft = by_ft })
	end
	local group = vim.api.nvim_create_augroup("IntellijFormatter", { clear = true })
	if config.format_on_save then
		vim.api.nvim_create_autocmd("BufWritePre", {
			group = group,
			callback = function(event)
				if M.supports(vim.bo[event.buf].filetype) and vim.bo[event.buf].buftype == "" then
					M.format({ bufnr = event.buf, async = false })
				end
			end,
			desc = "Format supported buffers with IntelliJ",
		})
	end
	vim.api.nvim_create_user_command("IntellijFormat", function(command)
		local format_opts = { async = true }
		if command.range > 0 then
			local last = vim.api.nvim_buf_get_lines(0, command.line2 - 1, command.line2, false)[1] or ""
			format_opts.range = { start = { command.line1, 0 }, ["end"] = { command.line2, #last } }
		end
		M.format(format_opts)
	end, { range = true, force = true, desc = "Format buffer or range with IntelliJ" })
	vim.api.nvim_create_user_command("IntellijFormatterInstall", function(command)
		M.install({ force = command.bang })
	end, { bang = true, force = true, desc = "Download and verify the pinned formatter engine" })
	vim.api.nvim_create_user_command("IntellijFormatterInfo", function()
		vim.notify(M.info(), vim.log.levels.INFO, { title = "IntelliJ formatter" })
	end, { force = true, desc = "Show formatter configuration" })
	vim.api.nvim_create_user_command("IntellijFormatterStop", function()
		M.stop()
	end, { force = true, desc = "Stop the formatter daemon" })
end

return M
