-- test/conformance: the cross-language corpus instrument (serialize-lua-conformance).
-- Run by `make test T=conformance` from the repository root. It enumerates
-- conformance/ at run time and runs every record as STANDARD.md, "What a runner
-- checks", requires:
--   * an accepted vector decodes the stated value (a bit pattern for the float
--     family) and consumes exactly `consumed` bits;
--   * `writer canonical` re-writes the decoded values to the vector's bytes;
--   * `writer_input bits = 0x...` hands the compressed_float writer that float32
--     and requires the vector's bytes, on refused vectors too;
--   * a refused vector refuses with its STATED REASON (the stream's first
--     refusal), leaves the failing read's destination unwritten, and leaves the
--     stream terminal: every later step refuses too, consuming no bits and
--     writing nothing, and so does one more read after the record;
--   * `measure_at_least` is a floor for MeasureStream.
-- Vector names are unique across the corpus, a malformed record (an unknown key,
-- a refusal with no reason or an unknown one) is red, and an operation with no
-- runner is red, never skipped.
--
-- The buffer contract: a ReadStream reads a Lua string and never looks past its
-- length, so the stream is presented with no slack (STANDARD.md, "A harness
-- presents every stream with the slack its implementation's buffer contract
-- requires": this port's contract requires none).
--
-- THE CONTROLS (STANDARD.md, "A gate nobody has seen go red"): the vendored
-- conformance-controls/unknown-operation.txt must be REJECTED; and for each
-- refusal rule, a reader with that one rule deleted (a scratch copy of the
-- library source with one needle replaced, loaded in place of the real module)
-- runs the real corpus and must fail EXACTLY the vectors
-- conformance-controls/<rule>.expected names. A needle that no longer matches
-- is a failure of the control, never a silent no-op.

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

-- The library under test. bind() (re)loads it, so a control can swap in a
-- sabotaged module and the corpus runs against that.
local L = {}
local function bind()
  L.serialize = require("serialize")
  L.flt = require("serialize_float")
  local reasons = {}
  for _, r in pairs(L.serialize.Refusal) do reasons[r] = true end
  L.reasons = reasons
end
bind()

--------------------------------------------------------------------------------
-- numbers (STANDARD.md, "The vector format": signed decimal or 0x hexadecimal,
-- up to 128 bits). Every value is held exactly as a 128-bit two's complement
-- { lo, hi } pair of 64-bit integers; nothing goes through a double.
--------------------------------------------------------------------------------

local MASK64 = -1

local function neg128(lo, hi)
  lo, hi = ~lo, ~hi
  lo = lo + 1
  if lo == 0 then hi = hi + 1 end
  return lo, hi
end

-- mul128small(lo, hi, m, add): (lo,hi) * m + add over 128 bits, m and add small.
local function mulAdd128(lo, hi, m, add)
  -- split lo into 32-bit halves so the products cannot wrap
  local l0 = lo & 0xffffffff
  local l1 = (lo >> 32) & 0xffffffff
  local p0 = l0 * m + add
  local p1 = l1 * m + (p0 >> 32)
  local newLo = (p0 & 0xffffffff) | ((p1 & 0xffffffff) << 32)
  local newHi = hi * m + (p1 >> 32)
  return newLo, newHi
end

local function parse128(token)
  check(type(token) == "string" and token ~= "", "malformed number: empty")
  local t = token
  local neg = false
  if t:sub(1, 1) == "-" then neg = true; t = t:sub(2) end
  local lo, hi = 0, 0
  if t:sub(1, 2) == "0x" or t:sub(1, 2) == "0X" then
    local h = t:sub(3)
    check(h:match("^%x+$") and #h <= 32, "malformed hexadecimal number: " .. token)
    for i = 1, #h do
      local v = tonumber(h:sub(i, i), 16)
      hi = (hi << 4) | (lo >> 60 & 0xf)
      lo = (lo << 4) | v
    end
  else
    check(t:match("^%d+$"), "malformed decimal number: " .. token)
    check(#t <= 39, "number wider than 128 bits: " .. token)
    for i = 1, #t do
      lo, hi = mulAdd128(lo, hi, 10, t:byte(i) - 48)
    end
  end
  if neg then lo, hi = neg128(lo, hi) end
  return lo, hi
end

-- A value that must fit a Lua integer (int64): its high half is the sign
-- extension of its low half.
local function parseInt64(token)
  local lo, hi = parse128(token)
  check(hi == (lo < 0 and MASK64 or 0), "value does not fit 64 bits: " .. token)
  return lo
end

local function parsePair(token)
  local lo, hi = parse128(token)
  return { lo = lo, hi = hi }
end

-- A float parameter (compressed_float min/max/res): a decimal, taken as a Lua
-- float; the library rounds it to float32.
local function parseFloatParam(token)
  local v = tonumber(token)
  check(v ~= nil, "malformed float parameter: " .. token)
  return v + 0.0
end

local function unhex(s)
  if s == nil then return "" end
  local compact = s:gsub("%s+", "")
  check(#compact % 2 == 0 and compact:match("^%x*$"), "malformed hex bytes: " .. s)
  return (compact:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

local function hexOf(s)
  local out = {}
  for i = 1, #s do out[#out + 1] = string.format("%02X", s:byte(i)) end
  return table.concat(out, " ")
end

--------------------------------------------------------------------------------
-- parsing records (STANDARD.md, "The vector format")
--------------------------------------------------------------------------------

local KNOWN_KEYS = {
  operation = true, name = true, param = true, bytes = true, expect = true,
  consumed = true, writer = true, writer_input = true, measure_at_least = true,
}

local function parseVectorsText(content, path)
  local records = {}
  local cur
  local lineNo = 0
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lineNo = lineNo + 1
    local where = path .. ":" .. lineNo
    if line:sub(1, 1) == "#" then
      -- a comment, at the start of a line only
    elseif line:match("^%s*$") then
      cur = nil
    else
      local key, rest = line:match("^(%S+)%s*(.-)%s*$")
      check(KNOWN_KEYS[key], where .. ": unknown key " .. tostring(key))
      if key == "operation" then
        check(cur == nil, where .. ": a second operation in one record")
        cur = { operation = rest, params = {}, parammap = {}, line = lineNo, file = path }
        records[#records + 1] = cur
      else
        check(cur ~= nil, where .. ": " .. key .. " outside a record")
        if key == "name" then
          check(cur.name == nil and rest ~= "", where .. ": name")
          cur.name = rest
        elseif key == "param" then
          local pname, pval = rest:match("^(%S+)%s*=%s*(.-)$")
          check(pname ~= nil, where .. ": malformed param")
          cur.params[#cur.params + 1] = { name = pname, value = pval }
          if pname ~= "step" then cur.parammap[pname] = pval end
        elseif key == "bytes" then
          cur.bytes = unhex(rest)
        elseif key == "expect" then
          check(cur.expect == nil, where .. ": a second expect")
          local reason = rest:match("^refused%s*(.-)$")
          if rest == "refused" or reason ~= nil then
            check(reason ~= nil and reason ~= "", where .. ": a refusal states no reason")
            check(L.reasons[reason], where .. ": unknown refusal reason " .. reason)
            cur.expect = "refused"
            cur.reason = reason
          else
            local kind, v = rest:match("^(%a+)%s*=%s*(.-)$")
            check(kind == "value" or kind == "bits", where .. ": malformed expect " .. rest)
            cur.expect = kind
            cur.expectText = v
          end
        elseif key == "consumed" then
          cur.consumed = math.tointeger(tonumber(rest))
          check(cur.consumed ~= nil and rest:match("^%d+$"), where .. ": malformed consumed")
        elseif key == "writer" then
          check(rest == "canonical", where .. ": writer " .. rest)
          cur.writer = true
        elseif key == "writer_input" then
          local b = rest:match("^bits%s*=%s*0x(%x+)$")
          check(b ~= nil and #b == 8, where .. ": malformed writer_input")
          cur.writerInput = tonumber(b, 16)
        elseif key == "measure_at_least" then
          cur.measure = math.tointeger(tonumber(rest))
          check(cur.measure ~= nil, where .. ": malformed measure_at_least")
        end
      end
    end
  end
  for _, rec in ipairs(records) do
    local where = path .. ":" .. rec.line
    check(rec.name ~= nil, where .. ": a record has no name")
    check(rec.expect ~= nil, where .. ": " .. rec.name .. " has no expect")
    check(rec.bytes ~= nil, where .. ": " .. rec.name .. " has no bytes")
    if rec.expect ~= "refused" then
      check(rec.consumed ~= nil, where .. ": " .. rec.name .. " has no consumed")
    end
  end
  return records
end

local function parseVectors(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("a")
  f:close()
  return parseVectorsText(content, path)
end

--------------------------------------------------------------------------------
-- steps: one spelling per operation (conformance/sequence.txt)
--------------------------------------------------------------------------------

-- parseStep(op, words): a step from its operation and its parameter words, in
-- the step spelling's order.
local function parseStep(op, words)
  local st = { op = op }
  local function want(n)
    check(#words == n, "step " .. op .. " takes " .. n .. " parameters, got " .. #words)
  end
  if op == "bits" then
    want(1); st.n = parseInt64(words[1])
  elseif op == "bool" or op == "align" or op == "float" or op == "double"
    or op == "uint128" or op == "end" then
    want(0)
  elseif op == "int" or op == "int64" then
    want(2); st.min = parseInt64(words[1]); st.max = parseInt64(words[2])
  elseif op == "int128" then
    want(2); st.min = parsePair(words[1]); st.max = parsePair(words[2])
  elseif op == "fixed" then
    want(4)
    st.ib = parseInt64(words[1]); st.fb = parseInt64(words[2])
    st.min = parseInt64(words[3]); st.max = parseInt64(words[4])
  elseif op == "int_relative" then
    want(1); st.previous = parseInt64(words[1])
  elseif op == "compressed_float" then
    want(3)
    st.min = parseFloatParam(words[1]); st.max = parseFloatParam(words[2])
    st.res = parseFloatParam(words[3])
  elseif op == "bytes" then
    want(1); st.count = parseInt64(words[1])
  elseif op == "string" then
    want(1); st.bufferSize = parseInt64(words[1])
  elseif op == "object" then
    want(1); st.count = parseInt64(words[1])
  else
    error("no runner for operation " .. tostring(op), 0)
  end
  return st
end

local function words(s)
  local out = {}
  for w in s:gmatch("%S+") do out[#out + 1] = w end
  return out
end

-- Every operation this runner drives; anything else is red, never skipped.
local KNOWN_OPS = {
  bits = true, bool = true, align = true, float = true, double = true, uint128 = true,
  ["end"] = true, int = true, int64 = true, int128 = true, fixed = true,
  int_relative = true, compressed_float = true, bytes = true, string = true,
}

-- The parameter names of a single-operation record, in step spelling order.
local SINGLE_PARAMS = {
  bits = { "bits" },
  int = { "min", "max" }, int64 = { "min", "max" }, int128 = { "min", "max" },
  fixed = { "integer_bits", "fraction_bits", "min", "max" },
  int_relative = { "previous" },
  compressed_float = { "min", "max", "res" },
  bytes = { "count" },
  string = { "buffer_size" },
}

-- buildSteps(rec): the flat step list. A sequence lists its steps; a single
-- operation is one step, after a `bits <preceding_bits>` step whose value is
-- not stated when the record places the stream at a non-zero bit index.
-- Returns steps, and the index of the step the record's single value is for.
local function buildSteps(rec)
  if rec.operation == "sequence" then
    local steps = {}
    for _, p in ipairs(rec.params) do
      check(p.name == "step", rec.name .. ": a sequence takes only step params, got " .. p.name)
      local w = words(p.value)
      local op = table.remove(w, 1)
      steps[#steps + 1] = parseStep(op, w)
    end
    check(#steps > 0, rec.name .. ": a sequence with no steps")
    return steps, nil
  end
  local op = rec.operation
  if not KNOWN_OPS[op] then error("no runner for operation " .. tostring(op), 0) end
  local names = SINGLE_PARAMS[op] or {}
  local w = {}
  local used = 0
  for _, n in ipairs(names) do
    local v = rec.parammap[n]
    check(v ~= nil, rec.name .. ": param " .. n .. " missing")
    w[#w + 1] = v
    used = used + 1
  end
  local steps = {}
  local pb = rec.parammap.preceding_bits
  if pb ~= nil then
    used = used + 1
    local n = parseInt64(pb)
    steps[#steps + 1] = { op = "bits", n = n, unstated = true }
  end
  for _, p in ipairs(rec.params) do
    check(p.name ~= "step", rec.name .. ": a step param outside a sequence")
  end
  check(used == #rec.params, rec.name .. ": unexpected params for " .. op)
  steps[#steps + 1] = parseStep(op, w)
  return steps, #steps
end

-- treeOf(steps): `object <n>` wraps the next n steps (STANDARD.md, object).
local function treeOf(steps)
  local i = 1
  local function take(limit)
    local nodes = {}
    while i <= #steps and (limit == nil or #nodes < limit) do
      local st = steps[i]
      st.index = i
      i = i + 1
      if st.op == "object" then
        st.children = take(st.count)
        check(#st.children == st.count, "object " .. st.count .. " wraps fewer steps")
      end
      nodes[#nodes + 1] = st
    end
    return nodes
  end
  return take(nil)
end

--------------------------------------------------------------------------------
-- running steps
--------------------------------------------------------------------------------

-- A read destination's initial value: unique, so a refused read that leaves it
-- untouched is distinguishable from one that wrote anything at all.
local SENTINEL = setmetatable({}, { __tostring = function() return "<unwritten>" end })

-- call(s, st, holder): one primitive operation on stream s with holder.
local function call(s, st, holder)
  local op = st.op
  if op == "bits" then
    if st.n == 0 then
      -- zero bits read and write nothing, on a healthy stream; a failed one
      -- answers false (terminal)
      if s:error() ~= nil then return false end
      if s:isReading() then holder.value = 0 end
      return true
    end
    if st.n <= 32 then return s:serializeBits(holder, st.n) end
    return s:serializeBits64(holder, st.n)
  elseif op == "bool" then return s:serializeBool(holder)
  elseif op == "uint128" then return s:serializeUint128(holder)
  elseif op == "int" then return s:serializeInt(holder, st.min, st.max)
  elseif op == "int64" then return s:serializeInt64(holder, st.min, st.max)
  elseif op == "int128" then return s:serializeInt128(holder, st.min, st.max)
  elseif op == "fixed" then return s:serializeFixed(holder, st.ib, st.fb, st.min, st.max)
  elseif op == "int_relative" then return s:serializeIntRelative(st.previous, holder)
  elseif op == "float" then return s:serializeFloat(holder)
  elseif op == "double" then return s:serializeDouble(holder)
  elseif op == "compressed_float" then
    return s:serializeCompressedFloat(holder, st.min, st.max, st.res)
  elseif op == "bytes" then return s:serializeBytes(holder, st.count)
  elseif op == "string" then return s:serializeString(holder, st.bufferSize)
  elseif op == "align" then return s:serializeAlign()
  elseif op == "end" then return s:serializeEnd()
  end
  error("no runner for operation " .. tostring(op), 0)
end

-- readTree(s, nodes, out): reads every node, never stopping at a refusal, and
-- records per step: ok, the bits it consumed, and its destination. An object
-- runs its children through serializeObject.
local function readTree(s, nodes, out)
  local all = true
  for _, st in ipairs(nodes) do
    local before = s:bitsProcessed()
    local r = { step = st }
    out[st.index] = r
    if st.op == "object" then
      local inner = true
      local obj = { serialize = function(_, stream)
        inner = readTree(stream, st.children, out)
        return inner
      end }
      r.ok = s:serializeObject(obj)
      r.holder = { value = SENTINEL }
    else
      r.holder = { value = SENTINEL }
      r.ok = call(s, st, r.holder)
    end
    r.consumed = s:bitsProcessed() - before
    all = all and r.ok
  end
  return all
end

local function readAll(data, steps, tree)
  local rs = L.serialize.ReadStream.new(data)
  local out = {}
  local ok = readTree(rs, tree, out)
  return rs, ok, out, steps
end

-- writeTree(s, nodes, values): writes (or measures) every node with the values
-- a read decoded.
local function writeTree(s, nodes, values)
  for _, st in ipairs(nodes) do
    if st.op == "object" then
      local obj = { serialize = function(_, stream) return writeTree(stream, st.children, values) end }
      if not s:serializeObject(obj) then return false end
    else
      if not call(s, st, { value = values[st.index] }) then return false end
    end
  end
  return true
end

local function capacityFor(bytes)
  return math.max(8, ((bytes + 7) // 8) * 8)
end

--------------------------------------------------------------------------------
-- comparing values, exactly
--------------------------------------------------------------------------------

local function dbits(v)
  return string.unpack("<i8", string.pack("<d", v))
end

-- actualPair(st, v): the decoded value as an exact 128-bit pair, typed by the
-- operation: an unsigned field zero-extends, a signed one sign-extends.
local function actualPair(st, v)
  if type(v) == "table" then return v.lo, v.hi end
  local op = st.op
  if op == "bits" then return v, 0 end
  return v, (v < 0 and MASK64 or 0)
end

-- matches(st, actual, token): does the decoded value equal the stated one?
local function matches(st, actual, token, kind)
  local op = st.op
  if op == "align" or op == "end" or op == "object" then
    return token == "-" or token == "0"
  end
  if token == "-" then return false end
  if op == "float" or op == "compressed_float" or op == "double" then
    local want = token:match("^0x(%x+)$")
    if want == nil then return false end
    local wlo, whi = parse128("0x" .. want)
    if whi ~= 0 then return false end
    local got = (op == "double") and dbits(actual) or L.flt.float32Bits(actual)
    return got == wlo
  end
  if kind == "bits" then return false end
  if op == "bool" then
    return (token == "true" and actual == true) or (token == "false" and actual == false)
  end
  if op == "bytes" or op == "string" then
    return type(actual) == "string" and actual == unhex(token)
  end
  if type(actual) ~= "number" and type(actual) ~= "table" then return false end
  local wlo, whi = parse128(token)
  local alo, ahi = actualPair(st, actual)
  return alo == wlo and ahi == whi
end

local function render(st, v)
  if v == SENTINEL then return "<unwritten>" end
  if type(v) == "table" then return string.format("{lo=0x%016x,hi=0x%016x}", v.lo, v.hi) end
  if type(v) == "string" then return "[" .. hexOf(v) .. "]" end
  if st.op == "double" and type(v) == "number" then return string.format("0x%016X", dbits(v)) end
  if (st.op == "float" or st.op == "compressed_float") and type(v) == "number" then
    return string.format("0x%08X", L.flt.float32Bits(v))
  end
  return tostring(v)
end

local function splitExpect(text, n)
  local parts = {}
  if n == 1 then
    parts[1] = text
  else
    for p in (text .. "|"):gmatch("([^|]*)|") do
      parts[#parts + 1] = (p:gsub("^%s+", ""):gsub("%s+$", ""))
    end
  end
  return parts
end

--------------------------------------------------------------------------------
-- one record
--------------------------------------------------------------------------------

local function runWriterInput(rec, steps)
  check(#steps == 1 and steps[1].op == "compressed_float",
    rec.name .. ": writer_input is for a single compressed_float")
  local st = steps[1]
  local value = L.flt.float32FromBits(rec.writerInput)
  local ws = L.serialize.WriteStream.new(capacityFor(#rec.bytes))
  check(ws:serializeCompressedFloat({ value = value }, st.min, st.max, st.res),
    rec.name .. ": writer_input write failed: " .. tostring(ws:error()))
  ws:flush()
  check(ws:data() == rec.bytes, rec.name .. ": writer_input wrote [" .. hexOf(ws:data())
    .. "], want [" .. hexOf(rec.bytes) .. "]")
end

local function runRecord(rec)
  local steps, single = buildSteps(rec)
  local tree = treeOf(steps)

  if rec.writerInput ~= nil then runWriterInput(rec, steps) end

  local rs, ok, out = readAll(rec.bytes, steps, tree)

  if rec.expect == "refused" then
    check(not ok, rec.name .. ": a refused vector was accepted")
    check(rs:error() == rec.reason, rec.name .. ": refused as " .. tostring(rs:error())
      .. ", the vector states " .. rec.reason)
    -- the first refusing primitive leaves its destination unwritten; every
    -- step after it refuses, consumes nothing and writes nothing
    local first
    for i = 1, #steps do
      local r = out[i]
      if r ~= nil then
        if first == nil then
          if not r.ok and steps[i].op ~= "object" then
            first = i
            check(r.holder.value == SENTINEL, rec.name .. ": step " .. i
              .. " refused but wrote its destination: " .. render(steps[i], r.holder.value))
          end
        else
          check(not r.ok, rec.name .. ": step " .. i .. " after the refusal was accepted")
          check(r.consumed == 0, rec.name .. ": step " .. i .. " after the refusal consumed bits")
          check(r.holder.value == SENTINEL, rec.name .. ": step " .. i .. " after the refusal wrote its destination")
        end
      end
    end
    check(first ~= nil, rec.name .. ": no primitive step refused")
    -- the stream is terminal for one more read of every kind it ran, and an end
    local before = rs:bitsProcessed()
    local again = {}
    check(not readTree(rs, tree, again), rec.name .. ": the failed stream accepted a further read")
    for i = 1, #steps do
      local r = again[i]
      if r ~= nil then
        check(not r.ok and r.consumed == 0 and r.holder.value == SENTINEL,
          rec.name .. ": a further read of step " .. i .. " on the failed stream was not refused cleanly")
      end
    end
    check(rs:serializeEnd() == false, rec.name .. ": an end on the failed stream was accepted")
    check(rs:bitsProcessed() == before, rec.name .. ": the failed stream consumed bits")
    check(rs:error() == rec.reason, rec.name .. ": the echoes changed the first reason to " .. tostring(rs:error()))
    return
  end

  check(ok, rec.name .. ": an accepted vector was refused as " .. tostring(rs:error()))
  check(rs:bitsProcessed() == rec.consumed, rec.name .. ": consumed " .. rs:bitsProcessed()
    .. ", the vector states " .. rec.consumed)

  local values = {}
  for i = 1, #steps do values[i] = out[i].holder.value end

  local parts = splitExpect(rec.expectText, single and 1 or #steps)
  if single then
    for i = 1, #steps do
      if i ~= single then check(steps[i].unstated, rec.name .. ": a value with no expectation") end
    end
    check(matches(steps[single], values[single], parts[1], rec.expect), rec.name .. ": decoded "
      .. render(steps[single], values[single]) .. ", the vector states " .. parts[1])
  else
    check(#parts == #steps, rec.name .. ": " .. #parts .. " expected values for " .. #steps .. " steps")
    for i = 1, #steps do
      check(matches(steps[i], values[i], parts[i], rec.expect), rec.name .. ": step " .. i .. " ("
        .. steps[i].op .. ") decoded " .. render(steps[i], values[i]) .. ", the vector states " .. parts[i])
    end
  end

  if rec.writer then
    local ws = L.serialize.WriteStream.new(capacityFor(#rec.bytes))
    check(writeTree(ws, tree, values), rec.name .. ": the canonical write failed: " .. tostring(ws:error()))
    check(ws:serializeEnd(), rec.name .. ": the writer's end failed")
    ws:flush()
    check(ws:data() == rec.bytes, rec.name .. ": the writer emitted [" .. hexOf(ws:data())
      .. "], the vector states [" .. hexOf(rec.bytes) .. "]")
  end

  if rec.measure then
    local ms = L.serialize.MeasureStream.new()
    check(writeTree(ms, tree, values), rec.name .. ": the measure failed: " .. tostring(ms:error()))
    check(ms:bitsProcessed() >= rec.measure, rec.name .. ": measured " .. ms:bitsProcessed()
      .. ", the vector requires at least " .. rec.measure)
  end
end

--------------------------------------------------------------------------------
-- the corpus
--------------------------------------------------------------------------------

local function readDir(path, suffix)
  local out = {}
  local p = io.popen("ls " .. path .. " 2>/dev/null")
  if not p then return out end
  for line in p:lines() do
    if line:sub(-#suffix) == suffix then out[#out + 1] = line end
  end
  p:close()
  table.sort(out)
  return out
end

-- runCorpus(): every record of every file; returns the per-file counts, the
-- total, and the names of the records that failed (with their messages).
local function runCorpus()
  local files = readDir("conformance", ".txt")
  check(#files > 0, "no conformance vectors found: the vendored conformance/ directory is missing or empty")
  local names = {}
  local counts = {}
  local failed = {}
  local total = 0
  for _, file in ipairs(files) do
    local records = parseVectors("conformance/" .. file)
    local declared = 0
    for line in io.lines("conformance/" .. file) do
      if line:match("^operation%s") then declared = declared + 1 end
    end
    check(#records > 0 and #records == declared, file .. ": parsed " .. #records
      .. " records, the file declares " .. declared)
    for _, rec in ipairs(records) do
      check(names[rec.name] == nil, file .. ": vector name " .. rec.name .. " is not unique")
      names[rec.name] = file
      local ok, err = pcall(runRecord, rec)
      if not ok then failed[#failed + 1] = { name = rec.name, err = tostring(err) } end
      total = total + 1
    end
    counts[#counts + 1] = { file = file, n = #records }
  end
  return counts, total, failed
end

function TestConformanceCorpus()
  local counts, total, failed = runCorpus()
  for _, c in ipairs(counts) do print(c.file .. ": " .. c.n .. " records") end
  for _, f in ipairs(failed) do print("  FAIL " .. f.err) end
  check(#failed == 0, #failed .. " of " .. total .. " vectors failed")
  print("conformance: " .. total .. " of " .. total .. " vectors passed in " .. #counts .. " files")
end

-- Control: an operation with no runner is REJECTED, never skipped.
function TestConformanceControlUnknownOperation()
  local recs = parseVectors("conformance-controls/unknown-operation.txt")
  check(#recs == 1, "the unknown-operation control holds one record")
  local ok, err = pcall(runRecord, recs[1])
  check(not ok, "control unknown-operation: an operation with no runner must be REJECTED")
  check(tostring(err):find("no runner for operation no_such_operation", 1, true) ~= nil,
    "control unknown-operation: the rejection names the operation, got " .. tostring(err))
end

--------------------------------------------------------------------------------
-- the sabotage controls
--------------------------------------------------------------------------------

-- Each control deletes ONE refusal rule (or, for wrong-reason, names the wrong
-- one) by replacing needles in a scratch copy of the library source. A rule
-- that lives in more than one place in this port (a ranged int is also
-- int_relative's bounded payload and a string's length, as STANDARD.md
-- defines them) is deleted in each place, so the reader has that one rule
-- deleted and nothing else.
local CONTROLS = {
  {
    name = "align-padding", rule = "readers must verify that the alignment padding bits are zero",
    patches = { { "src/serialize_stream.lua",
      "  local v = self:_readBits(n)\n  if v == nil then return false end\n  if v ~= 0 then return fail(self, NONZERO_PADDING) end",
      "  local v = self:_readBits(n)\n  if v == nil then return false end\n  if v ~= 0 and false then return fail(self, NONZERO_PADDING) end" } },
  },
  {
    name = "ranged-reconstruction", rule = "a ranged int decodes to its offset plus min",
    patches = {
      { "src/serialize_int.lua",
        "    if offset > span then\n      return s:_fail(VALUE_OUT_OF_RANGE)\n    end\n    return true, offset + min",
        "    if offset > span then\n      return s:_fail(VALUE_OUT_OF_RANGE)\n    end\n    return true, offset" },
      { "src/serialize_int_relative.lua",
        "return result(stream, previous, previous + b.min + offset)",
        "return result(stream, previous, previous + offset)" },
    },
  },
  {
    name = "ranged-range", rule = "a ranged int whose offset is past the span is refused",
    patches = {
      { "src/serialize_int.lua", "    if offset > span then\n", "    if offset > span and false then\n" },
      { "src/serialize_int_relative.lua", "if offset > b.max - b.min then", "if offset > b.max - b.min and false then" },
      { "src/serialize_bytes.lua", "if length > bufferSize - 1 then return s:_fail(VALUE_OUT_OF_RANGE) end",
        "if length > bufferSize - 1 and false then return s:_fail(VALUE_OUT_OF_RANGE) end" },
    },
  },
  {
    -- Every read consults the failure state in the one dispatcher; this
    -- deletes the consult for serializeFixed, whose degenerate field reads no
    -- bits and would otherwise succeed.
    name = "fixed-degenerate-terminal", rule = "every read consults the failure state, zero bit reads included",
    patches = { { "src/serialize_stream.lua",
      "        if a.check then a.check(...) end\n        if self._err ~= nil then return false end\n        local ok, value = a.read(self, ...)",
      "        if a.check then a.check(...) end\n        if self._err ~= nil and name ~= \"serializeFixed\" then return false end\n        local ok, value = a.read(self, ...)" } },
  },
  {
    name = "float-finite", rule = "a float read refuses NaN and the infinities",
    patches = { { "src/serialize_float.lua",
      "      if bits == nil then return false end\n      if not floatBitsAreFinite(bits) then",
      "      if bits == nil then return false end\n      if not floatBitsAreFinite(bits) and false then" } },
  },
  {
    name = "double-finite", rule = "a double read refuses NaN and the infinities",
    patches = { { "src/serialize_float.lua",
      "      if bits == nil then return false end\n      if not doubleBitsAreFinite(bits) then",
      "      if bits == nil then return false end\n      if not doubleBitsAreFinite(bits) and false then" } },
  },
  {
    name = "compressed-float-finite", rule = "a compressed float decode that is not finite is refused",
    patches = { { "src/serialize_compressed_float.lua",
      "if not isFinite(v) then return s:_fail(NON_FINITE_FLOAT) end",
      "if not isFinite(v) and false then return s:_fail(NON_FINITE_FLOAT) end" } },
  },
  {
    name = "end-trailing-data", rule = "an end refuses a whole byte after the object",
    patches = { { "src/serialize_stream.lua",
      "if remaining >= 8 then return fail(self, TRAILING_DATA) end",
      "if remaining >= 8 and false then return fail(self, TRAILING_DATA) end" } },
  },
  {
    name = "end-padding", rule = "an end refuses non-zero padding in the final byte",
    patches = { { "src/serialize_stream.lua",
      "  local v = self:_readBits(remaining)\n  if v == nil then return false end\n  if v ~= 0 then return fail(self, NONZERO_PADDING) end",
      "  local v = self:_readBits(remaining)\n  if v == nil then return false end\n  if v ~= 0 and false then return fail(self, NONZERO_PADDING) end" } },
  },
  {
    name = "int-relative-canonical", rule = "the absolute tier refuses a difference a bounded tier carries",
    patches = { { "src/serialize_int_relative.lua",
      "if v - previous <= LAST_BOUNDED_MAX then",
      "if v - previous <= LAST_BOUNDED_MAX and false then" } },
  },
  {
    name = "string-embedded-nul", rule = "a string read refuses a zero byte among its payload",
    patches = { { "src/serialize_bytes.lua",
      "if data:find(\"\\0\", 1, true) then return s:_fail(EMBEDDED_NUL) end",
      "if data:find(\"\\0\", 1, true) and false then return s:_fail(EMBEDDED_NUL) end" } },
  },
  {
    name = "string-utf8", rule = "a string read refuses a payload that is not well formed UTF-8",
    patches = { { "src/serialize_bytes.lua",
      "if not validUTF8(data) then return s:_fail(INVALID_UTF8) end",
      "if not validUTF8(data) and false then return s:_fail(INVALID_UTF8) end" } },
  },
  {
    name = "string-utf8-surrogate", rule = "a string read refuses an encoded surrogate code point",
    patches = { { "src/serialize_bytes.lua",
      "if b == 0xED and c1 >= 0xA0 then return false end",
      "if b == 0xED and c1 >= 0xA0 and c1 > 0xFF then return false end" } },
  },
  {
    -- A reader whose ranged 64-bit integer passes through a double, as a port
    -- backed by a double number type would.
    name = "int64-through-double", rule = "a 64 bit value is carried exactly, never through a double",
    patches = { { "src/serialize_int.lua",
      "    if math.ult(span, offset) then\n      return s:_fail(VALUE_OUT_OF_RANGE)\n    end\n    return true, offset + min",
      "    if math.ult(span, offset) then\n      return s:_fail(VALUE_OUT_OF_RANGE)\n    end\n"
        .. "    local d = (offset + min) + 0.0\n"
        .. "    return true, (d >= 9223372036854775807.0) and math.maxinteger or math.tointeger(d)" } },
  },
  {
    name = "wrong-reason", rule = "a refusal names the rule that refused it",
    patches = { { "src/serialize_bytes.lua",
      "then return s:_fail(EMBEDDED_NUL) end",
      "then return s:_fail(INVALID_UTF8) end" } },
  },
}

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

local function unloadLibrary()
  for k in pairs(package.loaded) do
    if k == "serialize" or k:match("^serialize_") then package.loaded[k] = nil end
  end
  for k in pairs(package.preload) do
    if k == "serialize" or k:match("^serialize_") then package.preload[k] = nil end
  end
end

-- withSabotage(control, fn): runs fn against the library with the control's
-- patches applied, then restores the real library. Each needle must occur
-- exactly once in its file, or the control itself fails.
local function withSabotage(control, fn)
  local sources = {}
  for _, p in ipairs(control.patches) do
    local file, needle, patch = p[1], p[2], p[3]
    local src = sources[file] or readFile(file)
    local first = src:find(needle, 1, true)
    check(first ~= nil, "control " .. control.name .. ": the needle no longer matches " .. file)
    check(src:find(needle, first + 1, true) == nil,
      "control " .. control.name .. ": the needle matches more than once in " .. file)
    sources[file] = src:sub(1, first - 1) .. patch .. src:sub(first + #needle)
  end
  unloadLibrary()
  for file, src in pairs(sources) do
    local mod = file:match("^src/(.+)%.lua$")
    local chunk = assert(load(src, "=" .. file .. " (sabotaged: " .. control.name .. ")", "t"))
    package.preload[mod] = function(...) return chunk(...) end
  end
  bind()
  local ok, err = pcall(fn)
  unloadLibrary()
  bind()
  if not ok then error(err, 0) end
end

local function readExpected(name)
  local list, set = {}, {}
  for line in io.lines("conformance-controls/" .. name .. ".expected") do
    if not line:match("^#") and line:match("%S") then
      local n = line:match("^%s*(.-)%s*$")
      list[#list + 1] = n
      set[n] = true
    end
  end
  return list, set
end

local function runControl(control)
  local expectedList, expected = readExpected(control.name)
  check(#expectedList > 0, "control " .. control.name .. ": the expected list names no vector")
  local failedSet = {}
  withSabotage(control, function()
    local _, _, failed = runCorpus()
    for _, f in ipairs(failed) do failedSet[f.name] = f.err end
  end)
  local problems = {}
  for _, n in ipairs(expectedList) do
    if failedSet[n] == nil then problems[#problems + 1] = n .. " should have failed and passed" end
  end
  local names = {}
  for n in pairs(failedSet) do names[#names + 1] = n end
  table.sort(names)
  for _, n in ipairs(names) do
    if not expected[n] then problems[#problems + 1] = n .. " failed and is not in the list: " .. failedSet[n] end
  end
  check(#problems == 0, "control " .. control.name .. " (" .. control.rule .. "):\n  "
    .. table.concat(problems, "\n  "))
  print("control " .. control.name .. ": exactly the " .. #expectedList .. " expected vectors failed")
end

function TestConformanceControls()
  -- every vendored .expected list has a control here, and every control a list
  local have = {}
  for _, c in ipairs(CONTROLS) do have[c.name] = true end
  for _, f in ipairs(readDir("conformance-controls", ".expected")) do
    local n = f:sub(1, -#".expected" - 1)
    check(have[n], "conformance-controls/" .. f .. " has no sabotage control in this runner")
  end
  for _, c in ipairs(CONTROLS) do runControl(c) end
end

-- The controls' own reversed witness: a sabotage whose needle does not match
-- fails, by name, rather than running the real library as if sabotaged.
function TestConformanceControlNeedleMustMatch()
  local ok, err = pcall(withSabotage, {
    name = "no-such-needle", rule = "none",
    patches = { { "src/serialize_stream.lua", "this text appears nowhere in the source", "" } },
  }, function() end)
  check(not ok and tostring(err):find("needle no longer matches", 1, true) ~= nil,
    "a needle that does not match must fail the control, got " .. tostring(err))
end

-- The runner's own reversed witnesses: each record below is a real vector
-- with one thing wrong, and the runner must fail it. Its twin, with that thing
-- right, must pass, so a witness cannot pass by failing for another reason.
local WITNESSES = {
  -- 2^64 - 1 as a uint128 has hi = 0; -1 has hi = all ones. A runner that
  -- treats the two high halves as equal passes the wrong one.
  { good = "operation uint128\nname w\nbytes FF FF FF FF FF FF FF FF 00 00 00 00 00 00 00 00\nexpect value = 18446744073709551615\nconsumed 128\nwriter canonical\n",
    bad = "operation uint128\nname w\nbytes FF FF FF FF FF FF FF FF 00 00 00 00 00 00 00 00\nexpect value = -1\nconsumed 128\n",
    why = "a 128-bit value compared on both halves" },
  { good = "operation bits\nname w\nparam bits = 64\nbytes FF FF FF FF FF FF FF FF\nexpect value = 18446744073709551615\nconsumed 64\n",
    bad = "operation bits\nname w\nparam bits = 64\nbytes FF FF FF FF FF FF FF FF\nexpect value = 18446744073709551614\nconsumed 64\n",
    why = "a 64-bit value compared exactly" },
  { good = "operation int64\nname w\nparam min = -9223372036854775808\nparam max = 9223372036854775807\nbytes FF FF FF FF FF FF FF FF\nexpect value = 9223372036854775807\nconsumed 64\n",
    bad = "operation int64\nname w\nparam min = -9223372036854775808\nparam max = 9223372036854775807\nbytes FF FF FF FF FF FF FF FF\nexpect value = 9223372036854775807\nconsumed 63\n",
    why = "the bits consumed" },
  { good = "operation sequence\nname w\nparam step = bits 3\nbytes 05\nexpect value = 5\nconsumed 3\nwriter canonical\n",
    bad = "operation sequence\nname w\nparam step = bits 3\nbytes 0D\nexpect value = 5\nconsumed 3\nwriter canonical\n",
    why = "the canonical writer's bytes" },
  { good = "operation string\nname w\nparam buffer_size = 4\nbytes 01 00\nexpect refused embedded_nul\n",
    bad = "operation string\nname w\nparam buffer_size = 4\nbytes 01 00\nexpect refused invalid_utf8\n",
    why = "the stated refusal reason" },
  { good = "operation sequence\nname w\nparam step = bits 8\nparam step = align\nparam step = bits 8\nbytes 01 02\nexpect value = 1 | - | 2\nconsumed 16\nmeasure_at_least 23\n",
    bad = "operation sequence\nname w\nparam step = bits 8\nparam step = align\nparam step = bits 8\nbytes 01 02\nexpect value = 1 | - | 2\nconsumed 16\nmeasure_at_least 24\n",
    why = "the measure floor" },
  { good = "operation compressed_float\nname w\nparam min = 0\nparam max = 10\nparam res = 0.01\nwriter_input bits = 0x3CCCCCCD\nbytes 03 00\nexpect bits = 0x3CF5C290\nconsumed 10\n",
    bad = "operation compressed_float\nname w\nparam min = 0\nparam max = 10\nparam res = 0.01\nwriter_input bits = 0x3CA3D70A\nbytes 03 00\nexpect bits = 0x3CF5C290\nconsumed 10\n",
    why = "the writer_input bytes" },
  { good = "operation sequence\nname w\nparam step = bits 3\nparam step = end\nbytes 05\nexpect value = 5 | -\nconsumed 8\n",
    bad = "operation sequence\nname w\nparam step = bits 3\nparam step = end\nbytes 05\nexpect value = 6 | -\nconsumed 8\n",
    why = "a sequence's values" },
}

function TestConformanceRunnerWitnesses()
  for _, w in ipairs(WITNESSES) do
    local good = parseVectorsText(w.good, "witness")
    check(#good == 1, "witness parse: " .. w.why)
    local ok, err = pcall(runRecord, good[1])
    check(ok, "witness twin must pass (" .. w.why .. "): " .. tostring(err))
    local bad = parseVectorsText(w.bad, "witness")
    check(#bad == 1, "witness parse: " .. w.why)
    check(not pcall(runRecord, bad[1]), "the runner must fail a vector wrong in " .. w.why)
  end
  -- malformed records are red: a refusal with no reason, an unknown reason,
  -- an unknown key
  local malformed = {
    "operation bool\nname m\nbytes\nexpect refused\n",
    "operation bool\nname m\nbytes\nexpect refused overflow\n",
    "operation bool\nname m\nbytes\nexpect refused past_end\nfrobnicate 1\n",
  }
  for _, text in ipairs(malformed) do
    check(not pcall(parseVectorsText, text, "malformed"), "a malformed record must be red: " .. text)
  end
  check(pcall(parseVectorsText, "operation bool\nname m\nbytes\nexpect refused past_end\n", "ok"),
    "the well-formed twin of the malformed records parses")
end

return {
  parseVectors = parseVectors,
  buildSteps = buildSteps,
  treeOf = treeOf,
  readAll = readAll,
  runRecord = runRecord,
  matches = matches,
  unhex = unhex,
  SENTINEL = SENTINEL,
}
