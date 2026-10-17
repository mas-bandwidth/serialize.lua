// Package fuzz tests the Lua serialize port differentially against serialize.go:
// for every generated program the two writers must emit identical bytes, the
// packet must decode cleanly, and on mutation the readers must agree on where and
// whether the read fails.
package fuzz

import (
	"bytes"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"flag"

	"github.com/mas-bandwidth/serialize.go"
)

// widenIntRange, when set via -widen-int, makes the Go writer use int ranges one
// bit wider than the Lua side declares, so the bytes differ and the test goes red.
// It is the negative control: the same harness, one deliberate divergence.
var widenIntRange = false

func init() {
	flag.BoolVar(&widenIntRange, "widen-int", false, "negative control: widen the int64 range by one bit")
}

type op struct {
	kind   string
	width  int
	lo, hi int64
	valI   int64
	valF32 float32
	valF64 float64
	payload []byte
	bufSize int
	prev    int32
	extra   int64
}

// emitLua renders the op as a driver.lua command line.
func (o op) emitLua() string {
	switch o.kind {
	case "bits":
		return fmt.Sprintf("bits %d %d", o.valI, o.width)
	case "bits64":
		return fmt.Sprintf("bits64 %d %d", o.valI, o.width)
	case "bool":
		if o.valI != 0 {
			return "bool 1"
		}
		return "bool 0"
	case "u8", "u16", "u32", "u64":
		return fmt.Sprintf("%s %d", o.kind, o.valI)
	case "int", "int64":
		return fmt.Sprintf("%s %d %d %d", o.kind, o.valI, o.lo, o.hi)
	case "float":
		return fmt.Sprintf("float %d", math.Float32bits(o.valF32))
	case "double":
		b := math.Float64bits(o.valF64)
		return fmt.Sprintf("double %d %d", uint32(b>>32), uint32(b))
	case "cfloat":
		return fmt.Sprintf("cfloat %s %s %s %s",
			fmtFloat32(o.valF32), fmtFloat32(float32(o.lo)), fmtFloat32(float32(o.hi)), fmtFloat32(float32(o.valF64)))
	case "bytes", "str", "wstr":
		hex := fmt.Sprintf("%x", o.payload)
		if hex == "" {
			hex = "."
		}
		if o.kind == "bytes" {
			return fmt.Sprintf("bytes %s %d", hex, len(o.payload))
		}
		return fmt.Sprintf("%s %s %d", o.kind, hex, o.bufSize)
	case "align":
		return "align"
	case "intrel":
		return fmt.Sprintf("intrel %d %d", o.prev, o.valI)
	case "fixed64":
		return fmt.Sprintf("fixed64 %d %d %d %d %d", o.valI, o.width, o.lo, o.hi, o.extra)
	}
	return ""
}

func fmtFloat32(f float32) string {
	return fmt.Sprintf("%g", f)
}

func (o *op) write(w *serialize.WriteStream) {
	switch o.kind {
	case "bits":
		v := uint32(o.valI)
		w.SerializeBits(&v, o.width)
	case "bits64":
		v := uint64(o.valI)
		w.SerializeBits64(&v, o.width)
	case "bool":
		v := o.valI != 0
		w.SerializeBool(&v)
	case "u8":
		v := uint8(o.valI)
		w.SerializeUint8(&v)
	case "u16":
		v := uint16(o.valI)
		w.SerializeUint16(&v)
	case "u32":
		v := uint32(o.valI)
		w.SerializeUint32(&v)
	case "u64":
		v := uint64(o.valI)
		w.SerializeUint64(&v)
	case "int":
		v := int32(o.valI)
		w.SerializeInt(&v, int32(o.lo), int32(o.hi))
	case "int64":
		v := o.valI
		if widenIntRange {
			// negative control: wider than the Lua declaration (never min > max)
			w.SerializeInt64(&v, o.lo, negMax(o.hi))
		} else {
			w.SerializeInt64(&v, o.lo, o.hi)
		}
	case "float":
		v := o.valF32
		w.SerializeFloat32(&v)
	case "double":
		v := o.valF64
		w.SerializeFloat64(&v)
	case "cfloat":
		v := o.valF32
		w.SerializeCompressedFloat32(&v, float32(o.lo), float32(o.hi), float32(o.valF64))
	case "bytes":
		w.SerializeBytes(o.payload)
	case "str":
		v := string(o.payload)
		w.SerializeString(&v, o.bufSize)
	case "wstr":
		v := string(o.payload)
		w.SerializeWideString(&v, o.bufSize)
	case "align":
		w.SerializeAlign()
	case "intrel":
		v := int32(o.valI)
		w.SerializeIntRelative(o.prev, &v)
	case "fixed64":
		v := o.valI
		w.SerializeFixed64(&v, o.width, int(o.lo), o.hi, o.extra)
	}
}

