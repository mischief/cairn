-- SPDX-License-Identifier: ISC
-- receipt: what a classifier wrote into a document, as one metadata
-- value under gen.NAME: "v=3 model=gemma-4-26b content=12@TIME
-- vocab=1a2b3c4d wrote=compilers,linkers". A later run uses it to find
-- new, changed, and out-of-date documents, and to leave alone those a
-- person has edited since. Only classifiers read receipts.

local M = {}

-- key(name) -> the metadata key of a classifier's receipt
function M.key(name)
	return "gen." .. name
end

M.FIELDS = { "v", "model", "content", "vocab", "wrote" }

-- parse(s) -> table of the fields, or nil
function M.parse(s)
	if type(s) ~= "string" then
		return nil
	end

	local r = {}

	for k, v in s:gmatch("(%w+)=(%S*)") do
		r[k] = v
	end
	return next(r) and r or nil
end

-- format(r) -> the receipt as one line
function M.format(r)
	local out = {}

	for _, k in ipairs(M.FIELDS) do
		if r[k] ~= nil then
			out[#out + 1] = k .. "=" .. tostring(r[k])
		end
	end
	return table.concat(out, " ")
end

-- content(d, file) -> a key that changes when a file's bytes or its
-- extracted text change
function M.content(d, file)
	if not file then
		return "none"
	end
	return ("%d@%s"):format(file, d:row("SELECT max(created) FROM extract "
	    .. "WHERE file = ?", { file }) or "-")
end

-- hash(s) -> 8 hex digits of the SHA-256 of s, for a vocabulary
function M.hash(s)
	return (require("cairn.sha256").sum(s):sub(1, 4):gsub(".", function(c)
		return ("%02x"):format(c:byte())
	end))
end

-- state(r, want, now) -> "new", "edited" (someone changed what the
-- classifier wrote), "changed" (content), "old" (classifier version),
-- "model", "vocab", or "current". want holds v, model, content, and
-- vocab; now is what the document holds today, in the form of r.wrote.
function M.state(r, want, now)
	if not r then
		return "new"
	end
	if (r.wrote or "") ~= (now or "") then
		return "edited"
	end
	if r.content ~= want.content then
		return "changed"
	end
	if (tonumber(r.v) or 0) < want.v then
		return "old"
	end
	if r.model ~= want.model then
		return "model"
	end
	if r.vocab ~= want.vocab then
		return "vocab"
	end
	return "current"
end

-- which(opts) -> set of states to run: new and changed by default;
-- --stale adds old, model, and vocab; --all runs every state but edited
function M.which(opts)
	local s = { new = true, changed = true }

	if opts.stale or opts.all then
		s.old, s.model, s.vocab = true, true, true
	end
	if opts.all then
		s.current = true
	end
	return s
end

return M
