-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local cid = require "cairn.cid"
local db = require "cairn.db"
local store = require "cairn.store"

describe("gc", function()
	local d

	before_each(function()
		d = assert(db.open(":memory:"))
	end)

	after_each(function()
		d:close()
	end)

	it("removes unreachable blocks and keeps history", function()
		local a = store.note(d, { title = "a", body = "one", author = "k" })
		local w = store.current(d, a)

		store.note(d, { id = a, rev = 1, base = w, title = "a", body = "two",
		    author = "k" })

		local b = store.note(d, { title = "b", body = "see [[a]]",
		    author = "k" })
		local junk = d:put(cid.RAW, "left by a crash")

		assert.is_true(d:has(junk))

		local before = d:row("SELECT count(*) FROM block")
		local n, bytes = store.gc(d, true)

		assert.equal(1, n)
		assert.equal(#"left by a crash", bytes)
		assert.equal(before, d:row("SELECT count(*) FROM block"))

		n = store.gc(d)
		assert.equal(1, n)
		assert.is_false(d:has(junk))
		assert.is_nil(d:lookup(junk))

		-- rev 1 of a, its old body, and the version b's link saw remain
		local v1 = d:row("SELECT node FROM doc_version WHERE doc = ? "
		    .. "AND rev = 1", { a })

		assert.is_not_nil(store.node(d, v1))
		assert.equal(3, d:row("SELECT count(*) FROM file"))
		assert.equal(0, (store.gc(d)))
		assert.is_not_nil(b)
		assert.equal(0, #d:rows("PRAGMA foreign_key_check"))
	end)
end)

describe("autogc", function()
	it("runs after gc.auto writes and resets the count", function()
		local d = assert(db.open(":memory:"))
		local config = require "cairn.config"

		config.set(d, "gc.auto", "3")
		store.note(d, { title = "a", body = "1", author = "k" })
		store.note(d, { title = "b", body = "2", author = "k" })
		assert.is_false(store.autogc(d))
		d:put(cid.RAW, "junk")
		store.note(d, { title = "c", body = "3", author = "k" })
		assert.is_true(store.autogc(d))
		assert.equal("0", d:row("SELECT value FROM state "
		    .. "WHERE key = 'gc.writes'"))
		assert.is_false(d:has(cid.sha256(cid.RAW, "junk")))
		config.set(d, "gc.auto", "0")
		for i = 1, 5 do
			store.note(d, { title = "n" .. i, body = "x" .. i, author = "k" })
		end
		assert.is_false(store.autogc(d))
		d:close()
	end)
end)
