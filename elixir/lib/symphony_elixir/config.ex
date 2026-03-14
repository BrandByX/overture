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
    priority_field_name = normalize_optional_string(settings.tracker.priority_field_name)
    priority_option_map = settings.tracker.priority_option_map

    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["github_projects", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "github_projects" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_github_api_token}

      settings.tracker.kind == "github_projects" and settings.tracker.owner_type not in ["organization", "user"] ->
        {:error, :invalid_github_owner_type}

      settings.tracker.kind == "github_projects" and not is_binary(settings.tracker.owner_login) ->
        {:error, {:invalid_workflow_config, "tracker.owner_login must be set for github_projects"}}

      settings.tracker.kind == "github_projects" and not is_integer(settings.tracker.project_number) ->
        {:error, {:invalid_workflow_config, "tracker.project_number must be an integer for github_projects"}}

      settings.tracker.kind == "github_projects" and not is_binary(settings.tracker.repository) ->
        {:error, :invalid_github_repository}

      settings.tracker.kind == "github_projects" and not is_binary(settings.tracker.status_field_name) ->
        {:error, {:invalid_workflow_config, "tracker.status_field_name must be set for github_projects"}}

      settings.tracker.kind == "github_projects" and priority_field_name == settings.tracker.status_field_name ->
        {:error, {:invalid_workflow_config, "tracker.priority_field_name must not match tracker.status_field_name"}}

      settings.tracker.kind == "github_projects" and is_nil(priority_field_name) and present_map?(priority_option_map) ->
        {:error, {:invalid_workflow_config, "tracker.priority_option_map requires tracker.priority_field_name for github_projects"}}

      settings.tracker.kind == "github_projects" and normalized_tracker_assignee == "" ->
        {:error, {:invalid_workflow_config, "tracker.assignee must be an explicit GitHub login for github_projects"}}

      settings.tracker.kind == "github_projects" and normalized_tracker_assignee == "me" ->
        {:error, {:invalid_workflow_config, "tracker.assignee: me is not supported for github_projects; use an explicit GitHub login"}}

      true ->
        validate_tracker_backend(settings)
    end
  end

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
