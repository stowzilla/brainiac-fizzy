# frozen_string_literal: true

# Top-level convenience methods that delegate to Fizzy plugin modules.
#
# The handler files (assignment.rb, comments.rb, etc.) were originally
# top-level functions in brainiac core. They call helpers like
# `fizzy_env_for`, `identify_project_by_tags`, etc. as top-level methods.
#
# These delegators make them available at top level so the handler files
# work without modification.

def fizzy_token_for(agent_name)
  Brainiac::Plugins::Fizzy::Helpers.fizzy_token_for(agent_name)
end

def fizzy_env_for(agent_name)
  Brainiac::Plugins::Fizzy::Helpers.fizzy_env_for(agent_name)
end

def default_fizzy_env
  Brainiac::Plugins::Fizzy::Helpers.default_fizzy_env
end

def prefetch_card_context(card_number, repo_path:, agent_name: nil)
  Brainiac::Plugins::Fizzy::Helpers.prefetch_card_context(card_number, repo_path: repo_path, agent_name: agent_name)
end

def tag_names(tags)
  Brainiac::Plugins::Fizzy::Helpers.tag_names(tags)
end

def card_has_tag?(tags, name)
  Brainiac::Plugins::Fizzy::Helpers.card_has_tag?(tags, name)
end

def fetch_card_tags(card_number, repo_path:, env: nil)
  Brainiac::Plugins::Fizzy::Helpers.fetch_card_tags(card_number, repo_path: repo_path, env: env)
end

def resolve_github_agent_env(agent_name, github_repo)
  Brainiac::Plugins::Fizzy::Helpers.resolve_github_agent_env(agent_name, github_repo)
end

def fetch_intent_context(card_number, repo_path:, agent_name: nil)
  Brainiac::Plugins::Fizzy::Helpers.fetch_intent_context(card_number, repo_path: repo_path, agent_name: agent_name)
end

def move_card_to_column(card_number, column_name, project_config:, agent_name: nil, board_key: nil)
  Brainiac::Plugins::Fizzy::Helpers.move_card_to_column(card_number, column_name, project_config: project_config, agent_name: agent_name,
                                                                                  board_key: board_key)
end

def append_fizzy_comment_footer(card_number, project_config:, agent_name: nil, since: nil)
  Brainiac::Plugins::Fizzy::Helpers.append_fizzy_comment_footer(card_number, project_config: project_config, agent_name: agent_name, since: since)
end

def ensure_fizzy_yaml!(chdir, project_config)
  Brainiac::Plugins::Fizzy::Helpers.ensure_fizzy_yaml!(chdir, project_config)
end

def scrub_invalid_attachments!(dir)
  Brainiac::Plugins::Fizzy::Helpers.scrub_invalid_attachments!(dir)
end

def detect_planning_mode(text:, tags:, card_internal_id:, card_number:)
  Brainiac::Plugins::Fizzy::Helpers.detect_planning_mode(text: text, tags: tags,
                                                         card_internal_id: card_internal_id, card_number: card_number)
end

def lookup_fizzy_card_info(card_internal_id)
  Brainiac::Plugins::Fizzy::Helpers.lookup_fizzy_card_info(card_internal_id)
end

def update_fizzy_work_item(card_internal_id, updates)
  Brainiac::Plugins::Fizzy::Helpers.update_fizzy_work_item(card_internal_id, updates)
end

def resolve_card_number(internal_id, repo_path:)
  Brainiac::Plugins::Fizzy::Helpers.resolve_card_number(internal_id, repo_path: repo_path)
end

def verify_fizzy_signature!(request, payload_body, board_key: nil)
  Brainiac::Plugins::Fizzy::Helpers.verify_signature!(request, payload_body, board_key: board_key)
end

# Legacy alias used by handler files
def verify_signature!(request, payload_body, board_key: nil)
  Brainiac::Plugins::Fizzy::Helpers.verify_signature!(request, payload_body, board_key: board_key)
end

# Config delegators
def identify_project_by_tags(tags, board_key: nil)
  Brainiac::Plugins::Fizzy::Config.identify_project_by_tags(tags, board_key: board_key)
end

def board_config(board_key)
  Brainiac::Plugins::Fizzy::Config.board_config(board_key)
end

def board_webhook_secret(board_key)
  Brainiac::Plugins::Fizzy::Config.board_webhook_secret(board_key)
end

def board_column_id(board_key, column_name)
  Brainiac::Plugins::Fizzy::Config.board_column_id(board_key, column_name)
end

def board_key_for_project(project_config)
  Brainiac::Plugins::Fizzy::Config.board_key_for_project(project_config)
end

def board_key_for_id(board_id)
  Brainiac::Plugins::Fizzy::Config.board_key_for_id(board_id)
end

def authorized?(payload)
  Brainiac::Plugins::Fizzy::Config.authorized?(payload)
end

def human_mentioned?(user_id)
  Brainiac::Plugins::Fizzy::Config.human_mentioned?(user_id)
end

# Extracts user IDs from Fizzy mention markup in plain text.
# Fizzy represents mentions as @[Display Name](user-id) in plain text.
def detect_mentioned_user_ids(text)
  return [] unless text

  text.scan(/@\[[^\]]*\]\(([^)]+)\)/).flatten
end

