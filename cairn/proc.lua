-- proc: run a command with no shell and collect its output.

local fcntl = require "posix.fcntl"
local poll = require "posix.poll"
local unistd = require "posix.unistd"
local wait = require "posix.sys.wait"

local M = {}

-- output beyond this is an error, not an unbounded string
M.MAXOUT = 256 * 1024 * 1024

-- run(argv[, opts]) -> stdout, exit code, stderr. opts.tick is called
-- every opts.every seconds while the command runs; an error in it
-- kills the command. Exit code 127 means the command was not found.
function M.run(argv, opts)
	opts = opts or {}

	local r, w = assert(unistd.pipe())
	local er, ew = assert(unistd.pipe())
	local pid = assert(unistd.fork())

	if pid == 0 then
		unistd.close(r)
		unistd.close(er)
		unistd.dup2(w, 1)
		unistd.dup2(ew, 2)

		local null = fcntl.open("/dev/null", fcntl.O_RDONLY)

		if null then
			unistd.dup2(null, 0)
		end

		local args = {}

		for i = 2, #argv do
			args[i - 1] = argv[i]
		end
		args[0] = argv[1]
		unistd.execp(argv[1], args)
		unistd._exit(127)
	end
	unistd.close(w)
	unistd.close(ew)

	local out, err = {}, {}
	local size = 0
	local open = { [r] = out, [er] = err }
	local every = (opts.every or 30) * 1000
	local failure

	while next(open) do
		local fds = {}

		for fd in pairs(open) do
			fds[fd] = { events = { IN = true } }
		end

		local n = poll.poll(fds, opts.tick and every or -1)

		if n == 0 then
			local ok, why = pcall(opts.tick)

			if not ok then
				failure = why
				break
			end
		elseif n and n > 0 then
			for fd, p in pairs(fds) do
				if p.revents and (p.revents.IN or p.revents.HUP) then
					local s = unistd.read(fd, 65536)

					if not s or s == "" then
						unistd.close(fd)
						open[fd] = nil
					else
						local buf = open[fd]

						buf[#buf + 1] = s
						size = size + #s
						if size > M.MAXOUT then
							failure = "output too large"
							break
						end
					end
				end
			end
			if failure then
				break
			end
		end
	end
	if failure then
		require("posix.signal").kill(pid, 9)
		for fd in pairs(open) do
			unistd.close(fd)
		end
	end

	local _, how, status = wait.wait(pid)

	if failure then
		error(failure, 0)
	end
	if how ~= "exited" then
		status = 128 + (status or 0)
	end
	return table.concat(out), status, table.concat(err)
end

-- spawn(argv, env) starts a detached process in its own session and
-- does not wait for it.
function M.spawn(argv, env)
	local pid = assert(unistd.fork())

	if pid == 0 then
		unistd.setpid("s")
		if unistd.fork() ~= 0 then
			unistd._exit(0)
		end

		local null = fcntl.open("/dev/null", fcntl.O_RDWR)

		for fd = 0, 2 do
			unistd.dup2(null, fd)
		end

		local stdlib = require "posix.stdlib"

		for k, v in pairs(env or {}) do
			stdlib.setenv(k, v)
		end

		local args = {}

		for i = 2, #argv do
			args[i - 1] = argv[i]
		end
		args[0] = argv[1]
		unistd.execp(argv[1], args)
		unistd._exit(127)
	end
	wait.wait(pid)
end

return M
