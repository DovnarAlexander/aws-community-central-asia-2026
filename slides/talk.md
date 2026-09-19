---
theme: naviteq-slidev
title: The probe that killed itself
titleTemplate: '%s — Naviteq'
info: |
  AWS User Group Central Asia 2026.
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

Alexander Dovnar · Naviteq · AWS User Group Central Asia 2026

<!--
WHERE WE ARE
The promise. Nothing moves on this slide.

SAY
"Good morning. This talk is about six lines in your manifest that almost everyone copies from the service next door, and about the two of them that can take a healthy service down and put the outage on your AWS bill.
Two incidents, both reproduced live on a real EKS cluster. The pods die because the numbers say they should."

IF THE CLUSTER IS DOWN
Say so now rather than later and present from the recordings. They are full runs of the same show, cut per step, so losing one step costs that step and nothing else.
-->

---
layout: default
---

# Alexander Dovnar

<div class="grid grid-cols-[auto_1fr] gap-8 mt-4 items-start">

<img src="/brand/portrait.png" class="w-40 h-40 rounded-full object-cover" alt="Alexander Dovnar" />

<div>

<p class="nq-lede">CTO at <strong>Naviteq</strong>. Co-host of <strong>DevOps Kitchen Talks</strong>, 70+ episodes and 300k+ views.</p>

<ul class="nq-body mt-3">
<li><strong>AWS Community Builder</strong>, Containers — since 2023</li>
<li><strong>Terragrunt Ambassador</strong> — since 2025</li>
<li>Kubestronaut · CKA · CKS · AWS Solutions Architect Professional · AWS Security Specialty</li>
<li>Co-author of <em>Cracking the Kubernetes Interview</em>, Packt</li>
</ul>

<p class="nq-body mt-3 text-sm">alex-dovnar.in · youtube.com/c/DevOpsKitchenTalks · linkedin.com/in/dovnaralex · github.com/DovnarAlexander</p>

</div>
</div>

<!--
WHERE WE ARE
Thirty seconds on who is talking, then straight to the terminal.

THE CLICKS
1. photograph and the mark: "I run engineering at Naviteq."
2. the role: "And I co-host DevOps Kitchen Talks, seventy-odd episodes of two people arguing about infrastructure."
3. the credentials: read one, not five. The containers track and the Terragrunt ambassadorship are the two that say why this talk.
4. the links: "These are all on the QR at the end, so nobody needs to photograph this slide."

THEN
"Both incidents you are about to see happened to somebody I know, and one of them happened to me."
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="0" fit="both" />
  </div>
</div>

<!--
WHERE WE ARE
The cast, introduced by the stage itself. Runs {len} and starts on its own; the bar along the bottom is how much is left.

WHILE IT PLAYS
- Timur ships the service.
- Ruslan tunes the numbers.
- Madina asks what the probe is actually for.
- Karpenter answers Pending pods by buying machines, and has a credit card.

DO NOT SKIP IT
A later step called "Madina unhooks the probe" does not land on a room that has never met her. Talk over it instead.
-->

---
layout: default
---

# Something is asking your container questions

<p class="nq-lede">Not a load balancer. Not a human. <strong>kubelet</strong>, every few seconds, forever, using numbers out of your manifest.</p>

<div class="nq-fig my-1">
  <img src="/diagrams/probes.svg" alt="kubelet asks three questions; each kind of wrong answer costs something different" />
</div>

<p class="nq-statement">Of everything that can take a container down (a crash, an OOM, an eviction, a rollout), a probe is the only one that does it <strong>while the process is working perfectly well</strong>.</p>

<!--
WHERE WE ARE
The one piece of theory that has to come before the first failure. The diagram draws itself branch by branch.

THE CLICKS
1. the opening line: "Something is asking your container questions, and it is not a load balancer and not a human. It is kubelet, the agent on every node, asking every few seconds, forever, using numbers that came out of your manifest."
2. kubelet appears: point at it. The only actor in the talk that never changes its behaviour.
3. startup: "Has it finished booting? While this one runs, the other two are not consulted at all."
4. liveness: "Is the process alive? A wrong answer restarts the container, and work in flight dies with it."
5. readiness: "Can it serve right now? A wrong answer only takes the pod out of the Service. It keeps running and comes back by itself."
6. the closing line: land this one slowly.

