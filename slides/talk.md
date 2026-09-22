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
"Good evening. I'm really happy to be there and thanks for inviting me :) This talk is about six lines in your YAML file."

"Almost everyone copies them from the service next door. Two of them can kill a healthy service and put the outage on your AWS bill."
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

2 "And I’m the co-host  and “named” CTO of DevOps Kitchen Talks podcast where we discuss DevOps topics and argue about AI 

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
"This is the terminal the whole talk lives in. A real cluster, a real database, and the failures are real too."

"On call today. Timur writes the backend. His service takes ten seconds to start. He copied his probe from a blog post, and it is green, so he thinks it is right."

"Ruslan runs the infrastructure. Every problem is a number in a YAML file, and that has always worked before today."

"Madina is the intern. She has read the documentation. Nobody asks her for a while."

CLICK CARRIES THE RECORDING ON
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
"Then the machines. kubelet does not read your code. It reads your manifest, and pulls the trigger."

"Postgres has two CPUs and fifty-four connections to give. KEDA adds workers when the queue is deep, and has no other ideas. Karpenter buys machines when pods do not fit. That one has a credit card."

"Seven of them, and the two that matter are not people."

CLICK MOVES ON
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
Before starting anything, let's try to do some recap about things we about the k8s about Probes.

1 "Something asks your container questions. It is not a load balancer. It is not a person."
"It is kubelet. It runs on every node. It asks every few seconds, forever, using numbers from your YAML."

2 "That one. It is the only thing in this talk that never changes how it behaves."

3 "Startup. Has it finished booting? While this one runs, nobody asks the other two."

4 "Liveness. Is the process alive? A wrong answer restarts the container, and the work it was doing dies with it."

5 "Readiness. Can it serve right now? A wrong answer only takes the pod out of the Service. It keeps running, and it comes back on its own."

6 [slowly] "Many things can take a container down. A crash. Out of memory. An eviction. A rollout."

"A probe is the only one that does it while the process is working fine."
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
1 "One queue. Two autoscalers, watching two different things. One database with a low connection limit."

2 "That is the network, and the cluster inside it."

3 "A request lands here."

4 "It goes on the queue."

5 "A worker picks it up."

6 "Both of them talk to the same Postgres. It allows sixty connections. RDS keeps six, so the app gets fifty-four."

"Remember that number."

7 "These two are watching. KEDA reads the queue. Karpenter buys machines for pods that do not fit."

"Neither of them knows why the queue is deep."

8 "The cluster is small on purpose, so you can see the node count grow on screen."


++ small instances + small nodes

[the no-NAT saving only if somebody asks about cost]
-->

---
layout: section
variant: 2
---

# Incident 1

## The probe that kills a healthy pod

<!--
"A service that takes ten seconds to start. A probe copied from an article. Nobody wrote a bug."
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
1 "Every number in YAML looks fine on its own."

2 "The service warms up for ten seconds. Keep that number. Everything else is measured against it."

3 "This is what was in the file."

4 "This is the whole probe."

5 "It asks /healthz over HTTP."

6 "Wait two seconds before the first question."

7 "Then ask again every second."

8 "An answer has one second to arrive."

9 "Three misses in a row, and the pod dies."

10 [pause here]

11 "Two seconds, plus three misses one second apart. Five seconds of patience."

"The service needs ten. So the pod will die on the fifth second, every time. There is no bug anywhere in the code."

12 "People fix this by making initialDelaySeconds bigger. That works until the day the start gets slower."

"A startupProbe is the real answer. It gives boot its own time, and while it runs nobody asks the other two."

"And timeoutSeconds is the part that hurts later. An answer at 1.1 seconds counts the same as no answer at all. A service answers slowly exactly when it is busy."
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
"Timur says the service is done. Ten seconds to start: it warms a cache and opens a pool. Ruslan asks about the probe."

CLICK CARRIES THE RECORDING ON
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
"He copied one out of an article. Madina asks for the numbers and starts adding them up, and Ruslan ships it before she finishes."

"The pod is Pending. There is nowhere to put it, so Karpenter goes shopping."

"Her card stays up for the whole wait. Two seconds before the first question. One second between questions. One second to answer. Three misses and the pod dies."

"Five seconds of patience against a ten second start."

