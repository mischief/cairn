-- config: settings kept in the database, so a backup holds them too.
-- An environment variable overrides the stored value for one process.

local M = {}

-- key -> { env, default, desc, check }
M.KEYS = {
	["lgml.url"] = { env = "CAIRN_LGML", default = "http://127.0.0.1:8091",
	    desc = "lgml server for image descriptions and transcripts" },
	["lgml.model"] = { env = "CAIRN_MODEL", default = "gemma-4-26b",
	    desc = "lgml model for image descriptions" },
	["enrich.vision"] = { env = "CAIRN_VISION", default = "0",
	    desc = "1 lets an enricher started by cairn mcp use lgml",
	    check = "^[01]$" },
	["mcp.write"] = { env = "CAIRN_MCP_WRITE", default = "0",
	    desc = "1 gives cairn mcp its write tools: put, edit, tag, meta, "
	    .. "link, attach",
	    check = "^[01]$" },
	["gc.auto"] = { env = "CAIRN_GC_AUTO", default = "1000",
	    desc = "run gc after this many versions are written; 0 turns "
	    .. "it off", check = "^%d+$" },
	["limit.daily"] = { env = "CAIRN_DAILY_BYTES",
	    default = tostring(256 * 1024 * 1024),
	    desc = "bytes each author may store per day", check = "^%d+$" },
}

-- get(d, key) -> value, from the environment, then the database, then
-- the default
function M.get(d, key)
	local k = assert(M.KEYS[key], "unknown config key " .. key)
	local v = k.env and os.getenv(k.env)

	if v and v ~= "" then
		return v
	end
	return d:row("SELECT value FROM config WHERE key = ?", { key })
	    or k.default
end

function M.number(d, key)
	return math.tointeger(tonumber(M.get(d, key)))
end

-- set(d, key, value) stores a value; nil value removes it
function M.set(d, key, value)
	local k = M.KEYS[key]

	if not k then
		error("unknown config key " .. tostring(key), 0)
	end
	if value == nil then
		d:run("DELETE FROM config WHERE key = ?", { key })
		return
	end
	if k.check and not tostring(value):match(k.check) then
		error(("bad value for %s: %s"):format(key, value), 0)
	end
	d:run("INSERT INTO config (key, value) VALUES (?, ?) "
	    .. "ON CONFLICT (key) DO UPDATE SET value = excluded.value",
	    { key, tostring(value) })
end

-- list(d) -> { key, value, source, desc } for every key
function M.list(d)
	local out = {}

	for key, k in pairs(M.KEYS) do
		local env = k.env and os.getenv(k.env)
		local stored = d:row("SELECT value FROM config WHERE key = ?", { key })
		local source = (env and env ~= "") and ("env " .. k.env)
		    or stored and "db" or "default"

		out[#out + 1] = { key = key, value = M.get(d, key), source = source,
		    desc = k.desc }
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

return M
