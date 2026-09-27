-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local cid = require "cairn.cid"
local db = require "cairn.db"
local schema = require "cairn.schema"

describe("db", function()
	local d

	before_each(function()
		d = assert(db.open(":memory:"))
	end)

	after_each(function()
		d:close()
	end)

	it("stamps application id and schema version", function()
		assert.equal(schema.APPLICATION_ID, d:row("PRAGMA application_id"))
		assert.equal(schema.VERSION, d:row("PRAGMA user_version"))
	end)

	it("stores a raw block under its CID", function()
		local c, id = d:put(cid.RAW, "hello\0world")

		assert.equal(cid.sha256(cid.RAW, "hello\0world"), c)
		assert.is_true(d:has(c))

		local data, codec = d:get(c)

		assert.equal("hello\0world", data)
		assert.equal(cid.RAW, codec)
		assert.equal(id, d:lookup(c))
	end)

	it("matches the known CID of a raw block", function()
		-- ipfs add --cid-version=1 --raw-leaves of "hello world\n"
		local c = d:put(cid.RAW, "hello world\n")

		assert.equal("bafkreifjjcie6lypi6ny7amxnfftagclbuxndqonfipmb64f2km2devei4",
		    cid.tostring(c))
	end)

	it("stores the same bytes once", function()
		local a, ida = d:put(cid.RAW, "x")
		local b, idb = d:put(cid.RAW, "x")

		assert.equal(a, b)
		assert.equal(ida, idb)
		assert.equal(1, d:row("SELECT count(*) FROM block"))
	end)

	it("returns nil for an absent block", function()
		assert.is_nil(d:get(cid.sha256(cid.RAW, "nope")))
		assert.is_false(d:has(cid.sha256(cid.RAW, "nope")))
	end)

	it("refuses codecs with no link parser", function()
		assert.has_error(function()
			d:put(cid.DAG_PB, "")
		end)
	end)

	it("records links of a DRISL block in ref", function()
		local drisl = require "cairn.drisl"
		local leaf = d:put(cid.RAW, "leaf")
		local gone = cid.sha256(cid.RAW, "not stored")
		local _, id = d:put(cid.DAG_CBOR, drisl.encode({
			a = drisl.link(leaf), b = drisl.link(gone) }))

		assert.equal(2, d:row("SELECT count(*) FROM ref WHERE parent = ?",
		    { id }))
		assert.is_nil(d:get(gone))
		assert.is_not_nil(d:lookup(gone))
	end)

	it("refuses a malformed DRISL block", function()
		assert.has_error(function()
			d:put(cid.DAG_CBOR, "\xa1\x01\x01")
		end)
	end)

	it("refuses oversized blocks", function()
		assert.has_error(function()
			d:put(cid.RAW, ("x"):rep(db.MAXBLOCK + 1))
		end)
	end)

	it("rolls back a failed transaction", function()
		assert.has_error(function()
			d:tx(function()
				d:put(cid.RAW, "gone")
				error("boom")
			end)
		end)
		assert.is_false(d:has(cid.sha256(cid.RAW, "gone")))
	end)

	it("indexes chunks through the fts triggers", function()
		d:exec([[
INSERT INTO cid (id, cid) VALUES (1, x'01');
INSERT INTO file (id, size) VALUES (1, 0);
INSERT INTO extract (id, file, kind, extractor, version, created)
    VALUES (1, 1, 'text', 'builtin', 1, 'now');
INSERT INTO chunk (extract, seq, heading, body)
    VALUES (1, 1, 'intro', 'running cairns mark trails');
]])
		assert.equal(1, d:row("SELECT count(*) FROM chunk_fts "
		    .. "WHERE chunk_fts MATCH 'run'"))
		d:exec("UPDATE chunk SET body = 'stones' WHERE id = 1")
		assert.equal(0, d:row("SELECT count(*) FROM chunk_fts "
		    .. "WHERE chunk_fts MATCH 'run'"))
	end)

	it("opens a file database again and refuses foreign ones", function()
		local path = os.tmpname()

		os.remove(path)

		local a = assert(db.open(path))
		local c = a:put(cid.RAW, "kept")

		assert.equal("wal", a:row("PRAGMA journal_mode"))
		assert.equal(8192, a:row("PRAGMA page_size"))
		assert.equal(2, a:row("PRAGMA auto_vacuum"))
		a:close()

		local b = assert(db.open(path))

		assert.equal("kept", (b:get(c)))
		b:close()

		local other = os.tmpname()
		local sqlite3 = require "lsqlite3"
		local s = sqlite3.open(other)

		s:exec("CREATE TABLE t (x)")
		s:close()

		local ok, err = db.open(other)

		assert.is_nil(ok)
		assert.equal("not a cairn database", err)
		for _, p in ipairs({ path, path .. "-wal", path .. "-shm", other }) do
			os.remove(p)
		end
	end)
end)
