# serialize.lua — the design

This page is the design every card of the `serialize-lua` stream copies. It
was written by the design card (serialize-lua-design) with the skeleton it
describes: `src/serialize.lua` (the entry), `src/serialize_stream.lua` (the
three streams), the `Makefile` and its runner, and `test/smoke/`. Every later
card creates ONE family file named in (h), and its own `test/<card>/`
directory, and needs to decide nothing that is decided here.

**The sources.** The wire is [STANDARD.md](STANDARD.md), format version 1.1,
and the corpus is [conformance/](conformance/); both are vendored VERBATIM from
[mas-bandwidth/serialize](https://github.com/mas-bandwidth/serialize) at tag
`v1.17.0` (commit `56a1b590af81`). They are the same bytes as
[serialize.go](https://github.com/mas-bandwidth/serialize.go) `v1.15.1`'s
copies (commit `963f6dfe2327`): `diff -r conformance/ <serialize v1.17.0>/conformance/`,
`diff -r conformance/ <serialize.go v1.15.1>/conformance/` and
`diff STANDARD.md <serialize.go v1.15.1>/STANDARD.md` are all empty
(checked on hetzner2, 2026-10-17, 18 corpus files). Where STANDARD.md is
silent, serialize.go v1.15.1 is the reference for behaviour and the C++
library breaks a tie (STANDARD.md, Implementation Law, "Sources");
[serialize.js](https://github.com/mas-bandwidth/serialize.js) (commit
`ff765a1a89a8`) is the worked example for SPELLING only. Both are read, never
imported. The number model, byte buffers, float32 rule and loading rule are
mas-bandwidth/schema's `docs/PORT-LUA.md` (branch
`sprint/schema-lua-port-design.w1.g1.e21`, commit `de38f658b5dd`), restated in
(c) to (f) with no change of substance, so schema's Lua leg vendors these files
unchanged.

**The oracle.** Every family card matches serialize's own vectors byte for
byte: the corpus in `conformance/*.txt` (read by the test itself through `io`),
and the C++ and Go test vectors the card's family has (`.ref/serialize/test.cpp`,
`.ref/serialize.go/*_test.go`), cited by test name.

**The interpreter.** PUC-Rio Lua 5.4.8, built from source by `make dist-lua`
(the pin, URL and sha256 are schema's `make/lua.mk`'s). Libraries considered:
only what the pinned interpreter ships (`string`, `table`, `math`, `utf8`, and
`io` in tests). Nothing added.

## (a) THE API

