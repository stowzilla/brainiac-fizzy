# Project Structure

## Layout

```
lib/brainiac/plugins/fizzy/
├── plugin.rb              # Plugin registration and entry point
├── hooks.rb               # Hook registration (post_session, etc.)
├── helpers.rb             # Shared utility methods
└── handlers/              # Event-specific handler modules
    ├── assignment.rb      # Card assignment handling
    ├── comment.rb         # Comment routing and @mentions
    ├── deploy.rb          # Deploy shortcut handling
    ├── deployments.rb     # Deployment environment tracking
    ├── duplicate.rb       # Duplicate detection (trigram + semantic)
    └── no_comment.rb      # No-comment fallback re-dispatch

test/
├── test_helper.rb         # Shared test setup and stubs
├── test_fizzy.rb          # Core fizzy handler tests
├── test_deploy.rb         # Deployment handler tests
└── test_no_comment.rb     # No-comment fallback tests
```

## Conventions

- Handlers go in `lib/brainiac/plugins/fizzy/handlers/`.
- Keep `hooks.rb` focused on hook registration; extract complex logic into handler modules.
- Tests use Minitest with the helper stubs in `test_helper.rb`.
