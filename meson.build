# Pure Lua: nothing is built, only installed and tested.
project('cairn', version : '0.1.0', meson_version : '>= 0.64.0',
        license : 'MIT')

lua_version = get_option('lua_version')

lua = find_program('lua' + lua_version, 'lua', required : true)
luadir = get_option('datadir') / 'lua' / lua_version

install_subdir('cairn', install_dir : luadir)

install_data('bin/cairn.lua', install_dir : get_option('bindir'),
             rename : 'cairn', install_mode : 'rwxr-xr-x')

busted = find_program('busted', required : get_option('tests'))

if busted.found()
  test('spec', busted,
       args : ['--lua=' + lua.full_path(), '--output=plainTerminal'],
       workdir : meson.current_source_dir(),
       timeout : 300)
endif
