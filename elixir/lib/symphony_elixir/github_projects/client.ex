defmodule SymphonyElixir.GitHubProjects.Client do
  @moduledoc """
  Read and mutate GitHub Projects-backed tracker items.

  Uses GitHub GraphQL to load board metadata, poll issue-backed project items,
  reconcile linked issue state, and perform tracker writes.

  Returns normalized `%SymphonyElixir.Tracker.Issue{}` structs or tracker write results.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker.Issue

  @graphql_endpoint "https://api.github.com/graphql"
  @max_error_body_log_bytes 1_000
  @item_page_size 50
  @field_page_size 50
  @assignee_page_size 20
  @label_page_size 50
  @id_batch_size 50

  @project_contract_query """
  query OvertureProjectFieldContract(
    $ownerLogin: String!,
    $projectNumber: Int!,
    $fieldFirst: Int!,
    $after: String
  ) {
    organization(login: $ownerLogin) {
      projectV2(number: $projectNumber) {
        id
        fields(first: $fieldFirst, after: $after) {
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
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
    user(login: $ownerLogin) {
      projectV2(number: $projectNumber) {
        id
        fields(first: $fieldFirst, after: $after) {
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
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """

  @project_items_query """
  query OvertureProjectItems(
    $projectId: ID!,
    $statusFieldName: String!,
    $first: Int!,
    $after: String,
    $assigneeFirst: Int!,
    $labelFirst: Int!
  ) {
    node(id: $projectId) {
      ... on ProjectV2 {
        items(first: $first, after: $after) {
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
                body
                url
                state
                stateReason(enableDuplicate: true)
                repository {
                  nameWithOwner
                }
                assignees(first: $assigneeFirst) {
                  nodes {
                    login
                  }
                }
                labels(first: $labelFirst) {
                  nodes {
                    name
                  }
                }
                createdAt
                updatedAt
              }
              ... on PullRequest {
                id
              }
              ... on DraftIssue {
                title
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

  @project_items_by_id_query """
  query OvertureProjectItemsById(
    $ids: [ID!]!,
    $statusFieldName: String!,
    $assigneeFirst: Int!,
    $labelFirst: Int!
  ) {
    nodes(ids: $ids) {
      __typename
      ... on ProjectV2Item {
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
            body
            url
            state
            stateReason(enableDuplicate: true)
            repository {
              nameWithOwner
            }
            assignees(first: $assigneeFirst) {
              nodes {
                login
              }
            }
            labels(first: $labelFirst) {
              nodes {
                name
              }
            }
            createdAt
            updatedAt
          }
          ... on PullRequest {
            id
          }
          ... on DraftIssue {
            title
          }
        }
      }
    }
  }
  """

  @add_comment_mutation """
  mutation OvertureAddComment($contentId: ID!, $body: String!) {
    addComment(input: {subjectId: $contentId, body: $body}) {
      commentEdge {
        node {
          id
        }
      }
    }
  }
  """

  @update_state_mutation """
  mutation OvertureUpdateProjectState($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
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

  @close_issue_mutation """
  mutation OvertureCloseIssue($contentId: ID!, $stateReason: IssueStateReason!) {
    closeIssue(input: {issueId: $contentId, stateReason: $stateReason}) {
      issue {
        id
        state
        stateReason(enableDuplicate: true)
      }
    }
  }
  """

  @reopen_issue_mutation """
  mutation OvertureReopenIssue($contentId: ID!) {
    reopenIssue(input: {issueId: $contentId}) {
      issue {
        id
        state
        stateReason(enableDuplicate: true)
      }
    }
  }
  """

  @type request_fun :: (map(), [{binary(), binary()}] -> {:ok, %{status: integer(), body: map() | binary()}} | {:error, term()})

  @type project_contract :: %{
          project_id: String.t(),
          repository: String.t(),
          status_field: %{
            id: String.t(),
            name: String.t(),
            option_ids_by_name: %{optional(String.t()) => String.t()}
          }
        }

  @doc """
  Validate the GitHub Projects tracker configuration against live board metadata.

  Confirms the project exists, the configured workflow field is a single-select
  field, and every configured workflow state exists as an option on that field.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_tracker_config(term()) :: :ok | {:error, term()}
  def validate_tracker_config(tracker) do
    with :ok <- validate_owner_type(tracker.owner_type),
         :ok <- validate_repository(tracker.repository),
         {:ok, _contract} <- fetch_project_contract(tracker, &post_graphql_request/2) do
      :ok
    end
  end

  @doc """
  Fetch active issue-backed project items for dispatch.

  Uses the configured GitHub Projects tracker contract, normalizes issue-backed
  project items, applies assignee routing, and reconciles issue open state for
  active work items before they reach the orchestrator.

  Returns `{:ok, issues}` or `{:error, reason}`.
  """
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    fetch_candidate_issues_with_tracker(tracker, &post_graphql_request/2)
  end

  @doc false
  @spec fetch_candidate_issues_for_test(term(), request_fun()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_test(tracker, request_fun) when is_function(request_fun, 2) do
    fetch_candidate_issues_with_tracker(tracker, request_fun)
  end

  @doc """
  Fetch issue-backed project items whose board status matches the requested states.

  Uses the configured board contract and returns only issue-backed project items
  from the configured repository whose project status matches the given names.

  Returns `{:ok, issues}` or `{:error, reason}`.
  """
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker
    fetch_issues_by_states_with_tracker(tracker, state_names, &post_graphql_request/2)
  end

  @doc false
  @spec fetch_issues_by_states_for_test(term(), [String.t()], request_fun()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(tracker, state_names, request_fun)
      when is_list(state_names) and is_function(request_fun, 2) do
    fetch_issues_by_states_with_tracker(tracker, state_names, request_fun)
  end

  @doc """
  Refresh project item state for the requested project item IDs.

  Loads project items by their canonical `ProjectV2Item.id`, normalizes the
  linked issue state, and preserves the request order in the returned results.

  Returns `{:ok, issues}` or `{:error, reason}`.
  """
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker
    fetch_issue_states_by_ids_with_tracker(tracker, issue_ids, &post_graphql_request/2)
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test(term(), [String.t()], request_fun()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(tracker, issue_ids, request_fun)
      when is_list(issue_ids) and is_function(request_fun, 2) do
    fetch_issue_states_by_ids_with_tracker(tracker, issue_ids, request_fun)
  end

  @doc """
  Create a tracker comment on the linked GitHub issue.

  Uses the normalized issue's `content_id` so comments always land on the
  linked GitHub issue rather than the project item.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec create_comment(Issue.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(%Issue{} = issue, body) when is_binary(body) do
    tracker = Config.settings!().tracker
    create_comment_with_tracker(issue, body, tracker, &post_graphql_request/2)
  end

  @doc false
  @spec create_comment_for_test(Issue.t(), String.t(), term(), request_fun()) :: :ok | {:error, term()}
  def create_comment_for_test(%Issue{} = issue, body, tracker, request_fun)
      when is_binary(body) and is_function(request_fun, 2) do
    create_comment_with_tracker(issue, body, tracker, request_fun)
  end

  @doc """
  Update the project status for a normalized tracker issue.

  Resolves the configured project field option for the requested state, updates
  the project item, and then closes or reopens the linked issue when the target
  workflow state requires it.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec update_issue_state(Issue.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(%Issue{} = issue, state_name) when is_binary(state_name) do
    tracker = Config.settings!().tracker
    update_issue_state_with_tracker(issue, state_name, tracker, &post_graphql_request/2)
  end

  @doc false
  @spec update_issue_state_for_test(Issue.t(), String.t(), term(), request_fun()) ::
          :ok | {:error, term()}
  def update_issue_state_for_test(%Issue{} = issue, state_name, tracker, request_fun)
      when is_binary(state_name) and is_function(request_fun, 2) do
    update_issue_state_with_tracker(issue, state_name, tracker, request_fun)
  end

  @doc """
  Execute a GitHub GraphQL request using the configured tracker auth.

  Uses the same tracker auth contract as polling and tracker mutations. Test
  callers may provide an explicit tracker and request function override.

  Returns `{:ok, body}` or `{:error, reason}`.
  """
  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    tracker = Keyword.get(opts, :tracker, Config.settings!().tracker)
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(tracker),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "GitHub Projects GraphQL request failed status=#{response.status}" <>
            github_error_context(payload, response)
        )

        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub Projects GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  # Fetch candidate issues using the provided tracker settings.
  #
  # Resolves the board contract, then walks the configured board for issue-backed
  # items in active states.
  #
  # Returns `{:ok, issues}` or `{:error, reason}`.
  defp fetch_candidate_issues_with_tracker(tracker, request_fun) do
    with {:ok, assignee_filter} <- routing_assignee_filter(tracker.assignee),
         {:ok, contract} <- fetch_project_contract(tracker, request_fun) do
      fetch_project_items_by_states(tracker, contract, tracker.active_states, assignee_filter, request_fun)
    end
  end

  # Fetch issue-backed project items for the given states.
  #
  # Uses the same normalization path as candidate polling but omits assignee
  # filtering so terminal cleanup can see all matching issue-backed items.
  #
  # Returns `{:ok, issues}` or `{:error, reason}`.
  defp fetch_issues_by_states_with_tracker(tracker, state_names, request_fun) do
    normalized_state_names = normalize_state_names(state_names)

    case normalized_state_names do
      [] ->
        {:ok, []}

      _ ->
        with {:ok, contract} <- fetch_project_contract(tracker, request_fun) do
          fetch_project_items_by_states(tracker, contract, normalized_state_names, nil, request_fun)
        end
    end
  end

  # Refresh issue-backed project items by canonical project item IDs.
  #
  # Loads batches of project items by `ProjectV2Item.id`, applies normalization
  # and reconciliation, and preserves the requested order in the results.
  #
  # Returns `{:ok, issues}` or `{:error, reason}`.
  defp fetch_issue_states_by_ids_with_tracker(tracker, issue_ids, request_fun) do
    normalized_ids =
      issue_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case normalized_ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter(tracker.assignee),
             {:ok, contract} <- fetch_project_contract(tracker, request_fun) do
          ids
          |> Enum.chunk_every(@id_batch_size)
          |> Enum.reduce_while({:ok, []}, fn batch_ids, {:ok, acc_issues} ->
            case fetch_project_item_batch(batch_ids, tracker, contract, assignee_filter, request_fun) do
              {:ok, batch_issues} -> {:cont, {:ok, acc_issues ++ batch_issues}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
          |> sort_issue_batch(ids)
        end
    end
  end

  # Create a GitHub issue comment using the normalized issue content ID.
  #
  # Rejects issues without a linked issue node ID so the caller does not
  # accidentally comment against the project item identity.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp create_comment_with_tracker(%Issue{content_id: nil}, _body, _tracker, _request_fun) do
    {:error, :github_projects_missing_issue_content_id}
  end

  defp create_comment_with_tracker(%Issue{content_id: content_id}, body, tracker, request_fun) do
    variables = %{contentId: content_id, body: body}

    with {:ok, response} <-
           graphql(@add_comment_mutation, variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureAddComment"
           ),
         {:ok, comment_id} <- extract_comment_id(response) do
      if is_binary(comment_id) and comment_id != "" do
        :ok
      else
        {:error, :github_projects_comment_create_failed}
      end
    end
  end

  # Update the project status field and reconcile the linked issue state.
  #
  # Applies the project field update first, then mirrors the requested workflow
  # state onto the linked issue by closing or reopening it when required.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp update_issue_state_with_tracker(%Issue{} = issue, state_name, tracker, request_fun) do
    with {:ok, contract} <- fetch_project_contract(tracker, request_fun),
         {:ok, option_id} <- status_option_id(contract, state_name),
         :ok <- update_project_item_state(issue, contract, option_id, tracker, request_fun),
         :ok <- reconcile_issue_state_after_write(issue, state_name, tracker, request_fun) do
      :ok
    end
  end

  # Fetch and validate the board contract needed by polling and writes.
  #
  # Loads the configured project, verifies the workflow field type, and builds
  # an option lookup map for later project item writes.
  #
  # Returns `{:ok, contract}` or `{:error, reason}`.
  defp fetch_project_contract(tracker, request_fun) do
    with :ok <- validate_owner_type(tracker.owner_type),
         :ok <- validate_repository(tracker.repository),
         {:ok, project} <- fetch_project(tracker, request_fun),
         {:ok, field} <- find_status_field(project, tracker.status_field_name),
         :ok <- ensure_single_select_field(field, tracker.status_field_name),
         :ok <- ensure_state_options(field, tracker) do
      {:ok,
       %{
         project_id: project["id"],
         repository: tracker.repository,
         status_field: %{
           id: field["id"],
           name: field["name"],
           option_ids_by_name: status_option_ids(field)
         }
       }}
    end
  end

  # Fetch the configured project and field metadata.
  #
  # Uses the owner login and project number from tracker config so later item
  # queries can target the project by its node ID.
  #
  # Returns `{:ok, project_map}` or `{:error, reason}`.
  defp fetch_project(tracker, request_fun) do
    owner_field =
      case tracker.owner_type do
        "organization" -> "organization"
        "user" -> "user"
      end

    fetch_project_field_page(tracker, owner_field, nil, [], request_fun)
  end

  # Fetch one page of project field metadata and continue until the status field appears.
  #
  # Paginates the `ProjectV2.fields` connection so status field lookup remains
  # correct on boards with more fields than the initial page size.
  #
  # Returns `{:ok, project_map}` or `{:error, reason}`.
  defp fetch_project_field_page(tracker, owner_field, after_cursor, acc_fields, request_fun) do
    variables = %{
      ownerLogin: tracker.owner_login,
      projectNumber: tracker.project_number,
      fieldFirst: @field_page_size,
      after: after_cursor
    }

    with {:ok, response} <-
           graphql(@project_contract_query, variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureProjectFieldContract"
           ),
         {:ok, project, page_info} <- extract_project(response, owner_field) do
      updated_fields =
        acc_fields ++
          (project
           |> get_in(["fields", "nodes"])
           |> List.wrap())

      project = put_in(project, ["fields", "nodes"], updated_fields)

      cond do
        status_field_present?(updated_fields, tracker.status_field_name) ->
          {:ok, project}

        page_info.has_next_page == true and is_binary(page_info.end_cursor) and page_info.end_cursor != "" ->
          fetch_project_field_page(tracker, owner_field, page_info.end_cursor, updated_fields, request_fun)

        page_info.has_next_page == true ->
          {:error, :github_projects_missing_end_cursor}

        true ->
          {:ok, project}
      end
    end
  end

  # Fetch all project items whose workflow state matches the requested names.
  #
  # Pages through the configured board, normalizes issue-backed items, applies
  # state filtering locally, and skips non-runnable item types.
  #
  # Returns `{:ok, issues}` or `{:error, reason}`.
  defp fetch_project_items_by_states(tracker, contract, state_names, assignee_filter, request_fun) do
    requested_states = normalized_state_set(state_names)
    fetch_project_items_page(nil, tracker, contract, requested_states, assignee_filter, request_fun, [])
  end

  # Fetch one page of project items and accumulate normalized issues.
  #
  # Stops when the project has no next page and returns the collected issue list.
  #
  # Returns `{:ok, issues}` or `{:error, reason}`.
  defp fetch_project_items_page(after_cursor, tracker, contract, requested_states, assignee_filter, request_fun, acc_issues) do
    variables = %{
      projectId: contract.project_id,
      statusFieldName: contract.status_field.name,
      first: @item_page_size,
      after: after_cursor,
      assigneeFirst: @assignee_page_size,
      labelFirst: @label_page_size
    }

    with {:ok, response} <-
           graphql(@project_items_query, variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureProjectItems"
           ),
         {:ok, items, page_info} <- decode_project_items_page(response),
         {:ok, normalized_issues} <-
           normalize_project_items(items, tracker, contract, requested_states, assignee_filter, request_fun) do
      updated_acc = acc_issues ++ normalized_issues

      case page_info do
        %{has_next_page: true, end_cursor: end_cursor} when is_binary(end_cursor) and end_cursor != "" ->
          fetch_project_items_page(end_cursor, tracker, contract, requested_states, assignee_filter, request_fun, updated_acc)

        %{has_next_page: true} ->
          {:error, :github_projects_missing_end_cursor}

        _ ->
          {:ok, updated_acc}
      end
    end
  end

  # Fetch a batch of project items by project item ID.
  #
  # Uses GitHub's `nodes(ids:)` query so orchestrator refreshes can load project
  # item state directly from canonical runtime IDs.
  #
  # Returns `{:ok, issues}` or `{:error, reason}`.
  defp fetch_project_item_batch(ids, tracker, contract, assignee_filter, request_fun) do
    variables = %{
      ids: ids,
      statusFieldName: contract.status_field.name,
      assigneeFirst: @assignee_page_size,
      labelFirst: @label_page_size
    }

    with {:ok, response} <-
           graphql(@project_items_by_id_query, variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureProjectItemsById"
           ),
         {:ok, items} <- decode_project_item_batch(response),
         {:ok, normalized_issues} <-
           normalize_project_items(items, tracker, contract, nil, assignee_filter, request_fun) do
      {:ok, normalized_issues}
    end
  end

  # Normalize one page or batch of raw project items.
  #
  # Converts runnable issue-backed items into `%Issue{}` structs and skips
  # archived, PR-linked, draft, redacted, or wrong-repo items.
  #
  # Returns `{:ok, issues}` or `{:error, reason}`.
  defp normalize_project_items(items, tracker, contract, requested_states, assignee_filter, request_fun) do
    issues =
      items
      |> Enum.reduce([], fn item, acc ->
        case normalize_project_item(item, tracker, contract, assignee_filter, request_fun) do
          {:ok, %Issue{} = issue} ->
            if include_issue_state?(issue, requested_states) do
              [issue | acc]
            else
              acc
            end

          :skip ->
            acc
        end
      end)
      |> Enum.reverse()

    {:ok, issues}
  end

  # Normalize a single raw project item into a tracker issue.
  #
  # Builds the provider-neutral issue model and performs read-time reconciliation
  # for active and terminal workflow states.
  #
  # Returns `{:ok, issue}` or `:skip`.
  defp normalize_project_item(item, tracker, contract, assignee_filter, request_fun) when is_map(item) do
    with false <- Map.get(item, "isArchived", false),
         {:ok, state_name} <- project_item_state(item),
         {:ok, issue_content} <- issue_content(item),
         :ok <- ensure_issue_repository(issue_content, tracker.repository) do
      issue =
        build_issue(item, issue_content, state_name, assignee_filter)

      reconcile_issue_for_read(issue, tracker, contract, request_fun)
    else
      true -> :skip
      :skip -> :skip
      {:error, _reason} -> :skip
    end
  end

  defp normalize_project_item(_item, _tracker, _contract, _assignee_filter, _request_fun), do: :skip

  # Extract the workflow state from a project item field value.
  #
  # Only single-select status values are accepted as runnable workflow states.
  #
  # Returns `{:ok, state_name}` or `{:error, reason}`.
  defp project_item_state(item) do
    case Map.get(item, "fieldValueByName") do
      %{"__typename" => "ProjectV2ItemFieldSingleSelectValue", "name" => state_name}
      when is_binary(state_name) and state_name != "" ->
        {:ok, state_name}

      _ ->
        {:error, :missing_project_item_state}
    end
  end

  # Extract linked issue content and reject non-runnable item types.
  #
  # Only linked GitHub issues are accepted as runnable tracker inputs in v1.
  #
  # Returns `{:ok, issue_content}` or `:skip`.
  defp issue_content(item) do
    case Map.get(item, "content") do
      %{"__typename" => "Issue"} = content -> {:ok, content}
      %{"__typename" => "PullRequest"} -> :skip
      %{"__typename" => "DraftIssue"} -> :skip
      nil -> :skip
      _other -> :skip
    end
  end

  # Ensure the linked issue belongs to the configured repository.
  #
  # This keeps the runtime on the single configured repository support surface.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_issue_repository(issue_content, repository) do
    issue_repository =
      issue_content
      |> get_in(["repository", "nameWithOwner"])
      |> normalize_repository()

    if issue_repository == normalize_repository(repository) do
      :ok
    else
      {:error, :wrong_repository}
    end
  end

  # Build a provider-neutral tracker issue from a project item and linked issue.
  #
  # Preserves the project item ID as the canonical runtime identity and derives
  # assignee routing from normalized GitHub login values.
  #
  # Returns a `%Issue{}` struct.
  defp build_issue(item, issue_content, state_name, assignee_filter) do
    assignee_logins = extract_assignee_logins(issue_content)

    %Issue{
      id: Map.get(item, "id"),
      content_id: Map.get(issue_content, "id"),
      content_number: Map.get(issue_content, "number"),
      identifier: build_issue_identifier(issue_content),
      title: Map.get(issue_content, "title"),
      description: Map.get(issue_content, "body"),
      priority: nil,
      state: state_name,
      content_state: Map.get(issue_content, "state"),
      content_state_reason: Map.get(issue_content, "stateReason"),
      branch_name: nil,
      url: Map.get(issue_content, "url"),
      assignee_logins: assignee_logins,
      blocked_by: [],
      labels: extract_labels(issue_content),
      assigned_to_worker: assigned_to_worker?(assignee_logins, assignee_filter),
      created_at: parse_datetime(Map.get(issue_content, "createdAt")),
      updated_at: parse_datetime(Map.get(issue_content, "updatedAt"))
    }
  end

  # Reconcile linked issue state while reading project items.
  #
  # Active workflow states reopen closed linked issues before dispatch, while
  # terminal states best-effort close still-open linked issues.
  #
  # Returns `{:ok, issue}` or `:skip`.
  defp reconcile_issue_for_read(%Issue{} = issue, tracker, _contract, request_fun) do
    cond do
      active_issue_state?(issue.state, tracker) and issue.content_state == "CLOSED" and issue.assigned_to_worker ->
        case reopen_issue(issue, tracker, request_fun) do
          {:ok, reopened_issue} ->
            {:ok, reopened_issue}

          {:error, reason} ->
            Logger.warning("Skipping issue after reopen failure: issue_id=#{issue.id} identifier=#{issue.identifier} reason=#{inspect(reason)}")
            :skip
        end

      terminal_issue_state?(issue.state, tracker) and issue.content_state != "CLOSED" ->
        case close_issue(issue, issue.state, tracker, request_fun) do
          {:ok, closed_issue} ->
            {:ok, closed_issue}

          {:error, reason} ->
            Logger.warning("Keeping terminal issue after close failure: issue_id=#{issue.id} identifier=#{issue.identifier} reason=#{inspect(reason)}")
            {:ok, issue}
        end

      true ->
        {:ok, issue}
    end
  end

  # Update the project status field on a project item.
  #
  # Resolves the target option ID from the loaded board contract and applies the
  # single-select field mutation to the project item.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp update_project_item_state(issue, contract, option_id, tracker, request_fun) do
    variables = %{
      projectId: contract.project_id,
      itemId: issue.id,
      fieldId: contract.status_field.id,
      optionId: option_id
    }

    with {:ok, response} <-
           graphql(@update_state_mutation, variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureUpdateProjectState"
           ),
         {:ok, updated_item_id} <- extract_updated_item_id(response),
         true <- updated_item_id == issue.id do
      :ok
    else
      false ->
        {:error, :github_projects_issue_update_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Mirror the requested workflow state onto the linked GitHub issue.
  #
  # Closes issues for terminal workflow states and reopens issues for active
  # workflow states when the linked issue is currently closed.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp reconcile_issue_state_after_write(%Issue{} = issue, state_name, tracker, request_fun) do
    cond do
      terminal_issue_state?(state_name, tracker) and issue.content_state != "CLOSED" ->
        case close_issue(issue, state_name, tracker, request_fun) do
          {:ok, _issue} -> :ok
          {:error, reason} -> {:error, reason}
        end

      active_issue_state?(state_name, tracker) and issue.content_state == "CLOSED" ->
        case reopen_issue(issue, tracker, request_fun) do
          {:ok, _issue} -> :ok
          {:error, reason} -> {:error, reason}
        end

      true ->
        :ok
    end
  end

  # Reopen a linked GitHub issue and update the normalized issue snapshot.
  #
  # Uses the linked issue node ID and returns an updated issue struct on success.
  #
  # Returns `{:ok, issue}` or `{:error, reason}`.
  defp reopen_issue(%Issue{content_id: nil}, _tracker, _request_fun) do
    {:error, :github_projects_missing_issue_content_id}
  end

  defp reopen_issue(%Issue{} = issue, tracker, request_fun) do
    variables = %{contentId: issue.content_id}

    with {:ok, response} <-
           graphql(@reopen_issue_mutation, variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureReopenIssue"
           ),
         {:ok, _issue_id} <- extract_reopened_issue_id(response) do
      reopened_issue = %{issue | content_state: "OPEN", content_state_reason: nil}
      {:ok, reopened_issue}
    end
  end

  # Close a linked GitHub issue using the workflow-state close reason mapping.
  #
  # Uses deterministic close reasons so terminal workflow semantics round-trip
  # cleanly through GitHub's issue state reason field.
  #
  # Returns `{:ok, issue}` or `{:error, reason}`.
  defp close_issue(%Issue{content_id: nil}, _state_name, _tracker, _request_fun) do
    {:error, :github_projects_missing_issue_content_id}
  end

  defp close_issue(%Issue{} = issue, state_name, tracker, request_fun) do
    state_reason = close_reason_for_state(state_name)
    variables = %{contentId: issue.content_id, stateReason: state_reason}

    with {:ok, response} <-
           graphql(@close_issue_mutation, variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureCloseIssue"
           ),
         {:ok, _issue_id} <- extract_closed_issue_id(response) do
      closed_issue = %{issue | content_state: "CLOSED", content_state_reason: state_reason}
      {:ok, closed_issue}
    end
  end

  # Decode one page of project items from GitHub GraphQL.
  #
  # Extracts the raw item nodes and pagination metadata or returns a GraphQL
  # error tuple when GitHub returns an error payload.
  #
  # Returns `{:ok, items, page_info}` or `{:error, reason}`.
  defp decode_project_items_page(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp decode_project_items_page(%{"data" => %{"node" => %{"items" => %{"nodes" => nodes, "pageInfo" => page_info}}}}) do
    {:ok, List.wrap(nodes), %{has_next_page: page_info["hasNextPage"] == true, end_cursor: page_info["endCursor"]}}
  end

  defp decode_project_items_page(_response), do: {:error, :github_projects_unknown_payload}

  # Decode a batch lookup by project item IDs.
  #
  # Filters the nodes response down to actual `ProjectV2Item` entries while
  # preserving the requested order for later sorting.
  #
  # Returns `{:ok, items}` or `{:error, reason}`.
  defp decode_project_item_batch(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp decode_project_item_batch(%{"data" => %{"nodes" => nodes}}) when is_list(nodes) do
    items =
      Enum.flat_map(nodes, fn
        %{"__typename" => "ProjectV2Item"} = item -> [item]
        _other -> []
      end)

    {:ok, items}
  end

  defp decode_project_item_batch(_response), do: {:error, :github_projects_unknown_payload}

  # Extract the configured project payload from the contract query.
  #
  # Chooses the configured owner branch and returns its project metadata.
  #
  # Returns `{:ok, project}` or `{:error, reason}`.
  defp extract_project(%{"errors" => errors}, _owner_field), do: {:error, {:github_graphql_errors, errors}}

  defp extract_project(%{"data" => data}, owner_field) when is_map(data) do
    case get_in(data, [owner_field, "projectV2"]) do
      %{"fields" => %{"pageInfo" => page_info}} = project ->
        {:ok, project, %{has_next_page: page_info["hasNextPage"] == true, end_cursor: page_info["endCursor"]}}

      %{} = project ->
        {:ok, project, %{has_next_page: false, end_cursor: nil}}

      _ ->
        {:error, :github_projects_project_not_found}
    end
  end

  defp extract_project(_response, _owner_field), do: {:error, :github_projects_project_not_found}

  # Detect whether the configured workflow field is already present in loaded field pages.
  #
  # Returns `true` when the field list contains the named status field.
  defp status_field_present?(fields, status_field_name) when is_list(fields) and is_binary(status_field_name) do
    Enum.any?(fields, fn
      %{"name" => ^status_field_name} -> true
      _field -> false
    end)
  end

  defp status_field_present?(_fields, _status_field_name), do: false

  # Find the configured workflow field on the project.
  #
  # The project contract query loads all visible fields, so this helper selects
  # the configured workflow field by name.
  #
  # Returns `{:ok, field}` or `{:error, reason}`.
  defp find_status_field(project, status_field_name) when is_binary(status_field_name) do
    field =
      project
      |> get_in(["fields", "nodes"])
      |> List.wrap()
      |> Enum.find(fn
        %{"name" => ^status_field_name} -> true
        _field -> false
      end)

    case field do
      %{} = value -> {:ok, value}
      nil -> {:error, {:github_projects_status_field_not_found, status_field_name}}
    end
  end

  # Ensure the configured owner type is supported.
  #
  # The runtime only supports organization and user projects in v1.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp validate_owner_type(owner_type) when owner_type in ["organization", "user"], do: :ok
  defp validate_owner_type(_owner_type), do: {:error, :invalid_github_owner_type}

  # Ensure the configured repository uses owner/repo form.
  #
  # This keeps repository filtering deterministic and avoids ambiguous repo
  # comparisons during item normalization.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp validate_repository(repository) when is_binary(repository) do
    if String.match?(repository, ~r/^[^\/\s]+\/[^\/\s]+$/) do
      :ok
    else
      {:error, :invalid_github_repository}
    end
  end

  defp validate_repository(_repository), do: {:error, :invalid_github_repository}

  # Ensure the configured workflow field is single-select.
  #
  # Overture depends on option IDs for both polling semantics and project item
  # field updates.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_single_select_field(%{"__typename" => "ProjectV2SingleSelectField"}, _status_field_name), do: :ok

  defp ensure_single_select_field(%{"__typename" => typename}, status_field_name) do
    {:error, {:github_projects_status_field_not_single_select, status_field_name, typename}}
  end

  # Ensure configured workflow states exist as field options.
  #
  # This locks the runtime state machine to the live board field contract.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_state_options(field, tracker) do
    option_names =
      field
      |> Map.get("options", [])
      |> Enum.map(&Map.get(&1, "name"))
      |> MapSet.new()

    missing_states =
      tracker.active_states
      |> Kernel.++(tracker.terminal_states)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(option_names, &1))

    case missing_states do
      [] -> :ok
      _ -> {:error, {:github_projects_missing_state_options, missing_states}}
    end
  end

  # Build a field option-name to option-ID map.
  #
  # This lookup powers workflow state updates on project items.
  #
  # Returns a map keyed by option name.
  defp status_option_ids(field) do
    field
    |> Map.get("options", [])
    |> Enum.reduce(%{}, fn option, acc ->
      case {Map.get(option, "name"), Map.get(option, "id")} do
        {name, option_id} when is_binary(name) and is_binary(option_id) ->
          Map.put(acc, name, option_id)

        _ ->
          acc
      end
    end)
  end

  # Resolve a project status option ID by workflow state name.
  #
  # Returns `{:ok, option_id}` or `{:error, reason}`.
  defp status_option_id(contract, state_name) when is_binary(state_name) do
    case get_in(contract, [:status_field, :option_ids_by_name, state_name]) do
      option_id when is_binary(option_id) -> {:ok, option_id}
      _ -> {:error, {:github_projects_missing_state_option, state_name}}
    end
  end

  # Build the public issue identifier for a linked GitHub issue.
  #
  # Formats the identifier as `owner/repo#number`.
  #
  # Returns the identifier string or `nil`.
  defp build_issue_identifier(issue_content) do
    with repository when is_binary(repository) <- get_in(issue_content, ["repository", "nameWithOwner"]),
         issue_number when is_integer(issue_number) <- Map.get(issue_content, "number") do
      "#{repository}##{issue_number}"
    end
  end

  # Extract normalized assignee logins from a GitHub issue payload.
  #
  # Returns a deduplicated list of lowercased GitHub logins.
  defp extract_assignee_logins(issue_content) do
    issue_content
    |> get_in(["assignees", "nodes"])
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "login"))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  # Extract normalized label names from a GitHub issue payload.
  #
  # Returns a deduplicated list of lowercased label names.
  defp extract_labels(issue_content) do
    issue_content
    |> get_in(["labels", "nodes"])
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  # Determine whether an issue is routed to the configured worker assignee.
  #
  # Returns `true` when no assignee filter exists or when the configured login
  # is present on the linked issue.
  defp assigned_to_worker?(_assignee_logins, nil), do: true

  defp assigned_to_worker?(assignee_logins, configured_login) when is_binary(configured_login) do
    Enum.any?(assignee_logins, &(&1 == configured_login))
  end

  defp assigned_to_worker?(_assignee_logins, _configured_login), do: false

  # Normalize the configured assignee filter for routing.
  #
  # Returns `{:ok, nil}` when no filter is configured or `{:ok, login}` for an
  # explicit GitHub login.
  defp routing_assignee_filter(nil), do: {:ok, nil}

  defp routing_assignee_filter(assignee) when is_binary(assignee) do
    normalized_login =
      assignee
      |> String.trim()
      |> String.downcase()

    cond do
      normalized_login == "" ->
        {:error, {:invalid_workflow_config, "tracker.assignee must be an explicit GitHub login for github_projects"}}

      normalized_login == "me" ->
        {:error, {:invalid_workflow_config, "tracker.assignee: me is not supported for github_projects; use an explicit GitHub login"}}

      true ->
        {:ok, normalized_login}
    end
  end

  defp routing_assignee_filter(_assignee), do: {:ok, nil}

  # Normalize a repository name for case-insensitive comparison.
  #
  # Returns the lowercased repository name or `nil`.
  defp normalize_repository(repository) when is_binary(repository) do
    repository
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_repository(_repository), do: nil

  # Normalize a workflow-state list into a deduplicated set.
  #
  # Returns a `MapSet` of normalized state names.
  defp normalized_state_set(state_names) do
    state_names
    |> normalize_state_names()
    |> MapSet.new()
  end

  # Normalize a workflow-state list into deduplicated names.
  #
  # Returns a list of normalized state names.
  defp normalize_state_names(state_names) do
    state_names
    |> Enum.map(&normalize_state_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Normalize one workflow state name for comparison.
  #
  # Returns the lowercased state name or `nil`.
  defp normalize_state_name(state_name) when is_binary(state_name) do
    case String.trim(state_name) do
      "" -> nil
      normalized -> String.downcase(normalized)
    end
  end

  defp normalize_state_name(_state_name), do: nil

  # Decide whether a normalized issue belongs in the requested state filter.
  #
  # Returns `true` when no explicit filter exists or when the issue state matches.
  defp include_issue_state?(_issue, nil), do: true

  defp include_issue_state?(%Issue{state: state_name}, requested_states) when is_map(requested_states) do
    MapSet.member?(requested_states, normalize_state_name(state_name))
  end

  defp include_issue_state?(_issue, _requested_states), do: false

  # Decide whether a workflow state is active in the configured tracker contract.
  #
  # Returns `true` when the state is configured as active.
  defp active_issue_state?(state_name, tracker) do
    tracker.active_states
    |> normalized_state_set()
    |> MapSet.member?(normalize_state_name(state_name))
  end

  # Decide whether a workflow state is terminal in the configured tracker contract.
  #
  # Returns `true` when the state is configured as terminal.
  defp terminal_issue_state?(state_name, tracker) do
    tracker.terminal_states
    |> normalized_state_set()
    |> MapSet.member?(normalize_state_name(state_name))
  end

  # Map a workflow state name to a GitHub issue close reason.
  #
  # Returns one of GitHub's supported issue close reason enum strings.
  defp close_reason_for_state(state_name) when is_binary(state_name) do
    case normalize_state_name(state_name) do
      "done" -> "COMPLETED"
      "duplicate" -> "DUPLICATE"
      "canceled" -> "NOT_PLANNED"
      "cancelled" -> "NOT_PLANNED"
      _ -> "NOT_PLANNED"
    end
  end

  defp close_reason_for_state(_state_name), do: "NOT_PLANNED"

  # Sort a fetched issue batch back into the original ID request order.
  #
  # Returns `{:ok, issues}` or propagates an existing error.
  defp sort_issue_batch({:ok, issues}, requested_ids) when is_list(issues) and is_list(requested_ids) do
    issue_order =
      requested_ids
      |> Enum.with_index()
      |> Map.new()

    sorted_issues =
      Enum.sort_by(issues, fn
        %Issue{id: issue_id} -> Map.get(issue_order, issue_id, map_size(issue_order))
        _issue -> map_size(issue_order)
      end)

    {:ok, sorted_issues}
  end

  defp sort_issue_batch(other, _requested_ids), do: other

  # Extract the created comment ID from a comment mutation response.
  #
  # Returns `{:ok, comment_id}` or `{:error, reason}`.
  defp extract_comment_id(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp extract_comment_id(%{"data" => %{"addComment" => %{"commentEdge" => %{"node" => %{"id" => comment_id}}}}})
       when is_binary(comment_id) do
    {:ok, comment_id}
  end

  defp extract_comment_id(_response), do: {:error, :github_projects_comment_create_failed}

  # Extract the updated project item ID from a state update mutation response.
  #
  # Returns `{:ok, item_id}` or `{:error, reason}`.
  defp extract_updated_item_id(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp extract_updated_item_id(%{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => item_id}}}})
       when is_binary(item_id) do
    {:ok, item_id}
  end

  defp extract_updated_item_id(_response), do: {:error, :github_projects_issue_update_failed}

  # Extract the closed issue ID from a close mutation response.
  #
  # Returns `{:ok, issue_id}` or `{:error, reason}`.
  defp extract_closed_issue_id(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp extract_closed_issue_id(%{"data" => %{"closeIssue" => %{"issue" => %{"id" => issue_id}}}})
       when is_binary(issue_id) do
    {:ok, issue_id}
  end

  defp extract_closed_issue_id(_response), do: {:error, :github_projects_issue_close_failed}

  # Extract the reopened issue ID from a reopen mutation response.
  #
  # Returns `{:ok, issue_id}` or `{:error, reason}`.
  defp extract_reopened_issue_id(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp extract_reopened_issue_id(%{"data" => %{"reopenIssue" => %{"issue" => %{"id" => issue_id}}}})
       when is_binary(issue_id) do
    {:ok, issue_id}
  end

  defp extract_reopened_issue_id(_response), do: {:error, :github_projects_issue_reopen_failed}

  # Build a GraphQL payload with an optional operation name.
  #
  # Returns a JSON-ready payload map.
  defp build_graphql_payload(query, variables, operation_name) do
    %{"query" => query, "variables" => variables}
    |> maybe_put_operation_name(operation_name)
  end

  # Add the operation name to the payload when one is present.
  #
  # Returns the payload map.
  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    case String.trim(operation_name) do
      "" -> payload
      normalized -> Map.put(payload, "operationName", normalized)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  # Build GraphQL headers from the configured tracker auth source.
  #
  # Uses the same auth contract as tracker polling and mutations so the runtime
  # and dynamic tools cannot drift.
  #
  # Returns `{:ok, headers}` or `{:error, reason}`.
  defp graphql_headers(tracker) do
    token = Schema.resolve_secret_setting(Map.get(tracker, :api_key), System.get_env("GITHUB_TOKEN"))

    case token do
      value when is_binary(value) and value != "" ->
        {:ok,
         [
           {"authorization", "Bearer #{value}"},
           {"content-type", "application/json"},
           {"accept", "application/vnd.github+json"},
           {"user-agent", "Overture"}
         ]}

      _ ->
        {:error, :missing_github_api_token}
    end
  end

  # Post one GitHub GraphQL request with Req.
  #
  # Returns `{:ok, %{status: status, body: body}}` or `{:error, reason}`.
  defp post_graphql_request(payload, headers) do
    Req.new(url: @graphql_endpoint, headers: headers, json: payload)
    |> Req.post()
    |> case do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Parse an ISO8601 datetime string from the GitHub API.
  #
  # Returns `DateTime.t()` or `nil`.
  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  # Format request and response context for GitHub GraphQL failures.
  #
  # Returns a log-safe context string.
  defp github_error_context(payload, %{body: body}) do
    response_body =
      body
      |> inspect(limit: :infinity, printable_limit: :infinity)
      |> String.slice(0, @max_error_body_log_bytes)

    payload_context = " payload=#{inspect(payload, printable_limit: 200)}"
    " response=#{response_body}" <> payload_context
  end

  defp github_error_context(payload, _response) do
    " payload=#{inspect(payload, printable_limit: 200)}"
  end
end
