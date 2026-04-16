import AppKit
import HarnessMonitorKit
import HarnessMonitorUI
import SwiftUI

struct WindowCommandScopeTrackingModifier: ViewModifier {
  let scope: WindowNavigationScope?
  let routingState: WindowCommandRoutingState

  func body(content: Content) -> some View {
    content
      .background(WindowCommandScopeTrackingView(scope: scope, routingState: routingState))
  }
}

private struct WindowCommandScopeTrackingView: NSViewRepresentable {
  let scope: WindowNavigationScope?
  let routingState: WindowCommandRoutingState

  func makeNSView(context: Context) -> WindowCommandScopeTrackingNSView {
    let view = WindowCommandScopeTrackingNSView()
    view.alphaValue = 0
    view.setAccessibilityHidden(true)
    view.configure(scope: scope, routingState: routingState)
    return view
  }

  func updateNSView(_ nsView: WindowCommandScopeTrackingNSView, context: Context) {
    nsView.configure(scope: scope, routingState: routingState)
  }
}

private final class WindowCommandScopeTrackingNSView: NSView {
  private var scope: WindowNavigationScope?
  private weak var routingState: WindowCommandRoutingState?
  private var observedWindow: NSWindow?
  private var notificationTokens: [NSObjectProtocol] = []

  deinit {
    MainActor.assumeIsolated {
      tearDownWindowObservation()
    }
  }

  func configure(
    scope: WindowNavigationScope?,
    routingState: WindowCommandRoutingState
  ) {
    self.scope = scope
    self.routingState = routingState
    if let window {
      beginObserving(window: window)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    beginObserving(window: window)
  }

  private func beginObserving(window: NSWindow?) {
    guard observedWindow !== window else {
      updateRoutingState()
      return
    }

    tearDownWindowObservation()
    observedWindow = window

    guard let window else {
      return
    }

    let notificationCenter = NotificationCenter.default
    notificationTokens = [
      notificationCenter.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.activate(window: window)
        }
      },
      notificationCenter.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.clear(window: window)
        }
      },
    ]

    updateRoutingState()
  }

  private func tearDownWindowObservation() {
    if let observedWindow {
      routingState?.clear(windowID: ObjectIdentifier(observedWindow))
    }
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    notificationTokens.removeAll()
    observedWindow = nil
  }

  private func updateRoutingState() {
    guard let window = observedWindow else {
      return
    }
    if window.isKeyWindow {
      activate(window: window)
    }
  }

  private func activate(window: NSWindow) {
    routingState?.activate(scope: scope, windowID: ObjectIdentifier(window))
  }

  private func clear(window: NSWindow) {
    routingState?.clear(windowID: ObjectIdentifier(window))
  }
}
