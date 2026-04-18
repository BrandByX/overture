# Known Issue: Baseline `make all` Fails on Pre-Existing Credo Findings

Created: 2026-04-17
Updated: 2026-04-17

## Summary

The current Overture baseline on `origin/main` does not pass the full Elixir quality gate
`cd elixir && mise exec -- make all`.

This failure is caused by pre-existing `credo --strict` findings in unrelated files. It does **not**
by itself mean the Overture runtime is broken or that ticket-scoped behavior changes are failing.

## Current impact

- the repo-wide `make all` gate is currently red on baseline `origin/main`
- ticket-scoped work can still have passing targeted tests while the full gate remains red
- engineers must distinguish between:
  - runtime behavior working
  - the repo's full lint and quality gate being green

## Evidence

- baseline checked: `origin/main` at `c2ae860`
- upstream checked: `upstream/main` at `9e89dd9`
- the failure reproduces on an isolated export of `origin/main`, so it is not caused by local
  in-flight ticket changes
- the current lint gate runs through `mix lint`, which includes `credo --strict`

## Failure shape

The reproduced baseline failure reports:

- 8 readability issues
- 17 refactoring opportunities

The flagged files include:

- `elixir/lib/symphony_elixir/github_projects/client.ex`
- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/test/support/test_support.exs`
- `elixir/test/support/live_smoke_support.exs`

Most of the findings are maintainability and style debt such as:

- long lines
- redundant `with` clauses
- `cond` blocks that Credo prefers to be `if`
- nested or complex functions

## What this does **not** mean

- it does not prove Overture does not run
- it does not prove current runtime behavior is broken
- it does not mean every ticket must fix the full repo-wide Credo backlog before it can be
  validated at the behavior level

## Recommended handling

For ticket-scoped work:

- run the targeted tests that cover the changed behavior
- run `git diff --check`
- report clearly when `make all` remains blocked by this known baseline issue

For repo maintenance:

- track a separate cleanup effort to restore a green baseline for `credo --strict`
- prioritize the higher-risk complexity hotspots in:
  - `github_projects/client.ex`
  - `config.ex`
  - `codex/dynamic_tool.ex`

## Reproduction

From a clean checkout of the current baseline:

```bash
cd elixir
mise exec -- make all
```

Expected current result:

- format check passes
- lint fails in `credo --strict` on pre-existing findings in the files listed above
