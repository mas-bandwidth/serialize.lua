-- test/uniform: the uniform behaviour rules U1 to U16 of IMPLEMENTING.md
-- (vendored from serialize v2.1.0) that this port proves with its own tests,
-- and the 2026-10-27 audit findings for this port. Run by `make test
-- T=uniform` from the repository root. Each test names its rule. Unit tests:
-- no real time, no sockets, no files.

local serialize = require("serialize")
local S = require("serialize_stream")
local Refusal = serialize.Refusal

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local function raises(fn, want)
  local ok, err = pcall(fn)
  check(not ok, "expected a raise containing: " .. want)
  check(string.find(tostring(err), want, 1, true) ~= nil,
    "raise was \"" .. tostring(err) .. "\", wanted it to contain \"" .. want .. "\"")
end

local SENTINEL = {}

-- refusedRead(what, data, fn): fn(rs, holder) on a fresh read stream over data
-- must not raise, must return false, latch value_out_of_range, consume
-- nothing and leave the holder untouched (U7, U16).
local function refusedRead(what, data, fn)
  local rs = serialize.ReadStream.new(data)
  local h = { value = SENTINEL }
  local ok, r = pcall(fn, rs, h)
  check(ok, what .. ": the read raised: " .. tostring(r))
  check(r == false, what .. ": the read did not refuse")
  check(rs:error() == Refusal.ValueOutOfRange, what .. ": latched " .. tostring(rs:error()))
  check(rs:bitsProcessed() == 0, what .. ": the refused read consumed bits")
  check(h.value == SENTINEL, what .. ": the refused read wrote the holder")
end

-- U1: write buffers are a multiple of 8 bytes, checked.
function TestU1WriteBufferIsAMultipleOf8()
  for _, n in ipairs({ 1, 4, 7, 12, -8, 8.0 }) do
    raises(function() serialize.WriteStream.new(n) end,
      "serialize: bit writer buffer size must be a multiple of 8 bytes")
  end
  for _, n in ipairs({ 0, 8, 16, 1024 }) do
    check(serialize.WriteStream.new(n):ok(), "capacity " .. n .. " is accepted")
  end
end

-- U3, U4: the writer checks UTF-8 and NUL on a string write, as the reader
-- does: a NUL first, then Table 3-7. A string that fails is write misuse and
-- traps (U9), naming the reason, with nothing written and nothing latched.
-- The measure applies the same checks by the same trap (U6).
function TestU4StringWriteChecksUtf8AndNul()
  local cases = {
    { "a\0b", Refusal.EmbeddedNul },
    { "\xff", Refusal.InvalidUtf8 },
    { "\xed\xa0\x80", Refusal.InvalidUtf8 }, -- an encoded lone surrogate
    { "\xc0\xaf", Refusal.InvalidUtf8 },     -- overlong
    { "\xe2\x82", Refusal.InvalidUtf8 },     -- truncated
  }
  for _, c in ipairs(cases) do
    local ws = serialize.WriteStream.new(16)
    raises(function() ws:serializeString({ value = c[1] }, 16) end, "write misuse (IMPLEMENTING.md U9): " .. c[2])
    check(ws:error() == nil, "string write latched " .. tostring(ws:error()))
    check(ws:bitsProcessed() == 0, "a trapped string write wrote bits")
    local ms = serialize.MeasureStream.new()
    raises(function() ms:serializeString({ value = c[1] }, 16) end, "write misuse (IMPLEMENTING.md U9): " .. c[2])
    check(ms:error() == nil and ms:bitsProcessed() == 0, "string measure latched or counted")
  end
  local ws = serialize.WriteStream.new(16)
  check(ws:serializeString({ value = "h\xc3\xa9\xf0\x9f\x98\x80" }, 16), "well formed UTF-8 is written")
end

-- U6: a measure stream refuses nothing: no read refusal is ever latched on it,
-- whatever the misuse; misuse traps as it does on a write (U9), and the
-- measure keeps counting after a trapped call.
function TestU6MeasureRefusesNothing()
  local ms = serialize.MeasureStream.new()
  raises(function() ms:serializeInt({ value = 50 }, 0, 10) end, "value_out_of_range")
  raises(function() ms:serializeInt64({ value = -1 }, 0, 10) end, "value_out_of_range")
  raises(function() ms:serializeDouble({ value = 0 / 0 + 0.0 }) end, "non_finite_float")
  check(ms:serializeObject({ serialize = function() return false end }) == false, "a refusing object fails the call")
  check(ms:fail(Refusal.PastEnd) == false, "fail on a measure returns false")
  check(ms:error() == nil, "a measure latched " .. tostring(ms:error()))
  check(ms:refusal() == "none", "a measure's refusal is none")
  check(ms:serializeBits({ value = 1 }, 3) and ms:bitsProcessed() == 3, "the measure keeps counting")
