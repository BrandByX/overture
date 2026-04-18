# Overture Upstream Sync Round 1

Created: 2026-04-17
Updated: 2026-04-17

## Goal

Bring over the first three post-fork upstream Symphony improvements that materially benefit
Overture without widening the scope of the GitHub Projects fork.

## Current state

- Overture forked from Symphony after upstream commit `ff65c7c`
- Overture has not yet absorbed upstream PRs `#57`, `#50`, or `#54`
- Overture already diverges heavily in tracker/runtime/docs, so upstream sync work must stay
  selective and intentional

## Target state

- GitHub Actions workflows use pinned external action SHAs
- Codex stderr noise no longer creates false malformed protocol events
- One worker run stays pinned to one SSH host, with retries owned by the orchestrator

## Workstream sequence

1. `#57` workflow ref pinning
   - `overture-upstream-sync-57-workflow-ref-pinning.md`
2. `#50` Codex stream parsing fix
   - `overture-upstream-sync-50-codex-stream-parsing.md`
3. `#54` single-host retries
   - `overture-upstream-sync-54-single-host-retries.md`

## Key constraints

- add no new workflow config, runtime config, or feature flag for this sync round
- preserve Overture's GitHub Projects tracker fork behavior and public docs posture
- prefer manual ports where Overture has already diverged from upstream implementation details
- keep the three workstreams independently implementable and reviewable

## Acceptance criteria

- all three child tickets can be implemented independently
- the docs point to the exact files and intended validation for each sync
- sequencing is explicit: `#57` first, then `#50`, then `#54`
- the epic remains additive and does not alter `overture-github-projects-migration.md`
