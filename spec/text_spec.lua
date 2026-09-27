-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local chunk = require "cairn.chunk"
local db = require "cairn.db"
local extract = require "cairn.extract"
local store = require "cairn.store"

describe("page text", function()
	it("drops running heads, feet, and page numbers", function()
		local words = { "alpha", "bravo", "charlie", "delta", "echo", "fox" }
		local pages = {}

		for i, w in ipairs(words) do
			pages[i] = ("ACME Spec Rev 2\n\n%s\n\n%d\n"):format(w, i)
		end

		local out = chunk.running(pages)

		assert.equal("\ncharlie\n\n", out[3])
		assert.same({ "only page" }, chunk.running({ "only page" }))
	end)

	it("keeps a line that repeats away from the page edges", function()
		local pages = {}

		for i = 1, 6 do
			pages[i] = ("a %d\nb\nc\nREG\nd\ne\nf"):format(i)
		end
		assert.equal("REG", chunk.running(pages)[2])
	end)

	it("shortens dot leaders and blank runs", function()
		assert.equal("Scope ... 20\n\nnext", chunk.tidy(
		    "Scope .......... 20   \n\n\n\nnext"))
		assert.equal("a ... 3", chunk.tidy("a . . . . . . 3"))
		assert.equal("f(...)", chunk.tidy("f(...)"))
	end)

	it("tells two columns of prose from a table", function()
		local two, table_ = {}, {}

		for i = 1, 12 do
			two[i] = ("left column prose words go here %02d      "
			    .. "right column prose words go here %02d"):format(i, i)
			table_[i] = ("OPCODE %02d    V/V    AVX512F    Move packed "
			    .. "doubleword    values"):format(i)
		end
		assert.is_true(extract.twocolumn(table.concat(two, "\n")))
		assert.is_false(extract.twocolumn(table.concat(table_, "\n")))
		assert.is_false(extract.twocolumn("short\npage"))
	end)
end)

describe("page ranges", function()
	it("gets a range of PDF pages", function()
		local cli = require "cairn.cli"
		local d = assert(db.open(":memory:"))
		local id = store.attach(d, { data = "%PDF pages", name = "p.pdf",
		    author = "k" })
		local file = store.doc(d, id).content
		local text = {}

		for i, w in ipairs({ "alpha", "bravo", "charlie", "delta", "echo" }) do
			text[i] = "page body " .. w
		end
		store.index(d, file, "pdf", "pdftotext", 1,
		    chunk.pages(table.concat(text, "\f")))

		local v = cli.view(d, id, nil, nil, "p=2-3")

		assert.matches("page body bravo", v.text)
		assert.matches("page body charlie", v.text)
		assert.is_nil(v.text:find("delta", 1, true))
		assert.is_nil(cli.view(d, id, nil, nil, "p=4").text
		    :find("charlie", 1, true))
		d:close()
	end)
end)

describe("scope notes", function()
	it("lists a tag's scope note and a tag with only an about page", function()
		local search = require "cairn.search"
		local d = assert(db.open(":memory:"))

		store.note(d, { title = "Topic: security", body = "threats",
		    author = "k", about = "topic/security",
		    meta = { ["skos.scopeNote"] = "threats and defenses" } })

		local t = search.tags(d, "topic/")

		assert.same({ "topic", "topic/security" }, { t[1].name, t[2].name })
		assert.equal(0, t[2].count)
		assert.equal("threats and defenses", t[2].scope)
		d:close()
	end)
end)

describe("about pages in search", function()
	it("leaves them out unless asked for", function()
		local search = require "cairn.search"
		local d = assert(db.open(":memory:"))
		local page = store.note(d, { title = "Computer security",
		    body = "threats and defenses", author = "k",
		    about = "topic/security" })
		local doc = store.note(d, { title = "Tor", body = "defenses against "
		    .. "traffic analysis", author = "k" })

		local hits = search.search(d, "defenses")

		assert.equal(1, #hits)
		assert.equal(doc, hits[1].id)
		hits = search.search(d, "defenses", { about = true })
		assert.equal(1, #hits)
		assert.equal(page, hits[1].id)
		d:close()
	end)
end)

describe("search depth", function()
	it("ranks a document with the words on many pages first", function()
		local search = require "cairn.search"
		local d = assert(db.open(":memory:"))
		local short = store.attach(d, { data = "%PDF short", name = "s.pdf",
		    author = "k", title = "slides" })
		local long = store.attach(d, { data = "%PDF long", name = "l.pdf",
		    author = "k", title = "manual" })
		local pages = {}

		-- each page its own words, or they read as running heads
		for i, w in ipairs({ "allocator", "seed", "memory", "errors",
		    "threads", "hooks" }) do
			pages[i] = ("zetaframe and the %s: how the %s works with a new "
			    .. "state, and what to check"):format(w, w)
		end
		store.index(d, store.doc(d, short).content, "pdf", "pdftotext", 1,
		    chunk.pages("creating a state: call zetaframe, open the "
		    .. "modules, and close it when done\f"))
		store.index(d, store.doc(d, long).content, "pdf", "pdftotext", 1,
		    chunk.pages(table.concat(pages, "\f")))
		-- other text, so the word is rare as in a real store
		local other = store.attach(d, { data = "%PDF other", name = "o.pdf",
		    author = "k", title = "other" })
		local rest = {}

		for i = 1, 60 do
			rest[i] = ("unrelated page %d about disks and networks"):format(i)
		end
		store.index(d, store.doc(d, other).content, "pdf", "pdftotext", 1,
		    chunk.pages(table.concat(rest, "\f")))
		assert.equal(long, search.search(d, "zetaframe")[1].id)
		d:close()
	end)
end)
