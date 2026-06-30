# frozen_string_literal: true

# Card duplicate detection (card_published / card_triaged).
#
# When a new card is created, checks for similar existing cards using
# trigram and semantic similarity. Posts a warning comment if duplicates found.

def handle_card_published(payload)
  eventable = payload["eventable"] || {}
  card_number = eventable["number"]
  title = eventable["title"] || ""
  creator_name = payload.dig("creator", "name")
  creator_id = payload.dig("creator", "id")
  tags = eventable["tags"] || []

  # Creator-based routing: only the machine whose local human created the card
  # handles dedup. Requires `"local": true` on the human in fizzy.json authorized_users.
  local_humans = FIZZY_CONFIG.fetch("authorized_users", []).select { |u| u["human"] && u["local"] }
  if local_humans.empty?
    LOG.info "[CardIndex] No local humans configured — skipping dedup, indexing only"
    return index_card_only(card_number, title, creator_name, creator_id, tags)
  end

  unless local_humans.any? { |u| u["id"] == creator_id }
    LOG.info "[CardIndex] Ignoring card ##{card_number} — creator '#{creator_name}' is not a local human"
    return index_card_only(card_number, title, creator_name, creator_id, tags)
  end

  # Check for duplicates before indexing
  similar = CARD_INDEX.find_similar_cards(title, exclude_number: card_number, tags: tags) if card_number
  index_card_only(card_number, title, creator_name, creator_id, tags, skip_response: true)

  if similar&.any?
    post_duplicate_warning(card_number, title, tags, similar)
    [200, { status: "duplicate_detected", card: card_number,
            similar: similar.map { |s| { number: s[:number], score: s[:score].round(2) } } }.to_json]
  else
    LOG.info "[CardIndex] Card ##{card_number} '#{title}' indexed, no duplicates found"
    [200, { status: "indexed", card: card_number }.to_json]
  end
end

def index_card_only(card_number, title, creator_name, creator_id, tags, skip_response: false)
  CARD_INDEX.index_card(number: card_number, title: title, creator_name: creator_name, creator_id: creator_id, tags: tags) if card_number
  CARD_INDEX.save
  CARD_INDEX.schedule_qmd_reindex
  [200, { status: "indexed", card: card_number }.to_json] unless skip_response
end

def post_duplicate_warning(card_number, title, tags, similar)
  best = similar.first
  LOG.info "[CardIndex] Potential duplicate: ##{card_number} '#{title}' ≈ " \
           "##{best[:number]} '#{best[:title]}' (score: #{best[:score].round(2)})"

  project_result = identify_project_by_tags(tags)
  return unless project_result

  _project_key, project_config = project_result
  repo_path = project_config["repo_path"]

  Thread.new do
    method_label = { trigram: "📝", semantic: "🧠", both: "📝🧠" }
    dupes = similar.map do |s|
      icon = method_label[s[:method]] || "📝"
      "##{s[:number]} \"#{s[:title]}\" (#{(s[:score] * 100).round}% #{icon})"
    end.join("\n- ")
    body = "⚠️ **Possible duplicate detected:**\n- #{dupes}\n\n_📝 = text similarity, 🧠 = semantic similarity_"
    run_cmd("fizzy", "comment", "create", "--card", card_number.to_s, "--body", body,
            chdir: repo_path, env: default_fizzy_env)
    LOG.info "[CardIndex] Posted duplicate warning on card ##{card_number}"
  rescue StandardError => e
    LOG.warn "[CardIndex] Failed to post duplicate warning: #{e.message}"
  end
end
