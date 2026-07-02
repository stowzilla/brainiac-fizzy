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
          setup_webhook_route(app)
          setup_api_routes(app)
        end

        def setup_webhook_route(app)
          app.post "/fizzy/?:board_key?" do
            content_type :json
            request.body.rewind
            payload_body = request.body.read
            board_key = params["board_key"]

            LOG.debug "[Fizzy] Webhook received: board_key=#{board_key}, content_length=#{payload_body.length}" if LOG.debug?

            unless Brainiac::Plugins::Fizzy::Helpers.verify_signature!(request, payload_body, board_key: board_key)
              LOG.warn "[Fizzy] Signature verification failed for board_key=#{board_key}"
              halt 401, { error: "Invalid signature" }.to_json
            end

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

            status_code, body = dispatch_webhook_action(action, payload)
            LOG.info "[Fizzy] #{action} response: #{status_code} - #{body}"
            halt status_code, body
          rescue JSON::ParserError => e
            LOG.error "[Fizzy] Invalid JSON: #{e.message}"
            halt 400, { error: "Invalid JSON" }.to_json
          rescue StandardError => e
            LOG.error "[Fizzy] Unhandled error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
            halt 500, { error: e.message }.to_json
          end
        end

        def setup_api_routes(app)
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

          # Card index API (duplicate detection)
          app.get "/api/card-index" do
            content_type :json
            halt 404, { error: "Card index not available" }.to_json unless defined?(CARD_INDEX)

            query = params["q"]
            if query && !query.empty?
              similar = CARD_INDEX.find_similar_cards(query)
              { query: query, matches: similar, total_indexed: CARD_INDEX.size }.to_json
            else
              { total: CARD_INDEX.size, cards: CARD_INDEX }.to_json
            end
          end

          # Deployment API routes (if deployments are configured)
          return unless defined?(DEPLOYMENTS_CONFIG)

          app.get "/api/deployments" do
            content_type :json
            reload_deployments_config!
            reload_deployment_state!
            { deployments: deployment_status }.to_json
          end

          app.post "/api/deployments/:env" do
            content_type :json
            env_key = params["env"]
            request.body.rewind
            payload = JSON.parse(request.body.read)
            result = deploy_to_environment(env_key, worktree_path: payload["worktree"], deployed_by: payload["deployed_by"])
            if result[:error]
              halt 404, result.to_json
            else
              { status: "deployed", env: env_key, deployment: result }.to_json
            end
          rescue JSON::ParserError
            halt 400, { error: "Invalid JSON" }.to_json
          end

          app.delete "/api/deployments/:env" do
            content_type :json
            env_key = params["env"]
            state = load_deployment_state
            if state.key?(env_key)
              state[env_key] = { "status" => "available", "cleared_at" => Time.now.iso8601, "last_card" => state[env_key]["card_number"] }
              save_deployment_state(state)
              DEPLOYMENT_STATE.replace(state)
              LOG.info "[Fizzy:Deploy] Manually cleared #{env_key}"
              { status: "cleared", env: env_key }.to_json
            else
              halt 404, { error: "Unknown environment: #{env_key}" }.to_json
            end
          end

          app.post "/api/deployments/:env/deploying" do
            content_type :json
            env_key = params["env"]
            config = DEPLOYMENTS_CONFIG["environments"] || {}
            halt 404, { error: "Unknown environment: #{env_key}" }.to_json unless config.key?(env_key)
            request.body.rewind
            payload = begin
              JSON.parse(request.body.read)
            rescue StandardError
              {}
            end
            mark_deploying(env_key, worktree_path: payload["worktree"] || "")
            LOG.info "[Fizzy:Deploy] #{env_key} marked deploying via API"
            { status: "deploying", env: env_key }.to_json
          end
        end

        public

        def handle_publish_or_triage(action, payload)
          eventable = payload["eventable"] || {}
          card_number = eventable["number"]&.to_s

          if action == "card_triaged" && card_number
            return [200, { status: "ignored", reason: "self_move" }.to_json] if self_move_recent?(card_number)
            return [200, { status: "ignored", reason: "card_merged" }.to_json] if work_item_merged?(card_number)

            card_key = "card-#{card_number}"
            return [200, { status: "ignored", reason: "recently_completed" }.to_json] if recently_completed?(card_key)
          end

          if action == "card_published"
            assignees = eventable["assignees"] || []
            return handle_card_assigned(payload) if assignees.any? { |a| local_agent_names.include?(a["name"]) }
          end

          handle_card_published(payload)
        end
      end
    end
  end
end
