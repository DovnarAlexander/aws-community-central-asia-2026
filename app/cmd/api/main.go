// api is the HTTP half of the demo: it serves work, it enqueues work, and it
// answers the three probes that the talk is about.
//
// Environment:
//
//	PORT                    listen port                              (8080)
//	DSN                     Postgres DSN                             (required)
//	QUEUE_URL               SQS work queue; /enqueue needs it        (optional)
//	WARMUP_SECONDS          how long the service pretends to warm up (30)
//	WORK_LATENCY_MS         how long /work holds a pooled connection (50)
//	WORK_ROWS               rows /work aggregates per request        (3000)
//	POOL_MAX                pool size per replica -- and the wall    (10)
//	HEALTHZ_MODE            db | local                               (db)
//	READY_MODE              db_each_call | cached                    (db_each_call)
//	READY_PING_INTERVAL_MS  background refresher period              (2000)
//	READY_PING_TIMEOUT_MS   background refresher timeout             (1000)
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
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
		queueURL    = appenv.String("QUEUE_URL", "")
		warmup      = appenv.Seconds("WARMUP_SECONDS", 30)
		workLatency = appenv.Millis("WORK_LATENCY_MS", 50)
		workRows    = appenv.Int("WORK_ROWS", 3000)
		poolMax     = appenv.Int("POOL_MAX", 10)
		healthzMode = appenv.String("HEALTHZ_MODE", health.LivenessDB)
		readyMode   = appenv.String("READY_MODE", health.ReadinessDBEachCall)
	)

	log.Printf("boot: warmup=%s work_latency=%s work_rows=%d pool_max=%d healthz=%s ready=%s",
		warmup, workLatency, workRows, poolMax, healthzMode, readyMode)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	st, err := store.Open(ctx, store.Config{DSN: dsn, PoolMax: int32(poolMax)})
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	defer st.Close()

	// sem stands in for a worker pool: /work holds a slot for the whole round
	// trip to the database, so a service that is merely busy grows a queue
	// here. Under HEALTHZ_MODE=db the liveness probe joins the same queue, and
	// that is how a healthy service comes to fail its own health check.
	sem := make(chan struct{}, poolMax)
	acquire := func(c context.Context) (func(), bool) {
		select {
		case sem <- struct{}{}:
			return func() { <-sem }, true
		case <-c.Done():
			return nil, false
		}
	}

	h := health.New(health.Options{
		Store:        st,
		Liveness:     healthzMode,
		Readiness:    readyMode,
		PingInterval: appenv.Millis("READY_PING_INTERVAL_MS", 2000),
		PingTimeout:  appenv.Millis("READY_PING_TIMEOUT_MS", 1000),
		Acquire:      acquire,
	})

	// A slow start, the way a JVM service or a big cache warm actually behaves:
	// the process is up and listening, and serves nothing.
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
		log.Printf("warmup finished after %s -- serving now", time.Since(start).Round(time.Millisecond))
	}()

	if readyMode == health.ReadinessCached {
		go h.RunPingLoop(ctx)
	}

	var queue *work.Queue
	if queueURL != "" {
		if queue, err = work.Open(ctx, queueURL); err != nil {
			log.Fatalf("queue: %v", err)
		}
	}

	mux := http.NewServeMux()
	mux.Handle("/startupz", h.Handler())
	mux.Handle("/healthz", h.Handler())
	mux.Handle("/ready", h.Handler())

	mux.HandleFunc("/work", func(w http.ResponseWriter, r *http.Request) {
		if !h.IsWarm() {
			http.Error(w, "warming up", http.StatusServiceUnavailable)
			return
		}
		start := time.Now()

		release, ok := acquire(r.Context())
		if !ok {
			http.Error(w, "queue timeout", http.StatusServiceUnavailable)
			return
		}
		defer release()

		c, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()

		if err := st.Work(c, workRows, workLatency); err != nil {
			log.Printf("work: db error after %s: %v", time.Since(start).Round(time.Millisecond), err)
			http.Error(w, "db error", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintf(w, "ok %s\n", time.Since(start).Round(time.Millisecond))
	})

	// /enqueue is how the demo creates queue depth for KEDA to react to. It
	// does not touch the database, so the load generator can fill the queue
	// even while the database is the thing that is on fire.
	mux.HandleFunc("/enqueue", func(w http.ResponseWriter, r *http.Request) {
		if queue == nil {
			http.Error(w, "QUEUE_URL is not set", http.StatusNotImplemented)
			return
		}

		n := 1
		if v := r.URL.Query().Get("n"); v != "" {
			parsed, err := strconv.Atoi(v)
			if err != nil || parsed < 1 || parsed > 10000 {
				http.Error(w, "n must be between 1 and 10000", http.StatusBadRequest)
				return
			}
			n = parsed
		}

		c, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()

		sent, err := queue.Enqueue(c, n)
		if err != nil {
			log.Printf("enqueue: sent %d of %d: %v", sent, n, err)
			http.Error(w, fmt.Sprintf("enqueued %d of %d: %v", sent, n, err), http.StatusBadGateway)
			return
		}
		fmt.Fprintf(w, "enqueued %d\n", sent)
	})

	srv := &http.Server{Addr: ":" + port, Handler: mux}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()
	log.Printf("listening on :%s", port)

	<-ctx.Done()
	log.Printf("shutting down")

	shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdown)
	os.Exit(0)
}
