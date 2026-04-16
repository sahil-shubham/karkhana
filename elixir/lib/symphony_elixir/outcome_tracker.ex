defmodule SymphonyElixir.OutcomeTracker do
  @moduledoc """
  Tracks issue outcomes by scanning Linear issue history.

  Classifies closed issues by how many times they bounced between
  states (In Review → In Progress = one "touch" requiring human
  feedback).

  Runs periodically or on-demand. Results are surfaced on the
  dashboard and API.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Client}

  @type outcome :: :zero_touch | :one_touch | :multi_touch | :heavy_touch
  @type outcome_record :: %{
          issue_id: String.t(),
          identifier: String.t(),
          outcome: outcome,
          touches: non_neg_integer(),
          closed_at: DateTime.t() | nil
        }

  @closed_issues_query """
  query KarkhanaClosedIssues($projectSlug: String!, $first: Int!) {
    issues(
      filter: {
        project: { slugId: { eq: $projectSlug } }
        state: { name: { in: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"] } }
        completedAt: { gte: "$SINCE" }
      }
      first: $first
      orderBy: completedAt
    ) {
      nodes {
        id
        identifier
        completedAt
        history(first: 50) {
          nodes {
            fromState { name }
            toState { name }
            createdAt
          }
        }
      }
    }
  }
  """

  @doc """
  Scan recently closed issues and classify their outcomes.
  Returns a list of outcome records.
  """
  @spec scan_recent(keyword()) :: {:ok, [outcome_record()]} | {:error, term()}
  def scan_recent(opts \\ []) do
    days = Keyword.get(opts, :days, 7)
    since = DateTime.utc_now() |> DateTime.add(-days * 86400) |> DateTime.to_iso8601()
    project_slug = Config.settings!().tracker.project_slug

    # Build query with the date filter interpolated
    query = String.replace(@closed_issues_query, "$SINCE", since)

    case Client.graphql(query, %{"projectSlug" => project_slug, "first" => 50}) do
      {:ok, %{"data" => %{"issues" => %{"nodes" => issues}}}} ->
        outcomes = Enum.map(issues, &classify_issue/1)
        {:ok, outcomes}

      {:ok, %{"errors" => errors}} ->
        {:error, {:graphql_errors, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Produce a summary of outcomes.
  """
  @spec summarize([outcome_record()]) :: map()
  def summarize(outcomes) when is_list(outcomes) do
    total = length(outcomes)
    by_outcome = Enum.group_by(outcomes, & &1.outcome)

    zero = length(Map.get(by_outcome, :zero_touch, []))
    one = length(Map.get(by_outcome, :one_touch, []))
    multi = length(Map.get(by_outcome, :multi_touch, []))
    heavy = length(Map.get(by_outcome, :heavy_touch, []))

    %{
      total: total,
      zero_touch: zero,
      one_touch: one,
      multi_touch: multi,
      heavy_touch: heavy,
      zero_touch_rate: if(total > 0, do: Float.round(zero / total * 100, 1), else: 0.0),
      outcomes: outcomes
    }
  end

  # Classify a single issue based on its state transition history
  defp classify_issue(issue) do
    history = get_in(issue, ["history", "nodes"]) || []
    touches = count_review_bounces(history)

    outcome =
      cond do
        touches == 0 -> :zero_touch
        touches == 1 -> :one_touch
        touches <= 3 -> :multi_touch
        true -> :heavy_touch
      end

    completed_at =
      case issue["completedAt"] do
        str when is_binary(str) ->
          case DateTime.from_iso8601(str) do
            {:ok, dt, _} -> dt
            _ -> nil
          end
        _ -> nil
      end

    %{
      issue_id: issue["id"],
      identifier: issue["identifier"],
      outcome: outcome,
      touches: touches,
      closed_at: completed_at
    }
  end

  # Count how many times an issue bounced from "In Review" back to "In Progress"
  # Each bounce = one round of human feedback
  defp count_review_bounces(history_nodes) do
    history_nodes
    |> Enum.count(fn node ->
      from = get_in(node, ["fromState", "name"])
      to = get_in(node, ["toState", "name"])
      normalize(from) == "in review" and normalize(to) == "in progress"
    end)
  end

  defp normalize(nil), do: ""
  defp normalize(s) when is_binary(s), do: String.downcase(String.trim(s))
end
