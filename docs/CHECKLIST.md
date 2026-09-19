# The probe checklist

What the talk ends on, in the form you can use on Monday. Everything here is
demonstrated live in this repository — the manifests that break are in
`k8s/incident1/` and `k8s/incident2/`, and the ones that do not are next to them.

## The three probes answer three different questions

| | Question | What a failure does | How it should be tuned |
| --- | --- | --- | --- |
| `startupProbe` | has it finished booting? | holds the other two off | generous: `failureThreshold × periodSeconds` covers the slowest start you can imagine |
| `livenessProbe` | is the process alive? | **restarts the container** | slack: long period, long timeout, several misses |
| `readinessProbe` | can this pod serve right now? | removes it from the EndpointSlice | tight: it is allowed to be twitchy |

If you cannot say what a restart would fix, do not restart. Liveness is the
last resort, not the first responder.

## Liveness

- [ ] It does not touch the database, a cache, a queue, or any other process.
      A dependency in a liveness probe means one slow dependency restarts every
      replica you have.
- [ ] It does not share a connection pool or a worker slot with real traffic.
      A probe that queues behind the work it is checking measures load, not life.
- [ ] `timeoutSeconds` is seconds, not one. One second is a latency alarm wired
      to a kill switch.
- [ ] The arithmetic is written down: `initialDelaySeconds + failureThreshold ×
      periodSeconds` is how much patience the probe has. Compare it to the
      slowest start you have ever seen, not the usual one.

## Startup

- [ ] Anything that takes more than a few seconds to boot has a `startupProbe`,
      not a larger `initialDelaySeconds`. `initialDelaySeconds` is the only probe
      number with no feedback: it counts, it does not look. It is a bet that
      tomorrow starts no slower than today, and a cold cache, a noisier
      neighbour, a bigger dataset or one more step at boot all win that bet
      without touching the manifest.
- [ ] Its budget is explicit: `failureThreshold × periodSeconds`. Two minutes is
      not extravagant.

## Readiness

- [ ] It answers "can **this** pod serve", never "is the shared thing healthy".
      The blast radius of a readiness probe is every replica that shares whatever
      it asks about — and when they all fail at once the EndpointSlice is empty,
      which is a Service with nowhere to send anything.
- [ ] If it must know about a dependency, it reads a flag that something else
      refreshes on its own schedule. Cost O(1) in replicas instead of O(n), and
      a stale flag still fails honestly — one pod at a time, as each flag expires.
- [ ] You have multiplied its cost by your maximum replica count and then by
      your autoscaler's ceiling. A check that is free at three replicas is a
      denial of service at twenty-four.

## The things around the probe that decide how far it goes

- [ ] `replicas × POOL_MAX` stays under the database's `max_connections`, with
      room for everything else that connects.
- [ ] Every autoscaler has a ceiling. A `maxReplicaCount` you never set is the
      difference between an incident and an invoice — the queue autoscaler sees
      a deep queue, not the reason it is deep, and a queue that grows because
      the workers are stuck looks exactly like one that grows because there is
      work.
- [ ] A worker that cannot reach its dependency does not acknowledge its
      message. The message comes back, the queue gets deeper, and the autoscaler
      reads that as demand. Check that your retry path cannot feed your scaler.
- [ ] Node autoscaling turns all of the above into money. Nothing in this
      failure mode is broken, which is why nothing alerts on it.

## The one sentence

Probes are the only code that can kill a healthy service — and with an
autoscaler underneath, bill you for it.
