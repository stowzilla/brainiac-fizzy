# frozen_string_literal: true

require_relative "fizzy/version"
require_relative "fizzy/config"
require_relative "fizzy/helpers"
require_relative "fizzy/prompts"
require_relative "fizzy/planning"
require_relative "fizzy/hooks"
require_relative "fizzy/delegators"

# Handler sub-modules (define top-level functions for webhook handling)
require_relative "fizzy/handlers/assignment"
require_relative "fizzy/handlers/comments"
require_relative "fizzy/handlers/dedup"
require_relative "fizzy/handlers/deploy"
require_relative "fizzy/handlers/card_index"
require_relative "fizzy/handlers/deployments"

module Brainiac
  module Plugins
    module Fizzy
      class << self
        # Called by Brainiac plugin system during server startup.
        #
        # @param app [Sinatra::Application] The running Brainiac server
        def register(app)
          # Load Fizzy config
          Brainiac::Plugins::Fizzy::Config.load!

          # Register channel prompt
          Brainiac.register_channel_prompt(:fizzy,
                                          Brainiac::Plugins::Fizzy::Prompts::CHANNEL,
                                          pre_post_check: Brainiac::Plugins::Fizzy::Prompts::PRE_POST_CHECK)

          # Register lifecycle hooks
          Brainiac::Plugins::Fizzy::Hooks.register_all!

          # Set up webhook route
          setup_routes(app)

          LOG.info "[Fizzy] Plugin registered (webhook: /fizzy)"
        end

        private

        def setup_routes(app)
          app.post "/fizzy/?:board_key?" do
            content_type :json
            request.body.rewind
            payload_body = request.body.read
            board_key = params["board_key"]

            Brainiac::Plugins::Fizzy::Helpers.verify_signature!(request, payload_body, board_key: board_key)

            payload = JSON.parse(payload_body)
            event_id = payload["id"]
            action = payload["action"]

            LOG.info "[Fizzy] Received event #{event_id}: action=#{action}"

            if already_processed?(event_id)
              LOG.info "[Fizzy] Skipping duplicate event #{event_id}"
              halt 200, { status: "duplicate" }.to_json
            end

            reload_projects!
            reload_agent_registry!

            case action
            when "card_assigned"
              status_code, body = handle_card_assigned(payload)
              LOG.info "[Fizzy] #{action} response: #{status_code} - #{body}"
              halt status_code, body
            when "comment_created"
              status_code, body = handle_comment(payload)
              LOG.info "[Fizzy] comment_created response: #{status_code} - #{body}"
              halt status_code, body
            when "card_published", "card_triaged"
              status_code, body = Brainiac::Plugins::Fizzy.handle_publish_or_triage(action, payload)
              LOG.info "[Fizzy] #{action} response: #{status_code} - #{body}"
              halt status_code, body
            else
              LOG.info "[Fizzy] Ignoring unknown action: #{action}"
              halt 200, { status: "ignored", action: action }.to_json
            end
          rescue JSON::ParserError => e
            LOG.error "[Fizzy] Invalid JSON: #{e.message}"
            halt 400, { error: "Invalid JSON" }.to_json
          rescue StandardError => e
            LOG.error "[Fizzy] Unhandled error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
            halt 500, { error: e.message }.to_json
          end

          # API status endpoint
          app.get "/api/fizzy" do
            content_type :json
            config = Brainiac::Plugins::Fizzy::Config.current
            {
              enabled: true,
              boards: config["boards"]&.keys || [],
              authorized_users: (config["authorized_users"] || []).size
            }.to_json
          end
        end

        public

        def handle_publish_or_triage(action, payload)
          eventable = payload["eventable"] || {}
          card_number = eventable["number"]&.to_s

          if action == "card_triaged" && card_number
            return [200, { status: "ignored", reason: "self_move" }.to_json] if self_move_recent?(card_number)
            return [200, { status: "ignored", reason: "card_merged" }.to_json] if card_merged?(card_number)

            card_key = "card-#{card_number}"
            return [200, { status: "ignored", reason: "recently_completed" }.to_json] if recently_completed?(card_key)
          end

          if action == "card_published"
            assignees = eventable["assignees"] || []
            if assignees.any? { |a| local_agent_names.include?(a["name"]) }
              return handle_card_assigned(payload)
            end
          end

          handle_card_published(payload)
        end
      end
    end
  end
end
