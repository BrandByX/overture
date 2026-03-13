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

```text
AGENTS.md
ARCHITECTURE.md
OVERTURE_BASELINE.md
README.md
docs/
├── README.md
├── PLANS.md
├── design-docs/
│   ├── index.md
│   ├── fork-baseline-policy.md
│   ├── github-projects-fork.md
│   └── tracker-identity-and-routing.md
├── exec-plans/
│   └── active/
│       └── overture-github-projects-migration.md
└── product-specs/
    ├── index.md
    ├── current-runtime-baseline.md
    └── github-projects-runtime-contract.md
elixir/
├── AGENTS.md
└── WORKFLOW.md
```

## Repo-wide rules

- Treat `Overture` as the public-facing repo and product name.
- Keep internal v1 runtime identifiers unchanged unless a ticket explicitly widens scope.
- Update canonical docs in the same change when behavior or config changes.
- Use `cd elixir && mise exec -- make all` for Elixir/runtime changes.
- Use `git diff --check` at minimum for docs-only changes.
