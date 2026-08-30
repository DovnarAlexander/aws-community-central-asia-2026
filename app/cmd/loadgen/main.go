// loadgen is a dependency-free load generator built for a stage.
//
// It prints one line a second -- rate, p95, and a split by failure kind -- which
// is the panel the audience actually reads: 5xx appearing and p95 climbing, in
// real time. On exit it writes a JSON summary so the driver can put a "before"
// run and an "after" run side by side.
//
// Two modes:
//
//	-mode http     hammer an HTTP endpoint (act 1: the service kills itself)
//	-mode enqueue  fill the SQS queue through the api (act 2: KEDA reacts to it)
//
// It runs inside the cluster rather than on the laptop. Venue Wi-Fi in the
// latency numbers would make the before/after table lie, and the whole point of
// that table is that it is measured rather than asserted.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"sync"
	"syscall"
	"time"
)

type bucket struct {
	mu        sync.Mutex
	latencies []time.Duration
	ok        int
	serverErr int
	connErr   int
}

func (b *bucket) add(d time.Duration, kind string) {
	b.mu.Lock()
	defer b.mu.Unlock()

	switch kind {
	case "ok":
		// Only served requests enter the quantiles. An instant 503 from a pod
		// that just restarted is a failure, not a fast response; mixed into p50
		// it would make the broken run look quicker than the fixed one.
		b.latencies = append(b.latencies, d)
		b.ok++
	case "5xx":
		b.serverErr++
	default:
		b.connErr++
	}
}

func (b *bucket) drain() (lat []time.Duration, ok, serverErr, connErr int) {
	b.mu.Lock()
	defer b.mu.Unlock()

	lat, ok, serverErr, connErr = b.latencies, b.ok, b.serverErr, b.connErr
	b.latencies, b.ok, b.serverErr, b.connErr = nil, 0, 0, 0
	return
}

type summary struct {
	Label     string  `json:"label"`
	Seconds   float64 `json:"seconds"`
	Requests  int     `json:"requests"`
	OK        int     `json:"ok"`
	ServerErr int     `json:"server_err"`
	ConnErr   int     `json:"conn_err"`
	OKPerSec  float64 `json:"ok_per_sec"`
	P50ms     int64   `json:"p50_ms"`
	P95ms     int64   `json:"p95_ms"`
	P99ms     int64   `json:"p99_ms"`
	MaxMs     int64   `json:"max_ms"`
}

