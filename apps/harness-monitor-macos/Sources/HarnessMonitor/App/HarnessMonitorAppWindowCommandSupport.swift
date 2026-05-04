import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
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

  static func dismantleNSView(_ nsView: WindowCommandScopeTrackingNSView, coordinator: ()) {
    // SwiftUI calls this on the MainActor when the representable is removed
    // from the view tree, which is the right place to clear the routing
    // state entry. The NSView's deinit cannot do that step because ARC may
    // release the view on a non-main thread.
    nsView.tearDownWindowObservation()
  }
}

private final class WindowCommandScopeTrackingNSView: NSView {
  private var scope: WindowNavigationScope?
  private weak var routingState: WindowCommandRoutingState?
  private var observedWindow: NSWindow?
  // nonisolated(unsafe) so deinit (which can fire off the MainActor when ARC
  // releases on com.apple.SwiftUI.DisplayLink during dashboard <-> cockpit
  // transitions) can read the array without tripping the libdispatch queue
  // assertion that `MainActor.assumeIsolated` would. Mutations all happen on
  // the MainActor (see `beginObserving`); the deinit only reads after the
  // last write, so concurrent access is not possible.
  private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

  deinit {
    // ARC may release this NSView on any thread (notably
    // com.apple.SwiftUI.DisplayLink during workspace transitions), so we
    // cannot wrap the cleanup in `MainActor.assumeIsolated`. Removing the
    // notification observers is thread-safe; the routing-state clear is the
    // MainActor-only step and runs synchronously when the observed window
    // closes (`willCloseNotification`) or when SwiftUI tears the
    // representable down via `dismantleNSView`, so it is fine to skip here.
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
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

  fileprivate func tearDownWindowObservation() {
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
