-- test/bits: the bits family (card serialize-lua-bits). Runs every record of
-- conformance/bits.txt, bool.txt, uint128.txt and align.txt, serial.go's
-- TestContinue and TestUntil cases, and MeasureStream's bit counts for the
-- operations this card owns. Run by `make test T=bits` from the repository
-- root. No real time, no sockets, no network.

local serialize = require("serialize")
local WriteStream = serialize.WriteStream
local ReadStream = serialize.ReadStream
local MeasureStream = serialize.MeasureStream

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local function raises(fn, want)
  local ok, err = pcall(fn)
  check(not ok, "expected a raise containing: " .. want)
  check(string.find(tostring(err), want, 1, true) ~= nil,
    "raise was \"" .. tostring(err) .. "\", wanted it to contain \"" .. want .. "\"")
end

--------------------------------------------------------------------------------
-- LARGE-UNSIGNED COMPARISON (limbs, 32-bit each, LSB first; up to 4 = 128 bits).
--------------------------------------------------------------------------------

local function parseNum(s)
  if s:match("^0[xX]") then
    local t = s:sub(3)
    local nums = {}
    for i = #t, 1, -8 do
      local chunk = t:sub(math.max(1, i - 7), i)
      nums[#nums + 1] = tonumber(chunk, 16)
    end
    return nums
  end
  local nums = { 0 }
  for i = 1, #s do
    local carry = s:byte(i) - 48
    for k = 1, #nums do
      local p = nums[k] * 10 + carry
      nums[k] = p & 0xffffffff
      carry = p >> 32
    end
    while carry > 0 do
      nums[#nums + 1] = carry & 0xffffffff
      carry = carry >> 32
    end
  end
  return nums
end

local function intToLimbs(v)
  return { v & 0xffffffff, (v >> 32) & 0xffffffff }
end

local function uint128ToLimbs(v)
  return {
    v.lo & 0xffffffff,
    (v.lo >> 32) & 0xffffffff,
    v.hi & 0xffffffff,
    (v.hi >> 32) & 0xffffffff,
  }
end

local function limbsEq(a, b)
  local n = math.max(#a, #b)
  for i = 1, n do
    if (a[i] or 0) ~= (b[i] or 0) then return false end
  end
  return true
end

local function limbsToInt(limbs)
  local lo = limbs[1] or 0
  local hi = limbs[2] or 0
  return lo | (hi << 32)
end

--------------------------------------------------------------------------------
-- UINT128 AND BYTES THROUGH THIS CARD'S PRIMITIVES.
--
-- DESIGN.md (h) gives the serializeUint128 arm to serialize_int128.lua and the
-- serializeBytes arm to serialize_bytes.lua, and this card's file may not add
-- either. The conformance records are still this card's to pin: uint128 is
-- exactly serializeBits64(lo, 64) then serializeBits64(hi, 64) (STANDARD.md,
-- uint128), and a bytes block is an align followed by its bytes. Running them
-- through the bits arms is the same wire, byte for byte.
--------------------------------------------------------------------------------

local function readUint128(stream)
  local lo = { value = false }
  local hi = { value = false }
  if not stream:serializeBits64(lo, 64) then return false end
  if not stream:serializeBits64(hi, 64) then return false end
  return true, { lo = lo.value, hi = hi.value }
end

local function writeUint128(stream, value)
  if not stream:serializeBits64({ value = value.lo }, 64) then return false end
  return stream:serializeBits64({ value = value.hi }, 64)
end

local function readBytesViaBits(stream, n)
  if not stream:serializeAlign() then return false end
  local out = {}
  for i = 1, n do
    local h = { value = 0 }
    if not stream:serializeBits(h, 8) then return false end
    out[i] = string.char(h.value)
  end
  return true, table.concat(out)
end

local function writeBytesViaBits(stream, value)
  if not stream:serializeAlign() then return false end
  for i = 1, #value do
    if not stream:serializeBits({ value = value:byte(i) }, 8) then return false end
  end
  return true
end

--------------------------------------------------------------------------------
-- VECTOR PARSING
--------------------------------------------------------------------------------

local function readFile(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function loadRecords(path)
  local records = {}
  local cur
  for line in readFile(path):gmatch("[^\n]*") do
    line = line:gsub("\r$", "")
    if line:match("^%s*$") then
      cur = nil
    elseif line:sub(1, 1) == "#" then
    else
      local key, rest = line:match("^(%S+)%s?(.*)$")
      if rest == "" then rest = nil end
      if not cur then
        cur = { op = nil, name = nil, params = {}, steps = {}, bytes = "", expect = nil, consumed = nil, writer = false, measure = nil }
        records[#records + 1] = cur
      end
      if key == "operation" then
        cur.op = rest
      elseif key == "name" then
        cur.name = rest
      elseif key == "param" then
        local pn, pv = rest:match("^(%S+)%s*=%s*(.*)$")
        if pn == "step" then
          cur.steps[#cur.steps + 1] = pv
        else
          cur.params[pn] = pv
        end
      elseif key == "bytes" then
        if rest then
          local bin = {}
          for b in rest:gmatch("%x%x") do bin[#bin + 1] = string.char(tonumber(b, 16)) end
          cur.bytes = table.concat(bin)
        else
          cur.bytes = ""
        end
      elseif key == "expect" then
        cur.expect = rest
      elseif key == "consumed" then
        cur.consumed = tonumber(rest)
      elseif key == "writer" then
        cur.writer = (rest == "canonical")
      elseif key == "measure_at_least" then
        cur.measure = tonumber(rest)
      end
    end
  end
  return records
end

local function expectValue(rec)
  local v = rec.expect
  if v and v:match("^value%s*=%s*(.*)$") then
    return v:match("^value%s*=%s*(.*)$")
  end
  return nil
end

local function isRefused(rec)
  return rec.expect and rec.expect:match("^refused$") ~= nil
end

--------------------------------------------------------------------------------
-- SINGLE-OP READ / WRITE
--------------------------------------------------------------------------------

local CAPACITY = 64

local function doRead(rec)
  local rs = ReadStream.new(rec.bytes)
  local holder = { value = false }
  local ok
  if rec.op == "bits" then
    local bits = tonumber(rec.params.bits)
    if bits <= 32 then
      ok = rs:serializeBits(holder, bits)
    else
      ok = rs:serializeBits64(holder, bits)
    end
  elseif rec.op == "bool" then
    ok = rs:serializeBool(holder)
  elseif rec.op == "uint128" then
    local okRead, value = readUint128(rs)
    if okRead then holder.value = value end
    ok = okRead
  elseif rec.op == "align" then
    local pb = tonumber(rec.params.preceding_bits)
    if pb > 0 then
      local d = { value = 0 }
      ok = rs:serializeBits(d, pb)
    end
    if ok ~= false then ok = rs:serializeAlign() end
  else
    error("test: no runner for operation " .. tostring(rec.op))
  end
  return rs, holder, ok
end

local function checkAcceptedBits(rec)
  local rs, holder, ok = doRead(rec)
  check(ok == true, "expected accepted read: " .. rec.name)
  check(rs:error() == nil, "no error latched: " .. rec.name)
  check(rs:bitsProcessed() == rec.consumed,
    rec.name .. ": consumed " .. tostring(rs:bitsProcessed()) .. ", want " .. tostring(rec.consumed))
  local ev = expectValue(rec)
  if rec.op == "bits" then
    check(limbsEq(intToLimbs(holder.value), parseNum(ev)), rec.name .. ": decoded value mismatch")
  elseif rec.op == "bool" then
    check(holder.value == (ev == "true"), rec.name .. ": bool mismatch")
  elseif rec.op == "uint128" then
    check(limbsEq(uint128ToLimbs(holder.value), parseNum(ev)), rec.name .. ": uint128 mismatch")
  end
end

local function checkRefused(rec)
  local rs, holder, ok = doRead(rec)
  check(ok == false, "expected refusal: " .. rec.name)
  check(rs:error() ~= nil, "refusal must latch an error: " .. rec.name)
  if rec.op ~= "align" then
    check(holder.value == false, "destination must be untouched: " .. rec.name)
  end
  local before = rs:bitsProcessed()
  local ok2 = rs:serializeBits({ value = false }, 1)
  check(ok2 == false, "terminal: a later read must fail: " .. rec.name)
  check(rs:bitsProcessed() == before, "terminal: no bits consumed: " .. rec.name)
end

local function checkWriter(rec)
  local ws = WriteStream.new(CAPACITY)
  local ok
  local ev = expectValue(rec)
  if rec.op == "bits" then
    local bits = tonumber(rec.params.bits)
    if bits <= 32 then
      ok = ws:serializeBits({ value = limbsToInt(parseNum(ev)) }, bits)
    else
      ok = ws:serializeBits64({ value = limbsToInt(parseNum(ev)) }, bits)
    end
  elseif rec.op == "bool" then
    ok = ws:serializeBool({ value = (ev == "true") })
  elseif rec.op == "uint128" then
    local limbs = parseNum(ev)
    local value = {
      lo = (limbs[1] or 0) | ((limbs[2] or 0) << 32),
      hi = (limbs[3] or 0) | ((limbs[4] or 0) << 32),
    }
    ok = writeUint128(ws, value)
  elseif rec.op == "align" then
    local pb = tonumber(rec.params.preceding_bits)
    if pb > 0 then
      local v = (rec.bytes:byte(1) or 0) & ((1 << pb) - 1)
      ok = ws:serializeBits({ value = v }, pb)
    end
    if ok ~= false then ok = ws:serializeAlign() end
  end
  check(ok == true, "writer failed: " .. rec.name)
  ws:flush()
  check(ws:data() == rec.bytes, "writer bytes mismatch: " .. rec.name)
end

local function runSingleOpFile(path)
  local records = loadRecords(path)
  local counts = { accepted = 0, refused = 0 }
  for _, rec in ipairs(records) do
    if isRefused(rec) then
      checkRefused(rec)
      counts.refused = counts.refused + 1
    else
      checkAcceptedBits(rec)
      counts.accepted = counts.accepted + 1
      if rec.writer then checkWriter(rec) end
    end
  end
  check(#records == counts.accepted + counts.refused, path .. ": record accounting")
  print("bits: " .. path .. " " .. #records .. " records")
  return #records
end

--------------------------------------------------------------------------------
-- SEQUENCE / OBJECT RUNNER (conformance/object.txt)
--------------------------------------------------------------------------------

local function parseStep(s)
  local t, rest = s:match("^(%S+)%s*(.*)$")
  if t == "bits" then return { type = "bits", n = tonumber(rest) } end
  if t == "bool" then return { type = "bool" } end
  if t == "align" then return { type = "align" } end
  if t == "bytes" then return { type = "bytes", n = tonumber(rest) } end
  if t == "object" then return { type = "object", n = tonumber(rest) } end
  error("test: unknown step \"" .. tostring(s) .. "\"")
end

local function buildOps(steps, idx)
  local ops = {}
  local i = idx or 1
  while i <= #steps do
    local st = steps[i]
    local op = parseStep(st)
    if op.type == "object" then
      local inner = {}
      i = i + 1
      for _ = 1, op.n do
        local sub = parseStep(steps[i])
        if sub.type == "object" then
          local subInner, ni = buildOps(steps, i)
          sub.inner = subInner
          inner[#inner + 1] = sub
          i = ni
        else
          inner[#inner + 1] = sub
          i = i + 1
        end
      end
      op.inner = inner
      ops[#ops + 1] = op
    else
      ops[#ops + 1] = op
      i = i + 1
    end
  end
  return ops, i
end

local function hexEncode(s)
  local out = {}
  for i = 1, #s do out[#out + 1] = string.format("%02X", s:byte(i)) end
  return table.concat(out)
end

local function splitExpect(rec)
  local ev = expectValue(rec)
  local parts = {}
  if ev then
    for p in ev:gmatch("[^|]+") do
      local t = p:match("^%s*(.-)%s*$")
      parts[#parts + 1] = t
    end
  end
  return parts
end

-- ctx: { mode, values, tokens, ti } ; returns true on success.
local function nextToken(ctx)
  repeat
    ctx.ti = ctx.ti + 1
  until ctx.tokens[ctx.ti] ~= "-"
  return ctx.tokens[ctx.ti]
end

local function runOps(stream, ops, ctx)
  for _, op in ipairs(ops) do
    if op.type == "object" then
      local obj = {
        serialize = function(self, s)
          return runOps(s, op.inner, ctx)
        end,
      }
      if ctx.mode == "read" then ctx.values[#ctx.values + 1] = "-" end
      if not stream:serializeObject(obj) then return false end
    elseif op.type == "align" then
      if ctx.mode == "read" then ctx.values[#ctx.values + 1] = "-" end
      if not stream:serializeAlign() then return false end
    elseif op.type == "bits" then
      if ctx.mode == "read" then
        local h = { value = false }
        local ok
        if op.n <= 32 then ok = stream:serializeBits(h, op.n) else ok = stream:serializeBits64(h, op.n) end
        if not ok then return false end
        ctx.values[#ctx.values + 1] = h.value
      elseif ctx.mode == "write" then
        local v = limbsToInt(parseNum(nextToken(ctx)))
        local ok
        if op.n <= 32 then ok = stream:serializeBits({ value = v }, op.n) else ok = stream:serializeBits64({ value = v }, op.n) end
        if not ok then return false end
      else
        if not stream:serializeBits({ value = 0 }, op.n) then return false end
      end
    elseif op.type == "bool" then
      if ctx.mode == "read" then
        local h = { value = false }
        if not stream:serializeBool(h) then return false end
        ctx.values[#ctx.values + 1] = h.value
      elseif ctx.mode == "write" then
        if not stream:serializeBool({ value = (nextToken(ctx) == "true") }) then return false end
      else
        if not stream:serializeBool({ value = true }) then return false end
      end
    elseif op.type == "bytes" then
      if ctx.mode == "read" then
        local ok, value = readBytesViaBits(stream, op.n)
        if not ok then return false end
        ctx.values[#ctx.values + 1] = value
      elseif ctx.mode == "write" then
        local tok = nextToken(ctx)
        local bin = {}
        for b in tok:gmatch("%x%x") do bin[#bin + 1] = string.char(tonumber(b, 16)) end
        if not writeBytesViaBits(stream, table.concat(bin)) then return false end
      else
        if not writeBytesViaBits(stream, string.rep("\0", op.n)) then return false end
      end
    end
  end
  return true
end

local function checkSeqAccepted(rec)
  local ops = buildOps(rec.steps)
  -- read
  local rs = ReadStream.new(rec.bytes)
  local ctx = { mode = "read", values = {} }
  local ok = runOps(rs, ops, ctx)
  check(ok == true, "expected accepted sequence: " .. rec.name)
  check(rs:error() == nil, "no error latched: " .. rec.name)
  check(rs:bitsProcessed() == rec.consumed,
    rec.name .. ": consumed " .. tostring(rs:bitsProcessed()) .. ", want " .. tostring(rec.consumed))
  local parts = splitExpect(rec)
  check(#ctx.values == #parts, rec.name .. ": value count")
  for i = 1, #parts do
    local want, got = parts[i], ctx.values[i]
    if got == "-" then
      check(want == "-", rec.name .. ": expect '-' at " .. i)
    elseif type(got) == "boolean" then
      check(want == (got and "true" or "false"), rec.name .. ": bool at " .. i)
    elseif type(got) == "string" then
      check(hexEncode(got) == want, rec.name .. ": bytes at " .. i)
    else
      check(limbsEq(intToLimbs(got), parseNum(want)), rec.name .. ": value at " .. i)
    end
  end
  -- writer canonical
  if rec.writer then
    local ws = WriteStream.new(CAPACITY)
    local wctx = { mode = "write", tokens = splitExpect(rec), ti = 0 }
    local wok = runOps(ws, ops, wctx)
    check(wok == true, "writer failed: " .. rec.name)
    ws:flush()
    check(ws:data() == rec.bytes, "writer bytes mismatch: " .. rec.name)
  end
  -- measure floor
  if rec.measure then
    local ms = MeasureStream.new()
    local mctx = { mode = "measure" }
    check(runOps(ms, ops, mctx), "measure failed: " .. rec.name)
    check(ms:bitsProcessed() >= rec.measure,
      rec.name .. ": measure " .. tostring(ms:bitsProcessed()) .. " < " .. tostring(rec.measure))
  end
end

local function checkSeqRefused(rec)
  local ops = buildOps(rec.steps)
  local rs = ReadStream.new(rec.bytes)
  local ctx = { mode = "read", values = {} }
  local ok = runOps(rs, ops, ctx)
  check(ok == false, "expected refused sequence: " .. rec.name)
  check(rs:error() ~= nil, "refusal must latch: " .. rec.name)
  local before = rs:bitsProcessed()
  local ok2 = rs:serializeBits({ value = false }, 1)
  check(ok2 == false, "terminal: later read must fail: " .. rec.name)
  check(rs:bitsProcessed() == before, "terminal: no bits consumed: " .. rec.name)
end

local function runSeqFile(path)
  local records = loadRecords(path)
  local counts = { accepted = 0, refused = 0 }
  for _, rec in ipairs(records) do
    if isRefused(rec) then
      checkSeqRefused(rec)
      counts.refused = counts.refused + 1
    else
      checkSeqAccepted(rec)
      counts.accepted = counts.accepted + 1
    end
  end
  check(#records == counts.accepted + counts.refused, path .. ": record accounting")
  print("bits: " .. path .. " " .. #records .. " records")
  return #records
end

--------------------------------------------------------------------------------
-- TestSerializeBits
--------------------------------------------------------------------------------

function TestSerializeBits()
  -- conformance, one file at a time; every record must equal the file's count.
  local want = {
    ["conformance/bits.txt"] = 20,
    ["conformance/bool.txt"] = 5,
    ["conformance/uint128.txt"] = 7,
    ["conformance/align.txt"] = 10,
    ["conformance/object.txt"] = 7,
  }
  for path, n in pairs(want) do
    if path == "conformance/object.txt" then
      check(runSeqFile(path) == n, path .. ": record count changed")
    else
      check(runSingleOpFile(path) == n, path .. ": record count changed")
    end
  end

  -- misuse raises, naming the rule (serialize.go's panic strings)
  raises(function() WriteStream.new(64):serializeBits({ value = 1 }, 0) end, "bits must be in [1,32]")
  raises(function() WriteStream.new(64):serializeBits({ value = 1 }, 33) end, "bits must be in [1,32]")
  raises(function() WriteStream.new(64):serializeBits64({ value = 1 }, 65) end, "bits must be in [1,64]")
  raises(function() WriteStream.new(64):serializeBits({ value = 1.0 }, 1) end, "must be an integer")
  raises(function() WriteStream.new(64):serializeBits({ value = 4294967296 }, 1) end, "in [0,4294967295]")
  raises(function() WriteStream.new(64):serializeUint8({ value = 300 }) end, "in [0,255]")
  raises(function() WriteStream.new(64):serializeUint16({ value = -1 }) end, "in [0,65535]")
  raises(function() WriteStream.new(64):serializeUint32({ value = 4294967296 }) end, "in [0,4294967295]")
  raises(function() WriteStream.new(64):serializeBool({ value = 1 }) end, "must be a boolean")
  raises(function() WriteStream.new(64):serializeBits64({ value = 1 }, 0) end, "bits must be in [1,64]")

  -- serialize.go TestContinue (sentinel-driven loop)
  do
    local items = { 10, 20, 30, 40, 50 }
    local ws = WriteStream.new(64)
    local i, hasNext = 0, #items > 0
    while serialize.Continue(ws, { value = hasNext }) do
      i = i + 1
      check(ws:serializeBits({ value = items[i] }, 8), "continue write")
      hasNext = i < #items
    end
    check(ws:error() == nil, "continue write stream ok")
    ws:flush()
    local rs = ReadStream.new(ws:data())
    local read = {}
    hasNext = true
    while serialize.Continue(rs, { value = hasNext }) do
      local h = { value = 0 }
      check(rs:serializeBits(h, 8), "continue read")
      read[#read + 1] = h.value
      hasNext = true
    end
    check(rs:error() == nil, "continue read stream ok")
    check(#read == #items, "continue item count")
    for k = 1, #items do check(read[k] == items[k], "continue value " .. k) end
  end

  -- serialize.go TestUntil (termination bit)
  do
    local items = { 10, 20, 30, 40, 50 }
    local ws = WriteStream.new(64)
    local i, done = 0, #items == 0
    while serialize.Until(ws, { value = done }) do
      i = i + 1
      check(ws:serializeBits({ value = items[i] }, 8), "until write")
      done = i == #items
    end
    check(ws:error() == nil, "until write stream ok")
    ws:flush()
    check(ws:bitsProcessed() == #items * 9 + 1, "until bits written")
    local rs = ReadStream.new(ws:data())
    local read = {}
    done = false
    while serialize.Until(rs, { value = done }) do
      local h = { value = 0 }
      check(rs:serializeBits(h, 8), "until read")
      read[#read + 1] = h.value
      done = false
    end
    check(rs:error() == nil, "until read stream ok")
    check(#read == #items, "until item count")
    for k = 1, #items do check(read[k] == items[k], "until value " .. k) end
  end

  -- MeasureStream bit counts per operation
  do
    local ms = MeasureStream.new()
    check(ms:serializeBits({ value = 255 }, 8), "measure bits")
    check(ms:bitsProcessed() == 8, "measure bits count")
    check(ms:serializeBits64({ value = -1 }, 64), "measure bits64")
    check(ms:bitsProcessed() == 72, "measure bits64 count")
    check(ms:serializeBool({ value = true }), "measure bool")
    check(ms:bitsProcessed() == 73, "measure bool count")
    check(ms:serializeUint8({ value = 255 }), "measure uint8")
    check(ms:serializeUint16({ value = 65535 }), "measure uint16")
    check(ms:serializeUint32({ value = 4294967295 }), "measure uint32")
    check(ms:serializeUint64({ value = -1 }), "measure uint64")
    check(ms:bitsProcessed() == 73 + 8 + 16 + 32 + 64, "measure uint counts")
    check(ms:serializeBits64({ value = -1 }, 64), "measure uint128 low half")
    check(ms:serializeBits64({ value = -1 }, 64), "measure uint128 high half")
    check(ms:bitsProcessed() == 73 + 8 + 16 + 32 + 64 + 128, "measure uint128 count")
    check(ms:serializeAlign(), "measure align")
    check(ms:bitsProcessed() == 73 + 8 + 16 + 32 + 64 + 128 + 7, "measure align count")
    check(ms:error() == nil, "measure never latches")
  end

  -- the api helpers: bitsRequired / bitsRequired64 and the zig-zag pair
  check(serialize.bitsRequired(0, 7) == 3, "bitsRequired(0,7)")
  check(serialize.bitsRequired(0, 8) == 4, "bitsRequired(0,8)")
  check(serialize.bitsRequired(2, 2) == 0, "bitsRequired degenerate")
  check(serialize.bitsRequired(0, 255) == 8, "bitsRequired(0,255)")
  check(serialize.bitsRequired64(0, 255) == 8, "bitsRequired64(0,255)")
  check(serialize.bitsRequired64(-1, 0) == 1, "bitsRequired64 unsigned diff")
  check(serialize.bitsRequired64(0, -1) == 64, "bitsRequired64(0,uint64 max)")
  local zz = function(n) return serialize.unsignedToSigned(serialize.signedToUnsigned(n)) end
  local conv = { 0, -1, 1, -2, 2, 2147483647, -2147483648 }
  for _, n in ipairs(conv) do
    check(zz(n) == n, "zig-zag round trip " .. n)
  end
  check(serialize.signedToUnsigned(-1) == 1, "signedToUnsigned(-1)")
  check(serialize.signedToUnsigned(0) == 0, "signedToUnsigned(0)")
  check(serialize.unsignedToSigned(1) == -1, "unsignedToSigned(1)")
  check(serialize.unsignedToSigned(0) == 0, "unsignedToSigned(0)")
end
