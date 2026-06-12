package duckdb

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"testing"
)

func TestBeginTxRejectsUnsupportedOptions(t *testing.T) {
	raw, err := (&Driver{}).Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	c := raw.(driver.ConnBeginTx)

	if _, err := c.BeginTx(context.Background(), driver.TxOptions{ReadOnly: true}); err == nil || !strings.Contains(err.Error(), "read-only") {
		t.Fatalf("read-only BeginTx error = %v; want read-only rejection", err)
	}
	if _, err := c.BeginTx(context.Background(), driver.TxOptions{Isolation: driver.IsolationLevel(sql.LevelSerializable)}); err == nil || !strings.Contains(err.Error(), "unsupported isolation") {
		t.Fatalf("isolation BeginTx error = %v; want unsupported isolation rejection", err)
	}
}

func TestPingHonorsCanceledContext(t *testing.T) {
	raw, err := (&Driver{}).Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	p := raw.(driver.Pinger)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := p.Ping(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("Ping canceled error = %v; want context.Canceled", err)
	}
}
