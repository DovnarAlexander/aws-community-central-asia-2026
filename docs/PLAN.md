# Plan — "The probe that killed itself", AWS edition

Porting the DKT Conf 2026 talk (`../dkt-probes-demo`) from a kind cluster on a laptop to a
live AWS environment, and rebuilding the second half of the story so that the autoscalers
turn a misconfigured probe into an EC2 bill.

## Decisions taken

| Question | Decision |
| --- | --- |
| Platform | EKS + Karpenter + KEDA, RDS PostgreSQL, SQS |
| Slot | **35 minutes** — which forces two incidents, not three (see *Incident structure*) |
| Deck / terminal / docs language | English throughout |
| What runs live on stage | Infra provisioned the day before; only deploys, probes, pod scale, node scale and the connection wall happen live |
| Deck theme | `naviteq-slidev` |
| Cast | Timur (backend), Ruslan (DevOps), Madina (intern) |
| AWS account | `250295255927` / `just-devops`, region `eu-central-1`. Credentials come from the standard AWS chain — export `AWS_PROFILE` (or anything else the CLI accepts) before running `task`; nothing pins a profile name. `infra/root.hcl` pins the account id, so wrong credentials fail the apply |
| IaC | **Terragrunt v1.1.3** — `root.hcl`, units in `infra/<name>/`, modules in `infra/modules/<name>/`, the ephemeral environment composed as a `terragrunt.stack.hcl`. Backend and provider generated, `errors`/`retry` for transient AWS failures. Runs OpenTofu |
| Terraform state | Existing bucket `250295255927-eu-central-1-terraform-states`, S3 native locking (no DynamoDB — `use_lockfile`) |

## Account baseline, measured 2026-08-30

Worth writing down, because it is what makes cost control easy here.

- Last month's spend: **$0.00**. Nothing is running — no EC2, no NAT, no EKS, no RDS,
  no load balancers, no unattached EIPs.
- A `daily_budget` exists at **$50/day, alerting at 90%**. That threshold is far above a
  forgotten cluster (~$10/day), so it would never catch the failure mode we actually care
  about. We add our own guard.
- **Service quota: 8 vCPU on-demand and 8 vCPU spot** (separate quotas) in `eu-central-1`.
  The demo is designed to fit inside this rather than wait on an increase request that may
  take days on a personal account.

Because the account starts empty, anything that shows up in the bill is ours. That makes
the sweep in `task cost:check` unambiguous.

## The thesis that changes

The original ends on: *probes are the only code that can kill a healthy service.* On AWS
that gets a sharper ending, because the blast radius is no longer the cluster.

A readiness probe wired to a shared dependency, plus a queue-depth autoscaler, plus a node
autoscaler, is a positive feedback loop with a price tag:

```
probe hits the shared DB  →  replicas go NotReady  →  they stop consuming SQS
      ↑                                                        ↓
Karpenter buys more nodes  ←  KEDA scales workers up  ←  queue depth grows
```

Every turn adds RDS connections, which deepens the wall that started it. The audience
watches the node count climb while throughput goes to zero. That only works on real cloud
infrastructure, and it is the reason this port is worth doing.

## What happens in this repository

`aws-community-central-asia-2026` is the new home and the only repository we write to.
`../dkt-probes-demo` is read-only source material: we port from it, we never edit it. It
stays intact as the record of the DKT Conf 2026 talk.

What gets **ported and adapted**:

| From | Becomes | Change |
| --- | --- | --- |
| `demo`, `lib/demo.sh` | same | Translated; new helpers for nodes, queue depth, KEDA |
| `lib/story.sh` | same | Translated, recast; KEDA and Karpenter replace HPA as the amplifier. Name column widens from 8 to 9 characters — "Karpenter" does not fit the old one |
| `steps/incident1.sh`, `incident2.sh` | same | Translated, retargeted, resequenced for 35 minutes |
| `manifests/` | `k8s/` | DSN from a secret, no in-cluster Postgres, resources sized for real nodes |
| `stage` | same | New panel layout around nodes and queue depth |
| `tools/loadgen/` | same | Gains an SQS enqueue mode |
| `app/main.go` | `app/cmd/api/` | Split, plus an `/enqueue` endpoint |
| `db/seed.sql` | same | Runs as a Job against RDS instead of baking into an image |
| `Taskfile.yml` | same | AWS lifecycle: `up`, `down`, `preflight`, `smoke`, `cost:check` |
| `docs/RUNBOOK.md`, `docs/SCRIPT.md` | same | Rewritten for the AWS setup, in English |
| `slides/` | same | New theme, new language, new content |

