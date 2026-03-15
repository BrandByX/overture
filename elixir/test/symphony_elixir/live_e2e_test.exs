defmodule SymphonyElixir.LiveE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubProjects.Client
  alias SymphonyElixir.LiveSmokeSupport
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Workflow

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

    write_live_workflow!(context)
    :ok = LiveSmokeSupport.verify_schema_contract!()

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

  test "github projects live smoke settles once work is handed off to Human Review" do
    runtime_context = LiveSmokeSupport.create_runtime_context!()
    issue_fixture = LiveSmokeSupport.create_issue_fixture!(runtime_context, title_prefix: "Overture live smoke human review", status_name: "Todo")
    context = Map.put(runtime_context, :issue, issue_fixture)
    :ok = LiveSmokeSupport.write_status_codex!(context, issue_fixture, "Human Review")

    write_live_workflow!(context)
    :ok = LiveSmokeSupport.verify_schema_contract!()

    orchestrator_name = Module.concat(__MODULE__, HumanReviewSmokeOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid) do
        Process.exit(orchestrator_pid, :normal)
      end

      LiveSmokeSupport.cleanup_issue_fixture!(context, issue_fixture)
      LiveSmokeSupport.cleanup_runtime!(context)
    end)

    assert LiveSmokeSupport.wait_for_claimed_issue!(orchestrator_pid, issue_fixture.item_id) ==
             issue_fixture.item_id

    :ok = LiveSmokeSupport.wait_for_project_item_state!(context, issue_fixture.item_id, "Human Review")
    :ok = LiveSmokeSupport.wait_for_orchestrator_idle!(orchestrator_pid, context, timeout_ms: 10_000)

    refute Enum.any?(LiveSmokeSupport.fetch_candidate_issues!(), &(&1.id == issue_fixture.item_id))

    trace = File.read!(context.trace_file)
    assert trace =~ "call-live-smoke-comment"
    assert trace =~ "call-live-smoke-status"
    refute trace =~ "call-live-smoke-close"
  end

  test "github projects live smoke keeps same-board Todo work blocked until the blocker reaches Done" do
    context = LiveSmokeSupport.create_runtime_context!()
    blocker = LiveSmokeSupport.create_issue_fixture!(context, title_prefix: "Overture live smoke blocker", status_name: "Backlog")
    dependent = LiveSmokeSupport.create_issue_fixture!(context, title_prefix: "Overture live smoke dependent", status_name: "Todo")
    :ok = LiveSmokeSupport.add_blocker!(context, dependent, blocker)

    write_live_workflow!(context, codex_command: "#{context.hold_codex_binary} app-server")
    :ok = LiveSmokeSupport.verify_schema_contract!()

    orchestrator_name = Module.concat(__MODULE__, SameBoardBlockerSmokeOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid) do
        Process.exit(orchestrator_pid, :normal)
      end

      safe_remove_blocker(context, dependent, blocker)
      LiveSmokeSupport.cleanup_issue_fixture!(context, dependent)
      LiveSmokeSupport.cleanup_issue_fixture!(context, blocker)
      LiveSmokeSupport.cleanup_runtime!(context)
    end)

    dependent_issue = fetch_candidate_issue!(dependent.item_id)

    assert Enum.any?(dependent_issue.blocked_by, fn blocker_ref ->
             blocker_ref.identifier == blocker.identifier and blocker_ref.state == "Backlog"
           end)

    :ok = LiveSmokeSupport.assert_issue_unclaimed!(orchestrator_pid, dependent.item_id)
    :ok = LiveSmokeSupport.set_issue_status!(context, blocker, "Done")
    assert LiveSmokeSupport.wait_for_claimed_issue!(orchestrator_pid, dependent.item_id) == dependent.item_id
  end

  test "github projects live smoke unblocks Todo work when an off-board blocker closes" do
    context = LiveSmokeSupport.create_runtime_context!()
    blocker = LiveSmokeSupport.create_issue_fixture!(context, title_prefix: "Overture live smoke off-board blocker", add_to_project?: false)
    dependent = LiveSmokeSupport.create_issue_fixture!(context, title_prefix: "Overture live smoke off-board dependent", status_name: "Todo")
    :ok = LiveSmokeSupport.add_blocker!(context, dependent, blocker)

    write_live_workflow!(context, codex_command: "#{context.hold_codex_binary} app-server")
    :ok = LiveSmokeSupport.verify_schema_contract!()

    orchestrator_name = Module.concat(__MODULE__, OffBoardBlockerSmokeOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid) do
        Process.exit(orchestrator_pid, :normal)
      end

      safe_remove_blocker(context, dependent, blocker)
      LiveSmokeSupport.cleanup_issue_fixture!(context, dependent)
      LiveSmokeSupport.cleanup_issue_fixture!(context, blocker)
      LiveSmokeSupport.cleanup_runtime!(context)
    end)

    dependent_issue = fetch_candidate_issue!(dependent.item_id)

    assert Enum.any?(dependent_issue.blocked_by, fn blocker_ref ->
             blocker_ref.identifier == blocker.identifier and blocker_ref.state == "OPEN"
           end)

    :ok = LiveSmokeSupport.assert_issue_unclaimed!(orchestrator_pid, dependent.item_id)
    :ok = LiveSmokeSupport.close_issue!(context, blocker)
    assert LiveSmokeSupport.wait_for_claimed_issue!(orchestrator_pid, dependent.item_id) == dependent.item_id
  end

  test "github projects live smoke dispatches higher-priority work first with one slot" do
    context = LiveSmokeSupport.create_runtime_context!()
    high_priority = LiveSmokeSupport.create_issue_fixture!(context, title_prefix: "Overture live smoke priority one", status_name: "Todo", priority: 1)
    low_priority = LiveSmokeSupport.create_issue_fixture!(context, title_prefix: "Overture live smoke priority three", status_name: "Todo", priority: 3)

    write_live_workflow!(
      context,
      codex_command: "#{context.hold_codex_binary} app-server",
      tracker_priority_field_name: "Priority"
    )

    :ok = LiveSmokeSupport.verify_schema_contract!()

    orchestrator_name = Module.concat(__MODULE__, PrioritySmokeOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(orchestrator_pid) do
        Process.exit(orchestrator_pid, :normal)
      end

      LiveSmokeSupport.cleanup_issue_fixture!(context, low_priority)
      LiveSmokeSupport.cleanup_issue_fixture!(context, high_priority)
      LiveSmokeSupport.cleanup_runtime!(context)
    end)

    assert LiveSmokeSupport.wait_for_claimed_issue!(orchestrator_pid, high_priority.item_id) == high_priority.item_id
    :ok = LiveSmokeSupport.assert_issue_unclaimed!(orchestrator_pid, low_priority.item_id, duration_ms: 750)
  end

  test "github projects live smoke keeps branch_name nil when two linked branches exist" do
    context = LiveSmokeSupport.create_runtime_context!()
    issue_fixture = LiveSmokeSupport.create_issue_fixture!(context, title_prefix: "Overture live smoke branch ambiguity", status_name: "Todo")
    branch_one_name = "overture-live-smoke-#{context.run_id}-a"
    branch_two_name = "overture-live-smoke-#{context.run_id}-b"
    branch_one = LiveSmokeSupport.create_linked_branch!(context, issue_fixture, branch_one_name)
    branch_two = LiveSmokeSupport.create_linked_branch!(context, issue_fixture, branch_two_name)

    write_live_workflow!(context)
    :ok = LiveSmokeSupport.verify_schema_contract!()

    on_exit(fn ->
      linked_branches =
        if is_binary(branch_one.ref_id) and is_binary(branch_two.ref_id) do
          [branch_two, branch_one]
        else
          context
          |> LiveSmokeSupport.refetch_linked_branches!(issue_fixture)
          |> Enum.filter(fn linked_branch ->
            linked_branch.ref_name in [branch_one_name, branch_two_name]
          end)
        end

      Enum.each(linked_branches, fn linked_branch ->
        LiveSmokeSupport.cleanup_linked_branch!(context, linked_branch)
      end)

      LiveSmokeSupport.cleanup_issue_fixture!(context, issue_fixture)
      LiveSmokeSupport.cleanup_runtime!(context)
    end)

    branch_issue = fetch_candidate_issue!(issue_fixture.item_id)

    assert branch_issue.branch_name == nil
  end

  # Write the live smoke workflow file with optional overrides.
  #
  # Uses the shared live smoke workflow contract and then applies the scenario-
  # specific overrides so each test exercises the intended runtime path.
  #
  # Returns `:ok`.
  defp write_live_workflow!(context, overrides \\ []) do
    workflow_overrides = Keyword.merge(LiveSmokeSupport.workflow_overrides(context), overrides)
    write_workflow_file!(Workflow.workflow_file_path(), workflow_overrides)
  end

  # Fetch one live candidate issue by project item ID.
  #
  # Raises when the requested issue is missing so smoke assertions fail with a
  # clear tracker-normalization error instead of a later nil dereference.
  #
  # Returns the normalized issue struct.
  defp fetch_candidate_issue!(issue_id) when is_binary(issue_id) do
    case Enum.find(LiveSmokeSupport.fetch_candidate_issues!(), &(&1.id == issue_id)) do
      nil -> raise "Live smoke could not find candidate issue #{issue_id}."
      issue -> issue
    end
  end

  # Remove a blocker relationship during cleanup without masking the main test.
  #
  # Cleanup should be best effort because the issues themselves are disposable.
  #
  # Returns `:ok`.
  defp safe_remove_blocker(context, dependent, blocker) do
    LiveSmokeSupport.remove_blocker!(context, dependent, blocker)
  rescue
    _error -> :ok
  end
end
