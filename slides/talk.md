---
theme: naviteq-slidev
title: The probe that killed itself
titleTemplate: '%s — Naviteq'
info: |
  AWS Community Day Central Asia 2026.
  The talk is the terminal; this deck is the fallback and the handout.
author: Alexander Dovnar
keywords: kubernetes,probes,liveness,readiness,startup,eks,karpenter,keda,rds,sre
exportFilename: probe-that-killed-itself
colorSchema: light
# The theme's own families, served from slides/fonts rather than Google Fonts.
# The @font-face rules are in style.css, and `provider: none` is what stops
# Slidev adding the remote stylesheet next to them.
fonts:
  sans: DM Sans
  mono: Fira Code
  provider: none
# A deck that declares `addons:` replaces the theme's list rather than adding
# to it, so anything the deck uses has to be named here even when the theme
# would have brought it along. Without the name <WindowMockup> falls through to
# unplugin-icons, which reads it as the icon `wi/ndow-mockup` and fails with a
# message that says nothing about addons.
addons:
  - slidev-addon-window-mockup
drawings:
  persist: false
class: text-left
transition: fade
mdc: true
layout: cover
variant: 2
---

# The probe that killed itself

## A health check, two autoscalers, and an EC2 bill

Alexander Dovnar · Naviteq · AWS Community Day Central Asia 2026

<!--
"Good morning. This talk is about the six lines in your manifest that almost
everyone copies from the service next door — and about the two of those lines
that can take a healthy service down and put the outage on your AWS bill.

Two incidents, both reproduced live on a real EKS cluster. Nothing here is
staged: the pods die because the numbers say they should."

Operational note: this deck is not the talk. The talk is the terminal. Use the
deck when the cluster cannot be used — the recordings on the incident slides
are full runs of the same show, cut per segment, so a failure at step 2.2 costs
you 2.2 and nothing else.
-->

---
layout: default
---

# Something is asking your container questions

<p class="nq-lede">Not a load balancer. Not a human. <strong>kubelet</strong>, every few seconds, forever, using numbers out of your manifest.</p>

<div class="nq-fig my-1">
  <img src="/diagrams/probes.svg" alt="kubelet asks three questions; each kind of wrong answer costs something different" />
</div>

<p class="nq-statement">Of everything that can take a container down — a crash, an OOM, an eviction, a rollout — a probe is the only one that does it <strong>while the process is working perfectly well</strong>.</p>

<!--
"Before anything fails, one picture. Something is asking your container
questions, and it is not a load balancer and not a human. It is kubelet, the
agent on every node, asking every few seconds, forever, using numbers that came
out of your manifest.

Three questions, and they are not interchangeable. Startup asks whether the
thing has finished booting, and while it runs the other two are not consulted
at all. Liveness asks whether the process is alive, and a wrong answer restarts
the container — work in flight dies with it. Readiness asks whether it can
serve right now, and a wrong answer only takes the pod out of the Service; it
keeps running and comes back by itself.

Hold on to the bottom row, because everything today comes from it. Of all the
things that can take a container down, a probe is the only one that does it
while the process is working perfectly well."
-->

---
layout: default
---

# What is actually running

<p class="nq-lede">One queue, two autoscalers on two different signals, one database with <code>max_connections</code> pinned low.</p>

<div class="nq-fig my-1">
  <img src="/diagrams/architecture.svg" alt="EKS with api, SQS, workers, KEDA and Karpenter, all against one RDS instance" />
</div>

<p class="nq-note">Three deliberate constraints: <strong>no NAT gateway</strong> (the quiet $32 a month), <strong>spot and small instances</strong> so scaling is visible as node <em>count</em>, and a <strong>non-burstable</strong> RDS class so the failure reproduces on the day instead of running out of CPU credits halfway through.</p>

<!--
"Thirty seconds on the environment, because two details in it do all the work
later.

The api takes requests and puts jobs on an SQS queue. Workers consume the
queue. KEDA — the autoscaler that scales on external metrics — watches the
queue depth and adds workers. Karpenter watches for pods that cannot be
scheduled and buys EC2 nodes to put them on. Two autoscalers, two different
signals, neither aware of the other.

