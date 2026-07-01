# frozen_string_literal: true

module Brainiac
  module Plugins
    module Fizzy
      # Fizzy-specific helper functions.
      # These were previously in lib/brainiac/helpers.rb in core.
      module Helpers
        class << self
          def verify_signature!(request, payload_body, board_key: nil)
            secret = board_key ? Config.board_webhook_secret(board_key) : ENV.fetch("FIZZY_WEBHOOK_SECRET", nil)
            return unless secret

            signature = request.env["HTTP_X_HUB_SIGNATURE_256"] || request.env["HTTP_X_FIZZY_SIGNATURE"]
            expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, payload_body)}"
            halt 401, { error: "Invalid signature" }.to_json unless signature && Rack::Utils.secure_compare(expected, signature)
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

          def prefetch_card_context(card_number, repo_path:, agent_name: nil)
            env = fizzy_env_for(agent_name || AI_AGENT_NAME)
            card_details = fetch_card_details(card_number, repo_path: repo_path, env: env)
            card_comments = fetch_card_comments(card_number, repo_path: repo_path, env: env)

            context = ""
            context += "## Card Details\n#{card_details}\n\n" unless card_details.empty?
            context += "## Recent Comments\n#{card_comments}\n" unless card_comments.empty?
            context
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
            output = run_cmd("fizzy", "comment", "list", "--card", card_number.to_s, chdir: repo_path, env: env)
            comments = JSON.parse(output)["data"] || []
            return "" if comments.empty?

            comments.last(15).map do |c|
              body = c.dig("body", "plain_text") || ""
              body = body[0..500] + "..." if body.length > 500
              "**#{c["creator_name"]}** (#{c["id"]}):\n#{body}"
            end.join("\n\n---\n\n")
          rescue StandardError => e
            LOG.warn "[Fizzy] Could not fetch comments for card ##{card_number}: #{e.message}" if defined?(LOG)
            ""
          end

          def move_card_to_column(card_number, column_name, project_config:, agent_name: nil)
            board_key = Config.board_key_for_project(project_config)
            column_id = Config.board_column_id(board_key, column_name) if board_key
            return unless column_id

            repo_path = project_config["repo_path"]
            env = fizzy_env_for(agent_name || AI_AGENT_NAME)
            run_cmd("fizzy", "card", "column", card_number.to_s, "--column", column_id, chdir: repo_path, env: env)
          end

          def append_fizzy_comment_footer(card_number, project_config:, agent_name: nil)
            repo_path = project_config["repo_path"]
            env = fizzy_env_for(agent_name || AI_AGENT_NAME)

            output = run_cmd("fizzy", "comment", "list", "--card", card_number.to_s, chdir: repo_path, env: env)
            comments = JSON.parse(output)["data"] || []
            agent_display = agent_display_name(agent_name || AI_AGENT_NAME)

            last_agent_comment = comments.reverse.find do |c|
              c["creator_name"]&.downcase == agent_display.downcase
            end
            return unless last_agent_comment

            # Check if footer already exists
            body = last_agent_comment.dig("body", "html") || ""
            return if body.include?("<em>Branch:")

            # Detect branch from comment content or card map
            branch = detect_branch_from_comment(body, card_number)
            return unless branch

            pr_url = detect_pr_url(branch, project_config)
            footer = "<p><em>Branch: <code>#{branch}</code>"
            footer += " | <a href=\"#{pr_url}\">PR</a>" if pr_url
            footer += "</em></p>"

            updated_body = body + footer
            run_cmd("fizzy", "comment", "update", last_agent_comment["id"], "--card", card_number.to_s,
                    "--body", updated_body, chdir: repo_path, env: env)
          rescue StandardError => e
            LOG.warn "[Fizzy] Could not append footer to card ##{card_number}: #{e.message}" if defined?(LOG)
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

          private

          def detect_branch_from_comment(body, card_number)
            # Try to find branch in comment body
            match = body.match(/<code>(fizzy-#{card_number}-[^<]+)<\/code>/)
            return match[1] if match

            # Fall back to card map
            map = load_card_map
            entry = map.values.find { |v| v["number"].to_s == card_number.to_s }
            entry&.dig("branch")
          end

          def detect_pr_url(branch, project_config)
            repo = project_config["github_repo"]
            return nil unless repo

            "https://github.com/#{repo}/pull/new/#{branch}"
          end
        end
      end
    end
  end
end
