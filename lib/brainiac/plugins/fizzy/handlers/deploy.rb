# frozen_string_literal: true

# Fizzy deploy comment handler.
#
# When a comment is just "dev02" (or any dev\d+), deploy the card's
# worktree to that environment. No agent dispatch — reactions only.

def handle_deploy_comment(eventable, env_key, card_internal_id)
  comment_id = eventable["id"]
  card_info = lookup_fizzy_card_info(card_internal_id)

  # Validate environment exists
  deploy_config = DEPLOYMENTS_CONFIG["environments"] || {}
  unless deploy_config.key?(env_key)
    LOG.warn "[Deploy] Unknown environment: #{env_key}"
    return [200, { status: "ignored", reason: "unknown environment" }.to_json]
  end

  # Check environment ownership
  env_owner = deploy_config[env_key]["owner"]
  unless env_owner && env_owner.downcase == AI_AGENT_NAME.downcase
    LOG.info "[Deploy] Skipping #{env_key} — owner is #{env_owner.inspect}, this machine is #{AI_AGENT_NAME}"
    return [200, { status: "ignored", reason: env_owner ? "owned by #{env_owner}" : "no owner configured" }.to_json]
  end

  worktree = card_info&.dig("worktree")
  card_number = card_info&.dig("number")

  # If worktree doesn't exist locally, try to clone the branch from origin
  if worktree.nil? || !File.directory?(worktree)
    result = clone_branch_for_deploy(eventable, card_internal_id, card_info)
    unless result
      LOG.warn "[Deploy] Could not resolve or clone branch for card #{card_internal_id}"
      return [200, { status: "ignored", reason: "no worktree and could not clone branch" }.to_json]
    end
    worktree = result[:worktree]
    card_number = result[:card_number]
  end

  deploy_script = File.join(worktree, "scripts", "deploy.sh")
  unless File.exist?(deploy_script)
    LOG.warn "[Deploy] No deploy script at #{deploy_script}"
    return [200, { status: "ignored", reason: "no deploy script" }.to_json]
  end

  LOG.info "[Deploy] Deploying card ##{card_number} worktree to #{env_key}"
  mark_deploying(env_key, worktree_path: worktree)

  Thread.new do
    react_to_deploy(card_number, comment_id, worktree, "🚀")
    run_deploy(env_key, card_number, comment_id, worktree)
  rescue StandardError => e
    LOG.error "[Deploy] Error deploying card ##{card_number} to #{env_key}: #{e.message}"
    react_to_deploy(card_number, comment_id, worktree, "❌")
  end

  [200, { status: "deploying", card: card_number, env: env_key }.to_json]
end

def react_to_deploy(card_number, comment_id, worktree, emoji)
  run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s,
          "--comment", comment_id.to_s, "--content", emoji,
          chdir: worktree, env: default_fizzy_env)
rescue StandardError => e
  LOG.warn "[Deploy] Could not add reaction #{emoji}: #{e.message}"
end

def run_deploy(env_key, card_number, comment_id, worktree)
  deploy_env = {}
  aws_profile = DEPLOYMENTS_CONFIG.dig("environments", env_key, "aws_profile")
  deploy_env["AWS_PROFILE"] = aws_profile if aws_profile

  stdout, stderr, status = Open3.capture3(deploy_env, "./scripts/deploy.sh", env_key, chdir: worktree)

  if !status.success? && terraform_lock_error?(stdout, stderr)
    stdout, stderr, status = retry_deploy_with_init(deploy_env, env_key, card_number, worktree)
  end

  if status.success?
    LOG.info "[Deploy] Successfully deployed card ##{card_number} to #{env_key}"
    react_to_deploy(card_number, comment_id, worktree, "✅")
    deploy_to_environment(env_key, worktree_path: worktree, deployed_by: "fizzy-comment")
  else
    LOG.error "[Deploy] Failed deploying card ##{card_number} to #{env_key}: #{stderr}"
    react_to_deploy(card_number, comment_id, worktree, "❌")
    record_deploy_failure(env_key, worktree_path: worktree, stdout: stdout, stderr: stderr)
  end
end

def retry_deploy_with_init(deploy_env, env_key, card_number, worktree)
  LOG.info "[Deploy] Terraform lock file mismatch for card ##{card_number} — retrying with init -upgrade"
  infra_dir = File.join(worktree, "infrastructure", env_key)
  lock_file = File.join(infra_dir, ".terraform.lock.hcl")
  FileUtils.rm_f(lock_file)
  Open3.capture3(deploy_env, "terraform", "init", "-upgrade", chdir: infra_dir) if File.directory?(infra_dir)
  Open3.capture3(deploy_env, "./scripts/deploy.sh", env_key, chdir: worktree)
end

# Clone a remote branch locally for deploy when the worktree doesn't exist on this machine.
# Returns { worktree:, card_number: } on success, nil on failure.
def clone_branch_for_deploy(eventable, card_internal_id, card_info)
  card_tags = eventable.dig("card", "tags") || []
  project_result = identify_project_by_tags(card_tags)
  unless project_result
    LOG.warn "[Deploy] Cannot identify project for card #{card_internal_id}"
    return nil
  end
  project_key, project_config = project_result
  repo_path = project_config["repo_path"]

  card_number = card_info&.dig("number")
  card_number ||= resolve_card_number(card_internal_id, repo_path: repo_path)
  unless card_number
    LOG.warn "[Deploy] Cannot resolve card number for #{card_internal_id}"
    return nil
  end

  debounced_repo_fetch(repo_path)
  branches = run_cmd("git", "branch", "-r", "--list", "origin/fizzy-#{card_number}-*", chdir: repo_path).strip
  branch = branches.lines.map(&:strip).first&.sub("origin/", "")
  unless branch
    LOG.warn "[Deploy] No remote branch matching fizzy-#{card_number}-* found"
    return nil
  end

  worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{branch}")

  unless File.directory?(worktree_path)
    branch_exists_locally = system("git", "rev-parse", "--verify", branch, chdir: repo_path, out: File::NULL, err: File::NULL)
    if branch_exists_locally
      run_cmd("git", "worktree", "add", worktree_path, branch, chdir: repo_path)
    else
      run_cmd("git", "worktree", "add", "--track", "-b", branch, worktree_path, "origin/#{branch}", chdir: repo_path)
    end

    trust_version_manager(worktree_path, chdir: worktree_path)
    apply_worktree_includes(repo_path, worktree_path)
    run_project_hook(repo_path, "worktree-setup", extra_env: { "WORKTREE_PATH" => worktree_path })
  end

  # Update card map
  update_fizzy_work_item(card_internal_id,
                         "number" => card_number, "branch" => branch,
                         "worktree" => worktree_path, "project" => project_key)

  LOG.info "[Deploy] Cloned branch #{branch} into worktree #{worktree_path} for card ##{card_number}"
  { worktree: worktree_path, card_number: card_number }
rescue StandardError => e
  LOG.error "[Deploy] Failed to clone branch for card #{card_internal_id}: #{e.message}"
  nil
end
