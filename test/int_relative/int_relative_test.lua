-- test/int_relative: the int_relative arm (DESIGN.md (h); STANDARD.md int_relative).
-- Run by `make test T=int_relative` from the repository root. Pins: every record
-- of conformance/int_relative.txt, read and (on `writer = canonical` records) the
-- writer's bytes, byte for byte; the file's record count; and serialize.go
-- v1.15.1's TestIntRelativeValidation cases, ported.

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

local function parseVectors(text)
  local records, cur = {}, nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*$") then
      if cur then records[#records + 1] = cur; cur = nil end
    elseif not line:match("^%s*#") then
      cur = cur or {}
      local key, val = line:match("^(%S+)%s+(.*)$")
      if key then cur[key] = val end
    end
  end
  return records
end

function TestSerializeIntRelative()
  local f = assert(io.open("conformance/int_relative.txt", "r"))
  local text = f:read("a")
  f:close()

  local records = parseVectors(text)

  local opCount = 0
  for line in text:gmatch("[^\n]+") do
    if line:match("^operation%s+") then opCount = opCount + 1 end
  end
  print("int_relative conformance records: " .. #records)
  check(#records == opCount, "record count " .. #records .. " != operation lines " .. opCount)

  local ValueOutOfRange = serialize.SerializeError.ValueOutOfRange

  for _, rec in ipairs(records) do
    local name = rec.name or "?"
    local prev = tonumber((rec["param"] or ""):match("previous%s*=%s*(%-?%d+)"))
    check(prev ~= nil, name .. ": no previous param")
    local bytes = hexToBytes(rec["bytes"] or "")
    local expectRefused = (rec.expect == "refused")
    local expectValue = expectRefused and nil or tonumber((rec.expect or ""):match("value%s*=%s*(%d+)"))
    local consumed = tonumber(rec.consumed)

    -- READ
    local rs = serialize.ReadStream.new(bytes)
    local holder = { value = -987654321 }
    local ok = rs:serializeIntRelative(prev, holder)
    if expectRefused then
      check(ok == false, name .. ": refused read succeeded, error=" .. tostring(rs:error()))
      check(rs:error() ~= nil, name .. ": refused read latched no error")
      check(holder.value == -987654321, name .. ": refusal wrote the destination")
      local before = rs:bitsProcessed()
      local h2 = { value = -111111111 }
      local ok2 = rs:serializeIntRelative(prev, h2)
      check(ok2 == false, name .. ": stream not terminal after refusal")
      check(h2.value == -111111111, name .. ": terminal read wrote the destination")
      check(rs:bitsProcessed() == before, name .. ": terminal read consumed bits")
    else
      check(ok == true, name .. ": accepted read failed, error=" .. tostring(rs:error()))
      check(holder.value == expectValue, name .. ": decoded " .. tostring(holder.value)
        .. " != expected " .. tostring(expectValue))
      if consumed then
        check(rs:bitsProcessed() == consumed, name .. ": consumed " .. rs:bitsProcessed()
          .. " != " .. consumed)
      end
    end

    -- WRITER: only records marked canonical pin the bytes a writer emits
    if rec.writer == "canonical" then
      check(not expectRefused, name .. ": a refused record cannot be canonical")
      local ws = serialize.WriteStream.new(8)
      local wh = { value = expectValue }
      local wok = ws:serializeIntRelative(prev, wh)
      check(wok == true, name .. ": canonical write failed, error=" .. tostring(ws:error()))
      ws:flush()
      check(ws:data() == bytes, name .. ": writer bytes differ")
    end
  end

  -- serialize.go v1.15.1 TestIntRelativeValidation, ported.

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

  -- a previous outside the domain is API misuse on every stream
  do
    local want = "serialize: int relative previous must be in [0,2147483647]"
    raises(function() serialize.WriteStream.new(8):serializeIntRelative(-1, { value = 5 }) end, want)
    raises(function() serialize.ReadStream.new(""):serializeIntRelative(-1, { value = 0 }) end, want)
    raises(function() serialize.MeasureStream.new():serializeIntRelative(-1, { value = 5 }) end, want)
  end

  -- a current inside the int32 type but outside the operation's domain is not
  -- misuse: write and measure latch ValueOutOfRange and write nothing
  -- (serialize.go WriteStream/MeasureStream SerializeIntRelative; DESIGN.md (c), (h)).
  do
    for _, current in ipairs({ -1, -5, -2147483648 }) do
      local ws = serialize.WriteStream.new(8)
      local wh = { value = current }
      check(ws:serializeIntRelative(100, wh) == false,
        "negative current " .. current .. " write succeeded")
      check(ws:error() == ValueOutOfRange,
        "negative current " .. current .. " write latched " .. tostring(ws:error()))
      check(ws:bitsProcessed() == 0,
        "negative current " .. current .. " write consumed bits")
      check(wh.value == current, "negative current " .. current .. " write changed the holder")

      local ms = serialize.MeasureStream.new()
      local mh = { value = current }
      check(ms:serializeIntRelative(100, mh) == false,
        "negative current " .. current .. " measure succeeded")
      check(ms:error() == ValueOutOfRange,
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
