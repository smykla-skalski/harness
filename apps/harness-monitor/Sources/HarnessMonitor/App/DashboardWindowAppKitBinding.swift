import AppKit
import SwiftUI

/// Registers the singleton dashboard NSWindow so quit-time persistence and
/// launch-time replay can restore mixed dashboard+session tab groups.
struct DashboardWindowAppKitBinding: ViewModifier {
  func body(content: Content) -> some View {
    content.background(
      DashboardWindowAppKitBindingAccessor()
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    )
  }
}

private struct DashboardWindowAppKitBindingAccessor: NSViewRepresentable {
  func makeNSView(context: Context) -> DashboardWindowAppKitBindingNSView {
    DashboardWindowAppKitBindingNSView()
  }

  func updateNSView(_ nsView: DashboardWindowAppKitBindingNSView, context: Context) {
    nsView.refreshBinding()
  }

  static func dismantleNSView(_ nsView: DashboardWindowAppKitBindingNSView, coordinator: ()) {
    nsView.removeFromSuperview()
  }
}

final class DashboardWindowAppKitBindingNSView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refreshBinding()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if let currentWindow = window {
      DashboardWindowAppKitRegistry.shared.unbind(window: currentWindow)
    }
  }

  fileprivate func refreshBinding() {
    guard let window else { return }
    DashboardWindowAppKitRegistry.shared.bind(window: window)
  }
}

@MainActor
final class DashboardWindowAppKitRegistry {
  static let shared = DashboardWindowAppKitRegistry()

  private weak var boundWindow: NSWindow?

  var window: NSWindow? {
    boundWindow
  }

  func bind(window: NSWindow) {
    boundWindow = window
  }

  func unbind(window: NSWindow) {
    if boundWindow === window {
      boundWindow = nil
    }
  }

  func resetForTesting() {
    boundWindow = nil
  }
}
