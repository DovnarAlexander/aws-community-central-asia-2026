#!/usr/bin/env bash
# Act 1 -- a healthy pod kills itself.
#
# A beat is a scene: the characters speak, the driver runs commands, and our own
# narration (say) appears only where the output on screen would otherwise be
# unreadable. Everything printed is read aloud straight off the screen.

M=k8s/act1

# ── 1.1 ──────────────────────────────────────────────────────────────────────
b_1_1() {
  timur "Service is done. Takes 30 seconds to start: warms a cache, opens a pool, reads config."
  timur "After that it flies."
  ruslan "Got a probe?"
  timur "Copied one out of an article. It was right there in the example."
  madina "What are the numbers?"
  timur "initialDelay 5, period 5, timeout 1, three misses. Same as everyone."
  show "$M/10-liveness-naive.yaml"

  run "envsubst < $M/10-liveness-naive.yaml | kubectl apply -f -"

  say ""
  say "The pod is Pending. There is nowhere to put it -- so Karpenter goes shopping."
  karpenter "One pod with nowhere to go. Buying a machine."
  # Measured at about 20 seconds from Pending to Ready on spot t4g capacity in
  # eu-central-1. 40 leaves room for a slow day without stalling the beat.
  watch_pods 40 "Pending -- waiting on EC2" "app=svc"
  wait_for 'kubectl -n demo get pods -l app=svc --no-headers | grep -qv Pending' 180 "node arrived, pod scheduled"

  kubelet "Five seconds gone. Asking: are you alive?"
  timur "It is warming up."
  kubelet "That answer is not in the manifest."
  say ""
  say "The warmup runs 30 seconds. The first knock lands at five. Count along."
  watch_pods 80 "watch the RESTARTS column" "app=svc"

  run "kubectl -n demo get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail -5"
  kubelet "Three misses in a row. Killing it."
  timur "I did not write a single bug!"
  kubelet "I do not read your code. I read your manifest."

  badsay "Nobody touched the code and there is no traffic yet. Arithmetic killed the pod."
}

# ── 1.2 ──────────────────────────────────────────────────────────────────────
b_1_2() {
  ruslan "CrashLoop? Seen it a hundred times. One line fixes it."
  timur "Which one?"
  ruslan "The one with the number in it."
  showdiff "$M/10-liveness-naive.yaml" "$M/11-liveness-initialdelay.yaml"
  ruslan "Forty is bigger than thirty. We are done here."
  madina "What if the start gets slower?"
  ruslan "Why would it?"

  run "envsubst < $M/11-liveness-initialdelay.yaml | kubectl apply -f -"
  wait_for 'kubectl -n demo rollout status deploy/svc --timeout=5s' 200 "pod up"
  run "kubectl -n demo get pods -l app=svc"
  ruslan "Green. Told you."

  pause "A week passes. The cache is cold, Karpenter has packed two more containers onto the node, and CPU is now shared. The service starts in 60 seconds, not 30."

  run "kubectl -n demo set env deploy/svc WARMUP_SECONDS=60"
  ruslan "I did not touch the manifest."
  madina "The manifest did not change. Everything around it got slower."
  kubelet "Forty seconds gone. Asking: are you alive?"
  watch_pods 90 "same manifest, slower environment" "app=svc"

  badsay "initialDelaySeconds is a bet that tomorrow looks like today."
}

# ── 1.3 ──────────────────────────────────────────────────────────────────────
b_1_3() {
  madina "May I? The documentation has a startupProbe."
  ruslan "You read the documentation?"
  madina "All of it."
  ruslan "..."
  madina "Until startup says ready, liveness and readiness are not consulted at all."
  timur "So the start gets its own time budget?"
  madina "Its own. Two minutes if it wants. It does not affect the liveness period."
  showdiff "$M/11-liveness-initialdelay.yaml" "$M/12-startup-probe.yaml"

  run "envsubst < $M/12-startup-probe.yaml | kubectl apply -f -"
  say ""
  say "Same 60-second warmup as before. Watch the RESTARTS column."
  watch_pods 80 "0/1 -- but no restarts" "app=svc"
  wait_for 'kubectl -n demo rollout status deploy/svc --timeout=5s' 200 "ready, zero restarts"
  kubelet "I was told to wait, so I waited. Nobody told me before."

  bigsay "A slow start is no longer punished with a restart."
}

# ── 1.4 ──────────────────────────────────────────────────────────────────────
b_1_4() {
  timur "Start is fixed. Rolling out the production configuration."
  timur "Three replicas, 10-second warmup, /work doing a real query against RDS."
  ruslan "Touching liveness?"
  timur "Why? It is green."
  madina "It goes to the database through the same pool as /work."
  ruslan "Pool of four, the query is trivial. Ship it."
  showdiff "$M/12-startup-probe.yaml" "$M/13-under-load.yaml"

  run "envsubst < $M/13-under-load.yaml | kubectl apply -f -"
  wait_for 'kubectl -n demo rollout status deploy/svc --timeout=5s' 240 "three replicas ready"
  run "kubectl -n demo get pods -l app=svc -o wide"

  pause "Here comes traffic. The service is healthy. It is simply busy."
  load_start http 300 "act1-before" 0s 100
  say "The pool is full of real work, and /healthz joins the same queue."
  kubelet "A second gone, no answer. Again. And again."
  kubelet "Three misses. Killing it."
  watch_pods 120 "liveness cannot meet timeoutSeconds: 1" "app=svc"

  mark_restarts "act1-before"
  load_stop

  run "kubectl -n demo get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail -6"
  timur "It is alive! It is just busy!"
  kubelet "I cannot tell busy from dead. I only own a timer."

  badsay "Liveness should ask whether the process is alive. It asked how fast it answers."
  vote "who took down a healthy service?" \
    "Timur -- copied a probe out of an article" \
    "Ruslan -- tuned numbers and left liveness alone" \
    "kubelet -- pulled the trigger"
}

# ── 1.5 ──────────────────────────────────────────────────────────────────────
b_1_5() {
  madina "None of the three. It was the wrong question."
  ruslan "Meaning?"
  madina "Liveness answers one thing: is the process alive. You do not visit a database for that."
  madina "And do not rush it -- generous timeout, more misses allowed."
  timur "Then what takes a busy pod out of rotation?"
  madina "Readiness. That one is allowed to be twitchy."
  ruslan "One probe softer, the other sharper. Fine."
  showdiff "$M/13-under-load.yaml" "$M/14-liveness-fixed.yaml"

  run "envsubst < $M/14-liveness-fixed.yaml | kubectl apply -f -"
  wait_for 'kubectl -n demo rollout status deploy/svc --timeout=5s' 240 "three replicas ready"

  pause "Same load. Same service. Same hardware."
  load_start http 300 "act1-after" 0s 100
  watch_pods 120 "RESTARTS should stay at zero" "app=svc"

  mark_restarts "act1-after"
  load_stop

  compare "act1-before" "act1-after" "ACT 1 . same load, before and after the probe fix"
  ruslan "p95 is the same as it was."
  madina "The service did not get faster. It stopped shooting at itself."

  reveal "option four -- the question the probe was asking."
  say "It asked \"are you answering quickly\" and punished the answer as if it meant \"are you dead\"."
  bigsay "The load never changed. What took the service down was the health check."
}

beat "1.1" "Timur ships a service"                 b_1_1
beat "1.2" "Ruslan comes to the rescue"            b_1_2
beat "1.3" "Madina reads the documentation"        b_1_3
beat "1.4" "Production config, and real traffic"   b_1_4
beat "1.5" "End of act 1 -- before and after"      b_1_5
