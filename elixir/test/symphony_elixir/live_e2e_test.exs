defmodule SymphonyElixir.LiveE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubProjects.Client
  alias SymphonyElixir.LiveSmokeSupport
  alias SymphonyElixir.Orchestrator

  @moduletag :live_e2e
  @moduletag timeout: 120_000

  @skip_reason LiveSmokeSupport.skip_reason()

  if @skip_reason do
    @moduletag skip: @skip_reason
  end

  setup do
    previous_client_module =
      Application.get_env(:symphony_elixir, :github_projects_client_module)

    Application.put_env(:symphony_elixir, :github_projects_client_module, Client)

    on_exit(fn ->
      if is_nil(previous_client_module) do
        Application.delete_env(:symphony_elixir, :github_projects_client_module)
      else
        Application.put_env(
          :symphony_elixir,
          :github_projects_client_module,
          previous_client_module
        )
      end
    end)

    :ok
  end

  test "github projects live smoke processes issue-backed work and ignores pr-backed items" do
    context = LiveSmokeSupport.create_context!()
    expected_workspace = Path.basename(context.workspace_path)
    expected_pr_state = LiveSmokeSupport.pr_item_state!(context)

    write_workflow_file!(Workflow.workflow_file_path(), LiveSmokeSupport.workflow_overrides(context))

    orchestrator_name = Module.concat(__MODULE__, LiveSmokeOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid) do
        Process.exit(orchestrator_pid, :normal)
      end

      LiveSmokeSupport.cleanup!(context)
    end)

    proof = LiveSmokeSupport.wait_for_run_proof!(context, timeout_ms: 60_000)
    :ok = LiveSmokeSupport.wait_for_orchestrator_idle!(orchestrator_pid, context, timeout_ms: 10_000)

    assert String.trim(proof.marker_content) == context.marker_content
    assert proof.issue_state.state == "CLOSED"
    assert proof.issue_state.state_reason == "COMPLETED"
    assert proof.item_state == "Done"
    assert Enum.member?(proof.issue_state.comments, context.issue.comment_marker)
    assert File.dir?(context.workspace_path)
    assert File.exists?(context.trace_file)
    assert File.read!(context.trace_file) =~ "call-live-smoke-comment"
    assert File.read!(context.trace_file) =~ "call-live-smoke-done"
    assert File.read!(context.trace_file) =~ "call-live-smoke-close"
    assert File.ls!(context.workspace_root) == [expected_workspace]
    assert LiveSmokeSupport.pr_item_state!(context) == expected_pr_state
  end
end
