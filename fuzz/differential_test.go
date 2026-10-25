// Package fuzz tests the Lua serialize port differentially against serialize.go:
// for every generated program the two writers must emit identical bytes, each
// side must read the other's bytes back to the program's values, and on mutation
// the readers must agree on whether, where, for what reason and with what values
// they stop. Every program ends with serialize_end, as a packet reader must
// (STANDARD.md, end), so a mutation that leaves a byte over or sets a padding
// bit is refused by both readers, for the same reason.
package fuzz

import (
	"bytes"
	"encoding/hex"
	"flag"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/mas-bandwidth/serialize.go/v2"
)

// widenIntRange, when set via -widen-int, makes the Go writer use int ranges one
// bit wider than the Lua side declares, so the bytes differ and the test goes red.
// It is the negative control: the same harness, one deliberate divergence.
var widenIntRange = false

// defaultSeed is the per-push gate's seed: every push runs the same programs.
const defaultSeed = 0x1234567890abcdef

// The extended-run knobs. Their defaults are the per-push gate exactly: one
// round of 2000 programs from defaultSeed. The nightly run passes a seed that
// varies per run and a duration, and the seed is logged first so a failure
// reproduces with -seed=<logged value> (rounds are drawn in order from one
// generator, so the failing round is reached again from the same seed).
var (
	fuzzSeed     uint64
	fuzzPrograms int
	fuzzRounds   int
	fuzzDuration time.Duration
	failuresDir  string
)

func init() {
	flag.BoolVar(&widenIntRange, "widen-int", false, "negative control: widen the int64 range by one bit")
	flag.Uint64Var(&fuzzSeed, "seed", defaultSeed, "generator seed; logged at the start of every run")
	flag.IntVar(&fuzzPrograms, "programs", 2000, "programs per round")
	flag.IntVar(&fuzzRounds, "rounds", 1, "run at least this many rounds")
	flag.DurationVar(&fuzzDuration, "duration", 0, "keep running rounds until this much time has passed (0: stop after -rounds)")
	flag.StringVar(&failuresDir, "failures-dir", "", "on a failure, write the failing program and its bytes here")
}

const bufferSize = 1 << 16

type op struct {
	kind    string
	width   int
	lo, hi  int64
	valI    int64
	valU    uint64
	valF32  float32
	valF64  float64
	payload []byte
	bufSize int
	prev    int32

	ib, fb int

	cfMin, cfMax, cfRes uint32

	min128, max128, val128 serialize.Int128
	u128                   serialize.Uint128

	objU uint32
	objB bool
}

func (o op) f32bits(bits uint32) float32 { return math.Float32frombits(bits) }

// emitLua renders the op as a driver.lua command line. Values wider than a
// Lua-accurate decimal are written as hex bit patterns.
func (o op) emitLua() string {
	switch o.kind {
	case "bits":
		return fmt.Sprintf("bits %x %d", uint32(o.valU), o.width)
	case "bits64":
		return fmt.Sprintf("bits64 %x %d", o.valU, o.width)
	case "bool":
		if o.valU != 0 {
			return "bool 1"
		}
		return "bool 0"
	case "u8", "u16", "u32":
		return fmt.Sprintf("%s %d", o.kind, o.valU)
	case "u64":
		return fmt.Sprintf("u64 %x", o.valU)
	case "int":
		return fmt.Sprintf("int %d %d %d", o.valI, o.lo, o.hi)
	case "int64":
		return fmt.Sprintf("int64 %x %x %x", uint64(o.valI), uint64(o.lo), uint64(o.hi))
	case "u128":
		return fmt.Sprintf("u128 %x %x", o.u128.Lo, o.u128.Hi)
	case "i128":
		return fmt.Sprintf("i128 %x %x %x %x %x %x",
			o.min128.Lo, o.min128.Hi, o.max128.Lo, o.max128.Hi, o.val128.Lo, o.val128.Hi)
	case "fixed64":
		return fmt.Sprintf("fixed64 %d %d %d %d %d", o.valI, o.ib, o.fb, o.lo, o.hi)
	case "fixed128":
		return fmt.Sprintf("fixed128 %x %x %d %d %d %d",
			o.val128.Lo, o.val128.Hi, o.ib, o.fb, o.lo, o.hi)
	case "intrel":
		return fmt.Sprintf("intrel %d %d", o.prev, o.valI)
	case "float":
		return fmt.Sprintf("float %08x", math.Float32bits(o.valF32))
	case "double":
		return fmt.Sprintf("double %016x", math.Float64bits(o.valF64))
	case "cfloat":
		return fmt.Sprintf("cfloat %08x %08x %08x %08x",
			math.Float32bits(o.valF32), o.cfMin, o.cfMax, o.cfRes)
	case "bytes":
		return fmt.Sprintf("bytes %s %d", hexOrDot(o.payload), len(o.payload))
	case "str":
		return fmt.Sprintf("%s %s %d", o.kind, hexOrDot(o.payload), o.bufSize)
	case "align":
		return "align"
	case "end":
		return "end"
	case "object":
		if o.objB {
			return fmt.Sprintf("object %d 1", o.objU)
		}
		return fmt.Sprintf("object %d 0", o.objU)
	}
	return ""
}

