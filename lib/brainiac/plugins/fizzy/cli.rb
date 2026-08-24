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
            when "webhook"
              board_webhook(args)
            else
              puts "Usage: brainiac fizzy board <setup|list|assign|columns|webhook>"
              puts ""
              puts "Commands:"
              puts "  setup                         Add a new board (interactive, fetches columns from Fizzy)"
              puts "  list                          List configured boards and their columns"
              puts "  assign <project> <board_key>  Assign a project to a board"
              puts "  columns <board_key>           Refresh columns for a board from Fizzy"
              puts "  webhook <board_key> [url]     Create/replace webhook and save the signing secret"
            end
          end

          # --- board setup (split into phases) ---

          def board_setup
            puts "Fizzy Board Setup"
            puts "================="
            puts ""

            board = board_setup_select_or_create_board
            return unless board

            board_key = board_setup_choose_key(board["name"])
            column_map = board_setup_columns(board["id"], board["name"])
            secret = board_setup_ask_secret(board_key)

            config = board_setup_save(board_key, board["id"], column_map, secret)

            puts ""
            puts "✓ Board \"#{board["name"]}\" added as '#{board_key}' in #{FIZZY_CONFIG_FILE}"
            puts "  Columns: #{column_map.keys.join(", ")}" unless column_map.empty?

            board_setup_offer_webhook(config, board_key, board["id"])

            puts ""
            puts "Next steps:"
            puts "  brainiac fizzy board assign <project-key> #{board_key}"
          end

          def board_setup_select_or_create_board
            boards_json = run_fizzy("board", "list", "--all", "--json")
            unless boards_json
              puts "Error: Could not fetch boards from Fizzy CLI."
              puts "  Ensure 'fizzy' is on your PATH and authenticated."
              puts "  Run: fizzy doctor"
              return nil
            end

            boards = JSON.parse(boards_json)["data"] || []

            puts "Available boards:"
            boards.each_with_index do |board, i|
              puts "  #{i + 1}) #{board["name"]} (#{board["id"]})"
            end
            puts "  #{boards.size + 1}) ✨ Create a new board"
            puts ""
            print "Select board number: "
            choice = $stdin.gets&.chomp&.to_i
            return puts("Cancelled.") unless choice&.positive? && choice <= boards.size + 1

            if choice == boards.size + 1
              board_setup_create_board
            else
              boards[choice - 1]
            end
          end

          def board_setup_create_board
            print "New board name: "
            name = $stdin.gets&.chomp
            return puts("Cancelled.") if name.nil? || name.empty?

            print "Allow all team members access? [Y/n]: "
            all_access = $stdin.gets&.chomp&.downcase != "n"

            args = ["board", "create", "--name", name, "--all_access", all_access.to_s, "--json"]
            output = run_fizzy(*args)
            unless output
              puts "Error: Failed to create board."
              return nil
            end

            board_data = JSON.parse(output)["data"]
            puts "✓ Created board \"#{name}\" (#{board_data["id"]})"
            board_data
          end

          def board_setup_choose_key(board_name)
            suggested_key = board_name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_|_$/, "")
            print "Board key for config [#{suggested_key}]: "
            board_key = $stdin.gets&.chomp
            board_key = suggested_key if board_key.nil? || board_key.empty?
            board_key
          end

          def board_setup_columns(board_id, board_name)
            columns_json = run_fizzy("column", "list", "--board", board_id, "--json")
            columns = columns_json ? (JSON.parse(columns_json)["data"] || []) : []
            custom_columns = columns.reject { |c| c["pseudo"] }

            puts ""
            if custom_columns.any?
              puts "Existing columns for \"#{board_name}\":"
              columns.each do |col|
                pseudo_tag = col["pseudo"] ? " [built-in]" : ""
                puts "  • #{col["name"]} (#{col["id"]})#{pseudo_tag}"
              end
              puts ""
              print "Create brainiac lifecycle columns (right_now, needs_review, uat)? [y/N]: "
              custom_columns = board_setup_create_lifecycle_columns(board_id, custom_columns) if $stdin.gets&.chomp&.downcase == "y"
            else
              puts "No custom columns on \"#{board_name}\" yet."
              print "Create brainiac lifecycle columns (right_now, needs_review, uat)? [Y/n]: "
              custom_columns = board_setup_create_lifecycle_columns(board_id, custom_columns) if $stdin.gets&.chomp&.downcase != "n"
            end

            puts ""
            puts "Map columns to brainiac config keys:"
            puts "(These control lifecycle transitions: right_now, needs_review, uat)"
            puts "Leave blank to accept suggestion, '-' to skip."
            puts ""

            prompt_column_mapping(custom_columns)
          end

          def board_setup_create_lifecycle_columns(board_id, existing_columns)
            lifecycle = [
              { config_key: "right_now", default_name: "Right Now", color: "blue" },
              { config_key: "needs_review", default_name: "Needs Review", color: "yellow" },
              { config_key: "uat", default_name: "UAT", color: "lime" }
            ]

            existing_names = existing_columns.map { |c| c["name"].downcase }

            lifecycle.each do |col_def|
              if existing_names.include?(col_def[:default_name].downcase)
                puts "  ✓ \"#{col_def[:default_name]}\" already exists"
                next
              end

              print "  Name for #{col_def[:config_key]} column [#{col_def[:default_name]}]: "
              name = $stdin.gets&.chomp
              name = col_def[:default_name] if name.nil? || name.empty?

              output = run_fizzy("column", "create", "--board", board_id,
                                 "--name", name, "--color", col_def[:color], "--json")
              if output
                col_data = JSON.parse(output)["data"]
                puts "  ✓ Created \"#{name}\" (#{col_data["id"]})"
                existing_columns << col_data
              else
                puts "  ⚠ Failed to create \"#{name}\""
              end
            end

            existing_columns
          end

          def board_setup_ask_secret(board_key)
            puts ""
            puts "Webhook setup:"
            puts "  Fizzy generates the signing secret when you create a webhook."
            print "Paste the webhook signing_secret from Fizzy (or 'skip' to set later): "
            secret = $stdin.gets&.chomp
            if secret.nil? || secret.empty? || secret == "skip"
              puts "  ⚠ No secret set — you'll need to add it to fizzy.json manually later."
              puts "    Create the webhook in Fizzy, then paste the signing_secret into:"
              puts "    #{FIZZY_CONFIG_FILE} → boards.#{board_key}.webhook_secret"
              nil
            else
              secret
            end
          end

          def board_setup_save(board_key, board_id, column_map, secret)
            config = load_fizzy_config
            config["boards"] ||= {}
            board_entry = { "board_id" => board_id, "columns" => column_map }
            board_entry["webhook_secret"] = secret if secret
            config["boards"][board_key] = board_entry
            save_fizzy_config(config)
            config
          end

          def board_setup_offer_webhook(config, board_key, board_id)
            puts ""
            print "Create webhook in Fizzy now? [Y/n]: "
            answer = $stdin.gets&.chomp&.downcase
            return if answer == "n"

            webhook_url = prompt_webhook_url(board_key)
            return unless webhook_url && !webhook_url.empty?

            signing_secret = create_fizzy_webhook(board_id, board_key, webhook_url)
            return unless signing_secret

            config["boards"][board_key]["webhook_secret"] = signing_secret
            save_fizzy_config(config)
            puts "✓ Webhook created! Signing secret saved to fizzy.json."
          end

          # --- board list ---

          def board_list
            config = load_fizzy_config
            boards = config["boards"] || {}

            if boards.empty?
              puts "No boards configured."
              puts "Run 'brainiac fizzy board setup' to add one."
              return
            end

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

              assigned = projects.select { |_, cfg| cfg["fizzy_board"] == key }.keys
              puts "    Projects: #{assigned.any? ? assigned.join(", ") : "(none)"}"
            end
          end

          # --- board assign ---

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

            config = load_fizzy_config
            unless config.dig("boards", board_key)
              puts "Error: Board '#{board_key}' not found in fizzy.json."
              puts "Available: #{(config["boards"] || {}).keys.join(", ")}"
              return
            end

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

          # --- board columns ---

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

            new_map = prompt_column_mapping(custom_columns, existing_map)

            config["boards"][board_key]["columns"] = new_map
            save_fizzy_config(config)

            puts ""
            puts "✓ Updated columns for '#{board_key}': #{new_map.keys.join(", ")}"
          end

          # --- board webhook (split into phases) ---

          def board_webhook(args)
            board_key = args.shift
            webhook_url = args.shift

            unless board_key
              puts "Usage: brainiac fizzy board webhook <board-key> [payload-url]"
              puts ""
              puts "Creates a webhook in Fizzy for the board and saves the signing secret."
              puts "If the board already has a webhook, deletes it first."
              puts ""
              puts "Available boards:"
              config = load_fizzy_config
              (config["boards"] || {}).each_key { |k| puts "  #{k}" }
              return
            end

            config = load_fizzy_config
            board_config = config.dig("boards", board_key)
            unless board_config
              puts "Error: Board '#{board_key}' not found in fizzy.json."
              return
            end

            board_id = board_config["board_id"]

            return if remove_existing_webhooks(board_id) == :cancelled

            webhook_url ||= prompt_webhook_url(board_key)
            if webhook_url.nil? || webhook_url.empty?
              puts "Error: Payload URL is required."
              return
            end

            board_webhook_create_and_save(config, board_key, board_id, webhook_url)
          end

          def remove_existing_webhooks(board_id)
            existing_json = run_fizzy("webhook", "list", "--board", board_id, "--all", "--json")
            return :proceed unless existing_json

            existing = JSON.parse(existing_json)["data"] || []
            brainiac_webhooks = existing.select { |w| w["name"]&.start_with?("brainiac") }
            return :proceed unless brainiac_webhooks.any?

            puts "Existing brainiac webhook(s) found:"
            brainiac_webhooks.each do |w|
              status = w["active"] ? "active" : "inactive"
              puts "  • #{w["name"]} (#{status}) → #{w["payload_url"]}"
            end
            print "Delete existing and create new? [Y/n]: "
            answer = $stdin.gets&.chomp&.downcase
            if answer == "n"
              puts "Cancelled."
              return :cancelled
            end
            brainiac_webhooks.each do |w|
              run_fizzy("webhook", "delete", w["id"], "--board", board_id)
              puts "  Deleted: #{w["name"]}"
            end
            :proceed
          end

          def board_webhook_create_and_save(config, board_key, board_id, webhook_url)
            signing_secret = create_fizzy_webhook(board_id, board_key, webhook_url)
            webhook_id = @last_webhook_id

            if signing_secret
              config["boards"][board_key]["webhook_secret"] = signing_secret
              save_fizzy_config(config)
              puts "✓ Webhook created (ID: #{webhook_id})"
              puts "  URL: #{webhook_url}"
              puts "  Signing secret saved to fizzy.json"
            else
              puts "✓ Webhook created but no signing_secret in response."
              puts "  Check: fizzy webhook show #{webhook_id} --board #{board_id}"
            end
          end

          # --- shared helpers ---

          def prompt_column_mapping(columns, existing_map = {})
            column_map = {}
            columns.each do |col|
              existing_key = existing_map.key(col["id"])
              suggested = existing_key || col["name"].downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_|_$/, "")
              print "  \"#{col["name"]}\" → config key [#{suggested}]: "
              key = $stdin.gets&.chomp
              key = suggested if key.nil? || key.empty?
              next if ["-", "skip"].include?(key)

              column_map[key] = col["id"]
            end
            column_map
          end

          def prompt_webhook_url(board_key)
            detected_url = detect_ngrok_url
            if detected_url
              default_url = "#{detected_url}/fizzy/#{board_key}"
              print "Webhook payload URL [#{default_url}]: "
              input = $stdin.gets&.chomp
              input.nil? || input.empty? ? default_url : input
            else
              print "Webhook payload URL (e.g., https://your-ngrok.app/fizzy/#{board_key}): "
              $stdin.gets&.chomp
            end
          end

          def create_fizzy_webhook(board_id, board_key, webhook_url)
            actions = "card_assigned,card_closed,card_published,card_reopened,card_triaged,comment_created"
            webhook_json = run_fizzy("webhook", "create", "--board", board_id,
                                     "--name", "brainiac-#{board_key}",
                                     "--url", webhook_url,
                                     "--actions", actions, "--json")
            unless webhook_json
              puts "⚠ Failed to create webhook. Create it manually in Fizzy."
              return nil
            end

            webhook_data = JSON.parse(webhook_json)["data"]
            @last_webhook_id = webhook_data&.dig("id")
            webhook_data&.dig("signing_secret")
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

          def run_fizzy(*)
            require "open3"
            output, status = Open3.capture2("fizzy", *)
            status.success? ? output : nil
          rescue Errno::ENOENT
            nil
          end

          def detect_ngrok_url
            require "net/http"
            uri = URI("http://127.0.0.1:4040/api/tunnels")
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 2
            http.read_timeout = 2
            response = http.get(uri.path)
            data = JSON.parse(response.body)
            tunnels = data["tunnels"] || []
            https_tunnel = tunnels.find { |t| t["public_url"]&.start_with?("https://") }
            https_tunnel&.dig("public_url")
          rescue StandardError
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
      # When called with no args, returns top-level subcommands.
      # When called with args (the words typed so far after the plugin name),
      # returns context-sensitive completions for nested subcommands.
      def self.completions(args = [])
        return %w[board config setup status] if args.empty?

        case args[0]
        when "board"
          board_completions(args[1..])
        else
          []
        end
      end

      # Nested completions for `brainiac fizzy board ...`
      def self.board_completions(args)
        board_subcommands = %w[assign columns list ls setup webhook]
        return board_subcommands if args.empty?

        case args[0]
        when "assign"
          board_assign_completions(args[1..])
        when "columns", "webhook"
          board_key_completions(args[1..])
        else
          []
        end
      end

      # Completions for `brainiac fizzy board assign <project> <board>`
      def self.board_assign_completions(args)
        case args.length
        when 0
          load_project_keys
        when 1
          load_board_keys
        else
          []
        end
      end

      # Completions for commands that take a board key as next arg
      def self.board_key_completions(args)
        return load_board_keys if args.empty?

        []
      end

      # Load board keys from fizzy.json for completion
      def self.load_board_keys
        config_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "fizzy.json")
        return [] unless File.exist?(config_file)

        config = JSON.parse(File.read(config_file))
        (config["boards"] || {}).keys
      rescue StandardError
        []
      end

      # Load project keys from projects.json for completion
      def self.load_project_keys
        projects_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "projects.json")
        return [] unless File.exist?(projects_file)

        JSON.parse(File.read(projects_file)).keys
      rescue StandardError
        []
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
