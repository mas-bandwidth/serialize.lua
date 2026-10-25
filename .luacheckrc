-- luacheck configuration for `make lint` (make/lint.mk pins luacheck and runs
-- it on the pinned interpreter over src/, test/ and fuzz/driver.lua). Zero
-- warnings is the gate: luacheck exits nonzero on any warning. Each setting
-- below names why it is here; a finding is fixed in the code, not added here.

std = "lua54"

-- Method syntax: WriteStream:isWriting() and its siblings answer for the type
-- and never read self. That is the shape of the stream interface, not a slip.
self = false

-- An argument whose name starts with "_" is a positional slot the function
-- deliberately leaves unread: the operation tables give every write, read,
-- measure and checkValue one signature, and the measure arms take the value
-- they do not need. Any other unused argument is still a warning.
ignore = { "212/_.*" }

-- W581 offers "x < y" for "not (x >= y)". The float code compares that way on
-- purpose: the negated form is true for NaN and the suggested one is not, so
-- the rewrite would change behaviour (serialize_compressed_float.lua clamps).
files["src/serialize_compressed_float.lua"] = { ignore = { "581" } }

-- Test files declare their tests as top-level globals named Test<Name>; the
-- runner (the Makefile's TEST_RUNNER) collects them from the file's
-- environment. Only top-level definitions are allowed, so any other stray
-- global in a test is still a warning; a Test<Name> global is used by the
-- runner, which luacheck cannot see, so W131 (unused global) is ignored for
-- those names only. The conformance and smoke tables hold long hex vectors and
-- expected messages, so line length is not held there.
files["test"] = {
  allow_defined_top = true,
  ignore = { "131/Test%u.*" },
  max_line_length = false,
}
