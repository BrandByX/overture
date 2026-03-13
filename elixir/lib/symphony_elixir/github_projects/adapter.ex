defmodule SymphonyElixir.GitHubProjects.Adapter do
  @moduledoc """
  GitHub Projects-backed tracker adapter placeholder for the migration path.

  Ticket `#3` establishes the runtime config and issue model contract. Full
  polling and mutation behavior lands in the subsequent adapter implementation
  ticket.

  Returns `{:error, :github_projects_not_implemented}` for runtime operations.
  """

  @behaviour SymphonyElixir.Tracker

  @doc """
  Return the placeholder fetch response for candidate issues.

  Ticket `#3` establishes the runtime contract only; candidate polling lands in
  the subsequent adapter implementation ticket.

  Returns `{:error, :github_projects_not_implemented}`.
  """
  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: {:error, :github_projects_not_implemented}

  @doc """
  Return the placeholder fetch response for state-scoped issues.

  Ticket `#3` does not implement GitHub Projects polling yet.

  Returns `{:error, :github_projects_not_implemented}`.
  """
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(_states), do: {:error, :github_projects_not_implemented}

  @doc """
  Return the placeholder fetch response for issue state refresh.

  Ticket `#3` does not implement GitHub Projects state refresh yet.

  Returns `{:error, :github_projects_not_implemented}`.
  """
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(_issue_ids), do: {:error, :github_projects_not_implemented}

  @doc """
  Return the placeholder mutation response for tracker comments.

  Ticket `#3` does not implement GitHub Projects mutations yet.

  Returns `{:error, :github_projects_not_implemented}`.
  """
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(_issue_id, _body), do: {:error, :github_projects_not_implemented}

  @doc """
  Return the placeholder mutation response for tracker state updates.

  Ticket `#3` does not implement GitHub Projects mutations yet.

  Returns `{:error, :github_projects_not_implemented}`.
  """
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(_issue_id, _state_name), do: {:error, :github_projects_not_implemented}
end
