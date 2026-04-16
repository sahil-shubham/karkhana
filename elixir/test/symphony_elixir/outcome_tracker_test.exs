defmodule SymphonyElixir.OutcomeTrackerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OutcomeTracker

  describe "summarize/1" do
    test "empty list produces zero totals" do
      summary = OutcomeTracker.summarize([])
      assert summary.total == 0
      assert summary.zero_touch == 0
      assert summary.zero_touch_rate == 0.0
    end

    test "classifies and counts correctly" do
      outcomes = [
        %{issue_id: "1", identifier: "A-1", outcome: :zero_touch, touches: 0, closed_at: nil},
        %{issue_id: "2", identifier: "A-2", outcome: :zero_touch, touches: 0, closed_at: nil},
        %{issue_id: "3", identifier: "A-3", outcome: :one_touch, touches: 1, closed_at: nil},
        %{issue_id: "4", identifier: "A-4", outcome: :multi_touch, touches: 3, closed_at: nil},
        %{issue_id: "5", identifier: "A-5", outcome: :heavy_touch, touches: 5, closed_at: nil}
      ]

      summary = OutcomeTracker.summarize(outcomes)
      assert summary.total == 5
      assert summary.zero_touch == 2
      assert summary.one_touch == 1
      assert summary.multi_touch == 1
      assert summary.heavy_touch == 1
      assert_in_delta summary.zero_touch_rate, 40.0, 0.1
    end

    test "100% zero-touch rate" do
      outcomes = [
        %{issue_id: "1", identifier: "A-1", outcome: :zero_touch, touches: 0, closed_at: nil},
        %{issue_id: "2", identifier: "A-2", outcome: :zero_touch, touches: 0, closed_at: nil}
      ]

      summary = OutcomeTracker.summarize(outcomes)
      assert summary.zero_touch_rate == 100.0
    end
  end
end
