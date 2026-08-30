#!/usr/bin/env bash
# Act 2 -- one readiness probe takes every replica out of service, and the
# autoscalers respond by spending money.
#
# This act merges what used to be two. The old act 2 (readiness tied to the
# database) and the planned third act (queue, KEDA, Karpenter) share one root
# cause: a probe asking about a shared dependency. Told separately they teach
# the same lesson twice; together they are one cascade that starts in the
# database and ends on an invoice.

M2=k8s/act2

# ── 2.1 ──────────────────────────────────────────────────────────────────────
b_2_1() {
  say "In act 1 a pod killed itself. In act 2 every replica leaves the load balancer at once, and the autoscalers try to help."
  say ""
  say "A month has passed. Timur has grown, and now writes deliberately."
  say ""
  timur "Rewrote readiness. It is honest now."
  timur "Every call goes to the database and checks the data is actually readable."
  ruslan "LGTM. It checks a real dependency. That is the right thing to do."
  madina "..."
  ruslan "Madina?"
  madina "Nothing. It passed review."
  showdiff "k8s/act1/14-liveness-fixed.yaml" "$M2/20-ready-db-each-call.yaml"

  run "envsubst < $M2/20-ready-db-each-call.yaml | kubectl apply -f -"
  wait_for 'kubectl -n demo rollout status deploy/svc --timeout=5s' 240 "three replicas ready"

  say ""
  say "Three replicas, probing every two seconds. One and a half scans per second."
  run "kubectl -n demo get pods -l app=svc"
  run "kubectl exec -n demo deploy/dbshell -- sh -c 'psql \"\$DSN\" -c \"SELECT count(*) AS conns, count(*) FILTER (WHERE state=\\\"active\\\") AS active, current_setting(\\\"max_connections\\\") AS max FROM pg_stat_activity WHERE datname=current_database()\"'"

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

  load_start enqueue 20 "act2-fill" 90s 20
  say "Filling the queue: two thousand messages a second going in."
  keda "Queue is deep. Adding workers."
  karpenter "Pods are Pending. Buying machines."
  watch_scale 120 "queue depth up, workers up, nodes up"

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

  run "kubectl exec -n demo deploy/dbshell -- sh -c 'psql \"\$DSN\" -c \"SELECT state, count(*), max(now()-query_start)::interval(0) AS longest FROM pg_stat_activity WHERE datname=current_database() GROUP BY state ORDER BY 2 DESC\"'"
  run "kubectl -n demo logs -l app=worker --tail=3 --prefix 2>/dev/null | grep -i 'too many\\|pool at\\|process:' | tail -8"

  timur "\"too many connections\". The pods are up and they are not Ready."
  madina "And a worker that cannot reach the database does not delete its message."
  madina "The message comes back. The queue gets deeper."
  keda "Queue is deeper. Adding workers."
  madina "That is the loop."

  watch_scale 150 "throughput at zero, nodes still climbing"

  run "kubectl -n demo get endpointslices -l kubernetes.io/service-name=svc -o custom-columns=NAME:.metadata.name,READY:.endpoints[*].conditions.ready"
  timur "No endpoints left in the Service. Not one."

  mark_restarts "act2-before"
  mark_nodes "act2-before"
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
  wait_for 'kubectl -n demo rollout status deploy/svc --timeout=5s' 300 "api ready"

  pause "Same queue, same database, same cluster."
  load_start enqueue 20 "act2-after" 90s 20
  watch_scale 150 "workers Ready, queue draining, node count flat"

  run "kubectl exec -n demo deploy/dbshell -- sh -c 'psql \"\$DSN\" -c \"SELECT count(*) AS conns, count(*) FILTER (WHERE state=\\\"active\\\") AS active, current_setting(\\\"max_connections\\\") AS max FROM pg_stat_activity WHERE datname=current_database()\"'"
  pg "Forty-five connections, almost nothing active. Carry on."

  mark_restarts "act2-after"
  mark_nodes "act2-after"
  load_stop

  compare "act2-before" "act2-after" "ACT 2 . same queue, before and after unhooking the probe"
  ruslan "Same load. Same scale target."
  madina "Different probe."

  karpenter "Nothing is Pending. Consolidating."
  say "And the nodes go back. Karpenter was never the problem -- it was doing exactly what it was asked."

  bigsay "readiness = can THIS pod serve, not is the shared database alive."
}

beat "2.1" "The review that let it through"          b_2_1
beat "2.2" "Black Friday: the queue fills"           b_2_2
beat "2.3" "The cascade, and the autoscalers help"   b_2_3
beat "2.4" "Madina unhooks the probe"                b_2_4
