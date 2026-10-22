-- test/bits: the bits family (card serialize-lua-bits). Runs every record of
-- conformance/bits.txt, bool.txt, uint128.txt, align.txt and object.txt through
-- the shared runner, serialize.go's
-- TestContinue and TestUntil cases, and MeasureStream's bit counts for the
-- operations this card owns. Run by `make test T=bits` from the repository
-- root. No real time, no sockets, no network.

local serialize = require("serialize")
local WriteStream = serialize.WriteStream
local ReadStream = serialize.ReadStream
local MeasureStream = serialize.MeasureStream

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local function raises(fn, want)
  local ok, err = pcall(fn)
  check(not ok, "expected a raise containing: " .. want)
  check(string.find(tostring(err), want, 1, true) ~= nil,
    "raise was \"" .. tostring(err) .. "\", wanted it to contain \"" .. want .. "\"")
end

-- The corpus records are run by the shared runner (test/conformance), which
-- checks values exactly, bits consumed, the stated refusal reason, terminality,
-- the canonical bytes and the measure floor.
local C = assert(loadfile("test/conformance/conformance_test.lua"))()

local function runCorpusFile(path)
  local records = C.parseVectors(path)
  for _, rec in ipairs(records) do C.runRecord(rec) end
  print("bits: " .. path .. " " .. #records .. " records")
  return #records
end

--------------------------------------------------------------------------------
-- TestSerializeBits
--------------------------------------------------------------------------------

function TestSerializeBits()
  -- conformance, one file at a time; every record must equal the file's count.
  local want = {
    ["conformance/bits.txt"] = 26,
    ["conformance/bool.txt"] = 5,
    ["conformance/uint128.txt"] = 13,
    ["conformance/align.txt"] = 10,
    ["conformance/object.txt"] = 7,
  }
  for path, n in pairs(want) do
    check(runCorpusFile(path) == n, path .. ": record count changed")
  end

  -- misuse raises, naming the rule (serialize.go's panic strings)
  raises(function() WriteStream.new(64):serializeBits({ value = 1 }, 0) end, "bits must be in [1,32]")
  raises(function() WriteStream.new(64):serializeBits({ value = 1 }, 33) end, "bits must be in [1,32]")
  raises(function() WriteStream.new(64):serializeBits64({ value = 1 }, 65) end, "bits must be in [1,64]")
  raises(function() WriteStream.new(64):serializeBits({ value = 1.0 }, 1) end, "must be an integer")
  raises(function() WriteStream.new(64):serializeBits({ value = 4294967296 }, 1) end, "in [0,4294967295]")
  raises(function() WriteStream.new(64):serializeUint8({ value = 300 }) end, "in [0,255]")
  raises(function() WriteStream.new(64):serializeUint16({ value = -1 }) end, "in [0,65535]")
  raises(function() WriteStream.new(64):serializeUint32({ value = 4294967296 }) end, "in [0,4294967295]")
  raises(function() WriteStream.new(64):serializeBool({ value = 1 }) end, "must be a boolean")
  raises(function() WriteStream.new(64):serializeBits64({ value = 1 }, 0) end, "bits must be in [1,64]")

  -- serialize.go TestContinue (sentinel-driven loop)
  do
    local items = { 10, 20, 30, 40, 50 }
    local ws = WriteStream.new(64)
    local i, hasNext = 0, #items > 0
    while serialize.Continue(ws, { value = hasNext }) do
      i = i + 1
      check(ws:serializeBits({ value = items[i] }, 8), "continue write")
      hasNext = i < #items
    end
    check(ws:error() == nil, "continue write stream ok")
    ws:flush()
    local rs = ReadStream.new(ws:data())
    local read = {}
    hasNext = true
    while serialize.Continue(rs, { value = hasNext }) do
      local h = { value = 0 }
      check(rs:serializeBits(h, 8), "continue read")
      read[#read + 1] = h.value
      hasNext = true
    end
    check(rs:error() == nil, "continue read stream ok")
    check(#read == #items, "continue item count")
    for k = 1, #items do check(read[k] == items[k], "continue value " .. k) end
  end

  -- serialize.go TestUntil (termination bit)
  do
    local items = { 10, 20, 30, 40, 50 }
    local ws = WriteStream.new(64)
    local i, done = 0, #items == 0
    while serialize.Until(ws, { value = done }) do
      i = i + 1
      check(ws:serializeBits({ value = items[i] }, 8), "until write")
      done = i == #items
    end
    check(ws:error() == nil, "until write stream ok")
    ws:flush()
    check(ws:bitsProcessed() == #items * 9 + 1, "until bits written")
    local rs = ReadStream.new(ws:data())
    local read = {}
    done = false
    while serialize.Until(rs, { value = done }) do
      local h = { value = 0 }
      check(rs:serializeBits(h, 8), "until read")
      read[#read + 1] = h.value
      done = false
    end
    check(rs:error() == nil, "until read stream ok")
    check(#read == #items, "until item count")
    for k = 1, #items do check(read[k] == items[k], "until value " .. k) end
  end

  -- MeasureStream bit counts per operation
  do
    local ms = MeasureStream.new()
    check(ms:serializeBits({ value = 255 }, 8), "measure bits")
    check(ms:bitsProcessed() == 8, "measure bits count")
    check(ms:serializeBits64({ value = -1 }, 64), "measure bits64")
    check(ms:bitsProcessed() == 72, "measure bits64 count")
    check(ms:serializeBool({ value = true }), "measure bool")
    check(ms:bitsProcessed() == 73, "measure bool count")
    check(ms:serializeUint8({ value = 255 }), "measure uint8")
    check(ms:serializeUint16({ value = 65535 }), "measure uint16")
    check(ms:serializeUint32({ value = 4294967295 }), "measure uint32")
    check(ms:serializeUint64({ value = -1 }), "measure uint64")
    check(ms:bitsProcessed() == 73 + 8 + 16 + 32 + 64, "measure uint counts")
    check(ms:serializeBits64({ value = -1 }, 64), "measure uint128 low half")
    check(ms:serializeBits64({ value = -1 }, 64), "measure uint128 high half")
    check(ms:bitsProcessed() == 73 + 8 + 16 + 32 + 64 + 128, "measure uint128 count")
    check(ms:serializeAlign(), "measure align")
    check(ms:bitsProcessed() == 73 + 8 + 16 + 32 + 64 + 128 + 7, "measure align count")
    check(ms:error() == nil, "measure never latches")
  end

  -- the api helpers: bitsRequired / bitsRequired64 and the zig-zag pair
  check(serialize.bitsRequired(0, 7) == 3, "bitsRequired(0,7)")
  check(serialize.bitsRequired(0, 8) == 4, "bitsRequired(0,8)")
  check(serialize.bitsRequired(2, 2) == 0, "bitsRequired degenerate")
  check(serialize.bitsRequired(0, 255) == 8, "bitsRequired(0,255)")
  check(serialize.bitsRequired64(0, 255) == 8, "bitsRequired64(0,255)")
  check(serialize.bitsRequired64(-1, 0) == 1, "bitsRequired64 unsigned diff")
  check(serialize.bitsRequired64(0, -1) == 64, "bitsRequired64(0,uint64 max)")
  local zz = function(n) return serialize.unsignedToSigned(serialize.signedToUnsigned(n)) end
  local conv = { 0, -1, 1, -2, 2, 2147483647, -2147483648 }
  for _, n in ipairs(conv) do
    check(zz(n) == n, "zig-zag round trip " .. n)
  end
  check(serialize.signedToUnsigned(-1) == 1, "signedToUnsigned(-1)")
  check(serialize.signedToUnsigned(0) == 0, "signedToUnsigned(0)")
  check(serialize.unsignedToSigned(1) == -1, "unsignedToSigned(1)")
  check(serialize.unsignedToSigned(0) == 0, "unsignedToSigned(0)")
end
