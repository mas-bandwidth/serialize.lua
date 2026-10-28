-- test/int_relative: the int_relative arm (DESIGN.md (h); STANDARD.md int_relative).
-- Run by `make test T=int_relative` from the repository root. Pins: every record
-- of conformance/int_relative.txt through the shared runner, the canonical
-- absolute tier (non_canonical) with its reversed witnesses, and serialize.go's
-- TestIntRelativeValidation cases, ported.

local serialize = require("serialize")

local function check(cond, msg)
  if not cond then error(msg or "check failed", 2) end
end

local function raises(fn, want)
  local ok, err = pcall(fn)
  check(not ok, "expected a raise containing: " .. want)
  check(string.find(tostring(err), want, 1, true) ~= nil,
    "raise was \"" .. tostring(err) .. "\", wanted it to contain \"" .. want .. "\"")
end

local function hexToBytes(s)
  local out = {}
  for b in s:gmatch("%x%x") do
    out[#out + 1] = string.char(tonumber(b, 16))
  end
  return table.concat(out)
end

local C = assert(loadfile("test/conformance/conformance_test.lua"))()

function TestSerializeIntRelative()
  -- every record through the shared runner (test/conformance): the value, bits
  -- consumed, the stated refusal reason (value_out_of_range or non_canonical),
  -- the destination untouched, the stream terminal, the canonical bytes
  local records = C.parseVectors("conformance/int_relative.txt")
  for _, rec in ipairs(records) do C.runRecord(rec) end
  print("int_relative conformance records: " .. #records)
  check(#records == 49, "record count " .. #records)

  local ValueOutOfRange = serialize.Refusal.ValueOutOfRange
  local NonCanonical = serialize.Refusal.NonCanonical

  -- STANDARD.md int_relative, "The absolute tier is canonical too": the
  -- absolute tier carrying a difference a bounded tier takes is refused as
  -- non_canonical, at every bounded tier's top and at a difference of one;
  -- the first difference past the last tier is accepted (the reversed witness:
  -- a reader without the rule accepts every one of these).
  local function absolute(previous, current)
    local ws = serialize.WriteStream.new(8)
    check(ws:serializeBits({ value = 0 }, 6))
    check(ws:serializeBits({ value = current }, 32))
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local h = { value = -5 }
    local ok = rs:serializeIntRelative(previous, h)
    return ok, rs:error(), h.value
  end
  for _, difference in ipairs({ 1, 2, 6, 7, 23, 24, 280, 281, 4377, 4378, 69914 }) do
    local ok, err, value = absolute(1000, 1000 + difference)
    check(ok == false and err == NonCanonical and value == -5,
      "absolute tier with difference " .. difference .. ": " .. tostring(err))
  end
  do
    local ok, err, value = absolute(1000, 1000 + 69915)
    check(ok and err == nil and value == 1000 + 69915, "the first absolute difference is accepted")
    -- the domain and ordering rule comes first: past the domain with a small
    -- difference is value_out_of_range, and so is not increasing
    ok, err = absolute(2147483647 - 3, 2147483648)
    check(not ok and err == ValueOutOfRange, "past the domain with a small difference: " .. tostring(err))
    ok, err = absolute(1000, 1000)
    check(not ok and err == ValueOutOfRange, "equal to previous: " .. tostring(err))
    -- the 32-bit group's top bit set: 2^32 - 1 is past the domain, computed in
    -- 64 bits so the difference never wraps
    ok, err = absolute(2147483647 - 1, 0xFFFFFFFF)
    check(not ok and err == ValueOutOfRange, "all 32 bits set: " .. tostring(err))
  end
  -- the writer takes the first tier the difference fits, so it never writes a
  -- non-canonical absolute tier: every round trip at the tier edges reads back
  for _, difference in ipairs({ 1, 6, 7, 23, 24, 280, 281, 4377, 4378, 69914, 69915 }) do
    local ws = serialize.WriteStream.new(8)
    check(ws:serializeIntRelative(10, { value = 10 + difference }), "write difference " .. difference)
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local h = {}
    check(rs:serializeIntRelative(10, h) and h.value == 10 + difference,
      "round trip difference " .. difference .. ": " .. tostring(rs:error()))
  end

  -- serialize.go TestIntRelativeValidation, ported.

  -- the 32-bit fallback must reject a value that violates the previous < current contract
  do
    local bs = hexToBytes("80 0C 00 00 00") -- 6 false flags + 32 bits of 50
    local rs = serialize.ReadStream.new(bs)
    local holder = { value = -42 }
    check(rs:serializeIntRelative(100, holder) == false, "fallback accepted a non-increasing value")
    check(rs:error() == ValueOutOfRange, "fallback refusal latched " .. tostring(rs:error()))
    check(holder.value == -42, "fallback refusal wrote the destination")
  end

  -- a legitimate fallback round trip must still succeed
  do
    local ws = serialize.WriteStream.new(8)
    local wh = { value = 100000 }
    check(ws:serializeIntRelative(100, wh) == true, "fallback write failed")
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local rh = { value = 0 }
    check(rs:serializeIntRelative(100, rh) == true, "fallback read failed")
    check(rh.value == 100000, "fallback round trip " .. tostring(rh.value))
  end

  -- the widest gap the domain allows: 0 to 2^31 - 1 takes the absolute tier
  do
    local ws = serialize.WriteStream.new(8)
    local wh = { value = 2147483647 }
    check(ws:serializeIntRelative(0, wh) == true, "widest gap write failed")
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local rh = { value = 0 }
    check(rs:serializeIntRelative(0, rh) == true, "widest gap read failed")
    check(rh.value == 2147483647, "widest gap round trip " .. tostring(rh.value))
  end

  -- the reconstruction is checked in EVERY tier against the domain: a previous at the
  -- top leaves no room for any difference, so every tier refuses and leaves the
  -- destination unwritten
  do
    local differences = { 1, 5, 10, 100, 1000, 10000 }
    for _, difference in ipairs(differences) do
      local ws = serialize.WriteStream.new(8)
      local wh = { value = 10 + difference }
      check(ws:serializeIntRelative(10, wh) == true, "tier " .. difference .. " write failed")
      ws:flush()
      local rs = serialize.ReadStream.new(ws:data())
      local rh = { value = -1 }
      check(rs:serializeIntRelative(2147483647, rh) == false, "tier " .. difference .. " past the domain top accepted")
      check(rh.value == -1, "tier " .. difference .. " refusal wrote the destination")
    end
  end

  -- a previous outside the domain is API misuse: write and measure raise; a
  -- read refuses value_out_of_range, never a raise (IMPLEMENTING.md U7, U16)
  do
    local want = "serialize: int relative previous must be in [0,2147483647]"
    raises(function() serialize.WriteStream.new(8):serializeIntRelative(-1, { value = 5 }) end, want)
    raises(function() serialize.MeasureStream.new():serializeIntRelative(-1, { value = 5 }) end, want)
    local rs = serialize.ReadStream.new("\1")
    local rh = { value = 0 }
    check(rs:serializeIntRelative(-1, rh) == false and rs:error() == ValueOutOfRange,
      "a previous outside the domain on read refuses value_out_of_range")
    check(rh.value == 0 and rs:bitsProcessed() == 0, "the refused read consumed bits or wrote the holder")
  end

  -- a current inside the int32 type but outside the operation's domain (not
  -- above previous) is write misuse: the write traps, writing and latching
  -- nothing, and the measure traps the same way (IMPLEMENTING.md U9, U6)
  -- (serialize.go WriteStream/MeasureStream SerializeIntRelative; DESIGN.md (c), (h)).
  do
    for _, current in ipairs({ -1, -5, -2147483648 }) do
      local ws = serialize.WriteStream.new(8)
      local wh = { value = current }
      raises(function() ws:serializeIntRelative(100, wh) end,
        "write misuse (IMPLEMENTING.md U9): value_out_of_range")
      check(ws:error() == nil,
        "negative current " .. current .. " write latched " .. tostring(ws:error()))
      check(ws:bitsProcessed() == 0,
        "negative current " .. current .. " write consumed bits")
      check(wh.value == current, "negative current " .. current .. " write changed the holder")

      local ms = serialize.MeasureStream.new()
      local mh = { value = current }
      raises(function() ms:serializeIntRelative(100, mh) end,
        "write misuse (IMPLEMENTING.md U9): value_out_of_range")
      check(ms:error() == nil,
        "negative current " .. current .. " measure latched " .. tostring(ms:error()))
      check(ms:bitsProcessed() == 0,
        "negative current " .. current .. " measure consumed bits")
    end
  end

  -- a current outside the int32 type is API misuse on write and measure
  do
    local want = "serialize: int relative current"
    for _, current in ipairs({ -2147483649, 2147483648, 5.0 }) do
      raises(function() serialize.WriteStream.new(8):serializeIntRelative(0, { value = current }) end, want)
      raises(function() serialize.MeasureStream.new():serializeIntRelative(0, { value = current }) end, want)
    end
  end
end
