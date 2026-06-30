# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "tmpdir"
require "open3"

# Stub the core brainiac constants/methods that the plugin expects at load time.
# In production, these are provided by the brainiac gem (runtime dependency).
BRAINIAC_DIR = Dir.mktmpdir unless defined?(BRAINIAC_DIR)

LOG = Class.new {
  def info(_msg) = nil
  def warn(_msg) = nil
  def error(_msg) = nil
  def debug(_msg) = nil
}.new unless defined?(LOG)

# Core constants the handlers reference
FIZZY_CONFIG = { "authorized_users" => [], "boards" => {} } unless defined?(FIZZY_CONFIG)
FIZZY_BOARDS = {} unless defined?(FIZZY_BOARDS)
AUTHORIZED_USER_IDS = [] unless defined?(AUTHORIZED_USER_IDS)

# Stub core functions referenced at require time
def already_processed?(_id) = false
def session_active?(_key) = false
def self_move_recent?(_num, **) = false
def card_merged?(_num) = false
def recently_completed?(_key, **) = false
def local_agent_names = ["Galen"]
def reload_projects! = nil
def reload_agent_registry!(**) = nil
def reload_github_config! = nil
def authorized?(_payload) = true
def verify_signature!(*) = nil
def load_card_map = {}
def save_card_map(_map) = nil
def slugify(t, **) = t.downcase.gsub(/[^a-z0-9]+/, "-")[0..30]
def notify_unauthorized(*) = nil
def identify_project_by_tags(_tags) = nil
def prefetch_card_context(*) = ""
def detect_model(*args, **) = nil
def detect_effort(*args, **) = nil
def human_mentioned?(_id) = false

# CardIndex stub (card_index.rb defines a class)
class CardIndex # rubocop:disable Lint/ConstantDefinitionInBlock
  def initialize(**) = nil
  def add(_entry) = nil
  def search(_query) = []
  def size = 0
  def reindex! = nil
end

require_relative "../lib/brainiac-fizzy"

class TestFizzyPlugin < Minitest::Test
  def test_register_method_exists
    assert_respond_to Brainiac::Plugins::Fizzy, :register
  end

  def test_version_is_defined
    assert_match(/\A\d+\.\d+\.\d+\z/, Brainiac::Plugins::Fizzy::VERSION)
  end

  def test_module_hierarchy
    assert defined?(Brainiac::Plugins::Fizzy)
    assert defined?(Brainiac::Plugins::Fizzy::VERSION)
  end

  def test_handle_publish_or_triage_responds
    assert_respond_to Brainiac::Plugins::Fizzy, :handle_publish_or_triage
  end

  def test_handler_functions_defined_after_load
    # Top-level handler functions should exist in global scope after loading the gem
    assert method(:handle_card_assigned), "handle_card_assigned should be defined"
    assert method(:handle_comment), "handle_comment should be defined"
  end

  def test_card_triaged_merged_card_ignored
    Object.define_method(:card_merged?) { |_num| true }

    payload = { "eventable" => { "number" => "42" } }
    status, body = Brainiac::Plugins::Fizzy.handle_publish_or_triage("card_triaged", payload)

    assert_equal 200, status
    parsed = JSON.parse(body)
    assert_equal "card_merged", parsed["reason"]
  ensure
    Object.define_method(:card_merged?) { |_num| false }
  end

  def test_card_triaged_self_move_ignored
    Object.define_method(:self_move_recent?) { |_num, **| true }

    payload = { "eventable" => { "number" => "55" } }
    status, body = Brainiac::Plugins::Fizzy.handle_publish_or_triage("card_triaged", payload)

    assert_equal 200, status
    parsed = JSON.parse(body)
    assert_equal "self_move", parsed["reason"]
  ensure
    Object.define_method(:self_move_recent?) { |_num, **| false }
  end

  def test_card_triaged_recently_completed_ignored
    Object.define_method(:recently_completed?) { |_key, **| true }

    payload = { "eventable" => { "number" => "77" } }
    status, body = Brainiac::Plugins::Fizzy.handle_publish_or_triage("card_triaged", payload)

    assert_equal 200, status
    parsed = JSON.parse(body)
    assert_equal "recently_completed", parsed["reason"]
  ensure
    Object.define_method(:recently_completed?) { |_key, **| false }
  end
end
