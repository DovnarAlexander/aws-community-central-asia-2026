# Runbook — "The probe that killed itself", AWS edition

What to run, what to say, how long each step takes, and what to do when it does not
go the way it went in rehearsal.

The only command typed on stage is `./stage`. After that it is all "next": right arrow on
the clicker, Enter, or space.

## Who is on call

The demo tells the story of one team. Both incidents are written as dialogue: the driver prints
the lines, you read them out — in character, or flat, or straight off the screen. No
separate preparation is needed; the terminal is the teleprompter. Step 0 introduces
everyone, so there is no cast slide and no reason to leave the window.

| Who | Role | What they do |
| --- | --- | --- |
| `(o_o)` Timur | backend | Wrote a service that takes 10 seconds to start; copied the probe from an article |
| `(-_-)` Ruslan | DevOps | Fixes production by raising numbers in YAML. Approved the review |
| `(^_^)` Madina | intern | Read the documentation. Brings the startup probe and the incident 2 fix |
| `[o_o]` kubelet | executioner | Does exactly what the manifest says. Blameless |
| `(~_~)` Postgres | database | Two vCPU, 54 usable connections, endless patience |
| `[>_<]` KEDA | pod autoscaler | Queue is deep, so add workers. No other ideas |
| `[$_$]` Karpenter | node autoscaler | Pods are Pending, so buy machines. Has a credit card |

Twice per demo the driver prints an **EVERYONE VOTE** card — three options, the room shouts
a number. Nothing needs pressing; the answer arrives a moment later. Both times the correct
answer is not on the list, and that is the point: in 1.4 the culprit is not a person but the
question the probe was asking, and in 2.3 all three obvious responses add work to the
database everyone is already stuck behind.

## The night before

With internet, unhurried, about half an hour:

```sh
task bootstrap    # infra, image, 2M rows -- roughly 25 minutes, mostly EKS
task smoke        # every step unattended, with assertions -- about 20 minutes
```

`task bootstrap` is `up` + `secrets` + `dbshell` + `images` + `seed`. Everything it creates is tagged
`ExpiresAt` eight hours out, so if the talk is tomorrow, bring it up tomorrow — or re-run
`task up` in the morning to push the tag forward. The reaper will otherwise shut the
cluster down overnight, which is the correct behaviour and an inconvenient surprise.

**When you stop working, `task down`.** Not later. The environment costs about $0.40/hour
and takes fifteen minutes to rebuild.

## Half an hour before

Backstage, with the projector already mirrored:

```sh
task up           # if the environment is not already running
task reset        # one command to the state step 1.1 expects — run it every time
task preflight    # one screen of checks
./stage           # layout plus driver, waiting for the first press
```

`task preflight` should be green except possibly **karpenter capacity warm**, which is a
warning until something has been scheduled. Warm it deliberately — it makes incident 1's first
step a predictable 20 seconds instead of however long EC2 feels like taking:

```sh
kubectl -n demo run warm --image=public.ecr.aws/docker/library/busybox:latest \
  --overrides='{"spec":{"nodeSelector":{"role":"demo"}}}' -- sleep 300
```

Layout already on screen but no driver in it? `./stage` rebuilds it. Force with
`./stage --fresh`.

The bottom right pane names the run it is showing — `LOAD . incident1-before` in its border, and
the mode and rate in its first line — and it keeps the finished run's last lines on screen,
`SUMMARY` included, until the next load starts. That is the number the before/after table is
built from, so it is worth being able to point at.

### Font and layout

Terminal font large: **18pt minimum, 22–24pt is better**. Do not judge by eye — judge by
the window size in characters, because the smaller the font, the more fit. Aim for
**100–120 columns and 28–36 rows** for the whole screen; anything more is unreadable from
the middle of the room. `./stage` measures this itself and warns before the talk starts.

The layout assumes exactly that size: 62% of the width to the driver, 5 rows to the stat
panel, 8 to the load generator, everything else to the pods. In incident 2 there are up to
twenty-four of them, and that pane is the one that needs to grow.

If the projector still clips k9s's `RESTARTS` column, it does not matter: during every live
wait the driver prints its own pod table, with restarts, in the big pane. `Ctrl-b z` zooms
any pane to full screen and back.

## Timing

