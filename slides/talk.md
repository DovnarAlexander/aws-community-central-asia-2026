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
"Good morning. This talk is about six lines in your manifest that almost everyone copies from the service next door, and about the two of them that can take a healthy service down and put the outage on your AWS bill.

Two incidents, both reproduced live on a real EKS cluster. The pods die because the numbers say they should."

[if the cluster is down, say so now rather than later and present from the recordings -- they are full runs of the same show, cut per step]
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
1 "I run engineering at Naviteq."

2 "And I co-host DevOps Kitchen Talks -- seventy-odd episodes of two people arguing about infrastructure."

3 "AWS Community Builder on the containers track, and a Terragrunt ambassador. Which is more or less why this talk exists."

4 "These are all on the QR at the end, so nobody needs to photograph this slide."

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
[{len}, starts on its own]

[the boot sequence, then the title card: a real cluster, a real database, real
failures, nothing recorded -- including the parts that go wrong]

[the cast arrives one at a time. Introduce them as they land]

Timur is the backend developer. He wrote the service, it takes ten seconds to
start, and the probe he is using came out of a blog post. It is green, so as far
as he is concerned it is correct.

Ruslan runs DevOps. Every production problem is a number in a YAML file, and the
method has never failed him before today.

Madina is the intern. She has read the documentation, and nobody asks her opinion
for a while.

Then the machines. kubelet does not read your code, it reads your manifest and
pulls the trigger. Postgres has two vCPU and fifty-four connections to hand out.
KEDA adds workers when the queue is deep, and has no other ideas. Karpenter buys
machines when pods are Pending, and that one has a credit card.

[click for the card]

Seven characters, and the two that matter are not people.

[do not skip this slide -- "Madina unhooks the probe" later does not land on a
room that has never met her]
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
1 "Something is asking your container questions, and it is not a load balancer and it is not a human. It is kubelet, the agent on every node, asking every few seconds, forever, using numbers that came out of your manifest."

2 "That one. The only actor in this whole talk that never changes its behaviour."

3 "Startup: has it finished booting? While this one is running, the other two are not consulted at all."

4 "Liveness: is the process alive? A wrong answer restarts the container, and work in flight dies with it."

5 "Readiness: can it serve right now? A wrong answer only takes the pod out of the Service. It keeps running, and it comes back by itself."

6 [slowly] "Of everything that can take a container down -- a crash, an OOM, an eviction, a rollout -- a probe is the only one that does it while the process is working perfectly well."
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
1 "One queue, two autoscalers on two different signals, and one database with max_connections pinned low."

2 "That is the VPC, and the cluster inside it."

3 "A request lands here."

4 "It goes on SQS."

5 "A worker picks it up."

6 "And both of them reach the same Postgres. It is capped at sixty, and RDS keeps six for itself, so the application gets fifty-four. Remember that number."

7 "These two are watching. KEDA reads queue depth. Karpenter buys machines for pods that will not fit. Neither of them knows why the queue is deep."

8 "The cluster is deliberately small, so that scaling is visible as a node count on the screen."

[the no-NAT saving only if somebody asks about cost]
-->

---
layout: section
variant: 2
---

# Incident 1

## The probe that kills a healthy pod

<!--
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
1 "Every number in this probe is defensible on its own."

2 "The service warms up for ten seconds. That is the number everything else on this slide is measured against."

3 "Here is what was in the manifest."

4 "This is the whole probe."

5 "It asks /healthz over HTTP."

6 "Wait two seconds before asking anything."

7 "Then ask again every second."

8 "An answer has one second to arrive."

9 "Three misses in a row, and the pod dies."

10 [pause here]

11 "Two, plus three misses a second apart, is five seconds of patience. The service needs ten. The pod is killed on the fifth second, every single time, and there is no bug anywhere."

12 "A startupProbe gives boot its own budget instead, and while it runs the other two are not consulted at all. Raising initialDelaySeconds is the fix everyone reaches for, and it holds until the day the start gets slower.

And timeoutSeconds is the half that bites later. An answer at one point one seconds scores exactly the same as no answer at all -- and a service answers slowly precisely when it is busy."
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
[{len}, starts on its own]

Timur says the service is done: ten seconds to start, warms a cache, opens a
pool. Ruslan asks whether he has a probe. He copied one out of an article, it was
right there in the example. Madina asks for the numbers, and while she is still
adding them up, Ruslan ships it.

[the manifest, then the apply. The pod is Pending, so Karpenter goes shopping]

