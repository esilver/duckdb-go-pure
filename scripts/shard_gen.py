#!/usr/bin/env python3
"""Shard a wasm2go-generated gen.go into multiple files under GitHub's 100MB limit.

The wasm2go output for DuckDB is a single ~158MB Go file (package duckdbcore),
which cannot be committed to GitHub (hard limit: 100MB per file). This tool
streams the file and splits it on top-level `func ` boundaries into shards of
roughly --max-bytes each (default 40MB; the threshold leaves headroom so no
shard can approach 95MB).

Details handled:
  - gen_000.go keeps the original header verbatim (package decl + imports,
    including `_ "embed"`) plus everything before the first top-level func.
  - The `//go:embed gen.dat` directive and its `var data string` declaration,
    which sit mid-file in the wasm2go output, are hoisted into gen_000.go
    (the only shard that imports "embed").
  - Subsequent shards get a synthesized header: the original import set MINUS
    "embed".
  - Every shard ends with a blank-identifier use-guard block so that shards
    which happen not to use some import (e.g. unsafe, math/bits) still compile.
  - Comment/directive lines (e.g. //go:nosplit) immediately preceding a func
    are kept attached to that func when a split happens at the boundary.

Usage:
    python3 scripts/shard_gen.py <path/to/gen.go> <output-dir> [--max-bytes N]

Regenerating from scratch is documented in the README ("Regenerating the
engine"); the wasm build pipeline lives in github.com/esilver/duckdb-wasm2go-poc.
"""

import argparse
import os
import sys

SHARD_HEADER = """\
// Code generated; sharded from wasm2go output. DO NOT EDIT.

package duckdbcore

import (
\t"encoding/binary"
\t"math"
\t"math/bits"
\t"runtime"
\t"unsafe"
)
"""

# Appended to every shard so unused imports in any given shard are not a
# compile error (blank identifiers may be redeclared freely across files).
USE_GUARDS = """
var (
\t_ = binary.LittleEndian
\t_ = math.Pi
\t_ = bits.UintSize
\t_ = runtime.GOARCH
\t_ unsafe.Pointer
)
"""

EMBED_DIRECTIVE = "//go:embed gen.dat\n"
EMBED_VAR = "var data string\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("gen_go", help="path to the monolithic gen.go")
    ap.add_argument("outdir", help="directory to write gen_NNN.go shards into")
    ap.add_argument("--max-bytes", type=int, default=40 * 1024 * 1024,
                    help="rotation threshold per shard (default 40MiB)")
    args = ap.parse_args()

    # Rotate a little before the limit so the func that triggers rotation
    # cannot push the shard meaningfully past --max-bytes.
    threshold = args.max_bytes - 4 * 1024 * 1024

    os.makedirs(args.outdir, exist_ok=True)

    shard_idx = 0
    out = open(os.path.join(args.outdir, "gen_000.go"), "w")
    written = 0
    in_header = True          # before the first top-level func
    comment_run = []          # consecutive top-level //-lines, held back so
                              # directives stay attached to the func they precede
    embed_seen = False
    sizes = []

    def rotate():
        nonlocal out, written, shard_idx
        out.write(USE_GUARDS)
        out.close()
        sizes.append(os.path.getsize(out.name))
        shard_idx += 1
        out = open(os.path.join(args.outdir, "gen_%03d.go" % shard_idx), "w")
        out.write(SHARD_HEADER)
        written = len(SHARD_HEADER)

    with open(args.gen_go, "r") as f:
        for line in f:
            if in_header:
                out.write(line)
                written += len(line)
                if line.startswith("func "):
                    in_header = False
                continue

            if line.startswith("//"):
                comment_run.append(line)
                continue

            # Hoist the embed declaration (mid-file in wasm2go output) into
            # gen_000.go: only that shard imports "embed".
            if comment_run == [EMBED_DIRECTIVE] and line == EMBED_VAR:
                embed_seen = True
                comment_run = []
                continue

            if line.startswith("func ") and written >= threshold:
                rotate()

            for c in comment_run:
                out.write(c)
                written += len(c)
            comment_run = []
            out.write(line)
            written += len(line)

    for c in comment_run:  # trailing comments, if any
        out.write(c)
    out.write(USE_GUARDS)
    out.close()
    sizes.append(os.path.getsize(out.name))

    if not embed_seen:
        sys.exit("error: did not find '//go:embed gen.dat' + 'var data string' to hoist")
    with open(os.path.join(args.outdir, "gen_000.go"), "a") as f:
        f.write("\n" + EMBED_DIRECTIVE + EMBED_VAR)
    sizes[0] = os.path.getsize(os.path.join(args.outdir, "gen_000.go"))

    total = 0
    for i, s in enumerate(sizes):
        print("gen_%03d.go  %11d bytes" % (i, s))
        total += s
        if s >= 95 * 1024 * 1024:
            sys.exit("error: shard gen_%03d.go is >= 95MB" % i)
    print("total       %11d bytes in %d shards" % (total, len(sizes)))


if __name__ == "__main__":
    main()
