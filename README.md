# serialize.lua

A simple bitpacking serializer for Lua, wire compatible with the C++ [serialize](https://github.com/mas-bandwidth/serialize) library and [serialize.go](https://github.com/mas-bandwidth/serialize.go): the same values produce the same bytes.

Status: in progress. The wire format is serialize's [STANDARD.md](STANDARD.md), format version 1.1, vendored verbatim with its conformance corpus in [conformance/](conformance/). The pinned interpreter is Lua 5.4.8 (PUC-Rio). [DESIGN.md](DESIGN.md) is the design: the API, the bit order, the number model, loading, and the file each part lives in. Today the entry and the three streams exist; each value family lands as its own file.

    make dist-lua        # fetch and build the pinned interpreter into dist/ (sha256 checked)
    make test            # every test/*/*_test.lua
    make test T=smoke    # the files of test/smoke/ only

    -- the consumer replaces package.path and empties package.cpath (DESIGN.md (f))
    package.path = "/path/to/serialize.lua/src/?.lua"
    package.cpath = ""
    local serialize = require("serialize")

BSD 3-Clause license.
