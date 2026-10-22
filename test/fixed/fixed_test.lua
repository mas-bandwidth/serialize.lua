-- test/fixed: the fixed point Q format arm (DESIGN.md (h)).
-- Run by `make test T=fixed` from the repository root. Pins: every record of
-- conformance/fixed.txt (raw value, bits consumed, canonical bytes, refusal with
-- the destination untouched and the stream terminal), the per-file record count
-- equal to the file's count, serialize.go's panicFixedParams and panicFixedBounds
-- misuse rules, and the byte identity with the int64 path for three Q formats.

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
-- Run one fixed vector.
--------------------------------------------------------------------------------

local function runRecord(rec)
  local ib = tonumber(rec.params.integer_bits)
  local fb = tonumber(rec.params.fraction_bits)
  local total = ib + fb
  local mn = parseToken(rec.params.min).lo
  local mx = parseToken(rec.params.max).lo
  local data = hexToBinary(rec.bytes)

  local method = function(s, h, a, b, c, d) return s:serializeFixed(h, a, b, c, d) end
  local sentinel
  if total <= 64 then
    sentinel = 0x1122334455667788
  else
    sentinel = { lo = 0x1122334455667788, hi = 0x99aabbccddeeff00 }
  end

  local refused = (rec.expect == "refused")
  local expected
  if not refused then
    local p = parseToken(rec.expect.value)
    if total <= 64 then expected = p.lo else expected = p end
  end

  -- READ
  local rs = serialize.ReadStream.new(data)
  local holder = { value = sentinel }
  if refused then
    local ok = method(rs, holder, ib, fb, mn, mx)
    check(ok == false, "serializeFixed refused read must fail: " .. rec.name)
    check(valueEquals(holder.value, sentinel), "serializeFixed refused read must leave destination untouched: " .. rec.name)
    local before = rs:bitsProcessed()
    local h2 = { value = sentinel }
    check(method(rs, h2, ib, fb, mn, mx) == false and valueEquals(h2.value, sentinel)
      and rs:bitsProcessed() == before,
      "serializeFixed refused read must leave the stream terminal: " .. rec.name)
  else
    check(method(rs, holder, ib, fb, mn, mx), "serializeFixed accepted read failed: " .. rec.name
      .. " err=" .. tostring(rs:error()))
    check(valueEquals(holder.value, expected), "serializeFixed wrong value in " .. rec.name)
    check(rs:bitsProcessed() == rec.consumed, "serializeFixed wrong consumed in " .. rec.name)
  end

  -- WRITE canonical
  if rec.writer then
    local numBits = rec.consumed or 0
    local bytes = (numBits + 7) // 8
    local cap = ((bytes + 7) // 8) * 8
    local ws = serialize.WriteStream.new(cap)
    check(method(ws, { value = expected }, ib, fb, mn, mx), "serializeFixed canonical write failed: " .. rec.name
      .. " err=" .. tostring(ws:error()))
    ws:flush()
    check(ws:data() == data, "serializeFixed canonical bytes mismatch: " .. rec.name)
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

--------------------------------------------------------------------------------
-- Misuse: serialize.go's panicFixedParams and panicFixedBounds (stream.go).
--------------------------------------------------------------------------------

local function expectPanic(fn, msg)
  local ok = pcall(fn)
  check(not ok, "expected a raise: " .. msg)
end

local function expectFixedPanic(fn, msg)
  local ok, err = pcall(fn)
  check(not ok, "expected a raise: " .. msg)
  check(tostring(err):find("serialize: fixed point", 1, true) ~= nil, "wrong panic for: " .. msg)
end

--------------------------------------------------------------------------------
-- Byte identity with the int64 path for three Q formats (STANDARD.md, fixed).
--------------------------------------------------------------------------------

local function byteIdentity(ib, fb, min, max, raw)
  local rawMin = min << fb
  local rawMax = max << fb
  local wsFixed = serialize.WriteStream.new(16)
  local wsInt = serialize.WriteStream.new(16)
  check(wsFixed:serializeFixed({ value = raw }, ib, fb, min, max), "fixed write failed")
  check(wsInt:serializeInt64({ value = raw }, rawMin, rawMax), "int64 write failed")
  wsFixed:flush()
  wsInt:flush()
  check(wsFixed:data() == wsInt:data(),
    "byte identity mismatch for Q" .. ib .. "." .. fb .. " raw=" .. tostring(raw))
end

function TestSerializeFixed()
  -- loading the fixed family creates no global (DESIGN.md (f))
  local before = {}
  for k in pairs(_G) do before[k] = true end

  -- 1. the conformance corpus, record by record, with the per-file count
  runFile("conformance/fixed.txt")
  for k in pairs(_G) do
    check(before[k], "loading the fixed family created the global " .. tostring(k))
  end

  -- 2. misuse: panicFixedParams
  local ws = serialize.WriteStream.new(16)
  local h = { value = 0 }
  expectFixedPanic(function() ws:serializeFixed(h, 0, 32, 0, 100) end, "integerBits = 0")
  expectFixedPanic(function() ws:serializeFixed(h, 40, -8, 0, 100) end, "fractionBits < 0")
  expectFixedPanic(function() ws:serializeFixed(h, 8, 8, -100, -101) end, "min > max")
  expectFixedPanic(function() ws:serializeFixed(h, 40, 40, 0, 100) end, "total between 64 and 128")
  expectFixedPanic(function() ws:serializeFixed(h, 8, 8, 0.5, 100) end, "non-integer bounds")

  -- 3. misuse: panicFixedBounds
  expectFixedPanic(function() ws:serializeFixed(h, 8, 8, -200, 100) end, "min below Q8.8 signed capacity")
  expectFixedPanic(function() ws:serializeFixed(h, 8, 8, -100, 128) end, "max above Q8.8 signed capacity")
  expectFixedPanic(function() ws:serializeFixed(h, 32, 0, 0, 4294967296) end, "unsigned Q32.0 capacity")
  check(ws:error() == nil, "misuse must not latch a stream error")

  -- 4. the holder type misuse
  expectPanic(function() ws:serializeFixed({ value = {} }, 8, 8, -100, 100) end, "integer holder")
  expectPanic(function() ws:serializeFixed({ value = 0 }, 64, 64, 0, 100) end, "pair holder")

  -- 5. byte identity with the int64 path for three Q formats
  byteIdentity(8, 8, -100, 100, -832)
  byteIdentity(16, 16, -32768, 32767, 1588444911)
  byteIdentity(32, 0, 0, 7, 5)
end
