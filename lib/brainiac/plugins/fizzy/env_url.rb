# frozen_string_literal: true

module Brainiac
  module Plugins
    module Fizzy
      # Derives the public URL of an ephemeral Belt environment from its
      # terraform.tfvars. Kept separate from Helpers so the pure URL/HCL logic
      # stays small and independently testable.
      module EnvUrl
        module_function

        # URL of the ephemeral Belt environment for a card, if one is active.
        # The env name is `fizzy-<card_number>`; the public URL is derived from the
        # env's terraform.tfvars, matching the frontend_urls convention in the Belt
        # infra module:
        #   parent set -> https://<env>.<parent>.<domain>
        #   prod       -> https://<domain>
        #   otherwise  -> https://<env>.<domain>
        def for_card(card_number)
          return nil unless defined?(BeltConfig)

          env_name = BeltConfig.ephemeral_env_for_card(card_number)
          return nil unless BeltConfig.ephemeral_env?(env_name)

          info = BeltConfig.respond_to?(:ephemeral_env_info) ? BeltConfig.ephemeral_env_info(env_name) : nil
          worktree = info && info["worktree"]
          return nil unless worktree

          tfvars = File.join(worktree, "infrastructure", env_name.to_s, "terraform.tfvars")
          return nil unless File.exist?(tfvars)

          from_tfvars(tfvars)
        rescue StandardError => e
          LOG.warn "[Fizzy] Could not detect env URL for card ##{card_number}: #{e.message}" if defined?(LOG)
          nil
        end

        def from_tfvars(tfvars_path)
          vars = parse(File.read(tfvars_path))
          domain = vars["domain"].to_s
          return nil if domain.empty?

          environment = vars["environment"].to_s
          parent = vars["parent_environment"].to_s

          host =
            if !parent.empty?
              "#{environment}.#{parent}.#{domain}"
            elsif environment == "prod"
              domain
            else
              "#{environment}.#{domain}"
            end

          "https://#{host}"
        end

        # Minimal HCL parser for `key = "value"` lines in terraform.tfvars.
        def parse(contents)
          vars = {}
          contents.each_line do |line|
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?("#")

            match = stripped.match(/\A(\w+)\s*=\s*"([^"]*)"/)
            vars[match[1]] = match[2] if match
          end
          vars
        end
      end
    end
  end
end
