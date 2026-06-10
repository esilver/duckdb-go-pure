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

The transpiled engine is one very large Go package. The Go compiler's
optimizing backend cannot handle it (it OOMs at ~50GB RSS), so **the engine
package — and only the engine package — must be compiled unoptimized**.
Consumers must add one `-gcflags` argument to their own builds:

```sh
CGO_ENABLED=0 go build -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore=-N -l -c=16' ./...
```

- `-N -l` disables optimization/inlining for that one package; `-c=16`
  compiles its functions in parallel.
- Everything else (your code, this driver) still builds fully optimized.
- The first compile of the engine package takes ~10 minutes and several GB of
  RAM; it is cached by the Go build cache afterwards.
- `go test` additionally needs `-vet=off` (vet also cannot chew the package).

Without the flag, `go build` will appear to hang on the engine package and
eventually exhaust memory.

## Status

| Area | Status |
|---|---|
| Engine | DuckDB v1.5.3 + `core_functions` + `json` + `icu`, wasm2go-transpiled, pure Go |
| `database/sql` driver | Working (driver name `"duckdb"`; `:memory:` and file DSNs) |
| Scalar UDFs | Working (`RegisterScalarConn`: fixed args, varargs, NULL handling, volatile) |
| Aggregate UDFs | Working (`RegisterAggregateConn`, `RegisterAggregateBandConn` + `AggregateOptions`) |
| Value types | `JSONValue`, `Decimal`, dates/times/timestamps, lists, structs, enums, UUID, blobs |
| Persistence | Host-filesystem databases (open a path instead of `:memory:`) |
| Proven downstream | Drives a pure-Go `googlesqlite` stack passing 986/994 BigQuery-dialect conformance tests, and a pure-Go bigquery-emulator |
| Performance | Engine is compiled **unoptimized** (see above) — expect a significant slowdown vs. native DuckDB. Optimizing the engine build is a roadmap item. |
| Platforms | Pure Go: anywhere Go runs (64-bit recommended; the engine wants multi-GB compile-time and runtime memory) |

## Quickstart

```sh
go get github.com/esilver/duckdb-go-pure
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

Build it (the one-liner consumers need, verbatim):

```sh
CGO_ENABLED=0 go build -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore=-N -l -c=16' .
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
make build   # CGO_ENABLED=0 go build -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore=-N -l -c=16' ./...
make test    # CGO_ENABLED=0 go test -vet=off -gcflags='...same...' ./...
make example # build + run examples/basic
```

## How it works

- `internal/duckdbcore` — the wasm2go output: DuckDB's wasm module as a Go
  package (`gen_000.go` … `gen_004.go`, sharded under GitHub's 100MB file
  limit by `scripts/shard_gen.py`, plus the 6MB `gen.dat` data segment,
  `//go:embed`-ed). Linear wasm memory is a `[]byte`; the indirect function
  table is a `[]any` of Go funcs — which is exactly what makes Go-closure UDF
  callbacks possible.
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
wasm2go invocation) intentionally does **not** live in this repo. See
[esilver/duckdb-wasm2go-poc](https://github.com/esilver/duckdb-wasm2go-poc)
for the full, replicable pipeline. To refresh this repo from a newly generated
`gen.go` / `gen.dat`:

```sh
python3 scripts/shard_gen.py path/to/gen.go internal/duckdbcore
cp path/to/gen.dat internal/duckdbcore/
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
