import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the core TaskBoardItem and its nested graph,
/// generated from src/task_board/types.rs. The *Wire type owns the explicit
/// snake_case decode through the plain decoder; the item endpoints now decode it and
/// map to the rich hand TaskBoardItem. It references the adopted TaskBoardStatus
/// /TaskBoardPriority/TaskBoardAgentMode enums bare and faithfully carries sync state,
/// provider provenance, and optional workflow into the hand model.
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
    #expect(item.workflowKind == .prFix)
    #expect(item.executionRepository == "acme/widget")
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
    #expect(item.workflowKind == .defaultTask)
    #expect(item.executionRepository == nil)
    #expect(item.tags.isEmpty)
    #expect(item.externalRefs.isEmpty)
    #expect(item.importedFromProvider == nil)
    #expect(item.planning.summary == nil)
    #expect(item.workflow == nil)
    #expect(item.usage.inputTokens == nil)
    #expect(item.deletedAt == nil)
  }

  @Test("preserves an unknown workflow kind without rejecting the item")
  func decodesUnknownWorkflowKind() throws {
    let payload = """
      {
        "schema_version": 1,
        "id": "task-future",
        "title": "Future",
        "workflow_kind": "future_workflow",
        "created_at": "a",
        "updated_at": "b"
      }
      """
    let item = try decoder.decode(
      TaskBoardItemWire.self,
      from: Data(payload.utf8)
    )

    #expect(item.workflowKind == .unknown("future_workflow"))
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
    #expect(item.externalRefs.first?.syncState?.status == .todo)
    #expect(item.importedFromProvider == .gitHub)
    #expect(item.planning.approvedBy == "lead")
    let workflow = try #require(item.workflow)
    #expect(workflow.status == .running)
    #expect(workflow.attempts == 2)
    #expect(workflow.prNumber == 42)
    #expect(item.usage.inputTokens == 100)
  }

  @Test("maps the wire item kind to the hand model, defaulting to task")
  func mapsItemKindToHandModel() throws {
    let umbrellaWire = try decoder.decode(
      TaskBoardItemWire.self,
      from: Data(
        #"{"schema_version": 1, "id": "task-3", "title": "Umbrella", "kind": "umbrella", "created_at": "a", "updated_at": "b"}"#
          .utf8
      )
    )
    #expect(TaskBoardItem(wire: umbrellaWire).kind == .umbrella)

    let defaultWire = try decoder.decode(
      TaskBoardItemWire.self,
      from: Data(
        #"{"schema_version": 1, "id": "task-4", "title": "Plain", "created_at": "a", "updated_at": "b"}"#
          .utf8
      )
    )
    #expect(TaskBoardItem(wire: defaultWire).kind == .task)
  }

  @Test("maps the parent link to the hand model, defaulting to no parent and order zero")
  func mapsParentLinkToHandModel() throws {
    let childWire = try decoder.decode(
      TaskBoardItemWire.self,
      from: Data(
        #"{"schema_version": 1, "id": "task-5", "title": "Child", "parent_item_id": "task-3", "child_order": 2, "created_at": "a", "updated_at": "b"}"#
          .utf8
      )
    )
    let child = TaskBoardItem(wire: childWire)
    #expect(child.parentItemId == "task-3")
    #expect(child.childOrder == 2)

    let defaultWire = try decoder.decode(
      TaskBoardItemWire.self,
      from: Data(
        #"{"schema_version": 1, "id": "task-6", "title": "Solo", "created_at": "a", "updated_at": "b"}"#
          .utf8
      )
    )
    let solo = TaskBoardItem(wire: defaultWire)
    #expect(solo.parentItemId == nil)
    #expect(solo.childOrder == 0)
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
    #expect(item.importedFromProvider == nil)
    #expect(item.status == .todo)
  }

  @Test("maps the items-list response wrapper")
  func mapsListResponseWrapper() throws {
    let json =
      #"{"items": [\#(fullItemPayloadFixture)], "items_change_seq": 7, "item_revisions": {"task-1": 3}}"#
    let wire = try decoder.decode(
      TaskBoardListItemsResponseWire.self, from: Data(json.utf8)
    )
    let snapshot = TaskBoardListItemsSnapshot(wire: wire)
    #expect(snapshot.items.count == 1)
    #expect(snapshot.items.first?.id == "task-1")
    #expect(snapshot.items.first?.workflow?.status == .running)
    #expect(snapshot.itemsChangeSeq == 7)
    #expect(snapshot.itemRevisions == ["task-1": 3])
  }

  @Test("maps optional manual lane placement into the hand model")
  func mapsLanePlacement() throws {
    let wire = try decoder.decode(
      TaskBoardItemWire.self,
      from: Data(
        #"{"schema_version":1,"id":"placed","title":"Placed","lane_position":2,"lane_origin":{"kind":"manual","actor":"control"},"lane_set_at":"now","created_at":"a","updated_at":"b"}"#
          .utf8)
    )
    let item = TaskBoardItem(wire: wire)
    #expect(item.lanePosition == 2)
    #expect(item.laneOrigin == .manual(actor: "control"))
    #expect(item.laneSetAt == "now")
  }

  @Test("decodes server JSON and round-trips tagged lane origins through cache coding")
  func decodesServerItemAndRoundTripsLaneOrigins() throws {
    let serverDecoder = JSONDecoder()
    serverDecoder.keyDecodingStrategy = .convertFromSnakeCase
    let item = try serverDecoder.decode(TaskBoardItem.self, from: Data(fullItemPayloadFixture.utf8))
    #expect(item.lanePosition == 2)
    #expect(item.laneOrigin == .manual(actor: "daemon-control"))

    let cacheEncoder = JSONEncoder()
    cacheEncoder.keyEncodingStrategy = .convertToSnakeCase
    let cached = try serverDecoder.decode(TaskBoardItem.self, from: cacheEncoder.encode(item))
    #expect(cached == item)

    let manual = TaskBoardLaneOrigin.manual(actor: "daemon-control")
    let encodedManual = try #require(
      JSONSerialization.jsonObject(with: cacheEncoder.encode(manual)) as? [String: String]
    )
    #expect(encodedManual == ["kind": "manual", "actor": "daemon-control"])

    let serverAutomatic = try serverDecoder.decode(
      TaskBoardLaneOrigin.self,
      from: Data(#"{"kind":"automatic","producer":"provider-sync"}"#.utf8)
    )
    #expect(serverAutomatic == .automatic(producer: "provider-sync"))
    let automatic = TaskBoardLaneOrigin.automatic(producer: "provider-sync")
    let encodedAutomatic = try #require(
      JSONSerialization.jsonObject(with: cacheEncoder.encode(automatic)) as? [String: String]
    )
    #expect(encodedAutomatic == ["kind": "automatic", "producer": "provider-sync"])
    let decodedAutomatic = try serverDecoder.decode(
      TaskBoardLaneOrigin.self,
      from: cacheEncoder.encode(automatic)
    )
    #expect(decodedAutomatic == automatic)
  }

  @Test("accepts the legacy GitHub provider spelling")
  func decodesLegacyGitHubProvider() throws {
    let provider = try decoder.decode(
      ExternalRefProviderWire.self,
      from: Data(#""git_hub""#.utf8)
    )
    #expect(provider == .gitHub)
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
    "workflow_kind": "pr_fix",
    "execution_repository": "acme/widget",
    "external_refs": [
      {
        "provider": "github",
        "external_id": "123",
        "url": "https://example.com/123",
        "sync_state": { "title": "Synced", "status": "todo", "synced_at": "2026-06-17T10:00:00Z" }
      }
    ],
    "imported_from_provider": "github",
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
    "lane_position": 2,
    "lane_origin": { "kind": "manual", "actor": "daemon-control" },
    "lane_set_at": "2026-06-17T10:30:00Z",
    "created_at": "2026-06-17T08:00:00Z",
    "updated_at": "2026-06-17T11:00:00Z"
  }
  """
