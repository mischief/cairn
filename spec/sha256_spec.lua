-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

describe("sha256", function()
	-- load the pure Lua path even when luaossl is installed
	local saved = package.loaded["openssl.digest"]

	package.preload["openssl.digest"] = function()
		error("hidden for the test")
	end
	package.loaded["cairn.sha256"] = nil

	local pure = require "cairn.sha256"

	package.preload["openssl.digest"] = nil
	package.loaded["openssl.digest"] = saved
	package.loaded["cairn.sha256"] = nil

	local function hex(s)
		return (s:gsub(".", function(c)
			return ("%02x"):format(c:byte())
		end))
	end

	it("matches the FIPS 180-4 examples", function()
		assert.is_nil(pure.native)
		assert.equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		    hex(pure.sum("")))
		assert.equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		    hex(pure.sum("abc")))
		assert.equal("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
		    hex(pure.sum("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))
	end)

	it("agrees with luaossl on odd lengths", function()
		local ok, digest = pcall(require, "openssl.digest")

		if not ok then
			return
		end
		for _, n in ipairs({ 1, 55, 56, 63, 64, 65, 119, 1000, 70000 }) do
			local s = ("x"):rep(n)

			assert.equal(digest.new("sha256"):final(s), pure.sum(s))
		end
	end)
end)
