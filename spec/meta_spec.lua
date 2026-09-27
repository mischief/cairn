-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local db = require "cairn.db"
local meta = require "cairn.meta"
local search = require "cairn.search"
local store = require "cairn.store"

describe("meta", function()
	it("reads EDTF dates to their earliest day", function()
		assert.equal("1985", meta.edtf("1985"))
		assert.equal("1985-12", meta.edtf("1985-12"))
		assert.equal("1985-12-26", meta.edtf("1985-12-26"))
		assert.equal("1985", meta.edtf("1985?"))
		assert.equal("1985", meta.edtf("1985~"))
		assert.equal("1980", meta.edtf("198X"))
		assert.equal("1985", meta.edtf("1985/1987"))
		assert.equal("", meta.edtf("../1987"))
		assert.is_nil(meta.edtf("Dec-85"))
		assert.is_nil(meta.edtf("1985-13"))
		assert.is_nil(meta.edtf("85"))
	end)

	it("checks keys and refuses fields cairn already has", function()
		assert.equal("dcterms.date", meta.key("dcterms.date"))
		assert.equal("csl.DOI", meta.key("csl.DOI"))
		assert.is_nil(meta.key("date"))
		assert.is_nil(meta.key("Dc.date"))
		assert.is_nil(meta.key("dcterms.title"))
		assert.is_nil(meta.key("dcterms.subject"))
	end)

	it("applies set, remove, and add", function()
		local t = meta.apply({ ["a.x"] = "1" }, { "a.x=", "b.y=2",
		    "c.z+=one", "c.z+=two" })

		assert.same({ ["b.y"] = "2", ["c.z"] = { "one", "two" } }, t)
		assert.has_error(function()
			meta.apply({}, { "nokey" })
		end)
	end)

	it("maps PDF Info, Author to creator but not Creator", function()
		local t = meta.guess(meta.pdfinfo("Title: T\nAuthor: DoD\n"
		    .. "Creator: FrameMaker\nCreationDate: 1998-08-17T08:31:10Z\n"))

		assert.equal("DoD", t["dcterms.creator"])
		assert.equal("FrameMaker", t["pdf.Creator"])
		assert.equal("1998-08-17T08:31:10Z", t["pdf.CreationDate"])
		assert.is_nil(t["dcterms.date"])
	end)
end)

describe("store meta", function()
	local d, id

	before_each(function()
		d = assert(db.open(":memory:"))
		id = store.note(d, { title = "Orange Book", body = "criteria",
		    author = "kbd" })
	end)

	after_each(function()
		d:close()
	end)

	it("versions metadata and filters search on it", function()
		local _, rev = store.setmeta(d, id, { "dcterms.date=1985-12-26",
		    "dcterms.creator+=DoD", "dcterms.creator+=NCSC" }, "kbd")

		assert.equal(2, rev)

		local m = store.current(d, id).meta

		assert.equal("1985-12-26", m["dcterms.date"])
		assert.same({ "DoD", "NCSC" }, m["dcterms.creator"])
		assert.equal(1, #search.search(d, "date:<1990"))
		assert.equal(1, #search.search(d, "date:1985-12"))
		assert.equal(0, #search.search(d, "date:>=1986"))
		assert.equal(1, #search.search(d, "creator:ncsc"))
		assert.equal(1, #search.search(d, 'meta:dcterms.creator="dod"'))
		assert.equal(0, #search.search(d, "meta:csl.type"))
	end)

	it("keeps metadata across a note edit and refuses bad values", function()
		store.setmeta(d, id, { "dcterms.language=en" }, "kbd")

		local w = store.current(d, id)

		store.note(d, { id = id, rev = w.rev, base = w, title = w.title,
		    body = "criteria, second edition", author = "kbd" })
		assert.equal("en", store.current(d, id).meta["dcterms.language"])
		assert.has_error(function()
			store.setmeta(d, id, { "dcterms.date=Dec-85" }, "kbd")
		end)
		assert.has_error(function()
			store.setmeta(d, id,
			    { "x.token=ghp_abcdefghijklmnopqrstuvwxyz0123456789" }, "kbd")
		end)
	end)
end)

describe("pdfinfo", function()
	it("leaves an empty field empty", function()
		local t = meta.guess(meta.pdfinfo("Author:         \n"
		    .. "Creator:        Altium Designer\nProducer: x\n"))

		assert.is_nil(t["pdf.Author"])
		assert.is_nil(t["dcterms.creator"])
		assert.equal("Altium Designer", t["pdf.Creator"])
		assert.is_nil(meta.guess({ ["pdf.Author"] = "?" })["dcterms.creator"])
	end)
end)
