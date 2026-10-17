# serialize.lua

A simple bitpacking serializer for Lua, wire compatible with the C++ [serialize](https://github.com/mas-bandwidth/serialize) library and [serialize.go](https://github.com/mas-bandwidth/serialize.go): the same values produce the same bytes.

Status: in progress. The wire format is serialize's STANDARD.md, format version 1.1. The pinned interpreter is Lua 5.4.8.

BSD 3-Clause license.
