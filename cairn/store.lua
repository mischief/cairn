-- SPDX-License-Identifier: ISC
-- store: documents, versions, files, tags, and links over db. Every
-- write makes a DRISL version node and moves the document head with a
-- compare-and-swap on rev.

local cid = require "cairn.cid"
local chunk = require "cairn.chunk"
local meta = require "cairn.meta"
local config = require "cairn.config"
local drisl = require "cairn.drisl"
local secret = require "cairn.secret"
local tags = require "cairn.tags"
local util = require "cairn.util"

local M = {}

M.MAXFILE = 64 * 1024 * 1024

M.RELS = { ["see-also"] = true, cites = true, supersedes = true,
    contradicts = true }

-- kinds of extraction job for each mime type; text is indexed inline.
-- Jobs that need a model (vision, transcript) are queued by
-- cairn experiments enrich, not here.
local JOBS = {
	["application/pdf"] = { "pdf" },
	["image/png"] = { "ocr" },
	["image/jpeg"] = { "ocr" },
	["text/html"] = { "pandoc" },
	["application/epub+zip"] = { "pandoc" },
	["application/rtf"] = { "pandoc" },
	["application/vnd.oasis.opendocument.text"] = { "pandoc" },
	["application/vnd.openxmlformats-officedocument"
	    .. ".wordprocessingml.document"] = { "pandoc" },
}

function M.jobkinds(mime)
	return JOBS[mime] or {}
end

-- a conflict error carries the current rev so the caller can retry
local Conflict = { __tostring = function(e)
	return ("document %s is at rev %d, not %d"):format(e.id, e.rev,
	    e.want)
end }

function M.isconflict(e)
	return getmetatable(e) == Conflict
end

local function charge(d, author, n)
	local day = util.day()
	local used = d:row("SELECT bytes FROM usage WHERE author = ? AND day = ?",
	    { author, day }) or 0

	local limit = config.number(d, "limit.daily")

	if used + n > limit then
		error(("daily limit: %s wrote %d bytes today, limit %d"):format(
		    author, used, limit), 0)
	end
	d:run("INSERT INTO usage (author, day, bytes) VALUES (?, ?, ?) "
	    .. "ON CONFLICT (author, day) DO UPDATE SET bytes = bytes + ?",
	    { author, day, n, n })
end