end

-- U7, U5, U16: a reader never traps. Caller misuse on read refuses as
-- value_out_of_range before any bit moves; the failure state is checked first.
function TestU7ReadMisuseRefusesNeverRaises()
  local data = "\0\0\0\0\0\0\0\0"
  refusedRead("holder not a table", data, function(rs) return rs:serializeBits(nil, 8) end)
  refusedRead("bits 0", data, function(rs, h) return rs:serializeBits(h, 0) end)
  refusedRead("bits 33", data, function(rs, h) return rs:serializeBits(h, 33) end)
  refusedRead("bits64 65", data, function(rs, h) return rs:serializeBits64(h, 65) end)
  refusedRead("bits 8.0", data, function(rs, h) return rs:serializeBits(h, 8.0) end)
  refusedRead("negative byte count", data, function(rs, h) return rs:serializeBytes(h, -1) end)
  refusedRead("string buffer size 0", data, function(rs, h) return rs:serializeString(h, 0) end)
  refusedRead("string buffer size -5", data, function(rs, h) return rs:serializeString(h, -5) end)
  refusedRead("int min > max", data, function(rs, h) return rs:serializeInt(h, 5, 1) end)
  refusedRead("int min below int32 (U5)", data, function(rs, h) return rs:serializeInt(h, -2147483649, 0) end)
  refusedRead("int max above int32 (U5)", data, function(rs, h) return rs:serializeInt(h, 0, 2147483648) end)
  refusedRead("int64 min > max", data, function(rs, h) return rs:serializeInt64(h, 5, 1) end)
  refusedRead("int128 min > max", data, function(rs, h)
    return rs:serializeInt128(h, { lo = 5, hi = 0 }, { lo = 1, hi = 0 })
  end)
  refusedRead("fixed Q format too wide", data, function(rs, h) return rs:serializeFixed(h, 60, 10, 0, 1) end)
  refusedRead("fixed bounds outside the Q format", data, function(rs, h) return rs:serializeFixed(h, 4, 4, 0, 100) end)
  refusedRead("int_relative previous -1", data, function(rs, h) return rs:serializeIntRelative(-1, h) end)
  refusedRead("compressed min >= max", data, function(rs, h) return rs:serializeCompressedFloat(h, 1.0, 1.0, 0.1) end)
  refusedRead("compressed resolution NaN", data, function(rs, h)
    return rs:serializeCompressedFloat(h, 0.0, 1.0, 0 / 0 + 0.0)
  end)
  refusedRead("object that is not an object", data, function(rs) return rs:serializeObject(42) end)

  -- a read stream over something that is not a Lua string latches
  -- value_out_of_range at initialization, and every read refuses
  for _, d in ipairs({ 42, {}, false }) do
    local ok, rs = pcall(serialize.ReadStream.new, d)
    check(ok, "ReadStream.new over a " .. type(d) .. " raised: " .. tostring(rs))
    check(rs:error() == Refusal.ValueOutOfRange, "it latched " .. tostring(rs:error()))
    check(rs:serializeBits({ value = SENTINEL }, 1) == false, "a read on it was accepted")
    rs:reset("\1")
    check(rs:ok(), "reset onto a string clears it")
    local rs2 = serialize.ReadStream.new("\1")
    rs2:reset(d)
    check(rs2:error() == Refusal.ValueOutOfRange, "reset onto a " .. type(d) .. " latched " .. tostring(rs2:error()))
  end

  -- the failure state first: a stream that already failed keeps its reason
  local rs = serialize.ReadStream.new("")
  check(rs:serializeBits({ value = SENTINEL }, 8) == false and rs:error() == Refusal.PastEnd, "past_end first")
  check(rs:serializeBits({ value = SENTINEL }, 99) == false, "misuse on a failed stream refuses")
  check(rs:serializeString({ value = SENTINEL }, 0) == false, "misuse on a failed stream refuses")
  check(rs:error() == Refusal.PastEnd, "the first reason was replaced by " .. tostring(rs:error()))

  -- the same declarations still raise on write and measure (the port's
  -- write-misuse mechanism, DESIGN.md (g))
  raises(function() serialize.WriteStream.new(8):serializeBits({ value = 0 }, 33) end, "serialize: bits must be in [1,32]")
  raises(function() serialize.MeasureStream.new():serializeInt({ value = 0 }, 0, 2147483648) end,
    "serialize: serializeInt bounds must be in int32")
  raises(function() serialize.WriteStream.new(8):serializeString({ value = "" }, 0) end,
    "serialize: string buffer size must be in [1,1<<31)")
