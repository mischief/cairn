-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local db = require "cairn.db"
local derive = require "cairn.derive"
local store = require "cairn.store"

describe("derive", function()
	local d

	before_each(function()
		d = assert(db.open(":memory:"))

		local a = store.note(d, { title = "a", body = "one", tags = { "x" },
		    author = "k" })
		local w = store.current(d, a)

		store.note(d, { id = a, rev = 1, base = w, title = "a",
		    body = "two, see [[Nothing yet]]", author = "k" })
		store.note(d, { title = "b", body = "[[a]]", tags = { "y" },
		    author = "k", links = { { rel = "supersedes", doc = a } } })
		store.setmeta(d, a, { "dcterms.date=1985" }, "k")
	end)

	after_each(function()
		d:close()
	end)

	it("finds nothing wrong after normal writes", function()
		assert.same({}, derive.check(d))
	end)

	it("reports and repairs broken copies", function()
		d:exec("PRAGMA foreign_keys = OFF")
		d:exec("UPDATE doc SET title = 'wrong', superseded_by = NULL")
		d:exec("DELETE FROM tag")
		d:exec("DELETE FROM meta")
		d:exec("DELETE FROM doc_version")
		d:exec("DELETE FROM wanted")
		d:exec("PRAGMA foreign_keys = ON")
		assert.is_true(#derive.check(d) >= 5)
		assert.equal(2, derive.rebuild(d))
		assert.same({}, derive.check(d))
	end)

	it("rebuilds a lost doc table from the blocks", function()
		d:exec("PRAGMA foreign_keys = OFF")
		for _, t in ipairs({ "doc", "doc_fts", "doc_version", "tag", "link",
		    "meta", "wanted" }) do
			d:exec("DELETE FROM " .. t)
		end
		d:exec("PRAGMA foreign_keys = ON")
		assert.equal(2, derive.rebuild(d))
		assert.same({}, derive.check(d))
		assert.equal(3, d:row("SELECT count(*) FROM doc_version "
		    .. "WHERE doc = (SELECT id FROM doc WHERE title = 'a')"))
	end)
end)
