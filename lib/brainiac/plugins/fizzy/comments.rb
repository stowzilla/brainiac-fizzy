# frozen_string_literal: true

# Fizzy comment handler — routes incoming comments to the appropriate dispatch path.
#
# This is the main routing logic for Fizzy card comments:
# - Deploy shortcuts (dev01, dev02, etc.)
# - Cancel commands
# - Cross-agent mentions (@Galen on Kaylee's card)
# - Follow-up comments on existing worktrees
# - New mentions on untracked cards

# Context struct that accumulates state as a comment flows through the routing pipeline.
# Replaces long keyword-arg lists between sub-handlers.
CommentContext = Struct.new(
  :eventable, :plain_text, :card_internal_id, :card_info,
  :comment_id, :creator_name, :creator_is_agent,
  :mentioned_agent, :agent_name, :is_cross_agent_mention,
  :project_config, :project_key, :card_number, :worktree,
  :model, :effort, :deploy_intent, :cli_provider_override,
  :comment_vars, :card_tags, :worktree_override,
  keyword_init: true
)

def handle_comment(payload)
  eventable = payload["eventable"] || {}
  plain_text = eventable.dig("body", "plain_text") || ""
  card_internal_id = eventable.dig("card", "id")

  return handle_deploy_comment(eventable, plain_text.strip.downcase, card_internal_id) if plain_text.strip.match?(/\Adev\d+\z/i)

  mentioned_agent = detect_mentioned_agent(plain_text)
  gate_result = check_mention_gates(mentioned_agent, plain_text)
  return gate_result if gate_result

  creator_name, creator_is_agent, is_api_sourced = extract_creator_info(payload, eventable)
  unless creator_is_agent || is_api_sourced
    auth_result = authorize_human_comment(eventable, card_internal_id, creator_name, plain_text)
    return auth_result if auth_result
  end

  agent_result = validate_agent_comment(creator_is_agent, is_api_sourced, creator_name, mentioned_agent, card_internal_id)
  return agent_result if agent_result

  card_info = load_card_map[card_internal_id]
  comment_id = eventable["id"]

  return [200, { status: "ignored", reason: "not relevant" }.to_json] unless mentioned_agent || card_info

  project_config, project_key = resolve_fizzy_project(card_info, card_internal_id, eventable)
  return [200, { status: "ignored", reason: "no matching project" }.to_json] unless project_config

  tags = parse_inline_tags(plain_text)

  agent_name, is_cross_agent_mention = resolve_comment_agent(
    mentioned_agent: mentioned_agent, card_info: card_info, card_internal_id: card_internal_id,
    eventable: eventable, project_config: project_config, creator_is_agent: creator_is_agent
  )
  return [200, { status: "ignored", reason: "no assigned agent" }.to_json] unless agent_name

  cooldown_key = "card-#{card_info ? (card_info["number"] || card_internal_id) : card_internal_id}-#{agent_name.downcase}"
  if on_comment_cooldown?(cooldown_key)
    LOG.info "Skipping comment on #{cooldown_key} — within #{COMMENT_COOLDOWN}s cooldown"
    return [200, { status: "ignored", reason: "comment cooldown" }.to_json]
  end
  touch_comment_cooldown(cooldown_key)

  ctx = build_comment_context(
    eventable: eventable, plain_text: plain_text, tags: tags, card_internal_id: card_internal_id,
    card_info: card_info, comment_id: comment_id, creator_name: creator_name,
    creator_is_agent: creator_is_agent, mentioned_agent: mentioned_agent,
    agent_name: agent_name, is_cross_agent_mention: is_cross_agent_mention,
    project_config: project_config, project_key: project_key
  )

  # --- Route to appropriate sub-handler ---
  if is_cross_agent_mention
    handle_cross_agent_mention(ctx)
  elsif card_info || ctx.worktree_override
    handle_existing_card_comment(ctx)
  else
    handle_new_mention(ctx)
  end
end

# --- Early-exit helpers ---