func hexOrDot(b []byte) string {
	h := hex.EncodeToString(b)
	if h == "" {
		return "."
	}
	return h
}

// fuzzObject is the object operation: a uint32 and a bool through SerializeObject.
type fuzzObject struct {
	u uint32
	b bool
}

func (o *fuzzObject) Serialize(s serialize.Stream) error {
	u := o.u
	if s.IsReading() {
		u = 0
	}
	if err := s.SerializeUint32(&u); err != nil {
		return err
	}
	o.u = u
	b := o.b
	if s.IsReading() {
		b = false
	}
	if err := s.SerializeBool(&b); err != nil {
		return err
	}
	o.b = b
	return nil
}

func (o *op) write(w *serialize.WriteStream) {
	switch o.kind {
	case "bits":
		v := uint32(o.valU)
		w.SerializeBits(&v, o.width)
	case "bits64":
		v := o.valU
		w.SerializeBits64(&v, o.width)
	case "bool":
		v := o.valU != 0
		w.SerializeBool(&v)
	case "u8":
		v := uint8(o.valU)
		w.SerializeUint8(&v)
	case "u16":
		v := uint16(o.valU)
		w.SerializeUint16(&v)
	case "u32":
		v := uint32(o.valU)
		w.SerializeUint32(&v)
	case "u64":
		v := o.valU
		w.SerializeUint64(&v)
	case "int":
		v := int32(o.valI)
		w.SerializeInt(&v, int32(o.lo), int32(o.hi))
	case "int64":
		v := o.valI
		if widenIntRange {
			w.SerializeInt64(&v, o.lo, negMax(o.hi))
		} else {
			w.SerializeInt64(&v, o.lo, o.hi)
		}
	case "u128":
		v := o.u128
		w.SerializeUint128(&v)
	case "i128":
		v := o.val128
		w.SerializeInt128(&v, o.min128, o.max128)
	case "fixed64":
		v := o.valI
		w.SerializeFixed64(&v, o.ib, o.fb, o.lo, o.hi)
	case "fixed128":
		v := o.val128
		w.SerializeFixed128(&v, o.ib, o.fb, o.lo, o.hi)
	case "intrel":
		v := int32(o.valI)
		w.SerializeIntRelative(o.prev, &v)
	case "float":
		v := o.valF32
		w.SerializeFloat32(&v)
	case "double":
		v := o.valF64
		w.SerializeFloat64(&v)
	case "cfloat":
		v := o.valF32
		w.SerializeCompressedFloat32(&v, o.f32bits(o.cfMin), o.f32bits(o.cfMax), o.f32bits(o.cfRes))
	case "bytes":
		w.SerializeBytes(o.payload)
	case "str":
		v := string(o.payload)
		w.SerializeString(&v, o.bufSize)
	case "align":
		w.SerializeAlign()
	case "end":
		w.SerializeEnd()
	case "object":
		w.SerializeObject(&fuzzObject{u: o.objU, b: o.objB})
	}
}

