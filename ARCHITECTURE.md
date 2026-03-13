# Overture Architecture

Created: 2026-03-12

## Purpose

Describe the current Overture baseline and the target architecture for the GitHub Projects fork.

## Current baseline

Overture currently ships the upstream Symphony Elixir implementation with limited repo-level fork
changes.

Current baseline facts:

- Public-facing repo identity is `Overture`
- Current implementation lives under `elixir/`
- Internal runtime identifiers remain unchanged in v1
- The shipped sample workflow in `elixir/WORKFLOW.md` is still Linear-oriented
- The runtime currently assumes Linear tracker semantics, tracker auth, and issue model
- GitHub Projects setup exists operationally in GitHub, but it is not yet implemented in runtime
  code

## Target architecture

The target v1 architecture is a GitHub Projects-only production fork.

Target properties:

- One configured GitHub Project v2 board at runtime
- One configured repository at runtime
- Runnable tracker inputs are issue-backed project items only
- The project `Status` field is the workflow source of truth
- Linked issue comments carry progress and handoff notes
- Terminal project states close the linked issue
- Re-entry into active states reopens the linked issue
- PR-linked project items are not runnable tracker inputs
- Draft items, archived items, redacted items, and wrong-repo items are skipped

## Architectural transition

The migration is intentionally staged.

1. Establish the fork identity and repo-level harness
2. Define the new tracker/config/model contract
3. Replace Linear polling and mutations with GitHub Projects equivalents
4. Replace dynamic tracker tooling and public docs
5. Rewrite tests and add live smoke coverage

## Key design constraints

- Keep `issue.id` as the canonical runtime identity
  - redefine it as `ProjectV2Item.id`
- Add linked issue identity separately via `content_id`
- Keep `assigned_to_worker` as a derived normalized field
- Reject `tracker.assignee: me` in v1
- Require the configured status field to be a `ProjectV2SingleSelectField`

## Canonical references

- `OVERTURE_BASELINE.md`
- `docs/design-docs/github-projects-fork.md`
- `docs/design-docs/tracker-identity-and-routing.md`
- `docs/product-specs/github-projects-runtime-contract.md`
- `docs/exec-plans/active/overture-github-projects-migration.md`
