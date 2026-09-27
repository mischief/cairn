-- chunk: split extracted text into chunks for the FTS index. A chunk
-- is { page = n|nil, heading = s|nil, body = s }.

local M = {}

-- about 2000 tokens of English
M.MAX = 8000

-- clean(s) -> s without NUL and other control bytes except \t \n \f.
-- A NUL cuts off FTS5 content.
function M.clean(s)
	return (s:gsub("[%z\1-\8\11\13-\31\127]", ""))
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

-- pages(s) -> chunks, one or more per form-feed separated page
function M.pages(s)
	s = M.clean(s)

	local out, n = {}, 0

	for page in (s .. "\f"):gmatch("([^\f]*)\f") do
		n = n + 1
		split(page, out, n, nil)
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