-- putfile(d, data, mime, author) -> file id, binary cid
function M.putfile(d, data, mime, author)
	if #data > M.MAXFILE then
		error(("file of %d bytes is over the %d byte limit"):format(#data,
		    M.MAXFILE), 0)
	end
	return d:tx(function()
		local c = cid.sha256(cid.RAW, data)
		local id = d:lookup(c)

		if not (id and d:has(c)) then
			charge(d, author, #data)
			c, id = d:put(cid.RAW, data)
		end
		d:run("INSERT OR IGNORE INTO file (id, size, mime) VALUES (?, ?, ?)",
		    { id, #data, mime })
		return id, c
	end)
end

-- index(d, file, kind, extractor, version, chunks) replaces the chunks
-- of one extraction of a file
function M.index(d, file, kind, extractor, version, chunks)
	local bodies = {}

	for i, c in ipairs(chunks) do
		bodies[i] = c.body
	end

	local hash = chunk.hash(bodies)

	d:tx(function()
		local old = d:row("SELECT id FROM extract WHERE file = ? AND kind = ? "
		    .. "AND extractor = ?", { file, kind, extractor })

		if old then
			d:run("DELETE FROM chunk WHERE extract = ?", { old })
			d:run("UPDATE extract SET version = ?, created = ?, hash = ? "
			    .. "WHERE id = ?", { version, util.now(), hash, old })
		else
			d:run("INSERT INTO extract (file, kind, extractor, version, "
			    .. "created, hash) VALUES (?, ?, ?, ?, ?, ?)",
			    { file, kind, extractor, version, util.now(), hash })
			old = d.sql:last_insert_rowid()
		end
		for i, c in ipairs(chunks) do
			d:run("INSERT INTO chunk (extract, seq, page, heading, body) "
			    .. "VALUES (?, ?, ?, ?, ?)",
			    { old, i, c.page, c.heading, c.body, n = 5 })
		end
	end)
end

-- unindex(d, file) drops the chunks, extractions, and jobs of a file
-- that no document head holds. Old versions keep the file block, so
-- its text can be extracted again.
function M.unindex(d, file)
	if d:row("SELECT 1 FROM doc WHERE content = ?", { file }) then
		return
	end
	d:run("DELETE FROM chunk WHERE extract IN "
	    .. "(SELECT id FROM extract WHERE file = ?)", { file })
	d:run("DELETE FROM extract WHERE file = ?", { file })
	d:run("DELETE FROM job WHERE file = ?", { file })
end

-- gc(d, dry) deletes blocks that no document head reaches through ref:
-- prev to older versions, content to files, at to linked versions.
-- History stays. Returns blocks, bytes, and cid rows removed (or that
-- would be, when dry is set).
function M.gc(d, dry)
	return d:tx(function()
		d:exec("CREATE TEMP TABLE IF NOT EXISTS gc_live "
		    .. "(id INTEGER PRIMARY KEY)")
		d:exec("DELETE FROM gc_live")
		d:exec([[
WITH RECURSIVE live (id) AS (
	SELECT head FROM doc
	UNION
	SELECT r.child FROM ref r JOIN live l ON r.parent = l.id
)
INSERT INTO gc_live SELECT id FROM live]])

		local dead = "(SELECT id FROM block WHERE id NOT IN gc_live)"
		local blocks = d:row("SELECT count(*) FROM " .. dead .. " x")
		local bytes = d:row("SELECT coalesce(sum(size), 0) FROM block "
		    .. "WHERE id NOT IN gc_live")
		local orphan = "(SELECT id FROM cid WHERE id NOT IN "
		    .. "(SELECT id FROM block WHERE id IN gc_live) "
		    .. "AND id NOT IN (SELECT child FROM ref WHERE parent IN gc_live) "
		    .. "AND id NOT IN (SELECT head FROM doc) "
		    .. "AND id NOT IN (SELECT node FROM doc_version))"
		local cids = d:row("SELECT count(*) FROM " .. orphan .. " x")

		if not dry and (blocks > 0 or cids > 0) then
			d:exec("DELETE FROM chunk WHERE extract IN (SELECT id FROM extract "
			    .. "WHERE file IN " .. dead .. ")")
			d:exec("DELETE FROM extract WHERE file IN " .. dead)
			d:exec("DELETE FROM job WHERE file IN " .. dead)
			d:exec("DELETE FROM file WHERE id IN " .. dead)
			d:exec("DELETE FROM ref WHERE parent IN " .. dead)
			d:exec("DELETE FROM block WHERE id NOT IN gc_live")
			d:exec("DELETE FROM cid WHERE id IN " .. orphan)
		end
		d:exec("DELETE FROM gc_live")
		if not dry then
			d:run("INSERT INTO state (key, value) VALUES ('gc.writes', 0), "
			    .. "('gc.last', ?) ON CONFLICT (key) DO UPDATE "
			    .. "SET value = excluded.value", { util.now() })
		end
		return blocks, bytes, cids
	end)
end

-- autogc(d) runs gc and gives free pages back once gc.auto versions
-- were written since the last gc, as git gc --auto does. Returns true
-- when it ran.
function M.autogc(d)
	local limit = config.number(d, "gc.auto") or 0
	-- the parentheses matter: no row gives no values, and tonumber()
	-- with no argument raises
	local writes = tonumber((d:row("SELECT value FROM state "
	    .. "WHERE key = 'gc.writes'"))) or 0

	if limit == 0 or writes < limit then
		return false
	end
	M.gc(d)
	d:row("PRAGMA wal_checkpoint(TRUNCATE)")
	d:exec("PRAGMA incremental_vacuum")
	return true
end

-- indextext(d, file, mime, text) indexes a text file inline
function M.indextext(d, file, mime, text)
	-- plain text with form feeds, such as an RFC, has pages
	local chunks = mime == "text/markdown" and chunk.markdown(text)
	    or text:find("\f", 1, true) and chunk.pages(text)
	    or chunk.plain(text)

	M.index(d, file, "text", "builtin", 1, chunks)
end

-- ref(d, s) parses a link target: an id, a version or file CID, or a
-- title, each with an optional @rev and #fragment, with or without a
-- "cairn:" prefix. Returns { doc, rev, frag, pin } or nil, reason.
-- A fragment is "p=N" for a page, or heading text.
function M.ref(d, s)
	s = s:match("^%s*(.-)%s*$"):gsub("^cairn:", "")

	local target, frag = s:match("^(.-)#(.*)$")

	target = target or s
	if frag == "" then
		frag = nil
	end

	local base, rev = target:match("^(.-)@(%d+)$")

	target = base or target
	rev = math.tointeger(tonumber(rev))

	local r = { frag = frag, rev = rev, pin = rev ~= nil or nil }

	if util.isid(target) then
		if not d:row("SELECT 1 FROM doc WHERE id = ?", { target }) then
			return nil, "no document " .. target
		end
		r.doc = target
		return r
	end

	local c = target:match("^b[a-z2-7]+$") and cid.parse(target)

	if c then
		local v = d:rows("SELECT v.doc, v.rev FROM doc_version v JOIN cid c "
		    .. "ON c.id = v.node WHERE c.cid = ?", { c.bytes }, { true })[1]

		if v then
			r.doc, r.rev, r.pin = v.doc, v.rev, true
			return r
		end
		r.doc = d:row("SELECT d.id FROM doc d JOIN cid c ON c.id = d.content "
		    .. "WHERE c.cid = ? ORDER BY d.hidden, d.updated DESC",
		    { c.bytes }, { true })
		if r.doc then
			return r
		end
		return nil, "no document for " .. target
	end

	r.doc = d:row("SELECT id FROM doc WHERE lower(title) = lower(?) "
	    .. "ORDER BY hidden, superseded_by IS NOT NULL, updated DESC LIMIT 1",
	    { target })
	if r.doc then
		r.name = target
		return r
	end
	return nil, "no document titled \"" .. target .. "\""
end

-- uri(id, rev, frag) -> "cairn:ID[@REV][#FRAG]"
function M.uri(id, rev, frag)
	return "cairn:" .. id .. (rev and ("@" .. rev) or "")
	    .. (frag and ("#" .. frag) or "")
end

-- bodylinks(d, body, old) -> see-also links and wanted titles from the
-- [[...]] targets in a markdown body. old holds the links of the last
-- version: a title resolves to the document it named before, so a
-- retitled or new document with the same title does not steal it.
-- nocode(body) -> body with fenced code blocks and inline code spans
-- blanked out, so an example such as `[[TARGET]]` is not a link
local function nocode(body)
	body = ("\n" .. body):gsub("\n%s*(```+)[^\n]*\n.-\n%s*%1[^\n]*", "\n")
	body = body:gsub("\n%s*(~~~+)[^\n]*\n.-\n%s*%1[^\n]*", "\n")
	return (body:gsub("(`+).-%1", ""))
end

function M.bodylinks(d, body, old)
	local byname = {}

	body = nocode(body)

	for _, l in ipairs(old or {}) do
		if l.name then
			byname[l.name:lower()] = l
		end
	end

	local links, wanted, seen = {}, {}, {}

	for raw in body:gmatch("%[%[([^%]\n]+)%]%]") do
		local text = raw:match("^([^|]*)") -- [[target|label]]
		local r, why = M.ref(d, text)
		local target = text:match("^%s*(.-)%s*$"):gsub("^cairn:", "")
		    :gsub("#.*$", ""):gsub("@%d+$", "")
		local prev = byname[text:lower():match("^%s*(.-)%s*$")]

		if prev and d:row("SELECT 1 FROM doc WHERE id = ?", { prev.doc }) then
			r = { doc = prev.doc, name = prev.name, frag = prev.frag,
			    rev = prev.rev, pin = prev.pin }
		end
		if r then
			-- name marks a link that came from the body
			r.name = text:match("^%s*(.-)%s*$")
			r.rel = "see-also"
			links[#links + 1] = r
		elseif why and why:match("^no document titled") then
			local t = target:match("^%s*(.-)%s*$")

			if t ~= "" and not seen[t:lower()] then
				seen[t:lower()] = true
				wanted[#wanted + 1] = t
			end
		end
	end
	return links, wanted
end

-- fills(d, id) -> documents whose body wants a document titled like id
function M.fills(d, id)
	local out = {}

	for _, r in ipairs(d:rows("SELECT DISTINCT w.src FROM wanted w "
	    .. "JOIN doc d ON lower(d.title) = lower(w.title) "
	    .. "WHERE d.id = ? AND w.src != ?", { id, id })) do
		out[#out + 1] = r.src
	end
	return out
end

-- doc(d, id) -> doc row as a table, or nil
function M.doc(d, id)
	return d:rows("SELECT * FROM doc WHERE id = ?", { id })[1]
end

-- node(d, cidid) -> decoded version node
function M.node(d, cidid)
	local c = d:row("SELECT cid FROM cid WHERE id = ?", { cidid })
	local data = c and d:get(c)

	if not data then
		error("missing version node", 0)
	end
	return assert(drisl.decode(data)), c
end

-- links of a node as plain tables: rel, doc, at (binary cid of the
-- target version when the link was made), and frag, name, pin
function M.nodelinks(node)
	local out = {}

	for _, l in ipairs(node.links or {}) do
		out[#out + 1] = { rel = l.rel, doc = l.doc,
		    at = l.at and drisl.islink(l.at), frag = l.frag, name = l.name,
		    pin = l.pin }
	end
	return out
end

local function linkkey(l)
	return l.rel .. " " .. l.doc .. " " .. (l.frag or "")
end

-- checklinks(d, id, links, old) validates links and gives each an "at":
-- the version of the target it points to. A link that was in the last
-- version keeps its at, so a change to the target shows as a change.
local function checklinks(d, id, links, old)
	local keep = {}

	for _, l in ipairs(old or {}) do
		if l.at then
			keep[linkkey(l)] = l.at
		end
	end

	local seen, out = {}, {}

	for _, l in ipairs(links or {}) do
		if not M.RELS[l.rel] then
			error("unknown link rel \"" .. tostring(l.rel) .. "\"", 0)
		end
		if l.doc == id then
			error("a document cannot link to itself", 0)
		end

		local head = d:row("SELECT c.cid FROM doc d JOIN cid c ON c.id = d.head "
		    .. "WHERE d.id = ?", { l.doc })

		if not head then
			error("no document " .. tostring(l.doc), 0)
		end

		local at = l.at or not l.fresh and keep[linkkey(l)] or head

		if l.rev then
			at = d:row("SELECT c.cid FROM doc_version v JOIN cid c "
			    .. "ON c.id = v.node WHERE v.doc = ? AND v.rev = ?",
			    { l.doc, l.rev })
			if not at then
				error(("no rev %d of %s"):format(l.rev, l.doc), 0)
			end
		end

		local k = linkkey(l)

		if not seen[k] then
			seen[k] = true
			out[#out + 1] = { rel = l.rel, doc = l.doc, at = at, frag = l.frag,
			    name = l.name, pin = l.pin and true or nil, rev = l.rev }
		end
	end
	table.sort(out, function(a, b)
		return linkkey(a) < linkkey(b)
	end)
	return out
end

local function nullable(v)
	if v == nil then
		return drisl.null
	end
	return v
end

local function unnull(v)
	if v == drisl.null then
		return nil
	end
	return v
end

-- write(d, w) makes a new version and returns id, rev, binary cid.
-- w holds: id and rev (for an existing document, rev is the current
-- one), title, name, mime, content (file id), tags, about, links,
-- hidden, author, and handform (the caller chose the form itself).
function M.write(d, w)
	assert(w.author, "write: no author")

	local title = w.title and w.title:match("^%s*(.-)%s*$")

	if not title or title == "" then
		error("a document needs a title", 0)
	end

	local bad = secret.check(title)

	if bad then
		error("refused: title looks like it holds a secret (" .. bad .. ")",
		    0)
	end

	return d:tx(function()
		local id, rev, prev, created = w.id, 1, nil, util.now()
		local oldfile

		if id then
			local cur = M.doc(d, id)

			if not cur then
				error("no document " .. id, 0)
			end
			if cur.rev ~= w.rev then
				error(setmetatable({ id = id, rev = cur.rev, want = w.rev },
				    Conflict), 0)
			end
			rev = cur.rev + 1
			prev = cur.head
			oldfile = cur.content
		else
			id = util.newid()
		end

		local had = {}

		for _, r in ipairs(d:rows("SELECT name FROM tag WHERE doc = ?",
		    { id })) do
			had[r.name] = true
		end

		local tlist, terr = tags.clean(d, w.tags, had)

		if not tlist then
			error(terr, 0)
		end

		-- a form a person sets stays: a hand receipt makes the form
		-- classifier count it as edited. A classifier sets its own
		-- receipt in the same write.
		local wm = w.meta or {}
		local pm = prev and M.nodemeta(M.node(d, prev)) or {}
		local form = wm["dcterms.type"]

		if type(form) == "string" and wm["gen.form"] == pm["gen.form"]
		    and (w.handform or (prev and form ~= pm["dcterms.type"])) then
			wm["gen.form"] = "model=hand wrote=" .. form
			w.meta = wm
		end

		local mlist, merr = meta.clean(w.meta)

		if not mlist then
			error(merr, 0)
		end

		local nodemeta = {}

		for _, m in ipairs(mlist) do
			for _, v in ipairs(m.values) do
				local bad = secret.check(v)

				if bad then
					error("refused: " .. m.key .. " looks like it holds a "
					    .. "secret (" .. bad .. ")", 0)
				end
			end
			nodemeta[m.key] = #m.values == 1 and m.values[1]
			    or drisl.array(m.values)
		end
		local about = w.about

		if about then
			about = M.resolve_tag(d, about)
			if not w.hidden then
				local owner = d:row("SELECT id FROM doc WHERE about = ? "
				    .. "AND id != ? AND hidden = 0 "
				    .. "AND superseded_by IS NULL", { about, id })
				local taking = false

				for _, l in ipairs(w.links or {}) do
					if l.rel == "supersedes" and l.doc == owner then
						taking = true
					end
				end
				if owner and not taking then
					error("tag " .. about .. " already has an about page: "
					    .. owner .. " (supersede it to take over)", 0)
				end
			end
		end

		local old = prev and M.nodelinks(M.node(d, prev)) or {}
		local links = checklinks(d, id, w.links, old)
		local contentcid

		if w.content then
			contentcid = d:row("SELECT cid FROM cid WHERE id = ?",
			    { w.content })
		end

		local nodelinks = {}

		for i, l in ipairs(links) do
			nodelinks[i] = { rel = l.rel, doc = l.doc, at = drisl.link(l.at),
			    frag = l.frag, name = l.name, pin = l.pin }
		end

		local node = {
			type = "cairn/doc",
			v = 1,
			doc = id,
			rev = rev,
			prev = prev and drisl.link(d:row("SELECT cid FROM cid WHERE id = ?",
			    { prev })) or drisl.null,
			title = title,
			name = nullable(w.name),
			mime = nullable(w.mime),
			content = contentcid and drisl.link(contentcid) or drisl.null,
			tags = drisl.array(tlist),
			about = nullable(about),
			links = drisl.array(nodelinks),
			hidden = w.hidden and true or false,
			author = w.author,
			created = created,
			meta = #mlist > 0 and nodemeta or nil,
		}
		local bytes = drisl.encode(node)
		local c, head = d:put(cid.DAG_CBOR, bytes)
		local hidden = w.hidden and 1 or 0

		if rev == 1 then
			d:run("INSERT INTO doc (id, head, rev, title, mime, content, "
			    .. "about, hidden, author, created, updated) "
			    .. "VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)",
			    { id, head, title, w.mime, w.content, about, hidden,
			    w.author, created, created, n = 10 })
		else
			local n = d:run("UPDATE doc SET head = ?, rev = ?, title = ?, "
			    .. "mime = ?, content = ?, about = ?, hidden = ?, author = ?, "
			    .. "updated = ? WHERE id = ? AND rev = ?",
			    { head, rev, title, w.mime, w.content, about, hidden,
			    w.author, created, id, rev - 1, n = 11 })

			if n == 0 then
				local now = d:row("SELECT rev FROM doc WHERE id = ?", { id })

				error(setmetatable({ id = id, rev = now, want = w.rev },
				    Conflict), 0)
			end
		end
		d:run("INSERT INTO doc_version (doc, rev, node, author, created) "
		    .. "VALUES (?, ?, ?, ?, ?)", { id, rev, head, w.author, created })
		d:run("INSERT INTO state (key, value) VALUES ('gc.writes', 1) "
		    .. "ON CONFLICT (key) DO UPDATE SET value = value + 1")
		if oldfile and oldfile ~= w.content then
			M.unindex(d, oldfile)
		end

		d:run("DELETE FROM meta WHERE doc = ?", { id })
		for _, m in ipairs(mlist) do
			for i, v in ipairs(m.values) do
				d:run("INSERT INTO meta (doc, key, seq, value, start) "
				    .. "VALUES (?, ?, ?, ?, ?)", { id, m.key, i, v,
				    meta.DATES[m.key] and (meta.edtf(v)) or nil, n = 5 })
			end
		end

		d:run("DELETE FROM tag WHERE doc = ?", { id })
		for _, t in ipairs(tlist) do
			d:run("INSERT INTO tag (doc, name) VALUES (?, ?)", { id, t })
		end

		d:run("DELETE FROM link WHERE src = ?", { id })
		d:run("UPDATE doc SET superseded_by = NULL WHERE superseded_by = ?",
		    { id })
		for _, l in ipairs(links) do
			d:run("INSERT OR IGNORE INTO link (src, dst, rel) VALUES (?, ?, ?)",
			    { id, l.doc, l.rel })
			if l.rel == "supersedes" then
				d:run("UPDATE doc SET superseded_by = ? WHERE id = ?",
				    { id, l.doc })
			end
		end

		local n = d:row("SELECT n FROM doc WHERE id = ?", { id })

		d:run("DELETE FROM doc_fts WHERE rowid = ?", { n })
		d:run("INSERT INTO doc_fts (rowid, title, tags, abstract) "
		    .. "VALUES (?, ?, ?, ?)", { n, title, table.concat(tlist, " "),
		    d:row("SELECT value FROM meta WHERE doc = ? AND key = "
		    .. "'dcterms.abstract' ORDER BY seq LIMIT 1", { id }), n = 4 })
		return id, rev, c
	end)
end

function M.resolve_tag(d, s)
	local t, err = tags.normalize(s)

	if not t then
		error(err, 0)
	end
	return tags.resolve(d, t)
end

-- nodemeta(node) -> meta of a node as key -> text or list of text
function M.nodemeta(node)
	local out = {}

	for k, v in pairs(node.meta or {}) do
		if type(v) == "table" then
			local list = {}

			for i, x in ipairs(v) do
				list[i] = x
			end
			out[k] = list
		else
			out[k] = v
		end
	end
	return out
end

-- setmeta(d, id, changes, author) applies "key=value", "key=", and
-- "key+=value" changes and writes a new version
function M.setmeta(d, id, changes, author)
	return M.update(d, id, nil, author, function(w)
		meta.apply(w.meta, changes)
		for _, c in ipairs(changes) do
			if c:match("^dcterms%.type%+?=") then
				w.handform = true
			end
		end
	end)
end

-- current(d, id) -> write table built from the head node, for edits
function M.current(d, id)
	local cur = M.doc(d, id)

	if not cur then
		error("no document " .. tostring(id), 0)
	end

	local node = M.node(d, cur.head)
	local tl = {}

	for i, t in ipairs(node.tags) do
		tl[i] = t
	end
	return {
		id = id,
		rev = cur.rev,
		title = node.title,
		name = unnull(node.name),
		mime = unnull(node.mime),
		content = cur.content,
		tags = tl,
		about = unnull(node.about),
		links = M.nodelinks(node),
		hidden = node.hidden,
		meta = M.nodemeta(node),
	}, cur
end

-- content(d, fileid) -> file bytes
function M.content(d, fileid)
	local c = d:row("SELECT cid FROM cid WHERE id = ?", { fileid })

	return c and d:get(c)
end

-- neardups(d, title, body, except) -> up to 3 documents like this one
function M.neardups(d, title, body, except)
	local words = {}

	for w in (title .. " " .. (body or ""):sub(1, 300)):gmatch("[%w]+") do
		if #w > 2 and #words < 12 then
			words[#words + 1] = '"' .. w:lower() .. '"'
		end
	end
	if #words == 0 then
		return {}
	end

	local q = table.concat(words, " OR ")
	local rows = d:rows("SELECT d.id, d.title FROM doc_fts f "
	    .. "JOIN doc d ON d.n = f.rowid WHERE doc_fts MATCH ? "
	    .. "AND d.hidden = 0 AND d.superseded_by IS NULL AND d.about IS NULL "
	    .. "AND d.id != ? "
	    .. "ORDER BY bm25(doc_fts) LIMIT 3", { q, except or "" })

	return rows
end

-- note(d, n) writes a markdown note: n.title, n.body, n.tags, n.links,
-- n.author, and n.id + n.rev for a new version. Returns id, rev, cid,
-- near duplicates, close tags.
function M.note(d, n)
	local bad = secret.check(n.body)

	if bad then
		error("refused: text looks like it holds a secret (" .. bad .. ")",
		    0)
	end

	local dups = n.id and {} or M.neardups(d, n.title, n.body)
	local close = {}

	for _, t in ipairs(n.tags or {}) do
		local nt = tags.normalize(t)

		if nt then
			for _, c in ipairs(tags.close(d, tags.resolve(d, nt))) do
				close[#close + 1] = c
			end
		end
	end

	return d:tx(function()
		local file = M.putfile(d, n.body, "text/markdown", n.author)
		local w = n.base or {}
		local links, old = {}, w.links or {}

		-- links named in the body are rebuilt from it; the rest stay
		for _, l in ipairs(n.links or {}) do
			links[#links + 1] = l
		end
		for _, l in ipairs(old) do
			if not l.name then
				links[#links + 1] = l
			end
		end

		local body, wanted = M.bodylinks(d, n.body, old)

		for _, l in ipairs(body) do
			if l.doc ~= n.id then
				links[#links + 1] = l
			end
		end

		local nm = n.meta or w.meta

		local handform = nm and nm["dcterms.type"] ~= nil

		-- a new note is form note unless it says otherwise
		if not n.id and not n.about then
			nm = nm or {}
			nm["dcterms.type"] = nm["dcterms.type"] or "note"
		end

		local id, rev, c = M.write(d, {
			id = n.id, rev = n.rev,
			title = n.title or w.title,
			name = w.name,
			mime = "text/markdown",
			content = file,
			tags = n.tags or w.tags,
			about = n.about or w.about,
			links = links,
			hidden = w.hidden,
			meta = nm,
			author = n.author,
			handform = handform,
		})

		d:run("DELETE FROM wanted WHERE src = ?", { id })
		for _, t in ipairs(wanted) do
			d:run("INSERT OR IGNORE INTO wanted (src, title) VALUES (?, ?)",
			    { id, t })
		end

		M.indextext(d, file, "text/markdown", n.body)
		return id, rev, c, dups, close, wanted, M.fills(d, id)
	end)
end

-- filemeta(data, mime) -> meta read from the file itself: the PDF Info
-- fields as pdf.*, and a dcterms.creator guess. Empty for other types.
function M.filemeta(data, mime)
	if mime ~= "application/pdf" then
		return {}
	end

	local path = util.tmpfile(".pdf")

	util.writefile(path, data)

	local ok, out, code = pcall(require("cairn.proc").run,
	    { "pdfinfo", "-isodates", path })

	os.remove(path)
	if not ok or code ~= 0 then
		return {}
	end
	return meta.guess(meta.pdfinfo(out))
end

-- attach(d, a) stores a file: a.data, a.name, a.mime, a.title, a.tags,
-- a.links, a.author. Text files are indexed at once; other files get
-- extraction jobs. Returns id, rev, file cid, list of job kinds.
function M.attach(d, a)
	local mime = a.mime or util.mimeof(a.name)

	-- the same bytes again give back the document that holds them, so a
	-- repeat download or a second import makes no second document
	if not a.force then
		local fc = cid.sha256(cid.RAW, a.data)
		local have = d:rows("SELECT d.id, d.rev FROM doc d JOIN cid c "
		    .. "ON c.id = d.content WHERE c.cid = ? "
		    .. "ORDER BY d.hidden, d.superseded_by IS NOT NULL, d.updated DESC",
		    { fc }, { true })[1]

		if have then
			return have.id, have.rev, fc, {}, true
		end
	end

	if util.istext(mime) or mime:match("^text/") and mime ~= "text/html" then
		local bad = secret.check(a.data)

		if bad then
			error("refused: file looks like it holds a secret (" .. bad
			    .. ")", 0)
		end
	end

	local m = M.filemeta(a.data, mime)

	for k, v in pairs(a.meta or {}) do
		m[k] = v
	end

	return d:tx(function()
		local file, fc = M.putfile(d, a.data, mime, a.author)
		local id, rev = M.write(d, {
			title = a.title or a.name or "untitled",
			name = a.name,
			mime = mime,
			content = file,
			tags = a.tags,
			links = a.links,
			meta = m,
			author = a.author,
		})
		local kinds = {}

		if util.istext(mime) then
			M.indextext(d, file, mime, a.data)
		else
			for _, k in ipairs(M.jobkinds(mime)) do
				d:run("INSERT OR IGNORE INTO job (file, kind, status, created) "
				    .. "VALUES (?, ?, 'pending', ?)", { file, k, util.now() })
				kinds[#kinds + 1] = k
			end
		end
		return id, rev, fc, kinds
	end)
end

-- update(d, id, rev, fn, author) applies fn to the current write table
-- and writes a new version
function M.update(d, id, rev, author, fn)
	return d:tx(function()
		local w = M.current(d, id)

		if rev and rev ~= w.rev then
			error(setmetatable({ id = id, rev = w.rev, want = rev },
			    Conflict), 0)
		end
		fn(w)
		w.author = author
		return M.write(d, w)
	end)
end

-- link(d, src, target, rel, remove, author) adds or removes a link from
-- src to a target that ref() reads. Linking again to the same target
-- records its current version, which clears a "changed" mark.
function M.link(d, src, target, rel, remove, author)
	local r, why = M.ref(d, target)

	if not r then
		error(why, 0)
	end
	return M.update(d, src, nil, author, function(w)
		local keep = {}

		for _, l in ipairs(w.links) do
			if not (l.doc == r.doc and l.rel == rel
			    and (l.frag or "") == (r.frag or "")) then
				keep[#keep + 1] = l
			end
		end
		if not remove then
			keep[#keep + 1] = { rel = rel, doc = r.doc, frag = r.frag,
			    rev = r.rev, pin = r.pin, fresh = true }
		end
		w.links = keep
	end)
end

-- pending(d, fileid) -> true when extraction of the file is not done
function M.pending(d, fileid)
	return d:row("SELECT 1 FROM job WHERE file = ? "
	    .. "AND status IN ('pending', 'running')", { fileid }) ~= nil
end

-- text(d, fileid) -> list of { kind, extractor, chunks = {...} }. It
-- leaves out expand extractions: their terms are for the index, not
-- the text a reader or a classifier sees.
function M.text(d, fileid)
	local out = {}

	for _, e in ipairs(d:rows("SELECT id, kind, extractor FROM extract "
	    .. "WHERE file = ? AND kind != 'expand' ORDER BY kind, extractor",
	    { fileid })) do
		e.chunks = d:rows("SELECT seq, page, heading, body FROM chunk "
		    .. "WHERE extract = ? ORDER BY seq", { e.id })
		out[#out + 1] = e
	end
	return out
end

return M
