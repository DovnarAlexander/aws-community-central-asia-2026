#!/usr/bin/env bash
# Incident 1 -- a healthy pod kills itself.
#
# A step is a scene: the characters speak, the driver runs commands, and our own
# narration (say) appears only where the output on screen would otherwise be
# unreadable. Everything printed is read aloud straight off the screen.
#
# The theory lives here too, as cards inside the waits. There is no slide deck in
# front of this incident any more: a probe is explained at the moment the cluster is
# about to demonstrate it, which is also the moment the room is otherwise
# watching a rollout settle. See `teach` in lib/demo.sh.
#
# One rule holds everywhere: the card goes up BEFORE the wait it covers, never
# after. `teach` does that by construction -- it prints, then polls -- and where
# a step drives its own waiting, `notes` prints the card and the watching
# happens underneath. A wait that opens in silence and gets explained once it is
# over is the thing all of this exists to avoid.

M=k8s/incident1

# ── 1.1 ──────────────────────────────────────────────────────────────────────
b_1_1() {
  timur "Service is done. Takes 10 seconds to start: warms a cache, opens a pool, reads config."
  timur "After that it flies."
  ruslan "Got a probe?"
  timur "Copied one out of an article. It was right there in the example."
  madina "What are the numbers?"
  timur "initialDelay 2, period 1, timeout 1, three misses. Straight out of the example."
  show "$M/10-liveness-naive.yaml"

  run "envsubst < $M/10-liveness-naive.yaml | kubectl apply -f -"

  say ""
  say "The pod is Pending. There is nowhere to put it -- so Karpenter goes shopping."
  karpenter "One pod with nowhere to go. Buying a machine."

  # Karpenter takes 20 to 60 seconds and the room has nothing to look at, so
  # this is where the four numbers get explained -- immediately before they
  # kill something, rather than six minutes ago on a slide.
  #
  # The card goes up first and the waiting happens underneath it: the Pending
  # panel redraws its own lines below, so the numbers stay on screen for the
  # whole wait. The speaker reads them out while Karpenter shops, instead of
  # watching a countdown in silence and explaining afterwards.
  #
  # Signed, and ignored: the titles promise that nobody asks her opinion for a
  # while, and the card being right while the room talks over it is the arc of
  # incident 1 in miniature.
  madina "While we wait. Those four numbers Timur read out -- this is what they do."
  ruslan "Nobody asked."
  notes_madina 'A LIVENESS PROBE, IN FOUR NUMBERS' \
    "$(_col 22 'initialDelaySeconds')2   wait this long before the first question" \
    "$(_col 22 'periodSeconds')1   then ask again this often" \
    "$(_col 22 'timeoutSeconds')1   an answer slower than this is a miss" \
    "$(_col 22 'failureThreshold')3   this many misses in a row and the pod dies" \
    '' \
    'Patience = initialDelay + failureThreshold x period = 5 seconds.' \
    'The service needs 10. Nothing else here is a bug.' \
    '' \
    'kubelet asks. Not a load balancer, not a human, not your code.'

  watch_pods 25 "Pending -- waiting on EC2" "app=svc"
  settle 'kubectl -n demo get pods -l app=svc --no-headers | grep -qv Pending' \
    180 "node arrived, pod scheduled"

  kubelet "Two seconds gone. Asking: are you alive?"
  timur "It is warming up."
  kubelet "That answer is not in the manifest."
  say ""
  say "The warmup runs ten seconds. The first knock lands at two. Count along."
  # First kill at ~5s, the second at ~20s once CrashLoopBackOff adds its ten.
  # Two restarts is the whole argument; a third costs another half minute.
  watch_pods 25 "watch the RESTARTS column" "app=svc"

  kubelet "Three misses in a row. Killing it."
  timur "I did not write a single bug!"
  kubelet "I do not read your code. I read your manifest."

  badsay "Nobody touched the code and there is no traffic yet. Arithmetic killed the pod."
}