CLICK CARRIES THE RECORDING ON
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
"kubelet knocks at two seconds. Timur says it is still warming up. That answer is not in the manifest."

"Watch the RESTARTS column. Nobody touched the code, and there is no traffic."

CLICK MOVES ON
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
"Ruslan has seen this a hundred times. One line fixes it: initialDelaySeconds goes from two to twelve. Twelve is more than ten, so he is done."

"Madina asks what happens if the start gets slower. Ruslan asks why it would."

CLICK CARRIES THE RECORDING ON
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
"Green. It works because nothing changed, not because the number is right."

"A week later Timur ships a feature. The catalogue is loaded once at boot now, not on every request. Requests got twice as fast, and boot pays for it: warmup goes from ten seconds to twenty."

CLICK CARRIES THE RECORDING ON
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
"Nobody touched the probe. The service grew under it. Patience runs out at fifteen seconds. The service is ready at twenty."

"A cold cache. A busy neighbour. More data. None of those touch your YAML, and every one of them moves the start."

CLICK CARRIES THE RECORDING ON
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
"Every other number in a probe reacts to something. This one only counts."

"Madina's answer is the startupProbe. While startup runs, nobody asks the other two. Boot gets its own time, two minutes if it wants, and liveness goes back to what it was for."

"Her card has the three questions on it. Has it finished booting. Is it alive. Can it serve right now. Three questions, three probes, and they are not interchangeable."

"Same slow start, and RESTARTS is still zero."

CLICK MOVES ON
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
"The start is fixed. Timur rolls out the production settings: three replicas, and real work against the database."

"He also makes /healthz honest. It queries the database now, like the real work does. A health check that checks nothing is not a health check."

"Madina points out that /healthz reaches the database through the same pool as the real work. A pool of four. They ship it."

"Her card is the difference. Liveness fails, the container is killed. Readiness fails, the pod only leaves the Service."

CLICK CARRIES THE RECORDING ON
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
"Three replicas Ready, one per node. A busy pod is not a dead pod, and slow is a readiness question."

CLICK CARRIES THE RECORDING ON
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
"The traffic arrives. The service is healthy, it is just busy. The pool fills with real work, and /healthz waits in the same line as everything else."

"kubelet gets no answer."

CLICK CARRIES THE RECORDING ON
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
"Three times in a row, and it kills the container. Watch the RESTARTS column."

"Timur says it is alive, just busy. kubelet cannot tell busy from dead, because all it has is a timer."

"Liveness should ask whether the process is alive. This one asked how fast it answers, and the load did the rest."

CLICK CARRIES THE RECORDING ON
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
"Here is what kubelet actually said. Liveness probe failed, three times, and then it killed it."

"The traffic never changed."

CLICK MOVES ON
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
"Madina says none of the three. It was the wrong question. Liveness answers one thing: is the process alive. Do not ask a database."

CLICK CARRIES THE RECORDING ON
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
"Give it more time to answer, and allow more misses. What takes a busy pod out of rotation is readiness, and that one is allowed to be nervous."

"And /healthz goes back to local, so the check never leaves the process."

CLICK CARRIES THE RECORDING ON
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
"One question every ten seconds instead of five. Three seconds to answer instead of one. Five misses instead of three. Fifty seconds of patience before a kill."

"The list of what did not change is longer. Not the code. Not the traffic. Not the machines. Not the database."

"And not the readiness probe, which stays quick on purpose. Taking a busy replica out of rotation is exactly its job."

"Same three replicas, same three hundred requests a second, same column. This time it should not move at all."

CLICK CARRIES THE RECORDING ON
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
"p95 is the same. The service did not get faster. It stopped shooting at itself."

"The traffic never changed. The health check took the service down."

CLICK MOVES ON
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
1 "The same failed check. Two different probes. Two very different prices."

2 "Start with a healthy pod. Nothing is wrong with it."

3 "Liveness says no, and kubelet kills the container. The work it was doing dies. The pool is rebuilt. The cache is cold again."

"You cannot undo that. Liveness is for one thing only: a process that will never recover on its own."

4 "Readiness says no, and the pod leaves the Service. It keeps running. No traffic reaches it. It comes back on its own."

"You can undo that."

[before the last click] "So which one would you rather have answering the question?"

5 "Which means timeoutSeconds one on liveness is a speed alarm wired to a kill switch."

