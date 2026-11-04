# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module Brainiac
  module Plugins
    module Fizzy
      # Provisions a Fizzy user for a new brainiac agent (`brainiac agent create`
      # / `brainiac agent setup`).
      #
      # Fizzy has no "create user" API and only issues access tokens in the web
      # UI, so the manual part is: open the account's join link, join as the
      # agent's email, and copy a personal access token. Given that token, the
      # rest is automated: user id lookup, name + avatar, authorized_users, and
      # FIZZY_TOKEN in agents.json.
      module AgentSetup
        class << self
          def run(agent_key, entry)
            display_name = entry["display_name"] || agent_key.capitalize
            config = fizzy_config
            return unless config

            token = registry.dig(agent_key, "env", "FIZZY_TOKEN")
            if token && authorized?(config, display_name)
              puts "  [Fizzy] ✓ #{display_name} already has a Fizzy user (skipping)"
              return
            end

            token ||= prompt_for_token(display_name, entry["email"], config)
            return unless token

            user = identity_user(token)
            unless user
              puts "  [Fizzy] ✗ Fizzy rejected that token — re-run: brainiac agent setup #{agent_key}"
              return
            end

            update_profile(user["id"], display_name, entry["avatar_path"], token, config["admin_token"])
            save_token(agent_key, token)
            authorize(display_name, user["id"])
            puts "  [Fizzy] ✓ Saved FIZZY_TOKEN and added #{display_name} (#{user["id"]}) to authorized_users"
          end

          private

          def prompt_for_token(display_name, email, config)
            return nil unless $stdin.tty?

            join = fizzy_json("account", "join-code-show", token: config["admin_token"])
            puts ""
            puts "  [Fizzy] Create a Fizzy user for #{display_name}:"
            puts "    1. Open in a private window: #{join&.dig("url") || "(couldn't fetch — Account settings → Invite link)"}"
            puts "    2. Join as #{email || "the agent's email"}, then click the magic link from that inbox"
            puts "    3. Profile → Personal access tokens → new token with write access → copy it"
            puts "  Name, avatar and brainiac config are set automatically."
            print "  Access token (blank to skip): "
            token = read_secret
            puts ""
            token.nil? || token.empty? ? nil : token
          end

          def read_secret
            require "io/console"
            $stdin.noecho(&:gets)&.strip
          rescue Errno::ENOTTY, NoMethodError
            $stdin.gets&.strip
          end

          # The token owner's user record in the configured account.
          def identity_user(token)
            accounts = fizzy_json("identity", "show", token: token)&.dig("accounts") || []
            account = fizzy_json("config", "show")&.dig("account")
            match = accounts.find { |a| a["slug"].to_s.delete_prefix("/") == account.to_s } || accounts.first
            match&.dig("user")
          end

          # Users can't always edit themselves (members vs admins), so fall back
          # to the admin token from fizzy.json.
          def update_profile(user_id, display_name, avatar_path, token, admin_token)
            args = ["user", "update", user_id, "--name", display_name]
            args += ["--avatar", avatar_path] if avatar_path && File.file?(avatar_path)
            what = args.include?("--avatar") ? "name + avatar" : "name"

            if run_fizzy(*args, token: token) || (admin_token && run_fizzy(*args, token: admin_token))
              puts "  [Fizzy] ✓ Set #{what}"
            else
              puts "  [Fizzy] ⚠ Couldn't set #{what} — update the profile in Fizzy"
            end
          end

          def fizzy_json(*, token: nil)
            output = run_fizzy(*, "--quiet", token: token)
            output && JSON.parse(output)
          rescue JSON::ParserError
            nil
          end

          def run_fizzy(*args, token: nil)
            args += ["--token", token] if token
            output, status = Open3.capture2("fizzy", *args, err: File::NULL)
            status.success? ? output : nil
          rescue Errno::ENOENT
            nil
          end

          def brainiac_dir
            ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
          end

          def registry_file = File.join(brainiac_dir, "agents.json")
          def config_file = File.join(brainiac_dir, "fizzy.json")

          def registry
            File.exist?(registry_file) ? JSON.parse(File.read(registry_file)) : {}
          end

          def fizzy_config
            File.exist?(config_file) ? JSON.parse(File.read(config_file)) : nil
          end

          def authorized?(config, display_name)
            (config["authorized_users"] || []).any? { |u| u["name"]&.downcase == display_name.downcase }
          end

          def save_token(agent_key, token)
            reg = registry
            reg[agent_key] ||= {}
            reg[agent_key]["env"] ||= {}
            reg[agent_key]["env"]["FIZZY_TOKEN"] = token
            FileUtils.mkdir_p(brainiac_dir)
            File.write(registry_file, JSON.pretty_generate(reg))
          end

          def authorize(display_name, user_id)
            config = fizzy_config
            config["authorized_users"] ||= []
            config["authorized_users"].reject! { |u| u["name"]&.downcase == display_name.downcase }
            config["authorized_users"] << { "id" => user_id, "name" => display_name, "human" => false }
            File.write(config_file, JSON.pretty_generate(config))
          end
        end
      end
    end
  end
end
