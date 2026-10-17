-- test/conformance: TestGoldenWireFormat (serialize-lua-conformance).
-- serialize.go v1.15.1's TestGoldenWireFormat golden bytes (goldenWireBytes in
-- .ref/serialize.go/serialize_test.go) read and re-written byte for byte, and
-- every single-bit flip of a consumed bit refused or decoded differently. The
-- bytes are pasted as a literal, independent of the corpus parser; the corpus
-- runner in conformance_test.lua drives the message-golden-whole record (read,
-- canonical re-write byte for byte, measure).

local C = assert(loadfile("test/conformance/conformance_test.lua"))()
local serialize = require("serialize")
local flt = require("serialize_float")

-- goldenWireBytes from .ref/serialize.go/serialize_test.go (v1.15.1), the
-- 112-byte workspace message; conformance/message.txt carries the same bytes.
local GOLDEN_BYTES =
  "5D DA F7 E6 D5 77 DF 56 EF 9F 75 19 52 BC DA 0F 49 40 F4 55 55 55 55 55 " ..
  "55 55 FF FC D1 48 E0 59 D1 48 C0 7B F3 6A E2 59 D1 48 84 B7 06 DE AD BE " ..
  "EF CA FE 01 06 67 6F 6C 64 65 6E E3 21 00 00 C0 21 00 00 00 22 00 00 00 " ..
  "C0 60 00 80 A2 7C FC EC 26 CB FF FF 4B 1D 1F EF D2 1A 1F 01 E9 FF FF 09 " ..
  "19 2A 3B 4C 5D 6E 7F 78 6F 5E 4D 3C 2B 1A 09 04"

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local function dbits(v)
  return string.unpack("<i8", string.pack("<d", v))
end

-- compare two decoded values for one step: bit patterns for the float family,
-- numeric/pair equality otherwise.
local function decodedEqual(st, a, b)
  if st.op == "float" or st.op == "compressed_float" then
    return flt.float32Bits(a) == flt.float32Bits(b)
  end
  if st.op == "double" then
    return dbits(a) == dbits(b)
  end
  return C.valueEquals(a, b)
end

local function findRecord(name)
  for _, rec in ipairs(C.parseVectors("conformance/message.txt")) do
    if rec.name == name then return rec end
  end
  error("golden record not found: " .. name)
end

function TestGoldenWireFormat()
  local rec = findRecord("message-golden-whole")
  local consumed = rec.consumed
  check(consumed == 891, "golden consumed " .. tostring(consumed) .. ", want 891")

  -- the pasted serialize.go pin and the corpus record state the same bytes
  local data = C.unhex(GOLDEN_BYTES)
  check(data == C.unhex(rec.bytes), "golden literal and conformance/message.txt disagree")

  -- read + canonical re-write byte for byte (message.golden.whole carries writer
  -- canonical), plus the measure floor.
  C.runRecord(rec)

  -- every single-bit flip of a consumed bit is refused or decoded differently
  local steps = C.expandSteps(C.buildSteps(rec))
  local ok, base = C.runSteps(serialize.ReadStream.new(data), steps, "read")
  check(ok, "golden base read failed")

  local flips = 0
  for bit = 0, consumed - 1 do
    local byte = math.floor(bit / 8) + 1
    local mask = 1 << (bit % 8)
    local flipped = data:sub(1, byte - 1) .. string.char(data:byte(byte) ~ mask) .. data:sub(byte + 1)
    local rs = serialize.ReadStream.new(flipped)
    local ok2, vals = C.runSteps(rs, steps, "read")
    if not ok2 then
      flips = flips + 1
    else
      local differs = false
      if rs:bitsProcessed() ~= consumed then
        differs = true
      else
        for i, st in ipairs(steps) do
          if st.op ~= "object" then
            if not decodedEqual(st, vals[i], base[i]) then
              differs = true
              break
            end
          end
        end
      end
      check(differs, "bit " .. bit .. " flipped but decoded identically")
      flips = flips + 1
    end
  end
  check(flips == consumed, "flip coverage: " .. flips .. " of " .. consumed .. " bits exercised")
end