What is **written from scratch**:

- `infra/` — the entire Terragrunt setup. Nothing to port; the old repo's infrastructure was
  one `kind.yaml` file.
- `infra/guardrails/` — the always-on, near-free cost guard. Separate state, never destroyed.
- `app/cmd/worker/` — the SQS consumer, and the probe antipatterns specific to a queue
  consumer that has no HTTP traffic of its own.
- `k8s/platform/` — Karpenter `NodePool` / `EC2NodeClass`, KEDA `ScaledObject`.
- `scripts/preflight.sh` — replaces `scripts/check.sh`; checks a cloud environment rather
  than a laptop.
- `scripts/cost-check.sh` — the sweep described under *Cost*.

What is **dropped**:

- `kind.yaml`, `task load-images` — no local cluster.
- `db/Dockerfile` — the 2M rows are seeded into RDS and snapshotted, not baked into an image.
- The offline guarantee. It was the old demo's best property and it does not survive the
  move to AWS; phase 8 replaces it with a recorded fallback.

## Target architecture

```
VPC (2 AZ, PUBLIC subnets only, no NAT gateway)
├── EKS control plane
│   ├── managed node group — 1 × t3.large, on-demand, system only:
│   │   CoreDNS, Karpenter controller, KEDA operator, metrics-server
│   └── Karpenter NodePool — SPOT only, small instance types
│       every demo workload lands here, and only here
├── RDS PostgreSQL — db.m6g.large, single-AZ, no Multi-AZ, no read replica
│   └── custom parameter group: max_connections pinned low, on purpose
└── SQS: work queue + DLQ
```

Three constraints shaped that diagram, and each one is deliberate:

**No NAT gateway.** It is the single worst thing to forget: $32/month sitting idle plus
$0.045/GB, and nothing about it looks alarming in the console. Nodes go in public subnets
with public IPs and a restrictive security group. For an ephemeral demo cluster that trade
is correct, and it removes the biggest silent bleed in the design.

**Karpenter on spot, small instances.** Roughly 70% cheaper, it draws on the separate 8 vCPU
spot quota rather than competing with the system node group, and small nodes mean *more*
nodes appear when it scales — which is exactly the thing the audience needs to see.

**Non-burstable RDS.** `db.m6g.large` costs more per hour than a `t4g`, but burstable CPU
credits run out mid-demo and the incident-2 cascade stops being reproducible. At roughly $6
across the whole project, determinism is worth more than the saving.

Two workloads, one image. **api** is the existing HTTP service — `/work`, `/healthz`,
`/ready`, `/startupz` — plus a new `/enqueue` that pushes messages onto SQS. **worker**
long-polls the queue, does the same DB aggregation per message and deletes on success; this
is what KEDA scales and what incident 2 breaks. Every failure mode stays an environment variable,
so one image plays both the broken and the fixed role — the same contract as the original.

## Cost

The demo itself is cheap. The only real risk is forgetting to destroy it.

| | Per hour | Notes |
| --- | --- | --- |
| EKS control plane | $0.10 | Unavoidable while the cluster exists |
| RDS db.m6g.large | $0.156 | Plus $2.30/month for 20 GB gp3 while it exists |
| System node, 1 × t3.large | $0.096 | |
| Karpenter spot nodes | ~$0.05 | 2–4 small nodes at spot pricing |
| NAT gateway | **$0** | Designed out |
| **Running total** | **~$0.40** | |

- **Demo day**, 3 hours hot: **~$1.25**.
- **Whole project**, generously 50 hours of cluster uptime across weeks: **~$25**.
- **Idle between sessions**, everything destroyed: RDS snapshot (~$0.20/month), ECR, S3
  state. Under **$1/month**.

Against the stated tolerance of $100 for a couple of hours, that is roughly two orders of
magnitude of headroom. So the budget goes entirely into guarding against the forgotten
cluster, which at ~$10/day would cost $300 a month and never trip the existing $45 alarm.

