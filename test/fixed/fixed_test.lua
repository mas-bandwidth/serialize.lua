-- test/fixed: the fixed point Q format arm (DESIGN.md (h)).
-- Run by `make test T=fixed` from the repository root. Pins: every record of
-- conformance/fixed.txt (raw value, bits consumed, canonical bytes, refusal with
-- the destination untouched and the stream terminal), the per-file record count
-- equal to the file's count, serialize.go's panicFixedParams and panicFixedBounds
-- misuse rules, and the byte identity with the int64 path for three Q formats.

local serialize = require("serialize")

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

--------------------------------------------------------------------------------
-- The corpus records run through the shared runner (test/conformance): the raw
-- value exactly, bits consumed, the stated refusal reason, the destination
-- untouched, the stream terminal, the canonical bytes.
--------------------------------------------------------------------------------

local C = assert(loadfile("test/conformance/conformance_test.lua"))()

local function runFile(path)
  local records = C.parseVectors(path)
  for _, rec in ipairs(records) do C.runRecord(rec) end
  print(path .. ": " .. #records .. " records")
end

--------------------------------------------------------------------------------
-- Misuse: serialize.go's panicFixedParams and panicFixedBounds (stream.go).
--------------------------------------------------------------------------------

local function expectPanic(fn, msg)
  local ok = pcall(fn)
  check(not ok, "expected a raise: " .. msg)
end

local function expectFixedPanic(fn, msg)
  local ok, err = pcall(fn)
  check(not ok, "expected a raise: " .. msg)
  check(tostring(err):find("serialize: fixed point", 1, true) ~= nil, "wrong panic for: " .. msg)
end

--------------------------------------------------------------------------------
-- Byte identity with the int64 path for three Q formats (STANDARD.md, fixed).
--------------------------------------------------------------------------------

local function byteIdentity(ib, fb, min, max, raw)
  local rawMin = min << fb
  local rawMax = max << fb
  local wsFixed = serialize.WriteStream.new(16)
  local wsInt = serialize.WriteStream.new(16)
  check(wsFixed:serializeFixed({ value = raw }, ib, fb, min, max), "fixed write failed")
  check(wsInt:serializeInt64({ value = raw }, rawMin, rawMax), "int64 write failed")
  wsFixed:flush()
  wsInt:flush()
  check(wsFixed:data() == wsInt:data(),
    "byte identity mismatch for Q" .. ib .. "." .. fb .. " raw=" .. tostring(raw))
end

function TestSerializeFixed()
  -- loading the fixed family creates no global (DESIGN.md (f))
  local before = {}
  for k in pairs(_G) do before[k] = true end

  -- 1. the conformance corpus, record by record, with the per-file count
  runFile("conformance/fixed.txt")
  for k in pairs(_G) do
    check(before[k], "loading the fixed family created the global " .. tostring(k))
  end

  -- 2. misuse: panicFixedParams
  local ws = serialize.WriteStream.new(16)
  local h = { value = 0 }
  expectFixedPanic(function() ws:serializeFixed(h, 0, 32, 0, 100) end, "integerBits = 0")
  expectFixedPanic(function() ws:serializeFixed(h, 40, -8, 0, 100) end, "fractionBits < 0")
  expectFixedPanic(function() ws:serializeFixed(h, 8, 8, -100, -101) end, "min > max")
  expectFixedPanic(function() ws:serializeFixed(h, 40, 40, 0, 100) end, "total between 64 and 128")
  expectFixedPanic(function() ws:serializeFixed(h, 8, 8, 0.5, 100) end, "non-integer bounds")

  -- 3. misuse: panicFixedBounds
  expectFixedPanic(function() ws:serializeFixed(h, 8, 8, -200, 100) end, "min below Q8.8 signed capacity")
  expectFixedPanic(function() ws:serializeFixed(h, 8, 8, -100, 128) end, "max above Q8.8 signed capacity")
  expectFixedPanic(function() ws:serializeFixed(h, 32, 0, 0, 4294967296) end, "unsigned Q32.0 capacity")
  check(ws:error() == nil, "misuse must not latch a stream error")

  -- 4. the holder type misuse
  expectPanic(function() ws:serializeFixed({ value = {} }, 8, 8, -100, 100) end, "integer holder")
  expectPanic(function() ws:serializeFixed({ value = 0 }, 64, 64, 0, 100) end, "pair holder")

  -- 5. byte identity with the int64 path for three Q formats
  byteIdentity(8, 8, -100, 100, -832)
  byteIdentity(16, 16, -32768, 32767, 1588444911)
  byteIdentity(32, 0, 0, 7, 5)
end
