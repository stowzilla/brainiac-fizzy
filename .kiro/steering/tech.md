# Tech Stack

## Language & Runtime

- Ruby 3.4+ (see `.ruby-version`)
- Packaged as a gem (`brainiac-fizzy.gemspec`)
- Plugin for [brainiac](https://github.com/stowzilla/brainiac)

## Dependencies

| Gem | Purpose |
|-----|---------|
| brainiac ~> 0.0 | Host server (runtime dependency) |

## Dev Dependencies

| Gem | Purpose |
|-----|---------|
| minitest ~> 5.25 | Test framework |
| rake ~> 13.0 | Task runner |
| rubocop ~> 1.75 | Linter |
| rubocop-performance ~> 1.25 | Performance cops |

## Common Commands

```bash
# Run tests
bundle exec rake test

# Run linter
bundle exec rubocop

# Auto-fix lint offenses
bundle exec rubocop -A

# Run both (tests + lint check)
bundle exec rake test && bundle exec rubocop
```

## Quality Gates

Every push must pass:
1. `bundle exec rubocop` — zero offenses
2. `bundle exec rake test` — zero failures

These are not optional. Run both before every push.
