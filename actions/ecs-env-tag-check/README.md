# ecs-env-tag-check

A composite action that checks, read-only, that an ECS service whose task
definition references a mutable environment tag (for example `app:stage`)
actually runs the image that tag points to - so the next Terraform apply
of the service would not silently roll out a different image than the one
that is running.

It is a Ruby port of a reviewed Bash check from `aifinyo-ag/Hubspot`
(`.github/scripts/check-env-tag.sh`). The AWS CLI calls and their flags
are the same, and the JSON handling moved from `jq` to Ruby. It is the
counterpart of [`ecs-deploy-tag`](../ecs-deploy-tag), which moves such a
tag and deploys it.

Deliberate differences from the Bash version:

- `retry-seconds` is an input (the script's sixth argument), not the
  `CHECK_ENV_TAG_RETRY_SECONDS` environment variable.
- A `describe-services` failure entry with an empty `reason` fails the
  check; the Bash version went on.
- A successful `describe-images` without an `imageDigest` fails at once;
  the Bash version compared against the string `null`.
- A missing or `null` `taskArns` or `tasks` list, or AWS output that is
  not JSON, ends in a clean `::error::` line; the Bash version crashed in
  `jq`.
- A service whose one deployment is not `PRIMARY`, or that has none,
  fails as `no PRIMARY deployment`; the Bash version failed with
  `rolloutState (missing)`.
- A running task without a `taskArn` is still checked for `container`;
  in the Bash version such a task without `container` could pass.

## What it does

1. Reads the service (`ecs describe-services`). It must exist - no
   `failures`, exactly one service - and be `ACTIVE`. If a rollout is in
   progress - more than one deployment, or the `PRIMARY` deployment's
   `rolloutState` is `IN_PROGRESS` - it stops here and exits `0` without
   comparing anything (see [Skipped](#what-skipped-means)). Any other
   `rolloutState` (`FAILED`, or none at all) is an error, and so is a
   service whose one deployment is not `PRIMARY`, or that has none.
2. Reads the digest `env-tag` points to (`ecr describe-images`). A missing
   tag is an error: unlike a commit tag, the environment tag is expected
   to always exist.
3. Lists the service's tasks with desired status `RUNNING`
   (`ecs list-tasks`), describes them (`ecs describe-tasks`), and keeps
   only those whose `lastStatus` is `RUNNING` - tasks still starting or
   stopping are ignored. From each it reads the `imageDigest` of
   `container`. No running task, a running task without that container,
   a container without an `imageDigest`, or a task that `describe-tasks`
   reports under `failures` is an error.
4. Compares: every running digest must equal the tag's digest. If so, it
   logs `ok: <env-tag> = <digest> runs on <cluster>/<service>` and exits
   `0`.
5. On a mismatch, it waits `retry-seconds` (default 30) and repeats steps
   1-4 once. `ecs-deploy-tag` moves the tag first and only then calls
   `update-service`, so a check that reads in between sees a mismatch that
   is not drift; by the re-read, that deployment shows up as in progress
   or has finished. If the digests still differ, it logs
   `::error::<env-tag> points to X, but <cluster>/<service> runs Y (also on
   a re-read Ns later)` plus the note that the next Terraform apply on the
   service would roll out X, and exits `1`.

Every AWS call is a read. The action never moves the tag or touches the
service; fixing drift - redeploying the running commit tag, or moving the
tag back - is left to a person.

## Usage

Pin to a commit SHA of this repository, not a branch or tag. A daily
check of both environments, plus an on-demand run for one:

```yaml
on:
  schedule:
    - cron: '17 6 * * *'
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options:
          - stage
          - live
        required: true

jobs:
  check-env-tags:
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        # The schedule checks both environments, a dispatch only the chosen one.
        environment: ${{ fromJSON(github.event_name == 'workflow_dispatch' && format('["{0}"]', inputs.environment) || '["stage","live"]') }}
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@<sha>
        with:
          # ...

      - name: Check app-${{ matrix.environment }} against its tag
        uses: aifinyo-ag/.github/actions/ecs-env-tag-check@<40-character-commit-sha>
        with:
          repository: app
          env-tag: ${{ matrix.environment }}
          cluster: app-${{ matrix.environment }}
          service: app
          container: app
```

`fail-fast: false` keeps one environment's failure from cancelling the
other's check.

A scheduled run always uses the workflow file on the latest commit of the
default branch
([`schedule`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)).
Its failure notifications go to one person, not a team: the user who
created the workflow, or whoever last changed the `cron` line (or
re-enabled the workflow after it was disabled)
([notifications for workflow runs](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs)).
Whoever edits the `cron` line becomes the person notified when the check
fails.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `repository` | yes | Name of the ECR repository that holds the image. |
| `env-tag` | yes | Mutable tag the ECS task definition references, for example `stage`. |
| `cluster` | yes | Name of the ECS cluster the service runs on. |
| `service` | yes | Name of the ECS service to check. |
| `container` | yes | Name of the container (as defined in the task definition) whose running image digest is checked. |
| `retry-seconds` | no (default `30`) | Seconds to wait before the one re-read after a mismatch. A non-negative integer. |

## Requirements

The calling job must provide:

- AWS credentials in the environment (for example via
  `aws-actions/configure-aws-credentials`).
- Ruby >= 3.2 and AWS CLI v2 on the runner. `ubuntu-24.04` GitHub-hosted
  runners have both preinstalled.
- An IAM identity with at least these read-only actions:
  - `ecs:DescribeServices`
  - `ecs:ListTasks`
  - `ecs:DescribeTasks`
  - `ecr:DescribeImages`
- A service that uses the rolling update (`ECS`) deployment type and is
  not behind a Classic Load Balancer. ECS reports `rolloutState` only for
  such services
  ([Deployment](https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Deployment.html));
  for any other service, step 1 fails with `rolloutState (missing)`.
- At most 100 tasks with desired status `RUNNING` on the service.
  `describe-tasks` accepts at most 100 task ARNs
  ([DescribeTasks](https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DescribeTasks.html))
  and the check describes all of them in one call, so a service with
  more than 100 tasks fails. Batching is out of scope.

Before doing anything else, the action checks that every input is
non-empty, that `retry-seconds` is a non-negative integer, and that
`ruby` (>= 3.2) and `aws` are on `PATH`, and fails with a clear
`::error::` message otherwise.

## Exit codes

| Exit | Log | Meaning |
| --- | --- | --- |
| `0` | `ok: <env-tag> = <digest> runs on <cluster>/<service>` | Every running task of `container` runs the digest `env-tag` points to. |
| `0` | `deployment in progress on <cluster>/<service>, not checked` | Skipped: a rollout is in progress, nothing was compared. |
| `1` | `::error::<env-tag> points to X, but <cluster>/<service> runs Y ...` | Drift, on the first read and on the re-read. |
| `1` | `::error::...` | Anything else - the check fails closed: a missing or inactive service, a `FAILED` or missing `rolloutState`, no `PRIMARY` deployment, a missing tag, no running task, a running task without `container` or without an `imageDigest` for it, a failure reported by `describe-services` or `describe-tasks`, any AWS error, AWS output that is not JSON, or invalid arguments. |

Errors go to stderr as `::error::` lines, so they show up as annotations
on the run; `ok:` and skip lines go to stdout.

### What "skipped" means

While a rollout is in progress, the running digests are expected to
disagree with the tag until ECS finishes, so the check compares nothing
and exits `0`. The step is green, but nothing was verified; the log line
is the only sign. The next run checks again.

A rollout that never finishes is skipped on every run. Without the
deployment circuit breaker, ECS does not move a rollout that fails to
reach a steady state to `FAILED`
([Deployment](https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Deployment.html)),
so it can stay `IN_PROGRESS` - and this check green - until someone
looks at the service.

## Running the tests locally

The tests use an injected fake in place of the `aws` CLI and an injected
sleeper in place of the pause - no network access, credentials, or
waiting:

```bash
ruby actions/ecs-env-tag-check/test/ecs_env_tag_check_test.rb
```

## Sources

The AWS and GitHub behaviour this action relies on is documented, and
cited, at the top of [`ecs_env_tag_check.rb`](./ecs_env_tag_check.rb).
