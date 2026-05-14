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

  private static let placeholderToolbarIdentifier = "io.harnessmonitor.session.placeholder"

  init(sessionID: String) {
    self.sessionID = sessionID
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    installPlaceholderToolbarIfNeeded()
    refreshBinding()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if let currentWindow = window {
      SessionWindowAppKitRegistry.shared.unbind(window: currentWindow)
    }
  }

  fileprivate func refreshBinding() {
    guard let window else { return }
    SessionWindowAppKitRegistry.shared.bind(window: window, sessionID: sessionID)
  }

  // AppKit's NSWindowStackController syncs toolbars across tabbed siblings
  // whenever any sibling's toolbar changes. During SwiftUI's initial
  // setToolbar: on the active window, the sibling restored from the saved
  // tab group may still have `window.toolbar == nil`, which makes
  // -[NSThemeFrame _showToolbarWithAnimation:] log "attempt to show a
  // toolbar which is *nil*". Installing an empty placeholder here ensures
  // every session window has a non-nil toolbar before AppKit's tab sync
  // runs; SwiftUI's later setToolbar: replaces this atomically.
  private func installPlaceholderToolbarIfNeeded() {
    guard let window, window.toolbar == nil else { return }
    window.toolbar = NSToolbar(identifier: Self.placeholderToolbarIdentifier)
  }
}
