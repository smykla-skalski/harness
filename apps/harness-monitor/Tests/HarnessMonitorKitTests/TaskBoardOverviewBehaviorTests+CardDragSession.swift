import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

extension TaskBoardOverviewBehaviorTests {
  @Test("Drag session decision processes active phases only when no action is in flight")
  func dragSessionDecisionProcessesActivePhasesOnlyWhenIdle() {
    #expect(
      taskBoardCardDragSessionDecision(for: .initial, isActionInFlight: false) == .processActive
    )
    #expect(
      taskBoardCardDragSessionDecision(for: .active, isActionInFlight: false) == .processActive
    )
    #expect(taskBoardCardDragSessionDecision(for: .initial, isActionInFlight: true) == .ignore)
    #expect(taskBoardCardDragSessionDecision(for: .active, isActionInFlight: true) == .ignore)
  }

  @Test("Drag session decision always clears on terminal phases, even mid-action")
  func dragSessionDecisionAlwaysClearsOnTerminalPhases() {
    #expect(
      taskBoardCardDragSessionDecision(for: .ended(.move), isActionInFlight: false) == .clear
    )
    #expect(
      taskBoardCardDragSessionDecision(for: .ended(.move), isActionInFlight: true) == .clear
    )
    #expect(
      taskBoardCardDragSessionDecision(for: .dataTransferCompleted, isActionInFlight: false)
        == .clear
    )
    #expect(
      taskBoardCardDragSessionDecision(for: .dataTransferCompleted, isActionInFlight: true)
        == .clear
    )
  }
}