// read replays the op on a reader and returns its decoded value as a token, or
// false at the first refusal.
func (o op) read(r *serialize.ReadStream) (bool, string) {
	switch o.kind {
	case "bits":
		var v uint32
		if r.SerializeBits(&v, o.width) != nil {
			return false, ""
		}
		return true, strconv.FormatUint(uint64(v), 10)
	case "bits64":
		var v uint64
		if r.SerializeBits64(&v, o.width) != nil {
			return false, ""
		}
		return true, tokSigned(int64(v))
	case "bool":
		var v bool
		if r.SerializeBool(&v) != nil {
			return false, ""
		}
		return true, tokBool(v)
	case "u8":
		var v uint8
		if r.SerializeUint8(&v) != nil {
			return false, ""
		}
		return true, strconv.FormatUint(uint64(v), 10)
	case "u16":
		var v uint16
		if r.SerializeUint16(&v) != nil {
			return false, ""
		}
		return true, strconv.FormatUint(uint64(v), 10)
	case "u32":
		var v uint32
		if r.SerializeUint32(&v) != nil {
			return false, ""
		}
		return true, strconv.FormatUint(uint64(v), 10)
	case "u64":
		var v uint64
		if r.SerializeUint64(&v) != nil {
			return false, ""
		}
		return true, tokSigned(int64(v))
	case "int":
		var v int32
		if r.SerializeInt(&v, int32(o.lo), int32(o.hi)) != nil {
			return false, ""
		}
		return true, tokSigned(int64(v))
	case "int64":
		var v int64
		var err error
		if widenIntRange {
			err = r.SerializeInt64(&v, o.lo, negMax(o.hi))
		} else {
			err = r.SerializeInt64(&v, o.lo, o.hi)
		}
		if err != nil {
			return false, ""
		}
		return true, tokSigned(v)
	case "u128":
		var v serialize.Uint128
		if r.SerializeUint128(&v) != nil {
			return false, ""
		}
		return true, tokPair(v.Lo, v.Hi)
	case "i128":
		var v serialize.Int128
		if r.SerializeInt128(&v, o.min128, o.max128) != nil {
			return false, ""
		}
		return true, tokPair(v.Lo, v.Hi)
	case "fixed64":
		var v int64
		if r.SerializeFixed64(&v, o.ib, o.fb, o.lo, o.hi) != nil {
			return false, ""
		}
		return true, tokSigned(v)
	case "fixed128":
		var v serialize.Int128
		if r.SerializeFixed128(&v, o.ib, o.fb, o.lo, o.hi) != nil {
			return false, ""
		}
		return true, tokPair(v.Lo, v.Hi)
	case "intrel":
		var v int32
		if r.SerializeIntRelative(o.prev, &v) != nil {
			return false, ""
		}
		return true, tokSigned(int64(v))
	case "float":
		var v float32
		if r.SerializeFloat32(&v) != nil {
			return false, ""
		}
		return true, fmt.Sprintf("%08x", math.Float32bits(v))
	case "double":
		var v float64
		if r.SerializeFloat64(&v) != nil {
			return false, ""
		}
		return true, fmt.Sprintf("%016x", math.Float64bits(v))
	case "cfloat":
		var v float32
		if r.SerializeCompressedFloat32(&v, o.f32bits(o.cfMin), o.f32bits(o.cfMax), o.f32bits(o.cfRes)) != nil {
			return false, ""
		}
		return true, fmt.Sprintf("%08x", math.Float32bits(v))
	case "bytes":
		buf := make([]byte, len(o.payload))
		if r.SerializeBytes(buf) != nil {
			return false, ""
		}
		return true, hexOrDot(buf)
	case "str":
		var v string
		if r.SerializeString(&v, o.bufSize) != nil {
			return false, ""
		}
		return true, hexOrDot([]byte(v))
	case "align":
		if r.SerializeAlign() != nil {
			return false, ""
		}
		return true, "-"
	case "end":
		if r.SerializeEnd() != nil {
			return false, ""
		}
		return true, "-"
	case "object":
		obj := fuzzObject{}
		if r.SerializeObject(&obj) != nil {
			return false, ""
		}
		return true, fmt.Sprintf("%d,%d", obj.u, boolDigit(obj.b))
	}
	return false, ""
}

func tokSigned(v int64) string { return strconv.FormatInt(v, 10) }

