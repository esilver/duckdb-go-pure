package duckdb

// The engine seam: engineModule/engineNew bind the driver (module.go) to the
// generated engine. This repo ships the optimized multi-package engine —
// internal/duckdbcore/{core,shardNN,all}, produced by the PoC repo's
// scripts/transform_genopt.py (per-package sharding) and
// scripts/split_giant_fns.py (oversized-function splitting) — whose ~30 small
// packages the Go optimizer can compile fully optimized WITH inlining (the
// pre-split layout needed '-l' on the shards; the pre-shard monolith OOMed
// the optimizer at ~50GB and had to ship -N -l). No build flags are
// required — plain 'go build ./...' compiles the engine; see doc.go
// "Build flags (none required)".

import (
	engine "github.com/esilver/duckdb-go-pure/internal/duckdbcore/core"

	// The shards register every TBL_FnN func-var in core via their init()s;
	// without this blank import the engine's function table is all-nil.
	_ "github.com/esilver/duckdb-go-pure/internal/duckdbcore/all"
)

type engineModule = engine.Module

var engineNew = engine.New
