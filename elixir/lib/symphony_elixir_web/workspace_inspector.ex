defmodule SymphonyElixirWeb.WorkspaceInspector do
  @moduledoc false

  @max_files 8
  @max_commits 3
  @max_patch_chars 6_000
  @max_patch_lines 80

  @spec summarize(String.t() | nil, String.t() | nil) :: map()
  def summarize(_workspace_path, worker_host) when is_binary(worker_host) do
    %{
      available: false,
      dirty: false,
      branch: nil,
      head_sha: nil,
      ahead_count: nil,
      changed_file_count: 0,
      files: [],
      diff_stat: %{files_changed: 0, insertions: 0, deletions: 0},
      recent_commits: [],
      patch_preview: nil,
      note: "Remote workspace summary unavailable"
    }
  end

  def summarize(nil, _worker_host) do
    %{
      available: false,
      dirty: false,
      branch: nil,
      head_sha: nil,
      ahead_count: nil,
      changed_file_count: 0,
      files: [],
      diff_stat: %{files_changed: 0, insertions: 0, deletions: 0},
      recent_commits: [],
      patch_preview: nil,
      note: "Workspace not created yet"
    }
  end

  def summarize(workspace_path, _worker_host) when is_binary(workspace_path) do
    if File.dir?(workspace_path) and File.dir?(Path.join(workspace_path, ".git")) do
      status_entries = git_status_entries(workspace_path)

      diff_stat =
        workspace_path
        |> git_output(["diff", "--shortstat", "HEAD", "--"])
        |> parse_shortstat()

      patch_preview =
        workspace_path
        |> git_output(["diff", "--no-ext-diff", "--unified=0", "--no-color", "HEAD", "--"])
        |> compact_patch_preview()

      %{
        available: true,
        dirty: status_entries != [],
        branch: git_single_line(workspace_path, ["branch", "--show-current"]),
        head_sha: git_single_line(workspace_path, ["rev-parse", "--short", "HEAD"]),
        ahead_count: ahead_count(workspace_path),
        changed_file_count: length(status_entries),
        files: Enum.take(status_entries, @max_files),
        diff_stat: diff_stat,
        recent_commits: recent_commits(workspace_path),
        patch_preview: patch_preview,
        note: nil
      }
    else
      %{
        available: false,
        dirty: false,
        branch: nil,
        head_sha: nil,
        ahead_count: nil,
        changed_file_count: 0,
        files: [],
        diff_stat: %{files_changed: 0, insertions: 0, deletions: 0},
        recent_commits: [],
        patch_preview: nil,
        note: "Workspace path unavailable"
      }
    end
  end

  defp git_status_entries(workspace_path) do
    workspace_path
    |> git_output(["status", "--short", "--untracked-files=all"])
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_status_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_status_line(<<"?", "?", " ", rest::binary>>) do
    %{status: "untracked", short_status: "??", path: String.trim(rest)}
  end

  defp parse_status_line(<<x::binary-size(1), y::binary-size(1), " ", rest::binary>>) do
    short_status = String.trim(x <> y)

    %{
      status: humanize_status(short_status),
      short_status: short_status,
      path: String.trim(rest)
    }
  end

  defp parse_status_line(_line), do: nil

  defp humanize_status("A"), do: "added"
  defp humanize_status("M"), do: "modified"
  defp humanize_status("D"), do: "deleted"
  defp humanize_status("R"), do: "renamed"
  defp humanize_status("C"), do: "copied"
  defp humanize_status("U"), do: "conflict"
  defp humanize_status(short_status), do: String.downcase(short_status)

  defp parse_shortstat(nil), do: %{files_changed: 0, insertions: 0, deletions: 0}
  defp parse_shortstat(""), do: %{files_changed: 0, insertions: 0, deletions: 0}

  defp parse_shortstat(output) do
    %{
      files_changed: capture_count(output, ~r/(\d+)\s+files?\schanged/),
      insertions: capture_count(output, ~r/(\d+)\s+insertions?\(\+\)/),
      deletions: capture_count(output, ~r/(\d+)\s+deletions?\(-\)/)
    }
  end

  defp capture_count(output, regex) do
    case Regex.run(regex, output, capture: :all_but_first) do
      [value] -> String.to_integer(value)
      _ -> 0
    end
  end

  defp recent_commits(workspace_path) do
    workspace_path
    |> git_output(["log", "--oneline", "--decorate=no", "-n", Integer.to_string(@max_commits)])
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, " ", parts: 2) do
        [sha, subject] -> %{sha: sha, subject: subject}
        [sha] -> %{sha: sha, subject: ""}
      end
    end)
  end

  defp compact_patch_preview(nil), do: nil
  defp compact_patch_preview(""), do: nil

  defp compact_patch_preview(output) do
    output
    |> String.split("\n")
    |> Enum.take(@max_patch_lines)
    |> Enum.join("\n")
    |> String.slice(0, @max_patch_chars)
    |> case do
      "" -> nil
      preview -> preview
    end
  end

  defp ahead_count(workspace_path) do
    case git_output(workspace_path, ["rev-list", "--count", "@{upstream}..HEAD"]) do
      nil -> nil
      "" -> nil
      value ->
        try do
          String.to_integer(String.trim(value))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp git_single_line(workspace_path, args) do
    case git_output(workspace_path, args) do
      nil -> nil
      value -> String.trim(value)
    end
  end

  defp git_output(workspace_path, args) do
    case System.cmd("git", args, cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end
end
