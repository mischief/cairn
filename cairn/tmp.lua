-- SPDX-License-Identifier: ISC
-- tmp: private temporary directories that are removed on every exit
-- path, including SIGTERM, SIGINT, and SIGHUP. A SIGKILL leaves the
-- directory behind, but an input() file has no name to leave.

local dirent = require "posix.dirent"
local fcntl = require "posix.fcntl"
local signal = require "posix.signal"
local stdlib = require "posix.stdlib"
local unistd = require "posix.unistd"

local M = {}

-- live scopes, innermost last: { dir = path, fds = { fd, ... } }
local live = {}
local owner

local function remove(dir)
	for f in dirent.files(dir) do
		if f ~= "." and f ~= ".." then
			os.remove(dir .. "/" .. f)
		end
	end
	unistd.rmdir(dir)
end

-- clean() removes every live directory. Only the process that made them
-- does so: a child between fork and exec runs Lua handlers too.
function M.clean()
	if unistd.getpid() ~= owner then
		return
	end
	for i = #live, 1, -1 do
		pcall(remove, live[i].dir)
		live[i] = nil
	end
end

local function onsignal(sig)
	M.clean()
	signal.signal(sig, signal.SIG_DFL)
	signal.raise(sig)
end

-- the handlers stay for the life of the process. A signal that was
-- ignored when cairn started, such as SIGHUP under nohup, stays ignored.
local function install()
	if owner then
		return
	end
	owner = unistd.getpid()
	for _, sig in ipairs({ signal.SIGTERM, signal.SIGINT, signal.SIGHUP }) do
		if signal.signal(sig, onsignal) == signal.SIG_IGN then
			signal.signal(sig, signal.SIG_IGN)
		end
	end
end

-- with(fn) calls fn(dir) with a new private directory and removes the
-- directory and its files after. Errors from fn are raised again.
function M.with(fn)
	install()

	local base = os.getenv("TMPDIR") or "/tmp"
	local dir = assert(stdlib.mkdtemp(base .. "/cairn.XXXXXX"))
	local scope = { dir = dir, fds = {} }

	live[#live + 1] = scope

	local res = table.pack(pcall(fn, dir))

	for _, fd in ipairs(scope.fds) do
		unistd.close(fd)
	end
	for i = #live, 1, -1 do
		if live[i] == scope then
			table.remove(live, i)
		end
	end
	pcall(remove, dir)
	if not res[1] then
		error(res[2], 0)
	end
	return table.unpack(res, 2, res.n)
end

-- input(dir, data) -> a /dev/fd path that reads data. The file is
-- unlinked at once and the descriptor is closed when with() returns.
-- Child processes inherit the descriptor.
function M.input(dir, data)
	local path = dir .. "/input"
	local f = assert(io.open(path, "wb"))

	assert(f:write(data))
	f:close()

	local fd = assert(fcntl.open(path, fcntl.O_RDONLY))

	os.remove(path)
	for _, s in ipairs(live) do
		if s.dir == dir then
			s.fds[#s.fds + 1] = fd
		end
	end
	return "/dev/fd/" .. fd
end

-- rewind() seeks every input() descriptor to the start. On OpenBSD,
-- opening /dev/fd/N duplicates the descriptor, so a child shares its
-- offset with the previous child. Call it before each command.
function M.rewind()
	for _, s in ipairs(live) do
		for _, fd in ipairs(s.fds) do
			unistd.lseek(fd, 0, unistd.SEEK_SET)
		end
	end
end

return M
