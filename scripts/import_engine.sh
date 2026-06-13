#!/usr/bin/env bash
# Refresh this repo's engine + driver from an esilver/duckdb-wasm2go-poc
# checkout. The PoC repo generates the optimized multi-package engine
# (GENOPT=1 ./rebuild_fs_all.sh -> converge/genopt/{core,shardNN,all}); this
# script copies it in as internal/duckdbcore/{core,shardNN,all}, copies the
# driver + host packages, and rewrites the module-internal import paths.
#
# Usage: scripts/import_engine.sh /path/to/duckdb-wasm2go-poc
set -euo pipefail

POC=${1:?usage: import_engine.sh /path/to/duckdb-wasm2go-poc}
HERE=$(cd "$(dirname "$0")/.." && pwd)
MOD=github.com/esilver/duckdb-go-pure

[[ -f "$POC/converge/genopt/core/core.go" ]] || {
  echo "error: $POC/converge/genopt missing — run GENOPT=1 ./rebuild_fs_all.sh in the PoC first" >&2
  exit 1
}

rewrite() { # rewrite duckdbconverge import paths to this module's layout
  sed -i '' \
    -e "s|\"duckdbconverge/genopt/|\"$MOD/internal/duckdbcore/|g" \
    -e "s|\"duckdbconverge/exhost\"|\"$MOD/internal/exhost\"|g" \
    -e "s|\"duckdbconverge/wasishim\"|\"$MOD/internal/wasishim\"|g" \
    "$@"
}

echo "== engine: converge/genopt -> internal/duckdbcore (core + shards + all)"
rm -rf "$HERE/internal/duckdbcore"
mkdir -p "$HERE/internal/duckdbcore"
for d in "$POC"/converge/genopt/*/; do
  name=$(basename "$d")
  mkdir -p "$HERE/internal/duckdbcore/$name"
  cp "$d"/* "$HERE/internal/duckdbcore/$name/"
done
rewrite "$HERE"/internal/duckdbcore/shard*/shard.go "$HERE/internal/duckdbcore/all/all.go"

echo "== driver: converge/duckdb -> repo root (engine seam resolved to the optimized engine)"
find "$HERE" -maxdepth 1 -name '*.go' ! -name 'doc.go' -delete
for f in "$POC"/converge/duckdb/*.go; do
  base=$(basename "$f")
  # this repo ships only the optimized engine: no build-tag pair
  [[ "$base" == module_engine_genpkg.go ]] && continue
  cp "$f" "$HERE/$base"
done
# module_engine.go replaces the PoC's module_engine_genopt.go: same seam, but
# no build tag (this repo ships only the optimized engine) and consumer-facing
# prose instead of PoC build-pipeline references.
rm "$HERE/module_engine_genopt.go"
cat > "$HERE/module_engine.go" <<'EOF'
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
EOF
rewrite "$HERE"/*.go

echo "== internal/exhost"
rm -rf "$HERE/internal/exhost" && mkdir -p "$HERE/internal/exhost"
cp "$POC"/converge/exhost/*.go "$HERE/internal/exhost/"

echo "== internal/wasishim (with windows-portable statIdentity split)"
rm -rf "$HERE/internal/wasishim" && mkdir -p "$HERE/internal/wasishim"
cp "$POC"/converge/wasishim/*.go "$HERE/internal/wasishim/"
# The PoC keeps statIdentity inline in fs.go (syscall.Stat_t is unix-only);
# here it moves to stat_unix.go / stat_other.go so windows builds compile.
python3 - "$HERE/internal/wasishim/fs.go" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
inline = re.search(
    r'// statIdentity extracts.*?\nfunc statIdentity\(fi os\.FileInfo\) \(dev, ino, nlink uint64\) \{.*?\n\}\n',
    s, re.S)
assert inline, "statIdentity block not found in fs.go"
s = s.replace(inline.group(0),
    '// statIdentity (per-platform, see stat_unix.go / stat_other.go) extracts\n'
    '// (dev, ino, nlink) from an os.FileInfo. On unix it reads the underlying\n'
    '// *syscall.Stat_t; elsewhere it returns zeros (DuckDB does not depend on\n'
    '// these for reading data files).\n')
open(p, 'w').write(s)
PY
cat > "$HERE/internal/wasishim/stat_unix.go" <<'EOF'
//go:build unix

package wasishim

import (
	"os"
	"syscall"
)

// statIdentity extracts (dev, ino, nlink) from an os.FileInfo via the
// underlying *syscall.Stat_t.
func statIdentity(fi os.FileInfo) (dev, ino, nlink uint64) {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && st != nil {
		return uint64(st.Dev), uint64(st.Ino), uint64(st.Nlink)
	}
	return 0, 0, 0
}
EOF
cat > "$HERE/internal/wasishim/stat_other.go" <<'EOF'
//go:build !unix

package wasishim

import "os"

// statIdentity returns zeros on platforms without syscall.Stat_t (e.g.
// windows). DuckDB does not depend on (dev, ino, nlink) for reading data
// files; inode-based dedup is simply disabled.
func statIdentity(fi os.FileInfo) (dev, ino, nlink uint64) {
	_ = fi
	return 0, 0, 0
}
EOF

echo "== gofmt (driver + host packages; duckdbcore stays as generated)"
gofmt -w "$HERE"/*.go "$HERE"/internal/exhost "$HERE"/internal/wasishim

echo "== provenance: record engine source + artifact hashes -> PROVENANCE"
GEN_DAT="$HERE/internal/duckdbcore/core/gen.dat"
{
  echo "# Engine provenance for duckdb-go-pure."
  echo "# Regenerated by scripts/import_engine.sh at import time. Do not hand-edit."
  echo
  echo "duckdb_version: v1.5.3 (C-API amalgamation + core_functions + json + icu, statically linked)"
  echo "engine_source_repo: github.com/esilver/duckdb-wasm2go-poc"
  echo "engine_source_commit: $(git -C "$POC" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "engine_source_describe: $(git -C "$POC" describe --always --dirty 2>/dev/null || echo unknown)"
  echo "gen_dat_sha256: $(shasum -a 256 "$GEN_DAT" 2>/dev/null | cut -d' ' -f1)"
  echo "gen_dat_bytes: $(wc -c < "$GEN_DAT" 2>/dev/null | tr -d ' ')"
  echo
  echo "# The emcc/wasm2go versions and the exact build flags are recorded by the"
  echo "# PoC build scripts (build_with_core.sh / rebuild_fs_all.sh) at the engine"
  echo "# source commit above."
} > "$HERE/PROVENANCE"
echo "wrote $HERE/PROVENANCE"

echo "done. Engine source of record: $POC ($(git -C "$POC" rev-parse --short HEAD))"
