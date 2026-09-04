# frozen_string_literal: true

require_relative "test_helper"

# Tests for the "always show Branch / PR / Deployment link" behavior:
# - deployment_url_for_card resolves the live ephemeral URL for a card
# - the comment footer backup appends any missing references
# - the prompts mandate all three references
class TestReferenceFooter < Minitest::Test
  PROJECT_CONFIG = { "repo_path" => "/tmp/test-repo", "github_repo" => "acme/widgets" }.freeze

  def setup
    @state_file = DEPLOYMENT_STATE_FILE
    @config_file = DEPLOYMENTS_CONFIG_FILE
    @orig_state = File.exist?(@state_file) ? File.read(@state_file) : nil
    @orig_config = File.exist?(@config_file) ? File.read(@config_file) : nil
  end

  def teardown
    restore(@state_file, @orig_state)
    restore(@config_file, @orig_config)
    reload_deployments_config!(force: true)
    reload_deployment_state!(force: true)
  end

  def restore(path, contents)
    if contents
      File.write(path, contents)
    else
      FileUtils.rm_f(path)
    end
  end

  def write_deployments(config:, state:)
    File.write(@config_file, JSON.generate(config))
    File.write(@state_file, JSON.generate(state))
    reload_deployments_config!(force: true)
    reload_deployment_state!(force: true)
  end

  # --- deployment_url_for_card ---

  def test_deployment_url_for_card_returns_env_and_url_when_occupied
    write_deployments(
      config: { "environments" => { "dev01" => { "label" => "Dev 01", "url" => "https://dev01.example.com" } } },
      state: { "dev01" => { "status" => "occupied", "card_number" => "42" } }
    )

    result = deployment_url_for_card("42")
    assert_equal "dev01", result[:env]
    assert_equal "https://dev01.example.com", result[:url]
  end

  def test_deployment_url_for_card_matches_string_and_integer_card_numbers
    write_deployments(
      config: { "environments" => { "dev01" => { "url" => "https://dev01.example.com" } } },
      state: { "dev01" => { "status" => "occupied", "card_number" => 42 } }
    )

    refute_nil deployment_url_for_card("42")
    refute_nil deployment_url_for_card(42)
  end

  def test_deployment_url_for_card_nil_when_not_deployed
    write_deployments(
      config: { "environments" => { "dev01" => { "url" => "https://dev01.example.com" } } },
      state: { "dev01" => { "status" => "available" } }
    )

    assert_nil deployment_url_for_card("42")
  end

  def test_deployment_url_for_card_resolves_tag_specific_url
    write_deployments(
      config: { "environments" => { "dev01" => { "url" => "https://default.example.com",
                                                 "urls" => { "ops" => "https://ops.example.com" } } } },
      state: { "dev01" => { "status" => "occupied", "card_number" => "42", "card_tags" => %w[ops] } }
    )

    assert_equal "https://ops.example.com", deployment_url_for_card("42")[:url]
  end

  # --- ephemeral Belt env resolution (ephemeral_envs.json + tfvars) ---

  def write_ephemeral_env(card_number:, worktree:, status: "active")
    state = { "fizzy-#{card_number}" => { "status" => status, "card_number" => card_number, "worktree" => worktree } }
    File.write(EPHEMERAL_ENVS_FILE, JSON.generate(state))
  end

  def write_tfvars(worktree, env_name, contents)
    dir = File.join(worktree, "infrastructure", env_name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "terraform.tfvars"), contents)
  end

  def test_deployment_url_for_card_resolves_ephemeral_env_from_tfvars
    write_deployments(config: { "environments" => {} }, state: {})
    worktree = Dir.mktmpdir("ephemeral-wt")
    write_ephemeral_env(card_number: 99, worktree: worktree)
    write_tfvars(worktree, "fizzy-99", %(environment = "fizzy-99"\nparent_environment = "dev"\ndomain = "example.com"\n))

    result = deployment_url_for_card("99")
    assert_equal "fizzy-99", result[:env]
    assert_equal "https://fizzy-99.dev.example.com", result[:url]
  ensure
    FileUtils.rm_rf(worktree) if worktree
    FileUtils.rm_f(EPHEMERAL_ENVS_FILE)
  end

  def test_deployment_url_for_card_prefers_tracked_env_over_ephemeral
    write_deployments(
      config: { "environments" => { "dev01" => { "url" => "https://dev01.example.com" } } },
      state: { "dev01" => { "status" => "occupied", "card_number" => "99" } }
    )
    worktree = Dir.mktmpdir("ephemeral-wt")
    write_ephemeral_env(card_number: 99, worktree: worktree)
    write_tfvars(worktree, "fizzy-99", %(environment = "fizzy-99"\ndomain = "example.com"\n))

    assert_equal "dev01", deployment_url_for_card("99")[:env]
  ensure
    FileUtils.rm_rf(worktree) if worktree
    FileUtils.rm_f(EPHEMERAL_ENVS_FILE)
  end

  def test_deployment_url_for_card_ignores_destroyed_ephemeral_env
    write_deployments(config: { "environments" => {} }, state: {})
    worktree = Dir.mktmpdir("ephemeral-wt")
    write_ephemeral_env(card_number: 99, worktree: worktree, status: "destroyed")
    write_tfvars(worktree, "fizzy-99", %(environment = "fizzy-99"\ndomain = "example.com"\n))

    assert_nil deployment_url_for_card("99")
  ensure
    FileUtils.rm_rf(worktree) if worktree
    FileUtils.rm_f(EPHEMERAL_ENVS_FILE)
  end

  # --- ensure_reference_footer ---

  def footer(body, card_number)
    Brainiac::Plugins::Fizzy::Helpers.send(:ensure_reference_footer, body, card_number, PROJECT_CONFIG)
  end

  def test_footer_appends_all_missing_references
    write_deployments(
      config: { "environments" => { "dev01" => { "url" => "https://dev01.example.com" } } },
      state: { "dev01" => { "status" => "occupied", "card_number" => "42" } }
    )

    body = "<p>Done the work.</p><p><code>fizzy-42-my-feature</code></p>"
    result = footer(body, "42")

    assert_includes result, "fizzy-42-my-feature"
    assert_includes result, "github.com/acme/widgets/pull/new/fizzy-42-my-feature"
    assert_includes result, "https://dev01.example.com"
    assert_includes result, "Deployment (dev01)"
  end

  def test_footer_omits_deployment_when_not_deployed
    write_deployments(config: { "environments" => {} }, state: {})

    body = "<p>Done.</p><p><code>fizzy-42-my-feature</code></p>"
    result = footer(body, "42")

    refute_includes result, "Deployment"
    assert_includes result, "github.com/acme/widgets/pull/new/fizzy-42-my-feature"
  end

  def test_footer_does_not_duplicate_existing_pr_link
    write_deployments(config: { "environments" => {} }, state: {})

    body = "<p><code>fizzy-42-my-feature</code></p>" \
           "<p>PR: <a href=\"https://github.com/acme/widgets/pull/7\">#7</a></p>"
    result = footer(body, "42")

    refute_includes result, "pull/new/fizzy-42-my-feature"
  end

  def test_footer_returns_unchanged_when_branch_unknown
    write_deployments(config: { "environments" => {} }, state: {})

    body = "<p>No branch info here.</p>"
    assert_equal body, footer(body, "42")
  end
end

class TestReferencePrompts < Minitest::Test
  def test_card_assigned_prompt_mandates_all_three_references
    prompt = Brainiac::Plugins::Fizzy::Prompts::CARD_ASSIGNED
    assert_includes prompt, "Branch:"
    assert_includes prompt, "PR:"
    assert_includes prompt, "Deployment:"
  end

  def test_summarize_prompt_mandates_all_three_references
    prompt = Brainiac::Plugins::Fizzy::Prompts::SUMMARIZE_WORK
    assert_includes prompt, "Branch:"
    assert_includes prompt, "PR:"
    assert_includes prompt, "Deployment:"
  end
end
