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
