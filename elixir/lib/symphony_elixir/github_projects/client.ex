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
  @dependency_page_size 10
  @blocker_page_size 50
  @project_item_lookup_page_size 20
  @linked_branch_page_size 1
  @issue_state_reason_selection "stateReason(enableDuplicate: true)"
  @issue_closed_state_reasons ["COMPLETED", "NOT_PLANNED", "DUPLICATE"]
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

  @type request_fun :: (map(), [{binary(), binary()}] -> {:ok, %{status: integer(), body: map() | binary()}} | {:error, term()})

  @type project_contract :: %{
          project_id: String.t(),
          repository: String.t(),
          status_field: %{
            id: String.t(),
            name: String.t(),
            option_ids_by_name: %{optional(String.t()) => String.t()}
          },
          priority_field:
            nil
            | %{
                id: String.t(),
                name: String.t(),
                type: :number | :single_select,
                priority_by_option_id: %{optional(String.t()) => integer()},
                priority_by_option_name: %{optional(String.t()) => integer()}
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
      {:error, :missing_github_api_token} ->
        {:error, :missing_github_api_token}

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

  @doc """
  Verify the live GitHub GraphQL schema contract used by Overture.

  Introspects the issue close-reason read surface and close mutation input
  contract so tests and live smoke can fail clearly when GitHub changes the
  schema in a way that breaks Overture's tracker client.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec verify_schema_contract() :: :ok | {:error, term()}
  def verify_schema_contract do
    tracker = Config.settings!().tracker
    verify_schema_contract_with_tracker(tracker, &post_graphql_request/2)
  end

  @doc false
  @spec verify_schema_contract_for_test(term(), request_fun()) :: :ok | {:error, term()}
  def verify_schema_contract_for_test(tracker, request_fun) when is_function(request_fun, 2) do
    verify_schema_contract_with_tracker(tracker, request_fun)
  end

  # Verify the live GitHub schema contract used by Overture.
  #
  # Introspects the issue close-reason read surface and close mutation input
  # contract so tests and live smoke can fail clearly when GitHub changes the
  # schema in a way that breaks the tracker client.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp verify_schema_contract_with_tracker(tracker, request_fun) do
    with {:ok, response} <-
           graphql(schema_contract_query(), %{},
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureGitHubSchemaContract"
           ),
         :ok <- ensure_issue_state_reason_contract(response),
         :ok <- ensure_close_issue_input_contract(response),
         :ok <- ensure_issue_closed_state_reason_values(response) do
      :ok
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
         {:ok, status_field} <- find_status_field(project, tracker.status_field_name),
         {:ok, priority_field} <- find_priority_field(project, tracker.priority_field_name),
         :ok <- ensure_single_select_field(status_field, tracker.status_field_name),
         :ok <- ensure_state_options(status_field, tracker),
         {:ok, priority_field_contract} <- build_priority_field_contract(priority_field, tracker) do
      {:ok,
       %{
         project_id: project["id"],
         repository: tracker.repository,
         status_field: %{
           id: status_field["id"],
           name: status_field["name"],
           option_ids_by_name: status_option_ids(status_field)
         },
         priority_field: priority_field_contract
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

  # Fetch one page of project field metadata and continue until required fields are found.
  #
  # Paginates the `ProjectV2.fields` connection so status and optional priority
  # field lookup remains correct on boards with more fields than the initial
  # page size.
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
           graphql(project_contract_query(owner_field), variables,
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
        field_targets_loaded?(updated_fields, tracker.status_field_name, tracker.priority_field_name) ->
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

  # Build the owner-specific project contract query for the configured board owner.
  #
  # GitHub returns a `NOT_FOUND` error when a query asks for `user(...)` against
  # an organization login, so contract lookup must query only the configured
  # owner branch.
  #
  # Returns a GraphQL query string.
  defp project_contract_query(owner_field) when owner_field in ["organization", "user"] do
    """
    query OvertureProjectFieldContract(
      $ownerLogin: String!,
      $projectNumber: Int!,
      $fieldFirst: Int!,
      $after: String
    ) {
      #{owner_field}(login: $ownerLogin) {
        projectV2(number: $projectNumber) {
          id
          fields(first: $fieldFirst, after: $after) {
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
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
    }
    """
  end

  # Build the project item polling query, optionally including priority.
  #
  # Uses one query shape for status-only boards and one that also requests the
  # configured priority field value when priority parity is enabled.
  #
  # Returns a GraphQL query string.
  defp project_items_query(include_priority?) when is_boolean(include_priority?) do
    """
    query OvertureProjectItems(
      $projectId: ID!,
      $statusFieldName: String!,
      #{project_items_priority_variable(include_priority?)}
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
              #{status_field_value_selection()}
              #{priority_field_value_selection(include_priority?)}
              content {
                __typename
                ... on Issue {
                  #{issue_content_selection()}
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
  end

  # Build the project item refresh query, optionally including priority.
  #
  # Returns a GraphQL query string.
  defp project_items_by_id_query(include_priority?) when is_boolean(include_priority?) do
    """
    query OvertureProjectItemsById(
      $ids: [ID!]!,
      $statusFieldName: String!,
      #{project_items_priority_variable(include_priority?)}
      $assigneeFirst: Int!,
      $labelFirst: Int!
    ) {
      nodes(ids: $ids) {
        __typename
        ... on ProjectV2Item {
          id
          isArchived
          #{status_field_value_selection()}
          #{priority_field_value_selection(include_priority?)}
          content {
            __typename
            ... on Issue {
              #{issue_content_selection()}
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
  end

  # Build the close mutation using the live GitHub close-reason enum.
  #
  # Returns a GraphQL mutation string.
  defp close_issue_mutation do
    """
    mutation OvertureCloseIssue($contentId: ID!, $stateReason: IssueClosedStateReason) {
      closeIssue(input: {issueId: $contentId, stateReason: $stateReason}) {
        issue {
          id
          state
          #{issue_state_reason_selection()}
        }
      }
    }
    """
  end

  # Build the reopen mutation using the shared issue state-reason selection.
  #
  # Returns a GraphQL mutation string.
  defp reopen_issue_mutation do
    """
    mutation OvertureReopenIssue($contentId: ID!) {
      reopenIssue(input: {issueId: $contentId}) {
        issue {
          id
          state
          #{issue_state_reason_selection()}
        }
      }
    }
    """
  end

  # Build the blocker pagination query for one issue.
  #
  # Returns a GraphQL query string.
  defp blocker_page_query do
    """
    query OvertureIssueBlockedByPage($issueId: ID!, $after: String) {
      node(id: $issueId) {
        ... on Issue {
          id
          blockedBy(first: #{@blocker_page_size}, after: $after) {
            nodes {
              id
              number
              state
              repository {
                nameWithOwner
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
            totalCount
          }
        }
      }
    }
    """
  end

  # Build the initial blocker board-state lookup query for issue batches.
  #
  # Returns a GraphQL query string.
  defp blocker_project_items_query do
    """
    query OvertureBlockerProjectItems($ids: [ID!]!, $statusFieldName: String!) {
      nodes(ids: $ids) {
        __typename
        ... on Issue {
          id
          state
          projectItems(includeArchived: false, first: #{@project_item_lookup_page_size}) {
            nodes {
              project {
                id
              }
              #{status_field_value_selection()}
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
  end

  # Build the follow-up blocker board-state pagination query for one issue.
  #
  # Returns a GraphQL query string.
  defp blocker_project_items_page_query do
    """
    query OvertureBlockerProjectItemsPage($issueId: ID!, $statusFieldName: String!, $after: String) {
      node(id: $issueId) {
        ... on Issue {
          id
          state
          projectItems(includeArchived: false, first: #{@project_item_lookup_page_size}, after: $after) {
            nodes {
              project {
                id
              }
              #{status_field_value_selection()}
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
  end

  # Build the schema introspection query used by tests and live smoke.
  #
  # Returns a GraphQL query string.
  defp schema_contract_query do
    """
    query OvertureGitHubSchemaContract {
      issueType: __type(name: "Issue") {
        fields {
          name
          args {
            name
          }
        }
      }
      closeIssueInputType: __type(name: "CloseIssueInput") {
        inputFields {
          name
          type {
            name
            kind
            ofType {
              name
              kind
            }
          }
        }
      }
      issueClosedStateReasonType: __type(name: "IssueClosedStateReason") {
        enumValues {
          name
        }
      }
    }
    """
  end

  # Return the shared issue state-reason field selection.
  #
  # Returns a GraphQL field selection string.
  defp issue_state_reason_selection do
    @issue_state_reason_selection
  end

  # Return the status field selection used on project items and blocker items.
  #
  # Returns a GraphQL field selection string.
  defp status_field_value_selection do
    """
    fieldValueByName(name: $statusFieldName) {
      __typename
      ... on ProjectV2ItemFieldSingleSelectValue {
        name
        optionId
      }
    }
    """
  end

  # Return the optional priority field selection for project items.
  #
  # Returns a GraphQL field selection string.
  defp priority_field_value_selection(true) do
    """
    priorityFieldValue: fieldValueByName(name: $priorityFieldName) {
      __typename
      ... on ProjectV2ItemFieldNumberValue {
        number
      }
      ... on ProjectV2ItemFieldSingleSelectValue {
        name
        optionId
      }
    }
    """
  end

  defp priority_field_value_selection(false), do: ""

  # Return the optional priority query variable declaration.
  #
  # Returns a GraphQL variable declaration string.
  defp project_items_priority_variable(true), do: "$priorityFieldName: String!,"
  defp project_items_priority_variable(false), do: ""

  # Return the shared issue content selection used by GitHub item reads.
  #
  # Returns a GraphQL selection string.
  defp issue_content_selection do
    """
    id
    number
    title
    body
    url
    state
    #{issue_state_reason_selection()}
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
    blockedBy(first: #{@dependency_page_size}) {
      nodes {
        id
        number
        state
        repository {
          nameWithOwner
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
      totalCount
    }
    linkedBranches(first: #{@linked_branch_page_size}) {
      nodes {
        id
        ref {
          id
          name
        }
      }
      totalCount
    }
    createdAt
    updatedAt
    """
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
           graphql(project_items_query(contract.priority_field != nil), maybe_put_priority_field_name(variables, contract),
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
           graphql(project_items_by_id_query(contract.priority_field != nil), maybe_put_priority_field_name(variables, contract),
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
         :ok <- ensure_issue_repository(issue_content, tracker.repository),
         {:ok, issue} <- build_issue(item, issue_content, state_name, assignee_filter, tracker, contract, request_fun) do
      reconcile_issue_for_read(issue, tracker, contract, request_fun)
    else
      true ->
        :skip

      :skip ->
        :skip

      {:error, reason} ->
        Logger.warning("Skipping project item during normalization: item_id=#{inspect(Map.get(item, "id"))} reason=#{inspect(reason)}")
        :skip
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
  defp build_issue(item, issue_content, state_name, assignee_filter, tracker, contract, request_fun) do
    assignee_logins = extract_assignee_logins(issue_content)
    priority = extract_priority(item, contract)
    branch_name = extract_branch_name(issue_content)

    with {:ok, blocked_by} <- extract_blockers(issue_content, tracker, contract, request_fun) do
      {:ok,
       %Issue{
         id: Map.get(item, "id"),
         content_id: Map.get(issue_content, "id"),
         content_number: Map.get(issue_content, "number"),
         identifier: build_issue_identifier(issue_content),
         title: Map.get(issue_content, "title"),
         description: Map.get(issue_content, "body"),
         priority: priority,
         state: state_name,
         content_state: Map.get(issue_content, "state"),
         content_state_reason: Map.get(issue_content, "stateReason"),
         branch_name: branch_name,
         url: Map.get(issue_content, "url"),
         assignee_logins: assignee_logins,
         blocked_by: blocked_by,
         labels: extract_labels(issue_content),
         assigned_to_worker: assigned_to_worker?(assignee_logins, assignee_filter),
         created_at: parse_datetime(Map.get(issue_content, "createdAt")),
         updated_at: parse_datetime(Map.get(issue_content, "updatedAt"))
       }}
    end
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
           graphql(reopen_issue_mutation(), variables,
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
           graphql(close_issue_mutation(), variables,
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

  # Detect whether configured field targets are already present in loaded pages.
  #
  # Returns `true` when the required status field and optional priority field
  # have both been found.
  defp field_targets_loaded?(fields, status_field_name, priority_field_name)
       when is_list(fields) and is_binary(status_field_name) do
    status_field_found? = find_named_field(fields, status_field_name) != nil

    cond do
      not status_field_found? ->
        false

      is_nil(normalize_optional_string(priority_field_name)) ->
        true

      true ->
        find_named_field(fields, priority_field_name) != nil
    end
  end

  defp field_targets_loaded?(_fields, _status_field_name, _priority_field_name), do: false

  # Find the configured workflow field on the project.
  #
  # The project contract query loads all visible fields, so this helper selects
  # the configured workflow field by name.
  #
  # Returns `{:ok, field}` or `{:error, reason}`.
  defp find_status_field(project, status_field_name) when is_binary(status_field_name) do
    field = find_named_field(project |> get_in(["fields", "nodes"]) |> List.wrap(), status_field_name)

    case field do
      %{} = value -> {:ok, value}
      nil -> {:error, {:github_projects_status_field_not_found, status_field_name}}
    end
  end

  # Find the optional priority field on the project.
  #
  # Returns `{:ok, field | nil}` or `{:error, reason}`.
  defp find_priority_field(_project, nil), do: {:ok, nil}

  defp find_priority_field(project, priority_field_name) when is_binary(priority_field_name) do
    normalized_name = normalize_optional_string(priority_field_name)

    case normalized_name do
      nil ->
        {:ok, nil}

      name ->
        field = find_named_field(project |> get_in(["fields", "nodes"]) |> List.wrap(), name)

        case field do
          %{} = value -> {:ok, value}
          nil -> {:error, {:github_projects_priority_field_not_found, name}}
        end
    end
  end

  # Find a project field by name from a loaded field list.
  #
  # Returns the matching field map or `nil`.
  defp find_named_field(fields, field_name) when is_list(fields) and is_binary(field_name) do
    Enum.find(fields, fn
      %{"name" => ^field_name} -> true
      _field -> false
    end)
  end

  defp find_named_field(_fields, _field_name), do: nil

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

  # Build the validated optional priority field contract.
  #
  # Supports numeric GitHub project fields and single-select priority fields
  # with an explicit option-to-priority mapping.
  #
  # Returns `{:ok, priority_field_contract | nil}` or `{:error, reason}`.
  defp build_priority_field_contract(nil, tracker) do
    case normalize_priority_option_map(Map.get(tracker, :priority_option_map)) do
      %{} = option_map when map_size(option_map) > 0 ->
        {:error, {:invalid_workflow_config, "tracker.priority_option_map requires tracker.priority_field_name for github_projects"}}

      _ ->
        {:ok, nil}
    end
  end

  defp build_priority_field_contract(%{"__typename" => "ProjectV2Field", "dataType" => "NUMBER"} = field, tracker) do
    case normalize_priority_option_map(Map.get(tracker, :priority_option_map)) do
      %{} = option_map when map_size(option_map) > 0 ->
        {:error, {:invalid_workflow_config, "tracker.priority_option_map is only allowed for single-select GitHub priority fields"}}

      _ ->
        {:ok,
         %{
           id: field["id"],
           name: field["name"],
           type: :number,
           priority_by_option_id: %{},
           priority_by_option_name: %{}
         }}
    end
  end

  defp build_priority_field_contract(%{"__typename" => "ProjectV2SingleSelectField"} = field, tracker) do
    priority_option_map = normalize_priority_option_map(Map.get(tracker, :priority_option_map))

    cond do
      priority_option_map == nil or priority_option_map == %{} ->
        {:error, {:invalid_workflow_config, "tracker.priority_option_map is required for single-select GitHub priority fields"}}

      true ->
        with {:ok, option_names, option_ids_by_name} <- priority_options(field),
             :ok <- ensure_priority_option_names(option_names, priority_option_map),
             :ok <- ensure_priority_option_values(priority_option_map) do
          {:ok,
           %{
             id: field["id"],
             name: field["name"],
             type: :single_select,
             priority_by_option_id:
               Enum.reduce(priority_option_map, %{}, fn {option_name, priority}, acc ->
                 Map.put(acc, Map.fetch!(option_ids_by_name, option_name), priority)
               end),
             priority_by_option_name: priority_option_map
           }}
        end
    end
  end

  defp build_priority_field_contract(%{"__typename" => typename} = field, _tracker) do
    {:error, {:github_projects_priority_field_unsupported, field["name"], typename, Map.get(field, "dataType")}}
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

  # Normalize the configured priority option map.
  #
  # Returns a map keyed by option name or `nil`.
  defp normalize_priority_option_map(nil), do: nil

  defp normalize_priority_option_map(option_map) when is_map(option_map) do
    Enum.reduce(option_map, %{}, fn {option_name, priority}, acc ->
      case normalize_optional_string(to_string(option_name)) do
        nil -> acc
        normalized_name -> Map.put(acc, normalized_name, priority)
      end
    end)
  end

  defp normalize_priority_option_map(_option_map), do: %{}

  # Extract single-select priority options for validation and lookup building.
  #
  # Returns `{:ok, option_names, option_ids_by_name}` or `{:error, reason}`.
  defp priority_options(field) do
    option_ids_by_name =
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

    {:ok, Map.keys(option_ids_by_name) |> MapSet.new(), option_ids_by_name}
  end

  # Ensure configured priority option names exist on the live field.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_priority_option_names(option_names, priority_option_map) do
    missing_option_names =
      priority_option_map
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(option_names, &1))

    case missing_option_names do
      [] -> :ok
      _ -> {:error, {:github_projects_missing_priority_options, missing_option_names}}
    end
  end

  # Ensure configured priority values stay within Symphony's supported range.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_priority_option_values(priority_option_map) do
    case Enum.all?(priority_option_map, fn {_option_name, priority} -> is_integer(priority) and priority in 1..4 end) do
      true -> :ok
      false -> {:error, {:invalid_workflow_config, "tracker.priority_option_map values must be integers in 1..4"}}
    end
  end

  # Add the optional priority field variable when the board contract requires it.
  #
  # Returns the variables map.
  defp maybe_put_priority_field_name(variables, %{priority_field: %{name: priority_field_name}})
       when is_map(variables) and is_binary(priority_field_name) do
    Map.put(variables, :priorityFieldName, priority_field_name)
  end

  defp maybe_put_priority_field_name(variables, _contract), do: variables

  # Normalize the optional priority value from a project item.
  #
  # Returns an integer priority or `nil`.
  defp extract_priority(_item, %{priority_field: nil}), do: nil

  defp extract_priority(item, %{priority_field: %{type: :number}}) when is_map(item) do
    case Map.get(item, "priorityFieldValue") do
      %{"__typename" => "ProjectV2ItemFieldNumberValue", "number" => value}
      when is_number(value) and trunc(value) == value and value >= 1 and value <= 4 ->
        trunc(value)

      _ ->
        nil
    end
  end

  defp extract_priority(item, %{priority_field: %{type: :single_select} = priority_field}) when is_map(item) do
    case Map.get(item, "priorityFieldValue") do
      %{"__typename" => "ProjectV2ItemFieldSingleSelectValue"} = value ->
        Map.get(priority_field.priority_by_option_id, value["optionId"]) ||
          Map.get(priority_field.priority_by_option_name, value["name"])

      _ ->
        nil
    end
  end

  defp extract_priority(_item, _contract), do: nil

  # Normalize branch metadata from a linked GitHub issue.
  #
  # Returns the branch name when exactly one linked branch exists, otherwise `nil`.
  defp extract_branch_name(issue_content) when is_map(issue_content) do
    branch_count = issue_content |> get_in(["linkedBranches", "totalCount"])

    case branch_count do
      1 ->
        issue_content
        |> get_in(["linkedBranches", "nodes"])
        |> List.wrap()
        |> Enum.at(0)
        |> then(fn
          %{"ref" => %{"name" => branch_name}} when is_binary(branch_name) -> branch_name
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp extract_branch_name(_issue_content), do: nil

  # Normalize blockers from GitHub issue dependencies and board state.
  #
  # Fully paginates the blocker connection, resolves same-board blocker status,
  # and falls back to GitHub-native issue state only when the blocker is not on
  # the configured board.
  #
  # Returns `{:ok, blockers}` or `{:error, reason}`.
  defp extract_blockers(issue_content, tracker, contract, request_fun) when is_map(issue_content) do
    with {:ok, blocker_nodes} <- load_blocker_nodes(issue_content, tracker, request_fun),
         {:ok, blockers} <- normalize_blocker_refs(blocker_nodes),
         {:ok, resolved_blockers} <- resolve_blocker_states(blockers, tracker, contract, request_fun) do
      {:ok, resolved_blockers}
    end
  end

  defp extract_blockers(_issue_content, _tracker, _contract, _request_fun), do: {:ok, []}

  # Load the full blocker connection for one issue.
  #
  # Returns `{:ok, blocker_nodes}` or `{:error, reason}`.
  defp load_blocker_nodes(issue_content, tracker, request_fun) do
    blocker_nodes = issue_content |> get_in(["blockedBy", "nodes"]) |> List.wrap()
    total_count = issue_content |> get_in(["blockedBy", "totalCount"])
    page_info = issue_content |> get_in(["blockedBy", "pageInfo"])

    cond do
      not is_integer(total_count) or total_count <= length(blocker_nodes) ->
        {:ok, blocker_nodes}

      page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) and page_info["endCursor"] != "" ->
        issue_id = Map.get(issue_content, "id")
        fetch_blocker_pages(issue_id, page_info["endCursor"], blocker_nodes, tracker, request_fun)

      page_info["hasNextPage"] == true ->
        {:error, :github_projects_missing_end_cursor}

      true ->
        {:ok, blocker_nodes}
    end
  end

  # Fetch remaining blocker pages for one issue.
  #
  # Returns `{:ok, blocker_nodes}` or `{:error, reason}`.
  defp fetch_blocker_pages(issue_id, after_cursor, acc_nodes, tracker, request_fun)
       when is_binary(issue_id) and is_binary(after_cursor) do
    variables = %{issueId: issue_id, after: after_cursor}

    with {:ok, response} <-
           graphql(blocker_page_query(), variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureIssueBlockedByPage"
           ),
         {:ok, nodes, page_info} <- decode_blocker_page(response) do
      updated_nodes = acc_nodes ++ nodes

      cond do
        page_info.has_next_page == true and is_binary(page_info.end_cursor) and page_info.end_cursor != "" ->
          fetch_blocker_pages(issue_id, page_info.end_cursor, updated_nodes, tracker, request_fun)

        page_info.has_next_page == true ->
          {:error, :github_projects_missing_end_cursor}

        true ->
          {:ok, updated_nodes}
      end
    end
  end

  defp fetch_blocker_pages(_issue_id, _after_cursor, _acc_nodes, _tracker, _request_fun) do
    {:error, :github_projects_missing_issue_content_id}
  end

  # Decode one blocker pagination page.
  #
  # Returns `{:ok, blocker_nodes, page_info}` or `{:error, reason}`.
  defp decode_blocker_page(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp decode_blocker_page(%{"data" => %{"node" => %{"blockedBy" => %{"nodes" => nodes, "pageInfo" => page_info}}}}) do
    {:ok, List.wrap(nodes), %{has_next_page: page_info["hasNextPage"] == true, end_cursor: page_info["endCursor"]}}
  end

  defp decode_blocker_page(_response), do: {:error, :github_projects_unknown_payload}

  # Normalize raw blocker nodes into sortable blocker refs.
  #
  # Returns `{:ok, blockers}` or `{:error, reason}`.
  defp normalize_blocker_refs(blocker_nodes) when is_list(blocker_nodes) do
    blockers =
      blocker_nodes
      |> Enum.reduce_while([], fn blocker_node, acc ->
        case normalize_blocker_ref(blocker_node) do
          {:ok, blocker} -> {:cont, [blocker | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case blockers do
      {:error, reason} ->
        {:error, reason}

      normalized ->
        {:ok,
         normalized
         |> Enum.reverse()
         |> Enum.sort_by(fn blocker -> {blocker.identifier, blocker.id} end)}
    end
  end

  defp normalize_blocker_refs(_blocker_nodes), do: {:ok, []}

  # Normalize one blocker node to a provider-neutral blocker ref.
  #
  # Returns `{:ok, blocker}` or `{:error, reason}`.
  defp normalize_blocker_ref(%{"id" => blocker_id, "number" => blocker_number, "repository" => %{"nameWithOwner" => repository}, "state" => blocker_state})
       when is_binary(blocker_id) and is_integer(blocker_number) and is_binary(repository) and is_binary(blocker_state) do
    {:ok,
     %{
       id: blocker_id,
       identifier: "#{repository}##{blocker_number}",
       state: blocker_state,
       native_state: blocker_state
     }}
  end

  defp normalize_blocker_ref(_blocker_node), do: {:error, :github_projects_invalid_blocker}

  # Resolve blocker states using board status when the blocker is on the configured board.
  #
  # Returns `{:ok, blockers}` or `{:error, reason}`.
  defp resolve_blocker_states([], _tracker, _contract, _request_fun), do: {:ok, []}

  defp resolve_blocker_states(blockers, tracker, contract, request_fun) do
    blocker_ids = Enum.map(blockers, & &1.id)
    variables = %{ids: blocker_ids, statusFieldName: contract.status_field.name}

    with {:ok, response} <-
           graphql(blocker_project_items_query(), variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureBlockerProjectItems"
           ),
         {:ok, blocker_nodes} <- decode_blocker_project_items(response) do
      blocker_nodes_by_id =
        blocker_nodes
        |> Enum.reduce(%{}, fn blocker_node, acc -> Map.put(acc, blocker_node["id"], blocker_node) end)

      blockers
      |> Enum.reduce_while({:ok, []}, fn blocker, {:ok, acc} ->
        case resolve_blocker_state(blocker, Map.get(blocker_nodes_by_id, blocker.id), tracker, contract, request_fun) do
          {:ok, resolved_blocker} -> {:cont, {:ok, [resolved_blocker | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, resolved_blockers} ->
          {:ok,
           resolved_blockers
           |> Enum.reverse()
           |> Enum.sort_by(fn blocker -> {blocker.identifier, blocker.id} end)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Decode a blocker board-state lookup response.
  #
  # Returns `{:ok, blocker_issue_nodes}` or `{:error, reason}`.
  defp decode_blocker_project_items(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp decode_blocker_project_items(%{"data" => %{"nodes" => nodes}}) when is_list(nodes) do
    blocker_nodes =
      Enum.flat_map(nodes, fn
        %{"__typename" => "Issue"} = blocker_node -> [blocker_node]
        _other -> []
      end)

    {:ok, blocker_nodes}
  end

  defp decode_blocker_project_items(_response), do: {:error, :github_projects_unknown_payload}

  # Resolve one blocker to its final normalized state.
  #
  # Returns `{:ok, blocker}` or `{:error, reason}`.
  defp resolve_blocker_state(blocker, nil, _tracker, _contract, _request_fun) do
    {:error, {:github_projects_blocker_lookup_failed, blocker.identifier}}
  end

  defp resolve_blocker_state(blocker, blocker_node, tracker, contract, request_fun) do
    case resolve_blocker_board_state(blocker.id, blocker_node, tracker, contract, request_fun) do
      {:ok, {:board_status, status_name}} ->
        {:ok, blocker |> Map.put(:state, status_name) |> Map.delete(:native_state)}

      {:ok, :not_on_board} ->
        fallback_state = normalize_optional_string(Map.get(blocker, :native_state)) || Map.get(blocker_node, "state")
        {:ok, blocker |> Map.put(:state, fallback_state) |> Map.delete(:native_state)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Resolve board status for one blocker issue across paginated project items.
  #
  # Returns `{:ok, {:board_status, status_name} | :not_on_board}` or `{:error, reason}`.
  defp resolve_blocker_board_state(blocker_issue_id, blocker_node, tracker, contract, request_fun) do
    project_items = get_in(blocker_node, ["projectItems", "nodes"]) |> List.wrap()
    page_info = get_in(blocker_node, ["projectItems", "pageInfo"]) || %{}

    case find_project_item_for_project(project_items, contract.project_id) do
      {:ok, project_item} ->
        blocker_status_from_project_item(project_item, contract)

      :not_found ->
        cond do
          page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) and page_info["endCursor"] != "" ->
            fetch_blocker_project_items_page(blocker_issue_id, page_info["endCursor"], tracker, contract, request_fun)

          page_info["hasNextPage"] == true ->
            {:error, :github_projects_missing_end_cursor}

          true ->
            {:ok, :not_on_board}
        end
    end
  end

  # Fetch remaining blocker project-item pages until the configured board is found.
  #
  # Returns `{:ok, {:board_status, status_name} | :not_on_board}` or `{:error, reason}`.
  defp fetch_blocker_project_items_page(blocker_issue_id, after_cursor, tracker, contract, request_fun)
       when is_binary(blocker_issue_id) and is_binary(after_cursor) do
    variables = %{issueId: blocker_issue_id, statusFieldName: contract.status_field.name, after: after_cursor}

    with {:ok, response} <-
           graphql(blocker_project_items_page_query(), variables,
             tracker: tracker,
             request_fun: request_fun,
             operation_name: "OvertureBlockerProjectItemsPage"
           ),
         {:ok, project_items, page_info} <- decode_blocker_project_items_page(response) do
      case find_project_item_for_project(project_items, contract.project_id) do
        {:ok, project_item} ->
          blocker_status_from_project_item(project_item, contract)

        :not_found when page_info.has_next_page == true and is_binary(page_info.end_cursor) and page_info.end_cursor != "" ->
          fetch_blocker_project_items_page(blocker_issue_id, page_info.end_cursor, tracker, contract, request_fun)

        :not_found when page_info.has_next_page == true ->
          {:error, :github_projects_missing_end_cursor}

        :not_found ->
          {:ok, :not_on_board}
      end
    end
  end

  defp fetch_blocker_project_items_page(_blocker_issue_id, _after_cursor, _tracker, _contract, _request_fun) do
    {:error, :github_projects_missing_issue_content_id}
  end

  # Decode one blocker project-item page.
  #
  # Returns `{:ok, project_items, page_info}` or `{:error, reason}`.
  defp decode_blocker_project_items_page(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp decode_blocker_project_items_page(%{"data" => %{"node" => %{"projectItems" => %{"nodes" => nodes, "pageInfo" => page_info}}}}) do
    {:ok, List.wrap(nodes), %{has_next_page: page_info["hasNextPage"] == true, end_cursor: page_info["endCursor"]}}
  end

  defp decode_blocker_project_items_page(_response), do: {:error, :github_projects_unknown_payload}

  # Find the project item for the configured board from a list of project items.
  #
  # Returns `{:ok, project_item}` or `:not_found`.
  defp find_project_item_for_project(project_items, project_id) when is_list(project_items) and is_binary(project_id) do
    case Enum.find(project_items, fn
           %{"project" => %{"id" => ^project_id}} -> true
           _project_item -> false
         end) do
      %{} = project_item -> {:ok, project_item}
      nil -> :not_found
    end
  end

  defp find_project_item_for_project(_project_items, _project_id), do: :not_found

  # Extract a readable board status from a blocker project item.
  #
  # Returns `{:ok, {:board_status, status_name}}` or `{:error, reason}`.
  defp blocker_status_from_project_item(project_item, contract) do
    case Map.get(project_item, "fieldValueByName") do
      %{"__typename" => "ProjectV2ItemFieldSingleSelectValue", "name" => status_name}
      when is_binary(status_name) and status_name != "" ->
        {:ok, {:board_status, status_name}}

      _ ->
        {:error, {:github_projects_blocker_missing_status, contract.status_field.name}}
    end
  end

  # Normalize an optional string value for internal comparisons.
  #
  # Returns the trimmed string or `nil`.
  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  # Ensure the Issue.stateReason field still exposes the expected argument.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_issue_state_reason_contract(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp ensure_issue_state_reason_contract(%{"data" => %{"issueType" => %{"fields" => fields}}}) when is_list(fields) do
    case Enum.find(fields, &(&1["name"] == "stateReason")) do
      %{"args" => args} when is_list(args) ->
        if Enum.any?(args, &(&1["name"] == "enableDuplicate")) do
          :ok
        else
          {:error, {:github_schema_contract_mismatch, :issue_state_reason_missing_enable_duplicate}}
        end

      _ ->
        {:error, {:github_schema_contract_mismatch, :issue_state_reason_missing}}
    end
  end

  defp ensure_issue_state_reason_contract(_response) do
    {:error, {:github_schema_contract_mismatch, :issue_type_introspection_failed}}
  end

  # Ensure the closeIssue input still uses GitHub's closed-state enum.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_close_issue_input_contract(%{"data" => %{"closeIssueInputType" => %{"inputFields" => input_fields}}})
       when is_list(input_fields) do
    case Enum.find(input_fields, &(&1["name"] == "stateReason")) do
      %{"type" => %{"name" => "IssueClosedStateReason"}} ->
        :ok

      %{"type" => %{"ofType" => %{"name" => "IssueClosedStateReason"}}} ->
        :ok

      %{"type" => type_info} ->
        {:error, {:github_schema_contract_mismatch, {:close_issue_input_state_reason_type, type_info}}}

      nil ->
        {:error, {:github_schema_contract_mismatch, :close_issue_input_state_reason_missing}}
    end
  end

  defp ensure_close_issue_input_contract(_response) do
    {:error, {:github_schema_contract_mismatch, :close_issue_input_introspection_failed}}
  end

  # Ensure the GitHub closed-state enum still exposes the supported values.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_issue_closed_state_reason_values(%{"data" => %{"issueClosedStateReasonType" => %{"enumValues" => enum_values}}})
       when is_list(enum_values) do
    enum_names =
      enum_values
      |> Enum.map(& &1["name"])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    expected_names = MapSet.new(@issue_closed_state_reasons)

    if MapSet.subset?(expected_names, enum_names) do
      :ok
    else
      {:error, {:github_schema_contract_mismatch, {:issue_closed_state_reason_values, MapSet.to_list(enum_names)}}}
    end
  end

  defp ensure_issue_closed_state_reason_values(_response) do
    {:error, {:github_schema_contract_mismatch, :issue_closed_state_reason_introspection_failed}}
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
