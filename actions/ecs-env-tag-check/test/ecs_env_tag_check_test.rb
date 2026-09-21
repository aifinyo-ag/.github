#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for ecs_env_tag_check.rb against a fake aws runner. No network, no
# credentials, no real AWS calls, no waiting (the sleeper is injected).
#
# This is a 1:1 port of the 27 test cases of the reviewed Bash version in
# aifinyo-ag/Hubspot (.github/scripts/check-env-tag.test.sh), renamed to
# snake_case test_ methods with the same expectations on exit status and
# output. The Bash test grepped stdout and stderr merged; these tests also
# check the stream: errors on stderr, "ok:" and skip lines on stdout. The
# fake compares the full argument list of every call with the one the
# checker must send (only the order of the --tasks values is free), so an
# added, dropped or changed flag fails loudly instead of passing quietly.
#
# All example values below (repository, tag, cluster, service, container,
# task ARNs) are neutral placeholders, not environment details of any real
# deployment.

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require_relative "../ecs_env_tag_check"

# A fake `aws` runner: takes the argument list ecs_env_tag_check.rb would
# pass to Open3.capture3("aws", *args) and returns [stdout, stderr, status],
# where status responds to #success? and #exitstatus - the same interface
# Process::Status offers.
class FakeAws
  Status = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  REPOSITORY = "app"
  ENV_TAG = "stage"
  CLUSTER = "app-stage"
  SERVICE = "app"
  CONTAINER = "app"
  TASK_ARN_PREFIX = "arn:aws:ecs:eu-central-1:123456789012:task/app-stage"

  # One task with one CONTAINER container; a nil digest means the
  # container reports no imageDigest.
  def self.task(id, last_status, digest)
    container = { "name" => CONTAINER }
    container["imageDigest"] = digest if digest
    { "taskArn" => "#{TASK_ARN_PREFIX}/#{id}", "lastStatus" => last_status, "containers" => [container] }
  end

  attr_reader :calls, :reads, :rejections

  # opts keys (all optional, matching the Bash fake's FAKE_* variables):
  #   :describe_services_json - whole describe-services response (overrides
  #                             :service_status and :deployments)
  #   :service_status         - services[0].status (default "ACTIVE")
  #   :deployments            - services[0].deployments (default one
  #                             PRIMARY/COMPLETED deployment)
  #   :tag_digest             - digest behind REPOSITORY:ENV_TAG (default "sha256:aaa")
  #   :tasks                  - the tasks describe-tasks knows (taskArn,
  #                             lastStatus, containers), default one RUNNING
  #                             task on sha256:aaa
  #   :list_task_arns         - task ARNs list-tasks returns (default every
  #                             taskArn in :tasks); describe-tasks must receive
  #                             exactly these and reports the ones it does not
  #                             know as MISSING failures
  #   :describe_services_error, :tag_error, :list_tasks_error, :describe_tasks_error
  #                           - make that call fail like the real CLI does,
  #                             with this exception name
  #   :malformed_json         - the action ("describe-services",
  #                             "describe-images", "list-tasks" or
  #                             "describe-tasks") that succeeds but prints
  #                             something that is not JSON
  #   :tag_without_digest     - describe-images succeeds but reports no image
  # Every describe-services call starts one full read of the service. The
  # checker may re-read once after a mismatch, never more; from the second
  # read on, opts[:<key>_retry] (if set) replaces opts[:<key>].
  def initialize(opts = {})
    @opts = opts
    @calls = []
    @reads = 0
    @rejections = []
  end

  def call(args)
    @calls << args
    stdout, stderr, status =
      case args[0, 2]
      when %w[ecs describe-services] then describe_services(args)
      when %w[ecr describe-images] then describe_images(args)
      when %w[ecs list-tasks] then list_tasks(args)
      when %w[ecs describe-tasks] then describe_tasks(args)
      else fail_hard("unexpected: aws #{args.join(' ')}")
      end
    return ["not valid json", stderr, status] if status.success? && @opts[:malformed_json] == args[1]

    [stdout, stderr, status]
  end

  private

  # Every handler compares the full argument list with the one the
  # checker must send: an added flag (--max-items, --no-paginate, --query,
  # --region, ...), a dropped or reordered one, or --output other than
  # json is rejected.
  def unexpected_args(args, expected)
    fail_hard("unexpected arguments: aws #{args.join(' ')} (expected: aws #{expected.join(' ')})")
  end

  # The fixture for the current read: <key>_retry from the second read on
  # (if set), else <key>, else `default`.
  def fixture(key, default)
    retry_key = :"#{key}_retry"
    if @reads >= 2 && @opts.key?(retry_key)
      @opts[retry_key]
    elsif @opts.key?(key)
      @opts[key]
    else
      default
    end
  end

  # Harmless noise on stderr on every successful call: a checker that
  # merges stderr into stdout would fail to parse the JSON.
  def ok(stdout)
    [stdout, "warning: fake CLI notice\n", Status.new(0)]
  end

  def fail_hard(message)
    @rejections << message
    [+"", "#{message}\n", Status.new(99)]
  end

  def aws_error(exception_name, operation)
    [+"", "An error occurred (#{exception_name}) when calling the #{operation} operation\n", Status.new(254)]
  end

  def tasks
    fixture(:tasks, [FakeAws.task(1, "RUNNING", "sha256:aaa")])
  end

  def list_task_arns
    @opts.key?(:list_task_arns) ? @opts[:list_task_arns] : tasks.map { |t| t["taskArn"] }
  end

  # --- ecs describe-services ---------------------------------------------

  def describe_services(args)
    expected = ["ecs", "describe-services", "--cluster", CLUSTER, "--services", SERVICE, "--output", "json"]
    return unexpected_args(args, expected) unless args == expected

    @reads += 1
    return fail_hard("describe-services: read #{@reads} times, the checker may re-read only once") if @reads > 2
    return aws_error(@opts[:describe_services_error], "DescribeServices") if @opts[:describe_services_error]
    return ok(@opts[:describe_services_json].to_json) if @opts[:describe_services_json]

    deployments = fixture(:deployments, [{ "status" => "PRIMARY", "rolloutState" => "COMPLETED" }])
    ok({ "services" => [{ "serviceName" => SERVICE, "status" => @opts[:service_status] || "ACTIVE",
                          "deployments" => deployments }],
         "failures" => [] }.to_json)
  end

  # --- ecr describe-images -------------------------------------------------

  def describe_images(args)
    expected = ["ecr", "describe-images", "--repository-name", REPOSITORY, "--image-ids", "imageTag=#{ENV_TAG}",
                "--output", "json"]
    return unexpected_args(args, expected) unless args == expected

    return aws_error(@opts[:tag_error], "DescribeImages") if @opts[:tag_error]
    return ok({ "imageDetails" => [] }.to_json) if @opts[:tag_without_digest]

    ok({ "imageDetails" => [{ "imageDigest" => fixture(:tag_digest, "sha256:aaa") }] }.to_json)
  end

  # --- ecs list-tasks ---------------------------------------------------------

  def list_tasks(args)
    expected = ["ecs", "list-tasks", "--cluster", CLUSTER, "--service-name", SERVICE, "--desired-status", "RUNNING",
                "--output", "json"]
    return unexpected_args(args, expected) unless args == expected

    return aws_error(@opts[:list_tasks_error], "ListTasks") if @opts[:list_tasks_error]

    ok({ "taskArns" => list_task_arns }.to_json)
  end

  # --- ecs describe-tasks -------------------------------------------------------

  def describe_tasks(args)
    prefix = ["ecs", "describe-tasks", "--cluster", CLUSTER, "--tasks"]
    suffix = ["--output", "json"]
    expected = prefix + list_task_arns + suffix
    unless args.length >= prefix.length + suffix.length &&
           args.first(prefix.length) == prefix && args.last(suffix.length) == suffix
      return unexpected_args(args, expected)
    end

    # The real CLI refuses --tasks without a value before it calls AWS:
    # --tasks is a required list parameter, which AWS CLI v2 parses with
    # argparse nargs='+' (awscli/arguments.py in v2.36.4; see also
    # `aws ecs describe-tasks help`: "--tasks (list) [required]").
    asked = args[prefix.length...-suffix.length]
    return fail_hard("describe-tasks: --tasks needs at least one task ARN") if asked.empty?

    # Every task ARN list-tasks returned must reach describe-tasks, and
    # nothing else; only their order is free.
    return unexpected_args(args, expected) unless asked.sort == list_task_arns.sort

    return aws_error(@opts[:describe_tasks_error], "DescribeTasks") if @opts[:describe_tasks_error]

    known = tasks
    known_arns = known.map { |t| t["taskArn"] }
    ok({ "tasks" => known.select { |t| asked.include?(t["taskArn"]) },
         "failures" => (asked - known_arns).map { |arn| { "arn" => arn, "reason" => "MISSING" } } }.to_json)
  end
