defmodule Karkhana.Linear.WebhookTest do
  use ExUnit.Case, async: true

  alias Karkhana.Linear.Webhook
  alias Karkhana.Tracker.Event

  describe "verify_signature/3" do
    test "accepts valid HMAC signature" do
      body = ~s({"type":"Issue","action":"create"})
      secret = "test-secret-key"
      signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

      assert :ok = Webhook.verify_signature(body, signature, secret)
    end

    test "rejects invalid signature" do
      body = ~s({"type":"Issue","action":"create"})
      assert {:error, :invalid_signature} = Webhook.verify_signature(body, "bad-sig", "secret")
    end

    test "rejects nil inputs" do
      assert {:error, :invalid_signature} = Webhook.verify_signature(nil, nil, nil)
    end
  end

  describe "parse/1" do
    test "parses issue created" do
      payload = %{
        "type" => "Issue",
        "action" => "create",
        "createdAt" => "2026-04-17T00:00:00.000Z",
        "data" => %{
          "id" => "issue-123",
          "identifier" => "TST-1",
          "title" => "Test issue",
          "priority" => 2,
          "state" => %{"name" => "Todo"},
          "assigneeId" => "user-1",
          "description" => "A test"
        }
      }

      assert {:ok, %Event{} = event} = Webhook.parse(payload)
      assert event.type == :issue_created
      assert event.issue_id == "issue-123"
      assert event.issue_identifier == "TST-1"
      assert event.source == :linear
      assert event.data.title == "Test issue"
      assert event.data.state == "Todo"
      assert event.data.priority == 2
    end

    test "parses issue state change" do
      payload = %{
        "type" => "Issue",
        "action" => "update",
        "createdAt" => "2026-04-17T00:00:00.000Z",
        "updatedFrom" => %{"stateId" => "old-state-id"},
        "data" => %{
          "id" => "issue-123",
          "identifier" => "TST-2",
          "title" => "Test",
          "state" => %{"name" => "In Progress"}
        }
      }

      assert {:ok, %Event{} = event} = Webhook.parse(payload)
      assert event.type == :issue_state_changed
      assert event.data.state == "In Progress"
      assert event.data.updated_from == %{"stateId" => "old-state-id"}
    end

    test "parses issue assignment" do
      payload = %{
        "type" => "Issue",
        "action" => "update",
        "createdAt" => "2026-04-17T00:00:00.000Z",
        "updatedFrom" => %{"assigneeId" => "old-user"},
        "data" => %{
          "id" => "issue-123",
          "identifier" => "TST-3",
          "title" => "Test",
          "assigneeId" => "new-user"
        }
      }

      assert {:ok, %Event{} = event} = Webhook.parse(payload)
      assert event.type == :issue_assigned
      assert event.data.assignee_id == "new-user"
    end

    test "parses comment" do
      payload = %{
        "type" => "Comment",
        "action" => "create",
        "createdAt" => "2026-04-17T00:00:00.000Z",
        "data" => %{
          "id" => "comment-1",
          "issueId" => "issue-123",
          "body" => "Some feedback",
          "userId" => "user-1"
        }
      }

      assert {:ok, %Event{} = event} = Webhook.parse(payload)
      assert event.type == :issue_commented
      assert event.issue_id == "issue-123"
      assert event.data.body == "Some feedback"
    end

    test "parses label change" do
      payload = %{
        "type" => "IssueLabel",
        "action" => "create",
        "createdAt" => "2026-04-17T00:00:00.000Z",
        "data" => %{
          "issueId" => "issue-123",
          "name" => "qa"
        }
      }

      assert {:ok, %Event{} = event} = Webhook.parse(payload)
      assert event.type == :issue_labeled
      assert event.data.label == "qa"
    end

    test "returns error for unsupported type" do
      assert {:error, {:unsupported_webhook_type, "Project"}} =
               Webhook.parse(%{"type" => "Project", "action" => "create"})
    end

    test "returns error for invalid payload" do
      assert {:error, :invalid_payload} = Webhook.parse(%{})
    end

    test "handles generic update (no state or assignee change)" do
      payload = %{
        "type" => "Issue",
        "action" => "update",
        "createdAt" => "2026-04-17T00:00:00.000Z",
        "updatedFrom" => %{"title" => "Old title"},
        "data" => %{
          "id" => "issue-123",
          "identifier" => "TST-4",
          "title" => "New title"
        }
      }

      assert {:ok, %Event{} = event} = Webhook.parse(payload)
      assert event.type == :issue_updated
    end
  end
end