// read replays the op on a reader and reports whether it succeeds.
func (o op) read(r *serialize.ReadStream) bool {
	switch o.kind {
	case "bits":
		var v uint32
		return r.SerializeBits(&v, o.width) == nil
	case "bits64":
		var v uint64
		return r.SerializeBits64(&v, o.width) == nil
	case "bool":
		var v bool
		return r.SerializeBool(&v) == nil
	case "u8":
		var v uint8
		return r.SerializeUint8(&v) == nil
	case "u16":
		var v uint16
		return r.SerializeUint16(&v) == nil
	case "u32":
		var v uint32
		return r.SerializeUint32(&v) == nil
	case "u64":
		var v uint64
		return r.SerializeUint64(&v) == nil
	case "int":
		var v int32
		return r.SerializeInt(&v, int32(o.lo), int32(o.hi)) == nil
	case "int64":
		var v int64
		if widenIntRange {
			return r.SerializeInt64(&v, o.lo, negMax(o.hi)) == nil
		}
		return r.SerializeInt64(&v, o.lo, o.hi) == nil
	case "float":
		var v float32
		return r.SerializeFloat32(&v) == nil
	case "double":
		var v float64
		return r.SerializeFloat64(&v) == nil
	case "cfloat":
		var v float32
		return r.SerializeCompressedFloat32(&v, float32(o.lo), float32(o.hi), float32(o.valF64)) == nil
	case "bytes":
		buf := make([]byte, len(o.payload))
		return r.SerializeBytes(buf) == nil
	case "str":
		var v string
		return r.SerializeString(&v, o.bufSize) == nil
	case "wstr":
		var v string
		return r.SerializeWideString(&v, o.bufSize) == nil
	case "align":
		return r.SerializeAlign() == nil
	case "intrel":
		var v int32
		return r.SerializeIntRelative(o.prev, &v) == nil
	case "fixed64":
		var v int64
		return r.SerializeFixed64(&v, o.width, int(o.lo), o.hi, o.extra) == nil
	}
	return false
}

type program struct {
	ops []op
}

var rng *rand.Rand

func init() {
	// Fixed seed: no clock. math/rand/v2.
	rng = rand.New(rand.NewPCG(0x1234567890abcdef, 0x0ddc0ffee))
}

func randI(lo, hi int64) int64 {
	if lo > hi {
		lo, hi = hi, lo
	}
	if lo == hi {
		return lo
	}
	return lo + rng.Int64N(hi-lo+1)
}

func randU32() uint32 { return rng.Uint32() }

// randFloat32 returns a finite float32 (never NaN or ±Inf): the Lua port
// canonicalizes NaN payloads to quiet NaN (DESIGN.md (e)) while serialize.go
// writes the raw bits, so NaN values cannot satisfy byte equality.
func randFloat32() float32 {
	b := rng.Uint32()
	exp := (b >> 23) & 0xff
	if exp >= 0xff {
		exp = 0xfe
	}
	b = (b & 0x807fffff) | (exp << 23)
	return math.Float32frombits(b)
}

func randFloat64() float64 {
	b := rng.Uint64()
	exp := (b >> 52) & 0x7ff
	if exp >= 0x7ff {
		exp = 0x7fe
	}
	b = (b & 0x800fffffffffffff) | (uint64(exp) << 52)
	return math.Float64frombits(b)
}

// negMax returns a widened upper bound for the negative control, never producing
// min > max: widening a negative upper bound would shrink the range.
func negMax(hi int64) int64 {
	if hi < 0 {
		return hi
	}
	return hi*2 + 1
}

func randOp() op {
	var o op
	switch rng.IntN(17) {
	case 0:
		o.kind = "bits"
		o.width = int(randI(1, 32))
		o.valI = int64(rng.Uint64() & ((1 << min(o.width, 63)) - 1))
		o.valI &= (1 << o.width) - 1
		if o.width == 32 {
			o.valI = int64(rng.Uint32())
		}
	case 1:
		o.kind = "bits64"
		o.width = int(randI(1, 64))
		if o.width == 64 {
			o.valI = int64(rng.Uint64() & math.MaxInt64)
		} else {
			o.valI = int64(rng.Uint64() & ((1 << min(o.width, 63)) - 1))
		}
	case 2:
		o.kind = "bool"
		o.valI = int64(rng.IntN(2))
	case 3:
		o.kind = "u8"
		o.valI = int64(rng.Uint32() & 0xff)
	case 4:
		o.kind = "u16"
		o.valI = int64(rng.Uint32() & 0xffff)
	case 5:
		o.kind = "u32"
		o.valI = int64(rng.Uint32())
	case 6:
		o.kind = "u64"
		o.valI = int64(rng.Uint64() & math.MaxInt64)
	case 7:
		o.kind = "int"
		o.lo = randI(-100000, 100000)
		o.hi = o.lo + randI(0, 200000)
		o.valI = randI(o.lo, o.hi)
	case 8:
		o.kind = "int64"
		o.lo = randI(-1<<40, 1<<40)
		o.hi = o.lo + randI(0, 1<<44)
		o.valI = randI(o.lo, o.hi)
	case 9:
		o.kind = "float"
		o.valF32 = randFloat32()
	case 10:
		o.kind = "double"
		o.valF64 = randFloat64()
	case 11:
		o.kind = "cfloat"
		o.lo = int64(randI(-1000, -1))
		o.hi = int64(randI(1, 1000))
		o.valF64 = 0.5
		o.valF32 = float32(randI(int64(o.lo), int64(o.hi)))
	case 12:
		o.kind = "bytes"
		n := int(randI(0, 64))
		o.payload = make([]byte, n)
		for i := range o.payload {
			o.payload[i] = byte(rng.Uint32())
		}
	case 13:
		o.kind = "str"
		o.bufSize = int(randI(1, 256))
		n := int(randI(0, int64(o.bufSize)-1))
		o.payload = make([]byte, n)
		for i := range o.payload {
			o.payload[i] = byte(rng.IntN(0x7f)) + 1
		}
	case 14:
		o.kind = "wstr"
		o.bufSize = int(randI(1, 128))
		n := int(randI(0, int64(o.bufSize)-1))
		o.payload = make([]byte, 0)
		for i := 0; i < n; i++ {
			o.payload = append(o.payload, []byte(string(rune(rng.IntN(0xffff)+1)))...)
		}
	case 15:
		o.kind = "align"
	case 16:
		o.kind = "intrel"
		o.prev = int32(randI(0, math.MaxInt32-1))
		o.valI = int64(randI(int64(o.prev)+1, math.MaxInt32))
	}
	return o
}