end

-- U8 (AUDIT-LEDGER 2026-10-27, lua M, audit/bits_overwide.lua): a value that
-- does not fit its bit width is caught, never masked. The write traps (U9)
-- and writes nothing; the measure traps the same way (U6).
function TestU8OverwideBitsAreCaught()
  local cases = {
    { "serializeBits", 300, 8 }, { "serializeBits", 2, 1 }, { "serializeBits", 0xffffffff, 31 },
    { "serializeBits64", 1 << 40, 40 }, { "serializeBits64", -1, 63 }, { "serializeBits64", 1 << 32, 32 },
  }
  for _, c in ipairs(cases) do
    local what = c[1] .. "(" .. c[2] .. ", " .. c[3] .. ")"
    local ws = serialize.WriteStream.new(16)
    raises(function() ws[c[1]](ws, { value = c[2] }, c[3]) end, "value_out_of_range")
    check(ws:error() == nil, what .. ": the write latched " .. tostring(ws:error()))
    check(ws:bitsProcessed() == 0, what .. ": the trapped write wrote bits")
    local ms = serialize.MeasureStream.new()
    raises(function() ms[c[1]](ms, { value = c[2] }, c[3]) end, "value_out_of_range")
    check(ms:error() == nil and ms:bitsProcessed() == 0, what .. ": the measure latched or counted")
  end
  -- the widest values that fit are written exactly
  local ws = serialize.WriteStream.new(16)
  check(ws:serializeBits({ value = 255 }, 8) and ws:serializeBits({ value = 0xffffffff }, 32)
    and ws:serializeBits64({ value = -1 }, 64), "values that fit their width are written")
  ws:flush()
  local rs = serialize.ReadStream.new(ws:data())
  local a, b, c = {}, {}, {}
  check(rs:serializeBits(a, 8) and rs:serializeBits(b, 32) and rs:serializeBits64(c, 64), "they read back")
  check(a.value == 255 and b.value == 0xffffffff and c.value == -1, "and read back exactly")
end

-- U9, U14: the public fail. On a read, a listed reason latches as given, and
-- nil or anything else latches rejected, through the one latch; on a write or
-- a measure it returns false, records nothing, never raises.
function TestU9U14PublicFail()
  for _, reason in ipairs({ Refusal.PastEnd, Refusal.NonCanonical, Refusal.Rejected }) do
    local rs = serialize.ReadStream.new("")
    check(rs:fail(reason) == false and rs:error() == reason, "fail(" .. reason .. ") latches it")
    check(rs:refusal() == reason, "the refusal's name is " .. reason)
  end
  for _, reason in ipairs({ nil, "none", "bad", 42, true }) do
    local rs = serialize.ReadStream.new("")
    check(rs:fail(reason) == false, "fail(" .. tostring(reason) .. ") returns false")
    check(rs:error() == Refusal.Rejected, "fail(" .. tostring(reason) .. ") latched " .. tostring(rs:error()))
  end
  local rs = serialize.ReadStream.new("")
  rs:fail(Refusal.TrailingData)
  check(rs:fail(Refusal.PastEnd) == false and rs:error() == Refusal.TrailingData, "the first reason wins")
  for _, s in ipairs({ serialize.WriteStream.new(8), serialize.MeasureStream.new() }) do
    check(s:fail(Refusal.PastEnd) == false and s:fail() == false, "fail on write/measure returns false")
    check(s:error() == nil and s:refusal() == "none", "fail on write/measure recorded something")
  end
  -- a write object that refuses fails the call and latches nothing
  local ws = serialize.WriteStream.new(8)
  check(ws:serializeObject({ serialize = function() return false end }) == false, "a refusing object fails the call")
  check(ws:error() == nil, "a write object latched " .. tostring(ws:error()))
end

