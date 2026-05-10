package notify

import (
	"context"
	"fmt"
	"strconv"

	"github.com/jackc/pgx/v5/pgxpool"
)

// RenderDone signals Rails (or any other LISTEN render_done client) that the
// JPEG for ocrRequestID is on disk.
func RenderDone(ctx context.Context, pool *pgxpool.Pool, ocrRequestID int64) error {
	if _, err := pool.Exec(ctx, `SELECT pg_notify($1, $2)`, "render_done", strconv.FormatInt(ocrRequestID, 10)); err != nil {
		return fmt.Errorf("pg_notify render_done %d: %w", ocrRequestID, err)
	}
	return nil
}
