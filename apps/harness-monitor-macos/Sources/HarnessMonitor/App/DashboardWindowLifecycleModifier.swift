import SwiftUI

/// View-layer hook that mirrors the dashboard window's on-screen presence
/// into `DashboardWindowLifecycleTracker.shared` so the launch router can
/// restore the window on relaunch when the user had it open at quit.
struct DashboardWindowLifecycleModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .onAppear {
        DashboardWindowLifecycleTracker.shared.markOpen()
      }
      .onDisappear {
        DashboardWindowLifecycleTracker.shared.markClosed()
      }
  }
}
