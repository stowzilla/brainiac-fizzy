# frozen_string_literal: true

require_relative "fizzy/version"
require_relative "fizzy/assignment"
require_relative "fizzy/comments"
require_relative "fizzy/dedup"
require_relative "fizzy/deploy"
require_relative "fizzy/card_index"
require_relative "fizzy/deployments"

module Brainiac
  module Plugins
    module Fizzy
      class << self
        # Called by Brainiac plugin system during server startup.
        # Registers the Fizzy webhook route and card index/deployment background tasks.
        #
        # @param app [Sinatra::Application] The running Brainiac server
        def register(app)
          setup_routes(app)
          log "[Fizzy] Plugin registered (webhook: /fizzy)"
        end

        private

        def setup_routes(app)
          # POST /fizzy/:board_key — Incoming Fizzy webhook events
          app.post "/fizzy/?:board_key?" do
            content_type :json
            request.body.rewind
            payload_body = request.body.read
            board_key = params["board_key"]

            verify_signature!(request, payload_body, board_key: board_key)

            payload = JSON.parse(payload_body)

            event_id = payload["id"]
            action = payload["action"]

            LOG.info "[Fizzy] Received event #{event_id}: action=#{action}"

            if already_processed?(event_id)
              LOG.info "Skipping duplicate event #{event_id}"
              halt 200, { status: "duplicate" }.to_json
            end

            reload_projects!
            reload_agent_registry!
            reload_github_config!

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
            LOG.error "Invalid JSON: #{e.message}"
            halt 400, { error: "Invalid JSON" }.to_json
          rescue StandardError => e
            LOG.error "Unhandled error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
            halt 500, { error: e.message }.to_json
          end

          # GET /api/fizzy — Plugin status endpoint
          app.get "/api/fizzy" do
            content_type :json
            {
              enabled: true,
              card_index_size: defined?(CARD_INDEX) ? CARD_INDEX.size : 0,
              deployments: defined?(DEPLOYMENTS) ? DEPLOYMENTS.keys : []
            }.to_json
          end
        end

        def log(msg)
          LOG.info(msg) if defined?(LOG)
        end

        public

        # Handle card_published and card_triaged events.
        # Extracted to a module method so it can be tested independently.
        def handle_publish_or_triage(action, payload)
          eventable = payload["eventable"] || {}
          card_number = eventable["number"]&.to_s

          if action == "card_triaged" && card_number
            if self_move_recent?(card_number)
              LOG.info "[Fizzy] Ignoring card_triaged for ##{card_number} — self-move echo"
              return [200, { status: "ignored", reason: "self_move" }.to_json]
            end

            if card_merged?(card_number)
              LOG.info "[Fizzy] Ignoring card_triaged for ##{card_number} — card already merged"
              return [200, { status: "ignored", reason: "card_merged" }.to_json]
            end

            card_key = "card-#{card_number}"
            if recently_completed?(card_key)
              LOG.info "[Fizzy] Ignoring card_triaged for ##{card_number} — recently completed"
              return [200, { status: "ignored", reason: "recently_completed" }.to_json]
            end
          end

          # Only card_published does duplicate detection — card_triaged skips agent dispatch
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
