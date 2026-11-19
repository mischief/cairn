-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local proc = require "cairn.proc"
local tmp = require "cairn.tmp"

local function exists(path)
	return require("posix.sys.stat").stat(path) ~= nil
end

describe("tmp", function()
	it("removes the directory and its files after", function()
		local seen

		tmp.with(function(dir)
			seen = dir
			assert(io.open(dir .. "/a", "w")):close()
			assert.is_true(exists(dir .. "/a"))
		end)
		assert.is_false(exists(seen))
	end)

	it("removes the directory when fn raises", function()
		local seen
		local ok, err = pcall(tmp.with, function(dir)
			seen = dir
			assert(io.open(dir .. "/a", "w")):close()
			error("boom", 0)
		end)

		assert.is_false(ok)
		assert.equal("boom", err)
		assert.is_false(exists(seen))
	end)

	it("gives a child a nameless input it can read twice", function()
		tmp.with(function(dir)
			local path = tmp.input(dir, "hello\n")
			local names = {}

			for f in require("posix.dirent").files(dir) do
				if f ~= "." and f ~= ".." then
					names[#names + 1] = f
				end
			end
			assert.matches("^/dev/fd/%d+$", path)
			assert.same({}, names)
			for _ = 1, 2 do
				tmp.rewind()

				local out, code = proc.run({ "cat", path })

				assert.equal(0, code)
				assert.equal("hello\n", out)
			end
		end)
	end)

	it("removes the directory on SIGTERM and dies by the signal", function()
		local signal = require "posix.signal"
		local stdlib = require "posix.stdlib"
		local unistd = require "posix.unistd"
		local wait = require "posix.sys.wait"
		local base = assert(stdlib.mkdtemp((os.getenv("TMPDIR") or "/tmp")
		    .. "/spec.XXXXXX"))
		-- the child prints its directory, then waits to be killed
		local script = [[
			package.path = "./?.lua;" .. package.path
			require("cairn.tmp").with(function(dir)
				io.write(dir, "\n")
				io.flush()
				while true do end
			end)
		]]
		local r, w = assert(unistd.pipe())
		local pid = assert(unistd.fork())

		if pid == 0 then
			unistd.close(r)
			unistd.dup2(w, 1)
			stdlib.setenv("TMPDIR", base)
			unistd.execp("lua5.4", { [0] = "lua5.4", "-e", script })
			unistd._exit(127)
		end
		unistd.close(w)

		local dir = unistd.read(r, 4096):match("^(.-)\n")

		unistd.close(r)
		assert.matches("^" .. base .. "/cairn%.", dir)
		assert.is_true(exists(dir))
		signal.kill(pid, signal.SIGTERM)

		local _, how, sig = wait.wait(pid)

		assert.equal("killed", how)
		assert.equal(signal.SIGTERM, sig)
		assert.is_false(exists(dir))
		unistd.rmdir(base)
	end)
end)
