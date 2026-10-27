-- test/reject: the caller's own refusal, `rejected` (STANDARD.md 2.1,
-- "Refusal reasons"; IMPLEMENTING.md U2). Run by `make test T=reject` from the
-- repository root. Pins: the reason's name; stream:reject() on a read stream
-- latches it and returns false; a nested object whose callback refuses with
-- nothing latched latches it; both are terminal and the first reason wins;
-- reject is read only. Unit tests: no real time, no sockets, no files.

local serialize = require("serialize")
local Refusal = serialize.Refusal

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local function raises(fn, want)
  local ok, err = pcall(fn)
  check(not ok, "expected a raise containing: " .. want)
  check(string.find(tostring(err), want, 1, true) ~= nil,
    "raise was \"" .. tostring(err) .. "\", wanted it to contain \"" .. want .. "\"")
end

local SENTINEL = {}

-- terminal(rs, reason): every later read refuses, consumes nothing, writes
-- nothing, runs no callback, and the reason stays.
local function terminal(rs, reason, what)
  local before = rs:bitsProcessed()
  local h = { value = SENTINEL }
  check(rs:serializeBits(h, 8) == false and h.value == SENTINEL, what .. ": a read after it was accepted")
  local called = false
  check(rs:serializeObject({ serialize = function() called = true; return true end }) == false and not called,
    what .. ": an object after it was accepted or ran its callback")
  check(rs:serializeAlign() == false and rs:serializeEnd() == false, what .. ": align or end after it was accepted")
  check(rs:reject() == false, what .. ": a reject after it did not answer false")
  check(rs:bitsProcessed() == before, what .. ": the failed stream consumed bits")
  check(rs:error() == reason, what .. ": the reason changed to " .. tostring(rs:error()))
  check(not rs:ok(), what .. ": the failed stream reports ok")
end

function TestRejectedName()
  check(Refusal.Rejected == "rejected", "Refusal.Rejected is spelled as STANDARD.md spells it")
end

function TestReadStreamReject()
  local rs = serialize.ReadStream.new("\5")
  local h = { value = SENTINEL }
  check(rs:serializeBits(h, 4) and h.value == 5, "the four well formed bits are accepted")
  check(rs:reject() == false, "reject returns false")
  check(rs:error() == Refusal.Rejected, "reject latches rejected, got " .. tostring(rs:error()))
  terminal(rs, Refusal.Rejected, "top-level reject")
end

function TestRejectKeepsTheFirstReason()
  -- past_end first, then the caller rejects: the wire's reason stays
  local rs = serialize.ReadStream.new("\255")
  check(rs:serializeBits({ value = SENTINEL }, 16) == false, "a read past the end refuses")
  check(rs:reject() == false, "reject on a failed stream returns false")
  check(rs:error() == Refusal.PastEnd, "the first reason wins, got " .. tostring(rs:error()))
end

function TestObjectCallbackRefusalLatchesRejected()
  local rs = serialize.ReadStream.new("\5")
  local inner = { value = SENTINEL }
  local ok = rs:serializeObject({ serialize = function(_, s)
    if not s:serializeBits(inner, 4) then return false end
    return false
  end })
  check(ok == false, "an object whose callback refuses is refused")
  check(inner.value == 5, "the object's field read before it refused")
  check(rs:error() == Refusal.Rejected, "the object latched rejected, got " .. tostring(rs:error()))
  terminal(rs, Refusal.Rejected, "object rejection")
end

function TestObjectKindOutsideTheListIsRejected()
  for _, kind in ipairs({ "bad_value", 42, true }) do
    local rs = serialize.ReadStream.new("")
    check(rs:serializeObject({ serialize = function() return false, kind end }) == false,
      "an object refusing with kind " .. tostring(kind) .. " is refused")
    check(rs:error() == Refusal.Rejected, "a kind outside the list latches rejected, got " .. tostring(rs:error()))
  end
  -- a kind from the closed list is latched as given
  local rs = serialize.ReadStream.new("")
  check(rs:serializeObject({ serialize = function() return false, Refusal.ValueOutOfRange end }) == false,
    "an object refusing with a listed kind is refused")
  check(rs:error() == Refusal.ValueOutOfRange, "a listed kind is latched as given")
end

function TestObjectCallbackKeepsTheFirstReason()
  local rs = serialize.ReadStream.new("\255")
  check(rs:serializeObject({ serialize = function(_, s)
    s:serializeBits({ value = SENTINEL }, 16)
    return false
  end }) == false, "the object refuses")
  check(rs:error() == Refusal.PastEnd, "the primitive's reason is kept, got " .. tostring(rs:error()))
  -- a nested reject inside an object is one latch too
  local rs2 = serialize.ReadStream.new("\0")
  check(rs2:serializeObject({ serialize = function(_, s) return s:reject() end }) == false, "the object refuses")
  check(rs2:error() == Refusal.Rejected, "a reject inside an object latches rejected")
end

function TestObjectAcceptedWhenTheCallbackDoesNotReject()
  local rs = serialize.ReadStream.new("\26")
  local a, b = { value = SENTINEL }, { value = SENTINEL }
  check(rs:serializeObject({ serialize = function(_, s)
    return s:serializeBits(a, 4) and s:serializeBool(b)
  end }) == true, "the object is accepted")
  check(a.value == 10 and b.value == true and rs:error() == nil, "its fields decode and nothing latched")
end

function TestRejectIsReadOnly()
  raises(function() serialize.WriteStream.new(8):reject() end, "serialize: reject is read only")
  raises(function() serialize.MeasureStream.new():reject() end, "serialize: reject is read only")
end

function TestResetClearsRejected()
  local rs = serialize.ReadStream.new("\1")
  rs:reject()
  rs:reset("\1")
  local h = { value = SENTINEL }
  check(rs:error() == nil and rs:serializeBits(h, 8) and h.value == 1, "reset clears the rejection")
end
