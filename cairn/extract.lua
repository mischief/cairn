-- SPDX-License-Identifier: ISC
-- extract: run external tools over file bytes. Each extractor returns
-- a list of chunks, or raises. None of them touch the database.

local chunk = require "cairn.chunk"
local proc = require "cairn.proc"
local util = require "cairn.util"

local M = {}

M.VERSION = { pdf = 1, ocr = 1, vision = 1, transcript = 1, pandoc = 1 }

M.PROMPT = "Describe this image for a search index. Name the objects, "
    .. "any text you can read, diagrams, labels, and the kind of image. "
    .. "Plain text, no preamble."

local function run(argv, opts)
	local out, code, err = proc.run(argv, opts)

	if code == 127 then
		error(argv[1] .. " is not installed", 0)
	end
	if code ~= 0 then
		error(("%s exited %d: %s"):format(argv[1], code,
		    (err or ""):sub(1, 300)), 0)
	end
	return out
end

-- with(data, mime, fn) writes data to a temp file and calls fn(path)
local function with(data, mime, fn)
	local path = util.tmpfile(util.extof(mime))

	assert(util.writefile(path, data))

	local res = table.pack(pcall(fn, path))

	os.remove(path)
	if not res[1] then
		error(res[2], 0)
	end
	return table.unpack(res, 2, res.n)
end

local function b64(s)
	local cid = require "cairn.cid"
	local out = cid.bases.m.enc(s)

	return out .. ("="):rep((4 - #out % 4) % 4)
end

-- pdf(data, opts) -> chunks, needocr. needocr is true when the pdf
-- has no text layer.
function M.pdf(data, opts)
	return with(data, "application/pdf", function(path)
		local text = run({ "pdftotext", "-layout", "-enc", "UTF-8", path,
		    "-" }, opts)
		local chunks = chunk.pages(text)
		local pages = select(2, text:gsub("\f", "")) + 0

		return chunks, chunk.weight(text) < 20 * math.max(pages, 1)
	end)
end

-- ocr(data, mime, opts) -> chunks, from tesseract over each page
function M.ocr(data, mime, opts)
	return with(data, mime, function(path)
		if mime ~= "application/pdf" then
			return chunk.plain(run({ "tesseract", path, "-" }, opts))
		end

		local prefix = util.tmpfile()

		run({ "pdftoppm", "-r", "200", "-png", path, prefix }, opts)

		local dir, base = prefix:match("^(.*)/([^/]+)$")
		local pages, text = {}, {}

		for f in require("posix.dirent").files(dir) do
			if f:sub(1, #base + 1) == base .. "-" and f:match("%.png$") then
				pages[#pages + 1] = dir .. "/" .. f
			end
		end
		table.sort(pages)
		for _, f in ipairs(pages) do
			local ok, t = pcall(run, { "tesseract", f, "-" }, opts)

			os.remove(f)
			if not ok then
				error(t, 0)
			end
			text[#text + 1] = t
		end
		os.remove(prefix)
		return chunk.pages(table.concat(text, "\f"))
	end)
end

local function post(path, body, opts)
	local url = assert(opts.url, "no lgml url")

	return with(body, "application/json", function(bodypath)
		return run({ "curl", "-sS", "--fail-with-body", "-m", "900",
		    "-H", "content-type: application/json",
		    "--data-binary", "@" .. bodypath, url .. path }, opts)
	end)
end

-- vision(data, mime, opts) -> chunks with an image description
function M.vision(data, mime, opts)
	if mime ~= "image/png" and mime ~= "image/jpeg" then
		error("vision takes png or jpeg, not " .. tostring(mime), 0)
	end

	local json = require "mcptk.json"
	local body = json.encode({
		model = assert(opts.model, "no lgml model"),
		max_tokens = 600,
		chat_template_kwargs = { enable_thinking = false },
		messages = { {
			role = "user",
			content = {
				{ type = "text", text = M.PROMPT },
				{ type = "image_url", image_url = {
				    url = "data:" .. mime .. ";base64," .. b64(data) } },
			},
		} },
	})
	local res = json.decode(post("/v1/chat/completions", body, opts))
	local text = res.choices and res.choices[1] and res.choices[1].message
	    and res.choices[1].message.content

	if type(text) ~= "string" or text == "" then
		error("lgml gave no description", 0)
	end
	return chunk.plain(text)
end

-- transcript(data, mime, opts) -> chunks with an audio transcript
function M.transcript(data, mime, opts)
	return with(data, mime, function(path)
		local wav = util.tmpfile(".wav")
		local ok, res = pcall(function()
			run({ "ffmpeg", "-y", "-loglevel", "error", "-i", path,
			    "-ac", "1", "-ar", "16000", wav }, opts)
			return run({ "curl", "-sS", "--fail-with-body", "-m", "3600",
			    "-F", "file=@" .. wav, "-F", "response_format=json",
			    assert(opts.url, "no lgml url") .. "/v1/audio/transcriptions" }, opts)
		end)

		os.remove(wav)
		if not ok then
			error(res, 0)
		end

		local json = require "mcptk.json"
		local text = json.decode(res).text

		if type(text) ~= "string" then
			error("lgml gave no transcript", 0)
		end
		return chunk.plain(text)
	end)
end

local PANDOC = {
	["text/html"] = "html",
	["application/epub+zip"] = "epub",
	["application/rtf"] = "rtf",
	["application/vnd.oasis.opendocument.text"] = "odt",
	["application/vnd.openxmlformats-officedocument"
	    .. ".wordprocessingml.document"] = "docx",
}

-- pandoc(data, mime, opts) -> chunks of plain text
function M.pandoc(data, mime, opts)
	local from = PANDOC[mime]

	if not from then
		error("pandoc does not read " .. tostring(mime), 0)
	end
	return with(data, mime, function(path)
		return chunk.plain(run({ "pandoc", "-f", from, "-t", "plain",
		    "--wrap=none", path }, opts))
	end)
end

return M