Every type, function and stream method serialize.go v1.15.1 exports, in
serialize.js's spelling (`src/index.js`, `src/streams.js`). A value travels in
a HOLDER, `{ value = ... }`, exactly as serialize.js's ref objects: on write
and measure `holder.value` is consumed; on read it is assigned on success and
left unmodified on failure. Every serialize call returns a boolean. The first
error latches on the stream; every later call fails, consumes nothing and
writes nothing to its destination (STANDARD.md, Reader Obligations, "Failure
is terminal"). `test/smoke` parses the two tables below and checks every name
exists, so a row added here is a row the skeleton must carry.

### The entry: `local serialize = require("serialize")`

| name | file (card) | serialize.go |
|---|---|---|
| `serialize.SerializeError` | serialize_stream.lua (design) | the error kinds, below |
| `serialize.SerializeError.Overflow` | serialize_stream.lua (design) | `ErrOverflow` |
| `serialize.SerializeError.ValueOutOfRange` | serialize_stream.lua (design) | `ErrValueOutOfRange` |
| `serialize.SerializeError.Align` | serialize_stream.lua (design) | `ErrAlign` |
| `serialize.WriteStream.new(capacity)` | serialize_stream.lua (design) | `NewWriteStream(buffer)` |
| `serialize.ReadStream.new(data)` | serialize_stream.lua (design) | `NewReadStream(data)` |
| `serialize.MeasureStream.new()` | serialize_stream.lua (design) | `NewMeasureStream()` |
| `serialize.Continue(stream, holder)` | serialize.lua (design) | `Continue(stream, more)` |
| `serialize.Until(stream, holder)` | serialize.lua (design) | `Until(stream, done)` |
| `serialize.BitWriter.new(capacity)` | serialize_bitpacker.lua (bitpacker) | `NewBitWriter(buffer)` |
| `serialize.BitReader.new(data)` | serialize_bitpacker.lua (bitpacker) | `NewBitReader(data)` |
| `serialize.bitsRequired(min, max)` | serialize_bits.lua (bits) | `BitsRequired` |
| `serialize.bitsRequired64(min, max)` | serialize_bits.lua (bits) | `BitsRequired64` |
| `serialize.signedToUnsigned(n)` | serialize_bits.lua (bits) | `SignedToUnsigned` |
| `serialize.unsignedToSigned(n)` | serialize_bits.lua (bits) | `UnsignedToSigned` |
| `serialize.bitsRequired128(min, max)` | serialize_int128.lua (int) | `BitsRequired128` |
| `serialize.compressedFloatParams(min, max, resolution)` | serialize_compressed_float.lua (compressed-float) | `CompressedFloatParams`: returns `maxIntegerValue, bits, delta` |
| `serialize.Uint128.from64(x)` | serialize_int128.lua (int) | `Uint128From64` |
| `serialize.Uint128.uint64(v)` | serialize_int128.lua (int) | `Uint128.Uint64` |
| `serialize.Uint128.int128(v)` | serialize_int128.lua (int) | `Uint128.Int128` |
| `serialize.Uint128.isZero(v)` | serialize_int128.lua (int) | `Uint128.IsZero` |
| `serialize.Uint128.len(v)` | serialize_int128.lua (int) | `Uint128.Len` |
| `serialize.Uint128.cmp(a, b)` | serialize_int128.lua (int) | `Uint128.Cmp` |
| `serialize.Uint128.add(a, b)` | serialize_int128.lua (int) | `Uint128.Add` |
| `serialize.Uint128.sub(a, b)` | serialize_int128.lua (int) | `Uint128.Sub` |
| `serialize.Uint128.mul(a, b)` | serialize_int128.lua (int) | `Uint128.Mul` |
| `serialize.Uint128.divMod(a, b)` | serialize_int128.lua (int) | `Uint128.DivMod`: returns `quotient, remainder` |
| `serialize.Uint128.div(a, b)` | serialize_int128.lua (int) | `Uint128.Div` |
| `serialize.Uint128.mod(a, b)` | serialize_int128.lua (int) | `Uint128.Mod` |
| `serialize.Uint128.neg(v)` | serialize_int128.lua (int) | `Uint128.Neg` |
| `serialize.Uint128.bnot(v)` | serialize_int128.lua (int) | `Uint128.Not` |
| `serialize.Uint128.band(a, b)` | serialize_int128.lua (int) | `Uint128.And` |
| `serialize.Uint128.bor(a, b)` | serialize_int128.lua (int) | `Uint128.Or` |
| `serialize.Uint128.bxor(a, b)` | serialize_int128.lua (int) | `Uint128.Xor` |
| `serialize.Uint128.lsh(v, n)` | serialize_int128.lua (int) | `Uint128.Lsh` |
| `serialize.Uint128.rsh(v, n)` | serialize_int128.lua (int) | `Uint128.Rsh` |
| `serialize.Int128.from64(x)` | serialize_int128.lua (int) | `Int128From64` |
| `serialize.Int128.int64(v)` | serialize_int128.lua (int) | `Int128.Int64` |
| `serialize.Int128.uint128(v)` | serialize_int128.lua (int) | `Int128.Uint128` |
| `serialize.Int128.isNegative(v)` | serialize_int128.lua (int) | `Int128.IsNegative` |
| `serialize.Int128.cmp(a, b)` | serialize_int128.lua (int) | `Int128.Cmp` |
| `serialize.Int128.add(a, b)` | serialize_int128.lua (int) | `Int128.Add` |
| `serialize.Int128.sub(a, b)` | serialize_int128.lua (int) | `Int128.Sub` |
| `serialize.Int128.mul(a, b)` | serialize_int128.lua (int) | `Int128.Mul` |
| `serialize.Int128.divMod(a, b)` | serialize_int128.lua (int) | `Int128.DivMod`: truncating, returns `quotient, remainder` |
| `serialize.Int128.div(a, b)` | serialize_int128.lua (int) | `Int128.Div` |
| `serialize.Int128.mod(a, b)` | serialize_int128.lua (int) | `Int128.Mod` |
| `serialize.Int128.neg(v)` | serialize_int128.lua (int) | `Int128.Neg` |
| `serialize.Int128.bnot(v)` | serialize_int128.lua (int) | `Int128.Not` |
| `serialize.Int128.band(a, b)` | serialize_int128.lua (int) | `Int128.And` |
| `serialize.Int128.bor(a, b)` | serialize_int128.lua (int) | `Int128.Or` |
| `serialize.Int128.bxor(a, b)` | serialize_int128.lua (int) | `Int128.Xor` |
| `serialize.Int128.lsh(v, n)` | serialize_int128.lua (int) | `Int128.Lsh` |
| `serialize.Int128.rsh(v, n)` | serialize_int128.lua (int) | `Int128.Rsh` (arithmetic) |

serialize.go's types map as: `Stream` is any of the three stream objects (one
serialize function written against the methods below handles all three);
`Serializer` is any table with a `serialize(self, stream)` method that returns
`true` on success, or `false` and optionally an error kind; `Uint128` and
`Int128` are `{ lo = <low 64>, hi = <high 64> }` (see (c)).

### The stream methods: `stream:<method>(...)`

The second column names the streams that carry the method: W WriteStream, R
ReadStream, M MeasureStream.

