"""Dead-man switch for the demo infrastructure.

Runs hourly. Finds everything tagged Project=<project> whose ExpiresAt tag has
passed and shuts the billable parts of it down, so a forgotten cluster costs an
hour rather than a month.

It deliberately does NOT need Terraform state to work. That is the whole point:
it still fires when the laptop is closed, when a destroy failed halfway, or when
the person who ran `task up` simply forgot. Terraform can always be reconciled
afterwards -- `terraform apply` brings back whatever the reaper removed.

Order matters. EKS managed node groups go to zero first: that kills the Karpenter
controller, so the nodes it owns stay dead once we terminate them. Reversing the
two lets Karpenter helpfully buy replacements for the instances we just killed.

Resources missing an ExpiresAt tag count as expired. Fail-safe beats fail-open
when the failure mode is a bill.
"""

import datetime
import json
import os

import boto3

PROJECT = os.environ["PROJECT_TAG"]
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

ec2 = boto3.client("ec2")
eks = boto3.client("eks")
rds = boto3.client("rds")
sns = boto3.client("sns")


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def _expired(tags):
    """(is_expired, reason). Tags arrive as a plain dict."""
    raw = tags.get("ExpiresAt")
    if not raw:
        return True, "no ExpiresAt tag"
    try:
        exp = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return True, "unparseable ExpiresAt=%s" % raw
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=datetime.timezone.utc)
    if _now() > exp:
        return True, "expired at %s" % raw
    return False, "alive until %s" % raw


def _tags_of(tag_list, key="Key", value="Value"):
    return {t[key]: t[value] for t in (tag_list or [])}


def _is_ours(tags):
    return tags.get("Project") == PROJECT


# ── EKS ──────────────────────────────────────────────────────────────────────


def reap_eks(actions):
    for name in eks.list_clusters().get("clusters", []):
        try:
            cluster = eks.describe_cluster(name=name)["cluster"]
        except eks.exceptions.ResourceNotFoundException:
            continue
        tags = cluster.get("tags", {})
        if not _is_ours(tags):
            continue
        gone, why = _expired(tags)
        if not gone:
            actions.append("eks/%s: kept, %s" % (name, why))
            continue

        for ng_name in eks.list_nodegroups(clusterName=name).get("nodegroups", []):
            ng = eks.describe_nodegroup(clusterName=name, nodegroupName=ng_name)[
                "nodegroup"
            ]
            desired = ng.get("scalingConfig", {}).get("desiredSize", 0)
            if desired == 0:
                continue
            if DRY_RUN:
                actions.append(
                    "eks/%s/%s: WOULD scale %d -> 0 (%s)" % (name, ng_name, desired, why)
                )
                continue
            eks.update_nodegroup_config(
                clusterName=name,
                nodegroupName=ng_name,
                scalingConfig={"minSize": 0, "maxSize": 1, "desiredSize": 0},
            )
            actions.append(
                "eks/%s/%s: scaled %d -> 0 (%s)" % (name, ng_name, desired, why)
            )


# ── EC2 ──────────────────────────────────────────────────────────────────────


def reap_ec2(actions):
    doomed = []
    paginator = ec2.get_paginator("describe_instances")
    pages = paginator.paginate(
        Filters=[
            {"Name": "tag:Project", "Values": [PROJECT]},
            {"Name": "instance-state-name", "Values": ["pending", "running"]},
        ]
    )
    for page in pages:
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                tags = _tags_of(inst.get("Tags"))
                gone, why = _expired(tags)
                iid = inst["InstanceId"]
                if not gone:
                    actions.append("ec2/%s: kept, %s" % (iid, why))
                    continue
                doomed.append(iid)
                actions.append(
                    "ec2/%s (%s): terminating, %s"
                    % (iid, inst.get("InstanceType", "?"), why)
                )

    if doomed and not DRY_RUN:
        ec2.terminate_instances(InstanceIds=doomed)
    elif doomed:
        actions.append("ec2: DRY_RUN, %d instances left alone" % len(doomed))


# ── RDS ──────────────────────────────────────────────────────────────────────


def reap_rds(actions):
    paginator = rds.get_paginator("describe_db_instances")
    for page in paginator.paginate():
        for db in page["DBInstances"]:
            tags = _tags_of(db.get("TagList"))
            if not _is_ours(tags):
                continue
            ident = db["DBInstanceIdentifier"]
            gone, why = _expired(tags)
            if not gone:
                actions.append("rds/%s: kept, %s" % (ident, why))
                continue
            if db["DBInstanceStatus"] != "available":
                actions.append(
                    "rds/%s: skipped, status=%s" % (ident, db["DBInstanceStatus"])
                )
                continue
            if DRY_RUN:
                actions.append("rds/%s: WOULD stop, %s" % (ident, why))
                continue
            # Stop, not delete. A Lambda that deletes databases is a worse
            # problem than the bill it prevents. Stopping drops the instance
            # charge immediately; the human still runs `task down` to remove
            # the storage, and AWS auto-restarts a stopped instance after
            # seven days -- which the next reaper run catches again.
            rds.stop_db_instance(DBInstanceIdentifier=ident)
            actions.append("rds/%s: stopped, %s" % (ident, why))


# ── entrypoint ───────────────────────────────────────────────────────────────


def handler(event, context):
    actions = []
    errors = []

    for name, fn in (("eks", reap_eks), ("ec2", reap_ec2), ("rds", reap_rds)):
        try:
            fn(actions)
        except Exception as exc:  # one broken service must not stop the others
            errors.append("%s: %s" % (name, exc))

    reaped = [a for a in actions if ": kept" not in a and ": skipped" not in a]
    summary = {
        "project": PROJECT,
        "dry_run": DRY_RUN,
        "reaped": len(reaped),
        "actions": actions,
        "errors": errors,
    }
    print(json.dumps(summary))

    # Only speak up when something happened. An hourly "nothing to do" email
    # trains you to ignore the one that matters.
    if (reaped or errors) and SNS_TOPIC_ARN:
        lines = ["Project: %s" % PROJECT, ""]
        if reaped:
            lines.append("Shut down:")
            lines += ["  - %s" % a for a in reaped]
        if errors:
            lines.append("")
            lines.append("Errors:")
            lines += ["  - %s" % e for e in errors]
        lines += ["", "Run `task cost:check` to confirm nothing is left."]
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[%s] reaper shut down %d resource(s)" % (PROJECT, len(reaped)),
            Message="\n".join(lines),
        )

    return summary
