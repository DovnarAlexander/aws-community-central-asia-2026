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
# Hash routing, so the built deck serves from any folder of any static host.
# With the default history router and `--base ./` the app boots and then the
# router fails to match /whatever/index.html and renders its 404 page -- the
# "blank deck" is the SPA working and the routing not. The tooling that
# navigates slide URLs (check-slides.mjs) uses /#/n accordingly.
routerMode: hash
layout: cover
variant: 2
---

# The probe that killed itself

## A health check, two autoscalers, and an EC2 bill

Alexander Dovnar · Naviteq · AWS User Group Central Asia 2026

<!--
"Good evening. I am really happy to be here — thank you for inviting me."

"This talk is about six lines in your YAML file."

"Almost everyone copies them from the service next door. Two of them can
kill a healthy service and put the outage on your AWS bill."
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
Let's start with some short self-introduction :)

1 "I run engineering at Naviteq as the CTO. We do DevOps services for variety of companies mostly from Israel."

2 "And I’m the co-host  and “named” CTO of DevOps Kitchen Talks podcast where we discuss DevOps topics and argue about AI 

3 "AWS Community Builder on the containers track, and a Terragrunt ambassador. Which is more or less why this talk exists.” Also last year we released with my friend the book with Packt called “Cracking the Kubernetes interview"

4 "These are all on the QR at the end, so nobody needs to photograph this slide."

"Both incidents you are about to see happened to somebody I know, and one of them happened to me."
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="0.1" fit="both" />
  </div>
</div>

<!--
The opening titles: the people, one card each. The cards are on screen —
add one line per person, no more.

"This terminal is the whole talk. A real cluster, a real database, and
the failures are real too."

Timur writes the backend and copied his probe from a blog post. Ruslan
runs the infrastructure and fixes things by changing numbers. Madina is
the intern. She read the documentation.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="0.2" fit="both" />
  </div>
</div>

<!--
Now the machines get cards too.

kubelet reads the manifest, not the code. Postgres has 54 connections to
give. KEDA adds workers when the queue is deep. Karpenter buys machines
— that one has a credit card.

"Seven characters. The two that matter are not people."

[CLICK — next scene]
-->

---
layout: default
---

# Something is asking your container questions

<p class="nq-lede" v-click="1">Not a load balancer. Not a human. <strong>kubelet</strong>, every few seconds, forever, using numbers out of your manifest.</p>

<div class="nq-fig my-1">
  <div class="nq-layers">
    <img src="/diagrams/probes-1.svg" v-click="2" alt="kubelet asks three questions; each kind of wrong answer costs something different" />
    <img src="/diagrams/probes-2.svg" v-click="3" alt="" />
    <img src="/diagrams/probes-3.svg" v-click="4" alt="" />
    <img src="/diagrams/probes-4.svg" v-click="5" alt="" />
  </div>
</div>

<p class="nq-statement" v-click="6">Of everything that can take a container down (a crash, an OOM, an eviction, a rollout), a probe is the only one that does it <strong>while the process is working perfectly well</strong>.</p>

<!--
A one-minute recap before the story starts. Keep every beat to two
short lines.

[1 — the lede]
"Something asks your container questions. Not a load balancer. Not a person."
"kubelet. Every node. Every few seconds. With numbers from your YAML."

[2 — kubelet appears]
"It is the only thing in this talk that never changes how it behaves."

[3 — startup]
"Startup: has it finished booting? While it runs, nobody asks the other two."

[4 — liveness]
"Liveness: is the process alive? A wrong answer restarts the container."

[5 — readiness]
"Readiness: can it serve right now? A wrong answer takes the pod out of
the Service. It keeps running, and it comes back on its own."

[6 — the statement, slowly]
"A crash. Out of memory. An eviction. A rollout. All of those kill containers."
"A probe is the only one that does it while the process is working fine."
-->

---
layout: default
---

# What is actually running

<p class="nq-lede" v-click="1">One queue, two autoscalers on two different signals, one database with <code>max_connections</code> pinned low.</p>

