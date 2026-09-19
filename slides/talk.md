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
WHERE WE ARE · the promise. Nothing is revealed here; the slide is the title.

"Good morning. This talk is about the six lines in your manifest that almost
everyone copies from the service next door, and about the two of those lines
that can take a healthy service down and put the outage on your AWS bill.

Two incidents, both reproduced live on a real EKS cluster. Nothing here is
staged: the pods die because the numbers say they should."

If the cluster is unavailable, say so now rather than later, and present from
the recordings: they are full runs of the same show, cut per step, so losing
step 2.2 costs 2.2 and nothing else.
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
WHERE WE ARE · thirty seconds on who is talking, then straight to the terminal.
Four presses.

[click] photograph and the mark. "I run engineering at Naviteq."

[click] the role. "And I co-host DevOps Kitchen Talks, which is seventy-odd
episodes of two people arguing about infrastructure."

[click] the credentials. Read one, not five. The containers track and the
Terragrunt ambassadorship are the two that say why this talk and not another.

[click] the links. "These are all on the QR at the end, so nobody needs to
photograph this slide."

Then: "Every one of the two incidents you are about to see happened to somebody
I know, and one of them happened to me."
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
0

WHERE WE ARE · the cast, introduced by the stage itself. The recording starts
on its own when the slide arrives; the bar along the bottom is how much is left.

Timur ships the service. Ruslan tunes the numbers. Madina asks what the probe is
actually for. Karpenter answers Pending pods by buying machines, and has a
credit card.

About a minute and a half. Talk over it rather than skipping it: a later step called
"Madina unhooks the probe" does not land on a room that has never met her.
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
WHERE WE ARE · the one piece of theory that has to come before the first
failure. Six presses, and the diagram draws itself branch by branch.

[click] the opening line. "Something is asking your container questions, and it
is not a load balancer and not a human. It is kubelet, the agent on every node,
asking every few seconds, forever, using numbers that came out of your manifest."

[click] kubelet appears. Point at it. This is the only actor in the talk that
never changes its behaviour.

[click] startup. "Has it finished booting? While this one runs, the other two
are not consulted at all."

[click] liveness. "Is the process alive? A wrong answer restarts the container,
and work in flight dies with it."

[click] readiness. "Can it serve right now? A wrong answer only takes the pod
out of the Service. It keeps running and it comes back by itself."

[click] the line at the bottom, which is the one to land slowly: of everything
that can take a container down, a probe is the only one that does it while the
process is working perfectly well.
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
WHERE WE ARE · the cluster, before anything breaks. Eight presses, following a
request through the system.

[click] the opening line. One queue, two autoscalers on two different signals,
one database with max_connections pinned low.

[click] the VPC and the cluster. Mention the no-NAT quirk only if somebody asks
about cost; otherwise keep moving.

[click] the api. "A request lands here."

[click] the queue. "It goes on SQS."

[click] the worker. "A worker picks it up."

[click] the database, and the long line back from the api. "Both of them reach
the same Postgres. It is capped at sixty connections and RDS reserves six of
those for itself, so the application gets fifty-four. Remember that number.
that number."

[click] KEDA and Karpenter. "These two are watching. KEDA reads queue depth,
Karpenter buys machines for pods that will not fit. Neither of them knows why
the queue is deep."

[click] the constraints line. Say it once: the cluster is deliberately small so
the failure is visible, not so the demo is cheap.
-->

---
layout: section
variant: 2
---

# Incident 1

## The probe that kills a healthy pod

<!--
WHERE WE ARE · the first of two. No presses.

"A service that takes ten seconds to start, and a probe copied out of an
article. Nobody writes a bug."
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
WHERE WE ARE · the mechanism, before the cluster demonstrates it. Twelve
presses; the manifest arrives a line at a time.

[click] the opening line.

[click] "ten seconds" turns bold. That is the number the rest of the slide is
measured against.

[click] the panel.

[click] livenessProbe. "This is the whole probe."

[click] the endpoint. "It asks /healthz over HTTP."

[click] initialDelaySeconds: two. "Wait two seconds before asking anything."

[click] periodSeconds: one. "Then ask again every second."

