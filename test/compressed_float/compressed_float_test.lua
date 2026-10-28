-- test/compressed_float: the compressed float (DESIGN.md (h)).
-- Run by `make test T=compressed_float` from the repository root. Pins: every
-- record of conformance/compressed_float.txt (decoded float32 bits, bits
-- consumed, refusal with the destination untouched and the stream terminal),
-- the per-file record count equal to the file's count, serialize.go's
-- TestCompressedFloatTopOfRangeClamp witnesses ([0,8388609] and [0,16777215]
-- at resolution 1, writing max, through both entry points), and
-- TestCompressedFloatValidation's misuse rules: a read of an integer above
-- maxIntegerValue, a huge delta / resolution ratio that must not overflow the
-- uint32 quantization range, and a non-finite value, which the checked writer
-- asserts on; and the format 2.0 finite decode (STANDARD.md, "The decode must
-- be finite"): the writer raises on a declaration whose top decode is not
-- finite, and the reader refuses a non-finite decode as non_finite_float.

local serialize = require("serialize")

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

--------------------------------------------------------------------------------
-- The corpus records run through the shared runner (test/conformance): the
-- decoded float32 bits, bits consumed, the stated refusal reason (a non-finite
-- decode is non_finite_float), the destination untouched, the stream terminal,
-- and the writer_input bytes.
--------------------------------------------------------------------------------

local C = assert(loadfile("test/conformance/conformance_test.lua"))()

local function runFile(path)
  local records = C.parseVectors(path)
  for _, rec in ipairs(records) do C.runRecord(rec) end
  print(path .. ": " .. #records .. " records")
end

local function raisesDecode(fn, what)
  local ok, err = pcall(fn)
  check(not ok and tostring(err):find("top decode", 1, true) ~= nil,
    what .. ": the writer must raise on the declaration, got " .. tostring(err))
end

local function clampWitness(maxv)
  local ws = serialize.WriteStream.new(16)
  check(ws:serializeCompressedFloat({ value = maxv }, 0, maxv, 1.0),
    "clamp witness write failed, err=" .. tostring(ws:error()))
  ws:flush()
  local rs = serialize.ReadStream.new(ws:data())
  local h = {}
  check(rs:serializeCompressedFloat(h, 0, maxv, 1.0), "clamp witness read failed")
  check(h.value == maxv, "clamp witness value " .. tostring(maxv) .. " round-tripped to " .. tostring(h.value))
end

local function clampWitnessPrecomputed(maxv)
  local maxInt, bits, delta = serialize.compressedFloatParams(0, maxv, 1.0)
  local ws = serialize.WriteStream.new(16)
  check(ws:serializeCompressedFloatPrecomputed({ value = maxv }, maxInt, bits, delta, 0.0),
    "precomputed clamp witness write failed, err=" .. tostring(ws:error()))
  ws:flush()
  local rs = serialize.ReadStream.new(ws:data())
  local h = {}
  check(rs:serializeCompressedFloatPrecomputed(h, maxInt, bits, delta, 0.0),
    "precomputed clamp witness read failed")
  check(h.value == maxv, "precomputed clamp witness value " .. tostring(maxv) .. " round-tripped to " .. tostring(h.value))
end

function TestSerializeCompressedFloat()
  -- 1. the conformance corpus, record by record, with per-file count.
  runFile("conformance/compressed_float.txt")

  -- 2. serialize.go TestCompressedFloatTopOfRangeClamp: the normative integer
  -- clamp, writing max through both the derived and precomputed paths.
  clampWitness(8388609.0)
  clampWitness(16777215.0)
  clampWitnessPrecomputed(8388609.0)
  clampWitnessPrecomputed(16777215.0)

  -- 3. serialize.go TestCompressedFloatValidation's misuse rules.
  -- a malicious packet can encode integers above maxIntegerValue in the bit
  -- headroom; reads must reject them (maxIntegerValue is 1000 for [0,10] at
  -- res 0.01 -> 10 bits).
  do
    local ws = serialize.WriteStream.new(8)
    check(ws:serializeBits({ value = 1023 }, 10))
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local h = { value = -1.0 }
    check(rs:serializeCompressedFloat(h, 0, 10, 0.01) == false, "above-maxIntegerValue read must refuse")
    check(rs:error() == serialize.Refusal.ValueOutOfRange, "above-maxIntegerValue is value_out_of_range")
    check(h.value == -1.0, "above-maxIntegerValue refused read must leave destination untouched")
  end

  -- 4. STANDARD.md, "The decode must be finite": over [3*2^103, FLT_MAX] at
  -- resolution 2^104 the top integer decodes to +inf. The declaration is
  -- non-conforming as a whole, so the WRITER raises on it even for a value
  -- that decodes finite (min itself), through both entry points, and the
  -- measure makes the same check by the same trap (IMPLEMENTING.md U6, U9);
  -- the reader does not raise, and refuses the top integer as
  -- non_finite_float.
  do
    local min, max, res = 3.0 * 2.0 ^ 103, 340282346638528859811704183484516925440.0, 2.0 ^ 104
    raisesDecode(function()
      serialize.WriteStream.new(8):serializeCompressedFloat({ value = min }, min, max, res)
    end, "derived")
    local maxInt, bits, delta = serialize.compressedFloatParams(min, max, res)
    raisesDecode(function()
      serialize.WriteStream.new(8):serializeCompressedFloatPrecomputed({ value = min }, maxInt, bits, delta, min)
    end, "precomputed")
    raisesDecode(function()
      serialize.MeasureStream.new():serializeCompressedFloat({ value = min }, min, max, res)
    end, "measure, derived")
    raisesDecode(function()
      serialize.MeasureStream.new():serializeCompressedFloatPrecomputed({ value = min }, maxInt, bits, delta, min)
    end, "measure, precomputed")
    -- the top integer, read: non_finite_float, destination untouched
    local ws = serialize.WriteStream.new(8)
    check(ws:serializeBits({ value = maxInt }, bits))
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local h = { value = -1.0 }
    check(rs:serializeCompressedFloat(h, min, max, res) == false
      and rs:error() == serialize.Refusal.NonFiniteFloat and h.value == -1.0,
      "the top integer's decode is refused as non_finite_float, got " .. tostring(rs:error()))
    -- reversed witness: one below the top decodes finite and is accepted
    local ws2 = serialize.WriteStream.new(8)
    check(ws2:serializeBits({ value = maxInt - 1 }, bits))
    ws2:flush()
    local rs2 = serialize.ReadStream.new(ws2:data())
    check(rs2:serializeCompressedFloat(h, min, max, res) and h.value < math.huge,
      "the integer below the top decodes finite")
    -- a delta past FLT_MAX, and a delta / resolution past FLT_MAX, are
    -- misdeclarations of the same kind (IMPLEMENTING.md, "The check model"),
    -- trapped on write and measure, never clamped
    for _, s in ipairs({ serialize.WriteStream.new(8), serialize.MeasureStream.new() }) do
      local ok, err = pcall(s.serializeCompressedFloat, s, { value = 0.0 }, -max, max, 1.0)
      check(not ok and tostring(err):find("delta max - min", 1, true), "delta past FLT_MAX: " .. tostring(err))
      ok, err = pcall(s.serializeCompressedFloat, s, { value = 0.0 }, 0.0, 1e38, 1e-38)
      check(not ok and tostring(err):find("delta / resolution", 1, true), "delta / res past FLT_MAX: " .. tostring(err))
    end
    -- a conforming declaration's write is untouched by the assert
    check(serialize.WriteStream.new(8):serializeCompressedFloat({ value = 5.0 }, 0.0, 10.0, 0.01),
      "a conforming declaration writes")
  end

  -- huge delta / resolution ratios must not overflow the uint32 quantization range.
  do
    local ws = serialize.WriteStream.new(8)
    local written = 5000000000.0
    check(ws:serializeCompressedFloat({ value = written }, 0, 10000000000.0, 1.0))
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local h = {}
    check(rs:serializeCompressedFloat(h, 0, 10000000000.0, 1.0))
    check(math.abs(h.value - written) <= 4096.0,
      "huge ratio round trip " .. tostring(h.value) .. " too far from " .. tostring(written))
  end

  -- a non-finite value is non-conforming and the checked writer asserts
  -- (raises) on it (IMPLEMENTING.md, "The check model").
  do
    local ws = serialize.WriteStream.new(8)
    local ok, err = pcall(function()
      ws:serializeCompressedFloat({ value = 0 / 0 }, 0, 10, 0.01)
    end)
    check(not ok, "writing NaN must raise, got " .. tostring(err))
  end
end