And everything, api and workers alike, talks to one RDS PostgreSQL instance
whose max_connections is pinned at fifty-seven. That number is the wall we hit
in the second incident.

The constraints at the bottom are there so the demo is honest: no NAT gateway,
small spot instances so scaling shows up as a node count you can read across
the room, and a non-burstable database that cannot quietly save us with CPU
credits."
-->

---
layout: section
variant: 2
---

# Incident 1

## The probe that kills a healthy pod

<!--
"First incident. A probe that kills a pod that has nothing wrong with it."
-->

---
layout: default
---

# It is arithmetic, not a bug

<p class="nq-lede">The service warms up for <strong>30 seconds</strong>. Every number in this probe is defensible on its own.</p>

<div class="grid grid-cols-[1.08fr_1fr] gap-7 mt-2">

<div>

```yaml {all|3|4|6|5}
livenessProbe:
  httpGet: { path: /healthz, port: 8080 }
  initialDelaySeconds: 5   # pause before the first question
  periodSeconds: 5         # then ask again this often
  timeoutSeconds: 1        # an answer slower than this is a miss
  failureThreshold: 3      # this many misses and the pod dies
```

<div v-click="7" class="nq-note mt-3">

A <code>startupProbe</code> gives boot its own budget instead, and while it runs the other two are not consulted at all. Raising <code>initialDelaySeconds</code> is the fix everyone reaches for, and it holds until the day the start gets slower.

</div>

</div>

<div>

<div v-click="5">

<p class="nq-figure-number">5 + 3 × 5 = 20 s</p>

<p class="nq-body">Patience runs out at twenty. The service is ready at thirty. <strong>The pod dies every single time</strong>, and nothing in the manifest is wrong.</p>

</div>

<div v-click="6" class="mt-5">

<p class="nq-body"><code>timeoutSeconds: 1</code> is the other half. An answer at 1.1 seconds counts exactly the same as no answer at all — and a service answers slowly precisely when it is busy.</p>

</div>

</div>

</div>

<!--
"Here is the probe. Four numbers, all copied, none of them absurd.

[click] initialDelaySeconds: five. Wait five seconds before asking anything.

[click] periodSeconds: five. Then ask again every five seconds.

[click] failureThreshold: three. Three misses in a row and the pod dies.

[click] timeoutSeconds: one. An answer has one second to arrive.

[click] So add them up. Five, plus three misses five seconds apart, is twenty
seconds of patience. The service needs thirty to warm up. The pod is killed on
the twentieth second, every single time, and there is no bug anywhere — not in
the code, not in the manifest. It is arithmetic.

[click] And timeoutSeconds is the half that bites later. An answer at one point
one seconds is scored the same as no answer at all, and a service gets slow
exactly when it is busy.

[click] The fix everyone reaches for is a bigger initialDelaySeconds, and it
holds right up until the day boot gets slower — a cold cache, a noisier
neighbour, one more step at startup. A startupProbe gives boot its own budget
instead, and silences the other two while it runs."
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.1" fit="both" />
  </div>
</div>

<!--
1.1 · Timur ships a service

"This is the recording of that run, cut per step. A slow start killed by
liveness; a startupProbe fixes it; and then the same probe kills three healthy
replicas under load, because it measures latency and calls the answer death."

One slide per step now, not one for the incident: each segment starts itself
when its slide comes up and stops at the end of its own step, so the clicker
still only ever means one thing. Skipping a step is skipping a slide.

Recorded with `GEOM=native task deck:record -- full`, cut by `task deck:split`.
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.2" fit="both" />
  </div>
</div>

<!--
1.2 · The number, and the documentation
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.3" fit="both" />
  </div>
</div>

<!--
1.3 · Production config, and real traffic

The RESTARTS column climbing while the service is healthy is the whole
incident. If incident 1 has to lose a segment to the clock, keep this one.
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.4" fit="both" />
  </div>
