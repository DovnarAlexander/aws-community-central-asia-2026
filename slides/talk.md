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
[{len}, starts on its own. Everything below is on the screen -- read it, do not summarise it]

"Reaching the cluster. Waking the database. Calling the developer. Calling the DevOps. Hiring an intern."

"THE PROBE THAT KILLED ITSELF. A real cluster, a real database, real failures. Nothing is recorded -- including the parts that go wrong."

"On call.

Timur, backend: 'I wrote the service. It takes ten seconds to start: warms a cache, opens a pool. The probe I copied from a blog post. It is green, so it is correct.'

Ruslan, DevOps: 'Any production problem is a number in a YAML file. The method works. It has never failed me before today.'

Madina, intern: 'I read the documentation.' -- and nobody asks her opinion for a while.

kubelet, the executioner: 'I do not read your code. I read your manifest, and then I pull the trigger.'

Postgres, the database: 'Two vCPU, fifty-four connections you may have, and a great deal of patience.'

KEDA, the pod autoscaler: 'The queue is deep, so I will add workers.' It has no other ideas.

Karpenter, the node autoscaler: 'Pods are Pending, so I will buy machines.' This one has a credit card.

Any resemblance to your team is coincidental. Probably."

[click for the card]

"What this talk is about. Every container you run has something asking it questions. Not a load balancer, not a human: kubelet, every few seconds, forever, using numbers out of your manifest.

Startup: has it finished booting? Liveness: is it alive -- and a wrong answer restarts it. Readiness: can it serve -- and a wrong answer unplugs it.

Of everything that can take a container down -- a crash, an OOM, an eviction, a rollout -- a probe is the only one that does it while the process is working perfectly well."

"Two incidents. Both times the service was killed by a check, not by traffic."

[do not skip it -- "Madina unhooks the probe" later does not land on a room that has never met her]
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
[{len}, starts on its own. Read the screen; the lines below are all of it]

Timur: "Service is done. Takes ten seconds to start: warms a cache, opens a pool, reads config. After that it flies."
Ruslan: "Got a probe?"
Timur: "Copied one out of an article. It was right there in the example."
Madina: "What are the numbers?"
Timur: "initialDelay two, period one, timeout one, three misses. Straight out of the example."
Madina: "Two, plus three misses a second apart, is..."
Ruslan: "Ship it."

[the manifest, then the apply]

"The pod is Pending. There is nowhere to put it, so Karpenter goes shopping."
Karpenter: "One pod with nowhere to go. Buying a machine."

Madina: "While we wait. This is what those four numbers Timur read out actually do."
Ruslan: "Nobody asked."

[her card, up for the whole wait -- read it out]
"A liveness probe, in four numbers. initialDelaySeconds two: wait this long before the first question. periodSeconds one: then ask again this often. timeoutSeconds one: an answer slower than this is a miss. failureThreshold three: this many misses in a row and the pod dies.

Patience equals initialDelay plus failureThreshold times period. Five seconds. The service needs ten. Nothing else here is a bug.

And kubelet is the one asking. Not a load balancer, not a human, not your code."

[the node arrives, the pod is scheduled]

kubelet: "Two seconds gone. Asking: are you alive?"
Timur: "It is warming up."
kubelet: "That answer is not in the manifest."

"The warmup runs ten seconds. The first knock lands at two. Count along. Watch the RESTARTS column."

kubelet: "Three misses in a row. Killing it."
Timur: "I did not write a single bug!"
kubelet: "I do not read your code. I read your manifest."

"Nobody touched the code and there is no traffic yet. Arithmetic killed the pod."
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
[{len}, starts on its own. Read the screen; the lines below are all of it]

Ruslan: "CrashLoop? Seen it a hundred times. One line fixes it."
Timur: "Which one?"
Ruslan: "The one with the number in it."

[the diff: initialDelaySeconds two becomes twelve]

Ruslan: "Twelve is bigger than ten. We are done here."
Madina: "What if the start gets slower?"
Ruslan: "Why would it?"

[the apply]

Madina: "It holds because nothing changed. Not because the number is right."
Ruslan: "It holds because the number is right."

[the pod comes up green]

Ruslan: "Green. Told you."

[click -- a week passes, Timur ships a feature]

