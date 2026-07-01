# frozen_string_literal: true

require_relative "lib/brainiac/plugins/fizzy/version"

Gem::Specification.new do |s|
  s.name        = "brainiac-fizzy"
  s.version     = Brainiac::Plugins::Fizzy::VERSION
  s.summary     = "Fizzy card management plugin for Brainiac"
  s.description = "Full Fizzy integration for Brainiac — card assignment, comment routing, " \
                  "@mentions, cross-agent reviews, duplicate detection, deploy shortcuts, " \
                  "deployment tracking, and planning mode. Uses Brainiac's hook system for " \
                  "lifecycle integration (PR merge → card close, agent complete → column move)."
  s.authors     = ["Andy Davis"]
  s.homepage    = "https://github.com/stowzilla/brainiac-fizzy"
  s.license     = "MIT"
  s.required_ruby_version = ">= 3.4"

  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  s.require_paths = ["lib"]

  s.add_dependency "brainiac", ">= 0.1.0"

  s.add_development_dependency "minitest", "~> 5.25"
  s.add_development_dependency "rake", "~> 13.0"

  s.metadata["rubygems_mfa_required"] = "true"
end