# ── 1.2 ──────────────────────────────────────────────────────────────────────
# Two steps merged into one. Ruslan raising the number and Madina producing the
# startupProbe are a question and its answer; told as separate steps they cost
# an extra step header, an extra rollout and an extra before/after, which is
# about three minutes for a lesson that is already one lesson.
b_1_2() {
  ruslan "CrashLoop? Seen it a hundred times. One line fixes it."
  timur "Which one?"
  ruslan "The one with the number in it."
  showdiff "$M/10-liveness-naive.yaml" "$M/11-liveness-initialdelay.yaml"
  ruslan "Twelve is bigger than ten. We are done here."
  madina "What if the start gets slower?"
  ruslan "Why would it?"

  run "envsubst < $M/11-liveness-initialdelay.yaml | kubectl apply -f -"

  # This one used to be a card and is better as an argument, in her voice: it
  # has nothing to look up in it, only a claim to make. The rollout settles
  # underneath while she makes it.
  madina "It holds because nothing changed. Not because the number is right."
  madina "A cold cache. A noisier neighbour on the node. A bigger dataset. One more step at boot."
  madina "None of those touch the manifest, and every one of them moves the start."
  madina "Every other number in a probe reacts to something the process did. This one only counts."
  madina "It cannot tell a slow start from a dead process, because it is not looking."
  settle 'kubectl -n demo rollout status deploy/svc --timeout=5s' 200 "pod up"

  run "kubectl -n demo get pods -l app=svc"
  ruslan "Green. Told you."

  pause "A week passes. The cache is cold, Karpenter has packed two more containers onto the node, and CPU is now shared. The service starts in 20 seconds, not 10." \
    "click to move a week forward"

  # Not a step improving the application: the same application, somewhere
  # slower. It is still a change to WARMUP_SECONDS, so it is still announced --
  # the room has to see that the manifest is untouched and the world is not.
  appchange timur 'WARMUP_SECONDS  10 -> 20' \
    "Nothing shipped. The start just takes twenty seconds on this node now, so that is what I am setting it to."
  run "kubectl -n demo set env deploy/svc WARMUP_SECONDS=20"
  ruslan "I did not touch the manifest."
  madina "The manifest did not change. Everything around it got slower."
  kubelet "Twelve seconds gone. Asking: are you alive?"
  # Patience is 12 + 3x1 = 15 seconds against a 20-second start: the kill lands
  # at 15, five seconds before the service would have been ready. Both numbers
  # go to the room before the race rather than after it -- a countdown nobody
  # has been told the terms of is just a countdown.
  say ""
  say "Two numbers are racing. Patience runs out at fifteen seconds. The service is ready at twenty."
  watch_pods 25 "same manifest, slower environment" "app=svc"

  badsay "initialDelaySeconds is a bet that tomorrow looks like today."

  madina "May I? The documentation has a startupProbe."
  ruslan "You read the documentation?"
  madina "All of it."
  ruslan "..."
  madina "Until startup says ready, liveness and readiness are not consulted at all."
  timur "So the start gets its own time budget?"
  madina "Its own. Two minutes if it wants. It does not affect the liveness period."
  showdiff "$M/11-liveness-initialdelay.yaml" "$M/12-startup-probe.yaml"

  run "envsubst < $M/12-startup-probe.yaml | kubectl apply -f -"

  # The same 20-second start as a moment ago, and this time nothing punishes it.
  # The pod sits at 0/1 while the card explains what the three probes are for;
  # the pods pane on the right keeps showing it.
  madina "The whole of it is one page. Here."
  teach_madina 'THREE PROBES, THREE QUESTIONS' \
    "$(_col 12 'startup')has it finished booting?" \
    "$(_col 12 'liveness')is the process alive?      -> restart the container" \
    "$(_col 12 'readiness')can it serve right now?    -> out of the load balancer" \
    '' \
    'While startup runs, the other two are not consulted at all.' \
    'Its budget is its own: failureThreshold x period = 60 x 2 = 120s.' \
    'Once it passes it is never consulted again.' \
    '' \
    'So boot gets a deadline, and liveness goes back to asking about' \
    'steady state, which is what it was for.' \
    -- 'kubectl -n demo rollout status deploy/svc --timeout=5s' 200 "ready, zero restarts"

  watch_pods 20 "same slow start, RESTARTS still 0" "app=svc"
  kubelet "I was told to wait, so I waited. Nobody told me before."

  bigsay "A slow start is no longer punished with a restart."
}

