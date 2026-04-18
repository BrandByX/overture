# Overture Elixir

This directory contains the current Elixir/OTP implementation shipped in Overture, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Overture Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Overture Elixir screenshot](../.github/media/elixir-screenshot.png)

## v1 naming and scope

The fork now presents itself publicly as Overture, but the implementation remains intentionally
conservative in v1.

- Public-facing repo and docs use the Overture name.
- Internal runtime identifiers remain `SymphonyElixir`, `:symphony_elixir`, and `./bin/symphony`.
- The current Elixir implementation uses GitHub Projects as its real tracker contract while
  preserving upstream internal module/runtime naming.

## How it works

1. Polls a configured GitHub Projects v2 board for issue-backed work items in active states
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Overture also serves a client-side `github_graphql` tool so that repo
skills can make raw GitHub GraphQL calls using the same configured tracker auth as the poller.

If a claimed project item moves to a terminal state (`Done`, `Cancelled`, or `Duplicate`),
Overture stops the active agent for that issue and cleans up matching workspaces.

Important v1 tracker semantics:

- Runnable tracker inputs are issue-backed project items only.
- PR-linked project items, draft items, archived items, redacted items, and wrong-repo items are
  skipped by the poller.
- The project `Status` field is the workflow source of truth.
- `tracker.priority_field_name` is optional and may point to either a numeric GitHub Projects field
  or a single-select field with an explicit `tracker.priority_option_map`.
- Same-board blockers use project workflow state semantics; off-board blockers fall back to GitHub
  issue `OPEN` / `CLOSED`.
- `branch_name` is only populated when the linked issue has exactly one linked branch.
- `tracker.assignee` must be an explicit GitHub login when used.
- `tracker.assignee: me` is intentionally unsupported in v1.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Create a GitHub token with repository issue and project access, and make it available through
   `GITHUB_TOKEN` or an explicit `tracker.api_key` value in your workflow.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, and `land` skills to your repo.
   - Overture's tracker-native raw access now comes from the `github_graphql` app-server tool.
   - Do not treat any legacy tracker-specific skill from the upstream baseline as part of the
     supported Overture workflow.
5. Customize the copied `WORKFLOW.md` file for your project.
   - Set `tracker.owner_type`, `tracker.owner_login`, `tracker.project_number`, and
     `tracker.repository` to the board/repo you want Overture to manage.
   - Ensure `tracker.status_field_name` points to a GitHub Projects single-select field, usually
     `Status`.
   - If you want priority-aware dispatch, set `tracker.priority_field_name` to either:
     - a numeric GitHub Projects field with values `1..4`, or
     - a single-select field plus `tracker.priority_option_map`
   - Make the configured `active_states` and `terminal_states` match the options present on that
     field.
   - If you want assignee-based routing, set `tracker.assignee` to an explicit GitHub login.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/BrandByX/overture
cd overture/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Overture defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Overture to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: github_projects
  owner_type: organization
  owner_login: "your-org"
  project_number: 1
  repository: "your-org/your-repo"
  status_field_name: "Status"
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a tracked issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Overture passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Overture validation.
- `agent.max_turns` caps how many back-to-back Codex turns Overture will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Overture uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- When `worker.ssh_hosts` is configured, Overture keeps each agent run on one selected SSH host.
  If startup fails on that host, the orchestrator schedules the retry instead of silently hopping
  to another host during the same run.
- `tracker.api_key` reads from `GITHUB_TOKEN` when unset or when value is `$GITHUB_TOKEN`.
- `tracker.status_field_name` must resolve to a `ProjectV2SingleSelectField`.
- `tracker.priority_field_name` is optional:
  - numeric fields accept whole values `1..4`
  - single-select fields require `tracker.priority_option_map`
- `tracker.priority_option_map` is invalid unless `tracker.priority_field_name` points to a
  single-select field.
- `tracker.assignee: me` is rejected in v1; use an explicit GitHub login instead.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $GITHUB_TOKEN
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Overture does not boot.
- If a later reload fails, Overture keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

The supported quality gate today is `make all`.

GitHub Projects live smoke coverage now exists as an opt-in path rather than part of the default
fast test gate. Use:

- `make all` for the main implementation gate
- targeted ExUnit coverage for tracker/runtime changes
- the dedicated live smoke command when you need end-to-end confidence against a real project

### GitHub Projects live smoke

The live smoke path starts the real Overture orchestrator during the ExUnit run, uses the real
`Overture Sandbox` board, creates disposable issue-backed fixtures, and proves that Overture can:

- poll and claim a live issue-backed board item
- create a real workspace
- leave behind a deterministic workspace side effect
- comment on the linked GitHub issue
- transition the project item to `Done`
- ignore a PR-linked project item on the same board
- keep a same-board `Todo` issue blocked until its same-board blocker reaches `Done`
- keep a `Todo` issue blocked by an off-board blocker until that blocker closes
- dispatch a higher-priority runnable issue before a lower-priority one when only one slot is available
- keep `branch_name` as `nil` when a linked issue has multiple linked branches

Prerequisites:

- `GITHUB_TOKEN` must be set with issue and project write access for `BrandByX/overture`
- `OVERTURE_LIVE_SMOKE=1` must be set to opt into the live smoke path
- `Overture Sandbox` must include:
  - the documented `Status` field and `Backlog` holding state
  - a numeric `Priority` field for the priority-ordering scenario

Run it from this directory:

```bash
export GITHUB_TOKEN=your_token_here
export OVERTURE_LIVE_SMOKE=1
mise exec -- mix test test/symphony_elixir/live_e2e_test.exs
```

For the full operator contract and cleanup behavior, see:

- [`../docs/references/live-smoke-runbook.md`](../docs/references/live-smoke-runbook.md)

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Overture repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