35 minutes, and the buffer is not optional for a live cloud demo.

There are no slides. The six minutes of theory became one card in the titles, eight `teach`
cards spread through the incidents, and a closing card with a link and a QR. Each teaching card
sits in a wait the demo was going to spend anyway — a rollout settling, a node being bought,
a queue filling before KEDA has looked at it — and is printed in the driver pane, so the
right-hand panes keep running underneath it.

Seven of the eight are **Madina's**, printed under her name: read them as hers, not as
yours. One line of her dialogue sets each one up, and in 2.1 the card is explicitly what she
did not say out loud.

**The card is always up before the wait it covers, never after.** That is the whole working
method: press, the thing starts coming up, the card appears, and you read it aloud while the
cluster works — the screen and the voice carrying the same content at the same time. If you
ever find yourself watching a countdown with nothing to say, that is a bug in the step, not
in your preparation. The same rule is why 1.2's kill window opens with both numbers that are
racing, and why 2.4 says what to watch for before the ninety seconds rather than after. The KEDA card is unsigned — it is about the autoscaler, not about
anybody. Two arguments that used to be cards are now spoken: the one about
`initialDelaySeconds` in 1.2, and the closing lines of 2.4.

**Before the talk, once:** `task qr` writes `docs/qr.txt` for the closing card and
`slides/public/qr.svg` for the deck — it needs `segno` (`pipx install segno`), and both
files are committed afterwards. `GEOM=native task deck:record -- full` records the fallback
against a live cluster in one pass and `task deck:split` cuts it into the eight per-step
casts the deck plays; they need `brew install asciinema`. The QR has a placeholder committed,
so nothing is broken before you get to it.

| | What | Length |
| --- | --- | --- |
| 0 | The cast, and one card: what this talk is about | 1.5 min |
| 1.1 | Timur ships a service | 4 min |
| 1.2 | The number, and the documentation | 5.5 min |
| 1.3 | Production config, and real traffic | 4 min |
| 1.4 | End of incident 1 — before and after | 3.5 min |
| 2.1 | The review that let it through | 2.5 min |
| 2.2 | Black Friday: the queue fills | 3 min |
| 2.3 | The cascade, and the autoscalers help | 5 min |
| 2.4 | Madina unhooks the probe | 5.5 min |
| Close | Postmortem, the takeaway card, the QR | 2 min |
| | Buffer | 3 min |

Modelled end to end that is **39.5 to 43 minutes against a 35-minute slot**. Roughly a
minute and a half of that came back deliberately: signing the cards costs a line of Madina
setting each one up, and every wait now opens with the text rather than with silence — which
is more words, spoken over time the clock was spending anyway — 38 if the
countdowns get cut once the room has the point, 42 if everything runs to zero. It was 44 to
51 before the theory moved into the waits, so the restructuring bought six to nine minutes
and the show is still three to seven minutes long.

Both figures are modelled, not measured. The countdowns come to 9.5 minutes, which is the
only part `task smoke` measures directly; everything else assumes five seconds per spoken
line, and there are eighty-eight of them. That assumption alone is worth ±1.5 minutes, so
**rehearse with a stopwatch before deciding what else to cut** — the answer changes
depending on how fast the dialogue actually goes.

Running long? Three levers, in the order to pull them:

1. Every `watch_pods` and `watch_scale` ends early on "next". Once the room has visibly got
   the point, move.
2. Every `teach` card ends early on "next" too — and the wait underneath keeps running, so
   the cluster is no further behind. Cards are written with the line that matters first and
   the rest as depth to drop.
3. The incidents are independent. Incident 1 alone with the postmortem is a complete talk.

## Incident 1 — the probe that kills a healthy pod

### 1.1 — Timur ships a service

The pod is `Pending` first, because there is nowhere to put it. Karpenter buys a machine;
measured at about 20 seconds. The **four numbers** card goes up in that wait — the probe
vocabulary explained immediately before the probe uses it to kill something.

Then: warmup 10 seconds, `initialDelaySeconds: 2`, three misses a second apart. Two
plus fifteen is twenty seconds of patience against thirty seconds of startup. The first
restart lands at about t+20s from the container starting, the second at about t+50s once
the restart backoff is added.

**Watch:** the `RESTARTS` column. Count the misses out loud with kubelet.