<div class="nq-fig my-1">
  <div class="nq-layers">
    <img src="/diagrams/architecture-1.svg" v-click="2" alt="EKS with api, SQS, workers, KEDA and Karpenter, all against one RDS instance" />
    <img src="/diagrams/architecture-2.svg" v-click="3" alt="" />
    <img src="/diagrams/architecture-3.svg" v-click="4" alt="" />
    <img src="/diagrams/architecture-4.svg" v-click="5" alt="" />
    <img src="/diagrams/architecture-5.svg" v-click="6" alt="" />
    <img src="/diagrams/architecture-6.svg" v-click="7" alt="" />
  </div>
</div>

<p class="nq-note" v-click="8">Three deliberate constraints: <strong>no NAT gateway</strong> (the quiet $32 a month), <strong>spot and small instances</strong> so scaling is visible as node <em>count</em>, and a <strong>non-burstable</strong> RDS class so the failure reproduces on the day instead of running out of CPU credits halfway through.</p>

<!--
[1 — the pieces]
"One queue. Two autoscalers, watching two different things. One database
with a low connection limit."

[2 — the network]
"The network, and the cluster inside it."

[3 — api]
"A request lands here."

[4 — queue]
"It goes on the queue."

[5 — worker]
"A worker picks it up."

[6 — the database]
"Both sides talk to the same Postgres. The setting says sixty. RDS keeps
six for itself. The app gets fifty-four."
"Remember fifty-four."

[7 — the autoscalers]
"KEDA reads the queue. Karpenter buys machines for pods that do not fit."
"Neither of them knows WHY the queue is deep."

[8 — the constraints]
"The cluster is small on purpose, so you can watch scaling as node count."

[the no-NAT saving — only if somebody asks about cost]
-->

---
layout: section
variant: 2
---

# Incident 1

## The probe that kills a healthy pod

<!--
"A service that takes ten seconds to start. A probe copied from an
article. Nobody wrote a bug."
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.1.1" fit="both" />
  </div>
</div>

<!--
Timur ships his service — ten seconds to start, warming a cache and a
pool. Ruslan asks about the probe; it is copied from an article.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.1.2" fit="both" />
  </div>
</div>

<!--
Madina asks for the numbers and starts adding them up. Ruslan ships
before she finishes — let the room finish the sum for her.

The pod is Pending, so Karpenter buys a machine. While it shops,
Madina's card explains the four numbers. Read the card from the screen,
slowly — it ends on the sum: five seconds of patience, ten seconds of
start.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.1.3" fit="both" />
  </div>
</div>

<!--
kubelet knocks at two seconds; the service needs ten. Two kills, then
CrashLoopBackOff.

[point at the RESTARTS column]

[the closing line is on screen — read it, then pause]

[CLICK — the next slide does the math]
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

</div>

<div>

<div v-click="4">

<p class="nq-body"><code>timeoutSeconds: 1</code> — an answer at 1.1 seconds counts exactly the same as no answer at all. Keep that line. It comes back.</p>

</div>

<div v-click="5" class="mt-5">

<p class="nq-figure-number">2 + 3 × 1 = 5 s</p>

<p class="nq-body">Patience runs out at five. The service is ready at ten. <strong>The pod dies every single time</strong>, and nothing in the manifest is wrong.</p>

</div>

</div>

</div>

<!--
The freeze-frame: the math the room just watched, on one slide.

[0 — the probe from the article]
"This is the whole probe. And the service needs ten seconds. Keep that number."

[1 — initialDelaySeconds]
"Wait two seconds before the first question."

[2 — periodSeconds]
"Then ask again every second."

[3 — failureThreshold]
"Three misses in a row — the pod dies."

[4 — timeoutSeconds]
"And one second to answer. Hold that line. It comes back later."

[5 — the sum]
"Two, plus three misses one second apart. Five seconds of patience."
"The service needs ten. So the pod dies on the fifth second. Every time."
"There is no bug anywhere in the code."
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.2.1" fit="both" />
  </div>
</div>

<!--
Ruslan has seen CrashLoop a hundred times: one line fixes it.
initialDelaySeconds goes from two to twelve. Twelve is bigger than ten,
so he is done. Madina asks what happens if the start gets slower.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.2.2" fit="both" />
  </div>
</div>

<!--
Green — but it holds because nothing changed, not because the number is
right. Her line about that is on screen.

A week passes. Timur ships a good feature: the catalogue is preloaded
at boot now. Requests get twice as fast — and warmup goes from ten
seconds to twenty. Nobody touched the probe.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.2.3" fit="both" />
  </div>