# Webhook dispatch — routes incoming actions to the appropriate handler.
# Called from within the Sinatra route block, so it must be a top-level method.
def dispatch_webhook_action(action, payload, board_key: nil)
  case action
  when "card_assigned"
    handle_card_assigned(payload, board_key: board_key)
  when "comment_created"
    handle_comment(payload, board_key: board_key)
  when "card_published", "card_triaged"
    Brainiac::Plugins::Fizzy.handle_publish_or_triage(action, payload, board_key: board_key)
  else
    LOG.info "[Fizzy] Ignoring unknown action: #{action}"
    [200, { status: "ignored", action: action }.to_json]
  end
end

# Top-level prompt constants — handler files reference these directly
PROMPT_CARD_ASSIGNED = Brainiac::Plugins::Fizzy::Prompts::CARD_ASSIGNED
PROMPT_FOLLOWUP_WORKTREE = Brainiac::Plugins::Fizzy::Prompts::FOLLOWUP_WORKTREE
PROMPT_FOLLOWUP_NO_WORKTREE = Brainiac::Plugins::Fizzy::Prompts::FOLLOWUP_NO_WORKTREE
PROMPT_MENTION = Brainiac::Plugins::Fizzy::Prompts::MENTION
PROMPT_CROSS_AGENT_REVIEW = Brainiac::Plugins::Fizzy::Prompts::CROSS_AGENT_REVIEW
PROMPT_PLANNING_MODE = Brainiac::Plugins::Fizzy::Prompts::PLANNING_MODE

# Default Fizzy board column IDs — used as fallback when board_key is nil or
# the board config doesn't specify column mappings.
DEFAULT_COLUMN_IDS = {
  "right_now" => "03f5xa5q9fog9592pa1279dts",
  "needs_review" => "03f5ykobhpsd78hbuvajtn8g8",
  "uat" => "03fsmglsr6az06ppyotawsti8"
}.freeze

# Render planning mode prompt — identical to render_prompt but inserts the planning
# instructions between PROMPT_CORE and the channel rules. This was originally defined
# in brainiac core's planning.rb but belongs here after the fizzy extraction.
def render_planning_prompt(situation_template, vars = {}, brain_context: "", card_context: "", agent_name: AI_AGENT_NAME,
                           channel: :fizzy, board_key: nil)
  plans_dir = Brainiac::Plugins::Fizzy::Planning::PLANS_DIR
  plan_file = File.join(plans_dir, "card-#{vars["CARD_ID"]}-plan.md")

  result = ""
  result += "#{brain_context}\n" unless brain_context.empty?
  result += card_context unless card_context.empty?
  result += PROMPT_CORE
  result += PROMPT_PLANNING_MODE.gsub("{{PLAN_FILE}}", plan_file)
  plugin_prompt = Brainiac.channel_prompts[channel]
  result += plugin_prompt || CHANNEL_PROMPTS.fetch(channel, "")
  result += situation_template

  # Pre-post comment check (same as render_prompt — use plugin-registered lookup)
  plugin_pre_post = Brainiac.channel_pre_post_checks[channel]
  result += plugin_pre_post if plugin_pre_post

  result += PROMPT_REFLECTION

  planning_vars = vars.merge("PLAN_FILE" => plan_file)
  planning_vars["KNOWLEDGE_DIR"] ||= KNOWLEDGE_DIR
  planning_vars["MEMORY_DIR"] ||= memory_dir_for(agent_name)
  planning_vars["PERSONA_DIR"] ||= persona_dir_for(agent_name)
  planning_vars["PERSONA_COLLECTION"] ||= persona_collection_for(agent_name)
  planning_vars["AGENT_NAME"] ||= agent_name

  # Populate column IDs from board config, falling back to defaults
  DEFAULT_COLUMN_IDS.each do |col_name, default_id|
    var_name = "#{col_name.upcase}_COLUMN_ID"
    planning_vars[var_name] ||= (board_key && board_column_id(board_key, col_name)) || default_id
  end

  ensure_memory_file_exists!(vars["CARD_ID"], planning_vars["MEMORY_DIR"])

  roster = agent_roster
  roster_lines = roster.map { |_key, display| "  - @#{display}" }.join("\n")
  planning_vars["AGENT_ROSTER"] ||= roster_lines

  planning_vars.each { |key, val| result.gsub!("{{#{key}}}", val.to_s) }
  result
end

# Ensure a card's memory file exists so the agent can read it without error.
def ensure_memory_file_exists!(card_id, memory_dir)
  return unless card_id

  memory_file = File.join(memory_dir, "card-#{card_id}.md")
  FileUtils.mkdir_p(memory_dir)
  FileUtils.touch(memory_file)
end

# Config constants — handler files reference these as top-level constants.
# These are evaluated after Config.load! has been called (during plugin register).
# Use a delegating object so it always reflects current config state.
FIZZY_CONFIG = Class.new do
  def fetch(key, default = nil) = Brainiac::Plugins::Fizzy::Config.current.fetch(key, default)
  def [](key) = Brainiac::Plugins::Fizzy::Config.current[key]
  def dig(*keys) = Brainiac::Plugins::Fizzy::Config.current.dig(*keys)
end.new

AUTHORIZED_USER_IDS = Class.new do
  def include?(id) = Brainiac::Plugins::Fizzy::Config.authorized_user_ids.include?(id)
  def map(&) = Brainiac::Plugins::Fizzy::Config.authorized_user_ids.map(&)
  def any?(&) = Brainiac::Plugins::Fizzy::Config.authorized_user_ids.any?(&)
end.new
