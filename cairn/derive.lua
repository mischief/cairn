-- SPDX-License-Identifier: ISC
-- derive: the index tables from the blocks alone. The version nodes are
-- the truth; doc, doc_version, tag, link, meta, wanted, and doc_fts are
-- copies. check() reports where a copy differs; rebuild() rewrites them.

local cid = require "cairn.cid"
local drisl = require "cairn.drisl"
local meta = require "cairn.meta"
local store = require "cairn.store"

local M = {}

-- abstract(e) -> the first dcterms.abstract value of an expected row set
function M.abstract(e)
	for _, m in ipairs(e.meta) do
		if m.key == "dcterms.abstract" and m.seq == 1 then
			return m.value
		end
	end
end

local function unnull(v)
	if v == drisl.null then
		return nil
	end
	return v
end

-- heads(d) -> doc id -> { id = cid row id, node = node }, from every
-- version node in the block table: the highest rev of each document
function M.heads(d)
	local out = {}
	local st = d.sql:prepare("SELECT id, data FROM block WHERE codec = ?")

	st:bind_values(cid.DAG_CBOR)
	for id, data in st:urows() do
		local node = drisl.decode(data)

		if type(node) == "table" and node.type == "cairn/doc"
		    and type(node.doc) == "string" then
			local cur = out[node.doc]

			if not cur or node.rev > cur.node.rev then
				out[node.doc] = { id = id, node = node }
			end
		end
	end
	st:finalize()
	return out
end

-- chain(d, head) -> versions from the head back along prev, newest
-- first; each { rev, id, author, created }
local function chain(d, id, node)
	local out = {}

	while node do
		out[#out + 1] = { rev = node.rev, id = id, author = node.author,
		    created = node.created }

		local prev = drisl.islink(node.prev)

		id = prev and d:lookup(prev)
		node = nil
		if id then
			local data = d:get(prev)

			node = data and drisl.decode(data)
		end
	end
	return out
end

