-- test/strings: the string family's conformance test (card serialize-lua-strings).
-- Run by `make test T=strings` from the repository root. Runs every record of
-- conformance/bytes.txt and string.txt through the shared runner (the reader
-- leg on every vector with its stated refusal reason, the writer leg on the
-- `writer = canonical` ones), and the record count per file. Plus the format
-- 2.0 string rules with their reversed witnesses: a NUL is embedded_nul BEFORE
-- the encoding is checked, an ill-formed payload is invalid_utf8, real text
-- round trips byte for byte, a wire-claimed length is checked against what
-- remains before anything is taken, and serialize.go's
-- TestWideStringLengthValidatedBeforeNarrowing string case. wstring is gone
-- (STANDARD.md, "Format version"): the stream has no serializeWideString.
-- No real time, no sockets, no network: io reads only the vendored corpus.

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

local serialize = require("serialize")
local C = assert(loadfile("test/conformance/conformance_test.lua"))()

local Refusal = serialize.Refusal

-- readString(bytes, bufferSize): ok, the stream's reason, the destination.
local function readString(bytes, bufferSize)
  local rs = serialize.ReadStream.new(bytes)
  local h = { value = "untouched" }
  local ok = rs:serializeString(h, bufferSize)
  return ok, rs:error(), h.value, rs
end

