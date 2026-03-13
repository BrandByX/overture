# Current Runtime Baseline

Created: 2026-03-12

## Purpose

Describe what the repository actually ships today so agents do not confuse the planned GitHub
Projects migration with the current implementation.

## Current shipped runtime

- The current implementation lives under `elixir/`.
- The shipped sample workflow is `elixir/WORKFLOW.md`.
- The runtime currently assumes Linear tracker semantics.
- The runtime currently assumes Linear auth and issue model semantics.
- The current dynamic tracker tool is still `linear_graphql`.

## Current repository posture

- The repository is publicly branded as Overture.
- GitHub Projects boards already exist operationally for the migration program.
- The codebase has not yet replaced the runtime tracker implementation with GitHub Projects.

## Use this doc when

- deciding whether a change belongs to baseline cleanup or to the tracker migration
- checking whether a behavior is already shipped or only planned
- validating that public-facing docs do not overstate current runtime capability
