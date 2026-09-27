# cairn design

cairn is a knowledge store for agents and people. Knowledge is notes
that agents write and files that agents or people add: markdown, pdf,
images, office documents, audio. Everything lives in one SQLite file.
A backup is a copy of that file.

cairn is a command-line tool first. An MCP server gives LLM agents the
fast subset of the same operations.

## Goals

- One file holds all content, all history, and all indexes.
- Every file and every document version has a content address (CID).
- Full-text search covers notes, file text, OCR, image descriptions,
  and transcripts.
- Tags are the topics. A document has many tags, so it sits under many
  topics.
- Documents link to each other.
- Search results are small. A caller fetches full text only on request.
- Files come back out with their original names.

## Non-goals

- No deletion. A document can be hidden or superseded, not removed.
- No network sync or replication.
- No embeddings in the first version. FTS5 comes first.
- No LLM extraction of entities or facts on write.
- No python and no node.js, in cairn or in its tools.

## Stack

- Lua 5.4.
- lsqlite3 for the database, with FTS5.
- luaossl for sha2-256 and random bytes.
- mcptk for the MCP stdio server.
- External extractors run as commands: pdftotext, pdftoppm, tesseract,
  pandoc, ffmpeg.
- lgml over local HTTP for image descriptions and audio transcripts.

## Work split

Commands that finish in milliseconds run anywhere: in the CLI and as
MCP tools. Slow work runs only in the CLI, as a separate command that a
caller can put in the background.

- `cairn attach` stores a file and its document, queues extraction, and
  returns at once. The document is searchable by title and tags at
  once. Its text becomes searchable after enrichment.
- `cairn enrich` drains the extraction queue. An agent runs it as a
  background command and gets a notice when it exits. A person can run
  it from cron or a systemd timer.
- Markdown and plain-text notes need no extractor. `put` indexes them
  in the same call.

No process holds a write transaction while an extractor runs. Enrich
extracts first, then writes the chunks in one short transaction.

## Content addresses

All CIDs are CIDv1 with sha2-256. The first version uses two codecs:

| codec | code | holds |
| --- | --- | --- |
| raw | 0x55 | the bytes of one file |
| dag-cbor | 0x71 | a document version node, encoded as DRISL |

Both are DASL CIDs. A file is one raw block, up to 64 MiB. Its CID is
the raw CID of its bytes, which is the same CID that
`ipfs add --cid-version=1 --raw-leaves` gives for a file of up to one
chunk.

The database stores CIDs as binary blobs. The CLI and tools show them
as base32 strings (`bafk...`, `bafy...`).

### DRISL

Version nodes use DRISL, the DASL profile of deterministic dag-cbor:

- map keys sorted by encoded bytes, no duplicates;
- integers in the shortest form;
- only tag 42 (a CID link);
- no floats in cairn nodes;
- no indefinite lengths;
- simple values limited to true, false, and null.

The decoder rejects input that breaks any rule. After a decode it
encodes the value again and compares the bytes. The CLI and tools may
show a node as dag-json, but cairn never hashes JSON.

In Lua, `1` and `1.0` are different values. The encoder refuses floats,
so a stray float is an error, not a new hash.

## Database

The database has `application_id` `0x4341524e` ("CARN") and a schema
version in `user_version`. Before it creates the first table, cairn
sets:

```sql
PRAGMA page_size = 8192;
PRAGMA auto_vacuum = INCREMENTAL;
PRAGMA journal_mode = WAL;
```

Each connection sets `synchronous = NORMAL`, `foreign_keys = ON`,
`busy_timeout = 5000`, and `journal_size_limit`. It runs
`PRAGMA optimize` when it closes.

All times are RFC 3339 UTC with a `Z` and no fraction:
`2026-09-26T12:00:00Z`. Text order is then time order.

### Blocks

```sql
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
```

- `cid` gives every CID a small integer. Other tables use that integer.
  A `cid` row can exist before its block, so a node can link to a block
  that is not stored.
