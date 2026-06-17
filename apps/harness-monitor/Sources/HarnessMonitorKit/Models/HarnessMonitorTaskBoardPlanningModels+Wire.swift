import Foundation

// Map the generated planning wire types to the rich hand models. The response
// carries a TaskBoardItemWire, adapted through the item wire/model split; the
// transition reuses the adopted TaskBoardStatus bare and the planning-state mapping.

extension TaskBoardPlanningTransition {
  public init(wire: PlanningTransitionWire) {
    self.init(
      boardItemId: wire.boardItemId,
      fromStatus: wire.fromStatus,
      toStatus: wire.toStatus,
      planning: TaskBoardPlanningState(wire: wire.planning)
    )
  }
}

extension TaskBoardPlanningResponse {
  public init(wire: TaskBoardPlanningResponseWire) {
    self.init(
      transition: TaskBoardPlanningTransition(wire: wire.transition),
      item: TaskBoardItem(wire: wire.item)
    )
  }
}
