# frozen_string_literal: true

# Fizzy card assignment handler.
#
# When a card is assigned to a local agent, creates a worktree, builds the prompt,
# and dispatches the agent to begin work.

def handle_card_assigned(payload)
  eventable = payload["eventable"] || {}
  assignees = eventable["assignees"] || []

  local_names = local_agent_names
  assigned_agent = assignees.map { |a| a["name"] }.find { |name| local_names.include?(name) }

  assignee_names = assignees.map { |a| a["name"] }.join(", ")
  LOG.info "[Fizzy] Card assigned to: [#{assignee_names}], local agents: [#{local_names.join(", ")}]"

  return ignore_assignment("wrong assignee", assignee_names, local_names) unless assigned_agent
  return ignore_unauthorized(payload, eventable) unless authorized?(payload)

  card_number = eventable["number"]
  card_internal_id = eventable["id"]
  title = eventable["title"] || "untitled"
  tags = eventable["tags"] || []

  project_result = identify_project_by_tags(tags)
  unless project_result
    tag_names = tags.map { |t| t.is_a?(Hash) ? t["name"] : t }.join(", ")
    LOG.warn "No project found for card ##{card_number} with tags: #{tag_names}"
    return [200, { status: "ignored", reason: "no matching project" }.to_json]
  end

  project_key, project_config = project_result
  repo_path = project_config["repo_path"]
  branch = "fizzy-#{card_number}-#{slugify(title)}"

  card_key = "card-#{card_number}"
  if session_active?(card_key)
    LOG.info "Skipping card ##{card_number} — agent session already active"
    return [200, { status: "ignored", reason: "session already active" }.to_json]
  end

  LOG.info "Card ##{card_number} assigned to #{assigned_agent} for project '#{project_key}', " \
           "creating worktree: #{branch} (model: #{detect_model(project_config, tags: tags) || "default"})"

  react_to_assignment(card_number, repo_path, assigned_agent)
  worktree_path = setup_assigned_worktree(repo_path, branch, card_internal_id, card_number, project_key, assigned_agent)

  initial_cli = detect_cli_provider(tags: tags)
  initial_model = detect_model(project_config, tags: tags)
  initial_effort = detect_effort(project_config, tags: tags)

  # Persist initial overrides from card tags to the work item
  resolve_work_item_overrides(
    branch: branch,
    inline_cli_provider: initial_cli,
    inline_model: initial_model,
    inline_effort: initial_effort
  )

  dispatch_assigned_card(
    card_number: card_number, card_internal_id: card_internal_id, title: title, tags: tags,
    branch: branch, worktree_path: worktree_path, project_config: project_config, project_key: project_key,
    agent_name: assigned_agent, model: initial_model,
    effort: initial_effort, cli_provider_override: initial_cli
  )
end

def ignore_assignment(reason, assignee_names, local_names)
  LOG.info "[Fizzy] No local agent matched. Assignees: [#{assignee_names}], Local: [#{local_names.join(", ")}]"
  [200, { status: "ignored", reason: reason }.to_json]
end

def ignore_unauthorized(payload, eventable)
  creator_name = payload.dig("creator", "name") || "Unknown"
  notify_unauthorized("card_assigned", creator_name, "card ##{eventable["number"]}")
  [200, { status: "ignored", reason: "unauthorized" }.to_json]
end

def react_to_assignment(card_number, repo_path, agent_name)
  Thread.new do
    env = fizzy_env_for(agent_name)

    # Best-effort cleanup of existing reactions from this agent
    begin
      result = run_cmd("fizzy", "reaction", "list", "--card", card_number.to_s,
                       chdir: repo_path, env: env)
      reactions = JSON.parse(result)["data"] || []

      identity_output = run_cmd("fizzy", "identity", "show", chdir: repo_path, env: env)
      current_user_id = JSON.parse(identity_output).dig("data", "accounts", 0, "user", "id")

      if current_user_id
        reactions.each do |reaction|
          if reaction.dig("reacter", "id") == current_user_id
            run_cmd("fizzy", "reaction", "delete", reaction["id"], "--card", card_number.to_s,
                    chdir: repo_path, env: env)
          end
        end
      end
    rescue StandardError => e
      LOG.warn "Could not clean up existing reactions on card ##{card_number}: #{e.message}"
    end

    # Always attempt to add the reaction even if cleanup failed
    run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s,
            "--content", "👀", chdir: repo_path, env: env)
  rescue StandardError => e
    LOG.warn "Could not add reaction to card ##{card_number}: #{e.message}"
  end
end

def setup_assigned_worktree(repo_path, branch, card_internal_id, card_number, project_key, agent_name)
  debounced_repo_fetch(repo_path)
  worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{branch}")
  worktree_path = create_or_reuse_worktree(repo_path: repo_path, branch: branch, worktree_path: worktree_path)

  register_work_item(
    branch: branch, worktree: worktree_path, project: project_key, agent: agent_name,
    source: :fizzy, source_data: { "card_internal_id" => card_internal_id, "card_number" => card_number }
  )
  worktree_path
end

def dispatch_assigned_card(card_number:, card_internal_id:, title:, tags:, branch:, worktree_path:,
                           project_config:, project_key:, agent_name:, model:, effort:, cli_provider_override:)
  card_context = prefetch_card_context(card_number, repo_path: project_config["repo_path"], agent_name: agent_name)
  planning_info = detect_planning_mode(text: title, tags: tags, card_internal_id: card_internal_id, card_number: card_number)

  template_vars = {
    "CARD_NUMBER" => card_number, "CARD_TITLE" => title,
    "BRANCH" => branch, "COMMENT_CREATOR" => agent_name
  }
  brain_ctx = build_brain_context(
    agent_name: agent_name, card_title: title,
    card_number: card_number, project_key: project_key, source: :fizzy
  )

  prompt = if planning_info
             LOG.info "[Planning] Planning mode active for card ##{card_number}"
             template_vars["CARD_ID"] = planning_info[:card_id]
             render_planning_prompt(PROMPT_CARD_ASSIGNED, template_vars,
                                    brain_context: brain_ctx, card_context: card_context, agent_name: agent_name)
           else
             template_vars["CARD_ID"] = card_number
             render_prompt(PROMPT_CARD_ASSIGNED, template_vars,
                           brain_context: brain_ctx, card_context: card_context, agent_name: agent_name)
           end

  card_key = "card-#{card_number}"
  pid, log_file = run_agent(prompt,
                            project_config: project_config, chdir: worktree_path,
                            log_name: "assigned-#{card_number}", model: model, effort: effort,
                            agent_name: agent_name, card_number: card_number, source: :fizzy,
                            source_context: { card_number: card_number },
                            cli_provider: cli_provider_override)
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: agent_name)

  Thread.new { move_card_to_column(card_number, "right_now", project_config: project_config, agent_name: agent_name) }

  [200, { status: "processed", card: card_number, branch: branch, project: project_key, agent: agent_name }.to_json]
end
