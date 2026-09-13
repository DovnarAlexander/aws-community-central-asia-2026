#!/usr/bin/env bash
# Incident 2 -- one readiness probe takes every replica out of service, and the
# autoscalers respond by spending money.
#
# This incident merges what used to be two. The old incident 2 (readiness tied to the
# database) and the planned third incident (queue, KEDA, Karpenter) share one root
# cause: a probe asking about a shared dependency. Told separately they teach
# the same lesson twice; together they are one cascade that starts in the
# database and ends on an invoice.

M2=k8s/incident2

# ── 2.1 ──────────────────────────────────────────────────────────────────────
b_2_1() {
  say "In the first incident a pod killed itself. In this one every replica leaves the load balancer at once, and the autoscalers try to help."
  say ""
  say "A month has passed. Timur has grown, and now writes deliberately."
  say ""
  timur "Rewrote readiness. It is honest now."
  timur "Every call goes to the database and checks the data is actually readable."
  ruslan "LGTM. It checks a real dependency. That is the right thing to do."
  madina "..."
  ruslan "Madina?"
  madina "Nothing. It passed review."
  showdiff "k8s/incident1/14-liveness-fixed.yaml" "$M2/20-ready-db-each-call.yaml"

  run "envsubst < $M2/20-ready-db-each-call.yaml | kubectl apply -f -"

  # The best use of a signed card in the show: she has just said "Nothing. It
  # passed review." and the note appears anyway. The room gets the objection she
  # swallowed, which is also the objection the next twelve minutes are about.
  say ""
  say "She does not say it out loud. She writes it down."
  teach_madina 'HOW A READINESS FAILURE ACTUALLY REMOVES A POD' \
    'The Service does not route to pods. It routes to an EndpointSlice,' \
    'and readiness is what puts an address in it or takes it out.' \
    '' \
    'One pod NotReady   -> its address is removed, the rest carry the load.' \
    'Every pod NotReady -> the slice is empty and the Service has nowhere' \
    '                      to send anything. No error, no traffic, no pods.' \
    '' \
    'So the blast radius of a readiness probe is not one replica.' \
    'It is every replica that shares whatever the probe is asking about.' \
    -- 'kubectl -n demo rollout status deploy/svc --timeout=5s' 240 "three replicas ready"

  say ""
  say "Three replicas, probing every two seconds. One and a half scans per second."
  run "kubectl exec -n demo deploy/dbshell -- sh -c \"psql \\\"\\\$DSN\\\" -c \\\"SELECT count(*) AS conns, count(*) FILTER (WHERE state='active') AS active, current_setting('max_connections') AS max FROM pg_stat_activity WHERE datname=current_database()\\\"\""

  pg "Twelve connections out of fifty-seven. I did not even wake up."
  ruslan "All green. Zero incidents."
  madina "While there are three replicas, yes."
}

# ── 2.2 ──────────────────────────────────────────────────────────────────────
b_2_2() {
  say "Black Friday. The work arrives -- as a queue, which is what the whole system was built for."
  run "kubectl -n demo get scaledobject worker"
  say ""
  say "KEDA watches the queue. Zero workers right now, because there is nothing to do."

  # Labelled incident2-before because that is what it is: this run spans the whole
  # cascade, and step 2.4 compares it against the run after the fix. It used to
  # be labelled act2-fill, which no step ever asked for, so the before and after
  # table at the end of incident 2 had nothing to read.
  load_start enqueue 20 "incident2-before" 90s 20
  say "Filling the queue: two thousand messages a second going in."

  # KEDA polls every five seconds and the first worker still has to be
  # scheduled, so the first half-minute is the autoscaler thinking. That is
  # the window in which to say what it is actually doing.
  teach 'KEDA, AND WHAT IT IS COUNTING' \
    "$(_col 20 'pollingInterval 5')it asks SQS how deep the queue is" \
    "$(_col 20 'queueLength 20')messages per worker it is willing to tolerate" \
    "$(_col 20 'maxReplicaCount 24')the ceiling, and the only thing stopping it" \
    '' \
    'desired workers = queue depth / 20, capped at 24.' \
    'minReplicaCount is 0, so this scales up from nothing at all.' \
    '' \
    'Nothing in that formula knows why the queue is deep. A queue that' \
    'grows because the workers are stuck looks exactly like a queue that' \
    'grows because there is a lot of work.' \
    -- 'kubectl -n demo get pods -l app=worker --no-headers 2>/dev/null | grep -q .' \
    120 "first workers scheduled"

  keda "Queue is deep. Adding workers."
  karpenter "Pods are Pending. Buying machines."
  watch_scale 80 "queue depth up, workers up, nodes up"

  run "kubectl get nodes -l role=demo"
  ruslan "This is the system working. Look at it scale."
  madina "Look at what each new worker does before it processes anything."
}

