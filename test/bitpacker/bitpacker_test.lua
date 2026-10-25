-- test/bitpacker: the bit writer and bit reader (card serialize-lua-bitpacker).
-- Run by `make test T=bitpacker` from the repository root. Pins:
--   1. every width 1..32 at every starting bit offset 0..63, against an
--      independent bit-by-bit LSB-first oracle written here (DESIGN.md (b));
--   2. the sequence of serialize.go v1.15.1's TestBitpacker byte for byte;
--   3. readBits round-trips the same matrix;
--   4. a read past the end is refused by wouldReadPastEnd and raises the
--      reader's overflow error, and data of 0..9 bytes reads nothing outside
--      itself (STANDARD.md, Reader Obligations; DESIGN.md (d), (g));
--   5. readAlign refuses a nonzero padding bit (STANDARD.md, align).
-- No real time, no sockets, no network.

local serialize = require("serialize")

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local function raises(fn, want)
  local ok, err = pcall(fn)
  check(not ok, "expected a raise containing: " .. want)
  check(string.find(tostring(err), want, 1, true) ~= nil,
    "raise was \"" .. tostring(err) .. "\", wanted it to contain \"" .. want .. "\"")
end

-- The independent oracle: pack fields LSB-first, one bit at a time, into a
-- byte table. Never calls the code under test.
local function oracle(fields)
  local total = 0
  for _, f in ipairs(fields) do total = total + f[2] end
  local bytes = {}
  for i = 0, (total + 7) // 8 - 1 do bytes[i + 1] = 0 end
  local pos = 0
  for _, f in ipairs(fields) do
    local value, bits = f[1], f[2]
    for i = 0, bits - 1 do
      local bit = (value >> i) & 1
      local idx = pos + i
      local b = idx // 8
      bytes[b + 1] = bytes[b + 1] | (bit << (idx % 8))
    end
    pos = pos + bits
  end
  return string.char(table.unpack(bytes)), total
end

local function writePrefix(w, bits)
  local rem = bits
  while rem > 0 do
    local c = math.min(rem, 32)
    w:writeBits(0, c)
    rem = rem - c
  end
end

local function readPrefix(r, bits)
  local rem = bits
  while rem > 0 do
    local c = math.min(rem, 32)
    local v = r:readBits(c)
    check(v == 0, "the zero prefix must read back as zero")
    rem = rem - c
  end
end