func tokBool(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

func boolDigit(v bool) int {
	if v {
		return 1
	}
	return 0
}

func tokPair(lo, hi uint64) string {
	return fmt.Sprintf("%d,%d", int64(lo), int64(hi))
}

type program struct {
	ops []op
}

// rng is seeded from -seed when the test starts (flags are parsed by then).
// math/rand/v2; the seed never comes from the clock.
var rng *rand.Rand

func seedRNG(seed uint64) {
	rng = rand.New(rand.NewPCG(seed, 0x0ddc0ffee))
}

func randRange(lo, hi int64) int64 {
	if lo >= hi {
		return lo
	}
	span := uint64(hi) - uint64(lo)
	if span == math.MaxUint64 {
		return int64(rng.Uint64())
	}
	return int64(uint64(lo) + rng.Uint64N(span+1))
}

func randU32() uint32 { return rng.Uint32() }

func randU64() uint64 { return rng.Uint64() }

func mask32(width int) uint64 {
	if width >= 32 {
		return math.MaxUint32
	}
	return (uint64(1) << width) - 1
}

func mask64(width int) uint64 {
	if width >= 64 {
		return math.MaxUint64
	}
	return (uint64(1) << width) - 1
}

// negMax returns a widened upper bound for the negative control, never producing
// min > max: widening a negative upper bound would shrink the range.
func negMax(hi int64) int64 {
	if hi < 0 || hi > (math.MaxInt64-1)/2 {
		return hi
	}
	return hi*2 + 1
}

func randInt128() serialize.Int128 {
	return serialize.Int128{Lo: randU64(), Hi: randU64()}
}

func randOp() op {
	var o op
	switch rng.IntN(21) {
	case 0: // bits
		o.kind = "bits"
		o.width = int(randRange(1, 32))
		o.valU = randU64() & mask32(o.width)
	case 1: // bits64
		o.kind = "bits64"
		o.width = int(randRange(1, 64))
		o.valU = randU64() & mask64(o.width)
	case 2: // bool
		o.kind = "bool"
		o.valU = uint64(rng.IntN(2))
	case 3: // u8
		o.kind = "u8"
		o.valU = uint64(randU32() & 0xff)
	case 4: // u16
		o.kind = "u16"
		o.valU = uint64(randU32() & 0xffff)
	case 5: // u32
		o.kind = "u32"
		o.valU = uint64(randU32())
	case 6: // u64
		o.kind = "u64"
		o.valU = randU64()
	case 7: // int32 ranged, with degenerate and edge ranges
		o.kind = "int"
		switch rng.IntN(4) {
		case 0:
			o.lo = randRange(-100000, 100000)
			o.hi = o.lo + randRange(0, 200000)
			o.valI = randRange(o.lo, o.hi)
		case 1:
			o.lo = int64(rng.Int32())
			o.hi = o.lo
			o.valI = o.lo
		case 2:
			o.lo = math.MinInt32
			o.hi = math.MaxInt32
			o.valI = int64(rng.Int32())
		default:
			o.lo = math.MinInt32
			o.hi = math.MinInt32 + randRange(0, 1<<20)
			o.valI = randRange(o.lo, o.hi)
		}
	case 8: // int64 ranged, with degenerate and edge ranges
		o.kind = "int64"
		switch rng.IntN(5) {
		case 0:
			o.lo = randRange(-1<<40, 1<<40)
			o.hi = o.lo + randRange(0, 1<<44)
			o.valI = randRange(o.lo, o.hi)
		case 1:
			o.lo = int64(rng.Uint64())
			o.hi = o.lo
			o.valI = o.lo
		case 2:
			o.lo = math.MinInt64
			o.hi = o.lo + randRange(0, 1<<20)
			o.valI = randRange(o.lo, o.hi)
		case 3:
			o.hi = math.MaxInt64
			o.lo = o.hi - randRange(0, 1<<20)
			o.valI = randRange(o.lo, o.hi)
		default:
			o.lo = math.MinInt32
			o.hi = math.MaxInt32
			o.valI = int64(rng.Int32())
		}
	case 9: // uint128 raw
		o.kind = "u128"
		o.u128 = serialize.Uint128{Lo: randU64(), Hi: randU64()}
	case 10: // int128 ranged: small, wide positive, full 127-bit, negative, degenerate
		o.kind = "i128"
		switch rng.IntN(5) {
		case 0:
			lo := randRange(-1<<40, 1<<40)
			hi := lo + randRange(0, 1<<40)
			o.min128 = serialize.Int128From64(lo)
			o.max128 = serialize.Int128From64(hi)
			o.val128 = serialize.Int128From64(randRange(lo, hi))
		case 1:
			o.min128 = serialize.Int128{Lo: randU64(), Hi: randU64() & 0x3fffffffffffffff}
			span := randRange(0, 1<<32)
			o.max128 = o.min128.Add(serialize.Int128From64(span))
			o.val128 = o.min128.Add(serialize.Int128From64(randRange(0, span)))
		case 2:
			o.min128 = serialize.Int128{}
			o.max128 = serialize.Int128{Lo: math.MaxUint64, Hi: math.MaxInt64}
			o.val128 = serialize.Int128{Lo: randU64(), Hi: randU64() & math.MaxInt64}
		case 3:
			o.min128 = serialize.Int128{Lo: randU64(), Hi: randU64() | 0x8000000000000000}
			span := randRange(0, 1<<40)
			o.max128 = o.min128.Add(serialize.Int128From64(span))
			o.val128 = o.min128.Add(serialize.Int128From64(randRange(0, span)))
		default:
			v := randInt128()
			o.min128 = v
			o.max128 = v
			o.val128 = v
		}
	case 11: // fixed64
		o.kind = "fixed64"
		switch rng.IntN(4) {
		case 0:
			o.ib = int(randRange(8, 30))
			o.fb = int(randRange(0, 16))
			o.lo = randRange(-100, 0)
			o.hi = o.lo + randRange(0, 100)
		case 1:
			o.ib = 32
			o.fb = 0
			o.lo = math.MinInt32
			o.hi = math.MaxInt32
		case 2:
			o.ib = 16
			o.fb = 16
			o.lo = -(1 << 15)
			o.hi = (1 << 15) - 1
		default:
			o.ib = int(randRange(8, 20))
			o.fb = int(randRange(0, 8))
			o.lo = randRange(-100, 100)
			o.hi = o.lo
		}
		o.valI = randRange(o.lo<<o.fb, o.hi<<o.fb)
	case 12: // fixed128 (Q format with integerBits + fractionBits == 128)
		o.kind = "fixed128"
		o.fb = int(randRange(1, 48))
		o.ib = 128 - o.fb
		o.lo = randRange(-1<<20, 0)
		o.hi = o.lo + randRange(0, 1<<20)
		if rng.IntN(4) == 0 {
			o.hi = o.lo
		}
		whole := randRange(o.lo, o.hi)
		o.val128 = serialize.Int128From64(whole).Lsh(uint(o.fb))
	case 13: // int_relative
		o.kind = "intrel"
		switch rng.IntN(3) {
		case 0:
			o.prev = 0
			o.valI = 1
		case 1:
			o.prev = math.MaxInt32 - 1
			o.valI = math.MaxInt32
		default:
			o.prev = int32(randRange(0, math.MaxInt32-1))
			o.valI = randRange(int64(o.prev)+1, math.MaxInt32)
		}
	case 14: // float32: finite patterns only (format 2.0), the edges included
		o.kind = "float"
		bits := randU32()
		switch rng.IntN(8) {
		case 0: // a subnormal or a signed zero
			bits &= 0x807fffff
		case 1: // the top binade, up to FLT_MAX
			bits = (bits & 0x807fffff) | 0x7f000000
		}
		if bits&0x7f800000 == 0x7f800000 {
			bits &^= 0x00800000 // never NaN or an infinity: the writer refuses them
		}
		o.valF32 = math.Float32frombits(bits)
	case 15: // double: finite patterns only (format 2.0), the edges included
		o.kind = "double"
		bits := randU64()
		switch rng.IntN(8) {
		case 0: // a subnormal or a signed zero
			bits &= 0x800fffffffffffff
		case 1: // the top binade, up to the largest finite double
			bits = (bits & 0x800fffffffffffff) | 0x7fe0000000000000
		}
		if bits&0x7ff0000000000000 == 0x7ff0000000000000 {
			bits &^= 0x0010000000000000
		}
		o.valF64 = math.Float64frombits(bits)
	case 16: // compressed float32, exactly representable integers at resolution 1
		o.kind = "cfloat"
		lo := int32(randRange(-1000, -1))
		hi := int32(randRange(1, 1000))
		o.cfMin = math.Float32bits(float32(lo))
		o.cfMax = math.Float32bits(float32(hi))
		o.cfRes = math.Float32bits(1)
		o.valF32 = float32(randRange(int64(lo), int64(hi)))
	case 17: // bytes
		o.kind = "bytes"
		n := int(randRange(0, 64))
		o.payload = make([]byte, n)
		for i := range o.payload {
			o.payload[i] = byte(randU32())
		}
	case 18: // string
		o.kind = "str"
		o.bufSize = int(randRange(1, 256))
		n := int(randRange(0, int64(o.bufSize)-1))
		o.payload = make([]byte, n)
		for i := range o.payload {
			o.payload[i] = byte(randRange(1, 0x7f))
		}
	case 19: // align
		o.kind = "align"
	default: // object
		o.kind = "object"
		o.objU = randU32()
		o.objB = rng.IntN(2) == 1
	}
	return o
}

func genProgram() program {
	n := int(randRange(1, 24))
	var p program
	for i := 0; i < n; i++ {
		p.ops = append(p.ops, randOp())
	}
	// a packet is one object and its end (STANDARD.md, end)
	p.ops = append(p.ops, op{kind: "end"})
	return p
}

func writeGo(p program) ([]byte, bool) {
	buf := make([]byte, bufferSize)
	w := serialize.NewWriteStream(buf)
	for _, o := range p.ops {
		o.write(w)
	}
	w.Flush()
	return w.Data(), w.Err() == nil
}

func writeAllGo(programs []program) [][]byte {
	out := make([][]byte, len(programs))
	for i, p := range programs {
		d, _ := writeGo(p)
		out[i] = d
	}
	return out
}

func luaInterp() string {
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	root := filepath.Dir(wd)
	return filepath.Join(root, "dist", "lua-5.4.8", "src", "lua")
}

func repoRoot() string {
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	return filepath.Dir(wd)
}

func runLua(t *testing.T, batchFile string) []string {
	cmd := exec.Command(luaInterp(), "-E", filepath.Join(repoRoot(), "fuzz", "driver.lua"), batchFile)
	cmd.Dir = repoRoot() // repo root so package.path=./src works
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("driver failed: %v\nstderr:%s", err, stderr.String())
	}
	var lines []string
	for _, ln := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(ln, "HEX ") || strings.HasPrefix(ln, "READ ") {
			lines = append(lines, ln)
		}
	}
	return lines
}

