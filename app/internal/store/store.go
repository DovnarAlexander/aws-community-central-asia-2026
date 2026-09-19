// Package store is the connection pool and the three queries the demo runs
// against it.
//
// The pool is the pressure point of the whole talk. Every replica opens
// PoolMax connections and holds them, so `replicas x PoolMax` is a number that
// either fits inside the database's max_connections or does not -- and when it
// does not, the failure arrives on stage rather than in production.
package store

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Rows seeded by db/seed.sql. The work query picks a window inside this range.
const SeededRows = 2_000_000

type Config struct {
	DSN     string
	PoolMax int32
}

type Store struct {
	pool *pgxpool.Pool
}

func Open(ctx context.Context, cfg Config) (*Store, error) {
	pcfg, err := pgxpool.ParseConfig(cfg.DSN)
	if err != nil {
		return nil, fmt.Errorf("parse DSN: %w", err)
	}

	pcfg.MaxConns = cfg.PoolMax

	// MinConns equal to MaxConns means the pool is claimed in full at startup
	// rather than growing under load. Without it the connection wall arrives
	// late and smeared across a minute, instead of exactly when the replica
	// count crosses the line -- and a failure that arrives vaguely is a failure
	// the audience does not believe.
	pcfg.MinConns = cfg.PoolMax

	pcfg.MaxConnLifetime = time.Hour
	pcfg.HealthCheckPeriod = 5 * time.Second
	pcfg.ConnConfig.ConnectTimeout = 5 * time.Second

	pool, err := pgxpool.NewWithConfig(ctx, pcfg)
	if err != nil {
		return nil, fmt.Errorf("pool: %w", err)
	}
	return &Store{pool: pool}, nil
}

func (s *Store) Close() { s.pool.Close() }

// Warm opens the whole pool before the process reports itself started, for the
// same reason MinConns is set: predictable timing.
func (s *Store) Warm(ctx context.Context) {
	n := int(s.pool.Config().MaxConns)
	conns := make([]*pgxpool.Conn, 0, n)

	for range n {
		c, err := s.pool.Acquire(ctx)
		if err != nil {
			// Expected once the database is out of connection slots. Say so
			// plainly: this line is the evidence for the wall.
			log.Printf("warmup: pool at %d/%d connections: %v", len(conns), n, err)
			break
		}
		if _, err := c.Exec(ctx, `SELECT 1`); err != nil {
			log.Printf("warmup: ping failed: %v", err)
		}
		conns = append(conns, c)
	}

	for _, c := range conns {
		c.Release()
	}
	log.Printf("warmup: pool ready, %d/%d connections", len(conns), n)
}

// Work is what the service exists to do: aggregate a window of rows. Real
// traffic costs the database real CPU, which is the point -- in act 2 the
// probes are not hitting an idle database, they are competing with the work
// the service was built for.
//
// The window start is chosen in Go rather than with random() in the WHERE
// clause. Inline, the expression is volatile, the planner loses the index scan,
// and every request becomes a full pass over two million rows -- which would
// make the query expensive for a reason that has nothing to do with the talk.
func (s *Store) Work(ctx context.Context, rows int, latency time.Duration) error {
	from := rand.Int63n(int64(SeededRows - rows))

	var count int64
	var maxLen int
	err := s.pool.QueryRow(ctx,
		`SELECT count(*), max(length(payload)) FROM items WHERE id BETWEEN $1 AND $2`,
		from, from+int64(rows),
	).Scan(&count, &maxLen)
	if err != nil {
		return err
	}

	if latency > 0 {
		// Real work on a real connection: the pool slot stays occupied for the
		// duration, which is what lets a busy service starve its own probes.
		if _, err := s.pool.Exec(ctx, `SELECT pg_sleep($1)`, latency.Seconds()); err != nil {
			return err
		}
	}
	return nil
}

// Ping is the cheap check: one round trip, no scan. This is what a readiness
// probe should cost, and what the background refresher in health uses.
func (s *Store) Ping(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, `SELECT 1`)
	return err
}

// ExpensiveCheck is the antipattern, written the way it gets written in real
// life: "readiness should verify we can actually read our data". No index can
// help a leading-wildcard LIKE, so it is a full pass over two million rows --
// per replica, per probe period. Three replicas hide it. Sixteen do not.
func (s *Store) ExpensiveCheck(ctx context.Context) error {
	var n int64
	return s.pool.QueryRow(ctx,
		`SELECT count(*) FROM items WHERE payload LIKE '%needle%'`,
	).Scan(&n)
}

// Stat reports what the psql panel on stage shows, so the driver and the
// application agree on the numbers.
type Stat struct {
	Connections    int
	Active         int
	MaxConnections int
}

func (s *Store) Stat(ctx context.Context) (Stat, error) {
	var st Stat
	err := s.pool.QueryRow(ctx, `
		SELECT count(*),
		       count(*) FILTER (WHERE state = 'active'),
		       current_setting('max_connections')::int
		FROM pg_stat_activity
		WHERE datname = current_database()
	`).Scan(&st.Connections, &st.Active, &st.MaxConnections)
	return st, err
}
