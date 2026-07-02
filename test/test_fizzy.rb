# frozen_string_literal: true

require_relative "test_helper"

class TestFizzyPlugin < Minitest::Test
  def test_register_method_exists
    assert_respond_to Brainiac::Plugins::Fizzy, :register
  end

  def test_version_defined
    assert_match(/\A\d+\.\d+\.\d+\z/, Brainiac::Plugins::Fizzy::VERSION)
  end

  def test_prompts_channel_defined
    assert_kind_of String, Brainiac::Plugins::Fizzy::Prompts::CHANNEL
    assert_includes Brainiac::Plugins::Fizzy::Prompts::CHANNEL, "Fizzy"
  end

  def test_prompts_pre_post_check_defined
    assert_kind_of String, Brainiac::Plugins::Fizzy::Prompts::PRE_POST_CHECK
    assert_includes Brainiac::Plugins::Fizzy::Prompts::PRE_POST_CHECK, "fizzy card show"
  end

  def test_prompts_card_assigned_defined
    assert_kind_of String, Brainiac::Plugins::Fizzy::Prompts::CARD_ASSIGNED
  end

  def test_prompts_followup_worktree_defined
    assert_kind_of String, Brainiac::Plugins::Fizzy::Prompts::FOLLOWUP_WORKTREE
  end

  def test_prompts_cross_agent_review_defined
    assert_kind_of String, Brainiac::Plugins::Fizzy::Prompts::CROSS_AGENT_REVIEW
  end

  def test_handle_publish_or_triage_card_triaged_merged
    Object.define_method(:work_item_merged?) { |_num| true }
    payload = { "eventable" => { "number" => "42" } }
    status, body = Brainiac::Plugins::Fizzy.handle_publish_or_triage("card_triaged", payload)
    assert_equal 200, status
    assert_equal "card_merged", JSON.parse(body)["reason"]
  ensure
    Object.define_method(:work_item_merged?) { |_num| false }
  end

  def test_handle_publish_or_triage_card_triaged_self_move
    Object.define_method(:self_move_recent?) { |_num, **| true }
    payload = { "eventable" => { "number" => "55" } }
    status, body = Brainiac::Plugins::Fizzy.handle_publish_or_triage("card_triaged", payload)
    assert_equal 200, status
    assert_equal "self_move", JSON.parse(body)["reason"]
  ensure
    Object.define_method(:self_move_recent?) { |_num, **| false }
  end
end

class TestFizzyHelpers < Minitest::Test
  def test_fizzy_token_for
    assert_equal "tok_galen", Brainiac::Plugins::Fizzy::Helpers.fizzy_token_for("Galen")
  end

  def test_fizzy_token_for_unknown
    assert_nil Brainiac::Plugins::Fizzy::Helpers.fizzy_token_for("UnknownBot")
  end

  def test_fizzy_env_for_returns_hash
    env = Brainiac::Plugins::Fizzy::Helpers.fizzy_env_for("Galen")
    assert_kind_of Hash, env
  end

  def test_verify_signature_valid
    secret = "test-secret"
    body = "hello world"
    computed = OpenSSL::HMAC.hexdigest("sha256", secret, body)

    request = Minitest::Mock.new
    request.expect(:env, { "HTTP_X_WEBHOOK_SIGNATURE" => computed })

    Brainiac::Plugins::Fizzy::Config.load!
    result = Brainiac::Plugins::Fizzy::Helpers.verify_signature!(request, body, board_key: "development")
    assert result
  end

  def test_verify_signature_invalid
    request = Minitest::Mock.new
    request.expect(:env, { "HTTP_X_WEBHOOK_SIGNATURE" => "bad-signature" })

    Brainiac::Plugins::Fizzy::Config.load!
    result = Brainiac::Plugins::Fizzy::Helpers.verify_signature!(request, "hello", board_key: "development")
    refute result
  end

  def test_verify_signature_missing
    request = Minitest::Mock.new
    request.expect(:env, {})

    result = Brainiac::Plugins::Fizzy::Helpers.verify_signature!(request, "hello", board_key: "development")
    refute result
  end
end

class TestFizzyDelegators < Minitest::Test
  def test_top_level_fizzy_env_for
    env = fizzy_env_for("Galen")
    assert_kind_of Hash, env
  end

  def test_top_level_identify_project_by_tags
    key, _config = identify_project_by_tags([{ "name" => "marketplace" }])
    assert_equal "marketplace", key
  end

  def test_top_level_authorized
    payload = { "creator" => { "id" => "user-1" } }
    assert authorized?(payload)
  end

  def test_fizzy_config_delegator
    assert_kind_of Array, FIZZY_CONFIG.fetch("authorized_users", [])
  end

  def test_authorized_user_ids_delegator
    assert AUTHORIZED_USER_IDS.include?("user-1")
    refute AUTHORIZED_USER_IDS.include?("unknown")
  end

  def test_prompt_constants_defined
    assert_kind_of String, PROMPT_CARD_ASSIGNED
    assert_kind_of String, PROMPT_FOLLOWUP_WORKTREE
    assert_kind_of String, PROMPT_CROSS_AGENT_REVIEW
  end
end
