import AppKit
import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  /// Restart the per-repository scheduler with a forced refresh after the
  /// system wakes from sleep. See `DashboardReviewsSystemWakeModifier`
  /// for why this is needed.
  func handleSystemWake() {
    Task { await startScheduler(forceRefreshAll: true) }
  }
}

/// Observe `NSWorkspace.didWakeNotification` and run `onWake` on the main
/// actor each time the system reports a wake-from-sleep transition.
///
/// The Dashboard Reviews route uses this to restart its per-repository
/// scheduler on wake: the daemon's WebSocket RPC has no resource timeout, so
/// a TCP connection that went zombie during sleep can leave a query awaiting
/// forever. The scheduler's per-fetch timeout caps the worst case to ~60s,
/// and this hook collapses recovery to ~0s for the common wake path.
struct DashboardReviewsSystemWakeModifier: ViewModifier {
  let onWake: @MainActor () -> Void

  func body(content: Content) -> some View {
    content.onReceive(
      NSWorkspace.shared.notificationCenter
        .publisher(for: NSWorkspace.didWakeNotification)
    ) { _ in
      onWake()
    }
  }
}

extension View {
  /// Run `action` whenever `NSWorkspace.didWakeNotification` fires — the
  /// system signal that the Mac just woke from sleep.
  func dashboardReviewsOnSystemWake(
    perform action: @escaping @MainActor () -> Void
  ) -> some View {
    modifier(DashboardReviewsSystemWakeModifier(onWake: action))
  }
}