</div>

<!--
The same race again: patience runs out at fifteen, the service is ready
at twenty. The pod dies — and nobody did anything wrong.

Madina lists what moves a start: a cold cache, a noisy neighbour, more
data. None of them touch the manifest.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.2.4" fit="both" />
  </div>
</div>

<!--
Madina finally gets her answer in: the documentation has a startupProbe.
While startup runs, the other two are not consulted. Boot gets its own
budget — two minutes if it wants.

Her card with the three probes is on screen. Read it from there, slowly.

[point at RESTARTS — same slow start, still zero]

[CLICK — next scene]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.3.1" fit="both" />
  </div>
</div>

<!--
The start is fixed, so Timur ships the production config: three
replicas and real queries. He also points /healthz at the database —
an honest check, in his words. Madina warns that it shares the pool
with the real work. Four connections. They ship anyway.

Her card — restart versus remove — is on screen during the rollout.
Read it from there.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.3.2" fit="both" />
  </div>
</div>

<!--
Three replicas Ready, one per node.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.3.3" fit="both" />
  </div>
</div>

<!--
The traffic starts. The service is healthy — only busy. The pool fills
with real work, and /healthz waits in the same line. kubelet gets no
answer.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.3.4" fit="both" />
  </div>
</div>

<!--
Three misses in a row, and kubelet kills the container.

[point at RESTARTS climbing]

Timur protests: it is alive, just busy. kubelet cannot tell the
difference — it only owns a timer.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.3.5" fit="both" />
  </div>
</div>

<!--
The events log: liveness failed three times, then the kill. The
traffic never changed.

Then the vote: who took down a healthy service? Take hands.

[CLICK — next scene: Madina answers]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.4.1" fit="both" />
  </div>
</div>

<!--
Madina says none of the three — it was the wrong question. Liveness
asks one thing: is the process alive. You do not visit a database for
that.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.4.2" fit="both" />
  </div>
</div>

<!--
The fix: /healthz stops leaving the process, and liveness gets a
generous timeout and more misses. Readiness stays tight on purpose —
taking a busy replica out of rotation is its job.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.4.3" fit="both" />
  </div>
</div>

<!--
Her card lists the changes — and the longer list of what did not
change: not the code, not the traffic, not the machines, not the
database.

Same load again. This time RESTARTS should not move at all.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="1.4.4" fit="both" />
  </div>
</div>

<!--
The before/after table. p95 is the same — the service did not get
faster. It stopped shooting at itself.

[the closing line is on screen — read it, then pause]

[CLICK — the next slide sums the incident up]
-->

---
layout: default
---

# The question the probe was asking

<p class="nq-lede" v-click="1">The same failed check, routed through two different probes, costs two completely different things.</p>

<div class="nq-fig my-1">
  <div class="nq-layers">
    <img src="/diagrams/verdicts-1.svg" v-click="2" alt="liveness kills the container; readiness only removes the pod from the Service" />
    <img src="/diagrams/verdicts-2.svg" v-click="3" alt="" />
    <img src="/diagrams/verdicts-3.svg" v-click="4" alt="" />
  </div>
</div>

<p class="nq-statement" v-click="5">Which makes <code>timeoutSeconds: 1</code> on a liveness probe <strong>a latency alarm wired to a kill switch</strong>. The load never changed. What took the service down was the health check.</p>

<!--
The freeze-frame for incident 1. The room has seen all of it — keep
each beat short.

[1 — two paths]
"The same failed check. Two different probes. Two very different prices."

[2 — a healthy pod]
"Start with a healthy pod. Nothing is wrong with it."

[3 — liveness]
"Liveness says no — kubelet kills the container. Work in flight dies.
The pool is rebuilt. The cache is cold."
"You cannot undo that."

[4 — readiness]
"Readiness says no — the pod leaves the Service. It keeps running. It
comes back on its own."
"You can undo that."

[before the last click] "So which one should be answering the question?"

[5 — the statement]
"Which makes timeoutSeconds one on liveness a latency alarm wired to a
kill switch."
-->

---
layout: section
variant: 3
---

# Incident 2

## The probe that buys EC2 instances

