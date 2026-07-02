# frozen_string_literal: true

require_relative "test_helper"

class TestFizzyHooks < Minitest::Test
  def setup
    Brainiac.reset_hooks!
    Brainiac::Plugins::Fizzy::Hooks.register_all!
  end

  def test_brain_context_hook_returns_fizzy_queries_for_fizzy_source
    results = Brainiac.emit(:build_brain_context, source: :fizzy, card_title: "test", comment_body: "")
    queries = results.flatten.compact
    assert_includes queries, "fizzy CLI commands"
  end

  def test_brain_context_hook_returns_fizzy_queries_when_fizzy_mentioned
    results = Brainiac.emit(:build_brain_context, source: :discord, card_title: "fix fizzy bug", comment_body: "")
    queries = results.flatten.compact
    assert_includes queries, "fizzy CLI commands"
  end

  def test_brain_context_hook_returns_empty_for_unrelated
    results = Brainiac.emit(:build_brain_context, source: :discord, card_title: "fix CSS", comment_body: "style issue")
    queries = results.flatten.compact
    refute_includes queries, "fizzy CLI commands"
  end

  def test_detect_cli_provider_from_tags
    results = Brainiac.emit(:detect_cli_provider, tags: [{ "name" => "cli-grok" }])
    assert_equal "grok", results.compact.first
  end

  def test_detect_cli_provider_no_match
    results = Brainiac.emit(:detect_cli_provider, tags: [{ "name" => "marketplace" }])
    assert_nil results.compact.first
  end

  def test_detect_effort_from_tags
    results = Brainiac.emit(:detect_effort, tags: [{ "name" => "effort-high" }], allowed: %w[low medium high max])
    assert_equal "high", results.compact.first
  end

  def test_detect_effort_no_match
    results = Brainiac.emit(:detect_effort, tags: [{ "name" => "marketplace" }], allowed: %w[low medium high])
    assert_nil results.compact.first
  end

  def test_pre_dispatch_hook_registered
    # Should not raise
    Brainiac.emit(:pre_dispatch, chdir: "/tmp", project_config: { "repo_path" => "/tmp" }, agent_name: "Galen")
  end

  def test_agent_crashed_returns_fizzy_for_fizzy_source
    results = Brainiac.emit(:agent_crashed,
                            source: :fizzy,
                            source_context: { card_number: "99" },
                            exit_status: 1,
                            log_file: "/tmp/test.log",
                            agent_name: "Galen",
                            project_config: { "repo_path" => "/tmp" },
                            snippet: "error trace")
    assert_includes results, :fizzy
  end

  def test_agent_crashed_ignores_non_fizzy_source
    results = Brainiac.emit(:agent_crashed,
                            source: :discord,
                            source_context: {},
                            exit_status: 1,
                            log_file: "/tmp/test.log",
                            agent_name: "Galen",
                            project_config: {},
                            snippet: nil)
    refute_includes results, :fizzy
  end
end
