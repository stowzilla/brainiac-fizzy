# frozen_string_literal: true

require "json"

module Brainiac
  module Plugins
    module Fizzy
      # CLI subcommands for brainiac-fizzy plugin.
      #
      # Invoked when a user runs `brainiac fizzy <command>`.
      module Cli
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        FIZZY_CONFIG_FILE = File.join(BRAINIAC_DIR, "fizzy.json")

        class << self
          def run(args)
            command = args.shift

            case command
            when "config"
              cmd_config
            when "status"
              cmd_status
            when "setup"
              cmd_setup
            else
              print_help
            end
          end

          private

          def cmd_config
            if File.exist?(FIZZY_CONFIG_FILE)
              puts File.read(FIZZY_CONFIG_FILE)
            else
              puts "No Fizzy config found at #{FIZZY_CONFIG_FILE}"
              puts "Run 'brainiac fizzy setup' to get started."
            end
          end

          def cmd_status
            server_url = detect_server_url
            begin
              uri = URI("#{server_url}/api/fizzy")
              response = Net::HTTP.get_response(uri)
              data = JSON.parse(response.body)
              puts "Fizzy: #{data["enabled"] ? "enabled" : "disabled"}"
              puts "Boards: #{(data["boards"] || []).join(", ")}" if data["boards"]
              puts "Authorized users: #{data["authorized_users"]}" if data["authorized_users"]
            rescue StandardError => e
              puts "Could not reach server at #{server_url}: #{e.message}"
              puts "Is the server running? Check with: brainiac status"
            end
          end

          def cmd_setup
            puts "Fizzy Setup"
            puts "==========="
            puts ""

            if File.exist?(FIZZY_CONFIG_FILE)
              config = JSON.parse(File.read(FIZZY_CONFIG_FILE))
              boards = config["boards"] || {}
              users = config["authorized_users"] || []

              if boards.any?
                puts "✓ #{boards.size} board(s) configured: #{boards.keys.join(", ")}"
              else
                puts "⚠ No boards configured."
                puts "  Edit #{FIZZY_CONFIG_FILE} to add board config."
              end
              puts ""

              if users.any?
                puts "✓ #{users.size} authorized user(s)"
              else
                puts "⚠ No authorized users configured."
              end
            else
              puts "⚠ No fizzy.json found."
              puts "  Create #{FIZZY_CONFIG_FILE} with your board config."
              puts ""
              puts "  Minimum config:"
              puts "  {"
              puts '    "authorized_users": [{ "id": "user-id", "name": "You", "human": true }],'
              puts '    "boards": {'
              puts '      "development": {'
              puts '        "board_id": "your-board-id",'
              puts '        "webhook_secret": "your-secret",'
              puts '        "columns": { "right_now": "col-id", "needs_review": "col-id" }'
              puts "      }"
              puts "    }"
              puts "  }"
            end
            puts ""
            puts "Webhook URL: https://<your-ngrok>.ngrok-free.app/fizzy/<board-key>"
          end

          def print_help
            puts <<~HELP
              Usage: brainiac fizzy <command>

              Commands:
                config                              Show Fizzy config
                status                              Check Fizzy status via server API
                setup                               Show setup guide

              Fizzy handles card assignment, comments, @mentions, cross-agent reviews,
              duplicate detection, and planning mode via webhooks.

              Webhook URL: https://<your-ngrok>/fizzy/<board-key>
              Config file: #{FIZZY_CONFIG_FILE}
            HELP
          end

          def detect_server_url
            config_file = File.join(BRAINIAC_DIR, "brainiac.json")
            if File.exist?(config_file)
              config = JSON.parse(File.read(config_file))
              config["server_url"] || "http://localhost:4567"
            else
              "http://localhost:4567"
            end
          rescue JSON::ParserError
            "http://localhost:4567"
          end
        end
      end

      # Plugin CLI entry point — called by brainiac core's plugin delegation.
      def self.cli(args)
        Cli.run(args)
      end

      # Subcommand names for bash completion.
      def self.completions
        %w[config status setup]
      end
    end
  end
end
