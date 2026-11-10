-- test/float: float and double, with float32 rounding (serialize-lua-float).
-- Run by `make test T=float` from the repository root. Pins: every record of
-- conformance/float.txt and double.txt through the shared runner, comparing BIT
-- PATTERNS (STANDARD.md, "Finite values only, every one bit exact"): accepted
-- records read and (when canonical) write the exact bytes; non-finite patterns
-- are refused as non_finite_float with the holder untouched. A non-finite value
-- is write misuse, tested after the float32 narrowing: the writer and the
-- measure trap on it (IMPLEMENTING.md U9, U6). fround pins Go's float32()
-- conversion on a table of edges checked against Go's float32() bit for bit.
-- No real time, no sockets, no network: io only reads the conformance files.

local serialize = require("serialize")
local flt = require("serialize_float")
local C = assert(loadfile("test/conformance/conformance_test.lua"))()

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local NON_FINITE = serialize.Refusal.NonFiniteFloat

local function fromDoubleBits(bits)
  return (string.unpack("<d", string.pack("<i8", bits)))
end

-- traps(fn): fn raises the write-misuse trap naming non_finite_float.
local function traps(fn, what)
  local ok, err = pcall(fn)
  check(not ok, what .. ": did not trap")
  check(string.find(tostring(err), "write misuse (IMPLEMENTING.md U9): " .. NON_FINITE, 1, true) ~= nil,
    what .. ": the trap was " .. tostring(err))
end

-- writeRefused(method, value): the writer traps (U9), writing nothing and
-- latching nothing; the measure traps the same way (U6).
local function writeRefused(method, value, what)
  local ws = serialize.WriteStream.new(8)
  local h = { value = value }
  traps(function() return ws[method](ws, h) end, what .. ": the write")
  check(ws:error() == nil, what .. ": the write latched " .. tostring(ws:error()))
  check(ws:bitsProcessed() == 0, what .. ": the trapped write wrote bits")
  check(rawequal(h.value, value) or (h.value ~= h.value and value ~= value), what .. ": the holder changed")
  local ms = serialize.MeasureStream.new()
  traps(function() return ms[method](ms, { value = value }) end, what .. ": the measure")
  check(ms:error() == nil, what .. ": the measure latched " .. tostring(ms:error()))
end

local function writeAccepted(method, value, what)
  local ws = serialize.WriteStream.new(8)
  check(ws[method](ws, { value = value }) == true, what .. ": the write must accept, got " .. tostring(ws:error()))
  local ms = serialize.MeasureStream.new()
  check(ms[method](ms, { value = value }) == true, what .. ": the measure must accept")
end

local function wireBytes(method, value, what)
  local ws = serialize.WriteStream.new(8)
  check(ws[method](ws, { value = value }) == true, what .. ": the write must accept, got " .. tostring(ws:error()))
  ws:flush()
  return ws:data()
end

