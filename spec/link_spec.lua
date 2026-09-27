-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local cid = require "cairn.cid"
local db = require "cairn.db"
local store = require "cairn.store"

describe("links", function()
	local d

	before_each(function()
		d = assert(db.open(":memory:"))
	end)

	after_each(function()
		d:close()
	end)

	local function note(title, body, extra)
		local n = { title = title, body = body, author = "kbd" }

		for k, v in pairs(extra or {}) do
			n[k] = v
		end
		return store.note(d, n)
	end

	local function links(id)
		return store.nodelinks(store.node(d, store.doc(d, id).head))
	end

	local function edit(id, body, title)
		local w = store.current(d, id)

		return store.note(d, { id = id, rev = w.rev, base = w,
		    title = title or w.title, body = body, author = "kbd" })
	end

	it("reads ids, CIDs, titles, URIs, revs and fragments", function()
		local a, _, c = note("Spec", "text")

		assert.same({ doc = a, frag = "p=3" },
		    store.ref(d, "cairn:" .. a .. "#p=3"))

		local r = store.ref(d, cid.tostring(c))

		assert.equal(a, r.doc)
		assert.equal(1, r.rev)
		assert.is_true(r.pin)
		assert.equal(a, store.ref(d, "spec@1").doc)
		assert.equal(1, store.ref(d, "Spec@1").rev)
		assert.is_nil(store.ref(d, "nothing"))
		assert.equal("cairn:" .. a .. "@2#p=4", store.uri(a, 2, "p=4"))
	end)

	it("records the target version and marks later changes", function()
		local a, _, ca = note("Spec", "v1")
		local b = note("Notes", "see [[Spec#p=2]] and [[" .. a .. "]]")
		local l = links(b)

		-- a page link and a plain link to one document are two links
		assert.equal(2, #l)
		assert.is_nil(l[1].frag)
		assert.equal("p=2", l[2].frag)
		assert.equal(ca, l[2].at)

		local _, _, ca2 = edit(a, "v2")

		-- an edit of b keeps the version it linked, so the change shows
		edit(b, "see [[Spec#p=2]] again")
		assert.equal(ca, links(b)[1].at)

		-- linking again marks it current
		store.link(d, b, "cairn:" .. a .. "#p=2", "see-also", false, "kbd")

		local found = false

		for _, x in ipairs(links(b)) do
			if x.frag == "p=2" and x.at == ca2 then
				found = true
			end
		end
		assert.is_true(found)
	end)

	it("pins a version with @rev", function()
		local a, _, c1 = note("Spec", "v1")

		edit(a, "v2")

		local b = note("Notes", "old text in [[Spec@1]]")
		local l = links(b)[1]

		assert.is_true(l.pin)
		assert.equal(c1, l.at)
	end)

	it("drops links removed from the body", function()
		note("Spec", "x")

		local b = note("Notes", "[[Spec]]")

		assert.equal(1, #links(b))
		edit(b, "no links now")
		assert.equal(0, #links(b))
	end)

	it("keeps wanted titles and reports when a note fills one", function()
		local b, _, _, _, _, wanted = note("Notes", "see [[Future topic]]")

		assert.same({ "Future topic" }, wanted)

		local _, _, _, _, _, _, fills = note("Future topic", "here")

		assert.same({ b }, fills)
	end)

	it("keeps a title link on its document after a retitle", function()
		local a = note("Old name", "x")
		local b = note("Notes", "[[Old name]]")

		edit(a, "x", "New name")
		note("Old name", "a different document")
		edit(b, "[[Old name]] still")
		assert.equal(a, links(b)[1].doc)
	end)
end)

describe("unindex", function()
	it("drops the chunks of an old note body", function()
		local d = assert(db.open(":memory:"))
		local id = store.note(d, { title = "t", body = "alpha words",
		    author = "kbd" })
		local w = store.current(d, id)

		store.note(d, { id = id, rev = 1, base = w, title = "t",
		    body = "beta words", author = "kbd" })
		assert.equal(1, d:row("SELECT count(*) FROM chunk"))
		assert.equal(0, d:row("SELECT count(*) FROM chunk_fts "
		    .. "WHERE chunk_fts MATCH 'alpha'"))

		-- a file another document still holds keeps its chunks
		local other = store.note(d, { title = "u", body = "beta words",
		    author = "kbd" })

		w = store.current(d, id)
		store.note(d, { id = id, rev = 2, base = w, title = "t",
		    body = "gamma", author = "kbd" })
		assert.equal(1, d:row("SELECT count(*) FROM chunk_fts "
		    .. "WHERE chunk_fts MATCH 'beta'"))
		assert.is_not_nil(other)
		d:close()
	end)
end)