THE LINE THAT MATTERS
Of everything that can take a container down, a probe is the only one that does it while the process is working perfectly well.
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
WHERE WE ARE
The cluster, before anything breaks. Follow a request through it.

THE CLICKS
1. the opening line: one queue, two autoscalers on two different signals, one database with max_connections pinned low.
2. the VPC and the cluster: mention the no-NAT quirk only if somebody asks about cost.
3. the api: "A request lands here."
4. the queue: "It goes on SQS."
5. the worker: "A worker picks it up."
6. the database, and the long line back from the api: "Both of them reach the same Postgres. It is capped at sixty and RDS keeps six, so the application gets fifty-four. Remember that number."
7. KEDA and Karpenter: "These two are watching. KEDA reads queue depth, Karpenter buys machines for pods that will not fit. Neither knows why the queue is deep."
8. the constraints line: say it once: the cluster is deliberately small so the failure is visible.
-->

---
layout: section
variant: 2
---

# Incident 1

## The probe that kills a healthy pod

<!--
WHERE WE ARE
The first of two.

SAY
"A service that takes ten seconds to start, and a probe copied out of an article. Nobody writes a bug."
-->

---
layout: default
---

# It is arithmetic, not a bug

<p class="nq-lede">The service warms up for <strong>10 seconds</strong>. Every number in this probe is defensible on its own.</p>

<div class="grid grid-cols-[1.08fr_1fr] gap-7 mt-2">

<div>

```yaml {all|3|4|6|5}
livenessProbe:
  httpGet: { path: /healthz, port: 8080 }
  initialDelaySeconds: 2   # pause before the first question
  periodSeconds: 1         # then ask again this often
  timeoutSeconds: 1        # an answer slower than this is a miss
  failureThreshold: 3      # this many misses and the pod dies
```

<div v-click="7" class="nq-note mt-3">

A <code>startupProbe</code> gives boot its own budget instead, and while it runs the other two are not consulted at all. Raising <code>initialDelaySeconds</code> is the fix everyone reaches for, and it holds until the day the start gets slower.

</div>

</div>

<div>

<div v-click="5">

<p class="nq-figure-number">2 + 3 × 1 = 5 s</p>

<p class="nq-body">Patience runs out at five. The service is ready at ten. <strong>The pod dies every single time</strong>, and nothing in the manifest is wrong.</p>

</div>

<div v-click="6" class="mt-5">

<p class="nq-body"><code>timeoutSeconds: 1</code> is the other half. An answer at 1.1 seconds counts exactly the same as no answer at all, and a service answers slowly precisely when it is busy.</p>

</div>

</div>

</div>

<!--
WHERE WE ARE
The mechanism, before the cluster demonstrates it. The manifest arrives a line at a time.

THE CLICKS
1. the opening line
2. "ten seconds" turns bold: the number the rest of the slide is measured against
3. the panel
4. livenessProbe: "This is the whole probe."
5. the endpoint: "It asks /healthz over HTTP."
6. initialDelaySeconds: 2: "Wait two seconds before asking anything."
7. periodSeconds: 1: "Then ask again every second."
8. timeoutSeconds: 1: "An answer has one second to arrive."
9. failureThreshold: 3: "Three misses in a row and the pod dies."
10. the sum flies in: pause here
11. the sum turns bold: "Two, plus three misses a second apart, is five seconds of patience. The service needs ten. The pod is killed on the fifth second, every single time, and there is no bug anywhere."
12. the last line

THE HALF THAT BITES LATER
timeoutSeconds. An answer at 1.1 seconds scores the same as no answer at all, and a service gets slow exactly when it is busy.
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
WHERE WE ARE
The first failure, running. {len}, starts on its own.

WHILE IT PLAYS
- The pod is Pending while Karpenter buys a machine.
- Then it starts.
- Then kubelet kills it on the fifth second, and again after the backoff.

WATCH
The RESTARTS column.

SAY OVER IT
Nobody touched the code and there is no traffic yet. The arithmetic from two slides ago is what killed it.
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
WHERE WE ARE
Ruslan's fix, and the day it stops working. {len}, starts on its own.

WHILE IT PLAYS
- The number goes up and the CrashLoop stops. Let Ruslan be right for a moment.
- A feature ships. Boot takes twenty seconds instead of ten.
- The same manifest kills the pod again.
- Madina produces the startupProbe: boot gets its own budget and liveness goes back to asking about steady state.

