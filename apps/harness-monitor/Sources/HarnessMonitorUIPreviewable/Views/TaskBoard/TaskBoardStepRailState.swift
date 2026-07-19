import HarnessMonitorKit
import Observation

@MainActor
@Observable
final class TaskBoardStepRailState {
  enum Confirmation: Identifiable {
    case externalSync
    case evaluate
    case deliver
    case complete

    var id: String {
      switch self {
      case .externalSync: "external-sync"
      case .evaluate: "evaluate"
      case .deliver: "deliver"
      case .complete: "complete"
      }
    }
  }

  var isRunning = false
  var pickedSelection: TaskBoardDispatchSelection?
  var delivery: TaskBoardDispatchDelivery?
  var confirmation: Confirmation?
  var approvalRefreshGeneration: UInt64 = 0
  /// The board item the guided flow follows through its lifecycle, even after it
  /// leaves the Todo column. Set on pick.
  var lockedItemID: String?
  /// A rail node the user tapped to read ahead; nil shows the live current stage.
  var viewingColumn: TaskBoardStepColumn?

  var isBusy: Bool { isRunning }

  /// Serializes manual operations: only one may run at a time.
  func begin() -> Bool {
    guard !isRunning else { return false }
    isRunning = true
    return true
  }

  func finish() {
    isRunning = false
  }

  func requestApprovalRefresh() {
    approvalRefreshGeneration &+= 1
  }

  /// Clears the per-item flow so the wizard follows the next target.
  func resetFlow() {
    pickedSelection = nil
    delivery = nil
    lockedItemID = nil
    viewingColumn = nil
  }

  func reset() {
    isRunning = false
    pickedSelection = nil
    delivery = nil
    confirmation = nil
    approvalRefreshGeneration = 0
    lockedItemID = nil
    viewingColumn = nil
  }
}
