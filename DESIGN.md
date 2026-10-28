# serialize.lua — the design

This page is the design every card of the `serialize-lua` stream copies. It
was written by the design card (serialize-lua-design) with the skeleton it
describes: `src/serialize.lua` (the entry), `src/serialize_stream.lua` (the
three streams), the `Makefile` and its runner, and `test/smoke/`. Every later
card creates ONE family file named in (h), and its own `test/<card>/`
directory, and needs to decide nothing that is decided here.

**The sources.** The wire is [STANDARD.md](STANDARD.md), format version 2.0,
and the corpus is [conformance/](conformance/) with its negative controls in
[conformance-controls/](conformance-controls/); STANDARD.md, IMPLEMENTING.md and
both directories are vendored VERBATIM from
[mas-bandwidth/serialize](https://github.com/mas-bandwidth/serialize) at tag
`v2.1.1` (commit `bd3d67e23c8acc2c45eff69633dbe16c029a2cba`: standard
2.1, format 2.0 — the `rejected` refusal reason, IMPLEMENTING.md's uniform
rules U1–U16 with the 2.1.1 rulings on U3, U6, U9 and U15, and the `reject`
step), by `tools/revendor.sh v2.1.1`, and CI
diffs them against the tag on
every run. Where STANDARD.md is silent,
[serialize.go](https://github.com/mas-bandwidth/serialize.go) `v2.0.0` (module
`github.com/mas-bandwidth/serialize.go/v2`) is the reference for behaviour
(IMPLEMENTING.md, "Sources"), and the fuzz oracle;
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

Every type, function and stream method serialize.go v2 exports, in
serialize.js's spelling (`src/index.js`, `src/streams.js`). A value travels in
a HOLDER, `{ value = ... }`, exactly as serialize.js's ref objects: on write
and measure `holder.value` is consumed; on read it is assigned on success and
left unmodified on failure. Every serialize call returns a boolean. On a
READ the first error latches on the stream; every later call fails, consumes
nothing and writes nothing to its destination (STANDARD.md, Reader
Obligations, "Failure is terminal"). On a WRITE or a MEASURE misuse is never
latched: it traps, Lua's `error()`, at the call (IMPLEMENTING.md U9; (g)). `test/smoke` parses the two tables below and checks every name
exists, so a row added here is a row the skeleton must carry.

### The entry: `local serialize = require("serialize")`

| name | file (card) | serialize.go |
|---|---|---|
| `serialize.Refusal` | serialize_stream.lua (design) | the refusal reasons (STANDARD.md, "Refusal reasons"), below |
| `serialize.Refusal.PastEnd` | serialize_stream.lua (design) | `ErrPastEnd`, `"past_end"` |
| `serialize.Refusal.ValueOutOfRange` | serialize_stream.lua (design) | `ErrValueOutOfRange`, `"value_out_of_range"` |
| `serialize.Refusal.NonzeroPadding` | serialize_stream.lua (design) | `ErrNonzeroPadding`, `"nonzero_padding"` |
| `serialize.Refusal.TrailingData` | serialize_stream.lua (design) | `ErrTrailingData`, `"trailing_data"` |
| `serialize.Refusal.NonFiniteFloat` | serialize_stream.lua (design) | `ErrNonFiniteFloat`, `"non_finite_float"` |
| `serialize.Refusal.InvalidUtf8` | serialize_stream.lua (design) | `ErrInvalidUTF8`, `"invalid_utf8"` |
| `serialize.Refusal.EmbeddedNul` | serialize_stream.lua (design) | `ErrEmbeddedNul`, `"embedded_nul"` |
| `serialize.Refusal.NonCanonical` | serialize_stream.lua (design) | `ErrNonCanonical`, `"non_canonical"` |
| `serialize.Refusal.Rejected` | serialize_stream.lua (design) | `ErrRejected`, `"rejected"`: the caller's own refusal (STANDARD.md 2.1; IMPLEMENTING.md U2) |
| `serialize.refusalName(reason)` | serialize_stream.lua (design) | the refusal-name function (IMPLEMENTING.md U14): `"none"` for nil, a listed reason's own name; anything else raises |
| `serialize.WriteStream.new(capacity)` | serialize_stream.lua (design) | `NewWriteStream(buffer)` |
| `serialize.ReadStream.new(data)` | serialize_stream.lua (design) | `NewReadStream(data)`; data that is not a Lua string latches `value_out_of_range` at initialization (IMPLEMENTING.md U7) |
| `serialize.MeasureStream.new()` | serialize_stream.lua (design) | `NewMeasureStream()` |
| `serialize.copyString(source, destSize)` | serialize.lua (design) | `serialize_copy_string` (IMPLEMENTING.md U15): returns the bytes of `source` before its first NUL, cut to `destSize - 1` and backed off while the first byte left out is a continuation byte (10xxxxxx), so `serializeString` with `bufferSize = destSize` accepts a well-formed result. Lua strings are byte strings, so the rule applies to any bytes. `destSize` below 1 or not an integer, or a `source` that is not a string, is write misuse: the trap (U9) |
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
| `stream:serializeAlign()` | W R M | `SerializeAlign` | serialize_stream.lua (design) |
| `stream:serializeObject(object)` | W R M | `SerializeObject` | serialize_stream.lua (design) |
| `stream:reject()` | R | `Reject`: the caller refuses the read as `rejected` and gets false (W and M: caller misuse, the trap, in every run: this port is always checked; IMPLEMENTING.md U2, U9) | serialize_stream.lua (design) |
| `stream:fail(reason)` | W R M | `serialize_fail` (IMPLEMENTING.md U14): R latches a listed reason as given and nil or anything else as `rejected`, and returns false; W and M return false, record nothing and never trap (U6, U9) | serialize_stream.lua (design) |
| `stream:serializeEnd()` | W R M | `SerializeEnd`: a packet reader reads it after the top-level object (R: `trailing_data`, then `nonzero_padding`; W and M: a no-op returning true, IMPLEMENTING.md U12) | serialize_stream.lua (design) |
| `stream:alignBits()` | W R M | `AlignBits` (M: always 7) | serialize_stream.lua (design) |
| `stream:bitsProcessed()` | W R M | `BitsProcessed` | serialize_stream.lua (design) |
| `stream:bytesProcessed()` | W R M | `BytesProcessed` | serialize_stream.lua (design) |
| `stream:error()` | W R M | `Err`: nil, or the FIRST refusal's reason, spelled as STANDARD.md spells it (W and M: always nil; write misuse traps and never latches, U6, U9) | serialize_stream.lua (design) |
| `stream:refusal()` | W R M | the refusal's name, `"none"` for no refusal (IMPLEMENTING.md U14) | serialize_stream.lua (design) |
| `stream:ok()` | W R M | `Err() == nil` (serialize.js `ok`) | serialize_stream.lua (design) |
| `stream:setContext(context)` | W R M | `SetContext` | serialize_stream.lua (design) |
| `stream:context()` | W R M | `Context` | serialize_stream.lua (design) |
| `stream:flush()` | W | `Flush`: required; the written bytes are unspecified until it runs (IMPLEMENTING.md U11) | serialize_stream.lua (design) |
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
7. **The refusal reasons are strings**: `stream:error()` is the reason as
   STANDARD.md spells it (`"past_end"`, `"embedded_nul"`, ...), and
   `serialize.Refusal` names the eight in serialize.go's order. A Lua string
   compares by value, so a caller tests `s:error() == serialize.Refusal.PastEnd`.
   They are a READER's reasons only (IMPLEMENTING.md U9): a write or a
   measure stream never latches one. Write misuse traps instead, and the
   trap's message names the reason the reader would give for the same fault:
   `serialize: write misuse (IMPLEMENTING.md U9): past_end`, and likewise
   `value_out_of_range`, `non_finite_float`, `embedded_nul`, `invalid_utf8`.
8. **One `serializeFixed`** covers serialize.go's `SerializeFixed64` and
   `SerializeFixed128` (serialize.js's one name): integerBits + fractionBits
   ≤ 64 is Fixed64 with an integer holder, = 128 is Fixed128 with a
   `{ lo, hi }` holder, anything else raises serialize.go's
   `panicFixedParams`. serialize.js's extra restriction to storage widths 8,
   16, 32, 64 and 128 is not adopted: serialize.go accepts any total up to 64.
9. **No checked/production split**: serialize.js forks its writer at load on
   `NODE_ENV`; Lua has one build, and it is a checked build always
   (IMPLEMENTING.md U9: "An implementation with no unchecked build is a
   checked build, always"), so every write and measure misuse traps in every
   run, `reject` on a write or a measure included (g).
10. **Names serialize.js lacks** (`serializeObject`,
    `serializeCompressedFloatPrecomputed`, `compressedFloatParams`,
    `setContext`, `context`, `signedToUnsigned`, `unsignedToSigned`, the
    128-bit helpers, `Continue`, `Until`, `flush`) are serialize.go's names
    in serialize.js's camelCase.
11. **64-bit values are integers**, not BigInts: (c).
12. **A failing object gives a kind, not an error value**: serialize.go's
    `Serializer` returns any `error` and the stream latches it; Lua has no
    error values, so `object:serialize(stream)` returns `false` and,
    optionally, a kind. A kind from the closed list (`serialize.Refusal`)
    is latched as given; an object that fails without one, or with one
    outside the list, latches `rejected` (STANDARD.md 2.1, "Refusal reasons";
    IMPLEMENTING.md U2), so a refused stream never reports none. Through the
    one latch, so a reason a primitive inside the object latched first is
    kept. An object that returns `true` after a primitive inside it latched
    still fails the call (serialize.go returns `s.err`).

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
- The final byte's unused bits (STANDARD.md, end): the writer emits zero
  there, by construction (the scratch above the bit index is zero), and its
  end emits nothing; a reader's `serializeEnd()` reads them and refuses a set
  one as `nonzero_padding`, after refusing a whole byte left over as
  `trailing_data`.

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
  but outside the call's `[min,max]` is write misuse too, caught by the arm
  rather than `checkValue`: it traps, naming `value_out_of_range` (U9, (g)).
- Bit counts and byte counts are integers; arithmetic on them never meets
  2^53, because they are integers, not floats.

LuaJIT (Lua 5.1, no integer subtype) is not covered; a LuaJIT build would take
the Luau port's number model, not this one. Nor is a Lua 5.4 built with
`LUA_32BITS`: its 32-bit integer cannot hold a uint32 or a 64-bit window, so
`serialize_stream.lua` refuses to load there, raising by name, rather than
decode hostile bytes wrongly (AUDIT-LEDGER 2026-10-27, lua L).

## (d) BYTES

PORT-LUA.md, BYTE BUFFERS, for this library.

- **A READ** is a Lua string (immutable bytes) and an integer cursor.
  Fixed-width little-endian values are `string.unpack("<I4", s, pos)` and
  friends, every format naming `<`. The bounds check is made BEFORE any load
  (`bit_index + n > 8 * #data`, STANDARD.md, Reader Obligations), so
  `string.unpack` never runs off the end of the string and hostile bytes never
  raise. **The allocation contract** (IMPLEMENTING.md, "The buffer contract":
  "Every implementation states which allocation contract its caller is
  under"): a caller passes the
  exact packet as a Lua string and owes NO slack, because a Lua string cannot
  carry bytes past its length. The reader pays for that once, at the
  boundary: `BitReader.new` and `reset` keep the data with 16 zero bytes
  appended (one concatenation per packet), so every word load in the hot path
  is one branchless `string.unpack` and no per-read near-end branch exists.
  That is the copying entry point IMPLEMENTING.md admits (it "prices the
  copy once at the boundary"); a per-read tail
  branch (serialize.go's tail window) is the slower option the speed rule
  refuses, and is not used. Padding bytes are loaded, never interpreted.
  `readBytes` returns `string.sub` of the data: a fresh string, never
  aliasing anything mutable.
- **A WRITE** is a table of pieces (8-byte words from `string.pack("<i8", word)` and block-copied substrings) joined once by `table.concat` when the
  bytes are asked for, never repeated string concatenation.
- **Bytes and strings** travel as Lua strings. `string` is UTF-8 bytes (the
  writer's contract: well-formed UTF-8, no interior NUL; the reader refuses a
  NUL anywhere as `embedded_nul` FIRST, then ill-formed UTF-8 under Unicode
  Table 3-7 as `invalid_utf8`). A Lua string is bytes, so real text (CJK, a
  BOM, combining marks, U+FFFF, four-byte characters) comes back exactly as
  read: no normalization, no stripping, no replacement. A wire-claimed length
  is tested against the bytes that remain before anything is taken, so a
  hostile length never sizes an allocation. `wstring` is gone (format 2.0).

## (e) FLOAT32

PORT-LUA.md, BYTE BUFFERS, "float32 rounding and patterns", for this library,
with the port ruling that float32 writes round exactly as Go's `float32()`
does.

- A float32 holder holds a double. Its 32-bit pattern is computed by INTEGER
  BIT SURGERY between the float64 and float32 layouts, never through a float
  conversion: the double's 64 bits are `string.unpack("<i8", string.pack("<d", v))` (an 8-byte copy, no conversion), and the float32 pattern is assembled
  from sign, exponent and mantissa with integer operations. `string.pack("<f", v)` is NOT used for a value that is not exactly a float32, because the C
  conversion behind it is a float conversion.
- **Finite values only** (STANDARD.md, "Finite values only, every one bit
  exact"). A read tests the RAW 32 or 64 bits: an exponent field of all ones
  (`bits & 0x7F800000 == 0x7F800000`, `0x7FF0000000000000` for double) is
  refused as `non_finite_float` before anything is converted or assigned.
  The writer and the measure test the bits AFTER the float32 narrowing, so a
  finite double above `FLT_MAX`, which narrows to an infinity, is refused as
  `non_finite_float` too, as serialize.go v2's writer refuses it. Negative
  zero and every subnormal are finite and move bit for bit.
- **Write, a double that is exactly a float32** (every value a read produced):
  the pattern moves bit for bit, so a read and a re-write reproduce the 32
  bits.
- **Write, any other double**: rounded exactly as Go's `float32()` conversion
  does: round to nearest, ties to even; magnitudes past the float32 range
  become infinities; results below the normal range are rounded as float32
  subnormals (or to signed zero); a NaN narrows to the quiet NaN with its
  sign, which the writer then refuses (its payload is never sent).
- **Read**: the 32 bits widen to the double with the same value by surgery
  (exponent rebiased, mantissa shifted left 29), then `string.unpack("<d", string.pack("<i8", bits64))`.
- `fround(x)`, the float32 rounding of a double, is the write rule followed
  by the read rule. The float card (serialize_float.lua) owns `fround`,
  `float32Bits` and `float32FromBits`, exported on its module table for the
  compressed-float card; they are not entry names. They are language
  necessities in IMPLEMENTING.md U15's sense (Lua has no float32), and they
  are INTERNAL: (f) says which names are, and promises nothing about them.
- **compressed_float's parameters are float32**, as serialize.go's
  `min, max, resolution float32` and `*float32` value are: the arm rounds
  `min`, `max`, `resolution` and the written value with `fround` first,
  exactly the `float32()` a Go caller applies at the call site, and a value
  that is NaN or infinite after rounding is misuse and raises
  (IMPLEMENTING.md, "The check model": a checked writer asserts on "a
  `compressed_float` value that is not finite"; serialize.go clamps such a
  value instead, and this writer is the checked build, (g)). For
  `serializeCompressedFloatPrecomputed` the constants must be exactly what
  `compressedFloatParams` derives (`delta` exactly a float32 among them),
  else it raises serialize.go's `panicPrecomputedFloat`.
- **The decode must be finite** (STANDARD.md, compressed_float). The reader
  refuses a decode that is not finite as `non_finite_float`, destination
  untouched, whatever the declaration. The WRITER, on both entry points,
  raises on a declaration whose top decode `fround(min + delta)` is not
  finite, even for a value that decodes finite: the declaration is
  non-conforming as a whole. So does a declaration whose `delta = fround(max -
  min)` or `fround(delta / resolution)` is not finite: write misuse
  (IMPLEMENTING.md, "The check model"), trapped, never clamped into
  `maxIntegerValue`. The measure makes the same checks by the same trap
  (U6). The reader never raises on any of them.
- **compressed_float's arithmetic is float32**, emulated by `fround` after
  EVERY operation (STANDARD.md, compressed_float: "This arithmetic is
  `float32`, and the two roundings are part of the format"): `delta = fround(max - min)`, `values = fround(delta / resolution)`, on write
  `normalized = fround(fround(value - min) / delta)`, clamped, `product = fround(normalized * fround(maxIntegerValue))`, `sum = fround(product + 0.5)`, then the floor and the integer clamp; on read `fround(fround( fround(integer) / fround(maxIntegerValue)) * delta) + min` rounded once
  more. Doubles never fuse a multiply and an add in Lua, so the barrier is
  the explicit `fround`. serialize.go v2 is the same arithmetic
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
- **The public surface is `require("serialize")`** (IMPLEMENTING.md U15,
  "Exports beyond the reference operations"): the names of the (a) tables,
  and nothing else. Lua cannot hide a module, so every `serialize_*` module
  is reachable by `require`, and every name on one (`serialize_stream`'s
  `family`, `lazy`, `method`, `DISPATCH`, `trapMisuse`; `serialize_float`'s
  `fround`, `float32Bits`, `float32FromBits`, `floatBitsAreFinite`,
  `doubleBitsAreFinite`; each family's `methods` and `api`; the `_`-prefixed
  stream primitives) is INTERNAL: this port promises nothing about them and
  may change them in any release.
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

**The writer is STRICT, and write misuse TRAPS** (IMPLEMENTING.md U9, "One
write-misuse mechanism: the trap"). It produces exactly serialize.go v2's
bytes. This port has no unchecked build, so it is a checked build always, and
its trap is Lua's `error()`, raised at the call, before any bit of the
operation is written, in every run. Every write misuse traps: a value outside
its range or bit width, a `float`, `double` or `compressed_float` value that
is not finite, a bad declaration, text that is not well-formed UTF-8, holds a
NUL or does not fit `bufferSize - 1`, a write buffer that is not a multiple
of 8 bytes, and an operation that does not fit the room left. A declaration's
raise message is serialize.go's panic string (`serialize: bits must be in
[1,32]`, `serialize: min must not be greater than max`, and the rest of
`serialize.go`'s `panic*` constants); a value's is `serialize: write misuse
(IMPLEMENTING.md U9): <reason>`, naming the reason a reader would give.
Beyond serialize.go, the type checks of (c) raise. **Write misuse never
latches**: a write stream has no refusal state, `error()` on it is always nil,
nothing returns false, and a write after a trap emits exactly what it would
have without it. `stream:fail()` on a write returns false, records nothing and
never traps; an object whose serialize returns false on a write makes
`serializeObject` return false and records nothing; `stream:reject()` on a
write traps. STANDARD.md's doctrine ("Writes assume trusted data") puts the
cost of these checks on the writer, and a Lua build has no release mode to
strip them from.

**Caller misuse, by stream** (IMPLEMENTING.md U7, U9, U16). Every arm's
`check` validates the caller's declaration (bit counts, bounds, Q formats,
buffer sizes, byte counts, the compressed float's parameters and precomputed
constants, int_relative's `previous`) and returns the rule's message rather
than raising. On a write or a measure the stream raises it, as above. On a
READ it is a refusal, never a raise: after the failure state is consulted (so
a failed stream keeps its first reason), a bad declaration, a holder that is
not a table, or a `serializeObject` argument that is not an object refuses as
`value_out_of_range` before any bit moves. The check costs the read path what
it cost before: the same comparisons, one branch on the result. A value that
does not fit its call (outside `[min,max]`, over its bit width (U8), a string
past its buffer, with a NUL or not UTF-8 (U4), a non-finite float) traps on a
write and a measure and writes nothing (U9); a write checks room for the
whole operation, length field, align and payload, before any bit, and traps
naming `past_end` when it does not fit (U10, U9).

**The reader forgives nothing** (format 2.0: "every value has exactly one
encoding"). A packet reader reads `serializeEnd()` after the top-level object:
it refuses a whole byte or more left over as `trailing_data`, then a set bit
in the final byte's padding as `nonzero_padding`, and an accepted end leaves
`bitsProcessed()` at 8 * #data (STANDARD.md, end).

    local rs = serialize.ReadStream.new(packet)
    local ok = rs:serializeObject(message) and rs:serializeEnd()
    -- not ok: rs:error() is the first refusal's reason

**Security trumps.** Every refusal STANDARD.md and serialize.go state binds in
every case, each with its reason (STANDARD.md, "Refusal reasons"): a decoded
value outside `[min,max]` or a decoded offset past the range, a string length
past its buffer, an int_relative reconstruction outside the domain or not
above `previous`, and a compressed integer above `maxIntegerValue`
(`value_out_of_range`); non-zero padding in an align, the aligns inside
`bytes` and `string` included, and in the final byte at the end
(`nonzero_padding`); a whole byte after the end (`trailing_data`); a `float`
or `double` pattern whose exponent is all ones, tested on the raw bits, and a
compressed decode that is not finite (`non_finite_float`); a NUL in a string
(`embedded_nul`, before the encoding is checked); ill-formed UTF-8
(`invalid_utf8`); the absolute int_relative tier carrying a difference a
bounded tier takes (`non_canonical`, after the domain rule); and every read
past the end (`past_end`). Where two rules meet, the order is STANDARD.md's:
align padding before the payload length, the NUL scan before UTF-8, trailing
data before end padding, the int_relative domain before the canonical tier.
The FIRST refusal's reason is the stream's; later refusals are echoes and keep
it. On each:

- the destination is untouched: the stream assigns `holder.value` only after
  the read arm reports success (STANDARD.md, Reader Obligations, "A refused
  primitive read must leave its destination unwritten"); a composite read
  (`serializeObject`) may leave earlier members written, as the standard
  allows;
- the stream is terminal: the first error latches and sticks; every later
  serialize call returns `false`, consumes no bits and writes no holder,
  zero-bit operations included (a degenerate range, an align on an aligned
  stream, a zero-count `serializeBytes`, `serializeObject`, `serializeEnd`); only `reset`
  clears it (STANDARD.md, Reader Obligations, "Failure is terminal": the
  latch shape);
- hostile bytes never raise: a raise on the read path is a bug (STANDARD.md:
  "A trap, a crash or an abort on malformed input is non-conforming"); every
  arithmetic step on read data is integer arithmetic that wraps, and no read
  path calls a function that raises on a value the wire can carry (a
  `string.unpack` past the end, `utf8.codepoint` on malformed bytes);
- no read past the data's end: the bounds test precedes every load (d).

The order of one serialize call (`serialize_stream.lua`, `M.method`). Write
and measure: the holder is a table, else raise; the family loads, else raise
"not implemented"; the arm's `check` runs (a bad declaration raises) and its
`checkValue` (a value of the wrong type raises); the arm runs, and traps on a
value its operation cannot carry (U9). There is no failed write or measure
state to consult. Read: the family loads, else raise "not implemented";
a failed stream returns `false`; a holder that is not a table or a bad
declaration refuses `value_out_of_range`; the arm runs; the stream settles
the result (a read assigns the holder only on success). Because the family
loads before the latch check, a method whose
family file is absent raises "not implemented" even on a failed stream: absent
code is not a runtime condition.

**The measure stream** (STANDARD.md, The Measure Stream) follows the writer's
misuse model, charges 7 bits per alignment-performing operation (`align`,
`bytes`, `string`; `alignBits()` is always 7) and exact widths for everything
else, and refuses nothing (IMPLEMENTING.md U6): it makes every check a write
makes, except room, which it does not have, by the same trap (U9), and
latches nothing, so its `error()` is always nil; `fail` returns false and an
object that refuses on it makes `serializeObject` return false, recording
nothing. Its end costs nothing.

## (h) THE FILE LAYOUT

| file | card | what it exports |
|---|---|---|
| `src/serialize.lua` | serialize-lua-design | the entry: the API table of (a); lazy stubs for every family function |
| `src/serialize_stream.lua` | serialize-lua-design | the three streams, the latch, terminality, bit accounting, `serializeAlign`, `serializeEnd`, `serializeObject`, the lazy loader (`family`, `lazy`, `method`) and the dispatch table |
| `src/serialize_bitpacker.lua` | serialize-lua-bitpacker | `api.BitWriter.new`, `api.BitReader.new` |
| `src/serialize_bits.lua` | serialize-lua-bits | arms `serializeBits`, `serializeBits64`, `serializeBool`, `serializeUint8`, `serializeUint16`, `serializeUint32`, `serializeUint64`; `api.bitsRequired`, `api.bitsRequired64`, `api.signedToUnsigned`, `api.unsignedToSigned` |
| `src/serialize_int.lua` | serialize-lua-int | arms `serializeInt`, `serializeInt64` |
| `src/serialize_int128.lua` | serialize-lua-int | arms `serializeInt128`, `serializeUint128`; `api.bitsRequired128`, `api.Uint128.*`, `api.Int128.*` |
| `src/serialize_fixed.lua` | serialize-lua-fixed | arm `serializeFixed` |
| `src/serialize_int_relative.lua` | serialize-lua-int-relative | arm `serializeIntRelative` |
| `src/serialize_float.lua` | serialize-lua-float | arms `serializeFloat`, `serializeDouble`; module fields `fround`, `float32Bits`, `float32FromBits` |
| `src/serialize_compressed_float.lua` | serialize-lua-compressed-float | arms `serializeCompressedFloat`, `serializeCompressedFloatPrecomputed`; `api.compressedFloatParams` |
| `src/serialize_bytes.lua` | serialize-lua-strings | arms `serializeBytes`, `serializeString` |

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
  outside `[min,max]` is caught by the write and measure arms: they trap
  (U9).
- `write(stream, ...)` and `measure(stream, ...)` receive the arguments with
  `holder.value` in the holder's place (`serializeIntRelative`:
  `write(stream, previous, value)`). They return `true`, or trap through a
  primitive or `stream:_fail(reason)`, which on a write or a measure stream is
  the trap (U9): it raises `serialize: write misuse (IMPLEMENTING.md U9):
  <reason>` and records nothing; `reason` is one of `serialize.Refusal`'s.
- `read(stream, ...)` receives the arguments without the holder and returns
  `true, value` or `false` (after latching). It never touches a holder: the
  stream assigns it.
- A read arm that returns `false` without a latched error, `true` on a failed
  stream, or a non-boolean, raises `serialize: <name> returned false without latching an error` (and its siblings); a write or measure arm that returns anything but `true` raises `serialize: <name> write or measure arm must return true or trap`: the contract is held, not trusted.
- A family module reaches another family through the stream module's loader,
  `require("serialize_stream").family("int128", "serializeFixed")`, never a
  bare `require` and never through the entry, so a sibling whose file is
  absent raises `serialize: serializeFixed not implemented` rather than
  `module not found`.

**The primitives an arm calls**, all in `serialize_stream.lua`; the read
primitives check the latch first:

| primitive | stream | what |
|---|---|---|
| `stream:_writeBits(value, bits)` | W | bits in [1,64]; value masked to bits; the TOTAL width is checked against the capacity before anything is written (else the trap, naming `past_end`, U9); bits > 32 split low 32 first; returns true |
| `stream:_writeBytes(s)` | W | the stream must be aligned (else raises serialize.go's `panicNotAligned`); the trap naming `past_end` if it does not fit (U9); returns true |
| `stream:_readBits(bits)` | R | bits in [1,64]; the bounds test precedes the load; returns the integer, or nil after latching `past_end` |
| `stream:_readBytes(n)` | R | aligned; returns a fresh string of n bytes, or nil after latching `past_end`; the count is compared with what remains, in bytes, before anything is read |
| `stream:_measure(bits)` | M | adds bits; returns true |
| `stream:_fail(reason)` | W R M | R: latches reason if nothing is latched, returns false; W and M: the trap (U9), records nothing |
| `stream:serializeAlign()` | W R M | the public align, callable from an arm (the bytes family aligns first) |

The write and read primitives build the bitpacker's `BitWriter` or
`BitReader` lazily, on their first load or store, so until
`serialize_bitpacker.lua` exists they raise `serialize: BitWriter.new not implemented` (or `BitReader.new`) on the first bit actually moved. The
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
  repository root, as `dist/lua-5.4.8/src/lua -E build/test_runner.lua <file>` (`-E`: `LUA_PATH`, `LUA_CPATH` and `LUA_INIT` are never consulted).
  `build/test_runner.lua` is written from the Makefile's `TEST_RUNNER`; it
  replaces `package.path` with `./src/?.lua` and sets `package.cpath = ""`
  (f), then loads the test file.
- A test file declares global functions named `Test<Name>`; the runner calls
  each in declaration order and prints `RUN Test<Name>`, then `--- PASS Test<Name>` or `--- FAIL Test<Name>` (with the raise and its traceback). A
  test fails by raising. A file that declares no test, or raises while
  loading, fails by name. The last line is `ok   make test` or `FAIL make test`, and the exit status is nonzero on any failure.
- Unit tests use no real time, no sockets, no network and no outside
  services; a test clock is an argument and starts at 1000.0. `make dist-lua`
  is setup, run once before the tests, never from a test.
