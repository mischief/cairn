-- SPDX-License-Identifier: ISC
-- md: markdown to HTML for the notes cairn stores. It knows headings,
-- paragraphs, fenced code, quotes, lists, tables, rules, and the usual
-- inline marks. Raw HTML in the source is escaped, never passed on.

local M = {}

local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
    ['"'] = "&quot;", ["'"] = "&#39;" }

-- escape(s) -> s safe as HTML text or as an attribute value
function M.escape(s)
	return (tostring(s):gsub("[&<>\"']", ESC))
end

local esc = M.escape

-- slug(s) -> an id for a heading
function M.slug(s)
	return (s:lower():gsub("[^%w%s-]", ""):gsub("%s+", "-"))
end

-- safeurl(u) -> u when a browser may follow it from a note, else nil
local function safeurl(u)
	if u:match("^https?://") or u:match("^mailto:") or u:match("^#") then
		return u
	end
	return nil
end

-- href(o, u) -> the address for a link target, or nil. o.link maps a
-- cairn: URI to an address.
local function href(o, u)
	if u:match("^cairn:") then
		return o.link and o.link(u) or nil
	end
	return safeurl(u)
end

local function anchor(o, u, label)
	local h = href(o, u)

	if not h then
		return label
	end
	return ('<a href="%s">%s</a>'):format(esc(h), label)
end

local inline

-- closer(s, i, mark) -> start of the next mark at or after i that ends
-- a span: it does not follow a space. An "_" mark also ends at a word
-- boundary, so snake_case names stay whole.
local function closer(s, i, mark)
	local at = i

	while true do
		local a, b = s:find(mark, at, true)

		if not a then
			return nil
		end

		local before, after = s:sub(a - 1, a - 1), s:sub(b + 1, b + 1)

		if a > i and not before:match("%s") and before ~= "\\"
		    and (mark:sub(1, 1) ~= "_" or not after:match("[%w_]")) then
			return a
		end
		at = a + 1
	end
end

local SPANS = { { "**", "strong" }, { "__", "strong" }, { "~~", "del" },
    { "*", "em" }, { "_", "em" } }

