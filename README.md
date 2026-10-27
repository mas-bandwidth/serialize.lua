# serialize.lua

A simple bitpacking serializer for Lua, wire compatible with the C++ [serialize](https://github.com/mas-bandwidth/serialize) library and [serialize.go](https://github.com/mas-bandwidth/serialize.go): the same values produce the same bytes.

The wire format is serialize's [STANDARD.md](STANDARD.md), **format version 2.0**: the wire carries only integers and bytes, and every value has exactly one encoding. STANDARD.md, IMPLEMENTING.md, the conformance corpus in [conformance/](conformance/) and its negative controls in [conformance-controls/](conformance-controls/) are vendored verbatim from mas-bandwidth/serialize at commit `3617d360` (the 2.0.1 corpus; `tools/revendor.sh 3617d3606db9c5686018d6568f0aa761869083c5`; CI diffs them against that commit). The port passes every vector with its stated refusal reason, and every sabotage control fails exactly its `.expected` list. The pinned interpreter is Lua 5.4.8 (PUC-Rio). [DESIGN.md](DESIGN.md) is the design: the API, the bit order, the number model, loading, and the file each part lives in.

A packet reader reads the top-level object and then its end, which refuses trailing bytes (`trailing_data`) and set padding in the final byte (`nonzero_padding`). A refused read reports the first refusal's reason, spelled as STANDARD.md spells it:

    local rs = serialize.ReadStream.new(packet)
    local ok = rs:serializeObject(message) and rs:serializeEnd()
    if not ok then print(rs:error()) end -- "past_end", "embedded_nul", ...

    make dist-lua        # fetch and build the pinned interpreter into dist/ (sha256 checked)
    make test            # every test/*/*_test.lua
    make test T=smoke    # the files of test/smoke/ only
    make fuzz            # differential fuzzing against serialize.go v2 (needs Go)

    -- the consumer replaces package.path and empties package.cpath (DESIGN.md (f))
    package.path = "/path/to/serialize.lua/src/?.lua"
    package.cpath = ""
    local serialize = require("serialize")

BSD 3-Clause license.