function TestSerializeFloat()
  local counts = { ["conformance/float.txt"] = 24, ["conformance/double.txt"] = 27 }
  for path, n in pairs(counts) do
    local records = C.parseVectors(path)
    check(#records == n, path .. ": expected " .. n .. " records, parsed " .. #records)
    for _, rec in ipairs(records) do C.runRecord(rec) end
    print(path .. ": " .. #records .. " records")
  end

  -- the writer is handed finite values only (STANDARD.md, "Finite values
  -- only"): NaN, signaling NaN and both infinities refused on write and measure
  local inf, nan = math.huge, 0.0 / 0.0
  for _, v in ipairs({ inf, -inf, nan, -nan, fromDoubleBits(0x7FF0000000000001) }) do
    writeRefused("serializeFloat", v, "float " .. tostring(v))
    writeRefused("serializeDouble", v, "double " .. tostring(v))
  end
  -- the float test is on the bits AFTER the narrowing: a finite double above
  -- FLT_MAX narrows to an infinity, which is what would be sent. Reversed
  -- witness: the same value is finite as a double, so a check on the caller's
  -- double would pass it.
  local aboveFltMax = fromDoubleBits(0x47EFFFFFF0000000) -- rounds to +inf in float32
  check(aboveFltMax == aboveFltMax and aboveFltMax ~= inf, "the witness is a finite double")
  writeRefused("serializeFloat", aboveFltMax, "float above FLT_MAX")
  writeRefused("serializeFloat", -aboveFltMax, "float below -FLT_MAX")
  writeAccepted("serializeDouble", aboveFltMax, "the same value as a double")
  -- just inside: FLT_MAX itself, and a double that rounds down onto it
  writeAccepted("serializeFloat", fromDoubleBits(0x47EFFFFFE0000000), "FLT_MAX")
  writeAccepted("serializeFloat", fromDoubleBits(0x47EFFFFFE8000000), "a double that rounds to FLT_MAX")
  -- negative zero and the smallest subnormals are finite
  writeAccepted("serializeFloat", -0.0, "float -0")
  writeAccepted("serializeDouble", -0.0, "double -0")
  writeAccepted("serializeDouble", fromDoubleBits(1), "double smallest subnormal")

  -- a failed stream keeps its first reason: a past_end read, then a
  -- non-finite pattern, still reports past_end
  local rs = serialize.ReadStream.new("\0\0\128\127")
  check(rs:serializeDouble({ value = 0.0 }) == false and rs:error() == serialize.Refusal.PastEnd,
    "a 64-bit read of four bytes is past_end")
  check(rs:serializeFloat({ value = 0.0 }) == false and rs:error() == serialize.Refusal.PastEnd,
    "the echo keeps the first reason")

  -- -------------------------------------------------------------------------
  -- fround: Go's float32() on a table of edges, checked bit for bit.
  -- Each entry is { double bits, expected float32 bits }.
  -- -------------------------------------------------------------------------
  local FROUND = {
    { 0x3FF0000010000000, 0x3F800000 },
    { 0x3FF0000030000000, 0x3F800002 },
    { 0x4000000010000000, 0x40000000 },
    { 0x4000000030000000, 0x40000002 },
    { 0x3FF0000010400000, 0x3F800001 },
    { 0x3FF000000FC00000, 0x3F800000 },
    { 0x380FFFFFC0000000, 0x007FFFFF },
    { 0x3810000000000000, 0x00800000 },
    { 0x36A0000000000000, 0x00000001 },
    { 0x47EFFFFFE0000000, 0x7F7FFFFF },
    { 0x47EFFFFFF0000000, 0x7F800000 },
    { 0x47EFFFFFE8000000, 0x7F7FFFFF },
    { 0x47F0000008000000, 0x7F800000 },
    { 0x8000000000000000, 0x80000000 },
    { 0x7FF0000000000000, 0x7F800000 },
    { 0xFFF0000000000000, 0xFF800000 },
    { 0x6CA3344B5669E91A, 0x7F800000 },
    { 0x5292E65FF01ACD3E, 0x7F800000 },
    { 0xDE7D997018E76D3D, 0xFF800000 },
    { 0xA859325C1560EF38, 0x80000000 },
    { 0x074BD759424C2157, 0x00000000 },
    { 0x7BCEAE93BA2F3E86, 0x7F800000 },
    { 0x4E960CDEDC2F5DB0, 0x7F800000 },
    { 0x01ED7BAA951DD288, 0x00000000 },
    { 0x111A73351BF3C7EF, 0x00000000 },
    { 0x4183B5A61176293D, 0x4C1DAD31 },
    { 0x8530E5D48705C3A5, 0x80000000 },
    { 0x2D5A6DE913F048C9, 0x00000000 },
    { 0xE59D8991073F654E, 0xFF800000 },
    { 0x4AC54FC0F3C67062, 0x7F800000 },
    { 0x405B649C88DEA0FD, 0x42DB24E4 },
    { 0x25489852DFE5FC07, 0x00000000 },
    { 0xBD1BEAF1E2C3D308, 0xA8DF578F },
    { 0x36966ED599E41752, 0x00000001 },
    { 0x9F488141CC20C93F, 0x80000000 },
    { 0xF4419951974403CF, 0xFF800000 },
    { 0xE610E904CDDE9697, 0xFF800000 },
    { 0x8D8A958B54E3D2A5, 0x80000000 },
    { 0x21943124C6350E63, 0x00000000 },
    { 0x477B1D11BE64E9F0, 0x7BD8E88E },
    { 0xD8C6B42639326B86, 0xFF800000 },
    { 0xD50736AA5B835BA0, 0xFF800000 },
    { 0xB248C27C89A4CB88, 0x80000000 },
    { 0x1F28C87850C515DC, 0x00000000 },
    { 0x3AE8960CACDB465E, 0x1744B065 },
    { 0x52CC0FD2A29C6B69, 0x7F800000 },
    { 0xB63DC172377A9121, 0x80000000 },
    { 0x2E3E033D1136A530, 0x00000000 },
    { 0xC54068AA1FC599FF, 0xEA034551 },
    { 0xF1841C07B1D213C8, 0xFF800000 },
    { 0x5B3656EADF334362, 0x7F800000 },
    { 0x6634A46D8B24A77F, 0x7F800000 },
    { 0x8CDD787E4C4D53B8, 0x80000000 },
    { 0xA8507DBBB92D6338, 0x80000000 },
    { 0xCC80719073FBF2DC, 0xFF800000 },
    { 0xCB42187337EF566F, 0xFF800000 },
    { 0xAA178388EDD6624B, 0x80000000 },
    { 0xB9913C6227DFE503, 0x8C89E311 },
    { 0xCC7F4ABFE29E95C8, 0xFF800000 },
    { 0xB3AFE5F2D1557BE3, 0x80000000 },
    { 0xCF7A136ADBFF2C44, 0xFF800000 },
    { 0x91B94CA5E4D872E9, 0x80000000 },
    { 0x9CB9F036AA3E56CE, 0x80000000 },
    { 0xB482E533A028AC6E, 0x80000000 },
    { 0x14FA89E9C6558C19, 0x00000000 },
    { 0x3A9F5EA6B65EA9F8, 0x14FAF536 },
    { 0xE7E62EA447785F36, 0xFF800000 },
    { 0xD34029C21613AFD7, 0xFF800000 },
    { 0x5DC40D73D6A35348, 0x7F800000 },
    { 0xD3B7142F42C1F9C7, 0xFF800000 },
    { 0x4AB2E131B6618319, 0x7F800000 },
    { 0x2A7FEDC27300E774, 0x00000000 },
    { 0x28E86970C714E592, 0x00000000 },
    { 0x66B778F521379016, 0x7F800000 },
    { 0xA96CAAA0A06D98B4, 0x80000000 },
    { 0x6EB22A265D80D4BE, 0x7F800000 },
    { 0xC3E8CD8761FD2489, 0xDF466C3B },
    { 0x76973EA0E7790949, 0x7F800000 },
    { 0x0BF1496E2970124B, 0x00000000 },
    { 0x66B609B2E88D83A5, 0x7F800000 },
    -- subnormal rounding regressions: single rounding of
    -- the exact double onto the 2^-149 grid, not double-rounding through a
    -- pre-rounded 24-bit significand; each was computed by Go's float32().
    { 0x38079409D4CD951F, 0x005E5027 },
    { 0x38019D69AB4DE00B, 0x004675A7 },
    { 0xB806E9532EE11361, 0x805BA54D },
    { 0x37CA83FA083B0854, 0x0006A0FF },
  }
  for _, edge in ipairs(FROUND) do
    local inbits, want = edge[1], edge[2]
    local v = string.unpack("<d", string.pack("<i8", inbits))
    local got = flt.float32Bits(flt.fround(v))
    check(got == want,
      "fround(" .. string.format("%016X", inbits) .. ") = " ..
      string.format("%08X", got) .. ", Go float32() = " .. string.format("%08X", want))
  end

  -- NaN narrows to a NaN pattern (exponent all ones, mantissa set), which the
  -- writer refuses; its payload no longer matters, since the format carries
  -- finite values only.
  for _, bits in ipairs({ 0x7FF8000000000001, 0x7FF4000000000001, -1 }) do
    local got = flt.float32Bits(fromDoubleBits(bits))
    check((got & 0x7F800000) == 0x7F800000 and (got & 0x7FFFFF) ~= 0,
      string.format("NaN %016X narrows to a NaN pattern, got %08X", bits, got))
  end

  -- The compressed float wire path must round through the same fround the
  -- edge table above pins. Count calls through the exported function while a
  -- write and a read run.
  do
    local realFround = flt.fround
    local calls = 0
    flt.fround = function(v)
      calls = calls + 1
      return realFround(v)
    end
    local ok, err = pcall(function()
      local ws = serialize.WriteStream.new(8)
      check(ws:serializeCompressedFloat({ value = 1.5 }, 0.0, 10.0, 0.01),
        "compressed float write failed, err=" .. tostring(ws:error()))
      ws:flush()
      local crs = serialize.ReadStream.new(ws:data())
      local h = {}
      check(crs:serializeCompressedFloat(h, 0.0, 10.0, 0.01),
        "compressed float read failed, err=" .. tostring(crs:error()))
    end)
    flt.fround = realFround
    if not ok then error(err, 0) end
    check(calls > 0, "the compressed float wire path must use the float family's fround")
  end
end

-- An integer-subtype Lua number is still a Lua number: serializeFloat and
-- serializeDouble accept it and write the same bits as its float value.
function TestSerializeFloatIntegerSubtype()
  check(math.type(1) == "integer" and math.type(1.0) == "float",
    "the witness uses both Lua number subtypes")
  for _, v in ipairs({ 0, 1, -1, 3, 42 }) do
    check(math.type(v) == "integer", tostring(v) .. " is an integer subtype")
    check(wireBytes("serializeFloat", v, "float " .. tostring(v))
      == wireBytes("serializeFloat", v + 0.0, "float " .. tostring(v) .. ".0"),
      "serializeFloat writes integer " .. tostring(v) .. " as its float value")
    check(wireBytes("serializeDouble", v, "double " .. tostring(v))
      == wireBytes("serializeDouble", v + 0.0, "double " .. tostring(v) .. ".0"),
      "serializeDouble writes integer " .. tostring(v) .. " as its float value")
    local ms = serialize.MeasureStream.new()
    check(ms:serializeFloat({ value = v }) == true and ms:bitsProcessed() == 32,
      "serializeFloat measures integer " .. tostring(v) .. " as 32 bits")
    local msd = serialize.MeasureStream.new()
    check(msd:serializeDouble({ value = v }) == true and msd:bitsProcessed() == 64,
      "serializeDouble measures integer " .. tostring(v) .. " as 64 bits")
    local function compressed(x)
      local ws = serialize.WriteStream.new(8)
      check(ws:serializeCompressedFloat({ value = x }, -50, 50, 1) == true,
        "serializeCompressedFloat accepts " .. math.type(x) .. " " .. tostring(x) .. ", got " .. tostring(ws:error()))
      ws:flush()
      local mc = serialize.MeasureStream.new()
      check(mc:serializeCompressedFloat({ value = x }, -50, 50, 1) == true,
        "serializeCompressedFloat measures " .. math.type(x) .. " " .. tostring(x))
      return ws:data(), mc:bitsProcessed()
    end
    local ib, ibits = compressed(v)
    local fb, fbits = compressed(v + 0.0)
    check(ib == fb and ibits == fbits,
      "serializeCompressedFloat writes integer " .. tostring(v) .. " as its float value")
  end
  local d = 3 // 1
  check(math.type(d) == "integer", "3 // 1 is an integer subtype")
  check(wireBytes("serializeDouble", d, "double 3 // 1") == wireBytes("serializeDouble", 3.0, "double 3.0"),
    "serializeDouble writes 3 // 1 as 3.0")
end

-- An integer with no exact double value is write misuse (IMPLEMENTING.md U3:
-- a writer never sends bytes that differ from the caller's value): the write
-- and the measure raise, writing and counting nothing. Every integer that
-- converts exactly, the int64 extremes 2^53 and -2^63 included, is written.
function TestSerializeFloatInexactIntegerRaises()
  local want = "serialize: a float holder integer must convert exactly to a double"
  for _, method in ipairs({ "serializeFloat", "serializeDouble" }) do
    for _, v in ipairs({ math.maxinteger, (1 << 53) + 1, -(1 << 53) - 1, math.mininteger + 1 }) do
      local what = method .. "(" .. tostring(v) .. ")"
      local ws = serialize.WriteStream.new(8)
      local ok, err = pcall(function() return ws[method](ws, { value = v }) end)
      check(not ok, what .. ": the write did not raise")
      check(string.find(tostring(err), want, 1, true) ~= nil, what .. ": the write raised " .. tostring(err))
      check(ws:error() == nil and ws:bitsProcessed() == 0, what .. ": the raised write latched or wrote")
      local ms = serialize.MeasureStream.new()
      ok, err = pcall(function() return ms[method](ms, { value = v }) end)
      check(not ok, what .. ": the measure did not raise")
      check(string.find(tostring(err), want, 1, true) ~= nil, what .. ": the measure raised " .. tostring(err))
      check(ms:error() == nil and ms:bitsProcessed() == 0, what .. ": the raised measure latched or counted")
    end
    for _, v in ipairs({ 1 << 53, -(1 << 53), math.mininteger, 1 << 62 }) do
      writeAccepted(method, v, method .. "(" .. tostring(v) .. ")")
    end
  end
  check(wireBytes("serializeDouble", math.mininteger, "double -2^63")
    == wireBytes("serializeDouble", -2.0 ^ 63, "double -2.0^63"), "serializeDouble writes -2^63 exactly")
end
