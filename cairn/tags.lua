-- SPDX-License-Identifier: ISC
-- tags: tag names, aliases, and close-name suggestions. Tags are the
-- topics; a "/" makes a nested name.

local M = {}

M.MAX = 32

-- normalize(s) -> tag name, or nil, reason
function M.normalize(s)
	if type(s) ~= "string" then
		return nil, "tag is not a string"
	end

	local t = s:lower():gsub("%s+", "-"):gsub("^/+", ""):gsub("/+$", "")

	if #t < 1 or #t > 40 then
		return nil, "tag \"" .. s .. "\" must be 1 to 40 characters"
	end
	if not t:match("^[a-z0-9/-]+$") or t:find("//", 1, true) then
		return nil, "tag \"" .. s .. "\" may hold only a-z, 0-9, - and /"
	end
	return t
end

-- resolve(d, name) -> the tag an alias points to, or name
function M.resolve(d, name)
	return d:row("SELECT name FROM tag_alias WHERE alias = ?", { name })
	    or name
end

-- topics are tags under this prefix; each needs an about page
M.TOPIC = "topic/"

-- clean(d, list, had) -> sorted unique resolved names, or nil, reason.
-- A topic/ tag must have an about page, unless the set had (the tags
-- the document holds now) already holds it.
function M.clean(d, list, had)
	local seen, out = {}, {}

	for _, s in ipairs(list or {}) do
		local t, err = M.normalize(s)

		if not t then
			return nil, err
		end
		t = M.resolve(d, t)
		if (t == "topic" or t:sub(1, #M.TOPIC) == M.TOPIC)
		    and not (had and had[t])
		    and not d:row("SELECT 1 FROM doc WHERE about = ? AND hidden = 0 "
		    .. "AND superseded_by IS NULL", { t }) then
			return nil, ("no topic %s: cairn tags topic/ lists the topics; a "
			    .. "new one needs an about page (cairn put --about %s)")
			    :format(t, t)
		end
		if not seen[t] then
			seen[t] = true
			out[#out + 1] = t
		end
	end
	if #out > M.MAX then
		return nil, "more than " .. M.MAX .. " tags"
	end
	table.sort(out)
	return out
end

local function distance(a, b)
	if math.abs(#a - #b) > 2 then
		return 3
	end

	local prev = {}

	for j = 0, #b do
		prev[j] = j
	end
	for i = 1, #a do
		local cur = { [0] = i }

		for j = 1, #b do
			local cost = a:byte(i) == b:byte(j) and 0 or 1

			cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1,
			    prev[j - 1] + cost)
		end
		prev = cur
	end
	return prev[#b]
end

-- close(d, name) -> existing tags with a close name, for a new tag
function M.close(d, name)
	if d:row("SELECT 1 FROM tag WHERE name = ?", { name })
	    or d:row("SELECT 1 FROM doc WHERE about = ?", { name }) then
		return {}
	end

	local out = {}
	local st = d.sql:prepare("SELECT DISTINCT name FROM tag")
	-- a shared namespace such as topic/ says nothing; compare what
	-- follows the last "/"
	local last = name:match("([^/]*)$")

	for t in st:urows() do
		local tl = t:match("([^/]*)$")
		local shared = 0

		while shared < math.min(#tl, #last)
		    and tl:byte(shared + 1) == last:byte(shared + 1) do
			shared = shared + 1
		end
		-- short names match too much: "c" sits inside most words
		local short = math.min(#t, #name)
		local limit = math.max(#t, #name) <= 5 and 1 or 2

		if short >= 3 and (distance(t, name) <= limit
		    or t:find(name, 1, true) or name:find(t, 1, true))
		    or shared >= 4 then
			out[#out + 1] = t
		end
	end
	st:finalize()
	table.sort(out)
	return out
end

return M