-- stringBytes(payload, bufferSize): the wire bytes of a string field, built
-- with the bit primitives so a payload no writer would emit can be framed.
local function stringBytes(payload, bufferSize)
  local ws = serialize.WriteStream.new(64)
  local w = serialize.bitsRequired(0, bufferSize - 1)
  if w > 0 then check(ws:serializeBits({ value = #payload }, w)) end
  check(ws:serializeAlign())
  check(ws:serializeBytes({ value = payload }, #payload))
  ws:flush()
  return ws:data()
end

local function testRefusalReasons()
  -- a NUL anywhere is embedded_nul, and it wins over an encoding error in the
  -- same payload (STANDARD.md, string: the NUL scan runs over the whole
  -- payload first). Reversed witness: a reader that validates UTF-8 first
  -- reports invalid_utf8 for FF 00.
  for _, payload in ipairs({ "\0", "\0A", "A\0B", "AB\0", "\xFF\0", "\0\xFF" }) do
    local ok, err, value = readString(stringBytes(payload, 16), 16)
    check(not ok and err == Refusal.EmbeddedNul and value == "untouched",
      "a payload with a NUL is embedded_nul, got " .. tostring(err))
  end
  -- the same bytes without the NUL: FF alone is invalid_utf8, A B is accepted
  local ok, err = readString(stringBytes("\xFF", 16), 16)
  check(not ok and err == Refusal.InvalidUtf8, "FF is invalid_utf8, got " .. tostring(err))
  for _, payload in ipairs({ "\xC0\xAF", "\xED\xA0\x80", "\xF4\x90\x80\x80", "\xE2\x82", "\x80" }) do
    ok, err = readString(stringBytes(payload, 16), 16)
    check(not ok and err == Refusal.InvalidUtf8, "ill-formed payload is invalid_utf8, got " .. tostring(err))
  end
  ok, err = readString(stringBytes("AB", 16), 16)
  check(ok and err == nil, "the payload without the NUL is accepted")
  -- the length past the buffer is value_out_of_range; set align padding
  -- before a truncated payload is nonzero_padding, never past_end
  ok, err = readString("\x07", 5)
  check(not ok and err == Refusal.ValueOutOfRange, "length 7 in a buffer of 5, got " .. tostring(err))
  ok, err = readString("\xFF", 16)
  check(not ok and err == Refusal.NonzeroPadding, "padding before a truncated payload, got " .. tostring(err))
end

-- Real text round trips byte for byte: no normalization, no BOM stripping, no
-- replacement, every plane (STANDARD.md, string, "Validation refuses illegal
-- byte sequences, and never a real character").
local function testRealText()
  local texts = {
    "\u{570D}\u{68CB}",                -- CJK
    "\u{BC14}\u{B451}",                -- Korean
    "\u{0646}\u{0631}\u{062F}",        -- Arabic, right to left
    "e\u{0301}",                       -- combining acute, not normalized
    "\u{00E9}",                        -- precomposed
    "\u{FEFF}go",                      -- byte order mark kept
    "\u{FFFF}",                        -- noncharacter kept
    "\u{1F600}",                       -- emoji
    "\u{20000}",                       -- CJK Extension B
    "\u{10FFFF}",                      -- the highest code point
  }
  for _, text in ipairs(texts) do
    local ws = serialize.WriteStream.new(64)
    check(ws:serializeString({ value = text }, 32), "write " .. text)
    check(ws:serializeEnd(), "end")
    ws:flush()
    local rs = serialize.ReadStream.new(ws:data())
    local h = {}
    check(rs:serializeString(h, 32) and rs:serializeEnd(), "read " .. text .. ": " .. tostring(rs:error()))
    check(h.value == text, "text changed in the round trip")
  end
end

-- Allocate before check (PORT-BRIEF, 2026-10-22): the wire-claimed length is
-- checked against the bytes that remain BEFORE anything is taken, so a tiny
-- stream claiming a huge string is refused as past_end at once. _readBytes
-- compares the count with what remains, in bytes, before it reads.
local function testClaimedLengthCheckedFirst()
  local bufferSize = (1 << 31) - 1 -- the largest legal buffer: a 31-bit length field
  local ws = serialize.WriteStream.new(8)
  check(ws:serializeBits({ value = bufferSize - 1 }, 31))
  ws:flush()
  local data = ws:data() -- four bytes: the length, then the align's padding
  check(#data == 4, "the claim is four bytes")
  local ok, err, value = readString(data, bufferSize)
  check(not ok and err == Refusal.PastEnd and value == "untouched",
    "a four-byte stream claiming 2^31 - 2 bytes is past_end, got " .. tostring(err))
  -- bytes: a count past what remains is past_end, with the same order
  local rs = serialize.ReadStream.new("\0\0\0\0")
  local h = { value = "untouched" }
  check(rs:serializeBytes(h, 1 << 40) == false and rs:error() == Refusal.PastEnd and h.value == "untouched",
    "bytes claiming 2^40 is past_end")
end

-- serialize.go TestWideStringLengthValidatedBeforeNarrowing, the string case:
-- a length equal to bufferSize is write misuse (the terminator has nowhere to
-- go), and traps (IMPLEMENTING.md U9); one less fits.
local function testStringLengthOnWrite()
  local ws = serialize.WriteStream.new(64)
  local ok, err = pcall(ws.serializeString, ws, { value = "ABC" }, 3)
  check(not ok, "string length equals bufferSize traps")
  check(string.find(tostring(err), "write misuse (IMPLEMENTING.md U9): " .. Refusal.ValueOutOfRange, 1, true),
    "the trap names value_out_of_range: " .. tostring(err))
  check(ws:error() == nil, "a trapped write latches nothing")
  check(ws:bitsProcessed() == 0, "a trapped write writes nothing")
  local ws2 = serialize.WriteStream.new(64)
  check(ws2:serializeString({ value = "AB" }, 3), "string length one less fits")
end

function TestSerializeStrings()
  local files = {
    { "conformance/bytes.txt", 12 },
    { "conformance/string.txt", 53 },
  }
  for _, pair in ipairs(files) do
    local path, want = pair[1], pair[2]
    local records = C.parseVectors(path)
    local base = path:match("([^/]+)$")
    print(base .. ": " .. #records .. " records")
    check(#records == want, base .. " record count " .. #records .. " want " .. want)
    for _, r in ipairs(records) do C.runRecord(r) end
  end
  check(serialize.WriteStream.new(8).serializeWideString == nil, "wstring is removed from the write stream")
  check(serialize.ReadStream.new("").serializeWideString == nil, "wstring is removed from the read stream")
  check(serialize.MeasureStream.new().serializeWideString == nil, "wstring is removed from the measure stream")
  testRefusalReasons()
  testRealText()
  testClaimedLengthCheckedFirst()
  testStringLengthOnWrite()
end