THE LINE TO LAND
initialDelaySeconds is a bet that tomorrow looks like today. Nobody touched the probe.
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
WHERE WE ARE
Production config and real traffic. {len}, starts on its own.

WHILE IT PLAYS
- Three replicas, and /healthz goes to the database through the same pool as /work.
- The load starts.
- Ends on the vote.

WATCH
The RESTARTS column, and point at it when it moves.

SAY OVER IT
The service is healthy. It is busy, and liveness cannot tell busy from dead because it only owns a timer.

DO NOT ANSWER THE VOTE
Let the room argue.
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
WHERE WE ARE
The fix, and the same load again. {len}, starts on its own.

WHILE IT PLAYS
- Two changes go in.
- The same load runs again.
- A before-and-after table closes it, built from two real measurements.

SAY OVER IT
The list of what was not touched is longer: not the code, not the traffic, not the hardware, not the database, and not the readiness probe, which stays tight on purpose.

READ THE NUMBERS, DO NOT PARAPHRASE
p95 is the same. The service did not get faster. It stopped shooting at itself.
-->

---
layout: default
---

# The question the probe was asking

<p class="nq-lede">The same failed check, routed through two different probes, costs two completely different things.</p>

<div class="nq-fig my-1">
  <img src="/diagrams/verdicts.svg" alt="liveness kills the container; readiness only removes the pod from the Service" />
</div>

<p class="nq-statement">Which makes <code>timeoutSeconds: 1</code> on a liveness probe <strong>a latency alarm wired to a kill switch</strong>. The load never changed. What took the service down was the health check.</p>

<!--
WHERE WE ARE
The answer to the vote, and the distinction the whole talk turns on.

THE CLICKS
1. the opening line: the same failed check, down two different probes, costs two completely different things
2. a pod that is working fine: "Start from a healthy pod. Nothing is wrong with it."
3. the liveness branch: "Liveness says no, and kubelet kills the container. Work in flight dies, the pool is rebuilt, the cache is cold. Irreversible. The only thing it is for is noticing a process that will never recover."
4. the readiness branch: "Readiness says no, and the pod leaves the EndpointSlice. It keeps running, no traffic reaches it, and it comes back by itself. Reversible."
5. the closing line

BEFORE THE LAST CLICK
Ask the room which one they would rather have.

THE LINE THAT MATTERS
timeoutSeconds: 1 on a liveness probe is a latency alarm wired to a kill switch.
-->

---
layout: section
variant: 3
---

# Incident 2

## The probe that buys EC2 instances

<!--
WHERE WE ARE
The second incident, a month later.

SAY
"Timur did everything right this time. He read the documentation and wrote the probe himself. It passes review, and it takes the whole service down."
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

<p class="nq-note mt-3" v-click="3">At three replicas the database does not notice: twelve connections out of fifty-four, one and a half scans a second. It passes review, it passes staging, and it passes the first week in production.</p>

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

<p class="nq-note mt-3" v-click="6"><code>max_connections</code> is 60, and RDS keeps six of those for itself: the application gets <strong>54</strong>. The probe that passed review is now a denial of service against the database it was checking.</p>

</div>

</div>

<!--
WHERE WE ARE
The probe nobody argues with, and what it costs at scale.

THE CLICKS
1. the sentence: "Readiness should verify we can actually read our data." Nobody argues with that in a pull request, and that is the problem.
2. the panel
3. readinessProbe
4. the endpoint
5. periodSeconds: 2: "Every two seconds, every replica."
6. the table: walk it left to right. "Three replicas: one and a half scans a second, twelve connections. The database does not notice."
7. fifty-four flies in
8. it turns bold: "The terminal will say sixty, because that is what max_connections is set to. RDS keeps six for itself, so fifty-four is what the application can have. At twenty-four replicas the probe alone wants ninety-six."
9. the closing line

THE LINE THAT MATTERS
The probe that passed review is now a denial of service against the database it was checking.
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
WHERE WE ARE
The centre of the talk. Walk it slowly: each click adds one step and the arrow into it.

THE CLICKS
1. the probe asks the database
2. replicas go NotReady
3. workers stop consuming SQS
4. the queue depth grows
5. KEDA adds workers
6. Karpenter buys nodes: the only step in the circle with a price tag
7. the last arrow, and the circle is closed
8. the closing line

