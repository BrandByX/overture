# Overture Baseline

Created: 2026-03-12
Updated: 2026-03-13

## Purpose

Document the initial Overture fork posture after the public rename and GitHub Projects runtime
cutover.

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
- The shipped Elixir runtime now uses GitHub Projects as its production tracker contract.
- Runnable tracker inputs are issue-backed project items only.
- PR-linked project items, draft items, archived items, and redacted items are non-runnable in v1.

## Upstream sync strategy

- Keep the `upstream` remote pointed at `openai/symphony`.
- Review upstream changes intentionally before merging or cherry-picking them into Overture.
- Prefer explicit follow-up issues for divergence work instead of silently drifting from upstream.

## Related work

Remaining GitHub Projects migration work is now focused on docs parity, test migration, and live
smoke coverage rather than on the core tracker cutover itself.

Canonical planning and design docs now live in:

- `AGENTS.md`
- `ARCHITECTURE.md`
- `docs/README.md`
