#!/usr/bin/env ruby
# frozen_string_literal: true

# Deploy an image to an ECS service whose task definition references a
# mutable environment tag, for example app:stage.
#
# Usage: ecs_deploy_tag.rb <repository> <commit-tag> <env-tag> <cluster> <service> <container>
# Needs: AWS credentials in the environment, AWS CLI v2, Ruby >= 3.2.
#
# 1. refuse to run while another deployment is already in flight
# 2. remember the digest <env-tag> points at
# 3. point <env-tag> at the digest of <commit-tag> (retag, no pull)
# 4. force a new deployment and wait until the service is stable
# 5. check that every running <container> runs that digest
#
# Exit 0 only when step 5 holds. Once the tag has moved, any failure
# restores <env-tag> to the digest it had before - so a failed run cannot
# cause the next Terraform apply to roll out the failed image - except when
# the wait in step 4 times out while ECS is still actively rolling the new
# image forward (PRIMARY deployment, rolloutState IN_PROGRESS): the tag is
# then left on the new digest so it keeps matching what ECS is converging
# on, and a later run (or a manual check) can decide what to do once the
# rollout finishes. Cancelling the job (from the GitHub UI, SIGKILL, or
# losing the runner) can cut the process off before the restore in `ensure`
# runs, and can likewise leave <env-tag> on the new digest.
#
# This is a Ruby port of a Bash version proven on a stage deployment
# (2026-09-15). Behaviour,
# AWS calls and flags are unchanged; --output text plus manual parsing is
# replaced by --output json plus JSON.parse (JSON null stands in for
# Bash's literal "None"), and AWS calls go through an injected runner
# instead of a literal `aws` subprocess, so tests can run without network
# access or credentials.
#
# Sources (fetched and cross-checked before this port was written):
# - https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-retag.html
#   (retag procedure: batch-get-image for the manifest, then put-image
#   with --image-tag)
# - https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_PutImage.html
#   (imageManifestMediaType, imageDigest, ImageAlreadyExistsException,
#   ImageDigestDoesNotMatchException)
# - https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_BatchGetImage.html
#   (response images[].imageManifest, images[].imageManifestMediaType)
# - https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_DescribeImages.html
#   (imageDetails[].imageDigest, ImageNotFoundException)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_UpdateService.html
#   (forceNewDeployment; the response's "service" is the full Service object)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DescribeServices.html
#   (services[].deployments)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Deployment.html
#   (status: PRIMARY | ACTIVE | INACTIVE; rolloutState: COMPLETED | FAILED |
#   IN_PROGRESS, only returned for the rolling-update (ECS) deployment type)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Container.html
#   (name, imageDigest)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_ListTasks.html
#   (desiredStatus, serviceName, response taskArns)
# - https://docs.aws.amazon.com/cli/latest/reference/ecs/wait/services-stable.html
#   (polls every 15s, gives up after 40 checks, exit 255)
# - https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-ecs.html
#   (container image resolution; forceNewDeployment re-resolves tags to digests)
# - https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation
#   (a cancelled run's step gets SIGINT, then SIGTERM after a 7500ms grace
#   period, then is killed after a further 2500ms - all well before this
#   script's own AWS calls would time out)
# - https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections
#   (pass untrusted input through env: and read it back as a variable
#   instead of interpolating ${{ }} into a script; applied in action.yml)

require "json"
require "open3"

