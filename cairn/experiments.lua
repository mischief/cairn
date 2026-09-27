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

-- meta: ask jev (lgml systemone) for a document's year, type, and
-- language, and whether its creator name is real

M.MIN = 0.8
M.TEXT = 3000

M.TYPES = {
	specification = "a technical specification of a format, protocol, "
	    .. "interface, or architecture from one vendor or project",
	standard = "a standard or draft approved by a standards body such as "
	    .. "ISO, OASIS, or a government",
	manual = "a programmer's, user's, or technical reference manual for a "
	    .. "product or chip family",
	datasheet = "electrical and pin data of one part or module",
	paper = "a research paper",
	schematic = "a circuit schematic",
	book = "a book or monograph",
	notes = "notes, a web page, or API documentation",
}

M.LANGS = { en = "English", pl = "Polish", de = "German", fr = "French",
    zh = "Chinese", ja = "Japanese", other = "another language" }

local function years(s)
	local seen, out = {}, {}
	local now = tonumber(os.date("!%Y"))

	for y in s:gmatch("%f[%d]([12]%d%d%d)%f[%D]") do
		local n = tonumber(y)

		if n >= 1950 and n <= now and not seen[y] then
			seen[y] = true
			out[#out + 1] = y
		end
	end
	table.sort(out)
	while #out > 16 do
		table.remove(out, 1)
	end
	return out
end

-- sample(parts, from, n) -> up to n characters of chunk bodies, starting
-- at chunk index from
local function sample(chunks, from, n)
	local out, size = {}, 0

	for i = from, #chunks do
		local b = chunks[i].body:gsub("[ \t]+", " "):gsub("%.%s?%.[%.%s]*", ". ")

		out[#out + 1] = b
		size = size + #b
		if size > n then
			break
		end
	end
	-- a byte cut can split a character, so clean after it
	return require("cairn.chunk").utf8(table.concat(out, "\n"):sub(1, n))
end

-- questions(d, doc) -> state, questions for one document
local function questions(d, row)
	local store = require "cairn.store"
	local w = store.current(d, row.id)
	local m = w.meta
	local chunks = {}

	for _, e in ipairs(w.content and store.text(d, w.content) or {}) do
		for _, c in ipairs(e.chunks) do
			chunks[#chunks + 1] = c
		end
	end

	local head = { "Title in the library: " .. w.title }

	for _, k in ipairs({ "pdf.Title", "pdf.Subject", "pdf.Author",
	    "pdf.Keywords" }) do
		if m[k] then
			head[#head + 1] = k:sub(5) .. " (from the PDF file): "
			    .. (type(m[k]) == "table" and table.concat(m[k], "; ") or m[k])
		end
	end

	local front = sample(chunks, 1, M.TEXT)
	local state = require("cairn.chunk").utf8(table.concat(head, "\n")
	    .. "\n\nFirst pages:\n" .. front)
	local q = {}
	local ys = years(w.title .. " " .. tostring(m["pdf.Subject"] or "")
	    .. " " .. tostring(m["pdf.Title"] or "") .. " " .. front)

	if #ys > 0 then
		local crit = { none = "the text shows no year of publication" }

		for _, y in ipairs(ys) do
			crit[y] = "published or last revised in " .. y
		end
		q.year = { type = "choice", criteria = crit,
		    instructions = "In which year was this document published or "
		    .. "last revised?" }
	end
	q.type = { type = "choice", criteria = M.TYPES,
	    instructions = "What kind of document is this?" }

	-- judge the language from inside the document, not its cover
	local inner = sample(chunks, math.max(2, #chunks // 3), 1200)

	if inner ~= "" then
		q.language = { type = "choice", criteria = M.LANGS,
		    instructions = "What language is this passage from the body of "
		    .. "the document written in?\nPassage:\n" .. inner }
	end

	local creator = m["dcterms.creator"]

	if type(creator) == "table" then
		creator = table.concat(creator, "; ")
	end
	if creator then
		q.creator_ok = { type = "noul",
		    instructions = ("Is '%s' the name of a real person or "
		    .. "organization that wrote or published this document?")
		    :format(creator),
		    criteria = { ["true"] = "a real author or publisher name",
		    ["false"] = "junk, a program name, or a placeholder" } }
	end
	return state, q, w
end

local function sure(a)
	return a and a.choice and a.choice ~= "none"
	    and (a.confidence or 0) >= M.MIN and a.choice
end

-- changes(w, answers) -> meta changes to apply, filling only empty keys
local function changes(w, a)
	local m, ch = w.meta, {}
	local y, t, l = sure(a.year), sure(a.type), sure(a.language)

	if y and not m["dcterms.date"] then
		ch[#ch + 1] = "dcterms.date=" .. y
	end
	if t and not m["dcterms.type"] then
		ch[#ch + 1] = "dcterms.type=" .. t
	end
	if l and not m["dcterms.language"] then
		ch[#ch + 1] = "dcterms.language=" .. l
	end
	if a.creator_ok and a.creator_ok.noul and a.creator_ok.noul < 0.5 then
		ch[#ch + 1] = "dcterms.creator="
	end
	return ch
end

local function fmt(a)
	if not a then
		return "-"
	end
	if a.choice then
		return ("%s (%.2f)"):format(a.choice, a.confidence or 0)
	end
	if a.noul then
		return ("%.2f"):format(a.noul)
	end
	return "?"
end

M.list.meta = {
	usage = "meta [ID... | --all] [--apply] [--model m]",
	desc = "guess year, type, and language with jev; without IDs only "
	    .. "documents not checked yet; --apply writes answers at 0.8 or "
	    .. "above into empty fields",
	run = function(p, d)
		local lgml = require "cairn.lgml"
		local store = require "cairn.store"
		local cli = require "cairn.cli"
		local model = p.opts.model or config.get(d, "lgml.decide")
		local c = lgml.client(d, { timeout = 600 })
		local ids = {}

		for _, a in ipairs(p.args) do
			ids[#ids + 1] = cli.docid(d, a)
		end
		if #ids == 0 then
			-- without --all, only documents jev has not checked yet
			for _, r in ipairs(d:rows("SELECT id FROM doc d WHERE hidden = 0 "
			    .. "AND superseded_by IS NULL AND (? OR NOT EXISTS (SELECT 1 "
			    .. "FROM meta m WHERE m.doc = d.id AND m.key = 'jev.checked')) "
			    .. "ORDER BY title", { p.opts.all and 1 or 0 })) do
				ids[#ids + 1] = r.id
			end
		end

		local applied = 0

		for _, id in ipairs(ids) do
			local state, q, w = questions(d, { id = id })
			local r, err = c:systemone{ model = model, state = state,
			    questions = q,
			    lgml = { recipe = { prior_weight = { noul = 1 } } } }

			if not r then
				print(("%s  error: %s %s"):format(id, err.kind,
				    err.message or ""))
			else
				local a = r.answers or {}
				local ch = changes(w, a)

				print(("%s  %s\n    year %s  type %s  language %s  "
				    .. "creator_ok %s%s"):format(id, w.title:sub(1, 60),
				    fmt(a.year), fmt(a.type), fmt(a.language),
				    fmt(a.creator_ok), #ch > 0 and ("\n    -> "
				    .. table.concat(ch, " ")) or ""))
				if p.opts.apply and #ch > 0 then
					ch[#ch + 1] = "jev.model=" .. model
					ch[#ch + 1] = "jev.checked=" .. os.date("!%Y-%m-%d")
					store.setmeta(d, id, ch, cli.author())
					applied = applied + 1
				end
			end
		end
		c:close()
		print(p.opts.apply and ("%d documents changed"):format(applied)
		    or "dry run; --apply writes the -> lines")
	end,
}

-- chunks(d, file, skip) -> the chunks of a file's extractions, in page
-- order, leaving out the kind named by skip
local function filechunks(d, file, skip)
	local out = {}

	for _, r in ipairs(d:rows("SELECT c.id, c.page, c.heading, c.body "
	    .. "FROM chunk c JOIN extract e ON e.id = c.extract "
	    .. "WHERE e.file = ? AND e.kind != ? ORDER BY e.kind, c.seq",
	    { file, skip or "" })) do
		out[#out + 1] = r
	end
	return out
end

local function targets(p, d)
	local cli = require "cairn.cli"
	local ids = {}

	for _, a in ipairs(p.args) do
		ids[#ids + 1] = cli.docid(d, a)
	end
	if #ids == 0 then
		for _, r in ipairs(d:rows("SELECT id FROM doc WHERE hidden = 0 "
		    .. "AND superseded_by IS NULL ORDER BY title")) do
			ids[#ids + 1] = r.id
		end
	end
	return ids
end

-- similar: a vector per document from its chunks, then the nearest
-- documents of each, stored as rows. Search needs no model afterwards.

M.SAMPLE = 48

local function pack(v)
	local out = {}

	for i, x in ipairs(v) do
		out[i] = string.pack("<f", x)
	end
	return table.concat(out)
end

local function unpack(s)
	local out = {}

	for i = 1, #s // 4 do
		out[i] = string.unpack("<f", s, 4 * i - 3)
	end
	return out
end

local function dot(a, b)
	local s = 0

	for i = 1, #a do
		s = s + a[i] * b[i]
	end
	return s
end

-- docvector(c, title, chunks, model, dims) -> unit mean vector of up to
-- SAMPLE chunks spread evenly over the document
local function docvector(lgml, c, title, chunks, model, dims)
	local texts = {}
	local step = math.max(1, #chunks / M.SAMPLE)

	for i = 1, #chunks, step do
		local ch = chunks[math.floor(i)]

		texts[#texts + 1] = require("cairn.chunk").utf8(("Title: %s\n%s")
		    :format(title, ch.body:sub(1, 6000)))
	end
	if #texts == 0 then
		texts[1] = "Title: " .. title
	end

	local sum = {}

	for i = 1, #texts, 16 do
		local batch = { table.unpack(texts, i, math.min(i + 15, #texts)) }

		for _, v in ipairs(lgml.embed(c, batch, { model = model,
		    dimensions = dims })) do
			for k, x in ipairs(v) do
				sum[k] = (sum[k] or 0) + x
			end
		end
	end

	local len = math.sqrt(dot(sum, sum))

	for k, x in ipairs(sum) do
		sum[k] = x / len
	end
	return sum, #texts
end

M.list.similar = {
	usage = "similar [--top n] [--dims n] [--model m] [--force]",
	desc = "embed each document once and store its nearest documents",
	run = function(p, d)
		local lgml = require "cairn.lgml"
		local util = require "cairn.util"
		local model = p.opts.model or config.get(d, "lgml.embed")
		local dims = math.tointeger(tonumber(p.opts.dims)) or 512
		local top = math.tointeger(tonumber(p.opts.top)) or 10
		local c = lgml.client(d, { timeout = 900 })
		local made, t0 = 0, os.time()

		for _, id in ipairs(targets({ args = {} }, d)) do
			local row = d:rows("SELECT title, content FROM doc WHERE id = ?",
			    { id })[1]
			local have = d:rows("SELECT file, model, dims FROM docvec "
			    .. "WHERE doc = ?", { id })[1]

			if p.opts.force or not have or have.file ~= row.content
			    or have.model ~= model or have.dims ~= dims then
				local chunks = row.content and filechunks(d, row.content,
				    "expand") or {}
				local v, n = docvector(lgml, c, row.title, chunks, model, dims)

				d:run("INSERT INTO docvec (doc, file, model, dims, chunks, "
				    .. "created, v) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT "
				    .. "(doc) DO UPDATE SET file = excluded.file, model = "
				    .. "excluded.model, dims = excluded.dims, chunks = "
				    .. "excluded.chunks, created = excluded.created, "
				    .. "v = excluded.v",
				    { id, row.content, model, dims, n, util.now(), pack(v),
				    n = 7 }, { [7] = true })
				made = made + 1
				io.stderr:write(("%s %d chunks, %d s\n"):format(
				    row.title:sub(1, 50), n, os.time() - t0))
			end
		end
		c:close()

		-- neighbours from the stored vectors alone
		local vecs = {}

		for _, r in ipairs(d:rows("SELECT v.doc, v.v FROM docvec v "
		    .. "JOIN doc d ON d.id = v.doc WHERE v.model = ? AND v.dims = ? "
		    .. "AND d.hidden = 0 AND d.superseded_by IS NULL",
		    { model, dims })) do
			vecs[#vecs + 1] = { id = r.doc, v = unpack(r.v) }
		end
		d:tx(function()
			d:run("DELETE FROM similar")
			for _, a in ipairs(vecs) do
				local near = {}

				for _, b in ipairs(vecs) do
					if a.id ~= b.id then
						near[#near + 1] = { id = b.id, s = dot(a.v, b.v) }
					end
				end
				table.sort(near, function(x, y)
					return x.s > y.s
				end)
				for k = 1, math.min(top, #near) do
					d:run("INSERT INTO similar (doc, other, score, model) "
					    .. "VALUES (?, ?, ?, ?)",
					    { a.id, near[k].id, near[k].s, model })
				end
			end
		end)
		print(("%d documents embedded, %d with neighbours, %d s"):format(
		    made, #vecs, os.time() - t0))
	end,
}

-- expand: per chunk, a model writes the words a reader might search
-- for; they are indexed as an extraction of kind "expand"

M.EXPAND = "Write what a reader might type into a search box to find this "
    .. "passage of a technical document: synonyms, expanded acronyms, "
    .. "related concepts, and the names of registers, functions, fields, "
    .. "or commands it covers; then up to 4 questions the passage "
    .. "answers. Use words that are not already in the passage where you "
    .. "can."

M.SCHEMA = {
	type = "object",
	properties = {
		terms = { type = "array", items = { type = "string" }, maxItems = 24 },
		questions = { type = "array", items = { type = "string" },
		    maxItems = 4 },
	},
	required = { "terms", "questions" },
}

M.list.expand = {
	usage = "expand ID... | --all [--model m] [--force]",
	desc = "write search terms and questions per chunk with a model, and "
	    .. "index them",
	run = function(p, d)
		local lgml = require "cairn.lgml"
		local store = require "cairn.store"
		local model = p.opts.model or config.get(d, "lgml.decide")

		if #p.args == 0 and not p.opts.all then
			error("expand costs a model call per chunk: name documents, "
			    .. "or give --all", 0)
		end

		local c = lgml.client(d, { timeout = 900 })
		local t0 = os.time()
		local total = 0

		for _, id in ipairs(targets(p, d)) do
			local row = d:rows("SELECT title, content FROM doc WHERE id = ?",
			    { id })[1]
			local done = row.content and d:row("SELECT 1 FROM extract "
			    .. "WHERE file = ? AND kind = 'expand'", { row.content })

			if row.content and (p.opts.force or not done) then
				local out = {}

				for i, ch in ipairs(filechunks(d, row.content, "expand")) do
					local text = lgml.chat(c, {
						model = model,
						max_tokens = 400,
						chat_template_kwargs = { enable_thinking = false },
						response_format = { type = "json_schema",
						    json_schema = { schema = M.SCHEMA } },
						messages = { {
							role = "user",
							content = M.EXPAND .. "\n\nDocument: " .. row.title
							    .. (ch.heading and ("\nSection: " .. ch.heading)
							    or "") .. "\n\nPassage:\n"
							    .. require("cairn.chunk").utf8(ch.body:sub(1,
							    6000)),
						} },
					})
					local ok, r = pcall(require("lgml.client").json.decode,
					    text)

					if ok and type(r) == "table" then
						out[#out + 1] = { page = ch.page, heading = ch.heading,
						    body = "terms: " .. table.concat(r.terms or {},
						    "; ") .. "\nquestions: " .. table.concat(
						    r.questions or {}, " ") }
					end
					if i % 10 == 0 then
						io.stderr:write(("%s: %d chunks, %d s\n"):format(
						    row.title:sub(1, 40), i, os.time() - t0))
					end
				end
				store.index(d, row.content, "expand", "lgml:" .. model, 1, out)
				total = total + #out
				print(("%s  %d chunks expanded"):format(row.title:sub(1, 60),
				    #out))
			end
		end
		c:close()
		print(("%d chunks, %d s"):format(total, os.time() - t0))
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
