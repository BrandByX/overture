defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.GitHubProjects.Client, as: GitHubProjectsClient

  test "tool_specs advertises the github_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "operationName" => _,
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "github_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "GitHub"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["github_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "github_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_graphql",
        %{
          "query" => "query Viewer { viewer { login } }",
          "variables" => %{"includeProjects" => false}
        },
        github_client: fn query, variables, opts ->
          send(test_pid, {:github_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"login" => "sid"}}}}
        end
      )

    assert_received {:github_client_called, "query Viewer { viewer { login } }", %{"includeProjects" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"login" => "sid"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "github_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_graphql",
        "  query Viewer { viewer { login } }  ",
        github_client: fn query, variables, opts ->
          send(test_pid, {:github_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"login" => "sid"}}}}
        end
      )

    assert_received {:github_client_called, "query Viewer { viewer { login } }", %{}, []}
    assert response["success"] == true
  end

  test "github_graphql forwards operationName arguments to the GitHub client" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_graphql",
        %{
          "query" => "query Viewer { viewer { login } }\nquery Repositories { viewer { repositories(first: 5) { nodes { name } } } }",
          "operationName" => "Viewer"
        },
        github_client: fn query, variables, opts ->
          send(test_pid, {:github_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"login" => "sid"}}}}
        end
      )

    assert_received {:github_client_called, query, %{}, opts}
    assert query =~ "query Viewer"
    assert Keyword.get(opts, :operation_name) == "Viewer"
    assert response["success"] == true
  end

  test "github_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { login } }
    query Repositories { viewer { repositories(first: 5) { nodes { name } } } }
    """

    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => query},
        github_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:github_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:github_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "github_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("github_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`github_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "github_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        github_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "github_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "github_graphql validates required arguments before calling GitHub" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`github_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "   "},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "github_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "github_graphql",
        [:not, :valid],
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`github_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "github_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }", "variables" => ["bad"]},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`github_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "github_graphql rejects invalid operation names" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }", "operationName" => 123},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when operationName is invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`github_graphql.operationName` must be a string when provided."
             }
           }
  end

  test "github_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts -> {:error, :missing_github_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Overture is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
             }
           }

    status_error =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts -> {:error, {:github_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "GitHub GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts -> {:error, {:github_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "GitHub GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "github_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "GitHub GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "github_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  test "github_graphql uses explicit tracker auth when tracker.api_key is set" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: &GitHubProjectsClient.graphql/3,
        tracker: %{api_key: "ghs_explicit_token"},
        request_fun: fn payload, headers ->
          send(test_pid, {:graphql_request, payload, headers})
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "sid"}}}}}
        end
      )

    assert_received {:graphql_request, %{"query" => "query Viewer { viewer { login } }", "variables" => %{}}, headers}
    assert {"authorization", "Bearer ghs_explicit_token"} in headers
    assert response["success"] == true
  end

  test "github_graphql falls back through the same GITHUB_TOKEN resolution path as the tracker client" do
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      if is_binary(previous_github_token) do
        System.put_env("GITHUB_TOKEN", previous_github_token)
      else
        System.delete_env("GITHUB_TOKEN")
      end
    end)

    System.put_env("GITHUB_TOKEN", "ghp_fallback_token")
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: &GitHubProjectsClient.graphql/3,
        tracker: %{api_key: "$GITHUB_TOKEN"},
        request_fun: fn payload, headers ->
          send(test_pid, {:graphql_request, payload, headers})
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "sid"}}}}}
        end
      )

    assert_received {:graphql_request, %{"query" => "query Viewer { viewer { login } }", "variables" => %{}}, headers}
    assert {"authorization", "Bearer ghp_fallback_token"} in headers
    assert response["success"] == true
  end

  test "github_graphql missing auth matches the tracker client's missing auth path" do
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      if is_binary(previous_github_token) do
        System.put_env("GITHUB_TOKEN", previous_github_token)
      else
        System.delete_env("GITHUB_TOKEN")
      end
    end)

    System.delete_env("GITHUB_TOKEN")

    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: &GitHubProjectsClient.graphql/3,
        tracker: %{api_key: "$GITHUB_TOKEN"},
        request_fun: fn _payload, _headers ->
          flunk("request_fun should not be called when GitHub auth is missing")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Overture is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
             }
           }

    assert {:error, :missing_github_api_token} =
             GitHubProjectsClient.graphql(
               "query Viewer { viewer { login } }",
               %{},
               tracker: %{api_key: "$GITHUB_TOKEN"},
               request_fun: fn _payload, _headers ->
                 flunk("request_fun should not be called when GitHub auth is missing")
               end
             )
  end
end
