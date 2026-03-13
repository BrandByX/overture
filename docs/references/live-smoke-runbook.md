# Overture Live Smoke Runbook

Created: 2026-03-13

## Purpose

Document the opt-in live smoke path that validates the real Overture runtime against the
`Overture Sandbox` GitHub Projects board.

This path is intentionally stronger than unit or adapter coverage:

- it starts the real Overture orchestrator during the test run
- it uses the real GitHub Projects board and live tracker auth
- it creates a disposable issue-backed project item
- it proves Overture can poll, claim, create a workspace, write a tracker comment, and transition
  tracker state
- it proves PR-linked project items remain non-runnable

## Prerequisites

Before running live smoke, make sure all of the following are true:

- `GITHUB_TOKEN` is set
- the token can:
  - read and write issues in `BrandByX/overture`
  - read and write GitHub Projects data for the `BrandByX` owner boards
- the local machine can create temporary workspaces under the test root
- the local machine can run the Overture Elixir test suite from `elixir/`

Important note:

- you do **not** need to start a separate long-lived `./bin/symphony` process manually
- the live smoke test itself starts the real Overture orchestrator during the ExUnit run

## Sandbox contract

The smoke path targets the board metadata recorded in:

- `github-projects-board-metadata.md`
- `../product-specs/github-projects-runtime-contract.md`

Concrete sandbox values:

- owner login: `BrandByX`
- owner type: `organization`
- repository: `BrandByX/overture`
- project number: `5`
- board name: `Overture Sandbox`
- workflow field: `Status`

## Opt-in environment gate

The smoke path is intentionally not part of the default fast test gate.

Required environment variable:

- `OVERTURE_LIVE_SMOKE=1`

If that variable is absent, the live smoke test is skipped with a clear message.

## Command

Run the smoke path from the Elixir implementation directory:

```bash
cd /Users/sidneyl/code/overture/elixir
export GITHUB_TOKEN=your_token_here
export OVERTURE_LIVE_SMOKE=1
mise exec -- mix test test/symphony_elixir/live_e2e_test.exs
```

## What the smoke path proves

The live smoke test creates a disposable GitHub issue, adds it to `Overture Sandbox`, and then
uses a deterministic fake Codex binary through the normal app-server/runtime path.

That setup proves:

- the real Overture orchestrator can poll the sandbox board
- the issue-backed project item is claimed and executed
- a real workspace is created for the issue
- a deterministic workspace marker file is written
- Overture can execute real `github_graphql` tool calls with the configured tracker auth
- the linked issue receives a real tracker comment
- the project item transitions to `Done`
- the linked issue is closed with the expected close reason
- a PR-linked project item can be present on the board without becoming runnable work

## Cleanup behavior

The default cleanup path is intentionally auditable.

After the smoke run, cleanup:

- closes the disposable issue if it is still open
- removes the disposable project item from `Overture Sandbox`
- removes any PR-backed fixture item created specifically for the smoke run
- restores reused PR-backed item state when needed
- removes the temporary local workspace root

Deletion is not the default cleanup behavior.

## What this path does not prove

The live smoke path does not try to validate every production concern.

It does not prove:

- multi-repo board behavior
- draft-item behavior
- PR-linked items as runnable work, which are intentionally unsupported
- dependency/blocker semantics
- GitHub App auth behavior

If those concerns need validation later, they should land as separate tickets.
