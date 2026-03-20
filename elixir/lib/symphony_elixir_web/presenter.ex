defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{CodexBudget, Config, Orchestrator, StatusDashboard}
  alias SymphonyElixirWeb.WorkspaceInspector

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    codex_info = codex_info()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          codex: codex_info,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload(&1, codex_info)),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload(&1, codex_info)),
          codex_totals: codex_totals_payload(snapshot.codex_totals, codex_info),
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    codex_info = codex_info()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, codex_info)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, codex_info) do
    workspace_path = workspace_path(issue_identifier, running, retry)
    worker_host = workspace_host(running, retry)
    workspace_summary = WorkspaceInspector.summarize(workspace_path, worker_host)

    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      codex: codex_info,
      workspace: %{
        path: workspace_path,
        host: worker_host
      },
      phase: issue_phase(running, retry, workspace_summary),
      estimated_cost: issue_estimated_cost(running, codex_info),
      workspace_summary: workspace_summary,
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running, codex_info, workspace_summary),
      retry: retry && retry_issue_payload(retry, codex_info, workspace_summary),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry, codex_info) do
    workspace_summary = WorkspaceInspector.summarize(Map.get(entry, :workspace_path), Map.get(entry, :worker_host))
    tokens = token_payload(entry)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      phase: phase_payload(entry.state, summarize_message(entry.last_codex_message), workspace_summary),
      workspace_summary: workspace_summary,
      tokens: tokens,
      estimated_cost: CodexBudget.estimated_cost_payload(tokens, codex_info)
    }
  end

  defp retry_entry_payload(entry, codex_info) do
    workspace_summary = WorkspaceInspector.summarize(Map.get(entry, :workspace_path), Map.get(entry, :worker_host))

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      phase: phase_payload("Retrying", entry.error, workspace_summary),
      workspace_summary: workspace_summary,
      estimated_cost: CodexBudget.estimated_cost_payload(%{input_tokens: 0, output_tokens: 0, total_tokens: 0}, codex_info)
    }
  end

  defp running_issue_payload(running, codex_info, workspace_summary) do
    tokens = token_payload(running)

    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      phase: phase_payload(running.state, summarize_message(running.last_codex_message), workspace_summary),
      workspace_summary: workspace_summary,
      tokens: tokens,
      estimated_cost: CodexBudget.estimated_cost_payload(tokens, codex_info)
    }
  end

  defp retry_issue_payload(retry, codex_info, workspace_summary) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      phase: phase_payload("Retrying", retry.error, workspace_summary),
      workspace_summary: workspace_summary,
      estimated_cost: CodexBudget.estimated_cost_payload(%{input_tokens: 0, output_tokens: 0, total_tokens: 0}, codex_info)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp codex_totals_payload(codex_totals, codex_info) do
    Map.put(codex_totals, :estimated_cost, CodexBudget.estimated_cost_payload(codex_totals, codex_info))
  end

  defp token_payload(entry) do
    %{
      input_tokens: Map.get(entry, :codex_input_tokens, 0),
      output_tokens: Map.get(entry, :codex_output_tokens, 0),
      total_tokens: Map.get(entry, :codex_total_tokens, 0)
    }
  end

  defp issue_phase(running, _retry, workspace_summary) when not is_nil(running) do
    phase_payload(running.state, summarize_message(running.last_codex_message), workspace_summary)
  end

  defp issue_phase(_running, retry, workspace_summary) when not is_nil(retry) do
    phase_payload("Retrying", retry.error, workspace_summary)
  end

  defp issue_phase(_running, _retry, _workspace_summary), do: phase_payload("Unknown", nil, nil)

  defp issue_estimated_cost(nil, codex_info),
    do: CodexBudget.estimated_cost_payload(%{input_tokens: 0, output_tokens: 0, total_tokens: 0}, codex_info)

  defp issue_estimated_cost(running, codex_info), do: CodexBudget.estimated_cost_payload(token_payload(running), codex_info)

  defp codex_info, do: CodexBudget.codex_info(Config.settings!())

  defp phase_payload(state, message, workspace_summary) do
    normalized_state = state |> to_string() |> String.downcase()
    normalized_message = message |> to_string() |> String.downcase()
    dirty = workspace_summary && Map.get(workspace_summary, :dirty, false)

    cond do
      String.contains?(normalized_state, "merging") ->
        %{label: "Merging", tone: "active", detail: "Landing approved work"}

      String.contains?(normalized_state, "review") ->
        %{label: "Waiting for review", tone: "warning", detail: "Awaiting approval"}

      String.contains?(normalized_state, "retry") ->
        %{label: "Retrying", tone: "warning", detail: "Waiting for the next retry window"}

      String.contains?(normalized_message, "approval requested") ->
        %{label: "Awaiting approval", tone: "warning", detail: message}

      String.contains?(normalized_message, "command") ->
        %{label: "Running commands", tone: "active", detail: message}

      String.contains?(normalized_message, "tool") or String.contains?(normalized_message, "mcp") ->
        %{label: "Using tools", tone: "neutral", detail: message}

      String.contains?(normalized_message, "turn diff") or dirty ->
        %{label: "Editing", tone: "active", detail: message || "Workspace changes detected"}

      String.contains?(normalized_message, "reasoning") ->
        %{label: "Investigating", tone: "neutral", detail: message}

      String.contains?(normalized_state, "progress") ->
        %{label: "Working", tone: "active", detail: message || "Agent is actively working"}

      true ->
        %{label: "Queued", tone: "neutral", detail: message || "Waiting for new activity"}
    end
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
