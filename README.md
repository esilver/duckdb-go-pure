# duckdb-go-pure

**DuckDB as a pure-Go `database/sql` driver. `CGO_ENABLED=0`. No libduckdb, no
cgo, no shared libraries.**

DuckDB v1.5.3 (the full C-API amalgamation, with the `core_functions`, `json`
and `icu` extensions statically linked) is compiled to WebAssembly with
Emscripten and transpiled to plain Go with
[ncruces/wasm2go](https://github.com/ncruces/wasm2go) — the same approach
[ncruces/go-sqlite3](https://github.com/ncruces/go-sqlite3) uses for SQLite.
The transpiled engine lives in `internal/duckdbcore`; this package wraps it in
an idiomatic `database/sql` driver plus DuckDB-specific extension points
(scalar and aggregate UDFs implemented as Go closures that the engine calls
back during query execution).

Extracted from the working proof of concept at
[esilver/duckdb-wasm2go-poc](https://github.com/esilver/duckdb-wasm2go-poc).

## Required build flags (read this first)

The transpiled engine is very large Go code. Since v0.2.0 it ships sharded
into ~30 packages (`internal/duckdbcore/{core,shardNN,all}`), and since
v0.3.0 every oversized transpiled function is split into part-functions
(the PoC repo's `scripts/split_giant_fns.py`), so the Go optimizer compiles
the whole engine **fully optimized, inlining included** — queries run
2.3–2.9× faster than v0.2.x, which had to disable inlining (`-l`) on the
shards to keep the compile under control. **No build flags are required**:

```sh
CGO_ENABLED=0 go build ./...
```

- Measured cold build: ~30s, ~3GB worst single compile process (16 cores);
  the engine is cached by the Go build cache after the first build. Add
  `-p 1` only if you are tight on RAM (it serializes package compiles).
- Optional **PGO**: `default.pgo` (a representative query/storage profile)
  ships in this module; building your main package with
  `-pgo=$(go list -m -f '{{.Dir}}' github.com/esilver/duckdb-go-pure)/default.pgo`
  measured a further 1.3–1.8× on aggregates, strings, and storage
  round-trips.
- Everything else (your code, this driver) builds with default flags.
- `go test` additionally needs `-vet=off` (vet cannot chew the generated
  packages).
- Since v0.3.0 the module also builds for `GOOS=js GOARCH=wasm` and runs
  under Node/V8 via Go's `wasm_exec.js` — the function split is what brought
  the largest engine function under the Go compiler's 65536-SSA-block hard
  cap that previously bricked every js/wasm build.

## Status

| Area | Status |
|---|---|
| Engine | DuckDB v1.5.3 + `core_functions` + `json` + `icu`, wasm2go-transpiled, pure Go |
| `database/sql` driver | Working (driver name `"duckdb"`; `:memory:` and file DSNs) |
| Scalar UDFs | Working (`RegisterScalarConn`: fixed args, varargs, NULL handling, volatile) |
| Aggregate UDFs | Working (`RegisterAggregateConn`, `RegisterAggregateBandConn` + `AggregateOptions`) |
| Value types | `JSONValue`, `Decimal`, dates/times/timestamps, lists, structs, maps, enums, unions, intervals, UUID, blobs, HUGEINT, BIT, TIMETZ, BIGNUM, GEOMETRY (WKT), VARIANT |
| Column metadata | `ColumnType.DatabaseTypeName` returns the full DuckDB type name, recursive for nested types (duckdb-go parity) |
| Connection pooling | Safe: `rows.Next`/`Close` take the shared engine lock (since v0.2.1), so pooled `database/sql` connections can interleave freely |
| Bulk loading | `Appender` (DuckDB's native bulk-load path, ~100× faster than per-row `INSERT`) |
| Persistence | Host-filesystem databases (open a path instead of `:memory:`), host-FS glob (`read_csv('data/*.csv')`) |
| DuckDB's own test corpus | sqllogictest (`test/sql/**`, 3,322 files): **2,379 files PASS; 99.7% of 44,651 executed records** (runner committed in the [PoC repo](https://github.com/esilver/duckdb-wasm2go-poc)) |
| Proven downstream | Drives a pure-Go `googlesqlite` stack passing **986/994 BigQuery-dialect conformance tests with zero failures** (exceeds the cgo baseline of 972), and a pure-Go bigquery-emulator that is acceptance-tested with the real `bq` CLI |
| Performance | Engine compiles **fully optimized + inlined** since v0.3.0 (see above): 2.3–2.9× faster than v0.2.x, which was 2.0–2.6× faster than the v0.1.x monolith; still slower than native DuckDB (wasm2go has no SIMD), widest on SIMD-friendly scan/aggregate |
| Platforms | Pure Go: anywhere Go runs, **including `GOOS=js GOARCH=wasm`** since v0.3.0 (64-bit recommended; the engine wants multi-GB compile-time and runtime memory) |

## Quickstart

```sh
go get github.com/esilver/duckdb-go-pure   # current release line: v0.3.x
```

```go
package main

import (
	"database/sql"
	"fmt"
	"log"

	_ "github.com/esilver/duckdb-go-pure" // registers the "duckdb" driver
)

func main() {
	db, err := sql.Open("duckdb", ":memory:") // or a file path for persistence
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	var msg string
	if err := db.QueryRow(`SELECT 'hello from pure-Go DuckDB ' || version()`).Scan(&msg); err != nil {
		log.Fatal(err)
	}
	fmt.Println(msg)
}
```

Build it (the flags consumers need, verbatim):

```sh
CGO_ENABLED=0 go build \
  -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore/...=-c=1' .
```

## Scalar UDFs

Go closures become SQL functions; DuckDB calls them back, vectorized, during
query execution:

```go
import (
	"context"
	"database/sql"
	"database/sql/driver"

	duckdb "github.com/esilver/duckdb-go-pure"
)

const duckdbTypeBigint = 5 // duckdb_type id from duckdb.h

conn, _ := db.Conn(context.Background())
defer conn.Close()

err := duckdb.RegisterScalarConn(conn, "my_add_one",
	[]int32{duckdbTypeBigint}, duckdbTypeBigint,
	-1,    // varargs type id (-1: not variadic)
	false, // special NULL handling
	false, // volatile
	func(args []driver.Value) (any, error) {
		return args[0].(int64) + 1, nil
	})

var out int64
db.QueryRow(`SELECT my_add_one(41)`).Scan(&out) // 42
```

Registration is catalog-scoped: register on one connection and every
connection of that `*sql.DB` sees the function. Aggregate UDFs work the same
way through `RegisterAggregateConn` / `RegisterAggregateBandConn` (see
`udf_agg_band.go` and the tests). A complete runnable example is in
[`examples/basic`](examples/basic/main.go) (`make example`).

## Building and testing this repo

```sh
make build   # CGO_ENABLED=0 go build -gcflags='.../duckdbcore/...=-c=1' ./...
make test    # CGO_ENABLED=0 go test -vet=off -gcflags='...same...' ./...
make example # build + run examples/basic
```

## How it works

- `internal/duckdbcore` — the wasm2go output: DuckDB's wasm module as Go,
  sharded by the PoC repo's `scripts/transform_genopt.py` into `core` (the
  `Module` type, memory helpers, dispatch) + ~29 `shardNN` packages (the
  42.5k generated functions; cross-shard calls go through `TBL_FnN` func-vars
  that each shard's `init()` registers) + `all` (blank-imports every shard),
  so the Go optimizer's per-package memory stays bounded. Since v0.3.0 the
  PoC repo's `scripts/split_giant_fns.py` additionally splits every
  oversized transpiled function (up to 36.5k lines) into semantically
  identical part-functions, which is what lets the shards compile with
  inlining enabled and fit under the compiler's SSA-block hard cap
  (`GOOS=js`). The 6MB `gen.dat`
  data segment is `//go:embed`-ed in `core`. Linear wasm memory is a
  `[]byte`; the indirect function table is a `[]any` of Go funcs — which is
  exactly what makes Go-closure UDF callbacks possible.
- `internal/exhost` — a Go implementation of Emscripten's C++ exception ABI
  (`invoke_*` trampolines, `__cxa_throw` & friends) using panic/recover, so
  DuckDB's `-fexceptions` build unwinds correctly.
- `internal/wasishim` — the WASI + Emscripten host surface (clock, rng,
  stdout, and a host-filesystem layer so file-backed databases persist).
- The root package (`duckdb`) drives the engine through the DuckDB C API
  (`duckdb_open`/`duckdb_query`/data chunks) and adapts it to
  `database/sql/driver`.

## Regenerating the engine

The wasm build pipeline (Emscripten flags, the DuckDB amalgamation build,
wasm2go invocation, the multi-package optimizer transform) intentionally does
**not** live in this repo. See
[esilver/duckdb-wasm2go-poc](https://github.com/esilver/duckdb-wasm2go-poc)
for the full, replicable pipeline. To refresh this repo from a PoC checkout
(after `GENOPT=1 ./rebuild_fs_all.sh` there has populated `converge/genopt`):

```sh
scripts/import_engine.sh path/to/duckdb-wasm2go-poc
make test
```

## Related

- [esilver/duckdb-wasm2go-poc](https://github.com/esilver/duckdb-wasm2go-poc) — provenance: the PoC + engine build pipeline
- [ncruces/wasm2go](https://github.com/ncruces/wasm2go) — the wasm-to-Go transpiler
- [ncruces/go-sqlite3](https://github.com/ncruces/go-sqlite3) — the pattern this module follows, for SQLite
- [duckdb/duckdb](https://github.com/duckdb/duckdb) — DuckDB itself

## License

MIT. The embedded engine is DuckDB (MIT, Copyright Stichting DuckDB
Foundation) and bundles ICU (ICU license) via the icu extension — both notices
are included in [LICENSE](LICENSE); credits in [NOTICE](NOTICE).
