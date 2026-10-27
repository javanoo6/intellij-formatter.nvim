local M = {}
local queues = {}

function M.args(config, ctx, jar, source)
	local args = { "-jar", jar, "--format" }
	if vim.bo[ctx.buf].filetype == "java" and not ctx.range then
		if config.optimize_imports then
			args[#args + 1] = "--optimize-imports"
		end
		if config.rearrange then
			args[#args + 1] = "--rearrange"
		end
	end
	local editorconfig = config.editorconfig
	if type(editorconfig) == "function" then
		editorconfig = editorconfig(ctx)
	end
	if editorconfig then
		assert(type(editorconfig) == "string", "editorconfig must return a path or nil")
		editorconfig = vim.fn.fnamemodify(vim.fn.expand(editorconfig), ":p")
		vim.list_extend(args, { "--editorconfig", editorconfig })
	end
	-- The engine's daemon protocol splits paths on whitespace; argv does not.
	if not config.daemon or source:find("%s") or (editorconfig and editorconfig:find("%s")) then
		args[#args + 1] = "--no-daemon"
	end
	args[#args + 1] = source
	return args
end

-- Conform owns diff/range application and buffer updates. This function returns
-- formatted lines only, so it is safe to finish after an asynchronous install.
local function run(config, ctx, jar, lines, unchanged, callback)
	if not unchanged() then
		callback("Buffer or formatter settings changed while the engine was installing; newer edits were kept")
		return
	end
	local name = ".intellij-formatter-"
		.. vim.fn.getpid()
		.. "-"
		.. tostring(vim.uv.hrtime())
		.. "-"
		.. vim.fs.basename(ctx.filename)
	local temporary = vim.fs.joinpath(ctx.dirname, name)
	local fd
	local finished = false
	local function done(error, output)
		if finished then
			return
		end
		finished = true
		if fd then
			pcall(vim.uv.fs_close, fd)
			fd = nil
		end
		pcall(vim.uv.fs_unlink, temporary)
		callback(error, output)
	end
	local ok, err = pcall(function()
		local text = table.concat(lines, "\n") .. (vim.bo[ctx.buf].eol and "\n" or "")
		local open_error
		fd, open_error = vim.uv.fs_open(temporary, "wx", 384)
		assert(fd, "Cannot create formatter temporary file: " .. tostring(open_error))
		local written, write_error = vim.uv.fs_write(fd, text)
		assert(written == #text, "Cannot write formatter temporary file: " .. tostring(write_error))
		vim.uv.fs_close(fd)
		fd = nil
		local command = { config.java }
		vim.list_extend(command, M.args(config, ctx, jar, temporary))
		vim.system(
			command,
			{ text = true, timeout = config.timeout_ms },
			vim.schedule_wrap(function(result)
				if result.code ~= 0 then
					local diagnostic = vim.trim(result.stderr or "")
					if diagnostic == "" then
						diagnostic = vim.trim(result.stdout or "")
					end
					done("IntelliJ formatter failed (exit " .. result.code .. "): " .. diagnostic)
					return
				end
				if not unchanged() then
					done("Buffer or formatter settings changed during formatting; newer edits were kept")
					return
				end
				local read_ok, output = pcall(vim.fn.readfile, temporary, "b")
				if not read_ok then
					done("Cannot read formatted output: " .. tostring(output))
					return
				end
				for index, line in ipairs(output) do
					output[index] = line:gsub("\r$", "")
				end
				if #output > 1 and output[#output] == "" then
					table.remove(output)
				end
				if #output == 0 then
					output = { "" }
				end
				done(nil, output)
			end)
		)
	end)
	if not ok then
		done(tostring(err))
	end
end

-- The engine extracts its runtime and starts its daemon on the first request.
-- Serialize requests for a JAR so simultaneous first uses cannot race that setup.
function M.run(config, ctx, jar, lines, unchanged, callback)
	local queue = queues[jar] or { items = {}, running = false }
	queues[jar] = queue
	local function pump()
		if queue.running then
			return
		end
		local job = queue.items[1]
		if not job then
			if queues[jar] == queue then
				queues[jar] = nil
			end
			return
		end
		queue.running = true
		job()
	end
	queue.items[#queue.items + 1] = function()
		local finished = false
		local function done(err, output)
			if finished then
				return
			end
			finished = true
			table.remove(queue.items, 1)
			queue.running = false
			vim.schedule(pump)
			callback(err, output)
		end
		local ok, err = pcall(run, config, ctx, jar, lines, unchanged, done)
		if not ok then
			done(tostring(err))
		end
	end
	pump()
end

return M
