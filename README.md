# serialize.lua

A simple bitpacking serializer for Lua, wire compatible with the C++ [serialize](https://github.com/mas-bandwidth/serialize) library and [serialize.go](https://github.com/mas-bandwidth/serialize.go): the same values produce the same bytes.

The wire format is serialize's [STANDARD.md](STANDARD.md), **format version 2.0**: the wire carries only integers and bytes, and every value has exactly one encoding. STANDARD.md, IMPLEMENTING.md, the conformance corpus in [conformance/](conformance/) and its negative controls in [conformance-controls/](conformance-controls/) are vendored verbatim from mas-bandwidth/serialize `v2.1.4` (`tools/revendor.sh v2.1.4`; CI diffs them against the tag). The port passes every vector with its stated refusal reason, and every sabotage control fails exactly its `.expected` list. The port is version 2.1.3. Its pinned interpreter is Lua 5.4.8 (PUC-Rio); it is also compatible with Lua 5.3 and Lua 5.5, and Lua 5.1, Lua 5.2 and LuaJIT are not supported. It requires 64-bit integers and IEEE 754 binary64 floats; an interpreter built with `LUA_32BITS` or with a non-binary64 float type is refused at load, by name. [DESIGN.md](DESIGN.md) is the design: the API, the bit order, the number model, loading, and the file each part lives in.

A packet reader reads the top-level object and then its end, which refuses trailing bytes (`trailing_data`) and set padding in the final byte (`nonzero_padding`). A refused read reports the first refusal's reason, spelled as STANDARD.md spells it:

    local rs = serialize.ReadStream.new(packet)
    local ok = rs:serializeObject(message) and rs:serializeEnd()
    if not ok then print(rs:error()) end -- "past_end", "embedded_nul", ...

A write or a measure refuses nothing. Lua has no release build, so this port is a checked build always, and every write and measure misuse (a value outside its range or bit width, a non-finite float, text that is not UTF-8, holds a NUL or does not fit its buffer, a write past the end) traps, at the call, with Lua's `error()`, in every run (IMPLEMENTING.md U9). Write misuse never latches: `error()` on a write or a measure stream is always nil. `serialize.copyString(source, bufferSize)` bounds a string for `serializeString` (IMPLEMENTING.md U15). The public surface is `require("serialize")`; the `serialize_*` modules are internal (DESIGN.md (f)).

    make dist-lua        # fetch and build the pinned interpreter into dist/ (sha256 checked)
    make test            # every test/*/*_test.lua
    make test T=smoke    # the files of test/smoke/ only
    make fuzz            # differential fuzzing against serialize.go v2 (needs Go)

    -- the consumer replaces package.path and empties package.cpath (DESIGN.md (f))
    package.path = "<dir>/?.lua"
    package.cpath = ""
    local serialize = require("serialize")

BSD 3-Clause license.