def build_comment_context(eventable:, plain_text:, tags:, card_internal_id:, card_info:, comment_id:, creator_name:,
                          creator_is_agent:, mentioned_agent:, agent_name:, is_cross_agent_mention:,
                          project_config:, project_key:)
  deploy_intent = tags[:deploy_intent]
  LOG.info "[Deploy] Detected [deploy#{":#{deploy_intent}" unless deploy_intent == :auto}] tag on card #{card_internal_id}" if deploy_intent

  card_tags = eventable.dig("card", "tags") || []
  clean_text = tags[:clean_text]

  CommentContext.new(
    eventable: eventable, plain_text: clean_text, card_internal_id: card_internal_id,
    card_info: card_info, comment_id: comment_id, creator_name: creator_name,
    creator_is_agent: creator_is_agent, mentioned_agent: mentioned_agent,
    agent_name: agent_name, is_cross_agent_mention: is_cross_agent_mention,
    project_config: project_config, project_key: project_key,
    model: detect_model(project_config, text: plain_text),
    effort: detect_effort(project_config, tags: card_tags, text: plain_text),
    deploy_intent: deploy_intent,
    cli_provider_override: detect_cli_provider(text: plain_text, tags: card_tags),
    card_tags: card_tags,
    worktree_override: resolve_worktree_override(tags, project_config),
    comment_vars: {
      "COMMENT_CREATOR" => creator_name || "Unknown",
      "COMMENT_ID" => comment_id.to_s,
      "COMMENT_BODY" => clean_text
    }
  )
end

def check_mention_gates(mentioned_agent, plain_text)
  mentioned_user_ids = detect_mentioned_user_ids(plain_text)
  if mentioned_user_ids.any? { |id| human_mentioned?(id) }
    LOG.info "[Fizzy] Human @mentioned in comment, skipping agent dispatch"
    return [200, { status: "ignored", reason: "human mentioned" }.to_json]
  end

  if mentioned_agent && !local_agent_names.include?(mentioned_agent)
    LOG.info "[Fizzy] Ignoring mention of non-local agent #{mentioned_agent}"
    return [200, { status: "ignored", reason: "non-local agent mentioned" }.to_json]
  end

  nil
end

def extract_creator_info(payload, eventable)
  creator_name = eventable.dig("creator", "name")
  creator_is_agent = comment_from_agent?(creator_name)
  creator_is_agent ||= comment_from_agent?(payload.dig("creator", "name"))

  source = eventable["source"] || payload["source"]
  is_api_sourced = source && source != "web"

  [creator_name, creator_is_agent, is_api_sourced]
end

def authorize_human_comment(eventable, card_internal_id, creator_name, plain_text)
  creator_id = eventable.dig("creator", "id")

  unless AUTHORIZED_USER_IDS.include?(creator_id)
    notify_unauthorized("comment_created", creator_name, "card #{card_internal_id}")
    return [200, { status: "ignored", reason: "unauthorized" }.to_json]
  end

  record_human_comment(card_internal_id)

  cancel_keywords = %w[cancel stop halt abort kill ❌]
  return handle_cancel_command(eventable, card_internal_id) if cancel_keywords.include?(plain_text.strip.downcase)

  nil
end

def validate_agent_comment(creator_is_agent, is_api_sourced, creator_name, mentioned_agent, card_internal_id)
  return nil unless creator_is_agent || is_api_sourced

  card_info = load_card_map[card_internal_id]
  card_assigned_agent = card_info&.dig("agent")

  agent_is_assigned = card_assigned_agent && card_assigned_agent.downcase == (creator_name || "").downcase
  agent_is_mentioned = mentioned_agent && mentioned_agent.downcase == (creator_name || "").downcase

  unless agent_is_assigned || agent_is_mentioned
    LOG.info "Blocking agent comment from #{creator_name} on card #{card_internal_id}: not assigned and not mentioned"
    return [200, { status: "ignored", reason: "agent not assigned or mentioned" }.to_json]
  end

  # Agent-to-agent loop prevention
  if mentioned_agent && mentioned_agent.downcase != (creator_name || "").downcase
    unless agent_dispatch_allowed?(card_internal_id)
      LOG.info "Blocking agent-to-agent dispatch on card #{card_internal_id}: " \
               "depth limit reached (#{creator_name} → @#{mentioned_agent})"
      return [200, { status: "ignored", reason: "agent-to-agent depth limit" }.to_json]
    end
    LOG.info "Allowing agent-to-agent dispatch on card #{card_internal_id}: #{creator_name} → @#{mentioned_agent}"
  elsif !mentioned_agent
    LOG.info "Ignoring self-comment from #{creator_name} on card #{card_internal_id}"
    return [200, { status: "ignored", reason: "self-comment" }.to_json]
  end

  nil
