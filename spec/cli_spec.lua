-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path
local cli = require "cairn.cli"

describe("progname", function()
	local saved

	before_each(function()
		saved = _G.arg
	end)
	after_each(function()
		_G.arg = saved
	end)

	it("comes from arg[0]", function()
		_G.arg = { [0] = "/home/u/bin/mydb" }
		assert.equal("mydb", cli.progname())
	end)

	it("names commands, not URIs or paths", function()
		_G.arg = { [0] = "mydb" }
		assert.equal("mydb: x; mydb get 'cairn:ID' at a/cairn.db; mydb\n",
		    cli.named("cairn: x; cairn get 'cairn:ID' at a/cairn.db; cairn\n"))
	end)

	it("leaves text alone as cairn", function()
		_G.arg = { [0] = "/x/cairn" }
		assert.equal("cairn get", cli.named("cairn get"))
	end)
end)
