-- SPDX-License-Identifier: ISC
-- schema: the cairn database layout, one entry per schema version.
-- migrations[n] takes a database at user_version n-1 to n. DESIGN.md
-- explains each table.

local M = {}

-- "CARN", in PRAGMA application_id
M.APPLICATION_ID = 0x4341524e

-- set on an empty file, before the first table
M.PRAGMAS_NEW = {
	"PRAGMA page_size = 8192",
	"PRAGMA auto_vacuum = INCREMENTAL",
}

-- set on every connection
M.PRAGMAS = {
	"PRAGMA synchronous = NORMAL",
	"PRAGMA foreign_keys = ON",
	"PRAGMA busy_timeout = 5000",
	"PRAGMA journal_size_limit = 67108864",
}

M.migrations = {}

M.migrations[1] = [[
CREATE TABLE cid (
	id INTEGER PRIMARY KEY,
	cid BLOB NOT NULL UNIQUE
);

CREATE TABLE block (
	id INTEGER PRIMARY KEY REFERENCES cid (id),
	codec INTEGER NOT NULL,
	size INTEGER NOT NULL,
	data BLOB NOT NULL
);

CREATE TABLE ref (
	parent INTEGER NOT NULL REFERENCES cid (id),
	child INTEGER NOT NULL REFERENCES cid (id),
	PRIMARY KEY (parent, child)
) WITHOUT ROWID;
CREATE INDEX ref_child ON ref (child);

CREATE TABLE file (
	id INTEGER PRIMARY KEY REFERENCES cid (id),
	size INTEGER NOT NULL,
	mime TEXT
);

CREATE TABLE doc (
	n INTEGER PRIMARY KEY,
	id TEXT NOT NULL UNIQUE,
	head INTEGER NOT NULL REFERENCES cid (id),
	rev INTEGER NOT NULL,
	title TEXT NOT NULL,
	mime TEXT,
	content INTEGER REFERENCES file (id),
	about TEXT,
	hidden INTEGER NOT NULL DEFAULT 0,
	author TEXT,
	created TEXT NOT NULL,
	updated TEXT NOT NULL,
	superseded_by TEXT REFERENCES doc (id)
);
CREATE INDEX doc_content ON doc (content);
CREATE INDEX doc_updated ON doc (updated);
CREATE INDEX doc_about ON doc (about) WHERE about IS NOT NULL;

CREATE TABLE doc_version (
	doc TEXT NOT NULL REFERENCES doc (id),
	rev INTEGER NOT NULL,
	node INTEGER NOT NULL REFERENCES cid (id),
	author TEXT,
	created TEXT NOT NULL,
	PRIMARY KEY (doc, rev)
) WITHOUT ROWID;
CREATE INDEX doc_version_created ON doc_version (created);

CREATE TABLE tag (
	doc TEXT NOT NULL REFERENCES doc (id),
	name TEXT NOT NULL,
	PRIMARY KEY (doc, name)
) WITHOUT ROWID;
CREATE INDEX tag_name ON tag (name);

CREATE TABLE tag_alias (
	alias TEXT PRIMARY KEY,
	name TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE usage (
	author TEXT NOT NULL,
	day TEXT NOT NULL,
	bytes INTEGER NOT NULL,
	PRIMARY KEY (author, day)
) WITHOUT ROWID;

CREATE TABLE link (
	src TEXT NOT NULL REFERENCES doc (id),
	dst TEXT NOT NULL REFERENCES doc (id),
	rel TEXT NOT NULL,
	PRIMARY KEY (src, dst, rel)
) WITHOUT ROWID;
CREATE INDEX link_dst ON link (dst, rel);

CREATE TABLE job (
	id INTEGER PRIMARY KEY,
	file INTEGER NOT NULL REFERENCES file (id),
	kind TEXT NOT NULL,
	status TEXT NOT NULL,
	lease TEXT,
	lease_until TEXT,
	tries INTEGER NOT NULL DEFAULT 0,
	error TEXT,
	created TEXT NOT NULL,
	UNIQUE (file, kind)
);
CREATE INDEX job_status ON job (status, id);

CREATE TABLE extract (
	id INTEGER PRIMARY KEY,
	file INTEGER NOT NULL REFERENCES file (id),
	kind TEXT NOT NULL,
	extractor TEXT NOT NULL,
	version INTEGER NOT NULL,
	created TEXT NOT NULL,
	UNIQUE (file, kind, extractor)
);

CREATE TABLE chunk (
	id INTEGER PRIMARY KEY,
	extract INTEGER NOT NULL REFERENCES extract (id),
	seq INTEGER NOT NULL,
	page INTEGER,
	heading TEXT,
	body TEXT NOT NULL,
	UNIQUE (extract, seq)
);

CREATE VIRTUAL TABLE chunk_fts USING fts5 (
	heading, body,
	content = 'chunk', content_rowid = 'id',
	tokenize = 'porter unicode61 remove_diacritics 2',
	prefix = '2 3'
);

CREATE VIRTUAL TABLE chunk_tri USING fts5 (
	body,
	content = 'chunk', content_rowid = 'id',
	tokenize = 'trigram'
);

-- external content: the delete command needs the exact old values
CREATE TRIGGER chunk_ai AFTER INSERT ON chunk BEGIN
	INSERT INTO chunk_fts (rowid, heading, body)
	    VALUES (new.id, new.heading, new.body);
	INSERT INTO chunk_tri (rowid, body) VALUES (new.id, new.body);
END;

CREATE TRIGGER chunk_ad AFTER DELETE ON chunk BEGIN
	INSERT INTO chunk_fts (chunk_fts, rowid, heading, body)
	    VALUES ('delete', old.id, old.heading, old.body);
	INSERT INTO chunk_tri (chunk_tri, rowid, body)
	    VALUES ('delete', old.id, old.body);
END;

CREATE TRIGGER chunk_au AFTER UPDATE ON chunk BEGIN
	INSERT INTO chunk_fts (chunk_fts, rowid, heading, body)
	    VALUES ('delete', old.id, old.heading, old.body);
	INSERT INTO chunk_tri (chunk_tri, rowid, body)
	    VALUES ('delete', old.id, old.body);
	INSERT INTO chunk_fts (rowid, heading, body)
	    VALUES (new.id, new.heading, new.body);
	INSERT INTO chunk_tri (rowid, body) VALUES (new.id, new.body);
END;

-- rowid is doc.n; the code keeps it current when a head moves
CREATE VIRTUAL TABLE doc_fts USING fts5 (
	title, tags,
	tokenize = 'porter unicode61 remove_diacritics 2'
);
]]

M.migrations[2] = [[
CREATE TABLE config (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
) WITHOUT ROWID;
]]

-- the trigram index cost a quarter of the file; search scans chunk text
-- with instr() instead when the word index finds nothing
M.migrations[3] = [[
DROP TRIGGER chunk_ai;
DROP TRIGGER chunk_ad;
DROP TRIGGER chunk_au;
DROP TABLE chunk_tri;

CREATE TRIGGER chunk_ai AFTER INSERT ON chunk BEGIN
	INSERT INTO chunk_fts (rowid, heading, body)
	    VALUES (new.id, new.heading, new.body);
END;

CREATE TRIGGER chunk_ad AFTER DELETE ON chunk BEGIN
	INSERT INTO chunk_fts (chunk_fts, rowid, heading, body)
	    VALUES ('delete', old.id, old.heading, old.body);
END;

CREATE TRIGGER chunk_au AFTER UPDATE ON chunk BEGIN
	INSERT INTO chunk_fts (chunk_fts, rowid, heading, body)
	    VALUES ('delete', old.id, old.heading, old.body);
	INSERT INTO chunk_fts (rowid, heading, body)
	    VALUES (new.id, new.heading, new.body);
END;
]]

-- [[title]] targets that name no document yet
M.migrations[4] = [[
CREATE TABLE wanted (
	src TEXT NOT NULL REFERENCES doc (id),
	title TEXT NOT NULL,
	PRIMARY KEY (src, title)
) WITHOUT ROWID;
CREATE INDEX wanted_title ON wanted (lower(title));
]]

-- per-document metadata; start is the earliest date of a date key
M.migrations[5] = [[
CREATE TABLE meta (
	doc TEXT NOT NULL REFERENCES doc (id),
	key TEXT NOT NULL,
	seq INTEGER NOT NULL,
	value TEXT NOT NULL,
	start TEXT,
	PRIMARY KEY (doc, key, seq)
) WITHOUT ROWID;
CREATE INDEX meta_key ON meta (key, value);
CREATE INDEX meta_start ON meta (key, start) WHERE start IS NOT NULL;
]]

-- drop the index rows of files that no document head holds, left by
-- note edits before store.unindex existed
M.migrations[6] = [[
DELETE FROM chunk WHERE extract IN (SELECT id FROM extract WHERE file NOT IN
    (SELECT content FROM doc WHERE content IS NOT NULL));
DELETE FROM extract WHERE file NOT IN
    (SELECT content FROM doc WHERE content IS NOT NULL);
DELETE FROM job WHERE file NOT IN
    (SELECT content FROM doc WHERE content IS NOT NULL);
]]

-- counters cairn keeps for itself, such as writes since the last gc
M.migrations[7] = [[
CREATE TABLE state (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
) WITHOUT ROWID;
]]

M.VERSION = #M.migrations

return M
