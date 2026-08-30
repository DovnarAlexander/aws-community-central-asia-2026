# The AWS credentials every part of the demo needs, defaulted in one place.
#
# Five separate processes talk to AWS during the talk -- the driver, the stat
# panel, k9s, kubectl's EKS auth plugin, and whatever the driver shells out to
# -- and each is started by something different: `task`, a bare shell, or a
# tmux pane inherited from a server that may have been running since before
# this repository existed.
#
# Only `task` sets AWS_PROFILE, from the env block in Taskfile.yml. Anything
# started any other way authenticated as nobody, and the failure surfaced far
# from its cause: `terragrunt output` returned an empty string, `aws sqs
# get-queue-url` returned an empty string, and the driver reported "cannot find
# the environment" as though the infrastructure were missing. It was up.
#
# Assignments are conditional, so an explicitly exported profile still wins.
: "${AWS_PROFILE:=personal}"
: "${AWS_REGION:=eu-central-1}"
export AWS_PROFILE AWS_REGION
