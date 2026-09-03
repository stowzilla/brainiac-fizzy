# frozen_string_literal: true

module Brainiac
  module Plugins
    module Fizzy
      # Fizzy-specific helper functions.
      # These were previously in lib/brainiac/helpers.rb in core.
      module Helpers
        class << self
          # Returns true if signature is valid (or no secret configured).
          # Returns false if signature verification fails.
          def verify_signature!(request, payload_body, board_key: nil)
            signature = request.env["HTTP_X_WEBHOOK_SIGNATURE"]
            return false unless signature

            secret = board_key ? Config.board_webhook_secret(board_key) : ENV.fetch("FIZZY_WEBHOOK_SECRET", nil)
            return false unless secret

            computed = OpenSSL::HMAC.hexdigest("sha256", secret, payload_body)
            Rack::Utils.secure_compare(signature, computed)
          end

          def fizzy_token_for(agent_name)
            agent_env_var(agent_name, "FIZZY_TOKEN")
          end

          def fizzy_env_for(agent_name)
            token = fizzy_token_for(agent_name) || fizzy_token_for(AI_AGENT_NAME)
            token ? { "FIZZY_TOKEN" => token } : {}
          end

          def default_fizzy_env
            fizzy_env_for(AI_AGENT_NAME)
          end

          # Resolve GitHub App token for an agent so gh CLI runs as their bot identity.
          # Uses brainiac-github's AppClient if available.
          def resolve_github_agent_env(agent_name, github_repo)
            return {} unless github_repo

            if defined?(Brainiac::Plugins::Github::AppClient)
              repo_owner = github_repo.split("/").first
              token = Brainiac::Plugins::Github::AppClient.installation_token_for(agent_name, repo_owner: repo_owner)
              return { "GH_TOKEN" => token } if token
            end
            {}
          rescue StandardError => e
            LOG.warn "[Fizzy] Could not resolve GitHub token for #{agent_name}: #{e.message}" if defined?(LOG)
            {}
          end

          def prefetch_card_context(card_number, repo_path:, agent_name: nil)
            env = fizzy_env_for(agent_name || AI_AGENT_NAME)
            card_details = fetch_card_details(card_number, repo_path: repo_path, env: env)
            card_comments = fetch_card_comments(card_number, repo_path: repo_path, env: env)

            context = ""
            context += "## Card Details\n#{card_details}\n\n" unless card_details.empty?
            context += "## Recent Comments\n#{card_comments}\n" unless card_comments.empty?
            context
          end

          # Normalize Fizzy tags from webhook hashes ({ "name" => "deploy" })
          # or API strings ("deploy") into a lowercase name list.
          def tag_names(tags)
            Array(tags).filter_map do |tag|
              name = tag.is_a?(Hash) ? (tag["name"] || tag[:name]) : tag
              normalized = name.to_s.downcase
              normalized unless normalized.empty?
            end
          end

          def card_has_tag?(tags, name)
            tag_names(tags).include?(name.to_s.downcase)
          end

          # Live tags from `fizzy card show`. Returns nil on failure so callers
          # can fall back to webhook payload tags. Fizzy has no tag-added webhook;
          # comment payloads may omit or stale-cache tags, so this is the source of truth.
          def fetch_card_tags(card_number, repo_path:, env: nil)
            return nil unless card_number && repo_path

            env ||= default_fizzy_env
            output = run_cmd("fizzy", "card", "show", card_number.to_s, chdir: repo_path, env: env)
            card = JSON.parse(output)["data"]
            return nil unless card

            Array(card["tags"])
          rescue StandardError => e
            LOG.warn "[Fizzy] Could not fetch tags for card ##{card_number}: #{e.message}" if defined?(LOG)
            nil
          end

          def fetch_card_details(card_number, repo_path:, env:)
            output = run_cmd("fizzy", "card", "show", card_number.to_s, chdir: repo_path, env: env)
            card = JSON.parse(output)["data"]
            return "" unless card

            parts = []
            parts << "**Title:** #{card["title"]}"
            parts << "**Body:**\n#{card.dig("body", "plain_text")}" if card.dig("body", "plain_text")
            parts.join("\n")
          rescue StandardError => e
            LOG.warn "[Fizzy] Could not fetch card ##{card_number}: #{e.message}" if defined?(LOG)
            ""
          end

          def fetch_card_comments(card_number, repo_path:, env:)
            output = run_cmd("fizzy", "comment", "list", "--card", card_number.to_s, "--all", chdir: repo_path, env: env)
            comments = JSON.parse(output)["data"] || []
            return "" if comments.empty?

            comments.last(15).map do |c|
              body = c.dig("body", "plain_text") || ""
              body = "#{body[0..500]}..." if body.length > 500
              "**#{c.dig("creator", "name")}** (#{c["id"]}):\n#{body}"
            end.join("\n\n---\n\n")
          rescue StandardError => e
            LOG.warn "[Fizzy] Could not fetch comments for card ##{card_number}: #{e.message}" if defined?(LOG)
            ""
          end

          # Lightweight recent comment context for intent classification.
          # Returns a simple "author: message" format (last 5 comments).
          def fetch_intent_context(card_number, repo_path:, agent_name: nil)
            env = fizzy_env_for(agent_name || AI_AGENT_NAME)
            output = run_cmd("fizzy", "comment", "list", "--card", card_number.to_s, "--all", chdir: repo_path, env: env)
            comments = JSON.parse(output)["data"] || []
            return nil if comments.empty?

            comments.last(5).map do |c|
              creator = c.dig("creator", "name") || "unknown"
              body = (c.dig("body", "plain_text") || "").lines.first(3).join.strip
              body = "#{body[0..200]}..." if body.length > 200
              "#{creator}: #{body}"
            end.join("\n")
          rescue StandardError => e
            LOG.warn "[Fizzy] Could not fetch intent context for card ##{card_number}: #{e.message}" if defined?(LOG)
            nil
          end

          def move_card_to_column(card_number, column_name, project_config:, agent_name: nil, board_key: nil)
            board_key ||= Config.board_key_for_project(project_config)
            column_id = Config.board_column_id(board_key, column_name) if board_key
            return unless column_id

            repo_path = project_config["repo_path"]
            env = fizzy_env_for(agent_name || AI_AGENT_NAME)
            run_cmd("fizzy", "card", "column", card_number.to_s, "--column", column_id, chdir: repo_path, env: env)
          end

          def append_fizzy_comment_footer(card_number, project_config:, agent_name: nil, since: nil)
            repo_path = project_config["repo_path"]
            env = fizzy_env_for(agent_name || AI_AGENT_NAME)

            output = run_cmd("fizzy", "comment", "list", "--card", card_number.to_s, "--all", chdir: repo_path, env: env)
            comments = JSON.parse(output)["data"] || []
            agent_display = agent_display_name(agent_name || AI_AGENT_NAME)

            # Find the most recent agent comment, scoped to this session if `since` is provided.
            # Subtracts 30s buffer from `since` to account for clock skew between local server and Fizzy API.
            agent_comments = comments.select { |c| c.dig("creator", "name")&.downcase == agent_display.downcase }
            if since
              buffered_since = since - 30
              agent_comments = agent_comments.select do |c|
                comment_time = c["created_at"] && Time.parse(c["created_at"])
                comment_time && comment_time > buffered_since
              end
            end

            last_agent_comment = agent_comments.last
            return false unless last_agent_comment

            # Append footer if applicable
            body = last_agent_comment.dig("body", "html") || ""
            unless footer_already_present?(body)
              branch = detect_branch_from_comment(body, card_number)
              if branch
                footer = build_comment_footer(branch, card_number, project_config)
                updated_body = body + footer
                run_cmd("fizzy", "comment", "update", last_agent_comment["id"], "--card", card_number.to_s,
                        "--body", updated_body, chdir: repo_path, env: env)
              end
            end

            true
          rescue StandardError => e
            LOG.warn "[Fizzy] Could not append footer to card ##{card_number}: #{e.message}" if defined?(LOG)
            false
          end

          def ensure_fizzy_yaml!(chdir, project_config)
            fizzy_yaml_dest = File.join(chdir, ".fizzy.yaml")
            return if File.exist?(fizzy_yaml_dest)

            fizzy_yaml_src = File.join(project_config["repo_path"], ".fizzy.yaml")
            return unless File.exist?(fizzy_yaml_src)

            FileUtils.cp(fizzy_yaml_src, fizzy_yaml_dest)
            LOG.info "[Fizzy] Copied .fizzy.yaml to #{chdir}" if defined?(LOG)
          end

          def scrub_invalid_attachments!(dir)
            attachments_dir = File.join(dir, ".fizzy-attachments")
            return unless Dir.exist?(attachments_dir)

            Dir.glob(File.join(attachments_dir, "*")).each do |file|
              next unless File.file?(file)
              next if File.size(file) > 100 # Keep files with real content

              File.delete(file)
            end
          end

          # Determines whether a card should run in planning mode.
          # Returns nil if planning is not active, or { card_id: <id> } if it is.
          # Planning mode is triggered by a "plan" or "planning" tag on the card.
          def detect_planning_mode(text:, tags:, card_internal_id:, card_number:)
            tag_names = (tags || []).map { |t| t.is_a?(Hash) ? t["name"] : t.to_s }.map(&:downcase)
            return nil unless tag_names.include?("plan") || tag_names.include?("planning")

            { card_id: card_number || card_internal_id }
          end

          # Look up a Fizzy card's work item info by its internal ID.
          # Returns a hash with top-level "number", "agent", "branch", "worktree", "project"
          # keys for backward compatibility with handler code, or nil if not found.
          def lookup_fizzy_card_info(card_internal_id)
            return nil unless card_internal_id

            result = find_work_item_by_card(card_internal_id)
            return nil unless result

            _work_item_id, info = result
            # Ensure "number" is at top level for fizzy handler compat
            info["number"] ||= info.dig("sources", "fizzy", "card_number")
            info
          end

          # Update or create a work item entry for a Fizzy card.
          # Accepts a hash of fields to merge into the existing entry.
          # Handles both new-format (wi-xxx keyed) and creates new entries properly.
          def update_fizzy_work_item(card_internal_id, updates)
            return unless card_internal_id

            map = load_work_item_map
            result = nil
            work_item_id = nil

            # Find existing entry by card internal ID
            map.each do |wid, info|
              next unless info.is_a?(Hash)

              fizzy_source = info.dig("sources", "fizzy")
              next unless fizzy_source && fizzy_source["card_internal_id"] == card_internal_id

              work_item_id = wid
              result = info
              break
            end

            card_number = updates.delete("number")

            if result
              result["sources"]["fizzy"]["card_number"] = card_number if card_number
              result.merge!(updates)
              map[work_item_id] = result
            else
              new_id = generate_work_item_id(branch: updates["branch"], card_number: card_number)
              map[new_id] = {
                "id" => new_id,
                "branch" => updates["branch"],
                "worktree" => updates["worktree"],
                "project" => updates["project"],
                "agent" => updates["agent"],
                "sources" => {
                  "fizzy" => {
                    "card_internal_id" => card_internal_id,
                    "card_number" => card_number
                  }.compact
                }
              }.compact.merge(updates.except("branch", "worktree", "project", "agent"))
            end

            save_work_item_map(map)
          end

          # Resolve a card number from an internal ID by querying the Fizzy API.
          # Searches card lists to find the matching card.
          def resolve_card_number(internal_id, repo_path:)
            env = default_fizzy_env
            base_cmd = %w[fizzy card list]
            ["--all", "--all --indexed-by closed"].each do |flags|
              cmd = base_cmd + flags.split
              output = run_cmd(*cmd, chdir: repo_path, env: env)
              data = JSON.parse(output)["data"] || []
              match = data.find { |c| c["id"] == internal_id }
              if match
                LOG.info "Resolved card number #{match["number"]} for internal_id #{internal_id}" if defined?(LOG)
                return match["number"]
              end
            rescue StandardError
              next
            end

            LOG.warn "Could not resolve card number for internal_id #{internal_id}" if defined?(LOG)
            nil
          end

          private

          def detect_branch_from_comment(body, card_number)
            # Try to find branch in comment body
            match = body.match(%r{<code>(fizzy-#{card_number}-[^<]+)</code>})
            return match[1] if match

            # Fall back to card map — check both new and old format
            map = load_work_item_map
            entry = map.values.find do |v|
              v.dig("sources", "fizzy", "card_number").to_s == card_number.to_s ||
                v["number"].to_s == card_number.to_s
            end
            entry&.dig("branch")
          end

          def detect_pr_url(branch, project_config)
            repo = project_config["github_repo"]
            return nil unless repo

            # Prefer the existing open PR for this branch. `pull/new/<branch>` only
            # opens the "create PR" page, which is wrong once a PR already exists.
            existing = existing_pr_url(branch, repo, project_config["repo_path"])
            return existing if existing

            "https://github.com/#{repo}/pull/new/#{branch}"
          end

          # Look up the URL of an already-open PR for `branch` via the gh CLI.
          # Returns nil if gh fails or no PR exists (caller falls back to new-PR link).
          def existing_pr_url(branch, repo, repo_path)
            output = run_cmd("gh", "pr", "view", branch, "--repo", repo, "--json", "url",
                             "--jq", ".url", chdir: repo_path)
            url = output.to_s.strip
            url.empty? ? nil : url
          rescue StandardError
            nil
          end

          # True if the comment body already carries a "Branch:" footer/label, in
          # either the footer format (`<em>Branch:`) or the agent-authored format
          # (`<strong>Branch:</strong>`). Prevents appending a duplicate footer.
          def footer_already_present?(body)
            body.include?("<em>Branch:") ||
              body.match?(%r{<strong>\s*Branch:\s*</strong>}i) ||
              body.match?(/(^|>)\s*Branch:\s*</)
          end

          # Build the "<em>Branch: <code>...</code> | PR | Env</em>" footer.
          # Includes the ephemeral env link when the card has an active env.
          def build_comment_footer(branch, card_number, project_config)
            pr_url = detect_pr_url(branch, project_config)
            env_url = detect_env_url(card_number)

            footer = "<p><em>Branch: <code>#{branch}</code>"
            footer += " | <a href=\"#{pr_url}\">PR</a>" if pr_url
            footer += " | <a href=\"#{env_url}\">Env</a>" if env_url
            footer += "</em></p>"
            footer
          end

          # URL of the ephemeral Belt environment for this card, if one is active.
          def detect_env_url(card_number)
            EnvUrl.for_card(card_number)
          end
        end
      end
    end
  end
end
