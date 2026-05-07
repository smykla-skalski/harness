import HarnessMonitorKit
import Observation

@MainActor
@Observable
final class SessionWindowPresenceTracker {
  private(set) var activeSessionWindowCount = 0
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

  func sessionWindowAppeared() {
    activeSessionWindowCount += 1
    guard activeSessionWindowCount == 1 else { return }
    bindSessionWindowUI()
  }

  func sessionWindowDisappeared() {
    guard activeSessionWindowCount > 0 else { return }
    activeSessionWindowCount -= 1
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
