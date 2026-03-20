defmodule SymphonyElixirWeb.IssueLive do
  @moduledoc """
  Browser-friendly detail view for a single Symphony issue/session.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def mount(%{"issue_identifier" => issue_identifier}, _session, socket) do
    socket =
      socket
      |> assign(:issue_identifier, issue_identifier)
      |> assign_issue_payload()

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign_issue_payload(socket)}
  end

  @impl true
  def handle_event("stop_issue", %{"issue_id" => issue_id}, socket) do
    socket =
      case SymphonyElixir.Orchestrator.stop_issue(orchestrator(), issue_id) do
        {:ok, _payload} ->
          socket
          |> put_flash(:info, "Stopped issue #{socket.assigns.issue_identifier}")
          |> assign_issue_payload()

        {:error, :issue_not_found} ->
          put_flash(socket, :error, "Issue is no longer running")

        {:error, _reason} ->
          put_flash(socket, :error, "Unable to stop issue right now")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <div class="stack-sm">
              <a class="kicker-link" href="/">Back to dashboard</a>
              <p class="eyebrow">Issue Session</p>
            </div>
            <h1 class="hero-title hero-title-compact">
              <%= @issue_identifier %>
            </h1>
            <p class="hero-copy">
              Live workspace, token usage, attempts, and recent Codex activity for this issue.
            </p>
            <p :if={@status == :ok} class="hero-meta">
              <span class="mono"><%= @payload.codex.model %></span>
              <span>·</span>
              <span><%= String.capitalize(to_string(@payload.codex.reasoning_effort)) %> reasoning</span>
              <span>·</span>
              <span><%= @payload.estimated_cost.note %></span>
            </p>
            <div :if={@status == :ok and @payload.issue_id} class="hero-actions">
              <button
                type="button"
                class="secondary subtle-button-danger"
                phx-click="stop_issue"
                phx-value-issue_id={@payload.issue_id}
                data-confirm={"Stop #{@issue_identifier}?"}
              >
                Stop Issue
              </button>
            </div>
          </div>

          <div class="status-stack">
            <%= if @status == :ok do %>
              <span class={phase_badge_class(@payload.phase)}>
                <%= @payload.phase.label %>
              </span>
            <% else %>
              <span class="status-badge status-badge-offline">
                Not found
              </span>
            <% end %>
          </div>
        </div>
      </header>

      <%= if @status == :error do %>
        <section class="error-card">
          <h2 class="error-title">Issue not currently tracked</h2>
          <p class="error-copy">
            This issue is not active in the runtime right now. It may have completed, moved to a terminal
            state, or not been picked up yet.
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Workspace</p>
            <p class="metric-value metric-value-path"><%= short_path(@payload.workspace.path) %></p>
            <p class="metric-detail mono"><%= @payload.workspace.path %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Turns</p>
            <p class="metric-value numeric"><%= running_turns(@payload) %></p>
            <p class="metric-detail">Back-to-back Codex turns in the current invocation.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Estimated cost</p>
            <p class="metric-value numeric"><%= @payload.estimated_cost.formatted %></p>
            <p class="metric-detail"><%= @payload.estimated_cost.note %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(running_tokens(@payload, :total_tokens)) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(running_tokens(@payload, :input_tokens)) %> / Out <%= format_int(running_tokens(@payload, :output_tokens)) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Changes</p>
            <p class="metric-value numeric"><%= @payload.workspace_summary.changed_file_count %></p>
            <p class="metric-detail">
              <%= changes_summary(@payload.workspace_summary) %>
            </p>
          </article>
        </section>

        <section class="issue-grid">
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Live details</h2>
                <p class="section-copy">Current execution metadata for this session.</p>
              </div>
              <a class="subtle-link" href={"/api/v1/#{@issue_identifier}"} target="_blank" rel="noreferrer">
                Open raw JSON
              </a>
            </div>

            <div class="definition-list">
              <div class="definition-row">
                <span class="definition-term">Status</span>
                <span class="definition-value"><%= humanize_issue_status(@payload.status) %></span>
              </div>
              <div class="definition-row">
                <span class="definition-term">Phase</span>
                <span class="definition-value"><%= @payload.phase.label %></span>
              </div>
              <div class="definition-row">
                <span class="definition-term">Linear state</span>
                <span class="definition-value"><%= running_state(@payload) %></span>
              </div>
              <div class="definition-row">
                <span class="definition-term">Branch</span>
                <span class="definition-value mono"><%= @payload.workspace_summary.branch || "n/a" %></span>
              </div>
              <div class="definition-row">
                <span class="definition-term">Head</span>
                <span class="definition-value mono"><%= @payload.workspace_summary.head_sha || "n/a" %></span>
              </div>
              <div class="definition-row">
                <span class="definition-term">Session ID</span>
                <span class="definition-value mono wrap-anywhere"><%= running_value(@payload, :session_id) || "n/a" %></span>
              </div>
              <div class="definition-row">
                <span class="definition-term">Started</span>
                <span class="definition-value mono"><%= running_value(@payload, :started_at) || "n/a" %></span>
              </div>
              <div class="definition-row">
                <span class="definition-term">Worker host</span>
                <span class="definition-value"><%= @payload.workspace.host || "localhost" %></span>
              </div>
              <div :if={@payload.last_error} class="definition-row">
                <span class="definition-term">Last error</span>
                <span class="definition-value wrap-anywhere"><%= @payload.last_error %></span>
              </div>
            </div>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Recent activity</h2>
                <p class="section-copy">Most recent agent event surfaced by Symphony.</p>
              </div>
            </div>

            <%= if @payload.recent_events == [] do %>
              <p class="empty-state">No events recorded yet.</p>
            <% else %>
              <div class="activity-list">
                <article :for={event <- @payload.recent_events} class="activity-card">
                  <div class="activity-meta">
                    <span class="state-badge"><%= event.event || "event" %></span>
                    <span class="mono muted"><%= event.at || "n/a" %></span>
                  </div>
                  <p class="activity-copy"><%= event.message || "No message" %></p>
                </article>
              </div>
            <% end %>
          </section>
        </section>

        <section class="issue-grid">
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Workspace changes</h2>
                <p class="section-copy">Tracked file changes and diff summary from the current workspace.</p>
              </div>
            </div>

            <%= if @payload.workspace_summary.files == [] do %>
              <p class="empty-state"><%= changes_summary(@payload.workspace_summary) %></p>
            <% else %>
              <div class="definition-list">
                <div class="definition-row">
                  <span class="definition-term">Diff stat</span>
                  <span class="definition-value mono"><%= diff_summary(@payload.workspace_summary.diff_stat) %></span>
                </div>
                <div class="definition-row">
                  <span class="definition-term">Files</span>
                  <div class="file-list">
                    <div :for={file <- @payload.workspace_summary.files} class="file-row">
                      <span class="state-badge"><%= file.short_status %></span>
                      <span class="mono wrap-anywhere"><%= file.path %></span>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Recent commits</h2>
                <p class="section-copy">Latest workspace commits, useful when the worktree is clean but the branch moved.</p>
              </div>
            </div>

            <%= if @payload.workspace_summary.recent_commits == [] do %>
              <p class="empty-state">No commit history available.</p>
            <% else %>
              <div class="activity-list">
                <article :for={commit <- @payload.workspace_summary.recent_commits} class="activity-card">
                  <div class="activity-meta">
                    <span class="state-badge"><%= commit.sha %></span>
                  </div>
                  <p class="activity-copy"><%= commit.subject %></p>
                </article>
              </div>
            <% end %>
          </section>
        </section>

        <section :if={@payload.workspace_summary.patch_preview} class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Diff preview</h2>
              <p class="section-copy">First lines of the current workspace diff.</p>
            </div>
          </div>

          <pre class="code-panel"><%= @payload.workspace_summary.patch_preview %></pre>
        </section>
      <% end %>
    </section>
    """
  end

  defp assign_issue_payload(socket) do
    case Presenter.issue_payload(socket.assigns.issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        socket
        |> assign(:status, :ok)
        |> assign(:payload, payload)

      {:error, :issue_not_found} ->
        socket
        |> assign(:status, :error)
        |> assign(:payload, nil)
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp humanize_issue_status(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp running_value(%{running: nil}, _key), do: nil
  defp running_value(%{running: running}, key), do: Map.get(running, key)

  defp running_state(%{running: nil}), do: "n/a"
  defp running_state(%{running: running}), do: running.state || "n/a"

  defp running_turns(%{running: nil}), do: 0
  defp running_turns(%{running: running}), do: running.turn_count || 0

  defp running_tokens(%{running: nil}, _key), do: 0
  defp running_tokens(%{running: running}, key), do: get_in(running, [:tokens, key]) || 0

  defp short_path(path) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.reverse()
    |> Enum.take(2)
    |> Enum.reverse()
    |> Path.join()
  end

  defp short_path(_path), do: "n/a"

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp phase_badge_class(%{tone: tone}) do
    base = "status-badge"

    case tone do
      "active" -> "#{base} status-badge-live"
      "warning" -> "#{base} state-badge-warning"
      "danger" -> "#{base} state-badge-danger"
      _ -> base
    end
  end

  defp phase_badge_class(_phase), do: "status-badge"

  defp changes_summary(%{changed_file_count: 0, ahead_count: ahead_count}) when is_integer(ahead_count) and ahead_count > 0,
    do: "#{ahead_count} commit(s) ahead of upstream"

  defp changes_summary(%{changed_file_count: 0}), do: "No workspace changes detected yet."

  defp changes_summary(%{changed_file_count: count, diff_stat: diff_stat}),
    do: "#{count} files changed · #{diff_summary(diff_stat)}"

  defp changes_summary(_summary), do: "Change summary unavailable"

  defp diff_summary(%{insertions: insertions, deletions: deletions}),
    do: "+#{insertions} / -#{deletions}"
end
