# The engine (internal/duckdbcore) is wasm2go-transpiled DuckDB, sharded into
# ~30 packages (core + shardNN + all) and with every oversized transpiled
# function split into part-functions (the PoC repo's split_giant_fns.py), so
# the Go optimizer compiles it fully optimized — inlining included.
#
# NO SPECIAL FLAGS REQUIRED: plain 'go build ./...' compiles the engine
# (measured: ~30s cold, ~3GB worst single compile process, 16 cores).
# Add '-p 1' only if you are tight on RAM (serializes package compiles).
ENGINE  := github.com/esilver/duckdb-go-pure/internal/duckdbcore

.PHONY: build test example

build:
	CGO_ENABLED=0 go build ./...

test:
	CGO_ENABLED=0 go test -vet=off ./...

example:
	CGO_ENABLED=0 go build -o /tmp/duckdb-go-pure-basic ./examples/basic
	/tmp/duckdb-go-pure-basic
