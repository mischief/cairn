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

-- the forms of cairn/vocab.lua, as choices for dcterms.type
M.TYPES = {}

for _, f in ipairs(require("cairn.vocab").forms) do
	M.TYPES[f[1]] = f[2]
end

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
		-- about pages define tags; they are not content to compare
		for _, r in ipairs(d:rows("SELECT id FROM doc WHERE hidden = 0 "
		    .. "AND superseded_by IS NULL AND about IS NULL ORDER BY title")) do
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
			local have = d:rows("SELECT file, model, dims, created FROM "
			    .. "docvec WHERE doc = ?", { id })[1]
			-- text extracted after the vector was made, such as a PDF
			-- enriched after its first embedding
			local newer = have and row.content and d:row("SELECT 1 FROM "
			    .. "extract WHERE file = ? AND kind != 'expand' AND "
			    .. "created > ?", { row.content, have.created })

			if p.opts.force or not have or have.file ~= row.content
			    or have.model ~= model or have.dims ~= dims or newer then
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
		    .. "AND d.hidden = 0 AND d.superseded_by IS NULL "
		    .. "AND d.about IS NULL",
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
    .. "can. Answer as JSON: {\"terms\": [\"...\", \"...\"], "
    .. "\"questions\": [\"...?\"]}, one term or question a string."


M.SCHEMA = {
	type = "object",
	additionalProperties = false,
	properties = {
		-- a bounded pattern caps each string; lgml ignores maxLength when
		-- a pattern is present
		terms = { type = "array", minItems = 3, maxItems = 16,
		    items = { type = "string", pattern = "^[^\\[\\]{}`<>]{2,80}$" } },
		questions = { type = "array", minItems = 1, maxItems = 4,
		    items = { type = "string", pattern = "^[^\\[\\]{}`<>]{8,200}$" } },
	},
	required = { "terms", "questions" },
}

-- notes and field names a model leaks into a list
local LEAKS = { "_note", "unquote", "^terms$", "^questions$" }