[click] timeoutSeconds: one. "An answer has one second to arrive."

[click] failureThreshold: three. "Three misses in a row and the pod dies."

[click] the sum flies in. Pause here.

[click] the sum turns bold. "Two, plus three misses a second apart, is five
seconds of patience. The service needs ten. The pod is killed on the fifth
second, every single time, and there is no bug anywhere: not in the code, not
in the manifest."

[click] the last line. timeoutSeconds is the half that bites later: an answer at
1.1 seconds scores the same as no answer at all, and a service gets slow
exactly when it is busy.
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
1.1

WHERE WE ARE · the first failure, running. Starts on its own.

Watch the RESTARTS column. The pod is Pending first while Karpenter buys a
machine, then it starts, then kubelet kills it on the fifth second, and again
after the backoff.

What to say while it runs: nobody touched the code and there is no traffic yet.
The arithmetic from two slides ago is what killed it.
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

WHERE WE ARE · Ruslan's fix, and the day it stops working. Starts on its own.

Two halves. First the number goes up and the CrashLoop stops — let Ruslan be
right for a moment. Then a feature ships, boot takes twenty seconds instead of
ten, and the same manifest kills the pod again.

The line to land: initialDelaySeconds is a bet that tomorrow looks like today.
Nobody touched the probe.

The second half is where Madina produces the startupProbe. Boot gets its own
budget and liveness goes back to asking about steady state.
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
1.3

WHERE WE ARE · production config and real traffic. Starts on its own.

Three replicas now, and /healthz goes to the database through the same pool as
/work. Then the load starts.

Point at the RESTARTS column when it moves. The service is healthy. It is
simply busy, and liveness cannot tell busy from dead because it only owns a
timer.

Ends on the vote. Let the room argue and do not answer it.
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

WHERE WE ARE · the fix, and the same load again. Starts on its own.

Two changes, and the list of what was not touched is longer: not the code, not
the traffic, not the hardware, not the database, and not the readiness probe,
which stays tight on purpose.

The before-and-after table at the end is built from two real measurements. Read
the numbers rather than paraphrasing them: p95 is the same. The service did not
get faster, it stopped shooting at itself.
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
WHERE WE ARE · the answer to the vote, and the distinction the whole talk turns
on. Five presses.

[click] the opening line. The same failed check, down two different probes,
costs two completely different things.

[click] a pod that is working fine. "Start from a healthy pod. Nothing is wrong
with it."

[click] the liveness branch. "Liveness says no, and kubelet kills the
container. Work in flight dies, the pool is rebuilt, the cache is cold again.
That is irreversible: the only thing it is for is noticing a process that will
never recover."

[click] the readiness branch. "Readiness says no, and the pod leaves the
EndpointSlice. It keeps running, no traffic reaches it, and it comes back by
itself. That is reversible."

Ask the room which one they would rather have before the last press.

[click] the closing line. timeoutSeconds: 1 on a liveness probe is a latency
alarm wired to a kill switch.
-->

---
layout: section
variant: 3
---

# Incident 2

## The probe that buys EC2 instances

<!--
WHERE WE ARE · the second incident, a month later. No presses.

"Timur did everything right this time. He read the documentation and wrote the
probe himself. It passes review, and it takes the whole service down."
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
WHERE WE ARE · the probe nobody argues with, and what it costs at scale. Nine
presses.

[click] the sentence. "Readiness should verify we can actually read our data."
Nobody argues with that in a pull request, and that is the problem.

[click] the panel.

[click] readinessProbe. [click] the endpoint. [click] periodSeconds: two.
"Every two seconds, every replica."

[click] the table. Walk it left to right. "Three replicas: one and a half scans
a second, twelve connections. The database does not notice."

[click] fifty-four flies in. [click] it turns bold. "The terminal will say
sixty, because that is what max_connections is set to. RDS keeps six of them
for itself, so fifty-four is what the application can actually have. At
twenty-four replicas the probe alone wants ninety-six."

[click] the closing line. The probe that passed review is now a denial of
service against the database it was checking.
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
WHERE WE ARE · the centre of the talk. Eight presses, and the circle closes on
the last one.

