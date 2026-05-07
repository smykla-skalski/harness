import AppKit
import HarnessMonitorKit
import SwiftUI

struct SessionWindowLifecycleModifier: ViewModifier {
  let store: HarnessMonitorStore
  let sessionID: String
  let tracker: SessionWindowPresenceTracker

  func body(content: Content) -> some View {
    content.background(
      SessionWindowLifecycleAccessor(
        store: store,
        sessionID: sessionID,
        tracker: tracker
      )
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    )
  }
}

private struct SessionWindowLifecycleAccessor: NSViewRepresentable {
  let store: HarnessMonitorStore
  let sessionID: String
  let tracker: SessionWindowPresenceTracker

  func makeNSView(context: Context) -> SessionWindowLifecycleNSView {
    let view = SessionWindowLifecycleNSView()
    view.configure(store: store, sessionID: sessionID, tracker: tracker)
    return view
  }

  func updateNSView(_ nsView: SessionWindowLifecycleNSView, context: Context) {
    nsView.configure(store: store, sessionID: sessionID, tracker: tracker)
  }

  static func dismantleNSView(_ nsView: SessionWindowLifecycleNSView, coordinator: ()) {
    nsView.tearDownWindowObservation()
  }
}

private final class SessionWindowLifecycleNSView: NSView {
  private weak var store: HarnessMonitorStore?
  private weak var tracker: SessionWindowPresenceTracker?
  private var sessionID = ""
  private var observedWindow: NSWindow?
  nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []

  deinit {
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
  }

  func configure(
    store: HarnessMonitorStore,
    sessionID: String,
    tracker: SessionWindowPresenceTracker
  ) {
    self.store = store
    self.sessionID = sessionID
    self.tracker = tracker
    observe(window: window)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observe(window: window)
  }

  fileprivate func tearDownWindowObservation() {
    deactivateObservedWindow()
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    notificationTokens.removeAll()
    observedWindow = nil
  }

  private func observe(window: NSWindow?) {
    guard observedWindow !== window else {
      return
    }

    tearDownWindowObservation()
    observedWindow = window

    guard let window else {
      return
    }

    activate(window: window)
    notificationTokens = [
      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.tearDownWindowObservation()
        }
      }
    ]
  }

  private func activate(window: NSWindow) {
    let windowID = ObjectIdentifier(window)
    store?.registerOpenSessionWindow(windowID: windowID, sessionID: sessionID)
    tracker?.sessionWindowAppeared(windowID: windowID)
  }

  private func deactivateObservedWindow() {
    guard let observedWindow else {
      return
    }
    let windowID = ObjectIdentifier(observedWindow)
    store?.unregisterOpenSessionWindow(windowID: windowID)
    tracker?.sessionWindowDisappeared(windowID: windowID)
  }
}