-- inline(s, o) -> HTML for the marks inside one block
function inline(s, o)
	local out, i, n = {}, 1, #s
	local text = i

	local function flush(upto)
		if upto >= text then
			out[#out + 1] = esc(s:sub(text, upto))
		end
	end

	while i <= n do
		local c = s:sub(i, i)
		local a, b, x, y

		if c == "\\" then
			if s:sub(i + 1, i + 1) == "\n" then
				flush(i - 1)
				out[#out + 1] = "<br>\n"
				i = i + 2
				text = i
			elseif s:sub(i + 1, i + 1):match("%p") then
				flush(i - 1)
				out[#out + 1] = esc(s:sub(i + 1, i + 1))
				i = i + 2
				text = i
			else
				i = i + 1
			end
			goto continue
		end

		if c == "`" then
			local ticks = s:match("^`+", i)

			a, b = s:find(ticks, i + #ticks, true)
			-- the closing run has the same length
			while a and s:sub(b + 1, b + 1) == "`" do
				b = s:match("^`+()", a) - 1
				a, b = s:find(ticks, b + 1, true)
			end
			if a then
				flush(i - 1)
				out[#out + 1] = "<code>" .. esc(s:sub(i + #ticks, a - 1)
				    :gsub("^ (.+) $", "%1")) .. "</code>"
				i = b + 1
				text = i
				goto continue
			end
			i = i + #ticks
			goto continue
		end

		if c == "[" and s:sub(i + 1, i + 1) == "[" then
			a, b, x = s:find("^%[%[([^%]\n]+)%]%]", i)
			if a then
				local target, label = x:match("^([^|]*)|(.*)$")

				target = (target or x):match("^%s*(.-)%s*$")
				label = esc(label or target)
				flush(i - 1)

				local h = o.wiki and o.wiki(target)

				if h then
					out[#out + 1] = ('<a class="wiki" href="%s">%s</a>')
					    :format(esc(h), label)
				else
					out[#out + 1] = ('<span class="wanted">%s</span>')
					    :format(label)
				end
				i = b + 1
				text = i
				goto continue
			end
		end

		if c == "[" or (c == "!" and s:sub(i + 1, i + 1) == "[") then
			local at = c == "!" and i + 1 or i

			a, b, x, y = s:find("^(%b[])(%b())", at)
			if a then
				local label = x:sub(2, -2)
				local u = y:sub(2, -2):match("^%s*<?([^%s>]*)")

				flush(i - 1)
				if c == "!" then
					local h = u:match("^cairn:") and o.image and o.image(u)

					if h then
						out[#out + 1] = ('<img src="%s" alt="%s">'):format(
						    esc(h), esc(label))
					else
						out[#out + 1] = anchor(o, u, esc(label))
					end
				else
					out[#out + 1] = anchor(o, u, inline(label, o))
				end
				i = b + 1
				text = i
				goto continue
			end
		end

		if c == "<" then
			a, b, x = s:find("^<(%a[%w+.-]*:[^%s<>]+)>", i)
			if a then
				flush(i - 1)
				out[#out + 1] = anchor(o, x, esc(x))
				i = b + 1
				text = i
				goto continue
			end
		end

		-- a bare address, when it starts a word
		if (c == "h" or c == "c") and not s:sub(i - 1, i - 1):match("[%w_]")
		    then
			a, b = s:find("^https?://[^%s<>]+", i)
			if not a then
				a, b = s:find("^cairn:[a-z2-7]+[^%s<>]*", i)
			end
			if a then
				-- punctuation at the end belongs to the sentence
				local u = s:sub(a, b):gsub("[.,;:!?'\"]+$", "")

				if u:sub(-1) == ")" and not u:find("(", 1, true) then
					u = u:sub(1, -2)
				end
				flush(i - 1)
				out[#out + 1] = anchor(o, u, esc(u))
				i = a + #u
				text = i
				goto continue
			end
		end

		if c == "*" or c == "_" or c == "~" then
			local prev = s:sub(i - 1, i - 1)

			for _, sp in ipairs(SPANS) do
				local mark, tag = sp[1], sp[2]

				if s:sub(i, i + #mark - 1) == mark
				    and not s:sub(i + #mark, i + #mark):match("^%s?$")
				    and (c ~= "_" or not prev:match("[%w_]")) then
					a = closer(s, i + #mark, mark)
					if a then
						flush(i - 1)
						out[#out + 1] = ("<%s>%s</%s>"):format(tag,
						    inline(s:sub(i + #mark, a - 1), o), tag)
						i = a + #mark
						text = i
						goto continue
					end
				end
			end
			-- a run of marks with no partner is text
			i = s:match("^[*_~]+()", i)
			goto continue
		end

		if c == " " and s:find("^  +\n", i) then
			flush(i - 1)
			out[#out + 1] = "<br>\n"
			i = s:match("^ +\n()", i)
			text = i
			goto continue
		end

		i = i + 1
		::continue::
	end
	flush(n)
	return table.concat(out)
end

-- inline(s, o) -> HTML for one line of marked text
function M.inline(s, o)
	return inline(s, o or {})
end

local function isrule(l)
	local c = l:match("^ ? ? ?([-*_])")

	if not c then
		return false
	end

	local body = l:gsub("%s", "")

	return #body >= 3 and body == c:rep(#body)
end

local function fence(l)
	local ind, mark, info = l:match("^( ? ? ?)(```+)%s*([^`]*)$")

	if not mark then
		ind, mark, info = l:match("^( ? ? ?)(~~~+)%s*(.*)$")
	end
	return mark, info, ind
end

-- item(l) -> indent, marker width, ordered start or false, rest
local function item(l)
	local ind, mark, rest = l:match("^(%s*)([-*+])%s+(.*)$")

	if ind then
		return #ind, #mark + 1, false, rest
	end

	local num

	ind, num, rest = l:match("^(%s*)(%d+)[.)]%s+(.*)$")
	if ind and #num < 10 then
		return #ind, #num + 2, tonumber(num), rest
	end
	return nil
end

local function isdelim(l)
	return l:find("-", 1, true) and l:find("|", 1, true)
	    and l:match("^[%s|:-]+$") ~= nil
end

-- cells(l) -> the cells of a table row
local function cells(l)
	local out = {}

	l = l:match("^%s*|?(.-)|?%s*$")
	-- a "\|" is a bar inside a cell
	l = l:gsub("\\|", "\1")
	for c in (l .. "|"):gmatch("([^|]*)|") do
		out[#out + 1] = c:gsub("\1", "|"):match("^%s*(.-)%s*$")
	end
	return out
end

-- starts(l) -> true when line l opens a block that ends a paragraph
local function starts(l)
	return l:match("^ ? ? ?#+%s") or l:match("^ ? ? ?>") or fence(l)
	    or isrule(l) or item(l)
end

local blocks

local function list(lines, i, out, o)
	local base, _, ordered = item(lines[i])
	local items, loose = {}, false
	local n = #lines

	while i <= n do
		local ind, width, ord, rest = item(lines[i])

		if not ind or ind > base + 1 or (ord ~= false) ~= (ordered ~= false)
		    then
			break
		end

		local body, blank = { rest }, false
		local inner = ind + width

		i = i + 1
		while i <= n do
			local l = lines[i]

			if l:match("^%s*$") then
				blank = true
				body[#body + 1] = ""
				i = i + 1
			else
				local lead = #l:match("^%s*")

				if lead >= math.min(inner, base + 2) then
					body[#body + 1] = l:sub(math.min(lead, inner) + 1)
				elseif not blank and not starts(l) then
					-- a lazy line goes on with the paragraph
					body[#body + 1] = l
				else
					break
				end
				if blank and lead >= math.min(inner, base + 2) then
					loose = true
				end
				blank = false
				i = i + 1
			end
		end
		while body[#body] == "" do
			body[#body] = nil
		end
		-- a blank line between two items makes the list loose
		if blank and i <= n then
			local nind, _, nord = item(lines[i])

			if nind == base and (nord ~= false) == (ordered ~= false) then
				loose = true
			end
		end
		items[#items + 1] = body
	end

	local tag = ordered and "ol" or "ul"

	if ordered and ordered ~= 1 then
		out[#out + 1] = ('<ol start="%d">\n'):format(ordered)
	else
		out[#out + 1] = "<" .. tag .. ">\n"
	end
	for _, body in ipairs(items) do
		local sub = {}

		blocks(body, sub, o, not loose)
		out[#out + 1] = "<li>" .. table.concat(sub):gsub("\n$", "")
		    .. "</li>\n"
	end
	out[#out + 1] = "</" .. tag .. ">\n"
	return i
end

-- blocks(lines, out, o, tight) appends the HTML of lines to out. A
-- tight list item leaves its paragraphs bare.
function blocks(lines, out, o, tight)
	local i, n = 1, #lines

	while i <= n do
		local l = lines[i]
		local mark, info, ind = fence(l)

		if l:match("^%s*$") then
			i = i + 1
		elseif mark then
			local code = {}

			i = i + 1
			while i <= n do
				local m, rest = lines[i]:match("^ ? ? ?([`~]+)%s*(.*)$")

				if m and rest == "" and #m >= #mark
				    and m:sub(1, 1) == mark:sub(1, 1) then
					i = i + 1
					break
				end
				-- drop the indent of the opening fence
				code[#code + 1] = lines[i]:gsub("^" .. (" ?"):rep(#ind), "")
				i = i + 1
			end

			local lang = info:match("^([%w_+#.-]+)")

			out[#out + 1] = ("<pre><code%s>%s\n</code></pre>\n"):format(
			    lang and (' class="language-' .. esc(lang) .. '"') or "",
			    esc(table.concat(code, "\n")))
		elseif l:match("^ ? ? ?#+%s") or l:match("^ ? ? ?#+$") then
			local h, text = l:match("^ ? ? ?(#+)%s*(.-)%s*$")

			if #h <= 6 then
				text = text:gsub("%s+#+$", ""):gsub("^#+$", "")
				out[#out + 1] = ('<h%d id="%s">%s</h%d>\n'):format(#h,
				    esc(M.slug(text)), inline(text, o), #h)
			else
				out[#out + 1] = "<p>" .. inline(l, o) .. "</p>\n"
			end
			i = i + 1
		elseif isrule(l) then
			out[#out + 1] = "<hr>\n"
			i = i + 1
		elseif l:match("^ ? ? ?>") then
			local quote = {}

			while i <= n and not lines[i]:match("^%s*$") do
				local q = lines[i]:match("^ ? ? ?> ?(.*)$")

				if not q and starts(lines[i]) then
					break
				end
				quote[#quote + 1] = q or lines[i]
				i = i + 1
			end
			out[#out + 1] = "<blockquote>\n"
			blocks(quote, out, o)
			out[#out + 1] = "</blockquote>\n"
		elseif item(l) then
			i = list(lines, i, out, o)
		elseif l:find("|", 1, true) and lines[i + 1]
		    and isdelim(lines[i + 1])
		    and #cells(l) == #cells(lines[i + 1]) then
			local align, cols = {}, #cells(l)

			for k, c in ipairs(cells(lines[i + 1])) do
				local left, right = c:sub(1, 1) == ":", c:sub(-1) == ":"

				align[k] = left and right and "center" or right and "right"
				    or left and "left" or nil
			end

			local function row(tag, cs)
				out[#out + 1] = "<tr>"
				for k = 1, cols do
					out[#out + 1] = ("<%s%s>%s</%s>"):format(tag, align[k]
					    and (' class="' .. align[k] .. '"') or "",
					    inline(cs[k] or "", o), tag)
				end
				out[#out + 1] = "</tr>\n"
			end

			out[#out + 1] = "<table>\n<thead>\n"
			row("th", cells(l))
			out[#out + 1] = "</thead>\n<tbody>\n"
			i = i + 2
			while i <= n and lines[i]:find("|", 1, true)
			    and not lines[i]:match("^%s*$") do
				row("td", cells(lines[i]))
				i = i + 1
			end
			out[#out + 1] = "</tbody>\n</table>\n"
		else
			local para = { (l:gsub("^%s+", "")) }

			i = i + 1
			while i <= n and not lines[i]:match("^%s*$")
			    and not starts(lines[i]) do
				para[#para + 1] = (lines[i]:gsub("^%s+", ""))
				i = i + 1
			end

			local text = inline(table.concat(para, "\n"):gsub("%s+$", ""), o)

			out[#out + 1] = tight and (text .. "\n")
			    or ("<p>" .. text .. "</p>\n")
		end
	end
end

-- render(text, o) -> HTML. o.wiki(target) gives the address of a
-- [[target]] link, or nil when no document has it. o.link(uri) gives
-- the address of a cairn: URI. o.image(uri) gives the address of the
-- file of a cairn: URI, for an image.
function M.render(text, o)
	local lines, out = {}, {}

	text = text:gsub("\r\n?", "\n"):gsub("\t", "    ")
	for l in (text .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = l
	end
	blocks(lines, out, o or {})
	return table.concat(out)
end

return M