func parseWriteLine(t *testing.T, line string) []byte {
	if !strings.HasPrefix(line, "HEX ") {
		t.Fatalf("expected HEX line, got %q", line)
	}
	b, err := hex.DecodeString(strings.TrimPrefix(line, "HEX "))
	if err != nil {
		t.Fatalf("bad HEX line %q: %v", line, err)
	}
	return b
}

type readResult struct {
	n      int
	reason string // the first refusal's reason as STANDARD.md spells it, "ok" if none
	tokens []string
}

func parseReadLine(t *testing.T, line string) readResult {
	if !strings.HasPrefix(line, "READ ") {
		t.Fatalf("expected READ line, got %q", line)
	}
	fields := strings.Fields(line)
	if len(fields) < 2 {
		t.Fatalf("short READ line %q", line)
	}
	n, err := strconv.Atoi(fields[1])
	if err != nil {
		t.Fatalf("bad READ count in %q: %v", line, err)
	}
	if len(fields) < 3 {
		t.Fatalf("READ line %q carries no reason", line)
	}
	tokens := fields[3:]
	if len(tokens) != n {
		t.Fatalf("READ line %q reports %d but carries %d tokens", line, n, len(tokens))
	}
	return readResult{n: n, reason: fields[2], tokens: tokens}
}

