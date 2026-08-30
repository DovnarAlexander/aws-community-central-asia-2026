// Package health is the subject of the talk: the three probe endpoints, and
// the several wrong ways to implement them.
//
// Each mode below is something people actually write, for reasons that sound
// good in review. That is what makes them worth demonstrating -- nobody ships
// an obviously broken probe, they ship a probe that asks a reasonable question
// at the wrong cost, or asks the right question about the wrong thing.
package health

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"sync/atomic"
	"time"

	"probes-demo/internal/store"
)

// Liveness modes.
const (
	// LivenessDB routes the probe through the same connection pool that serves
	// traffic. A busy service then fails its own liveness check and kubelet
	// restarts a process that was never unhealthy, only occupied.
	LivenessDB = "db"

	// LivenessLastMessage is the queue-consumer version of the same mistake:
	// "a worker that has not processed anything recently must be stuck". It is
	// indistinguishable from an empty queue, so the entire fleet restarts at
	// exactly the moment it has successfully finished all the work.
	LivenessLastMessage = "last_message"

	// LivenessLocal is the fix. Liveness answers one question -- is this
	// process alive -- and never leaves the process to answer it.
	LivenessLocal = "local"
)

// Readiness modes.
const (
	// ReadinessDBEachCall does a full table scan per probe call. The cost is
	// replicas x (1/period), so it is invisible at three replicas and ruinous
	// at sixteen: the probe becomes the dominant load on the database it is
	// checking.
	ReadinessDBEachCall = "db_each_call"

	// ReadinessCached is the fix. One background refresher per replica does one
	// cheap ping per interval; the probe reads a flag. O(1), whatever the
	// replica count.
	ReadinessCached = "cached"
)

type Options struct {
	Store *store.Store

	Liveness  string
	Readiness string

	// PingInterval and PingTimeout drive the background refresher used by
	// ReadinessCached.
	PingInterval time.Duration
	PingTimeout  time.Duration

	// MaxIdle is how long LivenessLastMessage tolerates silence. Only the
	// worker sets it.
	MaxIdle time.Duration

	// Acquire, when set, makes LivenessDB queue for a worker slot exactly as a
	// real request does. Without it the probe would skip the queue and the
	// service would never fail its own check, which is the entire mechanism of
	// act 1.
	Acquire func(context.Context) (func(), bool)
}

type Server struct {
	opt Options

	warm        atomic.Bool
	dbUp        atomic.Bool
	dbReason    atomic.Value // string
	lastMessage atomic.Int64 // UnixNano
}

func New(opt Options) *Server {
	s := &Server{opt: opt}
	s.dbReason.Store("starting")
	s.lastMessage.Store(time.Now().UnixNano())
	return s
}

// MarkWarm ends the startup period. Until it is called, every endpoint reports
// unhealthy -- which is what startupProbe exists to tolerate.
func (s *Server) MarkWarm() { s.warm.Store(true) }

func (s *Server) IsWarm() bool { return s.warm.Load() }

// Touch records that the worker processed something. Only meaningful under
// LivenessLastMessage.
func (s *Server) Touch() { s.lastMessage.Store(time.Now().UnixNano()) }

// DBUp reports the cached view of the database, refreshed by RunPingLoop. The
// worker also consults it before taking new work: declining to pull a message
// it cannot process is honest back-pressure, not a trick.
func (s *Server) DBUp() bool { return s.dbUp.Load() }

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/startupz", s.startupz)
	mux.HandleFunc("/healthz", s.healthz)
	mux.HandleFunc("/ready", s.ready)
	return mux
}

// RunPingLoop keeps the cached flag fresh with one cheap query per interval,
// regardless of how often kubelet asks. Started only for ReadinessCached.
func (s *Server) RunPingLoop(ctx context.Context) {
	check := func() {
		c, cancel := context.WithTimeout(ctx, s.opt.PingTimeout)
		defer cancel()

		if err := s.opt.Store.Ping(c); err != nil {
			s.dbUp.Store(false)
			s.dbReason.Store(err.Error())
			log.Printf("ping: db down: %v", err)
			return
		}
		if !s.dbUp.Load() {
			log.Printf("ping: db back up")
		}
		s.dbUp.Store(true)
		s.dbReason.Store("")
	}

	check()
	ticker := time.NewTicker(s.opt.PingInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			check()
		}
	}
}

func (s *Server) startupz(w http.ResponseWriter, r *http.Request) {
	if !s.warm.Load() {
		http.Error(w, "still warming up", http.StatusServiceUnavailable)
		return
	}
	fmt.Fprintln(w, "started")
}

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	if !s.warm.Load() {
		http.Error(w, "warming up", http.StatusServiceUnavailable)
		return
	}

	switch s.opt.Liveness {
	case LivenessDB:
		s.livenessViaDB(w, r)

	case LivenessLastMessage:
		idle := time.Since(time.Unix(0, s.lastMessage.Load()))
		if idle > s.opt.MaxIdle {
			// The log line the demo reads out loud. The worker is perfectly
			// healthy; it simply has nothing to do.
			log.Printf("healthz: FAILED, no message processed for %s (max %s)",
				idle.Round(time.Second), s.opt.MaxIdle)
			http.Error(w, "no recent work", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "alive")

	default: // LivenessLocal
		fmt.Fprintln(w, "alive")
	}
}

func (s *Server) livenessViaDB(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	if s.opt.Acquire != nil {
		release, ok := s.opt.Acquire(r.Context())
		if !ok {
			log.Printf("healthz: FAILED, queued %s waiting for a worker slot",
				time.Since(start).Round(time.Millisecond))
			http.Error(w, "no worker slot", http.StatusServiceUnavailable)
			return
		}
		defer release()
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	if err := s.opt.Store.Ping(ctx); err != nil {
		log.Printf("healthz: FAILED after %s: %v", time.Since(start).Round(time.Millisecond), err)
		http.Error(w, "db unreachable", http.StatusServiceUnavailable)
		return
	}

	if d := time.Since(start); d > 200*time.Millisecond {
		log.Printf("healthz: slow -- %s", d.Round(time.Millisecond))
	}
	fmt.Fprintln(w, "alive")
}

func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	if !s.warm.Load() {
		http.Error(w, "warming up", http.StatusServiceUnavailable)
		return
	}

	if s.opt.Readiness == ReadinessCached {
		if !s.dbUp.Load() {
			reason, _ := s.dbReason.Load().(string)
			http.Error(w, "db down: "+reason, http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "ready")
		return
	}

	// ReadinessDBEachCall: a full scan, on every call, on every replica.
	start := time.Now()
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	if err := s.opt.Store.ExpensiveCheck(ctx); err != nil {
		log.Printf("ready: FAILED after %s: %v", time.Since(start).Round(time.Millisecond), err)
		http.Error(w, "db check failed", http.StatusServiceUnavailable)
		return
	}

	log.Printf("ready: ok in %s", time.Since(start).Round(time.Millisecond))
	fmt.Fprintln(w, "ready")
}
