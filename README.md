# duckdb-go-pure

[![CI](https://github.com/esilver/duckdb-go-pure/actions/workflows/ci.yml/badge.svg)](https://github.com/esilver/duckdb-go-pure/actions/workflows/ci.yml)

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

## The stack

This driver is the engine layer of a pure-Go, DuckDB-backed BigQuery emulator.
Top to bottom:

- [esilver/bigquery-emulator](https://github.com/esilver/bigquery-emulator) is
  the BigQuery REST API server (a fork of goccy/bigquery-emulator).
- [esilver/googlesqlite](https://github.com/esilver/googlesqlite) is the
  GoogleSQL engine: it lowers analyzed BigQuery SQL to DuckDB SQL and registers
  BigQuery builtins as DuckDB UDFs (a fork of goccy/googlesqlite, retargeted
  from a SQLite backend to DuckDB).
- [esilver/go-googlesql](https://github.com/esilver/go-googlesql) is the ZetaSQL
  analyzer bridge (a fork of goccy/go-googlesql).
- **duckdb-go-pure** (this repo) is DuckDB itself, as a pure-Go `database/sql`
  driver.

The whole stack runs `CGO_ENABLED=0` with no native libraries. This repo is a
showcase of pure-Go DuckDB, shared for interest and experimentation. The
official cgo driver remains the recommended driver for production use (see
Related).

## Build (no flags required)

Build with the standard Go toolchain, no cgo and no special flags:

```sh
CGO_ENABLED=0 go build ./...
```

(Maintainers: `make jsgate` adds a GOOS=js compile check before tagging a
release, because the wasm backend enforces a per-function block cap that native
builds do not.)

The transpiled engine is very large Go code. Since v0.2.0 it ships sharded
into ~30 packages (`internal/duckdbcore/{core,shardNN,all}`), and since
v0.3.0 every oversized transpiled function is split into part-functions
(the PoC repo's `scripts/split_giant_fns.py`), so the Go optimizer compiles
the whole engine **fully optimized, inlining included** — queries run
2.3–2.9× faster than v0.2.x, which had to disable inlining (`-l`) on the
shards to keep the compile under control.

- Measured cold build: ~30s, ~3GB worst single compile process (16 cores);
  the engine is cached by the Go build cache after the first build. Add
  `-p 1` only if you are tight on RAM (it serializes package compiles).
- PGO: measured no effect on the fully-inlined v0.3.x engine (interleaved
  A/B on a quiet machine, 0.97-1.01x across aggregate/string/join/storage
  shapes at 100k-2M rows), so no PGO profile ships.
- Everything else (your code, this driver) builds with default flags.
- `go test` additionally needs `-vet=off`, because `go vet` cannot analyze the
  very large generated engine packages.
- Since v0.3.0 the module also builds for `GOOS=js GOARCH=wasm` and runs
  under Node/V8 via Go's `wasm_exec.js` — the function split is what brought
  the largest engine function under the Go compiler's 65536-SSA-block hard
  cap, which previously blocked every js/wasm build from compiling.

## Status

| Area | Status |
|---|---|
| Engine | DuckDB v1.5.3 + `core_functions` + `json` + `icu`, wasm2go-transpiled, pure Go |
| `database/sql` driver | Working (driver name `"duckdb"`; `:memory:` and file DSNs) |
| Scalar UDFs | Working (`RegisterScalarConn`: fixed args, varargs, NULL handling, volatile) |
| Aggregate UDFs | Working (`RegisterAggregateBandConn` + `AggregateOptions`) |
| Value types | `JSONValue`, `Decimal`, dates/times/timestamps, lists, structs, maps, enums, unions, intervals, UUID, blobs, HUGEINT, BIT, TIMETZ, BIGNUM, GEOMETRY (WKT), VARIANT |
| Column metadata | `ColumnType.DatabaseTypeName` returns the full DuckDB type name, recursive for nested types (duckdb-go parity) |
| Connection pooling | Safe: `rows.Next`/`Close` take the shared engine lock (since v0.2.1), so pooled `database/sql` connections can interleave freely |
| Statement cancellation | Context cancellation **interrupts a RUNNING statement** (since v0.3.5, via DuckDB's own interrupt flag): a runaway query on a cancelled/expired context returns a native `INTERRUPT Error` joined with the context error within milliseconds, and the engine stays healthy, so context cancellation reliably stops a running query instead of only taking effect at the next statement boundary |
| Bulk loading | `Appender`-shaped bulk path backed by a table-function feed and batched `INSERT ... SELECT`: one statement per flush and one trampoline call per 2048 rows, so bulk loads skip per-row `INSERT` round trips |
| Persistence | Host-filesystem databases (open a path instead of `:memory:`), host-FS glob (`read_csv('data/*.csv')`) |
| DuckDB's own test corpus | sqllogictest (`test/sql/**`, 3,322 files): **2,522 files PASS / 9 FAIL / 791 SKIP** (2026-06-11, engine repo @ 790272e, runner `converge/cmd/sqllogic`; every remaining failure a documented permanent exclusion — canonical history in the engine repo's KNOWN-LIMITS.md) (runner committed in the [PoC repo](https://github.com/esilver/duckdb-wasm2go-poc)) |
| Proven downstream | Drives a pure-Go `googlesqlite` stack with a named CI spec conformance gate covering 707 spec files and 1,177 asserted cases (697 implemented, 7 partial, 3 unsupported), plus a pure-Go bigquery-emulator acceptance-tested with real clients including the `bq` CLI |
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

Build it (the command consumers need, verbatim):

```sh
CGO_ENABLED=0 go build .
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
way through `RegisterAggregateBandConn` (see `udf_agg_band.go` and the tests).
A complete runnable example is in
[`examples/basic`](examples/basic/main.go) (`make example`).

## Building and testing this repo

```sh
make build   # CGO_ENABLED=0 go build ./...
make test    # CGO_ENABLED=0 go test -vet=off ./...
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
- [duckdb/duckdb-go](https://github.com/duckdb/duckdb-go) (formerly marcboeker/go-duckdb), the official cgo-based DuckDB Go driver. This repo is an independent, from-scratch reimplementation over a wasm2go-transpiled engine and shares no code with it. It deliberately registers the same `database/sql` driver name (`duckdb`) to be a drop-in swap, so a single binary must not blank-import both.

## License

MIT. The embedded engine is DuckDB (MIT, Copyright Stichting DuckDB
Foundation) and bundles ICU (ICU license) via the icu extension — both notices
are included in [LICENSE](LICENSE); credits in [NOTICE](NOTICE).
