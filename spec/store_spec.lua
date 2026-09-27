-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local cid = require "cairn.cid"
local db = require "cairn.db"
local drisl = require "cairn.drisl"
local search = require "cairn.search"
local store = require "cairn.store"

describe("store", function()
	local d

	before_each(function()
		d = assert(db.open(":memory:"))
	end)

	after_each(function()
		d:close()
	end)

	local function note(title, body, tags, extra)
		local n = { title = title, body = body, tags = tags,
		    author = "kbd" }

		for k, v in pairs(extra or {}) do
			n[k] = v
		end
		return store.note(d, n)
	end

	it("writes a note with a DRISL version node", function()
		local id, rev, c = note("Wiring the STM32", "# pins\nPA9 is TX",
		    { "STM32", "hw/uart" })

		assert.equal(1, rev)
		assert.equal(16, #id)

		local data, codec = d:get(c)

		assert.equal(cid.DAG_CBOR, codec)

		local node = assert(drisl.decode(data))

		assert.equal("cairn/doc", node.type)
		assert.equal(id, node.doc)
		assert.equal(drisl.null, node.prev)
		assert.same({ "hw/uart", "stm32" }, { node.tags[1], node.tags[2] })
		assert.is_not_nil(drisl.islink(node.content))
		assert.equal("kbd", node.author)
	end)

	it("finds a note by body and by title", function()
		local id = note("Wiring", "the uart runs at 115200 baud", { "hw" })
		local hits = search.search(d, "baud")

		assert.equal(1, #hits)
		assert.equal(id, hits[1].id)
		assert.matches("%[baud%]", hits[1].snippet)
		assert.equal(id, search.search(d, "wir")[1].id)
	end)

	it("finds part words by scanning when the index has none", function()
		local id = note("queues", "each virtqueue has a Descriptor table")
		local hits = search.search(d, "irtqueu")

		assert.equal(1, #hits)
		assert.equal(id, hits[1].id)
		assert.equal("each v[irtqueu]e has a Descriptor table", hits[1].snippet)
		assert.equal(0, #search.search(d, "irtqueu tag:none"))
	end)

	it("filters by tag prefix on a / boundary", function()
		local a = note("a", "alpha", { "hw/stm32" })

		note("b", "alpha", { "hwmon" })

		local hits = search.search(d, "alpha tag:hw")

		assert.equal(1, #hits)
		assert.equal(a, hits[1].id)
	end)

	it("resolves tag aliases on write and read", function()
		d:run("INSERT INTO tag_alias (alias, name) VALUES ('sqlite3', 'sqlite')")

		local id = note("wal", "checkpoint", { "sqlite3" })

		assert.equal("sqlite", d:row("SELECT name FROM tag WHERE doc = ?",
		    { id }))
		assert.equal(id, search.search(d, "tag:sqlite3")[1].id)
	end)

	it("moves the head and refuses a stale rev", function()
		local id = note("t", "one")
		local w = store.current(d, id)
		local _, rev2 = note("t", "two", nil, { id = id, rev = 1, base = w })

		assert.equal(2, rev2)

		local ok, err = pcall(note, "t", "three", nil,
		    { id = id, rev = 1, base = w })

		assert.is_false(ok)
		assert.is_true(store.isconflict(err))
		assert.equal(2, err.rev)

		local node = store.node(d, store.doc(d, id).head)

		assert.is_not_nil(drisl.islink(node.prev))
		assert.equal(0, #search.search(d, "one"))
		assert.equal(1, #search.search(d, "two"))
	end)

	it("links notes, walks them, and hides superseded ones", function()
		local a = note("Old way", "use cron")
		local b = note("New way", "use a timer, see [[Old way]]")

		assert.equal("see-also", d:row("SELECT rel FROM link WHERE src = ?",
		    { b }))

		local c = note("Newest", "timer units", nil,
		    { links = { { rel = "supersedes", doc = a } } })

		assert.equal(c, store.doc(d, a).superseded_by)
		assert.equal(0, #search.search(d, "cron"))
		assert.equal(1, #search.search(d, "cron", { superseded = true }))

		local rel = search.related(d, a, 2)

		assert.equal(2, #rel)
	end)

	it("keeps one about page per tag", function()
		local a = note("stm32 overview", "chips", { "stm32" },
		    { about = "stm32" })

		assert.has_error(function()
			note("another", "x", nil, { about = "stm32" })
		end)
		note("new overview", "x", { "stm32" },
		    { about = "stm32", links = { { rel = "supersedes", doc = a } } })

		local t = search.tags(d)

		assert.equal("stm32", t[1].name)
	end)

	it("refuses secrets", function()
		assert.has_error(function()
			note("keys", "token = ghp_abcdefghijklmnopqrstuvwxyz0123456789")
		end)
		assert.has_error(function()
			note("k", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc")
		end)
		assert.equal(0, d:row("SELECT count(*) FROM doc"))
	end)

	it("attaches a pdf and queues extraction", function()
		local id, _, fc, kinds = store.attach(d, { data = "%PDF-1.4 fake",
		    name = "sheet.pdf", author = "kbd", tags = { "datasheet" } })

		assert.same({ "pdf" }, kinds)
		assert.equal("application/pdf", store.doc(d, id).mime)
		assert.equal(cid.sha256(cid.RAW, "%PDF-1.4 fake"), fc)

		local hits = search.search(d, "sheet")

		assert.equal(1, #hits)
		assert.is_true(hits[1].pending)
	end)

	it("dedupes files and suggests near duplicates", function()
		note("uart baud rate", "115200")

		local _, _, _, dups = note("uart baud", "115200")

		assert.equal(1, #dups)
		assert.equal(1, d:row("SELECT count(*) FROM file"))
	end)

	it("suggests close tags", function()
		note("a", "x", { "datasheet" })

		local _, _, _, _, close = note("b", "y", { "datasheets" })

		assert.same({ "datasheet" }, close)
	end)
end)

describe("search chunks", function()
	it("returns the best few passages of each document", function()
		local d = assert(db.open(":memory:"))
		local body = {}

		for i = 1, 5 do
			body[#body + 1] = "# part " .. i .. "\nvirtqueue text " .. i
		end
		store.note(d, { title = "spec", body = table.concat(body, "\n"),
		    author = "kbd" })

		local h = search.search(d, "virtqueue")[1]

		assert.equal(3, #h.chunks)
		assert.equal(5, #search.search(d, "virtqueue", { chunks = 9 })[1].chunks)
		assert.equal(1, #search.search(d, "virtqueue", { chunks = 1 })[1].chunks)
		d:close()
	end)
end)
