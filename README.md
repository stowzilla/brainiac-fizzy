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

## Setup

Requires the [`fizzy` CLI](https://github.com/robzolkos/fizzy-cli), installed and configured for your account.

### Adding an agent (recommended)

```bash
brainiac agent create "Galen" --local --avatar galen.png --description-file galen.md
```

Fizzy has no API for creating users or issuing tokens, so there's one manual step. The plugin prints your account's join link; open it **in a private window** (so you're not signed in as yourself), join as the agent's email, click the magic link from that inbox, then Profile → Personal access tokens → create a token with write access and paste it in once. Everything else is automated:

- Fizzy user name and avatar set (falls back to `admin_token` if the agent can't edit its own profile)
- Agent added to `authorized_users` in `~/.brainiac/fizzy.json` (`"human": false`)
- `FIZZY_TOKEN` saved to the agent's `env` in `~/.brainiac/agents.json`

This step is skipped until `fizzy.json` exists — set up a board first (below). For an existing agent, an interrupted create, or after installing this plugin, run `brainiac agent setup galen` (add `--only fizzy` to run just this plugin; `--skip fizzy` leaves Fizzy out). It's safe to re-run: agents that already have a token and an `authorized_users` entry are skipped.

**Manual alternative:** create the Fizzy user and token as above, add `{ "id": "<fizzy-user-id>", "name": "Galen", "human": false }` to `authorized_users` in `fizzy.json`, and set `FIZZY_TOKEN` in the agent's `env` in `~/.brainiac/agents.json`.

### Boards

```bash
brainiac fizzy board setup                   # pick/create a board, map columns, create the webhook
brainiac fizzy board assign <project> <board-key>
```

`board setup` can create the lifecycle columns (`right_now`, `needs_review`, `uat`) and the webhook for you, saving the signing secret to `fizzy.json`. Run `brainiac fizzy setup` to check what's configured.

## Commands

```
brainiac fizzy setup                              Check config and print next steps
brainiac fizzy config                             Show fizzy.json
brainiac fizzy status                             Fizzy status (via the running server)
brainiac fizzy board setup                        Add a board (interactive, fetches columns from Fizzy)
brainiac fizzy board list                         List boards, columns, and assigned projects
brainiac fizzy board assign <project> <board-key> Assign a project to a board
brainiac fizzy board columns <board-key>          Refresh a board's columns from Fizzy
brainiac fizzy board webhook <board-key> [url]    Create/replace the webhook and save its secret
brainiac fizzy env setup <card-number>            Deploy an ephemeral Belt env for an already-worked card
```

## Configuration

Fizzy configuration lives in `~/.brainiac/fizzy.json`:

```json
{
  "authorized_users": [
    { "id": "user-id-1", "name": "Andy", "human": true },
    { "id": "agent-id-1", "name": "Galen", "human": false }
  ],
  "admin_token": "admin-personal-access-token",
  "uat_agent": false,
  "uat_agent_tag": "uat",
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

- `authorized_users` — only webhook events from these users are acted on; `human` marks people vs. agents
- `admin_token` — optional admin access token, used to read the join link, edit agent profiles, and reactivate disabled webhooks
- `boards.<key>.webhook_secret` — falls back to the `FIZZY_WEBHOOK_SECRET` env var
- Projects map to boards via `fizzy_board` in `projects.json` (`brainiac fizzy board assign`) or a `.fizzy.yaml` in the repo

### UAT agent (`uat_agent`)

When a PR is merged and its card moves to the UAT column, Brainiac can dispatch
an LLM agent to write manual testing steps as a card comment. This spends tokens
on every merge, so it's **disabled by default**. Set `"uat_agent": true` at the
top level of `fizzy.json` to opt back in globally. The card still moves to UAT
and gets the PR-merged comment either way — only the agent dispatch is gated.

**Per-card opt-in:** Even with `uat_agent` off globally, you can trigger the UAT
agent for a single card by adding the `uat` tag to it. When the card's PR merges,
Brainiac fetches the card's live tags and dispatches the UAT agent if the tag is
present. Customize the tag name with `"uat_agent_tag": "your-tag"`, or set it to
`false`/`null` to disable per-card overrides entirely. This gives you three
states:

- `uat_agent: true` — dispatch on every merge
- `uat_agent: false` (default) + `uat` tag on a card — dispatch for that card only
- `uat_agent: false` + no tag — never dispatch (pure bookkeeping, zero tokens)

## What This Plugin Handles

| Event | Action |
|-------|--------|
| Card assigned | Creates worktree, maps card to branch, dispatches assigned agent |
| Card published | Duplicate detection (trigram + semantic) |
| @mention in comment | Routes to mentioned agent (cross-agent reviews) |
| Follow-up comment | Runs card's assigned agent in existing worktree |
| Deploy shortcut | Clones branch to deployment environment (dev01, dev02) |

## Webhook Setup

`brainiac fizzy board setup` / `board webhook` create this for you. To do it by hand, set your Fizzy webhook URL to:
```
https://your-ngrok.ngrok-free.app/fizzy/development
```

Where `development` is the board key from `fizzy.json`. Set the secret to the board's `webhook_secret`.

## Dependencies on Brainiac Core

This plugin runs inside the brainiac server process and uses core functions:

- `run_agent` — agent CLI dispatch
- `session_active?`, `already_processed?` — deduplication
- `create_or_reuse_worktree` — git worktree management
- `render_prompt` — prompt template composition
- `reload_projects!`, `reload_agent_registry!` — config hot-reload

These are all provided by the `brainiac` gem (runtime dependency). Webhook signature verification, tag-to-project mapping, and card context pre-fetch live in this plugin.

## Migrating from Built-in Handler

Older Brainiac versions shipped a built-in Fizzy handler; core no longer includes it. Install the plugin (`brainiac install fizzy`) and restart (`brainiac restart`). It uses the same config files, so it's a drop-in replacement.

## Development

```bash
cd ~/Code/brainiac-fizzy
bundle install
rake test
rake rubocop
```

## License

MIT
