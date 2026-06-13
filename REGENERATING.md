# Regenerating the engine

The DuckDB engine under `internal/duckdbcore/` is generated, not hand-written:
DuckDB v1.5.3 compiled to WebAssembly and transpiled to Go with
[ncruces/wasm2go](https://github.com/ncruces/wasm2go). The generator pipeline
lives in the PoC repo, [esilver/duckdb-wasm2go-poc](https://github.com/esilver/duckdb-wasm2go-poc),
not here. `PROVENANCE` records the engine source commit and the gen.dat hash.

## Regenerate / bump the engine

1. In a checkout of `esilver/duckdb-wasm2go-poc`, build the optimized
   multi-package engine: `GENOPT=1 ./rebuild_fs_all.sh` (produces
   `converge/genopt/{core,shardNN,all}`). This needs emscripten, wasm2go, and Go;
   the PoC build scripts pin the toolchain and the emcc flags (the standalone-wasm
   shape, no SIMD, legacy exceptions, the function-split step).
2. Import it here: `scripts/import_engine.sh /path/to/duckdb-wasm2go-poc`. The
   script copies the engine, driver, and host packages, rewrites import paths,
   gofmts, and writes `PROVENANCE`.
3. Verify:
   ```sh
   CGO_ENABLED=0 go build ./...
   make jsgate          # GOOS=js compile check: catches any transpiled function
                        # over the Go compiler's 65536-SSA-block cap
   go test -vet=off ./...
   ```

## Why the generator is a separate repo

The transpile pipeline (emcc flags, the standalone-wasm shape, the function-split
step, the wasm2go invocation) is involved and shared with the PoC's own
experiments, and it pulls in multi-GB build scaffolding. Keeping it in the PoC
repo keeps this consumer repo usable. The cost is that this repo cannot rebuild
its own engine in isolation. `PROVENANCE` plus `scripts/import_engine.sh` are the
bridge that makes the result reproducible.
