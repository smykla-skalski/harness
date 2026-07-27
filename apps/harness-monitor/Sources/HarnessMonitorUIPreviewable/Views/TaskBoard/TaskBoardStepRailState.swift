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
  private(set) var pickedSelection: TaskBoardDispatchSelection?
  var delivery: TaskBoardDispatchDelivery?
  var confirmation: Confirmation?
  var approvalRefreshGeneration: UInt64 = 0
  /// The board item the guided flow follows through its lifecycle, even after it
  /// leaves the Todo column. Set on pick.
  private(set) var lockedItemID: String?
  /// Bumps whenever the flow the next launch should reopen on changes. The panel
  /// watches this rather than the stored value itself, which would mean rebuilding
  /// and deep-comparing a dispatch plan on every body pass.
  private(set) var flowRevision: UInt64 = 0
  /// A rail node the user tapped to read ahead; nil shows the live current stage.
  var viewingColumn: TaskBoardStepColumn?
  /// The stored flow this panel has read but not yet resolved against the live
  /// board. Read from disk once; restoration then retries against it as board
  /// snapshots arrive, and clears it once the flow is adopted or superseded.
  var pendingRestoredFlow: TaskBoardStepFlowSnapshot?
  var hasLoadedPersistedFlow = false
  /// Whether the automation-context footer is open. Held here rather than left
  /// to `DisclosureGroup` so the label can drive it from a full-width tap.
  var isAutomationContextExpanded = false

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
    flowRevision &+= 1
  }

  /// Pick loaded a plan, so the flow follows that item and drops any delivery
  /// recorded for the previous one.
  func applyPick(_ selection: TaskBoardDispatchSelection?) {
    pickedSelection = selection
    delivery = nil
    // Always track the picked item, clearing the lock when Pick returned nil.
    lockedItemID = selection?.item.id
    flowRevision &+= 1
  }

  /// Adopts the flow an earlier launch stored. Deliberately no revision bump:
  /// this is what the stored flow already says, and treating it as a change
  /// would rewrite the same bytes on every panel mount.
  func adoptRestoredFlow(itemID: String, pickedSelection: TaskBoardDispatchSelection?) {
    self.pickedSelection = pickedSelection
    lockedItemID = itemID
    pendingRestoredFlow = nil
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
    pendingRestoredFlow = nil
    flowRevision &+= 1
  }

  /// `hasLoadedPersistedFlow` deliberately survives: the disk read happens once
  /// per panel, and a flow cleared here leaves nothing to read back.
  func reset() {
    isRunning = false
    pickedSelection = nil
    delivery = nil
    confirmation = nil
    approvalRefreshGeneration = 0
    lockedItemID = nil
    viewingColumn = nil
    pendingRestoredFlow = nil
    flowRevision &+= 1
    isAutomationContextExpanded = false
  }
}