- `block.data` is the last column. List and search queries never read
  it.
- `ref` holds the links inside each block. cairn parses them from the
  block when it writes the block. It never takes them from the caller.
- A block is immutable. A second write of the same CID changes nothing.
- lsqlite3 has no incremental blob I/O, so a whole file passes through
  Lua memory. The 64 MiB limit keeps that bounded.

### Files

```sql
CREATE TABLE file (
	id INTEGER PRIMARY KEY REFERENCES cid (id),
	size INTEGER NOT NULL,
	mime TEXT
);
```

`file.id` is the CID of the file root. Today that is the raw block. A
later UnixFS root is a dag-pb CID in the same column, so the table
needs no change.

### Documents

A document has a stable id and a chain of versions. The id is 10 random
bytes in lowercase base32 (16 characters). Each version is a DRISL node:

```
{
  "type":    "cairn/doc",
  "v":       1,
  "doc":     "<id>",
  "rev":     3,
  "prev":    CID of rev 2, or null,
  "title":   "...",
  "name":    "original-file-name.pdf", or null,
  "mime":    "application/pdf",
  "content": CID of the file, or null,
  "tags":    ["stm32", "datasheet"],
  "about":   "stm32", or null,
  "links":   [{"rel": "see-also", "doc": "<id>", "at": CID,
               "frag": "p=29", "name": "Intel MP spec"}],
  "hidden":  false,
  "author":  "kbd",
  "created": "2026-09-26T12:00:00Z",
  "meta":    {"dcterms.date": "1985-12-26",
              "dcterms.creator": ["DoD", "NCSC"]}
}
```

`author` and `created` are who wrote this version into cairn and when.
The document's own author and date go in `meta`. A node with no
metadata has no `meta` key.

- A note is a document whose content is a markdown file. A file added
  with `attach` is a document too. The same tables and commands serve
  both.
- `about` makes the document the page for a tag. It holds the overview
  for that topic.
- `hidden` removes the document from search and lists. A new version
  can set it back to false.
- Extracted text is not in the node. It is derived from the content and
  can be built again.

```sql
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

CREATE TABLE doc_version (
	doc TEXT NOT NULL REFERENCES doc (id),
	rev INTEGER NOT NULL,
	node INTEGER NOT NULL REFERENCES cid (id),
	author TEXT,
	created TEXT NOT NULL,
	PRIMARY KEY (doc, rev)
) WITHOUT ROWID;
CREATE INDEX doc_version_created ON doc_version (created);
```

The `doc` row copies fields from the head node so that lists and
filters do not decode DRISL. `tag` and `link` also come from the head
node. They are indexes, not the source of truth. `doc.n` is an INTEGER
PRIMARY KEY, so VACUUM does not renumber it, and the FTS tables use it
as their rowid.

A new version moves the head with a compare-and-swap:

```sql
UPDATE doc SET head = ?, rev = ? WHERE id = ? AND rev = ?;
```

If no row changes, another writer was first. The command returns the
current rev and the caller tries again.

### Metadata

A document may carry metadata: keys of the form `namespace.name`, each
with a text value or a list of text values. It lives in the version
node, so every change is a new version with its own CID, and history
keeps old values.

| namespace | holds |
| --- | --- |
| `dcterms` | DCMI Terms: date, creator, publisher, identifier, language, source, type, description, rights, and the rest |
| `pdf` | PDF Info fields as found in the file: Title, Author, Subject, Keywords, Creator, Producer, CreationDate, ModDate |
| `csl` | citation fields that DCMI lacks, such as csl.type or csl.DOI |
| any other | free for people and agents |

- A namespace is lowercase letters, digits, and `-`. A name keeps the
  spelling of its vocabulary, such as `dcterms.isVersionOf`. The
  separator is a dot, because `:` separates search filters.
- `dcterms.title`, `dcterms.subject`, and `dcterms.relation` are
  refused: the title, tags, and links already hold them.
