local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local conform_path = vim.env.CONFORM_PATH or (vim.fn.stdpath("data") .. "/lazy/conform.nvim")
assert(vim.fn.isdirectory(conform_path) == 1, "Set CONFORM_PATH to a conform.nvim checkout")
vim.opt.runtimepath:append(conform_path)
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/runtime", "p")
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind)
	return kind == "data" and fixture .. "/data" or stdpath(kind)
end
local java_options = vim.env.JAVA_TOOL_OPTIONS
vim.env.JAVA_TOOL_OPTIONS = "-Djava.io.tmpdir=" .. fixture .. "/runtime"
local formatter = require("intellij-formatter")
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks = checks + 1
end
local function wait_for(predicate, timeout)
	assert(vim.wait(timeout or 15000, predicate, 10), "Timed out")
end
local function buffer(name, lines)
	local path = fixture .. "/project/" .. name
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(lines, path)
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf })
	return buf
end
local function content(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local opts = { notify = false, jar = vim.env.FORMATTER_JAR }
local function format(buf, extra)
	local called, error
	formatter.format(vim.tbl_extend("force", { bufnr = buf, async = false }, extra or {}), function(err)
		error, called = err, true
	end)
	check(called and not error, "Formatting failed for " .. vim.api.nvim_buf_get_name(buf) .. ": " .. tostring(error))
end
local function run()
	formatter.setup(opts)
	if not opts.jar then
		local completed, error
		formatter.install({}, function(err)
			error, completed = err, true
		end)
		wait_for(function()
			return completed
		end, 210000)
		check(not error, "Engine installation failed: " .. tostring(error))
	end
	check(formatter.available(), "Engine is available")
	buffer(".editorconfig", { "root = true", "", "[*]", "indent_style = space", "indent_size = 2" })
	local samples = {
		{
			"Sample.java",
			{ "import java.util.List;", "class Sample{int sum(int a,int b){return a+b;}}" },
			"return a + b;",
		},
		{ "sample.py", { "def add(a,b):", "    return a+b" }, "\n  return a + b" },
		{ "sample.pyw", { "def add(a,b):", "    return a+b" }, "def add(a, b):" },
		{ "sample.pyi", { "def add(a:int,b:int)->int: ..." }, "def add(a: int, b: int) -> int:" },
		{ "sample.json", { '{"key":1}' }, '"key": 1' },
		{ "sample.jsonc", { "// keep this comment", '{"key":1}' }, "// keep this comment" },
		{ "sample.json5", { "{key:'value',}" }, "key: 'value'" },
		{ "sample.toml", { "[section]", "key=1" }, "key = 1" },
		{ "sample.xml", { "<root><child>value</child></root>" }, "\n  <child>" },
		{ "sample.html", { "<html><body><div><p>Hello</p></div></body></html>" }, "<html>\n" },
		{
			"sample.xhtml",
			{ '<html xmlns="http://www.w3.org/1999/xhtml"><body><div><p>Hello</p></div></body></html>' },
			"<body>\n",
		},
		{
			"sample.xsl",
			{
				'<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0"><xsl:template match="/"><output/></xsl:template></xsl:stylesheet>',
			},
			"\n  <xsl:template",
		},
		{ "sample.yaml", { "root:", "   child:  1" }, "\n  child: 1" },
		{ "sample.yml", { "root:", "   child:  1" }, "\n  child: 1" },
		{ "sample.sh", { "#!/bin/bash", "if true;then", "echo  hello", "fi" }, "\n  echo hello" },
		{ "sample.bash", { "#!/bin/bash", "if true;then", "echo  hello", "fi" }, "if true; then" },
		{ "sample.zsh", { "#!/bin/zsh", "if true;then", "echo  hello", "fi" }, "if true; then" },
		{ "shell-script", { "#!/usr/bin/env bash", "if true;then", "echo  hello", "fi" }, "if true; then" },
		{ "sample.md", { "|a|b|", "|---|---|", "|1|2|" }, "| a" },
	}
	for _, sample in ipairs(samples) do
		local buf = buffer(sample[1], sample[2])
		format(buf)
		local formatted = content(buf)
		check(formatted:find(sample[3], 1, true), sample[1] .. " was not formatted: " .. formatted)
		check(formatted ~= table.concat(sample[2], "\n"), sample[1] .. " did not change")
		if sample[1] == "Sample.java" then
			check(not formatted:find("java.util.List", 1, true), "Unused Java import removed")
		end
		format(buf)
		check(content(buf) == formatted, sample[1] .. " formatting is idempotent")
	end
	local spaced = buffer("space ' ; $(touch INJECTED)/sample.py", { "value=1+2" })
	format(spaced)
	check(content(spaced) == "value = 1 + 2", "Paths with spaces and shell characters are safe")
	check(vim.fn.filereadable(fixture .. "/project/INJECTED") == 0, "No shell command injection")
	local ranged = buffer("range.py", { "first=1", "# unchanged", "# separator", "# another separator", "second=2" })
	format(ranged, { range = { start = { 1, 0 }, ["end"] = { 1, 7 } } })
	check(
		content(ranged) == "first = 1\n# unchanged\n# separator\n# another separator\nsecond=2",
		"Range filters a separate unselected edit hunk: " .. content(ranged)
	)
	local invalid = buffer("invalid.sh", { "#!/bin/bash", "if true; then" })
	local failed
	formatter.format({ bufnr = invalid }, function(err)
		failed = err
	end)
	check(failed ~= nil, "Invalid shell syntax returns an error")
	check(content(invalid) == "#!/bin/bash\nif true; then", "Invalid script preserved")
	local subsequent = buffer("after-error.py", { "value=3+4" })
	format(subsequent)
	check(content(subsequent) == "value = 3 + 4", "Daemon remains usable after a failed request")
	local direct = buffer("conform-direct.py", { "value=5+6" })
	local direct_error
	check(
		require("conform").formatters_by_ft.python.timeout_ms == 30000,
		"Direct Conform calls inherit the configured timeout"
	)
	require("conform").format({ bufnr = direct }, function(error)
		direct_error = error
	end)
	check(
		not direct_error and content(direct) == "value = 5 + 6",
		"Direct Conform integration formats supported buffers"
	)

	local async = buffer("async.py", { "value=1+2" })
	local completed
	formatter.format({ bufnr = async, async = true }, function()
		completed = true
	end)
	vim.api.nvim_buf_set_lines(async, 0, -1, false, { "value=99" })
	wait_for(function()
		return completed
	end)
	check(content(async) == "value=99", "Stale async formatting cannot overwrite newer buffer edits")

	formatter.setup(vim.tbl_extend("force", opts, { format_on_save = true }))
	local on_save = buffer("save.yaml", { "root:", "   child:  1" })
	vim.api.nvim_buf_call(on_save, function()
		vim.cmd("silent write")
	end)
	check(
		table.concat(vim.fn.readfile(vim.api.nvim_buf_get_name(on_save)), "\n") == "root:\n  child: 1",
		"Format-on-save writes formatted content"
	)
end

local ok, err = xpcall(run, debug.traceback)
local stopped = false
formatter.stop(function()
	stopped = true
end)
vim.wait(10000, function()
	return stopped
end, 10)
vim.fn.stdpath = stdpath
vim.env.JAVA_TOOL_OPTIONS = java_options
vim.fn.delete(fixture, "rf")
if not ok then
	vim.api.nvim_err_writeln(err)
	vim.cmd("cquit 1")
end
print("PASS: " .. checks .. " integration checks")
vim.cmd("qa!")
