# Шпаргалка докладчика — «The probe that killed itself»

48 слайдов `slides/talk.pptx`, по одному на секцию `slides/talk.md`. Заголовок
слайда и пометки — по-русски, спикерноуты — дословно из `talk.md`, как их
произносить.

Слайды с терминалом — это шаги записи (`Cast step=...`); на каждом таком слайде
клик запускает следующий кусок записи.

---

**1. Титул — «The probe that killed itself»**

```
"Good evening. I am really happy to be here — thank you for inviting me."

"This talk is about six lines in your YAML file."

"Almost everyone copies them from the service next door. Two of them can
kill a healthy service and put the outage on your AWS bill."
```

**2. Alexander Dovnar — био** *(слайд заморожен, сделан руками в PowerPoint)*

```
Let's start with some short self-introduction :)

1 "I run engineering at Naviteq as the CTO. We do DevOps services for variety of companies mostly from Israel."

2 "And I'm the co-host and "named" CTO of DevOps Kitchen Talks podcast where we discuss DevOps topics and argue about AI

3 "AWS Community Builder on the containers track, and a Terragrunt ambassador. Which is more or less why this talk exists." Also last year we released with my friend the book with Packt called "Cracking the Kubernetes interview"

4 "These are all on the QR at the end, so nobody needs to photograph this slide."

"Both incidents you are about to see happened to somebody I know, and one of them happened to me."
```

---

**3. ТЕРМИНАЛ — cast 0.1 (титры, люди)**

```
The opening titles: the people, one card each. The cards are on screen —
add one line per person, no more.

"This terminal is the whole talk. A real cluster, a real database, and
the failures are real too."

Timur writes the backend and copied his probe from a blog post. Ruslan
runs the infrastructure and fixes things by changing numbers. Madina is
the intern. She read the documentation.

[CLICK — recording continues]
```

**4. ТЕРМИНАЛ — cast 0.2 (титры, машины)**

```
Now the machines get cards too.

kubelet reads the manifest, not the code. Postgres has 54 connections to
give. KEDA adds workers when the queue is deep. Karpenter buys machines
— that one has a credit card.

"Seven characters. The two that matter are not people."

[CLICK — next scene]
```

---

**5. «Something is asking your container questions»** — 6 кликов

```
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
```

**6. «What is actually running»** — 8 кликов

```
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
```

---

**7. Разделитель «Incident 1 · The probe that kills a healthy pod»**

```
"A service that takes ten seconds to start. A probe copied from an
article. Nobody wrote a bug."
```

**8. ТЕРМИНАЛ — cast 1.1.1**

```
Timur ships his service — ten seconds to start, warming a cache and a
pool. Ruslan asks about the probe; it is copied from an article.

[CLICK — recording continues]
```

**9. ТЕРМИНАЛ — cast 1.1.2**

```
Madina asks for the numbers and starts adding them up. Ruslan ships
before she finishes — let the room finish the sum for her.

The pod is Pending, so Karpenter buys a machine. While it shops,
Madina's card explains the four numbers. Read the card from the screen,
slowly — it ends on the sum: five seconds of patience, ten seconds of
start.

[CLICK — recording continues]
```

**10. ТЕРМИНАЛ — cast 1.1.3**

```
kubelet knocks at two seconds; the service needs ten. Two kills, then
CrashLoopBackOff.

[point at the RESTARTS column]

[the closing line is on screen — read it, then pause]

[CLICK — the next slide does the math]
```

**11. «It is arithmetic, not a bug»** — 6 состояний

```
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
```

**12. ТЕРМИНАЛ — cast 1.2.1**

```
Ruslan has seen CrashLoop a hundred times: one line fixes it.
initialDelaySeconds goes from two to twelve. Twelve is bigger than ten,
so he is done. Madina asks what happens if the start gets slower.

[CLICK — recording continues]
```

**13. ТЕРМИНАЛ — cast 1.2.2**

```
Green — but it holds because nothing changed, not because the number is
right. Her line about that is on screen.

A week passes. Timur ships a good feature: the catalogue is preloaded
at boot now. Requests get twice as fast — and warmup goes from ten
seconds to twenty. Nobody touched the probe.

[CLICK — recording continues]
```

**14. ТЕРМИНАЛ — cast 1.2.3**

