package cache

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// Cache is a disk-backed LRU keyed by SHA256 hashes.
//
// Files live at <dir>/<key>.png; an SQLite index tracks size and last-access.
// All mutations are guarded by a single mutex — the bottleneck is filesystem
// I/O rather than the index, so finer-grained locking would add complexity
// without a measurable win.
type Cache struct {
	dir      string
	maxBytes int64
	db       *sql.DB
	mu       sync.Mutex
}

func Open(dir string, maxBytes int64) (*Cache, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir cache dir: %w", err)
	}
	dbPath := filepath.Join(dir, "index.db")
	db, err := sql.Open("sqlite", dbPath+"?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS entries (
			key         TEXT PRIMARY KEY,
			size_bytes  INTEGER NOT NULL,
			last_access INTEGER NOT NULL
		);
		CREATE INDEX IF NOT EXISTS idx_entries_last_access ON entries(last_access);
	`); err != nil {
		db.Close()
		return nil, fmt.Errorf("init schema: %w", err)
	}
	return &Cache{dir: dir, maxBytes: maxBytes, db: db}, nil
}

func (c *Cache) Close() error { return c.db.Close() }

// Key derives a deterministic cache key from the inputs that identify a
// rendered page.
func Key(absPath string, mtimeUnix int64, page int, dpi float64) string {
	h := sha256.New()
	io.WriteString(h, absPath)
	io.WriteString(h, "|")
	io.WriteString(h, strconv.FormatInt(mtimeUnix, 10))
	io.WriteString(h, "|")
	io.WriteString(h, strconv.Itoa(page))
	io.WriteString(h, "|")
	io.WriteString(h, strconv.FormatFloat(dpi, 'f', -1, 64))
	return hex.EncodeToString(h.Sum(nil))
}

func (c *Cache) Path(key string) string {
	return filepath.Join(c.dir, key+".png")
}

// Get reports whether a cache file exists for key. On hit it bumps last_access.
// Missing files (e.g. cleaned by hand) are treated as misses and the stale
// index row is dropped.
func (c *Cache) Get(ctx context.Context, key string) (string, bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	path := c.Path(key)
	if _, err := os.Stat(path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			_, _ = c.db.ExecContext(ctx, `DELETE FROM entries WHERE key = ?`, key)
			return "", false, nil
		}
		return "", false, fmt.Errorf("stat cache file: %w", err)
	}
	if _, err := c.db.ExecContext(ctx, `UPDATE entries SET last_access = ? WHERE key = ?`, time.Now().Unix(), key); err != nil {
		return "", false, fmt.Errorf("update last_access: %w", err)
	}
	return path, true, nil
}

// Put writes data atomically and records the entry, then evicts least-recently
// accessed entries until the total size is under the cap.
func (c *Cache) Put(ctx context.Context, key string, data []byte) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	path := c.Path(key)
	if err := writeAtomic(path, data); err != nil {
		return "", err
	}
	if _, err := c.db.ExecContext(ctx,
		`INSERT INTO entries(key, size_bytes, last_access) VALUES (?, ?, ?)
		 ON CONFLICT(key) DO UPDATE SET size_bytes = excluded.size_bytes, last_access = excluded.last_access`,
		key, int64(len(data)), time.Now().Unix(),
	); err != nil {
		return "", fmt.Errorf("insert entry: %w", err)
	}
	if err := c.evictLocked(ctx); err != nil {
		return "", err
	}
	return path, nil
}

func (c *Cache) evictLocked(ctx context.Context) error {
	var total int64
	if err := c.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(size_bytes), 0) FROM entries`).Scan(&total); err != nil {
		return fmt.Errorf("sum entries: %w", err)
	}
	if total <= c.maxBytes {
		return nil
	}
	rows, err := c.db.QueryContext(ctx, `SELECT key, size_bytes FROM entries ORDER BY last_access ASC`)
	if err != nil {
		return fmt.Errorf("list entries: %w", err)
	}
	type victim struct {
		key  string
		size int64
	}
	var victims []victim
	for rows.Next() {
		var v victim
		if err := rows.Scan(&v.key, &v.size); err != nil {
			rows.Close()
			return fmt.Errorf("scan entry: %w", err)
		}
		victims = append(victims, v)
		total -= v.size
		if total <= c.maxBytes {
			break
		}
	}
	if err := rows.Close(); err != nil {
		return fmt.Errorf("close rows: %w", err)
	}
	for _, v := range victims {
		if err := os.Remove(c.Path(v.key)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove cache file: %w", err)
		}
		if _, err := c.db.ExecContext(ctx, `DELETE FROM entries WHERE key = ?`, v.key); err != nil {
			return fmt.Errorf("delete entry: %w", err)
		}
	}
	return nil
}

// TotalBytes is exposed for tests.
func (c *Cache) TotalBytes(ctx context.Context) (int64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	var total int64
	err := c.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(size_bytes), 0) FROM entries`).Scan(&total)
	return total, err
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return fmt.Errorf("open tmp: %w", err)
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("sync tmp: %w", err)
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("close tmp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename tmp: %w", err)
	}
	return nil
}