<!--
"This time Timur did everything right. He read the docs and wrote the
probe himself."

"It passes review. And it takes the whole service down."
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

</div>

<div>

<p class="nq-figure-number" v-click="3">scans/sec = replicas ÷ period</p>

<p class="nq-note mt-3" v-click="4">At three replicas: one and a half scans a second, twelve connections out of fifty-four. The database does not notice. It passes review, it passes staging, and it passes the first week in production.</p>

</div>

</div>

<!--
Only the innocent half of the story lives on this slide. The rest is
the demo's to tell.

[0 — the sentence]
"Readiness should check that we can really read our data. Nobody argues
with that in a review."
"That is the problem."

[1 — the probe]
"A readiness probe. It asks /ready every two seconds."

[2 — the query]
"And /ready runs a real query on the database."

[3 — the formula]
"Every replica asks. Scans per second is replicas divided by period."

[4 — three replicas]
"Three replicas: one and a half scans a second, twelve connections out
of fifty-four. The database does not notice."
"It passes review, staging, and the first week in production."
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.1.1" fit="both" />
  </div>
</div>

<!--
A month later. Timur did not copy this probe — he read the docs and
wrote it himself: every readiness call queries the database. Ruslan
approves it, because it checks something real. Madina says nothing.
It passed review.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.1.2" fit="both" />
  </div>
</div>

<!--
She said it out loud three times in the first incident. This time she
writes it down.

Her card explains the blast radius: the Service routes to a list of
addresses, and readiness edits that list. Every pod NotReady means an
empty list — no error, no traffic. Read the card from the screen.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.1.3" fit="both" />
  </div>
</div>

<!--
Twelve connections out of fifty-four. Postgres did not even wake up.
All green — while there are three replicas.

[CLICK — next scene: Black Friday]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.2.1" fit="both" />
  </div>
</div>

<!--
Black Friday. The work arrives as a queue — that is what this system
was built for. KEDA watches it, with zero workers running.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.2.2" fit="both" />
  </div>
</div>

<!--
Two thousand messages a second start going in.

The KEDA card is on screen: poll every five seconds, twenty messages
per worker, ceiling at twenty-four. Read it from there — and land on
its last line: nothing in that formula knows WHY the queue is deep.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.2.3" fit="both" />
  </div>
</div>

<!--
KEDA adds workers. The workers do not fit, so Karpenter buys machines.
Ruslan calls it the system working.

[point at the node counter — the only number here with a price on it]

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.2.4" fit="both" />
  </div>
</div>

<!--
Madina asks the room to look at what each new worker does before it
processes a single message.

[CLICK — next scene: the database]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.3.1" fit="both" />
  </div>
</div>

<!--
Every replica opens a pool of four and scans two million rows every two
seconds — because that is what its readiness probe does. Ruslan calls
it a health check. Madina calls it a health check multiplied by the
replica count.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.3.2" fit="both" />
  </div>
</div>

<!--
The arithmetic lands: twenty-four workers, four connections each —
ninety-six wanted. Postgres has fifty-four.

[point at the worker logs: too many connections]

The pods are up — and not Ready. A worker that cannot reach the
database never acks its message. The message comes back. The queue
gets deeper.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.3.3" fit="both" />
  </div>
</div>

<!--
The loop closes on screen: NotReady workers, deeper queue, more
workers, more nodes. Madina's loop card is up while the panes keep
turning underneath it.

[point at throughput: zero. Nodes: still climbing]

"Nothing here is broken. Every part is doing exactly what we asked."

[CLICK — the next slide freezes the loop]
-->

---
layout: default
---

# The loop

<div class="nq-fig my-1">
  <div class="nq-layers">
    <img src="/diagrams/loop-1.svg" v-click="1" alt="probe, NotReady, queue depth, KEDA, Karpenter, back to the probe" />
    <img src="/diagrams/loop-2.svg" v-click="2" alt="" />
    <img src="/diagrams/loop-3.svg" v-click="3" alt="" />
    <img src="/diagrams/loop-4.svg" v-click="4" alt="" />
    <img src="/diagrams/loop-5.svg" v-click="5" alt="" />
    <img src="/diagrams/loop-6.svg" v-click="6" alt="" />
    <img src="/diagrams/loop-7.svg" v-click="7" alt="" />
  </div>