- Date keys (`dcterms.date`, `issued`, `created`, `modified`,
  `available`, `valid`) take EDTF (ISO 8601-2): `1985`, `1985-12`,
  `1985-12-26`, `1985?`, `1985~`, `198X`, `1985/1987`. The index keeps
  the earliest day of each, so dates compare as text.
- `attach` reads the PDF Info fields into `pdf.*` as found and copies
  `pdf.Author` to `dcterms.creator` when that is unset. PDF `Creator`
  is the program that made the file, not the person, so it stays in
  `pdf.Creator`. `pdf.CreationDate` is when the file was made, often a
  scan years after the document, so cairn does not copy it to
  `dcterms.date`.
- Limits: 64 keys, 32 values per key, 2000 bytes per value. Values go
  through the secret check.

```sql
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
```

`meta` is an index over the head node, like `tag`. `start` is the
earliest day of a date value.

Search filters:

| filter | matches |
| --- | --- |
| `meta:KEY` | documents with that key |
| `meta:KEY=VALUE` | a value, ignoring case |
| `meta:KEY~PART` | a value that holds PART |
| `date:1985`, `date:1985-12` | a `dcterms.date` that starts so |
| `date:<1990`, `date:>=1985-06` | a `dcterms.date` before or after |
| `creator:TEXT` | a `dcterms.creator` that holds TEXT |

A filter value with spaces is quoted: `creator:"DoD NCSC"`.

### Tags

Tags are the topics. There is no topic tree and no parent link.

```sql
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
```

- A tag name is lowercase ASCII letters, digits, `-`, and `/`, 1 to 40
  characters. A `/` makes a nested name such as `hw/stm32`.
- A filter on `hw` matches `hw` and every tag under `hw/`. It does not
  match `hwmon`.
- Aliases resolve on every write and every read: `sqlite3` becomes
  `sqlite` in a stored tag, in a `tag:` filter, and in `cairn tags`.
- `put` and `attach` show existing tags with close names: by edit
  distance, by shared prefix, and by alias. This keeps the topics
  clean, so writers reuse tags instead of making new spellings.
- `cairn tags` lists tags with their document counts and the tags that
  appear with them most. It shows nested names as a tree.
- A filter on two tags means documents with both tags.
- One visible, current document can be the `about` page for a tag. A
  second claim fails. To take over a tag page, a new document
  supersedes the old one. `doc.about` has an index.

### Links

```sql
CREATE TABLE link (
	src TEXT NOT NULL REFERENCES doc (id),
	dst TEXT NOT NULL REFERENCES doc (id),
	rel TEXT NOT NULL,
	PRIMARY KEY (src, dst, rel)
) WITHOUT ROWID;
CREATE INDEX link_dst ON link (dst, rel);
```

| rel | meaning |
| --- | --- |
| see-also | related document |
| cites | src uses dst as a source |
| supersedes | src replaces dst |
| contradicts | src disagrees with dst |

- `supersedes` sets `doc.superseded_by` on the target. Search hides
  superseded documents unless the caller asks for them.
- `related` walks the links in both directions with a recursive CTE.
- The `link` table is an index over the head node: one row per source,
  target, and rel. The node keeps the full links.

#### Link targets

A link target is a title, a document id, or a CID, and it may end in
`@REV` for a fixed version and `#FRAG` for a place in the document:

| target | means |
| --- | --- |
| `Intel MP spec` | the newest version of the document with that title |
| `jr77522vusb3dhdh@2` | rev 2 of that document |
| `bafyrei...` | the version with that node CID |
| `bafkrei...` | the newest document with that file |
| `...#p=29` | page 29 of its text |
| `...#wiring` | its sections whose heading holds "wiring" |

`cairn:TARGET` is the same link as text, for use outside cairn: in IRC,
commit messages, and code comments. Search hits and `get` print these
URIs, and `get` takes them.

