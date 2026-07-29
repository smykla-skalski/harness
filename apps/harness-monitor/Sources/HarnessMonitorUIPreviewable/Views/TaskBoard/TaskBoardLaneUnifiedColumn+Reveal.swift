import Foundation

extension TaskBoardLaneUnifiedColumn {
  func handlePerfLaneScroll(note: Notification, edge: String) {
    guard
      let raw = note.userInfo?[HarnessMonitorPerfTaskBoardLaneScrollBus.laneRawKey] as? String,
      raw == lane.rawValue
    else { return }
    let row = edge == "top" ? 0 : max(0, laneListRows.count - 1)
    Task { @MainActor in
      guard await nativeListCoordinator.reveal(row: row, in: lane) else {
        return
      }
      HarnessMonitorPerfTaskBoardLaneScrollBus.recordAccepted(laneRaw: raw, edge: edge)
    }
  }

  func revealCard(_ request: TaskBoardLaneRevealRequest) async {
    let row = laneListRows.firstIndex { $0.cardID == request.cardID }
    let didReveal =
      if let row {
        await nativeListCoordinator.reveal(row: row, in: lane)
      } else {
        false
      }
    guard revealCoordinator.isPending(request) else { return }
    if didReveal {
      revealCoordinator.consume(request)
    } else if revealCoordinator.retry(request) == nil {
      revealCoordinator.consume(request)
    }
  }
}
