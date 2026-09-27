-- SPDX-License-Identifier: ISC
-- secret: refuse text that looks like it holds a credential. There is
-- no deletion, so a stored secret stays forever.

local M = {}

local function run(class, n)
	return class:rep(n) .. class .. "*"
end

-- name, Lua pattern
M.PATTERNS = {
	{ "openai-style key", "sk%-" .. run("[%w_%-]", 20) },
	{ "github token", "gh[pousr]_" .. run("%w", 30) },
	{ "github token", "github_pat_" .. run("[%w_]", 30) },
	{ "aws access key", "AKIA" .. run("[A-Z0-9]", 16) },
	{ "slack token", "xox[abprs]%-" .. run("[%w%-]", 10) },
	{ "private key", "%-%-%-%-%-BEGIN [%u ]*PRIVATE KEY%-%-%-%-%-" },
}

local KEYWORDS = { "key", "token", "secret", "passw", "credential" }

-- wordy(s) -> true when s is words and short numbers joined by - or _,
-- such as a file name in a URL: us-18-Valsorda-Squeezing-A-Key-Through
local function wordy(s)
	local parts = 0

	for part in s:gmatch("[^%-_]+") do
		if not (part:match("^%a+$") or part:match("^%d%d?%d?%d?$")) then
			return false
		end
		parts = parts + 1
	end
	return parts >= 3
end

-- bits of entropy per character of s
local function entropy(s)
	local counts = {}

	for i = 1, #s do
		local c = s:sub(i, i)

		counts[c] = (counts[c] or 0) + 1
	end

	local h = 0

	for _, n in pairs(counts) do
		local p = n / #s

		h = h - p * math.log(p, 2)
	end
	return h
end

-- check(text) -> nil when clean, or the name of what matched
function M.check(text)
	if type(text) ~= "string" then
		return nil
	end
	for _, p in ipairs(M.PATTERNS) do
		if text:find(p[2]) then
			return p[1]
		end
	end
	for line in text:gmatch("[^\n]+") do
		-- URLs carry long mixed paths and commit hashes; the patterns
		-- above still see a key inside one
		line = line:gsub("%a[%w+.-]*://[^%s)%]>\"'`]+", " ")

		local low = line:lower()

		for _, k in ipairs(KEYWORDS) do
			if low:find(k, 1, true) then
				for word in line:gmatch("[%w+/=_%-]+") do
					-- keys mix cases and digits; paths and
					-- identifiers do not. A CID looks like a key
					-- but names public content.
					if #word >= 32 and word:find("%d")
					    and word:find("%u") and word:find("%l")
					    and entropy(word) > 4.0 and not wordy(word)
					    and not require("cairn.cid").parse(word) then
						return "high-entropy string near \""
						    .. k .. "\""
					end
				end
				break
			end
		end
	end
	return nil
end

return M