# ── 2.3 ──────────────────────────────────────────────────────────────────────
b_2_3() {
  madina "Every replica opens its own pool. Four connections each."
  madina "And every replica scans two million rows every two seconds, because that is what its readiness probe does."
  ruslan "That is a health check."
  madina "That is a health check multiplied by the replica count."
  say ""
  say "At three replicas it was a third of a core. KEDA is allowed twenty-four."
  pg "Twenty-four workers at four connections is ninety-six. I have fifty-seven."
  pg "And two vCPU, which are now entirely yours."

  run "kubectl exec -n demo deploy/dbshell -- sh -c \"psql \\\"\\\$DSN\\\" -c \\\"SELECT state, count(*), max(now()-query_start)::interval(0) AS longest FROM pg_stat_activity WHERE datname=current_database() GROUP BY state ORDER BY 2 DESC\\\"\""
  run "kubectl -n demo logs -l app=worker --tail=3 --prefix 2>/dev/null | grep -i 'too many\\|pool at\\|process:' | tail -8"

  timur "\"too many connections\". The pods are up and they are not Ready."
  madina "And a worker that cannot reach the database does not delete its message."
  madina "The message comes back. The queue gets deeper."
  keda "Queue is deeper. Adding workers."
  madina "That is the loop."

  # The one picture the whole talk is built on. It goes up before the window
  # it explains, and the right-hand panes keep running underneath it -- the
  # room reads the loop and watches it turn at the same time.
  teach_madina 'THE LOOP' \
    'probe asks the DB  ->  replicas NotReady  ->  workers stop consuming' \
    '  ^                                                     |' \
    '  |                                                     v' \
    ' more nodes bought  <-  KEDA adds workers  <-  queue depth grows' \
    '' \
    'Every turn adds connections to the database that is already the' \
    'bottleneck, which makes the next turn worse. Nothing in the loop' \
    'is broken. Every component is doing exactly what it was asked.' \
    '' \
    'The only part of it with a price tag is the bottom left.'

  watch_scale 120 "throughput at zero, nodes still climbing"

  run "kubectl -n demo get endpointslices -l kubernetes.io/service-name=svc -o custom-columns=NAME:.metadata.name,READY:.endpoints[*].conditions.ready"
  timur "No endpoints left in the Service. Not one."

  mark_restarts "incident2-before"
  mark_nodes "incident2-before"
  mark_workers "incident2-before"
  load_stop

  badsay "Scaling did not save the service. Scaling is what took it down -- and it bought hardware to do it."
  vote "what do you do first?" \
    "raise maxReplicaCount -- there are clearly not enough workers" \
    "restart the database -- it is slow" \
    "raise timeoutSeconds on the probe -- let it wait"
}