Timur: "Catalogue is preloaded now. /work used to fetch it on every request; it reads it once at boot instead."
Ruslan: "Requests got faster, then."
Timur: "Twice as fast. Boot pays for it."
Timur: "WARMUP_SECONDS, ten to twenty. One more thing to do before the port opens. I did not go near the probe."
Ruslan: "I did not touch the probe either."
Madina: "Nobody did. The service grew underneath it."
kubelet: "Twelve seconds gone. Asking: are you alive?"

"Two numbers are racing. Patience runs out at fifteen seconds. The service is ready at twenty. Same manifest, slower environment."

"initialDelaySeconds is a bet that tomorrow looks like today."

Ruslan: "...You did ask what happens if the start gets slower."
Madina: "I did. A cold cache. A noisier neighbour. A bigger dataset. One more step at boot. None of those touch the manifest, and every one of them moves the start."
Madina: "Every other number in a probe reacts to something the process did. This one only counts. It cannot tell a slow start from a dead process, because it is not looking."

Madina: "May I? The documentation has a startupProbe."
Ruslan: "You read the documentation?"
Madina: "All of it."
Ruslan: "..."
Madina: "Until startup says ready, liveness and readiness are not consulted at all."
Timur: "So the start gets its own time budget?"
Madina: "Its own. Two minutes if it wants. It does not affect the liveness period. And liveness goes back to what it was for: the initialDelay comes out, the period goes back to five."
Madina: "The twenty is not mine, by the way. Timur put it on the cluster a minute ago and the file still said ten, so applying it would have quietly made the service fast again."

[the diff, then the apply]

Madina: "The whole of it is one page. Here."

[her card -- read it out]
"Three probes, three questions. startup: has it finished booting? liveness: is the process alive -- and the answer restarts the container. readiness: can it serve right now -- and the answer takes it out of the load balancer.

While startup runs, the other two are not consulted at all. Its budget is its own: failureThreshold times period, sixty times two, a hundred and twenty seconds. Once it passes it is never consulted again.

So boot gets a deadline, and liveness goes back to asking about steady state, which is what it was for."

"Same slow start, and RESTARTS is still zero."
kubelet: "I was told to wait, so I waited. Nobody told me before."

"A slow start is no longer punished with a restart."
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
[{len}, starts on its own. Read the screen; the lines below are all of it]

Timur: "Start is fixed. Rolling out the production configuration. Three replicas, and /work doing a real query against RDS."
Timur: "And I made /healthz honest: HEALTHZ_MODE, local to db. It queries the database now, same as /work. A health check that checks nothing is not a health check."
Ruslan: "Touching liveness?"
Timur: "Why? It is green."
Madina: "It goes to the database through the same pool as /work."
Ruslan: "Pool of four, the query is trivial. Ship it."

[the diff, then the apply]

Madina: "Before it ships. These two are not the same question."
Ruslan: "It is green, Madina."

[her card -- read it out]
"Restart or remove: two very different answers. Liveness fails, and kubelet kills the container: work in flight dies, the pool is rebuilt, the cache is cold again. Readiness fails, and the pod leaves the EndpointSlice. That is all. It keeps running, and it comes back by itself.

A busy pod is not a dead pod. Slow is a readiness question. Liveness has one job: notice a process that will never recover.

Which makes timeoutSeconds one on liveness a latency alarm wired to a kill switch."

[three replicas Ready, one per node]

[click -- here comes the traffic. "The service is healthy. It is simply busy."]

"The pool is full of real work, and /healthz joins the same queue."
kubelet: "A second gone, no answer. Again. And again."
kubelet: "Three misses. Killing it."

"Watch the RESTARTS column -- liveness cannot meet timeoutSeconds one."

[the Unhealthy events]

Timur: "It is alive! It is just busy!"
kubelet: "I cannot tell busy from dead. I only own a timer."

"Liveness should ask whether the process is alive. It asked how fast it answers."

[the vote] "Who took down a healthy service? Timur, who copied a probe out of an article. Ruslan, who tuned numbers and left liveness alone. Or kubelet, who pulled the trigger."

[do not answer it -- let the room argue]
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
[{len}, starts on its own. Read the screen; the lines below are all of it]

