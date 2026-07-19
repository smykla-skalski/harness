import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

extension TaskBoardOverviewBehaviorTests {
  @Test("Drop gate rejects with a busy reason when dropping is disabled")
  func dropGateRejectsWhenDisabled() {
    let payload = TaskBoardCardDragPayload(item: .api(itemID: "board-1", status: .backlog))

    let result = taskBoardCardDropGate(
      payloads: [payload],
      lane: .todo,
      isDropEnabled: false,
      isDropCandidate: true
    )

    #expect(
      result
        == .reject("Cannot move task: an action is already in progress")
    )
  }

  @Test("Drop gate rejects with a lane reason when the lane is not a drop candidate")
  func dropGateRejectsWhenNotDropCandidate() {
    let payload = TaskBoardCardDragPayload(item: .api(itemID: "board-1", status: .backlog))

    let result = taskBoardCardDropGate(
      payloads: [payload],
      lane: .todo,
      isDropEnabled: true,
      isDropCandidate: false
    )

    #expect(
      result
        == .reject("Cannot move task: it can no longer move to this lane")
    )
  }

  @Test("Drop gate rejects with a lane reason when the plan cannot resolve")
  func dropGateRejectsWhenPlanUnresolvable() {
    // Source lane equals destination lane, so TaskBoardCardDropPlan.resolve returns nil even
    // though isDropCandidate claims the lane accepts drops (a config/delivery race).
    let payload = TaskBoardCardDragPayload(item: .api(itemID: "board-1", status: .todo))

    let result = taskBoardCardDropGate(
      payloads: [payload],
      lane: .todo,
      isDropEnabled: true,
      isDropCandidate: true
    )

    #expect(
      result
        == .reject("Cannot move task: it can no longer move to this lane")
    )
  }

  @Test("Drop gate proceeds with the resolved plan when enabled and a candidate")
  func dropGateProceedsWhenAllowed() {
    let payload = TaskBoardCardDragPayload(item: .api(itemID: "board-1", status: .backlog))

    let result = taskBoardCardDropGate(
      payloads: [payload],
      lane: .todo,
      isDropEnabled: true,
      isDropCandidate: true
    )

    #expect(
      result
        == .proceed(
          TaskBoardCardDropPlan(
            items: [.api(itemID: "board-1", status: .backlog)],
            destination: .todo
          )
        )
    )
  }
}
