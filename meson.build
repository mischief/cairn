# Pure Lua: nothing is built, only installed and tested.
project('cairn', version : '0.1.0', meson_version : '>= 0.64.0',
        license : 'ISC')

lua_version = get_option('lua_version')

lua = find_program('lua' + lua_version, 'lua', required : true)
luadir = get_option('datadir') / 'lua' / lua_version

install_subdir('cairn', install_dir : luadir)

# The process title setter, the one compiled piece.
lua_dep = dependency('lua' + lua_version, 'lua-' + lua_version,
                     'lua' + lua_version.replace('.', ''), required : false)
if lua_dep.found()
  shared_module('proctitle', 'src/proctitle.c',
                name_prefix : '',
                dependencies : lua_dep,
                install : true,
                install_dir : get_option('libdir') / 'lua' / lua_version / 'cairn')
endif

install_data('bin/cairn.lua', install_dir : get_option('bindir'),
             rename : 'cairn', install_mode : 'rwxr-xr-x')

busted = find_program('busted', required : get_option('tests'))

if busted.found()
  test('spec', busted,
       args : ['--lua=' + lua.full_path(), '--output=plainTerminal'],
       workdir : meson.current_source_dir(),
       timeout : 300)
endif