### 1.2 — The number, and the documentation

Two steps in one: Ruslan's number and Madina's answer to it are a question and its answer,
and telling them separately cost an extra rollout and an extra step header for one lesson.

`initialDelaySeconds: 12` against a 10-second start fixes it, and holds until the day the
start gets slower. That day is Timur shipping a feature: the catalogue is preloaded at boot
so `/work` stops fetching it per request, which halves request latency and doubles the boot.
`kubectl set env WARMUP_SECONDS=20` stands in for the new build. Patience is 12 + 3×1 =
15 seconds, so the kill lands at 15, five seconds before the service would have been ready.
The manifest is untouched; everything around it changed.

The numbers are small on purpose. The failure is pure arithmetic and arithmetic is as true
at five seconds as at forty, and with patience under ten the RESTARTS column moves while
you are still explaining why it will — at the old 5 + 3×5 the first kill landed on the
twentieth second no matter what the warmup said, which is what made the opening drag.

**`WARMUP_SECONDS` never moves inside a probe diff.** It used to drop from 30 to 15 in the
same diff as Ruslan's `initialDelaySeconds`, unannounced, so his fix looked like it worked
partly because the application had quietly been made faster. Every change to the service
itself — warmup, `HEALTHZ_MODE`, `READY_MODE`, `POOL_MAX` — is announced by whoever owns it
with an `app change` line and a reason, and a step about a probe changes only the probe.
The manifests' header comments are stripped before anything is shown, so the diff on screen
is the change and nothing else: Ruslan's is one line.

Then `startupProbe`: its own budget, 60 checks at 2 seconds, and while it runs liveness is
not consulted at all. Same 20-second start as the breakage a minute earlier — the manifest
carries `WARMUP_SECONDS=20` for exactly that reason, so do not "fix" it back to 10. It stays
at 20 for the rest of the show, incident 2 included: the feature was never taken out, and
once the startupProbe exists the boot time stops being anybody's problem. The **three
probes** card fills the 20 seconds; the pods pane shows 0/1 and `RESTARTS 0` throughout,
which is the step's whole argument.

### 1.3 — Production config, and real traffic

Three replicas, `HEALTHZ_MODE=db`. `/healthz` now queues for the same worker slot and the
same pooled connection as `/work`. Under load the queue outgrows `timeoutSeconds: 1`, three
checks miss, and kubelet restarts three healthy replicas for being busy.

**Vote card.** Let the room argue. Do not answer.

### 1.4 — End of incident 1

`HEALTHZ_MODE=local`, and the liveness numbers get slack. The before/after table is built
from two real measurements — do not paraphrase it, read the numbers.

**The answer to the vote** is Madina's first line of 1.4 — none of the three, it was the
wrong question. The probe asked "are you answering quickly" and punished the answer as
though it meant "are you dead". It used to be answered twice, once there and once as a
closing card six minutes later, which read as though the vote were still open; the incident
now ends on "it stopped shooting at itself", the same shape incident 2 uses.

## Incident 2 — the probe that buys EC2 instances

### 2.1 — The review that let it through

`READY_MODE=db_each_call`. "Readiness should verify we can actually read our data" is a
sentence nobody argues with in a pull request. At three replicas the database does not
notice. Show the connection count while it is still boring — the room needs the baseline.

The **EndpointSlice** card fills the rollout: a readiness failure removes an address from a
slice, and the blast radius is every replica that shares whatever the probe asks about.
That is the sentence incident 2 then spends ten minutes proving.

### 2.2 — Black Friday

The queue fills. KEDA scales workers from zero; Karpenter starts buying. Measured in
rehearsal: 0 → 4 → 8 → 16 → 24 workers while nodes went 1 → 2 → 3 → 4.

KEDA polls every five seconds and the first worker still has to be scheduled, so the first
half-minute is the autoscaler thinking about it. The **KEDA** card goes there, and it ends
by itself the moment the first worker pod appears.

**Watch:** the stat panel. Queue depth and node count on adjacent lines is the argument of
the whole incident.

### 2.3 — The cascade

Twenty-four workers at four connections is ninety-six against a budget of fifty-four. The
workers that cannot connect do not delete their messages, so the messages come back, the
queue gets deeper, KEDA scales harder, and Karpenter buys more machines. Throughput sits at
zero while the node counter climbs.

