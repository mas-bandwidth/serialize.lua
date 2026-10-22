-- test/int: the ranged integers int, int64 and int128 (DESIGN.md (h)).
-- Run by `make test T=int` from the repository root. Pins: every record of
-- conformance/int.txt, int64.txt and int128.txt (value, bits consumed, canonical
-- bytes, refusal with the destination untouched and the stream terminal), the
-- per-file record count equal to the file's count, serialize.go's TestBitsRequired,
-- TestBitsRequired64 and TestSerializeInt64FullRange edge cases, and the writer's
-- ValueOutOfRange latch for a value one past each bound.

local serialize = require("serialize")

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

--------------------------------------------------------------------------------
-- Parsing: decimal and hex integers up to 128 bits.
--------------------------------------------------------------------------------

local function parseBigUnsigned(s)
  local limbs = { 0 }
  for i = 1, #s do
    local d = s:byte(i) - 48
    local carry = d
    for j = 1, #limbs do
      local t = limbs[j] * 10 + carry
      limbs[j] = t & 0xffffffff
      carry = t >> 32
    end
    while carry ~= 0 do
      limbs[#limbs + 1] = carry & 0xffffffff
      carry = carry >> 32
    end
  end
  return limbs
end

local function limbsTo128(limbs)
  local function limb(i) return limbs[i] or 0 end
  local lo = limb(1) | (limb(2) << 32)
  local hi = limb(3) | (limb(4) << 32)
  return lo, hi
end

local function parseHex128(s)
  local h = s
  if h:sub(1, 2) == "0x" then h = h:sub(3) end
  local lo, hi = 0, 0
  local shift = 0
  for i = #h, 1, -1 do
    local ch = h:byte(i)
    local v
    if ch >= 48 and ch <= 57 then v = ch - 48
    elseif ch >= 97 and ch <= 102 then v = ch - 87
    else v = ch - 55 end
    if shift < 64 then
      lo = lo | (v << shift)
    else
      hi = hi | (v << (shift - 64))
    end
    shift = shift + 4
  end
  return lo, hi
end

local function parseToken(token)
  local t = token
  local neg = false
  if t:sub(1, 1) == "-" then neg = true; t = t:sub(2) end
  local lo, hi
  if t:sub(1, 2) == "0x" then
    lo, hi = parseHex128(t)
  else
    lo, hi = limbsTo128(parseBigUnsigned(t))
  end
  if neg then
    lo = (~lo) & 0xffffffffffffffff
    hi = (~hi) & 0xffffffffffffffff
    lo = lo + 1
    if (lo & 0xffffffffffffffff) == 0 then hi = hi + 1 end
    lo = lo & 0xffffffffffffffff
    hi = hi & 0xffffffffffffffff
  end
  return { lo = lo, hi = hi }
end

local function valueEquals(a, b)
  if type(a) == "number" and type(b) == "number" then return a == b end
  if type(a) == "table" and type(b) == "table" then
    return a.lo == b.lo and a.hi == b.hi
  end
  return false
end

local function hexToBinary(s)
  local t = {}
  for pair in s:gmatch("%x%x") do
    t[#t + 1] = string.char(tonumber(pair, 16))
  end
  return table.concat(t)
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
        cur = { operation = op, params = {}, bytes = "", expect = nil, consumed = nil, writer = false }
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
                  local v = ex:match("^value%s*=%s*(.+)$")
                  if v then cur.expect = { value = v } end
                end
              else
                local c = stripped:match("^consumed%s+(%d+)")
                if c then cur.consumed = tonumber(c) end
                if stripped == "writer canonical" then cur.writer = true end
              end
            end
          end
        end
      end
    end
  end
  return records
end

--------------------------------------------------------------------------------
-- Run one vector on one operation.
--------------------------------------------------------------------------------

local function runRecord(op, rec)
  local minP = parseToken(rec.params.min)
  local maxP = parseToken(rec.params.max)
  local data = hexToBinary(rec.bytes)

  local method, mn, mx, sentinel
  if op == "int" then
    method = function(s, h, mn0, mx0) return s:serializeInt(h, mn0, mx0) end
    mn, mx = minP.lo, maxP.lo
    sentinel = 0x11223344
  elseif op == "int64" then
    method = function(s, h, mn0, mx0) return s:serializeInt64(h, mn0, mx0) end
    mn, mx = minP.lo, maxP.lo
    sentinel = 0x1122334455667788
  else
    method = function(s, h, mn0, mx0) return s:serializeInt128(h, mn0, mx0) end
    mn, mx = minP, maxP
    sentinel = { lo = 0x1122334455667788, hi = 0x99aabbccddeeff00 }
  end

  local refused = (rec.expect == "refused")
  local expected
  if not refused then
    local p = parseToken(rec.expect.value)
    if op == "int128" then expected = p else expected = p.lo end
  end

  -- READ
  local rs = serialize.ReadStream.new(data)
  local holder = { value = sentinel }
  if refused then
    local ok = method(rs, holder, mn, mx)
    check(ok == false, op .. " refused read must fail: " .. rec.name)
    check(valueEquals(holder.value, sentinel), op .. " refused read must leave destination untouched: " .. rec.name)
    local before = rs:bitsProcessed()
    local h2 = { value = sentinel }
    check(method(rs, h2, mn, mx) == false and valueEquals(h2.value, sentinel)
      and rs:bitsProcessed() == before,
      op .. " refused read must leave the stream terminal: " .. rec.name)
  else
    check(method(rs, holder, mn, mx), op .. " accepted read failed: " .. rec.name
      .. " err=" .. tostring(rs:error()))
    check(valueEquals(holder.value, expected), op .. " wrong value in " .. rec.name)
    check(rs:bitsProcessed() == rec.consumed, op .. " wrong consumed in " .. rec.name)
  end

  -- WRITE canonical
  if rec.writer then
    local numBits = rec.consumed or 0
    local bytes = (numBits + 7) // 8
    local cap = ((bytes + 7) // 8) * 8
    local ws = serialize.WriteStream.new(cap)
    check(method(ws, { value = expected }, mn, mx), op .. " canonical write failed: " .. rec.name
      .. " err=" .. tostring(ws:error()))
    ws:flush()
    check(ws:data() == data, op .. " canonical bytes mismatch: " .. rec.name)
  end
end

local function runFile(op, path)
  local records = parseVectors(path)
  local f = assert(io.open(path, "r"))
  local opCount = 0
  for line in f:lines() do
    if line:match("^operation%s+") then opCount = opCount + 1 end
  end
  f:close()
  check(#records == opCount, path .. ": parsed " .. #records .. " records, file declares " .. opCount)
  for _, rec in ipairs(records) do
    runRecord(op, rec)
  end
  print(path .. ": " .. #records .. " records")
end

--------------------------------------------------------------------------------
-- Reference bit-length helpers (for the uint64-only edge cases).
--------------------------------------------------------------------------------

local function bitlen(n)
  local c = 0
  while n > 0 do
    n = n >> 1
    c = c + 1
  end
  return c
end

local function refBitsReq64(min, max)
  if min == max then return 0 end
  if max - min < 0 then return 64 end
  return bitlen(max - min)
end

function TestSerializeInt()
  -- loading the int families creates no global (DESIGN.md (f)): snapshot before
  -- the first call, which is what makes the lazy loader require them
  local before = {}
  for k in pairs(_G) do before[k] = true end

  -- 1. the conformance corpus, record by record, with per-file counts
  runFile("int", "conformance/int.txt")
  runFile("int64", "conformance/int64.txt")
  runFile("int128", "conformance/int128.txt")
  for k in pairs(_G) do
    check(before[k], "loading the int families created the global " .. tostring(k))
  end

  -- 2. serialize.go TestBitsRequired / TestBitsRequired64 edge cases, through the
  -- actual serialized width (a measure of the shipped range-width logic)
  local cases32 = {
    { 0, 0, 0 }, { 0, 1, 1 }, { 0, 2, 2 }, { 0, 3, 2 },
    { 0, 4, 3 }, { 0, 5, 3 }, { 0, 6, 3 }, { 0, 7, 3 },
    { 0, 8, 4 }, { 0, 255, 8 }, { 0, 65535, 16 }, { 0, 4294967295, 32 },
  }
  for _, c in ipairs(cases32) do
    local ws = serialize.WriteStream.new(16)
    check(ws:serializeInt64({ value = c[1] }, c[1], c[2]) and ws:bitsProcessed() == c[3],
      "BitsRequired64 case [" .. c[1] .. "," .. c[2] .. "] width " .. c[3])
  end

  local cases64 = {
    { 0, 0, 0 }, { 0, 1, 1 }, { 0, 255, 8 }, { 0, 4294967295, 32 },
    { 0, 4294967296, 33 }, { 0, 1 << 40, 41 },
    { math.mininteger, math.maxinteger, 64 },
    { -5000000000, 5000000000, 34 },
  }
  for _, c in ipairs(cases64) do
    local ws = serialize.WriteStream.new(16)
    check(ws:serializeInt64({ value = c[1] }, c[1], c[2]) and ws:bitsProcessed() == c[3],
      "BitsRequired64 case [" .. c[1] .. "," .. c[2] .. "] width " .. c[3])
  end
  -- the one case the signed int64 stream cannot express: the full uint64 span
  check(refBitsReq64(0, 0xffffffffffffffff) == 64, "BitsRequired64(0,0xFFFFFFFFFFFFFFFF) = 64")

  -- 3. serialize.go TestSerializeInt64FullRange
  do
    local min64, max64 = math.mininteger, math.maxinteger
    for _, v in ipairs({ min64, min64 + 1, -1, 0, 1, max64 - 1, max64 }) do
      local ws = serialize.WriteStream.new(16)
      check(ws:serializeInt64({ value = v }, min64, max64))
      ws:flush()
      local rs = serialize.ReadStream.new(ws:data())
      local h = {}
      check(rs:serializeInt64(h, min64, max64), "full-range read failed")
      check(h.value == v, "full-range round trip mismatch: " .. tostring(v))
    end
    local mn, mx = -5000000000, 5000000000
    for _, v in ipairs({ mn, mn + 1, -1, 0, 1, 4123456789, mx - 1, mx }) do
      local ws = serialize.WriteStream.new(16)
      check(ws:serializeInt64({ value = v }, mn, mx))
      ws:flush()
      local rs = serialize.ReadStream.new(ws:data())
      local h = {}
      check(rs:serializeInt64(h, mn, mx), "two-dword read failed")
      check(h.value == v, "two-dword round trip mismatch: " .. tostring(v))
    end
    local ws = serialize.WriteStream.new(8)
    check(ws:serializeInt64({ value = 55 }, -100, 100))
    ws:flush()
    check(ws:bitsProcessed() == 8, "BitsRequired64(-100,100) = 8")
    local rs = serialize.ReadStream.new(ws:data())
    local h = {}
    check(rs:serializeInt64(h, -100, 100) and h.value == 55, "small-range round trip")
  end

  -- 4. the writer's ValueOutOfRange latch for a value one past each bound
  do
    check(serialize.WriteStream.new(16):serializeInt({ value = 11 }, 0, 10) == false, "int max+1 must latch")
    local w1 = serialize.WriteStream.new(16)
    check(w1:serializeInt({ value = 11 }, 0, 10) == false
      and w1:error() == serialize.SerializeError.ValueOutOfRange, "int max+1 latches ValueOutOfRange")
    local w2 = serialize.WriteStream.new(16)
    check(w2:serializeInt({ value = -1 }, 0, 10) == false
      and w2:error() == serialize.SerializeError.ValueOutOfRange, "int min-1 latches ValueOutOfRange")

    local w3 = serialize.WriteStream.new(16)
    check(w3:serializeInt64({ value = 10000000001 }, -10000000000, 10000000000) == false
      and w3:error() == serialize.SerializeError.ValueOutOfRange, "int64 max+1 latches ValueOutOfRange")
    local w4 = serialize.WriteStream.new(16)
    check(w4:serializeInt64({ value = -10000000001 }, -10000000000, 10000000000) == false
      and w4:error() == serialize.SerializeError.ValueOutOfRange, "int64 min-1 latches ValueOutOfRange")

    local m0 = { lo = 0, hi = 0 }
    local m10 = { lo = 10, hi = 0 }
    local w5 = serialize.WriteStream.new(16)
    check(w5:serializeInt128({ value = { lo = 11, hi = 0 } }, m0, m10) == false
      and w5:error() == serialize.SerializeError.ValueOutOfRange, "int128 max+1 latches ValueOutOfRange")
    local w6 = serialize.WriteStream.new(16)
    check(w6:serializeInt128({ value = { lo = 0xffffffffffffffff, hi = 0xffffffffffffffff } }, m0, m10) == false
      and w6:error() == serialize.SerializeError.ValueOutOfRange, "int128 min-1 latches ValueOutOfRange")
  end
end