"The traffic never changed. The health check took the service down."
-->

---
layout: section
variant: 3
---

# Incident 2

## The probe that buys EC2 instances

<!--
"This time Timur did everything right. He read the docs and wrote the probe himself."

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
1 "'Readiness should check that we can really read our data.' Nobody argues with that in a review."

"That is the problem."

2 "Here it is."

3 "A readiness probe."

4 "It asks /ready, and /ready runs a real query on the database."

5 "Every two seconds. On every replica."

6 "Read it left to right. Three replicas: one and a half scans a second, twelve connections. The database does not notice."

7 [pause here]

8 "The screen will say sixty, because that is the setting. RDS keeps six, so the app gets fifty-four."

"At twenty-four replicas the probe alone wants ninety-six."

9 "The probe that passed review is now attacking the database it was checking."
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

2 "The database runs out of connections. The probe fails. The replicas go NotReady."

3 "A NotReady worker stops taking messages."

4 "So the queue gets deeper."

5 "KEDA sees a deep queue and adds workers."

6 "The workers do not fit, so Karpenter buys nodes. That is the only step here with a price on it."

7 "And every new worker asks the database the same question. The circle is closed."

[before the last click] "Nothing here is broken. Every part is doing exactly what we asked it to do."

8 "Every turn adds connections to the database that is already the slow part, and makes the next turn worse."

"And one step in that circle is paid by the hour."
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
"A month later. Timur did not copy this one. He read the docs and wrote it himself: every readiness call queries the database to check the data is really there."

"Ruslan approves it, because it checks something real."

CLICK CARRIES THE RECORDING ON
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
"Madina says nothing. It passed review. She said it out loud three times in the first story. This time she writes it down."

"The Service does not send traffic to pods. It sends it to a list of addresses, and readiness puts a pod on that list or takes it off."

"One pod NotReady, and the rest carry the load. Every pod NotReady, and the list is empty. No error, no traffic."

"A readiness probe does not break one replica. It breaks every replica asking the same question."

CLICK CARRIES THE RECORDING ON
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
"Three replicas, twelve connections out of fifty-four. Postgres did not even wake up. All green, while there are three replicas."

CLICK MOVES ON
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
"Black Friday. The work arrives as a queue, which is what this system was built for. KEDA is watching it, with zero workers."

CLICK CARRIES THE RECORDING ON
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
"Then two thousand messages a second start going in."

"Her card has the three numbers KEDA works from. It asks the queue how deep it is every five seconds. It allows twenty messages per worker. And it will go up to twenty-four workers, which is the limit and the only thing stopping it."

"Nothing in that formula knows why the queue is deep. A queue that grows because the workers are stuck looks exactly like a queue that grows because there is work."

CLICK CARRIES THE RECORDING ON
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
"KEDA adds workers. The workers do not fit, so Karpenter buys machines."

"Watch the node counter on the right. Queue up, workers up, nodes up. That is the number that costs money, and it is the only step in this circle with a price on it."

"Ruslan says this is the system working. Look at it scale."

CLICK CARRIES THE RECORDING ON
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
"Madina says look at what each new worker does before it processes anything. Every one of them opens a pool, and every one of them asks the database the same question the probe asks."

CLICK MOVES ON
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
"So they ask the database. Every replica opens its own pool, four connections each, and scans two million rows every two seconds, because that is what its readiness probe does."

"Ruslan calls it a health check. It is a health check times the number of replicas."

CLICK CARRIES THE RECORDING ON
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
"With three replicas it was a third of a CPU. KEDA is allowed twenty-four. Twenty-four workers at four connections is ninety-six. Postgres has fifty-four, and two CPUs, and they are all ours now."

"The worker logs say it plainly. Too many connections. The remaining slots are reserved for somebody else."

"The pods are up, and they are not Ready. A worker that cannot reach the database never tells the queue it is done, so the message comes back and the queue gets deeper."

CLICK CARRIES THE RECORDING ON
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
"KEDA sees a deeper queue and adds workers. Postgres is refusing new connections now, and everyone who has one is holding it. Karpenter sees more pods that do not fit and keeps buying, because nobody told it to stop."

"That is the loop, and it is on the screen now."

"The probe asks the database, so the replicas go NotReady, so the workers stop taking messages. The queue gets deeper, so KEDA adds workers, so more nodes are bought. And every new one asks the database the same question."

