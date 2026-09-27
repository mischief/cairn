-- SPDX-License-Identifier: ISC
-- util: time, ids, and file helpers shared by the other modules.

local cid = require "cairn.cid"

local M = {}

-- random(n) -> n random bytes, from luaossl when it is installed, else
-- from /dev/urandom
local function random(n)
	local ok, rand = pcall(require, "openssl.rand")

	if ok then
		return rand.bytes(n)
	end

	local f = assert(io.open("/dev/urandom", "rb"))
	local s = f:read(n)

	f:close()
	assert(s and #s == n, "short read from /dev/urandom")
	return s
end

-- now() -> RFC 3339 UTC, fixed width, so text order is time order
function M.now(t)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

function M.day(t)
	return os.date("!%Y-%m-%d", t)
end

-- newid() -> 16 characters of lowercase base32 over 10 random bytes
function M.newid()
	return cid.bases.b.enc(random(10))
end

-- which(name) -> full path of an executable file on PATH, or nil
function M.which(name)
	local stat = require "posix.sys.stat"
	local unistd = require "posix.unistd"

	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local p = dir .. "/" .. name
		local st = dir:sub(1, 1) == "/" and stat.stat(p)

		if st and stat.S_ISREG(st.st_mode) ~= 0
		    and unistd.access(p, "x") == 0 then
			return p
		end
	end
end

function M.isid(s)
	return type(s) == "string" and #s == 16 and s:match("^[a-z2-7]+$") ~= nil
end

function M.readfile(path)
	local f, err = io.open(path, "rb")

	if not f then
		return nil, err
	end

	local s = f:read("a")

	f:close()
	return s
end

function M.writefile(path, s)
	local f, err = io.open(path, "wb")

	if not f then
		return nil, err
	end
	f:write(s)
	f:close()
	return true
end

-- tmpfile(ext) -> a new empty file path ending in ext
function M.tmpfile(ext)
	local base = os.tmpname()

	if not ext or ext == "" then
		return base
	end

	local path = base .. ext

	os.rename(base, path)
	return path
end

local EXT = {
	md = "text/markdown", markdown = "text/markdown",
	txt = "text/plain", text = "text/plain",
	pdf = "application/pdf",
	png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg",
	gif = "image/gif", webp = "image/webp",
	html = "text/html", htm = "text/html",
	docx = "application/vnd.openxmlformats-officedocument"
	    .. ".wordprocessingml.document",
	odt = "application/vnd.oasis.opendocument.text",
	epub = "application/epub+zip", rtf = "application/rtf",
	wav = "audio/wav", mp3 = "audio/mpeg", ogg = "audio/ogg",
	flac = "audio/flac", m4a = "audio/mp4", opus = "audio/ogg",
}

M.EXT = EXT

-- extension of a mime type, for temp files that tools read by name
function M.extof(mime)
	for ext, m in pairs(EXT) do
		if m == mime and #ext <= 4 and ext ~= "htm" and ext ~= "jpg"
		    and ext ~= "text" then
			return "." .. ext
		end
	end
	return ""
end

-- mimeof(name[, path]) -> mime type from the extension, then file(1)
function M.mimeof(name, path)
	local ext = name and name:match("%.([%w]+)$")
	local m = ext and EXT[ext:lower()]

	if m or not path then
		return m or "application/octet-stream"
	end

	local proc = require "cairn.proc"
	local out, code = proc.run({ "file", "--brief", "--mime-type", path })

	if code == 0 and out:match("^%S+/%S+") then
		return out:match("^(%S+/%S+)")
	end
	return "application/octet-stream"
end

function M.istext(mime)
	return mime == "text/markdown" or mime == "text/plain"
end

return M
