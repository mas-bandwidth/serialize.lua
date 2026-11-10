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
  check(serialize.bitsRequired64(0, 0xffffffffffffffff) == 64, "BitsRequired64(0,0xFFFFFFFFFFFFFFFF) = 64")

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

-- The two-lane 128-bit helpers (serialize.go int128.go). Every exported
-- Uint128 and Int128 operation, and bitsRequired128, is pinned against the
-- known-answer vectors of serialize.go's TestUint128, TestInt128 and
-- TestBitsRequired128.
function TestSerializeInt128PairOps()
  local U = serialize.Uint128
  local I = serialize.Int128

  local function pair(hi, lo) return { lo = lo, hi = hi } end
  local function eq(v, want, what)
    check(type(v) == "table" and v.lo == want.lo and v.hi == want.hi,
      what .. ": got {lo=" .. tostring(v and v.lo) .. ",hi=" .. tostring(v and v.hi)
        .. "} want {lo=" .. tostring(want.lo) .. ",hi=" .. tostring(want.hi) .. "}")
  end

  local lo = 0xfedcba9876543210
  local hi = 0x0123456789abcdef

  -- construction and lane conversions
  do
    local v = U.from64(lo)
    check(v.lo == lo and v.hi == 0 and U.uint64(v) == lo, "Uint128.from64/uint64")
    check(U.uint64(pair(hi, lo)) == lo, "Uint128.uint64 truncates to the low lane")
    eq(I.uint128(I.from64(-1)), pair(-1, -1), "Int128.from64(-1) sign extends")
    eq(I.uint128(I.from64(math.mininteger)), pair(-1, math.mininteger),
      "Int128.from64(MinInt64) sign extends")
    eq(I.uint128(I.from64(math.maxinteger)), pair(0, math.maxinteger),
      "Int128.from64(MaxInt64) sign extends")
    eq(U.from64(1 << 63), pair(0, 1 << 63), "Uint128.from64(1<<63) zero extends")
    eq(I.uint128(I.from64(7)), pair(0, 7), "Int128.from64(7) zero high lane")
    check(I.int64(I.from64(-5)) == -5 and I.int64(I.from64(math.mininteger)) == math.mininteger,
      "Int128.int64 truncates to the low lane")
    eq(U.int128(pair(hi, lo)), pair(hi, lo), "Uint128.int128 preserves the pattern")
    eq(I.uint128(I.from64(-1)), pair(-1, -1), "Int128.uint128 preserves the pattern")
  end

  -- ordering, length and zero tests
  do
    local a, b, c = pair(1, 0), pair(0, -1), pair(1, 1)
    check(U.cmp(a, b) > 0 and U.cmp(b, a) < 0, "Uint128.cmp: the high lane dominates")
    check(U.cmp(c, a) > 0, "Uint128.cmp: the low lane breaks ties")
    check(U.cmp(a, pair(1, 0)) == 0, "Uint128.cmp: equality")
    check(U.isZero(pair(0, 0)) and not U.isZero(pair(0, 1)), "Uint128.isZero")
    check(U.len(pair(0, 0)) == 0 and U.len(U.from64(1)) == 1
      and U.len(pair(1, 0)) == 65 and U.len(pair(-1, -1)) == 128, "Uint128.len")

    local intMin, intMax = pair(0x8000000000000000, 0), pair(0x7fffffffffffffff, -1)
    local minusOne, zero = I.from64(-1), pair(0, 0)
    check(I.cmp(minusOne, zero) < 0 and I.cmp(zero, I.from64(1)) < 0,
      "Int128.cmp: negatives below positives")
    check(I.cmp(intMin, I.from64(math.mininteger)) < 0 and I.cmp(intMin, minusOne) < 0,
      "Int128.cmp: MinInt128 below every int64")
    check(I.cmp(intMax, I.from64(math.maxinteger)) > 0 and I.cmp(intMin, intMax) < 0,
      "Int128.cmp: MaxInt128 above every int64")
    check(I.cmp(pair(-1, 5), pair(-1, 7)) < 0, "Int128.cmp: the low lane breaks sign ties")
    check(I.cmp(I.from64(1), minusOne) > 0, "Int128.cmp: 1 > -1")
    check(I.cmp(U.int128(U.from64(1 << 63)), zero) > 0, "Int128.cmp: 2^63 is positive")
    check(I.isNegative(minusOne) and I.isNegative(intMin)
      and not I.isNegative(zero) and not I.isNegative(intMax), "Int128.isNegative")
  end

  -- arithmetic
  do
    local max64, allOnes, one = U.from64(-1), pair(-1, -1), U.from64(1)
    eq(U.add(max64, one), pair(1, 0), "Uint128.add: carry out of the low lane")
    eq(U.add(allOnes, one), pair(0, 0), "Uint128.add: wraps modulo 2^128")
    eq(U.sub(pair(0, 0), one), allOnes, "Uint128.sub: borrow wraps back")
    eq(U.sub(pair(1, 0), one), max64, "Uint128.sub: borrow out of the high lane")

    local twoTo32 = U.from64(1 << 32)
    eq(U.mul(U.from64(3), U.from64(5)), U.from64(15), "Uint128.mul: 3*5")
    eq(U.mul(twoTo32, twoTo32), pair(1, 0), "Uint128.mul: 2^64 crosses into the high lane")
    eq(U.mul(max64, max64), pair(0xfffffffffffffffe, 1), "Uint128.mul: max64*max64")
    eq(U.mul(pair(1, 0), U.from64(5)), pair(5, 0), "Uint128.mul: the high lane path")
    eq(U.mul(allOnes, allOnes), one, "Uint128.mul: (2^128-1)^2 mod 2^128")

    eq(U.neg(pair(0, 0)), pair(0, 0), "Uint128.neg: -0")
    eq(U.neg(one), allOnes, "Uint128.neg: -1 wraps to all ones")
    eq(U.add(U.neg(pair(hi, lo)), pair(hi, lo)), pair(0, 0), "Uint128.neg: -v + v")

    eq(I.add(I.from64(-3), I.from64(5)), I.from64(2), "Int128.add: -3 + 5")
    eq(I.sub(I.from64(3), I.from64(5)), I.from64(-2), "Int128.sub: 3 - 5")
    eq(I.mul(I.from64(-3), I.from64(5)), I.from64(-15), "Int128.mul: -3 * 5")
    eq(I.mul(I.from64(-3), I.from64(-5)), I.from64(15), "Int128.mul: -3 * -5")
    eq(I.add(pair(0x7fffffffffffffff, -1), I.from64(1)), pair(0x8000000000000000, 0),
      "Int128.add: MaxInt128 + 1 wraps")
    eq(I.sub(pair(0x8000000000000000, 0), I.from64(1)), pair(0x7fffffffffffffff, -1),
      "Int128.sub: MinInt128 - 1 wraps")
    eq(I.mul(I.from64(math.maxinteger), I.from64(4)), pair(1, -4),
      "Int128.mul: crosses the lane boundary")
    eq(I.neg(I.from64(5)), I.from64(-5), "Int128.neg: 5")
    eq(I.neg(I.from64(-5)), I.from64(5), "Int128.neg: -5")
    eq(I.neg(pair(0x8000000000000000, 0)), pair(0x8000000000000000, 0),
      "Int128.neg: MinInt128 wraps to itself")
  end

  -- division and modulo, including the wide and degenerate cases
  do
    local allOnes = pair(-1, -1)
    local udiv = {
      { U.from64(100), U.from64(7), U.from64(14), U.from64(2) },
      { pair(1, 7), U.from64(16), U.from64(1 << 60), U.from64(7) },
      { pair(1 << 63, 0), pair(1, 0), U.from64(1 << 63), pair(0, 0) },
      { allOnes, U.from64(3), pair(0x5555555555555555, 0x5555555555555555), pair(0, 0) },
      { U.from64(7), pair(1, 0), pair(0, 0), U.from64(7) },
      { allOnes, pair(0, 0), pair(0, 0), pair(0, 0) },
    }
    for idx, c in ipairs(udiv) do
      local q, r = U.divMod(c[1], c[2])
      eq(q, c[3], "Uint128.divMod[" .. idx .. "] quotient")
      eq(r, c[4], "Uint128.divMod[" .. idx .. "] remainder")
      eq(U.div(c[1], c[2]), c[3], "Uint128.div[" .. idx .. "]")
      eq(U.mod(c[1], c[2]), c[4], "Uint128.mod[" .. idx .. "]")
    end

    local intMin = pair(0x8000000000000000, 0)
    local intMax = pair(0x7fffffffffffffff, -1)
    local minusOne, zero = I.from64(-1), pair(0, 0)
    local idiv = {
      { intMin, I.from64(2), pair(0xc000000000000000, 0), zero },
      { intMin, I.from64(1), intMin, zero },
      { intMin, minusOne, intMin, zero },
      { intMax, zero, zero, zero },
    }
    for idx, c in ipairs(idiv) do
      local q, r = I.divMod(c[1], c[2])
      eq(q, c[3], "Int128.divMod[" .. idx .. "] quotient")
      eq(r, c[4], "Int128.divMod[" .. idx .. "] remainder")
      eq(I.div(c[1], c[2]), c[3], "Int128.div[" .. idx .. "]")
      eq(I.mod(c[1], c[2]), c[4], "Int128.mod[" .. idx .. "]")
    end
  end

  -- bitwise operations
  do
    local p = pair(0xf0f0f0f0f0f0f0f0, -0x5555555555555556)
    local q = pair(0xff00ff00ff00ff00, -0x3333333333333334)
    eq(U.band(p, q), pair(0xf000f000f000f000, -0x7777777777777778), "Uint128.band")
    eq(U.bor(p, q), pair(0xfff0fff0fff0fff0, -0x1111111111111112), "Uint128.bor")
    eq(U.bxor(p, q), pair(0x0ff00ff00ff00ff0, 0x6666666666666666), "Uint128.bxor")
    eq(U.bnot(p), pair(0x0f0f0f0f0f0f0f0f, 0x5555555555555555), "Uint128.bnot")

    local minusOne, zero = I.from64(-1), pair(0, 0)
    eq(I.bnot(zero), minusOne, "Int128.bnot")
    eq(I.band(minusOne, I.from64(5)), I.from64(5), "Int128.band")
    eq(I.bor(zero, minusOne), minusOne, "Int128.bor")
    eq(I.bxor(minusOne, minusOne), zero, "Int128.bxor")
  end

  -- shifts, including the counts at and past 128 that yield zero
  do
    local v = pair(hi, lo)
    local lsh = {
      { 0, v }, { 1, pair(hi << 1 | lo >> 63, lo << 1) },
      { 63, pair(hi << 63 | lo >> 1, lo << 63) },
      { 64, pair(lo, 0) }, { 65, pair(lo << 1, 0) }, { 127, pair(lo << 63, 0) },
      { 128, pair(0, 0) }, { 200, pair(0, 0) },
    }
    for _, c in ipairs(lsh) do
      eq(U.lsh(v, c[1]), c[2], "Uint128.lsh(" .. c[1] .. ")")
    end
    local rsh = {
      { 0, v }, { 1, pair(hi >> 1, lo >> 1 | hi << 63) },
      { 63, pair(hi >> 63, lo >> 63 | hi << 1) },
      { 64, pair(0, hi) }, { 65, pair(0, hi >> 1) }, { 127, pair(0, hi >> 63) },
      { 128, pair(0, 0) }, { 200, pair(0, 0) },
    }
    for _, c in ipairs(rsh) do
      eq(U.rsh(v, c[1]), c[2], "Uint128.rsh(" .. c[1] .. ")")
    end

    local intMin = pair(0x8000000000000000, 0)
    local intMax = pair(0x7fffffffffffffff, -1)
    local minusOne, zero = I.from64(-1), pair(0, 0)
    local irsh = {
      { intMin, 0, intMin }, { intMin, 1, pair(0xc000000000000000, 0) },
      { intMin, 63, pair(-1, 0) }, { intMin, 64, I.from64(math.mininteger) },
      { intMin, 65, I.from64(math.mininteger // 2) }, { intMin, 127, minusOne },
      { intMin, 128, minusOne }, { intMin, 200, minusOne },
      { I.from64(-7), 1, I.from64(-4) }, { intMax, 127, zero }, { intMax, 128, zero },
      { I.lsh(I.from64(1), 100), 100, I.from64(1) },
    }
    for _, c in ipairs(irsh) do
      eq(I.rsh(c[1], c[2]), c[3], "Int128.rsh(" .. c[2] .. ")")
    end
    eq(I.lsh(minusOne, 1), I.from64(-2), "Int128.lsh: -1 << 1")
    eq(I.lsh(minusOne, 64), pair(-1, 0), "Int128.lsh: -1 << 64")
    eq(I.lsh(I.from64(1), 127), intMin, "Int128.lsh: 1 << 127")
    eq(I.lsh(minusOne, 128), zero, "Int128.lsh(128) yields zero")
    eq(I.lsh(minusOne, 200), zero, "Int128.lsh(200) yields zero")
  end

  -- bitsRequired128
  do
    local br = serialize.bitsRequired128
    local cases = {
      { pair(0, 0), pair(0, 0), 0 },
      { pair(0, 0), pair(0, 1), 1 },
      { pair(0, 0), pair(0, 255), 8 },
      { pair(0, 0), pair(0, 4294967295), 32 },
      { pair(0, 0), pair(0, 4294967296), 33 },
      { pair(0, 0), pair(0, -1), 64 },
      { pair(0, 0), pair(1, 0), 65 },
      { pair(0, 0), U.lsh(U.from64(1), 127), 128 },
      { pair(0, 0), pair(-1, -1), 128 },
      { I.uint128(I.from64(-5000000000)), I.uint128(I.from64(5000000000)), 34 },
      { U.from64(-5000000000), U.from64(5000000000), 128 },
      { U.from64(1), pair(-1, -1), 128 },
    }
    for idx, c in ipairs(cases) do
      check(br(c[1], c[2]) == c[3], "bitsRequired128[" .. idx .. "] = " .. c[3])
    end
  end
end
