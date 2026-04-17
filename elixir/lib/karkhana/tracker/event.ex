defmodule Karkhana.Tracker.Event do
  @moduledoc """
  Generic tracker event. Webhook payloads from Linear (or any future tracker)
  are translated into this struct before reaching the orchestrator.

  The orchestrator never sees tracker-specific payloads — only these events.
  """

  @type event_type ::
          :issue_created
          | :issue_updated
          | :issue_state_changed
          | :issue_assigned
          | :issue_commented
          | :issue_labeled

  @type t :: %__MODULE__{
          type: event_type(),
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          data: map(),
          source: atom(),
          timestamp: DateTime.t()
        }

  defstruct [:type, :issue_id, :issue_identifier, :data, :source, :timestamp]
end
