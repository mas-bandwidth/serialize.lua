-- fuzz/driver.lua: the Lua half of the differential. Reads a batch file given
-- as arg[1] (the path) and writes, for each program, one line to stdout:
--   HEX <lowercase hex bytes of the written packet>
-- A program is a sequence of lines:
--   BEG <capacity>   start a write program; capacity is the buffer in bytes (mult of 8)
--   <op> <args...>   one serialize operation (see the dispatch below)
--   FLUSH             flush the writer and print the HEX line
--   END               end the program
-- The ops are deliberately chosen so values are integers or hex strings, avoiding
-- float-vs-integer ambiguity on the boundary. The writer is strict: a value out of
-- range latches, and later ops write nothing, exactly as serialize.go behaves, so the
-- bytes are the same as the Go side's even when a program latches an error.
package.path = "./src/?.lua"

local serialize = require("serialize")
local WriteStream = serialize.WriteStream

local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function fromhex(h)
  if h == "." then return "" end
  return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

local function udiv(a, b)
  -- unsigned division helper for 64-bit bit patterns
  if a >= 0 then
    return math.floor(a / b)
  end
  return math.floor((a - (b - 1)) / b)
end

local s
local function op_bits(args)
  local v, w = tonumber(args[1]), tonumber(args[2])
  return s:serializeBits({ value = v }, w)
end
local function op_bits64(args)
  local v, w = tonumber(args[1]), tonumber(args[2])
  return s:serializeBits64({ value = v }, w)
end
local function op_bool(args)
  local v = tonumber(args[1])
  return s:serializeBool({ value = v == 1 })
end
local function op_u8(args) return s:serializeUint8({ value = tonumber(args[1]) }) end
local function op_u16(args) return s:serializeUint16({ value = tonumber(args[1]) }) end
local function op_u32(args) return s:serializeUint32({ value = tonumber(args[1]) }) end
local function op_u64(args) return s:serializeUint64({ value = tonumber(args[1]) }) end
local function op_int(args)
  local v, mn, mx = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
  return s:serializeInt({ value = v }, mn, mx)
end
local function op_int64(args)
  local v, mn, mx = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
  return s:serializeInt64({ value = v }, mn, mx)
end
local function op_float(args)
  local bits = tonumber(args[1])
  local v = string.unpack("f", string.pack("<I4", bits))
  return s:serializeFloat({ value = v })
end
local function op_double(args)
  local hi, lo = tonumber(args[1]), tonumber(args[2])
  local v = string.unpack("d", string.pack("<I4I4", lo, hi))
  return s:serializeDouble({ value = v })
end
local function op_cfloat(args)
  local v, mn, mx, res = tonumber(args[1]), tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
  return s:serializeCompressedFloat({ value = v }, mn, mx, res)
end
local function op_bytes(args)
  return s:serializeBytes({ value = fromhex(args[1]) }, tonumber(args[2]))
end
local function op_str(args)
  return s:serializeString({ value = fromhex(args[1]) }, tonumber(args[2]))
end
local function op_wstr(args)
  local h = args[1]
  return s:serializeWideString({ value = fromhex(h) }, tonumber(args[2]))
end
local function op_align()
  return s:serializeAlign()
end
local function op_intrel(args)
  local prev, cur = tonumber(args[1]), tonumber(args[2])
  return s:serializeIntRelative(prev, { value = cur })
end
local function op_fixed64(args)
  local v, ib, fb, mn, mx = tonumber(args[1]), tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
  return s:serializeFixed64({ value = v }, ib, fb, mn, mx)
end

local OPS = {
  bits = op_bits, bits64 = op_bits64, bool = op_bool,
  u8 = op_u8, u16 = op_u16, u32 = op_u32, u64 = op_u64,
  int = op_int, int64 = op_int64,
  float = op_float, double = op_double, cfloat = op_cfloat,
  bytes = op_bytes, str = op_str, wstr = op_wstr,
  align = op_align, intrel = op_intrel, fixed64 = op_fixed64,
}

local f = assert(io.open(arg[1], "rb"))
local blk = f:read("*a")
f:close()

for line in (blk .. "\n"):gmatch("([^\r\n]+)\r?\n") do
  if line == "" then
    -- skip
  elseif line == "END" then
    s = nil
  elseif line == "FLUSH" then
    s:flush()
    io.write("HEX " .. hex(s:data()) .. "\n")
  else
    local first, rest = line:match("^(%S+)%s*(.*)$")
    if first == "BEG" then
      s = WriteStream.new(tonumber(rest))
    else
      local op = OPS[first]
      if op == nil then
        error("driver: unknown op " .. tostring(first))
      end
      local args = {}
      for a in (rest .. " "):gmatch("(%S+)%s*") do
        args[#args + 1] = a
      end
      op(args)
    end
  end
end