#### Links in a note body

- `[[TARGET]]` or `[[TARGET|label]]` in a markdown body becomes a
  `see-also` link when the note is written.
- The node link keeps the target text as `name`. A link with a `name`
  came from the body, so the next version rebuilds it from the body: a
  link removed from the body goes away. Links without a `name` came
  from `cairn link` and stay.
- A title resolves to the document it named in the last version, when
  that document still exists. A retitled document, or a new document
  with the old title, does not take the link over.
- A title that names no document is kept in `wanted`:

```sql
CREATE TABLE wanted (
	src TEXT NOT NULL REFERENCES doc (id),
	title TEXT NOT NULL,
	PRIMARY KEY (src, title)
) WITHOUT ROWID;
CREATE INDEX wanted_title ON wanted (lower(title));
```

  `cairn wanted` lists the titles that no document has yet. They are
  notes worth writing. When `put` writes a document with a wanted
  title, it names the notes that want it. Their next edit resolves the
  link.

#### The version a link saw

Each node link has `at`: a tag-42 link to the version node of the
target when the link was made. It gives two things:

- **Change marks.** When the target head is no longer `at`, `get` marks
  the link "changed since linked: rev 1 -> 2". The reader knows its
  source moved on and can check the claim again.
- **Provenance.** A `cites` link proves which text a claim rests on,
  after the target changes or is superseded. Because `at` is a block
  link, `ref` records it, and a future garbage collector keeps that
  version.

A link that was in the last version keeps its `at`, so an edit does not
clear a change mark. `cairn link` with the same source, target, and rel
records the current version again, which clears the mark. `@REV` pins
a link: `at` is that version, and `pin` is true, so the link never
shows as changed.

## Extraction

Extraction runs on file content, not on documents. Two documents with
the same file share one extraction.

```sql
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
```

`job.status` is `pending`, `running`, `done`, or `failed`. An enricher
claims a job in one statement, so two enrichers never take the same
job. The statement needs SQLite 3.35 or later for RETURNING.

```sql
UPDATE job SET status = 'running', lease = :token,
    lease_until = :until, tries = tries + 1
WHERE id = (SELECT id FROM job WHERE status = 'pending'
            AND kind IN (:kinds) ORDER BY id LIMIT 1)
RETURNING id, file, kind;
```

- The lease token is `<host>:<pid>:<random>`. It names the enricher
  that holds the job.
- `kinds` holds only the kinds this enricher can run. Without
  `--vision`, it leaves out `vision` and `transcript`, so those jobs
  stay pending.
- A lease lasts 120 seconds. While an extractor runs, the enricher
  renews `lease_until` every 30 seconds with the same token check.
- A `running` job with an expired lease goes back to `pending`. After
  three tries it becomes `failed`, with the error kept.
- The enricher finishes a job in one transaction: it sets the job to
  `done` where `id` and `lease` still match, and only if that changes
  a row, it replaces all chunks of that file, kind, and extractor. A
  late enricher whose lease was taken writes nothing. A retry or a
  reindex never doubles the chunks.
- `cairn enrich --retry-failed` sets failed jobs back to pending.
- After an extractor version change, `cairn reindex` sets jobs back to
  pending where `extract.version` is older than the current version.
  `UNIQUE (file, kind)` keeps one job row per file and kind.

