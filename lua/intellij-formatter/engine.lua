local M = {}
local installing = false

function M.checksum_command(path)
	for _, tool in ipairs({
		{ "sha256sum", path },
		{ "shasum", "-a", "256", path },
		{ "openssl", "dgst", "-sha256", path },
		{ "certutil", "-hashfile", path, "SHA256" },
	}) do
		if vim.fn.executable(tool[1]) == 1 then
			return tool
		end
	end
end

-- Keep the previous installation intact until the replacement is downloaded and verified.
function M.install(opts, callback)
	callback = callback or function() end
	local function finish(err, path)
		callback(err, path)
	end
	if installing then
		finish("An engine installation is already running")
		return
	end
	if vim.fn.filereadable(opts.jar) == 1 and not opts.force then
		finish(nil, opts.jar)
		return
	end
	if vim.fn.executable("curl") ~= 1 then
		finish(
			"Engine installation requires curl on PATH; alternatively configure jar with a local formatter-cli-full.jar"
		)
		return
	end
	if not M.checksum_command(opts.jar) then
		finish("Install sha256sum, shasum, openssl, or certutil to verify the engine download")
		return
	end
	vim.fn.mkdir(vim.fs.dirname(opts.jar), "p")
	local temporary = opts.jar .. "." .. vim.fn.getpid() .. ".download"
	installing = true
	local function done(err)
		installing = false
		pcall(vim.uv.fs_unlink, temporary)
		finish(err, not err and opts.jar or nil)
	end
	local function spawn(cmd, options, on_exit)
		local ok, err = pcall(vim.system, cmd, options, vim.schedule_wrap(on_exit))
		if not ok then
			done(tostring(err))
		end
	end
	spawn({
		"curl",
		"--fail",
		"--location",
		"--retry",
		"2",
		"--connect-timeout",
		"15",
		"--max-time",
		"180",
		"--output",
		temporary,
		opts.url,
	}, { text = true, timeout = 190000 }, function(download)
		if download.code ~= 0 then
			done("Engine download failed: " .. vim.trim(download.stderr or "curl exited " .. download.code))
			return
		end
		local checksum = M.checksum_command(temporary)
		spawn(checksum, { text = true, timeout = 30000 }, function(result)
			local digest
			if checksum[1] == "openssl" then
				digest = (result.stdout or ""):match("=%s*(%x+)%s*$")
			elseif checksum[1] == "certutil" then
				for line in (result.stdout or ""):gmatch("[^\r\n]+") do
					local token = line:gsub("%s", "")
					if #token == 64 and token:match("^%x+$") then
						digest = token
						break
					end
				end
			else
				digest = (result.stdout or ""):match("^\\?(%x+)%s")
			end
			if result.code ~= 0 or not digest or digest:lower() ~= opts.sha256:lower() then
				done("Engine SHA-256 verification failed; the previous installation was kept")
				return
			end
			local ok, err = vim.uv.fs_rename(temporary, opts.jar)
			done(not ok and ("Cannot install verified engine: " .. tostring(err)) or nil)
		end)
	end)
end

return M