end

def resolve_worktree_override(tags, project_config)
  return nil unless tags[:worktree_override]

  override_branch = tags[:worktree_override]
  repo_path = project_config["repo_path"]
  candidate = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{override_branch}")

  if File.directory?(candidate)
    LOG.info "Worktree override requested: #{override_branch} -> #{candidate}"
    { "branch" => override_branch, "worktree" => candidate }
  else
    LOG.warn "Worktree override branch '#{override_branch}' not found at #{candidate}, ignoring"
    nil
  end
end

# --- Comment sub-handlers ---

# --- Comment sub-handlers ---

def handle_cancel_command(eventable, card_internal_id)
  killed = 0
  card_number_for_cancel = load_card_map.dig(card_internal_id, "number")
  prefixes = ["card-#{card_internal_id}"]
  prefixes << "card-#{card_number_for_cancel}" if card_number_for_cancel

  ACTIVE_SESSIONS_MUTEX.synchronize do
    ACTIVE_SESSIONS.keys.select { |k| prefixes.any? { |p| k == p || k.start_with?("#{p}-") } }.each do |key|
      info = ACTIVE_SESSIONS[key]
      next unless info

      begin
        Process.kill("KILL", info[:pid])
        LOG.info "[Fizzy] Cancelled session #{key} (PID: #{info[:pid]})"
      rescue Errno::ESRCH, Errno::EPERM => e
        LOG.warn "[Fizzy] Could not kill #{key}: #{e.message}"
      end
      archive_session(key, info)
      ACTIVE_SESSIONS.delete(key)
      killed += 1
    end
  end

  comment_id_for_cancel = eventable["id"]
  card_info_for_cancel = load_card_map[card_internal_id]
  if card_info_for_cancel && card_number_for_cancel && comment_id_for_cancel
    repo = (card_info_for_cancel["project"] && PROJECTS.dig(card_info_for_cancel["project"], "repo_path")) ||
           DEFAULT_PROJECT["repo_path"]
    Thread.new do
      run_cmd("fizzy", "reaction", "create", "--card", card_number_for_cancel.to_s,
              "--comment", comment_id_for_cancel.to_s, "--content", "🛑",
              chdir: repo, env: default_fizzy_env)
    rescue StandardError => e
      LOG.warn "[Fizzy] Could not add 🛑 reaction: #{e.message}"
    end
  end

  LOG.info "[Fizzy] Cancel command received for card #{card_number_for_cancel || card_internal_id}: killed #{killed} session(s)"
  [200, { status: "cancelled", card: card_number_for_cancel || card_internal_id, sessions_killed: killed }.to_json]
end

def resolve_fizzy_project(card_info, card_internal_id, eventable)
  if card_info
    if card_info["project"]
      project_key = card_info["project"]
      project_config = PROJECTS[project_key] || DEFAULT_PROJECT
    else
      card_tags = eventable.dig("card", "tags") || []
      project_result = identify_project_by_tags(card_tags)
      if project_result
        project_key, project_config = project_result
        card_info["project"] = project_key
        map = load_card_map
        map[card_internal_id] = card_info
        save_card_map(map)
        LOG.info "Backfilled project '#{project_key}' for card #{card_internal_id} in card map"
      else
        LOG.warn "No project found for card #{card_internal_id}"
        return [nil, nil]
      end
    end
  else
    card_tags = eventable.dig("card", "tags") || []
    project_result = identify_project_by_tags(card_tags)
    if project_result
      project_key, project_config = project_result
    else
      LOG.warn "No project found for mentioned card #{card_internal_id}"
      return [nil, nil]
    end
  end

  [project_config, project_key]
end

def resolve_comment_agent(mentioned_agent:, card_info:, card_internal_id:, eventable:, project_config:, creator_is_agent:)
  card_assigned_agent = card_info&.dig("agent")

  # Resolve assigned agent from payload or API if missing
  card_assigned_agent = resolve_assigned_agent(card_info, card_internal_id, eventable, project_config) if card_assigned_agent.nil?

  if mentioned_agent
    agent_name = mentioned_agent
    is_cross_agent_mention = !card_assigned_agent || card_assigned_agent != mentioned_agent
  else
    unless card_assigned_agent
      LOG.info "Skipping card #{card_internal_id} — no assigned agent and no mention"
      return [nil, false]
    end
    agent_name = card_assigned_agent
    is_cross_agent_mention = false
  end

  [agent_name, is_cross_agent_mention]