[Madina's card is up for the whole wait -- read the four numbers off it]

Two seconds before the first question. One second between questions. One second
to answer. Three misses and the pod dies. That is five seconds of patience
against a ten-second start, and kubelet is the one asking -- not a load balancer,
not a human, not your code.

[the node arrives, the pod is scheduled]

kubelet knocks at two seconds. Timur says it is warming up. That answer is not in
the manifest.

Count along, and watch the RESTARTS column. Nobody touched the code and there is
no traffic yet. Arithmetic killed the pod.
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
[{len}, starts on its own]

Ruslan has seen CrashLoop a hundred times and says one line fixes it: the one
with the number in it. initialDelaySeconds goes from two to twelve. Twelve is
bigger than ten, so he is done here.

Madina asks what happens if the start gets slower. Ruslan asks why it would.

[the apply, and the pod comes up green]

It holds. Madina's point is that it holds because nothing changed, not because
the number is right.

[click -- a week passes, and Timur ships a feature]

The catalogue is preloaded now. /work used to fetch it on every request; it reads
it once at boot instead. Requests got twice as fast and boot pays for it: warmup
goes from ten seconds to twenty.

Nobody went near the probe. The service grew underneath it.

Two numbers are racing. Patience runs out at fifteen seconds, and the service is
ready at twenty. Same manifest, slower environment.

initialDelaySeconds is a bet that tomorrow looks like today. A cold cache, a
noisier neighbour, a bigger dataset, one more step at boot -- none of those touch
the manifest, and every one of them moves the start. Every other number in a
probe reacts to something the process did. This one only counts.

Madina's answer is the startupProbe, and she has read the whole documentation.

[the diff, then the apply. Her card -- read the three questions off it]

While startup runs, the other two are not consulted at all. Boot gets its own
budget, two minutes if it wants, and liveness goes back to asking about steady
state, which is what it was for.

Same slow start, and RESTARTS is still zero. A slow start is no longer punished
with a restart.
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
[{len}, starts on its own]

Timur has fixed the start and is rolling out the production configuration: three
replicas, and /work doing a real query against RDS.

He has also made /healthz honest. It queries the database now, same as /work,
because a health check that checks nothing is not a health check.

Ruslan asks whether he is touching liveness. Why would he, it is green. Madina
points out that /healthz now reaches the database through the same pool as /work.
Pool of four, trivial query. Ship it.

[the diff, then the apply. Her card before it ships -- read the two answers off
it]

Liveness fails and kubelet kills the container: work in flight dies, the pool is
rebuilt, the cache is cold again. Readiness fails and the pod leaves the
EndpointSlice. That is all -- it keeps running and it comes back by itself.

A busy pod is not a dead pod. Slow is a readiness question. Liveness has one job:
notice a process that will never recover. Which makes timeoutSeconds one on
liveness a latency alarm wired to a kill switch.

[three replicas Ready, one per node. Click -- here comes the traffic]

The service is healthy. It is simply busy. The pool fills with real work and
/healthz joins the same queue. kubelet gets no answer, three times in a row, and
kills it.

Watch the RESTARTS column. Timur says it is alive, it is just busy. kubelet
cannot tell busy from dead, because it only owns a timer.

Liveness should ask whether the process is alive. It asked how fast it answers.

[the vote: who took down a healthy service -- Timur who copied the probe, Ruslan
who left liveness alone, or kubelet who pulled the trigger]

[do not answer it. Let the room argue]
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
[{len}, starts on its own]

Madina's answer is none of the three. It was the wrong question.

Liveness answers one thing, whether the process is alive, and you do not visit a
database for that. Give it a generous timeout and allow more misses. What takes a
busy pod out of rotation is readiness, and that one is allowed to be twitchy.

And /healthz goes back to local, so the check stops leaving the process. Whether
the database answers is a readiness question, and readiness already asks it.

[the diff, then the apply. Her card -- read what changed off it]

One question every ten seconds instead of five. Three seconds to answer instead
of one. Five misses instead of three. Fifty seconds of patience before a kill.

The list of what did not change is longer: not the code, not the traffic, not the
hardware, not the database, and not the readiness probe, which stays tight on
purpose, because taking a busy replica out of rotation is exactly its job.

[click -- same load, same service, same hardware]

Same three replicas, same three hundred requests a second, same column. This time
it should not move at all.

[the before-and-after table -- read the numbers off it, do not paraphrase]

p95 is the same as it was. The service did not get faster. It stopped shooting at
itself.

It asked whether the service was answering quickly, and punished the answer as if
it meant "are you dead". The load never changed. What took the service down was
the health check.
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
1 "The same failed check, routed through two different probes, costs two completely different things."

2 "Start from a healthy pod. Nothing is wrong with it."

3 "Liveness says no, and kubelet kills the container. Work in flight dies, the pool is rebuilt, the cache is cold. That is irreversible. The only thing liveness is for is noticing a process that will never recover on its own."

4 "Readiness says no, and the pod leaves the EndpointSlice. It keeps running, no traffic reaches it, and it comes back by itself. Reversible."

[before the last click] "So which of the two would you rather have answering that question?"

5 "Which makes timeoutSeconds: 1 on a liveness probe a latency alarm wired to a kill switch. The load never changed. What took the service down was the health check."
-->

---
layout: section
variant: 3
---

# Incident 2

## The probe that buys EC2 instances

<!--
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
1 "'Readiness should verify we can actually read our data.' Nobody argues with that sentence in a pull request. That is exactly the problem."

2 "Here it is."

3 "A readiness probe."

4 "It asks /ready, and /ready runs a real query against the database."

5 "Every two seconds. On every replica."

6 "Walk it left to right. Three replicas: one and a half scans a second, twelve connections. The database does not notice."

7 [pause here]

8 "The terminal will say sixty, because that is what max_connections is set to. RDS keeps six for itself, so fifty-four is what the application can have. And at twenty-four replicas the probe alone wants ninety-six."

9 "The probe that passed review is now a denial of service against the database it was checking."
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
1 "The probe asks the database. Every two seconds, on every replica."

2 "The database runs out of connections, the probe fails, and the replicas go NotReady."

3 "A NotReady worker stops consuming SQS."

4 "So the queue gets deeper."

5 "KEDA sees a deep queue and adds workers."

6 "The workers do not fit, so Karpenter buys nodes. That is the only step in this circle with a price tag."

7 "And every new worker starts asking the database the same question. The circle is closed."

[before the last click] "Nothing in this loop is broken. Every component is doing exactly what it was asked to do."

8 "Every turn adds connections to the database that is already the bottleneck, which makes the next turn worse. And one step in that circle is billed by the hour."
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
[{len}, starts on its own]

In the first incident a pod killed itself. In this one every replica leaves the
load balancer at once, and the autoscalers try to help.

[a month has passed]

Timur did not copy this one. He read the documentation and wrote it himself:
every readiness call goes to the database and checks the data is actually
readable.

Ruslan approves it -- it checks a real dependency, which is the right thing to
do. Madina says nothing. It passed review.

She said it three times in the first incident. This time she writes it down.

[her card -- read it out]

The Service routes to an EndpointSlice, and readiness is what puts an address in
it or takes it out. One pod NotReady, the rest carry the load. Every pod
NotReady, and the slice is empty: no error, no traffic, no pods.

So the blast radius is not one replica. It is every replica that shares whatever
the probe is asking about.

[the connection count]

Three replicas, twelve connections out of fifty-four. Postgres did not even wake
up. All green, zero incidents -- while there are three replicas.
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
[{len}, starts on its own]

Black Friday. The work arrives as a queue, which is what the whole system was
built for.

[the ScaledObject: min zero, max twenty-four, trigger SQS]

KEDA watches the queue. Zero workers right now, because there is nothing to do.
Then two thousand messages a second start going in.

[the card, while KEDA thinks -- read the three numbers off it]

It asks SQS how deep the queue is every five seconds. It tolerates twenty
messages per worker. And it will go to twenty-four workers, which is the ceiling
and the only thing stopping it. Desired workers is queue depth over twenty,
capped at twenty-four, and minReplicaCount is zero, so this scales up from
nothing at all.

Nothing in that formula knows why the queue is deep. A queue that grows because
the workers are stuck looks exactly like a queue that grows because there is a
lot of work.

KEDA adds workers. The workers do not fit, so Karpenter buys machines.

[the node list]

Queue depth up, workers up, nodes up. Watch the node counter -- that is the
number that costs money.

Ruslan says this is the system working, look at it scale. Madina says look at
what each new worker does before it processes anything.
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
[{len}, starts on its own]

Madina does the arithmetic out loud. Every replica opens its own pool, four
connections each, and every replica scans two million rows every two seconds,
because that is what its readiness probe does. Ruslan calls it a health check.
It is a health check multiplied by the replica count.

At three replicas it was a third of a core. KEDA is allowed twenty-four.

Twenty-four workers at four connections is ninety-six. Postgres has fifty-four,
and two vCPU which are now entirely ours.

[the connection states, then the worker logs: "too many connections"]

The pods are up and they are not Ready. And a worker that cannot reach the
database does not delete its message, so the message comes back and the queue
gets deeper. KEDA sees a deeper queue and adds workers. Postgres is refusing new
connections, and everyone who has one is holding it. Karpenter sees more Pending
pods and keeps buying, because nobody has told it to stop.

That is the loop.

[her card stays up while the numbers move -- read it out]

The probe asks the database, so the replicas go NotReady, so the workers stop
consuming. The queue depth grows, so KEDA adds workers, so more nodes are bought,
and every one of them starts asking the database the same question.

Every turn adds connections to the database that is already the bottleneck, which
makes the next turn worse. Nothing in the loop is broken. Every component is
doing exactly what it was asked. The only part of it with a price tag is the
bottom left.

Throughput at zero, and the nodes are still climbing. Watch the node count, not
the queue. A queue going up under load is expected. A node count going up while
nothing is being processed is the incident.

[the EndpointSlice]

No endpoints left in the Service. Not one.

Scaling did not save the service. Scaling is what took it down, and it bought
hardware to do it.

[the vote: raise maxReplicaCount, restart the database, or raise timeoutSeconds
on the probe]

[from the recording: this cut stops after the KEDA card, so narrate the cascade
off the loop slide instead]
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
[{len}, starts on its own]

The answer is none of the three. All three add work to the database, and the
database is where everyone is already stuck. The first one also buys more
machines.

Madina unhooks the probe from the database. A background goroutine does SELECT
one every two seconds with a timeout and stores the result in a flag, and the
probe reads the flag. That is all.

Timur asks what happens if the database really does go down. The flag goes stale
and the pod honestly leaves the load balancer. Ruslan asks whether that means all
twenty-four at once. One at a time, as each flag expires -- and the database gets
not one extra query.

The probe now costs the same whether there are twenty-four replicas or two
hundred and forty.

Two more things. The pool is budgeted against the wall: three connections, not
four. And KEDA gets a ceiling, because an autoscaler without one is a way to turn
an incident into an invoice.

[the diff, then the apply. Her card -- read the three parts off it]

One: the probe reads a flag, not the database, so the cost is O(1) in replicas
instead of O(n), and a stale flag still takes the pod out. Two: replicas times
POOL_MAX has to stay under max_connections, with room for everything else. Three:
maxReplicaCount is twelve, not twenty-four.

Only the first one is about probes. The other two decide how far the next mistake
gets before something stops it.

[click -- same queue, same database, same cluster]

Two things to watch while this runs. Every worker that comes up should go Ready
and stay Ready, and the node count should not move. The queue will not go down:
two thousand a second go in and twelve workers cannot outrun that.

[the connection count, then the before-and-after table -- read the numbers off it]

Forty-five connections, almost nothing active. Same load, same scale target,
different probe.

Twelve workers, twelve Ready. A minute ago there were twenty-four and next to
none of them served. Those twenty-four took messages and handed every one of them
back; these twelve finish what they take. One probe changed, nothing else did.

And nothing new was bought. Karpenter gives the idle machines back a couple of
minutes later. It was never the problem -- it did what it was asked.

Readiness means "can this pod serve", not "is the shared database alive".
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
1 "One: unhook the probe. A goroutine refreshes a flag on its own schedule, and the probe just reads the flag. O(1) in replicas instead of O(n) -- and a stale flag still takes the pod out, one at a time as each one expires."

2 "Two: budget the pool. replicas times POOL_MAX has to stay under max_connections, with room for everything else that connects to that database."

3 "Three: cap the autoscaler. Twelve, not twenty-four. An autoscaler without a ceiling is a way to turn an incident into an invoice."

[before the last click] "Only the first of those three is about probes. The other two decide how far the next mistake gets before something stops it."

4 "Twelve workers, twelve Ready, against twenty-four of which next to none served. One probe changed. Nothing else did."
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
1 "Liveness touches nothing else: not the database, not a cache, not a queue, not another process. And the arithmetic is written down -- initialDelay plus failureThreshold times period, against the slowest start you have ever seen, not the usual one."

2 "Anything slower than a few seconds gets a startupProbe, not a bigger initialDelaySeconds. And its budget is explicit. Two minutes is not extravagant."

3 "If you cannot say what a restart would fix, do not restart."

[photograph slide -- stop talking and let them]
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
1 "Readiness answers 'can this pod serve'. Never 'is the shared thing healthy'. If it has to know about a dependency, it reads a flag that something else refreshes."

2 "And two of these are not about probes at all. Every autoscaler has a ceiling. And a worker that cannot reach its dependency does not ack its message -- check that your retry path cannot feed your scaler. That is the one people forget."

3 "Probes are the only code that can kill a healthy service, and with an autoscaler underneath, bill you for it."
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
"Everything you just saw is in that repository: the checklist, the manifests with these numbers in them, and the driver that ran the show. The failures reproduce: task bootstrap, then ./demo."

[leave this slide on screen for questions]
-->
