import AppKit
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
      .modifier(HarnessMonitorApplicationWindowLifecycleModifier())
  }
}

struct HarnessMonitorApplicationWindowLifecycleModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.background(HarnessMonitorApplicationWindowLifecycleView())
  }
}

private struct HarnessMonitorApplicationWindowLifecycleView: NSViewRepresentable {
  func makeNSView(context: Context) -> HarnessMonitorApplicationWindowLifecycleNSView {
    HarnessMonitorApplicationWindowLifecycleNSView()
  }

  func updateNSView(
    _ nsView: HarnessMonitorApplicationWindowLifecycleNSView,
    context: Context
  ) {}

  static func dismantleNSView(
    _ nsView: HarnessMonitorApplicationWindowLifecycleNSView,
    coordinator: ()
  ) {}
}

private final class HarnessMonitorApplicationWindowLifecycleNSView: NSView {
  private weak var observedWindow: NSWindow?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window, observedWindow !== window else { return }
    observedWindow = window
    let windowID = ObjectIdentifier(window)
    HarnessMonitorApplicationPresenceController.shared.applicationWindowDidOpen(windowID)
  }
}
