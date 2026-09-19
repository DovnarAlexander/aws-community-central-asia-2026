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
"Good morning. This talk is about six lines in your YAML file."

"Almost everyone copies them from the service next door. Two of them can kill a healthy service and put the outage on your AWS bill."

"Two stories. Both of them really ran on a real cluster. The pods die because the numbers say they should."

[if the cluster is down, say it now and play the recordings]
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

[the boot, then the title card]

[the cast arrives one at a time. Introduce them as they land]

"Timur writes the backend. His service takes ten seconds to start. He copied his probe from a blog post, and it is green, so he thinks it is right."

"Ruslan runs the infrastructure. For him every problem is a number in a YAML file. That has always worked before today."

"Madina is the intern. She has read the docs. Nobody asks her for a while."

"Then the machines. kubelet does not read your code. It reads your YAML and pulls the trigger."

"Postgres has two CPUs and fifty-four connections to give."

"KEDA adds workers when the queue is deep. It has no other ideas."

"And Karpenter buys machines when pods do not fit. That one has a credit card."

[click for the card]

"Seven of them. The two that matter are not people."

[do not skip this slide. Madina unhooks the probe later, and that does not land on a room that has never met her]
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
1 "Every number here looks fine on its own."

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

"The service needs ten. So the pod dies on the fifth second, every time. There is no bug anywhere."

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
    <Cast src="/casts/full.cast" step="1.1" fit="both" />
  </div>
</div>

<!--
[{len}, starts on its own]

"Timur says the service is ready. Ten seconds to start: it warms a cache and opens a pool."

"Ruslan asks if he has a probe. He copied one from an article, it was right there in the example."

"Madina asks for the numbers. She is still adding them up when Ruslan ships it."

[the YAML, then the apply. The pod is Pending, so Karpenter goes shopping]

