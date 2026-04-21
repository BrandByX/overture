defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubProjects.Client, as: GitHubProjectsClient
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a tracked issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    normalized_tracker_assignee = normalize_tracker_assignee(settings.tracker.assignee)
    normalized_active_states = normalize_tracker_active_states(settings.tracker.active_states)
    priority_field_name = normalize_optional_string(settings.tracker.priority_field_name)
    priority_option_map = settings.tracker.priority_option_map

    with :ok <- validate_tracker_kind(settings),
         :ok <- validate_github_api_key(settings),
         :ok <- validate_github_owner_type(settings),
         :ok <- validate_github_owner_login(settings),
         :ok <- validate_github_project_number(settings),
         :ok <- validate_github_repository(settings),
         :ok <- validate_github_status_field_name(settings),
         :ok <- validate_github_priority_field_name(settings, priority_field_name),
         :ok <- validate_github_priority_option_map(settings, priority_field_name, priority_option_map),
         :ok <- validate_github_assignee(settings, normalized_tracker_assignee),
         :ok <- validate_github_active_states(settings, normalized_active_states) do
      validate_tracker_backend(settings)
    end
  end

  defp validate_tracker_kind(%{tracker: %{kind: nil}}), do: {:error, :missing_tracker_kind}

  defp validate_tracker_kind(%{tracker: %{kind: kind}})
       when kind not in ["github_projects", "memory"] do
    {:error, {:unsupported_tracker_kind, kind}}
  end

  defp validate_tracker_kind(_settings), do: :ok

  defp validate_github_api_key(%{tracker: %{kind: "github_projects", api_key: api_key}})
       when not is_binary(api_key) do
    {:error, :missing_github_api_token}
  end

  defp validate_github_api_key(_settings), do: :ok

  defp validate_github_owner_type(%{tracker: %{kind: "github_projects", owner_type: owner_type}})
       when owner_type not in ["organization", "user"] do
    {:error, :invalid_github_owner_type}
  end

  defp validate_github_owner_type(_settings), do: :ok

  defp validate_github_owner_login(%{tracker: %{kind: "github_projects", owner_login: owner_login}})
       when not is_binary(owner_login) do
    {:error, {:invalid_workflow_config, "tracker.owner_login must be set for github_projects"}}
  end

  defp validate_github_owner_login(_settings), do: :ok

  defp validate_github_project_number(%{tracker: %{kind: "github_projects", project_number: project_number}})
       when not is_integer(project_number) do
    {:error, {:invalid_workflow_config, "tracker.project_number must be an integer for github_projects"}}
  end

  defp validate_github_project_number(_settings), do: :ok

  defp validate_github_repository(%{tracker: %{kind: "github_projects", repository: repository}})
       when not is_binary(repository) do
    {:error, :invalid_github_repository}
  end

  defp validate_github_repository(_settings), do: :ok

  defp validate_github_status_field_name(%{tracker: %{kind: "github_projects", status_field_name: status_field_name}})
       when not is_binary(status_field_name) do
    {:error, {:invalid_workflow_config, "tracker.status_field_name must be set for github_projects"}}
  end

  defp validate_github_status_field_name(_settings), do: :ok

  defp validate_github_priority_field_name(
         %{tracker: %{kind: "github_projects", status_field_name: status_field_name}},
         priority_field_name
       )
       when priority_field_name == status_field_name do
    {:error, {:invalid_workflow_config, "tracker.priority_field_name must not match tracker.status_field_name"}}
  end

  defp validate_github_priority_field_name(_settings, _priority_field_name), do: :ok

  defp validate_github_priority_option_map(
         %{tracker: %{kind: "github_projects"}},
         nil,
         priority_option_map
       ) do
    if present_map?(priority_option_map) do
      {:error, {:invalid_workflow_config, "tracker.priority_option_map requires tracker.priority_field_name for github_projects"}}
    else
      :ok
    end
  end

  defp validate_github_priority_option_map(_settings, _priority_field_name, _priority_option_map), do: :ok

  defp validate_github_assignee(%{tracker: %{kind: "github_projects"}}, "") do
    {:error, {:invalid_workflow_config, "tracker.assignee must be an explicit GitHub login for github_projects"}}
  end

  defp validate_github_assignee(%{tracker: %{kind: "github_projects"}}, "me") do
    {:error, {:invalid_workflow_config, "tracker.assignee: me is not supported for github_projects; use an explicit GitHub login"}}
  end

  defp validate_github_assignee(_settings, _normalized_tracker_assignee), do: :ok

  defp validate_github_active_states(%{tracker: %{kind: "github_projects"}}, normalized_active_states) do
    if human_review_active?(normalized_active_states) do
      {:error, {:invalid_workflow_config, "tracker.active_states must not include Human Review; it is a manual handoff state"}}
    else
      :ok
    end
  end

  defp validate_github_active_states(_settings, _normalized_active_states), do: :ok

  defp validate_tracker_backend(%{tracker: %{kind: "memory"}}), do: :ok

  defp validate_tracker_backend(%{tracker: %{kind: "github_projects"} = tracker}) do
    github_projects_client_module().validate_tracker_config(tracker)
  end

  defp validate_tracker_backend(_settings), do: :ok

  defp github_projects_client_module do
    Application.get_env(:symphony_elixir, :github_projects_client_module, GitHubProjectsClient)
  end

  defp normalize_tracker_assignee(assignee) when is_binary(assignee) do
    assignee
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_assignee(_assignee), do: nil

  # Normalize configured active state names for semantic validation.
  #
  # Downcases each string state name so validation can reject reserved workflow
  # states regardless of YAML capitalization.
  #
  # Returns the normalized state-name list.
  defp normalize_tracker_active_states(active_states) when is_list(active_states) do
    Enum.map(active_states, &Schema.normalize_issue_state/1)
  end

  defp normalize_tracker_active_states(_active_states), do: []

  # Detect whether the workflow incorrectly treats Human Review as active.
  #
  # `Human Review` is a manual handoff state in the shipped GitHub workflow and
  # must not appear in `tracker.active_states`.
  #
  # Returns `true` when `Human Review` is configured as active.
  defp human_review_active?(active_states) when is_list(active_states) do
    Enum.any?(active_states, &(&1 == "human review"))
  end

  defp human_review_active?(_active_states), do: false

  # Normalize an optional workflow string setting.
  #
  # Trims blank strings to `nil` so semantic validation can distinguish between
  # unset and present values reliably.
  #
  # Returns the trimmed string or `nil`.
  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  # Detect whether a workflow value is a non-empty map.
  #
  # Uses map size so semantic validation can reject empty placeholder maps
  # without treating `nil` as configured data.
  #
  # Returns `true` when the map contains at least one entry.
  defp present_map?(value) when is_map(value), do: map_size(value) > 0
  defp present_map?(_value), do: false

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