### Three layers of guard

1. **`task down`** destroys everything and then verifies, rather than trusting Terraform's
   exit code. RDS is destroyed *to a final snapshot* rather than left stopped — a stopped
   instance restarts itself after 7 days and resumes billing silently.
2. **`task cost:check`** sweeps `eu-central-1` for EC2, EKS, RDS, NAT gateways, unattached
   EIPs, load balancers and EBS volumes — both project-tagged and untagged strays — prints
   an estimated hourly burn, and exits non-zero if anything is alive. Trivially reliable
   here because the account baseline is empty.
3. **A TTL dead-man switch** in `infra/guardrails/`: EventBridge Scheduler runs a Lambda
   hourly; anything tagged `Project=probes-demo` whose `ExpiresAt` tag has passed gets its
   EC2 instances terminated and its RDS instance stopped. It does not need Terraform state
   to work, so it still fires if my laptop is closed or a destroy failed halfway. Cost is
   effectively zero. Plus a project-scoped budget alarm at a threshold that actually
   catches a forgotten cluster, not $45.

### The working rule

Every test session I run ends with `task down` followed by `task cost:check`, and I paste
the sweep output into the conversation. Infrastructure is never left up between sessions
"because we'll need it again in an hour" — bringing it back costs about 15 minutes and
about 10 cents.

## Incident structure

35 minutes is the constraint that reshapes the show. The original was 29 minutes for two
incidents, and the plan had been to add a third for the queue and the autoscalers. That does not
fit — but the fix improves the talk rather than compromising it.

The original talk's second act (readiness tied to the database) and the third one that was
planned for this port (queue, KEDA, Karpenter) share one root cause: **a probe that asks
about a shared dependency**. Splitting them in two tells the same lesson twice. Merged, there is one cascade that starts
in the database and gets amplified into an EC2 bill — a single escalating arc instead of
two similar ones.

| | | Budget |
| --- | --- | --- |
| Opening | Who is on call, and one card: what this talk is about | 1.5 min |
| Incident 1 | **The probe that kills a healthy pod** | 16.5 min |
| Incident 2 | **The probe that buys EC2 instances** | 16 min |
| Close | Postmortem, the takeaway card, the QR | 2 min |
| Buffer | Non-negotiable for a live cloud demo | 3 min |

That adds up to 39, and the model says 39.5 to 43 once the cast, the close and the buffer
are counted — so the show is still three to seven minutes long. Before the
restructuring it modelled at 44 to 51, so moving the theory into the waits bought six to
nine minutes, which is most of the gap and not all of it.

Both figures are modelled rather than measured. The countdowns are 9.5 minutes and `task
smoke` measures those; the rest assumes five seconds per spoken line across eighty-eight
lines, which is worth ±1.5 minutes on its own. The next lever is therefore a stopwatch, not
another edit. If the model holds, the two candidates are dialogue — incident 1 carries fifty
spoken lines, incident 2 thirty-eight — and folding 2.2 into 2.3, which are one continuous event
told as two steps.

### Where the theory went

The six minutes of slides at the front are gone, and not by being cut: they are distributed
into the demo as `teach` cards, each one placed in a wait the demo was going to spend
anyway. That decision followed from measuring the thing honestly. Modelled step by step,
the show was running 44 to 51 minutes against a 35-minute slot, and roughly sixteen of
those minutes were countdowns — a rollout settling, Karpenter buying a node, a queue
filling before KEDA has looked at it. Moving theory into that dead time is the only lever
that buys minutes without dropping a topic.

Two kinds of wait, and only one of them is available:

- **Dead** — nothing to look at yet. Rollouts, the node purchase, the first half-minute of
  the queue fill. Four to five minutes in total, and this is where every card goes.
- **The payoff** — `RESTARTS` climbing, queue depth and node count pulling apart. Nothing
  is ever printed over these. They are what the room came for.

The cards are printed in the driver pane rather than shown in a deck, because `./stage` is
one tmux window: the three right-hand panes keep running underneath a card, so the node
counter climbs next to the card explaining why it climbs. Leaving tmux for Slidev would
stop all three, and there would be something to switch back from.

