// Package duckdb provides a pure-Go (CGO_ENABLED=0) database/sql driver for
// DuckDB. No libduckdb, no cgo: the DuckDB engine (v1.5.3, with core_functions,
// json and icu statically linked) is compiled to WebAssembly with Emscripten
// and transpiled to Go with wasm2go (github.com/ncruces/wasm2go) — the approach
// github.com/ncruces/go-sqlite3 uses for SQLite. The driver talks to the
// transpiled engine through DuckDB's C API surface.
//
// Importing the package registers the "duckdb" driver:
//
//	import (
//		"database/sql"
//
//		_ "github.com/esilver/duckdb-go-pure"
//	)
//
//	db, err := sql.Open("duckdb", ":memory:")
//
// The data source name is ":memory:" (or empty) for an in-memory database, or a
// filesystem path for a host-filesystem-backed persistent database.
//
// The registered "duckdb" name makes this a drop-in swap for the official cgo
// driver (github.com/duckdb/duckdb-go). A single binary must not blank-import
// both, since both register that name.
//
// # Build flags (none required)
//
//	CGO_ENABLED=0 go build ./...
//
// go test additionally needs -vet=off. The README "How it works" section
// explains why the transpiled engine compiles fully optimized with no special
// flags.
//
// # Beyond database/sql
//
// Per-connection DuckDB extension points beyond the standard interface:
//
//   - Scalar UDFs (RegisterScalarConn, ScalarOptions) and band-merge aggregate
//     UDFs (RegisterAggregateBandConn, AggregateOptions), as Go closures the
//     engine calls back during query execution.
//   - An Appender-shaped bulk path over a table-function feed and batched
//     INSERT ... SELECT (one statement per flush, so bulk loads skip per-row
//     INSERT round trips).
//   - The JSONValue and Decimal value types that round-trip DuckDB JSON and
//     DECIMAL through UDFs and result scans.
package duckdb
