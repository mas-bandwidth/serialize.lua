-- fuzz/driver.lua: the Lua half of the differential. Reads a batch file given
-- as arg[1] (the path) and writes one result line per program to stdout:
--   HEX <lowercase hex bytes>       a written packet
--   READ <n> <reason> <token>...    a read: n ops accepted, the first refusal's
--                                   reason (STANDARD.md spelling, "ok" if none),
--                                   then the accepted ops' values
-- A program is a sequence of lines:
--   W <capacity>      start a write program; capacity in bytes (multiple of 8)
--   R <hex>           start a read program over those bytes
--   <op> <args...>    one serialize operation (see the dispatch below)
--   END               finish: flush a write, or report a read
-- Values cross the process boundary as integers or hex strings, never as
-- float-vs-integer ambiguity. The writer is strict, and a read latches the
-- first refusal and reports how many ops decoded before it and its reason, so
-- the Go side can compare accept/refuse, the reason and every decoded value.
package.path = "./src/?.lua"

local serialize = require("serialize")
local floatmod = require("serialize_float")
local WriteStream = serialize.WriteStream
local ReadStream = serialize.ReadStream

local fround = floatmod.fround
local float32Bits = floatmod.float32Bits
local float32FromBits = floatmod.float32FromBits

local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function fromhex(h)
  if h == "." then return "" end
  return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

local function H(s) return tonumber(s, 16) end

local s
local function op_bits(args)
  local h = { value = H(args[1]) }
  return s:serializeBits(h, tonumber(args[2])), h
end
local function op_bits64(args)
  local h = { value = H(args[1]) }
  return s:serializeBits64(h, tonumber(args[2])), h
end
local function op_bool(args)
  local h = { value = tonumber(args[1]) == 1 }
  return s:serializeBool(h), h
end
local function op_u8(args)
  local h = { value = tonumber(args[1]) }
  return s:serializeUint8(h), h
end
local function op_u16(args)
  local h = { value = tonumber(args[1]) }
  return s:serializeUint16(h), h
end
local function op_u32(args)
  local h = { value = tonumber(args[1]) }
  return s:serializeUint32(h), h
end
local function op_u64(args)
  local h = { value = H(args[1]) }
  return s:serializeUint64(h), h
end
local function op_int(args)
  local h = { value = tonumber(args[1]) }
  return s:serializeInt(h, tonumber(args[2]), tonumber(args[3])), h
end
local function op_int64(args)
  local h = { value = H(args[1]) }
  return s:serializeInt64(h, H(args[2]), H(args[3])), h
end
local function op_u128(args)
  local h = { value = { lo = H(args[1]), hi = H(args[2]) } }
  return s:serializeUint128(h), h
end
local function op_i128(args)
  local mn = { lo = H(args[1]), hi = H(args[2]) }
  local mx = { lo = H(args[3]), hi = H(args[4]) }
  local h = { value = { lo = H(args[5]), hi = H(args[6]) } }
  return s:serializeInt128(h, mn, mx), h
end
local function op_fixed64(args)
  local h = { value = tonumber(args[1]) }
  return s:serializeFixed(h, tonumber(args[2]), tonumber(args[3]),
    tonumber(args[4]), tonumber(args[5])), h
end
local function op_fixed128(args)
  local h = { value = { lo = H(args[1]), hi = H(args[2]) } }
  return s:serializeFixed(h, tonumber(args[3]), tonumber(args[4]),
    tonumber(args[5]), tonumber(args[6])), h
end
local function op_intrel(args)
  local h = { value = tonumber(args[2]) }
  return s:serializeIntRelative(tonumber(args[1]), h), h
end
local function op_float(args)
  local h = { value = float32FromBits(H(args[1])) }
  return s:serializeFloat(h), h
end
local function op_double(args)
  local bits = H(args[1])
  local h = { value = string.unpack("<d", string.pack("<i8", bits)) }
  return s:serializeDouble(h), h
