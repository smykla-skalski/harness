import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension TaskBoardOrchestratorPresentationTests {
  @Test("Known repository scope projects prior-run and workflow metrics onto visible repositories")
  func repositoryScopeProjectsOrchestratorMetrics() {
    let allowed = taskBoardItem(id: "allowed", status: .todo, workflowStatus: .idle)
    let evaluation = TaskBoardOrchestratorEvaluationOutcome(
      total: 2,
      evaluated: 0,
      skipped: 2,
      records: [
        TaskBoardOrchestratorEvaluationRecord(
          boardItemId: allowed.id,
          outcome: .skippedUnlinked
        ),
        TaskBoardOrchestratorEvaluationRecord(
          boardItemId: "disabled",
          outcome: .skippedUnlinked
        ),
      ]
    )
    let run = orchestratorRun(evaluation: evaluation)
    let status = orchestratorStatus(
      lastRun: run,
      workflowCounts: [
        TaskBoardWorkflowExecutionCount(status: .idle, count: 996),
        TaskBoardWorkflowExecutionCount(status: .paused, count: 2),
      ]
    )

    let presentation = TaskBoardOrchestratorPresentation(
      status: status,
      taskBoardItems: [allowed],
      localHostProjectTypes: [],
      repositoryScopeIsKnown: true
    )

    #expect(
      presentation.workflowCounts
        == [TaskBoardWorkflowCountPresentation(status: .idle, count: 1)]
    )
    guard case .lastRun(_, let appliedCount, let scopedEvaluation) = presentation.summarySource
    else {
      Issue.record("Expected the scoped last-run summary")
      return
    }
    #expect(appliedCount == 0)
    #expect(scopedEvaluation?.total == 1)
    #expect(scopedEvaluation?.evaluated == 0)

    let standaloneEvaluation = TaskBoardEvaluationSummary(
      total: 2,
      evaluated: 2,
      updated: 1,
      blocked: 1,
      records: [
        TaskBoardEvaluationRecord(
          boardItemId: allowed.id,
          outcome: .completed,
          updated: true
        ),
        TaskBoardEvaluationRecord(
          boardItemId: "disabled",
          outcome: .blocked
        ),
      ]
    )
    let standalonePresentation = TaskBoardOrchestratorPresentation(
      status: status,
      taskBoardItems: [allowed],
      localHostProjectTypes: [],
      latestEvaluation: standaloneEvaluation,
      latestEvaluationBaselineRunID: run.runId,
      repositoryScopeIsKnown: true
    )
    guard
      case .standaloneEvaluation(let scopedStandalone) = standalonePresentation.summarySource
    else {
      Issue.record("Expected the scoped standalone evaluation")
      return
    }
    #expect(scopedStandalone.total == 1)
    #expect(scopedStandalone.evaluated == 1)
    #expect(scopedStandalone.updated == 1)
    #expect(scopedStandalone.blocked == 0)
    #expect(scopedStandalone.failed == 0)

    #expect(
      TaskBoardOrchestratorPresentation(
        status: status,
        taskBoardItems: [allowed],
        localHostProjectTypes: nil,
        repositoryScopeIsKnown: true
      ).workflowCounts
        == [TaskBoardWorkflowCountPresentation(status: .paused, count: 2)]
    )
  }
}
