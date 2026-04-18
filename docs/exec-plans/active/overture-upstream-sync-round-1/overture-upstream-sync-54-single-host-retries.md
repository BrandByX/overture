# Overture Upstream Sync `#54`: Single-Host Retries

Created: 2026-04-17
Updated: 2026-04-17

## Goal

Port upstream Symphony PR `#54` so each Overture worker run stays pinned to one SSH host and lets
the orchestrator own retries between runs.

## Current state

- `AgentRunner` still has internal cross-host failover
- Overture orchestrator already owns retry scheduling and worker-host metadata
- a startup failure on one host can still fall through to another host inside the same run

## Target state

- each worker run is pinned to one selected host
- a startup failure on one host surfaces to the orchestrator instead of silently hopping hosts
- orchestrator retry ownership remains unchanged
- the selected `worker_host` is preserved in retry metadata and reused on retry dispatch
- existing preferred-host retry flow and per-host capacity behavior stay intact

## Implementation notes

- update `elixir/lib/symphony_elixir/agent_runner.ex` to remove the multi-host failover loop
- switch agent-run logging from host-list form to single-host form
- select exactly one worker host per run, matching the current orchestrator-selected host
- do not add a feature flag or alternate retry mode
- keep orchestrator retry ownership and current retry metadata flow unchanged
- preserve and verify the existing host-affinity chain in the orchestrator:
  - chosen `worker_host` is stored when the run is spawned
  - retry scheduling keeps that `worker_host` in retry metadata
  - retry dispatch uses that preserved `worker_host` as the preferred retry host
- add a regression in `elixir/test/symphony_elixir/core_test.exs` proving a startup failure on one
  SSH host does not silently fall through to a second host during the same run
- add an Overture-only follow-up note in `elixir/README.md` explaining that one run stays on one
  host and retries are orchestrator-driven

## Acceptance criteria

- one run never switches from host A to host B internally
- a failed startup surfaces back to the orchestrator retry path rather than hidden failover
- retry metadata preserves the selected `worker_host` and reuses it on retry dispatch
- existing host-capacity selection behavior remains green
- no new config surface is introduced

## Validation

Run:

```bash
cd elixir && mise exec -- mix test test/symphony_elixir/core_test.exs
cd elixir && mise exec -- make all
```
