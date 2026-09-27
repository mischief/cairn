-- SPDX-License-Identifier: ISC
-- lgml: calls to an lgml server through lgml-client, for the
-- experiments. lgml-client is optional; cairn runs without it, and
-- only the code that calls a model needs it.

local config = require "cairn.config"

local M = {}

M.HINT = "lgml-client is not installed: luarocks --lua-version 5.4 "
    .. "install --local lgml-client (git.offblast.org/mischief/lgml-client)"

-- available() -> the lgml.client module, or nil
function M.available()
	local ok, client = pcall(require, "lgml.client")

	return ok and client or nil
end

-- client(d, opts) -> a client for the lgml.url setting. opts: url,
-- timeout, tick, tick_every. Raises with an install hint when
-- lgml-client is missing.
function M.client(d, opts)
	local client = M.available()

	if not client then
		error(M.HINT, 0)
	end
	opts = opts or {}
	return assert(client.new{
		url = opts.url or config.get(d, "lgml.url"),
		timeout = opts.timeout or 900,
		tick = opts.tick,
		tick_every = opts.tick_every,
	})
end

local function fail(what, err)
	error(("lgml %s: %s%s"):format(what, err.kind, err.message
	    and (": " .. err.message) or ""), 0)
end

-- chat(c, body) -> the text of the first choice of a chat completion
function M.chat(c, body)
	local r, err = c:call("POST", "/v1/chat/completions", body)

	if not r then
		fail("chat", err)
	end

	local text = r.choices and r.choices[1] and r.choices[1].message
	    and r.choices[1].message.content

	if type(text) ~= "string" then
		error("lgml chat: no text in the reply", 0)
	end
	return text
end

-- embed(c, texts, opts) -> list of vectors (lists of numbers), one per
-- text. opts: model, dimensions.
function M.embed(c, texts, opts)
	opts = opts or {}

	local client = M.available()
	local r, err = c:call("POST", "/v1/embeddings", {
		model = opts.model,
		input = client.array(texts),
		dimensions = opts.dimensions,
	})

	if not r then
		fail("embeddings", err)
	end

	local out = {}

	for _, e in ipairs(r.data or {}) do
		out[e.index + 1] = e.embedding
	end
	return out, r.usage
end

return M
