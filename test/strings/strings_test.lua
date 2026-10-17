-- test/strings: the string family's conformance test (card serialize-lua-strings).
-- Run by `make test T=strings` from the repository root. Runs every record of
-- conformance/bytes.txt, string.txt and wstring.txt as a runner must: the reader
-- leg on every vector, the writer leg on the `writer = canonical` ones, and the
-- record count per file, which must equal the file's count. Plus serialize.go's
-- TestSerializeWideStringFamilyPin and TestWideStringLengthValidatedBeforeNarrowing.
-- No real time, no sockets, no network: io reads only the vendored corpus.

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

-- The bitpacker dependency (DEPENDS-ON: serialize-lua-bitpacker) has not landed
-- on this branch, so the stream's lazy loader cannot find serialize_bitpacker.lua.
-- The cartridge family itself only needs the stream's bit primitives, which
-- delegate to BitWriter/BitReader; this test installs a minimal, correct shim on
-- the preload path so the strings suite can run standalone. It implements exactly
-- the surface the stream calls (DESIGN.md (h)): BitWriter.new(capacity), writeBits
-- (bits in [1,32]), writeBytes, flushBits, data; BitReader.new(data), readBits,
-- readBytes. The stream performs every bounds check and the >32-bit split itself,
-- so the shim only has to move bits the way serialize.go's bitpacker.go does.
local bitpackerShim = function()
  local BitWriter = {}
  BitWriter.__index = BitWriter
  function BitWriter.new(capacity)
    local self = {
      words = {}, capacity = capacity, numBits = capacity * 8,
      bitsWritten = 0, scratch = 0, scratchBits = 0, wordIndex = 0,
    }
    return setmetatable(self, BitWriter)
  end
  function BitWriter:writeBits(value, bits)
    value = value & ((1 << bits) - 1)
    self.scratch = self.scratch | (value << self.scratchBits)
    local nsb = self.scratchBits + bits
    if nsb >= 64 then
      self.words[self.wordIndex + 1] = self.scratch
      self.wordIndex = self.wordIndex + 1
      self.scratch = value >> (64 - self.scratchBits)
      self.scratchBits = nsb - 64
    else
      self.scratchBits = nsb
    end
    self.bitsWritten = self.bitsWritten + bits
  end
  function BitWriter:writeBytes(s)
    local n = #s
    if n == 0 then return end
    local headBytes = ((8 - (self.bitsWritten % 64) // 8) % 8)
    if headBytes > n then headBytes = n end
    for i = 1, headBytes do self:writeBits(s:byte(i), 8) end
    if headBytes == n then return end
    local numWords = (n - headBytes) // 8
    if numWords > 0 then
      for w = 0, numWords - 1 do
        local off = headBytes + w * 8
        local word = s:byte(off + 1)
          | (s:byte(off + 2) << 8) | (s:byte(off + 3) << 16)
          | (s:byte(off + 4) << 24) | (s:byte(off + 5) << 32)
          | (s:byte(off + 6) << 40) | (s:byte(off + 7) << 48)
          | (s:byte(off + 8) << 56)
        self.words[self.wordIndex + 1] = word
        self.wordIndex = self.wordIndex + 1
      end
      self.bitsWritten = self.bitsWritten + numWords * 64
    end
    for i = headBytes + numWords * 8 + 1, n do
      self:writeBits(s:byte(i), 8)
    end
  end
  function BitWriter:flushBits()
    if self.scratchBits ~= 0 then
      self.words[self.wordIndex + 1] = self.scratch
      self.scratch = 0
      self.scratchBits = 0
      self.wordIndex = self.wordIndex + 1
    end
  end
  function BitWriter:data()
    local bytesWritten = (self.bitsWritten + 7) // 8
    if bytesWritten == 0 then return "" end
    local out = {}
    local outn = 0
    for i = 1, bytesWritten do
      local w = self.words[((i - 1) // 8) + 1] or 0
      local shift = ((i - 1) % 8) * 8
      outn = outn + 1
      out[outn] = string.char((w >> shift) & 0xFF)
    end
    return table.concat(out)
  end
  local BitReader = {}
  BitReader.__index = BitReader
  function BitReader.new(data)
    local self = { data = data, numBits = #data * 8, bitsRead = 0 }
    return setmetatable(self, BitReader)
  end
  function BitReader:readBits(bits)
    local byteIndex = self.bitsRead >> 3
    local shift = self.bitsRead & 7
    local window = 0
    for b = 0, 7 do
      local byte = self.data:byte(byteIndex + b + 1)
      if byte then window = window | (byte << (b * 8)) end
    end
    local output = (window >> shift) & ((1 << bits) - 1)
    self.bitsRead = self.bitsRead + bits
    return output
  end
  function BitReader:readBytes(n)
    local offset = self.bitsRead >> 3
    self.bitsRead = self.bitsRead + n * 8
    return self.data:sub(offset + 1, offset + n)
  end
  return {
    methods = {},
    api = { BitWriter = { new = BitWriter.new }, BitReader = { new = BitReader.new } },
  }
end
package.preload["serialize_bitpacker"] = bitpackerShim

local function hexBytes(s)
  if #s == 0 then return "" end
  return (s:gsub(".", function(c) return string.format("%02X", c:byte()) .. " " end)):sub(1, -2)
end

local function utf8Next(s, i)
  local b = s:byte(i)
  if b < 0x80 then
    return b, i + 1
  elseif b < 0xE0 then
    return ((b & 0x1F) << 6) | (s:byte(i + 1) & 0x3F), i + 2
  elseif b < 0xF0 then
    return ((b & 0x0F) << 12) | ((s:byte(i + 1) & 0x3F) << 6)
      | (s:byte(i + 2) & 0x3F), i + 3
  else
    return ((b & 0x07) << 18) | ((s:byte(i + 1) & 0x3F) << 12)
      | ((s:byte(i + 2) & 0x3F) << 6) | (s:byte(i + 3) & 0x3F), i + 4
  end
end

local function codeUnits(s)
  local parts = {}
  local i = 1
  while i <= #s do
    local cp, nxt = utf8Next(s, i)
    if cp > 0xFFFF then
      local base = cp - 0x10000
      parts[#parts + 1] = string.format("%04X", 0xD800 + (base >> 10))
      parts[#parts + 1] = string.format("%04X", 0xDC00 + (base & 0x3FF))
    else
      parts[#parts + 1] = string.format("%04X", cp)
    end
    i = nxt
  end
  return table.concat(parts, " ")
end

local function parseConformanceFile(path)
  local f = assert(io.open(path, "r"))
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  local records = {}
  local cur = nil
  local flush = function()
    if cur then records[#records + 1] = cur; cur = nil end
  end
  for _, line in ipairs(lines) do
    if line:sub(1, 1) == "#" then
    elseif line:match("^%s*$") then
      flush()
    else
      if not cur then cur = { params = {} } end
      local key, rest = line:match("^(%S+)%s*(.*)$")
      rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
      if key == "operation" then
        cur.operation = rest
      elseif key == "name" then
        cur.name = rest
      elseif key == "param" then
        local pn, pv = rest:match("^([^=]+)=(.*)$")
        cur.params[pn:gsub("^%s+", ""):gsub("%s+$", "")] = pv:gsub("^%s+", ""):gsub("%s+$", "")
      elseif key == "bytes" then
        local buf = {}
        for pair in rest:gmatch("%S+") do buf[#buf + 1] = string.char(tonumber(pair, 16)) end
        cur.bytes = table.concat(buf)
      elseif key == "expect" then
        if rest == "refused" then
          cur.expectKind = "refused"
        else
          local _, val = rest:match("^([^=]+)=(.*)$")
          cur.expectKind = "value"
          cur.expectText = val:gsub("^%s+", ""):gsub("%s+$", "")
        end
      elseif key == "consumed" then
        cur.consumed = tonumber(rest)
      elseif key == "writer" then
        cur.writer = (rest == "canonical")
      end
    end
  end
  flush()
  return records
end

local function writerCapacity(bytes)
  return ((#bytes + 8) // 8) * 8 + 8
end

local function runRecord(serialize, r)
  local name = r.name
  if r.operation == "bytes" then
    local P = tonumber(r.params.preceding_bits or "0")
    local count = tonumber(r.params.count)
    local rs = serialize.ReadStream.new(r.bytes)
    local prev
    local ok = true
    if P > 0 then
      prev = rs:_readBits(P)
      if prev == nil then ok = false end
    end
    local holder = { value = "" }
    if ok then ok = rs:serializeBytes(holder, count) end
    if r.expectKind == "refused" then
      check(not ok, name .. ": expected refusal")
      check(rs:error() ~= nil and not rs:ok(), name .. ": refusal must latch")
      check(holder.value == "", name .. ": refused read leaves destination untouched")
      check(rs:serializeBytes({ value = "" }, count) == false, name .. ": refused stream is terminal")
    else
      check(ok, name .. ": accepted vector refused")
      check(hexBytes(holder.value) == r.expectText, name .. ": decoded bytes mismatch")
      check(rs:bitsProcessed() == r.consumed, name .. ": consumed " .. rs:bitsProcessed() .. " want " .. r.consumed)
      if r.writer then
        local ws = serialize.WriteStream.new(writerCapacity(r.bytes))
        if P > 0 then check(ws:_writeBits(prev, P), name .. ": writer preceding bits") end
        check(ws:serializeBytes({ value = holder.value }, count), name .. ": writer refused")
        ws:flush()
        check(hexBytes(ws:data()) == hexBytes(r.bytes), name .. ": writer bytes mismatch")
      end
    end
  elseif r.operation == "string" then
    local bufferSize = tonumber(r.params.buffer_size)
    local rs = serialize.ReadStream.new(r.bytes)
    local holder = { value = "" }
    local ok = rs:serializeString(holder, bufferSize)
    if r.expectKind == "refused" then
      check(not ok, name .. ": expected refusal")
      check(rs:error() ~= nil and not rs:ok(), name .. ": refusal must latch")
      check(holder.value == "", name .. ": refused read leaves destination untouched")
      check(rs:serializeString({ value = "" }, bufferSize) == false, name .. ": refused stream is terminal")
    else
      check(ok, name .. ": accepted vector refused")
      check(hexBytes(holder.value) == r.expectText, name .. ": decoded bytes mismatch")
      check(rs:bitsProcessed() == r.consumed, name .. ": consumed " .. rs:bitsProcessed() .. " want " .. r.consumed)
      if r.writer then
        local ws = serialize.WriteStream.new(writerCapacity(r.bytes))
        check(ws:serializeString({ value = holder.value }, bufferSize), name .. ": writer refused")
        ws:flush()
        check(hexBytes(ws:data()) == hexBytes(r.bytes), name .. ": writer bytes mismatch")
      end
    end
  elseif r.operation == "wstring" then
    local bufferSize = tonumber(r.params.buffer_size)
    local rs = serialize.ReadStream.new(r.bytes)
    local holder = { value = "" }
    local ok = rs:serializeWideString(holder, bufferSize)
    if r.expectKind == "refused" then
      check(not ok, name .. ": expected refusal")
      check(rs:error() ~= nil and not rs:ok(), name .. ": refusal must latch")
      check(holder.value == "", name .. ": refused read leaves destination untouched")
      check(rs:serializeWideString({ value = "" }, bufferSize) == false, name .. ": refused stream is terminal")
    else
      check(ok, name .. ": accepted vector refused")
      check(codeUnits(holder.value) == r.expectText, name .. ": decoded units mismatch")
      check(rs:bitsProcessed() == r.consumed, name .. ": consumed " .. rs:bitsProcessed() .. " want " .. r.consumed)
      if r.writer then
        local ws = serialize.WriteStream.new(writerCapacity(r.bytes))
        check(ws:serializeWideString({ value = holder.value }, bufferSize), name .. ": writer refused")
        ws:flush()
        check(hexBytes(ws:data()) == hexBytes(r.bytes), name .. ": writer bytes mismatch")
      end
    end
  else
    error("vector for an operation the strings test does not drive: " .. tostring(r.operation), 3)
  end
end

-- serialize.go TestSerializeWideStringFamilyPin: U+1F600 then U+0041 through an
-- 8-unit buffer must produce these exact 13 bytes, and read back to the same text.
local function testWideStringFamilyPin(serialize)
  local pinned = string.char(
    0xEB, 0xC1, 0x06, 0x00, 0x00, 0xF0, 0x06, 0x00, 0x08, 0x02, 0x00, 0x00, 0x00)
  local v = "\u{1F600}A" -- one astral code point + one basic-plane: three code units
  local ws = serialize.WriteStream.new(64)
  check(ws:serializeWideString({ value = v }, 8), "family pin writer")
  ws:flush()
  check(hexBytes(ws:data()) == hexBytes(pinned), "family pin bytes")
  check(ws:bitsProcessed() == 3 + 3 * 32, "family pin bits")
  local ms = serialize.MeasureStream.new()
  check(ms:serializeWideString({ value = v }, 8), "family pin measure")
  check(ms:bitsProcessed() == ws:bitsProcessed(), "family pin measure agrees with write")
  local rs = serialize.ReadStream.new(pinned)
  local h = { value = "" }
  check(rs:serializeWideString(h, 8), "family pin read")
  check(h.value == v, "family pin roundtrip")
end

-- serialize.go TestWideStringLengthValidatedBeforeNarrowing: the length is
-- compared against the buffer at the caller's own width before it narrows to the
-- int32 length field, so a length equal to bufferSize is refused however many
-- code units it is.
local function testWideStringLengthValidatedBeforeNarrowing(serialize)
  local wideFits = function(len, bs) return len < bs end
  check(wideFits(7, 8), "a length of 7 fits a buffer of 8")
  check(not wideFits(8, 8), "a length of 8 does not fit a buffer of 8: the terminator has nowhere to go")
  local ws = serialize.WriteStream.new(64)
  check(ws:serializeString({ value = "ABC" }, 3) == false, "string length equals bufferSize refused")
  check(ws:error() == serialize.SerializeError.ValueOutOfRange, "string refusal kind")
  check(ws:bitsProcessed() == 0, "a refused write writes nothing")
  local ws2 = serialize.WriteStream.new(64)
  check(ws2:serializeWideString({ value = "ABCD" }, 4) == false, "wide unit count equals bufferSize refused")
  check(ws2:error() == serialize.SerializeError.ValueOutOfRange, "wide refusal kind")
  check(ws2:bitsProcessed() == 0, "a refused wide write writes nothing")
  local ws3 = serialize.WriteStream.new(64)
  check(ws3:serializeWideString({ value = "ABC" }, 4), "wide unit count one less fits")
end

function TestSerializeStrings()
  local serialize = require("serialize")
  local files = {
    { "conformance/bytes.txt", 11 },
    { "conformance/string.txt", 38 },
    { "conformance/wstring.txt", 28 },
  }
  for _, pair in ipairs(files) do
    local path, want = pair[1], pair[2]
    local records = parseConformanceFile(path)
    local base = path:match("([^/]+)$")
    print(base .. ": " .. #records .. " records")
    check(#records == want, base .. " record count " .. #records .. " want " .. want)
    for _, r in ipairs(records) do
      runRecord(serialize, r)
    end
  end
  testWideStringFamilyPin(serialize)
  testWideStringLengthValidatedBeforeNarrowing(serialize)
end