</div>

<!--
1.4 · End of incident 1 -- before and after
-->

---
layout: default
---

# The question the probe was asking

<p class="nq-lede">The same failed check, routed through two different probes, costs two completely different things.</p>

<div class="nq-fig my-1">
  <img src="/diagrams/verdicts.svg" alt="liveness kills the container; readiness only removes the pod from the Service" />
</div>

<p class="nq-statement">Which makes <code>timeoutSeconds: 1</code> on a liveness probe <strong>a latency alarm wired to a kill switch</strong>. The load never changed — what took the service down was the health check.</p>

<!--
"So why did a slow answer cost us the container?

Because of which probe was asking. Same pod, working fine, same failed check.

On the left, liveness says no: kubelet kills the container. Everything in
flight dies with it, the connection pool is rebuilt, the cache is cold again.
That action is irreversible, and liveness has exactly one job — notice a
process that will never recover on its own.

On the right, readiness says no: the pod leaves the EndpointSlice and stops
receiving traffic. That is all. It keeps running, and when it answers again it
comes back by itself. That action is reversible, which is why slow is a
readiness question and never a liveness one.

Which makes a one-second timeout on a liveness probe what it actually is: a
latency alarm wired to a kill switch. The load never changed. What took the
service down was the health check."
-->

---
layout: section
variant: 3
---

# Incident 2

## The probe that buys EC2 instances

<!--
"Second incident. Same idea, but now there are autoscalers underneath, and the
blast radius stops being the cluster and starts being the invoice."
-->

---
layout: default
---

# A readiness probe that passes review

<p class="nq-lede">"Readiness should verify we can actually read our data." Nobody argues with that sentence in a pull request.</p>

<div class="grid grid-cols-[0.92fr_1.08fr] gap-8 mt-2">

<div>

```yaml {all|3}
readinessProbe:
  httpGet: { path: /ready, port: 8080 }
  periodSeconds: 2
```

```go {all|2}
// READY_MODE=db_each_call
rows, err := db.Query(ctx, aggregate)
```

<p class="nq-note mt-3" v-click="3">At three replicas the database does not notice: twelve connections out of fifty-seven, one and a half scans a second. It passes review, it passes staging, and it passes the first week in production.</p>

</div>

<div>

<p class="nq-figure-number" v-click="4">scans/sec = replicas ÷ period</p>

<div v-click="5" class="mt-2">

| replicas | scans/sec | connections |
| --- | --- | --- |
| 3 | 1.5 | 12 |
| 12 | 6 | 48 |
| **24** | **12** | **96** |

</div>

<p class="nq-note mt-3" v-click="6"><code>max_connections</code> is 57. The probe that passed review is now a denial of service against the database it was checking.</p>

</div>

</div>

<!--
"Second probe. This one is readiness, and it is the one nobody objects to.

[click] periodSeconds: two. Every replica asks every two seconds.

[click] And the check itself goes to the database — a real query, because
readiness should verify we can actually read our data. That sentence is why
this ships.

[click] At three replicas nothing happens. Twelve connections out of
fifty-seven, one and a half scans a second. It passes review, it passes
staging, and it passes the first week in production.

[click] But the cost of that check is not a constant. It is replicas divided
by the period — it scales with the fleet, and the fleet is exactly what an
autoscaler moves.

[click] Three replicas, twelve connections. Twelve replicas, forty-eight.
Twenty-four replicas, ninety-six.

[click] max_connections is fifty-seven. Somewhere between the second row and
the third, the health check becomes a denial of service against the database it
was written to check."
-->

---
layout: default
---

# The loop

<div class="nq-fig my-1">
  <img src="/diagrams/loop.svg" alt="probe, NotReady, queue depth, KEDA, Karpenter, back to the probe" />
</div>

<p class="nq-statement">Every turn adds connections to the database that is already the bottleneck, which makes the next turn worse. One step in that circle is <strong>billed by the hour</strong>.</p>

<!--
"And this is the picture the whole talk is built on.

