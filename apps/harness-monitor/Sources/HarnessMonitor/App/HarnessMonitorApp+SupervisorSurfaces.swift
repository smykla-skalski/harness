import HarnessMonitorKit
import HarnessMonitorUIPreviewable

extension HarnessMonitorApp {
  @MainActor
  static func bindSupervisorSurfacesIfNeeded(
    to store: HarnessMonitorStore,
    notificationController: HarnessMonitorUserNotificationController,
    dockBadgeController: PendingDecisionsDockBadgeController,
    menuBarStatusController: HarnessMonitorMenuBarStatusController
  ) {
    bindSupervisorSurfaces(
      to: store,
      notificationController: notificationController,
      dockBadgeController: dockBadgeController,
      menuBarStatusController: menuBarStatusController
    )
  }

  /// Wires the supervisor's user-facing surfaces (system notifications, dock badge, menu bar
  /// status) to the store at app launch. Previously these bindings followed the first/last
  /// `SessionWindow`, which silenced background-tick decisions whenever no window happened to
  /// be open. The menu bar extra and dock badge live for the entire app lifetime, so the
  /// bindings now follow that lifetime too.
  @MainActor
  static func bindSupervisorSurfaces(
    to store: HarnessMonitorStore,
    notificationController: HarnessMonitorUserNotificationController,
    dockBadgeController: PendingDecisionsDockBadgeController,
    menuBarStatusController: HarnessMonitorMenuBarStatusController
  ) {
    store.bindSupervisorNotifications(notificationController)
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
}
