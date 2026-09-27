-- SPDX-License-Identifier: ISC
-- queue: extraction jobs. An enricher claims a job with a lease, renews
-- the lease while it works, and finishes only if it still holds it.

local util = require "cairn.util"

local M = {}

M.LEASE = 120
M.TRIES = 3

-- kinds an enricher runs; vision and transcript need --vision
M.BASIC = { "pdf", "ocr", "pandoc" }
M.VISION = { "vision", "transcript" }

local function until_(secs)
	return util.now(os.time() + (secs or M.LEASE))
end

function M.token()
	local host = util.readfile("/proc/sys/kernel/hostname") or "host"

	return ("%s:%d:%s"):format(host:gsub("%s", ""),
	    require("posix.unistd").getpid(), util.newid():sub(1, 8))
end

-- enqueue(d, file, kind) adds a pending job unless one exists
function M.enqueue(d, file, kind)
	d:run("INSERT OR IGNORE INTO job (file, kind, status, created) "
	    .. "VALUES (?, ?, 'pending', ?)", { file, kind, util.now() })
end

-- reclaim(d) returns running jobs with an expired lease to the queue
function M.reclaim(d)
	return d:run("UPDATE job SET status = CASE WHEN tries >= ? "
	    .. "THEN 'failed' ELSE 'pending' END, "
	    .. "error = coalesce(error, 'lease expired'), lease = NULL, "
	    .. "lease_until = NULL WHERE status = 'running' AND lease_until < ?",
	    { M.TRIES, util.now() })
end

-- claim(d, kinds, token) -> job { id, file, kind }, or nil
function M.claim(d, kinds, token)
	local marks = {}
	local args = { token, until_() }

	for i, k in ipairs(kinds) do
		marks[i] = "?"
		args[#args + 1] = k
	end

	local rows = d:rows("UPDATE job SET status = 'running', lease = ?, "
	    .. "lease_until = ?, tries = tries + 1 "
	    .. "WHERE id = (SELECT id FROM job WHERE status = 'pending' "
	    .. "AND kind IN (" .. table.concat(marks, ", ") .. ") "
	    .. "ORDER BY id LIMIT 1) RETURNING id, file, kind, tries", args)

	return rows[1]
end

-- renew(d, id, token) -> true while the lease is still ours
function M.renew(d, id, token)
	return d:run("UPDATE job SET lease_until = ? WHERE id = ? AND lease = ? "
	    .. "AND status = 'running'", { until_(), id, token }) > 0
end

-- finish(d, id, token, fn) marks the job done and runs fn in the same
-- transaction, only if the lease is still ours. Returns true if so.
function M.finish(d, id, token, fn)
	return d:tx(function()
		if d:run("UPDATE job SET status = 'done', lease = NULL, "
		    .. "lease_until = NULL, error = NULL WHERE id = ? AND lease = ? "
		    .. "AND status = 'running'", { id, token }) == 0 then
			return false
		end
		fn()
		return true
	end)
end

-- fail(d, id, token, err, final) puts the job back, or marks it failed
-- after the last try or when final is set
function M.fail(d, id, token, err, final)
	return d:run("UPDATE job SET status = CASE WHEN ? OR tries >= ? "
	    .. "THEN 'failed' ELSE 'pending' END, error = ?, lease = NULL, "
	    .. "lease_until = NULL WHERE id = ? AND lease = ?",
	    { final and 1 or 0, M.TRIES, tostring(err), id, token }) > 0
end

function M.retry_failed(d)
	return d:run("UPDATE job SET status = 'pending', tries = 0, error = NULL "
	    .. "WHERE status = 'failed'")
end

-- requeue(d, kind) sets done and failed jobs of a kind (or all) back to
-- pending
function M.requeue(d, kind)
	return d:run("UPDATE job SET status = 'pending', tries = 0, error = NULL "
	    .. "WHERE status IN ('done', 'failed') AND (? IS NULL OR kind = ?)",
	    { kind, kind, n = 2 })
end

-- status(d) -> list of { kind, status, count }
function M.status(d)
	return d:rows("SELECT kind, status, count(*) AS count FROM job "
	    .. "GROUP BY kind, status ORDER BY kind, status")
end

-- waiting(d, kinds) -> count of pending jobs of those kinds
function M.waiting(d, kinds)
	local marks, args = {}, {}

	for i, k in ipairs(kinds) do
		marks[i] = "?"
		args[i] = k
	end
	return d:row("SELECT count(*) FROM job WHERE status = 'pending' "
	    .. "AND kind IN (" .. table.concat(marks, ", ") .. ")", args)
end

return M
