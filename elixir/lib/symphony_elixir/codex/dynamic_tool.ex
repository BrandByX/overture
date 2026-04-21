defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.GitHubProjects.Client

  @github_graphql_tool "github_graphql"
  @github_graphql_description """
  Execute a raw GraphQL query or mutation against GitHub using Overture's configured tracker auth.
  """
  @github_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against GitHub."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      },
      "operationName" => %{
        "type" => ["string", "null"],
        "description" => "Optional GraphQL operation name for multi-operation documents."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @github_graphql_tool ->
        execute_github_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @github_graphql_tool,
        "description" => @github_graphql_description,
        "inputSchema" => @github_graphql_input_schema
      }
    ]
  end

  # Execute the GitHub GraphQL dynamic tool with the shared tracker auth contract.
  #
  # Accepts either a raw GraphQL string or a map with `query` and optional
  # `variables`. Forwards tracker auth overrides through the GitHub client so
  # polling and tool calls resolve auth the same way.
  #
  # Returns a dynamic tool response map.
  defp execute_github_graphql(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &Client.graphql/3)
    client_opts = Keyword.take(opts, [:tracker, :request_fun, :operation_name])

    with {:ok, query, variables, operation_name} <- normalize_graphql_arguments(arguments),
         {:ok, response} <- github_client.(query, variables, put_operation_name(client_opts, operation_name)) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  # Normalize dynamic tool arguments into a GraphQL query and variables map.
  #
  # Accepts either a raw query string or a map with `query`, optional
  # `variables`, and optional `operationName`.
  #
  # Returns `{:ok, query, variables, operation_name}` or `{:error, reason}`.
  defp normalize_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}, nil}
    end
  end

  defp normalize_graphql_arguments(arguments) when is_map(arguments) do
    with {:ok, query} <- normalize_query(arguments),
         {:ok, variables} <- normalize_variables(arguments),
         {:ok, operation_name} <- normalize_operation_name(arguments) do
      {:ok, query, variables, operation_name}
    end
  end

  defp normalize_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_operation_name(arguments) do
    case Map.get(arguments, "operationName") || Map.get(arguments, :operationName) do
      nil ->
        {:ok, nil}

      operation_name when is_binary(operation_name) ->
        case String.trim(operation_name) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :invalid_operation_name}
    end
  end

  defp put_operation_name(client_opts, nil), do: client_opts
  defp put_operation_name(client_opts, operation_name), do: Keyword.put(client_opts, :operation_name, operation_name)

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`github_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`github_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`github_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:invalid_operation_name) do
    %{
      "error" => %{
        "message" => "`github_graphql.operationName` must be a string when provided."
      }
    }
  end

  defp tool_error_payload(:missing_github_api_token) do
    %{
      "error" => %{
        "message" => "Overture is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:github_api_status, status}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
