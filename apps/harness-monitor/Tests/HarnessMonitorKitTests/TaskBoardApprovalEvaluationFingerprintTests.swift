import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task-board approval evaluation fingerprint")
struct TaskBoardApprovalEvaluationFingerprintTests {
  @Test("Evaluation fingerprint is order-independent and content-sensitive")
  func evaluationFingerprintIsOrderIndependentAndContentSensitive() {
    let running = record(id: "board-1", outcome: .workerRunning, updated: false)
    let blocked = record(id: "board-2", outcome: .blocked, updated: true)
    let changed = record(id: "board-2", outcome: .reviewPending, updated: true)

    let baseline = fingerprint(records: [running, blocked])
    let reordered = fingerprint(records: [blocked, running])
    let changedSet = fingerprint(records: [running, changed])

    #expect(baseline == reordered)
    #expect(baseline != changedSet)
  }

  private func fingerprint(
    records: [TaskBoardEvaluationRecord]
  ) -> TaskBoardApprovalEvaluationFingerprint {
    TaskBoardApprovalEvaluationFingerprint(
      evaluation: TaskBoardEvaluationSummary(
        total: records.count,
        evaluated: records.count,
        updated: 1,
        blocked: 1,
        records: records
      )
    )
  }

  private func record(
    id: String,
    outcome: TaskBoardEvaluationOutcome,
    updated: Bool
  ) -> TaskBoardEvaluationRecord {
    TaskBoardEvaluationRecord(
      boardItemId: id,
      outcome: outcome,
      updated: updated
    )
  }
}