[Madina's card stays up for the whole wait. Read the four numbers off it]

"Two seconds before the first question. One second between questions. One second to answer. Three misses and the pod dies."

"That is five seconds of patience against a ten second start."

"And kubelet is the one asking. Not a load balancer, not a person, not your code."

[the node arrives, the pod starts]

"kubelet knocks at two seconds. Timur says it is still warming up. That answer is not in the YAML."

"Count with me. Watch the RESTARTS column."

"Nobody touched the code. There is no traffic yet. Simple maths killed the pod."
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

"Ruslan has seen this a hundred times. One line fixes it: the one with the number in it."

"initialDelaySeconds goes from two to twelve. Twelve is more than ten, so he is done."

"Madina asks what happens if the start gets slower. Ruslan asks why it would."

[the apply, and the pod comes up green]

"It works. Madina's point is that it works because nothing changed, not because the number is right."

[click. A week passes, and Timur ships a feature]

"The catalogue is loaded once at boot now, instead of on every request. Requests got twice as fast, and boot pays for it."

"Warmup goes from ten seconds to twenty."

"Nobody touched the probe. The service grew under it."

"Two numbers are racing. Patience runs out at fifteen seconds. The service is ready at twenty."

"Same YAML, slower machine. initialDelaySeconds is a bet that tomorrow looks like today."

"A cold cache. A busy neighbour. More data. One more step at boot. None of those touch your YAML, and every one of them moves the start."

"Every other number in a probe reacts to something. This one only counts."

"Madina's answer is the startupProbe. She read all the docs."

[the diff, then the apply. Her card. Read the three questions off it]

"While startup runs, nobody asks the other two. Boot gets its own time, two minutes if it wants."

"And liveness goes back to what it was for."

"Same slow start, and RESTARTS is still zero."
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

"The start is fixed. Now Timur rolls out the production settings: three replicas, and real work against the database."

"He also makes /healthz honest. It queries the database now, same as the real work. A health check that checks nothing is not a health check."

"Ruslan asks if he is touching liveness. Why would he, it is green."

"Madina points out that /healthz now reaches the database through the same pool as the real work. Pool of four, small query. Ship it."

[the diff, then the apply. Her card before it ships. Read the two answers off it]

"Liveness fails, and kubelet kills the container. The work dies. The pool is rebuilt. The cache is cold again."

"Readiness fails, and the pod just leaves the Service. It keeps running and comes back on its own."

"A busy pod is not a dead pod. Slow is a readiness question."

"Liveness has one job: spot a process that will never recover."

[three replicas Ready, one per node. Click, and the traffic arrives]

"The service is healthy. It is just busy."

"The pool fills with real work, and /healthz waits in the same line."

"kubelet gets no answer. Three times. It kills it."

"Watch the RESTARTS column. Timur says it is alive, just busy. kubelet cannot tell busy from dead, because all it has is a timer."

"Liveness should ask if the process is alive. It asked how fast it answers."

[the vote. Timur who copied the probe, Ruslan who left liveness alone, or kubelet who pulled the trigger]

[do not answer it. Let them argue]
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

"Madina says none of the three. It was the wrong question."

"Liveness answers one thing: is the process alive. You do not go to a database for that."

"Give it more time to answer and allow more misses."

"What takes a busy pod out of rotation is readiness, and that one is allowed to be nervous."

"And /healthz goes back to local, so the check never leaves the process. Whether the database answers is a readiness question, and readiness already asks it."

[the diff, then the apply. Her card. Read what changed off it]

"One question every ten seconds instead of five. Three seconds to answer instead of one. Five misses instead of three."

"Fifty seconds of patience before a kill."

"The list of what did not change is longer. Not the code. Not the traffic. Not the machines. Not the database."

"And not the readiness probe, which stays quick on purpose. Taking a busy replica out of rotation is exactly its job."

[click. Same load, same service, same machines]

"Same three replicas, same three hundred requests a second, same column. This time it should not move at all."

[the before and after table. read the numbers, do not use your own words]

"p95 is the same as before. The service did not get faster. It stopped shooting at itself."

"The traffic never changed. The health check took the service down."
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
    <Cast src="/casts/full.cast" step="2.1" fit="both" />
  </div>
</div>

<!--
[{len}, starts on its own]

"In the first story one pod killed itself. In this one every replica leaves the load balancer at once, and the autoscalers try to help."

[a month has passed]

"Timur did not copy this one. He read the docs and wrote it himself. Every readiness call queries the database to check the data is really there."

"Ruslan approves it. It checks something real, which is the right thing to do."

"Madina says nothing. It passed review."

"She said it out loud three times in the first story. This time she writes it down."

[her card. Read it out]

"The Service does not send traffic to pods. It sends it to a list of addresses, and readiness puts a pod on that list or takes it off."

"One pod NotReady, and the rest carry the load. Every pod NotReady, and the list is empty. No error, no traffic, no pods."

"So a readiness probe does not break one replica. It breaks every replica asking the same question."

[the connection count]

"Three replicas, twelve connections out of fifty-four. Postgres did not even wake up."

"All green, no incidents. While there are three replicas."
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

"Black Friday. The work arrives as a queue, which is what this system was built for."

[the KEDA config: min zero, max twenty-four, watching the queue]

"KEDA watches the queue. Zero workers right now, because there is nothing to do."

"Then two thousand messages a second start going in."

[the card, while KEDA thinks. Read the three numbers off it]

"It asks the queue how deep it is every five seconds. It allows twenty messages per worker. And it will go up to twenty-four workers, which is the limit and the only thing stopping it."

"It starts from zero workers, so it scales up from nothing."

"Nothing in that formula knows why the queue is deep."

"A queue that grows because the workers are stuck looks exactly like a queue that grows because there is a lot of work."

"KEDA adds workers. The workers do not fit, so Karpenter buys machines."

[the node list]

"Queue up, workers up, nodes up. Watch the node counter. That is the number that costs money."

"Ruslan says this is the system working. Look at it scale."

"Madina says look at what each new worker does before it processes anything."
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

"Madina does the maths out loud."

"Every replica opens its own pool, four connections each. And every replica scans two million rows every two seconds, because that is what its readiness probe does."

"Ruslan calls it a health check. It is a health check times the number of replicas."

"With three replicas it was a third of a CPU. KEDA is allowed twenty-four."

"Twenty-four workers at four connections is ninety-six. Postgres has fifty-four, and two CPUs, and they are all ours now."

[the connection states, then the worker logs: too many connections]

"The pods are up, and they are not Ready."

"A worker that cannot reach the database does not tell the queue it is done. So the message comes back, and the queue gets deeper."

"KEDA sees a deeper queue and adds workers."

"Postgres is refusing new connections now. Everyone who has one is holding it."

"Karpenter sees more pods that do not fit and keeps buying, because nobody told it to stop."

"That is the loop."

[her card stays up while the numbers move. Read it out]

"The probe asks the database, so the replicas go NotReady, so the workers stop taking messages."

"The queue gets deeper, so KEDA adds workers, so more nodes are bought. And every one of them asks the database the same question."

"Every turn adds connections to the database that is already the slow part, and makes the next turn worse."

"Nothing here is broken. Every part is doing exactly what we asked it to do."

"The only step with a price on it is the bottom left."

"Throughput is zero, and the nodes are still going up."

"Watch the node count, not the queue. A queue going up under load is normal. A node count going up while nothing is processed is the incident."

[the endpoint list]

"No addresses left in the Service. Not one."

"Scaling did not save the service. Scaling took it down, and it bought hardware to do it."

[the vote: raise the worker limit, restart the database, or give the probe more time]

[this cut stops after the KEDA card, so tell the rest off the loop slide]
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

"None of the three. All of them add work to the database, and the database is where everyone is already stuck. The first one also buys more machines."

"Madina takes the probe off the database."

"A small background job asks the database a simple question every two seconds and saves the answer in a flag. The probe reads the flag. That is all."

"Timur asks what happens if the database really does go down. The flag goes old, and the pod honestly leaves the load balancer."

"Ruslan asks if that means all twenty-four at once. No: one at a time, as each flag expires. And the database gets no extra queries at all."

"The probe now costs the same with twenty-four replicas or two hundred and forty."

"Two more things. The pool is now three connections, not four, so the total stays under the limit."

"And KEDA gets a ceiling. An autoscaler without one turns an incident into a bill."

[the diff, then the apply. Her card. Read the three parts off it]

"One: the probe reads a flag, not the database. Same cost with any number of replicas, and an old flag still takes the pod out."

"Two: replicas times pool size must stay under the connection limit, with room for everything else."

"Three: the worker limit is twelve, not twenty-four."

"Only the first one is about probes. The other two decide how far the next mistake goes before something stops it."

[click. Same queue, same database, same cluster]

"Two things to watch. Every worker that comes up should go Ready and stay Ready. And the node count should not move."

"The queue will not go down. Two thousand a second go in, and twelve workers cannot beat that. Watch the other two numbers."

[the connection count, then the before and after table. Read the numbers off it]

"Forty-five connections, almost nothing active. Same load, same target, different probe."

"Twelve workers, twelve Ready. A minute ago there were twenty-four and almost none of them served."

"Those twenty-four took messages and handed every one of them back. These twelve finish what they take."

"One probe changed. Nothing else did."

"And nothing new was bought. Karpenter gives the idle machines back a few minutes later. It was never the problem. It did what we asked."

"Readiness means: can this pod serve. Not: is the shared database alive."
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