-- expected(d, head) -> the rows a head node implies for its document
function M.expected(d, doc, head)
	local node = head.node
	local versions = chain(d, head.id, node)
	local content = drisl.islink(node.content)
	local e = {
		head = head.id,
		rev = node.rev,
		title = node.title,
		mime = unnull(node.mime),
		content = content and d:lookup(content),
		about = unnull(node.about),
		hidden = node.hidden and 1 or 0,
		author = node.author,
		created = versions[#versions].created,
		updated = node.created,
		versions = versions,
		tags = {},
		links = store.nodelinks(node),
		meta = {},
		wanted = {},
	}

	for i, t in ipairs(node.tags or {}) do
		e.tags[i] = t
	end
	for k, v in pairs(store.nodemeta(node)) do
		for i, x in ipairs(type(v) == "table" and v or { v }) do
			e.meta[#e.meta + 1] = { key = k, seq = i, value = x,
			    start = meta.DATES[k] and (meta.edtf(x)) or nil }
		end
	end
	table.sort(e.meta, function(a, b)
		return a.key .. "\0" .. a.seq < b.key .. "\0" .. b.seq
	end)
	if e.mime == "text/markdown" and e.content then
		local body = store.content(d, e.content)

		if body then
			local _, wanted = store.bodylinks(d, body, e.links)

			e.wanted = wanted
			table.sort(e.wanted)
		end
	end
	return e
end

-- superseded(heads) -> target doc id -> doc id that supersedes it; the
-- newest head wins when several do
local function superseded(heads)
	local out, when = {}, {}

	for id, h in pairs(heads) do
		for _, l in ipairs(h.node.links or {}) do
			if l.rel == "supersedes" and (not when[l.doc]
			    or h.node.created > when[l.doc]) then
				out[l.doc] = id
				when[l.doc] = h.node.created
			end
		end
	end
	return out
end

local function list(rows, f)
	local out = {}

	for _, r in ipairs(rows) do
		out[#out + 1] = f(r)
	end
	table.sort(out)
	return table.concat(out, ", ")
end

-- check(d) -> list of problems, each a line of text
function M.check(d)
	local heads = M.heads(d)
	local sup = superseded(heads)
	local problems = {}

	local function bad(id, what, want, got)
		problems[#problems + 1] = ("doc %s: %s is %s, head says %s"):format(
		    id, what, tostring(got), tostring(want))
	end

	for _, r in ipairs(d:rows("SELECT id FROM doc")) do
		if not heads[r.id] then
			problems[#problems + 1] = "doc " .. r.id
			    .. ": no version node in the blocks"
		end
	end
	for id, h in pairs(heads) do
		local row = store.doc(d, id)

		if not row then
			problems[#problems + 1] = "doc " .. id .. ": no doc row"
			goto next
		end

		local e = M.expected(d, id, h)

		for _, k in ipairs({ "head", "rev", "title", "mime", "content",
		    "about", "hidden", "author", "created", "updated" }) do
			if row[k] ~= e[k] then
				bad(id, k, e[k], row[k])
			end
		end
		if row.superseded_by ~= sup[id] then
			bad(id, "superseded_by", sup[id], row.superseded_by)
		end

		local checks = {
			{ "versions", list(e.versions, function(v)
				return v.rev .. ":" .. v.id
			end), list(d:rows("SELECT rev, node FROM doc_version "
			    .. "WHERE doc = ?", { id }), function(v)
				return v.rev .. ":" .. v.node
			end) },
			{ "tags", list(e.tags, tostring), list(d:rows("SELECT name "
			    .. "FROM tag WHERE doc = ?", { id }), function(t)
				return t.name
			end) },
			{ "links", list(e.links, function(l)
				return l.rel .. ">" .. l.doc
			end), list(d:rows("SELECT DISTINCT rel, dst FROM link "
			    .. "WHERE src = ?", { id }), function(l)
				return l.rel .. ">" .. l.dst
			end) },
			{ "meta", list(e.meta, function(m)
				return m.key .. m.seq .. "=" .. m.value
			end), list(d:rows("SELECT key, seq, value FROM meta "
			    .. "WHERE doc = ?", { id }), function(m)
				return m.key .. m.seq .. "=" .. m.value
			end) },
			{ "wanted", list(e.wanted, tostring), list(d:rows("SELECT title "
			    .. "FROM wanted WHERE src = ?", { id }), function(w)
				return w.title
			end) },
		}

		-- links keep one row per rel and target, whatever the fragments
		local seen, dedup = {}, {}

		for part in checks[3][2]:gmatch("[^, ]+") do
			if not seen[part] then
				seen[part] = true
				dedup[#dedup + 1] = part
			end
		end
		checks[3][2] = table.concat(dedup, ", ")
		for _, c in ipairs(checks) do
			if c[2] ~= c[3] then
				bad(id, c[1], "[" .. c[2] .. "]", "[" .. c[3] .. "]")
			end
		end

		local fts = d:rows("SELECT title, tags, abstract FROM doc_fts "
		    .. "WHERE rowid = ?", { row.n })[1]

		if not fts or fts.title ~= e.title
		    or fts.tags ~= table.concat(e.tags, " ")
		    or fts.abstract ~= M.abstract(e) then
			bad(id, "doc_fts", e.title, fts and fts.title)
		end
		::next::
	end
	table.sort(problems)
	return problems
end

-- rebuild(d) rewrites every index table from the version nodes and
-- returns the number of documents
function M.rebuild(d)
	local heads = M.heads(d)
	local sup = superseded(heads)
	local n = 0

	d:tx(function()
		-- every row first: superseded_by and links name other documents
		for id, h in pairs(heads) do
			if not store.doc(d, id) then
				d:run("INSERT INTO doc (id, head, rev, title, created, updated) "
				    .. "VALUES (?, ?, ?, ?, ?, ?)", { id, h.id, h.node.rev,
				    h.node.title, h.node.created, h.node.created })
			end
		end
		for id, h in pairs(heads) do
			local e = M.expected(d, id, h)

			d:run("UPDATE doc SET head = ?, rev = ?, title = ?, mime = ?, "
			    .. "content = ?, about = ?, hidden = ?, author = ?, "
			    .. "created = ?, updated = ?, superseded_by = ? WHERE id = ?",
			    { e.head, e.rev, e.title, e.mime, e.content, e.about, e.hidden,
			    e.author, e.created, e.updated, sup[id], id, n = 12 })
			d:run("DELETE FROM doc_version WHERE doc = ?", { id })
			for _, v in ipairs(e.versions) do
				d:run("INSERT INTO doc_version (doc, rev, node, author, "
				    .. "created) VALUES (?, ?, ?, ?, ?)",
				    { id, v.rev, v.id, v.author, v.created })
			end
			d:run("DELETE FROM tag WHERE doc = ?", { id })
			for _, t in ipairs(e.tags) do
				d:run("INSERT INTO tag (doc, name) VALUES (?, ?)", { id, t })
			end
			d:run("DELETE FROM link WHERE src = ?", { id })
			for _, l in ipairs(e.links) do
				d:run("INSERT OR IGNORE INTO link (src, dst, rel) "
				    .. "VALUES (?, ?, ?)", { id, l.doc, l.rel })
			end
			d:run("DELETE FROM meta WHERE doc = ?", { id })
			for _, m in ipairs(e.meta) do
				d:run("INSERT INTO meta (doc, key, seq, value, start) "
				    .. "VALUES (?, ?, ?, ?, ?)",
				    { id, m.key, m.seq, m.value, m.start, n = 5 })
			end
			d:run("DELETE FROM wanted WHERE src = ?", { id })
			for _, t in ipairs(e.wanted) do
				d:run("INSERT OR IGNORE INTO wanted (src, title) VALUES (?, ?)",
				    { id, t })
			end

			local row = store.doc(d, id)

			d:run("DELETE FROM doc_fts WHERE rowid = ?", { row.n })
			d:run("INSERT INTO doc_fts (rowid, title, tags, abstract) "
			    .. "VALUES (?, ?, ?, ?)", { row.n, e.title,
			    table.concat(e.tags, " "), M.abstract(e), n = 4 })
			n = n + 1
		end
	end)
	return n
end

return M
