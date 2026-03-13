# Overture Agents

Created: 2026-03-12

Start here when working in this repository.

## Read in this order

1. `README.md`
2. `OVERTURE_BASELINE.md`
3. `ARCHITECTURE.md`
4. `docs/README.md`
5. `docs/design-docs/index.md`
6. `docs/product-specs/index.md`
7. `docs/PLANS.md`
8. `elixir/AGENTS.md`
9. `elixir/WORKFLOW.md`

## Repository map

- `README.md`: public-facing repo overview
- `OVERTURE_BASELINE.md`: fork naming and upstream-sync policy
- `ARCHITECTURE.md`: current baseline and target GitHub Projects architecture
- `docs/`: canonical design docs, runtime contract docs, and active execution plans
- `elixir/`: current runtime implementation and implementation-specific guidance

## Repo-wide rules

- Treat `Overture` as the public-facing repo and product name.
- Keep internal v1 runtime identifiers unchanged unless a ticket explicitly widens scope.
- Update canonical docs in the same change when behavior or config changes.
- Use `cd elixir && mise exec -- make all` for Elixir/runtime changes.
- Use `git diff --check` at minimum for docs-only changes.
