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

  maybe_create_ephemeral_belt_env(
    worktree_path: worktree_path, card_number: card_number, project_key: project_key, tags: tags
  )

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

# Ensure an ephemeral Belt environment is configured in the worktree when the
# card has a `deploy` tag. Fizzy has no tag-added webhook, so comment handlers
# pass fetch_live_tags: true to read current tags from `fizzy card show`.
#
# `belt g environment` is synchronous so the worktree is configured before the
# agent starts. The actual `belt deploy` runs in the background.
def maybe_create_ephemeral_belt_env(worktree_path:, card_number:, project_key:, tags: nil,
                                    repo_path: nil, agent_name: nil, fetch_live_tags: false)
  unless defined?(BeltConfig) && defined?(BeltEnvironment)
    LOG.debug "[EphemeralEnv] Belt utilities not available — skipping"
    return
  end

  unless worktree_path && File.directory?(worktree_path)
    LOG.debug "[EphemeralEnv] Worktree missing at #{worktree_path.inspect} — skipping"
    return
  end

  unless belt_app_for_ephemeral?(worktree_path)
    LOG.debug "[EphemeralEnv] #{project_key} is not a Belt app — skipping"
    return
  end

  unless BeltConfig.ephemeral_deploys_enabled?
    LOG.info "[EphemeralEnv] Ephemeral deploys disabled in basecamp.json"
    return
  end

  resolved_tags = resolve_ephemeral_env_tags(
    tags, card_number: card_number, repo_path: repo_path || worktree_path,
          agent_name: agent_name, fetch_live_tags: fetch_live_tags
  )
  tag_list = tag_names(resolved_tags)
  unless tag_list.include?("deploy")
    LOG.debug "[EphemeralEnv] Card ##{card_number} tags=#{tag_list.inspect} — no deploy tag, skipping"
    return
  end

  parent_env = BeltConfig.parent_env_for(project_key)
  unless parent_env
    LOG.info "[EphemeralEnv] Card ##{card_number} has deploy tag but no parent env configured for #{project_key}"
    return
  end

  env_name = BeltConfig.ephemeral_env_for_card(card_number)
  env_dir = File.join(worktree_path, "infrastructure", env_name.to_s)

  if File.directory?(env_dir)
    LOG.info "[EphemeralEnv] Card ##{card_number} has deploy tag; #{env_name} already configured at #{env_dir}"
    track_ephemeral_env_if_needed(env_name, card_number, project_key, parent_env, worktree_path)
    return
  end

  parent_dir = File.join(worktree_path, "infrastructure", parent_env.to_s)
  unless File.directory?(parent_dir)
    LOG.error "[EphemeralEnv] Parent env '#{parent_env}' not found at #{parent_dir}"
    return
  end

  LOG.info "[EphemeralEnv] Card ##{card_number} has deploy tag; #{env_name} not in worktree — creating from '#{parent_env}'"
  create_and_deploy_ephemeral_env(
    worktree_path: worktree_path, env_name: env_name, parent_env: parent_env,
    card_number: card_number, project_key: project_key
  )
rescue StandardError => e
  LOG.error "[EphemeralEnv] Error creating ephemeral env: #{e.message}"
end

def ensure_ephemeral_env_for_comment(ctx, card_number, worktree)
  return unless card_number && worktree && File.directory?(worktree)

  maybe_create_ephemeral_belt_env(
    worktree_path: worktree, card_number: card_number, project_key: ctx.project_key,
    tags: ctx.card_tags, repo_path: ctx.project_config["repo_path"],
    agent_name: ctx.agent_name, fetch_live_tags: true
  )
end

def belt_app_for_ephemeral?(worktree_path)
  return BeltEnvironment.belt_app?(worktree_path) if defined?(BeltEnvironment) && BeltEnvironment.respond_to?(:belt_app?)

  %w[config/routes.rb config/routes.tf.rb infrastructure/routes.tf.rb].any? do |rel|
    File.exist?(File.join(worktree_path, rel))
  end
end

def resolve_ephemeral_env_tags(tags, card_number:, repo_path:, agent_name:, fetch_live_tags:)
  return tags unless fetch_live_tags && card_number

  live = fetch_card_tags(card_number, repo_path: repo_path, env: fizzy_env_for(agent_name || AI_AGENT_NAME))
  if live
    LOG.info "[EphemeralEnv] Card ##{card_number} live tags: #{tag_names(live).inspect}"
    live
  else
    LOG.warn "[EphemeralEnv] Could not fetch live tags for card ##{card_number} — falling back to webhook tags #{tag_names(tags).inspect}"
    tags
  end
end

def track_ephemeral_env_if_needed(env_name, card_number, project_key, parent_env, worktree_path)
  return if BeltConfig.ephemeral_env?(env_name)

  BeltConfig.track_ephemeral_env(env_name,
                                 "card_number" => card_number,
                                 "project" => project_key,
                                 "parent_env" => parent_env,
                                 "worktree" => worktree_path)
end

def create_and_deploy_ephemeral_env(worktree_path:, env_name:, parent_env:, card_number:, project_key:)
  success = BeltEnvironment.create_environment(
    worktree: worktree_path, env_name: env_name, parent_env: parent_env
  )
  unless success
    LOG.error "[EphemeralEnv] Failed to create environment '#{env_name}'"
    return
  end

  BeltConfig.track_ephemeral_env(env_name,
                                 "card_number" => card_number,
                                 "project" => project_key,
                                 "parent_env" => parent_env,
                                 "worktree" => worktree_path)
  LOG.info "[EphemeralEnv] Configured #{env_name} in worktree, deploying in background"

  Thread.new do
    frontend_only = BeltEnvironment.frontend_only_changes?(worktree: worktree_path)
    BeltEnvironment.deploy(worktree: worktree_path, env_name: env_name, frontend_only: frontend_only)
  rescue StandardError => e
    LOG.error "[EphemeralEnv] Error deploying '#{env_name}': #{e.message}"
  end
end
