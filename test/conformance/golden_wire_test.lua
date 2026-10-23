-- test/conformance: TestGoldenWireFormat (serialize-lua-conformance).
-- The golden message of STANDARD.md, "The whole message" (format 2.0, 106
-- bytes, ending with serialize_end), read and re-written byte for byte, and
-- every single-bit flip of the 848 bits the read consumes (the end's padding
-- included) refused or decoded differently. The bytes are pasted as a literal
-- from STANDARD.md, independent of the corpus parser; the corpus runner in
-- conformance_test.lua drives the message-golden-whole record (read, reasons,
-- canonical re-write byte for byte, measure).

local C = assert(loadfile("test/conformance/conformance_test.lua"))()
local serialize = require("serialize")
local flt = require("serialize_float")

-- STANDARD.md, "The whole message": 106 bytes.
local GOLDEN_BYTES =
  "5D DA F7 E6 D5 77 DF 56 EF 9F 75 19 52 BC DA 0F 49 40 F4 55 55 55 55 55 " ..
  "55 55 FF FC D1 48 E0 59 D1 48 C0 7B F3 6A E2 59 D1 48 84 B7 06 DE AD BE " ..
  "EF CA FE 01 06 67 6F 6C 64 65 6E 06 E7 A2 81 E7 9F B3 C0 60 00 80 A2 7C " ..
  "FC EC 26 CB FF FF 4B 1D 1F EF D2 1A 1F 01 E9 FF FF 09 19 2A 3B 4C 5D 6E " ..
  "7F 78 6F 5E 4D 3C 2B 1A 09 04"

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local function dbits(v)
  return string.unpack("<i8", string.pack("<d", v))
end

-- compare two decoded values for one step: bit patterns for the float family,
-- exact equality otherwise (128-bit values as both halves).
local function decodedEqual(st, a, b)
  if st.op == "float" or st.op == "compressed_float" then
    return flt.float32Bits(a) == flt.float32Bits(b)
  end
  if st.op == "double" then
    return dbits(a) == dbits(b)
  end
  if type(a) == "table" and type(b) == "table" then
    return a.lo == b.lo and a.hi == b.hi
  end
  return a == b
end

local function findRecord(name)
  for _, rec in ipairs(C.parseVectors(C.corpusRoot .. "/conformance/message.txt")) do
    if rec.name == name then return rec end
  end
  error("golden record not found: " .. name)
end

function TestGoldenWireFormat()
  local rec = findRecord("message-golden-whole")
  local consumed = rec.consumed
  check(consumed == 848, "golden consumed " .. tostring(consumed) .. ", want 848")

  -- STANDARD.md's bytes and the corpus record state the same 106 bytes
  local data = C.unhex(GOLDEN_BYTES)
  check(#data == 106, "golden literal is " .. #data .. " bytes, want 106")
  check(data == rec.bytes, "golden literal and conformance/message.txt disagree")

  -- read + canonical re-write byte for byte, plus the measure floor
  C.runRecord(rec)

  -- every single-bit flip of a consumed bit is refused or decoded differently
  local steps = C.buildSteps(rec)
  local tree = C.treeOf(steps)
  check(steps[#steps].op == "end", "the golden message ends with serialize_end")
  local _, ok, base = C.readAll(data, steps, tree)
  check(ok, "golden base read failed")

  local flips, refused = 0, 0
  for bit = 0, consumed - 1 do
    local byte = bit // 8 + 1
    local mask = 1 << (bit % 8)
    local flipped = data:sub(1, byte - 1) .. string.char(data:byte(byte) ~ mask) .. data:sub(byte + 1)
    local rs, ok2, out = C.readAll(flipped, steps, tree)
    if not ok2 then
      refused = refused + 1
    else
      local differs = rs:bitsProcessed() ~= consumed
      for i, st in ipairs(steps) do
        if not differs and st.op ~= "object" then
          differs = not decodedEqual(st, out[i].holder.value, base[i].holder.value)
        end
      end
      check(differs, "bit " .. bit .. " flipped but decoded identically")
    end
    flips = flips + 1
  end
  check(flips == consumed, "flip coverage: " .. flips .. " of " .. consumed .. " bits exercised")
  -- the end's five padding bits are refused, never decoded
  check(refused >= 5, "the end's padding flips must be refused, " .. refused .. " refused")
end

-- The serialize.lua writer emits the golden message from its values, and the
-- packet reader that ends with serialize_end refuses the same bytes with one
-- byte appended (trailing_data) and with a padding bit set (nonzero_padding).
function TestGoldenMessageEnd()
  local rec = findRecord("message-golden-whole")
  local steps = C.buildSteps(rec)
  local tree = C.treeOf(steps)
  local data = C.unhex(GOLDEN_BYTES)

  local rs = select(1, C.readAll(data .. "\0", steps, tree))
  check(rs:error() == serialize.Refusal.TrailingData, "golden + one byte: " .. tostring(rs:error()))

  local last = #data
  local padded = data:sub(1, last - 1) .. string.char(data:byte(last) | 0x80)
  local rs2 = select(1, C.readAll(padded, steps, tree))
  check(rs2:error() == serialize.Refusal.NonzeroPadding, "golden with a padding bit: " .. tostring(rs2:error()))
end
