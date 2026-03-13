defmodule SymphonyElixir.GitHubProjects.Client do
  @moduledoc """
  Validate GitHub Projects tracker configuration against live board metadata.

  Uses the configured tracker auth and GitHub GraphQL to confirm that the
  selected board, repository, and workflow field contract exist before runtime.

  Returns `:ok` or `{:error, reason}`.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

  @graphql_endpoint "https://api.github.com/graphql"
  @max_error_body_log_bytes 1_000

  @spec validate_tracker_config(term()) :: :ok | {:error, term()}
  def validate_tracker_config(tracker) do
    with :ok <- validate_owner_type(tracker.owner_type),
         :ok <- validate_repository(tracker.repository),
         {:ok, field} <- fetch_status_field(tracker),
         :ok <- ensure_single_select_field(field, tracker.status_field_name),
         :ok <- ensure_state_options(field, tracker) do
      :ok
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = %{query: query, variables: variables}
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
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

  # Fetch the configured project field contract from GitHub.
  #
  # Uses the configured owner and project number to load board metadata, then
  # returns the field entry matching `tracker.status_field_name`.
  #
  # Returns `{:ok, field_map}` or `{:error, reason}`.
  defp fetch_status_field(tracker) do
    owner_field =
      case tracker.owner_type do
        "organization" -> "organization"
        "user" -> "user"
      end

    query = """
    query OvertureProjectFieldContract($ownerLogin: String!, $projectNumber: Int!, $fieldFirst: Int!) {
      #{owner_field}(login: $ownerLogin) {
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
    }
    """

    variables = %{
      ownerLogin: tracker.owner_login,
      projectNumber: tracker.project_number,
      fieldFirst: 50
    }

    with {:ok, response} <- graphql(query, variables),
         {:ok, project} <- extract_project(response, owner_field),
         {:ok, field} <- find_status_field(project, tracker.status_field_name) do
      {:ok, field}
    end
  end

  # Ensure the configured owner type is supported.
  #
  # The runtime accepts only `organization` and `user` because those map
  # directly to GitHub's root GraphQL owner lookups.
  #
  # Returns `:ok` or `{:error, reason}`.
  # Ensure the configured owner type is supported.
  #
  # The runtime accepts only organization and user owners because those map
  # directly to GitHub's root GraphQL owner lookups.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp validate_owner_type(owner_type) when owner_type in ["organization", "user"], do: :ok
  defp validate_owner_type(_owner_type), do: {:error, :invalid_github_owner_type}

  # Ensure the configured repository uses `owner/repo` form.
  #
  # This prevents poll-time ambiguity when issue-backed project items are
  # filtered to the configured repository.
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

  # Ensure the configured field is a single-select workflow field.
  #
  # Overture depends on single-select option IDs for both polling semantics and
  # future state mutations.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_single_select_field(
         %{"__typename" => "ProjectV2SingleSelectField"},
         _status_field_name
       ),
       do: :ok

  defp ensure_single_select_field(%{"__typename" => typename}, status_field_name) do
    {:error, {:github_projects_status_field_not_single_select, status_field_name, typename}}
  end

  # Ensure the configured workflow states exist as field options.
  #
  # This locks the runtime contract to the live board so state names in
  # `WORKFLOW.md` cannot drift away from the board configuration.
  #
  # Returns `:ok` or `{:error, reason}`.
  defp ensure_state_options(field, tracker) do
    option_names =
      field
      |> Map.get("options", [])
      |> Enum.map(&Map.get(&1, "name"))
      |> MapSet.new()

    configured_states =
      tracker.active_states
      |> Kernel.++(tracker.terminal_states)
      |> Enum.uniq()

    missing_states =
      configured_states
      |> Enum.reject(&MapSet.member?(option_names, &1))

    case missing_states do
      [] -> :ok
      _ -> {:error, {:github_projects_missing_state_options, missing_states}}
    end
  end

  # Extract the configured project payload from the GraphQL response.
  #
  # The root owner key differs between organization and user projects, so this
  # helper normalizes the response shape before field lookup.
  #
  # Returns `{:ok, project_map}` or `{:error, reason}`.
  defp extract_project(%{"data" => data}, owner_field) when is_map(data) do
    case get_in(data, [owner_field, "projectV2"]) do
      %{} = project -> {:ok, project}
      nil -> {:error, :github_projects_project_not_found}
      _ -> {:error, :github_projects_project_not_found}
    end
  end

  defp extract_project(_response, _owner_field), do: {:error, :github_projects_project_not_found}

  # Find the named workflow field on the configured project.
  #
  # The GraphQL response returns all fields, so this helper picks the configured
  # status field by name.
  #
  # Returns `{:ok, field_map}` or `{:error, reason}`.
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

  # Build GraphQL headers from the configured tracker auth source.
  #
  # Uses the same auth contract as tracker polling so validation behavior stays
  # aligned with runtime tracker access.
  #
  # Returns `{:ok, headers}` or `{:error, reason}`.
  defp graphql_headers do
    case Schema.resolve_secret_setting(Config.settings!().tracker.api_key, System.get_env("GITHUB_TOKEN")) do
      token when is_binary(token) and token != "" ->
        {:ok,
         [
           {"authorization", "Bearer #{token}"},
           {"content-type", "application/json"},
           {"accept", "application/vnd.github+json"},
           {"user-agent", "Overture"}
         ]}

      _ ->
        {:error, :missing_github_api_token}
    end
  end

  # Post a GitHub GraphQL request with Req.
  #
  # Sends the JSON payload to the GitHub GraphQL endpoint and normalizes the
  # result into the response shape used by this client.
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

  # Format request and response context for GitHub GraphQL failures.
  #
  # Truncates the logged response body so tracker validation errors stay
  # informative without overwhelming the logs.
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

  # Format request context when no structured response body is available.
  #
  # Keeps request logging consistent across transport and HTTP-status failures.
  #
  # Returns a log-safe context string.
  defp github_error_context(payload, _response) do
    " payload=#{inspect(payload, printable_limit: 200)}"
  end
end
