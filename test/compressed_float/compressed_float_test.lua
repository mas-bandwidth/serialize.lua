-- test/compressed_float: the compressed float (DESIGN.md (h)).
-- Run by `make test T=compressed_float` from the repository root. Pins: every
-- record of conformance/compressed_float.txt (decoded float32 bits, bits
-- consumed, refusal with the destination untouched and the stream terminal),
-- the per-file record count equal to the file's count, serialize.go's
-- TestCompressedFloatTopOfRangeClamp witnesses ([0,8388609] and [0,16777215]
-- at resolution 1, writing max, through both entry points), and
-- TestCompressedFloatValidation's misuse rules: a read of an integer above
-- maxIntegerValue, a huge delta / resolution ratio that must not overflow the
-- uint32 quantization range, and a non-finite value, which the checked writer
-- asserts on (STANDARD.md, "Non-finite inputs are non-conforming").

local serialize = require("serialize")

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local function hexToBinary(s)
  local t = {}
  for pair in s:gmatch("%x%x") do
    t[#t + 1] = string.char(tonumber(pair, 16))
  end
  return table.concat(t)
end

-- float32Bits(x): the 32-bit pattern of a double that is exactly a float32.
local function float32Bits(x)
  return select(1, string.unpack("<I4", string.pack("<f", x)))
end

--------------------------------------------------------------------------------
-- Conformance vector parsing.
--------------------------------------------------------------------------------

local function parseVectors(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("a")
  f:close()
  local records = {}
  local cur
  for line in content:gmatch("[^\n]+") do
    local stripped = line:gsub("^%s+", "")
    if stripped:sub(1, 1) ~= "#" and stripped ~= "" then
      local op = stripped:match("^operation%s+(%S+)")
      if op then
        cur = { operation = op, params = {}, bytes = "", expect = nil, consumed = nil }
        records[#records + 1] = cur
      else
        local nm = stripped:match("^name%s+(%S+)$")
        if nm then
          cur.name = nm
        else
          local pname, pval = stripped:match("^param%s+(%S+)%s*=%s*(.+)")
          if pname then
            cur.params[pname] = pval
          else
            local b = stripped:match("^bytes%s*(.*)$")
            if b ~= nil then
              cur.bytes = b
            else
              local ex = stripped:match("^expect%s+(.+)$")
              if ex then
                if ex == "refused" then
                  cur.expect = "refused"
                else
                  local bits = ex:match("^bits%s*=%s*(.+)$")
                  if bits then cur.expect = tonumber(bits) end
                end
              else
                local c = stripped:match("^consumed%s+(%d+)")
                if c then cur.consumed = tonumber(c) end
              end
            end
          end
        end
      end
    end
  end
  return records
end

local function runRecord(rec)
  local min = tonumber(rec.params.min)
  local max = tonumber(rec.params.max)
  local res = tonumber(rec.params.res)
  local data = hexToBinary(rec.bytes)

  local refused = (rec.expect == "refused")
  local expectedBits = rec.expect
  local sentinel = -12345.0

  local rs = serialize.ReadStream.new(data)
  local holder = { value = sentinel }
  if refused then
    local ok = rs:serializeCompressedFloat(holder, min, max, res)
    check(ok == false, "refused read must fail: " .. rec.name)
    check(holder.value == sentinel, "refused read must leave destination untouched: " .. rec.name)
    local before = rs:bitsProcessed()
    local h2 = { value = sentinel }
    check(rs:serializeCompressedFloat(h2, min, max, res) == false
      and h2.value == sentinel and rs:bitsProcessed() == before,
      "refused read must leave the stream terminal: " .. rec.name)
  else
    check(rs:serializeCompressedFloat(holder, min, max, res),
      "accepted read failed: " .. rec.name .. " err=" .. tostring(rs:error()))
    check(float32Bits(holder.value) == expectedBits, "wrong decoded bits in " .. rec.name
      .. string.format(": got 0x%08X want 0x%08X", float32Bits(holder.value), expectedBits))
    check(rs:bitsProcessed() == rec.consumed, "wrong consumed in " .. rec.name)
  end
end

local function runFile(path)
  local records = parseVectors(path)
  local f = assert(io.open(path, "r"))
  local opCount = 0
  for line in f:lines() do
    if line:match("^operation%s+") then opCount = opCount + 1 end
  end
  f:close()
  check(#records == opCount, path .. ": parsed " .. #records .. " records, file declares " .. opCount)
  for _, rec in ipairs(records) do
    runRecord(rec)
  end
  print(path .. ": " .. #records .. " records")
end

local function clampWitness(maxv)
  local ws = serialize.WriteStream.new(16)
  check(ws:serializeCompressedFloat({ value = maxv }, 0, maxv, 1.0),
    "clamp witness write failed, err=" .. tostring(ws:error()))
  ws:flush()
  local rs = serialize.ReadStream.new(ws:data())
  local h = {}
  check(rs:serializeCompressedFloat(h, 0, maxv, 1.0), "clamp witness read failed")
  check(h.value == maxv, "clamp witness value " .. tostring(maxv) .. " round-tripped to " .. tostring(h.value))
end

local function clampWitnessPrecomputed(maxv)
  local maxInt, bits, delta = serialize.compressedFloatParams(0, maxv, 1.0)
  local ws = serialize.WriteStream.new(16)
  check(ws:serializeCompressedFloatPrecomputed({ value = maxv }, maxInt, bits, delta, 0.0),
    "precomputed clamp witness write failed, err=" .. tostring(ws:error()))
  ws:flush()
  local rs = serialize.ReadStream.new(ws:data())
  local h = {}
  check(rs:serializeCompressedFloatPrecomputed(h, maxInt, bits, delta, 0.0),
    "precomputed clamp witness read failed")
  check(h.value == maxv, "precomputed clamp witness value " .. tostring(maxv) .. " round-tripped to " .. tostring(h.value))
end

function TestSerializeCompressedFloat()
  -- 1. the conformance corpus, record by record, with per-file count.
  runFile("conformance/compressed_float.txt")

  -- 2. serialize.go TestCompressedFloatTopOfRangeClamp: the normative integer
  -- clamp, writing max through both the derived and precomputed paths.
  clampWitness(8388609.0)
  clampWitness(16777215.0)
  clampWitnessPrecomputed(8388609.0)
  clampWitnessPrecomputed(16777215.0)

  -- 3. serialize.go TestCompressedFloatValidation's misuse rules.
  -- a malicious packet can encode integers above maxIntegerValue in the bit
  -- headroom; reads must reject them (maxIntegerValue is 1000 for [0,10] at
  -- res 0.01 -> 10 bits).
  do
    local ws = serialize.WriteStream.new(8)
    check(ws:serializeBits({ value = 1023 }, 10))
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local h = { value = -1.0 }
    check(rs:serializeCompressedFloat(h, 0, 10, 0.01) == false, "above-maxIntegerValue read must refuse")
    check(h.value == -1.0, "above-maxIntegerValue refused read must leave destination untouched")
  end

  -- huge delta / resolution ratios must not overflow the uint32 quantization range.
  do
    local ws = serialize.WriteStream.new(8)
    local written = 5000000000.0
    check(ws:serializeCompressedFloat({ value = written }, 0, 10000000000.0, 1.0))
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local h = {}
    check(rs:serializeCompressedFloat(h, 0, 10000000000.0, 1.0))
    check(math.abs(h.value - written) <= 4096.0,
      "huge ratio round trip " .. tostring(h.value) .. " too far from " .. tostring(written))
  end

  -- a non-finite value is non-conforming and the checked writer asserts
  -- (raises) on it (STANDARD.md, "Non-finite inputs are non-conforming").
  do
    local ws = serialize.WriteStream.new(8)
    local ok, err = pcall(function()
      ws:serializeCompressedFloat({ value = 0 / 0 }, 0, 10, 0.01)
    end)
    check(not ok, "writing NaN must raise, got " .. tostring(err))
  end
end
