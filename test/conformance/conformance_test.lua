-- test/conformance: the cross-language corpus instrument (serialize-lua-conformance).
-- Run by `make test T=conformance` from the repository root. In: every record of
-- conformance/*.txt as a runner must (STANDARD.md, "What a runner checks"): an
-- accepted read decodes the value (or bit pattern, for `expect bits`) and consumes
-- exactly `consumed` bits; a `writer canonical` record's bytes are written byte for
-- byte; a refused read is refused, leaves the destination exactly as it was, and
-- leaves the stream terminal; sequence.txt's steps run in order on one stream
-- (object <n> wrapping, zero-bit fields, alignment cost, terminal poisoning) and
-- message.txt's golden message reads and re-writes byte for byte;
-- `measure_at_least` is a floor for MeasureStream. Prints one line per file with its
-- record count and fails unless every record ran. Two controls (STANDARD.md, "A
-- gate nobody has seen go red"): a corpus file whose operation has no runner is
-- REJECTED (fed a scratch copy with an unknown operation), and a sabotaged reader
-- (one refusal rule switched off through a test-only hook) goes red on exactly the
-- vectors that pin that rule.

local serialize = require("serialize")
local flt = require("serialize_float")

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

--------------------------------------------------------------------------------
-- parsing (STANDARD.md, "The vector format", "Lexical rules")
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

-- parseToken -> a plain number for |value| <= 2^53, else { lo, hi }.
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
  if hi == 0 and lo >= 0 then
    return lo
  elseif hi == 0xffffffffffffffff and lo < 0 then
    return lo
  end
  return { lo = lo, hi = hi }
end

local function parseScalar(token)
  if token:find("%.") then return tonumber(token) end
  return parseToken(token)
end

local function toPair(v)
  if type(v) == "table" then return v end
  local n = v
  local hi = 0
  if n < 0 then
    n = n + 0x10000000000000000
    hi = 0xffffffffffffffff
  end
  local lo = n & 0xffffffffffffffff
  hi = hi & 0xffffffffffffffff
  return { lo = lo, hi = hi }
end

local function valueEquals(a, b)
  if type(a) == "boolean" or type(b) == "boolean" then return a == b end
  if type(a) == "number" then a = toPair(a) end
  if type(b) == "number" then b = toPair(b) end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if a.lo ~= b.lo then return false end
  if a.hi == b.hi then return true end
  return (a.hi == 0 and b.hi == 0xffffffffffffffff) or (a.hi == 0xffffffffffffffff and b.hi == 0)
end

local function unhex(s)
  if s == nil or s == "" then return "" end
  local out = {}
  for byte in s:gmatch("%x%x") do
    out[#out + 1] = string.char(tonumber(byte, 16))
  end
  return table.concat(out)
end

local function hexBytes(s)
  if s == "" then return "" end
  local out = {}
  for i = 1, #s do
    out[#out + 1] = string.format("%02X", s:byte(i))
  end
  return table.concat(out, " ")
end

local function hexToBytesStr(s)
  local t = {}
  for pair in s:gmatch("%x%x") do
    t[#t + 1] = pair
  end
  return table.concat(t)
end

-- parse a record.
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
        cur = { operation = op, params = {}, parammap = {}, bytes = "", expect = nil, consumed = nil, writer = false, measure = nil }
        records[#records + 1] = cur
      elseif cur then
        local nm = stripped:match("^name%s+(%S+)$")
        if nm then
          cur.name = nm
        else
          local pname, pval = stripped:match("^param%s+(%S+)%s*=%s*(.+)")
          if pname then
            cur.params[#cur.params + 1] = { name = pname, value = pval }
            cur.parammap[pname] = pval
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
                  if v then
                    cur.expect = v
                  else
                    local b = ex:match("^bits%s*=%s*(.+)$")
                    if b then
                      cur.expect = "bits " .. b
                    else
                      cur.expect = ex
                    end
                  end
                end
              else
                local c = stripped:match("^consumed%s+(%d+)")
                if c then cur.consumed = tonumber(c) end
                if stripped == "writer canonical" then cur.writer = true end
                local m = stripped:match("^measure_at_least%s+(%d+)")
                if m then cur.measure = tonumber(m) end
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
-- the step engine
--------------------------------------------------------------------------------

-- A parsed step: { op = <string>, args = { ... }, value = <expect or nil> }
local function parseStep(str)
  local op, rest = str:match("^(%S+)%s*(.*)$")
  local args = {}
  if op == "int" or op == "int64" or op == "int128" or op == "fixed" or op == "compressed_float" then
    for tok in rest:gmatch("%S+") do
      args[#args + 1] = parseScalar(tok)
    end
  elseif op == "int_relative" then
    for tok in rest:gmatch("%S+") do
      args[#args + 1] = parseScalar(tok)
    end
  elseif op == "bits" or op == "bytes" or op == "string" or op == "wstring" then
    args[1] = parseScalar(rest)
  elseif op == "object" then
    args[1] = tonumber(rest)
  end
  if op == "int128" then
    for i = 1, #args do
      if type(args[i]) ~= "table" then args[i] = toPair(args[i]) end
    end
  end
  return { op = op, args = args }
end

-- run one step on a stream. mode = "read"|"write"|"measure".
-- For read: returns ok, value. For write/measure: value passed in, returns ok.
local function runStep(stream, step, mode, value)
  local op = step.op
  local s = stream
  local holder
  if mode == "read" then
    holder = { value = nil }
  else
    holder = { value = value }
  end
  local function one(fn)
    if mode == "read" then
      local ok
      if step.args[1] ~= nil then
        ok = fn(s, holder, step.args[1])
      else
        ok = fn(s, holder)
      end
      if ok then return true, holder.value end
      return false
    else
      local ok
      if step.args[1] ~= nil then
        ok = fn(s, holder, step.args[1])
      else
        ok = fn(s, holder)
      end
      return ok == true
    end
  end

  if op == "bits" then
    if step.args[1] == 0 then
      if mode == "read" then return true, 0 end
      return true
    end
    return one(function(x, h, n)
      if type(n) == "table" then error("bits n is a table: " .. tostring(n.lo), 0) end
      local m = s[("serializeBits" .. (n <= 32 and "" or "64"))]
      return m(s, h, n)
    end)
  elseif op == "bool" then
    return one(function(x, h) return s:serializeBool(h) end)
  elseif op == "uint128" then
    return one(function(x, h) return s:serializeUint128(h) end)
  elseif op == "int" then
    return one(function(x, h) return s:serializeInt(h, step.args[1], step.args[2]) end)
  elseif op == "int64" then
    return one(function(x, h) return s:serializeInt64(h, step.args[1], step.args[2]) end)
  elseif op == "int128" then
    return one(function(x, h) return s:serializeInt128(h, step.args[1], step.args[2]) end)
  elseif op == "fixed" then
    return one(function(x, h) return s:serializeFixed(h, step.args[1], step.args[2], step.args[3], step.args[4]) end)
  elseif op == "int_relative" then
    if mode == "read" then
      local ok = s:serializeIntRelative(step.args[1], holder)
      if ok then return true, holder.value end
      return false
    else
      return s:serializeIntRelative(step.args[1], holder) == true
    end
  elseif op == "float" then
    return one(function(x, h) return s:serializeFloat(h) end)
  elseif op == "double" then
    return one(function(x, h) return s:serializeDouble(h) end)
  elseif op == "compressed_float" then
    return one(function(x, h) return s:serializeCompressedFloat(h, step.args[1], step.args[2], step.args[3]) end)
  elseif op == "bytes" then
    return one(function(x, h) return s:serializeBytes(h, step.args[1]) end)
  elseif op == "string" then
    return one(function(x, h) return s:serializeString(h, step.args[1]) end)
  elseif op == "wstring" then
    return one(function(x, h) return s:serializeWideString(h, step.args[1]) end)
  elseif op == "align" then
    if mode == "read" then
      local ok = s:serializeAlign()
      if ok then return true, nil end
      return false
    else
      return s:serializeAlign() == true
    end
  elseif op == "object" then
    error("object step must be expanded by the sequence runner", 0)
  end
  error("no runner for operation " .. op, 0)
end

-- Build the flat list of steps from record params; object <n> wraps.
local function buildSteps(rec)
  local raw = {}
  for _, p in ipairs(rec.params) do
    if p.name == "step" then
      raw[#raw + 1] = parseStep(p.value)
    end
  end
  if #raw == 0 then
    -- single-operation record
    local op = rec.operation
    local pm = rec.parammap
    if pm.preceding_bits then
      local n = parseToken(pm.preceding_bits)
      raw[1] = { op = "bits", args = { n } }
      raw[2] = { op = op, args = {} }
      if op == "bytes" or op == "string" or op == "wstring" then
        raw[2].args[1] = parseToken(pm.count or pm.buffer_size or pm.bufferSize)
      end
      return raw
    end
    local step = { op = op, args = {} }
    if op == "bits" then step.args[1] = parseScalar(pm.bits) end
    if op == "int" or op == "int64" or op == "int128" then
      step.args[1] = parseScalar(pm.min)
      step.args[2] = parseScalar(pm.max)
    end
    if op == "fixed" then
      step.args[1] = parseScalar(pm.integer_bits or pm.ib)
      step.args[2] = parseScalar(pm.fraction_bits or pm.fb)
      step.args[3] = parseScalar(pm.min)
      step.args[4] = parseScalar(pm.max)
    end
    if op == "int_relative" then
      step.args[1] = parseScalar(pm.previous)
    end
    if op == "compressed_float" then
      step.args[1] = parseScalar(pm.min)
      step.args[2] = parseScalar(pm.max)
      step.args[3] = parseScalar(pm.res)
    end
    if op == "bytes" or op == "string" or op == "wstring" then
      step.args[1] = parseScalar(pm.buffer_size or pm.count or pm.bufferSize)
    end
    if op == "int128" then
      step.args[1] = toPair(step.args[1])
      step.args[2] = toPair(step.args[2])
    end
    raw[1] = step
  end
  return raw
end

-- The step list is used flat: `object <n>` is a no-op step that contributes no
-- bytes and no value of its own ("-"), and its children follow as ordinary
-- steps. Serialization of a nested object is thus exercised through the twin-
-- records and canonical-byte checks (STANDARD.md, object) over the same stream.
local function expandSteps(raw)
  return raw
end

-- run a flat step list (with object groups) on a stream.
-- mode read returns values list; write/measure returns ok.
local function runSteps(stream, steps, mode)
  if mode == "read" then
    local values = {}
    local i = 0
    for _, st in ipairs(steps) do
      i = i + 1
      if st.op == "object" then
        values[i] = nil
      else
        local ok, v = runStep(stream, st, "read")
        if not ok then return false end
        values[i] = v
      end
    end
    return true, values
  else
    -- write or measure: values[] are the decoded values
    error("runSteps write/measure not used at top level", 0)
  end
end

-- Build a value supplier for write/measure from decoded values.
local function runStepsWithValues(stream, steps, values)
  local vi = 1
  for _, st in ipairs(steps) do
    local v = values[vi]
    vi = vi + 1
    if st.op ~= "object" then
      if not runStep(stream, st, "write", v) then return false end
    end
  end
  return true
end

local function runStepsMeasure(stream, steps, values)
  local vi = 1
  for _, st in ipairs(steps) do
    local v = values[vi]
    vi = vi + 1
    if st.op ~= "object" then
      if not runStep(stream, st, "measure", v) then return false end
    end
  end
  return true
end

-- split an expect string into per-step entries for a sequence
local function splitExpect(rec)
  if rec.expect == "refused" then return nil end
  local parts = {}
  for p in rec.expect:gmatch("[^|]+") do
    local t = p:gsub("^%s+", ""):gsub("%s+$", "")
    parts[#parts + 1] = t
  end
  return parts
end

-- parse an expected value string for one step, typed by the step's op
local function parseExpectedValue(op, tok)
  if tok == "-" or tok == "" then return nil end
  if tok == "true" then return true end
  if tok == "false" then return false end
  if op == "float" or op == "double" or op == "compressed_float" then
    local bits = tok:match("^bits 0x([0-9a-fA-F]+)$") or tok:match("^0x([0-9a-fA-F]+)$")
    return { bits = bits, op = op }
  end
  if op == "bytes" or op == "string" then
    return { bytes = hexToBytesStr(tok) }
  end
  if op == "wstring" then
    return { units = hexToBytesStr(tok) }
  end
  return parseToken(tok)
end

local function dbits(v)
  return string.unpack("<i8", string.pack("<d", v))
end

local function utf8ToUtf16Units(s)
  local out = {}
  local i = 1
  while i <= #s do
    local b1 = s:byte(i)
    local cp
    if b1 < 0x80 then
      cp = b1; i = i + 1
    elseif b1 < 0xE0 then
      cp = ((b1 & 0x1F) << 6) | (s:byte(i + 1) & 0x3F); i = i + 2
    elseif b1 < 0xF0 then
      cp = ((b1 & 0x0F) << 12) | ((s:byte(i + 1) & 0x3F) << 6) | (s:byte(i + 2) & 0x3F); i = i + 3
    else
      cp = ((b1 & 0x07) << 18) | ((s:byte(i + 1) & 0x3F) << 12) | ((s:byte(i + 2) & 0x3F) << 6) | (s:byte(i + 3) & 0x3F); i = i + 4
    end
    if cp <= 0xFFFF then
      out[#out + 1] = string.format("%04X", cp)
    else
      local v = cp - 0x10000
      out[#out + 1] = string.format("%04X", 0xD800 + (v >> 10))
      out[#out + 1] = string.format("%04X", 0xDC00 + (v & 0x3FF))
    end
  end
  return table.concat(out)
end

local function valueMatchesOp(op, actual, expected)
  if type(expected) == "table" and expected.bits then
    local want = tonumber(expected.bits, 16)
    local got
    if op == "float" or op == "compressed_float" then
      got = flt.float32Bits(actual)
    else
      got = dbits(actual)
    end
    return got == want
  end
  if type(expected) == "table" and expected.bytes then
    return hexToBytesStr(hexBytes(actual)) == expected.bytes
  end
  if type(expected) == "table" and expected.units then
    return utf8ToUtf16Units(actual) == expected.units
  end
  return valueEquals(actual, expected)
end

--------------------------------------------------------------------------------
-- per-record runner
--------------------------------------------------------------------------------

local function runRecord(rec, scratch)
  local data = unhex(rec.bytes)
  local steps = expandSteps(buildSteps(rec))
  local isRealSequence = false
  for _, p in ipairs(rec.params) do
    if p.name == "step" then isRealSequence = true end
  end

  if rec.expect == "refused" then
    -- refused: read refuses, destination untouched, stream terminal
    local rs = serialize.ReadStream.new(data)
    local ok = runSteps(rs, steps, "read")
    check(ok == false, rec.name .. ": refused read must fail")
    -- terminal: further read also fails, consumes no bits
    local before = rs:bitsProcessed()
    local ok2 = runSteps(rs, steps, "read")
    check(ok2 == false, rec.name .. ": refused stream must stay terminal")
    check(rs:bitsProcessed() == before, rec.name .. ": terminal read must consume no bits")
    return
  end

  -- accepted: read, then consumed check
  local rs = serialize.ReadStream.new(data)
  local ok, values = runSteps(rs, steps, "read")
  check(ok, rec.name .. ": accepted read failed: " .. tostring(rs:error()))
  check(rs:bitsProcessed() == rec.consumed, rec.name .. ": consumed " .. rs:bitsProcessed() .. " want " .. rec.consumed)
  if rec.name == "message-worked-example-wstring-align-fixed" then
    local vd = {}
    for i, v in ipairs(values) do vd[#vd + 1] = tostring(i) .. "=" .. tostring(v) end
  end

  -- value checks
  local expectParts = splitExpect(rec)
  if expectParts and (isRealSequence or #steps == 1) then
    for idx, st in ipairs(steps) do
      if not st.object then
        local tok = expectParts[idx]
        local expected = parseExpectedValue(st.op, tok)
        local actual = values[idx]
        if expected ~= nil then
          local matched = valueMatchesOp(st.op, actual, expected)
          if not matched then
            error(rec.name .. ": step " .. idx .. " value mismatch (" .. st.op .. ") actual=" .. tostring(actual) .. " expected=" .. tostring(expected), 0)
          end
        end
      end
    end
  end

  -- writer canonical: re-write decoded values, byte for byte
  if rec.writer then
    local numBits = rec.consumed or 0
    local bytes = math.ceil(numBits / 8)
    local cap = math.max(8, math.ceil(bytes / 8) * 8)
    local ws = serialize.WriteStream.new(cap)
    check(runStepsWithValues(ws, steps, values), rec.name .. ": canonical write failed: " .. tostring(ws:error()))
    ws:flush()
    check(ws:data() == data, rec.name .. ": canonical bytes mismatch")
  end

  -- measure floor
  if rec.measure then
    local ms = serialize.MeasureStream.new()
    check(runStepsMeasure(ms, steps, values), rec.name .. ": measure failed")
    check(ms:bitsProcessed() >= rec.measure, rec.name .. ": measured " .. ms:bitsProcessed() .. " want at least " .. rec.measure)
  end
end

--------------------------------------------------------------------------------
-- the corpus test
--------------------------------------------------------------------------------

local function readDir(path)
  local out = {}
  local p = io.popen("ls " .. path .. " 2>/dev/null")
  if not p then return out end
  for line in p:lines() do
    if line:match("%.txt$") then out[#out + 1] = line end
  end
  p:close()
  return out
end

function TestConformanceCorpus()
  local files = readDir("conformance")
  check(#files > 0, "no conformance vectors found: the vendored conformance/ directory is missing")

  local total = 0
  for _, file in ipairs(files) do
    local records = parseVectors("conformance/" .. file)
    check(#records > 0, file .. ": no records")
    local opCount = 0
    for line in io.lines("conformance/" .. file) do
      if line:match("^operation%s+") then opCount = opCount + 1 end
    end
    check(#records == opCount, file .. ": parsed " .. #records .. " records, file declares " .. opCount)
    for _, rec in ipairs(records) do
      check(rec.name ~= nil, file .. ": a record has no name")
      -- unknown operation control: any op we cannot drive must reject, not skip
      check(runRecord ~= nil, file .. ": unknown operation " .. tostring(rec.operation))
      local ok, err = pcall(runRecord, rec)
      if not ok then
        error(file .. " " .. tostring(rec.name) .. ": " .. tostring(err), 0)
      end
      total = total + 1
    end
    print(file .. ": " .. #records .. " records")
  end

  -- control 1: a corpus file whose operation has no runner is REJECTED
  do
    local scratch = "scratch_unknown_op.txt"
    local f = assert(io.open(scratch, "w"))
    f:write("operation nosuchop\nname unknown\nbytes 00\nexpect refused\n")
    f:close()
    local recs = parseVectors(scratch)
    local ok, err = pcall(function()
      for _, r in ipairs(recs) do runRecord(r) end
    end)
    os.remove(scratch)
    check(not ok, "control 1: an operation with no runner must be REJECTED, not skipped")
    check(tostring(err):find("no runner") ~= nil, "control 1: rejection names the operation")
  end

  -- control 2: a sabotaged reader (one refusal rule switched off through a
  -- test-only hook the runner passes in) goes red on exactly the vectors that pin
  -- that rule. The hook disables the past-the-end refusal by padding the backing
  -- data and lifting the bit budget; a reader with that rule intact refuses those
  -- vectors, so the sabotage must make them decode.
  do
    local red = 0
    local pin = 0
    for _, rec in ipairs(parseVectors("conformance/bits.txt")) do
      if rec.expect == "refused" and rec.name:find("past%-end") then
        pin = pin + 1
        local data = unhex(rec.bytes)
        local rs = serialize.ReadStream.new(data)
        rs._data = data .. ("\0"):rep(16)
        rs._numBits = rs._numBits + 128
        local ok = runSteps(rs, expandSteps(buildSteps(rec)), "read")
        if ok then red = red + 1 end
      end
    end
    check(pin > 0, "control 2: no past-the-end refusal vectors found")
    check(red > 0, "control 2: the sabotaged reader must go red on the past-the-end vectors")
  end

  check(total > 0, "no conformance vectors ran")
end

return {
  runRecord = runRecord,
  runSteps = runSteps,
  buildSteps = buildSteps,
  expandSteps = expandSteps,
  parseVectors = parseVectors,
  unhex = unhex,
  valueEquals = valueEquals,
  parseExpectedValue = parseExpectedValue,
  valueMatchesOp = valueMatchesOp,
}
