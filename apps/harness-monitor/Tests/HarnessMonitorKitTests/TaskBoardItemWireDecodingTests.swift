import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the core TaskBoardItem and its nested graph,
/// generated from src/task_board/types.rs. The *Wire type owns the explicit
/// snake_case decode through the plain decoder; the item endpoints now decode it and
/// map to the rich hand TaskBoardItem. It references the adopted TaskBoardStatus
/// /TaskBoardPriority/TaskBoardAgentMode enums bare and faithfully carries the fields
/// the hand model renames or drops (sync_state, optional workflow).
@Suite("Task board item wire type")
struct TaskBoardItemWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a fully populated item including the nested graph")
  func decodesFullItem() throws {
    let item = try decoder.decode(
      TaskBoardItemWire.self, from: Data(fullItemPayloadFixture.utf8)
    )

    #expect(item.id == "task-1")
    #expect(item.status == .inProgress)
    #expect(item.priority == .high)
    #expect(item.agentMode == .interactive)
    #expect(item.tags == ["urgent"])
    #expect(item.importedFromProvider == .gitHub)

    let ref = try #require(item.externalRefs.first)
    #expect(ref.provider == .gitHub)
    #expect(ref.externalId == "123")
    #expect(ref.syncState?.status == .todo)

    #expect(item.planning.approvedBy == "lead")
    let workflow = try #require(item.workflow)
    #expect(workflow.status == .running)
    #expect(workflow.attempts == 2)
    #expect(workflow.prNumber == 42)
    #expect(item.usage.inputTokens == 100)
    #expect(item.usage.costUsd == 0.25)
  }

  @Test("applies wire defaults for an item with only required fields")
  func decodesMinimalItem() throws {
    let item = try decoder.decode(
      TaskBoardItemWire.self,
      from: Data(
        #"{"schema_version": 1, "id": "task-2", "title": "Minimal", "created_at": "a", "updated_at": "b"}"#
          .utf8
      )
    )

    #expect(item.body.isEmpty)
    #expect(item.status == .todo)
    #expect(item.priority == .medium)
    #expect(item.agentMode == .headless)
    #expect(item.tags.isEmpty)
    #expect(item.externalRefs.isEmpty)
    #expect(item.importedFromProvider == nil)
    #expect(item.planning.summary == nil)
    #expect(item.workflow == nil)
    #expect(item.usage.inputTokens == nil)
    #expect(item.deletedAt == nil)
  }

  @Test("maps a decoded wire item to the rich hand model")
  func mapsFullItemToHandModel() throws {
    let wire = try decoder.decode(
      TaskBoardItemWire.self, from: Data(fullItemPayloadFixture.utf8)
    )
    let item = TaskBoardItem(wire: wire)

    #expect(item.id == "task-1")
    #expect(item.status == .inProgress)
    #expect(item.priority == .high)
    #expect(item.agentMode == .interactive)
    #expect(item.externalRefs.first?.provider == .gitHub)
    #expect(item.externalRefs.first?.url == "https://example.com/123")
    #expect(item.planning.approvedBy == "lead")
    let workflow = try #require(item.workflow)
    #expect(workflow.status == .running)
    #expect(workflow.attempts == 2)
    #expect(workflow.prNumber == 42)
    #expect(item.usage.inputTokens == 100)
  }

  @Test("maps an omitted wire workflow to a nil hand workflow")
  func mapsMinimalItemWorkflowToNil() throws {
    let wire = try decoder.decode(
      TaskBoardItemWire.self,
      from: Data(
        #"{"schema_version": 1, "id": "task-2", "title": "Minimal", "created_at": "a", "updated_at": "b"}"#
          .utf8
      )
    )
    let item = TaskBoardItem(wire: wire)
    #expect(item.workflow == nil)
    #expect(item.status == .todo)
  }

  @Test("maps the items-list response wrapper")
  func mapsListResponseWrapper() throws {
    let json = #"{"items": [\#(fullItemPayloadFixture)]}"#
    let wire = try decoder.decode(
      TaskBoardListItemsResponseWire.self, from: Data(json.utf8)
    )
    let items = wire.items.map(TaskBoardItem.init(wire:))
    #expect(items.count == 1)
    #expect(items.first?.id == "task-1")
    #expect(items.first?.workflow?.status == .running)
  }
}

private let fullItemPayloadFixture = """
  {
    "schema_version": 3,
    "id": "task-1",
    "title": "Fix the bug",
    "body": "details",
    "status": "in_progress",
    "priority": "high",
    "tags": ["urgent"],
    "project_id": "owner/repo",
    "target_project_types": ["rust"],
    "agent_mode": "interactive",
    "external_refs": [
      {
        "provider": "git_hub",
        "external_id": "123",
        "url": "https://example.com/123",
        "sync_state": { "title": "Synced", "status": "todo", "synced_at": "2026-06-17T10:00:00Z" }
      }
    ],
    "imported_from_provider": "git_hub",
    "planning": { "summary": "plan", "approved_by": "lead", "approved_at": "2026-06-17T09:00:00Z" },
    "workflow": {
      "execution_id": "exec-1",
      "status": "running",
      "attempts": 2,
      "branch": "fix/bug",
      "pr_number": 42,
      "policy_trace_ids": ["trace-1"]
    },
    "session_id": "sig-1",
    "work_item_id": "wi-1",
    "usage": { "input_tokens": 100, "output_tokens": 50, "cost_usd": 0.25 },
    "created_at": "2026-06-17T08:00:00Z",
    "updated_at": "2026-06-17T11:00:00Z"
  }
  """
