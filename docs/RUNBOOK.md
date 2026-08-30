# Runbook — "The probe that killed itself", AWS edition

What to run, what to say, how long each beat takes, and what to do when it does not
go the way it went in rehearsal.

The only command typed on stage is `./stage`. After that it is all "next": right arrow on
the clicker, Enter, or space.

## The cast

The demo tells the story of one team. Both acts are written as dialogue: the driver prints
the lines, you read them out — in character, or flat, or straight off the screen. No
separate preparation is needed; the terminal is the teleprompter. Beat 0 introduces
everyone, so there is no cast slide and no reason to leave the window.

| Who | Role | What they do |
| --- | --- | --- |
| `(o_o)` Timur | backend | Wrote a service that takes 30 seconds to start; copied the probe from an article |
| `(-_-)` Ruslan | DevOps | Fixes production by raising numbers in YAML. Approved the review |
| `(^_^)` Madina | intern | Read the documentation. Brings the startup probe and the act 2 fix |
| `[o_o]` kubelet | executioner | Does exactly what the manifest says. Blameless |
| `(~_~)` Postgres | database | Two vCPU, 54 usable connections, endless patience |
| `[>_<]` KEDA | pod autoscaler | Queue is deep, so add workers. No other ideas |
| `[$_$]` Karpenter | node autoscaler | Pods are Pending, so buy machines. Has a credit card |

Twice per demo the driver prints an **EVERYONE VOTE** card — three options, the room shouts
a number. Nothing needs pressing; the answer arrives a beat later. Both times the correct
answer is not on the list, and that is the point: in 1.4 the culprit is not a person but the
question the probe was asking, and in 2.3 all three obvious responses add work to the
database everyone is already stuck behind.

## The night before

With internet, unhurried, about half an hour:

```sh
task bootstrap    # infra, image, 2M rows -- roughly 25 minutes, mostly EKS
task smoke        # every beat unattended, with assertions -- about 20 minutes
```

`task bootstrap` is `up` + `images` + `seed`. Everything it creates is tagged
`ExpiresAt` eight hours out, so if the talk is tomorrow, bring it up tomorrow — or re-run
`task up` in the morning to push the tag forward. The reaper will otherwise shut the
cluster down overnight, which is the correct behaviour and an inconvenient surprise.

**When you stop working, `task down`.** Not later. The environment costs about $0.40/hour
and takes fifteen minutes to rebuild.

## Half an hour before

Backstage, with the projector already mirrored:

```sh
task up           # if the environment is not already running
task preflight    # one screen of checks
task dbshell      # the always-on psql the stat panel execs into
./stage           # layout plus driver, waiting for the first press
```

`task preflight` should be green except possibly **karpenter capacity warm**, which is a
warning until something has been scheduled. Warm it deliberately — it makes act 1's first
beat a predictable 20 seconds instead of however long EC2 feels like taking:

```sh
kubectl -n demo run warm --image=public.ecr.aws/docker/library/busybox:latest \
  --overrides='{"spec":{"nodeSelector":{"role":"demo"}}}' -- sleep 300
```

Layout already on screen but no driver in it? `./stage` rebuilds it. Force with
`./stage --fresh`.

### Font and layout

Terminal font large: **18pt minimum, 22–24pt is better**. Do not judge by eye — judge by
the window size in characters, because the smaller the font, the more fit. Aim for
**100–120 columns and 28–36 rows** for the whole screen; anything more is unreadable from
the middle of the room. `./stage` measures this itself and warns before the talk starts.

The layout assumes exactly that size: 62% of the width to the driver, 5 rows to the stat
panel, 8 to the load generator, everything else to the pods. In act 2 there are up to
twenty-four of them, and that pane is the one that needs to grow.

If the projector still clips k9s's `RESTARTS` column, it does not matter: during every live
wait the driver prints its own pod table, with restarts, in the big pane. `Ctrl-b z` zooms
any pane to full screen and back.

## Timing

35 minutes, and the buffer is not optional for a live cloud demo.

| | What | Length |
| --- | --- | --- |
| Slides | Theory | 6 min |
| 0 | The cast | 45 s |
| 1.1 | Timur ships a service | 2.5 min |
| 1.2 | Ruslan comes to the rescue | 2 min |
| 1.3 | Madina reads the documentation | 1.5 min |
| 1.4 | Production config, and real traffic | 2 min |
| 1.5 | End of act 1 — before and after | 1.5 min |
| 2.1 | The review that let it through | 2 min |
| 2.2 | Black Friday: the queue fills | 3 min |
| 2.3 | The cascade, and the autoscalers help | 4 min |
| 2.4 | Madina unhooks the probe | 4 min |
| Slides | Mental model, checklist, close | 3 min |
| | Buffer | 3 min |

Running long? Every `watch_pods` and `watch_scale` ends early on "next". Once the room has
visibly got the point, move.

## Act 1 — the probe that kills a healthy pod

### 1.1 — Timur ships a service

The pod is `Pending` first, because there is nowhere to put it. Karpenter buys a machine;
measured at about 20 seconds. Fill the wait by reading the manifest out loud — the numbers
in it are the whole beat.

Then: warmup 30 seconds, `initialDelaySeconds: 5`, three misses at 5-second intervals. Five
plus fifteen is twenty seconds of patience against thirty seconds of startup. The first
restart lands at about t+50s from apply, `CrashLoopBackOff` at about t+80s.

