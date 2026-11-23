-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local db = require "cairn.db"
local store = require "cairn.store"
local web = require "cairn.web"

describe("web", function()
	local d

	before_each(function()
		d = assert(db.open(":memory:"))
	end)

	after_each(function()
		d:close()
	end)

	local function get(path, query, extra)
		local req = { method = "GET", path = path, query = query or {} }

		for k, v in pairs(extra or {}) do
			req[k] = v
		end
		return web.handle(d, req)
	end

	local function note(title, body, tags)
		return store.note(d, { title = title, body = body, author = "kbd",
		    tags = tags })
	end

	it("lists recent documents on the front page", function()
		local id = note("First <note>", "body")
		local status, h, body = get("/")

		assert.equal(200, status)
		assert.equal("text/html; charset=utf-8", h["Content-Type"])
		assert.truthy(h["Content-Security-Policy"]:find("default-src 'none'",
		    1, true))
		assert.truthy(body:find('<a href="/d/' .. id
		    .. '">First &lt;note&gt;</a>', 1, true))
	end)

	it("lists a document once, at its newest version", function()
		local id = note("Doc", "first")
		local w = store.current(d, id)

		store.note(d, { id = id, rev = w.rev, base = w, title = "Doc",
		    body = "second", author = "kbd" })

		local rows = web.recent(d, 10)

		assert.equal(1, #rows)
		assert.equal(2, rows[1].rev)
	end)

	it("renders a note and resolves its links", function()
		local a = note("Target", "target text")
		local b = note("Source", "# Head\n\nsee [[Target]] and [[Nowhere]]"
		    .. "\n\n<script>alert(1)</script>", { "plan9" })
		local status, _, body = get("/d/" .. b)

		assert.equal(200, status)
		assert.truthy(body:find('<h1 id="head">Head</h1>', 1, true))
		assert.truthy(body:find('<a class="wiki" href="/d/' .. a
		    .. '">Target</a>', 1, true))
		assert.truthy(body:find('<span class="wanted">Nowhere</span>', 1,
		    true))
		assert.truthy(body:find('href="/search?q=tag%3Aplan9"', 1, true))
		assert.falsy(body:find("<script>", 1, true))
	end)

	it("shows the source of a note", function()
		local id = note("Source", "see [[Target]]")
		local _, _, body = get("/d/" .. id, { view = "source" })

		assert.truthy(body:find('<pre class="text">see [[Target]]</pre>', 1,
		    true))
	end)

	it("shows an old version", function()
		local id = note("Doc", "first text")
		local w = store.current(d, id)

		store.note(d, { id = id, rev = w.rev, base = w, title = "Doc",
		    body = "second text", author = "kbd" })

		local _, _, cur = get("/d/" .. id)
		local _, _, old = get("/d/" .. id .. "@1")

		assert.truthy(cur:find("second text", 1, true))
		assert.truthy(old:find("first text", 1, true))
		assert.truthy(old:find("current is rev 2", 1, true))
	end)

	it("redirects a title to the document", function()
		local id = note("Some title", "body")
		local status, h = get("/d/Some title")

		assert.equal(302, status)
		assert.equal("/d/" .. id, h.Location)
	end)

	it("answers 404 for a document that is absent", function()
		assert.equal(404, (get("/d/aaaaaaaaaaaaaaaa")))
		assert.equal(404, (get("/raw/aaaaaaaaaaaaaaaa")))
		assert.equal(404, (get("/nope")))
	end)

	it("finds documents", function()
		local id = note("Scheduler notes", "the run queue holds procs")
		local status, _, body = get("/search", { q = "queue" })

		assert.equal(200, status)
		assert.truthy(body:find('href="/d/' .. id .. '"', 1, true))
		assert.truthy(body:find("<mark>queue</mark>", 1, true))
		assert.truthy(body:find("1 to 1 of 1", 1, true))
	end)

	it("lists tags and wanted titles", function()
		note("A", "see [[Not written]]", { "hw/stm32" })

		local _, _, tags = get("/tags")
		local _, _, wanted = get("/wanted")

		assert.truthy(tags:find('<li class="d1"><a href="/search?q='
		    .. 'tag%3Ahw/stm32">hw/stm32</a>', 1, true))
		assert.truthy(wanted:find('<span class="wanted">Not written</span>',
		    1, true))
	end)

	it("serves stored HTML as plain text", function()
		local id = store.attach(d, { data = "<script>alert(1)</script>",
		    name = "x.html", mime = "text/html", title = "Page",
		    author = "kbd" })
		local status, h, body = get("/raw/" .. id)

		assert.equal(200, status)
		assert.equal("text/plain; charset=utf-8", h["Content-Type"])
		assert.equal("nosniff", h["X-Content-Type-Options"])
		assert.equal("<script>alert(1)</script>", body)
	end)

	it("serves a PDF in place and honors If-None-Match", function()
		local id = store.attach(d, { data = "%PDF-1.4 x", name = "a b.pdf",
		    title = "Paper", author = "kbd" })
		local status, h, body = get("/raw/" .. id)

		assert.equal(200, status)
		assert.equal("application/pdf", h["Content-Type"])
		assert.equal('inline; filename="a b.pdf"', h["Content-Disposition"])
		assert.equal("%PDF-1.4 x", body)
		assert.equal(304, (get("/raw/" .. id, nil, { inm = h.ETag })))

		local _, _, page = get("/d/" .. id, { at = "p=3" })

		assert.truthy(page:find('src="/raw/' .. id .. '#page=3"', 1, true))
	end)

	it("sends unknown types as a download", function()
		assert.same({ "application/octet-stream", "attachment" },
		    { web.rawtype("application/x-thing") })
		assert.same({ "image/png", "inline" }, { web.rawtype("image/png") })
	end)

	it("refuses writes and foreign hosts", function()
		assert.equal(405, (web.handle(d, { method = "POST", path = "/" })))
		assert.equal(403, (web.handle(d, { method = "GET", path = "/",
		    host = "evil.example" },
		    { hosts = { ["127.0.0.1:8377"] = true } })))
		assert.equal(200, (web.handle(d, { method = "GET", path = "/",
		    host = "127.0.0.1:8377" },
		    { hosts = { ["127.0.0.1:8377"] = true } })))
	end)

	it("reads listen addresses", function()
		assert.same({ "127.0.0.1", 8377 }, { web.address("127.0.0.1:8377") })
		assert.same({ "::1", 80 }, { web.address("[::1]:80") })
		assert.same({ "127.0.0.1", 9000 }, { web.address("9000") })
		assert.is_nil((web.address("nonsense")))
	end)
end)
