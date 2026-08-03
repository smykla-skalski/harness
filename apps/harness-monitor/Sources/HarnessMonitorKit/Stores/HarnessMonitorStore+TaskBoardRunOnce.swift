import Foundation

public struct TaskBoardRunOnceReservation: Sendable {
  let id: UUID

  fileprivate init(id: UUID) {
    self.id = id
  }
}

extension HarnessMonitorStore {
  public var isTaskBoardRunOnceInFlight: Bool {
    !taskBoardRuntimeState.pendingRunOnceReservations.isEmpty
      || !taskBoardRuntimeState.activeRunOnceReservations.isEmpty
  }

  public func reserveTaskBoardRunOnceAction() -> TaskBoardRunOnceReservation? {
    guard !isTaskBoardRunOnceInFlight else { return nil }
    let reservation = TaskBoardRunOnceReservation(id: UUID())
    taskBoardRuntimeState.pendingRunOnceReservations.insert(reservation.id)
    scheduleUISync([.contentDashboard])
    return reservation
  }

  func claimTaskBoardRunOnceAction(_ reservation: TaskBoardRunOnceReservation) -> Bool {
    guard taskBoardRuntimeState.pendingRunOnceReservations.remove(reservation.id) != nil else {
      return false
    }
    taskBoardRuntimeState.activeRunOnceReservations.insert(reservation.id)
    return true
  }

  @discardableResult
  public func cancelTaskBoardRunOnceReservation(
    _ reservation: TaskBoardRunOnceReservation
  ) -> Bool {
    guard taskBoardRuntimeState.pendingRunOnceReservations.remove(reservation.id) != nil else {
      return false
    }
    syncTaskBoardRunOnceAvailabilityIfIdle()
    return true
  }

  public func cancelPendingTaskBoardRunOnceActions() {
    guard !taskBoardRuntimeState.pendingRunOnceReservations.isEmpty else { return }
    taskBoardRuntimeState.pendingRunOnceReservations.removeAll(keepingCapacity: true)
    syncTaskBoardRunOnceAvailabilityIfIdle()
  }

  func endTaskBoardRunOnceAction(_ reservation: TaskBoardRunOnceReservation) {
    guard taskBoardRuntimeState.activeRunOnceReservations.remove(reservation.id) != nil else {
      return
    }
    syncTaskBoardRunOnceAvailabilityIfIdle()
  }

  private func syncTaskBoardRunOnceAvailabilityIfIdle() {
    if !isTaskBoardRunOnceInFlight {
      scheduleUISync([.contentDashboard])
    }
  }
}
