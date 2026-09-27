rockspec_format = '3.0'
package = 'cairn'
version = 'scm-1'

source = {
  url = 'git+https://git.offblast.org/mischief/cairn.git',
  branch = 'main',
}

description = {
  summary = 'A knowledge store for agents and people, in one SQLite file',
  detailed = [[
cairn keeps notes and files (pdf, images, audio, office documents) in
one SQLite database. Every file and document version has a CIDv1;
version nodes are DRISL. Extracted text, OCR, image descriptions and
transcripts are searchable through FTS5. Tags are the topics. A
command-line tool first, with an MCP server for LLM agents.
]],
  homepage = 'https://git.offblast.org/mischief/cairn',
  license = 'ISC',
  labels = { 'knowledge', 'sqlite', 'fts5', 'mcp', 'cid', 'agents' },
}

supported_platforms = { 'unix' }

dependencies = {
  'lua >= 5.4',
  'lsqlite3',
  'luaposix',
  'mcptk >= 0.1',
}

build = {
  type = 'builtin',
  modules = {
    ['cairn.chunk'] = 'cairn/chunk.lua',
    ['cairn.cid'] = 'cairn/cid.lua',
    ['cairn.cli'] = 'cairn/cli.lua',
    ['cairn.config'] = 'cairn/config.lua',
    ['cairn.db'] = 'cairn/db.lua',
    ['cairn.derive'] = 'cairn/derive.lua',
    ['cairn.drisl'] = 'cairn/drisl.lua',
    ['cairn.enrich'] = 'cairn/enrich.lua',
    ['cairn.experiments'] = 'cairn/experiments.lua',
    ['cairn.extract'] = 'cairn/extract.lua',
    ['cairn.lgml'] = 'cairn/lgml.lua',
    ['cairn.topics'] = 'cairn/topics.lua',
    ['cairn.vocab'] = 'cairn/vocab.lua',
    ['cairn.mcp'] = 'cairn/mcp.lua',
    ['cairn.meta'] = 'cairn/meta.lua',
    ['cairn.proc'] = 'cairn/proc.lua',
    ['cairn.queue'] = 'cairn/queue.lua',
    ['cairn.schema'] = 'cairn/schema.lua',
    ['cairn.receipt'] = 'cairn/receipt.lua',
    ['cairn.search'] = 'cairn/search.lua',
    ['cairn.sha256'] = 'cairn/sha256.lua',
    ['cairn.secret'] = 'cairn/secret.lua',
    ['cairn.store'] = 'cairn/store.lua',
    ['cairn.tags'] = 'cairn/tags.lua',
    ['cairn.util'] = 'cairn/util.lua',
  },
  install = {
    bin = {
      ['cairn'] = 'bin/cairn.lua',
    },
  },
}

test_dependencies = {
  'busted >= 2.0',
}

test = {
  type = 'busted',
}
