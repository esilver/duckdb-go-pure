// Package duckdb provides a pure-Go (CGO_ENABLED=0) database/sql driver for
// DuckDB. No libduckdb, no cgo: the DuckDB engine (v1.5.3, with the
// core_functions, json and icu extensions statically linked) is compiled to
// WebAssembly with Emscripten and transpiled to Go with wasm2go
// (github.com/ncruces/wasm2go) — the same approach github.com/ncruces/go-sqlite3
// uses for SQLite. The driver talks to the transpiled engine through DuckDB's
// C API surface.
//
// Registering the driver is a side effect of importing the package:
//
//	import (
//		"database/sql"
//
//		_ "github.com/esilver/duckdb-go-pure"
//	)
//
//	db, err := sql.Open("duckdb", ":memory:")
//
// The data source name is either ":memory:" (or empty) for an in-memory
// database, or a filesystem path for a persistent database backed by the host
// filesystem.
//
// This package registers the "duckdb" driver name so it can be a drop-in swap
// for the official cgo driver (github.com/duckdb/duckdb-go). A single binary
// must not blank-import both, since both register the same name.
//
// # Build flags (none required)
//
//	CGO_ENABLED=0 go build ./...
//
// go test additionally needs -vet=off. The README "How it works" section
// explains why the transpiled engine still compiles fully optimized with no
// special flags.
//
// # Beyond database/sql
//
// The package also exposes DuckDB-specific extension points on a per-connection
// basis: scalar UDFs (RegisterScalarConn), band-merge aggregate UDFs
// (RegisterAggregateBandConn, AggregateOptions), an Appender-shaped bulk path
// backed by a table-function feed and batched INSERT ... SELECT (one statement
// per flush, so bulk loads skip per-row INSERT round trips), plus the JSONValue
// and Decimal value types used to
// round-trip DuckDB JSON and DECIMAL values through UDFs and result scans.
package duckdb
