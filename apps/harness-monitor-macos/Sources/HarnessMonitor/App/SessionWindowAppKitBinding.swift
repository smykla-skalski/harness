import AppKit
import HarnessMonitorUIPreviewable
import SwiftUI

/// View-layer hook that registers the hosting NSWindow with
/// `SessionWindowAppKitRegistry` so quit-time tab-group capture and
/// launch-time tab-group replay can find the AppKit window for a session.
struct SessionWindowAppKitBinding: ViewModifier {
  let sessionID: String

  func body(content: Content) -> some View {
    content.background(
      SessionWindowAppKitBindingAccessor(sessionID: sessionID)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    )
  }
}

private struct SessionWindowAppKitBindingAccessor: NSViewRepresentable {
  let sessionID: String

  func makeNSView(context: Context) -> SessionWindowAppKitBindingNSView {
    SessionWindowAppKitBindingNSView(sessionID: sessionID)
  }

  func updateNSView(_ nsView: SessionWindowAppKitBindingNSView, context: Context) {
    nsView.sessionID = sessionID
    nsView.refreshBinding()
  }

  // SwiftUI sometimes drops the representable without first removing the
  // backing NSView (e.g. when the host window is torn down via WindowGroup
  // dismissal). In that path `viewWillMove(toWindow: nil)` does not fire
  // and the registry holds onto a stale entry. Detach explicitly so the
  // move-to-nil hook unbinds.
  static func dismantleNSView(_ nsView: SessionWindowAppKitBindingNSView, coordinator: ()) {
    nsView.removeFromSuperview()
  }
}

final class SessionWindowAppKitBindingNSView: NSView {
  fileprivate var sessionID: String
  private weak var observedWindow: NSWindow?

  init(sessionID: String) {
    self.sessionID = sessionID
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refreshBinding()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    let currentWindow = window
    super.viewWillMove(toWindow: newWindow)
    if let currentWindow {
      stopObserving(window: currentWindow)
      SessionWindowAppKitRegistry.shared.unbind(window: currentWindow)
    }
  }

  fileprivate func refreshBinding() {
    guard let window else { return }
    beginObserving(window: window)
    SessionWindowAppKitRegistry.shared.bind(window: window, sessionID: sessionID)
  }

  private func beginObserving(window: NSWindow) {
    guard observedWindow !== window else {
      return
    }
    if let observedWindow {
      stopObserving(window: observedWindow)
    }
    observedWindow = window
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(boundWindowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: window
    )
  }

  private func stopObserving(window: NSWindow) {
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.willCloseNotification,
      object: window
    )
    if observedWindow === window {
      observedWindow = nil
    }
  }

  @objc
  private func boundWindowWillClose(_ notification: Notification) {
    guard let closingWindow = notification.object as? NSWindow else {
      return
    }
    stopObserving(window: closingWindow)
    SessionWindowAppKitRegistry.shared.unbind(window: closingWindow)
  }
}
