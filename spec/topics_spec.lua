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
		local added, differ = topics.seed(d, "cairn", VOCAB)

		assert.same({ 5, {} }, { added, differ })
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
		    author = "k", tags = { "topic/cryptography" } })

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

describe("topic guard", function()
	it("refuses a topic/ tag without an about page", function()
		local d = assert(db.open(":memory:"))

		assert.has_error(function()
			store.note(d, { title = "x", body = "y", author = "k",
			    tags = { "topic/made-up" } })
		end)
		topics.seed(d, "cairn", VOCAB)

		local id = store.note(d, { title = "x", body = "y", author = "k",
		    tags = { "topic/privacy" } })
		local page = d:row("SELECT id FROM doc WHERE about = 'topic/privacy'")

		store.update(d, page, nil, "k", function(w)
			w.hidden = true
		end)
		-- a document keeps a topic it holds after the topic is hidden
		store.update(d, id, nil, "k", function(w)
			w.title = "x2"
		end)
		assert.has_error(function()
			store.note(d, { title = "z", body = "y", author = "k",
			    tags = { "topic/privacy" } })
		end)
		d:close()
	end)
end)

describe("topic cap", function()
	it("folds leaves into their shared broader topic", function()
		local x = require "cairn.experiments"
		local v = { children = {
			["computer-science"] = { "programming-languages",
			    "software-engineering", "computer-programming" },
			["programming-languages"] = { "compilers", "assembly-languages" },
			compilers = { "assemblers", "code-generation",
			    "compiler-optimization", "linkers" },
		} }
		local got = x.cap(v, { "assemblers", "assembly-languages",
		    "code-generation", "compiler-optimization", "computer-programming",
		    "linkers", "software-engineering" }, { ["computer-science"] = true })

		assert.same({ "compilers", "assembly-languages", "computer-programming",
		    "software-engineering" }, got)
	end)
end)
