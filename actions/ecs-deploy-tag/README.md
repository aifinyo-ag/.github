# ecs-deploy-tag

A composite action that deploys an image to an ECS service whose task
definition references a mutable environment tag (for example `app:stage`),
and verifies that the deployment actually landed before it reports
success.

It is a Ruby port of a Bash script proven on a real stage deployment. The
behaviour, the AWS CLI calls, and their flags are unchanged; only the
output parsing moved from `--output text` to `--output json`.

## What it does

1. Reads the digest that `commit-tag` currently points at. No such image
   is a hard failure; nothing is touched.
2. Reads the digest that `env-tag` currently points at (if any), so it can
   be restored later.
3. Refuses to run while the service already has more than one deployment
   in flight - with two deployments running, "the running digest" is
   ambiguous, and starting a third would only add confusion.
4. Retags `env-tag` onto the digest of `commit-tag` (a manifest
   `batch-get-image` + `put-image`, no image pull).
5. Forces a new ECS deployment (`update-service --force-new-deployment`)
   and waits for the service to become stable.
6. Checks that every currently running task of `container` reports the
   new digest.

The action exits `0` only when step 6 confirms the new digest is running
everywhere. Any failure after the tag has moved restores it to the digest
it had before, with one exception: if waiting for stability in step 5
times out while ECS is still actively rolling the new image forward
(deployment status `PRIMARY`, rollout state `IN_PROGRESS`), the tag is
left on the new digest so it keeps matching what ECS is converging on - a
later run, or a manual check, can then decide what to do once the rollout
finishes. Cancelling the job (from the GitHub UI, a signal, or losing the
runner) can likewise cut the process off before the restore runs and
leave the tag on the new digest.

If the restore itself fails, the action logs an `::error::` line noting
that the next Terraform apply would roll out the new image, and still
exits `1`.

## Usage

Pin to a commit SHA of this repository, not a branch or tag:

```yaml
jobs:
  deploy-stage:
    runs-on: ubuntu-24.04
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@<sha>
        with:
          # ...

      - name: Deploy to app-stage and check the running image
        uses: aifinyo-ag/.github/actions/ecs-deploy-tag@<40-character-commit-sha>
        with:
          repository: app
          commit-tag: ${{ needs.build-stage.outputs.image-tag }}
          env-tag: stage
          cluster: app-stage
          service: app
          container: app
```

Recommend a concurrency group per service and environment (for example
`group: deploy-app-stage`) so overlapping runs queue instead of racing
each other's tag moves.

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `repository` | yes | Name of the ECR repository that holds the image. |
| `commit-tag` | yes | Immutable tag to deploy; its digest is retagged onto `env-tag`. |
| `env-tag` | yes | Mutable tag the ECS task definition references, for example `stage`. |
| `cluster` | yes | Name of the ECS cluster the service runs on. |
| `service` | yes | Name of the ECS service to deploy. |
| `container` | yes | Name of the container (as defined in the task definition) whose running image digest is checked. |

## Requirements

The calling job must provide:

- AWS credentials in the environment (for example via
  `aws-actions/configure-aws-credentials`).
- Ruby >= 3.2 and AWS CLI v2 on the runner. `ubuntu-24.04` GitHub-hosted
  runners have both preinstalled.
- An IAM identity with at least:
  - `ecr:DescribeImages`
  - `ecr:BatchGetImage`
  - `ecr:PutImage`
  - `ecs:DescribeServices`
  - `ecs:UpdateService`
  - `ecs:ListTasks`
  - `ecs:DescribeTasks`

The action checks for `ruby` and `aws` on `PATH` and for Ruby >= 3.2
before doing anything else, and fails with a clear `::error::` message if
either is missing.

## Cancelling the job

If the workflow run is cancelled after the tag has moved but before the
action's own restore step runs, `env-tag` can be left pointing at the new
digest even though the deployment did not (yet) verify successfully. A
subsequent run of this action re-establishes a known-good state; a manual
check of the running digest is also enough to decide whether to leave it
or roll back by hand.

## Running the tests locally

The tests use an injected fake in place of the `aws` CLI - no network
access or credentials are needed:

```bash
ruby actions/ecs-deploy-tag/test/ecs_deploy_tag_test.rb
```

## Sources

The AWS and GitHub behaviour this action relies on is documented, and
cited, at the top of [`ecs_deploy_tag.rb`](./ecs_deploy_tag.rb).
