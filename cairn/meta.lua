-- SPDX-License-Identifier: ISC
-- meta: per-document metadata as namespace.name keys, such as
-- dcterms.date or pdf.Author. Values are text or lists of text.

local M = {}

M.MAXKEYS = 64
M.MAXVALUES = 32
M.MAXLEN = 2000

-- keys that already have a field of their own
M.RESERVED = {
	["dcterms.title"] = "the document title (cairn edit --title)",
	["dcterms.subject"] = "tags (cairn tag)",
	["dcterms.relation"] = "links (cairn link)",
}

-- keys whose values are EDTF dates
M.DATES = { ["dcterms.date"] = true, ["dcterms.issued"] = true,
    ["dcterms.created"] = true, ["dcterms.modified"] = true,
    ["dcterms.available"] = true, ["dcterms.valid"] = true }

-- key(s) -> s, or nil, reason
function M.key(s)
	if type(s) ~= "string"
	    or not s:match("^[a-z][a-z0-9%-]*%.[A-Za-z][A-Za-z0-9_%-]*$") then
		return nil, ("bad meta key %q: use namespace.name, such as "
		    .. "dcterms.date"):format(tostring(s))
	end
	if M.RESERVED[s] then
		return nil, s .. " is " .. M.RESERVED[s]
	end
	return s
end

-- one EDTF date, without intervals: YYYY[-MM[-DD]] with X for unknown
-- digits and a trailing ?, ~ or %. Returns its earliest form.
local function edtf1(s)
	local body = s:gsub("[%?~%%]$", "")
	local y, rest = body:match("^(%-?[%dX][%dX][%dX][%dX])(.*)$")

	if not y then
		return nil
	end

	local m, d = rest:match("^%-([%dX][%dX])%-([%dX][%dX])$")

	if not m then
		m = rest:match("^%-([%dX][%dX])$")
		if not m and rest ~= "" then
			return nil
		end
	end

	local start = y:gsub("X", "0")

	if m then
		local mm = m:gsub("X", "0")

		if tonumber(mm) > 12 then
			return nil
		end
		start = start .. "-" .. (mm == "00" and "01" or mm)
	end
	if d then
		local dd = d:gsub("X", "0")

		if tonumber(dd) > 31 then
			return nil
		end
		start = start .. "-" .. (dd == "00" and "01" or dd)
	end
	return start
end

-- edtf(s) -> earliest date as YYYY[-MM[-DD]], or nil, reason. Takes
-- the EDTF forms 1985, 1985-12, 1985-12-26, 1985?, 1985~, 198X, and
-- the interval 1985/1987 (either end may be ".." or empty).
function M.edtf(s)
	if type(s) ~= "string" then
		return nil, "date is not text"
	end

	local a, b = s:match("^([^/]*)/([^/]*)$")

	if a then
		local sa = (a == "" or a == "..") and "" or edtf1(a)
		local sb = (b == "" or b == "..") and "" or edtf1(b)

		if sa and sb then
			return sa
		end
	else
		local st = edtf1(s)

		if st then
			return st
		end
	end
	return nil, ("%q is not an EDTF date (1985, 1985-12, 1985-12-26, "
	    .. "1985?, 198X, 1985/1987)"):format(s)
end

-- clean(t) -> sorted list of { key, values = {...} }, or nil, reason
function M.clean(t)
	local out, n = {}, 0

	for k, v in pairs(t or {}) do
		local key, err = M.key(k)

		if not key then
			return nil, err
		end

		local vals = type(v) == "table" and v or { v }

		if #vals > M.MAXVALUES then
			return nil, key .. " has more than " .. M.MAXVALUES .. " values"
		end

		local list = {}

		for _, x in ipairs(vals) do
			if math.type(x) == "integer" then
				x = tostring(x)
			end
			if type(x) ~= "string" then
				return nil, key .. " values must be text"
			end
			x = x:match("^%s*(.-)%s*$")
			if #x > M.MAXLEN then
				return nil, key .. " value is over " .. M.MAXLEN .. " bytes"
			end
			if x ~= "" then
				if M.DATES[key] then
					local ok, why = M.edtf(x)

					if not ok then
						return nil, key .. ": " .. why
					end
				end
				list[#list + 1] = x
			end
		end
		if #list > 0 then
			n = n + 1
			out[#out + 1] = { key = key, values = list }
		end
	end
	if n > M.MAXKEYS then
		return nil, "more than " .. M.MAXKEYS .. " meta keys"
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

-- apply(t, changes) edits a meta table in place. Each change is
-- "key=value" (set), "key=" (remove), or "key+=value" (add to a list).
function M.apply(t, changes)
	for _, c in ipairs(changes) do
		local k, add, v = c:match("^([^=+]+)(%+?)=(.*)$")

		if not k then
			error(("bad meta change %q: use key=value, key=, or "
			    .. "key+=value"):format(c), 0)
		end

		local key, err = M.key(k)

		if not key then
			error(err, 0)
		end

		if v == "" and add == "" then
			t[key] = nil
		elseif add == "+" then
			local cur = t[key]
			local list = type(cur) == "table" and cur or { cur }

			list[#list + 1] = v
			t[key] = list
		else
			t[key] = v
		end
	end
	return t
end

-- from the PDF Info fields: raw values under pdf.*, and guesses for
-- dcterms keys that are not set. PDF Creator is the program, not the
-- person; the person is Author.
M.PDFINFO = { "Title", "Author", "Subject", "Keywords", "Creator",
    "Producer", "CreationDate", "ModDate" }

-- pdfinfo(text) -> table of pdf.* keys from `pdfinfo -isodates` output
function M.pdfinfo(text)
	local out = {}

	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		-- [ \t] and not %s: an empty field must not reach the next line
		local f, v = line:match("^(%a+):[ \t]*(.-)[ \t]*$")

		if f and v ~= "" then
			for _, want in ipairs(M.PDFINFO) do
				if f == want then
					out["pdf." .. f] = v
				end
			end
		end
	end
	return out
end

-- guess(t) copies pdf.Author to dcterms.creator when that is unset and
-- the author holds at least two letters in a row
function M.guess(t)
	local a = t["pdf.Author"]

	if a and a:find("%a%a") and not t["dcterms.creator"] then
		t["dcterms.creator"] = t["pdf.Author"]
	end
	return t
end

return M
