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
  @issue_title_prefix "Overture live smoke "
  @field_page_size 50
  @item_page_size 100
  @pull_request_page_size 20
  @marker_file_name "overture-live-smoke-marker.txt"
  @trace_file_name "overture-live-smoke.trace"
  @active_states ["Todo", "In Progress", "Human Review", "Rework", "Merging"]
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
    tracker = tracker()
    bootstrap = fetch_bootstrap!(tracker)
    cleanup_stale_issue_items!(tracker, bootstrap)
    run_id = Integer.to_string(System.unique_integer([:positive]))
    test_root = Path.join(System.tmp_dir!(), "overture-live-smoke-#{run_id}")
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, @trace_file_name)

    File.mkdir_p!(workspace_root)

    issue_fixture = create_issue_fixture!(tracker, bootstrap, run_id)
    pr_fixture = ensure_pr_fixture!(tracker, bootstrap)
    codex_binary = Path.join(test_root, "fake-codex")
    marker_content = "overture-live-smoke-run=#{run_id}"

    write_fake_codex!(
      codex_binary,
      trace_file,
      marker_content,
      issue_fixture,
      bootstrap.status_field,
      bootstrap.project_id
    )

    issue_identifier = "#{@repository}##{issue_fixture.number}"
    workspace_path = Path.join(workspace_root, safe_identifier(issue_identifier))
    marker_file = Path.join(workspace_path, @marker_file_name)

    %{
      run_id: run_id,
      tracker: tracker,
      test_root: test_root,
      trace_file: trace_file,
      workspace_root: workspace_root,
      workspace_path: workspace_path,
      marker_file: marker_file,
      marker_content: marker_content,
      codex_binary: codex_binary,
      bootstrap: bootstrap,
      issue: issue_fixture,
      pr_item: pr_fixture
    }
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
      poll_interval_ms: 30_000,
      max_turns: 1,
      prompt: live_smoke_prompt(context)
    ]
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
    repository_pull_requests = get_in(repository, ["pullRequests", "nodes"]) |> List.wrap()
    project_items = fetch_project_items!(tracker, project["id"])

    %{
      project_id: project["id"],
      repository_id: repository["id"],
      status_field: status_field,
      project_issue_items: project_issue_items(project_items),
      project_pull_request_items: project_pull_request_items(project_items),
      repository_pull_requests: repository_pull_requests
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
      issue_numbers =
        open_items
        |> Enum.map(&Integer.to_string(&1.number))
        |> Enum.join(", ")

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

  # Create a disposable issue and add it to the sandbox board.
  #
  # The issue-backed item is the runnable work item used by the smoke run and
  # is initialized in `Todo`.
  #
  # Returns issue fixture metadata.
  defp create_issue_fixture!(tracker, bootstrap, run_id) do
    title = "Overture live smoke #{run_id}"
    body = issue_body(run_id)

    issue_response =
      graphql!(tracker, @create_issue_mutation, %{repositoryId: bootstrap.repository_id, title: title, body: body}, operation_name: "OvertureLiveSmokeCreateIssue")

    issue = get_in(issue_response, ["data", "createIssue", "issue"]) || %{}
    item_id = add_project_item!(tracker, bootstrap.project_id, issue["id"])

    :ok =
      update_project_item_status!(
        tracker,
        bootstrap.project_id,
        item_id,
        bootstrap.status_field.id,
        bootstrap.status_field.option_ids_by_name["Todo"]
      )

    %{
      issue_id: issue["id"],
      item_id: item_id,
      number: issue["number"],
      url: issue["url"],
      identifier: "#{@repository}##{issue["number"]}",
      comment_marker: "Overture live smoke comment #{run_id}"
    }
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
  defp write_fake_codex!(path, trace_file, marker_content, issue_fixture, status_field, project_id) do
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

    done_call =
      Jason.encode!(%{
        "id" => 102,
        "method" => "item/tool/call",
        "params" => %{
          "name" => "github_graphql",
          "callId" => "call-live-smoke-done",
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
              "optionId" => status_field.option_ids_by_name["Done"]
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
          emit_json '#{done_call}'
          ;;
        6)
          emit_json '#{close_call}'
          ;;
        7)
          emit_json '#{completed_response}'
          exit 0
          ;;
        *)
          exit 0
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

  # Decide whether the smoke marker comment is present on the issue.
  #
  # Returns `true` or `false`.
  defp marker_comment_present?(issue_state, marker) when is_map(issue_state) and is_binary(marker) do
    issue_state.comments
    |> List.wrap()
    |> Enum.any?(&(&1 == marker))
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