```
The same race again: patience runs out at fifteen, the service is ready
at twenty. The pod dies — and nobody did anything wrong.

Madina lists what moves a start: a cold cache, a noisy neighbour, more
data. None of them touch the manifest.

[CLICK — recording continues]
```

**15. ТЕРМИНАЛ — cast 1.2.4**

```
Madina finally gets her answer in: the documentation has a startupProbe.
While startup runs, the other two are not consulted. Boot gets its own
budget — two minutes if it wants.

Her card with the three probes is on screen. Read it from there, slowly.

[point at RESTARTS — same slow start, still zero]

[CLICK — next scene]
```

**16. ТЕРМИНАЛ — cast 1.3.1**

```
The start is fixed, so Timur ships the production config: three
replicas and real queries. He also points /healthz at the database —
an honest check, in his words. Madina warns that it shares the pool
with the real work. Four connections. They ship anyway.

Her card — restart versus remove — is on screen during the rollout.
Read it from there.

[CLICK — recording continues]
```

**17. ТЕРМИНАЛ — cast 1.3.2**

```
Three replicas Ready, one per node.

[CLICK — recording continues]
```

**18. ТЕРМИНАЛ — cast 1.3.3**

```
The traffic starts. The service is healthy — only busy. The pool fills
with real work, and /healthz waits in the same line. kubelet gets no
answer.

[CLICK — recording continues]
```

**19. ТЕРМИНАЛ — cast 1.3.4**

```
Three misses in a row, and kubelet kills the container.

[point at RESTARTS climbing]

Timur protests: it is alive, just busy. kubelet cannot tell the
difference — it only owns a timer.

[CLICK — recording continues]
```

**20. ТЕРМИНАЛ — cast 1.3.5**

```
The events log: liveness failed three times, then the kill. The
traffic never changed.

Then the vote: who took down a healthy service? Take hands.

[CLICK — next scene: Madina answers]
```

**21. ТЕРМИНАЛ — cast 1.4.1**

```
Madina says none of the three — it was the wrong question. Liveness
asks one thing: is the process alive. You do not visit a database for
that.

[CLICK — recording continues]
```

**22. ТЕРМИНАЛ — cast 1.4.2**

```
The fix: /healthz stops leaving the process, and liveness gets a
generous timeout and more misses. Readiness stays tight on purpose —
taking a busy replica out of rotation is its job.

[CLICK — recording continues]
```

**23. ТЕРМИНАЛ — cast 1.4.3**

```
Her card lists the changes — and the longer list of what did not
change: not the code, not the traffic, not the machines, not the
database.

Same load again. This time RESTARTS should not move at all.

[CLICK — recording continues]
```

**24. ТЕРМИНАЛ — cast 1.4.4**

```
The before/after table. p95 is the same — the service did not get
faster. It stopped shooting at itself.

[the closing line is on screen — read it, then pause]

[CLICK — the next slide sums the incident up]
```

**25. «The question the probe was asking»** — 5 кликов

```
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
```

---

**26. Разделитель «Incident 2 · The probe that buys EC2 instances»**

```
"This time Timur did everything right. He read the docs and wrote the
probe himself."

"It passes review. And it takes the whole service down."
```

**27. «A readiness probe that passes review»** — 5 состояний

```
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
```

**28. ТЕРМИНАЛ — cast 2.1.1**

```
A month later. Timur did not copy this probe — he read the docs and
wrote it himself: every readiness call queries the database. Ruslan
approves it, because it checks something real. Madina says nothing.
It passed review.

[CLICK — recording continues]
```

**29. ТЕРМИНАЛ — cast 2.1.2**

```
She said it out loud three times in the first incident. This time she
writes it down.

Her card explains the blast radius: the Service routes to a list of
addresses, and readiness edits that list. Every pod NotReady means an
empty list — no error, no traffic. Read the card from the screen.

[CLICK — recording continues]
```

**30. ТЕРМИНАЛ — cast 2.1.3**

```
Twelve connections out of fifty-four. Postgres did not even wake up.
All green — while there are three replicas.

[CLICK — next scene: Black Friday]
```

**31. ТЕРМИНАЛ — cast 2.2.1**

