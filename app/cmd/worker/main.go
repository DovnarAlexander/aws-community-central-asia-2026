// worker is the queue consumer KEDA scales and act 2 breaks.
//
// It has no inbound traffic of its own, which is what makes its probes
// interesting: there is no natural signal of health, so people invent one.
// The usual invention is "have I processed anything recently", which cannot
// tell a stuck worker from an empty queue -- so the whole fleet restarts at
// precisely the moment it has finished all the work.
//
// Environment:
//
//	PORT                    probe listener                                (8080)
//	DSN                     Postgres DSN                                  (required)
//	QUEUE_URL               SQS work queue                                (required)
//	WARMUP_SECONDS          how long the worker pretends to warm up       (5)
//	WORK_LATENCY_MS         how long a message holds a pooled connection  (50)
//	WORK_ROWS               rows a message aggregates                     (3000)
//	POOL_MAX                pool size per replica -- and the wall         (4)
//	CONCURRENCY             messages processed at once per replica        (2)
//	HEALTHZ_MODE            last_message | local                          (local)
//	READY_MODE              db_each_call | cached                         (cached)
//	MAX_IDLE_SECONDS        silence tolerated by HEALTHZ_MODE=last_message (30)
//	READY_PING_INTERVAL_MS  background refresher period                   (2000)
//	READY_PING_TIMEOUT_MS   background refresher timeout                  (1000)
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"probes-demo/internal/appenv"
	"probes-demo/internal/health"
	"probes-demo/internal/store"
	"probes-demo/internal/work"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)

	var (
		port        = appenv.String("PORT", "8080")
		dsn         = appenv.MustString("DSN")
		queueURL    = appenv.MustString("QUEUE_URL")
		warmup      = appenv.Seconds("WARMUP_SECONDS", 5)
		workLatency = appenv.Millis("WORK_LATENCY_MS", 50)
		workRows    = appenv.Int("WORK_ROWS", 3000)
		poolMax     = appenv.Int("POOL_MAX", 4)
		concurrency = appenv.Int("CONCURRENCY", 2)
		healthzMode = appenv.String("HEALTHZ_MODE", health.LivenessLocal)
		readyMode   = appenv.String("READY_MODE", health.ReadinessCached)
		maxIdle     = appenv.Seconds("MAX_IDLE_SECONDS", 30)
	)

	log.Printf("boot: warmup=%s work_rows=%d pool_max=%d concurrency=%d healthz=%s ready=%s max_idle=%s",
		warmup, workRows, poolMax, concurrency, healthzMode, readyMode, maxIdle)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	st, err := store.Open(ctx, store.Config{DSN: dsn, PoolMax: int32(poolMax)})
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	defer st.Close()

	queue, err := work.Open(ctx, queueURL)
	if err != nil {
		log.Fatalf("queue: %v", err)
	}

	h := health.New(health.Options{
		Store:        st,
		Liveness:     healthzMode,
		Readiness:    readyMode,
		PingInterval: appenv.Millis("READY_PING_INTERVAL_MS", 2000),
		PingTimeout:  appenv.Millis("READY_PING_TIMEOUT_MS", 1000),
		MaxIdle:      maxIdle,
	})

	go func() {
		start := time.Now()
		st.Warm(ctx)
		if left := warmup - time.Since(start); left > 0 {
			select {
			case <-time.After(left):
			case <-ctx.Done():
				return
			}
		}
		h.MarkWarm()
		log.Printf("warmup finished after %s -- consuming now", time.Since(start).Round(time.Millisecond))
	}()

	if readyMode == health.ReadinessCached {
		go h.RunPingLoop(ctx)
	}

	srv := &http.Server{Addr: ":" + port, Handler: h.Handler()}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()
	log.Printf("probes listening on :%s", port)

	consume(ctx, queue, st, h, consumeOpts{
		concurrency: concurrency,
		workRows:    workRows,
		workLatency: workLatency,
		cachedReady: readyMode == health.ReadinessCached,
	})

	log.Printf("shutting down")
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdown)
}

type consumeOpts struct {
	concurrency int
	workRows    int
	workLatency time.Duration
	cachedReady bool
}

func consume(ctx context.Context, queue *work.Queue, st *store.Store, h *health.Server, opt consumeOpts) {
	for ctx.Err() == nil {
		if !h.IsWarm() {
			sleep(ctx, 500*time.Millisecond)
			continue
		}

		// Back-pressure, not a trick: a worker that knows its database is
		// unreachable declines to take messages it would only fail to process
		// and hand back. Under READY_MODE=cached this costs one cheap ping per
		// interval. Under db_each_call the check itself is the load -- which
		// is how a probe ends up scaling the cluster.
		if opt.cachedReady && !h.DBUp() {
			sleep(ctx, time.Second)
			continue
		}

		messages, err := queue.Receive(ctx, int32(opt.concurrency))
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("receive: %v", err)
			sleep(ctx, 2*time.Second)
			continue
		}
		if len(messages) == 0 {
			continue // long poll expired with an empty queue
		}

		var wg sync.WaitGroup
		for _, m := range messages {
			wg.Add(1)
			go func() {
				defer wg.Done()

				c, cancel := context.WithTimeout(ctx, 30*time.Second)
				defer cancel()

				if err := st.Work(c, opt.workRows, opt.workLatency); err != nil {
					// The message is deliberately not deleted. It becomes
					// visible again after the queue's visibility timeout, which
					// is what makes the death spiral in act 2 real rather than
					// staged: workers that cannot reach the database hand their
					// work straight back, depth climbs, KEDA scales harder, and
					// every new replica opens another pool against a database
					// that already has no connections left.
					log.Printf("process: %v", err)
					return
				}

				if err := queue.Delete(c, m.ReceiptHandle); err != nil {
					log.Printf("delete: %v", err)
					return
				}
				h.Touch()
			}()
		}
		wg.Wait()
	}
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