# ── 2.4 ──────────────────────────────────────────────────────────────────────
b_2_4() {
  reveal "none of the three."
  say "All three add work to the database, and the database is where everyone is already stuck. The first one also buys more machines."
  say ""
  madina "Unhook the probe from the database."
  madina "A background goroutine does SELECT 1 every two seconds with a timeout and stores the result in a flag."
  madina "The probe reads the flag. That is all."
  timur "And if the database really does go down?"
  madina "The flag goes stale and the pod honestly leaves the load balancer."
  ruslan "All sixteen at once?"
  madina "One at a time, as each flag expires. And the database gets not one extra query."
  say ""
  say "The probe now costs O(1). Sixteen replicas or a hundred and sixty, it is the same."
  madina "Two more things. The pool is budgeted against the wall: three connections, not four."
  madina "And KEDA gets a ceiling. An autoscaler without one is a way to turn an incident into an invoice."
  showdiff "$M2/20-ready-db-each-call.yaml" "$M2/21-ready-cached.yaml"

  run "envsubst < $M2/21-ready-cached.yaml | kubectl apply -f -"

  teach_madina 'THE FIX, IN THREE PARTS' \
    '1  The probe reads a flag, not the database. A goroutine refreshes' \
    '   the flag on its own schedule, so the cost is O(1) in replicas' \
    '   instead of O(n) -- and a stale flag still takes the pod out.' \
    '' \
    '2  The pool is budgeted against the wall: replicas x POOL_MAX has' \
    '   to stay under max_connections, with room for everything else.' \
    '' \
    '3  maxReplicaCount is 12, not 24. An autoscaler without a ceiling' \
    '   is a way to turn an incident into an invoice.' \
    '' \
    'Only the first one is about probes. The other two decide how far' \
    'the next mistake gets before something stops it.' \
    -- 'kubectl -n demo rollout status deploy/svc --timeout=5s' 300 "api ready"

  pause "Same queue, same database, same cluster." \
    "click to fill the queue again"
  load_start enqueue 20 "incident2-after" 90s 20

  # Said before the window rather than after it. Ninety seconds is a long time to
  # watch numbers with nothing to listen to, and these lines are what the room is
  # supposed to be watching FOR -- afterwards they are a summary, here they are
  # instructions.
  #
  # And not "draining": two thousand messages a second go in while twelve workers
  # take them out one aggregation at a time, so the depth keeps climbing. Saying
  # otherwise in front of a panel that shows the number would cost the talk every
  # bit of credit the previous fifteen minutes earned -- so say it first.
  madina "Two things, while this runs. The workers column, and the node count."
  madina "Every worker that comes up should go Ready and stay Ready. And the node count should not move."
  say "The queue will not go down -- two thousand a second go in, and twelve workers cannot outrun that. Watch the other two numbers."
  watch_scale 90 "every worker Ready, node count flat"

  run "kubectl exec -n demo deploy/dbshell -- sh -c \"psql \\\"\\\$DSN\\\" -c \\\"SELECT count(*) AS conns, count(*) FILTER (WHERE state='active') AS active, current_setting('max_connections') AS max FROM pg_stat_activity WHERE datname=current_database()\\\"\""
  pg "Forty-five connections, almost nothing active. Carry on."

  mark_restarts "incident2-after"
  mark_nodes "incident2-after"
  mark_workers "incident2-after"
  load_stop

  compare "incident2-before" "incident2-after" "INCIDENT 2 . same queue, before and after unhooking the probe"
  ruslan "Same load. Same scale target."
  madina "Different probe."

  say ""
  madina "Twelve workers. Twelve Ready. A minute ago there were twenty-four and next to none of them served."
  timur "So we are still behind."
  madina "Behind, and working. Those twenty-four took messages and handed every one of them back."
  madina "These twelve finish what they take. One probe changed. Nothing else did."

  karpenter "Nothing is Pending. I have stopped buying."
  say "And nothing new was bought. Karpenter gives the idle machines back a couple of minutes later. It was never the problem -- it did what it was asked."

  bigsay "readiness = can THIS pod serve, not is the shared database alive."
}

step "2.1" "The review that let it through"          b_2_1
step "2.2" "Black Friday: the queue fills"           b_2_2
step "2.3" "The cascade, and the autoscalers help"   b_2_3
step "2.4" "Madina unhooks the probe"                b_2_4
