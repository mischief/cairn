-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local tags = require "cairn.tags"
local vocab = require "cairn.vocab"

describe("vocab", function()
	local by = {}

	for _, t in ipairs(vocab.topics) do
		by[t[1]] = t
	end

	it("has unique, valid slugs, a label, and a scope note", function()
		local n = 0

		for _, t in ipairs(vocab.topics) do
			n = n + 1
			assert.equal("topic/" .. t[1], tags.normalize("topic/" .. t[1]))
			assert.is_true(#t[2] > 0 and #t[4] > 0, t[1])
		end

		local seen = 0

		for _ in pairs(by) do
			seen = seen + 1
		end
		assert.equal(n, seen)
	end)

	it("names only known broader topics, with no cycles", function()
		local function up(slug, path)
			assert.is_nil(path[slug], "cycle at " .. slug)
			path[slug] = true
			for b in by[slug][3]:gmatch("%S+") do
				assert.is_not_nil(by[b], slug .. " names unknown " .. b)
				up(b, path)
			end
			path[slug] = nil
		end

		for _, t in ipairs(vocab.topics) do
			up(t[1], {})
		end
	end)

	it("aliases point at topics", function()
		for alias, slug in pairs(vocab.aliases) do
			assert.is_not_nil(by[slug], alias .. " -> " .. slug)
		end
	end)
end)