BEFORE THE LAST CLICK
Say the thing the slide exists for: nothing in this loop is broken. Every component is doing exactly what it was asked to do.

THE LINE THAT MATTERS
Every turn adds connections to the database that is already the bottleneck, and one step in that circle is billed by the hour.
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
WHERE WE ARE
The review that let it through. {len}, starts on its own.

WHILE IT PLAYS
- Madina says nothing. She said it three times in incident 1 and it went nowhere, so this time she writes it down.
- The connection count on the right is the baseline: twelve of fifty-four, and Postgres does not wake up.

SAY OVER IT
It passes review, it passes staging, and it passes the first week in production.
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
WHERE WE ARE
Black Friday. {len}, starts on its own.

WHILE IT PLAYS
- The queue fills.
- KEDA scales workers from zero.
- Karpenter buys machines.

WATCH
The node counter. It is the number that costs money.

SAY OVER IT
This is the system working exactly as designed. Say so out loud before it stops being true.

IF PRESENTING FROM THE RECORDING
This cut is short and the scale-up is not in it: the waits were clicked through when the show was recorded. See docs/RUNBOOK.md.
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
WHERE WE ARE
The cascade. {len}, starts on its own.

WHILE IT PLAYS
- The wall arrives at fifty-four connections.
- Workers come up and cannot reach the database.
- They do not acknowledge their messages, so the messages come back.
- The queue gets deeper, so KEDA adds more workers.
- Ends on the second vote.

WATCH
The node count, not the queue. A queue going up under load is expected. A node count going up while nothing is processed is the incident.

IF PRESENTING FROM THE RECORDING
This cut stops after the KEDA card, so the cascade itself is not on screen. Narrate it from the loop slide instead, which is the better picture of it anyway.
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
WHERE WE ARE
The fix, and the same queue again. {len}, starts on its own.

WHILE IT PLAYS
- Every worker that comes up goes Ready and stays Ready.
- The node count does not move.
- The queue does not go down: two thousand a second go in and twelve workers cannot outrun that.

SAY BEFORE THE NUMBERS MOVE
Tell the room which two of those three to watch.

THE LINE TO CLOSE ON
Twelve workers, twelve Ready, against twenty-four of which next to none served. One probe changed. Nothing else did.
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

**O(1) in replicas**, not O(n), and a stale flag still takes the pod out, one at a time as each expires.

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
WHERE WE ARE
The answer. One click per part.

THE CLICKS
1. unhook the probe: "A goroutine refreshes a flag on its own schedule and the probe reads the flag. O(1) in replicas instead of O(n), and a stale flag still takes the pod out."
2. budget the pool: "replicas times POOL_MAX stays under max_connections, with room for everything else on that database."
3. cap the autoscaler: "Twelve, not twenty-four. An autoscaler without a ceiling is a way to turn an incident into an invoice."
4. the closing line

BEFORE THE LAST CLICK
Only the first of the three is about probes. The other two decide how far the next mistake gets before something stops it.
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
WHERE WE ARE
What to do on Monday. A slide to photograph, so stop talking and let them.

THE CLICKS
1. the liveness column: read the first and the last item; the room can read the middle two
2. the startup column: "Anything slower than a few seconds gets a startupProbe, not a bigger initialDelaySeconds."
3. the closing line turns bold

THE LINE THAT MATTERS
If you cannot say what a restart would fix, do not restart.
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
<li>A worker that cannot reach its dependency does not ack its message; check that your retry path cannot feed your scaler</li>
<li>Node autoscaling turns all of it into money</li>
</ul>

</div>

</div>

<p class="nq-statement mt-6">Probes are the only code that can kill a healthy service, and with an autoscaler underneath, bill you for it.</p>

<!--
WHERE WE ARE
The second half of the checklist.

THE CLICKS
1. the readiness column: the first line is the whole rule: can this pod serve, never is the shared thing healthy
2. around the probe: the two from incident 2 that are not about probes at all. The retry path is the one people forget.
3. the closing line turns bold

THE LINE THAT MATTERS
Probes are the only code that can kill a healthy service, and with an autoscaler underneath, bill you for it.
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
WHERE WE ARE
The end. Stop talking and leave the QR up.

SAY
"Everything you just saw is in that repository: the checklist, the manifests with these numbers in them, and the driver that ran the show. The failures reproduce: task bootstrap, then ./demo."

THEN
Leave this slide on screen for questions.
-->
