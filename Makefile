# The engine (internal/duckdbcore) is wasm2go-transpiled DuckDB, sharded into
# ~30 packages (core + shardNN + all) and with every oversized transpiled
# function split into part-functions (the PoC repo's split_giant_fns.py), so
# the Go optimizer compiles it fully optimized — inlining included. One flag
# is load-bearing:
#   - '-c=1' (serial function compilation) keeps per-package compiler memory
#     bounded (0.4-3.4GB peak per package, worst shard6).
# Since v0.3.0 no '-l' is needed anywhere: the function split is what keeps
# the inliner's IR bounded (pre-split, default inlining OOMed at ~50GB and
# the shards had to compile -l). Parallel package compiles are fine on a
# 64GB-class machine; add '-p 1' if you are tight on RAM (it serializes
# package compiles). Everything outside internal/duckdbcore builds with
# default flags.
ENGINE  := github.com/esilver/duckdb-go-pure/internal/duckdbcore
GCFLAGS := $(ENGINE)/...=-c=1

.PHONY: build test example

build:
	CGO_ENABLED=0 go build -gcflags='$(GCFLAGS)' ./...

test:
	CGO_ENABLED=0 go test -vet=off -gcflags='$(GCFLAGS)' ./...

example:
	CGO_ENABLED=0 go build -gcflags='$(GCFLAGS)' -o /tmp/duckdb-go-pure-basic ./examples/basic
	/tmp/duckdb-go-pure-basic
