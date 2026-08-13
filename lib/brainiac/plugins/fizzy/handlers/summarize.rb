# frozen_string_literal: true

require "time"

module Brainiac
  module Plugins
    module Fizzy
      # Handles re-dispatch summarize sessions and fallback comment posting.
      # Extracted from Hooks to keep module length manageable.
      module Summarize
        class << self
          # Re-dispatch an agent to post a summary comment when it completed work
          # but didn't comment on the card. Fires async with a 60s timeout.
          # If this session also fails to comment, posts a minimal fallback.
          def dispatch_summarize_session(ctx)
            card_number = ctx[:card_number]
            agent_name = ctx[:agent_name]
            project_config = ctx[:project_config]
            repo_path = project_config["repo_path"]
            session_started_at = ctx[:source_context]&.dig(:dispatched_at)

            map = load_work_item_map
            work_item = find_work_item(map, card_number)

            branch = work_item&.dig("branch") || "unknown"
            card_title = work_item&.dig("title") || ctx[:source_context]&.dig(:card_title) || "untitled"
            worktree_path = work_item&.dig("worktree") || repo_path

            if defined?(LOG)
              LOG.info "[Fizzy] Agent #{agent_name} completed card ##{card_number} without commenting — " \
                       "dispatching summarize session"
            end

            pid, log_file = dispatch_summarize_agent(card_number, card_title, branch, agent_name,
                                                     project_config, worktree_path)
            register_session("card-#{card_number}-summarize", pid, log_file: log_file, agent_name: agent_name)

            monitor_summarize_session(pid, card_number, agent_name, branch, repo_path, session_started_at,
                                      project_config)
          rescue StandardError => e
            LOG.error "[Fizzy] Failed to dispatch summarize session for card ##{card_number}: #{e.message}" if defined?(LOG)
            post_fallback_comment(card_number, work_item&.dig("branch") || "unknown", agent_name, project_config)
          end

          # Check if the agent posted a comment on the card since a given time.
          # If no `since` is provided, checks for any agent comment (legacy behavior).
          # Subtracts a 30s buffer from `since` to account for clock skew between
          # the local server and the Fizzy API.
          CLOCK_SKEW_BUFFER = 30

          def agent_commented_on_card?(card_number, agent_name, repo_path:, since: nil)
            env = Helpers.fizzy_env_for(agent_name)
            output = run_cmd("fizzy", "comment", "list", "--card", card_number.to_s, chdir: repo_path, env: env)
            comments = JSON.parse(output)["data"] || []
            agent_display = agent_display_name(agent_name)

            agent_comments = comments.select { |c| c["creator_name"]&.downcase == agent_display.downcase }
            return agent_comments.any? unless since

            buffered_since = since - CLOCK_SKEW_BUFFER
            agent_comments.any? do |c|
              comment_time = c["created_at"] && Time.parse(c["created_at"])
              comment_time && comment_time > buffered_since
            end
          rescue StandardError
            false
          end

          # Post a minimal server-generated comment when all else fails.
          def post_fallback_comment(card_number, branch, agent_name, project_config)
            repo_path = project_config["repo_path"]
            env = Helpers.fizzy_env_for(agent_name)

            pr_url = Helpers.send(:detect_pr_url, branch, project_config)
            body = "<p>✅ Work completed on this card.</p>"
            body += "<p><a href=\"#{pr_url}\">View PR</a></p>" if pr_url
            body += "<p><strong>Branch:</strong> <code>#{branch}</code></p>"

            run_cmd("fizzy", "comment", "create", "--card", card_number.to_s, "--body", body,
                    chdir: repo_path, env: env)
            LOG.info "[Fizzy] Posted fallback comment on card ##{card_number}" if defined?(LOG)
          rescue StandardError => e
            LOG.error "[Fizzy] Failed to post fallback comment on card ##{card_number}: #{e.message}" if defined?(LOG)
          end

          private

          def find_work_item(map, card_number)
            map.values.find do |info|
              info.is_a?(Hash) &&
                (info.dig("sources", "fizzy", "card_number").to_s == card_number.to_s ||
                 info["number"].to_s == card_number.to_s)
            end
          end

          def dispatch_summarize_agent(card_number, card_title, branch, agent_name, project_config, worktree_path)
            prompt = render_prompt(Prompts::SUMMARIZE_WORK,
                                   { "CARD_NUMBER" => card_number, "CARD_TITLE" => card_title, "BRANCH" => branch },
                                   brain_context: "", agent_name: agent_name, channel: :fizzy,
                                   board_key: Config.board_key_for_project(project_config))

            run_agent(prompt,
                      project_config: project_config, chdir: worktree_path,
                      log_name: "summarize-#{card_number}", agent_name: agent_name,
                      source: :fizzy,
                      source_context: { card_number: card_number, skip_summarize_redispatch: true },
                      skip_column_move: true)
          end

          def monitor_summarize_session(pid, card_number, agent_name, branch, repo_path, session_started_at,
                                        project_config)
            Thread.new do
              wait_for_process_or_timeout(pid, timeout: 60)
              sleep 2 # Brief pause to let any comment propagate

              unless agent_commented_on_card?(card_number, agent_name, repo_path: repo_path, since: session_started_at)
                post_fallback_comment(card_number, branch, agent_name, project_config)
              end
            rescue Errno::ECHILD
              # Process already reaped by session manager — check for comment
              sleep 2
              unless agent_commented_on_card?(card_number, agent_name, repo_path: repo_path, since: session_started_at)
                post_fallback_comment(card_number, branch, agent_name, project_config)
              end
            rescue StandardError => e
              LOG.error "[Fizzy] Summarize monitor error for card ##{card_number}: #{e.message}" if defined?(LOG)
            end
          end

          def wait_for_process_or_timeout(pid, timeout: 60)
            deadline = Time.now + timeout
            loop do
              result = Process.waitpid2(pid, Process::WNOHANG)
              break if result

              if Time.now > deadline
                safe_kill(pid)
                break
              end
              sleep 1
            end
          end

          def safe_kill(pid)
            Process.kill("TERM", pid)
            Process.waitpid2(pid)
          rescue Errno::ESRCH, Errno::ECHILD
            # Process already gone
          end
        end
      end
    end
  end
end
