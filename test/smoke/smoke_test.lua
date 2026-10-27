-- test/smoke: the skeleton every family card stands on (DESIGN.md (h), (i)).
-- Run by `make test T=smoke` from the repository root. Pins: the entry loads;
-- every API name DESIGN.md (a) lists exists; a family whose file is absent
-- raises "serialize: <name> not implemented"; the latch holds and is terminal
-- (STANDARD.md, Reader Obligations, "Failure is terminal"); loading is closed
-- (DESIGN.md (f)). No real time, no sockets, no network: io only reads
-- DESIGN.md and plants and removes two shadow files inside the checkout.

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local function raises(fn, want)
  local ok, err = pcall(fn)
  check(not ok, "expected a raise containing: " .. want)
  check(string.find(tostring(err), want, 1, true) ~= nil,
    "raise was \"" .. tostring(err) .. "\", wanted it to contain \"" .. want .. "\"")
end

-- The test-only families. No card creates serialize_smoke_absent.lua; the probe
-- family exists only through package.preload, inside this process.
local ABSENT = "smoke_absent"
local PROBE = "smoke_probe"

local function installProbe()
  package.preload["serialize_" .. PROBE] = function()
    return {
      methods = {
        serializeProbe = {
          check = function(bits)
            if math.type(bits) ~= "integer" or bits < 1 or bits > 64 then
              error("serialize: probe bits must be in [1,64]", 0)
            end
          end,
          write = function(s, value, bits) return s:_writeBits(value, bits) end,
          read = function(s, bits)
            local v = s:_readBits(bits)
            if v == nil then return false end
            return true, v
          end,
          measure = function(s, _value, bits) return s:_measure(bits) end,
        },
        serializeTyped = {
          checkValue = function(value)
            if math.type(value) ~= "integer" then error("serialize: probe value must be an integer", 0) end
          end,
          write = function(s, value) return s:_writeBits(value, 1) end,
          read = function(_s) return false end,
          measure = function(s, _value) return s:_measure(1) end,
        },
        serializeLiar = {
          write = function() return false end,
          read = function() return true, 1 end,
          measure = function() return "yes" end,
        },
      },
    }
  end
end