| mime | kind | extractor |
| --- | --- | --- |
| text/markdown, text/plain | text | built in, inline in `put` |
| application/pdf | pdf | `pdftotext -layout`, pages split on form feed |
| application/pdf, no text layer | ocr | `pdftoppm` then `tesseract` |
| image/png, image/jpeg | ocr | `tesseract` |
| image/png, image/jpeg | vision | lgml, only with `--vision` |
| audio/* | transcript | `ffmpeg` to 16 kHz mono WAV, then lgml, only with `--vision` |
| office and html | text | `pandoc -t plain` |

- lgml loads a model on first use. That can take GPU memory from other
  work on the same machine. So enrich calls lgml only when the caller
  gives `--vision`, and it names the model (`--model`, default
  `gemma-4-26b`).
- Image descriptions go to `/v1/chat/completions` with the image as a
  PNG or JPEG data URL and with thinking off
  (`chat_template_kwargs: {"enable_thinking": false}`).
- Chunks follow pages, or markdown headings, and stay under about 2000
  tokens. A chunk keeps its heading path for context.
- NUL bytes are removed before indexing. A NUL cuts off FTS content.
- When an extractor gets a new version, `cairn reindex` queues its
  files again.

## Search

```sql
CREATE VIRTUAL TABLE chunk_fts USING fts5 (
	heading, body,
	content = 'chunk', content_rowid = 'id',
	tokenize = 'porter unicode61 remove_diacritics 2',
	prefix = '2 3'
);

CREATE VIRTUAL TABLE doc_fts USING fts5 (
	title, tags,
	tokenize = 'porter unicode61 remove_diacritics 2'
);
```

- Triggers on `chunk` keep `chunk_fts` current. The delete trigger
  must pass the old values.
- `doc_fts` has one row per document, rowid equal to `doc.n`. The code
  updates it when the head moves.
- A query runs against `doc_fts` and `chunk_fts` and joins chunks to
  documents through `doc.content`. Results group by document and keep
  the best chunk for each. When several documents share a file, each
  of them is a result. Title hits weigh more than body hits.
- The porter tokenizer splits at `_`, so identifiers such as
  `GPIO_OUT_W1TS` match as words.
- When the word index finds nothing, search scans chunk text with
  `instr(lower(body), ?)` for part words. On 46 MB of text the scan
  takes about 0.1 s. A trigram index did the same in under 0.01 s but
  cost 64 MB, a quarter of the file, so cairn does not keep one.
- The query parser takes `tag:`, `mime:`, `author:`, and `since:`
  filters out of the query. If the rest has no FTS5 operators, each
  word is quoted and the last word gets a prefix match. A query with
  FTS5 operators goes to MATCH unchanged.
- A document whose extraction is not done shows `text: pending` in
  search and get results, so a caller knows why a body match is
  missing.

## Settings

Settings live in the database, so a backup holds them:

```sql
CREATE TABLE config (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
) WITHOUT ROWID;
```

| key | env | default |
| --- | --- | --- |
| lgml.url | CAIRN_LGML | http://127.0.0.1:8091 |
| lgml.model | CAIRN_MODEL | gemma-4-26b |
| enrich.vision | CAIRN_VISION | 0 |
| mcp.write | CAIRN_MCP_WRITE | 0 |
| gc.auto | CAIRN_GC_AUTO | 1000 |
| limit.daily | CAIRN_DAILY_BYTES | 268435456 |

An environment variable overrides the stored value for one process.
`cairn config` lists them with their source, and
`cairn config <key> <value>` stores one. The database path cannot live
in the database, so it comes from `-d`, then `CAIRN_DB`, then
`$XDG_DATA_HOME/cairn/cairn.db`.

## Authors

The author of a write comes from `CAIRN_AUTHOR`, then from the MCP
client name, then from `$USER`. There is no author argument. Each agent
starts its own cairn process, so the environment names the agent.

Stored text is data. Search and get results name the author of each
document and mark the text as stored content, not instructions.

## Safety

- Every write path checks for secrets: `put`, `edit`, and `attach`, in
  the CLI and in MCP. Before it stores or indexes text, cairn refuses
  content that matches
  common secret patterns: `sk-...`, `ghp_...`, `AKIA...`,
  `-----BEGIN ... PRIVATE KEY-----`, and long high-entropy strings next
  to words such as key, token, or secret. With no deletion, a stored
  secret stays forever.
- Each author has a daily byte limit, so a looping agent cannot fill
  the disk.
- `cairn fsck` hashes every block again, checks `ref`, and runs the FTS5
  `integrity-check` command on each FTS table.

## Commands

| command | does |
| --- | --- |
| `cairn init` | make an empty database |
| `cairn put <title> [-t tag]... [file\|-]` | write a markdown note |
| `cairn edit <id> <rev> [file\|-]` | new version of a note |
| `cairn attach <file> [-t tag]... [--title t]` | store a file, queue extraction |
| `cairn enrich [--vision] [--model m] [--max n]` | drain the queue |
| `cairn search <query>` | search |
| `cairn get <id\|cid\|uri> [--rev n] [--page n] [--at frag]` | show a document |
| `cairn cat <id\|cid> [out]` | write the file bytes |
| `cairn tag <id> [+tag\|-tag]...` | change tags |
| `cairn tags [prefix]` | list tags |
| `cairn link <src> <dst> <rel>` | add a link; dst takes `@rev` and `#p=N` |
| `cairn wanted` | titles linked but not written |
| `cairn meta <id> [key=v\|key=\|key+=v]... [--from-file]` | show or change metadata |
| `cairn related <id> [--depth n]` | linked documents |
| `cairn hide <id>`, `cairn unhide <id>` | hide or show a document |
| `cairn recent [--since t] [--author a]` | recent versions |
| `cairn alias <alias> <tag>` | add a tag alias |
| `cairn reindex [--kind k]` | queue extraction again |
| `cairn fsck` | check the database |
| `cairn backup <file>` | `VACUUM INTO` a copy |
| `cairn vacuum` | give free pages back to the disk |
| `cairn gc [--dry-run]` | delete blocks no document reaches; history stays |
| `cairn stats` | counts and sizes |
| `cairn config [key [value]]` | show or set a setting |
| `cairn status` | queue counts by status and kind |

The database path comes from `-d`, then `CAIRN_DB`, then
`$XDG_DATA_HOME/cairn/cairn.db`.

## MCP tools

`cairn mcp` serves the fast commands as MCP tools over stdio. It never
runs an extractor. By default it offers only the read tools: search,
get, tags, related, recent, wanted, and status. The write tools (put,
edit, tag, meta, link, attach) appear only when the `mcp.write`
setting is 1.
Agents then write through the CLI, where each agent can set its own
`CAIRN_AUTHOR`.
The read-only instructions tell an agent to run `cairn --help` before
it writes. That manual covers searching first, `put` with
`CAIRN_AUTHOR`, reading the near duplicates and close tags that `put`
returns, `attach` with a background `cairn enrich`, and what is worth
writing. The instructions name the full path of the command when it is
not on PATH.

| tool | arguments | returns |
| --- | --- | --- |
| search | query, tag?, mime?, superseded?, limit?, offset? | id, title, snippet, page, score, author, updated |
| get | id, CID, or cairn: URI; rev?, page? | node fields, links with change marks, one page of text |
| put | title, body, tags?, links? | id, rev, cid, near duplicates, close tags |
| edit | id, rev, op (append, replace, str_replace), ... | id, new rev, cid |
| tag | id, add?, remove? | new rev |
| tags | prefix?, with? | tags, counts, co-occurring tags |
| link | src, dst, rel | new rev of src |
| related | id, rel?, depth? | linked documents, both directions |
| recent | since?, author?, limit? | recent versions |
| wanted | | titles linked but not written |
| meta | id, set (key -> text, list, or null) | the new metadata |
| attach | path, title?, tags? | id, rev, file cid, queued job kinds |
| status | | queue counts by kind and status |

- `put` searches for near duplicates first and returns them with the
  new id. The agent decides whether to link or supersede.
- `edit` requires the current rev. A stale rev fails and returns the
  current one.
- `attach` reads a local file, stores it, and queues extraction. It
  returns at once. An agent with a shell can also run `cairn attach`.

### Enrichment without a shell

An agent with only MCP cannot run `cairn enrich`. So when the queue
has jobs and no enricher holds the lock file, `cairn mcp` starts a
detached `cairn enrich` process with fork and exec. The MCP process
never runs an extractor itself. A systemd user timer or a cron entry
that runs `cairn enrich` also works. `put` of a markdown note needs no
enrichment.

## Garbage collection

`cairn gc` is a mark and sweep over `ref`. The marks start at every
document head (hidden ones too) and follow `prev` to older versions,
`content` to files, and link `at` to the versions links saw. Blocks
with no mark go, with their `file`, `extract`, `chunk`, and `job` rows,
and so do `cid` rows that nothing names. History stays: every version
of every document is reachable through `prev`.

With no deletion, garbage is rare: blocks from a write that crashed
between statements, or files whose attach failed. `--dry-run` reports
what would go.

Like `git gc --auto`, cairn counts the versions it writes in the
`state` table:

```sql
CREATE TABLE state (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL
) WITHOUT ROWID;
```

`state` holds `gc.writes`, the versions written since the last gc, and
`gc.last`, when it ran. After each CLI command and each MCP write tool,
cairn runs gc and gives free pages back once `gc.writes` reaches the
`gc.auto` setting (1000; 0 turns it off). `cairn stats` shows the count
and the free bytes in the file.

## Backup

`cairn backup <file>` runs `VACUUM INTO`. Never copy the database file
alone: the WAL file can hold committed data.

## Limits

| limit | value |
| --- | --- |
| file size | 64 MiB |
| search results | 10 by default, 50 at most |
| get text | 16000 characters per page |
| tags per document | 32 |
| enrich tries per job | 3 |

## Later

These parts wait until a need appears.

- **UnixFS files.** The IPFS `unixfs-v1-2025` profile (IPIP-0499): 1
  MiB raw leaves under one dag-pb root. File CIDs then match kubo and
  helia for every size, not only files of one chunk. The whole-file raw
  CID stays as an alias, so existing CIDs keep working.
- **CAR export and import.** CARv1 out, CARv1 and CARv2 in, every block
  hashed again on import.
- **Mount.** A read-only luafuse view: `doc/<slug>/<name>`,
  `doc/<slug>/text/`, `tag/<a>/<b>/` as the documents with both tags,
  `cid/<cid>`, and a `search/<query>/` directory that answers lookups
  but lists nothing.
- **Pruning history.** `cairn prune --keep N` could drop version nodes
  older than the newest N of each document, except versions that a
  link's `at` names, and let gc remove the files they held. It breaks
  "no deletion", so it waits for a need.
- **Embeddings.** lgml has no embedding endpoint yet. When one exists,
  vectors merge with FTS5 through reciprocal rank fusion.

## Open questions

- Namespaces. A nullable `scope` column on `doc` (a project path, or
  null for global) is cheap to add later. Tags may be enough.
- Compression. Core SQLite does not compress. PDFs and images are
  already compressed. Markdown is small. The first version stores raw
  bytes. If compression comes later, it is a storage detail under the
  CID: a `block.enc` column, and the hash is always over the
  uncompressed bytes. CIDs do not change.

## References

- CID spec: https://github.com/multiformats/cid
- DASL and DRISL: https://dasl.ing/
- IPIP-0499, UnixFS CID profiles: https://specs.ipfs.tech/ipips/ipip-0499/
- CAR format: https://ipld.io/specs/transport/car/
- SQLite, internal and external blobs: https://www.sqlite.org/intern-v-extern-blob.html
- SQLite FTS5: https://www.sqlite.org/fts5.html
- atproto repository: https://atproto.com/specs/repository
- ipfs-sqlite-block-store: https://github.com/Actyx/ipfs-sqlite-block-store
- basic-memory: https://github.com/basicmachines-co/basic-memory
- Graphiti: https://github.com/getzep/graphiti
- SELF, executables as SQLite: https://fzakaria.com/2026/08/23/your-executable-is-a-sqlite-database
