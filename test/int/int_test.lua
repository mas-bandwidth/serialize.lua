-- test/int: the ranged integers int, int64 and int128 (DESIGN.md (h)).
-- Run by `make test T=int` from the repository root. Pins: every record of
-- conformance/int.txt, int64.txt and int128.txt (value, bits consumed, canonical
-- bytes, refusal with the destination untouched and the stream terminal), the
-- per-file record count equal to the file's count, serialize.go's TestBitsRequired,
-- TestBitsRequired64 and TestSerializeInt64FullRange edge cases, and the writer's
-- value_out_of_range trap for a value one past each bound.

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

  -- 4. a value one past each bound is write misuse: the trap
  -- (IMPLEMENTING.md U9), naming value_out_of_range, with nothing latched
  do
    local function traps(what, fn)
      local ws = serialize.WriteStream.new(16)
      local ok, err = pcall(fn, ws)
      check(not ok, what .. ": did not trap")
      check(string.find(tostring(err), "write misuse (IMPLEMENTING.md U9): value_out_of_range", 1, true) ~= nil,
        what .. ": the trap was " .. tostring(err))
      check(ws:error() == nil and ws:bitsProcessed() == 0, what .. ": latched or wrote")
    end
    traps("int max+1", function(w) return w:serializeInt({ value = 11 }, 0, 10) end)
    traps("int min-1", function(w) return w:serializeInt({ value = -1 }, 0, 10) end)
    traps("int64 max+1", function(w)
      return w:serializeInt64({ value = 10000000001 }, -10000000000, 10000000000)
    end)
    traps("int64 min-1", function(w)
      return w:serializeInt64({ value = -10000000001 }, -10000000000, 10000000000)
    end)
    local m0 = { lo = 0, hi = 0 }
    local m10 = { lo = 10, hi = 0 }
    traps("int128 max+1", function(w) return w:serializeInt128({ value = { lo = 11, hi = 0 } }, m0, m10) end)
    traps("int128 min-1", function(w)
      return w:serializeInt128({ value = { lo = 0xffffffffffffffff, hi = 0xffffffffffffffff } }, m0, m10)
    end)
  end
end

function TestSerializeInt128SignedDivMod()
  local I = serialize.Int128
  local function eq(v, want, what)
    check(v.lo == want.lo and v.hi == want.hi,
      what .. ": got {lo=" .. tostring(v.lo) .. ",hi=" .. tostring(v.hi)
        .. "} want {lo=" .. tostring(want.lo) .. ",hi=" .. tostring(want.hi) .. "}")
  end
  -- truncating division: quotient toward zero, remainder takes dividend sign
  local cases = {
    { 7, 2, 3, 1 }, { -7, 2, -3, -1 }, { 7, -2, -3, 1 }, { -7, -2, 3, -1 },
    { -6, 3, -2, 0 }, { 6, -3, -2, 0 }, { -6, -3, 2, 0 }, { 6, 3, 2, 0 },
    { 10, 3, 3, 1 }, { -10, 3, -3, -1 }, { 10, -3, -3, 1 }, { -10, -3, 3, -1 },
    { 0, 5, 0, 0 }, { 0, -5, 0, 0 }, { 1, -2, 0, 1 }, { -1, 2, 0, -1 },
    { -100, 7, -14, -2 }, { 100, -7, -14, 2 },
  }
  for _, c in ipairs(cases) do
    local x, y = I.from64(c[1]), I.from64(c[2])
    local wantQ, wantR = I.from64(c[3]), I.from64(c[4])
    local label = "Int128 divMod " .. c[1] .. "/" .. c[2]
    local q, r = I.divMod(x, y)
    eq(q, wantQ, label .. " quotient")
    eq(r, wantR, label .. " remainder")
    eq(I.div(x, y), wantQ, "Int128 div " .. c[1] .. "/" .. c[2])
    eq(I.mod(x, y), wantR, "Int128 mod " .. c[1] .. "/" .. c[2])
  end
  -- serialize.go TestInt128 divCases, with two-lane expected pairs:
  -- the 7/3 sign quadrants, -1/2, the MinInt128 boundaries and
  -- MaxInt128 divided by zero
  local divCases = {
    { { lo = 7, hi = 0 }, { lo = 3, hi = 0 }, { lo = 2, hi = 0 }, { lo = 1, hi = 0 } },
    { { lo = -7, hi = -1 }, { lo = 3, hi = 0 }, { lo = -2, hi = -1 }, { lo = -1, hi = -1 } },
    { { lo = 7, hi = 0 }, { lo = -3, hi = -1 }, { lo = -2, hi = -1 }, { lo = 1, hi = 0 } },
    { { lo = -7, hi = -1 }, { lo = -3, hi = -1 }, { lo = 2, hi = 0 }, { lo = -1, hi = -1 } },
    { { lo = -1, hi = -1 }, { lo = 2, hi = 0 }, { lo = 0, hi = 0 }, { lo = -1, hi = -1 } },
    { { lo = 0, hi = 0x8000000000000000 }, { lo = 2, hi = 0 },
      { lo = 0, hi = 0xc000000000000000 }, { lo = 0, hi = 0 } },
    { { lo = 0, hi = 0x8000000000000000 }, { lo = 1, hi = 0 },
      { lo = 0, hi = 0x8000000000000000 }, { lo = 0, hi = 0 } },
    { { lo = 0, hi = 0x8000000000000000 }, { lo = -1, hi = -1 },
      { lo = 0, hi = 0x8000000000000000 }, { lo = 0, hi = 0 } },
    { { lo = 0xffffffffffffffff, hi = 0x7fffffffffffffff }, { lo = 0, hi = 0 },
      { lo = 0, hi = 0 }, { lo = 0, hi = 0 } },
  }
  for i, c in ipairs(divCases) do
    local x, y, wantQ, wantR = c[1], c[2], c[3], c[4]
    local label = "Int128 divCases[" .. i .. "]"
    local q, r = I.divMod(x, y)
    eq(q, wantQ, label .. " divMod quotient")
    eq(r, wantR, label .. " divMod remainder")
    eq(I.div(x, y), wantQ, label .. " div")
    eq(I.mod(x, y), wantR, label .. " mod")
  end
  -- a dividend wider than 64 bits: 2^64 / 3 and its negation
  local wide = { lo = 0, hi = 1 }
  local q, r = I.divMod(wide, I.from64(3))
  eq(q, I.from64(6148914691236517205), "Int128 divMod 2^64/3 quotient")
  eq(r, I.from64(1), "Int128 divMod 2^64/3 remainder")
  local negWide = I.neg(wide)
  q, r = I.divMod(negWide, I.from64(3))
  eq(q, I.from64(-6148914691236517205), "Int128 divMod -2^64/3 quotient")
  eq(r, I.from64(-1), "Int128 divMod -2^64/3 remainder")
  q, r = I.divMod(negWide, I.from64(-3))
  eq(q, I.from64(6148914691236517205), "Int128 divMod -2^64/-3 quotient")
  eq(r, I.from64(-1), "Int128 divMod -2^64/-3 remainder")
end
