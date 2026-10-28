-- test/u9: the 2.1.1 rulings of IMPLEMENTING.md (vendored from serialize
-- v2.1.1): U9, one write-misuse mechanism, the trap; U6, a measure traps on
-- every misuse a write traps on and latches nothing; and U15's
-- serialize_copy_string. This port has no unchecked build, so its trap is
-- Lua's error(), raised at the call, in every run. Run by `make test T=u9`
-- from the repository root. Unit tests: no real time, no sockets, no files.

local serialize = require("serialize")
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

local NAN = 0 / 0 + 0.0
local INF = math.huge

-- Every value misuse U9 names, as (name, fn(stream)) over a fresh stream that
-- has room for it. Each must trap on a write and on a measure (U6).
local VALUE_MISUSE = {
  { "int above max", function(s) return s:serializeInt({ value = 50 }, 0, 10) end },
  { "int below min", function(s) return s:serializeInt({ value = -1 }, 0, 10) end },
  { "int64 below min", function(s) return s:serializeInt64({ value = -1 }, 0, 10) end },
  { "int128 above max", function(s)
    return s:serializeInt128({ value = { lo = 11, hi = 0 } }, { lo = 0, hi = 0 }, { lo = 10, hi = 0 })
  end },
  { "fixed outside its raw range", function(s) return s:serializeFixed({ value = 100 }, 4, 4, 0, 1) end },
  { "int_relative current not above previous", function(s) return s:serializeIntRelative(5, { value = 3 }) end },
  { "bits 0x1FF in 8", function(s) return s:serializeBits({ value = 0x1FF }, 8) end },
  { "bits64 2^40 in 40", function(s) return s:serializeBits64({ value = 1 << 40 }, 40) end },
  { "float 1e39 narrows to inf", function(s) return s:serializeFloat({ value = 1e39 }) end },
  { "float NaN", function(s) return s:serializeFloat({ value = NAN }) end },
  { "float -inf", function(s) return s:serializeFloat({ value = -INF }) end },
  { "double inf", function(s) return s:serializeDouble({ value = INF }) end },
  { "double NaN", function(s) return s:serializeDouble({ value = NAN }) end },
  { "string invalid UTF-8", function(s) return s:serializeString({ value = "\xff" }, 16) end },
  { "string lone surrogate", function(s) return s:serializeString({ value = "\xed\xa0\x80" }, 16) end },
  { "string with a NUL", function(s) return s:serializeString({ value = "a\0b" }, 16) end },
  { "string longer than buffer_size - 1", function(s) return s:serializeString({ value = "abcd" }, 4) end },
  { "compressed_float NaN value", function(s)
    return s:serializeCompressedFloat({ value = NAN }, 0.0, 1.0, 0.1)
  end },
  { "compressed_float delta / res not finite", function(s)
    return s:serializeCompressedFloat({ value = 1.0 }, 0.0, 1e38, 1e-38)
  end },
  { "compressed_float top decode not finite", function(s)
    return s:serializeCompressedFloat({ value = 0.0 }, -3e38, 3e38, 1e30)
  end },
}

-- U9: every write misuse traps at the call; nothing is written, nothing is
-- latched, and the stream goes on writing exactly as it would have.
function TestU9WriteMisuseTraps()
  for _, c in ipairs(VALUE_MISUSE) do
    local ws = serialize.WriteStream.new(64)
    check(ws:serializeBits({ value = 5 }, 3), c[1] .. ": the prefix write")
    local ok = pcall(c[2], ws)
    check(not ok, c[1] .. ": the write did not trap")
    check(ws:error() == nil and ws:refusal() == "none", c[1] .. ": the write latched " .. tostring(ws:error()))
    check(ws:bitsProcessed() == 3, c[1] .. ": the trapped write wrote " .. (ws:bitsProcessed() - 3) .. " bits")
    check(ws:serializeBits({ value = 2 }, 2), c[1] .. ": the write after the trap was refused")
    ws:flush()
    check(ws:data() == "\21", c[1] .. ": the later write did not emit what it would have")
  end
end

-- U9: room is write misuse too. A write that does not fit the room left traps
-- before any bit of it is written (U10), and latches no past_end.
function TestU9PastEndTraps()
  local cases = {
    { "bits past end", 0, function(s) return s:serializeBits({ value = 1 }, 1) end },
    { "bits64 past end", 8, function(s)
      return s:serializeBits({ value = 1 }, 3) and s:serializeBits64({ value = -1 }, 64)
    end },
    { "bytes payload past end", 8, function(s)
      return s:serializeBits({ value = 1 }, 3) and s:serializeBytes({ value = "12345678" }, 8)
    end },
    { "string payload past end", 8, function(s)
      return s:serializeBits({ value = 1 }, 3) and s:serializeString({ value = "abcdefgh" }, 200)
    end },
    { "uint128 past end", 8, function(s) return s:serializeUint128({ value = { lo = 1, hi = 2 } }) end },
  }
  for _, c in ipairs(cases) do
    local ws = serialize.WriteStream.new(c[2])
    local ok, err = pcall(c[3], ws)
    check(not ok, c[1] .. ": did not trap")
    check(string.find(tostring(err), "past_end", 1, true) ~= nil, c[1] .. ": the trap does not name past_end: " .. tostring(err))
    check(ws:error() == nil, c[1] .. ": latched " .. tostring(ws:error()))
    check(ws:bitsProcessed() == 0 or ws:bitsProcessed() == 3, c[1] .. ": wrote part of the operation")
  end
  -- an exact fit is not misuse
  local ws = serialize.WriteStream.new(8)
  check(ws:serializeBits({ value = 1 }, 3) and ws:serializeBytes({ value = "1234567" }, 7), "an exact fit")