Madina: "None of the three. It was the wrong question."
Ruslan: "Meaning?"
Madina: "Liveness answers one thing: is the process alive. You do not visit a database for that. And do not rush it: generous timeout, more misses allowed."
Timur: "Then what takes a busy pod out of rotation?"
Madina: "Readiness. That one is allowed to be twitchy."
Ruslan: "One probe softer, the other sharper. Fine."
Madina: "And HEALTHZ_MODE goes back to local -- /healthz stops leaving the process. Whether the database answers is a readiness question, and readiness already asks it."

[the diff, then the apply]

Madina: "Two changes. And the list of what I did not touch, which is longer."

[her card -- read it out]
"What changed, and what did not. HEALTHZ_MODE local: the check no longer leaves the process. period ten: one question every ten seconds, not five. timeout three: three seconds to answer, not one. failureThreshold five: fifty seconds of patience before a kill.

Not changed: the code, the traffic, the hardware, the database, the readiness probe -- which stays tight on purpose, because taking a busy replica out of rotation is exactly its job.

If you cannot say what a restart would fix, do not restart."

[click -- same load, same service, same hardware]

Madina: "Same three replicas, same three hundred requests a second, same column. This time it should not move at all."

"RESTARTS should stay at zero."

[the before-and-after table -- read the numbers off it, do not paraphrase]

Ruslan: "p95 is the same as it was."
Madina: "The service did not get faster. It stopped shooting at itself."

"It asked 'are you answering quickly' and punished the answer as if it meant 'are you dead'."

"The load never changed. What took the service down was the health check."
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
[{len}, starts on its own. Read the screen; the lines below are all of it]

"In the first incident a pod killed itself. In this one every replica leaves the load balancer at once, and the autoscalers try to help."

"A month has passed."

Timur: "I did not copy this one. I read the documentation and wrote it myself. Readiness is honest now: every call goes to the database and checks the data is actually readable."
Timur: "READY_MODE, cached to db_each_call. The probe used to read a cached flag. Now every /ready call does a real query, so a green pod means the database answered."
Ruslan: "LGTM. It checks a real dependency. That is the right thing to do."
Madina: "..."
Ruslan: "Madina?"
Madina: "Nothing. It passed review."

[the diff, then the apply]

"She said it out loud three times in the first incident. This time she writes it down."

[her card -- read it out]
"How a readiness failure actually removes a pod. The Service does not route to pods. It routes to an EndpointSlice, and readiness is what puts an address in it or takes it out.

One pod NotReady: its address is removed, and the rest carry the load. Every pod NotReady: the slice is empty and the Service has nowhere to send anything. No error, no traffic, no pods.

So the blast radius of a readiness probe is not one replica. It is every replica that shares whatever the probe is asking about."

"Three replicas, probing every two seconds. One and a half scans per second."

[the connection count]

Postgres: "Twelve connections out of fifty-four. I did not even wake up."
Ruslan: "All green. Zero incidents."
Madina: "While there are three replicas, yes."
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
[{len}, starts on its own. Read the screen; the lines below are all of it]

"Black Friday. The work arrives as a queue, which is what the whole system was built for."

[the ScaledObject: min zero, max twenty-four, trigger SQS]

"KEDA watches the queue. Zero workers right now, because there is nothing to do."

"Filling the queue: two thousand messages a second going in."

[the card, while KEDA thinks -- read it out]
"KEDA, and what it is counting. pollingInterval five: it asks SQS how deep the queue is. queueLength twenty: messages per worker it is willing to tolerate. maxReplicaCount twenty-four: the ceiling, and the only thing stopping it.

Desired workers equals queue depth over twenty, capped at twenty-four. minReplicaCount is zero, so this scales up from nothing at all.

Nothing in that formula knows why the queue is deep. A queue that grows because the workers are stuck looks exactly like a queue that grows because there is a lot of work."

KEDA: "Queue is deep. Adding workers."
Karpenter: "Pods are Pending. Buying machines."

"Queue depth up, workers up, nodes up. Watch the node counter -- that is the number that costs money."

[the node list]

Ruslan: "This is the system working. Look at it scale."
Madina: "Look at what each new worker does before it processes anything."

[from the recording: this cut is short and the scale-up is not in it -- see docs/RUNBOOK.md]
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
[{len}, starts on its own. Read the screen; the lines below are all of it]

Madina: "Every replica opens its own pool. Four connections each. And every replica scans two million rows every two seconds, because that is what its readiness probe does."
Ruslan: "That is a health check."
Madina: "That is a health check multiplied by the replica count."

