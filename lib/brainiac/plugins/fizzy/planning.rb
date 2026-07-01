# frozen_string_literal: true

module Brainiac
  module Plugins
    module Fizzy
      # Planning mode — generates plans from agent sessions and creates Fizzy steps.
      module Planning
        PLANS_DIR = File.join(
          ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")),
          "plans"
        )

        class << self
          # Called from :agent_completed hook after session finishes.
          # Checks if a plan file was produced and creates Fizzy steps from it.
          def finalize_if_needed(prompt_file, agent_name, project_config)
            return unless prompt_file && File.exist?(prompt_file)

            prompt_content = File.read(prompt_file)
            card_id_match = prompt_content.match(/CARD_ID.*?(\d+|discord-[\w-]+)/)
            return unless card_id_match

            card_id = card_id_match[1]
            plan_file = File.join(PLANS_DIR, "card-#{card_id}-plan.md")
            return unless File.exist?(plan_file)

            LOG.info "[Fizzy:Planning] Plan file detected for card #{card_id}, finalizing..." if defined?(LOG)
            finalize_plan(card_id: card_id, agent_name: agent_name, project_config: project_config)
          end

          def finalize_plan(card_id:, agent_name:, project_config:)
            plan_file = File.join(PLANS_DIR, "card-#{card_id}-plan.md")
            return { success: false, error: "No plan file" } unless File.exist?(plan_file)

            plan_content = File.read(plan_file)
            tasks = extract_tasks(plan_content)
            return { success: false, error: "No tasks found in plan" } if tasks.empty?

            card_number = card_id.match?(/^\d+$/) ? card_id.to_i : nil
            return { success: false, error: "No card number" } unless card_number

            repo_path = project_config["repo_path"]
            env = Helpers.fizzy_env_for(agent_name || AI_AGENT_NAME)

            tasks.each do |task_title|
              run_cmd("fizzy", "step", "create", "--card", card_number.to_s, "--content", task_title,
                      chdir: repo_path, env: env)
            end

            LOG.info "[Fizzy:Planning] Created #{tasks.size} steps for card ##{card_number}" if defined?(LOG)
            { success: true, tasks: tasks }
          rescue StandardError => e
            LOG.error "[Fizzy:Planning] Failed to finalize plan: #{e.message}" if defined?(LOG)
            { success: false, error: e.message }
          end

          private

          def extract_tasks(plan_content)
            tasks = []
            plan_content.each_line do |line|
              if line.match?(/^###\s+Task\s+\d+/)
                title = line.sub(/^###\s+Task\s+\d+:\s*/, "").strip
                tasks << title unless title.empty?
              end
            end
            tasks
          end
        end
      end
    end
  end
end