-- looping(s) -> true when s repeats like a model stuck in a loop: one
-- word 3 times in a row ("the-the-the"), or a word of 4 or more letters
-- 4 times anywhere ("implementer implementation implementer ...").
-- A normal question uses "the" 3 times, so short words count only in a
-- row.
local function looping(s)
	local seen, last, run = {}, nil, 0

	for w in s:lower():gmatch("%a+") do
		run = w == last and run + 1 or 1
		last = w
		seen[w] = (seen[w] or 0) + 1
		if run >= 3 or (#w >= 4 and seen[w] >= 4) then
			return true
		end
	end
	return false
end

-- clean(list, max) -> the strings of list a model got right: bullets
-- split apart, markup, runaway text, loops and leaked notes dropped,
-- words doubled by a slip ("to to") made single
function M.clean(list, max)
	local out = {}

	for _, s in ipairs(type(list) == "table" and list or {}) do
		if type(s) == "string" then
			-- a bullet is a hyphen before a space; "test-and-set" stays
			for part in (s:gsub("%-%s+", "\0") .. "\0"):gmatch("([^%z]*)%z") do
				part = part:gsub("^%s+", ""):gsub("%s+$", "")
				part = part:gsub("%f[%w](%w+) %1%f[%W]", "%1")

				local low, leak = part:lower(), false

				for _, l in ipairs(LEAKS) do
					leak = leak or low:find(l) ~= nil
				end
				if #part >= 2 and #part <= max and not part:find("[][{}`<>]")
				    and not low:find("json", 1, true) and not leak
				    and not looping(part) then
					out[#out + 1] = part
				end
			end
		end
	end
	return out
end

M.list.expand = {
	usage = "expand ID... | --all [--apply] [--model m] [--force]",
	desc = "write search terms and questions per chunk with a model; a dry "
	    .. "run prints them, --apply indexes them",
	run = function(p, d)
		local lgml = require "cairn.lgml"
		local store = require "cairn.store"
		local client = lgml.available()
		local model = p.opts.model or config.get(d, "lgml.decide")

		if #p.args == 0 and not p.opts.all then
			error("expand costs a model call per chunk: name documents, "
			    .. "or give --all", 0)
		end

		local schema = {}

		for k, v in pairs(M.SCHEMA) do
			schema[k] = v
		end
		schema.required = client.array(M.SCHEMA.required)

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

				print(("== %s  %s"):format(id, row.title))
				for i, ch in ipairs(filechunks(d, row.content, "expand")) do
					-- greedy decoding loops on open lists; some randomness
					-- with a presence penalty keeps the terms varied
					local text = lgml.chat(c, {
						model = model,
						max_tokens = 400,
						temperature = 0.4,
						presence_penalty = 0.5,
						chat_template_kwargs = { enable_thinking = false },
						response_format = { type = "json_schema",
						    json_schema = { name = "expand", schema = schema } },
						messages = { {
							role = "user",
							content = M.EXPAND .. "\n\nDocument: " .. row.title
							    .. (ch.heading and ("\nSection: " .. ch.heading)
							    or "") .. "\n\nPassage:\n"
							    .. require("cairn.chunk").utf8(ch.body:sub(1,
							    6000)),
						} },
					})
					local ok, r = pcall(client.json.decode, text)

					if ok and type(r) == "table" then
						local terms = M.clean(r.terms, 80)
						local qs = M.clean(r.questions, 200)

						if #terms + #qs > 0 then
							local body = "terms: " .. table.concat(terms, "; ")
							    .. "\nquestions: " .. table.concat(qs, " ")

							out[#out + 1] = { page = ch.page,
							    heading = ch.heading, body = body }
							print(("  %s\n    %s"):format(ch.page and ("p"
							    .. ch.page) or ch.heading or ("#" .. i),
							    body:gsub("\n", "\n    ")))
						end
					end
				end
				if p.opts.apply then
					store.index(d, row.content, "expand", "lgml:" .. model, 1,
					    out)
				end
				total = total + #out
			end
		end
		c:close()
		print(("%d chunks, %d s; %s"):format(total, os.time() - t0,
		    p.opts.apply and "indexed" or "dry run; --apply indexes them"))
	end,
}

-- form: a model picks each document's form (dcterms.type) from the forms
-- in cairn/vocab.lua. A value a person set is kept; values written by a
-- model (jev.model or gen.type) are judged again.

-- tags that name a form; form --apply moves them into dcterms.type
M.FORMTAGS = { spec = true, specification = true, manual = true,
    paper = true, standard = true, datasheet = true, schematic = true }

-- formstate(d, id) -> prompt state for one document, its current version
local function formstate(d, id)
	local store = require "cairn.store"
	local w = store.current(d, id)
	local chunks = {}

	for _, e in ipairs(w.content and store.text(d, w.content) or {}) do
		for _, c in ipairs(e.chunks) do
			chunks[#chunks + 1] = c
		end
	end

	local tags = {}

	for _, t in ipairs(w.tags) do
		if not t:match("^topic/") then
			tags[#tags + 1] = t
		end
	end

	local head = { "Title: " .. w.title, "File type: " .. (w.mime or "?") }

	if #tags > 0 then
		head[#head + 1] = "Tags: " .. table.concat(tags, ", ")
	end
	return require("cairn.chunk").utf8(table.concat(head, "\n")
	    .. "\n\nStart of the document:\n" .. sample(chunks, 1, 2500)), w
end

local receipt = require "cairn.receipt"

-- classifier versions; raising one makes earlier receipts old
M.VERSION = { form = 2, topics = 4, abstract = 1 }

-- state(d, name, w, model, vocab, now, blank) -> the receipt state of
-- version w for classifier name. now(w) is what w holds today; without
-- a receipt, a value in blank (such as the default form note) counts
-- as nothing written yet.
function M.state(d, name, w, model, vocab, now, blank)
	local r = receipt.parse(w.meta[receipt.key(name)])
	local cur = now(w)

	if not r then
		return (cur == "" or (blank or {})[cur]) and "new" or "edited"
	end
	return receipt.state(r, { v = M.VERSION[name], model = model,
	    content = receipt.content(d, w.content),
	    legacy = receipt.legacy(d, w.content), vocab = vocab }, cur)
end

-- plan(p, d, name, model, vocab, now, blank) -> ids to run, counts by
-- state. Named ids always run; --tag limits the candidates to one tag,
-- topics under it included.
local function plan(p, d, name, model, vocab, now, blank)
	local store = require "cairn.store"
	local cli = require "cairn.cli"
	local run, ids, count, cand = receipt.which(p.opts), {}, {}, {}

	if #p.args > 0 then
		for _, a in ipairs(p.args) do
			ids[#ids + 1] = cli.docid(d, a)
		end
		return ids, count
	end
	-- the parser files --tag and -t into one list, opts.t
	local tags = p.opts.t or (p.opts.tag and { p.opts.tag }) or {}

	if #tags > 0 then
		for _, h in ipairs((require("cairn.search").search(d, "",
		    { tag = tags, limit = 100000, max = 100000,
		    chunks = 1 }))) do
			cand[#cand + 1] = h.id
		end
	else
		for _, r in ipairs(d:rows("SELECT id FROM doc WHERE hidden = 0 "
		    .. "AND superseded_by IS NULL AND about IS NULL ORDER BY title")) do
			cand[#cand + 1] = r.id
		end
	end
	for _, id in ipairs(cand) do
		local st = M.state(d, name, store.current(d, id), model, vocab, now,
		    blank)

		count[st] = (count[st] or 0) + 1
		if run[st] then
			ids[#ids + 1] = id
		end
	end
	-- a vocabulary or version change marks every document stale; a
	-- rerun of all of them must be asked for by name
	if p.opts.stale and not p.opts.all and #tags == 0 then
		error(("--stale would run %s on %d document%s; limit it with --tag "
		    .. "or ids, or give --all"):format(name, #ids,
		    #ids == 1 and "" or "s"), 0)
	end
	return ids, count
end

-- stamp(d, name, id, model, vocab, wrote, change) writes a new version
-- of id as author cairn:NAME: change(w) edits it, and the receipt
-- records what the classifier wrote
-- while update runs, stamps queue here, one list of changes a document,
-- and update writes each document once at the end
local batch

local function stamp(d, name, id, model, vocab, wrote, change)
	local function edit(w)
		if change then
			change(w)
		end
		w.meta[receipt.key(name)] = receipt.format({ v = M.VERSION[name],
		    model = model, content = receipt.content(d, w.content),
		    vocab = vocab, wrote = wrote })
	end

	if batch then
		if not batch.edits[id] then
			batch.edits[id] = {}
			batch.order[#batch.order + 1] = id
		end
		table.insert(batch.edits[id], edit)
		return
	end
	require("cairn.store").update(d, id, nil, "cairn:" .. name, edit)
end

-- flush(d) writes each queued document as one version by cairn:update
local function flush(d)
	local store = require "cairn.store"
	local b = batch

	batch = nil
	for _, id in ipairs(b and b.order or {}) do
		store.update(d, id, nil, "cairn:update", function(w)
			for _, edit in ipairs(b.edits[id]) do
				edit(w)
			end
		end)
	end
	return b and #b.order or 0
end

-- adopt(d, name, model, vocab, now, ok) writes a receipt for each
-- document that holds a value but no receipt, when ok(w) says a model
-- wrote it; returns the count
local function adopt(d, name, model, vocab, now, ok)
	local store = require "cairn.store"
	local n = 0

	for _, r in ipairs(d:rows("SELECT id FROM doc WHERE hidden = 0 AND "
	    .. "superseded_by IS NULL AND about IS NULL")) do
		local w = store.current(d, r.id)

		if not w.meta[receipt.key(name)] and now(w) ~= "" and ok(w) then
			stamp(d, name, r.id, model, vocab, now(w), function(nw)
				nw.meta["gen.type"] = nil
			end)
			n = n + 1
		end
	end
	return n
end

local function formnow(w)
	local t = w.meta["dcterms.type"]

	return type(t) == "string" and t or ""
end

local function formvocab()
	local s = {}

	for _, f in ipairs(require("cairn.vocab").forms) do
		s[#s + 1] = f[1] .. "\t" .. f[2]
	end
	return receipt.hash(table.concat(s, "\n"))
end

M.list.form = {
	usage = "form [ID... | --stale | --all] [--tag t] [--apply] [--adopt]",
	desc = "pick each document's form (dcterms.type) from the list in "
	    .. "cairn/vocab.lua; without IDs only new and changed documents; "
	    .. "--apply writes it with a receipt and drops form tags",
	run = function(p, d)
		local lgml = require "cairn.lgml"
		local client = lgml.available()
		local model = p.opts.model or config.get(d, "lgml.decide")
		local forms, lines = {}, {}

		for _, f in ipairs(require("cairn.vocab").forms) do
			forms[#forms + 1] = f[1]
			lines[#lines + 1] = ("- %s: %s"):format(f[1], f[2])
		end

		local vocab = formvocab()

		if p.opts.adopt then
			print(("%d receipts written"):format(adopt(d, "form", model,
			    vocab, formnow, function(w)
				return w.meta["gen.type"] ~= nil
			end)))
			return
		end

		local ids = plan(p, d, "form", model, vocab, formnow,
		    { note = true })
		local c = lgml.client(d, { timeout = 600 })
		local count, done, t0 = {}, 0, os.time()
		local schema = { type = "object", additionalProperties = false,
		    required = client.array({ "form" }), properties = { form = {
		    type = "string", enum = client.array(forms) } } }

		for _, id in ipairs(ids) do
			local state, w = formstate(d, id)
			local r = c:call("POST", "/v1/chat/completions", {
				model = model,
				max_tokens = 40,
				temperature = 0,
				chat_template_kwargs = { enable_thinking = false },
				response_format = { type = "json_schema",
				    json_schema = { name = "form", schema = schema } },
				messages = { { role = "user", content = state
				    .. "\n\nWhat kind of document is this? Pick one form:\n"
				    .. table.concat(lines, "\n") } },
			})
			local text = r and r.choices and r.choices[1]
			    and r.choices[1].message and r.choices[1].message.content
			local ok, a = pcall(client.json.decode, text or "")
			local form = ok and type(a) == "table" and M.TYPES[a.form]
			    and a.form

			if not form then
				print(("%s  error: no form in the reply"):format(id))
			else
				local old = w.meta["dcterms.type"]
				local drop = {}

				for _, t in ipairs(w.tags) do
					if M.FORMTAGS[t] then
						drop[#drop + 1] = t
					end
				end
				done = done + 1
				count[form] = (count[form] or 0) + 1
				print(("%s  %-50s  %-13s -> %s%s"):format(id,
				    require("cairn.chunk").utf8(w.title:sub(1, 50)),
				    type(old) == "string" and old or "-", form,
				    #drop > 0 and ("  (drops tag " .. table.concat(drop, " ")
				    .. ")") or ""))
				if p.opts.apply then
					stamp(d, "form", id, model, vocab, form, function(nw)
						local keep = {}

						for _, t in ipairs(nw.tags) do
							if not M.FORMTAGS[t] then
								keep[#keep + 1] = t
							end
						end
						nw.tags = keep
						nw.meta["dcterms.type"] = form
						nw.meta["gen.type"] = nil
					end)
				end
			end
		end
		c:close()

		local rows = {}

		for f, n in pairs(count) do
			rows[#rows + 1] = { f = f, n = n }
		end
		table.sort(rows, function(x, y)
			return x.n > y.n or (x.n == y.n and x.f < y.f)
		end)
		print(("\n%d documents, %d s"):format(done, os.time() - t0))
		for _, x in ipairs(rows) do
			print(("  %-14s %4d"):format(x.f, x.n))
		end
		print(p.opts.apply and "forms written"
		    or "dry run; --apply writes dcterms.type")
	end,
}

-- topics: a model picks the general topics of each document. The
-- topics are the tags topic/NAME that have an about page; the page's
-- scope note tells the model what each one covers, and skos.broader
-- places it in the hierarchy. The most specific picks become
-- topic/NAME tags; a search for a broader topic finds them too.

-- topiclist(d) -> the topics: { names, label, scope, children, tops },
-- read from the about pages of topic/ tags and their skos.broader
local function topiclist(d)
	local topics = require "cairn.topics"
	local v = { names = {}, label = {}, scope = {}, children = {},
	    tops = {} }
	local up = {}

	for _, r in ipairs(d:rows("SELECT id, about, title FROM doc WHERE about "
	    .. "LIKE 'topic/%' AND hidden = 0 AND superseded_by IS NULL "
	    .. "ORDER BY about")) do
		local name = r.about:sub(#topics.PREFIX + 1)

		v.names[#v.names + 1] = name
		v.label[name] = r.title
		v.scope[name] = d:row("SELECT value FROM meta WHERE doc = ? AND "
		    .. "key = ? ORDER BY seq LIMIT 1", { r.id, topics.SCOPE }) or ""
		up[name] = {}
		for _, b in ipairs(d:rows("SELECT value FROM meta WHERE doc = ? AND "
		    .. "key = ? ORDER BY seq", { r.id, topics.BROADER })) do
			up[name][#up[name] + 1] = b.value:sub(#topics.PREFIX + 1)
		end
	end
	v.up = up
	for _, name in ipairs(v.names) do
		local known = 0

		for _, b in ipairs(up[name]) do
			if v.label[b] then
				known = known + 1
				v.children[b] = v.children[b] or {}
				v.children[b][#v.children[b] + 1] = name
			end
		end
		if known == 0 then
			v.tops[#v.tops + 1] = name
		end
	end
	if #v.names == 0 then
		error("no topics: run cairn topics seed, or write an about page "
		    .. "with cairn put --about topic/NAME", 0)
	end
	return v
end

-- topicnow(w) -> the topics a version holds, sorted, joined by commas
local function topicnow(w)
	local out = {}

	for _, t in ipairs(w.tags) do
		out[#out + 1] = t:match("^topic/(.+)$")
	end
	table.sort(out)
	return table.concat(out, ",")
end

-- topicvocab(v) -> a hash of the topics, their scope notes and broader
-- topics
local function topicvocab(v)
	local s = {}

	for _, n in ipairs(v.names) do
		local up = { table.unpack(v.up[n]) }

		table.sort(up)
		s[#s + 1] = ("%s\t%s\t%s"):format(n, v.scope[n], table.concat(up, " "))
	end
	table.sort(s)
	return receipt.hash(table.concat(s, "\n"))
end

-- tagsof(d, id) -> the tags of a document with aliases resolved
local function tagsof(d, id)
	local out = {}

	for _, r in ipairs(d:rows("SELECT DISTINCT coalesce(a.name, t.name) AS "
	    .. "name FROM tag t LEFT JOIN tag_alias a ON a.alias = t.name "
	    .. "WHERE t.doc = ? ORDER BY 1", { id })) do
		out[#out + 1] = r.name
	end
	return out
end

local function topicstate(d, id)
	local store = require "cairn.store"
	local w = store.current(d, id)
	local chunks = {}

	for _, e in ipairs(w.content and store.text(d, w.content) or {}) do
		for _, c in ipairs(e.chunks) do
			chunks[#chunks + 1] = c
		end
	end

	local own = {}

	for _, t in ipairs(tagsof(d, id)) do
		if not t:match("^topic/") then
			own[#own + 1] = t
		end
	end

	local head = { "Title: " .. w.title }

	if #own > 0 then
		head[#head + 1] = "Tags: " .. table.concat(own, ", ")
	end

	-- the topics of close documents keep answers consistent
	for _, r in ipairs(d:rows("SELECT s.other, d.title FROM similar s "
	    .. "JOIN doc d ON d.id = s.other WHERE s.doc = ? AND s.score >= 0.7 "
	    .. "ORDER BY s.score DESC LIMIT 3", { id })) do
		local ts = {}

		for _, t in ipairs(tagsof(d, r.other)) do
			ts[#ts + 1] = t:match("^topic/(.+)")
		end
		if #ts > 0 then
			head[#head + 1] = ("A similar document, %s, has the topics: %s")
			    :format(r.title, table.concat(ts, ", "))
		end
	end

	local body = sample(chunks, 1, M.TEXT)

	if w.body and w.body ~= "" then
		body = require("cairn.chunk").utf8(w.body:sub(1, M.TEXT))
	end
	return require("cairn.chunk").utf8(table.concat(head, "\n")
	    .. "\n\nStart of the document:\n" .. body), w
end

M.PICK = "Pick a topic only when a reader who studies that topic would "
    .. "want this document. Use each topic as its note defines it, not as "
    .. "its name sounds. Do not pick a topic for a side fact, such as the "
    .. "language a program is written in. Fewer topics are better than "
    .. "weak ones."

M.SUBJECTS = "In subjects, name 1 to 3 topics of this document in your "
    .. "own words, whether or not the list holds them. Make each as broad "
    .. "as the topics in the list: one or two lowercase words joined by a "
    .. "hyphen, not what this one document covers, and not a product or "
    .. "project."

-- pick(c, model, v, cand, state, o) -> list of topics from cand, list
-- of suggested topics not in the vocabulary; or nil, error. o: min,
-- max, subjects (ask for own words), above (the broader topics already
-- chosen).
local function pick(c, model, v, cand, state, o)
	local client = require("cairn.lgml").available()
	local ok_ = {}
	local lines = {}

	for _, t in ipairs(cand) do
		ok_[t] = true
		lines[#lines + 1] = ("- %s (%s): %s"):format(t, v.label[t], v.scope[t])
	end

	local props = { topics = { type = "array", minItems = o.min,
	    maxItems = o.max, items = { type = "string",
	    enum = client.array(cand) } } }
	local req = { "topics" }
	local ask = {}

	if o.subjects then
		props.subjects = { type = "array", minItems = 1, maxItems = 3,
		    items = { type = "string", pattern = "^[a-z]+(-[a-z]+)?$" } }
		req = { "subjects", "topics" }
		ask[#ask + 1] = M.SUBJECTS
	end
	if o.above then
		local ab = {}

		for _, t in ipairs(o.above) do
			ab[#ab + 1] = ("%s (%s)"):format(t, v.label[t])
		end
		-- the first step down from a top topic must go somewhere; below
		-- that, a narrower topic has to earn its place
		ask[#ask + 1] = ("This document is about %s. The list holds the "
		    .. "narrower topics under those. In topics, pick up to %d that "
		    .. "fit the document. %s"):format(table.concat(ab, ", "), o.max,
		    o.min > 0 and "Pick at least one." or "Pick a narrower topic "
		    .. "only when it is a main subject of the document; pick none "
		    .. "when the broader topics already say it.")
	else
		ask[#ask + 1] = ("In topics, pick %d to %d from the list.")
		    :format(o.min, o.max)
	end
	ask[#ask + 1] = M.PICK

	local schema = { type = "object", additionalProperties = false,
	    required = client.array(req), properties = props }
	local err

	for _ = 1, 2 do
		local r, e = c:call("POST", "/v1/chat/completions", {
			model = model,
			max_tokens = 200,
			temperature = 0,
			chat_template_kwargs = { enable_thinking = false },
			response_format = { type = "json_schema",
			    json_schema = { name = "topics", schema = schema } },
			messages = { {
				role = "user",
				-- the document comes first, so the calls for one document
				-- share a prefix that lgml can reuse
				content = ("%s\n\nThis is a list of topics, each with a note "
				    .. "on what it covers:\n%s\n\n%s"):format(state,
				    table.concat(lines, "\n"), table.concat(ask, "\n\n")),
			} },
		})
		local text = r and r.choices and r.choices[1]
		    and r.choices[1].message and r.choices[1].message.content
		local ok, a = pcall(client.json.decode, text or "")

		if ok and type(a) == "table" and type(a.topics) == "table" then
			local out, seen = {}, {}

			for _, t in ipairs(a.topics) do
				if ok_[t] and not seen[t] and #out < o.max then
					seen[t] = true
					out[#out + 1] = t
				end
			end

			local sug = {}

			-- own words the vocabulary holds, also as a plural, are no news
			for _, t in ipairs(type(a.subjects) == "table" and a.subjects
			    or {}) do
				if type(t) == "string" and not v.label[t]
				    and not v.label[(t:gsub("s$", ""))] then
					sug[#sug + 1] = t
				end
			end
			if #out >= o.min then
				return out, sug
			end
		end
		err = e and (e.kind .. " " .. (e.message or "")) or "bad reply"
	end
	return nil, err
end

-- deepest levels the classifier walks below the top topics
M.DEPTH = 5

-- classify(c, model, v, state) -> the most specific topics chosen,
-- every topic chosen, suggestions; or nil, error. It picks top topics,
-- then walks down: at each level it offers the topics under the ones
-- just chosen.
local function classify(c, model, v, state)
	local got, sug = pick(c, model, v, v.tops, state, { min = 1, max = 3,
	    subjects = true })

	if not got then
		return nil, sug
	end

	local chosen, order, frontier = {}, {}, got

	for _, t in ipairs(got) do
		chosen[t] = true
		order[#order + 1] = t
	end
	for level = 1, M.DEPTH do
		local cand, seen = {}, {}

		for _, f in ipairs(frontier) do
			for _, ch in ipairs(v.children[f] or {}) do
				if not chosen[ch] and not seen[ch] then
					seen[ch] = true
					cand[#cand + 1] = ch
				end
			end
		end
		if #cand == 0 then
			break
		end

		-- no document is only about a top topic, so the first step down
		-- must pick one
		local more = pick(c, model, v, cand, state, { min = level == 1
		    and 1 or 0, max = 4, above = frontier })

		if not more or #more == 0 then
			break
		end
		for _, t in ipairs(more) do
			chosen[t] = true
			order[#order + 1] = t
		end
		frontier = more
	end

	-- a chosen topic with a chosen topic under it is not a leaf, and a
	-- bare top topic says little next to deeper ones
	local leaves, deep, istop = {}, false, {}

	for _, t in ipairs(v.tops) do
		istop[t] = true
	end
	for _, t in ipairs(order) do
		deep = deep or not istop[t]
	end
	for _, t in ipairs(order) do
		local inner = false

		for _, ch in ipairs(v.children[t] or {}) do
			inner = inner or chosen[ch] == true
		end
		if not inner and not (deep and istop[t]) then
			leaves[#leaves + 1] = t
		end
	end
	return M.cap(v, leaves, istop), order, sug
end

-- most topics a document gets
M.TOPICS = 6

-- cap(v, leaves, istop) -> at most TOPICS leaves. Leaves that share a
-- broader topic below the top give way to it, the largest group first;
-- then the first ones picked stay.
function M.cap(v, leaves, istop)
	local up = {}

	for p, chs in pairs(v.children) do
		for _, ch in ipairs(chs) do
			up[ch] = up[ch] or {}
			up[ch][#up[ch] + 1] = p
		end
	end
	while #leaves > M.TOPICS do
		local groups = {}

		for _, l in ipairs(leaves) do
			for _, p in ipairs(up[l] or {}) do
				if not istop[p] then
					groups[p] = (groups[p] or 0) + 1
				end
			end
		end

		local best, n = nil, 1

		for p, k in pairs(groups) do
			if k > n or (k == n and best and p < best) then
				best, n = p, k
			end
		end
		if not best then
			break
		end

		local out, put = {}, false

		for _, l in ipairs(leaves) do
			local under = false

			for _, p in ipairs(up[l] or {}) do
				under = under or p == best
			end
			if not under then
				out[#out + 1] = l
			elseif not put then
				out[#out + 1] = best
				put = true
			end
		end
		leaves = out
	end
	while #leaves > M.TOPICS do
		table.remove(leaves)
	end
	return leaves
end

M.list.topics = {
	usage = "topics [ID... | --stale | --all] [--tag t] [--apply] [--adopt]",
	desc = "pick general topics from the topic/ about pages, walking down "
	    .. "from the top topics; without IDs only new and changed "
	    .. "documents; --apply writes the most specific topics as tags",
	run = function(p, d)
		local lgml = require "cairn.lgml"
		local store = require "cairn.store"
		local model = p.opts.model or config.get(d, "lgml.decide")
		local v = topiclist(d)
		local vocab = topicvocab(v)

		if p.opts.adopt then
			print(("%d receipts written"):format(adopt(d, "topics", model,
			    vocab, topicnow, function()
				return true
			end)))
			return
		end

		local ids = plan(p, d, "topics", model, vocab, topicnow)
		local c = lgml.client(d, { timeout = 600 })

		local count, wish, done, t0 = {}, {}, 0, os.time()

		for _, id in ipairs(ids) do
			local state, w = topicstate(d, id)
			local leaves, all, sug = classify(c, model, v, state)

			if not leaves then
				print(("%s  error: %s"):format(id, all))
			else
				done = done + 1
				for _, t in ipairs(all) do
					count[t] = (count[t] or 0) + 1
				end
				for _, t in ipairs(sug) do
					wish[t] = (wish[t] or 0) + 1
				end
				print(("%s  %-50s  %s%s"):format(id,
				    require("cairn.chunk").utf8(w.title:sub(1, 50)),
				    table.concat(leaves, " "), #sug > 0
				    and ("  (suggests " .. table.concat(sug, " ") .. ")")
				    or ""))
				if p.opts.apply then
					local wrote = { table.unpack(leaves) }

					table.sort(wrote)
					stamp(d, "topics", id, model, vocab, table.concat(wrote,
					    ","), function(nw)
						local set, keep = {}, {}

						for _, t in ipairs(nw.tags) do
							t = store.resolve_tag(d, t)
							-- a new answer replaces old topics
							if not t:match("^topic/") then
								set[t] = true
							end
						end
						for _, t in ipairs(leaves) do
							set["topic/" .. t] = true
						end
						for t in pairs(set) do
							keep[#keep + 1] = t
						end
						table.sort(keep)
						nw.tags = keep
					end)
				end
			end
		end
		c:close()

		-- how often each topic was chosen at any level; top topics on
		-- most documents, or narrow ones on one, may need a better note
		local rows = {}

		for t, n in pairs(count) do
			rows[#rows + 1] = { t = t, n = n }
		end
		table.sort(rows, function(a, b)
			return a.n > b.n or (a.n == b.n and a.t < b.t)
		end)
		print(("\n%d documents, %d s; topics chosen at any level:")
		    :format(done, os.time() - t0))
		for _, x in ipairs(rows) do
			print(("  %-30s %4d  %3d%%"):format(x.t, x.n,
			    done > 0 and x.n * 100 // done or 0))
		end

		-- suggestions are never written; a good one becomes a topic when
		-- someone writes its about page. Own words vary, so on a big run
		-- only repeated ones mean a gap.
		local ws = {}

		for t, n in pairs(wish) do
			if done < 10 or n >= 2 then
				ws[#ws + 1] = { t = t, n = n }
			end
		end
		table.sort(ws, function(a, b)
			return a.n > b.n or (a.n == b.n and a.t < b.t)
		end)
		if #ws > 0 then
			print("\nsuggested topics that have no about page:")
			for _, x in ipairs(ws) do
				print(("  %-30s %4d"):format(x.t, x.n))
			end
		end
		print(p.opts.apply and "topic tags written"
		    or "dry run; --apply writes topic/NAME tags")
	end,
}

-- summarize: a model writes a short abstract (dcterms.abstract) from
-- the start and the middle of a document. The receipt records a hash
-- of the abstract, so an abstract a person edits is left alone.

M.SUMMARY = "Summarize this document in 2 plain sentences for someone "
    .. "deciding whether to read it: what it covers and what it tells "
    .. "that the title does not, such as the problem, the method, the "
    .. "scope, or the main parts. Name specifics. Do not start with "
    .. "\"This document\", do not address the reader, no praise, no "
    .. "markdown, and do not mention the title or this request."

local function abstractnow(w)
	local a = w.meta["dcterms.abstract"]

	return type(a) == "string" and receipt.hash(a) or ""
end

local function summarystate(d, w)
	local store = require "cairn.store"
	local chunks = {}

	for _, e in ipairs(w.content and store.text(d, w.content) or {}) do
		for _, c in ipairs(e.chunks) do
			chunks[#chunks + 1] = c
		end
	end

	local s = ("Title: %s\n\nStart:\n%s"):format(w.title,
	    sample(chunks, 1, 4000))

	if #chunks > 4 then
		s = s .. "\n\nFrom the middle:\n" .. sample(chunks, #chunks // 2,
		    2000)
	end
	return require("cairn.chunk").utf8(s)
end

M.list.summarize = {
	usage = "summarize [ID... | --stale | --all] [--tag t] [--apply]",
	desc = "write a 2-sentence abstract (dcterms.abstract) of each "
	    .. "document; search shows its first sentence under a hit",
	run = function(p, d)
		local lgml = require "cairn.lgml"
		local store = require "cairn.store"
		local model = p.opts.model or config.get(d, "lgml.decide")
		local vocab = receipt.hash(M.SUMMARY)
		local ids = plan(p, d, "abstract", model, vocab, abstractnow)
		local c = lgml.client(d, { timeout = 600 })
		local done, t0 = 0, os.time()

		for _, id in ipairs(ids) do
			local w = store.current(d, id)
			local text = lgml.chat(c, {
				model = model,
				max_tokens = 200,
				temperature = 0,
				chat_template_kwargs = { enable_thinking = false },
				messages = { { role = "user", content = summarystate(d, w)
				    .. "\n\n" .. M.SUMMARY } },
			})

			text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
			done = done + 1
			print(("%s  %s\n    %s"):format(id, w.title, text))
			if p.opts.apply then
				stamp(d, "abstract", id, model, vocab, receipt.hash(text),
				    function(nw)
					nw.meta["dcterms.abstract"] = text
				end)
			end
		end
		c:close()
		print(("\n%d documents, %d s; %s"):format(done, os.time() - t0,
		    p.opts.apply and "abstracts written"
		    or "dry run; --apply writes dcterms.abstract"))
	end,
}

-- restamp: move receipts written before text hashes to the new content
-- key, where the text has not changed since; one version a document
M.list.restamp = {
	usage = "restamp",
	desc = "move old receipts to text-hash content keys, where nothing "
	    .. "changed since",
	run = function(_, d)
		local store = require "cairn.store"
		local n = 0

		for _, row in ipairs(d:rows("SELECT id FROM doc WHERE hidden = 0 "
		    .. "AND superseded_by IS NULL AND about IS NULL")) do
			local w = store.current(d, row.id)
			local old = receipt.legacy(d, w.content)
			local new = receipt.content(d, w.content)
			local todo = {}

			for _, name in ipairs({ "form", "topics", "abstract" }) do
				local r = receipt.parse(w.meta[receipt.key(name)])

				if r and r.content == old then
					r.content = new
					todo[receipt.key(name)] = receipt.format(r)
				end
			end
			if next(todo) then
				store.update(d, row.id, nil, "cairn:update", function(nw)
					for k, v in pairs(todo) do
						nw.meta[k] = v
					end
				end)
				n = n + 1
			end
		end
		print(("%d documents restamped"):format(n))
	end,
}

-- the classifiers update runs, in order
M.UPDATE = { "form", "topics", "summarize" }

M.list.update = {
	usage = "update [--apply] [--stale] [--tag t]",
	desc = "run form, topics, and summarize on new and changed documents, "
	    .. "then similar; a dry run prints what they would write",
	run = function(p, d, path)
		-- collect every classifier's changes, then write each document
		-- once, so a run adds one version a document, not one a classifier
		if p.opts.apply then
			batch = { edits = {}, order = {} }
		end
		for _, name in ipairs(M.UPDATE) do
			print("== " .. name)

			-- one classifier failing, such as topics with no topic list,
			-- does not stop the others
			local ok, err = pcall(M.list[name].run, { args = {},
			    opts = p.opts }, d, path)

			if not ok then
				print(("%s: %s"):format(name, tostring(err)))
			end
		end
		if p.opts.apply then
			print(("%d documents written"):format(flush(d)))
		end
		print("== similar")
		if p.opts.apply then
			M.list.similar.run({ args = {}, opts = {} }, d, path)
		else
			print("similar writes vectors; it runs with --apply")
		end
	end,
}

M.list.status = {
	usage = "status",
	desc = "count documents by receipt state for form, topics, and "
	    .. "abstract: new, changed, old, model, vocab, current, and edited",
	run = function(p, d)
		local model = p.opts.model or config.get(d, "lgml.decide")
		local q = { args = {}, opts = {} }
		local _, fc = plan(q, d, "form", model, formvocab(), formnow,
		    { note = true })
		local okv, v = pcall(topiclist, d)
		local tc = okv and select(2, plan(q, d, "topics", model,
		    topicvocab(v), topicnow)) or {}
		local _, ac = plan(q, d, "abstract", model,
		    receipt.hash(M.SUMMARY), abstractnow)
		local states = { "new", "changed", "old", "model", "vocab",
		    "current", "edited" }

		print(("%-8s %s"):format("", table.concat(states, "  ")))
		for _, x in ipairs({ { "form", fc }, { "topics", tc },
		    { "abstract", ac } }) do
			local row = {}

			for i, s in ipairs(states) do
				row[i] = ("%" .. #s .. "d"):format(x[2][s] or 0)
			end
			print(("%-8s %s"):format(x[1], table.concat(row, "  ")))
		end
		print("a plain run takes new and changed; --stale adds old, model, "
		    .. "and vocab; edited is never rerun unless named")
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