Measured on 2026-09-12: the queue passed 140,000, the node count reached 4, and **not one
of the 24 workers was Ready** at the end of the step. After the fix, 10 of 12 — the two that
are not are simply the ones KEDA created seconds earlier.

**The stat panel keeps working** through all of this, deliberately: `db/seed.sql` grants
`pg_use_reserved_connections` to the master user, so the observer holds a slot when nothing
else can get one. If that panel ever goes dark, the grant did not run — see below.

The **loop** card goes up immediately before the long window, not after it: the room needs
the diagram to read the counters, and the panes keep turning underneath it. It is the one
picture the whole talk is built on — give it its thirty seconds even when running late.

**Vote card.** All three options add work to the database. The first also buys hardware.

### 2.4 — Madina unhooks the probe

Seven lines change: `READY_MODE`, `POOL_MAX` 4 → 3, readiness period 2s → 5s,
`maxReplicaCount` 24 → 12. Show the diff before applying it — that diff is the most useful
slide in the talk.

The **three parts** card fills the rollout, and it is the one place to say out loud that
only the first of the three is about probes. The other two — a pool budgeted against
`max_connections`, a ceiling on the autoscaler — are what makes getting it wrong next time
survivable rather than expensive.

Then say plainly what the panel shows, because it is not a drain. Two thousand messages a
second go in and twelve workers take them out one aggregation at a time, so the depth keeps
climbing — measured at 142k → 308k across the window. What changes is everything else:
twelve workers of twelve are Ready where twenty-four gave five, messages come off the queue
instead of returning to it, and the node count stops moving. Karpenter consolidates the
idle machines about two minutes later (`consolidateAfter: 2m`), which is after the talk has
moved on — so say that it will, do not stand there waiting for it. It was never the
problem: it did exactly what it was asked.

## When it goes wrong

**The venue network dies.** Tethering is the primary uplink for exactly this reason; switch
to it. If that fails too, the recorded run and the deck stand on their own — say so, play
it, and keep talking. Do not debug connectivity in front of the room.

**`kubectl` starts failing with credential errors.** Every call refreshes an STS token, so a
brief outage breaks the driver and a restored connection fixes it. Press next and carry on;
the step re-runs its command.

**The stat panel shows `-- unreachable` during incident 2.** The `pg_use_reserved_connections`
grant did not run. Nothing to do mid-talk — narrate the wall from the worker logs instead,
which say `remaining connection slots are reserved` in plain English. Re-run `task seed`
afterwards.

**Karpenter does not buy a node.** Check the spot quota first: `task preflight` reports node
count, and the NodePool caps at 8 vCPU. If spot capacity is genuinely unavailable in both
AZs, the step still works — it is just slower and quieter.

**A step has clearly failed.** `./demo 2.1` jumps straight to a step; everything before it
runs silently to restore state.

**Start the whole show over.** `task reset` puts the cluster into the state step 1.1
expects, from whatever state it is in, and it works in both directions.

It **removes**: the `svc` and `worker` deployments, the ScaledObject, the load generator, the
contents of both SQS queues — waiting for the depth to actually reach zero, because a purge
is asynchronous and incident 2 opening on a queue that is already deep is a different incident — and
every measurement the last run left in `/tmp/probes-demo`.

It **restores**: the namespace, the `svc` Service, the `db` secret out of SSM, and the
`dbshell` pod. All of those applies are no-ops when the objects are already there, which is
what makes the command safe to run from any state — after a smoke run, on a half-built
cluster, or twice in a row. It is also why every "missing" hint in `task preflight` names
this one command.

It **leaves alone**: the 2M seeded rows and any Karpenter nodes still warm from the last run.
The warm nodes are wanted — `task preflight` warns when there are none, because the first pod
then waits on EC2 for however long EC2 feels like taking.

`./demo --reset` is the same thing minus the `db` secret, which comes out of SSM rather than
a file; the driver and `task smoke` use that path so neither depends on Task being
installed. For a genuinely empty cluster there is `task down` and `task bootstrap`, which is
twenty-five minutes rather than twenty seconds.