Walk it slowly. Each press adds one step and the arrow into it.

[click] the probe asks the database.
[click] replicas go NotReady.
[click] workers stop consuming SQS.
[click] the queue depth grows.
[click] KEDA adds workers.
[click] Karpenter buys nodes — the only step in the circle with a price tag.
[click] the last arrow, and the circle is closed.

Now say the thing the slide exists for: nothing in this loop is broken. Every
component is doing exactly what it was asked to do.

[click] the closing line. Every turn adds connections to the database that is
already the bottleneck, and one step in that circle is billed by the hour.
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
2.1

WHERE WE ARE · the review that let it through. Starts on its own.

Watch Madina say nothing. She said it three times in the first incident and
it went nowhere, so this time she writes it down instead.

The connection count on the right is the baseline. Twelve out of fifty-four,
and Postgres does not even wake up. It passes review, it passes staging, and it
passes the first week in production.
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

WHERE WE ARE · Black Friday. Starts on its own.

The queue fills, KEDA scales workers from zero, Karpenter buys machines. This
is the system working exactly as designed, and it is worth saying so out loud
before it stops being true.

Point at the node counter. It is the number that costs money.

If you are presenting from the recording rather than the cluster, know that
this segment is eleven seconds: it applies the manifests and shows the
connection baseline, and the scale-up is not in it. See the note on the
recording in docs/RUNBOOK.md.
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
2.3

WHERE WE ARE · the cascade. Starts on its own.

The wall arrives at fifty-four connections. Workers come up and cannot reach
the database, so they do not acknowledge their messages, so the messages come
back, so the queue gets deeper, so KEDA adds more workers.

The number to point at is the node count, not the queue. A queue going up under
load is expected. A node count going up while nothing is being processed is the
incident.

Ends on the second vote.

From the recording this segment is twenty-two seconds and stops after the KEDA
card, so the cascade itself is not on screen. Narrate it from the loop slide
instead, which is two slides back and is the better picture of it anyway.
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

WHERE WE ARE · the fix, and the same queue again. Starts on its own.

Before the numbers move, say what to watch for: every worker that comes up
should go Ready and stay Ready, and the node count should not move. The queue
will not go down — two thousand a second go in and twelve workers cannot outrun
that — so watch the other two numbers.

Twelve workers, twelve Ready, against twenty-four of which next to none served.
One probe changed. Nothing else did.
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
WHERE WE ARE · the answer. Four presses, one per part.

[click] unhook the probe. "A goroutine refreshes a flag on its own schedule and
the probe reads the flag. O(1) in replicas instead of O(n), and a stale flag
still takes the pod out."

[click] budget the pool. "replicas times POOL_MAX has to stay under
max_connections, with room for everything else that connects to that database."

[click] cap the autoscaler. "Twelve, not twenty-four. An autoscaler without a
ceiling is a way to turn an incident into an invoice."

Then the line that matters: only the first of the three is about probes. The
other two decide how far the next mistake gets before something stops it.

[click] the closing line. Twelve workers, twelve Ready, against twenty-four of
which next to none served.
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
WHERE WE ARE · what to do on Monday. Three presses. This is a slide to
photograph, so stop talking and let them.

[click] the liveness column. Read the first and the last item; the room can
read the middle two.

[click] the startup column. "Anything slower than a few seconds gets a
startupProbe, not a bigger initialDelaySeconds."

[click] the closing line turns bold. If you cannot say what a restart would
fix, do not restart.
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
WHERE WE ARE · the second half of the checklist. Three presses.

[click] the readiness column. The first line is the whole rule: can this pod
serve, never is the shared thing healthy.

[click] around the probe. These are the two from incident 2 that are not about
probes at all, and the retry path is the one people forget.

[click] the closing line turns bold. Probes are the only code that can kill a
healthy service, and with an autoscaler underneath, bill you for it.
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
WHERE WE ARE · the end. No presses. Stop talking and leave the QR up.

"Everything you just saw is in that repository: the checklist, the manifests
with these numbers in them, and the driver that ran the show. The failures
reproduce: task bootstrap, then ./demo."

Leave this slide on screen for questions.
-->