function TestSmoke()
  -- 1. the entry loads, and it is closed: nothing global is created by loading it
  local before = {}
  for k in pairs(_G) do before[k] = true end
  local serialize = require("serialize")
  local S = require("serialize_stream")
  check(type(serialize) == "table", "require(\"serialize\") must return the API table")
  check(type(S) == "table", "require(\"serialize_stream\") must return the stream module")
  for k in pairs(_G) do check(before[k], "loading serialize created the global " .. tostring(k)) end

  -- 2. every API name DESIGN.md (a) lists exists
  local f = assert(io.open("DESIGN.md", "r"))
  local design = f:read("a")
  f:close()
  local entryNames, streamNames = 0, 0
  local streams = {
    W = serialize.WriteStream.new(8),
    R = serialize.ReadStream.new(""),
    M = serialize.MeasureStream.new(),
  }
  for line in design:gmatch("[^\n]+") do
    local path = line:match("^| `serialize%.([%w_%.]+)")
    if path then
      local v = serialize
      for part in path:gmatch("[^%.]+") do
        check(type(v) == "table", "serialize." .. path .. ": a parent of " .. part .. " is not a table")
        v = v[part]
      end
      check(v ~= nil, "DESIGN.md lists serialize." .. path .. " and the entry has no such name")
      entryNames = entryNames + 1
    end
    local method, kinds = line:match("^| `stream:([%w_]+)%(.-%)` | ([WRM ]+) |")
    if method then
      for k in kinds:gmatch("[WRM]") do
        check(type(streams[k][method]) == "function",
          "DESIGN.md lists stream:" .. method .. " on " .. k .. " and that stream has no such method")
      end
      streamNames = streamNames + 1
    end
  end
  check(entryNames >= 40, "DESIGN.md (a) lists only " .. entryNames .. " serialize.* names; the parse found too few")
  check(streamNames >= 30, "DESIGN.md (a) lists only " .. streamNames .. " stream methods; the parse found too few")
  check(streams.W:isWriting() and not streams.W:isReading(), "WriteStream is writing")
  check(streams.R:isReading() and not streams.R:isWriting(), "ReadStream is reading")
  check(streams.M:isWriting() and not streams.M:isReading(), "MeasureStream is writing")

  -- 3. lazy dispatch: a family whose file is absent raises its not-implemented
  -- error by name, on every stream, through the same maker every real method uses
  local absent = S.method(ABSENT, "serializeSmokeAbsent", 1)
  raises(function() absent.write(streams.W, { value = 1 }, 1) end, "serialize: serializeSmokeAbsent not implemented")
  raises(function() absent.read(streams.R, { value = 1 }, 1) end, "serialize: serializeSmokeAbsent not implemented")
  raises(function() absent.measure(streams.M, { value = 1 }, 1) end, "serialize: serializeSmokeAbsent not implemented")
  local absentApi = S.lazy(ABSENT, "smokeAbsentFunction")
  raises(function() absentApi(1) end, "serialize: smokeAbsentFunction not implemented")
  check(package.loaded["serialize_" .. ABSENT] == nil, "an absent family must not be marked loaded")
  -- a present family without the arm raises the same way
  installProbe()
  local missing = S.method(PROBE, "serializeNoSuchArm", 1)
  raises(function() missing.write(streams.W, { value = 1 }) end, "serialize: serializeNoSuchArm not implemented")
  -- a holder is a table; misuse raises before anything else
  local probe = S.method(PROBE, "serializeProbe", 1)
  raises(function() probe.write(streams.W, 1, 1) end, "serialize: serializeProbe takes a holder")
  raises(function() probe.read(streams.R, { value = 0 }, 0) end, "serialize: probe bits must be in [1,64]")

  -- 4. the latch: on a ReadStream over empty data a failing call latches; a later
  -- call fails, consumes nothing and leaves its holder unchanged; the first error
  -- sticks; zero-bit operations refuse too; reset clears it.
  local rs = serialize.ReadStream.new("")
  check(rs:ok() and rs:error() == nil, "a new ReadStream is healthy")
  local holder = { value = 42 }
  check(probe.read(rs, holder, 1) == false, "reading 1 bit of empty data fails")
  check(rs:error() == serialize.Refusal.PastEnd, "the failure latches past_end, got " .. tostring(rs:error()))
  check(holder.value == 42, "a refused read leaves its holder unchanged")
  check(rs:bitsProcessed() == 0, "a refused read consumes nothing")
  rs:_fail(serialize.Refusal.NonzeroPadding)
  check(rs:error() == serialize.Refusal.PastEnd, "the first error sticks")
  check(probe.read(rs, holder, 1) == false and holder.value == 42, "a later call fails and leaves its holder unchanged")
  check(rs:serializeAlign() == false, "align on an aligned but failed stream refuses")
  local called = false
  local object = { serialize = function() called = true; return true end }
  check(rs:serializeObject(object) == false and not called, "object refuses on a failed stream without calling it")
  check(rs:bitsProcessed() == 0 and rs:bytesProcessed() == 0, "a failed stream consumed nothing")
  check(rs:_readBits(1) == nil, "the read primitive refuses on a failed stream")
  -- a byte count too large to multiply by 8 still refuses as past_end (the bounds
  -- test is made in bytes, as serialize.go makes it) rather than wrapping
  local brs = serialize.ReadStream.new("")
  check(brs:_readBytes(1 << 61) == nil and brs:error() == serialize.Refusal.PastEnd,
    "a huge byte count latches past_end")
  rs:reset("")
  check(rs:ok(), "reset clears the latch")

  -- the write side: a write past the end latches past_end and writes nothing
  local ws = serialize.WriteStream.new(0)
  check(probe.write(ws, { value = 1 }, 1) == false, "writing to a zero-capacity stream fails")
  check(ws:error() == serialize.Refusal.PastEnd, "the write failure latches past_end")
  check(ws:bitsProcessed() == 0 and ws:data() == "", "a refused write writes nothing")
  check(ws:serializeAlign() == false, "align refuses on a failed write stream")
  raises(function() serialize.WriteStream.new(7) end, "serialize: bit writer buffer size must be a multiple of 8 bytes")

  -- the measure side counts, and its latch holds too
  local ms = serialize.MeasureStream.new()
  check(probe.measure(ms, { value = 0 }, 13) == true and ms:bitsProcessed() == 13, "measure counts bits")
  check(ms:alignBits() == 7 and ms:serializeAlign() and ms:bitsProcessed() == 20, "measure charges an align 7 bits")
  check(ms:bytesProcessed() == 3, "measure rounds up to a byte")
  check(ms:serializeObject({ serialize = function() return false end }) == false, "an object that fails fails the stream")
  check(ms:error() == serialize.Refusal.Rejected, "an object failing without a kind latches rejected")
  check(probe.measure(ms, { value = 0 }, 1) == false and ms:bitsProcessed() == 20, "a failed measure counts nothing")

  -- the arm contract guard: an arm that lies about its result raises by name
  local liar = S.method(PROBE, "serializeLiar", 1)
  raises(function() liar.write(serialize.WriteStream.new(8), { value = 0 }) end, "serialize: serializeLiar returned false without latching")
  raises(function() liar.measure(serialize.MeasureStream.new(), { value = 0 }) end, "serialize: serializeLiar arm must return a boolean")
  local lrs = serialize.ReadStream.new("")
  lrs:_fail(serialize.Refusal.PastEnd)
  check(liar.read(lrs, { value = 0 }) == false, "a failed stream never reaches the arm")

  -- a value check (checkValue) raises on write and measure on a failed stream
  -- too: misuse raises on a healthy stream and a failed one alike (DESIGN.md (g))
  local typed = S.method(PROBE, "serializeTyped", 1)
  raises(function() typed.write(ws, { value = 1.0 }) end, "serialize: probe value must be an integer")
  raises(function() typed.measure(ms, { value = "x" }) end, "serialize: probe value must be an integer")
  check(typed.write(ws, { value = 1 }) == false, "a well-typed value on a failed stream fails without raising")

  -- Continue and Until fold the latch into the loop condition (serialize.go): a
  -- stream whose serializeBool fails stops the loop at once, whatever the holder
  -- says. A stand-in stream, so the test stays green before serialize_bits.lua lands.
  local failing = { serializeBool = function() return false end }
  local loops = 0
  while serialize.Continue(failing, { value = true }) do loops = loops + 1; check(loops < 2, "Continue spun") end
  while serialize.Until(failing, { value = false }) do loops = loops + 1; check(loops < 2, "Until spun") end
  check(loops == 0, "Continue and Until stop at once when serializeBool fails")
  local passing = { serializeBool = function() return true end }
  check(serialize.Continue(passing, { value = true }) == true and serialize.Continue(passing, { value = false }) == false,
    "Continue proceeds on a continuation bit")
  check(serialize.Until(passing, { value = false }) == true and serialize.Until(passing, { value = true }) == false,
    "Until proceeds until a termination bit")

  -- context is kept across reset (serialize.go: "The context is kept")
  ws:setContext("ctx")
  ws:reset(8)
  check(ws:context() == "ctx" and ws:ok(), "reset clears the latch and keeps the context")

  -- 5. loading is closed: package.path is replaced, package.cpath is empty, and a
  -- shadowing serialize_stream.lua in the working directory (which is also one
  -- level above src) and in this test's own directory is never loaded.
  check(package.cpath == "", "package.cpath must be empty, got \"" .. package.cpath .. "\"")
  check(package.path == "./src/?.lua", "package.path must be exactly ./src/?.lua, got \"" .. package.path .. "\"")
  check(package.searchpath("serialize_stream", package.path) == "./src/serialize_stream.lua", "serialize_stream resolves to src/")
  local shadows = { "./serialize_stream.lua", "./test/smoke/serialize_stream.lua" }
  for _, p in ipairs(shadows) do
    check(io.open(p, "r") == nil, p .. " already exists; the test will not overwrite it")
  end
  local savedEntry, savedStream = package.loaded["serialize"], package.loaded["serialize_stream"]
  local ok, err = pcall(function()
    for _, p in ipairs(shadows) do
      local w = assert(io.open(p, "w"))
      w:write("error(\"SHADOW LOADED: " .. p .. "\")\n")
      w:close()
    end
    -- the shadow would raise if it were loaded, and a default-style path finds it
    for _, p in ipairs(shadows) do
      raises(function() dofile(p) end, "SHADOW LOADED: " .. p)
    end
    check(package.searchpath("serialize_stream", "./?.lua;./test/smoke/?.lua") == "./serialize_stream.lua",
      "the planted shadow is where an unreplaced path would look")
    -- a fresh load of the entry and the stream module never reaches a shadow
    package.loaded["serialize"] = nil
    package.loaded["serialize_stream"] = nil
    local fresh = require("serialize")
    check(type(fresh) == "table" and type(fresh.WriteStream.new) == "function", "a fresh load succeeds")
    check(package.loaded["serialize_stream"] ~= nil, "the fresh load required serialize_stream")
  end)
  for _, p in ipairs(shadows) do os.remove(p) end
  package.loaded["serialize"], package.loaded["serialize_stream"] = savedEntry, savedStream
  package.preload["serialize_" .. PROBE] = nil
  for _, p in ipairs(shadows) do check(io.open(p, "r") == nil, p .. " was not removed") end
  if not ok then error(err, 0) end
end
