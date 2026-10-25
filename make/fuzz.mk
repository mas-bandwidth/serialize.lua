# The differential fuzz gate (serialize-lua-fuzz-differential card). The Go host
# tests the Lua port against serialize.go: byte-identical writers, clean decode,
# and mutation agreement. `make fuzz` runs it; `make fuzz-neg` runs the negative
# control (the -widen-int flag makes the Go writer diverge by one bit, so it must
# go red).
#
# FUZZ_FLAGS and FUZZ_TIMEOUT are empty and 600s by default, so the per-push gate
# is one round of 2000 programs from the fixed seed, as it always was. The nightly
# run (.github/workflows/nightly-fuzz.yml) widens them, for example
#   make fuzz FUZZ_TIMEOUT=0 FUZZ_FLAGS="-seed=<n> -duration=3600s -failures-dir=<dir>"
# and the test logs the seed first, so a red night reproduces with -seed.
FUZZ_FLAGS   ?=
FUZZ_TIMEOUT ?= 600s

.PHONY: fuzz fuzz-neg
fuzz:
	cd fuzz && nice -n 19 go test -count=1 -timeout $(FUZZ_TIMEOUT) -run 'TestDifferentialAgainstSerializeGo' -v $(FUZZ_FLAGS) .
fuzz-neg:
	cd fuzz && nice -n 19 go test -count=1 -timeout $(FUZZ_TIMEOUT) -run 'TestDifferentialAgainstSerializeGo' -v -widen-int=true $(FUZZ_FLAGS) .