end

def resolve_assigned_agent(card_info, card_internal_id, eventable, project_config)
  card_assignees = eventable.dig("card", "assignees") || []
  webhook_agent = card_assignees.map { |a| a["name"] }.find { |name| local_agent_names.include?(name) }

  webhook_agent = resolve_agent_via_api(card_info, card_internal_id, project_config) if webhook_agent.nil? && project_config

  return nil unless webhook_agent

  map = load_card_map
  map[card_internal_id] ||= {}
  map[card_internal_id]["agent"] = webhook_agent
  save_card_map(map)
  LOG.info "Backfilled agent '#{webhook_agent}' into card map for #{card_internal_id}"
  webhook_agent
end

def resolve_agent_via_api(card_info, card_internal_id, project_config)
  api_card_number = card_info&.dig("number") || card_internal_id
  return nil unless api_card_number

  output = run_cmd("fizzy", "card", "show", api_card_number.to_s,
                   chdir: project_config["repo_path"], env: default_fizzy_env)
  api_assignees = begin
    JSON.parse(output).dig("data", "assignees") || []
  rescue StandardError
    []
  end
  agent = api_assignees.map { |a| a["name"] }.find { |name| local_agent_names.include?(name) }
  LOG.info "Resolved assigned agent '#{agent}' via Fizzy API for card ##{api_card_number}" if agent
  agent
rescue StandardError => e
  LOG.warn "Fizzy API fallback failed for card ##{api_card_number}: #{e.message}"
  nil
end

# Handle cross-agent mention (agent tagged on another agent's card)
def handle_cross_agent_mention(ctx)
  card_assigned_agent = ctx.card_info&.dig("agent")
  return [200, { status: "ignored", reason: "card creation announcement" }.to_json] if cross_agent_announcement?(ctx)

  card_number = ctx.card_info&.dig("number")
  card_number ||= resolve_card_number(ctx.card_internal_id, repo_path: ctx.project_config["repo_path"])
  card_key = "card-#{card_number || ctx.card_internal_id}-#{ctx.agent_name.downcase}"
  if ctx.creator_is_agent && session_active?(card_key)
    return [200, { status: "ignored", reason: "session wait timeout" }.to_json] unless wait_for_session?(card_key)
  elsif session_active?(card_key)
    return [200, { status: "ignored", reason: "session already active" }.to_json]
  end

  LOG.info "Cross-agent mention: #{ctx.agent_name} tagged on #{card_assigned_agent}'s card " \
           "##{card_number || ctx.card_internal_id} (project: #{ctx.project_key})"
  record_agent_dispatch(ctx.card_internal_id) if ctx.creator_is_agent

  react_to_comment(card_number, ctx.comment_id, ctx.project_config, ctx.agent_name, "👀")

  review_worktree_path, review_branch = setup_cross_agent_worktree(ctx, card_number)
  card_context = prefetch_card_context(card_number, repo_path: ctx.project_config["repo_path"], agent_name: ctx.agent_name)

  prompt = render_prompt(PROMPT_CROSS_AGENT_REVIEW,
                         ctx.comment_vars.merge(
                           "CARD_NUMBER" => card_number || "N/A",
                           "CARD_INTERNAL_ID" => ctx.card_internal_id,
                           "CARD_ID" => card_number || ctx.card_internal_id,
                           "CARD_AGENT" => card_assigned_agent,
                           "WORKTREE_PATH" => review_worktree_path,
                           "BRANCH" => review_branch
                         ),
                         brain_context: build_brain_context(
                           agent_name: ctx.agent_name, card_number: card_number,
                           project_key: ctx.project_key, comment_body: ctx.plain_text, source: :fizzy
                         ),
                         card_context: card_context,
                         agent_name: ctx.agent_name)

  pid, log_file = run_agent(prompt,
                            project_config: ctx.project_config, chdir: review_worktree_path,
                            log_name: "review-#{ctx.agent_name.downcase}-#{card_number || ctx.card_internal_id}",
                            model: ctx.model, effort: ctx.effort, agent_name: ctx.agent_name,
                            card_number: card_number, comment_id: ctx.comment_id,
                            source: :fizzy, source_context: { card_number: card_number },
                            cli_provider: ctx.cli_provider_override)
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: ctx.agent_name)

  [200, { status: "cross_agent_review", agent: ctx.agent_name, card_agent: card_assigned_agent,
          card: card_number, card_internal_id: ctx.card_internal_id,
          project: ctx.project_key, worktree: review_worktree_path }.to_json]
