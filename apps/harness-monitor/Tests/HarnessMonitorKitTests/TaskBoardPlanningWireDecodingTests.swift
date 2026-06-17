import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the task-board planning response, generated from
/// task_board/planning.rs plus the protocol facade. The begin/submit/approve/revoke
/// endpoints decode TaskBoardPlanningResponseWire through the plain decoder and map to
/// the rich hand response; the embedded item reuses the TaskBoardItemWire split.
@Suite("Task board planning wire type")
struct TaskBoardPlanningWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes and maps a planning response with its transition and item")
  func mapsPlanningResponse() throws {
    let wire = try decoder.decode(
      TaskBoardPlanningResponseWire.self, from: Data(planningResponseFixture.utf8)
    )
    let response = TaskBoardPlanningResponse(wire: wire)

    #expect(response.transition.boardItemId == "task-1")
    #expect(response.transition.fromStatus == .planning)
    #expect(response.transition.toStatus == .planReview)
    #expect(response.transition.planning.approvedBy == "lead")
    #expect(response.item.id == "task-1")
    #expect(response.item.status == .planReview)
    #expect(response.item.workflow == nil)
  }
}

private let planningResponseFixture = """
  {
    "transition": {
      "board_item_id": "task-1",
      "from_status": "planning",
      "to_status": "plan_review",
      "planning": { "summary": "the plan", "approved_by": "lead" }
    },
    "item": {
      "schema_version": 1,
      "id": "task-1",
      "title": "Fix the bug",
      "status": "plan_review",
      "created_at": "2026-06-17T08:00:00Z",
      "updated_at": "2026-06-17T11:00:00Z"
    }
  }
  """
