# Overture Plans

Created: 2026-03-12
Updated: 2026-04-17

## Program boards

- Delivery board: <https://github.com/orgs/BrandByX/projects/6>
- Sandbox board: <https://github.com/orgs/BrandByX/projects/5>
- Live board metadata: `references/github-projects-board-metadata.md`

## Active execution plans

- `exec-plans/active/overture-github-projects-migration.md`
- `exec-plans/active/overture-upstream-sync-round-1/overture-upstream-sync-round-1.md`

## Upstream sync round 1

- Epic: `exec-plans/active/overture-upstream-sync-round-1/overture-upstream-sync-round-1.md`
- Workstream sequence:
  - `exec-plans/active/overture-upstream-sync-round-1/overture-upstream-sync-57-workflow-ref-pinning.md`
  - `exec-plans/active/overture-upstream-sync-round-1/overture-upstream-sync-50-codex-stream-parsing.md`
  - `exec-plans/active/overture-upstream-sync-round-1/overture-upstream-sync-54-single-host-retries.md`

## Delivery issues

- `#1` Fork Symphony and establish the Overture repo baseline
- `#2` Set up Overture Delivery and Sandbox GitHub Projects boards
- `#3` Replace Linear tracker config and issue model with GitHub Projects semantics
- `#4` Implement GitHub Projects polling, normalization, and tracker mutations
- `#5` Replace `linear_graphql` with `github_graphql` using shared tracker auth
- `#6` Rewrite Overture docs and runtime copy for GitHub Projects
- `#7` Rewrite Overture tests and fixtures for GitHub Projects
- `#8` Add GitHub Projects live smoke coverage and validate Overture end to end

## Planning notes

- Ticket `#1` establishes the public-facing fork and harness baseline.
- Ticket `#2` owns the GitHub Projects board contract, field semantics, and live metadata capture.
- Tickets `#3` through `#8` are the implementation sequence for the GitHub Projects runtime fork.
