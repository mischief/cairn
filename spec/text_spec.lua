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

describe("abstract in search", function()
	it("shows the first sentence of dcterms.abstract", function()
		local search = require "cairn.search"
		local d = assert(db.open(":memory:"))

		store.note(d, { title = "venti", body = "archival blocks by hash",
		    author = "k", meta = { ["dcterms.abstract"] = "Write-once "
		    .. "storage named by hash. It dedups blocks." } })
		assert.equal("Write-once storage named by hash.",
		    search.search(d, "archival")[1].abstract)
		d:close()
	end)
end)

describe("classifier authors", function()
	it("keep the writer as the author and stay out of recent", function()
		local search = require "cairn.search"
		local d = assert(db.open(":memory:"))
		local id = store.note(d, { title = "venti", body = "archival blocks",
		    author = "kbd" })

		store.update(d, id, nil, "cairn:topics", function(w)
			w.title = "venti2"
		end)
		assert.equal("kbd", search.search(d, "archival")[1].author)
		assert.equal(1, #search.search(d, "archival author:kbd"))
		assert.equal(1, #search.recent(d))
		assert.equal(1, #search.recent(d, nil, "cairn:topics"))
		d:close()
	end)
end)

describe("pandoc", function()
	it("keeps headings and link text from HTML", function()
		if not require("cairn.util").which("pandoc") then
			return
		end

		local html = [[<h1>API</h1><h2 id="f">new_state</h2>
<p>Call <a href="#g"><code>free_state</code></a> after <b>use</b>.</p>
<img src="logo.png" alt="logo"><div><span>end</span></div>]]
		local ch = extract.pandoc(html, "text/html")

		assert.equal("API > new_state", ch[1].heading)
		assert.matches("Call `free_state` after %*%*use%*%*%.", ch[1].body)
		assert.is_nil(ch[1].body:find("logo", 1, true))
		assert.is_nil(ch[1].body:find("#g", 1, true))
	end)
end)

describe("abstract index", function()
	it("finds a document by a word only its abstract holds", function()
		local search = require "cairn.search"
		local derive = require "cairn.derive"
		local d = assert(db.open(":memory:"))
		local id = store.note(d, { title = "venti", body = "archival blocks",
		    author = "k", meta = { ["dcterms.abstract"] = "Write-once "
		    .. "storage with deduplication." } })

		assert.equal(id, search.search(d, "deduplication")[1].id)
		assert.same({}, derive.check(d))
		d:close()
	end)
end)

describe("plain text with form feeds", function()
	it("keeps pages and drops running heads", function()
		local d = assert(db.open(":memory:"))
		local pages = {}

		for i, w in ipairs({ "alpha", "bravo", "charlie", "delta", "echo" }) do
			pages[i] = ("RFC 9999   Example   July 2026\n\n%s section\n\n"
			    .. "Author   Standards Track   [Page %d]"):format(w, i)
		end

		local id = store.attach(d, { data = table.concat(pages, "\f"),
		    name = "rfc9999.txt", mime = "text/plain", author = "k" })
		local text = require("cairn.cli").view(d, id, nil, nil, "p=3").text

		assert.matches("charlie section", text)
		assert.is_nil(text:find("Standards Track", 1, true))
		d:close()
	end)
end)

describe("markdown headings", function()
	it("leaves skipped levels out of the heading path", function()
		local ch = chunk.markdown("# walk(5)\n\n### NAME\n\nwalk - descend\n")

		assert.equal("walk(5) > NAME", ch[1].heading)
	end)
end)

describe("get of a note", function()
	it("shows headings and keeps the indent of a code line", function()
		local cli = require "cairn.cli"
		local d = assert(db.open(":memory:"))
		local id = store.note(d, { title = "guide", author = "k",
		    body = "# Using it\n\nintro\n\n## Health\n\n    cairn status\n"
		    .. "    cairn stats\n" })
		local text = cli.view(d, id).text

		assert.matches("# Using it\n\nintro", text)
		assert.matches("## Health\n\n    cairn status\n    cairn stats", text)
		d:close()
	end)

	it("shows a heading whose name ends in >", function()
		local cli = require "cairn.cli"
		local d = assert(db.open(":memory:"))
		local id = store.note(d, { title = "vi", author = "k",
		    body = "# Input\n\n## \\<newline\\>\n\nends a line\n\n"
		    .. "## Notes <!-- todo -->\n\nmore\n" })
		local text = cli.view(d, id).text

		assert.matches("## \\<newline\\>\n\nends a line", text, 1, true)
		assert.matches("## Notes <!-- todo -->\n\nmore", text, 1, true)
		d:close()
	end)
end)
