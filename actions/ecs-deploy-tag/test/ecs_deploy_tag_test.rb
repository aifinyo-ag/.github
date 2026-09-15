#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for ecs_deploy_tag.rb against a fake aws runner. No network, no
# credentials, no real AWS calls.
#
# This is a 1:1 port of the 18 test cases of the Bash reference
# implementation, renamed to snake_case test_ methods with the same
# expectations on exit status and the sequence of put-image calls. The
# fake enforces the same required flags the bash fake did, so a
# regression fails loudly instead of passing quietly.
#
# All example values below (repository, tags, cluster, service, container)
# are neutral placeholders, not environment details of any real deployment.

require "minitest/autorun"
require "json"
require_relative "../ecs_deploy_tag"

# A fake `aws` runner: takes the argument list ecs_deploy_tag.rb would pass
# to Open3.capture3("aws", *args) and returns [stdout, stderr, status],
# where status responds to #success? and #exitstatus - the same interface
# Process::Status offers.
class FakeAws
  Status = Struct.new(:exitstatus) do
    def success?
      exitstatus.zero?
    end
  end

  REPOSITORY = "app"
  COMMIT_TAG = "abc12345"
  ENV_TAG = "stage"
  DEFAULT_TASK_ARN = "arn:aws:ecs:us-east-1:123456789012:task/c/1"

  attr_reader :put_log, :calls

  # opts keys (all optional, matching the Bash fake's FAKE_* variables):
  #   :new, :old                     - digests digest_of should report
  #   :commit_tag_read_error         - exception name for the commit tag read
  #   :env_tag_read_error            - exception name for the env tag read
  #   :put_exists                    - digest for which put-image reports ImageAlreadyExistsException
  #   :put_fail_first                - first put-image call fails with ThrottlingException, then succeeds
  #   :deployments                   - deployment count returned by the pre-flight check (default 1)
  #   :update_exit                   - non-zero exit status for update-service (default 0)
  #   :update_service_malformed_json - update-service reports success but returns unparsable JSON
  #   :deployment_id                 - id update-service hands back (default "ecs-svc/111")
  #   :wait_exit                     - exit status for wait services-stable (default 0)
  #   :deployment_status/:deployment_rollout - values for the post-wait-failure lookup (default "ACTIVE"/"FAILED")
  #   :lookup_exit                   - non-zero exit status for the post-wait-failure describe-services lookup
  #   :tasks                         - explicit task ARNs (default one dummy ARN); [] means none
  #   :running                       - explicit running digest(s), array; defaults to [opts[:new]] if unset
  #   :missing_manifest_digest       - batch-get-image reports success but no image (JSON null) for this digest,
  #                                    simulating an image that has since been deleted from the repository
  def initialize(opts = {})
    @opts = opts
    @put_log = []
    @put_count = 0
    @calls = []
  end

  def call(args)
    @calls << args
    service, action = args[0], args[1]

    # Every call other than the waiter must ask for JSON: a regression
    # back to --output text (the Bash version's format) must fail loudly
    # here rather than silently parsing garbage.
    unless [service, action] == %w[ecs wait]
      output = value_of(args, "--output")
      return fail_hard("#{service} #{action}: expected --output json, got #{output.inspect}") unless output == "json"
    end

    if service == "ecr"
      repo = value_of(args, "--repository-name")
      return fail_hard("#{action}: missing/wrong --repository-name (got #{repo.inspect})") unless repo == REPOSITORY
    end

    case [service, action]
    when %w[ecr describe-images] then describe_images(args)
    when %w[ecr batch-get-image] then batch_get_image(args)
    when %w[ecr put-image] then put_image(args)
    when %w[ecs describe-services] then describe_services(args)
    when %w[ecs update-service] then update_service(args)
    when %w[ecs wait] then wait_services_stable(args)
    when %w[ecs list-tasks] then list_tasks(args)
    when %w[ecs describe-tasks] then describe_tasks(args)
    else fail_hard("unexpected: aws #{args.join(' ')}")
    end
  end

  private

  def value_of(args, flag)
    idx = args.index(flag)
    idx && args[idx + 1]
  end

  def has_flag(args, flag)
    args.include?(flag)
  end

  def ok(stdout, stderr = "")
    [stdout, stderr, Status.new(0)]
  end

  def fail_hard(message)
    [+"", "#{message}\n", Status.new(99)]
  end

  def aws_error(exception_name, operation, status: 254)
    [+"", "An error occurred (#{exception_name}) when calling the #{operation} operation\n", Status.new(status)]
  end

  # --- ecr describe-images -------------------------------------------

  def describe_images(args)
    ids = value_of(args, "--image-ids")
    tag = ids&.sub(/\Aimage[Tt]ag=/, "")
    case tag
    when COMMIT_TAG
      return aws_error(@opts[:commit_tag_read_error], "DescribeImages") if @opts[:commit_tag_read_error]

      digest = @opts[:new]
      return aws_error("ImageNotFoundException", "DescribeImages") unless digest

      # Harmless noise on every successful call: a script that merges
      # stderr into stdout would corrupt the digest with this line
      # instead of returning it cleanly.
      ok(digest.to_json, "warning: fake CLI notice\n")
    when ENV_TAG
      return aws_error(@opts[:env_tag_read_error], "DescribeImages") if @opts[:env_tag_read_error]

      digest = @opts[:old]
      return aws_error("ImageNotFoundException", "DescribeImages") unless digest

      ok(digest.to_json, "warning: fake CLI notice\n")
    else
      aws_error("ImageNotFoundException", "DescribeImages")
    end
  end

  # --- ecr batch-get-image ---------------------------------------------

  def batch_get_image(args)
    ids = value_of(args, "--image-ids")
    digest = ids.sub(/\AimageDigest=/, "")
    query = value_of(args, "--query")

    # A successful call with no matching image (the digest was deleted
    # from the repository): AWS CLI's --query renders the empty result
    # as JSON null, not an error.
    return ok("null") if @opts[:missing_manifest_digest] == digest

    case query
    when "images[0].imageManifestMediaType"
      ok("application/vnd.docker.distribution.manifest.v2+json".to_json)
    when "images[0].imageManifest"
      ok("manifest-of-#{digest}".to_json)
    else
      fail_hard("batch-get-image: unexpected query '#{query}'")
    end
  end

  # --- ecr put-image ----------------------------------------------------

  def put_image(args)
    manifest = value_of(args, "--image-manifest")
    digest_from_manifest = manifest.sub(/\Amanifest-of-/, "")
    media_type = value_of(args, "--image-manifest-media-type")
    return fail_hard("put-image: missing --image-manifest-media-type") if media_type.nil? || media_type.empty?

    put_digest = value_of(args, "--image-digest")
    return fail_hard("put-image: missing --image-digest") if put_digest.nil? || put_digest.empty?

    unless put_digest == digest_from_manifest
      return fail_hard("put-image: --image-digest '#{put_digest}' does not match the manifest's digest '#{digest_from_manifest}'")
    end

    return aws_error("ImageAlreadyExistsException", "PutImage") if @opts[:put_exists] == put_digest

    if @opts[:put_fail_first]
      @put_count += 1
      return aws_error("ThrottlingException", "PutImage") if @put_count == 1
    end

    @put_log << "put #{value_of(args, '--image-tag')} #{put_digest}"
    ok({ "image" => { "imageId" => { "imageDigest" => put_digest } } }.to_json)
  end

  # --- ecs describe-services --------------------------------------------

  def describe_services(args)
    query = value_of(args, "--query")
    case query
    when "length(services[0].deployments)"
      ok((@opts[:deployments] || 1).to_json)
    when /\Aservices\[0\]\.deployments\[\?id=='([^']*)'\] \| \[0\]\.\[status,rolloutState\]\z/
      return aws_error("ThrottlingException", "DescribeServices", status: @opts[:lookup_exit]) if @opts[:lookup_exit]

      got_id = Regexp.last_match(1)
      want_id = @opts[:deployment_id] || "ecs-svc/111"
      return fail_hard("describe-services: query has deployment id '#{got_id}', want '#{want_id}'") unless got_id == want_id

      ok([@opts[:deployment_status] || "ACTIVE", @opts[:deployment_rollout] || "FAILED"].to_json)
    else
      fail_hard("describe-services: unexpected query '#{query}'")
    end
  end

  # --- ecs update-service -------------------------------------------------

  def update_service(args)
    return fail_hard("update-service: missing --force-new-deployment") unless has_flag(args, "--force-new-deployment")
    return aws_error("ThrottlingException", "UpdateService", status: @opts[:update_exit]) if @opts[:update_exit] && @opts[:update_exit] != 0
    return ok("not valid json") if @opts[:update_service_malformed_json]

    ok((@opts[:deployment_id] || "ecs-svc/111").to_json)
  end

  # --- ecs wait services-stable --------------------------------------------

  def wait_services_stable(args)
    return fail_hard("wait: expected services-stable, got '#{args[2]}'") unless args[2] == "services-stable"

    exit_status = @opts[:wait_exit] || 0
    stderr = exit_status.zero? ? "" : "Waiter ServicesStable failed: Max attempts exceeded\n"
    [+"", stderr, Status.new(exit_status)]
  end

  # --- ecs list-tasks -------------------------------------------------------

  def list_tasks(_args)
    tasks = @opts.key?(:tasks) ? @opts[:tasks] : [DEFAULT_TASK_ARN]
    ok(tasks.to_json)
  end

  # --- ecs describe-tasks ----------------------------------------------------

  def describe_tasks(args)
    query = value_of(args, "--query")
    unless query == "tasks[].containers[?name=='app'].imageDigest[]"
      return fail_hard("describe-tasks: unexpected query '#{query}'")
    end

    running = @opts.key?(:running) ? @opts[:running] : [@opts[:new]].compact
    ok(running.compact.to_json)
  end
