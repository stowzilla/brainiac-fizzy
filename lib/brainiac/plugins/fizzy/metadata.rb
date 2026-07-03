# frozen_string_literal: true

# Lightweight metadata for brainiac-fizzy.
# Loaded by `brainiac help` without pulling in the full plugin runtime.

require_relative "version"

module Brainiac
  module Plugins
    module Fizzy
      # Returns true if Fizzy has at least one board configured.
      def self.configured?
        config_file = File.join(ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac")), "fizzy.json")
        return false unless File.exist?(config_file)

        config = JSON.parse(File.read(config_file))
        !(config["boards"] || {}).empty?
      rescue StandardError
        false
      end

      # Help text shown in `brainiac help` when the plugin is installed.
      def self.help_text
        "    brainiac fizzy <command>      Manage Fizzy boards"
      end
    end
  end
end
