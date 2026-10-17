-- test/float: float and double, with float32 rounding (serialize-lua-float).
-- Run by `make test T=float` from the repository root. Pins: every record of
-- conformance/float.txt and double.txt, comparing BIT PATTERNS (STANDARD.md,
-- "Bit transparency — both directions"): accepted records read and (when
-- canonical) write the exact bytes; refused records latch Overflow and leave
-- the holder untouched. fround pins Go's float32() conversion on a table of
-- edges computed by Go at `.ref/gen_fround_edges` (JOB.md). No real time, no
-- sockets, no network: io only reads the two conformance files.

local serialize = require("serialize")
local flt = require("serialize_float")

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

-- ---------------------------------------------------------------------------
-- conformance vector parsing (STANDARD.md, "The vector format")
-- ---------------------------------------------------------------------------

local function parseVectors(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("a")
  f:close()
  local records = {}
  local rec
  for line in text:gmatch("[^\n]+") do
    if not line:match("^#") then
      if line:match("^%s*$") then
        rec = nil
      else
        local op = line:match("^operation%s+(%S+)")
        if op then
          rec = { operation = op }
          records[#records + 1] = rec
        elseif rec then
          local key, value = line:match("^(%S+)%s*(.*)$")
          rec[key] = value
        end
      end
    end
  end
  return records
end

local function unhex(s)
  if s == nil or s == "" then return "" end
  local out = {}
  for byte in s:gmatch("%x%x") do
    out[#out + 1] = string.char(tonumber(byte, 16))
  end
  return table.concat(out)
end

-- hex (without 0x), up to 16 digits, as an int64 (wraps past 2^63)
local function parseBits(hex)
  local digits = #hex
  local loHex = hex:sub(math.max(1, digits - 7), digits)
  local hiHex = hex:sub(1, math.max(0, digits - 8))
  local lo = tonumber(loHex, 16) or 0
  local hi = (hiHex ~= "") and tonumber(hiHex, 16) or 0
  return (hi << 32) | lo
end

local function dbits(v)
  return string.unpack("<i8", string.pack("<d", v))
end

-- ---------------------------------------------------------------------------
-- the conformance run
-- ---------------------------------------------------------------------------

local SPECS = {
  { "float", "conformance/float.txt", "serializeFloat" },
  { "double", "conformance/double.txt", "serializeDouble" },
}

function TestSerializeFloat()
  local total = 0
  for _, spec in ipairs(SPECS) do
    local op, path, methodName = spec[1], spec[2], spec[3]
    local records = parseVectors(path)
    check(#records == 18, op .. ": expected 18 records, parsed " .. #records)
    print(op .. ".txt: " .. #records .. " records")
    for _, rec in ipairs(records) do
      check(rec.operation == "float" or rec.operation == "double", op .. ": bad operation " .. tostring(rec.operation))
      local bytes = unhex(rec.bytes)
      if rec.expect == "refused" then
        local rs = serialize.ReadStream.new(bytes)
        local holder = { value = nil }
        check(rs[methodName](rs, holder) == false, op .. ": " .. rec.name .. " must refuse")
        check(rs:error() == serialize.SerializeError.Overflow, op .. ": " .. rec.name .. " latches Overflow")
        check(holder.value == nil, op .. ": " .. rec.name .. " leaves the holder untouched")
      else
        local expectHex = assert(rec.expect:match("bits = 0x([0-9a-fA-F]+)"), op .. ": " .. rec.name .. " expect bits")
        local want = parseBits(expectHex)
        local wantConsumed = tonumber(rec.consumed) or 0
        -- read
        local rs = serialize.ReadStream.new(bytes)
        local holder = { value = nil }
        check(rs[methodName](rs, holder) == true, op .. ": " .. rec.name .. " read failed")
        check(rs:bitsProcessed() == wantConsumed, op .. ": " .. rec.name .. " consumed " .. rs:bitsProcessed() .. " want " .. wantConsumed)
        if op == "float" then
          check(flt.float32Bits(holder.value) == want, op .. ": " .. rec.name .. " read bits")
        else
          check(dbits(holder.value) == want, op .. ": " .. rec.name .. " read bits")
        end
        total = total + 1
        -- canonical write reproduces the bytes
        if rec.writer == "canonical" then
          local value
          if op == "float" then
            value = flt.float32FromBits(want)
          else
            value = string.unpack("<d", string.pack("<i8", want))
          end
          local ws = serialize.WriteStream.new(math.max(8, #bytes))
          check(ws[methodName](ws, { value = value }) == true, op .. ": " .. rec.name .. " write failed")
          ws:flush()
          check(ws:data() == bytes, op .. ": " .. rec.name .. " write bytes")
        end
      end
    end
  end
  check(total > 0, "no accepted float/double record was exercised")

  -- -------------------------------------------------------------------------
  -- fround: Go's float32() on a table of edges computed at .ref (JOB.md).
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
    { 0x7FF8000000000001, 0x7FC00000 },
    { 0x7FF4000000000001, 0x7FE00000 },
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
    -- subnormal rounding regressions (JOB.md attempt 2): single rounding of
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
end
