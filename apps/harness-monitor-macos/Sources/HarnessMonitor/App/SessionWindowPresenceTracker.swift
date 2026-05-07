import HarnessMonitorKit
import Observation

@MainActor
@Observable
final class SessionWindowPresenceTracker {
  private(set) var activeSessionWindowCount = 0
  @ObservationIgnored private var activeSessionWindowIDs: Set<ObjectIdentifier> = []
  private let store: HarnessMonitorStore
  private weak var notificationController: HarnessMonitorUserNotificationController?
  private let dockBadgeController: PendingDecisionsDockBadgeController
  private let menuBarStatusController: HarnessMonitorMenuBarStatusController

  init(
    store: HarnessMonitorStore,
    notificationController: HarnessMonitorUserNotificationController,
    dockBadgeController: PendingDecisionsDockBadgeController,
    menuBarStatusController: HarnessMonitorMenuBarStatusController
  ) {
    self.store = store
    self.notificationController = notificationController
    self.dockBadgeController = dockBadgeController
    self.menuBarStatusController = menuBarStatusController
  }

  func sessionWindowAppeared(windowID: ObjectIdentifier) {
    guard activeSessionWindowIDs.insert(windowID).inserted else {
      return
    }
    activeSessionWindowCount = activeSessionWindowIDs.count
    guard activeSessionWindowCount == 1 else { return }
    bindSessionWindowUI()
  }

  func sessionWindowDisappeared(windowID: ObjectIdentifier) {
    guard activeSessionWindowIDs.remove(windowID) != nil else {
      return
    }
    activeSessionWindowCount = activeSessionWindowIDs.count
    guard activeSessionWindowCount == 0 else { return }
    unbindSessionWindowUI()
  }

  private func bindSessionWindowUI() {
    if let notificationController {
      store.bindSupervisorNotifications(notificationController)
    }
    store.bindPendingDecisionsBadgeSync { [dockBadgeController] count in
      dockBadgeController.sync(count: count)
    }
    store.bindPendingDecisionsStatusSync { [menuBarStatusController] count, severity in
      if count == .zero {
        menuBarStatusController.reset()
      } else {
        menuBarStatusController.schedule(
          pendingDecisionCount: count,
          pendingDecisionSeverity: severity
        )
      }
    }
  }

  private func unbindSessionWindowUI() {
    store.unbindSupervisorNotifications()
    store.unbindPendingDecisionsBadgeSync()
    store.unbindPendingDecisionsStatusSync()
    dockBadgeController.sync(count: 0)
    menuBarStatusController.reset()
  }
}