There are no slides left at all, and the closing checklist is the reason there are none. The
room does not read a checklist off a screen — it photographs one. So the show ends on the
thing worth photographing: a card with a link, and a QR beside it (`task qr`). The link
carries `docs/CHECKLIST.md` and the manifests that produced every failure they just watched,
which is a better takeaway than a slide of bullets and costs no switch. One card stays at
the front, in the titles: who is asking the questions, and what the three answers do.
Without it Timur's "initialDelay 5, period 5, timeout 1, three misses" is noise to anyone
who has not wired a probe before.

The teaching cards are **signed**. Nearly all of them are Madina's, printed under her name
and in her colour, because an unattributed card is the author interrupting the story, while
a signed one is a thing a character produced — the same content, without the seam. Her part
was written for it: the intern whose whole role is having read the documentation. The two
cards that are arguments rather than references are spoken instead, because a claim belongs
in a voice and a card left up through it would be two things competing for the same
attention. The KEDA card stays unsigned: it is about the machine, not about anybody.

The best of them is in 2.1. Madina says "Nothing. It passed review." — and her note appears
anyway, carrying the objection she swallowed, which is the objection the next twelve minutes
are about.

The cost of the decision is that the talk and the cluster are now one artefact: if AWS is
having a bad afternoon, the theory goes down with the demo. The recorded fallback in phase
8 stops being a nicety.

**Incident 1 — the probe that kills a healthy pod.** Four steps, not five: Ruslan raising the
number and Madina producing the `startupProbe` are a question and its answer, and telling
them as separate steps cost an extra rollout, an extra step header and about three minutes
for one lesson. The incident-1 arithmetic was also halved — 25 seconds of patience against a
15-second start rather than 40 against 30 — because the failure is pure arithmetic and
arithmetic is as true at 25 seconds as at 40.

The story is unchanged: naive liveness kills a slow-starting service; Ruslan raises
`initialDelaySeconds` and it breaks again a week later; Madina brings `startupProbe`; then
under real load the same liveness kills three healthy replicas because it measures latency,
not life. One step comes free from AWS: the first pod sits `Pending` while Karpenter buys a
node. That wait used to be filler the audience enjoyed; it now carries the card that
explains the four probe numbers, immediately before the probe uses them to kill something,
and it still establishes the node panel before incident 2 needs it.

**Incident 2 — the probe that buys EC2 instances.** A readiness probe that "honestly checks the
database" passes review at three replicas. Then the queue fills: KEDA scales workers from
zero, Karpenter provisions nodes live. The probe cost multiplies by replica count, RDS hits
the pinned `max_connections`, every replica goes NotReady, workers stop consuming, queue
depth climbs, KEDA scales harder, Karpenter buys more nodes — and the node counter keeps
climbing while throughput sits at zero. The fix decouples the probes, caps
`maxReplicaCount`, and budgets the pool against `max_connections`. The queue drains, the
nodes scale back down.

Both incidents stay independently runnable, so the RUNBOOK can carry a short cut if the slot
shrinks on the day.

## Why each failure still reproduces

The original bought determinism with `limits.cpu: "1"` on an in-cluster Postgres. On AWS
the equivalent levers are:

| Failure | What guarantees it |
| --- | --- |
| Slow start killed by liveness | `WARMUP_SECONDS` vs `initialDelay + failureThreshold × period` — pure arithmetic, cloud-independent |
| Connection wall | The RDS parameter group pins `max_connections`; `replicas × POOL_MAX` is set to exceed it |
| Readiness cascade | A non-burstable RDS class gives fixed, known vCPU — the reason `t4g` is disqualified |
| Node scale visible on stage | Karpenter provisions in ~40–60 s, the only piece of AWS infrastructure fast enough to show honestly. Small spot instances mean more nodes appear |
| Queue death spiral | KEDA's `queueLength` target and worker pool size chosen so the loop closes before the audience loses interest |

All of these numbers need re-measuring against real RDS: the 200 ms full scan that made the
old incident 2 work on a laptop will land somewhere else on an m-class instance.

The 8 vCPU quota is a design input, not an obstacle. Demo pods request 100m each, so 16 API
replicas need 1.6 vCPU — the constraint is node *count*, not capacity, and small nodes make
the scaling more visible anyway.