func genProgram() program {
	n := int(randI(1, 24))
	var p program
	for i := 0; i < n; i++ {
		p.ops = append(p.ops, randOp())
	}
	return p
}

func writeGo(p program) ([]byte, bool) {
	buf := make([]byte, 4096)
	w := serialize.NewWriteStream(buf)
	for _, o := range p.ops {
		o.write(w)
	}
	w.Flush()
	data := w.Data()
	return data, w.Err() == nil
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
		if strings.HasPrefix(ln, "HEX ") {
			lines = append(lines, strings.TrimPrefix(ln, "HEX "))
		}
	}
	return lines
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

// readCount returns how many ops decoded successfully before the first failure (or
// the full sequence if all succeed).
func readCount(p program, data []byte) []int {
	r := serialize.NewReadStream(data)
	var seq []int
	for i, o := range p.ops {
		if !o.read(r) {
			break
		}
		seq = append(seq, i)
	}
	return seq
}

func TestDifferentialAgainstSerializeGo(t *testing.T) {
	const n = 2000
	const batch = 100
	programs := make([]program, n)
	for i := range programs {
		programs[i] = genProgram()
	}

	goBytes := writeAllGo(programs)

	// Run the Lua driver in batches of 100.
	luaBytes := make([][]byte, n)
	tmp := t.TempDir()
	for start := 0; start < n; start += batch {
		end := start + batch
		if end > n {
			end = n
		}
		var sb strings.Builder
		valid := 0
		for i := start; i < end; i++ {
			sb.WriteString(fmt.Sprintf("BEG 4096\n"))
			for _, o := range programs[i].ops {
				sb.WriteString(o.emitLua())
				sb.WriteString("\n")
			}
			sb.WriteString("FLUSH\nEND\n")
			valid++
		}
		batchFile := filepath.Join(tmp, fmt.Sprintf("batch%d.txt", start/batch))
		if err := os.WriteFile(batchFile, []byte(sb.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		lines := runLua(t, batchFile)
		if len(lines) != valid {
			t.Fatalf("batch %d: expected %d HEX lines, got %d", start/batch, valid, len(lines))
		}
		for i := start; i < end; i++ {
			hex := lines[i-start]
			b := make([]byte, len(hex)/2)
			fmt.Sscanf(hex, "%x", &b)
			luaBytes[i] = b
		}
	}

	// (1) byte equality
	for i := 0; i < n; i++ {
		a := goBytes[i]
		b := luaBytes[i]
		if !bytes.Equal(a, b) {
			t.Fatalf("program %d: bytes differ\ngo:  %x\nlua: %x\nprogram:\n%s", i, a, b, dumpProgram(programs[i]))
		}
		// (2) the Go bytes decode cleanly
		seq := readCount(programs[i], a)
		if len(seq) != len(programs[i].ops) {
			t.Fatalf("program %d: decode failed after %d/%d ops", i, len(seq), len(programs[i].ops))
		}
	}

	// (3) mutation agreement: 1 in 4 programs
	mutated := 0
	for i := 0; i < n; i++ {
		if rng.IntN(4) != 0 {
			continue
		}
		mutated++
		orig := goBytes[i]
		mut := mutateBytes(orig)
		seqGo := readCount(programs[i], mut)
		seqLua := readCount(programs[i], mut)
		if !equalInts(seqGo, seqLua) {
			t.Fatalf("program %d: mutation disagreement\ng(o accept %d, lua accept %d\nmutated from %x to %x\nprogram:\n%s",
				i, len(seqGo), len(seqLua), orig, mut, dumpProgram(programs[i]))
		}
	}
	t.Logf("ok  %d programs, %d mutated", n, mutated)
}

func equalInts(a, b []int) bool {
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

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
