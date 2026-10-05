# frozen_string_literal: true

require_relative "test_helper"

# Stubs for brainiac-core Belt helpers. Fizzy tests don't load belt.rb.
module BeltConfig
  class << self
    attr_accessor :enabled, :parent, :tracked

    def reset!
      @enabled = true
      @parent = "dev"
      @tracked = []
    end

    def ephemeral_deploys_enabled? = @enabled != false
    def parent_env_for(_key) = @parent
    def ephemeral_env_for_card(number) = "fizzy-#{number}"
    def ephemeral_env?(name) = Array(@tracked).include?(name)

    def track_ephemeral_env(name, _meta = {})
      @tracked ||= []
      @tracked << name
    end
  end
end

module BeltEnvironment
  class << self
    attr_accessor :created, :deployed, :create_calls, :deploy_calls, :create_result, :deploy_error

    def reset!
      @created = false
      @deployed = false
      @create_calls = []
      @deploy_calls = []
      @create_result = :ok
      @deploy_error = nil
    end

    def belt_app?(path)
      File.exist?(File.join(path, "config/routes.rb"))
    end

    def create_environment(worktree:, env_name:, parent_env:)
      @create_calls << { worktree: worktree, env_name: env_name, parent_env: parent_env }
      @created = true
      @create_result
    end

    def deploy(worktree:, env_name:, frontend_only: false)
      @deploy_calls << { worktree: worktree, env_name: env_name, frontend_only: frontend_only }
      raise @deploy_error if @deploy_error

      @deployed = true
      :ok
    end

    def frontend_only_changes?(**) = false
  end
end

class TestTagHelpers < Minitest::Test
  def test_tag_names_from_hashes
    assert_equal %w[deploy opus], tag_names([{ "name" => "deploy" }, { "name" => "opus" }])
  end

  def test_tag_names_from_strings
    assert_equal %w[deploy opus], tag_names(%w[deploy opus])
  end

  def test_tag_names_mixed_and_blank
    assert_equal %w[deploy], tag_names([{ "name" => "Deploy" }, "", nil, { "name" => "" }])
  end

  def test_card_has_tag
    assert card_has_tag?(%w[deploy opus], "deploy")
    refute card_has_tag?(%w[opus], "deploy")
    assert card_has_tag?([{ "name" => "deploy" }], "DEPLOY")
  end

  def test_fetch_card_tags_parses_api_strings
    json = { "ok" => true, "data" => { "tags" => %w[deploy opus] } }.to_json
    with_run_cmd_result(json) do
      tags = fetch_card_tags(1299, repo_path: "/tmp", env: {})
      assert_equal %w[deploy opus], tags
    end
  end

  def test_fetch_card_tags_returns_nil_on_failure
    with_run_cmd_result("") do
      assert_nil fetch_card_tags(1299, repo_path: "/tmp", env: {})
    end
  end

  def with_run_cmd_result(result)
    original = method(:run_cmd)
    Object.define_method(:run_cmd) { |*_args, **_kwargs| result }
    yield
  ensure
    Object.define_method(:run_cmd, original)
  end
end

class TestMaybeCreateEphemeralBeltEnv < Minitest::Test
  def setup
    BeltConfig.reset!
    BeltEnvironment.reset!
    @worktree = Dir.mktmpdir("ephemeral-wt")
    FileUtils.mkdir_p(File.join(@worktree, "config"))
    File.write(File.join(@worktree, "config/routes.rb"), "app.get '/x'\n")
    FileUtils.mkdir_p(File.join(@worktree, "infrastructure", "dev"))
  end

  def teardown
    FileUtils.rm_rf(@worktree)
  end

  def test_skips_without_deploy_tag
    maybe_create_ephemeral_belt_env(
      worktree_path: @worktree, card_number: 1299, project_key: "feature-parity",
      tags: %w[opus]
    )
    refute BeltEnvironment.created
  end

  def test_creates_when_deploy_tag_and_env_missing
    maybe_create_ephemeral_belt_env(
      worktree_path: @worktree, card_number: 1299, project_key: "feature-parity",
      tags: %w[deploy opus]
    )
    assert BeltEnvironment.created
    assert_equal "fizzy-1299", BeltEnvironment.create_calls.first[:env_name]
    assert_equal "dev", BeltEnvironment.create_calls.first[:parent_env]
    assert_includes BeltConfig.tracked, "fizzy-1299"
  end

  def test_skips_create_when_worktree_already_has_env
    FileUtils.mkdir_p(File.join(@worktree, "infrastructure", "fizzy-1299"))
    maybe_create_ephemeral_belt_env(
      worktree_path: @worktree, card_number: 1299, project_key: "feature-parity",
      tags: %w[deploy]
    )
    refute BeltEnvironment.created
  end

  def test_fetches_live_tags_when_webhook_tags_empty
    json = { "data" => { "tags" => ["deploy"] } }.to_json
    original = method(:run_cmd)
    Object.define_method(:run_cmd) { |*_args, **_kwargs| json }
    maybe_create_ephemeral_belt_env(
      worktree_path: @worktree, card_number: 1299, project_key: "feature-parity",
      tags: [], fetch_live_tags: true, repo_path: @worktree, agent_name: "Galen"
    )
    assert BeltEnvironment.created
  ensure
    Object.define_method(:run_cmd, original)
  end

  def test_skips_when_live_tags_have_no_deploy
    json = { "data" => { "tags" => ["opus"] } }.to_json
    original = method(:run_cmd)
    Object.define_method(:run_cmd) { |*_args, **_kwargs| json }
    maybe_create_ephemeral_belt_env(
      worktree_path: @worktree, card_number: 1299, project_key: "feature-parity",
      tags: %w[deploy], fetch_live_tags: true, repo_path: @worktree, agent_name: "Galen"
    )
    refute BeltEnvironment.created
  ensure
    Object.define_method(:run_cmd, original)
  end

  # --- force: true (manual `env setup` / API) — synchronous deploy ---------

  def test_force_deploys_synchronously
    maybe_create_ephemeral_belt_env(
      worktree_path: @worktree, card_number: 1299, project_key: "feature-parity",
      force: true
    )
    # No Thread.new — deploy has already run by the time the call returns.
    assert BeltEnvironment.created
    assert BeltEnvironment.deployed
    assert_equal "fizzy-1299", BeltEnvironment.deploy_calls.first[:env_name]
  end

  def test_force_skips_tag_resolution
    # force bypasses the deploy-tag gate even with no deploy tag present.
    maybe_create_ephemeral_belt_env(
      worktree_path: @worktree, card_number: 1299, project_key: "feature-parity",
      tags: %w[opus], force: true
    )
    assert BeltEnvironment.created
    assert BeltEnvironment.deployed
  end

  def test_force_raises_on_deploy_failure
    BeltEnvironment.deploy_error = StandardError.new("terraform apply failed")
    error = assert_raises(StandardError) do
      maybe_create_ephemeral_belt_env(
        worktree_path: @worktree, card_number: 1299, project_key: "feature-parity",
        force: true
      )
    end
    assert_match(/terraform apply failed/, error.message)
  end

  def test_force_raises_on_create_failure
    BeltEnvironment.create_result = nil
    assert_raises(StandardError) do
      maybe_create_ephemeral_belt_env(
        worktree_path: @worktree, card_number: 1299, project_key: "feature-parity",
        force: true
      )
    end
    refute BeltEnvironment.deployed
  end
end
