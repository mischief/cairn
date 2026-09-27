-- SPDX-License-Identifier: ISC
-- search: parse a query, run it against doc_fts and chunk_fts, and
-- group the hits by document.

local store = require "cairn.store"
local tags = require "cairn.tags"
local topics = require "cairn.topics"

local M = {}

M.LIMIT = 10
M.MAXLIMIT = 50

-- matching chunks returned for each document
M.CHUNKS = 3
M.MAXCHUNKS = 10

local FILTERS = { tag = true, mime = true, author = true, since = true,
    meta = true, date = true, creator = true, type = true }

-- words(q) -> list of words; a filter value may be quoted:
-- creator:"DoD NCSC"
local function words(q)
	local out, i = {}, 1

	while true do
		local s, e = q:find("%S", i)

		if not s then
			break
		end

		local k, v, stop = q:match('^(%a+:[^%s"]*)"([^"]*)"()', s)

		if k then
			out[#out + 1] = k .. v
			i = stop
		else
			s, e = q:find("%S+", s)
			out[#out + 1] = q:sub(s, e)
			i = e + 1
		end
	end
	return out
end

-- parse(q) -> text, filters. Filters are tag:, mime:, author:, since:,
-- meta:KEY[=VALUE|~VALUE], date:[<|>|<=|>=]EDTF, creator:TEXT, and
-- type:FORM (dcterms.type).
function M.parse(q)
	local f = { tag = {}, meta = {} }
	local rest = {}

	for _, word in ipairs(words(q or "")) do
		local k, v = word:match("^(%a+):(.+)$")

		if k and FILTERS[k] then
			if k == "tag" or k == "meta" then
				f[k][#f[k] + 1] = v
			else
				f[k] = v
			end
		else
			rest[#rest + 1] = word
		end
	end
	return table.concat(rest, " "), f
end

-- hasops(s) -> true when s uses FTS5 query syntax
function M.hasops(s)
	return s:find('["*^()]') ~= nil or s:find("%f[%w]AND%f[%W]") ~= nil
	    or s:find("%f[%w]OR%f[%W]") ~= nil
	    or s:find("%f[%w]NOT%f[%W]") ~= nil
	    or s:find("%f[%w]NEAR%f[%W]") ~= nil
end

-- fts(s) -> FTS5 query: each word quoted, a prefix match on the last
function M.fts(s, plain)
	if not plain and M.hasops(s) then
		return s
	end

	local words = {}

	for w in s:gmatch("[^%s%p]+") do
		words[#words + 1] = '"' .. w .. '"'
	end
	if #words == 0 then
		return nil
	end
	words[#words] = words[#words] .. "*"
	return table.concat(words, " ")
end

-- where clause and args for the filters, over doc d
local function filters(d, f, opts)
	-- hidden documents show only when asked for, and then only they do
	local sql, args = { opts.hidden and "d.hidden = 1" or "d.hidden = 0" }, {}

	-- about pages define tags; cairn tags shows their scope notes, so
	-- they show only when asked for, and then only they do
	sql[#sql + 1] = opts.about and "d.about IS NOT NULL" or "d.about IS NULL"

	if not opts.superseded then
		sql[#sql + 1] = "d.superseded_by IS NULL"
	end
	for _, t in ipairs(f.tag) do
		local name = store.resolve_tag(d, t)
		-- a topic also matches the topics under it
		local under = topics.descendants(d, name)
		local marks = ("?, "):rep(#under):sub(1, -3)

		sql[#sql + 1] = "EXISTS (SELECT 1 FROM tag t LEFT JOIN tag_alias a "
		    .. "ON a.alias = t.name WHERE t.doc = d.id "
		    .. "AND (coalesce(a.name, t.name) IN (" .. marks .. ") "
		    .. "OR coalesce(a.name, t.name) LIKE ? ESCAPE '\\'))"
		for _, u in ipairs(under) do
			args[#args + 1] = u
		end
		args[#args + 1] = name:gsub("[%%_\\]", "\\%0") .. "/%"
	end
	if f.mime then
		sql[#sql + 1] = "d.mime LIKE ?"
		args[#args + 1] = f.mime:find("/", 1, true) and f.mime
		    or f.mime .. "/%"
	end
	if f.author then
		sql[#sql + 1] = "d.author = ?"
		args[#args + 1] = f.author
	end
	if f.since then
		sql[#sql + 1] = "d.updated >= ?"
		args[#args + 1] = f.since
	end
	for _, m in ipairs(f.meta or {}) do
		local key, op, val = m:match("^([^=~]+)([=~])(.*)$")

		key = key or m
		if op == "=" then
			sql[#sql + 1] = "EXISTS (SELECT 1 FROM meta m WHERE m.doc = d.id "
			    .. "AND m.key = ? AND lower(m.value) = lower(?))"
			args[#args + 1] = key
			args[#args + 1] = val
		elseif op == "~" then
			sql[#sql + 1] = "EXISTS (SELECT 1 FROM meta m WHERE m.doc = d.id "
			    .. "AND m.key = ? AND instr(lower(m.value), lower(?)) > 0)"
			args[#args + 1] = key
			args[#args + 1] = val
		else
			sql[#sql + 1] = "EXISTS (SELECT 1 FROM meta m WHERE m.doc = d.id "
			    .. "AND m.key = ?)"
			args[#args + 1] = key
		end
	end
	if f.type then
		sql[#sql + 1] = "EXISTS (SELECT 1 FROM meta m WHERE m.doc = d.id "
		    .. "AND m.key = 'dcterms.type' AND lower(m.value) = lower(?))"
		args[#args + 1] = f.type
	end
	if f.creator then
		sql[#sql + 1] = "EXISTS (SELECT 1 FROM meta m WHERE m.doc = d.id "
		    .. "AND m.key = 'dcterms.creator' "
		    .. "AND instr(lower(m.value), lower(?)) > 0)"
		args[#args + 1] = f.creator
	end
	if f.date then
		local op, v = f.date:match("^([<>]=?)(.+)$")
		local start = require("cairn.meta").edtf(v or f.date)

		if not start then
			error("date: takes an EDTF date, such as date:<1990 or "
			    .. "date:1985-12", 0)
		end
		sql[#sql + 1] = "EXISTS (SELECT 1 FROM meta m WHERE m.doc = d.id "
		    .. "AND m.key = 'dcterms.date' AND "
		    .. (op and ("m.start " .. op .. " ?") or "m.start LIKE ? || '%'")
		    .. ")"
		args[#args + 1] = start
	end
	return table.concat(sql, " AND "), args
end

local function append(a, b)
	local out = {}

	for _, v in ipairs(a) do
		out[#out + 1] = v
	end
	for _, v in ipairs(b) do
		out[#out + 1] = v
	end
	return out
end

-- scan(d, text, where, wargs) -> chunks holding text anywhere, part
-- words too, with no case. A full scan of chunk text: it runs only when
-- the word index finds nothing.
function M.scan(d, text, where, wargs)
	local needle = text:lower()
	local rows = d:rows("SELECT d.*, c.page, c.heading, c.body, "
	    .. "instr(lower(c.body), ?) AS at FROM chunk c "
	    .. "JOIN extract e ON e.id = c.extract "
	    .. "JOIN doc d ON d.content = e.file "
	    .. "WHERE at > 0 AND " .. where .. " LIMIT 500",
	    append({ needle }, wargs))

	for _, r in ipairs(rows) do
		-- lower() only folds ASCII, so byte offsets match the body
		local s, e = r.at, r.at + #needle - 1
		local from = math.max(1, s - 80)

		r.snip = (from > 1 and "..." or "") .. r.body:sub(from, s - 1)
		    .. "[" .. r.body:sub(s, e) .. "]" .. r.body:sub(e + 1, e + 80)
		    .. (e + 80 < #r.body and "..." or "")
		r.s, r.body, r.at = 0, nil, nil
	end
	return rows
end

-- search(d, q, opts) -> list of hits. opts: tag, mime, author, since
-- (added to the parsed filters), superseded, limit, offset.
function M.search(d, q, opts)
	opts = opts or {}

	local text, f = M.parse(q)

	for _, k in ipairs({ "mime", "author", "since" }) do
		f[k] = opts[k] or f[k]
	end
	for _, t in ipairs(opts.tag or {}) do
		f.tag[#f.tag + 1] = t
	end

	local limit = math.min(opts.limit or M.LIMIT, opts.max or M.MAXLIMIT)
	local per = math.max(1, math.min(opts.chunks or M.CHUNKS, M.MAXCHUNKS))
	local offset = opts.offset or 0
	local where, wargs = filters(d, f, opts)
	local hits, order = {}, {}

	local function hit(row)
		local h = hits[row.id]

		if not h then
			h = { id = row.id, title = row.title, rev = row.rev,
			    mime = row.mime, author = row.author,
			    updated = row.updated, content = row.content, score = 0 }
			hits[row.id] = h
			order[#order + 1] = h
		end
		return h
	end

	local match = M.fts(text)
	local listed

	-- FTS5 refuses some input, such as a lone "*"; read it as plain
	-- words then, and list documents when no word is left
	if match and not pcall(d.rows, d, "SELECT 1 FROM doc_fts "
	    .. "WHERE doc_fts MATCH ? LIMIT 1", { match }) then
		match = M.fts(text, true)
	end

	if match then
		for _, r in ipairs(d:rows("SELECT d.*, bm25(doc_fts, 10.0, 5.0) AS s "
		    .. "FROM doc_fts JOIN doc d ON d.n = doc_fts.rowid "
		    .. "WHERE doc_fts MATCH ? AND " .. where .. " LIMIT 500",
		    append({ match }, wargs))) do
			local h = hit(r)

			h.score = h.score + r.s
		end

		local chunks = d:rows("SELECT d.*, c.page, c.heading, "
		    .. "snippet(chunk_fts, 1, '[', ']', '...', 24) AS snip, "
		    .. "bm25(chunk_fts, 2.0, 1.0) AS s "
		    .. "FROM chunk_fts JOIN chunk c ON c.id = chunk_fts.rowid "
		    .. "JOIN extract e ON e.id = c.extract "
		    .. "JOIN doc d ON d.content = e.file "
		    .. "WHERE chunk_fts MATCH ? AND " .. where
		    .. " ORDER BY s LIMIT 500", append({ match }, wargs))

		if #chunks == 0 and #order == 0 and not M.hasops(text)
		    and #text >= 3 then
			chunks = M.scan(d, text, where, wargs)
		end
		-- chunks come best first; each document keeps its best few, so a
		-- table of contents and the section it points to both show
		for _, r in ipairs(chunks) do
			local h = hit(r)

			h.chunks = h.chunks or {}
			if #h.chunks < per then
				h.chunks[#h.chunks + 1] = { page = r.page,
				    heading = r.heading, snippet = r.snip,
				    uri = store.uri(h.id, nil, r.page and ("p=" .. r.page)) }
			end
			if not h.best or r.s < h.best then
				h.best = r.s
				h.snippet = r.snip
				h.page = r.page
				h.heading = r.heading
			end
		end
		for _, h in ipairs(order) do
			h.score = h.score + (h.best or 0)
		end
		table.sort(order, function(a, b)
			if a.score ~= b.score then
				return a.score < b.score
			end
			return a.updated > b.updated
		end)
	else
		for _, r in ipairs(d:rows("SELECT d.* FROM doc d WHERE " .. where
		    .. " ORDER BY d.updated DESC LIMIT ? OFFSET ?",
		    append(wargs, { limit, offset }))) do
			hit(r)
		end
		listed = d:row("SELECT count(*) FROM doc d WHERE " .. where, wargs)
		offset = 0
	end

	local out = {}

	for i = offset + 1, math.min(#order, offset + limit) do
		local h = order[i]

		h.pending = h.content and store.pending(d, h.content) or nil
		h.uri = store.uri(h.id, nil, h.page and ("p=" .. h.page) or nil)
		h.content, h.best = nil, nil
		h.score = tonumber(("%.4g"):format(-h.score))
		out[#out + 1] = h
	end
	return out, listed or #order
end

-- visible tags with aliases resolved; a view over tag for the queries
-- below
local RTAG = "(SELECT t.doc, coalesce(a.name, t.name) AS name FROM tag t "
    .. "LEFT JOIN tag_alias a ON a.alias = t.name "
    .. "JOIN doc d ON d.id = t.doc "
    .. "WHERE d.hidden = 0 AND d.superseded_by IS NULL)"

-- the key on a tag's about page that holds its scope note: one line on
-- what the tag covers and what it leaves out (SKOS skos:scopeNote)
M.SCOPE = topics.SCOPE

-- tags(d, prefix) -> list of { name, count, with = {...}, about, scope }
-- for the tags that start with prefix. A nested name also lists its
-- parents, with the count of documents under each. A topic counts the
-- documents of the topics under it too.
function M.tags(d, prefix)
	local rows = d:rows("SELECT name, count(DISTINCT doc) AS count FROM "
	    .. RTAG .. " WHERE (? IS NULL OR name LIKE ? || '%') "
	    .. "GROUP BY name ORDER BY name", { prefix, prefix, n = 2 })
	local byname = {}

	for _, r in ipairs(rows) do
		byname[r.name] = r
	end
	-- a tag with an about page exists before any document uses it
	for _, a in ipairs(d:rows("SELECT DISTINCT about FROM doc WHERE about "
	    .. "IS NOT NULL AND hidden = 0 AND superseded_by IS NULL AND (? IS "
	    .. "NULL OR about LIKE ? || '%')", { prefix, prefix, n = 2 })) do
		if not byname[a.about] then
			byname[a.about] = { name = a.about, count = 0 }
			rows[#rows + 1] = byname[a.about]
		end
	end
	for _, r in ipairs(rows) do
		local parent = r.name:match("^(.+)/[^/]+$")

		while parent and not byname[parent] do
			byname[parent] = { name = parent, count = d:row(
			    "SELECT count(DISTINCT doc) FROM " .. RTAG
			    .. " WHERE name LIKE ? || '/%'", { parent }) }
			rows[#rows + 1] = byname[parent]
			parent = parent:match("^(.+)/[^/]+$")
		end
	end
	table.sort(rows, function(x, y)
		return x.name < y.name
	end)
	for _, r in ipairs(rows) do
		r.with = {}
		for _, w in ipairs(d:rows("SELECT b.name, count(*) AS n FROM "
		    .. RTAG .. " a JOIN " .. RTAG .. " b ON a.doc = b.doc "
		    .. "AND b.name != a.name WHERE a.name = ? "
		    .. "GROUP BY b.name ORDER BY n DESC, b.name LIMIT 3",
		    { r.name })) do
			r.with[#r.with + 1] = w.name
		end
		r.about = d:row("SELECT id FROM doc WHERE about = ? AND hidden = 0 "
		    .. "AND superseded_by IS NULL", { r.name })
		r.scope = r.about and d:row("SELECT value FROM meta WHERE doc = ? "
		    .. "AND key = ? ORDER BY seq LIMIT 1", { r.about, M.SCOPE })

		local under = r.about and topics.descendants(d, r.name) or {}

		if #under > 1 then
			local marks = ("?, "):rep(#under):sub(1, -3)

			under[#under + 1] = r.name:gsub("[%%_\\]", "\\%0") .. "/%"
			r.count = d:row("SELECT count(DISTINCT doc) FROM " .. RTAG
			    .. " WHERE name IN (" .. marks .. ") OR name LIKE ? "
			    .. "ESCAPE '\\'", under)
		end
	end
	return rows
end

-- lowest score of a similar document shown by default
M.SIMILAR = 0.5

-- similar(d, id, min) -> up to 5 of { id, score, title }: the stored
-- nearest documents (cairn experiments similar) that score min or more.
-- Documents linked either way are left out; links already show them.
function M.similar(d, id, min)
	return d:rows("SELECT s.other AS id, s.score, d.title FROM similar s "
	    .. "JOIN doc d ON d.id = s.other WHERE s.doc = ? AND d.hidden = 0 "
	    .. "AND d.about IS NULL AND s.score >= ? AND NOT EXISTS (SELECT 1 FROM link l WHERE "
	    .. "(l.src = s.doc AND l.dst = s.other) OR (l.src = s.other AND "
	    .. "l.dst = s.doc)) ORDER BY s.score DESC LIMIT 5",
	    { id, min or M.SIMILAR })
end

-- related(d, id, depth, rel) -> linked documents in both directions
function M.related(d, id, depth, rel)
	return d:rows([[
WITH RECURSIVE walk (id, depth, rel, dir) AS (
	SELECT ?, 0, NULL, NULL
	UNION
	SELECT CASE WHEN l.src = w.id THEN l.dst ELSE l.src END, w.depth + 1,
	    l.rel, CASE WHEN l.src = w.id THEN 'out' ELSE 'in' END
	FROM walk w JOIN link l ON (l.src = w.id OR l.dst = w.id)
	WHERE w.depth < ? AND (? IS NULL OR l.rel = ?)
)
SELECT d.id, d.title, min(w.depth) AS depth, w.rel, w.dir, d.updated
FROM walk w JOIN doc d ON d.id = w.id
WHERE w.depth > 0 AND d.hidden = 0 AND d.id != ?
GROUP BY d.id ORDER BY depth, d.updated DESC LIMIT 100
]], { id, depth or 1, rel, rel, id, n = 5 })
end

-- recent(d, since, author, limit) -> recent versions, without the about
-- pages of tags
function M.recent(d, since, author, limit)
	return d:rows("SELECT v.doc AS id, v.rev, v.author, v.created, d.title "
	    .. "FROM doc_version v JOIN doc d ON d.id = v.doc "
	    .. "WHERE (? IS NULL OR v.created >= ?) "
	    .. "AND (? IS NULL OR v.author = ?) AND d.hidden = 0 "
	    .. "AND d.about IS NULL "
	    .. "ORDER BY v.created DESC, v.rev DESC LIMIT ?",
	    { since, since, author, author, math.min(limit or 20, 200), n = 5 })
end

M.normalize = tags.normalize

return M
