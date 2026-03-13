# Overture Repository Guide

Created: 2026-03-12

This repository is BrandByX's GitHub Projects-focused fork of Symphony.

The current shipped runtime still lives under `elixir/` and remains Linear-oriented while the
GitHub Projects migration is in progress.

## Source of truth

Use repository knowledge in this order:

1. `README.md` and `OVERTURE_BASELINE.md` for repo identity and fork posture
2. `ARCHITECTURE.md` for current and target system shape
3. `docs/design-docs/*` for durable design decisions
4. `docs/product-specs/*` for the intended GitHub Projects runtime contract
5. `docs/exec-plans/active/*` for active implementation sequencing
6. `elixir/AGENTS.md` and `elixir/WORKFLOW.md` for current Elixir runtime implementation details

## Repository map

- `README.md`: public-facing overview of Overture
- `OVERTURE_BASELINE.md`: fork naming and upstream-sync policy
- `ARCHITECTURE.md`: current baseline vs target GitHub Projects architecture
- `docs/`: canonical repo docs for the migration program
- `elixir/`: current implementation, sample workflow, tests, and implementation-specific docs
- `.codex/`: local automation/bootstrap helpers

## Working rules

- Treat `Overture` as the public-facing product and repo name.
- Keep internal v1 runtime identifiers unchanged unless a ticket explicitly widens scope:
  - `SymphonyElixir`
  - `:symphony_elixir`
  - `./bin/symphony`
- Preserve the `upstream` remote to `openai/symphony` and document deliberate divergence.
- When behavior or config changes, update the corresponding canonical docs in the same PR.
- The current production tracker path is still Linear-shaped until the GitHub Projects tickets land.
- The target v1 tracker model is GitHub Projects with issue-backed runnable items only.

## Validation

- For Elixir/runtime changes, run:
  - `cd elixir && mise exec -- make all`
- For docs-only changes, at minimum run:
  - `git diff --check`

## Related docs

- `ARCHITECTURE.md`
- `docs/README.md`
- `OVERTURE_BASELINE.md`
- `elixir/AGENTS.md`
