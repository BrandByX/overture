# Fork Baseline Policy

Created: 2026-03-12

## Purpose

Capture the durable policy decisions that define the Overture fork baseline before the GitHub
Projects migration is implemented in runtime code.

## Public vs internal naming

- Public-facing repo and documentation identity is `Overture`.
- Internal runtime identifiers remain unchanged in v1:
  - `SymphonyElixir`
  - `:symphony_elixir`
  - `./bin/symphony`

Full internal package and module renaming is intentionally out of scope for v1.

## Upstream policy

- Keep the `upstream` remote pointed at `openai/symphony`.
- Review upstream changes deliberately before merging or cherry-picking them into Overture.
- Prefer explicit follow-up issues for divergence work instead of silently drifting from upstream.

## Documentation policy

- Root `AGENTS.md` is the repository entrypoint and table of contents, not the encyclopedia.
- Durable design decisions belong in `docs/design-docs/`.
- Target runtime and tracker contract details belong in `docs/product-specs/`.
- Active sequencing and migration execution belong in `docs/exec-plans/active/`.
- When behavior or config changes, update the corresponding canonical docs in the same PR.

## Runtime baseline policy

- The current shipped Elixir runtime remains Linear-oriented in this baseline.
- GitHub Projects support is planned work and should not be implied as already implemented.
