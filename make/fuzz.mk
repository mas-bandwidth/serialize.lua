# The differential fuzz gate (serialize-lua-fuzz-differential card). The Go host
# tests the Lua port against serialize.go: byte-identical writers, clean decode,
# and mutation agreement. `make fuzz` runs it; `make fuzz-neg` runs the negative
# control (the -widen-int flag makes the Go writer diverge by one bit, so it must
# go red).
.PHONY: fuzz fuzz-neg
fuzz:
	cd fuzz && nice -n 19 go test -count=1 -timeout 600s -run 'TestDifferentialAgainstSerializeGo' -v .
fuzz-neg:
	cd fuzz && nice -n 19 go test -count=1 -timeout 600s -run 'TestDifferentialAgainstSerializeGo' -v -widen-int .
