# frozen_string_literal: true

module Brainiac
  module Plugins
    module Fizzy
      # Fizzy configuration — loads ~/.brainiac/fizzy.json.
      # Provides board config, webhook secrets, authorized users, and column IDs.
      module Config
        FIZZY_CONFIG_FILE = File.join(
          ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")),
          "fizzy.json"
        )

        @config = {}
        @boards = {}
        @authorized_user_ids = []

        class << self
          attr_reader :config, :boards, :authorized_user_ids

          def load!
            @config = if File.exist?(FIZZY_CONFIG_FILE)
                        JSON.parse(File.read(FIZZY_CONFIG_FILE))
                      else
                        {}
                      end
            @boards = @config["boards"] || {}
            @authorized_user_ids = (@config["authorized_users"] || []).map { |u| u["id"] }
          rescue JSON::ParserError => e
            LOG.error "[Fizzy] Failed to parse fizzy.json: #{e.message}" if defined?(LOG)
            @config = {}
            @boards = {}
            @authorized_user_ids = []
          end

          def reload!
            load!
          end

          def current
            @config
          end

          def board_config(board_key)
            @boards[board_key.to_s]
          end

          def board_webhook_secret(board_key)
            config = board_config(board_key)
            config&.dig("webhook_secret") || ENV.fetch("FIZZY_WEBHOOK_SECRET", nil)
          end

          def board_column_id(board_key, column_name)
            config = board_config(board_key)
            config&.dig("columns", column_name.to_s)
          end

          def board_key_for_id(board_id)
            @boards.each do |key, config|
              return key if config["board_id"] == board_id
            end
            nil
          end

          def board_key_for_project(project_config)
            fizzy_yaml = File.join(project_config["repo_path"], ".fizzy.yaml")
            return nil unless File.exist?(fizzy_yaml)

            require "yaml"
            data = YAML.safe_load_file(fizzy_yaml)
            board_id = data["board"]
            board_key_for_id(board_id)
          rescue StandardError => e
            LOG.warn "[Fizzy] Could not read .fizzy.yaml: #{e.message}" if defined?(LOG)
            nil
          end

          def authorized?(payload)
            creator_id = payload.dig("creator", "id")
            @authorized_user_ids.include?(creator_id)
          end

          def human_mentioned?(user_id)
            user = (@config["authorized_users"] || []).find { |u| u["id"] == user_id }
            user && user["human"]
          end

          def identify_project_by_tags(tags)
            tag_names = tags.map { |t| t.is_a?(Hash) ? t["name"] : t.to_s }.map(&:downcase)

            PROJECTS.each do |key, config|
              project_tags = (config["fizzy_tags"] || []).map(&:downcase)
              return [key, config] if (tag_names & project_tags).any?
            end

            # Fall back to default project
            default_key = default_project_key
            default_key ? [default_key, PROJECTS[default_key]] : nil
          end
        end
      end
    end
  end
end
