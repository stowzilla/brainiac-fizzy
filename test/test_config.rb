# frozen_string_literal: true

require_relative "test_helper"

class TestFizzyConfig < Minitest::Test
  def setup
    Brainiac::Plugins::Fizzy::Config.load!
  end

  def test_load_parses_config
    config = Brainiac::Plugins::Fizzy::Config.current
    assert_kind_of Hash, config
    assert config.key?("authorized_users")
    assert config.key?("boards")
  end

  def test_board_config
    config = Brainiac::Plugins::Fizzy::Config.board_config("development")
    assert_equal "board-123", config["board_id"]
  end

  def test_board_config_nil_for_unknown
    assert_nil Brainiac::Plugins::Fizzy::Config.board_config("nonexistent")
  end

  def test_board_webhook_secret
    assert_equal "test-secret", Brainiac::Plugins::Fizzy::Config.board_webhook_secret("development")
  end

  def test_board_column_id
    assert_equal "col-1", Brainiac::Plugins::Fizzy::Config.board_column_id("development", "right_now")
    assert_equal "col-2", Brainiac::Plugins::Fizzy::Config.board_column_id("development", "needs_review")
  end

  def test_board_key_for_id
    assert_equal "development", Brainiac::Plugins::Fizzy::Config.board_key_for_id("board-123")
    assert_nil Brainiac::Plugins::Fizzy::Config.board_key_for_id("unknown")
  end

  def test_authorized_user
    payload = { "creator" => { "id" => "user-1" } }
    assert Brainiac::Plugins::Fizzy::Config.authorized?(payload)
  end

  def test_unauthorized_user
    payload = { "creator" => { "id" => "unknown-999" } }
    refute Brainiac::Plugins::Fizzy::Config.authorized?(payload)
  end

  def test_human_mentioned
    assert Brainiac::Plugins::Fizzy::Config.human_mentioned?("user-1")
  end

  def test_human_mentioned_false_for_agent
    refute Brainiac::Plugins::Fizzy::Config.human_mentioned?("agent-1")
  end

  def test_identify_project_by_tags
    tags = [{ "name" => "marketplace" }]
    key, config = Brainiac::Plugins::Fizzy::Config.identify_project_by_tags(tags)
    assert_equal "marketplace", key
    assert_equal "/tmp/test-repo", config["repo_path"]
  end

  def test_identify_project_by_tags_case_insensitive
    tags = [{ "name" => "Marketplace" }]
    key, _config = Brainiac::Plugins::Fizzy::Config.identify_project_by_tags(tags)
    assert_equal "marketplace", key
  end

  def test_identify_project_by_tags_falls_back_to_default
    tags = [{ "name" => "unknown-tag" }]
    key, _config = Brainiac::Plugins::Fizzy::Config.identify_project_by_tags(tags)
    assert_equal "brainiac", key
  end
end