"Every turn adds connections to the database that is already the slow part, and makes the next turn worse."

"Nothing here is broken. Every part is doing exactly what we asked it to do. The probe checks the data. KEDA drains the queue. Karpenter finds room for pods. Not one of them is wrong on its own."

"Watch the node count, not the queue. A queue going up under load is normal. A node count going up while nothing is processed at all is the incident."

"Throughput is zero. The nodes are still going up, and the bill goes up with them."

CLICK CARRIES THE RECORDING ON
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
"And here is the Service. No addresses left in it. Not one."

"Scaling did not save the service. Scaling took it down, and it bought hardware to do it."

"So the vote. Raise the worker limit, restart the database, or give the probe more time."

CLICK MOVES ON
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
"None of the three. All of them add work to the database, and the database is where everyone is already stuck. The first one also buys more machines."

"Madina takes the probe off the database instead."

CLICK CARRIES THE RECORDING ON
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
"A small background job asks the database a simple question every two seconds and saves the answer in a flag. The probe reads the flag. That is all."

"If the database really does go down, the flag goes old and the pod leaves the load balancer. Not all twenty-four at once: one at a time, as each flag expires."

"The probe now costs the same with twenty-four replicas or two hundred and forty."

"Two more things The pool is three connections instead of four, so the total stays under the limit. And KEDA gets a ceiling."

CLICK CARRIES THE RECORDING ON
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
"Only the first of the three is about probes. The other two decide how far the next mistake goes before something stops it."

"Same queue, same database, same cluster. Two things to watch. Every worker should go Ready and stay Ready, and the node count should not move."

CLICK CARRIES THE RECORDING ON
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
"Twelve workers, twelve Ready. A minute ago there were twenty-four, and almost none of them served."

"The queue will not go down. Two thousand a second go in, and twelve workers cannot beat that. Watch the other two numbers instead."

"Those twenty-four took messages and handed every one of them back. These twelve finish what they take."

"And nothing new was bought. The node count has not moved. Karpenter gives the idle machines back a few minutes later. It was never the problem: it did exactly what we asked."

"One probe changed. Not the code, not the traffic, not the database, not the machines."

CLICK CARRIES THE RECORDING ON
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
"Forty-five connections, and almost nothing active. Same load, same target, different probe."

"That is the whole of incident two, and the fix was six lines of YAML and one small background job."

"Readiness means: can this pod serve. Not: is the shared database alive."

CLICK MOVES ON
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
1 "One. Take the probe off the database. A small background job checks the database on its own and saves the answer in a flag. The probe reads the flag."

"Now the cost is the same with twenty-four replicas or two hundred. And if the flag goes old, the pod still leaves the Service, one at a time."

2 "Two. Keep the pool small enough. Replicas times POOL_MAX must stay under the connection limit, with room for everything else."

3 "Three. Give the autoscaler a limit. Twelve, not twenty-four. An autoscaler with no limit turns an incident into a bill."

[before the last click] "Only the first one is about probes. The other two decide how far the next mistake goes before something stops it."

4 "Twelve workers, twelve Ready. A minute ago there were twenty-four, and almost none of them served. One probe changed."
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
1 "Liveness touches nothing else. Not the database, not a cache, not a queue, not another process."

"And write the maths down. initialDelay plus failureThreshold times period, against the slowest start you have ever seen. Not the usual one."

2 "Anything slower than a few seconds gets a startupProbe, not a bigger initialDelaySeconds. Give it a clear budget. Two minutes is not too much."

3 "If you cannot say what a restart would fix, do not restart."

[photograph slide. Stop talking and let them]
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
1 "Readiness answers one question: can this pod serve? Never: is the shared thing healthy?"

"If it needs to know about something else, let it read a flag that another job keeps up to date."

2 "Two of these are not about probes at all. Every autoscaler needs a limit."

"And a worker that cannot reach its database does not tell the queue it is done. Check that your retry path cannot feed your autoscaler. People forget that one."

3 "Probes are the only code that can kill a healthy service. With an autoscaler under it, they also send you the bill."
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
"Everything you saw is in that repository. The checklist, the YAML with these numbers in it, and the tool that ran the show."

"The failures run again: task bootstrap, then ./demo."

[leave this on screen for questions]
-->
