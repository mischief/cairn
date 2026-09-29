-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local chunk = require "cairn.chunk"
local db = require "cairn.db"
local queue = require "cairn.queue"
local secret = require "cairn.secret"
local store = require "cairn.store"
local util = require "cairn.util"

describe("queue", function()
	local d, file

	before_each(function()
		d = assert(db.open(":memory:"))
		file = store.putfile(d, "%PDF fake", "application/pdf", "kbd")
		queue.enqueue(d, file, "pdf")
		queue.enqueue(d, file, "vision")
	end)

	after_each(function()
		d:close()
	end)

	it("claims only the kinds asked for", function()
		local job = queue.claim(d, queue.BASIC, "a")

		assert.equal("pdf", job.kind)
		assert.is_nil(queue.claim(d, queue.BASIC, "b"))
		assert.equal("vision", queue.claim(d, queue.VISION, "b").kind)
	end)

	it("finishes only while the lease is held", function()
		local job = queue.claim(d, queue.BASIC, "a")

		-- the lease runs out and another enricher takes the job
		d:run("UPDATE job SET lease_until = '2000-01-01T00:00:00Z'")
		assert.equal(1, queue.reclaim(d))

		local again = queue.claim(d, queue.BASIC, "b")

		assert.equal(job.id, again.id)
		assert.is_false(queue.renew(d, job.id, "a"))

		local ran = false

		assert.is_false(queue.finish(d, job.id, "a", function()
			ran = true
		end))
		assert.is_false(ran)
		assert.is_true(queue.finish(d, job.id, "b", function()
			ran = true
		end))
		assert.is_true(ran)
		assert.equal("done", d:row("SELECT status FROM job WHERE id = ?",
		    { job.id }))
	end)

	it("fails a job after the last try", function()
		for _ = 1, queue.TRIES do
			local job = queue.claim(d, queue.BASIC, "a")

			queue.fail(d, job.id, "a", "boom")
		end
		assert.is_nil(queue.claim(d, queue.BASIC, "a"))
		assert.equal("failed", d:row("SELECT status FROM job WHERE kind = 'pdf'"))
		assert.equal(1, queue.retry_failed(d))
		assert.equal("pdf", queue.claim(d, queue.BASIC, "a").kind)
	end)

	it("replaces chunks when a job runs again", function()
		store.index(d, file, "pdf", "pdftotext", 1, chunk.pages("a\fb"))
		store.index(d, file, "pdf", "pdftotext", 1, chunk.pages("c"))
		assert.equal(1, d:row("SELECT count(*) FROM chunk"))
	end)
end)

describe("chunk", function()
	it("splits markdown at headings with a path", function()
		local c = chunk.markdown("intro\n# A\none\n## B\ntwo\n```\n# not\n```\n# C\nthree")

		assert.equal(4, #c)
		assert.is_nil(c[1].heading)
		assert.equal("A", c[2].heading)
		assert.equal("A > B", c[3].heading)
		assert.matches("# not", c[3].body)
		assert.equal("C", c[4].heading)
	end)

	it("numbers pages and drops empty ones", function()
		local c = chunk.pages("one\f\ftwo\0")

		assert.equal(2, #c)
		assert.equal(3, c[2].page)
		assert.equal("two", c[2].body)
	end)

	it("splits long text under the limit", function()
		local c = chunk.plain(("word "):rep(5000))

		assert.is_true(#c > 1)
		for _, x in ipairs(c) do
			assert.is_true(#x.body <= chunk.MAX)
		end
	end)
end)

describe("secret", function()
	it("passes plain text and catches keys", function()
		assert.is_nil(secret.check("the key to this design is simple"))
		assert.is_nil(secret.check(("a"):rep(64)))
		assert.is_nil(secret.check(
		    "| `[logprob]` | `types/chat/chat_completion_token_logprob.py` |"))
		assert.is_nil(secret.check("token: build-with-claude/token-counting-guide"))
		assert.is_nil(secret.check(
		    "the key QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG names it"))
		assert.is_nil(secret.check("key: see https://github.com/libp2p/specs/"
		    .. "blob/4e2c796bc77a2639136b277224468b7c48b9fff1/RFC/0001-text"))
		assert.is_not_nil(secret.check("see https://x.example/"
		    .. "?t=ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
		assert.is_nil(secret.check("Key: us-18-Valsorda-Squeezing-A-Key-"
		    .. "Through-A-Carry-Bit-wp.pdf"))
		assert.is_not_nil(secret.check(
		    "key: Zx8qP2vL-9mN4rT7wK1yB6cH3jF5gD0sAe-Qw"))
		assert.is_nil(secret.check("the password in the "
		    .. "dot11RSNAConfigPasswordValueTable has a password"))
		assert.is_nil(secret.check("token: dot11WNMDiag8021xAuthRprtRqstToken"))
		assert.is_not_nil(secret.check("key: MCowBQYDK2VwAyEA/QT6kQWOAMhDJf56jBmszEQ"))
		assert.equal("aws access key", secret.check("AKIAABCDEFGHIJKLMNOP"))
		assert.is_not_nil(secret.check(
		    "api_key: Zx8qP2vL9mN4rT7wK1yB6cH3jF5gD0sAe"))
	end)
end)

describe("util", function()
	it("makes ids and times", function()
		assert.is_true(util.isid(util.newid()))
		assert.matches("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$", util.now())
	end)
end)

describe("tags", function()
	local tags = require "cairn.tags"

	it("suggests close names but not short substrings", function()
		local d = assert(db.open(":memory:"))
		d:exec("PRAGMA foreign_keys = OFF")

		for _, t in ipairs({ "c", "lgml", "softraid", "ab" }) do
			d:run("INSERT INTO tag (doc, name) VALUES ('x', ?)", { t })
		end
		assert.same({}, tags.close(d, "crypto"))
		assert.same({}, tags.close(d, "inference"))
		assert.same({}, tags.close(d, "cd"))
		assert.same({ "lgml" }, tags.close(d, "lgm"))
		assert.same({ "softraid" }, tags.close(d, "softrad"))
		d:close()
	end)
end)

describe("missing tools", function()
	it("defers a job without spending a try and revives failed ones", function()
		local d = assert(db.open(":memory:"))
		local file = store.putfile(d, "%PDF x", "application/pdf", "kbd")

		queue.enqueue(d, file, "pdf")

		local job = queue.claim(d, queue.BASIC, "a")

		queue.defer(d, job.id, "a", "pdftotext is not installed")
		assert.same({ "pending", 0 }, { d:row("SELECT status, tries FROM job") })
		d:exec("UPDATE job SET status = 'failed', tries = 3")
		assert.equal(1, queue.revive(d))
		assert.equal("pending", d:row("SELECT status FROM job"))
		d:close()
	end)
end)

describe("chunk.utf8", function()
	it("replaces invalid bytes and keeps valid text", function()
		assert.equal("abc", chunk.utf8("abc"))
		assert.equal("z\u{00fc}rich", chunk.utf8("z\u{00fc}rich"))
		assert.equal("a\u{FFFD}b", chunk.utf8("a\255b"))
		assert.equal("x\u{FFFD}", chunk.utf8(("x\u{00fc}"):sub(1, 2)))
		assert.equal("\u{FFFD}\u{FFFD}ok", chunk.utf8("\192\193ok"))
		assert.is_truthy(utf8.len(chunk.clean("a\255\0b")))
	end)
end)