The probe asks the database. The database is at its connection limit, so the
probe fails, and replicas go NotReady. A NotReady worker stops consuming SQS.
The queue depth grows. KEDA reads queue depth and adds workers. The new workers
have nowhere to run, so Karpenter buys nodes for them. Every new worker opens
connections to the same database — and asks it the same question every two
seconds.

Every turn of that circle makes the next turn worse. And the thing to say out
loud: nothing in this loop is broken. Every component is doing exactly what it
was asked to do. The only part of it with a price tag is the bottom — where a
misconfigured health check turns into EC2 instances."

Give this slide its thirty seconds even when running late.
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.1" fit="both" />
  </div>
</div>

<!--
2.1 · The review that let it through

"Queue fills. KEDA scales workers from zero. Karpenter buys machines. Then the
wall at fifty-seven connections — and throughput at zero while the node counter
keeps climbing."

This segment is the review itself: the probe that everyone signed off on.
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.2" fit="both" />
  </div>
</div>

<!--
2.2 · Black Friday: the queue fills
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.3" fit="both" />
  </div>
</div>

<!--
2.3 · The cascade, and the autoscalers help

The number to point at is the node count, not the queue. A queue going up under
load is expected; a node count going up while nothing is being processed is the
incident.
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.4" fit="both" />
  </div>
</div>

<!--
2.4 · Madina unhooks the probe
-->

---
layout: default
---

# The fix is three things, and only one is a probe

<div class="grid grid-cols-3 gap-6 mt-4 items-stretch">

<div v-click="1" class="h-full">

<NqCard class="h-full" accent="primary">

**1 · unhook the probe**

A goroutine refreshes a flag on its own schedule. The probe reads the flag.

**O(1) in replicas**, not O(n) — and a stale flag still takes the pod out, one at a time as each expires.

</NqCard>

</div>

<div v-click="2" class="h-full">

<NqCard class="h-full" accent="primary">

**2 · budget the pool**

`replicas × POOL_MAX` has to stay under `max_connections`, with room for everything else that connects.

</NqCard>

</div>

<div v-click="3" class="h-full">

<NqCard class="h-full" accent="accent">

**3 · cap the autoscaler**

`maxReplicaCount: 12`, not 24.

An autoscaler without a ceiling is a way to turn an incident into an invoice.

</NqCard>

</div>

</div>

<p class="nq-statement mt-8" v-click="4">Twelve workers, twelve Ready, against twenty-four of which next to none served. <strong>One probe changed. Nothing else did.</strong></p>

<!--
"Three fixes, and only the first one is about the probe.

[click] One: unhook the probe from the dependency. A goroutine refreshes a flag
on its own schedule, and the probe reads the flag. That is order one in
replicas instead of order n — and it still works as a health check, because a
flag that goes stale still takes the pod out, one pod at a time as each one
expires.

[click] Two: budget the pool. Replicas times the per-pod pool maximum has to
stay under max_connections, with room left for everything else that connects to
that database — migrations, the shell you opened, your monitoring.

[click] Three: cap the autoscaler. Twelve, not twenty-four. An autoscaler with
no ceiling is a mechanism for converting an incident into an invoice.

[click] And the result: twelve workers, twelve of them Ready, against
twenty-four of which almost none served a request. One probe changed. Nothing
else did."
-->

---
layout: default
---

# The checklist · liveness and startup

<div class="grid grid-cols-2 gap-10 mt-4">

<div>

<p class="nq-subhead">Liveness</p>

<ul class="nq-body mt-3">
<li>Does not touch the database, a cache, a queue, or any other process</li>
<li>Does not share a pool or a worker slot with real traffic</li>
<li><code>timeoutSeconds</code> in seconds, not one</li>
<li>The arithmetic is written down: <code>initialDelay + failureThreshold × period</code> against the <strong>slowest</strong> start you have ever seen, not the usual one</li>
</ul>

</div>

<div>

<p class="nq-subhead">Startup</p>