module EcsDeployTag
  # Runs the deploy against a repository/cluster/service, using `runner`
  # (an object responding to #call(args), or a lambda/method) to execute
  # `aws` calls. `runner.call(args)` must return [stdout, stderr, status]
  # where status responds to #success?.
  class Deployer
    def initialize(repository:, commit_tag:, env_tag:, cluster:, service:, container:, runner:, out: $stdout, err: $stderr)
      @repository = repository
      @commit_tag = commit_tag
      @env_tag = env_tag
      @cluster = cluster
      @service = service
      @container = container
      @runner = runner
      @out = out
      @err = err
      @tag_moved = false
      @old = nil
      @new = nil
    end

    # Returns 0 or 1. Never raises: any unexpected exception is caught and
    # turned into an "::error::" line plus exit 1, never a bare stacktrace.
    # The restore is attached to `ensure` so no exception - expected or
    # not - can skip it.
    def call
      @tag_moved = false
      status = 1
      begin
        status = deploy_steps
      rescue StandardError => e
        @err.puts "::error::unexpected error: #{e.class}: #{e.message}"
        status = 1
      ensure
        restore if status != 0
      end
      status
    end

    private

    def deploy_steps
      @new = digest_of(@commit_tag)
      return 1 if @new.nil? # fatal read error, already reported, nothing moved yet

      if @new.empty?
        @err.puts "::error::no image #{@repository}:#{@commit_tag}"
        return 1
      end

      @old = digest_of(@env_tag)
      return 1 if @old.nil? # fatal read error, already reported, nothing moved yet

      @out.puts "deploying #{@repository}:#{@commit_tag} (#{@new}) to #{@cluster}/#{@service}; " \
                 "#{@env_tag} was #{@old.empty? ? 'unset' : @old}"

      # Refuse to start a second deployment on top of one that is already
      # rolling: with two deployments in flight, "the running digest" is
      # ambiguous and forcing another one now would only add confusion.
      count = deployment_count
      return 1 if count.nil?

      if count != 1
        @err.puts "::error::#{@cluster}/#{@service} has #{count} deployments in flight, refusing to start another"
        return 1
      end

      # The tag may or may not actually move on the next line (a crash
      # between the batch-get-image and put-image calls inside
      # point_tag_at is possible in theory), but from here on a restore
      # is safe and idempotent: putting a tag back onto the manifest it
      # already names just hits ImageAlreadyExistsException.
      @tag_moved = true
      return 1 unless point_tag_at(@env_tag, @new)

      deployment_id = update_service
      if deployment_id == :error
        @err.puts "::error::could not start a deployment of #{@cluster}/#{@service}"
        return 1
      end

      unless wait_stable
        dep_status, dep_rollout = deployment_lookup(deployment_id)
        if dep_status == "PRIMARY" && dep_rollout == "IN_PROGRESS"
          # ECS is still converging on the new image; leave the tag alone
          # so it keeps matching what the deployment is rolling out to.
          @err.puts "::error::#{@cluster}/#{@service} deployment #{deployment_id} is still rolling " \
                     "#{@repository}:#{@commit_tag} (#{@new}) forward; #{@env_tag} stays on #{@new} " \
                     "until it finishes or fails"
          @tag_moved = false
          return 1
        end
        @err.puts "::error::#{@cluster}/#{@service} did not become stable"
        return 1
      end

      running = running_digests
      return 1 if running.nil?

      if running != @new
        @err.puts "::error::#{@cluster}/#{@service} runs #{running.empty? ? 'no task' : running}, expected #{@new}"
        return 1
      end

      @out.puts "running #{@repository}:#{@commit_tag} (#{@new})"
      0
    end

    # tag -> digest, "" if the tag does not exist, nil if a fatal read
    # error was already reported to @err (any error other than
    # ImageNotFoundException - throttling, network, access denied, ...).
    # stdout and stderr are always kept separate (never merged), so a
    # digest can never be confused with error text or vice versa.
    def digest_of(tag)
      out, err, status = @runner.call(
        ["ecr", "describe-images", "--repository-name", @repository,
         "--image-ids", "imageTag=#{tag}",
         "--query", "imageDetails[0].imageDigest", "--output", "json"]
      )
      if status.success?
        digest = JSON.parse(out)
        return digest.nil? ? "" : digest
      end
      return "" if err.include?("ImageNotFoundException")

      @err.puts "::error::could not read #{@repository}:#{tag} - #{err.rstrip}"
      nil
    end

    # Retags `digest` as `tag` via batch-get-image (manifest + media
    # type) and put-image. Returns true on success or when the tag
    # already names this manifest (ImageAlreadyExistsException); false
    # (with the AWS error already printed to @err) otherwise.
    def point_tag_at(tag, digest)
      manifest_out, manifest_err, manifest_status = @runner.call(
        ["ecr", "batch-get-image", "--repository-name", @repository,
         "--image-ids", "imageDigest=#{digest}",
         "--query", "images[0].imageManifest", "--output", "json"]
      )
      unless manifest_status.success?
        @err.puts manifest_err.rstrip
        return false
      end
      manifest = JSON.parse(manifest_out)

      media_out, media_err, media_status = @runner.call(
        ["ecr", "batch-get-image", "--repository-name", @repository,
         "--image-ids", "imageDigest=#{digest}",
         "--query", "images[0].imageManifestMediaType", "--output", "json"]
      )
      unless media_status.success?
        @err.puts media_err.rstrip
        return false
      end
      media_type = JSON.parse(media_out)

      _put_out, put_err, put_status = @runner.call(
        ["ecr", "put-image", "--repository-name", @repository, "--image-tag", tag,
         "--image-manifest", manifest, "--image-manifest-media-type", media_type,
         "--image-digest", digest, "--output", "json"]
      )
      return true if put_status.success?
      return true if put_err.include?("ImageAlreadyExistsException")

      @err.puts put_err.rstrip
      false
    end

    # Number of deployments currently on the service, or nil if the read
    # failed (already reported to @err).
    def deployment_count
      out, err, status = @runner.call(
        ["ecs", "describe-services", "--cluster", @cluster, "--services", @service,
         "--query", "length(services[0].deployments)", "--output", "json"]
      )
      unless status.success?
        @err.puts "::error::could not check deployments of #{@cluster}/#{@service} - #{err.rstrip}"
        return nil
      end
      JSON.parse(out)
    end

    # The id of the new PRIMARY deployment, or :error if the call itself
    # failed (a missing PRIMARY entry on an otherwise successful call is
    # not treated as an error, matching the Bash version).
    def update_service
      out, _err, status = @runner.call(
        ["ecs", "update-service", "--cluster", @cluster, "--service", @service, "--force-new-deployment",
         "--query", "service.deployments[?status=='PRIMARY'].id | [0]", "--output", "json"]
      )
      return :error unless status.success?

      JSON.parse(out)
    end

    def wait_stable
      _out, _err, status = @runner.call(
        ["ecs", "wait", "services-stable", "--cluster", @cluster, "--services", @service]
      )
      status.success?
    end

    # [status, rolloutState] of the deployment identified by
    # `deployment_id`, or [nil, nil] if the lookup itself failed (the
    # error text is printed to @err so it reaches the run's output
    # instead of being discarded) or no such deployment was found.
    def deployment_lookup(deployment_id)
      out, err, status = @runner.call(
        ["ecs", "describe-services", "--cluster", @cluster, "--services", @service,
         "--query", "services[0].deployments[?id=='#{deployment_id}'] | [0].[status,rolloutState]",
         "--output", "json"]
      )
      unless status.success?
        @err.puts "::error::could not check deployment #{deployment_id} of #{@cluster}/#{@service} - #{err.rstrip}"
        return [nil, nil]
      end
      result = JSON.parse(out)
      result.is_a?(Array) ? result : [nil, nil]
    end

    # Newline-joined, sorted, de-duplicated digests that the running
    # tasks' `@container` container reports, "" if there are no matching
    # containers (no tasks, or none by that name), nil if a read failed
    # (already reported to @err).
    def running_digests
      list_out, list_err, list_status = @runner.call(
        ["ecs", "list-tasks", "--cluster", @cluster, "--service-name", @service,
         "--desired-status", "RUNNING", "--query", "taskArns", "--output", "json"]
      )
      unless list_status.success?
        @err.puts "::error::could not list tasks of #{@cluster}/#{@service} - #{list_err.rstrip}"
        return nil
      end
      tasks = JSON.parse(list_out) || []
      return "" if tasks.empty?

      describe_out, describe_err, describe_status = @runner.call(
        ["ecs", "describe-tasks", "--cluster", @cluster, "--tasks", *tasks,
         "--query", "tasks[].containers[?name=='#{@container}'].imageDigest[]", "--output", "json"]
      )
      unless describe_status.success?
        @err.puts "::error::could not describe tasks of #{@cluster}/#{@service} - #{describe_err.rstrip}"
        return nil
      end
      digests = JSON.parse(describe_out) || []
      digests.uniq.sort.join("\n")
    end

    def restore
      return unless @tag_moved && @old && !@old.empty? && @old != @new

      if point_tag_at(@env_tag, @old)
        @out.puts "#{@env_tag} restored to #{@old}"
      else
        @err.puts "::error::could not restore #{@env_tag} to #{@old} - the next Terraform apply would roll out #{@new}"
      end
    end
  end

  # Real runner: shells out to the `aws` CLI. Kept as a module method
  # rather than a lambda constant so it never becomes a candidate for
  # accidental sharing of mutable state across calls.
  def self.aws_runner
    lambda do |args|
      Open3.capture3("aws", *args)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length != 6
    warn "Usage: ecs_deploy_tag.rb <repository> <commit-tag> <env-tag> <cluster> <service> <container>"
    exit 1
  end

  repository, commit_tag, env_tag, cluster, service, container = ARGV
  deployer = EcsDeployTag::Deployer.new(
    repository: repository, commit_tag: commit_tag, env_tag: env_tag,
    cluster: cluster, service: service, container: container,
    runner: EcsDeployTag.aws_runner
  )
  exit deployer.call
end
