local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local checks = 0
local function equal(actual, expected, label)
	assert(
		vim.deep_equal(actual, expected),
		label .. "\nExpected: " .. vim.inspect(expected) .. "\nActual: " .. vim.inspect(actual)
	)
	checks = checks + 1
end
local function contains(list, value)
	return vim.tbl_contains(list, value)
end
local conform = { formatters_by_ft = { python = { "ruff_format" }, lua = { "stylua" } } }
function conform.setup(opts)
	conform.formatters = opts.formatters
	conform.formatters_by_ft = vim.tbl_extend("force", conform.formatters_by_ft, opts.formatters_by_ft)
end
local formatted_buffer
function conform.format(opts, callback)
	formatted_buffer = { requested = opts.bufnr, current = vim.api.nvim_get_current_buf(), opts = opts }
	if callback then
		callback(nil, true)
	end
	return true
end
package.loaded.conform = conform
local formatter = require("intellij-formatter")
local function setup(opts)
	formatter.setup(vim.tbl_extend("force", { notify = false }, opts or {}))
end
local real_system = vim.system

local function run()
	setup()
	equal(formatter.options().timeout_ms, 30000, "Cold JVM startup has a 30-second allowance")
	equal(#formatter.filetypes(), 15, "All supported filetypes registered")
	equal(
		conform.formatters_by_ft.json,
		{ "intellij_formatter", lsp_format = "never", timeout_ms = 30000 },
		"JSON uses IntelliJ with a cold-start timeout"
	)
	equal(conform.formatters_by_ft.lua, { "stylua" }, "Unrelated formatters preserved")
	equal(formatter.supports("yaml.helm-values"), true, "Helm values use YAML")
	equal(formatter.supports("helm"), false, "Templates excluded")
	equal(formatter.jar_path():find("/0.0.8/formatter-cli-full.jar", 1, true) ~= nil, true, "Engine version pinned")
	local function command(ft, name, range)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].filetype = ft
		local args = formatter
			.conform_formatter()
			.args(nil, { buf = buf, filename = name or fixture .. "/Sample.java", range = range })
		vim.api.nvim_buf_delete(buf, { force = true })
		return args
	end
	local args = command("java")
	equal(contains(args, "--optimize-imports"), true, "Whole Java files optimize imports")
	equal(contains(args, "--rearrange"), true, "Whole Java files rearrange")
	equal(contains(args, "--no-daemon"), false, "Daemon is default")
	args = command("java", nil, { start = { 1, 0 }, ["end"] = { 1, 5 } })
	equal(contains(args, "--optimize-imports"), false, "Ranges omit import cleanup")
	equal(contains(args, "--rearrange"), false, "Ranges omit rearrangement")
	equal(contains(command("python"), "--optimize-imports"), false, "Python does not claim import cleanup")
	equal(
		contains(command("sh", fixture .. "/space ' ; $(touch INJECTED).sh"), "--no-daemon"),
		true,
		"Whitespace paths use argv-based one-shot"
	)
	setup({ editorconfig = fixture .. "/config with spaces/.editorconfig" })
	equal(contains(command("yaml"), "--no-daemon"), true, "EditorConfig whitespace handled")
	setup({
		editorconfig = function(ctx)
			return vim.fs.dirname(ctx.filename) .. "/.editorconfig"
		end,
		daemon = false,
	})
	args = command("yaml", fixture .. "/sample.yaml")
	equal(contains(args, fixture .. "/.editorconfig"), true, "EditorConfig callback receives context")
	equal(contains(args, "--no-daemon"), true, "One-shot can be selected explicitly")
	setup({ filetypes = { "python" }, format_on_save = true })
	equal(formatter.filetypes(), { "python" }, "Filetype list can be restricted")
	equal(conform.formatters_by_ft.java, nil, "Removed filetype route restored")
	equal(#vim.api.nvim_get_autocmds({ group = "IntellijFormatter" }), 1, "One save hook")
	setup({ filetypes = { "python" }, format_on_save = true })
	equal(#vim.api.nvim_get_autocmds({ group = "IntellijFormatter" }), 1, "Repeated setup has one save hook")
	setup({ conform = false })
	equal(conform.formatters_by_ft.python, { "ruff_format" }, "Original route restored when integration disabled")
	equal(#vim.api.nvim_get_autocmds({ group = "IntellijFormatter" }), 0, "Save hook disabled on setup")
	for _, opts in ipairs({
		{ version = "other" },
		{ sha256 = "wrong" },
		{ timeout_ms = -1 },
		{ filetypes = { "lua" } },
		{ daemon = "yes" },
	}) do
		equal(pcall(setup, opts), false, "Invalid configuration rejected")
	end
	equal(formatter.supports("java"), true, "Invalid setup preserves prior configuration")
	local jar = fixture .. "/local.jar"
	vim.fn.writefile({ "fixture" }, jar)
	setup({ jar = jar })
	equal(formatter.available(), true, "Local JAR supported")
	local target = vim.api.nvim_create_buf(false, true)
	vim.bo[target].filetype = "python"
	local current = vim.api.nvim_get_current_buf()
	local called
	equal(
		formatter.format({ bufnr = target }, function(err)
			called = err or "OK"
		end),
		true,
		"Format calls Conform"
	)
	equal(called, "OK", "Callback invoked")
	equal(
		{ formatted_buffer.requested, formatted_buffer.current },
		{ target, target },
		"Conform executes in target buffer"
	)
	equal(vim.api.nvim_get_current_buf(), current, "Original current buffer restored")
	equal(formatted_buffer.opts.lsp_format, "never", "LSP fallback disabled")
	setup({ jar = fixture .. "/missing.jar" })
	equal(
		formatter.format({ bufnr = target }, function(err)
			called = err
		end),
		false,
		"Missing engine fails before formatting"
	)
	equal(called:find("IntellijFormatterInstall", 1, true) ~= nil, true, "Missing engine has actionable message")
	vim.api.nvim_buf_delete(target, { force = true })

	local engine = require("intellij-formatter.engine")
	local destination = fixture .. "/managed.jar"
	local good_hash = vim.fn.sha256("verified engine")
	local checksum = good_hash
	local download_code = 0
	local requests = 0
	vim.system = function(cmd, _, callback)
		requests = requests + 1
		if cmd[1] == "curl" then
			local output
			for index, value in ipairs(cmd) do
				if value == "--output" then
					output = cmd[index + 1]
				end
			end
			vim.fn.writefile({ "verified engine" }, output)
			callback({ code = download_code, stderr = "fixture download error" })
		else
			callback({ code = 0, stdout = checksum .. "  " .. cmd[#cmd] .. "\n" })
		end
		return {}
	end
	local function install(force)
		local completed, error
		engine.install(
			{ jar = destination, url = "https://example.invalid/fixture.jar", sha256 = good_hash, force = force },
			function(err)
				error, completed = err, true
			end
		)
		assert(
			vim.wait(1000, function()
				return completed
			end, 5),
			"Install callback timed out"
		)
		return error
	end
	equal(install(), nil, "Verified engine installed")
	equal(vim.fn.readfile(destination), { "verified engine" }, "Verified contents installed")
	requests = 0
	equal(install(), nil, "Existing installation reused")
	equal(requests, 0, "Existing engine makes no network request")
	checksum = string.rep("0", 64)
	equal(install(true):find("verification failed", 1, true) ~= nil, true, "Corrupt download rejected")
	equal(vim.fn.readfile(destination), { "verified engine" }, "Failed replacement preserves previous JAR")
	download_code = 22
	equal(install(true):find("download failed", 1, true) ~= nil, true, "Download failure reported")
	equal(vim.fn.glob(destination .. ".*.download"), "", "Temporary download files removed")
	vim.system = real_system
end

local ok, err = xpcall(run, debug.traceback)
vim.system = real_system
vim.fn.delete(fixture, "rf")
if not ok then
	vim.api.nvim_err_writeln(err)
	vim.cmd("cquit 1")
end
print("PASS: " .. checks .. " unit checks")
vim.cmd("qa!")