</div>

<p class="nq-statement" v-click="8">Every turn adds connections to the database that is already the bottleneck, which makes the next turn worse. One step in that circle is <strong>billed by the hour</strong>.</p>

<!--
The freeze-frame. The room just watched this happen — walk the circle
once, quickly.

[1 — the probe]
"The probe asks the database. Every two seconds, on every replica."

[2 — NotReady]
"Connections run out. The probe fails. The replicas go NotReady."

[3 — consumers stop]
"A NotReady worker stops taking messages."

[4 — the queue]
"So the queue gets deeper."

[5 — KEDA]
"KEDA sees a deep queue and adds workers."

[6 — Karpenter]
"They do not fit, so Karpenter buys nodes. The only step with a price on it."

[7 — the circle closes]
"And every new worker asks the database the same question."

[before the last click] "Nothing is broken. Everything does what we asked."

[8 — the statement]
"Every turn adds connections to the bottleneck. Every turn makes the
next one worse."
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.3.4" fit="both" />
  </div>
</div>

<!--
The endpoint list is empty. Not one address. Scaling took the service
down, and it bought hardware to do it.

Then the vote: raise the worker limit, restart the database, or give
the probe more time? Take hands for each.

[CLICK — next scene: Madina answers]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.4.1" fit="both" />
  </div>
</div>

<!--
Again none of the three — every one of them adds work to the database,
and the first also buys more machines. Madina takes the probe off the
database instead.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.4.2" fit="both" />
  </div>
</div>

<!--
The fix, in her words: a background goroutine checks the database on
its own schedule and stores the answer in a flag. The probe reads the
flag. If the database really dies, the flags go stale and the pods
leave the balancer one at a time.

Two more changes ride along: the pool drops to three connections, and
KEDA gets a ceiling.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.4.3" fit="both" />
  </div>
</div>

<!--
Her card: the fix in three parts, and only the first is a probe. Read
it from the screen.

Same queue again. Two numbers to watch: every worker Ready, and a flat
node count. The queue itself will not go down — that warning is on
screen too.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.4.4" fit="both" />
  </div>
</div>

<!--
Twelve workers, twelve Ready, node count flat. The queue still grows —
twelve workers cannot outrun two thousand a second — but these twelve
finish what they take. The old twenty-four handed every message back.

Karpenter has stopped buying, and gives the idle machines back a few
minutes later. It was never the problem.

[CLICK — recording continues]
-->

---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/full.cast" step="2.4.5" fit="both" />
  </div>
</div>

<!--
Forty-five connections, almost nothing active. Same load, same target,
different probe.

[the closing line is on screen — read it, then pause]

[CLICK — the next slide sums the fix up]
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
The recap card. The room has seen every part of this — one line per
card, let them read the rest.

[1 — the probe]
"One. The probe reads a flag. The cost stops multiplying by replicas."

[2 — the pool]
"Two. Replicas times pool size stays under the connection limit."

[3 — the ceiling]
"Three. Every autoscaler gets a ceiling."

[before the last click] "Only the first one is about probes. The other
two decide how far the next mistake gets."

[4 — the statement]
"Twelve workers, twelve Ready. One probe changed. Nothing else did."
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
[1 — liveness]
"Liveness touches nothing outside the process."
"And the math is written down: delay plus threshold times period,
against the slowest start you have ever seen. Not the usual one."

[2 — startup]
"Anything slower than a few seconds gets a startupProbe, with its own
budget. Two minutes is fine."

[3 — the rule]
"If you cannot say what a restart would fix — do not restart."

[stop talking; let them photograph the slide]
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
[1 — readiness]
"Readiness answers one question: can THIS pod serve. Never: is the
shared thing healthy."
"If it must know about a dependency, it reads a flag."

[2 — around the probe]
"Multiply the probe's cost by the autoscaler's ceiling."
"Give every autoscaler a ceiling."
"And check that your retry path cannot feed your scaler."

[3 — the closing line]
"Probes are the only code that can kill a healthy service. With an
autoscaler underneath, they also send you the bill."
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
"Everything you saw is in this repository: the checklist, the manifests
with these numbers, and the tool that ran the show."

"The failures are reproducible: task bootstrap, then ./demo."

[leave this slide up for questions]
-->
