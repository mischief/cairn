-- SPDX-License-Identifier: ISC
-- drisl: DRISL, deterministic dag-cbor (https://dasl.ing/drisl.html),
-- minus floats: encode refuses them and decode rejects them.
-- Lua strings encode as text; M.bytes, M.link and M.null wrap the
-- other kinds. A sequence is an array, a string-keyed table a map, and
-- a bare {} an empty map. M.array marks an array, even an empty one.
-- Decoded arrays carry that mark, so decode then encode round-trips.

local cid = require "cairn.cid"

local M = {}

-- bounds recursion both ways: a hostile block on decode, a cycle on
-- encode
M.MAX_DEPTH = 64

local ARRAY = { __name = "drisl.array" }
local BYTES = { __name = "drisl.bytes" }
local LINK = { __name = "drisl.link" }

M.null = setmetatable({}, { __name = "drisl.null",
    __tostring = function() return "null" end })

function M.array(t)
	return setmetatable(t or {}, ARRAY)
end

function M.bytes(s)
	assert(type(s) == "string", "drisl.bytes: not a string")
	return setmetatable({ s }, BYTES)
end

-- link(binary cid)
function M.link(c)
	assert(cid.decode(c), "drisl.link: not a cid")
	return setmetatable({ c }, LINK)
end

function M.isarray(v)
	return getmetatable(v) == ARRAY
end

-- isbytes(v) -> the bytes, or nil
function M.isbytes(v)
	return getmetatable(v) == BYTES and v[1] or nil
end

-- islink(v) -> the binary cid, or nil
function M.islink(v)
	return getmetatable(v) == LINK and v[1] or nil
end

-- ---- encode ----

local function head(major, n)
	local m = major << 5

	if n < 24 then
		return string.char(m | n)
	elseif n <= 0xff then
		return string.pack(">BI1", m | 24, n)
	elseif n <= 0xffff then
		return string.pack(">BI2", m | 25, n)
	elseif n <= 0xffffffff then
		return string.pack(">BI4", m | 26, n)
	end
	return string.pack(">BI8", m | 27, n)
end

local function keyorder(a, b)
	if #a ~= #b then
		return #a < #b
	end
	return a < b
end

local function kind(t)
	local mt = getmetatable(t)

	if mt == ARRAY then
		return "array"
	elseif mt ~= nil then
		return mt.__name or "table with a metatable"
	end

	local n, strkeys = 0, true

	for k in pairs(t) do
		n = n + 1
		if type(k) ~= "string" then
			strkeys = false
		end
	end
	if n == 0 or strkeys then
		return "map"
	end
	if n == #t then
		return "array"
	end
	return "mixed table"
end

local encode_value

local function encode_table(t, out, depth)
	local k = kind(t)

	if k == "array" then
		out[#out + 1] = head(4, #t)
		for i = 1, #t do
			encode_value(t[i], out, depth + 1)
		end
	elseif k == "map" then
		local keys = {}

		for key in pairs(t) do
			keys[#keys + 1] = key
		end
		table.sort(keys, keyorder)
		out[#out + 1] = head(5, #keys)
		for _, key in ipairs(keys) do
			encode_value(key, out, depth + 1)
			encode_value(t[key], out, depth + 1)
		end
	else
		error("drisl: cannot encode " .. k, 0)
	end
end

function encode_value(v, out, depth)
	if depth > M.MAX_DEPTH then
		error("drisl: nested too deep", 0)
	end

	local t = type(v)

	if t == "number" then
		if math.type(v) ~= "integer" then
			error("drisl: float " .. tostring(v), 0)
		end
		if v >= 0 then
			out[#out + 1] = head(0, v)
		else
			out[#out + 1] = head(1, -1 - v)
		end
	elseif t == "string" then
		if not utf8.len(v) then
			error("drisl: string is not UTF-8", 0)
		end
		out[#out + 1] = head(3, #v)
		out[#out + 1] = v
	elseif t == "boolean" then
		out[#out + 1] = v and "\xf5" or "\xf4"
	elseif v == M.null then
		out[#out + 1] = "\xf6"
	elseif M.isbytes(v) then
		out[#out + 1] = head(2, #v[1])
		out[#out + 1] = v[1]
	elseif M.islink(v) then
		out[#out + 1] = "\xd8\x2a" .. head(2, #v[1] + 1) .. "\0"
		out[#out + 1] = v[1]
	elseif t == "table" then
		encode_table(v, out, depth)
	else
		error("drisl: cannot encode " .. t, 0)
	end
end

-- encode(value) -> bytes. Raises an error on a value DRISL cannot hold.
function M.encode(v)
	local out = {}

	encode_value(v, out, 0)
	return table.concat(out)
end

-- ---- decode ----

-- MIN[ai] is the smallest argument that needs that many bytes
local MIN = { [24] = 24, [25] = 0x100, [26] = 0x10000,
    [27] = 0x100000000 }
local FMT = { [24] = ">I1", [25] = ">I2", [26] = ">I4", [27] = ">I8" }

-- read a head at s[i]: major, argument, next index
local function readhead(s, i)
	local b = s:byte(i)

	if not b then
		error("truncated", 0)
	end

	local major, ai = b >> 5, b & 0x1f

	if major == 7 then
		return major, ai, i + 1
	end
	if ai < 24 then
		return major, ai, i + 1
	end
	if ai > 27 then
		error(ai == 31 and "indefinite length" or "reserved head", 0)
	end
	if i + (1 << (ai - 24)) > #s then
		error("truncated", 0)
	end

	local n, j = string.unpack(FMT[ai], s, i + 1)

	-- an I8 above 2^63-1 wraps negative in Lua
	if n < 0 then
		error("integer out of range", 0)
	end
	if n < MIN[ai] then
		error("non-minimal integer", 0)
	end
	return major, n, j
end

local function take(s, i, n)
	if n > #s - i + 1 then
		error("truncated", 0)
	end
	return s:sub(i, i + n - 1), i + n
end

local decode_value

local function decode_text(s, i, n)
	local v, j = take(s, i, n)

	if not utf8.len(v) then
		error("text is not UTF-8", 0)
	end
	return v, j
end

function decode_value(s, i, depth)
	if depth > M.MAX_DEPTH then
		error("nested too deep", 0)
	end

	local major, n, j = readhead(s, i)

	if major == 0 then
		return n, j
	elseif major == 1 then
		return -1 - n, j
	elseif major == 2 then
		local v

		v, j = take(s, j, n)
		return M.bytes(v), j
	elseif major == 3 then
		return decode_text(s, j, n)
	elseif major == 4 then
		local t = {}

		for k = 1, n do
			t[k], j = decode_value(s, j, depth + 1)
		end
		return M.array(t), j
	elseif major == 5 then
		local t, prev = {}, nil

		for _ = 1, n do
			local km, kn, key

			km, kn, j = readhead(s, j)
			if km ~= 3 then
				error("map key is not text", 0)
			end
			key, j = decode_text(s, j, kn)
			if prev and not keyorder(prev, key) then
				error(prev == key and "duplicate map key"
				    or "map keys out of order", 0)
			end
			prev = key
			t[key], j = decode_value(s, j, depth + 1)
		end
		return t, j
	elseif major == 6 then
		if n ~= 42 then
			error("tag " .. n, 0)
		end

		local bm, bn

		bm, bn, j = readhead(s, j)
		if bm ~= 2 then
			error("tag 42 without bytes", 0)
		end

		local raw

		raw, j = take(s, j, bn)
		if raw:byte(1) ~= 0 then
			error("tag 42 without 0x00 prefix", 0)
		end

		local c = raw:sub(2)
		local ok, why = cid.decode(c)

		if not ok then
			error("bad cid: " .. why, 0)
		end
		if ok.version ~= 1 then
			error("cidv0 link", 0)
		end
		return M.link(c), j
	end

	-- major 7
	if n == 20 then
		return false, j
	elseif n == 21 then
		return true, j
	elseif n == 22 then
		return M.null, j
	elseif n >= 25 and n <= 27 then
		error("float", 0)
	end
	error("simple value " .. n, 0)
end

-- decode(bytes) -> value, or nil, reason. The input must be exactly
-- one item in canonical form.
function M.decode(s)
	if type(s) ~= "string" then
		return nil, "not a string"
	end

	local ok, v, j = pcall(decode_value, s, 1, 0)

	if not ok then
		return nil, v
	end
	if j <= #s then
		return nil, "trailing bytes"
	end
	-- the checks above should make this hold; it guards against a
	-- missed rule
	if M.encode(v) ~= s then
		return nil, "not canonical"
	end
	return v
end

-- links(bytes) -> list of binary CIDs linked from a block
function M.links(s)
	local v, err = M.decode(s)

	if v == nil then
		error("drisl: " .. err, 0)
	end

	local out = {}

	local function walk(x)
		if type(x) ~= "table" then
			return
		end

		local c = M.islink(x)

		if c then
			out[#out + 1] = c
		elseif not M.isbytes(x) then
			for _, y in pairs(x) do
				walk(y)
			end
		end
	end

	walk(v)
	return out
end

return M
