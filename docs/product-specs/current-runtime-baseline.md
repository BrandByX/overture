# Current Runtime Baseline

Created: 2026-03-12
Updated: 2026-03-13

## Purpose

Describe what the repository actually ships today so agents do not confuse the planned GitHub
Projects migration with the current implementation.

## Current shipped runtime

- The current implementation lives under `elixir/`.
- The shipped sample workflow is `elixir/WORKFLOW.md`.
- The runtime currently assumes GitHub Projects tracker semantics.
- The runtime currently assumes GitHub auth and GitHub issue/project item model semantics.
- The current dynamic tracker tool is `github_graphql`.

## Current repository posture

- The repository is publicly branded as Overture.
- GitHub Projects boards already exist operationally for the migration program.
- The codebase now ships a GitHub Projects-backed runtime baseline.

## Use this doc when

- deciding whether a change belongs to baseline cleanup or to the tracker migration
- checking whether a behavior is already shipped or only planned
- validating that public-facing docs do not overstate current runtime capability
