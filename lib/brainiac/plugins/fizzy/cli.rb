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

        PROJECTS_FILE = File.join(BRAINIAC_DIR, "projects.json")

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
            when "board"
              cmd_board(args)
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

          def cmd_board(args)
            sub = args.shift
            case sub
            when "setup", "add"
              board_setup
            when "list", "ls"
              board_list
            when "assign"
              board_assign(args)
            when "columns", "refresh"
              board_columns(args)
            else
              puts "Usage: brainiac fizzy board <setup|list|assign|columns>"
              puts ""
              puts "Commands:"
              puts "  setup                         Add a new board (interactive, fetches columns from Fizzy)"
              puts "  list                          List configured boards and their columns"
              puts "  assign <project> <board_key>  Assign a project to a board"
              puts "  columns <board_key>           Refresh columns for a board from Fizzy"
            end
          end

          def board_setup
            puts "Fizzy Board Setup"
            puts "================="
            puts ""

            # Fetch boards from Fizzy CLI
            boards_json = run_fizzy("board", "list", "--all", "--json")
            unless boards_json
              puts "Error: Could not fetch boards from Fizzy CLI."
              puts "  Ensure 'fizzy' is on your PATH and authenticated."
              puts "  Run: fizzy doctor"
              return
            end

            boards = JSON.parse(boards_json)["data"] || []
            if boards.empty?
              puts "No boards found in your Fizzy account."
              return
            end

            # Display boards for selection
            puts "Available boards:"
            boards.each_with_index do |board, i|
              puts "  #{i + 1}) #{board["name"]} (#{board["id"]})"
            end
            puts ""
            print "Select board number: "
            choice = $stdin.gets&.chomp&.to_i
            return puts("Cancelled.") unless choice && choice.positive? && choice <= boards.size

            board = boards[choice - 1]
            board_id = board["id"]
            board_name = board["name"]

            # Ask for a board key (used in fizzy.json and project config)
            suggested_key = board_name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_|_$/, "")
            print "Board key for config [#{suggested_key}]: "
            board_key = $stdin.gets&.chomp
            board_key = suggested_key if board_key.nil? || board_key.empty?

            # Fetch columns
            columns_json = run_fizzy("column", "list", "--board", board_id, "--json")
            columns = if columns_json
                        JSON.parse(columns_json)["data"] || []
                      else
                        []
                      end

            # Filter out pseudo columns (built-in) — user probably wants custom ones
            custom_columns = columns.reject { |c| c["pseudo"] }
            all_columns = columns

            puts ""
            puts "Columns for \"#{board_name}\":"
            if all_columns.empty?
              puts "  (no columns found)"
            else
              all_columns.each do |col|
                pseudo_tag = col["pseudo"] ? " [built-in]" : ""
                puts "  • #{col["name"]} (#{col["id"]})#{pseudo_tag}"
              end
            end

            # Let user name the columns they want tracked
            puts ""
            puts "Which columns should brainiac track? Enter config names for each."
            puts "(These map to column transitions like right_now, needs_review, uat, etc.)"
            puts "Leave blank to skip a column."
            puts ""

            column_map = {}
            custom_columns.each do |col|
              suggested = col["name"].downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_|_$/, "")
              print "  \"#{col["name"]}\" → config key [#{suggested}]: "
              key = $stdin.gets&.chomp
              key = suggested if key.nil? || key.empty?
              next if key == "-" || key == "skip"

              column_map[key] = col["id"]
            end

            # Ask for webhook secret
            puts ""
            print "Webhook secret (or blank to generate one): "
            secret = $stdin.gets&.chomp
            if secret.nil? || secret.empty?
              secret = Array.new(24) { (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a).sample }.join
              puts "  Generated: #{secret}"
            end

            # Write to fizzy.json
            config = load_fizzy_config
            config["boards"] ||= {}
            config["boards"][board_key] = {
              "board_id" => board_id,
              "webhook_secret" => secret,
              "columns" => column_map
            }
            save_fizzy_config(config)

            puts ""
            puts "✓ Board \"#{board_name}\" added as '#{board_key}' in #{FIZZY_CONFIG_FILE}"
            puts "  Columns: #{column_map.keys.join(", ")}" unless column_map.empty?
            puts ""
            puts "Next steps:"
            puts "  brainiac fizzy board assign <project-key> #{board_key}"
            puts "  Set up webhook in Fizzy pointing to: https://<your-ngrok>/fizzy/#{board_key}"
          end

          def board_list
            config = load_fizzy_config
            boards = config["boards"] || {}

            if boards.empty?
              puts "No boards configured."
              puts "Run 'brainiac fizzy board setup' to add one."
              return
            end

            # Load projects to show assignments
            projects = load_projects_config

            puts "Configured boards:"
            boards.each do |key, board_config|
              puts ""
              puts "  #{key}:"
              puts "    Board ID: #{board_config["board_id"]}"
              puts "    Webhook:  #{board_config["webhook_secret"] ? "configured" : "not set"}"

              columns = board_config["columns"] || {}
              if columns.any?
                puts "    Columns:"
                columns.each { |name, id| puts "      #{name}: #{id}" }
              else
                puts "    Columns:  (none configured)"
              end

              # Show which projects use this board
              assigned = projects.select { |_, cfg| cfg["fizzy_board"] == key }.keys
              puts "    Projects: #{assigned.any? ? assigned.join(", ") : "(none)"}"
            end
          end

          def board_assign(args)
            project_key = args.shift
            board_key = args.shift

            unless project_key && board_key
              puts "Usage: brainiac fizzy board assign <project-key> <board-key>"
              puts ""
              puts "Available boards:"
              config = load_fizzy_config
              (config["boards"] || {}).each_key { |k| puts "  #{k}" }
              puts ""
              puts "Available projects:"
              load_projects_config.each_key { |k| puts "  #{k}" }
              return
            end

            # Validate board exists
            config = load_fizzy_config
            unless config.dig("boards", board_key)
              puts "Error: Board '#{board_key}' not found in fizzy.json."
              puts "Available: #{(config["boards"] || {}).keys.join(", ")}"
              return
            end

            # Update projects.json
            projects = load_projects_config
            unless projects.key?(project_key)
              puts "Error: Project '#{project_key}' not found in projects.json."
              puts "Available: #{projects.keys.join(", ")}"
              return
            end

            projects[project_key]["fizzy_board"] = board_key
            save_projects_config(projects)

            puts "✓ Assigned project '#{project_key}' to board '#{board_key}'"
          end

          def board_columns(args)
            board_key = args.shift
            unless board_key
              puts "Usage: brainiac fizzy board columns <board-key>"
              puts ""
              puts "Fetches current columns from Fizzy and lets you update the config."
              return
            end

            config = load_fizzy_config
            board_config = config.dig("boards", board_key)
            unless board_config
              puts "Error: Board '#{board_key}' not found in fizzy.json."
              puts "Available: #{(config["boards"] || {}).keys.join(", ")}"
              return
            end

            board_id = board_config["board_id"]
            columns_json = run_fizzy("column", "list", "--board", board_id, "--json")
            unless columns_json
              puts "Error: Could not fetch columns from Fizzy."
              return
            end

            columns = JSON.parse(columns_json)["data"] || []
            custom_columns = columns.reject { |c| c["pseudo"] }
            existing_map = board_config["columns"] || {}

            puts "Columns for board '#{board_key}' (#{board_id}):"
            puts ""

            columns.each do |col|
              pseudo_tag = col["pseudo"] ? " [built-in]" : ""
              existing_key = existing_map.key(col["id"])
              mapped = existing_key ? " → #{existing_key}" : ""
              puts "  • #{col["name"]} (#{col["id"]})#{pseudo_tag}#{mapped}"
            end

            puts ""
            puts "Update column mappings? (Enter new config keys, blank to keep, '-' to remove)"
            puts ""

            new_map = {}
            custom_columns.each do |col|
              existing_key = existing_map.key(col["id"])
              suggested = existing_key || col["name"].downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_|_$/, "")
              print "  \"#{col["name"]}\" → [#{suggested}]: "
              key = $stdin.gets&.chomp
              key = suggested if key.nil? || key.empty?
              next if key == "-" || key == "skip"

              new_map[key] = col["id"]
            end

            config["boards"][board_key]["columns"] = new_map
            save_fizzy_config(config)

            puts ""
            puts "✓ Updated columns for '#{board_key}': #{new_map.keys.join(", ")}"
          end

          def load_fizzy_config
            if File.exist?(FIZZY_CONFIG_FILE)
              JSON.parse(File.read(FIZZY_CONFIG_FILE))
            else
              { "boards" => {}, "authorized_users" => [] }
            end
          rescue JSON::ParserError
            { "boards" => {}, "authorized_users" => [] }
          end

          def save_fizzy_config(config)
            File.write(FIZZY_CONFIG_FILE, JSON.pretty_generate(config))
          end

          def load_projects_config
            if File.exist?(PROJECTS_FILE)
              JSON.parse(File.read(PROJECTS_FILE))
            else
              {}
            end
          rescue JSON::ParserError
            {}
          end

          def save_projects_config(projects)
            File.write(PROJECTS_FILE, JSON.pretty_generate(projects))
          end

          def run_fizzy(*args)
            require "open3"
            output, status = Open3.capture2("fizzy", *args)
            status.success? ? output : nil
          rescue Errno::ENOENT
            nil
          end

          def print_help
            puts <<~HELP
              Usage: brainiac fizzy <command>

              Commands:
                config                              Show Fizzy config
                status                              Check Fizzy status via server API
                setup                               Show setup guide
                board setup                         Add a new board (interactive, fetches columns from Fizzy)
                board list                          List configured boards and their columns
                board assign <project> <board_key>  Assign a project to a board
                board columns <board_key>           Refresh columns for a board from Fizzy

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

      # Called by brainiac CLI after `agent create` — prompts for Fizzy user ID.
      def self.on_agent_created(agent_key, entry)
        return unless $stdin.tty?

        config_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "fizzy.json")
        return unless File.exist?(config_file)

        display_name = entry["display_name"] || agent_key.capitalize
        puts ""
        puts "  [Fizzy] Configure Fizzy for #{display_name}?"
        print "  Fizzy user ID (or blank to skip): "
        user_id = $stdin.gets&.chomp
        return if user_id.nil? || user_id.empty?

        config = JSON.parse(File.read(config_file))
        config["authorized_users"] ||= []

        # Don't add if already present
        existing = config["authorized_users"].find { |u| u["id"] == user_id || u["name"]&.downcase == display_name.downcase }
        if existing
          puts "  ✓ #{display_name} already in authorized_users (id: #{existing["id"]})"
          return
        end

        config["authorized_users"] << { "id" => user_id, "name" => display_name, "human" => false }
        File.write(config_file, JSON.pretty_generate(config))
        puts "  ✓ Added #{display_name} (#{user_id}) to fizzy.json authorized_users"
      rescue JSON::ParserError => e
        puts "  ⚠ Could not update fizzy.json: #{e.message}"
      end

      # Called by brainiac CLI after `agent remove` — removes from Fizzy authorized_users.
      def self.on_agent_removed(agent_key, display_name)
        config_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "fizzy.json")
        return unless File.exist?(config_file)

        config = JSON.parse(File.read(config_file))
        users = config["authorized_users"]
        return unless users

        original_size = users.size
        users.reject! { |u| u["name"]&.downcase == display_name.downcase || u["name"]&.downcase == agent_key }
        return if users.size == original_size

        File.write(config_file, JSON.pretty_generate(config))
        puts "  [Fizzy] Removed #{display_name} from fizzy.json authorized_users"
      rescue JSON::ParserError
        nil
      end
    end
  end
end