end

# Handle comment on a card that's already in the card map (or has a worktree override)
def handle_existing_card_comment(ctx)
  effective_info = ctx.worktree_override ? (ctx.card_info || {}).merge(ctx.worktree_override) : ctx.card_info
  card_number = effective_info["number"]
  worktree = effective_info["worktree"]

  card_number = resolve_and_save_card_number(ctx.card_internal_id, ctx.project_config) if card_number.nil?
  worktree = find_and_save_worktree(ctx.card_internal_id, card_number, ctx.project_config) if !(worktree && File.directory?(worktree)) && card_number

  work_dir = worktree && File.directory?(worktree) ? worktree : ctx.project_config["repo_path"]
  card_key = "card-#{card_number || ctx.card_internal_id}"

  # Session management (wait, supersede, or queue)
  queued = handle_session_conflict(ctx, card_key, card_number, work_dir)
  return queued if queued

  LOG.info "Follow-up comment on card #{card_number || ctx.card_internal_id} " \
           "(project: #{ctx.project_key}), worktree: #{work_dir}"

  react_to_comment(card_number, ctx.comment_id, ctx.project_config, ctx.agent_name, "👍", chdir: work_dir)

  result = dispatch_followup_comment(ctx, card_key: card_key, card_number: card_number, work_dir: work_dir)
  [200, result.to_json]
end

# Handle mention on a card with no existing card_info (exploration)
def handle_new_mention(ctx)
  card_data = ctx.eventable["card"] || {}
  card_number = card_data["number"]
  card_title = card_data["title"] || "exploration"

  if card_number.nil?
    map_entry = load_card_map[ctx.card_internal_id]
    card_number = if map_entry && map_entry["number"]
                    map_entry["number"]
                  else
                    resolve_card_number(ctx.card_internal_id, repo_path: ctx.project_config["repo_path"])
                  end
  end

  LOG.info "#{ctx.agent_name} mentioned on card (internal_id: #{ctx.card_internal_id}, " \
           "project: #{ctx.project_key}), creating exploration worktree"
  record_agent_dispatch(ctx.card_internal_id) if ctx.creator_is_agent

  card_key = "card-#{card_number || ctx.card_internal_id}"
  return [200, { status: "ignored", reason: "session already active" }.to_json] if session_active?(card_key)

  react_to_comment(card_number, ctx.comment_id, ctx.project_config, ctx.agent_name, "👀")

  repo_path = ctx.project_config["repo_path"]
  worktree_path, branch = resolve_or_create_worktree(ctx, card_number, card_title, repo_path)

  map = load_card_map
  map[ctx.card_internal_id] = {
    "number" => card_number, "branch" => branch, "worktree" => worktree_path,
    "project" => ctx.project_key, "agent" => ctx.agent_name
  }
  save_card_map(map)

  prompt = build_mention_prompt(ctx, card_number, card_title, branch, worktree_path)

  pid, log_file = run_agent(prompt,
                            project_config: ctx.project_config, chdir: worktree_path,
                            log_name: "mention-#{card_number || ctx.card_internal_id}",
                            model: ctx.model, effort: ctx.effort, agent_name: ctx.agent_name,
                            card_number: card_number, comment_id: ctx.comment_id,
                            source: :fizzy, cli_provider: ctx.cli_provider_override,
                            source_context: { card_number: card_number })
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: ctx.agent_name)

  [200, { status: "responded", card_internal_id: ctx.card_internal_id, card_number: card_number,
          branch: branch, worktree: worktree_path, project: ctx.project_key }.to_json]
end

