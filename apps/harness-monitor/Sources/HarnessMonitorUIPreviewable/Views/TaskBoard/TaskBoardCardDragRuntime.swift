import HarnessMonitorKit
import Observation

@MainActor
@Observable
final class TaskBoardLaneDropHighlightState {
  private(set) var isTargeted = false

  func setTargeted(_ targeted: Bool) {
    guard isTargeted != targeted else { return }
    isTargeted = targeted
  }
}

@MainActor
final class TaskBoardCardDragRuntime {
  private(set) var cardIDs: [TaskBoardCardID] = []
  private(set) var candidateLanes: Set<TaskBoardInboxLane> = []
  private var activeTargetLane: TaskBoardInboxLane?
  private var highlightStates: [TaskBoardInboxLane: TaskBoardLaneDropHighlightState] = [:]

  var isActive: Bool {
    !cardIDs.isEmpty
  }

  func begin(
    cardIDs: [TaskBoardCardID],
    candidateLanes: Set<TaskBoardInboxLane>
  ) {
    clearActiveTarget()
    self.cardIDs = cardIDs
    self.candidateLanes = candidateLanes
  }

  func accepts(_ lane: TaskBoardInboxLane) -> Bool {
    candidateLanes.contains(lane)
  }

  func highlightState(
    for lane: TaskBoardInboxLane
  ) -> TaskBoardLaneDropHighlightState {
    if let state = highlightStates[lane] {
      return state
    }
    let state = TaskBoardLaneDropHighlightState()
    highlightStates[lane] = state
    return state
  }

  func setTargeted(_ targeted: Bool, lane: TaskBoardInboxLane) {
    guard targeted, accepts(lane) else {
      clearTarget(lane)
      return
    }
    if activeTargetLane != lane {
      clearActiveTarget()
      activeTargetLane = lane
    }
    highlightState(for: lane).setTargeted(true)
  }

  func clear() {
    clearActiveTarget()
    cardIDs = []
    candidateLanes = []
  }

  private func clearTarget(_ lane: TaskBoardInboxLane) {
    guard activeTargetLane == lane else { return }
    clearActiveTarget()
  }

  private func clearActiveTarget() {
    guard let activeTargetLane else { return }
    highlightStates[activeTargetLane]?.setTargeted(false)
    self.activeTargetLane = nil
  }
}