-- U10: a write checks room for the whole operation before writing any of it:
-- no length bits and no align bits ahead of a payload that does not fit. An
-- operation that does not fit is write misuse, and traps (U9).
function TestU10WholeOperationRoom()
  -- string: 8 length bits fit in 8 bytes, the 8 byte payload does not
  local ws = serialize.WriteStream.new(8)
  check(ws:serializeBits({ value = 1 }, 3), "three bits first")
  raises(function() ws:serializeString({ value = "abcdefgh" }, 200) end, "past_end")
  check(ws:error() == nil, "it latched " .. tostring(ws:error()))
  check(ws:bitsProcessed() == 3, "the trapped string wrote " .. (ws:bitsProcessed() - 3) .. " bits")
  -- bytes: the align would fit, the payload does not
  ws = serialize.WriteStream.new(8)
  check(ws:serializeBits({ value = 1 }, 3), "three bits first")
  raises(function() ws:serializeBytes({ value = "12345678" }, 8) end, "past_end")
  check(ws:error() == nil and ws:bitsProcessed() == 3, "the trapped bytes wrote align bits")
  -- the exact fit is accepted
  ws = serialize.WriteStream.new(8)
  check(ws:serializeBits({ value = 1 }, 3) and ws:serializeBytes({ value = "1234567" }, 7), "an exact fit")
  check(ws:bitsProcessed() == 64, "the exact fit fills the buffer")
end

-- U12: end on a write or a measure is a no-op returning true, after a
-- trapped write too.
function TestU12EndOnWriteAndMeasureIsTrue()
  local ws = serialize.WriteStream.new(0)
  check(ws:serializeEnd() == true, "end on a healthy write")
  raises(function() ws:serializeBits({ value = 1 }, 1) end, "past_end")
  check(ws:serializeEnd() == true and ws:bitsProcessed() == 0, "end after a trapped write")
  local ms = serialize.MeasureStream.new()
  check(ms:serializeEnd() == true and ms:bitsProcessed() == 0, "end on a measure")
end

-- U14: the refusal-name function, with the family spellings and "none".
function TestU14RefusalName()
  check(serialize.refusalName(nil) == "none", "no refusal is none")
  for _, r in pairs(Refusal) do
    check(serialize.refusalName(r) == r, "the name of " .. r)
  end
  raises(function() serialize.refusalName("bad") end, "serialize: refusalName takes nil or a reason")
  local rs = serialize.ReadStream.new("")
  check(rs:refusal() == "none", "a healthy read stream's refusal is none")
  rs:reject()
  check(rs:refusal() == "rejected", "a rejected stream's refusal is rejected")
end

-- U16 (AUDIT-LEDGER 2026-10-27, lua M, audit/precomputed_domain.lua): the
-- precomputed compressed_float's maxIntegerValue lies in [1, 4294967040],
-- judged before bitsRequired narrows it to 32 bits. Read refuses
-- value_out_of_range before any bit moves; write and measure raise.
function TestU16PrecomputedMaxIntegerValueDomain()
  local bad = {
    { 1 << 32, 0 },          -- bitsRequired(0, 2^32) is 0 over 32 bits
    { (1 << 32) + 5, 3 },    -- bitsRequired(0, 2^32 + 5) is 3 over 32 bits
    { 4294967041, 32 },      -- one past the clamp
    { -5, 32 },
    { 0, 0 },
  }
  for _, c in ipairs(bad) do
    local what = "maxIntegerValue " .. c[1] .. " bits " .. c[2]
    refusedRead(what, "\7\0\0\0\0\0\0\0", function(rs, h)
      return rs:serializeCompressedFloatPrecomputed(h, c[1], c[2], 10.0, 0.0)
    end)
    raises(function()
      serialize.WriteStream.new(8):serializeCompressedFloatPrecomputed({ value = 1.0 }, c[1], c[2], 10.0, 0.0)
    end, "serialize: precomputed compressed float constants")
    raises(function()
      serialize.MeasureStream.new():serializeCompressedFloatPrecomputed({ value = 1.0 }, c[1], c[2], 10.0, 0.0)
    end, "serialize: precomputed compressed float constants")
  end
  -- the top of the domain is accepted, as compressedFloatParams derives it
  local maxInt, bits, delta = serialize.compressedFloatParams(0.0, 1.0, 1e-12)
  check(maxInt == 4294967040 and bits == 32, "the derivation clamps to 4294967040 in 32 bits")
  local ws = serialize.WriteStream.new(8)
  check(ws:serializeCompressedFloatPrecomputed({ value = 0.5 }, maxInt, bits, delta, 0.0), "the top is accepted")
end

-- AUDIT-LEDGER 2026-10-27, lua L (audit/int32_build.lua): the library refuses
-- to load on an interpreter built with LUA_32BITS. The guard is a pure
-- function of math.maxinteger, faked here; the pinned interpreter passes it.
function TestIntegerWidthGuard()
  check(S.integerWidthError(math.maxinteger) == nil, "the pinned 64-bit interpreter passes the guard")
  local e = S.integerWidthError(2147483647)
  check(e ~= nil and e:find("LUA_32BITS", 1, true) ~= nil, "a 32-bit maxinteger is refused by name")
  check(S.integerWidthError(-1) ~= nil, "a wrapped maxinteger is refused")
end
