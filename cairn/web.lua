-- SPDX-License-Identifier: ISC
-- web: a read-only browser for the store over HTTP. Pages are plain
-- HTML with no scripts. Stored text is escaped, and stored files go
-- out with types that a browser does not run.

local cid = require "cairn.cid"
local cli = require "cairn.cli"
local md = require "cairn.md"
local search = require "cairn.search"
local store = require "cairn.store"

local M = {}

local esc = md.escape

-- address cairn web listens on by default
M.LISTEN = "127.0.0.1:8377"

-- hits on one search page, and documents on the front page
M.HITS = 20
M.RECENT = 50

M.CSP = "default-src 'none'; style-src 'self'; img-src 'self'; "
    .. "media-src 'self'; frame-src 'self'; form-action 'self'; "
    .. "base-uri 'none'; frame-ancestors 'self'"

M.STYLE = [[
:root { color-scheme: light dark; --fg: #1b1b1b; --bg: #fdfdfb;
  --dim: #6b6b6b; --line: #d8d8d2; --link: #0b5cad; --code: #f1f1ec;
  --mark: #ffe58a; }
@media (prefers-color-scheme: dark) {
  :root { --fg: #d8d8d4; --bg: #161616; --dim: #8c8c88; --line: #333;
    --link: #7ab4f0; --code: #222; --mark: #6b5600; }
}
* { box-sizing: border-box; }
body { margin: 0; font: 16px/1.5 system-ui, sans-serif; color: var(--fg);
  background: var(--bg); }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
header { display: flex; gap: 1em; align-items: center; flex-wrap: wrap;
  padding: .5em 1em; border-bottom: 1px solid var(--line); }
header .name { font-weight: 700; color: var(--fg); }
header form { flex: 1; display: flex; min-width: 12em; }
header input { flex: 1; font: inherit; padding: .25em .5em;
  color: var(--fg); background: var(--bg); border: 1px solid var(--line);
  border-radius: 4px; }
main { max-width: 60em; margin: 0 auto; padding: 1em; }
main.wide { max-width: none; }
h1 { font-size: 1.5em; margin: .2em 0 .4em; }
h2 { font-size: 1.2em; }
h3 { font-size: 1.05em; }
.dim, .dim a { color: var(--dim); }
.small { font-size: .85em; }
pre, code { font: .9em/1.45 ui-monospace, monospace; }
code { background: var(--code); padding: .1em .25em; border-radius: 3px; }
pre { background: var(--code); padding: .75em; border-radius: 4px;
  overflow-x: auto; }
pre code { background: none; padding: 0; font-size: 1em; }
pre.text { white-space: pre-wrap; overflow-wrap: anywhere; }
blockquote { margin: 1em 0; padding: 0 1em;
  border-left: 3px solid var(--line); color: var(--dim); }
table { border-collapse: collapse; }
th, td { border: 1px solid var(--line); padding: .25em .6em;
  text-align: left; vertical-align: top; }
.right { text-align: right; }
.center { text-align: center; }
hr { border: 0; border-top: 1px solid var(--line); }
mark { background: var(--mark); color: inherit; }
img { max-width: 100%; }
.wanted { color: #b3402a; border-bottom: 1px dashed; }
.tabs { display: flex; gap: .25em; margin: .75em 0;
  border-bottom: 1px solid var(--line); }
.tabs a, .tabs b { padding: .25em .75em; }
.tabs b { border: 1px solid var(--line); border-bottom-color: var(--bg);
  border-radius: 4px 4px 0 0; margin-bottom: -1px; }
.tags a { display: inline-block; margin: 0 .3em .2em 0; padding: 0 .5em;
  border: 1px solid var(--line); border-radius: 1em; font-size: .85em; }
.note { margin: .5em 0; padding: .4em .75em;
  border-left: 3px solid var(--mark); background: var(--code); }
.abstract { color: var(--dim); font-style: italic; }
.hit { margin: 0 0 1.1em; }
.hit .title { font-size: 1.1em; }
.hit p { margin: .15em 0; }
ul.plain { list-style: none; padding: 0; }
ul.plain li { margin: .2em 0; }
li.d1 { margin-left: 1.5em; } li.d2 { margin-left: 3em; }
li.d3 { margin-left: 4.5em; } li.d4 { margin-left: 6em; }
li.d5 { margin-left: 7.5em; } li.d6 { margin-left: 9em; }
dl.meta { display: grid; grid-template-columns: max-content 1fr;
  gap: .1em 1em; margin: .5em 0; }
dl.meta dt { color: var(--dim); }
dl.meta dd { margin: 0; overflow-wrap: anywhere; }
details { margin: .5em 0; }
summary { cursor: pointer; color: var(--dim); }
iframe.file { width: 100%; height: 85vh; border: 1px solid var(--line); }
.pager { display: flex; gap: 1em; margin: 1em 0; }
footer { margin-top: 2em; padding-top: .5em;
  border-top: 1px solid var(--line); }
]]

-- quote(s) -> s for use in a URL path or query value
local function quote(s)
	return (tostring(s):gsub("[^%w%-._~/]", function(c)
		return ("%%%02X"):format(c:byte())
	end))
end

M.quote = quote

-- docurl(id, rev, frag, view) -> address of a document page
local function docurl(id, rev, frag, view, page)
	local q = {}

	if frag then
		q[#q + 1] = "at=" .. quote(frag)
	end
	if view then
		q[#q + 1] = "view=" .. view
	end
	if page and page > 1 then
		q[#q + 1] = "page=" .. page
	end
	return "/d/" .. id .. (rev and ("@" .. rev) or "")
	    .. (#q > 0 and ("?" .. table.concat(q, "&")) or "")
end

M.docurl = docurl

local function rawurl(id, rev)
	return "/raw/" .. id .. (rev and ("@" .. rev) or "")
end

local function searchurl(q, offset)
	return "/search?q=" .. quote(q)
	    .. (offset and offset > 0 and ("&offset=" .. offset) or "")
end

local function link(href, text, class)
	return ('<a%s href="%s">%s</a>'):format(
	    class and (' class="' .. class .. '"') or "", esc(href), esc(text))
end

-- refurl(d, s) -> address of the document a link target names, or nil
local function refurl(d, s)
	local r = store.ref(d, s)

	return r and docurl(r.doc, r.pin and r.rev or nil, r.frag) or nil
end

-- a response: status, headers, body
local function html(status, title, body, o)
	o = o or {}

	local name = esc(cli.progname())
	local page = {
		"<!doctype html>\n<html lang=\"en\">\n<head>\n",
		"<meta charset=\"utf-8\">\n",
		"<meta name=\"viewport\" content=\"width=device-width, ",
		"initial-scale=1\">\n",
		"<title>", esc(title), " - ", name, "</title>\n",
		"<link rel=\"stylesheet\" href=\"/style.css\">\n</head>\n<body>\n",
		"<header><a class=\"name\" href=\"/\">", name, "</a>\n",
		"<form action=\"/search\"><input type=\"search\" name=\"q\" ",
		"placeholder=\"search\" value=\"", esc(o.q or ""), "\"",
		o.focus and " autofocus" or "", "></form>\n",
		"<nav><a href=\"/\">recent</a> <a href=\"/tags\">tags</a> ",
		"<a href=\"/wanted\">wanted</a></nav></header>\n",
		o.wide and "<main class=\"wide\">\n" or "<main>\n", body,
		"</main>\n</body>\n</html>\n",
	}

	return status, {
		["Content-Type"] = "text/html; charset=utf-8",
		["Content-Security-Policy"] = M.CSP,
		["X-Content-Type-Options"] = "nosniff",
		["Referrer-Policy"] = "no-referrer",
		["Cache-Control"] = "no-store",
	}, table.concat(page)
end

local function fail(status, msg)
	return html(status, tostring(status), "<h1>" .. status .. "</h1>\n<p>"
	    .. esc(msg) .. "</p>\n")
end

local function redirect(to)
	return 302, { Location = to, ["Cache-Control"] = "no-store" }, ""
end

local function day(t)
	return t and t:sub(1, 10) or "?"
end

-- recent(d, limit) -> the documents changed last, each once, at its
-- newest version. About pages and classifier versions (author
-- cairn:NAME) do not count.
function M.recent(d, limit)
	return d:rows("SELECT v.doc AS id, max(v.rev) AS rev, v.author, "
	    .. "v.created, d.title FROM doc_version v JOIN doc d ON d.id = v.doc "
	    .. "WHERE d.hidden = 0 AND d.about IS NULL "
	    .. "AND v.author NOT LIKE 'cairn:%' GROUP BY v.doc "
	    .. "ORDER BY v.created DESC, v.doc LIMIT ?", { limit })
end

local function front(d)
	local s = { "<h1>Recent</h1>\n<ul class=\"plain\">\n" }

	for _, r in ipairs(M.recent(d, M.RECENT)) do
		s[#s + 1] = ("<li><span class=\"dim small\">%s</span> %s "
		    .. "<span class=\"dim small\">rev %d, %s</span></li>\n"):format(
		    esc(day(r.created)), link(docurl(r.id), r.title), r.rev,
		    esc(r.author or "?"))
	end
	s[#s + 1] = "</ul>\n"
	return html(200, "recent", table.concat(s), { focus = true })
end

-- snippet(s) -> HTML of a search snippet; FTS5 puts [ ] around a match
local function snippet(s)
	return (esc(s:gsub("%s+", " ")):gsub("%[(.-)%]", "<mark>%1</mark>"))
end

local function results(d, q, offset)
	if q:match("^%s*$") then
		return html(200, "search", "<h1>Search</h1>\n<pre class=\"text\">"
		    .. esc(cli.named(cli.SEARCHHELP)) .. "</pre>\n", { focus = true })
	end

	local ok, hits, total = pcall(search.search, d, q,
	    { limit = M.HITS, offset = offset })

	if not ok then
		return html(400, q, "<h1>Search</h1>\n<p class=\"note\">"
		    .. esc(hits) .. "</p>\n", { q = q })
	end

	local s = {}

	if hits[1] and hits[1].match == "some" then
		s[#s + 1] = "<p class=\"note\">No document holds all the words. "
		    .. "These hold some of them.</p>\n"
	end
	for _, h in ipairs(hits) do
		s[#s + 1] = ("<div class=\"hit\"><div class=\"title\">%s</div>\n"
		    .. "<p class=\"dim small\">%s, %s%s</p>\n"):format(
		    link(docurl(h.id), h.title), esc(h.author or "?"),
		    esc(day(h.updated)), h.pending and ", text pending" or "")
		if h.abstract then
			s[#s + 1] = "<p>" .. esc(h.abstract) .. "</p>\n"
		end
		for _, c in ipairs(h.chunks or {}) do
			local at = ""

			if c.page then
				at = link(docurl(h.id, nil, "p=" .. c.page),
				    "p" .. c.page) .. ": "
			elseif c.heading and c.heading ~= "" then
				at = "<span class=\"dim\">" .. esc(c.heading)
				    .. ":</span> "
			end
			s[#s + 1] = "<p class=\"small\">" .. at .. snippet(c.snippet)
			    .. "</p>\n"
		end
		s[#s + 1] = "</div>\n"
	end
	if #hits == 0 then
		s[#s + 1] = "<p>Nothing found.</p>\n"
	end
	s[#s + 1] = "<div class=\"pager dim\">"
	if offset > 0 then
		s[#s + 1] = link(searchurl(q, math.max(0, offset - M.HITS)),
		    "previous")
	end
	s[#s + 1] = ("<span>%d to %d of %d</span>"):format(
	    #hits > 0 and offset + 1 or 0, offset + #hits, total)
	if offset + #hits < total then
		s[#s + 1] = link(searchurl(q, offset + M.HITS), "next")
	end
	s[#s + 1] = "</div>\n"
	return html(200, q, table.concat(s), { q = q })
end

local function taglist(d, prefix)
	local s = { "<h1>Tags", prefix and (" under " .. esc(prefix)) or "",
	    "</h1>\n<ul class=\"plain\">\n" }
	local rows = search.tags(d, prefix)

	for _, r in ipairs(rows) do
		local depth = select(2, r.name:gsub("/", ""))

		s[#s + 1] = ("<li class=\"d%d\">%s "
		    .. "<span class=\"dim small\">%d</span>"):format(
		    math.min(depth, 6),
		    link(searchurl("tag:" .. r.name), r.name), r.count)
		if r.about then
			s[#s + 1] = " " .. link(docurl(r.about), "about", "small")
		end
		if r.scope then
			s[#s + 1] = " <span class=\"dim small\">" .. esc(r.scope)
			    .. "</span>"
		end
		s[#s + 1] = "</li>\n"
	end
	s[#s + 1] = "</ul>\n"
	if #rows == 0 then
		s[#s + 1] = "<p>No tags.</p>\n"
	end
	return html(200, "tags", table.concat(s))
end

local function wanted(d)
	local s = { "<h1>Wanted</h1>\n<p class=\"dim\">Titles that notes link "
	    .. "to and no document has.</p>\n<ul class=\"plain\">\n" }

	for _, r in ipairs(cli.wanted(d)) do
		local from = {}

		for id in r.srcs:gmatch("%S+") do
			local t = d:row("SELECT title FROM doc WHERE id = ?", { id })

			from[#from + 1] = link(docurl(id), t or id)
		end
		s[#s + 1] = ("<li><span class=\"wanted\">%s</span> <span "
		    .. "class=\"dim small\">from %s</span></li>\n"):format(
		    esc(r.title), table.concat(from, ", "))
	end
	s[#s + 1] = "</ul>\n"
	return html(200, "wanted", table.concat(s))
end

-- kind(mime) -> how the viewer shows a file: md, text, pdf, image,
-- media, or other
local function kind(mime)
	mime = mime or ""
	if mime == "text/markdown" then
		return "md"
	elseif mime:match("^text/") or mime == "application/json"
	    or mime == "application/xml" then
		return "text"
	elseif mime == "application/pdf" then
		return "pdf"
	elseif mime:match("^image/") then
		return "image"
	elseif mime:match("^audio/") or mime:match("^video/") then
		return "media"
	end
	return "other"
end

M.kind = kind

-- views of each kind; the first is the default
local VIEWS = {
	md = { "page", "source", "text" },
	text = { "source", "text" },
	pdf = { "file", "text" },
	image = { "file", "text" },
	media = { "file", "text" },
	other = { "text" },
}

-- metadata namespaces shown folded
local QUIET = { pdf = true, jev = true, gen = true }

local function metalist(meta, quiet)
	local keys, s = {}, {}

	for k in pairs(meta) do
		if (QUIET[k:match("^[^.]+")] or false) == quiet
		    and k ~= "dcterms.abstract" then
			keys[#keys + 1] = k
		end
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local x = meta[k]

		for _, y in ipairs(type(x) == "table" and x or { x }) do
			y = tostring(y)
			s[#s + 1] = ("<dt>%s</dt><dd>%s</dd>\n"):format(esc(k),
			    y:match("^https?://%S+$") and link(y, y) or esc(y))
		end
	end
	return table.concat(s), #keys
end

-- filebytes(d, v) -> the bytes of the file of a view
local function filebytes(d, v)
	local c = v.file and cid.parse(v.file)

	return c and d:get(c.bytes)
end

local function size(n)
	if not n then
		return "?"
	elseif n < 1024 then
		return n .. " B"
	elseif n < 1024 * 1024 then
		return ("%.1f KiB"):format(n / 1024)
	end
	return ("%.1f MiB"):format(n / 1024 / 1024)
end

-- pdfpage(frag) -> first page of a p=N or p=N-M fragment
local function pdfpage(frag)
	return frag and frag:match("^p=(%d+)")
end

local function doc(d, ref, q)
	local r, why = store.ref(d, ref)

	if not r then
		return fail(404, why)
	end

	local rev = r.rev
	local frag = q.at ~= "" and q.at or r.frag

	if ref ~= r.doc .. (rev and ("@" .. rev) or "") then
		return redirect(docurl(r.doc, r.pin and rev or nil, frag))
	end

	local id = r.doc
	local head = store.doc(d, id)
	local page = math.tointeger(tonumber(q.page))
	local v = cli.view(d, id, rev, page, frag)
	local k = v.file and kind(v.mime) or "none"

	local views = VIEWS[k] or {}
	local view = views[1]

	for _, name in ipairs(views) do
		if q.view == name then
			view = name
		end
	end
	-- a heading fragment selects sections of the extracted text
	if frag and not pdfpage(frag) and not q.view and v.file then
		view = "text"
	end

	local s = { "<h1>", esc(v.title), "</h1>\n" }

	-- classifiers write as cairn:NAME; show who wrote the document
	local author = d:row("SELECT author FROM doc_version WHERE doc = ? "
	    .. "AND rev <= ? AND author NOT LIKE 'cairn:%' ORDER BY rev DESC "
	    .. "LIMIT 1", { id, v.rev }) or v.author

	s[#s + 1] = ("<p class=\"dim small\">%s, %s, rev %d%s</p>\n"):format(
	    esc(author or "?"), esc(day(v.created)), v.rev,
	    v.rev ~= head.rev and (" (" .. link(docurl(id), "current is rev "
	    .. head.rev) .. ")") or "")
	if v.hidden then
		s[#s + 1] = "<p class=\"note\">This document is hidden.</p>\n"
	end
	if v.superseded_by then
		s[#s + 1] = "<p class=\"note\">Superseded by "
		    .. link(docurl(v.superseded_by), d:row(
		    "SELECT title FROM doc WHERE id = ?", { v.superseded_by })
		    or v.superseded_by) .. ".</p>\n"
	end
	if v.about then
		s[#s + 1] = "<p class=\"note\">About page of the tag "
		    .. link(searchurl("tag:" .. v.about), v.about) .. ".</p>\n"
	end
	if #v.tags > 0 then
		s[#s + 1] = "<p class=\"tags\">"
		for _, t in ipairs(v.tags) do
			s[#s + 1] = link(searchurl("tag:" .. t), t)
		end
		s[#s + 1] = "</p>\n"
	end

	local abstract = v.meta["dcterms.abstract"]

	if abstract then
		s[#s + 1] = "<p class=\"abstract\">" .. esc(type(abstract)
		    == "table" and abstract[1] or abstract) .. "</p>\n"
	end

	if v.file then
		s[#s + 1] = "<div class=\"tabs\">"
		for _, name in ipairs(views) do
			s[#s + 1] = name == view and ("<b>" .. name .. "</b>")
			    or link(docurl(id, rev, frag, name), name)
		end
		s[#s + 1] = link(rawurl(id, rev), "raw") .. "</div>\n"
	end
	if frag and view == "text" then
		s[#s + 1] = "<p class=\"note\">Only the text at " .. esc(frag)
		    .. ". " .. link(docurl(id, rev, nil, "text"), "Show all")
		    .. ".</p>\n"
	end
	if v.pending then
		s[#s + 1] = "<p class=\"note\">Text extraction is pending.</p>\n"
	end

	local raw = rawurl(id, rev)

	if view == "page" then
		s[#s + 1] = "<article>\n" .. md.render(filebytes(d, v) or "", {
			wiki = function(t)
				return refurl(d, t)
			end,
			link = function(u)
				return refurl(d, u)
			end,
			image = function(u)
				local t = store.ref(d, u)

				return t and rawurl(t.doc, t.pin and t.rev or nil)
			end,
		}) .. "</article>\n"
	elseif view == "source" then
		s[#s + 1] = "<pre class=\"text\">" .. esc(filebytes(d, v) or "")
		    .. "</pre>\n"
	elseif view == "file" and k == "pdf" then
		local p = pdfpage(frag)

		s[#s + 1] = ("<iframe class=\"file\" src=\"%s%s\" title=\"%s\">"
		    .. "</iframe>\n"):format(esc(raw), p and ("#page=" .. p) or "",
		    esc(v.title))
	elseif view == "file" and k == "image" then
		s[#s + 1] = ("<p><a href=\"%s\"><img src=\"%s\" alt=\"%s\"></a>"
		    .. "</p>\n"):format(esc(raw), esc(raw), esc(v.title))
	elseif view == "file" and k == "media" then
		local tag = v.mime:match("^audio/") and "audio" or "video"

		s[#s + 1] = ("<p><%s controls src=\"%s\"></%s></p>\n"):format(tag,
		    esc(raw), tag)
	elseif view == "text" then
		s[#s + 1] = "<pre class=\"text\">" .. esc(v.text or "") .. "</pre>\n"
		if (v.pages or 1) > 1 then
			s[#s + 1] = "<div class=\"pager dim\">"
			if v.page > 1 then
				s[#s + 1] = link(docurl(id, rev, frag, "text", v.page - 1),
				    "previous")
			end
			s[#s + 1] = ("<span>page %d of %d</span>"):format(v.page,
			    v.pages)
			if v.page < v.pages then
				s[#s + 1] = link(docurl(id, rev, frag, "text", v.page + 1),
				    "next")
			end
			s[#s + 1] = "</div>\n"
		end
	end

	s[#s + 1] = "<footer>\n"

	local function rows(title, list, fn)
		if #list == 0 then
			return
		end
		s[#s + 1] = "<h3>" .. title .. "</h3>\n<ul class=\"plain\">\n"
		for _, x in ipairs(list) do
			s[#s + 1] = "<li>" .. fn(x) .. "</li>\n"
		end
		s[#s + 1] = "</ul>\n"
	end

	rows("Links", v.links, function(l)
		return ("<span class=\"dim small\">%s</span> %s%s%s"):format(
		    esc(l.rel), link(docurl(l.doc, l.pin and l.at_rev or nil,
		    l.frag), l.title or l.doc),
		    l.pin and (" <span class=\"dim small\">fixed at rev "
		    .. (l.at_rev or "?") .. "</span>") or "",
		    l.changed and (" <span class=\"dim small\">changed since "
		    .. "linked, rev " .. l.at_rev .. " to " .. l.rev .. "</span>")
		    or "")
	end)
	rows("Linked from", v.backlinks, function(l)
		return ("<span class=\"dim small\">%s</span> %s"):format(esc(l.rel),
		    link(docurl(l.doc), l.title or l.doc))
	end)
	rows("Similar", v.similar or {}, function(x)
		return ("<span class=\"dim small\">%.2f</span> %s"):format(x.score,
		    link(docurl(x.id), x.title))
	end)

	local shown = metalist(v.meta, false)
	local folded, nfolded = metalist(v.meta, true)

	s[#s + 1] = "<h3>Details</h3>\n<dl class=\"meta\">\n"
	s[#s + 1] = ("<dt>uri</dt><dd><code>%s</code></dd>\n"):format(
	    esc(store.uri(id, rev)))
	s[#s + 1] = ("<dt>cid</dt><dd><code>%s</code></dd>\n"):format(esc(v.cid))
	if v.file then
		s[#s + 1] = ("<dt>file</dt><dd>%s, %s%s<br><code>%s</code></dd>\n")
		    :format(esc(v.mime or "?"), size(v.size),
		    v.name and (", " .. esc(v.name)) or "", esc(v.file))
	end
	s[#s + 1] = shown .. "</dl>\n"
	if nfolded > 0 then
		s[#s + 1] = "<details><summary>More metadata</summary>\n"
		    .. "<dl class=\"meta\">\n" .. folded .. "</dl></details>\n"
	end

	local revs = d:rows("SELECT rev, author, created FROM doc_version "
	    .. "WHERE doc = ? ORDER BY rev DESC", { id })

	if #revs > 1 then
		s[#s + 1] = ("<details><summary>%d versions</summary>\n"
		    .. "<ul class=\"plain\">\n"):format(#revs)
		for _, x in ipairs(revs) do
			s[#s + 1] = ("<li>%s <span class=\"dim small\">%s, %s</span>"
			    .. "</li>\n"):format(x.rev == v.rev
			    and ("<b>rev " .. x.rev .. "</b>")
			    or link(docurl(id, x.rev), "rev " .. x.rev),
			    esc(x.author or "?"), esc(x.created))
		end
		s[#s + 1] = "</ul></details>\n"
	end
	s[#s + 1] = "</footer>\n"
	return html(200, v.title, table.concat(s),
	    { wide = view == "file" and k == "pdf" })
end

-- types a browser shows in place and does not run
local INLINE = { ["application/pdf"] = true, ["image/png"] = true,
    ["image/jpeg"] = true, ["image/gif"] = true, ["image/webp"] = true,
    ["image/avif"] = true, ["image/bmp"] = true }

-- rawtype(mime) -> Content-Type and Content-Disposition kind for a
-- stored file. Text goes out as plain text, so stored HTML never runs.
local function rawtype(mime)
	mime = mime or "application/octet-stream"
	if INLINE[mime] or mime:match("^audio/") or mime:match("^video/")
	    or mime == "image/svg+xml" then
		return mime, "inline"
	elseif kind(mime) == "md" or kind(mime) == "text" then
		return "text/plain; charset=utf-8", "inline"
	end
	return "application/octet-stream", "attachment"
end

M.rawtype = rawtype

local function raw(d, ref, req)
	local r, why = store.ref(d, ref)

	if not r then
		return fail(404, why)
	end

	local v = cli.view(d, r.doc, r.rev, nil, nil, nil, nil, true)
	local data = filebytes(d, v)

	if not data then
		return fail(404, "no file for " .. r.doc)
	end

	local ctype, disp = rawtype(v.mime)
	local etag = '"' .. v.file .. '"'
	local name = (v.name or r.doc):gsub("[^%w%._ -]", "_")
	local h = {
		["Content-Type"] = ctype,
		["Content-Disposition"] = ('%s; filename="%s"'):format(disp, name),
		["X-Content-Type-Options"] = "nosniff",
		["Cache-Control"] = "private, no-cache",
		ETag = etag,
	}

	-- a PDF viewer needs its own scripts; every other type is shut in
	if ctype ~= "application/pdf" then
		h["Content-Security-Policy"] = "default-src 'none'; sandbox"
	end
	if req.inm == etag then
		return 304, h, ""
	end
	return 200, h, data
end

-- handle(d, req, cfg) -> status, headers, body. req has method, path
-- (decoded), query (a table by name), host, and inm (If-None-Match).
-- cfg.hosts, when set, holds the Host values the server answers to.
function M.handle(d, req, cfg)
	if cfg and cfg.hosts and not cfg.hosts[(req.host or ""):lower()] then
		return 403, { ["Content-Type"] = "text/plain" }, "bad host\n"
	end
	if req.method ~= "GET" and req.method ~= "HEAD" then
		return 405, { Allow = "GET, HEAD", ["Content-Type"] = "text/plain" },
		    "read only\n"
	end

	local path, q = req.path, req.query or {}
	local ok, status, h, body = pcall(function()
		if path == "/" then
			return front(d)
		elseif path == "/style.css" then
			return 200, { ["Content-Type"] = "text/css; charset=utf-8",
			    ["Cache-Control"] = "no-cache" }, M.STYLE
		elseif path == "/search" then
			return results(d, q.q or "",
			    math.max(0, math.tointeger(tonumber(q.offset)) or 0))
		elseif path == "/tags" or path == "/tags/" then
			return taglist(d, nil)
		elseif path:match("^/tags/.") then
			return taglist(d, path:sub(7))
		elseif path == "/wanted" then
			return wanted(d)
		elseif path:match("^/d/.") then
			return doc(d, path:sub(4), q)
		elseif path:match("^/raw/.") then
			return raw(d, path:sub(6), req)
		end
		return fail(404, "no page " .. path)
	end)

	if not ok then
		local msg = tostring(status)

		return fail(msg:match("^no ") and 404 or 500, msg)
	end
	return status, h, body
end

local LOOPBACK = { ["127.0.0.1"] = true, ["::1"] = true,
    localhost = true }

-- address(s) -> host, port from "host:port", "[v6]:port", or "port"
function M.address(s)
	local host, port = s:match("^%[(.+)%]:(%d+)$")

	if not host then
		host, port = s:match("^([^:]+):(%d+)$")
	end
	if not host then
		host, port = "127.0.0.1", s:match("^(%d+)$")
	end
	if not port then
		return nil, "bad address " .. s .. "; use host:port"
	end
	return host, math.tointeger(tonumber(port))
end

-- serve(d, opts) listens and answers until the process ends. opts:
-- listen ("host:port"), and ready(url), called once the socket is open.
function M.serve(d, opts)
	local ok, server = pcall(require, "mhttp.server")

	if not ok then
		error("web needs the mhttp library", 0)
	end

	local poll = require "mhttp.io.poll"
	local url = require "mhttp.url"
	local host, port = M.address(opts.listen or M.LISTEN)

	if not host then
		error(port, 0)
	end

	local loop = poll.new()
	local l, err = loop:listen(host, port)

	if not l then
		error(("listen on %s: %s"):format(opts.listen or M.LISTEN, err), 0)
	end
	port = l:port()

	local cfg = {}

	-- on loopback, answer only to loopback names: a page of another
	-- site cannot then reach the store through a DNS name it controls
	if LOOPBACK[host] then
		cfg.hosts = {}
		for _, n in ipairs({ "127.0.0.1", "localhost", "[::1]" }) do
			cfg.hosts[n .. ":" .. port] = true
		end
	end

	local srv = server.new({ handler = function(req, res)
		local path = url.decode(req.path or "")

		if not path then
			return res:send(400, "bad path\n")
		end

		local status, h, body = M.handle(d, {
			method = req.method, path = path,
			query = url.query(req.query), host = req.headers:get("host"),
			inm = req.headers:get("if-none-match"),
		}, cfg)

		return res:send(status, body, h)
	end })

	loop:serve(l, srv)
	if opts.ready then
		opts.ready(("http://%s:%d"):format(host:find(":", 1, true)
		    and ("[" .. host .. "]") or host, port))
	end
	loop:run()
end

return M