## Repository layout

```
infra/root.hcl        backend, generated provider, retry policy — included by every unit
infra/guardrails/     persistent unit: TTL Lambda, schedule, budget alarms
infra/scratch/        throwaway unit that proves the reaper reaps; never left applied
infra/demo/           terragrunt.stack.hcl — the ephemeral environment (phase 1)
infra/modules/        the Terraform each unit runs
app/cmd/api/          HTTP service
app/cmd/worker/       SQS consumer
app/internal/         shared: db, probes, sqs
db/seed.sql           run as a Job against RDS, then snapshotted
k8s/incident1/, k8s/incident2/  one full manifest per step; the driver diffs between them
k8s/platform/         Karpenter NodePool, EC2NodeClass, KEDA ScaledObject
tools/loadgen/        HTTP load and SQS enqueue modes
demo, stage, lib/     driver, tmux layout, cast — ported and translated
scripts/              preflight, cost-check, stat, smoke, deck-stamp
slides/               Slidev, naviteq theme, English
docs/                 RUNBOOK.md, SCRIPT.md, PLAN.md
Taskfile.yml
```

## Phases

### 0. Guardrails — **done, 2026-08-30**
`infra/guardrails/` holds the reaper Lambda, an hourly EventBridge schedule, an SNS topic,
and two budgets: `probes-demo-daily-guard` at $15/day and `probes-demo-monthly` at $40 on
the `Project` cost allocation tag. `scripts/cost-check.sh` sweeps the account.

Verified end to end rather than assumed. `task guardrails:test` creates a `t4g.nano` tagged
`ExpiresAt=2000-01-01`, confirms the sweep finds it, invokes the reaper, confirms the
instance is terminated, destroys the leftover VPC and subnet, and re-runs the sweep. It
passed: reaper reported `reaped: 1`, and a 17-region sweep afterwards came back clean.

Two things learned in the process, both now encoded:

- **AWS rejects `FORECASTED` notifications on a `DAILY` budget** — only `ACTUAL` is
  accepted. The daily guard carries two actual thresholds (30% and 80%) instead; the
  forecast alarm lives on the monthly budget, where it is allowed.
- `scripts/cost-check.sh` priced an unknown instance type at the $0.10/h fallback. Correct
  behaviour for a guard — assume expensive when unsure — but `t4g` rates are now in the table.

**Outstanding:** the SNS email subscription is `PendingConfirmation`. Until that link in
`dovnar.alexander@gmail.com` is clicked, budget alarms and reaper reports go nowhere.

### 1. Infrastructure — **done, 2026-08-30**
A Terragrunt stack for VPC (public subnets, no NAT), EKS, the system node group, Karpenter on spot,
KEDA, RDS with the pinned parameter group, SQS and DLQ, IRSA or Pod Identity for the worker
and the KEDA operator, and the S3 backend. `task up` / `task down`. A seed Job for 2M rows,
followed by a manual RDS snapshot so later runs restore instead of re-seeding.

Six units, applied clean. Verified against the live environment: the cluster came up, RDS
answered from inside the VPC with `max_connections` pinned at 60, the seed job loaded
2,000,000 rows, and Karpenter provisioned a node on demand.

**Karpenter is faster than planned.** Pending to Ready measured at about **20 seconds** on
spot `t4g` capacity in `eu-central-1`, not the 40–60 assumed. Incident 1's waiting step was
shortened accordingly.

Three things only real AWS could have told us, all now fixed in the code:

- A Graviton instance type with the module's default `AL2023_x86_64_STANDARD` AMI is
  rejected outright rather than resolved — the arm64 decision has to be stated twice.
- Karpenter's controller policy exceeds the 6144-byte ceiling on a managed policy;
  `enable_inline_policy` moves it to the role, where the limit is 10240.
- The EKS module disables encryption on `encryption_config = null`, not `{}` — an empty
  object still satisfies its `!= null` check and produces a config block with no key.

### 2. Application — **done, 2026-08-30**
Split the existing `main.go` into `api` and `worker` around shared internals. Add
`/enqueue`, the SQS consume loop, and the worker's probe modes. Build and push to ECR.

