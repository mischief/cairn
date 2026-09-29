-- SPDX-License-Identifier: ISC
-- enrich: drain the extraction queue. Extractors run with no write
-- transaction open; results go in with one short transaction.

local fcntl = require "posix.fcntl"

local config = require "cairn.config"
local extract = require "cairn.extract"
local queue = require "cairn.queue"
local secret = require "cairn.secret"
local store = require "cairn.store"

local M = {}

-- lock(path) -> fd while no other enricher holds the lock, or nil
function M.lock(path)
	local fd = fcntl.open(path, fcntl.O_RDWR | fcntl.O_CREAT, 384)

	if not fd then
		return nil
	end
	if not fcntl.fcntl(fd, fcntl.F_SETLK, { l_type = fcntl.F_WRLCK,
	    l_whence = 0, l_start = 0, l_len = 0 }) then
		require("posix.unistd").close(fd)
		return nil
	end
	return fd
end

-- held(path) -> true when an enricher holds the lock
function M.held(path)
	local fd = M.lock(path)

	if fd then
		require("posix.unistd").close(fd)
		return false
	end
	return true
end

local function one(d, job, token, opts, log)
	local mime = d:row("SELECT mime FROM file WHERE id = ?", { job.file })
	local data = store.content(d, job.file)

	if not data then
		queue.fail(d, job.id, token, "file block is missing", true)
		return
	end

	local xopts = {
		model = opts.model,
		url = opts.url,
		every = 30,
		tick = function()
			if not queue.renew(d, job.id, token) then
				error("lease lost", 0)
			end
		end,
	}
	local ok, chunks, needocr = pcall(function()
		if job.kind == "pdf" then
			return extract.pdf(data, xopts)
		end
		return extract[job.kind](data, mime, xopts)
	end)

	if not ok then
		log(("job %d %s: %s"):format(job.id, job.kind, chunks))
		if tostring(chunks):match("is not installed") then
			queue.defer(d, job.id, token, chunks)
			return "missing"
		end
		queue.fail(d, job.id, token, chunks)
		return
	end
	-- a chunk that looks like it holds a secret stays out of the index;
	-- the rest of the file is still searchable
	local kept, dropped = {}, 0

	for _, c in ipairs(chunks) do
		local bad = secret.check(c.body)

		if bad then
			dropped = dropped + 1
			log(("job %d %s: chunk %s left out, %s"):format(job.id,
			    job.kind, c.page and ("page " .. c.page) or tostring(c.seq
			    or dropped), bad))
		else
			kept[#kept + 1] = c
		end
	end
	if dropped > 0 and #kept == 0 then
		queue.fail(d, job.id, token, "refused: every chunk looks like it "
		    .. "holds a secret", true)
		return
	end
	chunks = kept

	local extractor = ({ pdf = "pdftotext", ocr = "tesseract",
	    vision = "lgml:" .. opts.model,
	    transcript = "lgml:transcribe", pandoc = "pandoc" })[job.kind]

	if queue.finish(d, job.id, token, function()
		store.index(d, job.file, job.kind, extractor,
		    extract.VERSION[job.kind], chunks)
		if needocr then
			queue.enqueue(d, job.file, "ocr")
		end
	end) then
		log(("job %d %s: %d chunks%s"):format(job.id, job.kind, #chunks,
		    needocr and ", no text layer, ocr queued" or ""))
	else
		log(("job %d %s: lease lost, result dropped"):format(job.id,
		    job.kind))
	end
end

-- run(d, opts, log) drains the queue. opts: kinds (queue.BASIC by
-- default), model, max. Returns the number of jobs it took.
function M.run(d, opts, log)
	log = log or function() end

	local kinds = opts.kinds or queue.BASIC

	opts.model = opts.model or config.get(d, "lgml.model")
	opts.url = opts.url or config.get(d, "lgml.url")

	local token = queue.token()
	local n = 0

	-- a tool installed since the last run brings its jobs back
	queue.revive(d)

	while not opts.max or n < opts.max do
		queue.reclaim(d)

		local job = queue.claim(d, kinds, token)

		if not job then
			break
		end
		n = n + 1
		if one(d, job, token, opts, log) == "missing" then
			-- skip the kind for the rest of this run; its jobs wait
			local rest = {}

			for _, k in ipairs(kinds) do
				if k ~= job.kind then
					rest[#rest + 1] = k
				end
			end
			kinds = rest
			if #kinds == 0 then
				break
			end
		end
	end
	return n
end

return M
