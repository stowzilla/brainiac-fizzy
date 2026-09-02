# frozen_string_literal: true

# Fizzy card assignment handler.
#
# When a card is assigned to a local agent, creates a worktree, builds the prompt,
# and dispatches the agent to begin work.

def handle_card_assigned(payload, board_key: nil)
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

  project_result = identify_project_by_tags(tags, board_key: board_key)
  unless project_result
    tag_names = tags.map { |t| t.is_a?(Hash) ? t["name"] : t }.join(", ")
    LOG.warn "No project found for card ##{card_number} with tags: #{tag_names} (board: #{board_key})"
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
  worktree_path = setup_assigned_worktree(repo_path, branch, card_internal_id, card_number, project_key, assigned_agent, board_key: board_key)

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

  # Create ephemeral Belt environment if card has deploy tag and it's a Belt app
  has_deploy_tag = tags.any? do |tag|
    name = (tag.is_a?(Hash) ? tag["name"] : tag).to_s.downcase
    name == "deploy"
  end
  if has_deploy_tag
    maybe_create_ephemeral_belt_env(
      worktree_path: worktree_path, card_number: card_number, project_key: project_key
    )
  end

  dispatch_assigned_card(
    card_number: card_number, card_internal_id: card_internal_id, title: title, tags: tags,
    branch: branch, worktree_path: worktree_path, project_config: project_config, project_key: project_key,
    agent_name: assigned_agent, model: initial_model,
    effort: initial_effort, cli_provider_override: initial_cli, board_key: board_key
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

def setup_assigned_worktree(repo_path, branch, card_internal_id, card_number, project_key, agent_name, board_key: nil)
  debounced_repo_fetch(repo_path)
  worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{branch}")

  # Allow plugins (e.g., brainiac-basecamp) to override the base branch for epic workflows.
  base_ref = if defined?(resolve_base_branch)
               resolve_base_branch(repo_path: repo_path, card_number: card_number, project_key: project_key)
             end

  worktree_path = create_or_reuse_worktree(repo_path: repo_path, branch: branch, base_ref: base_ref, worktree_path: worktree_path)

  source_data = { "card_internal_id" => card_internal_id, "card_number" => card_number }
  source_data["board_key"] = board_key if board_key

  register_work_item(
    branch: branch, worktree: worktree_path, project: project_key, agent: agent_name,
    source: :fizzy, source_data: source_data
  )
  worktree_path
end

def dispatch_assigned_card(card_number:, card_internal_id:, title:, tags:, branch:, worktree_path:,
                           project_config:, project_key:, agent_name:, model:, effort:, cli_provider_override:, board_key: nil)
  card_context = prefetch_card_context(card_number, repo_path: project_config["repo_path"], agent_name: agent_name)
  planning_info = detect_planning_mode(text: title, tags: tags, card_internal_id: card_internal_id, card_number: card_number)

  template_vars = {
    "CARD_NUMBER" => card_number, "CARD_TITLE" => title,
    "BRANCH" => branch, "COMMENT_CREATOR" => agent_name
  }

  # Resolve custom PR target (for epic branch workflows)
  pr_target = resolve_pr_target(repo_path: project_config["repo_path"], card_number: card_number, project_key: project_key)
  template_vars["PR_TARGET_INSTRUCTION"] = if pr_target
                                             "**IMPORTANT: Open the PR targeting the `#{pr_target}` branch " \
                                               "(not main).** Use: `gh pr create --base #{pr_target}`"
                                           else
                                             ""
                                           end
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

  # Inject GitHub App token so agent's gh commands run as their bot identity
  github_repo = project_config["github_repo"]
  agent_github_env = resolve_github_agent_env(agent_name, github_repo)

  pid, log_file = run_agent(prompt,
                            project_config: project_config, chdir: worktree_path,
                            log_name: "assigned-#{card_number}", model: model, effort: effort,
                            agent_name: agent_name, card_number: card_number, source: :fizzy,
                            source_context: { card_number: card_number, board_key: board_key, dispatched_at: Time.now },
                            cli_provider: cli_provider_override, env: agent_github_env)
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: agent_name)

  Thread.new { move_card_to_column(card_number, "right_now", project_config: project_config, agent_name: agent_name, board_key: board_key) }

  [200, { status: "processed", card: card_number, branch: branch, project: project_key, agent: agent_name }.to_json]
end

# Create an ephemeral Belt environment for a card if:
# 1. The project has a parent environment configured
# 2. The worktree is a Belt application
# 3. Ephemeral deploys are enabled in basecamp.json
#
# This runs in the background to not block agent dispatch.
def maybe_create_ephemeral_belt_env(worktree_path:, card_number:, project_key:)
  Thread.new do
    # Check if Belt utilities are available (loaded from brainiac core)
    unless defined?(BeltHelpers) && defined?(BeltConfig) && defined?(BeltEnvironment)
      LOG.debug "[EphemeralEnv] Belt utilities not available — skipping ephemeral env creation"
      next
    end

    # Check if this is a Belt app
    unless belt_app?(worktree_path)
      LOG.debug "[EphemeralEnv] #{project_key} is not a Belt app — skipping ephemeral env"
      next
    end

    # Check if ephemeral deploys are enabled
    unless BeltConfig.ephemeral_deploys_enabled?
      LOG.info "[EphemeralEnv] Ephemeral deploys disabled in basecamp.json"
      next
    end

    # Get the parent environment for this project
    parent_env = BeltConfig.parent_env_for(project_key)
    unless parent_env
      LOG.info "[EphemeralEnv] No parent env configured for #{project_key} in basecamp.json deploy.project_envs"
      next
    end

    env_name = BeltConfig.ephemeral_env_for_card(card_number)

    # Check if environment already exists (re-assignment scenario)
    if BeltConfig.ephemeral_env?(env_name)
      LOG.info "[EphemeralEnv] Environment #{env_name} already exists — skipping creation"
      next
    end

    LOG.info "[EphemeralEnv] Creating ephemeral environment '#{env_name}' from '#{parent_env}' for card ##{card_number}"

    # Create the environment
    success = BeltEnvironment.create_environment(
      worktree: worktree_path,
      env_name: env_name,
      parent_env: parent_env
    )

    if success
      BeltConfig.track_ephemeral_env(env_name,
                                     "card_number" => card_number,
                                     "project" => project_key,
                                     "parent_env" => parent_env,
                                     "worktree" => worktree_path)
      LOG.info "[EphemeralEnv] Successfully created and tracked environment '#{env_name}'"

      # Deploy to the ephemeral environment
      frontend_only = BeltEnvironment.frontend_only_changes?(worktree: worktree_path)
      BeltEnvironment.deploy(worktree: worktree_path, env_name: env_name, frontend_only: frontend_only)
    else
      LOG.error "[EphemeralEnv] Failed to create environment '#{env_name}'"
    end
  rescue StandardError => e
    LOG.error "[EphemeralEnv] Error creating ephemeral env: #{e.message}"
  end
end
