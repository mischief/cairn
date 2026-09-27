# cairn

A knowledge store for agents and people. Notes and files (pdf, images,
audio, office documents) live in one SQLite file, with full-text
search over their text, OCR, image descriptions, and transcripts.
Every file and document version has a CIDv1. Tags are the topics.

DESIGN.md describes the data model and the decisions behind it.

## Use

    cairn init
    printf '# uart\n115200 baud on PA9\n' | cairn put "STM32 wiring" -t stm32
    cairn attach datasheet.pdf -t stm32 -t datasheet --set dcterms.date=2021
    cairn check                   # which extractors are installed
    cairn enrich                  # extract text; run it in the background
    cairn search "baud tag:stm32"
    cairn get <id>
    cairn tags

Notes link with `[[title]]`, `[[title#p=12]]` for a PDF page, or
`[[title@2]]` for a fixed version. A link remembers the version it
saw, and `cairn get` marks it when the target changed since.
`cairn:ID#p=12` is the same link as text, for IRC and commits.

`cairn --help` prints the manual, written for agents, and every
command. The database is `$CAIRN_DB`, or
`$XDG_DATA_HOME/cairn/cairn.db`. Writes are signed with `$CAIRN_AUTHOR`,
then the MCP client name, then `$USER`.

Settings live in the database: `cairn config` lists them,
`cairn config lgml.model gemma-4-26b` sets one, and an environment
variable (`CAIRN_LGML`, `CAIRN_MODEL`, `CAIRN_MCP_WRITE`,
`CAIRN_GC_AUTO`, `CAIRN_DAILY_BYTES`) overrides one for a single run.

Features that use a language model, such as image descriptions and
audio transcripts through a local lgml server, live under
`cairn experiments`; run it alone to list them. They load models on
the GPU, so they only run when asked.

## MCP

    claude mcp add cairn -e CAIRN_AUTHOR=myagent -- cairn mcp

The MCP server offers the read tools: search, get, tags, related,
recent, wanted, status. `cairn config mcp.write 1` adds the write
tools: put, edit, tag, meta, link, attach. It never runs an extractor;
after an attach it starts a detached `cairn enrich`.

Documents carry metadata as `namespace.name` keys, mostly DCMI Terms:
`cairn meta ID dcterms.date=1985-12-26 dcterms.creator='DoD NCSC'`.
Search filters on it: `date:<1990`, `creator:intel`,
`meta:KEY=VALUE`.

## Requirements

Lua 5.4, lsqlite3 (SQLite 3.35 or later, with FTS5), luaposix,
mcptk. luaossl is optional: with it, hashing is fast; without it,
cairn hashes in pure Lua. Extraction uses pdftotext, pdftoppm,
tesseract, pandoc, ffmpeg, and curl when they are installed.

## Install

    luarocks --lua-version 5.4 make --local cairn-scm-1.rockspec

The command lands in `~/.luarocks/bin`.

## Build and test

    meson setup build
    meson test -C build
    meson install -C build
