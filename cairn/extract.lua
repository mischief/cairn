-- SPDX-License-Identifier: ISC
-- extract: run external tools over file bytes. Each extractor returns
-- a list of chunks, or raises. None of them touch the database.

local chunk = require "cairn.chunk"
local proc = require "cairn.proc"
local util = require "cairn.util"

local M = {}

M.VERSION = { pdf = 2, ocr = 1, vision = 1, transcript = 1, pandoc = 2 }

-- commands each kind of job runs; ocr of a pdf also needs pdftoppm
M.TOOLS = {
	pdf = { "pdftotext" },
	ocr = { "tesseract" },
	pandoc = { "pandoc" },
	vision = {},
	transcript = { "ffmpeg", "curl" },
}

-- what each tool comes in, for hints
M.PACKAGE = { pdftotext = "poppler", pdftoppm = "poppler",
    tesseract = "tesseract", pandoc = "pandoc", ffmpeg = "ffmpeg",
    curl = "curl" }

-- missing(kind, mime) -> list of commands the kind needs that are not on
-- PATH
function M.missing(kind, mime)
	local need = { table.unpack(M.TOOLS[kind] or {}) }

	if kind == "ocr" and mime == "application/pdf" then
		need[#need + 1] = "pdftoppm"
	end

	local out = {}

	for _, t in ipairs(need) do
		if not util.which(t) then
			out[#out + 1] = t
		end
	end
	return out
end

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

-- twocolumn(page) -> true when a page of pdftotext -layout output holds
-- two columns of prose: most long lines have one gap, and the gaps line
-- up near the middle. Tables have several gaps a line.
function M.twocolumn(page)
	local width = 0

	for l in page:gmatch("[^\n]+") do
		width = math.max(width, #l)
	end
	if width < 60 then
		return false
	end

	local lo, hi = width * 3 // 10, width * 7 // 10
	local lines, gaps, hits = 0, 0, {}

	for l in page:gmatch("[^\n]+") do
		if #l >= width * 0.6 then
			local i = 1

			lines = lines + 1
			while true do
				local s, e = l:find("%s%s%s+", i)

				if not s then
					break
				end
				if s > 1 and e < #l and l:sub(1, s - 1):find("%S") then
					gaps = gaps + 1
					for c = math.max(s, lo), math.min(e, hi) do
						hits[c] = (hits[c] or 0) + 1
					end
				end
				i = e + 1
			end
		end
	end
	if lines < 8 then
		return false
	end

	local best = 0

	for _, n in pairs(hits) do
		best = math.max(best, n)
	end
	return best >= lines * 0.6 and gaps <= lines * 1.5
end

-- pdf(data, opts) -> chunks, needocr. needocr is true when most pages
-- have no text layer. Layout mode keeps tables readable but runs the
-- columns of a two-column page together, so those pages come from
-- reading order instead.
function M.pdf(data, opts)
	return with(data, "application/pdf", function(path)
		local text = run({ "pdftotext", "-layout", "-enc", "UTF-8", path,
		    "-" }, opts)
		local pages, twos = {}, false

		for p in text:gmatch("([^\f]*)\f") do
			pages[#pages + 1] = p
			twos = twos or M.twocolumn(p)
		end
		if twos then
			local flow, fp = run({ "pdftotext", "-enc", "UTF-8", path, "-" },
			    opts), {}

			for p in flow:gmatch("([^\f]*)\f") do
				fp[#fp + 1] = p
			end
			if #fp == #pages then
				for i, p in ipairs(pages) do
					if M.twocolumn(p) then
						pages[i] = fp[i]
					end
				end
				text = table.concat(pages, "\f") .. "\f"
			end
		end

		-- a scan often has a text layer on a few pages only, such as a
		-- typed introduction before scanned pages; OCR when most pages
		-- are empty
		local chunks, pages, empty = chunk.pages(text), 0, 0

		for p in text:gmatch("([^\f]*)\f") do
			pages = pages + 1
			if chunk.weight(p) < 20 then
				empty = empty + 1
			end
		end
		return chunks, pages == 0 or empty * 2 > pages
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

-- vision(data, mime, opts) -> chunks with an image description
function M.vision(data, mime, opts)
	if mime ~= "image/png" and mime ~= "image/jpeg" then
		error("vision takes png or jpeg, not " .. tostring(mime), 0)
	end

	local lgml = require "cairn.lgml"
	local c = lgml.client(nil, { url = assert(opts.url, "no lgml url"),
	    tick = opts.tick, tick_every = opts.every })
	local ok, text = pcall(lgml.chat, c, {
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

	c:close()
	if not ok then
		error(text, 0)
	end
	if text == "" then
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

-- a pandoc filter that keeps the text of links, spans, and divs, and
-- drops images and raw HTML, so markdown output reads as text
M.FILTER = [[
function Link(el) return el.content end
function Image() return {} end
function Span(el) return el.content end
function Div(el) return el.content end
function RawInline() return {} end
function RawBlock() return {} end
]]

-- pandoc(data, mime, opts) -> chunks split at the document's headings.
-- Markdown keeps headings and tables; the backslashes markdown puts
-- before punctuation are removed.
function M.pandoc(data, mime, opts)
	local from = PANDOC[mime]

	if not from then
		error("pandoc does not read " .. tostring(mime), 0)
	end

	local filter = util.tmpfile(".lua")

	assert(util.writefile(filter, M.FILTER))

	local ok, text = pcall(with, data, mime, function(path)
		return run({ "pandoc", "-f", from, "-t", "gfm-raw_html",
		    "--wrap=none", "-L", filter, path }, opts)
	end)

	os.remove(filter)
	if not ok then
		error(text, 0)
	end
	return chunk.markdown((text:gsub("\\(%p)", "%1")))
end

return M
