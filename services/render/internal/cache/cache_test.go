package cache

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestEvictsLeastRecentlyUsed(t *testing.T) {
	dir := t.TempDir()
	const cap int64 = 1024 * 10 // 10 KB
	c, err := Open(dir, cap)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer c.Close()

	ctx := context.Background()
	const entries = 8
	const entrySize = 2048 // 2 KB each → 16 KB total, well over cap
	keys := make([]string, entries)
	payload := make([]byte, entrySize)
	for i := range keys {
		keys[i] = Key("/fake.pdf", int64(i), 1, 300)
		if _, err := c.Put(ctx, keys[i], payload); err != nil {
			t.Fatalf("Put #%d: %v", i, err)
		}
	}

	// Touch the last-inserted entry so it is the most recently accessed.
	if _, hit, err := c.Get(ctx, keys[entries-1]); err != nil || !hit {
		t.Fatalf("Get last: hit=%v err=%v", hit, err)
	}

	// Insert one more to force another eviction pass.
	finalKey := Key("/fake.pdf", 9999, 1, 300)
	if _, err := c.Put(ctx, finalKey, payload); err != nil {
		t.Fatalf("Put final: %v", err)
	}

	total, err := c.TotalBytes(ctx)
	if err != nil {
		t.Fatalf("TotalBytes: %v", err)
	}
	if total > cap {
		t.Fatalf("total bytes %d exceeds cap %d", total, cap)
	}

	// Most-recently-accessed entry must survive.
	if _, hit, _ := c.Get(ctx, keys[entries-1]); !hit {
		t.Fatalf("expected MRU entry %s to survive, but it was evicted", keys[entries-1])
	}
	if _, hit, _ := c.Get(ctx, finalKey); !hit {
		t.Fatalf("expected just-inserted entry to survive")
	}

	// Earliest entry should be gone.
	if _, hit, _ := c.Get(ctx, keys[0]); hit {
		t.Fatalf("expected earliest entry %s to be evicted", keys[0])
	}
}

func TestStaleIndexRowOnMissingFile(t *testing.T) {
	dir := t.TempDir()
	c, err := Open(dir, 1<<20)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer c.Close()

	ctx := context.Background()
	key := Key("/fake.pdf", 1, 1, 300)
	if _, err := c.Put(ctx, key, []byte("hello")); err != nil {
		t.Fatalf("Put: %v", err)
	}
	// Nuke the file out from under the index.
	if err := os.Remove(filepath.Join(dir, key+".png")); err != nil {
		t.Fatalf("remove: %v", err)
	}
	_, hit, err := c.Get(ctx, key)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if hit {
		t.Fatal("expected miss when file is gone")
	}
	total, _ := c.TotalBytes(ctx)
	if total != 0 {
		t.Fatalf("expected 0 total after stale row cleanup, got %d", total)
	}
}

func TestKeyDeterminism(t *testing.T) {
	a := Key("/x.pdf", 12345, 3, 300)
	b := Key("/x.pdf", 12345, 3, 300)
	if a != b {
		t.Fatal("Key not deterministic")
	}
	if Key("/x.pdf", 12345, 3, 300) == Key("/x.pdf", 12345, 4, 300) {
		t.Fatal("Key collides on different page")
	}
	if len(a) != 64 {
		t.Fatalf("Key not hex-sha256: len=%d (%s)", len(a), strconv.Quote(a))
	}
}