end

-- U6: a measure makes every check a write makes (except room) by the same trap
-- and latches nothing; it goes on counting after a trapped call.
function TestU6MeasureTrapsLikeWrite()
  for _, c in ipairs(VALUE_MISUSE) do
    local ms = serialize.MeasureStream.new()
    local ok = pcall(c[2], ms)
    check(not ok, c[1] .. ": the measure did not trap")
    check(ms:error() == nil and ms:refusal() == "none", c[1] .. ": the measure latched " .. tostring(ms:error()))
    local before = ms:bitsProcessed()
    check(ms:serializeBits({ value = 1 }, 3) and ms:bitsProcessed() == before + 3, c[1] .. ": the measure stopped counting")
  end
  -- a measure has no room to run out of
  local ms = serialize.MeasureStream.new()
  check(ms:serializeBytes({ value = string.rep("x", 4096) }, 4096), "a measure has no room check")
end

-- U9, the precomputed compressed_float: its write and its measure make the
-- same top decode check.
function TestU6PrecomputedTopDecodeTrapsOnMeasure()
  -- delta and min are each finite float32; min + delta is not
  local maxInt, bitsN, delta = serialize.compressedFloatParams(0.0, 3e38, 3e38)
  local mn = 1e38
  raises(function()
    serialize.WriteStream.new(16):serializeCompressedFloatPrecomputed({ value = 0.0 }, maxInt, bitsN, delta, mn)
  end, "serialize: compressed float declaration's top decode")
  raises(function()
    serialize.MeasureStream.new():serializeCompressedFloatPrecomputed({ value = 0.0 }, maxInt, bitsN, delta, mn)
  end, "serialize: compressed float declaration's top decode")
end

-- U9 (roadmap u9-reject-checked-only): reject on a write or a measure is
-- caller misuse, and an always-checked port traps on it in every run, which is
-- what the C++ reference does in a debug build.
function TestU9RejectOnWriteAndMeasureTraps()
  raises(function() serialize.WriteStream.new(8):reject() end, "serialize: reject is read only")
  raises(function() serialize.MeasureStream.new():reject() end, "serialize: reject is read only")
  local rs = serialize.ReadStream.new("")
  check(rs:reject() == false and rs:error() == Refusal.Rejected, "reject on a read is a value")
end

-- U9: fail on a write or a measure returns false, records nothing and never
-- traps; a nested object returning false fails the call and records nothing.
function TestU9FailAndObjectReturnFalseNeverTrap()
  for _, s in ipairs({ serialize.WriteStream.new(8), serialize.MeasureStream.new() }) do
    check(s:fail(Refusal.PastEnd) == false and s:fail() == false, "fail returns false")
    check(s:serializeObject({ serialize = function() return false end }) == false, "a refusing object")
    check(s:error() == nil and s:refusal() == "none", "fail or the object recorded something")
    check(s:serializeBits({ value = 1 }, 1), "the stream goes on")
  end
end

-- U15: serialize_copy_string, on the source's bytes: the bytes before the
-- first NUL, cut to dest_size - 1, then backed off to a character start. The
-- vectors are the reference's test_copy_string; Lua strings are byte strings,
-- so the two ill-formed vectors apply.
function TestU15CopyString()
  local vectors = {
    { "abc", 8, "abc" },
    { "a\0bc", 8, "a" },
    { "abcdefghij", 4, "abc" },
    { "\xC3\xA9\xC3\xA9", 4, "\xC3\xA9" },
    { "\xC3\xA9\xC3\xA9", 3, "\xC3\xA9" },
    { "a\xF0\x9F\x98\x80", 3, "a" },
    { "a\xF0\x9F\x98\x80", 4, "a" },
    { "a\xF0\x9F\x98\x80", 5, "a" },
    { "a\xF0\x9F\x98\x80", 6, "a\xF0\x9F\x98\x80" },
    { "ab\x80\x80", 4, "a" },
    { "\xC3\xA9\xA9\xA9", 4, "" },
    { "abc", 1, "" },
  }
  for i, v in ipairs(vectors) do
    local got = serialize.copyString(v[1], v[2])
    check(got == v[3], "vector " .. i .. ": got " .. string.format("%q", got) .. ", wanted " .. string.format("%q", v[3]))
  end
  -- the result of a well-formed source is accepted by serializeString with
  -- buffer_size = dest_size
  local s = serialize.copyString("h\xc3\xa9llo w\xf0\x9f\x98\x80rld", 9)
  check(serialize.WriteStream.new(16):serializeString({ value = s }, 9), "the copy fits the string it bounds")
  -- dest_size below 1 is write misuse (U9): the trap
  raises(function() serialize.copyString("abc", 0) end, "serialize: copyString")
  raises(function() serialize.copyString("abc", -1) end, "serialize: copyString")
  raises(function() serialize.copyString("abc", 2.0) end, "serialize: copyString")
  raises(function() serialize.copyString(42, 8) end, "serialize: copyString")
end
