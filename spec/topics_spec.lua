-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local db = require "cairn.db"
local search = require "cairn.search"
local store = require "cairn.store"
local topics = require "cairn.topics"

local VOCAB = {
	topics = {
		{ "security", "Computer security", "", "threats and defenses" },
		{ "privacy", "Privacy", "security", "personal data" },
		{ "anonymity", "Anonymity", "privacy", "who talks to whom" },
		{ "mathematics", "Mathematics", "", "all of it" },
		{ "cryptography", "Cryptography", "security mathematics", "ciphers" },
	},
	aliases = { crypto = "cryptography" },
}

describe("topics", function()
	local d

	before_each(function()
		d = assert(db.open(":memory:"))
	end)

	after_each(function()
		d:close()
	end)

	it("seeds about pages once and keeps edited ones", function()
		local added, differ, aliases = topics.seed(d, "cairn", VOCAB)

		assert.same({ 5, {}, 1 }, { added, differ, aliases })
		assert.equal(0, (topics.seed(d, "cairn", VOCAB)))

		local id = d:row("SELECT id FROM doc WHERE about = 'topic/privacy'")

		store.setmeta(d, id, { "skos.scopeNote=my own note" }, "k")

		local _, changed = topics.seed(d, "cairn", VOCAB)

		assert.same({ "topic/privacy" }, changed)
		assert.equal("Cryptography", d:row("SELECT title FROM doc "
		    .. "WHERE about = 'topic/cryptography'"))
	end)

	it("finds documents under a broader topic", function()
		topics.seed(d, "cairn", VOCAB)

		local tor = store.note(d, { title = "Tor", body = "onion routing",
		    author = "k", tags = { "topic/anonymity" } })
		local rsa = store.note(d, { title = "RSA", body = "onion keys",
		    author = "k", tags = { "crypto" } })

		local function ids(q)
			local out = {}

			for _, h in ipairs(search.search(d, q)) do
				out[#out + 1] = h.id
			end
			table.sort(out)
			return out
		end

		local both = { tor, rsa }

		table.sort(both)
		assert.same(both, ids("onion tag:topic/security"))
		assert.same({ tor }, ids("onion tag:topic/privacy"))
		assert.same({ rsa }, ids("onion tag:topic/mathematics"))

		local count = {}

		for _, r in ipairs(search.tags(d, "topic/")) do
			count[r.name] = r.count
		end
		assert.equal(2, count["topic/security"])
		assert.equal(1, count["topic/mathematics"])
		assert.equal(1, count["topic/anonymity"])
	end)
end)
