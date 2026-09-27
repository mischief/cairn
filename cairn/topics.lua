-- SPDX-License-Identifier: ISC
-- topics: general topics are the tags topic/NAME that have an about
-- page. The page holds a scope note and the broader topics, as SKOS
-- does: skos.scopeNote and skos.broader. A search for a topic also
-- finds the topics under it.

local store = require "cairn.store"

local M = {}

M.PREFIX = "topic/"
M.SCOPE = "skos.scopeNote"
M.BROADER = "skos.broader"

-- page(d, tag) -> id of the about page of tag, or nil
local function page(d, tag)
	return d:row("SELECT id FROM doc WHERE about = ? AND hidden = 0 "
	    .. "AND superseded_by IS NULL", { tag })
end

-- descendants(d, tag) -> list of tag and every topic whose about page
-- names it as broader, at any depth
function M.descendants(d, tag)
	local out, seen, todo = {}, {}, { tag }

	while #todo > 0 do
		local t = table.remove(todo)

		if not seen[t] then
			seen[t] = true
			out[#out + 1] = t
			for _, r in ipairs(d:rows("SELECT a.about FROM meta m JOIN doc a "
			    .. "ON a.id = m.doc WHERE m.key = ? AND m.value = ? "
			    .. "AND a.about IS NOT NULL AND a.hidden = 0 "
			    .. "AND a.superseded_by IS NULL", { M.BROADER, t })) do
				todo[#todo + 1] = r.about
			end
		end
	end
	return out
end

-- seed(d, author, vocab) -> topics added, list of topics whose scope
-- note differs from the list. It writes an about page for each topic
-- that has none and never changes an existing page.
function M.seed(d, author, vocab)
	vocab = vocab or require "cairn.vocab"

	local added, differ = 0, {}

	for _, t in ipairs(vocab.topics) do
		local slug, label, broader, scope = t[1], t[2], t[3], t[4]
		local tag = M.PREFIX .. slug
		local id = page(d, tag)

		if id then
			local cur = d:row("SELECT value FROM meta WHERE doc = ? AND key = ? "
			    .. "ORDER BY seq LIMIT 1", { id, M.SCOPE })

			if cur ~= scope then
				differ[#differ + 1] = tag
			end
		else
			local up = {}

			for b in broader:gmatch("%S+") do
				up[#up + 1] = M.PREFIX .. b
			end

			local body = { scope, "", "Tag: " .. tag }

			if #up > 0 then
				body[#body + 1] = "Broader: " .. table.concat(up, ", ")
			end
			store.note(d, { title = label, body = table.concat(body, "\n"),
			    author = author, about = tag,
			    meta = { [M.SCOPE] = scope, [M.BROADER] = #up > 0 and up
			    or nil } })
			added = added + 1
		end
	end
	return added, differ
end

return M