| method | streams | serialize.go | file (card) |
|---|---|---|---|
| `stream:reset(...)` | W R M | `Reset` — W takes `capacity`, R takes `data`, M nothing; clears the latch, keeps the context | serialize_stream.lua (design) |
| `stream:isWriting()` | W R M | `IsWriting` | serialize_stream.lua (design) |
| `stream:isReading()` | W R M | `IsReading` | serialize_stream.lua (design) |
| `stream:serializeBits(holder, bits)` | W R M | `SerializeBits`, bits in [1,32] | serialize_bits.lua (bits) |
| `stream:serializeBits64(holder, bits)` | W R M | `SerializeBits64`, bits in [1,64] | serialize_bits.lua (bits) |
| `stream:serializeBool(holder)` | W R M | `SerializeBool` | serialize_bits.lua (bits) |
| `stream:serializeUint8(holder)` | W R M | `SerializeUint8` | serialize_bits.lua (bits) |
| `stream:serializeUint16(holder)` | W R M | `SerializeUint16` | serialize_bits.lua (bits) |
| `stream:serializeUint32(holder)` | W R M | `SerializeUint32` | serialize_bits.lua (bits) |
| `stream:serializeUint64(holder)` | W R M | `SerializeUint64` | serialize_bits.lua (bits) |
| `stream:serializeInt(holder, min, max)` | W R M | `SerializeInt` (int32) | serialize_int.lua (int) |
| `stream:serializeInt64(holder, min, max)` | W R M | `SerializeInt64` | serialize_int.lua (int) |
| `stream:serializeInt128(holder, min, max)` | W R M | `SerializeInt128` | serialize_int128.lua (int) |
| `stream:serializeUint128(holder)` | W R M | `SerializeUint128` | serialize_int128.lua (int) |
| `stream:serializeFixed(holder, integerBits, fractionBits, min, max)` | W R M | `SerializeFixed64` (integerBits + fractionBits ≤ 64) and `SerializeFixed128` (= 128) | serialize_fixed.lua (fixed) |
| `stream:serializeIntRelative(previous, holder)` | W R M | `SerializeIntRelative` | serialize_int_relative.lua (int-relative) |
| `stream:serializeFloat(holder)` | W R M | `SerializeFloat32` | serialize_float.lua (float) |
| `stream:serializeDouble(holder)` | W R M | `SerializeFloat64` | serialize_float.lua (float) |
| `stream:serializeCompressedFloat(holder, min, max, resolution)` | W R M | `SerializeCompressedFloat32` | serialize_compressed_float.lua (compressed-float) |
| `stream:serializeCompressedFloatPrecomputed(holder, maxIntegerValue, bits, delta, min)` | W R M | `SerializeCompressedFloat32Precomputed` | serialize_compressed_float.lua (compressed-float) |
| `stream:serializeBytes(holder, numBytes)` | W R M | `SerializeBytes` | serialize_bytes.lua (strings) |
| `stream:serializeString(holder, bufferSize)` | W R M | `SerializeString` | serialize_bytes.lua (strings) |
| `stream:serializeWideString(holder, bufferSize)` | W R M | `SerializeWideString` | serialize_bytes.lua (strings) |
| `stream:serializeAlign()` | W R M | `SerializeAlign` | serialize_stream.lua (design) |
| `stream:serializeObject(object)` | W R M | `SerializeObject` | serialize_stream.lua (design) |
| `stream:alignBits()` | W R M | `AlignBits` (M: always 7) | serialize_stream.lua (design) |
| `stream:bitsProcessed()` | W R M | `BitsProcessed` | serialize_stream.lua (design) |
| `stream:bytesProcessed()` | W R M | `BytesProcessed` | serialize_stream.lua (design) |
| `stream:error()` | W R M | `Err`: nil, or the latched kind | serialize_stream.lua (design) |
| `stream:ok()` | W R M | `Err() == nil` (serialize.js `ok`) | serialize_stream.lua (design) |
| `stream:setContext(context)` | W R M | `SetContext` | serialize_stream.lua (design) |
| `stream:context()` | W R M | `Context` | serialize_stream.lua (design) |
| `stream:flush()` | W | `Flush` | serialize_stream.lua (design) |
| `stream:data()` | W | `Data`: the first `bytesProcessed()` bytes, a Lua string; call `flush` first | serialize_stream.lua (design) |

### The bitpacker objects (card serialize-lua-bitpacker)

`serialize.BitWriter.new(capacity)` and `serialize.BitReader.new(data)` return
objects with serialize.go's `BitWriter` and `BitReader` methods, in
serialize.js's spelling. They raise where serialize.go panics (a write or read
past the end, bits outside [1,32], an unaligned `writeBytes`/`readBytes`, a
capacity that is not a multiple of 8): the bitpacker is the unchecked layer
under the streams, exactly as in Go, and untrusted data goes through
ReadStream, never straight to a BitReader.

| method | serialize.go |
|---|---|
| `writer:reset(capacity)` | `BitWriter.Reset` |
| `writer:writeBits(value, bits)` | `WriteBits`, bits in [1,32] |
| `writer:writeAlign()` | `WriteAlign` |
| `writer:writeBytes(s)` | `WriteBytes`, s a Lua string |
| `writer:flushBits()` | `FlushBits` |
| `writer:alignBits()` | `BitWriter.AlignBits` |
| `writer:bitsWritten()` | `BitsWritten` |
| `writer:bitsAvailable()` | `BitsAvailable` |
| `writer:bytesWritten()` | `BytesWritten` |
| `writer:data()` | `BitWriter.Data`: the first `bytesWritten()` bytes |
| `reader:reset(data)` | `BitReader.Reset` |
| `reader:wouldReadPastEnd(bits)` | `WouldReadPastEnd` |
| `reader:readBits(bits)` | `ReadBits`, bits in [1,32] |
| `reader:readAlign()` | `ReadAlign`: false when the padding is not zero |
| `reader:readBytes(n)` | `ReadBytes`: returns the n bytes as a Lua string |
| `reader:alignBits()` | `BitReader.AlignBits` |
| `reader:bitsRead()` | `BitsRead` |
| `reader:bitsRemaining()` | `BitsRemaining` |