# ── 1.3 ──────────────────────────────────────────────────────────────────────
b_1_3() {
  timur "Start is fixed. Rolling out the production configuration."
  timur "Three replicas, and /work doing a real query against RDS."
  # Two application-level changes go out in this one manifest, and the second is
  # the entire mechanism of the incident. Leaving it inside the diff for the
  # room to spot is how a step ends up looking like the probe broke on its own.
  appchange timur 'WARMUP_SECONDS  20 -> 10' \
    "Real hardware for production, so boot is back to ten seconds."
  appchange timur 'HEALTHZ_MODE  local -> db' \
    "And I made /healthz honest: it queries the database now, same as /work. A health check that checks nothing is not a health check."
  ruslan "Touching liveness?"
  timur "Why? It is green."
  madina "It goes to the database through the same pool as /work."
  ruslan "Pool of four, the query is trivial. Ship it."
  showdiff "$M/12-startup-probe.yaml" "$M/13-under-load.yaml"

  run "envsubst < $M/13-under-load.yaml | kubectl apply -f -"

  madina "Before it ships. These two are not the same question."
  ruslan "It is green, Madina."
  teach_madina 'RESTART OR REMOVE: TWO VERY DIFFERENT ANSWERS' \
    'liveness fails   -> kubelet kills the container. Work in flight dies,' \
    '                    the pool is rebuilt, the cache is cold again.' \
    'readiness fails  -> the pod leaves the EndpointSlice. That is all.' \
    '                    It keeps running, and it comes back by itself.' \
    '' \
    'A busy pod is not a dead pod. Slow is a readiness question.' \
    'Liveness has one job: notice a process that will never recover.' \
    '' \
    'Which makes timeoutSeconds: 1 on liveness a latency alarm wired' \
    'to a kill switch.' \
    -- 'kubectl -n demo rollout status deploy/svc --timeout=5s' 240 "three replicas ready"

  run "kubectl -n demo get pods -l app=svc -o wide"

  pause "Here comes traffic. The service is healthy. It is simply busy." \
    "click to start the traffic"
  # 45 seconds against a 60-second window. The generator prints its summary only
  # when it stops, and a pod deleted mid-run is gone before the log can be read
  # -- so it has to end on its own, inside the window, with room to spare. The
  # kills land in the first half of it either way.
  load_start http 300 "incident1-before" 45s 100
  say "The pool is full of real work, and /healthz joins the same queue."
  kubelet "A second gone, no answer. Again. And again."
  kubelet "Three misses. Killing it."
  # The load pod needs ~10s to start and saturate; the first kills land ~15s
  # after that. 45 seconds shows every replica restart at least once, and the
  # generator's own window is 45 -- this ends with it rather than after it.
  watch_pods 45 "liveness cannot meet timeoutSeconds: 1" "app=svc"

  mark_restarts "incident1-before" "app=svc"
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

# ── 1.4 ──────────────────────────────────────────────────────────────────────
b_1_4() {
  madina "None of the three. It was the wrong question."
  ruslan "Meaning?"
  madina "Liveness answers one thing: is the process alive. You do not visit a database for that."
  madina "And do not rush it -- generous timeout, more misses allowed."
  timur "Then what takes a busy pod out of rotation?"
  madina "Readiness. That one is allowed to be twitchy."
  ruslan "One probe softer, the other sharper. Fine."
  # The one change here that is not a probe. It is Madina's to announce because
  # it is Madina's fix, and it is the first thing she names on the card below.
  appchange madina 'HEALTHZ_MODE  db -> local' \
    "And /healthz stops leaving the process. Whether the database answers is a readiness question, and readiness already asks it."
  showdiff "$M/13-under-load.yaml" "$M/14-liveness-fixed.yaml"

  run "envsubst < $M/14-liveness-fixed.yaml | kubectl apply -f -"

  madina "Two changes. And the list of what I did not touch, which is longer."
  teach_madina 'WHAT CHANGED, AND WHAT DID NOT' \
    "$(_col 22 'HEALTHZ_MODE=local')the check no longer leaves the process" \
    "$(_col 22 'period 10')one question every ten seconds, not five" \
    "$(_col 22 'timeout 3')three seconds to answer, not one" \
    "$(_col 22 'failureThreshold 5')fifty seconds of patience before a kill" \
    '' \
    'Not changed: the code, the traffic, the hardware, the database,' \
    'the readiness probe -- which stays tight on purpose, because' \
    'taking a busy replica out of rotation is exactly its job.' \
    '' \
    'If you cannot say what a restart would fix, do not restart.' \
    -- 'kubectl -n demo rollout status deploy/svc --timeout=5s' 240 "three replicas ready"

  pause "Same load. Same service. Same hardware." \
    "click to start the same traffic again"
  load_start http 300 "incident1-after" 45s 100
  madina "Same three replicas, same three hundred requests a second, same column."
  madina "This time it should not move at all."
  watch_pods 45 "RESTARTS should stay at zero" "app=svc"

  mark_restarts "incident1-after" "app=svc"
  load_stop

  compare "incident1-before" "incident1-after" "INCIDENT 1 . same load, before and after the probe fix"
  ruslan "p95 is the same as it was."
  madina "The service did not get faster. It stopped shooting at itself."

  reveal "option four -- the question the probe was asking."
  say "It asked \"are you answering quickly\" and punished the answer as if it meant \"are you dead\"."
  bigsay "The load never changed. What took the service down was the health check."
}

step "1.1" "Timur ships a service"                    b_1_1
step "1.2" "The number, and the documentation"        b_1_2
step "1.3" "Production config, and real traffic"      b_1_3
step "1.4" "End of incident 1 -- before and after"         b_1_4
