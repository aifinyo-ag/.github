#!/usr/bin/env ruby
# frozen_string_literal: true

# Check that an ECS service's running image digest agrees with the digest
# its environment tag (for example app:stage) currently points to in ECR -
# i.e. that the next Terraform apply of this service would not silently
# roll out a different image than the one that is actually running.
#
# Usage: ecs_env_tag_check.rb <repository> <env-tag> <cluster> <service> <container> [<retry-seconds>]
# Needs: AWS credentials in the environment, AWS CLI v2, Ruby >= 3.2.
# Every AWS call below is a read ("describe"/"list"); nothing is written.
# <retry-seconds>: pause before the one re-read (step 5), default 30.
#
# 1. Read the service. It must exist and be ACTIVE. More than one
#    deployment, or one deployment with rolloutState IN_PROGRESS, is a
#    rollout in progress, not drift - running digests are expected to
#    disagree with the tag's target until ECS finishes converging - so
#    this exits 0 without comparing anything. Any other rolloutState
#    (FAILED, missing) is an error, and so is a service whose one
#    deployment is not PRIMARY, or that has none.
# 2. Read the digest <repository>:<env-tag> points to in ECR.
# 3. Read the image digest of <container> on every task of the service
#    whose lastStatus is RUNNING (tasks still starting or stopping are
#    ignored). A running task without that container, or without an
#    imageDigest for it, is an error, not drift.
# 4. Compare: every running digest must equal the tag's digest.
# 5. On a mismatch, wait and re-read everything once before failing (see
#    the comment there).
#
# Fails closed: exit 0 only for "no drift" or "deployment in progress".
# Exit 1: drift (also on the re-read), a missing or inactive service, a
# FAILED or unknown rollout, no PRIMARY deployment, a missing tag, no
# running task, a running task without a digest for <container>, any AWS
# read error or reported failure, output that is not JSON, or wrong
# arguments.
#
# This is a Ruby port of the reviewed Bash check in aifinyo-ag/Hubspot
# (.github/scripts/check-env-tag.sh). The AWS calls and their flags are
# the same: every call still reads the full --output json response, and
# JSON.parse plus plain Ruby replaces jq. AWS calls go through an injected
# runner instead of a literal `aws` subprocess, and the pause before the
# re-read through an injected sleeper, so tests can run without network
# access, credentials or waiting. Deliberate differences from the Bash
# version:
# - <retry-seconds> is an argument (the action's retry-seconds input),
#   not the CHECK_ENV_TAG_RETRY_SECONDS environment variable.
# - A describe-services failure entry with an empty reason fails the
#   check; the Bash version joined the reasons and went on when the
#   result was empty.
# - A successful describe-images without an imageDigest fails at once;
#   the Bash version compared against the string "null".
# - A missing or null taskArns or tasks list, or output that is not JSON,
#   ends in a clean ::error:: line (for output that is not JSON, one that
#   names the call); the Bash version crashed in jq.
# - A service whose one deployment is not PRIMARY, or that has none,
#   fails as "no PRIMARY deployment"; the Bash version failed with
#   "rolloutState (missing)".
# - A running task without a taskArn is still checked for <container>;
#   the Bash version's jq join turned the null ARN into an empty string,
#   so such a task without <container> could pass.
#
# Sources (each URL confirmed reachable before this port was written; the
# AWS field names, values and limits noted below also match the service
# model bundled with AWS CLI v2.36.4, the other notes are carried over from
# the reviewed Bash version):
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DescribeServices.html
#   (a missing service is reported in failures[] next to an empty
#   services[], not as an error)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Service.html
#   (status: ACTIVE | DRAINING | INACTIVE; deployments)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Deployment.html
#   (status: PRIMARY | ACTIVE | INACTIVE; rolloutState: COMPLETED | FAILED |
#   IN_PROGRESS, only returned for services that use the rolling-update
#   (ECS) deployment type and are not behind a Classic Load Balancer - so
#   any other service always fails step 1 with rolloutState (missing))
# - https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_DescribeImages.html
#   (imageDetails[].imageDigest, ImageNotFoundException)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_ListTasks.html
#   (desiredStatus, serviceName, response taskArns)
# - https://docs.aws.amazon.com/cli/latest/reference/ecs/list-tasks.html
#   (a paginated operation: the CLI issues as many calls as needed and
#   returns every task ARN unless --no-paginate is given)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DescribeTasks.html
#   (tasks: up to 100 task IDs or ARNs; response tasks[] and failures[])
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Task.html
#   (taskArn, lastStatus, containers)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Container.html
#   (name, imageDigest)
# - https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_Failure.html
#   (arn, reason)
# - https://docs.github.com/en/actions/reference/security/secure-use
#   (pass untrusted input through env: and read it back as a variable
#   instead of interpolating ${{ }} into a script; applied in action.yml)

require "json"
require "open3"

