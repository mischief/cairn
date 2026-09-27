-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local receipt = require "cairn.receipt"

describe("receipt", function()
	local want = { v = 3, model = "m", content = "1@t", vocab = "ab" }

	it("round-trips its fields", function()
		local r = { v = 3, model = "m", content = "1@t", vocab = "ab",
		    wrote = "compilers,linkers" }

		assert.same({ v = "3", model = "m", content = "1@t", vocab = "ab",
		    wrote = "compilers,linkers" }, receipt.parse(receipt.format(r)))
	end)

	it("says why a document needs the classifier", function()
		local r = receipt.parse("v=3 model=m content=1@t vocab=ab wrote=x")

		assert.equal("new", receipt.state(nil, want, ""))
		assert.equal("current", receipt.state(r, want, "x"))
		assert.equal("hand", receipt.state(r, want, "y"))
		assert.equal("changed", receipt.state(r, { v = 3, model = "m",
		    content = "1@u", vocab = "ab" }, "x"))
		assert.equal("old", receipt.state(r, { v = 4, model = "m",
		    content = "1@t", vocab = "ab" }, "x"))
		assert.equal("model", receipt.state(r, { v = 3, model = "n",
		    content = "1@t", vocab = "ab" }, "x"))
		assert.equal("vocab", receipt.state(r, { v = 3, model = "m",
		    content = "1@t", vocab = "cd" }, "x"))
	end)

	it("runs new and changed by default", function()
		assert.same({ new = true, changed = true }, receipt.which({}))
		assert.is_true(receipt.which({ stale = true }).vocab)
		assert.is_nil(receipt.which({ all = true }).hand)
	end)
end)
