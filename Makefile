# The engine (internal/duckdbcore) is wasm2go-transpiled DuckDB, sharded into
# ~30 packages (core + shardNN + all) so the Go optimizer can compile it fully
# optimized package-by-package (the old monolithic layout OOMed the compiler at
# ~50GB RSS and had to ship -N -l). Two flags are load-bearing:
#   - shards need '-l' (no inlining): default inlining re-expands the generated
#     IR and the compile OOMs at ~50GB again.
#   - '-c=1' (serial function compilation) keeps per-package compiler memory
#     flat; the whole engine compiles in ~2 minutes / <3GB peak.
# core compiles WITHOUT '-l' (intra-package inlining of the memory helpers is a
# real win); the more specific pattern wins, so list it after the catch-all.
# '-p 1' serializes package compiles for the first (uncached) build; drop it if
# you have RAM to spare. Everything outside internal/duckdbcore builds with
# default flags.
ENGINE      := github.com/esilver/duckdb-go-pure/internal/duckdbcore
GCFLAGS_ALL := $(ENGINE)/...=-l -c=1
GCFLAGS_CORE:= $(ENGINE)/core=-c=1

.PHONY: build test example

build:
	CGO_ENABLED=0 go build -p 1 -gcflags='$(GCFLAGS_ALL)' -gcflags='$(GCFLAGS_CORE)' ./...

test:
	CGO_ENABLED=0 go test -vet=off -p 1 -gcflags='$(GCFLAGS_ALL)' -gcflags='$(GCFLAGS_CORE)' ./...

example:
	CGO_ENABLED=0 go build -p 1 -gcflags='$(GCFLAGS_ALL)' -gcflags='$(GCFLAGS_CORE)' -o /tmp/duckdb-go-pure-basic ./examples/basic
	/tmp/duckdb-go-pure-basic
