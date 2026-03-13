# Overture Baseline

Created: 2026-03-12

## Purpose

Document the initial Overture fork posture before the GitHub Projects tracker migration lands.

## v1 naming policy

- Public-facing repo identity is `Overture`.
- Public-facing documentation should describe the project as BrandByX's fork of Symphony.
- Internal runtime identifiers remain unchanged in v1:
  - `SymphonyElixir`
  - `:symphony_elixir`
  - `./bin/symphony`

Full internal package and module renaming is intentionally out of scope for v1.

## Current behavior baseline

- The repository starts from the upstream Symphony codebase.
- The shipped Elixir runtime remains Linear-oriented in this baseline.
- GitHub Projects support is planned follow-on work and is not yet implemented here.

## Upstream sync strategy

- Keep the `upstream` remote pointed at `openai/symphony`.
- Review upstream changes intentionally before merging or cherry-picking them into Overture.
- Prefer explicit follow-up issues for divergence work instead of silently drifting from upstream.

## Related work

The GitHub Projects migration and broader Overture runtime changes are tracked in the repository
issue backlog rather than being folded into this baseline rename pass.

Canonical planning and design docs now live in:

- `AGENTS.md`
- `ARCHITECTURE.md`
- `docs/README.md`