### Deviations from serialize.js's spelling, each with its reason

1. **Constructors are `.new(...)`**: Lua has no `new` operator.
2. **`WriteStream.new(capacity)` takes a byte count, not a buffer**: a Lua
   string is immutable, so the writer owns its buffer. `capacity` is a
   multiple of 8, as serialize.go's buffer must be (its panic message is
   raised otherwise); the written bytes come back from `data()`.
3. **`serializeBytes(holder, numBytes)`** carries the count: serialize.js fills
   a caller's `Uint8Array` in place and serialize.go a caller's slice, which
   Lua strings cannot be. On write `#holder.value` must equal `numBytes`
   (misuse raises); on read the holder receives a fresh string of `numBytes`
   bytes. Both sides must know the length; it is not sent (serialize.go).
4. **`isWriting()`, `isReading()`, `error()`, `ok()` are methods**: Lua has no
   getters, and a method keeps one calling shape across all three streams.
5. **`serialize.Continue` and `serialize.Until` keep serialize.go's
   capitalised names**: `until` is a reserved word in Lua, so serialize.js's
   camelCase cannot spell it, and the pair stays one spelling.
6. **`bnot`, `band`, `bor`, `bxor`** for the 128-bit `Not`, `And`, `Or`,
   `Xor`: `not`, `and` and `or` are reserved words; these are Lua 5.2's own
   names for the bitwise operations.
7. **Three error kinds, not four**: serialize.js adds `InvalidString`;
   serialize.go refuses a malformed string with `ErrValueOutOfRange`, and the
   card names serialize.go's three. String refusals latch `ValueOutOfRange`.