<ul class="nq-body mt-3">
<li>Anything slower than a few seconds gets a <code>startupProbe</code>, not a bigger <code>initialDelaySeconds</code></li>
<li>Its budget is explicit: <code>failureThreshold × periodSeconds</code>. Two minutes is not extravagant</li>
</ul>

</div>

</div>

<p class="nq-statement mt-8"><NqHighlight type="solid" color="primary">If you cannot say what a restart would fix, do not restart.</NqHighlight></p>

<!--
"The takeaway half. This is the page worth photographing, and it is in the
repository as docs/CHECKLIST.md so nobody has to.

Liveness first. It does not touch the database, a cache, a queue or any other
process — because it is the one probe whose answer is a kill. It does not share
a connection pool or a worker slot with real traffic, or it will fail exactly
when traffic is heaviest. Its timeout is measured in seconds, not one. And the
arithmetic is written down somewhere, checked against the slowest start you
have ever seen rather than the usual one.

Startup: anything that takes more than a few seconds to boot gets a
startupProbe rather than a bigger initial delay, and its budget is stated
explicitly. Two minutes of boot budget is not extravagant.

And the sentence to leave with: if you cannot say what a restart would fix, do
not restart."
-->

---
layout: default
---

# The checklist · readiness, and the blast radius

<div class="grid grid-cols-2 gap-10 mt-4">

<div>

<p class="nq-subhead">Readiness</p>

<ul class="nq-body mt-3">
<li>Answers "can <strong>this</strong> pod serve", never "is the shared thing healthy"</li>
<li>If it must know about a dependency, it reads a flag something else refreshes</li>
<li>Multiply its cost by your maximum replica count, then by the autoscaler's ceiling</li>
</ul>

</div>

<div>

<p class="nq-subhead">Around the probe</p>

<ul class="nq-body mt-3">
<li><code>replicas × POOL_MAX</code> under <code>max_connections</code></li>
<li>Every autoscaler has a ceiling</li>
<li>A worker that cannot reach its dependency does not ack its message — check that your retry path cannot feed your scaler</li>
<li>Node autoscaling turns all of it into money</li>
</ul>

</div>

</div>

<p class="nq-statement mt-6">Probes are the only code that can kill a healthy service — and with an autoscaler underneath, bill you for it.</p>

<!--
"Readiness. It answers one question: can this pod serve right now. Never 'is
the shared thing healthy', because every replica asking that turns one sick
dependency into a fleet-wide outage. If it genuinely has to know about a
dependency, it reads a flag that something else refreshes. And whatever it
costs, multiply that by your maximum replica count and then by the autoscaler's
ceiling — that is the real number.

Around the probe: replicas times pool maximum stays under max_connections.
Every autoscaler has a ceiling. Watch the retry path — a worker that cannot
reach its dependency does not acknowledge its message, the message goes back on
the queue, and the queue is what your scaler is reading. And node autoscaling
turns all of it into money.

Which is where we started. Probes are the only code you write that can kill a
healthy service — and with an autoscaler underneath, bill you for it."
-->

---
layout: end
variant: 2
---

# Take it with you

## Everything you just saw, including the manifests with the numbers

<div class="mt-8 flex items-center gap-10">

<div class="nq-qr shrink-0">
  <img src="/qr.svg" alt="QR code for github.com/DovnarAlexander/aws-community-central-asia-2026" />
</div>

<div class="text-left">

<p class="nq-statement leading-snug"><strong>github.com/DovnarAlexander/</strong><br><strong>aws-community-central-asia-2026</strong></p>

<p class="nq-body mt-3">The checklist is <code>docs/CHECKLIST.md</code>. The probes are in <code>k8s/</code>, numbers included. The failures are reproducible: <code>task bootstrap</code>, then <code>./demo</code>.</p>

</div>

</div>

<!--
"Everything is in the repository — the checklist, the manifests with these
numbers in them, and the demo itself. Point a camera at the code and you can
reproduce both incidents on your own cluster in about twenty minutes.

Thank you. Questions?"

The room photographs this slide. Leave it up while taking questions.
-->
