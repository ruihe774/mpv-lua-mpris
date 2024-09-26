# mpv-lua-mpris

Pure Lua implementation of [MPRIS](https://specifications.freedesktop.org/mpris-spec/latest) for [mpv](https://mpv.io).
This plugin implements the MPRIS D-Bus interface which allows controlling mpv using media keys and through desktop environments.
It is an alternative to [mpv-mpris](https://github.com/hoyon/mpv-mpris) if you dislike using a binary code plugin.

Your mpv must be compiled with [LuaJIT](https://luajit.org) (which is the usual case) to use this plugin. [PUC Lua](https://lua.org) is not supported.

## Installation

Just copy `mpris.lua` into the [`script` directory](https://mpv.io/manual/master/#script-location).