"At three replicas it was a third of a core. KEDA is allowed twenty-four."

Postgres: "Twenty-four workers at four connections is ninety-six. I have fifty-four. And two vCPU, which are now entirely yours."

[the connection states, then the worker logs: "too many connections"]

Timur: "'too many connections'. The pods are up and they are not Ready."
Madina: "And a worker that cannot reach the database does not delete its message. The message comes back. The queue gets deeper."
KEDA: "Queue is deeper. Adding workers."
Postgres: "I am refusing new connections now. Everyone who has one is holding it."
Karpenter: "More Pending pods. Buying. Nobody has told me to stop."
Madina: "That is the loop."

[her card, and it stays up while the numbers move -- read it out]
"The loop. The probe asks the database, so the replicas go NotReady, so the workers stop consuming. The queue depth grows, so KEDA adds workers, so more nodes are bought -- and every one of them starts asking the database the same question.

Every turn adds connections to the database that is already the bottleneck, which makes the next turn worse. Nothing in the loop is broken. Every component is doing exactly what it was asked.

The only part of it with a price tag is the bottom left."

"Throughput at zero, nodes still climbing. Watch the node count, not the queue -- a queue going up under load is expected; a node count going up while nothing is processed is the incident."

[the EndpointSlice]

Timur: "No endpoints left in the Service. Not one."

"Scaling did not save the service. Scaling is what took it down, and it bought hardware to do it."

[the vote] "What do you do first? Raise maxReplicaCount -- there are clearly not enough workers. Restart the database -- it is slow. Or raise timeoutSeconds on the probe -- let it wait."

[from the recording: this cut stops after the KEDA card, so narrate the cascade off the loop slide instead]
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
[{len}, starts on its own. Read the screen; the lines below are all of it]

"The answer: none of the three. All three add work to the database, and the database is where everyone is already stuck. The first one also buys more machines."

Madina: "Unhook the probe from the database. A background goroutine does SELECT 1 every two seconds with a timeout and stores the result in a flag. The probe reads the flag. That is all."
Timur: "And if the database really does go down?"
Madina: "The flag goes stale and the pod honestly leaves the load balancer."
Ruslan: "All twenty-four at once?"
Madina: "One at a time, as each flag expires. And the database gets not one extra query."

"The probe now costs O(1). Twenty-four replicas or two hundred and forty, it is the same."

Madina: "Two more things. The pool is budgeted against the wall: three connections, not four. And KEDA gets a ceiling. An autoscaler without one is a way to turn an incident into an invoice."
Madina: "READY_MODE, db_each_call back to cached: a goroutine does SELECT 1 on its own schedule and stores the answer, so the cost stops multiplying by replicas. And POOL_MAX, four to three -- the pool is budgeted against max_connections rather than against nothing."

[the diff, then the apply]

[her card -- read it out]
"The fix, in three parts. One: the probe reads a flag, not the database. A goroutine refreshes the flag on its own schedule, so the cost is O(1) in replicas instead of O(n) -- and a stale flag still takes the pod out.

Two: the pool is budgeted against the wall. replicas times POOL_MAX has to stay under max_connections, with room for everything else.

Three: maxReplicaCount is twelve, not twenty-four. An autoscaler without a ceiling is a way to turn an incident into an invoice.

Only the first one is about probes. The other two decide how far the next mistake gets before something stops it."

[click -- same queue, same database, same cluster]

Madina: "Two things, while this runs. The workers column, and the node count. Every worker that comes up should go Ready and stay Ready. And the node count should not move."

"The queue will not go down: two thousand a second go in, and twelve workers cannot outrun that. Watch the other two numbers."

[the connection count]

Postgres: "Forty-five connections, almost nothing active. Carry on."

[the before-and-after table -- read the numbers off it]

Ruslan: "Same load. Same scale target."
Madina: "Different probe."
Madina: "Twelve workers. Twelve Ready. A minute ago there were twenty-four and next to none of them served."
Timur: "So we are still behind."
Madina: "Behind, and working. Those twenty-four took messages and handed every one of them back. These twelve finish what they take. One probe changed. Nothing else did."

Karpenter: "Nothing is Pending. I have stopped buying."

"And nothing new was bought. Karpenter gives the idle machines back a couple of minutes later. It was never the problem. It did what it was asked."

"readiness equals can THIS pod serve, not is the shared database alive."
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