**Everything has gone wrong.** `task deck:build` once, before the talk, and open
`slides/dist/index.html`. The slides carry a recorded run of the same show, cut per step, and
each segment starts itself when its slide comes up — so the deck is the same one button the
demo is. A cluster that died at step 2.2 costs you 2.2 and not the rest. Say plainly that it
is a recording; the room forgives that instantly and forgives a stall much less.

### Recording the fallback

Record once, split automatically. The driver prints a header for every step, so the cuts are
already in the recording and nobody reads timecodes off a scrubber:

```sh
task deck:record -- full    # opens the stage; run the show, then quit tmux
task deck:split             # step boundaries, plus slides ready to paste
```

A renumbered or retitled step moves its own cut, which hand-written timecodes would not. Do
it after a `task smoke` has passed, against the cluster the talk will use.

Before recording the show for real, spend ten seconds on:

```sh
GEOM=native task deck:record:probe   # opens the stage, closes itself, says yes or no
```

It is checking for one thing, and it is the one thing that looks fine in the terminal and
wrong in the deck. tmux draws a side-by-side layout by fencing the cursor into a pane's
column band — DECSLRM, `\033[105;167s` — and writing inside it. A real terminal honours the
fence; the deck's player does not implement it at all, and takes every one of those writes
at full width instead. The recording is not damaged, it is asking for something the player
cannot do, and nothing downstream can undo it: the right-hand panes come out smeared across
the screen, never cleared, with the stat panel drawn four times down the page. `./stage`
turns margins off so this does not happen; the probe is how you find out it worked on your
terminal, and `task deck:record` refuses to finish quietly if it did not.

What `deck:split` writes is `full.cuts.json` — a boundary per step — and the slides ask for
a step by name: `<Cast src="/casts/full.cast" step="1.4" />`. Every step gets a slide,
step 0 included: the introductions are part of the show, and a deck that opens straight on
incident 1 introduces Madina for the first time in the step where she unhooks the probe. Its
cut is the driver's own `0 . Who is on call` header a few seconds in, so the slide opens on
the cast rather than on tmux building the stage. One recording ships, and each
slide plays its range out of it. Cutting each step into a cast of its own is the obvious
thing and it is wrong: an asciicast is a stream of terminal writes, so a file that starts
mid-stream starts on a blank screen, and everything tmux had drawn before the cut — the pane
borders, k9s, the load panel — is simply missing until something repaints it. Seeking into
the whole recording makes the player replay the history instead, which costs single-digit
milliseconds and opens the step with the whole stage on screen.

The recording is text, not video, so its "resolution" is columns and rows. The default is
120x36 — the shape a projector reads, and the shape the deck's window on a slide is sized
for. For a recording meant to be watched on a screen rather than thrown at a wall, take the
whole terminal instead:

```sh
GEOM=native task deck:record -- full   # this window, full screen, nothing cropped
GEOM=160x44 task deck:record -- full   # or an explicit size
```

`task deck:split` notices when a recording is wider than a window on a slide and prints
full-bleed slides for it — no title, no chrome, the terminal edge to edge. Both shapes play
back in the geometry they were recorded in; the size is never pinned in the deck. Worth
knowing before reaching for `native`: every column added is a column the same slide width
has to divide between, so a full-screen cast is comfortable on a laptop and small in a room.

## Afterwards

```sh
task down         # destroys everything, then sweeps to prove it
task cost:check   # should print "nothing running"
```

Do this the same day. The reaper will catch a forgotten cluster within the hour and the
budget alarm within a day, but both of those are nets, not a plan — and a cluster left up
overnight is about $10 that bought nothing.

If `task down` reports an error, read the sweep it prints afterwards regardless: it runs
from a defer precisely so that a half-finished destroy still tells you what survived.

## What the room takes away

- Liveness answers one question: is this process alive. It never leaves the process to find
  out, and it is the last resort rather than the first responder.
- Readiness answers whether **this** pod can serve — not whether a shared dependency is
  healthy. A probe that asks about something shared is a probe that fails on every replica
  at once.
- The cost of a probe is `replicas × (1 / period)`. That number is knowable in advance, and
  nobody computes it.
- `replicas × POOL_MAX` against `max_connections` is also knowable in advance, and nobody
  computes that either.
- An autoscaler with no ceiling turns an incident into an invoice.