# Dispatch a follow-up comment to the agent.
def dispatch_followup_comment(ctx, card_key:, card_number:, work_dir:)
  card_tags = ctx.eventable.dig("card", "tags") || []
  effort = detect_effort(ctx.project_config, tags: card_tags, text: ctx.plain_text)

  is_worktree = work_dir != ctx.project_config["repo_path"]
  resolved = resolve_project_cli_config(ctx.project_config,
                                        cli_provider_override: ctx.cli_provider_override,
                                        agent_name: ctx.agent_name)
  should_resume = is_worktree && resolved["resume_flag"]

  prompt = if should_resume
             LOG.info "[Resume] Using lean prompt for follow-up on card #{card_number || ctx.card_internal_id}"
             render_resume_prompt(
               comment_body: ctx.plain_text, comment_creator: ctx.comment_vars["COMMENT_CREATOR"],
               comment_id: ctx.comment_id, card_number: card_number, agent_name: ctx.agent_name
             )
           else
             build_followup_prompt(ctx, card_number, card_tags, work_dir)
           end

  pid, log_file = run_agent(prompt,
                            project_config: ctx.project_config, chdir: work_dir,
                            log_name: "followup-#{card_number || ctx.card_internal_id}",
                            model: ctx.model, effort: effort, agent_name: ctx.agent_name,
                            card_number: card_number, comment_id: ctx.comment_id,
                            source: :fizzy, cli_provider: ctx.cli_provider_override, resume: is_worktree,
                            source_context: {
                              card_number: card_number, card_internal_id: ctx.card_internal_id,
                              deploy_intent: ctx.deploy_intent
                            })
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: ctx.agent_name)

  Thread.new { move_card_to_column(card_number, "right_now", project_config: ctx.project_config, agent_name: ctx.agent_name) }

  { status: "follow_up", card: card_number, card_internal_id: ctx.card_internal_id,
    worktree: work_dir, project: ctx.project_key }
end

# --- Shared helpers ---

