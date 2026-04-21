defmodule SymphonyElixir.LiveSmokeSupport do
  @moduledoc """
  Build and validate the GitHub Projects live smoke path for Overture.

  Uses the real `Overture Sandbox` board, creates disposable issue-backed
  tracker items, and prepares deterministic local Codex fixtures so the live
  smoke test can exercise the real orchestrator/runtime path.

  Returns context maps and assertion helpers for the live smoke test.
  """

  alias SymphonyElixir.GitHubProjects.Client

  @live_smoke_env "OVERTURE_LIVE_SMOKE"
  @github_token_env "GITHUB_TOKEN"
  @owner_login "BrandByX"
  @owner_type "organization"
  @repository "BrandByX/overture"
  @repository_name "overture"
  @project_number 5
  @status_field_name "Status"
  @priority_field_name "Priority"
  @issue_title_prefix "Overture live smoke "
  @field_page_size 50
  @item_page_size 100
  @pull_request_page_size 20
  @marker_file_name "overture-live-smoke-marker.txt"
  @trace_file_name "overture-live-smoke.trace"
  @active_states ["Todo", "In Progress", "Rework", "Merging"]
  @terminal_states ["Done", "Cancelled", "Duplicate"]
  @bootstrap_query """
  query OvertureLiveSmokeBootstrap(
    $ownerLogin: String!,
    $projectNumber: Int!,
    $repositoryName: String!,
    $fieldFirst: Int!,
    $pullRequestFirst: Int!
  ) {
    organization(login: $ownerLogin) {
      projectV2(number: $projectNumber) {
        id
        fields(first: $fieldFirst) {
          nodes {
            __typename
            ... on ProjectV2FieldCommon {
              id
              name
            }
            ... on ProjectV2Field {
              dataType
            }
            ... on ProjectV2SingleSelectField {
              options {
                id
                name
              }
            }
          }
        }
      }
    }
    repository(owner: $ownerLogin, name: $repositoryName) {
      id
      defaultBranchRef {
        name
        target {
          __typename
          ... on Commit {
            oid
          }
        }
      }
      pullRequests(first: $pullRequestFirst, orderBy: {field: UPDATED_AT, direction: DESC}) {
        nodes {
          id
          number
          url
          state
        }
      }
    }
  }
  """
  @project_items_query """
  query OvertureLiveSmokeProjectItems(
    $projectId: ID!,
    $statusFieldName: String!,
    $itemFirst: Int!,
    $after: String
  ) {
    node(id: $projectId) {
      ... on ProjectV2 {
        items(first: $itemFirst, after: $after) {
          nodes {
            id
            isArchived
            fieldValueByName(name: $statusFieldName) {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                optionId
              }
            }
            content {
              __typename
              ... on Issue {
                id
                number
                title
                url
                state
                stateReason(enableDuplicate: true)
              }
              ... on PullRequest {
                id
                number
                url
                state
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """
  @create_issue_mutation """
  mutation OvertureLiveSmokeCreateIssue($repositoryId: ID!, $title: String!, $body: String!) {
    createIssue(input: {repositoryId: $repositoryId, title: $title, body: $body}) {
      issue {
        id
        number
        url
      }
    }
  }
  """
  @add_project_item_mutation """
  mutation OvertureLiveSmokeAddProjectItem($projectId: ID!, $contentId: ID!) {
    addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
      item {
        id
      }
    }
  }
  """
  @update_status_mutation """
  mutation OvertureLiveSmokeUpdateStatus(
    $projectId: ID!,
    $itemId: ID!,
    $fieldId: ID!,
    $optionId: String!
  ) {
    updateProjectV2ItemFieldValue(
      input: {
        projectId: $projectId,
        itemId: $itemId,
        fieldId: $fieldId,
        value: {singleSelectOptionId: $optionId}
      }
    ) {
      projectV2Item {
        id
      }
    }
  }
  """
  @delete_project_item_mutation """
  mutation OvertureLiveSmokeDeleteProjectItem($projectId: ID!, $itemId: ID!) {
    deleteProjectV2Item(input: {projectId: $projectId, itemId: $itemId}) {
      deletedItemId
    }
  }
  """
  @add_blocker_mutation """
  mutation OvertureLiveSmokeAddBlockedBy($issueId: ID!, $blockingIssueId: ID!) {
    addBlockedBy(input: {issueId: $issueId, blockingIssueId: $blockingIssueId}) {
      issue {
        id
      }
    }
  }
  """
  @remove_blocker_mutation """
  mutation OvertureLiveSmokeRemoveBlockedBy($issueId: ID!, $blockingIssueId: ID!) {
    removeBlockedBy(input: {issueId: $issueId, blockingIssueId: $blockingIssueId}) {
      issue {
        id
      }
    }
  }
  """
  @update_number_field_mutation """
  mutation OvertureLiveSmokeUpdateNumberField(
    $projectId: ID!,
    $itemId: ID!,
    $fieldId: ID!,
    $number: Float!
  ) {
    updateProjectV2ItemFieldValue(
      input: {
        projectId: $projectId,
        itemId: $itemId,
        fieldId: $fieldId,
        value: {number: $number}
      }
    ) {
      projectV2Item {
        id
      }
    }
  }
  """
  @create_linked_branch_mutation """
  mutation OvertureLiveSmokeCreateLinkedBranch(
    $issueId: ID!,
    $repositoryId: ID!,
    $oid: GitObjectID!,
    $name: String!
  ) {
    createLinkedBranch(
      input: {issueId: $issueId, repositoryId: $repositoryId, oid: $oid, name: $name}
    ) {
      linkedBranch {
        id
        ref {
          id
          name
        }
      }
    }
  }
  """
  @delete_linked_branch_mutation """
  mutation OvertureLiveSmokeDeleteLinkedBranch($linkedBranchId: ID!) {
    deleteLinkedBranch(input: {linkedBranchId: $linkedBranchId}) {
      clientMutationId
    }
  }
  """
  @delete_ref_mutation """
  mutation OvertureLiveSmokeDeleteRef($refId: ID!) {
    deleteRef(input: {refId: $refId}) {
      clientMutationId
    }
  }
  """
  @close_issue_mutation """
  mutation OvertureLiveSmokeCloseIssue($issueId: ID!) {
    closeIssue(input: {issueId: $issueId, stateReason: COMPLETED}) {
      issue {
        id
        state
        stateReason(enableDuplicate: true)
      }
    }
  }
  """
  @issue_query """
  query OvertureLiveSmokeIssue(
    $ownerLogin: String!,
    $repositoryName: String!,
    $issueNumber: Int!
  ) {
    repository(owner: $ownerLogin, name: $repositoryName) {
      issue(number: $issueNumber) {
        id
        state
        stateReason(enableDuplicate: true)
        comments(last: 20) {
          nodes {
            body
          }
        }
      }
    }
  }
  """
  @issue_linked_branches_query """
  query OvertureLiveSmokeIssueLinkedBranches(
    $ownerLogin: String!,
    $repositoryName: String!,
    $issueNumber: Int!
  ) {
    repository(owner: $ownerLogin, name: $repositoryName) {
      issue(number: $issueNumber) {
        id
        linkedBranches(first: 20) {
          nodes {
            id
            ref {
              id
              name
            }
          }
        }
      }
    }
  }
  """
  @project_item_state_query """
  query OvertureLiveSmokeProjectItems($ids: [ID!]!, $statusFieldName: String!) {
    nodes(ids: $ids) {
      __typename
      ... on ProjectV2Item {
        id
        fieldValueByName(name: $statusFieldName) {
          __typename
          ... on ProjectV2ItemFieldSingleSelectValue {
            name
            optionId
          }
        }
      }
    }
  }
  """

  @doc """
  Return a skip reason when live smoke should not run.

  Requires an explicit opt-in plus a real `GITHUB_TOKEN`, because the live
  smoke path creates and mutates real sandbox tracker data.

  Returns a human-readable skip reason or `nil`.
  """
  @spec skip_reason() :: String.t() | nil
  def skip_reason do
    cond do
      not live_smoke_enabled?() ->
        "Set OVERTURE_LIVE_SMOKE=1 to run the GitHub Projects live smoke path."

      github_token() in [nil, ""] ->
        "Set GITHUB_TOKEN before running the GitHub Projects live smoke path."

      true ->
        nil
    end
  end

  @doc """
  Create disposable sandbox fixtures and local runtime inputs for live smoke.

  Creates a disposable issue-backed project item, ensures a PR-backed item is
  present for non-runnable coverage, writes the fake Codex binary, and returns
  workflow overrides plus cleanup metadata.

  Returns a context map with tracker, workspace, and fixture metadata.
  """
  @spec create_context!() :: map()
  def create_context! do
    runtime_context = create_runtime_context!()
    issue_fixture = create_issue_fixture!(runtime_context, run_id: runtime_context.run_id)
    pr_fixture = ensure_pr_fixture!(runtime_context.tracker, runtime_context.bootstrap)

    write_fake_codex!(
      runtime_context.codex_binary,
      runtime_context.trace_file,
      runtime_context.marker_content,
      issue_fixture,
      runtime_context.bootstrap.status_field,
      runtime_context.bootstrap.project_id
    )

    issue_identifier = "#{@repository}##{issue_fixture.number}"
    workspace_path = Path.join(runtime_context.workspace_root, safe_identifier(issue_identifier))
    marker_file = Path.join(workspace_path, @marker_file_name)

    Map.merge(runtime_context, %{
      workspace_path: workspace_path,
      marker_file: marker_file,
      issue: issue_fixture,
      pr_item: pr_fixture
    })
  end

  @doc """
  Create the reusable live smoke runtime context without tracker fixtures.

  Prepares the sandbox tracker metadata, temporary workspace root, and both the
  deterministic "complete work" fake Codex binary and a holding app-server
  binary used by blocker and priority smoke scenarios.

  Returns a context map with bootstrap metadata and local runtime paths.
  """
  @spec create_runtime_context!() :: map()
  def create_runtime_context! do
    tracker = tracker()
    bootstrap = fetch_bootstrap!(tracker)
    cleanup_stale_issue_items!(tracker, bootstrap)
    run_id = Integer.to_string(System.unique_integer([:positive]))
    test_root = Path.join(System.tmp_dir!(), "overture-live-smoke-#{run_id}")
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, @trace_file_name)

    File.mkdir_p!(workspace_root)

    codex_binary = Path.join(test_root, "fake-codex")
    hold_codex_binary = Path.join(test_root, "hold-codex")
    marker_content = "overture-live-smoke-run=#{run_id}"

    write_hold_codex!(hold_codex_binary, trace_file)

    %{
      run_id: run_id,
      tracker: tracker,
      test_root: test_root,
      trace_file: trace_file,
      workspace_root: workspace_root,
      marker_content: marker_content,
      codex_binary: codex_binary,
      hold_codex_binary: hold_codex_binary,
      bootstrap: bootstrap
    }
  end

  @doc """
  Write a deterministic fake Codex binary that moves one issue to one status.

  Uses the normal app-server protocol, leaves the standard marker comment, and
  updates the requested project status. Closing the linked issue is optional so
  smoke scenarios can model both handoff and terminal transitions.

  Returns `:ok`.
  """
  @spec write_status_codex!(map(), map(), String.t(), keyword()) :: :ok
  def write_status_codex!(context, issue_fixture, status_name, opts \\ [])
      when is_map(context) and is_map(issue_fixture) and is_binary(status_name) and is_list(opts) do
    close_issue? = Keyword.get(opts, :close_issue?, false)

    write_fake_codex!(
      context.codex_binary,
      context.trace_file,
      context.marker_content,
      issue_fixture,
      context.bootstrap.status_field,
      context.bootstrap.project_id,
      target_status_name: status_name,
      close_issue?: close_issue?
    )

    :ok
  end

  @doc """
  Remove the local temporary runtime assets for a live smoke context.

  Use this when a smoke scenario provisions its own tracker fixtures and only
  needs the temporary workspace root, trace file, and fake Codex binaries
  cleaned up afterward.

  Returns `:ok`.
  """
  @spec cleanup_runtime!(map()) :: :ok
  def cleanup_runtime!(context) when is_map(context) do
    File.rm_rf(context.test_root)
    :ok
  end

  @doc """
  Build workflow overrides for the live smoke runtime.

  Uses the real GitHub Projects tracker contract, a temporary workspace root,
  and the deterministic fake Codex binary that drives tracker writes during the
  smoke run.

  Returns workflow override keywords for `write_workflow_file!/2`.
  """
  @spec workflow_overrides(map()) :: keyword()
  def workflow_overrides(context) when is_map(context) do
    [
      tracker_api_token: "$#{@github_token_env}",
      tracker_owner_type: @owner_type,
      tracker_owner_login: @owner_login,
      tracker_project_number: @project_number,
      tracker_repository: @repository,
      tracker_status_field_name: @status_field_name,
      tracker_assignee: nil,
      tracker_active_states: @active_states,
      tracker_terminal_states: @terminal_states,
      workspace_root: context.workspace_root,
      codex_command: "#{shell_escape(context.codex_binary)} app-server",
      poll_interval_ms: 250,
      max_concurrent_agents: 1,
      max_turns: 1,
      prompt: live_smoke_prompt(context)
    ]
  end

  @doc """
  Verify the live GitHub schema contract before running smoke scenarios.

  Uses the configured workflow-backed client path so live smoke fails clearly
  when GitHub changes the read or close mutation schema Overture depends on.

  Returns `:ok`.
  """
  @spec verify_schema_contract!() :: :ok
  def verify_schema_contract! do
    case Client.verify_schema_contract() do
      :ok -> :ok
      {:error, reason} -> raise "Live smoke schema verification failed: #{inspect(reason)}"
    end
  end

  @doc """
  Create one disposable issue fixture for a live smoke scenario.

  Creates the repository issue, optionally adds it to the sandbox board, sets
  the requested workflow state, and optionally applies a numeric priority.

  Returns issue fixture metadata.
  """
  @spec create_issue_fixture!(map(), keyword()) :: map()
  def create_issue_fixture!(context, opts \\ []) when is_map(context) and is_list(opts) do
    run_id = Keyword.get(opts, :run_id, context.run_id)
    title_prefix = Keyword.get(opts, :title_prefix, @issue_title_prefix)
    status_name = Keyword.get(opts, :status_name, "Todo")
    add_to_project? = Keyword.get(opts, :add_to_project?, true)
    priority = Keyword.get(opts, :priority)
    title = String.trim("#{title_prefix} #{run_id}")
    body = Keyword.get(opts, :body, issue_body(run_id))
    comment_marker = Keyword.get(opts, :comment_marker, "Overture live smoke comment #{run_id}")

    issue_response =
      graphql!(
        context.tracker,
        @create_issue_mutation,
        %{repositoryId: context.bootstrap.repository_id, title: title, body: body},
        operation_name: "OvertureLiveSmokeCreateIssue"
      )

    issue = get_in(issue_response, ["data", "createIssue", "issue"]) || %{}

    item_id =
      if add_to_project? do
        add_project_item!(context.tracker, context.bootstrap.project_id, issue["id"])
      else
        nil
      end

    fixture = %{
      issue_id: issue["id"],
      item_id: item_id,
      number: issue["number"],
      url: issue["url"],
      identifier: "#{@repository}##{issue["number"]}",
      comment_marker: comment_marker
    }

    if is_binary(item_id) do
      :ok = set_issue_status!(context, fixture, status_name)
    end

    if not is_nil(priority) do
      :ok = set_issue_priority!(context, fixture, priority)
    end

    fixture
  end

  @doc """
  Remove one disposable issue fixture from the sandbox and repository.

  Closes the linked issue if needed and deletes the sandbox project item when
  the fixture was added to the board.

  Returns `:ok`.
  """
  @spec cleanup_issue_fixture!(map(), map()) :: :ok
  def cleanup_issue_fixture!(context, fixture) when is_map(context) and is_map(fixture) do
    maybe_close_issue(context.tracker, fixture.issue_id)
    maybe_delete_project_item(context.tracker, context.bootstrap.project_id, fixture.item_id)
    :ok
  end

  @doc """
  Update one issue-backed sandbox item to the requested workflow state.

  Requires the fixture to have a project item on the sandbox board.

  Returns `:ok`.
  """
  @spec set_issue_status!(map(), map(), String.t()) :: :ok
  def set_issue_status!(context, fixture, status_name)
      when is_map(context) and is_map(fixture) and is_binary(status_name) do
    option_id = context.bootstrap.status_field.option_ids_by_name[status_name]

    cond do
      not is_binary(fixture.item_id) ->
        raise "Live smoke issue fixture #{fixture.identifier} is not on the sandbox board."

      not is_binary(option_id) ->
        raise "Live smoke status option #{inspect(status_name)} was not found on the sandbox board."

      true ->
        update_project_item_status!(
          context.tracker,
          context.bootstrap.project_id,
          fixture.item_id,
          context.bootstrap.status_field.id,
          option_id
        )
    end
  end

  @doc """
  Update one issue-backed sandbox item to the requested numeric priority.

  Requires the sandbox board to expose the configured numeric `Priority` field.

  Returns `:ok`.
  """
  @spec set_issue_priority!(map(), map(), integer()) :: :ok
  def set_issue_priority!(context, fixture, priority)
      when is_map(context) and is_map(fixture) and is_integer(priority) do
    priority_field = require_priority_field!(context.bootstrap)

    if is_binary(fixture.item_id) do
      item_id = fixture.item_id

      response =
        graphql!(
          context.tracker,
          @update_number_field_mutation,
          %{
            projectId: context.bootstrap.project_id,
            itemId: item_id,
            fieldId: priority_field.id,
            number: priority * 1.0
          },
          operation_name: "OvertureLiveSmokeUpdateNumberField"
        )

      case get_in(response, ["data", "updateProjectV2ItemFieldValue", "projectV2Item", "id"]) do
        ^item_id -> :ok
        _ -> raise "Failed to update the live smoke numeric priority field."
      end
    else
      raise "Live smoke issue fixture #{fixture.identifier} is not on the sandbox board."
    end
  end

  @doc """
  Add one blocker dependency between two live smoke issues.

  The dependent and blocker are identified by their linked GitHub issue node
  IDs, not by project item IDs.

  Returns `:ok`.
  """
  @spec add_blocker!(map(), map(), map()) :: :ok
  def add_blocker!(context, dependent_fixture, blocker_fixture)
      when is_map(context) and is_map(dependent_fixture) and is_map(blocker_fixture) do
    response =
      graphql!(
        context.tracker,
        @add_blocker_mutation,
        %{issueId: dependent_fixture.issue_id, blockingIssueId: blocker_fixture.issue_id},
        operation_name: "OvertureLiveSmokeAddBlockedBy"
      )

    case get_in(response, ["data", "addBlockedBy", "issue", "id"]) do
      issue_id when issue_id == dependent_fixture.issue_id -> :ok
      _ -> raise "Failed to add the live smoke blocker relationship."
    end
  end

  @doc """
  Remove one blocker dependency between two live smoke issues.

  Returns `:ok`.
  """
  @spec remove_blocker!(map(), map(), map()) :: :ok
  def remove_blocker!(context, dependent_fixture, blocker_fixture)
      when is_map(context) and is_map(dependent_fixture) and is_map(blocker_fixture) do
    response =
      graphql!(
        context.tracker,
        @remove_blocker_mutation,
        %{issueId: dependent_fixture.issue_id, blockingIssueId: blocker_fixture.issue_id},
        operation_name: "OvertureLiveSmokeRemoveBlockedBy"
      )

    case get_in(response, ["data", "removeBlockedBy", "issue", "id"]) do
      issue_id when issue_id == dependent_fixture.issue_id -> :ok
      _ -> raise "Failed to remove the live smoke blocker relationship."
    end
  end

  @doc """
  Close one disposable live smoke issue.

  Uses the same close-reason semantics the runtime expects from GitHub.

  Returns `:ok`.
  """
  @spec close_issue!(map(), map()) :: :ok
  def close_issue!(context, fixture) when is_map(context) and is_map(fixture) do
    maybe_close_issue(context.tracker, fixture.issue_id)
  end

  @doc """
  Create one linked branch for the provided live smoke issue.

  Uses the sandbox repository default-branch commit OID as the base commit and
  returns the created linked-branch metadata needed for cleanup.

  Returns a map with linked-branch and ref IDs.
  """
  @spec create_linked_branch!(map(), map(), String.t()) :: map()
  def create_linked_branch!(context, fixture, branch_name)
      when is_map(context) and is_map(fixture) and is_binary(branch_name) do
    base_oid = require_default_branch_oid!(context.bootstrap)

    response =
      graphql!(
        context.tracker,
        @create_linked_branch_mutation,
        %{
          issueId: fixture.issue_id,
          repositoryId: context.bootstrap.repository_id,
          oid: base_oid,
          name: branch_name
        },
        operation_name: "OvertureLiveSmokeCreateLinkedBranch"
      )

    case get_in(response, ["data", "createLinkedBranch", "linkedBranch"]) do
      %{"id" => linked_branch_id} = linked_branch when is_binary(linked_branch_id) ->
        %{
          linked_branch_id: linked_branch_id,
          ref_id: get_in(linked_branch, ["ref", "id"]),
          ref_name: get_in(linked_branch, ["ref", "name"])
        }

      _ ->
        raise "Failed to create the live smoke linked branch."
    end
  end

  @doc """
  Refetch the linked branches for one live smoke issue.

  Use this when GitHub omits branch ref IDs in the create mutation response and
  cleanup needs concrete `linkedBranch.id` and `ref.id` values.

  Returns a list of linked-branch metadata maps.
  """
  @spec refetch_linked_branches!(map(), map()) :: [map()]
  def refetch_linked_branches!(context, fixture) when is_map(context) and is_map(fixture) do
    response =
      graphql!(
        context.tracker,
        @issue_linked_branches_query,
        %{
          ownerLogin: @owner_login,
          repositoryName: @repository_name,
          issueNumber: fixture.number
        },
        operation_name: "OvertureLiveSmokeIssueLinkedBranches"
      )

    response
    |> get_in(["data", "repository", "issue", "linkedBranches", "nodes"])
    |> List.wrap()
    |> Enum.map(fn linked_branch ->
      %{
        linked_branch_id: linked_branch["id"],
        ref_id: get_in(linked_branch, ["ref", "id"]),
        ref_name: get_in(linked_branch, ["ref", "name"])
      }
    end)
  end

  @doc """
  Remove one linked branch from both the issue and the repository.

  Unlinks the branch from the issue first, then deletes the underlying Git
  ref. If the ref ID is unavailable, callers should refetch linked branches
  before cleanup.

  Returns `:ok`.
  """
  @spec cleanup_linked_branch!(map(), map()) :: :ok
  def cleanup_linked_branch!(context, linked_branch)
      when is_map(context) and is_map(linked_branch) do
    delete_linked_branch!(context.tracker, linked_branch.linked_branch_id)

    case linked_branch.ref_id do
      ref_id when is_binary(ref_id) ->
        delete_ref!(context.tracker, ref_id)

      _ ->
        raise "Live smoke linked branch cleanup requires a repository ref ID."
    end
  end

  @doc """
  Fetch the live sandbox candidate issues through the production tracker client.

  Uses the current workflow-backed configuration so smoke assertions exercise
  the same normalization path as the runtime poller.

  Returns the normalized issue list.
  """
  @spec fetch_candidate_issues!() :: [map()]
  def fetch_candidate_issues! do
    case Client.fetch_candidate_issues() do
      {:ok, issues} -> issues
      {:error, reason} -> raise "Live smoke candidate fetch failed: #{inspect(reason)}"
    end
  end

  @doc """
  Wait until the orchestrator claims one specific project item.

  Polls the in-memory orchestrator state and returns the claimed item ID once
  the requested issue enters the running set.

  Returns the claimed project item ID.
  """
  @spec wait_for_claimed_issue!(pid(), String.t(), keyword()) :: String.t()
  def wait_for_claimed_issue!(orchestrator_pid, issue_id, opts \\ [])
      when is_pid(orchestrator_pid) and is_binary(issue_id) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    interval_ms = Keyword.get(opts, :interval_ms, 100)

    wait_until!(
      fn ->
        state = :sys.get_state(orchestrator_pid)

        cond do
          Map.has_key?(state.running, issue_id) -> issue_id
          MapSet.member?(state.claimed, issue_id) -> issue_id
          true -> false
        end
      end,
      timeout_ms,
      interval_ms,
      "Timed out waiting for the live smoke orchestrator to claim #{issue_id}."
    )
  end

  @doc """
  Assert that the orchestrator does not claim one project item for a duration.

  This is used by blocker smoke scenarios to prove the runtime kept the issue
  non-runnable until the blocker terminality changed.

  Returns `:ok`.
  """
  @spec assert_issue_unclaimed!(pid(), String.t(), keyword()) :: :ok
  def assert_issue_unclaimed!(orchestrator_pid, issue_id, opts \\ [])
      when is_pid(orchestrator_pid) and is_binary(issue_id) and is_list(opts) do
    duration_ms = Keyword.get(opts, :duration_ms, 1_500)
    interval_ms = Keyword.get(opts, :interval_ms, 100)
    started_at = System.monotonic_time(:millisecond)

    do_assert_issue_unclaimed!(orchestrator_pid, issue_id, started_at, duration_ms, interval_ms)
  end

  @doc """
  Wait until the live smoke run leaves behind the expected proofs.

  Polls the workspace and GitHub tracker state until the workspace marker,
  issue comment, issue close, and project state transition all appear.

  Returns a map describing the observed tracker and workspace state.
  """
  @spec wait_for_run_proof!(map(), keyword()) :: map()
  def wait_for_run_proof!(context, opts \\ []) when is_map(context) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    interval_ms = Keyword.get(opts, :interval_ms, 250)

    wait_until!(
      fn ->
        issue_state = issue_state(context)
        item_state = project_item_state(context, context.issue.item_id)

        if File.exists?(context.marker_file) and
             marker_comment_present?(issue_state, context.issue.comment_marker) and
             issue_state.state == "CLOSED" and
             issue_state.state_reason == "COMPLETED" and
             item_state == "Done" do
          %{
            marker_content: File.read!(context.marker_file),
            issue_state: issue_state,
            item_state: item_state
          }
        else
          false
        end
      end,
      timeout_ms,
      interval_ms,
      "Timed out waiting for the GitHub Projects live smoke proof."
    )
  end

  @doc """
  Wait until the orchestrator releases the live smoke issue claim.

  This proves the real retry/continuation path settled after the issue was
  moved into a terminal state during the smoke run.

  Returns `:ok`.
  """
  @spec wait_for_orchestrator_idle!(pid(), map(), keyword()) :: :ok
  def wait_for_orchestrator_idle!(orchestrator_pid, context, opts \\ [])
      when is_pid(orchestrator_pid) and is_map(context) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
    interval_ms = Keyword.get(opts, :interval_ms, 100)
    issue_id = context.issue.item_id

    wait_until!(
      fn ->
        state = :sys.get_state(orchestrator_pid)

        cond do
          Map.has_key?(state.running, issue_id) ->
            false

          MapSet.member?(state.claimed, issue_id) ->
            false

          Map.has_key?(state.retry_attempts, issue_id) ->
            false

          true ->
            :ok
        end
      end,
      timeout_ms,
      interval_ms,
      "Timed out waiting for the orchestrator to settle the live smoke issue."
    )

    :ok
  end

  @doc """
  Wait until one live smoke project item reaches one workflow state.

  Polls the live sandbox board until the target project item reports the
  requested status name. Use this to prove handoff states settle before making
  follow-on runtime assertions.

  Returns `:ok`.
  """
  @spec wait_for_project_item_state!(map(), String.t(), String.t(), keyword()) :: :ok
  def wait_for_project_item_state!(context, item_id, status_name, opts \\ [])
      when is_map(context) and is_binary(item_id) and is_binary(status_name) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    interval_ms = Keyword.get(opts, :interval_ms, 100)

    wait_until!(
      fn ->
        if project_item_state(context, item_id) == status_name do
          :ok
        else
          false
        end
      end,
      timeout_ms,
      interval_ms,
      "Timed out waiting for the live smoke item #{item_id} to reach #{status_name}."
    )

    :ok
  end

  @doc """
  Assert that the PR-linked project item stayed non-runnable.

  The smoke run should leave the PR-backed item in the same status it had
  during setup, which demonstrates that the poller skipped it as non-runnable.

  Returns the observed PR item state name.
  """
  @spec pr_item_state!(map()) :: String.t() | nil
  def pr_item_state!(context) when is_map(context) do
    project_item_state(context, context.pr_item.item_id)
  end

  @doc """
  Clean up live smoke fixtures and local temporary files.

  Closes the disposable issue if needed, removes project items from the sandbox
  board when this run created them, restores any reused PR item state, and
  deletes the temporary local test root.

  Returns `:ok`.
  """
  @spec cleanup!(map()) :: :ok
  def cleanup!(context) when is_map(context) do
    tracker = context.tracker

    maybe_close_issue(tracker, context.issue.issue_id)
    maybe_delete_project_item(tracker, context.bootstrap.project_id, context.issue.item_id)
    cleanup_pr_fixture!(tracker, context.bootstrap.project_id, context.pr_item)
    File.rm_rf(context.test_root)
    :ok
  end

  # Build the tracker map used by live smoke.
  #
  # Mirrors the real runtime contract so helper queries use the same auth and
  # board semantics as the production tracker client.
  #
  # Returns a tracker config map.
  defp tracker do
    %{
      kind: "github_projects",
      api_key: github_token(),
      owner_type: @owner_type,
      owner_login: @owner_login,
      project_number: @project_number,
      repository: @repository,
      status_field_name: @status_field_name,
      assignee: nil,
      active_states: @active_states,
      terminal_states: @terminal_states
    }
  end

  # Read the configured GitHub token from the environment.
  #
  # Returns the token string or `nil`.
  defp github_token do
    System.get_env(@github_token_env)
  end

  # Decide whether the operator explicitly enabled live smoke.
  #
  # Returns `true` or `false`.
  defp live_smoke_enabled? do
    System.get_env(@live_smoke_env) in ["1", "true", "TRUE", "yes", "YES"]
  end

  # Fetch the live sandbox board metadata required for the smoke run.
  #
  # Loads the project ID, repository ID, status field/option IDs, current
  # PR-backed board items, and candidate repository pull requests.
  #
  # Returns a metadata map.
  defp fetch_bootstrap!(tracker) do
    variables = %{
      ownerLogin: @owner_login,
      projectNumber: @project_number,
      repositoryName: @repository_name,
      fieldFirst: @field_page_size,
      pullRequestFirst: @pull_request_page_size
    }

    response =
      graphql!(tracker, @bootstrap_query, variables, operation_name: "OvertureLiveSmokeBootstrap")

    project = get_in(response, ["data", "organization", "projectV2"]) || %{}
    repository = get_in(response, ["data", "repository"]) || %{}
    status_field = project_status_field!(project)
    priority_field = project_priority_field(project)
    repository_pull_requests = get_in(repository, ["pullRequests", "nodes"]) |> List.wrap()
    project_items = fetch_project_items!(tracker, project["id"])
    default_branch_oid = get_in(repository, ["defaultBranchRef", "target", "oid"])
    default_branch_name = get_in(repository, ["defaultBranchRef", "name"])

    %{
      project_id: project["id"],
      repository_id: repository["id"],
      status_field: status_field,
      priority_field: priority_field,
      project_issue_items: project_issue_items(project_items),
      project_pull_request_items: project_pull_request_items(project_items),
      repository_pull_requests: repository_pull_requests,
      default_branch_oid: default_branch_oid,
      default_branch_name: default_branch_name
    }
  end

  # Delete leftover smoke issue-backed items from earlier interrupted runs.
  #
  # The live smoke contract expects one runnable issue-backed board item, so old
  # `Overture live smoke ...` issues and project items must be removed before
  # creating the next disposable fixture.
  #
  # Returns `:ok`.
  defp cleanup_stale_issue_items!(tracker, bootstrap) do
    {open_items, closed_items} =
      Enum.split_with(bootstrap.project_issue_items, fn item -> item.state == "OPEN" end)

    if open_items != [] do
      issue_numbers = Enum.map_join(open_items, ", ", &Integer.to_string(&1.number))

      raise "Another live smoke run is already active on the sandbox board (issues: #{issue_numbers})."
    end

    Enum.each(closed_items, fn item ->
      maybe_close_issue(tracker, item.issue_id)
      maybe_delete_project_item(tracker, bootstrap.project_id, item.item_id)
    end)

    :ok
  end

  # Fetch every project item from the sandbox board.
  #
  # Paginates the board item connection so the smoke helper can reason about
  # stale smoke issues and existing PR-backed items even on long-lived boards.
  #
  # Returns a list of raw project item maps.
  defp fetch_project_items!(tracker, project_id) when is_binary(project_id) do
    fetch_project_items_page!(tracker, project_id, nil, [])
  end

  # Continue paginating sandbox board items until the connection is exhausted.
  #
  # Returns a list of raw project item maps.
  defp fetch_project_items_page!(tracker, project_id, after_cursor, acc_items) do
    response =
      graphql!(
        tracker,
        @project_items_query,
        %{
          projectId: project_id,
          statusFieldName: @status_field_name,
          itemFirst: @item_page_size,
          after: after_cursor
        },
        operation_name: "OvertureLiveSmokeProjectItems"
      )

    items = get_in(response, ["data", "node", "items", "nodes"]) |> List.wrap()
    page_info = get_in(response, ["data", "node", "items", "pageInfo"]) || %{}
    updated_items = acc_items ++ items

    cond do
      page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) and page_info["endCursor"] != "" ->
        fetch_project_items_page!(tracker, project_id, page_info["endCursor"], updated_items)

      page_info["hasNextPage"] == true ->
        raise "Failed to continue paginating sandbox board items because endCursor was missing."

      true ->
        updated_items
    end
  end

  # Ensure a PR-backed item is present for non-runnable coverage.
  #
  # Prefers adding a repository PR that is not yet on the sandbox board so the
  # test can clean it up afterward without disturbing pre-existing board state.
  #
  # Returns PR item metadata.
  defp ensure_pr_fixture!(tracker, bootstrap) do
    existing_pr_content_ids =
      bootstrap.project_pull_request_items
      |> Enum.map(& &1.content_id)
      |> MapSet.new()

    case Enum.find(bootstrap.repository_pull_requests, fn pr ->
           not MapSet.member?(existing_pr_content_ids, pr["id"])
         end) do
      %{"id" => content_id, "number" => number, "url" => url} ->
        item_id = add_project_item!(tracker, bootstrap.project_id, content_id)

        :ok =
          update_project_item_status!(
            tracker,
            bootstrap.project_id,
            item_id,
            bootstrap.status_field.id,
            bootstrap.status_field.option_ids_by_name["Todo"]
          )

        %{
          item_id: item_id,
          content_id: content_id,
          number: number,
          url: url,
          created_for_smoke?: true,
          original_state: nil
        }

      nil ->
        use_existing_pr_item!(tracker, bootstrap)
    end
  end

  # Reuse an existing PR-backed sandbox item when no clean disposable PR exists.
  #
  # Records the original state so cleanup can restore it after the smoke run if
  # the test needs to move it into `Todo`.
  #
  # Returns PR item metadata.
  defp use_existing_pr_item!(tracker, bootstrap) do
    case List.first(bootstrap.project_pull_request_items) do
      %{item_id: item_id, content_id: content_id, state_name: state_name, number: number, url: url} ->
        if state_name != "Todo" do
          :ok =
            update_project_item_status!(
              tracker,
              bootstrap.project_id,
              item_id,
              bootstrap.status_field.id,
              bootstrap.status_field.option_ids_by_name["Todo"]
            )
        end

        %{
          item_id: item_id,
          content_id: content_id,
          number: number,
          url: url,
          created_for_smoke?: false,
          original_state: state_name
        }

      nil ->
        raise "Live smoke requires at least one repository pull request to build a PR-backed sandbox item."
    end
  end

  # Write the deterministic fake Codex binary used by live smoke.
  #
  # The fake binary still runs through the normal app-server protocol and uses
  # real `github_graphql` tool calls to comment on the issue and move the board
  # item into `Done`.
  #
  # Returns `:ok`.
  defp write_fake_codex!(path, trace_file, marker_content, issue_fixture, status_field, project_id, opts \\ []) do
    target_status_name = Keyword.get(opts, :target_status_name, "Done")
    close_issue? = Keyword.get(opts, :close_issue?, target_status_name == "Done")

    status_call_id =
      if target_status_name == "Done" and close_issue? do
        "call-live-smoke-done"
      else
        "call-live-smoke-status"
      end

    comment_call =
      Jason.encode!(%{
        "id" => 101,
        "method" => "item/tool/call",
        "params" => %{
          "name" => "github_graphql",
          "callId" => "call-live-smoke-comment",
          "threadId" => "thread-live-smoke",
          "turnId" => "turn-live-smoke",
          "arguments" => %{
            "query" => "mutation AddComment($issueId: ID!, $body: String!) { addComment(input: {subjectId: $issueId, body: $body}) { commentEdge { node { id } } } }",
            "operationName" => "AddComment",
            "variables" => %{
              "issueId" => issue_fixture.issue_id,
              "body" => issue_fixture.comment_marker
            }
          }
        }
      })

    status_call =
      Jason.encode!(%{
        "id" => 102,
        "method" => "item/tool/call",
        "params" => %{
          "name" => "github_graphql",
          "callId" => status_call_id,
          "threadId" => "thread-live-smoke",
          "turnId" => "turn-live-smoke",
          "arguments" => %{
            "query" =>
              "mutation UpdateStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) { updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: {singleSelectOptionId: $optionId}}) { projectV2Item { id } } }",
            "operationName" => "UpdateStatus",
            "variables" => %{
              "projectId" => project_id,
              "itemId" => issue_fixture.item_id,
              "fieldId" => status_field.id,
              "optionId" => status_field.option_ids_by_name[target_status_name]
            }
          }
        }
      })

    close_call =
      Jason.encode!(%{
        "id" => 103,
        "method" => "item/tool/call",
        "params" => %{
          "name" => "github_graphql",
          "callId" => "call-live-smoke-close",
          "threadId" => "thread-live-smoke",
          "turnId" => "turn-live-smoke",
          "arguments" => %{
            "query" => "mutation CloseIssue($issueId: ID!) { closeIssue(input: {issueId: $issueId, stateReason: COMPLETED}) { issue { id state stateReason(enableDuplicate: true) } } }",
            "operationName" => "CloseIssue",
            "variables" => %{
              "issueId" => issue_fixture.issue_id
            }
          }
        }
      })

    initialize_response = Jason.encode!(%{"id" => 1, "result" => %{}})
    thread_response = Jason.encode!(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-live-smoke"}}})
    turn_response = Jason.encode!(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-live-smoke"}}})
    completed_response = Jason.encode!(%{"method" => "turn/completed"})

    script = """
    #!/bin/sh
    set -eu
    trace_file=#{shell_escape(trace_file)}
    marker_content=#{shell_escape(marker_content)}
    count=0

    emit_json() {
      printf 'STDOUT:%s\\n' "$1" >> "$trace_file"
      printf '%s\\n' "$1"
    }

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          emit_json '#{initialize_response}'
          ;;
        2)
          ;;
        3)
          emit_json '#{thread_response}'
          ;;
        4)
          emit_json '#{turn_response}'
          printf '%s\\n' "$marker_content" > #{@marker_file_name}
          emit_json '#{comment_call}'
          ;;
        5)
          emit_json '#{status_call}'
          ;;
    #{if close_issue? do
      """
            6)
              emit_json '#{close_call}'
              ;;
            7)
              emit_json '#{completed_response}'
              exit 0
              ;;
      """
    else
      """
            6)
              emit_json '#{completed_response}'
              exit 0
              ;;
      """
    end}
        *)
          exit 0
          ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  # Write a holding fake Codex binary that starts a turn and then waits.
  #
  # This variant is used by blocker and priority smoke scenarios that only need
  # the orchestrator to claim work deterministically without mutating tracker
  # state on their behalf.
  #
  # Returns `:ok`.
  defp write_hold_codex!(path, trace_file) do
    initialize_response = Jason.encode!(%{"id" => 1, "result" => %{}})
    thread_response = Jason.encode!(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-live-smoke-hold"}}})
    turn_response = Jason.encode!(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-live-smoke-hold"}}})

    script = """
    #!/bin/sh
    set -eu
    trace_file=#{shell_escape(trace_file)}
    count=0

    emit_json() {
      printf 'STDOUT:%s\\n' "$1" >> "$trace_file"
      printf '%s\\n' "$1"
    }

    trap 'exit 0' INT TERM

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          emit_json '#{initialize_response}'
          ;;
        2)
          ;;
        3)
          emit_json '#{thread_response}'
          ;;
        4)
          emit_json '#{turn_response}'
          printf 'PWD:%s\\n' "$PWD" >> "$trace_file"
          while :; do
            sleep 1
          done
          ;;
        *)
          while :; do
            sleep 1
          done
          ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  # Query the live issue snapshot used by smoke assertions.
  #
  # Returns a map with issue state, close reason, and recent comment bodies.
  defp issue_state(context) do
    response =
      graphql!(
        context.tracker,
        @issue_query,
        %{
          ownerLogin: @owner_login,
          repositoryName: @repository_name,
          issueNumber: context.issue.number
        },
        operation_name: "OvertureLiveSmokeIssue"
      )

    issue = get_in(response, ["data", "repository", "issue"]) || %{}

    %{
      state: issue["state"],
      state_reason: issue["stateReason"],
      comments: issue |> get_in(["comments", "nodes"]) |> List.wrap() |> Enum.map(&Map.get(&1, "body"))
    }
  end

  # Query the current workflow state for a project item.
  #
  # Returns the project item status name or `nil`.
  defp project_item_state(context, item_id) when is_binary(item_id) do
    response =
      graphql!(
        context.tracker,
        @project_item_state_query,
        %{ids: [item_id], statusFieldName: @status_field_name},
        operation_name: "OvertureLiveSmokeProjectItems"
      )

    response
    |> get_in(["data", "nodes"])
    |> List.wrap()
    |> List.first()
    |> case do
      %{"fieldValueByName" => %{"name" => state_name}} -> state_name
      _ -> nil
    end
  end

  # Add one content node to the sandbox project.
  #
  # Returns the created project item ID.
  defp add_project_item!(tracker, project_id, content_id) do
    response =
      graphql!(
        tracker,
        @add_project_item_mutation,
        %{projectId: project_id, contentId: content_id},
        operation_name: "OvertureLiveSmokeAddProjectItem"
      )

    response
    |> get_in(["data", "addProjectV2ItemById", "item", "id"])
    |> case do
      item_id when is_binary(item_id) and item_id != "" -> item_id
      _ -> raise "Failed to add the live smoke item to the sandbox board."
    end
  end

  # Update one sandbox project item to the requested single-select option.
  #
  # Returns `:ok`.
  defp update_project_item_status!(tracker, project_id, item_id, field_id, option_id) do
    response =
      graphql!(
        tracker,
        @update_status_mutation,
        %{projectId: project_id, itemId: item_id, fieldId: field_id, optionId: option_id},
        operation_name: "OvertureLiveSmokeUpdateStatus"
      )

    case get_in(response, ["data", "updateProjectV2ItemFieldValue", "projectV2Item", "id"]) do
      ^item_id -> :ok
      _ -> raise "Failed to update the live smoke project item status."
    end
  end

  # Delete one project item from the sandbox board.
  #
  # Returns `:ok`.
  defp delete_project_item!(tracker, project_id, item_id) do
    response =
      graphql!(
        tracker,
        @delete_project_item_mutation,
        %{projectId: project_id, itemId: item_id},
        operation_name: "OvertureLiveSmokeDeleteProjectItem"
      )

    case get_in(response, ["data", "deleteProjectV2Item", "deletedItemId"]) do
      ^item_id -> :ok
      _ -> raise "Failed to delete the live smoke project item from the sandbox board."
    end
  end

  # Close the disposable live smoke issue if it is still open.
  #
  # Returns `:ok`.
  defp maybe_close_issue(_tracker, nil), do: :ok

  defp maybe_close_issue(tracker, issue_id) do
    _response =
      graphql!(
        tracker,
        @close_issue_mutation,
        %{issueId: issue_id},
        operation_name: "OvertureLiveSmokeCloseIssue"
      )

    :ok
  rescue
    _error -> :ok
  end

  # Delete a project item when this run owns it.
  #
  # Returns `:ok`.
  defp maybe_delete_project_item(_tracker, _project_id, nil), do: :ok

  defp maybe_delete_project_item(tracker, project_id, item_id) do
    delete_project_item!(tracker, project_id, item_id)
  rescue
    _error -> :ok
  end

  # Clean up the PR-backed sandbox fixture according to how it was provisioned.
  #
  # Returns `:ok`.
  defp cleanup_pr_fixture!(_tracker, _project_id, %{created_for_smoke?: false, original_state: nil}), do: :ok

  defp cleanup_pr_fixture!(tracker, project_id, %{created_for_smoke?: true, item_id: item_id}) do
    maybe_delete_project_item(tracker, project_id, item_id)
  end

  defp cleanup_pr_fixture!(
         tracker,
         project_id,
         %{created_for_smoke?: false, item_id: item_id, original_state: original_state}
       )
       when is_binary(original_state) do
    tracker
    |> fetch_bootstrap!()
    |> then(fn bootstrap ->
      option_id = bootstrap.status_field.option_ids_by_name[original_state]

      if is_binary(option_id) do
        update_project_item_status!(tracker, project_id, item_id, bootstrap.status_field.id, option_id)
      end
    end)

    :ok
  rescue
    _error -> :ok
  end

  # Extract the live `Status` field metadata from the sandbox project contract.
  #
  # Returns a map with the field ID and option-ID lookup.
  defp project_status_field!(project) do
    field =
      project
      |> get_in(["fields", "nodes"])
      |> List.wrap()
      |> Enum.find(fn
        %{"name" => @status_field_name, "__typename" => "ProjectV2SingleSelectField"} -> true
        _field -> false
      end)

    case field do
      %{"id" => field_id, "options" => options} ->
        %{
          id: field_id,
          option_ids_by_name:
            Enum.reduce(options, %{}, fn option, acc ->
              case {option["name"], option["id"]} do
                {name, option_id} when is_binary(name) and is_binary(option_id) ->
                  Map.put(acc, name, option_id)

                _ ->
                  acc
              end
            end)
        }

      _ ->
        raise "Failed to resolve the live smoke Status field metadata."
    end
  end

  # Extract the optional numeric `Priority` field metadata from the sandbox board.
  #
  # Returns a priority field map or `nil` when the board does not expose the
  # numeric field used by the priority smoke scenario.
  defp project_priority_field(project) do
    project
    |> get_in(["fields", "nodes"])
    |> List.wrap()
    |> Enum.find(fn
      %{"name" => @priority_field_name, "__typename" => "ProjectV2Field", "dataType" => "NUMBER"} -> true
      _field -> false
    end)
    |> case do
      %{"id" => field_id, "name" => field_name} when is_binary(field_id) and is_binary(field_name) ->
        %{
          id: field_id,
          name: field_name,
          type: :number
        }

      _ ->
        nil
    end
  end

  # Extract PR-backed project items already present on the sandbox board.
  #
  # Returns a list of PR item metadata maps.
  defp project_pull_request_items(items) do
    items
    |> List.wrap()
    |> Enum.flat_map(fn
      %{
        "id" => item_id,
        "isArchived" => false,
        "content" => %{
          "__typename" => "PullRequest",
          "id" => content_id,
          "number" => number,
          "url" => url
        }
      } = item ->
        state_name =
          case Map.get(item, "fieldValueByName") do
            %{"name" => name} when is_binary(name) -> name
            _ -> nil
          end

        [
          %{
            item_id: item_id,
            content_id: content_id,
            number: number,
            url: url,
            state_name: state_name
          }
        ]

      _other ->
        []
    end)
  end

  # Extract issue-backed project items created by previous smoke runs.
  #
  # Only items with the disposable smoke title prefix are returned so the helper
  # does not disturb unrelated sandbox issues already on the board.
  #
  # Returns a list of stale smoke issue item metadata maps.
  defp project_issue_items(items) do
    items
    |> List.wrap()
    |> Enum.flat_map(fn
      %{
        "id" => item_id,
        "isArchived" => false,
        "content" => %{
          "__typename" => "Issue",
          "id" => issue_id,
          "number" => number,
          "title" => title,
          "url" => url,
          "state" => state
        }
      } = item ->
        if String.starts_with?(title, @issue_title_prefix) do
          [
            %{
              item_id: item_id,
              issue_id: issue_id,
              number: number,
              title: title,
              url: url,
              state: state,
              project_state_name: project_state_name(item)
            }
          ]
        else
          []
        end

      _other ->
        []
    end)
  end

  # Extract the project workflow state from one sandbox item.
  #
  # Returns the single-select status name or `nil`.
  defp project_state_name(item) when is_map(item) do
    case Map.get(item, "fieldValueByName") do
      %{"name" => state_name} when is_binary(state_name) -> state_name
      _ -> nil
    end
  end

  # Require the sandbox board to expose the numeric `Priority` field.
  #
  # Returns the parsed priority field metadata or raises when the board is not
  # prepared for the priority smoke scenario.
  defp require_priority_field!(bootstrap) when is_map(bootstrap) do
    case Map.get(bootstrap, :priority_field) do
      %{id: field_id} = priority_field when is_binary(field_id) ->
        priority_field

      _ ->
        raise "Live smoke priority scenario requires a numeric #{@priority_field_name} field on the sandbox board."
    end
  end

  # Require the sandbox repository default branch OID for linked-branch smoke.
  #
  # Returns the commit OID string or raises when the bootstrap metadata is
  # incomplete.
  defp require_default_branch_oid!(bootstrap) when is_map(bootstrap) do
    case Map.get(bootstrap, :default_branch_oid) do
      oid when is_binary(oid) and oid != "" -> oid
      _ -> raise "Live smoke linked-branch scenario requires the sandbox repository default-branch commit OID."
    end
  end

  # Delete one linked branch from the GitHub issue linkage graph.
  #
  # Returns `:ok`.
  defp delete_linked_branch!(tracker, linked_branch_id) when is_binary(linked_branch_id) do
    _response =
      graphql!(
        tracker,
        @delete_linked_branch_mutation,
        %{linkedBranchId: linked_branch_id},
        operation_name: "OvertureLiveSmokeDeleteLinkedBranch"
      )

    :ok
  end

  # Delete one underlying Git ref after unlinking the branch from the issue.
  #
  # Returns `:ok`.
  defp delete_ref!(tracker, ref_id) when is_binary(ref_id) do
    _response =
      graphql!(
        tracker,
        @delete_ref_mutation,
        %{refId: ref_id},
        operation_name: "OvertureLiveSmokeDeleteRef"
      )

    :ok
  end

  # Decide whether the smoke marker comment is present on the issue.
  #
  # Returns `true` or `false`.
  defp marker_comment_present?(issue_state, marker) when is_map(issue_state) and is_binary(marker) do
    issue_state.comments
    |> List.wrap()
    |> Enum.any?(&(&1 == marker))
  end

  # Continue checking that the orchestrator has not claimed one project item.
  #
  # Returns `:ok` or raises if the issue becomes claimed before the deadline.
  defp do_assert_issue_unclaimed!(orchestrator_pid, issue_id, started_at, duration_ms, interval_ms) do
    state = :sys.get_state(orchestrator_pid)

    cond do
      Map.has_key?(state.running, issue_id) ->
        raise "Live smoke expected #{issue_id} to remain unclaimed, but it entered the running set."

      MapSet.member?(state.claimed, issue_id) ->
        raise "Live smoke expected #{issue_id} to remain unclaimed, but it entered the claimed set."

      System.monotonic_time(:millisecond) - started_at >= duration_ms ->
        :ok

      true ->
        Process.sleep(interval_ms)
        do_assert_issue_unclaimed!(orchestrator_pid, issue_id, started_at, duration_ms, interval_ms)
    end
  end

  # Wait until the provided function returns a truthy value.
  #
  # Polls on the requested interval and raises with the supplied message if the
  # condition does not become true before the timeout.
  #
  # Returns the truthy result.
  defp wait_until!(fun, timeout_ms, interval_ms, message)
       when is_function(fun, 0) and is_integer(timeout_ms) and is_integer(interval_ms) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_until(fun, started_at, timeout_ms, interval_ms, message)
  end

  # Continue polling a live smoke condition until timeout.
  #
  # Returns the condition result or raises on timeout.
  defp do_wait_until(fun, started_at, timeout_ms, interval_ms, message) do
    case fun.() do
      false ->
        if System.monotonic_time(:millisecond) - started_at >= timeout_ms do
          raise message
        else
          Process.sleep(interval_ms)
          do_wait_until(fun, started_at, timeout_ms, interval_ms, message)
        end

      nil ->
        if System.monotonic_time(:millisecond) - started_at >= timeout_ms do
          raise message
        else
          Process.sleep(interval_ms)
          do_wait_until(fun, started_at, timeout_ms, interval_ms, message)
        end

      result ->
        result
    end
  end

  # Execute a GitHub GraphQL operation and fail loudly on transport or GraphQL errors.
  #
  # Returns the decoded response map.
  defp graphql!(tracker, query, variables, opts) do
    case Client.graphql(query, variables,
           tracker: tracker,
           operation_name: Keyword.get(opts, :operation_name)
         ) do
      {:ok, %{"errors" => errors}} ->
        raise "Live smoke GitHub GraphQL errors: #{inspect(errors)}"

      {:ok, response} ->
        response

      {:error, reason} ->
        raise "Live smoke GitHub GraphQL request failed: #{inspect(reason)}"
    end
  end

  # Build the disposable issue body used by the live smoke fixture.
  #
  # Returns the issue body string.
  defp issue_body(run_id) do
    """
    Overture live smoke issue #{run_id}

    This issue was created by the opt-in GitHub Projects live smoke path.
    It should be closed and removed from the sandbox board during cleanup.
    """
  end

  # Build the smoke prompt used in the temporary workflow file.
  #
  # Returns the prompt string.
  defp live_smoke_prompt(context) do
    """
    Overture live smoke run #{context.run_id}

    Use the configured GitHub tracker tool path to leave a deterministic comment,
    move the issue-backed sandbox item into Done, and then finish the turn.
    """
  end

  # Normalize a tracker identifier into the workspace path-safe form used by `Workspace`.
  #
  # Returns the safe identifier string.
  defp safe_identifier(identifier) when is_binary(identifier) do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  # Shell-escape one command component for `codex.command`.
  #
  # Returns the escaped string.
  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
