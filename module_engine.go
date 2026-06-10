package duckdb

// The engine seam: engineModule/engineNew bind the driver (module.go) to the
// generated engine. This repo ships the optimized multi-package engine —
// internal/duckdbcore/{core,shardNN,all}, produced by the PoC repo's
// scripts/transform_genopt.py — whose ~30 small packages the Go optimizer can
// compile fully optimized (per-package compiler memory; the old monolithic
// layout OOMed the optimizer at ~50GB and had to ship -N -l). Build flags are
// load-bearing; see doc.go "Build flags (required)":
//
//	CGO_ENABLED=0 go build \
//	  -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore/...=-l -c=1' \
//	  -gcflags='github.com/esilver/duckdb-go-pure/internal/duckdbcore/core=-c=1' ./...
//
// '-l' on the shards is MANDATORY: default inlining re-expands the generated
// IR and the compile OOMs at ~50GB.

import (
	engine "github.com/esilver/duckdb-go-pure/internal/duckdbcore/core"

	// The shards register every TBL_FnN func-var in core via their init()s;
	// without this blank import the engine's function table is all-nil.
	_ "github.com/esilver/duckdb-go-pure/internal/duckdbcore/all"
)

type engineModule = engine.Module

var engineNew = engine.New
