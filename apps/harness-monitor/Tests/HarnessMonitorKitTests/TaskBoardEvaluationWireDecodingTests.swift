import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the task-board evaluation summary, generated from
/// task_board/evaluation.rs. The evaluate endpoint decodes
/// TaskBoardEvaluationSummaryWire through the plain decoder and maps to the rich hand
/// summary; records carry the rerouted TaskBoardItemWire and reference TaskStatus
/// /TaskBoardStatus bare. The hand summary uses Int counts and drops signal_failures.
@Suite("Task board evaluation wire type")
struct TaskBoardEvaluationWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes and maps an evaluation summary with a record and item")
  func mapsEvaluationSummary() throws {
    let wire = try decoder.decode(
      TaskBoardEvaluationSummaryWire.self, from: Data(evaluationSummaryFixture.utf8)
    )
    let summary = TaskBoardEvaluationSummary(wire: wire)

    #expect(summary.total == 3)
    #expect(summary.evaluated == 2)
    #expect(summary.completed == 1)
    #expect(summary.records.count == 1)

    let record = try #require(summary.records.first)
    #expect(record.boardItemId == "task-1")
    #expect(record.outcome == .workerRunning)
    #expect(record.taskStatus == .inProgress)
    #expect(record.boardStatus == .inProgress)
    #expect(record.workflowStatus == .running)
    #expect(record.updated)
    #expect(record.item?.id == "task-1")

    // The hand summary drops signal_failures; the wire still decodes them faithfully.
    #expect(wire.signalFailures.count == 1)
    #expect(wire.signalFailures.first?.boardItemId == "task-2")
  }
}

private let evaluationSummaryFixture = """
  {
    "total": 3,
    "evaluated": 2,
    "updated": 1,
    "skipped": 0,
    "completed": 1,
    "running": 1,
    "reviewing": 0,
    "blocked": 0,
    "failed": 0,
    "records": [
      {
        "board_item_id": "task-1",
        "session_id": "sig-1",
        "outcome": "worker_running",
        "task_status": "in_progress",
        "board_status": "in_progress",
        "workflow_status": "running",
        "updated": true,
        "item": {
          "schema_version": 1,
          "id": "task-1",
          "title": "Fix the bug",
          "status": "in_progress",
          "created_at": "2026-06-17T08:00:00Z",
          "updated_at": "2026-06-17T11:00:00Z"
        }
      }
    ],
    "signal_failures": [
      { "board_item_id": "task-2", "message": "signal probe failed" }
    ]
  }
  """
