# Overture GitHub Projects Migration

Created: 2026-03-12

## Goal

Replace the current Linear-oriented Symphony baseline with a GitHub Projects-only Overture runtime
that can poll, execute, update, and validate issue-backed project items.

## Current state

- The repo is publicly branded as Overture
- The current Elixir runtime remains Linear-oriented
- GitHub Projects boards are already created and configured operationally
- The migration work is tracked on the Overture Delivery board

## Target state

- `tracker.kind: github_projects` is the only real production tracker kind
- runtime polling works against one configured board and one configured repository
- runnable work comes only from issue-backed project items
- PR-linked project items are skipped as tracker inputs
- project `Status` drives workflow eligibility
- linked issues carry comments and close/reopen semantics

## Workstream sequence

1. `#1` establish the fork and harness baseline
2. `#2` finalize board and field setup
3. `#3` replace tracker model and config contract
4. `#4` implement GitHub Projects polling and mutations
5. `#5` replace the dynamic tracker tool and unify auth
6. `#6` rewrite public docs, sample workflow, and runtime copy
7. `#7` rewrite tests, helpers, fixtures, and snapshots
8. `#8` add sandbox live smoke coverage

## Key constraints

- keep `issue.id` as canonical runtime identity
- keep `assigned_to_worker` as a derived normalized field
- reject `tracker.assignee: me` in v1
- require `tracker.status_field_name` to resolve to a `ProjectV2SingleSelectField`
- support one board and one repository at runtime in v1

## Acceptance criteria

- Overture no longer requires Linear for real tracker work
- GitHub Projects config and field validation are enforced at startup
- issue-backed project items are runnable
- PR-linked project items are non-runnable and skipped
- tracker comments and workflow state changes hit the correct GitHub objects
- docs, dashboard output, tests, and live smoke paths all match the GitHub Projects contract