One image, three binaries: `api`, `worker`, `loadgen`. Built for arm64, pushed to ECR, and
running in the cluster.

`docker login` on macOS delegates to the keychain even with no `credsStore` configured, and
the keychain needs a click — so the push writes the registry token into an isolated docker
config instead. And `terragrunt output -raw` pads its value with trailing spaces, which
turned `$REPO:latest` into a tag the registry reported as a missing repository.

### 3. Manifests and tuning — **verified, tuning outstanding**
One manifest per step, the KEDA `ScaledObject`, the Karpenter `NodePool`. Then the real
work: measure and adjust `POOL_MAX`, `max_connections`, probe periods, scan cost and queue
targets until every failure lands inside its step.

Both incidents reproduce on the live environment.

**Incident 1**, measured: node arrives at t+20s, pod Running at t+30s, first restart at t+50s,
CrashLoopBackOff at t+80s. The arithmetic holds exactly as written.

**Incident 2**, measured: KEDA scaled workers 0 → 4 → 8 → 16 → 24 while Karpenter bought
1 → 2 → 3 → 4 nodes; the queue climbed past 110,000 and stopped draining; 19 of 24 workers
went NotReady with `remaining connection slots are reserved`. The spiral is real and needs
no help.

One thing incident 2 exposed that the plan had wrong: **the stage panel went blind at the wall.**
The observer's connection is refused along with everything else. RDS holds slots back for
its own internal `rds_reserved` role, and the master user is a member of `rds_superuser`
rather than a real superuser, so `superuser_reserved_connections` does not reach it either.
PostgreSQL 16's `pg_use_reserved_connections` does; `db/seed.sql` now grants it. Verified
with 16 workers holding 50 of 60 connections and every one of them NotReady — the counter
still reads.

That also corrects the budget everywhere: 60 `max_connections` is **54** in practice, not
the 57 the manifests claimed.

**Still outstanding:** the three-consecutive-runs rule, and tuning the incident 2 step lengths
against measured timings rather than estimates.

### 4. Driver and stage — **done, 2026-08-30**
Port `demo`, `lib/demo.sh`, `lib/story.sh` and `steps/`, translated and recast. Restructure
into the two incidents above. Replace the Postgres stat panel with a combined panel — Karpenter
nodes, SQS depth, RDS connections — and rework the tmux layout around it.

**Decided:** the load generator runs in-cluster, as a third binary in the same image. Venue
Wi-Fi in p95 would make the before/after table lie, and that table is the one place the talk
asks the audience to trust a number. The summary comes back through `kubectl logs` behind a
`SUMMARY` marker.

Still unrehearsed end to end — that is phase 5.

### 5. Smoke and rehearsal — **script written, not yet run**
`task smoke` runs both incidents unattended with assertions that the failures still happen. Then
timed dress rehearsals against the real environment.

**Done when:** smoke passes end to end and the run fits 22 minutes of demo time.

### 6. Documentation
RUNBOOK and SCRIPT in English, rewritten for AWS: what is provisioned the night before,
what the preflight covers, what to do when the venue network dies, per-incident timings, and the
teardown checklist.

### 7. Deck — **built, 2026-09-13**
`slides/talk.md` on `naviteq-slidev`, fifteen slides. Not the talk: the talk is the
terminal, and the theory moved into it as cards. This is the **fallback and the handout**,
which is a different artefact and a much thinner one. It carries only what a terminal cannot
show — the architecture, the feedback loop, the checklist — plus a recorded run of each
incident.

Two outputs from the one source:

- `task deck:build` → `slides/dist`, self-contained and offline. This is the one to present
  from: the recordings play, the clicks work.
- `task deck:pdf` → `slides/talk.pdf` for SlideShare, which takes PDF or PPTX and plays
  nothing at all. The PDF keeps the story and the QR; the recordings become still frames,
  which is why the cover carries a link to the built version.

The recordings are asciinema casts, one per incident rather than one for the whole show, so
a cluster that dies at step 2.2 costs 2.2 and nothing else. Text stays text: sharp at any
projector resolution, and about 100 KB against hundreds of megabytes for video. The player
is vendored into `slides/public/vendor/` because the situation it exists for is the venue
network being down.