module EcsEnvTagCheck
  USAGE = "usage: ecs_env_tag_check.rb <repository> <env-tag> <cluster> <service> <container> [<retry-seconds>]"

  # Runs the check against a repository/cluster/service, using `runner`
  # (an object responding to #call(args), or a lambda/method) to execute
  # `aws` calls, and `sleeper` (responding to #call(seconds)) for the
  # pause before the re-read. `runner.call(args)` must return
  # [stdout, stderr, status] where status responds to #success?.
  class Checker
    DEFAULT_RETRY_SECONDS = 30

    # Raised with an error message (without the "::error::" prefix) to
    # stop the check, like `fail` in the Bash version; #call turns it
    # into one "::error::" line on @err and exit 1.
    class Failed < StandardError; end

    def initialize(repository:, env_tag:, cluster:, service:, container:, runner:,
                   retry_seconds: DEFAULT_RETRY_SECONDS, out: $stdout, err: $stderr, sleeper: Kernel.method(:sleep))
      @repository = repository
      @env_tag = env_tag
      @cluster = cluster
      @service = service
      @container = container
      @runner = runner
      @retry_seconds = retry_seconds
      @out = out
      @err = err
      @sleeper = sleeper
    end

    # Returns 0 or 1. Never raises: any unexpected exception is caught and
    # turned into an "::error::" line plus exit 1, never a bare stacktrace.
    def call
      check
    rescue Failed => e
      @err.puts "::error::#{e.message}"
      1
    rescue StandardError => e
      @err.puts "::error::unexpected error: #{e.class}: #{e.message}"
      1
    end

    private

    def check
      state = read_state
      return in_progress if state == :in_progress
      return ok(state[:tag_digest]) if matches?(state)

      # 5. The ecs-deploy-tag action moves <env-tag> first and only then
      # calls update-service (and moves the tag back if the deploy fails).
      # A check that reads in between sees the new tag digest, one
      # COMPLETED deployment and the old running digest: a mismatch that is
      # not drift. So re-read everything once after a pause; by then the
      # forced deployment shows up as in progress, or has finished.
      @out.puts "#{@env_tag} points to #{state[:tag_digest]}, but #{@cluster}/#{@service} runs " \
                "#{state[:running_digests].join(', ')}; re-reading once in #{@retry_seconds}s " \
                "in case a deploy is moving the tag right now"
      @sleeper.call(@retry_seconds)

      state = read_state
      return in_progress if state == :in_progress
      return ok(state[:tag_digest]) if matches?(state)

      @err.puts "::error::#{@env_tag} points to #{state[:tag_digest]}, but #{@cluster}/#{@service} runs " \
                "#{state[:running_digests].join(', ')} (also on a re-read #{@retry_seconds}s later)"
      @err.puts "the next Terraform apply on this service would roll out #{state[:tag_digest]}; " \
                "redeploy the running commit tag or move the tag back"
      1
    end

    def matches?(state)
      state[:running_digests] == [state[:tag_digest]]
    end

    def in_progress
      @out.puts "deployment in progress on #{@cluster}/#{@service}, not checked"
      0
    end

    def ok(tag_digest)
      @out.puts "ok: #{@env_tag} = #{tag_digest} runs on #{@cluster}/#{@service}"
      0
    end

    def fail!(message)
      raise Failed, message
    end

    # Steps 1-3. Returns :in_progress, or { tag_digest:, running_digests: }
    # with the running digests sorted and unique. Anything else raises
    # Failed.
    def read_state
      return :in_progress if deployment_in_progress?

      { tag_digest: tag_digest, running_digests: running_digests }
    end

    # Runs one `aws` call with --output json and returns the parsed
    # response, or raises Failed with the AWS error text. stdout and
    # stderr are always kept separate (never merged), so the JSON can
    # never be confused with error text or vice versa.
    def aws_json(description, *args)
      out, err, status = @runner.call([*args, "--output", "json"])
      fail! "could not #{description} - #{err.to_s.rstrip}" unless status.success?

      parse_json(description, out)
    end

    # Parses the stdout of a successful `aws` call; output that is not
    # JSON raises Failed naming the call, not a bare JSON::ParserError.
    def parse_json(description, out)
      JSON.parse(out)
    rescue JSON::ParserError
      fail! "could not #{description} - the aws output is not valid JSON"
    end

    # 1. The service and its deployments: true if a rollout is in
    # progress, false if there is exactly one COMPLETED deployment.
    def deployment_in_progress?
      response = aws_json("read #{@cluster}/#{@service}",
                          "ecs", "describe-services", "--cluster", @cluster, "--services", @service)

      # Any failure entry fails the check, also one with an empty reason.
      failures = Array(response["failures"])
      unless failures.empty?
        reasons = failures.map { |f| f["reason"].to_s.empty? ? "unknown" : f["reason"] }.join(", ")
        fail! "could not read #{@cluster}/#{@service} - describe-services reported failures: #{reasons}"
      end

      services = Array(response["services"])
      fail! "could not read #{@cluster}/#{@service} - describe-services returned #{services.length} services" unless services.length == 1

      # The status check comes before the skip below: a service that is
      # not ACTIVE fails even while it has more than one deployment.
      service = services.first
      status = service["status"] || "(missing)"
      fail! "#{@cluster}/#{@service} is #{status}, not ACTIVE" unless status == "ACTIVE"

      deployments = Array(service["deployments"])
      return true if deployments.length > 1

      primary = deployments.find { |d| d["status"] == "PRIMARY" }
      fail! "cannot check #{@cluster}/#{@service}: it has no PRIMARY deployment" unless primary

      rollout = primary["rolloutState"] || "(missing)"
      case rollout
      when "COMPLETED" then false
      when "IN_PROGRESS" then true
      else
        fail! "cannot check #{@cluster}/#{@service}: its one deployment has rolloutState #{rollout} " \
              "(want COMPLETED, or IN_PROGRESS to skip)"
      end
    end

    # 2. Digest <repository>:<env-tag> currently points to. A missing tag
    # is a hard error: unlike a commit tag, the environment tag is
    # expected to always exist.
    def tag_digest
      out, err, status = @runner.call(
        ["ecr", "describe-images", "--repository-name", @repository,
         "--image-ids", "imageTag=#{@env_tag}", "--output", "json"]
      )
      unless status.success?
        fail! "no image #{@repository}:#{@env_tag}" if err.to_s.include?("ImageNotFoundException")
        fail! "could not read #{@repository}:#{@env_tag} - #{err.to_s.rstrip}"
      end

      details = parse_json("read #{@repository}:#{@env_tag}", out)["imageDetails"]
      digest = Array(details).first&.fetch("imageDigest", nil)
      fail! "could not read #{@repository}:#{@env_tag} - describe-images returned no imageDigest" unless digest.is_a?(String) && !digest.empty?

      digest
    end

    # 3. Image digests of <container> on every RUNNING task of the service.
    # list-tasks --desired-status RUNNING also returns tasks that are still
    # starting (lastStatus PENDING etc.), so lastStatus decides what counts.
    def running_digests
      listed = aws_json("list tasks of #{@cluster}/#{@service}",
                        "ecs", "list-tasks", "--cluster", @cluster, "--service-name", @service,
                        "--desired-status", "RUNNING")
      task_arns = Array(listed["taskArns"])
      fail! "no running task on #{@cluster}/#{@service}" if task_arns.empty?

      # One call for all task ARNs: describe-tasks accepts at most 100 task
      # ARNs, so a service with more than 100 tasks listed here fails.
      # Batching is out of scope.
      described = aws_json("describe tasks of #{@cluster}/#{@service}",
                           "ecs", "describe-tasks", "--cluster", @cluster, "--tasks", *task_arns)
      failures = Array(described["failures"])
      unless failures.empty?
        listed_failures = failures.map { |f| "#{f['arn'] || '?'} (#{f['reason'] || 'unknown'})" }.join(", ")
        fail! "could not describe tasks of #{@cluster}/#{@service} - describe-tasks reported failures: #{listed_failures}"
      end

      running = Array(described["tasks"]).select { |t| t["lastStatus"] == "RUNNING" }
      fail! "no running task on #{@cluster}/#{@service} (none of its tasks has lastStatus RUNNING yet)" if running.empty?

      # One [taskArn, matching containers] pair per running task entry. A
      # list, not a hash keyed by taskArn: a hash would keep only the last
      # of two entries with the same taskArn and could hide the other one.
      pairs = running.map { |t| [t["taskArn"], Array(t["containers"]).select { |c| c["name"] == @container }] }

      missing = pairs.select { |_arn, matching| matching.empty? }.map(&:first)
      fail! "no container #{@container} on running task(s) #{missing.join(', ')} of #{@cluster}/#{@service}" unless missing.empty?

      missing = pairs.select { |_arn, matching| matching.any? { |c| c["imageDigest"].to_s.empty? } }.map(&:first)
      unless missing.empty?
        fail! "container #{@container} reports no imageDigest on running task(s) #{missing.join(', ')} of #{@cluster}/#{@service}"
      end

      pairs.flat_map { |_arn, matching| matching.map { |c| c["imageDigest"] } }.uniq.sort
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

  # Command line entry: checks the argument count and <retry-seconds>
  # before any AWS call, then runs the check. Returns the exit status.
  # Kept separate from the `if __FILE__` block below so tests can drive
  # it with a fake runner and sleeper.
  def self.main(argv, runner: aws_runner, out: $stdout, err: $stderr, sleeper: Kernel.method(:sleep))
    unless [5, 6].include?(argv.length)
      err.puts "::error::#{USAGE}"
      return 1
    end

    repository, env_tag, cluster, service, container, retry_seconds = argv
    retry_seconds ||= Checker::DEFAULT_RETRY_SECONDS.to_s
    unless retry_seconds.match?(/\A[0-9]+\z/)
      err.puts "::error::retry-seconds must be a non-negative integer, got #{retry_seconds.inspect}"
      return 1
    end

    Checker.new(
      repository: repository, env_tag: env_tag, cluster: cluster, service: service, container: container,
      retry_seconds: Integer(retry_seconds, 10), runner: runner, out: out, err: err, sleeper: sleeper
    ).call
  end
end

if __FILE__ == $PROGRAM_NAME
  exit EcsEnvTagCheck.main(ARGV)
end