func mutateBytes(b []byte) []byte {
	if len(b) == 0 {
		return b
	}
	switch rng.IntN(3) {
	case 0: // bit flip
		cp := append([]byte(nil), b...)
		i := rng.IntN(len(cp))
		cp[i] ^= 1 << rng.IntN(8)
		return cp
	case 1: // truncation
		if len(b) <= 1 {
			return b[:0]
		}
		return b[:rng.IntN(len(b))]
	default: // extension
		cp := append([]byte(nil), b...)
		cp = append(cp, byte(rng.IntN(256)))
		return cp
	}
}

// readGo replays the program over data and returns how many ops decoded and the
// token of each value decoded before the first refusal.
func readGo(p program, data []byte) readResult {
	r := serialize.NewReadStream(data)
	var res readResult
	for _, o := range p.ops {
		ok, tok := o.read(r)
		if !ok {
			break
		}
		res.tokens = append(res.tokens, tok)
	}
	res.n = len(res.tokens)
	res.reason = "ok"
	if err := r.Err(); err != nil {
		refusal, isRefusal := err.(serialize.Refusal)
		if !isRefusal {
			panic(fmt.Sprintf("go reader latched a non-refusal error %v", err))
		}
		res.reason = refusal.String()
	}
	return res
}

// programTokens is what a clean read must return: the values the program wrote.
func programTokens(p program) []string {
	toks := make([]string, len(p.ops))
	for i, o := range p.ops {
		toks[i] = expectedToken(o)
	}
	return toks
}

func expectedToken(o op) string {
	switch o.kind {
	case "bits":
		return strconv.FormatUint(uint64(uint32(o.valU)), 10)
	case "bits64":
		return tokSigned(int64(o.valU))
	case "bool":
		return tokBool(o.valU != 0)
	case "u8", "u16", "u32":
		return strconv.FormatUint(o.valU, 10)
	case "u64":
		return tokSigned(int64(o.valU))
	case "int", "int64", "intrel":
		return tokSigned(o.valI)
	case "u128":
		return tokPair(o.u128.Lo, o.u128.Hi)
	case "i128", "fixed128":
		return tokPair(o.val128.Lo, o.val128.Hi)
	case "fixed64":
		return tokSigned(o.valI)
	case "float", "cfloat":
		return fmt.Sprintf("%08x", math.Float32bits(o.valF32))
	case "double":
		return fmt.Sprintf("%016x", math.Float64bits(o.valF64))
	case "bytes", "str":
		return hexOrDot(o.payload)
	case "align", "end":
		return "-"
	case "object":
		return fmt.Sprintf("%d,%d", o.objU, boolDigit(o.objB))
	}
	return ""
}

