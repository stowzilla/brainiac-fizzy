# brainiac-fizzy

Fizzy card management plugin for [Brainiac](https://github.com/stowzilla/brainiac).

Handles the full Fizzy integration: card assignment, comment routing, @mentions, cross-agent reviews, duplicate detection, deploy shortcuts, and deployment environment tracking.

## Installation

```bash
brainiac install fizzy
brainiac restart
```

Or manually:

```bash
gem install brainiac-fizzy
```

Then add to `~/.brainiac/plugins.json`:

```json
{
  "plugins": [
    { "name": "fizzy", "gem": "brainiac-fizzy" }
  ]
}
```

## Configuration

Fizzy configuration lives in `~/.brainiac/fizzy.json` (same as before):

```json
{
  "authorized_users": [
    { "id": "user-id-1", "name": "Andy", "human": true },
    { "id": "agent-id-1", "name": "Galen", "human": false }
  ],
  "boards": {
    "development": {
      "board_id": "your-board-id",
      "webhook_secret": "secret-for-this-board",
      "columns": {
        "right_now": "column-id",
        "needs_review": "column-id",
        "uat": "column-id"
      }
    }
  }
}
```

## What This Plugin Handles

| Event | Action |
|-------|--------|
| Card assigned | Creates worktree, maps card to branch, dispatches assigned agent |
| Card published | Duplicate detection (trigram + semantic) |
| @mention in comment | Routes to mentioned agent (cross-agent reviews) |
| Follow-up comment | Runs card's assigned agent in existing worktree |
| Deploy shortcut | Clones branch to deployment environment (dev01, dev02) |

## Webhook Setup

Set your Fizzy webhook URL to:
```
https://your-ngrok.ngrok-free.app/fizzy/development
```

Where `development` is the board key from `fizzy.json`. Set the secret to the board's `webhook_secret`.

## Dependencies on Brainiac Core

This plugin runs inside the brainiac server process and uses core functions:

- `verify_signature!` — webhook HMAC verification
- `run_agent` — agent CLI dispatch
- `session_active?`, `already_processed?` — deduplication
- `identify_project_by_tags` — card-to-project mapping
- `create_or_reuse_worktree` — git worktree management
- `prefetch_card_context` — card body/comments pre-fetch
- `render_prompt` — prompt template composition
- `reload_projects!`, `reload_agent_registry!` — config hot-reload

These are all provided by the `brainiac` gem (runtime dependency).

## Migrating from Built-in Handler

If upgrading from brainiac's built-in Fizzy handler:

1. Install the plugin: `brainiac install fizzy`
2. Disable the built-in handler in `~/.brainiac/brainiac.json`:
   ```json
   { "handlers": { "fizzy": false } }
   ```
3. Restart: `brainiac restart`

The plugin uses the exact same config files and functions — it's a drop-in replacement.

## Development

```bash
cd ~/Code/brainiac-fizzy
bundle install
rake test
```

## License

MIT