func main() {
	mode := flag.String("mode", "http", "http | enqueue")
	target := flag.String("url", "http://svc.demo.svc.cluster.local/work", "target URL")
	rps := flag.Int("rps", 200, "requests per second")
	workers := flag.Int("workers", 200, "cap on requests in flight")
	timeout := flag.Duration("timeout", 5*time.Second, "per-request timeout")
	duration := flag.Duration("duration", 0, "stop after this long; 0 runs until signalled")
	batch := flag.Int("batch", 100, "messages per call, enqueue mode only")
	keepAlive := flag.Bool("keepalive", false, "reuse connections (each one sticks to a single pod)")
	label := flag.String("label", "run", "label the run appears under in the JSON summary")
	out := flag.String("summary", "", "write the JSON summary here as well as to stdout")
	flag.Parse()

	// Keep-alive is off by default, deliberately. kube-proxy picks a backend
	// once per TCP connection, so a reused connection is welded to whichever pod
	// it first reached: a scale-out would send no traffic at all to the new
	// pods, and a run started against a half-ready deployment would keep
	// hammering the same one. A fresh connection per request keeps the load
	// balancing honest and immediate -- which is the thing act 2 is measuring.
	client := &http.Client{
		Timeout: *timeout,
		Transport: &http.Transport{
			DisableKeepAlives:   !*keepAlive,
			MaxIdleConns:        *workers * 2,
			MaxIdleConnsPerHost: *workers * 2,
			MaxConnsPerHost:     *workers * 2,
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-stop; cancel() }()

	if *duration > 0 {
		go func() {
			select {
			case <-time.After(*duration):
				cancel()
			case <-ctx.Done():
			}
		}()
	}

	url := *target
	if *mode == "enqueue" {
		url = fmt.Sprintf("%s?n=%d", *target, *batch)
	}

	live := &bucket{}
	total := &bucket{}

	slots := make(chan struct{}, *workers)
	var wg sync.WaitGroup

	fire := func() {
		defer wg.Done()
		defer func() { <-slots }()

		start := time.Now()
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		resp, err := client.Do(req)
		d := time.Since(start)

		if err != nil {
			// Requests still in flight when the run stops are not failures.
			// Counting them would put a permanent floor of `workers` errors
			// under every summary, including the ones that should read zero.
			if ctx.Err() != nil {
				return
			}
			live.add(d, "conn")
			total.add(d, "conn")
			return
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()

		kind := "ok"
		if resp.StatusCode >= 500 {
			kind = "5xx"
		}
		live.add(d, kind)
		total.add(d, kind)
	}

	started := time.Now()

	// One line a second. On stage this panel is about a third of the screen, so
	// the line is trimmed to fit in one row at a font size that is legible from
	// the back -- longer, and every second takes two rows and the panel turns to
	// mush. No clock and no 2xx count: the running panel shows time by itself,
	// and successes are whatever is neither 5xx nor err.
	go func() {
		tick := time.NewTicker(time.Second)
		defer tick.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				lat, ok, srv, conn := live.drain()
				n := ok + srv + conn
				_, p95, _, _ := quantiles(lat)

				line := fmt.Sprintf("rps %3d p95 %5s 5xx %2d err %2d", n, ms(p95), srv, conn)
				switch {
				case srv > 0 || conn > 0:
					line = "\033[1;31m" + line + " <\033[0m"
				case p95 > 500*time.Millisecond:
					line = "\033[1;33m" + line + " ~\033[0m"
				}
				fmt.Println(line)
			}
		}
	}()

	ticker := time.NewTicker(time.Second / time.Duration(*rps))
	defer ticker.Stop()

loop:
	for {
		select {
		case <-ctx.Done():
			break loop
		case <-ticker.C:
			select {
			case slots <- struct{}{}:
				wg.Add(1)
				go fire()
			default:
				// Saturated: no free slot. Skipping the tick is more honest than
				// growing an unbounded queue on the client and then reporting
				// its latency as if it were the server's.
			}
		}
	}
	wg.Wait()

	lat, ok, serverErr, connErr := total.drain()
	p50, p95, p99, max := quantiles(lat)
	elapsed := time.Since(started).Seconds()

	s := summary{
		Label:     *label,
		Seconds:   elapsed,
		Requests:  ok + serverErr + connErr,
		OK:        ok,
		ServerErr: serverErr,
		ConnErr:   connErr,
		OKPerSec:  float64(ok) / elapsed,
		P50ms:     p50.Milliseconds(),
		P95ms:     p95.Milliseconds(),
		P99ms:     p99.Milliseconds(),
		MaxMs:     max.Milliseconds(),
	}

	b, _ := json.Marshal(s)
	if *out != "" {
		os.WriteFile(*out, b, 0o644)
	}

	// The summary goes to stdout on one line with a marker, because in-cluster
	// the driver collects it with `kubectl logs` rather than from a file.
	fmt.Printf("\nSUMMARY %s\n", b)
	fmt.Printf("-- %s: %d requests, 2xx %d, 5xx %d, err %d, p50 %s, p95 %s, p99 %s\n",
		s.Label, s.Requests, s.OK, s.ServerErr, s.ConnErr, ms(p50), ms(p95), ms(p99))
}

func quantiles(l []time.Duration) (p50, p95, p99, max time.Duration) {
	if len(l) == 0 {
		return
	}
	sort.Slice(l, func(i, j int) bool { return l[i] < l[j] })

	at := func(q float64) time.Duration {
		i := int(q * float64(len(l)))
		if i >= len(l) {
			i = len(l) - 1
		}
		return l[i]
	}
	return at(0.50), at(0.95), at(0.99), l[len(l)-1]
}

func ms(d time.Duration) string {
	if d == 0 {
		return "-"
	}
	return fmt.Sprintf("%dms", d.Milliseconds())
}
