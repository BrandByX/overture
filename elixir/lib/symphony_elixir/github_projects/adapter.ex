defmodule SymphonyElixir.GitHubProjects.Adapter do
  @moduledoc """
  Delegate tracker reads and writes to the GitHub Projects client.

  Keeps the tracker boundary thin while the GitHub Projects client owns the
  polling, normalization, and mutation details.

  Returns tracker read results or tracker write results from the client.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHubProjects.Client
  alias SymphonyElixir.Tracker.Issue

  @doc """
  Fetch active issue-backed project items for dispatch.

  Delegates to the GitHub Projects client.

  Returns `{:ok, issues}` or `{:error, reason}`.
  """
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    Client.fetch_candidate_issues()
  end

  @doc """
  Fetch issue-backed project items for the requested board states.

  Delegates to the GitHub Projects client.

  Returns `{:ok, issues}` or `{:error, reason}`.
  """
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    Client.fetch_issues_by_states(states)
  end

  @doc """
  Refresh issue-backed project items by canonical project item ID.

  Delegates to the GitHub Projects client.

  Returns `{:ok, issues}` or `{:error, reason}`.
  """
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    Client.fetch_issue_states_by_ids(issue_ids)
  end

  @doc """
  Create a comment on the linked GitHub issue for a tracker item.

  Delegates to the GitHub Projects client.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec create_comment(Issue.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(%Issue{} = issue, body) do
    Client.create_comment(issue, body)
  end

  @doc """
  Update the project status for a tracker item and reconcile the linked issue.

  Delegates to the GitHub Projects client.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec update_issue_state(Issue.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(%Issue{} = issue, state_name) do
    Client.update_issue_state(issue, state_name)
  end
end
