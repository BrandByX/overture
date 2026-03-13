defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Store the normalized tracker issue representation used by the orchestrator.

  Use this struct as the provider-neutral runtime shape for tracker polling,
  routing, retries, and prompt building.

  Returns a `%SymphonyElixir.Tracker.Issue{}` struct.
  """

  defstruct [
    :id,
    :content_id,
    :content_number,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :content_state,
    :content_state_reason,
    :branch_name,
    :url,
    assignee_logins: [],
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          content_id: String.t() | nil,
          content_number: integer() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          content_state: String.t() | nil,
          content_state_reason: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_logins: [String.t()],
          blocked_by: [map()],
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Return normalized label names for a tracker issue.

  Use this helper when prompts or logs need the tracker label list in a stable
  string form.

  Returns a list of label strings.
  """
  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