```
Black Friday. The work arrives as a queue — that is what this system
was built for. KEDA watches it, with zero workers running.

[CLICK — recording continues]
```

**32. ТЕРМИНАЛ — cast 2.2.2**

```
Two thousand messages a second start going in.

The KEDA card is on screen: poll every five seconds, twenty messages
per worker, ceiling at twenty-four. Read it from there — and land on
its last line: nothing in that formula knows WHY the queue is deep.

[CLICK — recording continues]
```

**33. ТЕРМИНАЛ — cast 2.2.3**

```
KEDA adds workers. The workers do not fit, so Karpenter buys machines.
Ruslan calls it the system working.

[point at the node counter — the only number here with a price on it]

[CLICK — recording continues]
```

**34. ТЕРМИНАЛ — cast 2.2.4**

```
Madina asks the room to look at what each new worker does before it
processes a single message.

[CLICK — next scene: the database]
```

**35. ТЕРМИНАЛ — cast 2.3.1**

```
Every replica opens a pool of four and scans two million rows every two
seconds — because that is what its readiness probe does. Ruslan calls
it a health check. Madina calls it a health check multiplied by the
replica count.

[CLICK — recording continues]
```

**36. ТЕРМИНАЛ — cast 2.3.2**

```
The arithmetic lands: twenty-four workers, four connections each —
ninety-six wanted. Postgres has fifty-four.

[point at the worker logs: too many connections]

The pods are up — and not Ready. A worker that cannot reach the
database never acks its message. The message comes back. The queue
gets deeper.

[CLICK — recording continues]
```

**37. ТЕРМИНАЛ — cast 2.3.3**

```
The loop closes on screen: NotReady workers, deeper queue, more
workers, more nodes. Madina's loop card is up while the panes keep
turning underneath it.

[point at throughput: zero. Nodes: still climbing]

"Nothing here is broken. Every part is doing exactly what we asked."

[CLICK — the next slide freezes the loop]
```

**38. «The loop»** — 8 кликов

```
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
```

**39. ТЕРМИНАЛ — cast 2.3.4**

```
The endpoint list is empty. Not one address. Scaling took the service
down, and it bought hardware to do it.

Then the vote: raise the worker limit, restart the database, or give
the probe more time? Take hands for each.

[CLICK — next scene: Madina answers]
```

**40. ТЕРМИНАЛ — cast 2.4.1**

```
Again none of the three — every one of them adds work to the database,
and the first also buys more machines. Madina takes the probe off the
database instead.

[CLICK — recording continues]
```

**41. ТЕРМИНАЛ — cast 2.4.2**

```
The fix, in her words: a background goroutine checks the database on
its own schedule and stores the answer in a flag. The probe reads the
flag. If the database really dies, the flags go stale and the pods
leave the balancer one at a time.

Two more changes ride along: the pool drops to three connections, and
KEDA gets a ceiling.

[CLICK — recording continues]
```

**42. ТЕРМИНАЛ — cast 2.4.3**

```
Her card: the fix in three parts, and only the first is a probe. Read
it from the screen.

Same queue again. Two numbers to watch: every worker Ready, and a flat
node count. The queue itself will not go down — that warning is on
screen too.

[CLICK — recording continues]
```

**43. ТЕРМИНАЛ — cast 2.4.4**

```
Twelve workers, twelve Ready, node count flat. The queue still grows —
twelve workers cannot outrun two thousand a second — but these twelve
finish what they take. The old twenty-four handed every message back.

Karpenter has stopped buying, and gives the idle machines back a few
minutes later. It was never the problem.

[CLICK — recording continues]
```

**44. ТЕРМИНАЛ — cast 2.4.5**

```
Forty-five connections, almost nothing active. Same load, same target,
different probe.

[the closing line is on screen — read it, then pause]

[CLICK — the next slide sums the fix up]
```

**45. «The fix is three things, and only one is a probe»** — 4 клика

```
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
```

---

**46. «The checklist · liveness and startup»**

```
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
```

**47. «The checklist · readiness, and the blast radius»**

```
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
```

**48. «Take it with you» — QR**

```
"Everything you saw is in this repository: the checklist, the manifests
with these numbers, and the tool that ran the show."

"The failures are reproducible: task bootstrap, then ./demo."

[leave this slide up for questions]
```