end

class EcsEnvTagCheckTest < Minitest::Test
  ARN = FakeAws::TASK_ARN_PREFIX
  SCRIPT = File.expand_path("../ecs_env_tag_check.rb", __dir__)

  Result = Struct.new(:status, :out, :err, :fake, :sleeps)

  def task(id, last_status, digest)
    FakeAws.task(id, last_status, digest)
  end

  # Runs the checker against a FakeAws built from `opts`. The sleeper
  # records [seconds, number of aws calls made so far] for every sleep.
  def run_check(opts = {}, retry_seconds: 0)
    fake = FakeAws.new(opts)
    out = StringIO.new
    err = StringIO.new
    sleeps = []
    checker = EcsEnvTagCheck::Checker.new(
      repository: FakeAws::REPOSITORY, env_tag: FakeAws::ENV_TAG, cluster: FakeAws::CLUSTER,
      service: FakeAws::SERVICE, container: FakeAws::CONTAINER, retry_seconds: retry_seconds,
      runner: fake.method(:call), out: out, err: err,
      sleeper: ->(seconds) { sleeps << [seconds, fake.calls.length] }
    )
    status = checker.call
    Result.new(status, out.string, err.string, fake, sleeps)
  end

  # Runs EcsEnvTagCheck.main (the command line entry) against a FakeAws.
  def run_main(argv, opts = {})
    fake = FakeAws.new(opts)
    out = StringIO.new
    err = StringIO.new
    sleeps = []
    status = EcsEnvTagCheck.main(argv, runner: fake.method(:call), out: out, err: err,
                                       sleeper: ->(seconds) { sleeps << seconds })
    Result.new(status, out.string, err.string, fake, sleeps)
  end

  # The Bash test's check(): the exit status plus a substring of the
  # output - on stdout for exit 0, on stderr for exit 1. Also: the fake
  # never had to reject a call, and nothing crashed.
  def check(want_status, want_output, **opts)
    result = run_check(opts)
    assert_equal want_status, result.status, "stdout: #{result.out}\nstderr: #{result.err}"
    assert_includes(want_status.zero? ? result.out : result.err, want_output)
    assert_empty result.fake.rejections
    refute_includes result.err, "unexpected error"
    result
  end

  # --- comparing digests ---------------------------------------------------

  def test_match_single_running_digest_equals_the_tag_digest
    check 0, "ok: stage = sha256:aaa runs on app-stage/app"
  end

  def test_mismatch_the_running_digest_differs_from_the_tag_digest
    check 1, "::error::stage points to sha256:aaa, but app-stage/app runs sha256:bbb",
          tasks: [task(1, "RUNNING", "sha256:bbb")]
  end

  def test_two_tasks_only_the_second_one_differs
    check 1, "::error::stage points to sha256:aaa, but app-stage/app runs sha256:aaa, sha256:bbb",
          tasks: [task(1, "RUNNING", "sha256:aaa"), task(2, "RUNNING", "sha256:bbb")]
  end

  def test_two_tasks_with_the_same_digest_are_one_digest
    check 0, "ok: stage = sha256:aaa runs on app-stage/app",
          tasks: [task(1, "RUNNING", "sha256:aaa"), task(2, "RUNNING", "sha256:aaa")]
  end

  def test_a_second_container_with_another_name_and_digest_is_ignored
    check 0, "ok: stage = sha256:aaa runs on app-stage/app",
          tasks: [{ "taskArn" => "#{ARN}/1", "lastStatus" => "RUNNING",
                    "containers" => [{ "name" => "log-router", "imageDigest" => "sha256:fff" },
                                     { "name" => "app", "imageDigest" => "sha256:aaa" }] }]
  end

  def test_a_task_that_is_not_running_yet_is_ignored
    check 0, "ok: stage = sha256:aaa runs on app-stage/app",
          tasks: [task(1, "RUNNING", "sha256:aaa"), task(2, "PENDING", "sha256:bbb")]
  end

  # --- the one re-read after a mismatch (deploy action moved the tag, but
  # --- has not called update-service yet) ------------------------------------

  def test_mismatch_on_the_first_read_match_on_the_re_read
    check 0, "ok: stage = sha256:aaa runs on app-stage/app",
          tasks: [task(1, "RUNNING", "sha256:bbb")],
          tasks_retry: [task(1, "RUNNING", "sha256:aaa")]
  end

  def test_mismatch_on_the_first_read_deployment_in_progress_on_the_re_read
    check 0, "deployment in progress on app-stage/app, not checked",
          tasks: [task(1, "RUNNING", "sha256:bbb")],
          deployments_retry: [{ "status" => "PRIMARY", "rolloutState" => "IN_PROGRESS" },
                              { "status" => "ACTIVE", "rolloutState" => "COMPLETED" }]
  end

  def test_mismatch_on_both_reads
    check 1, "::error::stage points to sha256:aaa, but app-stage/app runs sha256:bbb (also on a re-read 0s later)",
          tasks: [task(1, "RUNNING", "sha256:bbb")]
  end

  # --- deployments: only IN_PROGRESS or more than one deployment skip -------

  def test_rollout_in_progress_on_the_one_deployment_is_not_checked
    check 0, "deployment in progress on app-stage/app, not checked",
          deployments: [{ "status" => "PRIMARY", "rolloutState" => "IN_PROGRESS" }]
  end

  def test_more_than_one_deployment_in_flight_is_not_checked
    check 0, "deployment in progress on app-stage/app, not checked",
          deployments: [{ "status" => "PRIMARY", "rolloutState" => "IN_PROGRESS" },
                        { "status" => "ACTIVE", "rolloutState" => "IN_PROGRESS" }]
  end

  def test_more_than_one_deployment_with_the_primary_one_completed_is_not_checked
    check 0, "deployment in progress on app-stage/app, not checked",
          deployments: [{ "status" => "PRIMARY", "rolloutState" => "COMPLETED" },
                        { "status" => "ACTIVE", "rolloutState" => "IN_PROGRESS" }],
          tasks: [task(1, "RUNNING", "sha256:bbb")]
  end

  def test_failed_rollout
    check 1, "::error::cannot check app-stage/app: its one deployment has rolloutState FAILED",
          deployments: [{ "status" => "PRIMARY", "rolloutState" => "FAILED" }]
  end

  def test_rollout_state_missing
    check 1, "::error::cannot check app-stage/app: its one deployment has rolloutState (missing)",
          deployments: [{ "status" => "PRIMARY" }]
  end

  # --- the service itself ------------------------------------------------------

  def test_missing_service
    check 1, "::error::could not read app-stage/app - describe-services reported failures: MISSING",
          describe_services_json: {
            "services" => [],
            "failures" => [{ "arn" => "arn:aws:ecs:eu-central-1:123456789012:service/app-stage/app",
                             "reason" => "MISSING" }]
          }
  end

  def test_service_not_active
    check 1, "::error::app-stage/app is DRAINING, not ACTIVE", service_status: "DRAINING"
  end

  # --- running tasks -------------------------------------------------------------

  # No task ARN from list-tasks ends the check before describe-tasks, which
  # the real CLI would refuse with an empty --tasks.
  def test_no_running_task
    result = check 1, "::error::no running task on app-stage/app", tasks: []
    assert_equal "::error::no running task on app-stage/app\n", result.err
    assert_equal [%w[ecs describe-services], %w[ecr describe-images], %w[ecs list-tasks]],
                 result.fake.calls.map { |c| c[0, 2] }
  end

  def test_only_a_task_that_is_not_running_yet
    check 1, "::error::no running task on app-stage/app", tasks: [task(1, "PENDING", nil)]
  end

  def test_running_task_without_image_digest
    check 1, "::error::container app reports no imageDigest on running task(s) #{ARN}/2 of app-stage/app",
          tasks: [task(1, "RUNNING", "sha256:aaa"), task(2, "RUNNING", nil)]
  end

  def test_running_task_without_the_container
    check 1, "::error::no container app on running task(s) #{ARN}/1 of app-stage/app",
          tasks: [{ "taskArn" => "#{ARN}/1", "lastStatus" => "RUNNING",
                    "containers" => [{ "name" => "log-router", "imageDigest" => "sha256:aaa" }] }]
  end

  def test_describe_tasks_reports_a_listed_task_as_a_failure
    check 1, "::error::could not describe tasks of app-stage/app - describe-tasks reported failures: #{ARN}/2 (MISSING)",
          list_task_arns: ["#{ARN}/1", "#{ARN}/2"]
  end

  # --- ECR tag and AWS errors: never swallowed, the AWS error text is kept --------

  def test_tag_missing
    check 1, "::error::no image app:stage", tag_error: "ImageNotFoundException"
  end

  def test_aws_error_reading_the_service
    check 1, "::error::could not read app-stage/app - An error occurred (ThrottlingException) " \
             "when calling the DescribeServices operation",
          describe_services_error: "ThrottlingException"
  end

  def test_aws_error_reading_the_env_tag_digest
    check 1, "::error::could not read app:stage - An error occurred (ThrottlingException) " \
             "when calling the DescribeImages operation",
          tag_error: "ThrottlingException"
  end

  def test_aws_error_listing_running_tasks
    check 1, "::error::could not list tasks of app-stage/app - An error occurred (ThrottlingException) " \
             "when calling the ListTasks operation",
          list_tasks_error: "ThrottlingException"
  end

  def test_aws_error_describing_running_tasks
    check 1, "::error::could not describe tasks of app-stage/app - An error occurred (ThrottlingException) " \
             "when calling the DescribeTasks operation",
          describe_tasks_error: "ThrottlingException"
  end

  # Wrong argument count: the Bash test ran the script itself with four
  # arguments. This runs the real file the same way, with a PATH that has
  # no `aws` on it, so a regression cannot reach AWS; then checks the same
  # through EcsEnvTagCheck.main, where it must not make any aws call.
  def test_wrong_argument_count
    _out, err, status = Open3.capture3({ "PATH" => File.dirname(RbConfig.ruby) },
                                       RbConfig.ruby, SCRIPT, "app", "stage", "app-stage", "app")
    assert_equal 1, status.exitstatus
    assert_includes err, "::error::usage:"

    [%w[app stage app-stage app], %w[app stage app-stage app app 30 extra]].each do |argv|
      result = run_main(argv)
      assert_equal 1, result.status
      assert_includes result.err, "::error::usage:"
      assert_empty result.fake.calls
    end
  end

  # --- additional cases (not part of the Bash suite) ---------------------------

  # retry-seconds reaches the sleeper, the sleep happens after the first
  # full read (4 aws calls) and before the second, and the second read is
  # the only one: the fake rejects a third describe-services call.
  def test_retry_seconds_reach_the_sleeper_and_the_retry_re_reads_exactly_once
    result = run_check({ tasks: [task(1, "RUNNING", "sha256:bbb")] }, retry_seconds: 7)
    assert_equal 1, result.status
    assert_equal [[7, 4]], result.sleeps
    assert_equal 2, result.fake.reads
    assert_equal 8, result.fake.calls.length
    assert_empty result.fake.rejections
    assert_includes result.out, "re-reading once in 7s"
    assert_includes result.err, "::error::stage points to sha256:aaa, but app-stage/app runs sha256:bbb " \
                                "(also on a re-read 7s later)"
    assert_includes result.err, "the next Terraform apply on this service would roll out sha256:aaa"
  end

  def test_a_match_reads_once_and_never_sleeps
    result = run_check({}, retry_seconds: 7)
    assert_equal 0, result.status
    assert_empty result.sleeps
    assert_equal 1, result.fake.reads
    assert_equal "", result.err
  end

  def test_a_skip_never_sleeps_or_reads_further
    result = run_check({ deployments: [{ "status" => "PRIMARY", "rolloutState" => "IN_PROGRESS" }] }, retry_seconds: 7)
    assert_equal 0, result.status
    assert_empty result.sleeps
    assert_equal [%w[ecs describe-services]], result.fake.calls.map { |c| c[0, 2] }
  end

  # The command line entry passes an explicit retry-seconds argument to
  # the sleeper, and defaults to 30 without one.
  def test_retry_seconds_argument_reaches_the_sleeper
    mismatch = { tasks: [task(1, "RUNNING", "sha256:bbb")] }
    assert_equal [5], run_main(%w[app stage app-stage app app 5], mismatch).sleeps
    assert_equal [30], run_main(%w[app stage app-stage app app], mismatch).sleeps
  end

  def test_invalid_retry_seconds_is_refused_before_any_aws_call
    ["", "abc", "-1", "1.5", " 5", "5\n"].each do |value|
      result = run_main(["app", "stage", "app-stage", "app", "app", value])
      assert_equal 1, result.status, "retry-seconds #{value.inspect}"
      assert_includes result.err, "::error::retry-seconds must be a non-negative integer"
      assert_empty result.fake.calls
    end
  end

  # Unparsable AWS output must end as one "::error::" line that names the
  # call, and exit 1 - never a bare stack trace.
  def test_invalid_json_from_aws_is_reported_not_raised
    {
      "describe-services" => "could not read app-stage/app",
      "describe-images" => "could not read app:stage",
      "list-tasks" => "could not list tasks of app-stage/app",
      "describe-tasks" => "could not describe tasks of app-stage/app"
    }.each do |action, description|
      result = check 1, "::error::#{description} - the aws output is not valid JSON", malformed_json: action
      assert_equal 1, result.err.lines.length, action
    end
  end

  # Any other exception - here the one Open3.capture3 raises when `aws` is
  # not on PATH - also ends as one "::error::" line and exit 1.
  def test_an_unexpected_exception_is_reported_not_raised
    err = StringIO.new
    status = EcsEnvTagCheck::Checker.new(
      repository: "app", env_tag: "stage", cluster: "app-stage", service: "app", container: "app",
      runner: ->(_args) { raise Errno::ENOENT, "aws" }, out: StringIO.new, err: err, sleeper: ->(_) {}
    ).call
    assert_equal 1, status
    assert_equal "::error::unexpected error: Errno::ENOENT: No such file or directory - aws\n", err.string
  end

  # A successful describe-images without a digest (not expected from AWS
  # for a tag lookup, which reports ImageNotFoundException instead) is an
  # error right away, not a comparison against an empty digest.
  def test_tag_lookup_without_a_digest_is_an_error
    result = run_check({ tag_without_digest: true })
    assert_equal 1, result.status
    assert_includes result.err, "::error::could not read app:stage - describe-images returned no imageDigest"
    assert_empty result.sleeps
  end

  # --- fail-closed rules on the describe-services response ---------------------

  COMPLETED_SERVICE = { "serviceName" => "app", "status" => "ACTIVE",
                        "deployments" => [{ "status" => "PRIMARY", "rolloutState" => "COMPLETED" }] }.freeze

  def test_describe_services_without_a_service_or_a_failure
    result = check 1, "::error::could not read app-stage/app - describe-services returned 0 services",
                   describe_services_json: { "services" => [], "failures" => [] }
    assert_equal 1, result.fake.calls.length
  end

  def test_describe_services_with_two_services
    result = check 1, "::error::could not read app-stage/app - describe-services returned 2 services",
                   describe_services_json: { "services" => [COMPLETED_SERVICE, COMPLETED_SERVICE], "failures" => [] }
    assert_equal 1, result.fake.calls.length
  end

  # A failure entry fails the check even when its reason is empty (the
  # Bash version joined the reasons and went on when that was empty).
  def test_a_describe_services_failure_with_an_empty_reason
    result = check 1, "::error::could not read app-stage/app - describe-services reported failures: unknown",
                   describe_services_json: {
                     "services" => [COMPLETED_SERVICE],
                     "failures" => [{ "arn" => "arn:aws:ecs:eu-central-1:123456789012:service/app-stage/app",
                                      "reason" => "" }]
                   }
    assert_equal 1, result.fake.calls.length
  end

  # The status check comes before the skip: a service that is not ACTIVE
  # fails even while it has more than one deployment.
  def test_a_draining_service_with_two_deployments_fails_and_is_not_skipped
    result = check 1, "::error::app-stage/app is DRAINING, not ACTIVE",
                   service_status: "DRAINING",
                   deployments: [{ "status" => "PRIMARY", "rolloutState" => "IN_PROGRESS" },
                                 { "status" => "ACTIVE", "rolloutState" => "COMPLETED" }]
    assert_empty result.out
  end

  # One deployment that is not PRIMARY, or none at all: fail closed as "no
  # PRIMARY deployment" (the Bash version said "rolloutState (missing)"),
  # never compare against a non-PRIMARY deployment's rolloutState.
  def test_a_service_without_a_primary_deployment
    [[{ "status" => "ACTIVE", "rolloutState" => "COMPLETED" }], []].each do |deployments|
      result = check 1, "::error::cannot check app-stage/app: it has no PRIMARY deployment", deployments: deployments
      assert_equal 1, result.fake.calls.length
    end
  end

  # --- running tasks and digests ------------------------------------------------

  def test_running_task_with_an_empty_image_digest
    check 1, "::error::container app reports no imageDigest on running task(s) #{ARN}/1 of app-stage/app",
          tasks: [task(1, "RUNNING", "")]
  end

  # The digests arrive in reverse order and are reported sorted.
  def test_running_digests_are_reported_sorted
    check 1, "::error::stage points to sha256:aaa, but app-stage/app runs sha256:aaa, sha256:bbb " \
             "(also on a re-read 0s later)",
          tasks: [task(1, "RUNNING", "sha256:bbb"), task(2, "RUNNING", "sha256:aaa")]
  end

  # describe-tasks answering with the same taskArn twice (not expected from
  # AWS): every entry is checked on its own, so one that is fine cannot
  # hide one that is not - as in the Bash version, which went through every
  # entry of tasks[].
  def test_a_repeated_task_arn_does_not_hide_a_task_without_the_container
    check 1, "::error::no container app on running task(s) #{ARN}/1 of app-stage/app",
          list_task_arns: ["#{ARN}/1"],
          tasks: [{ "taskArn" => "#{ARN}/1", "lastStatus" => "RUNNING",
                    "containers" => [{ "name" => "log-router", "imageDigest" => "sha256:aaa" }] },
                  task(1, "RUNNING", "sha256:aaa")]
  end

  def test_a_repeated_task_arn_does_not_hide_a_task_without_an_image_digest
    check 1, "::error::container app reports no imageDigest on running task(s) #{ARN}/1 of app-stage/app",
          list_task_arns: ["#{ARN}/1"],
          tasks: [task(1, "RUNNING", nil), task(1, "RUNNING", "sha256:aaa")]
  end

  def test_a_repeated_task_arn_does_not_hide_a_different_digest
    check 1, "::error::stage points to sha256:aaa, but app-stage/app runs sha256:aaa, sha256:bbb " \
             "(also on a re-read 0s later)",
          list_task_arns: ["#{ARN}/1"],
          tasks: [task(1, "RUNNING", "sha256:bbb"), task(1, "RUNNING", "sha256:aaa")]
  end

  # --- the fake itself -----------------------------------------------------------

  # The fake accepts exactly the four calls the checker makes (the --tasks
  # values in any order) and rejects every other argument list, so a flag
  # added to, dropped from or changed in a call of the checker - for
  # example --max-items 1 or --no-paginate on list-tasks, which would hide
  # tasks - fails the tests.
  def test_the_fake_accepts_only_the_exact_calls_of_the_checker
    opts = { tasks: [task(1, "RUNNING", "sha256:aaa"), task(2, "RUNNING", "sha256:aaa")] }
    exact = [
      %w[ecs describe-services --cluster app-stage --services app --output json],
      %w[ecr describe-images --repository-name app --image-ids imageTag=stage --output json],
      %w[ecs list-tasks --cluster app-stage --service-name app --desired-status RUNNING --output json],
      ["ecs", "describe-tasks", "--cluster", "app-stage", "--tasks", "#{ARN}/2", "#{ARN}/1", "--output", "json"]
    ]
    exact.each do |args|
      fake = FakeAws.new(opts)
      assert fake.call(args)[2].success?, "rejected: aws #{args.join(' ')}"
      assert_empty fake.rejections
    end

    wrong = exact.flat_map do |args|
      [args[0...-2] + ["--no-paginate"] + args[-2..],
       args + ["--max-items", "1"],
       args[0...-2] + ["--query", "taskArns"] + args[-2..],
       args[0...-1] + ["text"],
       args[0, 2] + args[4..]]
    end
    wrong << %w[ecs describe-tasks --cluster app-stage --tasks --output json]
    wrong << ["ecs", "describe-tasks", "--cluster", "app-stage", "--tasks", "#{ARN}/1", "--output", "json"]
    wrong.each do |args|
      fake = FakeAws.new(opts)
      refute fake.call(args)[2].success?, "accepted: aws #{args.join(' ')}"
      refute_empty fake.rejections
    end
  end
end