8. **One `serializeFixed`** covers serialize.go's `SerializeFixed64` and
   `SerializeFixed128` (serialize.js's one name): integerBits + fractionBits
   ≤ 64 is Fixed64 with an integer holder, = 128 is Fixed128 with a
   `{ lo, hi }` holder, anything else raises serialize.go's
   `panicFixedParams`. serialize.js's extra restriction to storage widths 8,
   16, 32, 64 and 128 is not adopted: serialize.go accepts any total up to 64.
9. **No checked/production split**: serialize.js forks its writer at load on
   `NODE_ENV`; Lua has one build, and the writer here is always the strict
   one (g).
10. **Names serialize.js lacks** (`serializeObject`,
    `serializeCompressedFloatPrecomputed`, `compressedFloatParams`,
    `setContext`, `context`, `signedToUnsigned`, `unsignedToSigned`, the
    128-bit helpers, `Continue`, `Until`, `flush`) are serialize.go's names
    in serialize.js's camelCase.
11. **64-bit values are integers**, not BigInts: (c).
12. **A failing object gives a kind, not an error value**: serialize.go's
    `Serializer` returns any `error` and the stream latches it; Lua has no
    error values, so `object:serialize(stream)` returns `false` and,
    optionally, a kind (any non-nil value, latched as given, as Go latches
    any error). An object that fails without giving one latches
    `ValueOutOfRange`, the kind serialize.go uses for a value its reader
    refuses. An object that returns `true` after a primitive inside it
    latched still fails the call (serialize.go returns `s.err`).

## (b) BIT ORDER AND ENDIANNESS

Exactly as C++ and Go. STANDARD.md, General Conventions, quoted:

> All multi-byte quantities are **little-endian**.
>
> The stream is accumulated in a **64-bit scratch word**. Bits are packed
> **least-significant-bit first**: the first value written occupies the lowest
> bits of the first word. When the scratch fills, the 64-bit word is copied to
> the buffer in host byte order on little-endian machines, and byte-swapped on
> big-endian machines. The result is the same bytes on the wire everywhere.
>
> A value of `n` bits, written when the scratch already holds `s` bits, occupies
> bits `[s, s+n)` of the current word. A value that would cross the 64-bit
> boundary is split: the low `64-s` bits complete the current word, and the
> remainder begins the next.
>
> **Flush.** After the final value, any partially filled scratch word is written
> out. The stream therefore always occupies a whole number of 8-byte words in the
> writer's buffer, but the meaningful length is the number of bytes actually
> required, rounded up to a byte.

And STANDARD.md, bits: "For `bits > 32` the value is split: the **low 32 bits
are written first as a 32-bit group**, then the remaining `bits - 32` high bits
as a second group." And uint128: "the **low 64-bit half first**, then the high
half, each half written exactly as `serialize_bits( half, 64 )`".

For this library:

- The scratch is one Lua integer (64 bits); a value enters it as
  `scratch | (value << s)` and the spill carry is `value >> (64 - s)` (`>>` is
  logical in Lua 5.4; a shift of 64 or more is 0, which is the right carry when
  a field ends the word exactly).
- A full word is stored as `string.pack("<i8", scratch)`: 8 little-endian bytes
  on every host, because the format names `<` and the host's byte order is
  never consulted (PORT-LUA.md, BYTE BUFFERS, M12).
- `bits > 32` is two groups, low 32 first, then `bits - 32` high: the stream's
  write primitive does the split (`serialize_stream.lua`, `_writeBits`), so no
  family repeats it. uint128 is `lo` as 64 bits, then `hi` as 64 bits.
- `flush` stores the partial word; `data()` is the first
  `bytesProcessed() = (bitsProcessed() + 7) // 8` bytes.
- Trailing bits (STANDARD.md, Reader Obligations, "Trailing bits"): the writer
  emits zero in the unused bits of the final byte, by construction (the
  scratch above the bit index is zero); a reader never looks at them.

## (c) THE NUMBER MODEL

PORT-LUA.md, 64-BIT AND 128-BIT INTEGERS, for this library. Lua 5.4 has a
native 64-bit integer subtype (`math.maxinteger` is `9223372036854775807`,
`math.mininteger` is `-9223372036854775808`, `math.type(1)` is `integer`).

- **int64** is the integer. **int32**, **uint8**, **uint16** and **uint32**
  are integers in their Go type's domain.
- **uint64** is the same 64 bits read unsigned: a value above 2^63 is the
  negative integer with those bits. Comparison is `math.ult`; `//` and `%` on a
  value above 2^63 go through the unsigned helpers of the card that needs them;
  a uint64 literal above int64's ceiling is a wrapping hex literal
  (`0xffffffffffffffff` is `-1`), and `math.mininteger` is spelled by name
  (the decimal `9223372036854775808` lexes as a float).
- **128-bit** values are two halves, `{ lo = <low 64>, hi = <high 64> }`, each
  an integer, two's complement across the pair. A read returns a fresh table;
  a write never mutates the holder's table.
- **bool** is a Lua boolean. **float32** and **float64** are Lua floats
  (doubles); a float32 holds the double that is exactly its float32 value (e).
- **A value of the wrong Lua type is API misuse and raises**, never a silent
  coercion: a float where an integer belongs (`1.0` included: `math.type`
  tells them apart exactly), an integer outside its Go type's domain (a
  `serializeUint8` of 300, a `serializeInt` bound outside int32), a non-string
  where a string belongs, and an integer where a float belongs (a
  `serializeFloat` or `serializeDouble` holder holds a float: `1.0`, never
  `1`). serialize.go's type system refuses these at compile time; the strict
  writer refuses them at the call (the arm's `checkValue`, (h)). A value INSIDE its Go type
  but outside the call's `[min,max]` is not misuse: it latches
  `ValueOutOfRange`, exactly where serialize.go does (g).
- Bit counts and byte counts are integers; arithmetic on them never meets
  2^53, because they are integers, not floats.

LuaJIT (Lua 5.1, no integer subtype) is not covered; a LuaJIT build would take
the Luau port's number model, not this one.

## (d) BYTES

PORT-LUA.md, BYTE BUFFERS, for this library.

- **A READ** is a Lua string (immutable bytes) and an integer cursor.
  Fixed-width little-endian values are `string.unpack("<I4", s, pos)` and
  friends, every format naming `<`. The bounds check is made BEFORE any load
  (`bit_index + n > 8 * #data`, STANDARD.md, Reader Obligations), so
  `string.unpack` never runs off the end of the string and hostile bytes never
  raise. **The allocation contract** (STANDARD.md, Reader Obligations,
  "every runtime states that its callers are under it"): a caller passes the
  exact packet as a Lua string and owes NO slack, because a Lua string cannot
  carry bytes past its length. The reader pays for that once, at the
  boundary: `BitReader.new` and `reset` keep the data with 16 zero bytes
  appended (one concatenation per packet), so every word load in the hot path
  is one branchless `string.unpack` and no per-read near-end branch exists.
  That is the copying entry point STANDARD.md admits ("A copying entry point
  that takes an exact-length input and copies it into a slack backed buffer
  is admitted as a convenience, ... because it prices the copy once at the
  boundary rather than per operation in the hot path"); a per-read tail
  branch (serialize.go's tail window) is the slower option the speed rule
  refuses, and is not used. Padding bytes are loaded, never interpreted.
  `readBytes` returns `string.sub` of the data: a fresh string, never
  aliasing anything mutable.
- **A WRITE** is a table of pieces (8-byte words from `string.pack("<i8",
  word)` and block-copied substrings) joined once by `table.concat` when the
  bytes are asked for, never repeated string concatenation.
- **Bytes and strings** travel as Lua strings. `string` is UTF-8 bytes (the
  writer's contract: well-formed UTF-8, no interior NUL; the reader refuses
  both, `ValueOutOfRange`); `utf8.len` decides well-formedness. `wstring`'s
  holder is also a Lua UTF-8 string, as serialize.go's `*string` is: the
  writer splits each astral code point into a surrogate pair of 32-bit
  groups and the reader recombines them (STANDARD.md, wstring).

## (e) FLOAT32

PORT-LUA.md, BYTE BUFFERS, "float32 rounding and patterns", for this library,
with the port ruling that float32 writes round exactly as Go's `float32()`
does.

- A float32 holder holds a double. Its 32-bit pattern is computed by INTEGER
  BIT SURGERY between the float64 and float32 layouts, never through a float
  conversion: the double's 64 bits are `string.unpack("<i8", string.pack("<d",
  v))` (an 8-byte copy, no conversion), and the float32 pattern is assembled
  from sign, exponent and mantissa with integer operations. `string.pack("<f",
  v)` is NOT used for a value that is not exactly a float32, because the C
  conversion behind it is a float conversion.
- **Write, a double that is exactly a float32** (every value a read produced):
  the pattern moves bit for bit, including a NaN's payload and a signalling
  NaN's clear quiet bit, so a read and a re-write reproduce the 32 bits
  (STANDARD.md, float, "Bit transparency — both directions").
- **Write, any other double**: rounded exactly as Go's `float32()` conversion
  does: round to nearest, ties to even; magnitudes past the float32 range
  become infinities; results below the normal range are rounded as float32
  subnormals (or to signed zero); a NaN that is not exactly a float32 (a
  non-zero bit among the low 29 mantissa bits) becomes the quiet NaN with its
  sign and its top 22 payload bits, as the conversion instruction on Go's
  targets (amd64, arm64) produces.
- **Read**: the 32 bits widen to the double with the same value by surgery
  (exponent rebiased, mantissa shifted left 29; a NaN keeps its payload and
  its quiet bit), then `string.unpack("<d", string.pack("<i8", bits64))`.
- `fround(x)`, the float32 rounding of a double, is the write rule followed
  by the read rule. The float card (serialize_float.lua) owns `fround`,
  `float32Bits` and `float32FromBits`, exported on its module table for the
  compressed-float card; they are not entry names.
- **compressed_float's parameters are float32**, as serialize.go's
  `min, max, resolution float32` and `*float32` value are: the arm rounds
  `min`, `max`, `resolution` and the written value with `fround` first,
  exactly the `float32()` a Go caller applies at the call site, and a value
  that is NaN or infinite after rounding is misuse and raises (STANDARD.md,
  compressed_float, "Non-finite inputs are non-conforming": "Conforming
  writers assert in checked builds"; serialize.go clamps such a value
  instead, and this writer is the checked build, (g)). For
  `serializeCompressedFloatPrecomputed` the constants must be exactly what
  `compressedFloatParams` derives (`delta` exactly a float32 among them),
  else it raises serialize.go's `panicPrecomputedFloat`.
- **compressed_float's arithmetic is float32**, emulated by `fround` after
  EVERY operation (STANDARD.md, compressed_float: "This arithmetic is
  `float32`, and the two roundings are part of the format"): `delta =
  fround(max - min)`, `values = fround(delta / resolution)`, on write
  `normalized = fround(fround(value - min) / delta)`, clamped, `product =
  fround(normalized * fround(maxIntegerValue))`, `sum = fround(product +
  0.5)`, then the floor and the integer clamp; on read `fround(fround(
  fround(integer) / fround(maxIntegerValue)) * delta) + min` rounded once
  more. Doubles never fuse a multiply and an add in Lua, so the barrier is
  the explicit `fround`. serialize.go v1.15.1 is the same arithmetic
  (`float32(normalizedValue*float32(maxIntegerValue)) + 0.5` is a float32
  sum).
- **double** is the 64 bits of the Lua float, moved by `string.pack("<d")` and
  `string.unpack("<i8")` and back: a copy, never a conversion.

## (f) LOADING

PORT-LUA.md, THE RUNTIME LAYOUT, "How a module requires its runtime", for
this library.

- Every file of this library is a module required by its BASENAME:
  `require("serialize")`, `require("serialize_stream")`,
  `require("serialize_bits")`. Each binds what it requires to a local and
  returns one table. Nothing is global: loading the library creates no global
  (test/smoke checks `_G` before and after).
- The CONSUMER owns the search path. It REPLACES `package.path` with its own
  directory's pattern (`<dir>/?.lua`; the runner uses `./src/?.lua`) and sets
  `package.cpath = ""`. It never prepends to either: a prepend leaves `./?.lua`
  and the system directories behind it, where a planted
  `serialize_stream.lua` would shadow the library. The library itself never
  reads or writes `package.path` or `package.cpath`.
- No native module is loaded: the library requires nothing but its own files,
  and uses only the interpreter's built-in `string`, `table`, `math` and
  `utf8` (tests add `io`).
- The basenames `serialize` and `serialize_*` are this library's. schema's Lua
  leg vendors these files into a generated unit's directory unchanged, and a
  schema file whose basename collides with one is refused there by name
  (PORT-LUA.md: a schema file colliding with a runtime file is refused at
  generation).
- A family file is required LAZILY (h). Its absence is decided the way
  `require` searches (`package.loaded`, `package.preload`, then
  `package.searchpath(name, package.path)`), never by catching an error, so an
  error inside a family file that is present propagates unchanged.

## (g) WRITER AND READER

**The writer is STRICT.** It produces exactly serialize.go v1.15.1's bytes. It
latches `ValueOutOfRange` or `Overflow` where serialize.go's WriteStream (and
MeasureStream) return them, and it RAISES, naming the rule, where serialize.go
panics on API misuse; the raise messages are serialize.go's panic strings
(`serialize: bits must be in [1,32]`, `serialize: min must not be greater than
max`, and the rest of `serialize.go`'s `panic*` constants). Misuse raises on a
healthy stream and on a failed one alike, as in serialize.go, where the panic
precedes the latch check. Beyond serialize.go, the type checks of (c) raise.
STANDARD.md's doctrine ("Writes assume trusted data") puts the cost of these
checks on the writer, and a Lua build has no release mode to strip them from.

**The reader is forgiving only where serialize.go's is, and where that is
nearly free**: trailing bits of the final byte are ignored (STANDARD.md,
Reader Obligations, "Trailing bits"), and nothing else is.

**Security trumps.** Every refusal STANDARD.md and serialize.go state binds in
every case: a decoded value outside `[min,max]`, a decoded offset past the
range, non-zero padding in an align (`Align`), a string with an interior NUL
or malformed UTF-8, a wstring group above `0xFFFF`, an unpaired surrogate or a
zero group, an int_relative reconstruction outside the domain or not above
`previous`, a compressed integer above `maxIntegerValue`, and every read past
the end (`Overflow`). On each:

- the destination is untouched: the stream assigns `holder.value` only after
  the read arm reports success (STANDARD.md, Reader Obligations, "A refused
  primitive read must leave its destination unwritten"); a composite read
  (`serializeObject`) may leave earlier members written, as the standard
  allows;
- the stream is terminal: the first error latches and sticks; every later
  serialize call returns `false`, consumes no bits and writes no holder,
  zero-bit operations included (a degenerate range, an align on an aligned
  stream, a zero-count `serializeBytes`, `serializeObject`); only `reset`
  clears it (STANDARD.md, Reader Obligations, "Failure is terminal": the
  latch shape);
- hostile bytes never raise: a raise on the read path is a bug (STANDARD.md:
  "A trap, a crash or an abort on malformed input is non-conforming"); every
  arithmetic step on read data is integer arithmetic that wraps, and no read
  path calls a function that raises on a value the wire can carry (a
  `string.unpack` past the end, `utf8.codepoint` on malformed bytes);
- no read past the data's end: the bounds test precedes every load (d).

The order of one serialize call (`serialize_stream.lua`, `M.method`): the
holder is a table, else raise; the family loads, else raise "not implemented";
the arm's `check` runs (misuse raises); a failed stream returns `false`; the
arm runs; the stream settles the result (a read assigns the holder only on
success). Because the family loads before the latch check, a method whose
family file is absent raises "not implemented" even on a failed stream: absent
code is not a runtime condition.

**The measure stream** (STANDARD.md, The Measure Stream) follows the writer's
misuse model, charges 7 bits per alignment-performing operation (`align`,
`bytes`, `string`; `alignBits()` is always 7) and exact widths for everything
else, and latches `ValueOutOfRange` where serialize.go's MeasureStream does.

## (h) THE FILE LAYOUT

| file | card | what it exports |
|---|---|---|
| `src/serialize.lua` | serialize-lua-design | the entry: the API table of (a); lazy stubs for every family function |
| `src/serialize_stream.lua` | serialize-lua-design | the three streams, the latch, terminality, bit accounting, `serializeAlign`, `serializeObject`, the lazy loader (`family`, `lazy`, `method`) and the dispatch table |
| `src/serialize_bitpacker.lua` | serialize-lua-bitpacker | `api.BitWriter.new`, `api.BitReader.new` |
| `src/serialize_bits.lua` | serialize-lua-bits | arms `serializeBits`, `serializeBits64`, `serializeBool`, `serializeUint8`, `serializeUint16`, `serializeUint32`, `serializeUint64`; `api.bitsRequired`, `api.bitsRequired64`, `api.signedToUnsigned`, `api.unsignedToSigned` |
| `src/serialize_int.lua` | serialize-lua-int | arms `serializeInt`, `serializeInt64` |
| `src/serialize_int128.lua` | serialize-lua-int | arms `serializeInt128`, `serializeUint128`; `api.bitsRequired128`, `api.Uint128.*`, `api.Int128.*` |
| `src/serialize_fixed.lua` | serialize-lua-fixed | arm `serializeFixed` |
| `src/serialize_int_relative.lua` | serialize-lua-int-relative | arm `serializeIntRelative` |
| `src/serialize_float.lua` | serialize-lua-float | arms `serializeFloat`, `serializeDouble`; module fields `fround`, `float32Bits`, `float32FromBits` |
| `src/serialize_compressed_float.lua` | serialize-lua-compressed-float | arms `serializeCompressedFloat`, `serializeCompressedFloatPrecomputed`; `api.compressedFloatParams` |
| `src/serialize_bytes.lua` | serialize-lua-strings | arms `serializeBytes`, `serializeString`, `serializeWideString` |

**A family module** is the file `src/serialize_<family>.lua`, and returns:

```lua
return {
  methods = {                       -- one entry per dispatched method it owns
    serializeInt = {
      check = function(min, max) end,           -- optional; raises on API misuse
      write = function(stream, value, min, max) end,   -- -> boolean
      read = function(stream, min, max) end,           -- -> ok, value
      measure = function(stream, value, min, max) end, -- -> boolean
    },
  },
  api = { },                        -- entry-level functions of (a), if any
}
```

- `check(...)` receives the call's arguments other than the holder, and
  raises on misuse. It runs before the latch check, on every stream.
- `checkValue(...)` (optional) receives the arguments with `holder.value` in
  the holder's place, on write and measure only, and raises on a value of the
  wrong Lua type or outside its Go type's domain ((c)), or a `serializeBytes`
  value whose length is not `numBytes`. It also runs before the latch check,
  so misuse raises on a failed stream too. A value inside its Go type but
  outside `[min,max]` is not misuse: the write arm latches it.
- `write(stream, ...)` and `measure(stream, ...)` receive the arguments with
  `holder.value` in the holder's place (`serializeIntRelative`:
  `write(stream, previous, value)`). They return `true`, or `false` after
  latching through a primitive or `stream:_fail(kind)`; `kind` is one of
  `SerializeError`'s three.
- `read(stream, ...)` receives the arguments without the holder and returns
  `true, value` or `false` (after latching). It never touches a holder: the
  stream assigns it.
- An arm that returns `false` without a latched error, `true` on a failed
  stream, or a non-boolean, raises `serialize: <name> returned false without
  latching an error` (and its siblings): the contract is held, not trusted.
- A family module reaches another family through the stream module's loader,
  `require("serialize_stream").family("int128", "serializeFixed")`, never a
  bare `require` and never through the entry, so a sibling whose file is
  absent raises `serialize: serializeFixed not implemented` rather than
  `module not found`.

**The primitives an arm calls**, all in `serialize_stream.lua`, each checking
the latch first:

| primitive | stream | what |
|---|---|---|
| `stream:_writeBits(value, bits)` | W | bits in [1,64]; value masked to bits; the TOTAL width is checked against the capacity before anything is written (`Overflow`); bits > 32 split low 32 first; returns boolean |
| `stream:_writeBytes(s)` | W | the stream must be aligned (else raises serialize.go's `panicNotAligned`); `Overflow` if it does not fit; returns boolean |
| `stream:_readBits(bits)` | R | bits in [1,64]; the bounds test precedes the load; returns the integer, or nil after latching `Overflow` |
| `stream:_readBytes(n)` | R | aligned; returns a fresh string of n bytes, or nil after latching `Overflow` |
| `stream:_measure(bits)` | M | adds bits; returns boolean |
| `stream:_fail(kind)` | W R M | latches kind if nothing is latched; returns false |
| `stream:serializeAlign()` | W R M | the public align, callable from an arm (the bytes family aligns first) |

The write and read primitives build the bitpacker's `BitWriter` or
`BitReader` lazily, on their first load or store, so until
`serialize_bitpacker.lua` exists they raise `serialize: BitWriter.new not
implemented` (or `BitReader.new`) on the first bit actually moved. The
bit accounting (`bitsProcessed`, `bytesProcessed`, `alignBits`, the capacity
and length bounds) is the stream's own and needs no family.

**The lazy dispatch.** `serialize_stream.lua`'s `DISPATCH` table names every
dispatched method, its family and its holder position; each stream's method
is built by `M.method(family, name, holderIndex)`. While a family's file is
absent its methods raise `serialize: <name> not implemented` (and an entry
function raises `serialize: <name> not implemented` through `M.lazy`), so each
family card creates its own file and no two cards edit one file. test/smoke
proves this through a test-only family name no card creates
(`smoke_absent`), so it stays green as the families land.

**Tests.** Each card's tests live in `test/<card short name>/`, e.g.
`test/bits/bits_test.lua`, and read `conformance/*.txt` themselves. A card's
own make targets, if it needs any, go in `make/<card>.mk`.

## (i) THE RUNNER

- `make dist-lua` fetches `https://www.lua.org/ftp/lua-5.4.8.tar.gz` into
  `dist/`, refuses by name any tarball whose sha256 is not
  `4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae`, and
  builds it from source into `dist/lua-5.4.8/` (`linux` on Linux, `macosx` on
  macOS, `posix` elsewhere). `dist/` and `build/` are gitignored.
- `make toolchain-lua` refuses by name a pin that does not resolve
  (`dist/lua-5.4.8/src/lua` missing, or not reporting `Lua 5.4.8`), naming
  `make dist-lua`. `make test` runs it first: an absent interpreter fails,
  never skips.
- `make test` runs every `test/*/*_test.lua`; `make test T=<name>` runs the
  files of `test/<name>/`. A missing `test/<name>/`, or one holding no
  `*_test.lua`, exits nonzero naming it; never a skip.
- Each test file runs in its own pinned interpreter process, from the
  repository root, as `dist/lua-5.4.8/src/lua -E build/test_runner.lua
  <file>` (`-E`: `LUA_PATH`, `LUA_CPATH` and `LUA_INIT` are never consulted).
  `build/test_runner.lua` is written from the Makefile's `TEST_RUNNER`; it
  replaces `package.path` with `./src/?.lua` and sets `package.cpath = ""`
  (f), then loads the test file.
- A test file declares global functions named `Test<Name>`; the runner calls
  each in declaration order and prints `RUN Test<Name>`, then `--- PASS
  Test<Name>` or `--- FAIL Test<Name>` (with the raise and its traceback). A
  test fails by raising. A file that declares no test, or raises while
  loading, fails by name. The last line is `ok   make test` or `FAIL make
  test`, and the exit status is nonzero on any failure.
- Unit tests use no real time, no sockets, no network and no outside
  services; a test clock is an argument and starts at 1000.0. `make dist-lua`
  is setup, run once before the tests, never from a test.
