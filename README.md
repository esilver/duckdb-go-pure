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
into ~30 packages (`internal/duckdbcore/{core,shardNN,all}`) so the Go
optimizer can compile it **fully optimized** package-by-package — queries run
2.0–2.6× faster than the v0.1.x engine, which had to ship a single monolithic
package compiled `-N -l` (full optimization OOMed the compiler at ~50GB RSS).
Consumers must add two `-gcflags` arguments to their own builds:

```sh
CGO_ENABLED=0 go build \
  -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore/...=-l -c=1' \
  -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore/core=-c=1' ./...
```

- `-l` (no inlining) on the shards is **mandatory**: default inlining
  re-expands the generated IR and the compile OOMs at ~50GB. `core` compiles
  without `-l` (the more specific pattern wins) — intra-package inlining of
  the wasm memory helpers is a real win there.
- `-c=1` (serial function compilation) keeps per-package compiler memory flat;
  the whole engine compiles in ~2 minutes / <3GB peak and is cached by the Go
  build cache afterwards. Add `-p 1` for the first build if you are tight on
  RAM (it serializes package compiles).
- Everything else (your code, this driver) still builds fully optimized with
  default flags.
- `go test` additionally needs `-vet=off` (vet cannot chew the generated
  packages).

Without the shard `-l` flag, `go build` will appear to hang on an engine
shard and eventually exhaust memory.

## Status

| Area | Status |
|---|---|
| Engine | DuckDB v1.5.3 + `core_functions` + `json` + `icu`, wasm2go-transpiled, pure Go |
| `database/sql` driver | Working (driver name `"duckdb"`; `:memory:` and file DSNs) |
| Scalar UDFs | Working (`RegisterScalarConn`: fixed args, varargs, NULL handling, volatile) |
| Aggregate UDFs | Working (`RegisterAggregateConn`, `RegisterAggregateBandConn` + `AggregateOptions`) |
| Value types | `JSONValue`, `Decimal`, dates/times/timestamps, lists, structs, maps, enums, unions, intervals, UUID, blobs, HUGEINT, BIT, TIMETZ |
| Bulk loading | `Appender` (DuckDB's native bulk-load path, ~100× faster than per-row `INSERT`) |
| Persistence | Host-filesystem databases (open a path instead of `:memory:`), host-FS glob (`read_csv('data/*.csv')`) |
| DuckDB's own test corpus | sqllogictest (`test/sql/**`, 3,322 files): **2,379 files PASS; 99.7% of 44,651 executed records** (runner committed in the [PoC repo](https://github.com/esilver/duckdb-wasm2go-poc)) |
| Proven downstream | Drives a pure-Go `googlesqlite` stack passing **986/994 BigQuery-dialect conformance tests with zero failures** (exceeds the cgo baseline of 972), and a pure-Go bigquery-emulator that is acceptance-tested with the real `bq` CLI |
| Performance | Engine compiles **fully optimized** since v0.2.0 (see above): roughly **2–11× slower than native DuckDB** (widest on SIMD-friendly scan/aggregate — wasm2go has no SIMD — narrower on join/hash/string-heavy work); 2.0–2.6× faster than v0.1.x |
| Platforms | Pure Go: anywhere Go runs (64-bit recommended; the engine wants multi-GB compile-time and runtime memory) |

## Quickstart

```sh
go get github.com/esilver/duckdb-go-pure   # current release line: v0.2.x
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
  -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore/...=-l -c=1' \
  -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore/core=-c=1' .
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
make build   # CGO_ENABLED=0 go build -p 1 -gcflags='.../duckdbcore/...=-l -c=1' -gcflags='.../duckdbcore/core=-c=1' ./...
make test    # CGO_ENABLED=0 go test -vet=off -p 1 -gcflags='...same...' ./...
make example # build + run examples/basic
```

## How it works

- `internal/duckdbcore` — the wasm2go output: DuckDB's wasm module as Go,
  sharded by the PoC repo's `scripts/transform_genopt.py` into `core` (the
  `Module` type, memory helpers, dispatch) + ~29 `shardNN` packages (the
  42.5k generated functions; cross-shard calls go through `TBL_FnN` func-vars
  that each shard's `init()` registers) + `all` (blank-imports every shard),
  so the Go optimizer's per-package memory stays bounded. The 6MB `gen.dat`
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