**Watch:** the `RESTARTS` column. Count the misses out loud with kubelet.

### 1.2 — Ruslan comes to the rescue

`initialDelaySeconds: 40` fixes it, and holds until the day the start gets slower.
`kubectl set env WARMUP_SECONDS=60` is that day. The manifest is untouched; everything
around it changed.

### 1.3 — Madina reads the documentation

`startupProbe` gives the slow start its own budget — 60 checks at 2 seconds — and while it
runs, liveness is not consulted. Same 60-second warmup as the previous beat, and no
restarts at all.

### 1.4 — Production config, and real traffic

Three replicas, `HEALTHZ_MODE=db`. `/healthz` now queues for the same worker slot and the
same pooled connection as `/work`. Under load the queue outgrows `timeoutSeconds: 1`, three
checks miss, and kubelet restarts three healthy replicas for being busy.

**Vote card.** Let the room argue. Do not answer.

### 1.5 — End of act 1

`HEALTHZ_MODE=local`, and the liveness numbers get slack. The before/after table is built
from two real measurements — do not paraphrase it, read the numbers.

**The answer to the vote** is option four: the question the probe was asking. It asked "are
you answering quickly" and punished the answer as though it meant "are you dead".

## Act 2 — the probe that buys EC2 instances

### 2.1 — The review that let it through

`READY_MODE=db_each_call`. "Readiness should verify we can actually read our data" is a
sentence nobody argues with in a pull request. At three replicas the database does not
notice. Show the connection count while it is still boring — the room needs the baseline.

### 2.2 — Black Friday

The queue fills. KEDA scales workers from zero; Karpenter starts buying. Measured in
rehearsal: 0 → 4 → 8 → 16 → 24 workers while nodes went 1 → 2 → 3 → 4.

**Watch:** the stat panel. Queue depth and node count on adjacent lines is the argument of
the whole act.

### 2.3 — The cascade

Twenty-four workers at four connections is ninety-six against a budget of fifty-four. The
workers that cannot connect do not delete their messages, so the messages come back, the
queue gets deeper, KEDA scales harder, and Karpenter buys more machines. Throughput sits at
zero while the node counter climbs.

In rehearsal the queue passed 110,000 and stopped draining, with 19 of 24 workers
`NotReady`.

**The stat panel keeps working** through all of this, deliberately: `db/seed.sql` grants
`pg_use_reserved_connections` to the master user, so the observer holds a slot when nothing
else can get one. If that panel ever goes dark, the grant did not run — see below.

**Vote card.** All three options add work to the database. The first also buys hardware.

### 2.4 — Madina unhooks the probe

Seven lines change: `READY_MODE`, `POOL_MAX` 4 → 3, readiness period 2s → 5s,
`maxReplicaCount` 24 → 12. Show the diff before applying it — that diff is the most useful
slide in the talk.

Then the queue drains, and Karpenter consolidates the nodes back down. Say plainly that
Karpenter was never the problem: it did exactly what it was asked.

## When it goes wrong

**The venue network dies.** Tethering is the primary uplink for exactly this reason; switch
to it. If that fails too, the recorded run and the deck stand on their own — say so, play
it, and keep talking. Do not debug connectivity in front of the room.

**`kubectl` starts failing with credential errors.** Every call refreshes an STS token, so a
brief outage breaks the driver and a restored connection fixes it. Press next and carry on;
the beat re-runs its command.

**The stat panel shows `-- unreachable` during act 2.** The `pg_use_reserved_connections`
grant did not run. Nothing to do mid-talk — narrate the wall from the worker logs instead,
which say `remaining connection slots are reserved` in plain English. Re-run `task seed`
afterwards.

**Karpenter does not buy a node.** Check the spot quota first: `task preflight` reports node
count, and the NodePool caps at 8 vCPU. If spot capacity is genuinely unavailable in both
AZs, the beat still works — it is just slower and quieter.

**A beat has clearly failed.** `./demo 2.1` jumps straight to a beat; everything before it
runs silently to restore state. `./demo --reset` tears the workloads down without touching
the cluster.

**Everything has gone wrong.** The deck is a complete talk on its own. The demo is the best
part, not the only part.

## Never run two stack runs at once

`task up` and `task down` do not queue behind each other. They race, and the losing side is
whatever was created most recently.

Seen once, and worth describing exactly. A `task down` was still running — its last resource,
the database security group, sat in `DependencyViolation` for thirteen minutes while RDS
released its network interfaces, printing `Still destroying...` and looking like a stuck but
harmless tail. A `task bootstrap` started in another window. The apply could not take the
lock on the database unit, so it skipped it and built everything else: VPC, cluster, node
group, queues, registry, platform. The destroy then carried on and deleted the RDS instance,
the DSN parameter, the subnet group and the parameter group. `task seed` failed with
`ParameterNotFound` — the only visible symptom, and it pointed at the wrong thing entirely.

Had the destroy reached the network unit, it would have taken the VPC out from under a
live cluster.

`task up` and `task down` now refuse to start while another `terragrunt stack run` is alive.
If one does need killing, kill it, then release the lock it left behind before applying:

```sh
cd infra/demo/.terragrunt-stack/<unit>
terragrunt run -- force-unlock -force <lock-id>   # id is in the .tflock object in S3
```

Then apply that one unit and let the stack catch up. A unit whose state still lists
resources AWS no longer has is not a problem: the next apply refreshes, notices, and
recreates them.

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
