// Command basic is the smallest end-to-end consumer of the pure-Go DuckDB
// driver: open an in-memory database, create/insert/select, and register a Go
// scalar UDF that DuckDB calls back during query execution.
//
// Build it with the normal Go toolchain; no cgo or engine-specific flags are
// required:
//
//	CGO_ENABLED=0 go build ./examples/basic
package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
	"log"

	duckdb "github.com/esilver/duckdb-go-pure" // registers the "duckdb" driver
)

// duckdb_type ids (from duckdb.h) used with the UDF registration API.
const (
	duckdbTypeBigint = 5
)

func main() {
	db, err := sql.Open("duckdb", ":memory:")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	// Plain database/sql: DDL, DML, query.
	if _, err := db.Exec(`CREATE TABLE people (id BIGINT, name VARCHAR)`); err != nil {
		log.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO people VALUES (1, 'Ada'), (2, 'Grace')`); err != nil {
		log.Fatal(err)
	}
	rows, err := db.Query(`SELECT id, name FROM people ORDER BY id`)
	if err != nil {
		log.Fatal(err)
	}
	for rows.Next() {
		var id int64
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("row: %d %s\n", id, name)
	}
	if err := rows.Err(); err != nil {
		log.Fatal(err)
	}
	rows.Close()

	// Scalar UDF: my_add_one(BIGINT) -> BIGINT, implemented as a Go closure.
	// Registration is catalog-scoped: register once on any connection of the
	// pool and every connection of this db sees it.
	ctx := context.Background()
	conn, err := db.Conn(ctx)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()
	err = duckdb.RegisterScalarConn(conn, "my_add_one",
		[]int32{duckdbTypeBigint}, duckdbTypeBigint,
		-1,    // not variadic
		false, // default NULL handling
		false, // deterministic
		func(args []driver.Value) (any, error) {
			return args[0].(int64) + 1, nil
		})
	if err != nil {
		log.Fatal(err)
	}

	var out int64
	if err := db.QueryRow(`SELECT my_add_one(41)`).Scan(&out); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("my_add_one(41) = %d\n", out)
}
