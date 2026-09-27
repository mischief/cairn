-- SPDX-License-Identifier: ISC
-- experiments: features that use a language model through lgml. They
-- sit behind the hidden `cairn experiments` command, away from the
-- normal commands and the manual, and may change or go away.

local config = require "cairn.config"
local enrich = require "cairn.enrich"
local queue = require "cairn.queue"

local M = {}

-- queue(d, kinds) adds a job of each kind for every file of a matching
-- type that a document holds. Returns the number added.
local MIMES = {
	vision = { "image/png", "image/jpeg" },
	transcript = { "audio/%" },
}

local function enqueue(d, kinds)
	local n = 0

	for _, kind in ipairs(kinds) do
		for _, like in ipairs(MIMES[kind] or {}) do
			for _, f in ipairs(d:rows("SELECT DISTINCT f.id FROM file f "
			    .. "JOIN doc c ON c.content = f.id WHERE f.mime LIKE ?",
			    { like })) do
				local before = d.sql:total_changes()

				queue.enqueue(d, f.id, kind)
				n = n + d.sql:total_changes() - before
			end
		end
	end
	return n
end

M.list = {}

M.list.enrich = {
	usage = "enrich [--kind vision|transcript] [--model m] [--max n]",
	desc = "describe images and transcribe audio with lgml",
	run = function(p, d, path)
		local kinds = p.opts.kind and { p.opts.kind } or queue.VISION

		for _, k in ipairs(kinds) do
			if not MIMES[k] then
				error("unknown kind " .. k .. ": use vision or transcript", 0)
			end
		end
		print(("%d jobs queued"):format(enqueue(d, kinds)))

		local lock = enrich.lock(path .. ".enrich.lock")

		if not lock then
			print("another enricher is running")
			return
		end

		local n = enrich.run(d, { kinds = kinds,
		    model = p.opts.model or config.get(d, "lgml.model"),
		    max = math.tointeger(tonumber(p.opts.max)) }, function(s)
			io.stderr:write(s, "\n")
		end)

		print(("%d jobs"):format(n))
	end,
}

function M.main(p, d, path)
	local name = p.args[1]

	if not name then
		local names = {}

		for k in pairs(M.list) do
			names[#names + 1] = k
		end
		table.sort(names)
		print("cairn experiments: features that use a language model "
		    .. "through lgml.\nThey may change or go away.\n")
		for _, k in ipairs(names) do
			print(("  %s\n      %s"):format(M.list[k].usage, M.list[k].desc))
		end
		return
	end

	local e = M.list[name]

	if not e then
		error("no experiment " .. name .. "; run cairn experiments", 0)
	end
	table.remove(p.args, 1)
	e.run(p, d, path)
end

return M
