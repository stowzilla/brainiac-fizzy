# AGENTS.md

## Pre-PR Checklist

Before opening or updating a pull request, agents MUST:

1. **Run rubocop** — `bundle exec rubocop` must pass with zero offenses.
2. **Run tests** — `bundle exec rake test` must pass with no failures.
3. **Fix, don't suppress** — if rubocop raises an offense, fix the code. Only add exclusions to `.rubocop.yml` when the rule fundamentally conflicts with the file's purpose (e.g., a registration hub exceeding module length).

If either step fails, fix the issues before pushing.

## Project Conventions

- Ruby 3.4+, double-quoted strings, 150-char line limit.
- Rubocop config is in `.rubocop.yml` at the project root.
- Test with Minitest: `bundle exec rake test`.
- Handlers go in `lib/brainiac/plugins/fizzy/handlers/`.
- Keep `hooks.rb` focused on hook registration; extract complex logic into handler modules.

## Code Style

- Follow existing patterns in the codebase.
- No `rescue nil` — use explicit rescue with specific exception classes.
- Avoid multiline modifier `if`/`unless` — use block form instead.
- Keep methods under the configured complexity limits (see `.rubocop.yml`).
