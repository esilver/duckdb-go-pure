# No special flags compile the transpiled engine (internal/duckdbcore). The
# README "How it works" section explains why. Add '-p 1' only if you are tight
# on RAM (it serializes package compiles).
ENGINE  := github.com/esilver/duckdb-go-pure/internal/duckdbcore

.PHONY: build test example

build:
	CGO_ENABLED=0 go build ./...

test:
	CGO_ENABLED=0 go test -vet=off ./...

example:
	CGO_ENABLED=0 go build -o /tmp/duckdb-go-pure-basic ./examples/basic
	/tmp/duckdb-go-pure-basic

# Release gate: the engine must keep compiling for the Go wasm backend
# (GOOS=js). A function exceeding the compiler's 65536-SSA-block cap
# passes native builds but bricks browser/wasip1 targets — this catches
# it before a tag does. (~7 min cold; no artifact kept.)
jsgate:
	CGO_ENABLED=0 GOOS=js GOARCH=wasm go build -o /dev/null .
