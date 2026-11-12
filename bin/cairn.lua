#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: ISC
-- cairn: a knowledge store for agents and people. See DESIGN.md.

-- luarocks installs this script as <tree>/bin/cairn with no wrapper, so
-- the process shows a short command line. Add the tree's module paths
-- here; the environment may not have them.
local tree = (arg and arg[0] or ""):match("^(.*)/bin/[^/]+$")

if tree then
	local v = _VERSION:match("%d+%.%d+")

	package.path = ("%s/share/lua/%s/?.lua;%s/share/lua/%s/?/init.lua;")
	    :format(tree, v, tree, v) .. package.path
	package.cpath = ("%s/lib/lua/%s/?.so;"):format(tree, v) .. package.cpath
end

-- Show "cairn mcp" in ps instead of the interpreter and its arguments.
-- Optional: without the compiled module the title stays as it is.
do
	local ok, pt = pcall(require, "cairn.proctitle")

	if ok then
		local t = { "cairn" }

		for i = 1, #arg do t[#t + 1] = arg[i] end
		pt.set(table.concat(t, " "), "cairn")
	end
end

local cli = require "cairn.cli"

os.exit(cli.main(arg))
