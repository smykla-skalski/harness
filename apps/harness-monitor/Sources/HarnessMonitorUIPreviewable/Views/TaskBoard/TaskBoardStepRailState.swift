import HarnessMonitorKit
import Observation

@MainActor
@Observable
final class TaskBoardStepRailState {
  enum Confirmation: Identifiable {
    case externalSync(itemID: String?)
    case evaluate(itemID: String)
    case deliver(itemID: String)
    case complete(itemID: String)

    var itemID: String? {
      switch self {
      case .externalSync(let itemID): itemID
      case .evaluate(let itemID), .deliver(let itemID), .complete(let itemID): itemID
      }
    }

    var id: String {
      switch self {
      case .externalSync: "external-sync-\(itemID ?? "none")"
      case .evaluate: "evaluate-\(itemID ?? "none")"
      case .deliver: "deliver-\(itemID ?? "none")"
      case .complete: "complete-\(itemID ?? "none")"
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

  /// Restores or preserves the active item without overwriting an explicit flow.
  func preserveFlowIdentity(itemID: String?) {
    guard lockedItemID == nil, let itemID else { return }
    lockedItemID = itemID
  }

  /// Captures the item the user is about to authorize before showing the dialog.
  func presentConfirmation(_ confirmation: Confirmation) {
    preserveFlowIdentity(itemID: confirmation.itemID)
    self.confirmation = confirmation
  }

  /// Starts Sync after pinning the item currently shown by the guided flow.
  func beginExternalSync(itemID: String?) -> Bool {
    guard begin() else { return false }
    preserveFlowIdentity(itemID: itemID)
    return true
  }

  /// External Sync refreshes sources inside the current flow. It never ends it.
  func finishExternalSync(succeeded: Bool) {
    if succeeded {
      requestApprovalRefresh()
    }
    finish()
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