function TestBitpacker()
  -- 1 and 3: every width at every starting bit offset, writer against the
  -- oracle, then the reader round-trips it.
  for bits = 1, 32 do
    for offset = 0, 63 do
      local value = (0xDEADBEEF >> (32 - bits)) & ((1 << bits) - 1)
      local w = serialize.BitWriter.new(16)
      writePrefix(w, offset)
      w:writeBits(value, bits)
      w:flushBits()

      local fields = {}
      if offset > 0 then fields[#fields + 1] = { 0, offset } end
      fields[#fields + 1] = { value, bits }
      local expected, total = oracle(fields)
      check(w:bitsWritten() == total, "bitsWritten at width " .. bits .. " offset " .. offset)
      check(w:bitsAvailable() == 16 * 8 - total, "bitsAvailable at width " .. bits .. " offset " .. offset)
      check(w:alignBits() == (8 - total % 8) % 8, "alignBits at width " .. bits .. " offset " .. offset)
      check(w:bytesWritten() == (total + 7) // 8, "bytesWritten at width " .. bits .. " offset " .. offset)
      check(w:data() == expected, "writer bytes differ from the oracle at width " .. bits .. " offset " .. offset)

      local r = serialize.BitReader.new(w:data())
      readPrefix(r, offset)
      check(r:readBits(bits) == value, "readBits round trip at width " .. bits .. " offset " .. offset)
      check(r:bitsRead() == total, "bitsRead at width " .. bits .. " offset " .. offset)
      check(r:bitsRemaining() == #w:data() * 8 - total,
        "bitsRemaining at width " .. bits .. " offset " .. offset)
    end
  end

  -- 2: serialize.go v1.15.1 TestBitpacker, byte for byte. The values and
  -- widths are its sequence; the expected bytes follow from the LSB-first
  -- wire and are pinned here.
  do
    local w = serialize.BitWriter.new(256)
    check(w:bitsWritten() == 0 and w:bytesWritten() == 0 and w:bitsAvailable() == 256 * 8,
      "bad initial writer state")
    w:writeBits(0, 1)
    w:writeBits(1, 1)
    w:writeBits(10, 8)
    w:writeBits(255, 8)
    w:writeBits(1000, 10)
    w:writeBits(50000, 16)
    w:writeBits(9999999, 32)
    w:flushBits()
    local bitsWritten = 1 + 1 + 8 + 8 + 10 + 16 + 32
    check(w:bytesWritten() == 10, "expected 10 bytes written, got " .. w:bytesWritten())
    check(w:bitsWritten() == bitsWritten, "expected " .. bitsWritten .. " bits written")
    check(w:bitsAvailable() == 256 * 8 - bitsWritten, "bad bits available")
    local expected = string.char(0x2a, 0xfc, 0xa3, 0x0f, 0x35, 0xfc, 0x67, 0x89, 0x09, 0x00)
    check(w:data() == expected, "the TestBitpacker sequence is not byte for byte")

    local r = serialize.BitReader.new(w:data())
    check(r:bitsRead() == 0 and r:bitsRemaining() == 10 * 8, "bad initial reader state")
    check(r:readBits(1) == 0, "a")
    check(r:readBits(1) == 1, "b")
    check(r:readBits(8) == 10, "c")
    check(r:readBits(8) == 255, "d")
    check(r:readBits(10) == 1000, "e")
    check(r:readBits(16) == 50000, "f")
    check(r:readBits(32) == 9999999, "g")
    check(r:bitsRead() == bitsWritten, "bad bits read")
    check(r:bitsRemaining() == 10 * 8 - bitsWritten, "bad bits remaining")
    check(not r:wouldReadPastEnd(r:bitsRemaining()), "reading the remaining bits must be legal")
    check(r:wouldReadPastEnd(r:bitsRemaining() + 1), "reading past the remaining bits must report past the end")
  end

  -- 4: an end is an end: wouldReadPastEnd says so, the read raises the
  -- reader's overflow error, and a buffer of 0..9 bytes is never read past.
  for n = 0, 9 do
    local bytes = {}
    for i = 1, n do bytes[i] = string.char(((i * 37) & 0xff)) end
    local data = table.concat(bytes)
    local r = serialize.BitReader.new(data)
    check(r:bitsRead() == 0 and r:bitsRemaining() == n * 8, "reader state at " .. n .. " bytes")
    check(not r:wouldReadPastEnd(n * 8), "reading all of " .. n .. " bytes must be legal")
    check(r:wouldReadPastEnd(n * 8 + 1), "one bit past " .. n .. " bytes must report the end")
    local rem = n * 8
    while rem > 0 do
      local c = math.min(rem, 32)
      local v = r:readBits(c)
      check(v ~= nil, "reading inside " .. n .. " bytes must succeed")
      rem = rem - c
    end
    check(r:bitsRemaining() == 0, "all bits of " .. n .. " bytes read")
    raises(function() r:readBits(1) end, "serialize: bit reader would read past the end of the buffer")
    raises(function() r:readBytes(1) end, "serialize: bit reader would read past the end of the buffer")

    -- every legal single-bit offset inside the data, including the last bit
    for offset = 0, n * 8 - 1 do
      local rr = serialize.BitReader.new(data)
      local left = offset
      while left > 0 do
        local c = math.min(left, 32)
        rr:readBits(c)
        left = left - c
      end
      check(not rr:wouldReadPastEnd(1), "offset " .. offset .. " in " .. n .. " bytes must hold a bit")
      local bit = rr:readBits(1)
      check(bit == 0 or bit == 1, "a read bit is 0 or 1")
    end
  end

  -- 5: readAlign verifies zero padding and refuses nonzero padding.
  do
    local w = serialize.BitWriter.new(8)
    w:writeBits(1, 1)
    w:flushBits()
    local r = serialize.BitReader.new(w:data())
    check(r:readBits(1) == 1, "the data bit")
    check(r:readAlign() == true, "zero padding must be accepted")
    check(r:bitsRead() == 8, "readAlign consumes the padding")

    local bad = serialize.BitReader.new(string.char(0xff))
    check(bad:readBits(1) == 1, "the data bit of the bad packet")
    check(bad:readAlign() == false, "nonzero padding must be refused")
  end

  -- The aligned byte block: writeBytes and readBytes round-trip, including a
  -- block longer than one word and a head that starts mid-word.
  do
    local w = serialize.BitWriter.new(64)
    w:writeBits(0x5, 3)
    w:writeAlign()
    local s = "hello, bitpacked bytes!"
    w:writeBytes(s)
    w:flushBits()
    local r = serialize.BitReader.new(w:data())
    check(r:readBits(3) == 0x5, "the lead bits")
    check(r:readAlign() == true, "aligned after the lead")
    check(r:readBytes(#s) == s, "writeBytes/readBytes round trip")
    check(r:bitsRemaining() == #w:data() * 8 - (3 + 5 + #s * 8), "byte block accounting")
    w:reset(8)
    check(w:bitsWritten() == 0 and w:bytesWritten() == 0 and w:data() == "", "reset clears the writer")
  end

  -- Misuse raises where serialize.go panics.
  raises(function() serialize.BitWriter.new(7) end,
    "serialize: bit writer buffer size must be a multiple of 8 bytes")
  local w = serialize.BitWriter.new(8)
  raises(function() w:writeBits(0, 0) end, "serialize: bits must be in [1,32]")
  raises(function() w:writeBits(0, 33) end, "serialize: bits must be in [1,32]")
  w:writeBits(0, 1)
  raises(function() w:writeBytes("x") end, "serialize: byte array serialization requires byte alignment")
  local full = serialize.BitWriter.new(8)
  full:writeBits(0, 32)
  full:writeBits(0, 32)
  raises(function() full:writeBits(0, 1) end, "serialize: bit writer overflow")
end
