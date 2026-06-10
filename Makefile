# The wasm2go-transpiled engine package (internal/duckdbcore) is too large for
# the Go compiler's optimizing backend (it OOMs around ~50GB RSS), so it must be
# compiled unoptimized: -N (no optimization) -l (no inlining) -c=16 (parallel
# function compilation). Every other package builds with full optimization.
# The first compile of the engine package takes several minutes; it is cached
# afterwards.
ENGINE_PKG  := github.com/esilver/duckdb-go-pure/internal/duckdbcore
GCFLAGS     := $(ENGINE_PKG)=-N -l -c=16

.PHONY: build test example

build:
	CGO_ENABLED=0 go build -gcflags='$(GCFLAGS)' ./...

test:
	CGO_ENABLED=0 go test -vet=off -gcflags='$(GCFLAGS)' ./...

example:
	CGO_ENABLED=0 go build -gcflags='$(GCFLAGS)' -o /tmp/duckdb-go-pure-basic ./examples/basic
	/tmp/duckdb-go-pure-basic
