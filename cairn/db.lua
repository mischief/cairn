-- SPDX-License-Identifier: ISC
-- db: open a cairn database and store blocks by CID. A block is
-- immutable; writing the same bytes twice stores one row.

local sqlite3 = require "lsqlite3"

local cid = require "cairn.cid"
local drisl = require "cairn.drisl"
local schema = require "cairn.schema"

local M = {}

-- a file is one raw block
M.MAXBLOCK = 64 * 1024 * 1024

-- links(data) -> list of binary CIDs, for each codec cairn stores
M.links = {
	[cid.RAW] = function()
		return {}
	end,
	[cid.DAG_CBOR] = drisl.links,
}

local D = {}
D.__index = D

local function check(self, rv, what)
	if rv ~= sqlite3.OK and rv ~= sqlite3.DONE and rv ~= sqlite3.ROW then
		error(what .. ": " .. self.sql:errmsg(), 2)
	end
	return rv
end

function D:exec(sql)
	check(self, self.sql:exec(sql), "exec")
end

-- prepare returns a cached statement, reset. row and run use it for
-- one step only; never iterate a cached statement while another call
-- may reuse the same SQL.
function D:prepare(sql)
	local st = self.stmts[sql]

	if not st then
		st = self.sql:prepare(sql)
		if not st then
			error("prepare: " .. self.sql:errmsg(), 2)
		end
		self.stmts[sql] = st
	end
	st:reset()
	return st
end

-- bind a list of values; strings bind as blobs when blob[i] is set
local function bind(st, args, blob)
	for i = 1, args.n or #args do
		local v = args[i]

		if blob and blob[i] then
			st:bind_blob(i, v)
		else
			st:bind(i, v)
		end
	end
end

-- first row of a query, as values; nil when there is none
function D:row(sql, args, blob)
	local st = self:prepare(sql)

	bind(st, args or {}, blob)

	local rv = check(self, st:step(), "step")

	if rv == sqlite3.ROW then
		local r = st:get_values()

		st:reset()
		return table.unpack(r, 1, st:columns())
	end
	st:reset()
end

-- rows(sql, args, blob) -> list of rows, each a table by column name.
-- It prepares a fresh statement, so callers may nest it.
function D:rows(sql, args, blob)
	local st = self.sql:prepare(sql)

	if not st then
		error("prepare: " .. self.sql:errmsg(), 2)
	end
	bind(st, args or {}, blob)

	local out = {}

	while true do
		local rv = st:step()

		if rv == sqlite3.ROW then
			out[#out + 1] = st:get_named_values()
		elseif rv == sqlite3.DONE then
			break
		else
			local err = self.sql:errmsg()

			st:finalize()
			error("step: " .. err, 2)
		end
	end
	st:finalize()
	return out
end

-- run a statement that returns no rows; returns changes()
function D:run(sql, args, blob)
	local st = self:prepare(sql)

	bind(st, args or {}, blob)
	check(self, st:step(), "step")
	st:reset()
	return self.sql:changes()
end

-- run fn inside one write transaction. An error rolls back and is
-- raised again. Nested calls join the outer transaction, with no
-- savepoint: an error in a nested call rolls back all of it.
function D:tx(fn, ...)
	if self.depth > 0 then
		return fn(...)
	end
	self:exec("BEGIN IMMEDIATE")
	self.depth = 1

	local res = table.pack(pcall(fn, ...))

	self.depth = 0
	if not res[1] then
		self.sql:exec("ROLLBACK")
		error(res[2], 0)
	end
	if self.sql:exec("COMMIT") ~= sqlite3.OK then
		local err = self.sql:errmsg()

		self.sql:exec("ROLLBACK")
		error("commit: " .. err, 2)
	end
	return table.unpack(res, 2, res.n)
end

-- intern(binary cid) -> integer id. Insert first, so two processes
-- that race on one CID both see the same row.
function D:intern(c)
	self:run("INSERT OR IGNORE INTO cid (cid) VALUES (?)", { c }, { true })
	return (self:row("SELECT id FROM cid WHERE cid = ?", { c }, { true }))
end

-- lookup(binary cid) -> integer id, or nil
function D:lookup(c)
	return (self:row("SELECT id FROM cid WHERE cid = ?", { c }, { true }))
end

-- put(codec, data) -> binary cid, id. Links inside the block go to ref.
function D:put(codec, data)
	local parse = M.links[codec]

	if not parse then
		error("put: no link parser for codec " .. codec, 2)
	end
	if #data > M.MAXBLOCK then
		error("put: block of " .. #data .. " bytes", 2)
	end

	local c = cid.sha256(codec, data)
	local links = parse(data)

	return self:tx(function()
		local id = self:intern(c)

		if self:run("INSERT OR IGNORE INTO block (id, codec, size, data) "
		    .. "VALUES (?, ?, ?, ?)", { id, codec, #data, data },
		    { [4] = true }) > 0 then
			for _, l in ipairs(links) do
				self:run("INSERT OR IGNORE INTO ref (parent, child) "
				    .. "VALUES (?, ?)", { id, self:intern(l) })
			end
		end
		return c, id
	end)
end

-- get(binary cid) -> data, codec; or nil when the block is absent
function D:get(c)
	local data, codec = self:row("SELECT b.data, b.codec FROM block b "
	    .. "JOIN cid c ON c.id = b.id WHERE c.cid = ?", { c }, { true })

	return data, codec
end

-- has(binary cid) -> true when the block is stored
function D:has(c)
	return self:row("SELECT 1 FROM block b JOIN cid c ON c.id = b.id "
	    .. "WHERE c.cid = ?", { c }, { true }) ~= nil
end

function D:close()
	self.sql:exec("PRAGMA optimize")
	for _, st in pairs(self.stmts) do
		st:finalize()
	end
	self.stmts = {}
	self.sql:close()
end

local function migrate(self)
	local appid = self:row("PRAGMA application_id")
	local ver = self:row("PRAGMA user_version")

	if appid ~= schema.APPLICATION_ID then
		local tables = self:row("SELECT count(*) FROM sqlite_schema")

		if appid ~= 0 or tables ~= 0 then
			return nil, "not a cairn database"
		end
		for _, p in ipairs(schema.PRAGMAS_NEW) do
			self:exec(p)
		end
	end
	if ver > schema.VERSION then
		return nil, "schema version " .. ver .. " is newer than "
		    .. schema.VERSION
	end
	if ver < schema.VERSION then
		self:tx(function()
			for v = ver + 1, schema.VERSION do
				self:exec(schema.migrations[v])
			end
			self:exec(("PRAGMA application_id = %d")
			    :format(schema.APPLICATION_ID))
			self:exec(("PRAGMA user_version = %d")
			    :format(schema.VERSION))
		end)
	end
	return true
end

-- open(path) -> db, or nil, reason. ":memory:" opens a scratch database.
function M.open(path)
	local sql, _, err = sqlite3.open(path)

	if not sql then
		return nil, err
	end

	local self = setmetatable({ sql = sql, stmts = {}, depth = 0 }, D)

	for _, p in ipairs(schema.PRAGMAS) do
		self:exec(p)
	end

	local ok, why = migrate(self)

	if not ok then
		self:close()
		return nil, why
	end
	if path ~= ":memory:" then
		self:row("PRAGMA journal_mode = WAL")
	end
	return self
end

return M
