import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the task-board audit, project and machine summaries, generated
/// from src/task_board/summary.rs. The thin hand mirrors decode camelCase via
/// convertFromSnakeCase today; these *Wire types own the explicit snake_case decode
/// through the plain decoder (project_id/item_count/by_status) and reference the
/// adopted TaskBoardStatus/TaskBoardAgentMode enums bare. The mappings narrow the
/// UInt counts to the hand Int. generate-only (decode reroute deferred).
@Suite("Task board summary wire types")
struct TaskBoardSummaryWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes an audit summary and maps to the hand model")
  func decodesAuditSummary() throws {
    let wire = try decoder.decode(
      TaskBoardAuditSummaryWire.self, from: Data(auditSummaryPayloadFixture.utf8)
    )
    #expect(wire.total == 12)
    #expect(wire.byStatus.count == 2)
    #expect(wire.byStatus[0].status == .inReview)
    #expect(wire.byStatus[0].count == 3)

    let summary = TaskBoardAuditSummary(wire: wire)
    #expect(summary.total == 12)
    #expect(summary.ready == 5)
    #expect(summary.blocked == 2)
    #expect(summary.deleted == 1)
    #expect(summary.byStatus[1].status == .needsYou)
    #expect(summary.byStatus[1].count == 4)
  }

  @Test("decodes a project summary and maps to the hand model")
  func decodesProjectSummary() throws {
    let wire = try decoder.decode(
      TaskBoardProjectSummaryWire.self,
      from: Data(#"{"project_id": "owner/repo", "item_count": 7, "ready_count": 3}"#.utf8)
    )
    #expect(wire.projectId == "owner/repo")
    #expect(wire.itemCount == 7)

    let summary = TaskBoardProjectSummary(wire: wire)
    #expect(summary.projectId == "owner/repo")
    #expect(summary.itemCount == 7)
    #expect(summary.readyCount == 3)
    #expect(summary.id == "owner/repo")
  }

  @Test("decodes a machine summary with the adopted agent mode")
  func decodesMachineSummary() throws {
    let wire = try decoder.decode(
      TaskBoardMachineSummaryWire.self,
      from: Data(#"{"mode": "headless", "item_count": 4, "ready_count": 1}"#.utf8)
    )
    #expect(wire.mode == .headless)

    let summary = TaskBoardMachineSummary(wire: wire)
    #expect(summary.mode == .headless)
    #expect(summary.itemCount == 4)
    #expect(summary.readyCount == 1)
    #expect(summary.id == .headless)
  }
}

private let auditSummaryPayloadFixture = """
  {
    "total": 12,
    "ready": 5,
    "blocked": 2,
    "deleted": 1,
    "by_status": [
      { "status": "in_review", "count": 3 },
      { "status": "needs_you", "count": 4 }
    ]
  }
  """