end
local function op_cfloat(args)
  local h = { value = float32FromBits(H(args[1])) }
  return s:serializeCompressedFloat(h, float32FromBits(H(args[2])),
    float32FromBits(H(args[3])), float32FromBits(H(args[4]))), h
end
local function op_bytes(args)
  local h = { value = fromhex(args[1]) }
  return s:serializeBytes(h, tonumber(args[2])), h
end
local function op_str(args)
  local h = { value = fromhex(args[1]) }
  return s:serializeString(h, tonumber(args[2])), h
end
local function op_align()
  return s:serializeAlign(), nil
end
local function op_end()
  return s:serializeEnd(), nil
end
local function op_object(args)
  local obj = { u = tonumber(args[1]), b = tonumber(args[2]) == 1 }
  function obj:serialize(stream)
    local reading = stream:isReading()
    local uh = { value = reading and 0 or self.u }
    if not stream:serializeUint32(uh) then return false end
    self.u = uh.value
    local bh = { value = reading and false or self.b }
    if not stream:serializeBool(bh) then return false end
    self.b = bh.value
    return true
  end
  return s:serializeObject(obj), obj
end

local OPS = {
  bits = op_bits, bits64 = op_bits64, bool = op_bool,
  u8 = op_u8, u16 = op_u16, u32 = op_u32, u64 = op_u64,
  int = op_int, int64 = op_int64, u128 = op_u128, i128 = op_i128,
  fixed64 = op_fixed64, fixed128 = op_fixed128,
  float = op_float, double = op_double, cfloat = op_cfloat,
  bytes = op_bytes, str = op_str,
  align = op_align, ["end"] = op_end, intrel = op_intrel, object = op_object,
}

local function token(kind, v)
  if kind == "bool" then
    return v and "1" or "0"
  elseif kind == "float" or kind == "cfloat" then
    return string.format("%08x", float32Bits(v))
  elseif kind == "double" then
    return string.format("%016x", string.unpack("<i8", string.pack("<d", v)))
  elseif kind == "bytes" or kind == "str" then
    local h = hex(v)
    if h == "" then return "." end
    return h
  elseif kind == "align" then
    return "-"
  elseif kind == "u128" or kind == "i128" or kind == "fixed128" then
    return string.format("%d,%d", v.lo, v.hi)
  elseif kind == "object" then
    return string.format("%d,%d", v.u, v.b and 1 or 0)
  end
  return string.format("%d", v)
end

local mode, ops, accept
local function beginRead(h)
  s = ReadStream.new(fromhex(h))
  mode = "read"
  ops, accept = {}, 0
end

local f = assert(io.open(arg[1], "rb"))
local blk = f:read("*a")
f:close()

for line in (blk .. "\n"):gmatch("([^\r\n]+)\r?\n") do
  if line == "" then
    -- skip
  elseif line == "END" then
    if mode == "write" then
      s:flush()
      io.write("HEX " .. hex(s:data()) .. "\n")
    else
      local parts = { "READ", string.format("%d", accept), s:error() or "ok" }
      for _, t in ipairs(ops) do parts[#parts + 1] = t end
      io.write(table.concat(parts, " ") .. "\n")
    end
    s = nil
  else
    local first, rest = line:match("^(%S+)%s*(.*)$")
    if first == "W" then
      s = WriteStream.new(tonumber(rest))
      mode = "write"
    elseif first == "R" then
      beginRead(rest)
    else
      local op = OPS[first]
      if op == nil then
        error("driver: unknown op " .. tostring(first))
      end
      local args = {}
      for a in (rest .. " "):gmatch("(%S+)%s*") do
        args[#args + 1] = a
      end
      if mode == "read-failed" or (mode == "read" and s:error() ~= nil) then
        -- terminal stream: later ops are no-ops, report the refusal index
      else
        local ok, holder = op(args)
        if mode == "read" then
          if ok then
            accept = accept + 1
            if holder ~= nil then
              local val = holder.value
              if first == "object" then val = holder end
              ops[#ops + 1] = token(first, val)
            else
              ops[#ops + 1] = "-"
            end
          else
            mode = "read-failed"
          end
        end
      end
    end
  end
end
