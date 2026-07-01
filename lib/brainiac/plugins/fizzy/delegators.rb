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

def move_card_to_column(card_number, column_name, project_config:, agent_name: nil)
  Brainiac::Plugins::Fizzy::Helpers.move_card_to_column(card_number, column_name, project_config: project_config, agent_name: agent_name)
end

def append_fizzy_comment_footer(card_number, project_config:, agent_name: nil)
  Brainiac::Plugins::Fizzy::Helpers.append_fizzy_comment_footer(card_number, project_config: project_config, agent_name: agent_name)
end

def ensure_fizzy_yaml!(chdir, project_config)
  Brainiac::Plugins::Fizzy::Helpers.ensure_fizzy_yaml!(chdir, project_config)
end

def scrub_invalid_attachments!(dir)
  Brainiac::Plugins::Fizzy::Helpers.scrub_invalid_attachments!(dir)
end

def verify_fizzy_signature!(request, payload_body, board_key: nil)
  Brainiac::Plugins::Fizzy::Helpers.verify_signature!(request, payload_body, board_key: board_key)
end

# Legacy alias used by handler files
def verify_signature!(request, payload_body, board_key: nil)
  Brainiac::Plugins::Fizzy::Helpers.verify_signature!(request, payload_body, board_key: board_key)
end

# Config delegators
def identify_project_by_tags(tags)
  Brainiac::Plugins::Fizzy::Config.identify_project_by_tags(tags)
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

# Top-level prompt constants — handler files reference these directly
PROMPT_CARD_ASSIGNED = Brainiac::Plugins::Fizzy::Prompts::CARD_ASSIGNED
PROMPT_FOLLOWUP_WORKTREE = Brainiac::Plugins::Fizzy::Prompts::FOLLOWUP_WORKTREE
PROMPT_FOLLOWUP_NO_WORKTREE = Brainiac::Plugins::Fizzy::Prompts::FOLLOWUP_NO_WORKTREE
PROMPT_MENTION = Brainiac::Plugins::Fizzy::Prompts::MENTION
PROMPT_CROSS_AGENT_REVIEW = Brainiac::Plugins::Fizzy::Prompts::CROSS_AGENT_REVIEW
