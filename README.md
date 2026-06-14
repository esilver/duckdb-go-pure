# duckdb-go-pure

[![CI](https://github.com/esilver/duckdb-go-pure/actions/workflows/ci.yml/badge.svg)](https://github.com/esilver/duckdb-go-pure/actions/workflows/ci.yml)

**DuckDB as a pure-Go `database/sql` driver. `CGO_ENABLED=0`, no libduckdb, no shared libraries.**

DuckDB v1.5.3 (the C-API amalgamation, with `core_functions`, `json` and `icu`
statically linked) is compiled to WebAssembly with Emscripten and transpiled to
Go with [ncruces/wasm2go](https://github.com/ncruces/wasm2go) — the approach
[ncruces/go-sqlite3](https://github.com/ncruces/go-sqlite3) uses for SQLite. The
transpiled engine lives in `internal/duckdbcore`. This package wraps it in an
idiomatic `database/sql` driver plus DuckDB extension points (scalar and
aggregate UDFs as Go closures the engine calls back during execution).

Extracted from the proof of concept at
[esilver/duckdb-wasm2go-poc](https://github.com/esilver/duckdb-wasm2go-poc),
which holds the full wasm build pipeline.

## Quickstart

```sh
go get github.com/esilver/duckdb-go-pure   # current release line: v0.3.x
```

```go
import (
	"database/sql"

	_ "github.com/esilver/duckdb-go-pure" // registers the "duckdb" driver
)

db, _ := sql.Open("duckdb", ":memory:") // or a file path for persistence
```

Build with the standard toolchain, no flags:

```sh
CGO_ENABLED=0 go build ./...
```

`go test` additionally needs `-vet=off` (`go vet` cannot analyze the very large
generated engine packages). A complete runnable program is
[`examples/basic`](examples/basic/main.go) (`make example`). See
[How it works](#how-it-works) for why the transpiled engine compiles fully
optimized with no special flags.

## The stack

This driver is the engine layer of a pure-Go, DuckDB-backed BigQuery emulator,
each repo a fork retargeted to this engine. Top to bottom:

- [esilver/bigquery-emulator](https://github.com/esilver/bigquery-emulator) — the BigQuery REST API server (forks goccy/bigquery-emulator).
- [esilver/googlesqlite](https://github.com/esilver/googlesqlite) — the GoogleSQL engine: lowers analyzed BigQuery SQL to DuckDB SQL and registers BigQuery builtins as DuckDB UDFs (forks goccy/googlesqlite, retargeted from SQLite to DuckDB).
- [esilver/go-googlesql](https://github.com/esilver/go-googlesql) — the ZetaSQL analyzer bridge (forks goccy/go-googlesql).
- **duckdb-go-pure** (this repo) — DuckDB itself, as a pure-Go `database/sql` driver.

The whole stack runs `CGO_ENABLED=0` with no native libraries.

## Capabilities

- **`database/sql` driver** — driver name `"duckdb"`, `:memory:` and file DSNs.
- **Scalar UDFs** — Go closures the engine calls back, vectorized ([`RegisterScalarConn`](udf_register.go), [example](examples/basic/main.go)): fixed args, varargs, NULL handling, volatile. Registration is catalog-scoped: register on one connection and every connection of that `*sql.DB` sees the function.
- **Aggregate UDFs** — band-merge aggregates ([`RegisterAggregateBandConn`](udf_register.go) + `AggregateOptions`).
- **Bulk loading** — [`Appender`](appender.go)-shaped path over a table-function feed and batched `INSERT ... SELECT`: one statement per flush, one trampoline call per 2048 rows, so bulk loads skip per-row `INSERT` round trips.
- **Value types** — `JSONValue`, `Decimal`, dates/times/timestamps, lists, structs, maps, enums, unions, intervals, UUID, blobs, HUGEINT, BIT, TIMETZ, BIGNUM, GEOMETRY (WKT), VARIANT.
- **Column metadata** — `ColumnType.DatabaseTypeName` returns the full DuckDB type name, recursive for nested types (duckdb-go parity).
- **Pooling** — `rows.Next`/`Close` take the shared engine lock, so pooled `database/sql` connections interleave freely.
- **Statement cancellation** — context cancellation interrupts a *running* statement (via DuckDB's interrupt flag): a runaway query on a cancelled context returns a native `INTERRUPT Error` joined with the context error within milliseconds, and the engine stays healthy.
- **Persistence** — host-filesystem databases (open a path instead of `:memory:`) and host-FS glob (`read_csv('data/*.csv')`).

Scalar UDF sketch:

```go
const duckdbTypeBigint = 5 // duckdb_type id from duckdb.h

conn, _ := db.Conn(context.Background())
defer conn.Close()

duckdb.RegisterScalarConn(conn, "my_add_one",
	[]int32{duckdbTypeBigint}, duckdbTypeBigint,
	duckdb.ScalarOptions{}, // VarargsTypeID -1, deterministic, default NULLs
	func(args []driver.Value) (any, error) {
		return args[0].(int64) + 1, nil
	})

var out int64
db.QueryRow(`SELECT my_add_one(41)`).Scan(&out) // 42
```

## Status

Pure Go, runs anywhere Go runs, **including `GOOS=js GOARCH=wasm`** since v0.3.0
(64-bit recommended, as the engine wants multi-GB compile-time and runtime memory).

Conformance against DuckDB's own sqllogictest corpus (`test/sql/**`, 3,322
files): **2,522 PASS / 9 FAIL / 791 SKIP**.[^slt] Each remaining failure is a
documented permanent exclusion. Proven downstream: drives the pure-Go
`googlesqlite` stack behind a CI conformance gate (707 spec files, 1,177
asserted cases — 697 implemented, 7 partial, 3 unsupported) and a pure-Go
bigquery-emulator acceptance-tested with real clients including the `bq` CLI.

[^slt]: Run 2026-06-11 against engine repo @ `790272e` with the
`converge/cmd/sqllogic` runner, committed in the
[PoC repo](https://github.com/esilver/duckdb-wasm2go-poc). Canonical history is
in the engine repo's `KNOWN-LIMITS.md`.

## Caveats

- **Not for production.** This is a showcase of pure-Go DuckDB, shared for
  interest and experimentation. The official cgo driver,
  [duckdb/duckdb-go](https://github.com/duckdb/duckdb-go), remains the
  recommended driver for production use.
- **Slower than native DuckDB.** wasm2go emits no SIMD, so the gap is widest on
  SIMD-friendly scan/aggregate. The engine still compiles fully optimized +
  inlined since v0.3.0: 2.3–2.9× faster than v0.2.x, which was 2.0–2.6× faster
  than the v0.1.x monolith. PGO measured no effect on the fully-inlined engine,
  so no profile ships.
- **Compile cost, not runtime cost.** The transpiled engine is very large Go
  code: ~30s cold build, ~3GB worst single compile process (16 cores), cached
  after the first build. Add `-p 1` only if you are tight on RAM. Your own code
  and this driver build with default flags.

## How it works

The engine ships sharded into ~30 packages
(`internal/duckdbcore/{core,shardNN,all}`) and every oversized transpiled
function (up to 36.5k lines) is split into part-functions, which keeps the Go
optimizer's per-package memory bounded, lets the shards compile with inlining
enabled, and fits the largest function under the compiler's 65536-SSA-block hard
cap (the cap that previously blocked every `GOOS=js` build).

- `internal/duckdbcore` — the wasm2go output: DuckDB's wasm module as Go. `core`
  holds the `Module` type, memory helpers, dispatch, and the `//go:embed`-ed
  6MB `gen.dat`. The ~29 `shardNN` packages hold the 42.5k generated functions
  (cross-shard calls go through `TBL_FnN` func-vars), and `all` blank-imports
  every shard. Linear wasm memory is a `[]byte`, and the indirect function table
  is a `[]any` of Go funcs — which is exactly what makes Go-closure UDF
  callbacks possible.
- `internal/exhost` — a Go implementation of Emscripten's C++ exception ABI
  (`invoke_*` trampolines, `__cxa_throw` & friends) via panic/recover, so
  DuckDB's `-fexceptions` build unwinds correctly.
- `internal/wasishim` — the WASI + Emscripten host surface (clock, rng, stdout,
  and a host-filesystem layer so file-backed databases persist).
- The root `duckdb` package drives the engine through the DuckDB C API
  (`duckdb_open`/`duckdb_query`/data chunks) and adapts it to
  `database/sql/driver`.

Maintainers: `make jsgate` adds a `GOOS=js` compile check before tagging, since
the wasm backend enforces the SSA-block cap that native builds do not.

## Regenerating the engine

The wasm build pipeline (Emscripten flags, DuckDB amalgamation build, wasm2go
invocation, the multi-package optimizer transform) lives in the
[PoC repo](https://github.com/esilver/duckdb-wasm2go-poc), not here. To refresh
this repo from a PoC checkout (after `GENOPT=1 ./rebuild_fs_all.sh` there has
populated `converge/genopt`):

```sh
scripts/import_engine.sh path/to/duckdb-wasm2go-poc
make test
```

## Related

- [esilver/duckdb-wasm2go-poc](https://github.com/esilver/duckdb-wasm2go-poc) — provenance: the PoC + engine build pipeline.
- [ncruces/wasm2go](https://github.com/ncruces/wasm2go) — the wasm-to-Go transpiler.
- [ncruces/go-sqlite3](https://github.com/ncruces/go-sqlite3) — the pattern this module follows, for SQLite.
- [duckdb/duckdb](https://github.com/duckdb/duckdb) — DuckDB itself.
- [duckdb/duckdb-go](https://github.com/duckdb/duckdb-go) (formerly marcboeker/go-duckdb) — the official cgo DuckDB Go driver. This repo is an independent, from-scratch reimplementation over a wasm2go-transpiled engine and shares no code with it. It deliberately registers the same `database/sql` driver name (`duckdb`) to be a drop-in swap, so a single binary must not blank-import both.

## License

MIT. The embedded engine is DuckDB (MIT, Copyright Stichting DuckDB Foundation)
and bundles ICU (ICU license) via the icu extension — both notices are in
[LICENSE](LICENSE), with credits in [NOTICE](NOTICE).