def card_announcement?(text)
  text.match?(/created\s+card\s+#?\d+/i) ||
    text.match?(/assigned\s+.*card\s+#?\d+/i) ||
    text.match?(/card\s+#?\d+.*assigned/i)
end

def cross_agent_announcement?(ctx)
  return false unless ctx.creator_is_agent && card_announcement?(ctx.plain_text)

  LOG.info "Ignoring cross-agent mention from #{ctx.comment_vars["COMMENT_CREATOR"]} " \
           "on card #{ctx.card_internal_id} — card creation/assignment (handled by webhook)"
  true
end

def react_to_comment(card_number, comment_id, project_config, agent_name, emoji, chdir: nil)
  return unless card_number

  work_dir = chdir || project_config["repo_path"]
  Thread.new do
    run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s,
            "--comment", comment_id.to_s, "--content", emoji,
            chdir: work_dir, env: fizzy_env_for(agent_name))
  rescue StandardError => e
    LOG.warn "Could not add #{emoji} reaction to comment: #{e.message}"
  end
end

def resolve_and_save_card_number(card_internal_id, project_config)
  card_number = resolve_card_number(card_internal_id, repo_path: project_config["repo_path"])
  if card_number
    map = load_card_map
    map[card_internal_id] ||= {}
    map[card_internal_id]["number"] = card_number
    save_card_map(map)
  end
  card_number
end

def find_and_save_worktree(card_internal_id, card_number, project_config)
  found = find_worktree_for_card(card_number, repo_path: project_config["repo_path"])
  return nil unless found

  map = load_card_map
  map[card_internal_id] ||= {}
  map[card_internal_id].merge!("worktree" => found[:worktree], "branch" => found[:branch])
  save_card_map(map)
  LOG.info "Found worktree by card number scan: #{found[:worktree]}"
  found[:worktree]
end

def handle_session_conflict(ctx, card_key, card_number, work_dir)
  if ctx.creator_is_agent && session_active?(card_key)
    return [200, { status: "ignored", reason: "session wait timeout" }.to_json] unless wait_for_session?(card_key)
  elsif session_active?(card_key)
    prev = find_supersedable_session(card_key)
    return queue_followup(ctx, card_key, card_number, work_dir) unless prev

    LOG.info "Superseding session on card #{card_number || ctx.card_internal_id} " \
             "(pid: #{prev[:pid]}) — human follow-up within #{SUPERSEDE_WINDOW}s"
    kill_session(prev[:session_key])

  end
  nil
end

def queue_followup(ctx, card_key, card_number, work_dir)
  react_to_comment(card_number, ctx.comment_id, ctx.project_config, ctx.agent_name, "👍", chdir: work_dir)

  Thread.new do
    unless wait_for_session?(card_key)
      LOG.warn "Giving up on queued follow-up for card #{card_number || ctx.card_internal_id}"
      next
    end
    dispatch_followup_comment(ctx, card_key: card_key, card_number: card_number, work_dir: work_dir)
  end

  [200, { status: "queued", card: card_number, card_internal_id: ctx.card_internal_id,
          reason: "waiting for active session" }.to_json]
end

def setup_cross_agent_worktree(ctx, card_number)
  repo_path = ctx.project_config["repo_path"]
  card_title = ctx.card_info&.dig("title") || ctx.eventable.dig("card", "title") || "review"
  review_branch = "#{ctx.agent_name.downcase}/fizzy-#{card_number}-#{slugify(card_title)}"
  review_worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{review_branch.tr("/", "-")}")

  debounced_repo_fetch(repo_path)

  if File.directory?(review_worktree_path)
    worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)
    FileUtils.rm_rf(review_worktree_path) unless worktree_list.include?(review_worktree_path)
  end

  create_review_worktree(repo_path, review_branch, review_worktree_path, ctx.card_info) unless File.directory?(review_worktree_path)

  [review_worktree_path, review_branch]
end

def create_review_worktree(repo_path, review_branch, review_worktree_path, card_info)
  card_branch = card_info&.dig("branch")
  branch_exists = card_branch && system("git", "rev-parse", "--verify", card_branch,
                                        chdir: repo_path, out: File::NULL, err: File::NULL)
  base_ref = branch_exists ? card_branch : "origin/#{get_default_branch(repo_path)}"

  if system("git", "rev-parse", "--verify", review_branch, chdir: repo_path, out: File::NULL, err: File::NULL)
    run_cmd("git", "branch", "-D", review_branch, chdir: repo_path)
  end

  run_cmd("git", "worktree", "add", "-b", review_branch, review_worktree_path, base_ref, chdir: repo_path)
  trust_version_manager(review_worktree_path, chdir: review_worktree_path)
  apply_worktree_includes(repo_path, review_worktree_path)
  run_project_hook(repo_path, "worktree-setup", extra_env: { "WORKTREE_PATH" => review_worktree_path })
  LOG.info "Created cross-agent review worktree at #{review_worktree_path} (base: #{base_ref})"
end

def resolve_or_create_worktree(ctx, card_number, card_title, repo_path)
  # Check for existing worktree in card map or on disk
  existing_map_entry = load_card_map[ctx.card_internal_id]
  if existing_map_entry && existing_map_entry["branch"] && existing_map_entry["worktree"] &&
     File.directory?(existing_map_entry["worktree"])
    LOG.info "Reusing existing worktree from card map: #{existing_map_entry["worktree"]}"
    return [existing_map_entry["worktree"], existing_map_entry["branch"]]
  end

  if card_number
    found = find_worktree_for_card(card_number, repo_path: repo_path)
    if found
      LOG.info "Found existing worktree by card number scan: #{found[:worktree]}"
      return [found[:worktree], found[:branch]]
    end
  end

  branch = card_number ? "fizzy-#{card_number}-#{slugify(card_title)}" : "fizzy-explore-#{ctx.card_internal_id[0..7]}"
  debounced_repo_fetch(repo_path)
  worktree_path = create_or_reuse_worktree(repo_path: repo_path, branch: branch)
  [worktree_path, branch]
end

def build_mention_prompt(ctx, card_number, card_title, branch, worktree_path)
  planning_info = detect_planning_mode(text: ctx.plain_text, tags: ctx.card_tags,
                                       card_internal_id: ctx.card_internal_id, card_number: card_number)

  if planning_info
    render_planning_prompt(PROMPT_MENTION,
                           ctx.comment_vars.merge(
                             "CARD_INTERNAL_ID" => ctx.card_internal_id, "CARD_ID" => planning_info[:card_id],
                             "CARD_NUMBER" => card_number || "N/A",
                             "CARD_NUMBER_TEXT" => card_number ? " (##{card_number})" : "",
                             "BRANCH" => branch
                           ),
                           brain_context: build_brain_context(
                             agent_name: ctx.agent_name, card_title: card_title, card_number: card_number,
                             project_key: ctx.project_key, comment_body: ctx.plain_text, source: :fizzy
                           ),
                           card_context: prefetch_card_context(card_number, repo_path: worktree_path,
                                                                            agent_name: ctx.agent_name),
                           agent_name: ctx.agent_name)
  else
    card_id = card_number || ctx.card_internal_id
    render_prompt(PROMPT_MENTION,
                  ctx.comment_vars.merge(
                    "CARD_INTERNAL_ID" => ctx.card_internal_id, "CARD_ID" => card_id,
                    "CARD_NUMBER" => card_number || "N/A", "CARD_NUMBER_TEXT" => card_number || ctx.card_internal_id
                  ),
                  brain_context: build_brain_context(
                    agent_name: ctx.agent_name, card_title: card_title, card_number: card_number,
                    project_key: ctx.project_key, comment_body: ctx.plain_text, source: :fizzy
                  ),
                  card_context: prefetch_card_context(card_number, repo_path: worktree_path,
                                                                   agent_name: ctx.agent_name),
                  agent_name: ctx.agent_name)
  end
end

def build_followup_prompt(ctx, card_number, card_tags, work_dir)
  planning_info = detect_planning_mode(text: ctx.plain_text, tags: card_tags,
                                       card_internal_id: ctx.card_internal_id, card_number: card_number)

  if planning_info
    build_planning_followup_prompt(ctx, card_number, planning_info[:card_id], work_dir)
  elsif work_dir != ctx.project_config["repo_path"]
    render_prompt(PROMPT_FOLLOWUP_WORKTREE,
                  ctx.comment_vars.merge("CARD_NUMBER" => card_number, "CARD_ID" => card_number),
                  brain_context: build_brain_context(
                    agent_name: ctx.agent_name, card_number: card_number,
                    project_key: ctx.project_key, comment_body: ctx.plain_text, source: :fizzy
                  ),
                  card_context: prefetch_card_context(card_number, repo_path: work_dir, agent_name: ctx.agent_name),
                  agent_name: ctx.agent_name)
  else
    render_prompt(PROMPT_FOLLOWUP_NO_WORKTREE,
                  ctx.comment_vars.merge("CARD_INTERNAL_ID" => ctx.card_internal_id, "CARD_ID" => ctx.card_internal_id),
                  brain_context: build_brain_context(
                    agent_name: ctx.agent_name, project_key: ctx.project_key,
                    comment_body: ctx.plain_text, source: :fizzy
                  ),
                  card_context: prefetch_card_context(card_number, repo_path: ctx.project_config["repo_path"],
                                                                   agent_name: ctx.agent_name),
                  agent_name: ctx.agent_name)
  end
end

def build_planning_followup_prompt(ctx, card_number, card_id, work_dir)
  if work_dir == ctx.project_config["repo_path"]
    render_planning_prompt(PROMPT_FOLLOWUP_NO_WORKTREE,
                           ctx.comment_vars.merge("CARD_INTERNAL_ID" => ctx.card_internal_id, "CARD_ID" => card_id),
                           brain_context: build_brain_context(
                             agent_name: ctx.agent_name, project_key: ctx.project_key,
                             comment_body: ctx.plain_text, source: :fizzy
                           ),
                           card_context: prefetch_card_context(card_number, repo_path: ctx.project_config["repo_path"],
                                                                            agent_name: ctx.agent_name),
                           agent_name: ctx.agent_name)
  else
    render_planning_prompt(PROMPT_FOLLOWUP_WORKTREE,
                           ctx.comment_vars.merge("CARD_NUMBER" => card_number, "CARD_ID" => card_id),
                           brain_context: build_brain_context(
                             agent_name: ctx.agent_name, card_number: card_number,
                             project_key: ctx.project_key, comment_body: ctx.plain_text, source: :fizzy
                           ),
                           card_context: prefetch_card_context(card_number, repo_path: work_dir, agent_name: ctx.agent_name),
                           agent_name: ctx.agent_name)
  end
end
