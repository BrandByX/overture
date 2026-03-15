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
- `tracker.priority_field_name`
- `tracker.priority_option_map`
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
- `tracker.priority_field_name`, when present, must resolve to either:
  - `ProjectV2Field` with `dataType == NUMBER`, or
  - `ProjectV2SingleSelectField`
- `tracker.priority_field_name` must not match `tracker.status_field_name`
- `tracker.priority_option_map` is invalid when `tracker.priority_field_name` is absent
- numeric priority fields must not use `tracker.priority_option_map`
- single-select priority fields require `tracker.priority_option_map`
- every configured priority option name must exist on the live priority field
- every configured priority value must be an integer in `1..4`
- `tracker.assignee`, when present, must be an explicit GitHub login
- `tracker.assignee: me` must fail validation clearly
- `tracker.active_states` must not include `Human Review`; it is a manual handoff state

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

Shipped workflow usage:

- active work states: `Todo`, `In Progress`, `Rework`, `Merging`
- manual handoff state: `Human Review`

Priority is optional and board-configured.

Supported priority models:

- numeric project field named by `tracker.priority_field_name`
- single-select project field named by `tracker.priority_field_name`, mapped through `tracker.priority_option_map`

If no priority field is configured, GitHub-backed issues continue to sort by `created_at` and identifier.

## Blocker semantics

GitHub blocker parity uses issue dependencies via `Issue.blockedBy`.

Blocker state normalization is explicit:

- blocker on the configured board with a readable `Status` field -> use the board workflow state
- blocker not on the configured board -> use GitHub-native `OPEN` or `CLOSED`
- blocker on the configured board with missing or unreadable status -> treat the dependent issue as a tracker data error and skip it

Dispatch behavior:

- `Todo` issues with non-terminal blockers are not dispatch-eligible
- same-board blockers become terminal when their board state matches configured terminal states
- off-board blockers become terminal when their GitHub state is `CLOSED`

## Branch metadata

GitHub branch metadata comes from `Issue.linkedBranches`.

Normalization rule:

- exactly one linked branch -> `branch_name`
- zero linked branches -> `nil`
- more than one linked branch -> `nil`

## Tracker mutations

The runtime writes to two different GitHub objects:

- comments go to the linked issue via `content_id`
- workflow state changes go to the project item via `id`

## Operations note

- GitHub issue and project mutations are attributed to whichever account owns
  the configured tracker token.
- Use a dedicated service account or GitHub App token when automation
  attribution must remain distinct from human operators.

## Close reason mapping

- `Done` -> `COMPLETED`
- `Duplicate` -> `DUPLICATE`
- `Cancelled` -> `NOT_PLANNED`
- other terminal fallback -> `NOT_PLANNED`

The live close mutation contract now uses `IssueClosedStateReason`, not `IssueStateReason`.

## GraphQL requirements

The GitHub Projects fork should use GraphQL for:

- project lookup by owner and number
- project field lookup
- single-select option lookup
- project item pagination
- linked issue metadata reads
- blocker dependency reads via `Issue.blockedBy`
- linked branch metadata via `Issue.linkedBranches`
- `stateReason(enableDuplicate: true)` behind one isolated helper so schema drift stays localized
- schema compatibility checks for:
  - `Issue.stateReason`
  - `CloseIssueInput.stateReason`
  - `IssueClosedStateReason`
- mutations:
  - `addComment`
  - `updateProjectV2ItemFieldValue`
  - `closeIssue`
  - `reopenIssue`

## Auth contract

- `tracker.api_key` is the configured auth source
- `github_graphql` must use the same configured auth contract as polling and tracker mutations
- `GITHUB_TOKEN` is only the default resolution path, not a separate tool-only auth path
