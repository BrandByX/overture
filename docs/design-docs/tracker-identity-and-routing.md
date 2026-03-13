# Tracker Identity And Routing

Created: 2026-03-12

## Canonical runtime identity

Overture keeps the existing runtime identity pattern:

- `issue.id` remains the canonical runtime key

For the GitHub Projects fork, `issue.id` becomes:

- `ProjectV2Item.id`

The linked issue identity is stored separately:

- `content_id` = linked `Issue.id`
- `content_number` = linked issue number
- `content_state` = linked issue `OPEN` / `CLOSED`
- `content_state_reason` = linked issue close reason

## Routing model

The orchestrator should remain largely intact.

- `assigned_to_worker` remains on the normalized issue struct
- it is derived during GitHub item normalization
- assignee filtering does not move into the orchestrator in v1

## Assignee policy

V1 routing policy:

- no assignee filter means `assigned_to_worker = true`
- `tracker.assignee` must be an explicit GitHub login
- `tracker.assignee: me` is rejected in v1
- unassigned issues are non-routable when an assignee filter is active

## State reconciliation

The project `Status` field is the workflow source of truth.

The linked issue open/closed state is a consistency mirror.

Rules:

- active project status + closed issue:
  - attempt `reopenIssue` before dispatch
  - skip if reopen fails
- terminal project status + open issue:
  - treat as terminal immediately
  - best-effort close during reconciliation if needed
- missing or unknown project status:
  - skip and log

## Runnable vs non-runnable tracker inputs

Runnable:

- issue-backed project items from the configured repo
- visible, non-archived items

Non-runnable:

- PR-linked project items
- draft items
- redacted items
- wrong-repo items
