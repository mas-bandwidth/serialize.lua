-- test/int: the ranged integers int, int64 and int128 (DESIGN.md (h)).
-- Run by `make test T=int` from the repository root. Pins: every record of
-- conformance/int.txt, int64.txt and int128.txt (value, bits consumed, canonical
-- bytes, refusal with the destination untouched and the stream terminal), the
-- per-file record count equal to the file's count, serialize.go's TestBitsRequired,
-- TestBitsRequired64 and TestSerializeInt64FullRange edge cases, and the writer's
-- value_out_of_range latch for a value one past each bound.

local serialize = require("serialize")

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

--------------------------------------------------------------------------------
-- The corpus records run through the shared runner (test/conformance): values
-- exactly (both 64-bit halves of a 128-bit value), bits consumed, the stated
-- refusal reason, the destination untouched, the stream terminal, the
-- canonical bytes.
--------------------------------------------------------------------------------

local C = assert(loadfile("test/conformance/conformance_test.lua"))()

local function runFile(op, path)
  local records = C.parseVectors(path)
  for _, rec in ipairs(records) do
    check(rec.operation == op, path .. ": " .. rec.name .. " is not " .. op)
    C.runRecord(rec)
  end
  print(path .. ": " .. #records .. " records")
end

--------------------------------------------------------------------------------
-- Reference bit-length helpers (for the uint64-only edge cases).
--------------------------------------------------------------------------------

local function bitlen(n)
  local c = 0
  while n > 0 do
    n = n >> 1
    c = c + 1
  end
  return c
end

local function refBitsReq64(min, max)
  if min == max then return 0 end
  if max - min < 0 then return 64 end
  return bitlen(max - min)
end

function TestSerializeInt()
  -- loading the int families creates no global (DESIGN.md (f)): snapshot before
  -- the first call, which is what makes the lazy loader require them
  local before = {}
  for k in pairs(_G) do before[k] = true end

  -- 1. the conformance corpus, record by record, with per-file counts
  runFile("int", "conformance/int.txt")
  runFile("int64", "conformance/int64.txt")
  runFile("int128", "conformance/int128.txt")
  for k in pairs(_G) do
    check(before[k], "loading the int families created the global " .. tostring(k))
  end

  -- 2. serialize.go TestBitsRequired / TestBitsRequired64 edge cases, through the
  -- actual serialized width (a measure of the shipped range-width logic)
  local cases32 = {
    { 0, 0, 0 }, { 0, 1, 1 }, { 0, 2, 2 }, { 0, 3, 2 },
    { 0, 4, 3 }, { 0, 5, 3 }, { 0, 6, 3 }, { 0, 7, 3 },
    { 0, 8, 4 }, { 0, 255, 8 }, { 0, 65535, 16 }, { 0, 4294967295, 32 },
  }
  for _, c in ipairs(cases32) do
    local ws = serialize.WriteStream.new(16)
    check(ws:serializeInt64({ value = c[1] }, c[1], c[2]) and ws:bitsProcessed() == c[3],
      "BitsRequired64 case [" .. c[1] .. "," .. c[2] .. "] width " .. c[3])
  end

  local cases64 = {
    { 0, 0, 0 }, { 0, 1, 1 }, { 0, 255, 8 }, { 0, 4294967295, 32 },
    { 0, 4294967296, 33 }, { 0, 1 << 40, 41 },
    { math.mininteger, math.maxinteger, 64 },
    { -5000000000, 5000000000, 34 },
  }
  for _, c in ipairs(cases64) do
    local ws = serialize.WriteStream.new(16)
    check(ws:serializeInt64({ value = c[1] }, c[1], c[2]) and ws:bitsProcessed() == c[3],
      "BitsRequired64 case [" .. c[1] .. "," .. c[2] .. "] width " .. c[3])
  end
  -- the one case the signed int64 stream cannot express: the full uint64 span
  check(refBitsReq64(0, 0xffffffffffffffff) == 64, "BitsRequired64(0,0xFFFFFFFFFFFFFFFF) = 64")

  -- 3. serialize.go TestSerializeInt64FullRange
  do
    local min64, max64 = math.mininteger, math.maxinteger
    for _, v in ipairs({ min64, min64 + 1, -1, 0, 1, max64 - 1, max64 }) do
      local ws = serialize.WriteStream.new(16)
      check(ws:serializeInt64({ value = v }, min64, max64))
      ws:flush()
      local rs = serialize.ReadStream.new(ws:data())
      local h = {}
      check(rs:serializeInt64(h, min64, max64), "full-range read failed")
      check(h.value == v, "full-range round trip mismatch: " .. tostring(v))
    end
    local mn, mx = -5000000000, 5000000000
    for _, v in ipairs({ mn, mn + 1, -1, 0, 1, 4123456789, mx - 1, mx }) do
      local ws = serialize.WriteStream.new(16)
      check(ws:serializeInt64({ value = v }, mn, mx))
      ws:flush()
      local rs = serialize.ReadStream.new(ws:data())
      local h = {}
      check(rs:serializeInt64(h, mn, mx), "two-dword read failed")
      check(h.value == v, "two-dword round trip mismatch: " .. tostring(v))
    end
    local ws = serialize.WriteStream.new(8)
    check(ws:serializeInt64({ value = 55 }, -100, 100))
    ws:flush()
    check(ws:bitsProcessed() == 8, "BitsRequired64(-100,100) = 8")
    local rs = serialize.ReadStream.new(ws:data())
    local h = {}
    check(rs:serializeInt64(h, -100, 100) and h.value == 55, "small-range round trip")
  end

  -- 4. the writer's value_out_of_range latch for a value one past each bound
  do
    check(serialize.WriteStream.new(16):serializeInt({ value = 11 }, 0, 10) == false, "int max+1 must latch")
    local w1 = serialize.WriteStream.new(16)
    check(w1:serializeInt({ value = 11 }, 0, 10) == false
      and w1:error() == serialize.Refusal.ValueOutOfRange, "int max+1 latches value_out_of_range")
    local w2 = serialize.WriteStream.new(16)
    check(w2:serializeInt({ value = -1 }, 0, 10) == false
      and w2:error() == serialize.Refusal.ValueOutOfRange, "int min-1 latches value_out_of_range")

    local w3 = serialize.WriteStream.new(16)
    check(w3:serializeInt64({ value = 10000000001 }, -10000000000, 10000000000) == false
      and w3:error() == serialize.Refusal.ValueOutOfRange, "int64 max+1 latches value_out_of_range")
    local w4 = serialize.WriteStream.new(16)
    check(w4:serializeInt64({ value = -10000000001 }, -10000000000, 10000000000) == false
      and w4:error() == serialize.Refusal.ValueOutOfRange, "int64 min-1 latches value_out_of_range")

    local m0 = { lo = 0, hi = 0 }
    local m10 = { lo = 10, hi = 0 }
    local w5 = serialize.WriteStream.new(16)
    check(w5:serializeInt128({ value = { lo = 11, hi = 0 } }, m0, m10) == false
      and w5:error() == serialize.Refusal.ValueOutOfRange, "int128 max+1 latches value_out_of_range")
    local w6 = serialize.WriteStream.new(16)
    check(w6:serializeInt128({ value = { lo = 0xffffffffffffffff, hi = 0xffffffffffffffff } }, m0, m10) == false
      and w6:error() == serialize.Refusal.ValueOutOfRange, "int128 min-1 latches value_out_of_range")
  end
end
