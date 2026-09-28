-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local cjson = require "cjson"
local db = require "cairn.db"
local lgml = require "cairn.lgml"
local store = require "cairn.store"
local topics = require "cairn.topics"
local x = require "cairn.experiments"

local VOCAB = {
	topics = {
		{ "security", "Computer security", "", "threats and defenses" },
		{ "privacy", "Privacy", "security", "personal data" },
		{ "mathematics", "Mathematics", "", "all of it" },
		{ "cryptography", "Cryptography", "security mathematics", "ciphers" },
	},
}

-- a fake lgml: form answers paper, topics takes the first choice, a
-- chat with no schema gets a two-sentence abstract, embeddings come
-- from the text's bytes
local calls
local fake = {}

function fake:call(_, path, body)
	calls[#calls + 1] = path
	if path == "/v1/embeddings" then
		local data = {}

		for i, t in ipairs(body.input) do
			local v = {}

			for k = 1, 8 do
				v[k] = (t:byte(k) or 1) / 255
			end
			data[i] = { index = i - 1, embedding = v }
		end
		return { data = data }
	end

	local rf = body.response_format
	local text

	if not rf then
		text = "First sentence here. Second one."
	elseif rf.json_schema.name == "form" then
		text = cjson.encode({ form = "paper" })
	else
		local props = rf.json_schema.schema.properties
		local first = props.topics.items.enum[1]

		text = cjson.encode(props.subjects
		    and { subjects = { "newfield" }, topics = { first } }
		    or { topics = { first } })
	end
	return { choices = { { message = { content = text },
	    finish_reason = "stop" } } }
end

function fake.close() end

describe("experiments with a fake lgml", function()
	local d, saved, quiet

	local function run(name, opts)
		x.main({ args = { name }, opts = opts or {} }, d, ":memory:")
	end

	local function chats()
		local n = 0

		for _, p in ipairs(calls) do
			n = n + (p == "/v1/chat/completions" and 1 or 0)
		end
		return n
	end

	before_each(function()
		saved = { client = lgml.client, available = lgml.available,
		    print = _G.print }
		lgml.client = function()
			return fake
		end
		lgml.available = function()
			return { array = function(t)
				return t
			end, json = { decode = cjson.decode } }
		end
		quiet = true
		_G.print = function(...)
			if not quiet then
				saved.print(...)
			end
		end
		calls = {}
		d = assert(db.open(":memory:"))
		topics.seed(d, "cairn", VOCAB)
	end)

	after_each(function()
		lgml.client, lgml.available = saved.client, saved.available
		_G.print = saved.print
		d:close()
	end)

	it("keeps a form a person chose", function()
		local def = store.note(d, { title = "rsa", body = "ciphers",
		    author = "k" })
		local set = store.note(d, { title = "tor", body = "onions",
		    author = "k", meta = { ["dcterms.type"] = "note" } })

		assert.is_nil(store.current(d, def).meta["gen.form"])
		-- naming the default form by hand counts too
		store.setmeta(d, def, { "dcterms.type=note" }, "k")
		assert.equal("model=hand wrote=note",
		    store.current(d, def).meta["gen.form"])
		assert.equal("model=hand wrote=note",
		    store.current(d, set).meta["gen.form"])
		store.setmeta(d, def, { "dcterms.type=report" }, "k")
		assert.equal("model=hand wrote=report",
		    store.current(d, def).meta["gen.form"])
		-- a write that sets its own receipt keeps it
		store.update(d, def, nil, "cairn:update", function(w)
			w.meta["dcterms.type"] = "paper"
			w.meta["gen.form"] = "v=2 model=m wrote=paper"
		end)
		assert.equal("v=2 model=m wrote=paper",
		    store.current(d, def).meta["gen.form"])
	end)

	it("writes nothing on a dry run", function()
		local id = store.note(d, { title = "rsa", body = "ciphers and keys",
		    author = "k" })

		run("update")
		assert.is_true(chats() > 0)
		assert.is_nil(store.current(d, id).meta["gen.topics"])
		assert.equal(0, d:row("SELECT count(*) FROM docvec"))
	end)

	it("classifies new documents once and leaves them alone after", function()
		local a = store.note(d, { title = "rsa", body = "ciphers and keys",
		    author = "k" })
		local b = store.note(d, { title = "tor", body = "onion routing",
		    author = "k" })

		run("update", { apply = true })

		for _, id in ipairs({ a, b }) do
			local w = store.current(d, id)

			assert.equal("paper", w.meta["dcterms.type"])
			assert.equal("First sentence here. Second one.",
			    w.meta["dcterms.abstract"])
			assert.same({ "topic/cryptography" }, w.tags)
			assert.matches("wrote=cryptography", w.meta["gen.topics"])
			assert.is_not_nil(w.meta["gen.form"])
			assert.is_not_nil(w.meta["gen.abstract"])
			-- one version for the note, one for the whole update run
			assert.equal(2, w.rev)
			assert.equal("cairn:update", d:row("SELECT author FROM "
			    .. "doc_version WHERE doc = ? AND rev = 2", { id }))
		end
		assert.equal(2, d:row("SELECT count(*) FROM docvec"))

		calls = {}
		run("update", { apply = true })
		assert.equal(0, #calls)
	end)

	it("keeps a hand edit and redoes changed content", function()
		local a = store.note(d, { title = "rsa", body = "ciphers and keys",
		    author = "k" })

		run("update", { apply = true })
		store.update(d, a, nil, "k", function(w)
			w.tags = { "topic/privacy" }
		end)
		calls = {}
		run("topics", { apply = true })
		assert.equal(0, chats())
		assert.same({ "topic/privacy" }, store.current(d, a).tags)

		local w = store.current(d, a)

		store.note(d, { id = a, rev = w.rev, base = w, title = "rsa",
		    body = "ciphers, keys, and signatures", author = "k" })
		calls = {}
		run("summarize", { apply = true })
		assert.equal(1, chats())
	end)
end)

describe("experiments --tag", function()
	it("runs only on documents with the tag", function()
		local saved = { client = lgml.client, available = lgml.available,
		    print = _G.print }

		lgml.client = function()
			return fake
		end
		lgml.available = function()
			return { array = function(t)
				return t
			end, json = { decode = cjson.decode } }
		end
		_G.print = function() end
		calls = {}

		local d = assert(db.open(":memory:"))

		store.note(d, { title = "rsa", body = "ciphers", author = "k",
		    tags = { "rfc" } })
		store.note(d, { title = "tor", body = "onions", author = "k" })
		x.main({ args = { "form" }, opts = { t = { "rfc" }, set = {} } }, d,
		    ":memory:")
		lgml.client, lgml.available = saved.client, saved.available
		_G.print = saved.print
		d:close()
		assert.equal(1, #calls)
	end)
end)

describe("experiments --stale", function()
	it("needs --tag, ids, or --all", function()
		local d = assert(db.open(":memory:"))

		store.note(d, { title = "rsa", body = "ciphers", author = "k" })
		assert.has_error(function()
			x.main({ args = { "form" }, opts = { stale = true, t = {} } }, d,
			    ":memory:")
		end, "--stale would run form on 1 document; limit it with --tag "
		    .. "or ids, or give --all")
		d:close()
	end)
end)

describe("receipts and re-extraction", function()
	it("do not redo a document whose text is only indexed again", function()
		local saved = { client = lgml.client, available = lgml.available,
		    print = _G.print }

		lgml.client = function()
			return fake
		end
		lgml.available = function()
			return { array = function(t)
				return t
			end, json = { decode = cjson.decode } }
		end
		_G.print = function() end

		local d = assert(db.open(":memory:"))

		topics.seed(d, "cairn", VOCAB)

		local id = store.note(d, { title = "rsa", body = "# keys\n\nciphers",
		    author = "k" })
		local opts = { apply = true, t = {} }

		x.main({ args = { "update" }, opts = opts }, d, ":memory:")

		-- the same text, indexed again with a new time
		local w = store.current(d, id)

		store.indextext(d, w.content, "text/markdown", store.content(d,
		    w.content))
		calls = {}
		x.main({ args = { "update" }, opts = opts }, d, ":memory:")
		lgml.client, lgml.available = saved.client, saved.available
		_G.print = saved.print
		d:close()
		assert.equal(0, #calls)
	end)
end)
