-- SPDX-License-Identifier: ISC
-- chunk: split extracted text into chunks for the FTS index. A chunk
-- is { page = n|nil, heading = s|nil, body = s }.

local M = {}

-- about 2000 tokens of English
M.MAX = 8000

-- utf8(s) -> s with each byte that is not part of valid UTF-8 replaced
-- by U+FFFD. Extractors can emit other encodings, and JSON and FTS5
-- want UTF-8.
function M.utf8(s)
	if utf8.len(s) then
		return s
	end

	local out, i = {}, 1

	while i <= #s do
		local n, bad = utf8.len(s, i)

		if n then
			out[#out + 1] = s:sub(i)
			break
		end
		out[#out + 1] = s:sub(i, bad - 1)
		out[#out + 1] = "\u{FFFD}"
		i = bad + 1
	end
	return table.concat(out)
end

-- clean(s) -> valid UTF-8 without NUL and other control bytes except
-- \t \n \f. A NUL ends FTS5 content early.
function M.clean(s)
	return (M.utf8(s):gsub("[%z\1-\8\11\13-\31\127]", ""))
end

-- split a body longer than MAX at paragraph, then line, then any
-- boundary
local function split(body, out, page, heading)
	body = body:gsub("^%s+", ""):gsub("%s+$", "")
	if body == "" then
		return
	end
	while #body > M.MAX do
		local cut = body:sub(1, M.MAX)
		local at = cut:match(".*()\n\n") or cut:match(".*()\n")
		    or cut:match(".*() ") or M.MAX

		if at < M.MAX // 4 then
			at = M.MAX
		end
		out[#out + 1] = { page = page, heading = heading,
		    body = (body:sub(1, at):gsub("%s+$", "")) }
		body = body:sub(at + 1):gsub("^%s+", "")
	end
	if body ~= "" then
		out[#out + 1] = { page = page, heading = heading, body = body }
	end
end

-- markdown(s) -> chunks split at headings; heading holds the path,
-- such as "setup > wiring"
function M.markdown(s)
	s = M.clean(s)

	local out, path = {}, {}
	local body, heading = {}, nil
	local fence = false

	local function flush()
		split(table.concat(body, "\n"), out, nil, heading)
		body = {}
	end

	for line in (s .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("^```") or line:match("^~~~") then
			fence = not fence
		end

		local hashes, title = line:match("^(#+)%s+(.-)%s*#*%s*$")

		if not fence and hashes and #hashes <= 6 then
			flush()
			for i = #hashes, #path do
				path[i] = nil
			end
			path[#hashes] = title
			for i = 1, #hashes do
				path[i] = path[i] or ""
			end
			heading = table.concat(path, " > "):gsub("^[ >]+", "")
		else
			body[#body + 1] = line
		end
	end
	flush()
	return out
end

-- tidy(s) -> s without dot leaders, trailing blanks, or runs of empty
-- lines
function M.tidy(s)
	return (s:gsub("[ ]*%.[ ]?%.[ ]?%.[ ]?%.[ ]?%.[%. ]*", " ... ")
	    :gsub("[ \t]+\n", "\n"):gsub("[ \t]+$", ""):gsub("\n\n\n+", "\n\n"))
end

-- the lines at each end of a page where running heads and page
-- numbers sit
M.EDGE = 3

-- edge(page) -> the line indexes of the first and last EDGE lines that
-- hold text, and the lines
local function edge(page)
	local lines, full = {}, {}

	for l in (page .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = l
		if l:find("%S") then
			full[#full + 1] = #lines
		end
	end

	local at = {}

	for i = 1, math.min(M.EDGE, #full) do
		at[full[i]] = true
		at[full[#full + 1 - i]] = true
	end
	return at, lines
end

-- a running line compares equal across pages with its page number
local function norm(l)
	return (l:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
	    :gsub("%d+", "#"))
end

-- running(pages) -> pages without running heads, running feet, and page
-- numbers. A line counts as running when it sits at the edge of at
-- least 3 pages and 30% of them. Short documents stay as they are.
function M.running(pages)
	if #pages < 4 then
		return pages
	end

	local count = {}

	for _, p in ipairs(pages) do
		local at, lines = edge(p)
		local seen = {}

		for n in pairs(at) do
			local k = norm(lines[n])

			if not seen[k] then
				seen[k] = true
				count[k] = (count[k] or 0) + 1
			end
		end
	end

	local need = math.max(3, #pages * 0.3)
	local out = {}

	for i, p in ipairs(pages) do
		local at, lines = edge(p)
		local keep = {}

		for n, l in ipairs(lines) do
			local k = norm(l)

			if not (at[n] and (count[k] >= need or k == "#"
			    or k:match("^[ivx]+$") and #k <= 5)) then
				keep[#keep + 1] = l
			end
		end
		out[i] = table.concat(keep, "\n")
	end
	return out
end

-- pages(s) -> chunks, one or more per form-feed separated page, without
-- running heads and feet
function M.pages(s)
	local list = {}

	for page in (M.clean(s) .. "\f"):gmatch("([^\f]*)\f") do
		list[#list + 1] = page
	end
	if list[#list] == "" and #list > 1 then
		list[#list] = nil
	end

	local out = {}

	for n, page in ipairs(M.running(list)) do
		split(M.tidy(page), out, n, nil)
	end
	return out
end

-- plain(s) -> chunks of plain text
function M.plain(s)
	local out = {}

	split(M.clean(s), out, nil, nil)
	return out
end

-- weight(s) -> number of non-space characters, to judge an empty result
function M.weight(s)
	return #s:gsub("%s", "")
end

return M
