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
