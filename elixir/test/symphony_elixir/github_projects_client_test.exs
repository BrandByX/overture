defmodule SymphonyElixir.GitHubProjectsClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubProjects.Client
  alias SymphonyElixir.Tracker.Issue

  test "fetch_candidate_issues normalizes issue-backed items and skips non-runnable content" do
    tracker = %{Config.settings!().tracker | assignee: "sidney"}

    request_fun = fn payload, headers ->
      send(self(), {:github_request, payload["operationName"], payload, headers})

      case payload["operationName"] do
        "OvertureProjectFieldContract" ->
          {:ok, %{status: 200, body: project_contract_response()}}

        "OvertureProjectItems" ->
          {:ok,
           %{
             status: 200,
             body:
               project_items_response([
                 issue_item("project-item-1", "Todo",
                   issue:
                     issue_node("issue-node-1", 101,
                       assignees: ["sidney"],
                       labels: ["Branding", "UI"]
                     )
                 ),
                 issue_item("project-item-2", "In Progress", issue: issue_node("issue-node-2", 102, assignees: ["jane"])),
                 pull_request_item("project-item-pr", "Todo"),
                 draft_item("project-item-draft", "Todo"),
                 issue_item("project-item-wrong-repo", "Todo", issue: issue_node("issue-node-3", 103, repository: "BrandByX/other")),
                 issue_item("project-item-terminal", "Done", issue: issue_node("issue-node-4", 104, assignees: ["sidney"]))
               ])
           }}

        "OvertureCloseIssue" ->
          {:ok, %{status: 200, body: close_issue_response("issue-node-4")}}
      end
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(tracker, request_fun)

    assert Enum.map(issues, & &1.id) == ["project-item-1", "project-item-2"]

    assert [
             %Issue{
               id: "project-item-1",
               content_id: "issue-node-1",
               content_number: 101,
               identifier: "BrandByX/overture#101",
               state: "Todo",
               content_state: "OPEN",
               labels: ["branding", "ui"],
               assignee_logins: ["sidney"],
               assigned_to_worker: true
             },
             %Issue{
               id: "project-item-2",
               content_id: "issue-node-2",
               content_number: 102,
               identifier: "BrandByX/overture#102",
               state: "In Progress",
               assignee_logins: ["jane"],
               assigned_to_worker: false
             }
           ] = issues

    assert_received {:github_request, "OvertureProjectFieldContract", _payload, headers}
    header_map = Map.new(headers)
    assert header_map["authorization"] == "Bearer token"
    assert header_map["user-agent"] == "Overture"
    assert_received {:github_request, "OvertureProjectItems", _payload, _headers}
  end

  test "fetch_issues_by_states ignores assignee routing so cleanup can see all matching items" do
    tracker = %{Config.settings!().tracker | assignee: "sidney"}

    request_fun = fn payload, _headers ->
      case payload["operationName"] do
        "OvertureProjectFieldContract" ->
          {:ok, %{status: 200, body: project_contract_response()}}

        "OvertureProjectItems" ->
          {:ok,
           %{
             status: 200,
             body:
               project_items_response([
                 issue_item("project-item-done", "Done", issue: issue_node("issue-node-done", 201, assignees: ["jane"], state: "OPEN"))
               ])
           }}

        "OvertureCloseIssue" ->
          {:ok, %{status: 200, body: close_issue_response("issue-node-done")}}
      end
    end

    assert {:ok, [%Issue{} = issue]} =
             Client.fetch_issues_by_states_for_test(tracker, ["Done"], request_fun)

    assert issue.id == "project-item-done"
    assert issue.assignee_logins == ["jane"]
    assert issue.assigned_to_worker
    assert issue.content_state == "CLOSED"
    assert issue.content_state_reason == "COMPLETED"
  end

  test "fetch_issue_states_by_ids preserves request order and reconciles active and terminal content state" do
    tracker = %{Config.settings!().tracker | assignee: "sidney"}

    request_fun = fn payload, _headers ->
      send(self(), {:github_request, payload["operationName"], payload})

      case payload["operationName"] do
        "OvertureProjectFieldContract" ->
          {:ok, %{status: 200, body: project_contract_response()}}

        "OvertureProjectItemsById" ->
          {:ok,
           %{
             status: 200,
             body:
               project_item_batch_response([
                 issue_item("project-item-1", "Done", issue: issue_node("issue-node-1", 301, assignees: ["jane"], state: "OPEN")),
                 issue_item("project-item-2", "Todo",
                   issue:
                     issue_node("issue-node-2", 302,
                       assignees: ["sidney"],
                       state: "CLOSED",
                       state_reason: "COMPLETED"
                     )
                 ),
                 pull_request_item("project-item-pr", "Todo")
               ])
           }}

        "OvertureCloseIssue" ->
          {:ok, %{status: 200, body: close_issue_response("issue-node-1")}}

        "OvertureReopenIssue" ->
          {:ok, %{status: 200, body: reopen_issue_response("issue-node-2")}}
      end
    end

    assert {:ok, issues} =
             Client.fetch_issue_states_by_ids_for_test(
               tracker,
               ["project-item-2", "project-item-1"],
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["project-item-2", "project-item-1"]

    assert [
             %Issue{
               id: "project-item-2",
               content_state: "OPEN",
               content_state_reason: nil
             },
             %Issue{
               id: "project-item-1",
               content_state: "CLOSED",
               content_state_reason: "COMPLETED"
             }
           ] = issues

    assert_received {:github_request, "OvertureProjectItemsById", payload}
    assert payload["variables"][:ids] == ["project-item-2", "project-item-1"]
    assert_received {:github_request, "OvertureCloseIssue", close_payload}
    assert close_payload["variables"][:contentId] == "issue-node-1"
    assert close_payload["variables"][:stateReason] == "COMPLETED"
    assert_received {:github_request, "OvertureReopenIssue", reopen_payload}
    assert reopen_payload["variables"][:contentId] == "issue-node-2"
  end

  test "create_comment uses the linked issue content id and tracker auth contract" do
    tracker = Config.settings!().tracker
    issue = %Issue{id: "project-item-1", content_id: "issue-node-1", identifier: "BrandByX/overture#401"}

    request_fun = fn payload, headers ->
      send(self(), {:github_request, payload["operationName"], payload, headers})
      {:ok, %{status: 200, body: add_comment_response("comment-node-1")}}
    end

    assert :ok = Client.create_comment_for_test(issue, "hello world", tracker, request_fun)

    assert_received {:github_request, "OvertureAddComment", payload, headers}
    assert payload["variables"][:contentId] == "issue-node-1"
    assert payload["variables"][:body] == "hello world"

    header_map = Map.new(headers)
    assert header_map["authorization"] == "Bearer token"
    assert header_map["accept"] == "application/vnd.github+json"
  end

  test "update_issue_state updates the project item and closes duplicate issues with deterministic reasons" do
    tracker = Config.settings!().tracker

    issue = %Issue{
      id: "project-item-dup",
      content_id: "issue-node-dup",
      identifier: "BrandByX/overture#501",
      state: "In Progress",
      content_state: "OPEN"
    }

    request_fun = fn payload, _headers ->
      send(self(), {:github_request, payload["operationName"], payload})

      case payload["operationName"] do
        "OvertureProjectFieldContract" ->
          {:ok, %{status: 200, body: project_contract_response()}}

        "OvertureUpdateProjectState" ->
          {:ok, %{status: 200, body: update_state_response("project-item-dup")}}

        "OvertureCloseIssue" ->
          {:ok, %{status: 200, body: close_issue_response("issue-node-dup")}}
      end
    end

    assert :ok = Client.update_issue_state_for_test(issue, "Duplicate", tracker, request_fun)

    assert_received {:github_request, "OvertureUpdateProjectState", update_payload}
    assert update_payload["variables"][:itemId] == "project-item-dup"
    assert update_payload["variables"][:projectId] == "project-node-1"
    assert update_payload["variables"][:fieldId] == "status-field-1"
    assert update_payload["variables"][:optionId] == "option-duplicate"

    assert_received {:github_request, "OvertureCloseIssue", close_payload}
    assert close_payload["variables"][:contentId] == "issue-node-dup"
    assert close_payload["variables"][:stateReason] == "DUPLICATE"
  end

  test "update_issue_state reopens closed issues when moving into an active workflow state" do
    tracker = Config.settings!().tracker

    issue = %Issue{
      id: "project-item-rework",
      content_id: "issue-node-rework",
      identifier: "BrandByX/overture#601",
      state: "Done",
      content_state: "CLOSED",
      content_state_reason: "COMPLETED"
    }

    request_fun = fn payload, _headers ->
      send(self(), {:github_request, payload["operationName"], payload})

      case payload["operationName"] do
        "OvertureProjectFieldContract" ->
          {:ok, %{status: 200, body: project_contract_response()}}

        "OvertureUpdateProjectState" ->
          {:ok, %{status: 200, body: update_state_response("project-item-rework")}}

        "OvertureReopenIssue" ->
          {:ok, %{status: 200, body: reopen_issue_response("issue-node-rework")}}
      end
    end

    assert :ok = Client.update_issue_state_for_test(issue, "Rework", tracker, request_fun)

    assert_received {:github_request, "OvertureUpdateProjectState", update_payload}
    assert update_payload["variables"][:optionId] == "option-rework"
    assert_received {:github_request, "OvertureReopenIssue", reopen_payload}
    assert reopen_payload["variables"][:contentId] == "issue-node-rework"
  end

  defp project_contract_response do
    %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "project-node-1",
            "fields" => %{
              "nodes" => [
                %{
                  "__typename" => "ProjectV2SingleSelectField",
                  "id" => "status-field-1",
                  "name" => "Status",
                  "options" => [
                    %{"id" => "option-backlog", "name" => "Backlog"},
                    %{"id" => "option-todo", "name" => "Todo"},
                    %{"id" => "option-in-progress", "name" => "In Progress"},
                    %{"id" => "option-human-review", "name" => "Human Review"},
                    %{"id" => "option-rework", "name" => "Rework"},
                    %{"id" => "option-merging", "name" => "Merging"},
                    %{"id" => "option-done", "name" => "Done"},
                    %{"id" => "option-cancelled", "name" => "Cancelled"},
                    %{"id" => "option-duplicate", "name" => "Duplicate"}
                  ]
                }
              ]
            }
          }
        },
        "user" => nil
      }
    }
  end

  defp project_items_response(nodes) do
    %{
      "data" => %{
        "node" => %{
          "items" => %{
            "nodes" => nodes,
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      }
    }
  end

  defp project_item_batch_response(nodes) do
    %{"data" => %{"nodes" => nodes}}
  end

  defp add_comment_response(comment_id) do
    %{
      "data" => %{
        "addComment" => %{
          "commentEdge" => %{"node" => %{"id" => comment_id}}
        }
      }
    }
  end

  defp update_state_response(item_id) do
    %{
      "data" => %{
        "updateProjectV2ItemFieldValue" => %{
          "projectV2Item" => %{"id" => item_id}
        }
      }
    }
  end

  defp close_issue_response(issue_id) do
    %{
      "data" => %{
        "closeIssue" => %{
          "issue" => %{
            "id" => issue_id,
            "state" => "CLOSED",
            "stateReason" => "COMPLETED"
          }
        }
      }
    }
  end

  defp reopen_issue_response(issue_id) do
    %{
      "data" => %{
        "reopenIssue" => %{
          "issue" => %{"id" => issue_id, "state" => "OPEN", "stateReason" => nil}
        }
      }
    }
  end

  defp issue_item(project_item_id, state_name, attrs) do
    %{
      "__typename" => "ProjectV2Item",
      "id" => project_item_id,
      "isArchived" => Keyword.get(attrs, :archived, false),
      "fieldValueByName" => %{
        "__typename" => "ProjectV2ItemFieldSingleSelectValue",
        "name" => state_name,
        "optionId" => "option-#{state_name |> String.downcase() |> String.replace(" ", "-")}"
      },
      "content" => Keyword.fetch!(attrs, :issue)
    }
  end

  defp pull_request_item(project_item_id, state_name) do
    %{
      "__typename" => "ProjectV2Item",
      "id" => project_item_id,
      "isArchived" => false,
      "fieldValueByName" => %{
        "__typename" => "ProjectV2ItemFieldSingleSelectValue",
        "name" => state_name,
        "optionId" => "option-#{state_name |> String.downcase() |> String.replace(" ", "-")}"
      },
      "content" => %{"__typename" => "PullRequest", "id" => "pr-node-1"}
    }
  end

  defp draft_item(project_item_id, state_name) do
    %{
      "__typename" => "ProjectV2Item",
      "id" => project_item_id,
      "isArchived" => false,
      "fieldValueByName" => %{
        "__typename" => "ProjectV2ItemFieldSingleSelectValue",
        "name" => state_name,
        "optionId" => "option-#{state_name |> String.downcase() |> String.replace(" ", "-")}"
      },
      "content" => %{"__typename" => "DraftIssue", "title" => "Draft"}
    }
  end

  defp issue_node(issue_id, issue_number, attrs) do
    repository = Keyword.get(attrs, :repository, "BrandByX/overture")
    assignees = Keyword.get(attrs, :assignees, [])
    labels = Keyword.get(attrs, :labels, [])
    state = Keyword.get(attrs, :state, "OPEN")
    state_reason = Keyword.get(attrs, :state_reason)

    %{
      "__typename" => "Issue",
      "id" => issue_id,
      "number" => issue_number,
      "title" => "Issue #{issue_number}",
      "body" => "Body #{issue_number}",
      "url" => "https://github.com/#{repository}/issues/#{issue_number}",
      "state" => state,
      "stateReason" => state_reason,
      "repository" => %{"nameWithOwner" => repository},
      "assignees" => %{"nodes" => Enum.map(assignees, &%{"login" => &1})},
      "labels" => %{"nodes" => Enum.map(labels, &%{"name" => &1})},
      "createdAt" => "2026-03-13T16:00:00Z",
      "updatedAt" => "2026-03-13T17:00:00Z"
    }
  end
end