**Nothing on a slide fetches anything.** That rule is what shapes the rest of the deck:

- The two brand faces, DM Sans and Fira Code, are served from `slides/fonts/` with
  `fonts.provider: none`, because a webfont that fails to load is a silent downgrade to the
  system sans. Sizes come from one scale defined in `slides/style.css`, not from whatever
  Tailwind step looked right on the slide being written.
- The four diagrams are Excalidraw scenes, generated by `scripts/build-diagrams.py` and
  rendered to flat SVG by `task deck:diagrams`. The Excalidraw renderer itself comes from a
  CDN, so it runs once, here, and only the SVG ships. Sources and output are both committed;
  the sources open in Excalidraw or the Obsidian plugin if a picture needs editing by hand.
- The recordings are sized by `.nq-cast-frame` in `style.css`: the stage is a 120x36
  terminal, and left to fill the slide the player comes out half a screen past the bottom.
  That width and the default recording geometry in `task deck:record` move together. A cast
  recorded at screen size instead (`GEOM=native`) has too many columns for that window and
  takes `nq-cast-full` — the whole canvas, no chrome — which `task deck:split` emits on its
  own once it sees the wider header. Either way the player reads its geometry out of the
  cast, so a recording is never replayed in a shape it did not run in.
- One recording ships, not one per step. `task deck:split` writes `full.cuts.json` — a
  boundary per step — and a slide names its step rather than a file. A segment cut into its
  own cast starts on a blank terminal, because an asciicast is a stream of writes and not a
  sequence of frames: the pane borders, k9s and the load panel were drawn before the cut and
  never repaint, so they are absent from the segment. Seeking into the whole recording makes
  the player rebuild the screen from the history in single-digit milliseconds. The cut times
  are measured with the same `idleTimeLimit` the deck plays with, and the manifest carries it
  so the two cannot drift — capping dead air moves the player's clock away from the
  recording's, and a cut in recording seconds lands minutes from its step.

- The stage runs tmux without left/right margins. tmux fences the cursor into a pane's column
  band to redraw it; the deck's player does not implement that and takes the writes at full
  width, so a recording plays back with the right-hand panes smeared across the screen. It is
  invisible until it is on a slide, so `scripts/cast-lint.py` looks for it at record time and
  `task deck:record:probe` settles it in ten seconds without a cluster.

Slide fit is checked rather than eyeballed — every slide, at every click, against the 980x551
canvas.

Outstanding: `npm i -g playwright-chromium` before the first PDF export, diagram render or
`task deck:check`. The recording and the QR are real.

### 8. Contingency
The original demo's proudest claim was that it needed no internet. This one cannot make that
claim, so the fallback is built rather than assumed: `scripts/preflight.sh` for a backstage
check of credentials, cluster, RDS, SQS, Karpenter, KEDA, row count and baseline nodes;
phone tethering as the primary uplink with venue Wi-Fi as backup; and a recorded full run
plus the exported deck if the network dies on stage.

## Risks

| Risk | Mitigation |
| --- | --- |
| **Infrastructure left running** | Three layers: `task down` with verification, `task cost:check`, TTL Lambda. RDS destroyed to a snapshot, never left stopped |
| Venue network fails mid-demo | Tethering first, recorded fallback, deck stands alone |
| `kubectl` calls STS on every invocation, so a blip breaks the driver | Accept and cover with the recording; document the reconnect path |
| Failures do not reproduce on cloud timings | Phase 3 exists for exactly this; three-run rule before moving on |
| Spot capacity unavailable on the day | NodePool spans several instance types and both AZs; on-demand fallback within quota |
| Karpenter slow to provision on the day | Warm one node before going on stage |
| 8 vCPU quota blocks the scale-out step | Designed to fit; request an increase early as insurance, but do not depend on it |
| Two incidents overrun 35 minutes | Incidents run independently; RUNBOOK carries a short cut and per-step timings |

## Open questions

1. **The load generator's home** — in-cluster or on the laptop (phase 4). Leaning
   in-cluster, but it is worth deciding against a real measurement rather than in advance.
2. **Whether to request the vCPU quota increase now.** It costs nothing to ask and takes
   days to arrive, so asking early is cheap insurance even though the design does not need it.
