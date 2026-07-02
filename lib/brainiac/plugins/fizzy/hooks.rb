# frozen_string_literal: true

module Brainiac
  module Plugins
    module Fizzy
      # Registers all Fizzy lifecycle hooks with the core event system.
      module Hooks
        class << self
          def register_all!
            register_agent_completed
            register_agent_crashed
            register_pre_dispatch
            register_brain_context
            register_pr_merged
            register_pr_review_received
            register_pr_synchronized
            register_production_deployed
            register_create_work_item
            register_server_started
            register_detect_cli_provider
            register_detect_effort
          end

          private

          # After an agent session completes — move card to needs_review, append footer
          def register_agent_completed
            Brainiac.on(:agent_completed) do |ctx|
              next unless ctx[:source] == :fizzy

              card_number = ctx[:card_number]
              next unless card_number && ctx[:exit_status]&.zero? && !ctx[:signaled]

              unless ctx[:skip_column_move] || card_merged?(card_number)
                Helpers.move_card_to_column(card_number, "needs_review",
                                           project_config: ctx[:project_config],
                                           agent_name: ctx[:agent_name])
                record_self_move(card_number)
              end

              Helpers.append_fizzy_comment_footer(card_number,
                                                 project_config: ctx[:project_config],
                                                 agent_name: ctx[:agent_name])

              # Planning mode finalization
              Planning.finalize_if_needed(ctx[:prompt_file], ctx[:agent_name], ctx[:project_config])
            end
          end

          # Agent crashed — post crash comment on Fizzy card
          def register_agent_crashed
            Brainiac.on(:agent_crashed) do |ctx|
              next unless ctx[:source] == :fizzy

              card_number = ctx[:source_context]&.dig(:card_number)
              next unless card_number

              repo_path = ctx[:project_config]&.dig("repo_path") || Dir.pwd
              snippet = ctx[:snippet]
              body = "<p>💥 <strong>#{ctx[:agent_name]} crashed</strong> (exit code #{ctx[:exit_status]})</p>" \
                     "<p>Log: <code>#{ctx[:log_file]}</code></p>"
              if snippet
                escaped = snippet[-1500..].to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
                body += "<pre>#{escaped}</pre>"
              end

              env = Helpers.fizzy_env_for(ctx[:agent_name])
              run_cmd("fizzy", "comment", "create", "--card", card_number.to_s, "--body", body,
                      chdir: repo_path, env: env)
              LOG.info "[Fizzy] Posted crash comment on card ##{card_number}" if defined?(LOG)

              :fizzy # Signal that we handled this source
            rescue StandardError => e
              LOG.error "[Fizzy] Failed to post crash comment: #{e.message}" if defined?(LOG)
              nil
            end
          end

          # Before agent dispatch — copy .fizzy.yaml and clean attachments
          def register_pre_dispatch
            Brainiac.on(:pre_dispatch) do |ctx|
              Helpers.ensure_fizzy_yaml!(ctx[:chdir], ctx[:project_config])
              Thread.new { Helpers.scrub_invalid_attachments!(ctx[:chdir]) }
            end
          end

          # Brain context building — inject fizzy CLI knowledge when source is fizzy
          def register_brain_context
            Brainiac.on(:build_brain_context) do |ctx|
              queries = []
              if ctx[:source] == :fizzy
                queries << "fizzy CLI commands"
              elsif [ctx[:card_title], ctx[:comment_body]].any? { |s| s&.match?(/fizzy/i) }
                queries << "fizzy CLI commands"
              end
              queries
            end
          end

          # PR merged — post comment on Fizzy card, move to UAT, dispatch UAT agent
          def register_pr_merged
            Brainiac.on(:pr_merged) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              card_info = ctx[:card_info]
              card_agent = card_info["agent"]
              env = Helpers.fizzy_env_for(card_agent)
              repo_path = ctx[:repo_path]

              # Post PR link comment
              pr_url = ctx[:pr_url]
              pr_title = ctx[:pr_title]
              branch = ctx[:branch]
              comment_body = "<p>PR merged into main: <a href=\"#{pr_url}\">#{pr_title}</a></p>" \
                             "<p>Branch: <code>#{branch}</code></p>"
              run_cmd("fizzy", "comment", "create", "--card", card_number.to_s, "--body", comment_body,
                      chdir: repo_path, env: env)

              # Move card to UAT
              Helpers.move_card_to_column(card_number, "uat",
                                         project_config: ctx[:project_config],
                                         agent_name: card_agent)
              record_self_move(card_number)

              # Clear deployment tracking
              clear_deployment_for_card(card_number) if respond_to?(:clear_deployment_for_card)

              # Dispatch UAT agent
              dispatch_fizzy_uat_agent(ctx)
            rescue StandardError => e
              LOG.error "[Fizzy] Error in pr_merged hook: #{e.message}" if defined?(LOG)
            end
          end

          # PR review received — post status comment on card
          def register_pr_review_received
            Brainiac.on(:pr_review_received) do |ctx|
              card_number = ctx[:card_number]
              next unless card_number

              Thread.new do
                env = Helpers.fizzy_env_for(ctx[:agent_name])
                status_comment = "<p>🔄 Code review received from @#{ctx[:reviewer]}. Updates in progress...</p>"
                run_cmd("fizzy", "comment", "create", "--card", card_number.to_s, "--body", status_comment,
                        chdir: ctx[:repo_path], env: env)
              rescue StandardError => e
                LOG.warn "[Fizzy] Could not post review status: #{e.message}" if defined?(LOG)
              end
            end
          end

          # Production deployed — close UAT cards
          def register_production_deployed
            Brainiac.on(:production_deployed) do |ctx|
              project_config = ctx[:project_config]
              repo_path = project_config["repo_path"]
              board_key = Config.board_key_for_project(project_config)
              next [] unless board_key

              uat_col = Config.board_column_id(board_key, "uat")
              next [] unless uat_col

              env = Helpers.default_fizzy_env
              output = run_cmd("fizzy", "card", "list", "--column", uat_col, "--all",
                               chdir: repo_path, env: env)
              card_list = JSON.parse(output)["data"] || []
              next [] if card_list.empty?

              closed = close_uat_cards(card_list, repo_path)
              closed
            rescue StandardError => e
              LOG.error "[Fizzy] Error closing UAT cards: #{e.message}" if defined?(LOG)
              []
            end
          end

          # Create work item (from Zoho triage) — create a Fizzy card
          def register_create_work_item
            Brainiac.on(:create_work_item) do |ctx|
              board_id = ctx[:board_id]
              title = ctx[:title]
              description = ctx[:description]
              tags = ctx[:tags] || []
              assign_to = ctx[:assign_to]

              # Resolve tag IDs
              agent_env = agent_env_for("Threepio")
              spawn_env = agent_env.empty? ? {} : agent_env
              tag_ids = resolve_tag_ids(tags, spawn_env)

              cmd = ["fizzy", "card", "create", "--board", board_id, "--title", title, "--description", description]
              cmd.push("--tag-ids", tag_ids.join(",")) unless tag_ids.empty?

              output, status = Open3.capture2e(spawn_env, *cmd)
              next nil unless status.success?

              card_data = JSON.parse(output)
              card_number = card_data.dig("data", "number")

              # Assign if requested
              if card_number && assign_to
                assign_card(card_number, assign_to, spawn_env)
              end

              { number: card_number, url: card_data.dig("data", "url"), title: title }
            rescue StandardError => e
              LOG.error "[Fizzy] Failed to create card: #{e.message}" if defined?(LOG)
              nil
            end
          end

          # --- Private helpers ---

          def dispatch_fizzy_uat_agent(ctx)
            card_number = ctx[:card_number]
            card_info = ctx[:card_info]
            project_config = ctx[:project_config]
            project_key = ctx[:project_key]
            repo_path = ctx[:repo_path]

            agent_name = card_info["agent"] || agent_name_for(project_config)
            card_title = card_info["title"] || ctx[:pr_title]

            prompt = render_prompt(Prompts::UAT_TESTING,
                                   { "CARD_NUMBER" => card_number, "CARD_TITLE" => card_title,
                                     "PR_NUMBER" => ctx[:pull_request]["number"].to_s },
                                   brain_context: build_brain_context(agent_name: agent_name, card_number: card_number,
                                                                      card_title: card_title, project_key: project_key),
                                   agent_name: agent_name, channel: :fizzy,
                                   board_key: Config.board_key_for_project(project_config))

            pid, log_file = run_agent(prompt, project_config: project_config, chdir: repo_path,
                                      log_name: "uat-#{card_number}", agent_name: agent_name,
                                      source: :fizzy, source_context: { card_number: card_number }, skip_column_move: true)
            register_session("card-#{card_number}", pid, log_file: log_file, agent_name: agent_name)
            LOG.info "[Fizzy] Dispatched #{agent_name} for UAT on card ##{card_number}" if defined?(LOG)
          rescue StandardError => e
            LOG.error "[Fizzy] Failed to dispatch UAT agent: #{e.message}" if defined?(LOG)
          end

          def close_uat_cards(card_list, repo_path)
            closed = []
            map = load_card_map

            card_list.each do |card|
              card_number = card["number"]
              next unless card_number

              map_entry = map.values.find { |info| info["number"] == card_number }
              agent_name = map_entry["agent"] if map_entry
              env = Helpers.fizzy_env_for(agent_name || AI_AGENT_NAME)

              run_cmd("fizzy", "comment", "create", "--card", card_number.to_s,
                      "--body", "<p>✅ Deployed to production. Closing card.</p>", chdir: repo_path, env: env)
              run_cmd("fizzy", "card", "close", card_number.to_s, chdir: repo_path, env: env)

              cleanup_card_worktrees(card_number, repo_path: repo_path,
                                    primary_worktree: map_entry&.dig("worktree"), primary_branch: map_entry&.dig("branch"))

              if map_entry
                internal_id = map.key(map_entry)
                map.delete(internal_id)
              end

              closed << { number: card_number, url: card["url"], title: card["title"] }
            end

            save_card_map(map) if closed.any?
            closed
          end

          def resolve_tag_ids(tag_names, spawn_env)
            output, status = Open3.capture2e(spawn_env, "fizzy", "tag", "list", "--all")
            return [] unless status.success?

            all_tags = JSON.parse(output)["data"] || []
            tag_names.filter_map do |name|
              tag = all_tags.find { |t| t["title"].downcase == name.downcase }
              tag&.dig("id")
            end
          rescue StandardError
            []
          end

          def assign_card(card_number, agent_name, spawn_env)
            users = Config.current["authorized_users"] || []
            user = users.find { |u| u["name"]&.downcase == agent_name.downcase }
            return unless user

            Open3.capture2e(spawn_env, "fizzy", "card", "assign", card_number.to_s, "--user", user["id"])
          end

          # Server started — run card index backfill
          def register_server_started
            Brainiac.on(:server_started) do
              if defined?(CARD_INDEX)
                LOG.info "[Fizzy:CardIndex] Starting background backfill..."
                CARD_INDEX.backfill
              end
            end
          end

          # Detect CLI provider from Fizzy card tags (e.g., cli-grok tag)
          def register_detect_cli_provider
            Brainiac.on(:detect_cli_provider) do |ctx|
              tags = ctx[:tags] || []
              result = nil
              tags.each do |tag|
                name = (tag.is_a?(Hash) ? tag["name"] : tag).to_s.downcase
                if name.start_with?("cli-")
                  result = name.sub("cli-", "")
                  break
                end
              end
              result
            end
          end

          # Detect effort level from Fizzy card tags (e.g., effort-high tag)
          def register_detect_effort
            Brainiac.on(:detect_effort) do |ctx|
              tags = ctx[:tags] || []
              allowed = ctx[:allowed] || []
              result = nil
              tags.each do |tag|
                name = (tag.is_a?(Hash) ? tag["name"] : tag).to_s.downcase
                if name.start_with?("effort-")
                  level = name.sub("effort-", "")
                  if allowed.include?(level)
                    result = level
                    break
                  end
                end
              end
              result
            end
          end

          # PR synchronized — handle auto-deploy if card is on a deploy env
          def register_pr_synchronized
            Brainiac.on(:pr_synchronized) do |ctx|
              next unless defined?(DEPLOYMENTS_CONFIG)

              card_number = ctx[:card_number]
              worktree = ctx[:worktree]
              next unless worktree && File.directory?(worktree)

              state = load_deployment_state
              config = DEPLOYMENTS_CONFIG["environments"] || {}
              env_key = state.find { |_k, v| v["card_number"] == card_number && v["status"] == "occupied" }&.first
              next unless env_key

              env_owner = config.dig(env_key, "owner")
              next unless env_owner && env_owner.downcase == AI_AGENT_NAME.downcase
              next if on_deploy_cooldown?(env_key)

              touch_deploy_cooldown(env_key)
              system("git", "pull", "--ff-only", chdir: worktree)

              deploy_script = File.join(worktree, "scripts", "deploy.sh")
              next unless File.exist?(deploy_script)

              LOG.info "[Fizzy:Deploy] Auto-deploying card ##{card_number} to #{env_key} (PR updated)"
              mark_deploying(env_key, worktree_path: worktree)
              run_pr_sync_deploy(env_key, card_number, worktree, config)
              true
            rescue StandardError => e
              LOG.error "[Fizzy:Deploy] PR sync deploy error: #{e.message}" if defined?(LOG)
              nil
            end
          end
        end
      end
    end
  end
end
