local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local stdpath, system = vim.fn.stdpath, vim.system
vim.fn.stdpath = function(kind)
	return kind == "data" and fixture .. "/data" or stdpath(kind)
end
local checks = 0
local function check(value, message)
	assert(value, message)
	checks = checks + 1
end
local conform = { formatters_by_ft = {} }
function conform.setup(opts)
	conform.formatters = opts.formatters
	conform.formatters_by_ft = vim.tbl_extend("force", conform.formatters_by_ft, opts.formatters_by_ft)
end
function conform.format(opts, callback)
	local definition = conform.formatters.intellij_formatter
	local buf = opts.bufnr
	local filename = vim.api.nvim_buf_get_name(buf)
	definition.format(
		definition,
		{ buf = buf, filename = filename, dirname = vim.fs.dirname(filename), range = opts.range },
		vim.api.nvim_buf_get_lines(buf, 0, -1, false),
		function(err, lines)
			if not err then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			end
			callback(err, not err)
		end
	)
	return true
end
package.loaded.conform = conform
local formatter = require("intellij-formatter")
local hash = vim.fn.sha256("test engine")
local digest = hash
local downloads, jobs = 0, 0
local pending
vim.system = function(command, _, callback)
	if command[1] == "curl" then
		downloads = downloads + 1
		local output
		for index, arg in ipairs(command) do
			if arg == "--output" then
				output = command[index + 1]
			end
		end
		vim.fn.writefile({ "test engine" }, output)
		pending = callback
	elseif command[1] == "java" then
		jobs = jobs + 1
		local path = command[#command]
		local lines = vim.fn.readfile(path)
		for index, line in ipairs(lines) do
			lines[index] = line:gsub("=", " = ")
		end
		vim.fn.writefile(lines, path)
		callback({ code = 0, stdout = "", stderr = "" })
	else
		callback({ code = 0, stdout = digest .. "  " .. command[#command] .. "\n" })
	end
	return {}
end
local function setup(opts)
	formatter.setup(vim.tbl_extend("force", { notify = false, sha256 = hash }, opts or {}))
end
local function buffer(name, text)
	local path = fixture .. "/" .. name .. ".py"
	vim.fn.writefile({ "disk_original=99" }, path)
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.bo[buf].filetype = "python"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
	return buf, path
end
local function start(buf)
	local state = {}
	state.started = formatter.format({ bufnr = buf, async = true }, function(err)
		state.err, state.done = err, true
	end)
	return state
end
local function complete(code)
	local callback = pending
	pending = nil
	callback({ code = code or 0, stderr = "fixture network error" })
end
local function wait(state)
	assert(
		vim.wait(1000, function()
			return state.done
		end, 5),
		"Queued format did not complete"
	)
end
local function text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function run()
	setup()
	check(not formatter.available(), "Fresh installation starts without a JAR")
	check(formatter.conform_formatter().condition(), "First-use formatter remains available")
	check(downloads == 0, "Availability inspection does not download anything")
	local first, original = buffer("first", "value=1")
	local second = buffer("second", "value=2")
	local a, b = start(first), start(second)
	check(a.started and b.started and not a.done and not b.done, "Requests queue during installation")
	check(downloads == 1, "Concurrent requests share one download")
	complete()
	wait(a)
	wait(b)
	check(not a.err and not b.err, "Both queued requests succeed")
	check(text(first) == "value = 1" and text(second) == "value = 2", "First-use requests format automatically")
	check(vim.fn.readfile(original)[1] == "disk_original=99", "Formatting leaves source files untouched")
	check(formatter.available() and formatter.timeout() == 30000, "Verified engine is cached with the normal timeout")
	local third = buffer("third", "value=3")
	local c = start(third)
	wait(c)
	check(not c.err and downloads == 1, "Cached engine formats without another download")

	vim.fn.delete(formatter.jar_path())
	local changed = buffer("changed", "value=4")
	local before_jobs = jobs
	local stale = start(changed)
	vim.api.nvim_buf_set_lines(changed, 0, -1, false, { "newer=5" })
	complete()
	wait(stale)
	check(stale.err and text(changed) == "newer=5", "Edits made during download are preserved")
	check(jobs == before_jobs, "Stale request never starts a formatter job")

	vim.fn.delete(formatter.jar_path())
	local bad_a, bad_b = start(first), start(second)
	digest = string.rep("0", 64)
	complete()
	wait(bad_a)
	wait(bad_b)
	check(bad_a.err and bad_b.err, "Checksum failure reaches every waiting request")
	check(not formatter.available() and jobs == before_jobs, "Unverified engine is never executed")
	check(text(first) == "value = 1", "Failed download does not change buffers")
	digest = hash
	local retry = start(third)
	complete()
	wait(retry)
	check(not retry.err and formatter.available(), "Next request can recover from a failed download")

	vim.fn.delete(formatter.jar_path())
	setup({ auto_install = false })
	local count = downloads
	local disabled = start(first)
	check(
		disabled.done and disabled.err and not disabled.started and downloads == count,
		"Offline opt-out never downloads"
	)
	setup({ jar = fixture .. "/missing.jar" })
	local custom = start(first)
	check(custom.err and downloads == count, "Custom missing JAR is not silently replaced")
	setup({ java = fixture .. "/missing-java" })
	local no_java = start(first)
	check(no_java.err and downloads == count, "Missing Java fails without a download")
	setup()
	local reconfigured = start(first)
	setup({ daemon = false })
	complete()
	wait(reconfigured)
	check(reconfigured.err and jobs == before_jobs + 1, "Reconfiguration cancels pending formatting safely")
	check(vim.fn.glob(fixture .. "/.intellij-formatter-*") == "", "Temporary formatting files are cleaned up")
end
local ok, err = xpcall(run, debug.traceback)
vim.system, vim.fn.stdpath = system, stdpath
vim.fn.delete(fixture, "rf")
if not ok then
	vim.api.nvim_err_writeln(err)
	vim.cmd("cquit 1")
end
print("PASS: " .. checks .. " automatic-install checks")
vim.cmd("qa!")
