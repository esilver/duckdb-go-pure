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
// # Build flags (none required)
//
// The transpiled engine (internal/duckdbcore) is sharded into ~30 packages
// (and its oversized functions split) so the Go optimizer can compile it
// fully optimized, inlining included. No build flags are required:
//
//	CGO_ENABLED=0 go build ./...
//
// Optional PGO: default.pgo in this module measured a further 1.3-1.8x
// when passed to your main-package build via -pgo.
//
// All other packages, including this driver and your application, compile with
// default flags. go test additionally needs -vet=off. Since v0.3.0 the module
// also builds for GOOS=js GOARCH=wasm (browser/Node).
//
// # Beyond database/sql
//
// The package also exposes DuckDB-specific extension points on a per-connection
// basis: scalar UDFs (RegisterScalarConn), band-merge aggregate UDFs
// (RegisterAggregateBandConn, AggregateOptions), an Appender for bulk loading
// (DuckDB's native appender, ~100x faster than per-row INSERT), plus the
// JSONValue and Decimal value types used to round-trip DuckDB JSON and DECIMAL
// values through UDFs and result scans.
package duckdb