end

class EcsDeployTagTest < Minitest::Test
  def build_deployer(fake)
    EcsDeployTag::Deployer.new(
      repository: FakeAws::REPOSITORY,
      commit_tag: FakeAws::COMMIT_TAG,
      env_tag: FakeAws::ENV_TAG,
      cluster: "app-stage",
      service: "app",
      container: "app",
      runner: fake.method(:call)
    )
  end

  def deploy(opts)
    fake = FakeAws.new(opts)
    status = build_deployer(fake).call
    [status, fake.put_log]
  end

  def test_deploys_and_verifies
    status, log = deploy(new: "sha256:new", old: "sha256:old")
    assert_equal 0, status
    assert_equal ["put stage sha256:new"], log
  end

  def test_tag_already_on_the_image_is_fine
    status, log = deploy(new: "sha256:new", old: "sha256:new", put_exists: "sha256:new")
    assert_equal 0, status
    assert_equal [], log
  end

  def test_no_image_for_the_commit_fails_untouched
    status, log = deploy(old: "sha256:old")
    assert_equal 1, status
    assert_equal [], log
  end

  def test_service_not_stable_restores_the_tag
    out, err = capture_io do
      @last_status, @last_log = deploy(new: "sha256:new", old: "sha256:old", wait_exit: 255)
    end
    assert_equal 1, @last_status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], @last_log
    assert_includes(out + err, "Max attempts exceeded")
  end

  def test_rolled_back_service_restores_the_tag
    status, log = deploy(new: "sha256:new", old: "sha256:old", running: ["sha256:old"])
    assert_equal 1, status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], log
  end

  def test_one_task_on_the_old_image_fails
    status, log = deploy(new: "sha256:new", old: "sha256:old", running: %w[sha256:new sha256:old])
    assert_equal 1, status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], log
  end

  def test_running_task_reports_no_digest_fails
    status, log = deploy(new: "sha256:new", old: "sha256:old", running: [])
    assert_equal 1, status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], log
  end

  def test_update_service_error_restores_the_tag
    out, err = capture_io do
      @last_status, @last_log = deploy(new: "sha256:new", old: "sha256:old", update_exit: 254)
    end
    assert_equal 1, @last_status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], @last_log
    assert_includes(out + err, "ThrottlingException")
  end

  def test_a_new_tag_has_nothing_to_restore
    fake = FakeAws.new(new: "sha256:new", wait_exit: 255)
    status = build_deployer(fake).call
    assert_equal 1, status
    assert_equal ["put stage sha256:new"], fake.put_log
    refute fake.calls.any? { |a| a[0, 2] == %w[ecr batch-get-image] && a.include?("imageDigest=") },
           "expected no restore attempt (no batch-get-image for an empty digest)"
  end

  def test_env_tag_read_error_stops_before_moving_the_tag
    status, log = deploy(new: "sha256:new", old: "sha256:old", env_tag_read_error: "ThrottlingException")
    assert_equal 1, status
    assert_equal [], log
  end

  def test_put_error_after_the_tag_may_have_moved_still_restores
    status, log = deploy(new: "sha256:new", old: "sha256:old", put_fail_first: true)
    assert_equal 1, status
    assert_equal ["put stage sha256:old"], log
  end

  def test_busy_service_is_refused_without_moving_the_tag
    status, log = deploy(new: "sha256:new", old: "sha256:old", deployments: 2)
    assert_equal 1, status
    assert_equal [], log
  end

  def test_slow_but_healthy_rollout_keeps_the_tag
    status, log = deploy(new: "sha256:new", old: "sha256:old", wait_exit: 255,
                          deployment_status: "PRIMARY", deployment_rollout: "IN_PROGRESS")
    assert_equal 1, status
    assert_equal ["put stage sha256:new"], log
  end

  def test_rolled_back_during_the_wait_restores_the_tag
    status, log = deploy(new: "sha256:new", old: "sha256:old", wait_exit: 255,
                          deployment_status: "ACTIVE", deployment_rollout: "FAILED")
    assert_equal 1, status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], log
  end

  def test_failed_deployment_still_primary_restores_the_tag
    status, log = deploy(new: "sha256:new", old: "sha256:old", wait_exit: 255,
                          deployment_status: "PRIMARY", deployment_rollout: "FAILED")
    assert_equal 1, status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], log
  end

  def test_in_progress_rollout_on_a_replaced_deployment_restores_the_tag
    status, log = deploy(new: "sha256:new", old: "sha256:old", wait_exit: 255,
                          deployment_status: "ACTIVE", deployment_rollout: "IN_PROGRESS")
    assert_equal 1, status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], log
  end

  def test_no_running_task_fails
    status, log = deploy(new: "sha256:new", old: "sha256:old", tasks: [])
    assert_equal 1, status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], log
  end

  def test_failing_deployment_lookup_restores_the_tag
    out, err = capture_io do
      @last_status, @last_log = deploy(new: "sha256:new", old: "sha256:old", wait_exit: 255, lookup_exit: 254)
    end
    assert_equal 1, @last_status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], @last_log
    assert_includes(out + err, "ThrottlingException")
  end

  # --- additional cases from fix round 1 (not part of the Bash suite) -----

  # An unexpected exception mid-deploy (here: unparsable JSON from
  # update-service, after the tag has already moved) must still be caught,
  # reported without a bare stack trace, and must still restore the tag.
  # Removing the top-level `rescue StandardError` in Deployer#call turns
  # this test red (an uncaught JSON::ParserError instead of a clean 1).
  def test_invalid_aws_response_during_deploy_still_restores_the_tag
    status, log = deploy(new: "sha256:new", old: "sha256:old", update_service_malformed_json: true)
    assert_equal 1, status
    assert_equal ["put stage sha256:new", "put stage sha256:old"], log
  end

  # If the old digest's image has since been deleted from the repository,
  # restoring the tag to it is impossible. This must fail cleanly with the
  # documented could-not-restore message (never a bare TypeError from
  # passing a nil manifest to the put-image call), and still exit 1.
  # Removing the "::error::could not restore ..." line turns this test red.
  def test_failed_restore_when_old_image_is_gone_reports_could_not_restore
    out, err = capture_io do
      @last_status, @last_log = deploy(new: "sha256:new", old: "sha256:old", wait_exit: 255,
                                        missing_manifest_digest: "sha256:old")
    end
    assert_equal 1, @last_status
    assert_equal ["put stage sha256:new"], @last_log
    assert_includes(out + err, "could not restore stage to sha256:old")
  end
end
