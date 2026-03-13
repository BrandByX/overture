# GitHub Projects Runtime Contract

Created: 2026-03-12

## Tracker config

The target runtime contract supports:

- `tracker.kind: github_projects`
- `tracker.api_key`
- `tracker.owner_type`
- `tracker.owner_login`
- `tracker.project_number`
- `tracker.repository`
- `tracker.status_field_name`
- `tracker.assignee`
- `tracker.active_states`
- `tracker.terminal_states`

## Defaults

- `tracker.api_key` resolves from `GITHUB_TOKEN` when omitted or set to `$GITHUB_TOKEN`
- `tracker.status_field_name` defaults to `Status`

## Validation rules

- `owner_type` must be `organization` or `user`
- `owner_login` is required
- `project_number` is required and numeric
- `repository` is required in `owner/repo` form
- `tracker.status_field_name` must resolve to a `ProjectV2SingleSelectField`
- all configured workflow states must exist as options on that field
- `tracker.assignee`, when present, must be an explicit GitHub login
- `tracker.assignee: me` must fail validation clearly

## Workflow field semantics

The `Status` field is the authoritative workflow field.

Target options:

- `Backlog`
- `Todo`
- `In Progress`
- `Human Review`
- `Rework`
- `Merging`
- `Done`
- `Cancelled`
- `Duplicate`

## Tracker mutations

The runtime writes to two different GitHub objects:

- comments go to the linked issue via `content_id`
- workflow state changes go to the project item via `id`

## Close reason mapping

- `Done` -> `COMPLETED`
- `Duplicate` -> `DUPLICATE`
- `Cancelled` -> `NOT_PLANNED`
- other terminal fallback -> `NOT_PLANNED`

## GraphQL requirements

The GitHub Projects fork should use GraphQL for:

- project lookup by owner and number
- project field lookup
- single-select option lookup
- project item pagination
- linked issue metadata reads
- `stateReason(enableDuplicate: true)` to preserve duplicate semantics
- mutations:
  - `addComment`
  - `updateProjectV2ItemFieldValue`
  - `closeIssue`
  - `reopenIssue`

## Auth contract

- `tracker.api_key` is the configured auth source
- `github_graphql` must use the same configured auth contract as polling and tracker mutations
- `GITHUB_TOKEN` is only the default resolution path, not a separate tool-only auth path
