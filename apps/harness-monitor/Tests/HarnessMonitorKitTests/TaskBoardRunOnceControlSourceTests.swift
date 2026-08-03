import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board Run Once controls")
struct TaskBoardRunOnceControlSourceTests {
  @Test("Run Once uses one stable label in every task-board surface")
  func runOnceUsesOneStableLabel() throws {
    let managementActionsSource = try taskBoardSourceFile(
      named: "TaskBoardItemLiveActionButtons.swift"
    )
    let orchestratorSource = try taskBoardSourceFile(
      named: "TaskBoardOrchestratorControls.swift"
    )
    let liveOperationsSource = try taskBoardSourceFile(
      named: "TaskBoardOverviewLiveOperations.swift"
    )

    for source in [managementActionsSource, orchestratorSource, liveOperationsSource] {
      #expect(source.contains("Run Once"))
      #expect(!source.contains("Preview Run Once"))
      #expect(!source.contains("Run Once Live"))
    }
  }

  @Test("Every Run Once surface exposes Stop while the run is locally in flight")
  func everyRunOnceSurfaceExposesStop() throws {
    let managementActionsSource = try taskBoardSourceFile(
      named: "TaskBoardItemLiveActionButtons.swift"
    )
    let orchestratorSource = try taskBoardSourceFile(
      named: "TaskBoardOrchestratorControls.swift"
    )

    #expect(managementActionsSource.contains("if isRunOnceInFlight"))
    #expect(managementActionsSource.contains("cancelTaskBoardOrchestratorRun()"))
    #expect(orchestratorSource.contains("isRunOnceInFlight"))
    #expect(orchestratorSource.contains("Label(\"Stop\""))
  }

  private func taskBoardSourceFile(named relativePath: String) throws -> String {
    try previewableSourceFile(domain: "TaskBoard", named: relativePath)
  }
}
