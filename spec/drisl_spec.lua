package.path = "./?.lua;./?/init.lua;" .. package.path

local cid = require "cairn.cid"
local drisl = require "cairn.drisl"

local function unhex(h)
	return (h:gsub("%s", ""):gsub("..", function(x)
		return string.char(tonumber(x, 16))
	end))
end

local function hex(s)
	return (s:gsub(".", function(c)
		return ("%02x"):format(c:byte())
	end))
end

describe("drisl", function()
	-- RFC 8949 appendix A, where DRISL allows the item
	local vectors = {
		{ 0, "00" }, { 23, "17" }, { 24, "1818" }, { 100, "1864" },
		{ 1000, "1903e8" }, { 1000000, "1a000f4240" },
		{ 1000000000000, "1b000000e8d4a51000" },
		{ math.maxinteger, "1b7fffffffffffffff" },
		{ -1, "20" }, { -10, "29" }, { -100, "3863" },
		{ -1000, "3903e7" },
		{ math.mininteger, "3b7fffffffffffffff" },
		{ "", "60" }, { "a", "6161" }, { "IETF", "6449455446" },
		{ "\u{00fc}", "62c3bc" }, { "\u{6c34}", "63e6b0b4" },
		{ drisl.bytes(""), "40" },
		{ drisl.bytes("\1\2\3\4"), "4401020304" },
		{ drisl.array(), "80" }, { { 1, 2, 3 }, "83010203" },
		{ { a = 1, b = { 2, 3 } }, "a26161016162820203" },
		{ {}, "a0" },
		{ true, "f5" }, { false, "f4" }, { drisl.null, "f6" },
	}

	for _, v in ipairs(vectors) do
		it("encodes and decodes " .. v[2], function()
			assert.equal(v[2], hex(drisl.encode(v[1])))

			local back, err = drisl.decode(unhex(v[2]))

			assert.is_nil(err)
			assert.equal(v[2], hex(drisl.encode(back)))
		end)
	end

	it("sorts map keys length first", function()
		assert.equal("a2616201626161" .. "02",
		    hex(drisl.encode({ b = 1, aa = 2 })))
	end)

	it("gives the known CID of an empty map", function()
		local c = cid.sha256(cid.DAG_CBOR, drisl.encode({}))

		assert.equal("bafyreigbtj4x7ip5legnfznufuopl4sg4knzc2cof6duas4b3q2fy6swua",
		    cid.tostring(c))
	end)

	it("round-trips links and finds them", function()
		local a = cid.sha256(cid.RAW, "a")
		local b = cid.sha256(cid.RAW, "b")
		local node = {
			prev = drisl.link(a),
			links = { { rel = "see-also", doc = "x" } },
			content = drisl.link(b),
			blob = drisl.bytes(a),
		}
		local enc = drisl.encode(node)
		local back = assert(drisl.decode(enc))

		assert.equal(a, drisl.islink(back.prev))
		assert.equal(a, drisl.isbytes(back.blob))

		local found = drisl.links(enc)

		table.sort(found)

		local want = { a, b }

		table.sort(want)
		assert.same(want, found)
	end)

	it("refuses values DRISL cannot hold", function()
		for _, v in ipairs({ 1.5, 1.0, "\xff", { 1, x = 2 },
		    { [2] = 1 }, print, setmetatable({}, {}) }) do
			assert.has_error(function()
				drisl.encode(v)
			end)
		end
	end)

	it("refuses a reference cycle", function()
		local t = {}

		t.t = t
		assert.has_error(function()
			drisl.encode(t)
		end)
	end)

	local bad = {
		{ "1817", "non-minimal integer" },
		{ "190017", "non-minimal integer" },
		{ "3b8000000000000000", "integer out of range" },
		{ "1b8000000000000000", "integer out of range" },
		{ "5f4101ff", "indefinite length" },
		{ "9f01ff", "indefinite length" },
		{ "fb3ff8000000000000", "float" },
		{ "f93c00", "float" },
		{ "f7", "simple value 23" },
		{ "c11a514b67b0", "tag 1" },
		{ "a1016161", "map key is not text" },
		{ "a2616201616102", "map keys out of order" },
		{ "a2616101616102", "duplicate map key" },
		{ "61ff", "text is not UTF-8" },
		{ "d82a4401020304", "tag 42 without 0x00 prefix" },
		{ "d82a6161", "tag 42 without bytes" },
		{ "0000", "trailing bytes" },
		{ "62", "truncated" },
		{ "1a0001", "truncated" },
		{ "", "truncated" },
	}

	for _, v in ipairs(bad) do
		it("rejects " .. v[1] .. " (" .. v[2] .. ")", function()
			local ok, err = drisl.decode(unhex(v[1]))

			assert.is_nil(ok)
			assert.equal(v[2], err)
		end)
	end

	it("rejects deep nesting", function()
		local s = ("81"):rep(drisl.MAX_DEPTH + 2) .. "00"
		local ok, err = drisl.decode(unhex(s))

		assert.is_nil(ok)
		assert.equal("nested too deep", err)
	end)
end)