// valuesAgree compares decoded values against the program. Compressed floats are
// lossy by design: their quantization is compared Lua-to-Go elsewhere, while every
// other operation must decode back to exactly the value written.
func valuesAgree(want, got []string, p program) int {
	if len(want) != len(got) {
		return firstDiff(want, got)
	}
	for i := range want {
		if p.ops[i].kind == "cfloat" {
			continue
		}
		if want[i] != got[i] {
			return i
		}
	}
	return -1
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func dumpProgram(p program) string {
	var sb strings.Builder
	for _, o := range p.ops {
		sb.WriteString(o.emitLua())
		sb.WriteString("\n")
	}
	return sb.String()
}

func TestDifferentialAgainstSerializeGo(t *testing.T) {
	const batch = 100
	if fuzzPrograms < 1 {
		t.Fatalf("-programs must be at least 1, got %d", fuzzPrograms)
	}
	seedRNG(fuzzSeed)
	if fuzzRounds < 1 {
		t.Fatalf("-rounds must be at least 1, got %d", fuzzRounds)
	}
	t.Logf("seed %d (0x%x), %d programs per round, at least %d rounds, duration %s",
		fuzzSeed, fuzzSeed, fuzzPrograms, fuzzRounds, fuzzDuration)

	tmp := t.TempDir()
	if failuresDir != "" {
		// Any failure, the driver's included, keeps the batch files the Lua
		// side was given, beside the per-program reports below.
		t.Cleanup(func() {
			if !t.Failed() {
				return
			}
			saveBatches(t, tmp)
		})
	}

	seen := map[string]bool{}
	totalPrograms, totalMutated, rounds := 0, 0, 0
	// The deadline is wall-clock time, the knob an extended run is budgeted in.
	// This is the functional tier (it spawns the interpreter), never a unit test.
	deadline := time.Now().Add(fuzzDuration)
	for {
		mutated := runRound(t, rounds, fuzzPrograms, batch, tmp, seen)
		totalPrograms += fuzzPrograms
		totalMutated += mutated
		rounds++
		if rounds >= fuzzRounds && (fuzzDuration <= 0 || !time.Now().Before(deadline)) {
			break
		}
	}
	for _, kind := range []string{
		"bits", "bits64", "bool", "u8", "u16", "u32", "u64", "u128",
		"int", "int64", "i128", "fixed64", "fixed128", "intrel",
		"float", "double", "cfloat", "bytes", "str", "align", "object", "end",
	} {
		if !seen[kind] {
			t.Fatalf("generated programs never exercise %s", kind)
		}
	}
	t.Logf("ok  seed %d: %d rounds, %d programs, %d mutated, %d operation kinds",
		fuzzSeed, rounds, totalPrograms, totalMutated, len(seen))
}

// reproLine is the command that runs the same programs again, through the
// given round (rounds are drawn in order from one generator).
func reproLine(round int) string {
	line := fmt.Sprintf("reproduce: cd fuzz && go test -count=1 -timeout 0 -run TestDifferentialAgainstSerializeGo -v -seed=%d -programs=%d -rounds=%d",
		fuzzSeed, fuzzPrograms, round+1)
	if widenIntRange {
		line += " -widen-int"
	}
	return line
}

// saveBatches copies the round's driver batch files into -failures-dir.
func saveBatches(t *testing.T, tmp string) {
	if err := os.MkdirAll(failuresDir, 0o755); err != nil {
		t.Logf("failures-dir: %v", err)
		return
	}
	entries, err := os.ReadDir(tmp)
	if err != nil {
		t.Logf("failures-dir: %v", err)
		return
	}
	for _, e := range entries {
		data, err := os.ReadFile(filepath.Join(tmp, e.Name()))
		if err != nil {
			continue
		}
		name := fmt.Sprintf("seed-%d-%s", fuzzSeed, e.Name())
		if err := os.WriteFile(filepath.Join(failuresDir, name), data, 0o644); err != nil {
			t.Logf("failures-dir: %v", err)
		}
	}
}

// runRound generates n programs from rng and checks them; it returns how many
// were mutated. A failure names the seed and round, writes the failing program
// to -failures-dir when set, and stops the test.
func runRound(t *testing.T, round, n, batch int, tmp string, seen map[string]bool) int {
	repro := reproLine(round)
	fail := func(i int, format string, args ...any) {
		t.Helper()
		msg := fmt.Sprintf("round %d ", round) + fmt.Sprintf(format, args...)
		if failuresDir != "" {
			report := fmt.Sprintf("seed %d (0x%x)\n%s\n\n%s\n", fuzzSeed, fuzzSeed, repro, msg)
			name := fmt.Sprintf("seed-%d-round-%d-program-%d.txt", fuzzSeed, round, i)
			if err := os.MkdirAll(failuresDir, 0o755); err == nil {
				if err := os.WriteFile(filepath.Join(failuresDir, name), []byte(report), 0o644); err != nil {
					t.Logf("failures-dir: %v", err)
				}
			}
		}
		t.Fatalf("seed %d: %s\n%s", fuzzSeed, msg, repro)
	}

	programs := make([]program, n)
	for i := range programs {
		programs[i] = genProgram()
		for _, o := range programs[i].ops {
			seen[o.kind] = true
		}
	}

	goBytes := writeAllGo(programs)

	// 1 in 4 programs is mutated before the readers see it.
	mutated := make([][]byte, n)
	mutatedCount := 0
	for i := 0; i < n; i++ {
		if rng.IntN(4) != 0 {
			continue
		}
		mutated[i] = mutateBytes(goBytes[i])
		mutatedCount++
	}

	// One interpreter process per batch of 100 programs: all writes, then every
	// clean read (Lua reads Go's bytes), then each mutated read.
	luaBytes := make([][]byte, n)
	luaRead := make([]readResult, n)
	luaMutRead := make([]readResult, n)
	for start := 0; start < n; start += batch {
		end := start + batch
		if end > n {
			end = n
		}
		var sb strings.Builder
		for i := start; i < end; i++ {
			sb.WriteString(fmt.Sprintf("W %d\n", bufferSize))
			for _, o := range programs[i].ops {
				sb.WriteString(o.emitLua())
				sb.WriteString("\n")
			}
			sb.WriteString("END\n")
		}
		for i := start; i < end; i++ {
			sb.WriteString(fmt.Sprintf("R %s\n", hex.EncodeToString(goBytes[i])))
			for _, o := range programs[i].ops {
				sb.WriteString(o.emitLua())
				sb.WriteString("\n")
			}
			sb.WriteString("END\n")
			if mutated[i] != nil {
				sb.WriteString(fmt.Sprintf("R %s\n", hex.EncodeToString(mutated[i])))
				for _, o := range programs[i].ops {
					sb.WriteString(o.emitLua())
					sb.WriteString("\n")
				}
				sb.WriteString("END\n")
			}
		}
		// One file name per batch index: a later round overwrites an earlier
		// round's file, so the files kept on a failure are the failing round's.
		batchFile := filepath.Join(tmp, fmt.Sprintf("batch%d.txt", start/batch))
		if err := os.WriteFile(batchFile, []byte(sb.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		lines := runLua(t, batchFile)
		pos := 0
		for i := start; i < end; i++ {
			luaBytes[i] = parseWriteLine(t, lines[pos])
			pos++
		}
		for i := start; i < end; i++ {
			luaRead[i] = parseReadLine(t, lines[pos])
			pos++
			if mutated[i] != nil {
				luaMutRead[i] = parseReadLine(t, lines[pos])
				pos++
			}
		}
		if pos != len(lines) {
			t.Fatalf("seed %d round %d batch %d: consumed %d result lines, driver printed %d\n%s",
				fuzzSeed, round, start/batch, pos, len(lines), repro)
		}
	}

	// (1) byte equality, and (2) each side reads the other's bytes back to the
	// program's values.
	for i := 0; i < n; i++ {
		if !bytes.Equal(goBytes[i], luaBytes[i]) {
			fail(i, "program %d: bytes differ\ngo:  %x\nlua: %x\nprogram:\n%s",
				i, goBytes[i], luaBytes[i], dumpProgram(programs[i]))
		}
		want := programTokens(programs[i])
		goRes := readGo(programs[i], luaBytes[i])
		if goRes.n != len(programs[i].ops) {
			fail(i, "program %d: go read refused at step %d/%d\nbytes: %x\nprogram:\n%s",
				i, goRes.n, len(programs[i].ops), goBytes[i], dumpProgram(programs[i]))
		}
		if bad := valuesAgree(want, goRes.tokens, programs[i]); bad >= 0 {
			fail(i, "program %d: go decoded values differ at step %d\nwant: %q\ngot:  %q\nprogram:\n%s",
				i, bad, want, goRes.tokens, dumpProgram(programs[i]))
		}
		if luaRead[i].n != len(programs[i].ops) {
			fail(i, "program %d: lua read refused at step %d/%d\nbytes: %x\nprogram:\n%s",
				i, luaRead[i].n, len(programs[i].ops), goBytes[i], dumpProgram(programs[i]))
		}
		if !equalStrings(luaRead[i].tokens, goRes.tokens) {
			fail(i, "program %d: lua decoded values differ from go at step %d\ngo:  %q\nlua: %q\nprogram:\n%s",
				i, firstDiff(goRes.tokens, luaRead[i].tokens), goRes.tokens, luaRead[i].tokens, dumpProgram(programs[i]))
		}
	}

	// (3) mutation agreement: both readers agree on accept/refuse, on the index
	// of the first refusal, on its reason, and on every value decoded before it.
	for i := 0; i < n; i++ {
		if mutated[i] == nil {
			continue
		}
		goRes := readGo(programs[i], mutated[i])
		luaRes := luaMutRead[i]
		if goRes.n != luaRes.n {
			fail(i, "program %d: mutation disagreement at step %d\nmutated from %x to %x\nprogram:\n%s",
				i, firstDiffInts(goRes.n, luaRes.n), goBytes[i], mutated[i], dumpProgram(programs[i]))
		}
		if goRes.reason != luaRes.reason {
			fail(i, "program %d: mutation reason disagreement: go %s, lua %s\nmutated from %x to %x\nprogram:\n%s",
				i, goRes.reason, luaRes.reason, goBytes[i], mutated[i], dumpProgram(programs[i]))
		}
		if !equalStrings(goRes.tokens, luaRes.tokens) {
			fail(i, "program %d: mutation value disagreement at step %d\ngo:  %q\nlua: %q\nmutated from %x to %x\nprogram:\n%s",
				i, firstDiff(goRes.tokens, luaRes.tokens), goRes.tokens, luaRes.tokens,
				goBytes[i], mutated[i], dumpProgram(programs[i]))
		}
	}
	return mutatedCount
}

func firstDiff(want, got []string) int {
	n := len(want)
	if len(got) < n {
		n = len(got)
	}
	for i := 0; i < n; i++ {
		if want[i] != got[i] {
			return i
		}
	}
	return n
}

func firstDiffInts(a, b int) int {
	if a < b {
		return a
	}
	return b
}
