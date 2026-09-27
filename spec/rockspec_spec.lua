-- SPDX-License-Identifier: ISC
local dirent = require "posix.dirent"

describe("rockspec", function()
	it("lists every module under cairn/", function()
		local f = assert(io.open("cairn-scm-1.rockspec"))
		local spec = f:read("a")

		f:close()
		for name in dirent.files("cairn") do
			local mod = name:match("^(.+)%.lua$")

			if mod then
				assert.is_truthy(spec:find("['cairn." .. mod .. "']", 1, true),
				    "cairn-scm-1.rockspec lacks cairn." .. mod)
			end
		end
	end)
end)
