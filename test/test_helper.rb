# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "tmpdir"
require "open3"
require "openssl"
require "rack/utils"

# --- Stub core constants and functions that the plugin expects ---

TEST_BRAINIAC_DIR = Dir.mktmpdir("brainiac-fizzy-test")

BRAINIAC_DIR = TEST_BRAINIAC_DIR unless defined?(BRAINIAC_DIR)
ENV["BRAINIAC_DIR"] = TEST_BRAINIAC_DIR

unless defined?(LOG)
  LOG = Class.new do
    def info(_msg) = nil
    def warn(_msg) = nil
    def error(_msg) = nil
    def debug(_msg) = nil
    def debug? = false
  end.new
end

AI_AGENT_NAME = "Galen" unless defined?(AI_AGENT_NAME)

# Stub core Brainiac module with hooks
module Brainiac
  @hooks = Hash.new { |h, k| h[k] = [] }
  @channel_prompts = {}
  @channel_pre_post_checks = {}

  class << self
    def on(event, &block) = @hooks[event] << block

    def emit(event, **ctx)
      @hooks[event].filter_map do |h|
        h.call(ctx)
      rescue StandardError
        nil
      end
    end

    def register_channel_prompt(channel, prompt, pre_post_check: nil)
      @channel_prompts[channel] = prompt
      @channel_pre_post_checks[channel] = pre_post_check if pre_post_check
    end
    attr_reader :hooks, :channel_prompts, :channel_pre_post_checks

    def reset_hooks!
      @hooks = Hash.new { |h, k| h[k] = [] }
      @channel_prompts = {}
      @channel_pre_post_checks = {}
    end
  end

  module Plugins; end
end

# Stub core functions the plugin uses
AGENT_REGISTRY = {
  "galen" => { "display_name" => "Galen", "local" => true, "env" => { "FIZZY_TOKEN" => "tok_galen" } },
  "glados" => { "display_name" => "GLaDOS", "local" => true, "env" => {} }
}.freeze

PROJECTS = {
  "marketplace" => { "repo_path" => "/tmp/test-repo", "tags" => %w[marketplace mp], "fizzy_tags" => %w[marketplace mp] },
  "brainiac" => { "repo_path" => "/tmp/test-brainiac", "tags" => ["brainiac"], "fizzy_tags" => ["brainiac"] }
}.freeze

def agent_env_var(name, key)
  agent_key = name.downcase.gsub(/[^a-z0-9-]/, "-")
  entry = AGENT_REGISTRY[agent_key]
  return nil unless entry.is_a?(Hash)

  entry.dig("env", key)
end

def agent_env_for(name)
  agent_key = name.downcase.gsub(/[^a-z0-9-]/, "-")
  entry = AGENT_REGISTRY[agent_key]
  return {} unless entry.is_a?(Hash)

  entry["env"] || {}
end

def agent_display_name(name)
  agent_key = name.downcase.gsub(/[^a-z0-9-]/, "-")
  entry = AGENT_REGISTRY[agent_key]
  return name unless entry.is_a?(Hash)

  entry["display_name"] || name
end

def default_project_key = "brainiac"
def run_cmd(*_cmd, chdir:, env: {}) = ""
def already_processed?(_id) = false
def session_active?(_key) = false
def self_move_recent?(_num, **) = false
def work_item_merged?(_num) = false
def recently_completed?(_key, **) = false
def local_agent_names = ["Galen"]
def reload_projects! = nil
def reload_agent_registry!(**) = nil
def load_work_item_map = {}
def save_work_item_map(_map) = nil
def slugify(text, **) = text.downcase.gsub(/[^a-z0-9]+/, "-")[0..30]
def record_self_move(_num) = nil

# Write fizzy.json for tests
fizzy_config = {
  "authorized_users" => [
    { "id" => "user-1", "name" => "Andy", "human" => true },
    { "id" => "agent-1", "name" => "Galen", "human" => false }
  ],
  "boards" => {
    "development" => {
      "board_id" => "board-123",
      "webhook_secret" => "test-secret",
      "columns" => { "right_now" => "col-1", "needs_review" => "col-2", "uat" => "col-3" }
    }
  }
}
File.write(File.join(TEST_BRAINIAC_DIR, "fizzy.json"), JSON.generate(fizzy_config))

require_relative "../lib/brainiac_fizzy"

# Load fizzy config (normally done during .register but tests don't call register)
Brainiac::Plugins::Fizzy::Config.load!
