# GitHub Projects Fork

Created: 2026-03-12

## Decision

Overture is a GitHub Projects-focused fork of Symphony, not a backward-compatible multi-tracker
variant.

## Why this fork exists

- BrandByX wants GitHub-native work management instead of Linear SaaS
- The upstream Elixir implementation is still Linear-oriented in config, docs, and runtime shape
- Backward compatibility would add code, docs, and test burden without helping the intended fork

## v1 cut line

Supported in v1:

- GitHub Projects v2 only
- one configured board at runtime
- one configured repository at runtime
- issue-backed project items as runnable tracker inputs
- project `Status` field as the workflow source of truth
- linked-issue comments and close/reopen behavior

Explicitly out of scope in v1:

- Linear compatibility
- multi-repo boards
- draft items as runnable work
- PR-linked project items as runnable work
- blocker/dependency parity
- full internal package/module renaming

## Naming policy

- Public-facing repo and docs use `Overture`
- Internal runtime names remain unchanged in v1
- The fork should be described honestly as a divergence from the current published Symphony spec
