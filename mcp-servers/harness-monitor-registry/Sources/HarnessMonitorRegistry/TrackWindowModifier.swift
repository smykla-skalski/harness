#if canImport(AppKit)
import AppKit
import SwiftUI

public extension View {
  /// Register the hosting NSWindow with an `AccessibilityRegistry` so the MCP
  /// server can discover it via `list_windows`. Also harvests the window's live
  /// AppKit view tree into `RegistryElement` values so `list_elements`,
  /// `get_element`, and `click_element` can target controls without requiring
  /// manual per-view registration in production scenes.
  ///
  /// Tracks frame, key/main state, and title automatically; re-registers on
  /// window and content updates.
  func trackWindow(registry: AccessibilityRegistry) -> some View {
    modifier(TrackWindowModifier(registry: registry))
  }
}

private struct TrackWindowModifier: ViewModifier {
  let registry: AccessibilityRegistry

  func body(content: Content) -> some View {
    content.background(
      WindowTrackingRepresentable(registry: registry)
        .frame(width: 0, height: 0)
    )
  }
}

private struct WindowTrackingRepresentable: NSViewRepresentable {
  let registry: AccessibilityRegistry

  func makeNSView(context: Context) -> WindowTrackingNSView {
    WindowTrackingNSView(registry: registry)
  }

  func updateNSView(_ nsView: WindowTrackingNSView, context: Context) {}
}

final class WindowTrackingNSView: NSView {
  private static let didUpdateElementRefreshInterval: Duration = .milliseconds(900)

  private let syncController: WindowRegistrySyncController
  private let elementSyncController: WindowElementRegistrySyncController
  private let clock = ContinuousClock()
  // nonisolated(unsafe) so the nonisolated deinit can read the array and
  // remove observers without `MainActor.assumeIsolated`. Mutations all
  // happen on the MainActor (`startTracking` / `stopTracking`); the deinit
  // only reads after the last write.
  private nonisolated(unsafe) var observations: [NSObjectProtocol] = []
  private var lastDidUpdateElementRefreshAt: ContinuousClock.Instant?

  deinit {
    // Thread-safe inline cleanup. ARC may release this NSView on any
    // thread (notably com.apple.SwiftUI.DisplayLink) and
    // `MainActor.assumeIsolated` would trap with a libdispatch BUG off-main.
    // NotificationCenter.removeObserver is documented thread-safe;
    // syncController/elementSyncController stop happens via
    // `viewDidMoveToWindow(nil)` on the MainActor.
    observations.forEach(NotificationCenter.default.removeObserver)
  }

  init(registry: AccessibilityRegistry) {
    syncController = WindowRegistrySyncController(registry: registry)
    elementSyncController = WindowElementRegistrySyncController(registry: registry)
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopTracking()
    guard let window else { return }
    startTracking(window)
  }

  private func startTracking(_ window: NSWindow) {
    let windowGeneration = syncController.beginTracking(windowID: window.windowNumber)
    let elementGeneration = elementSyncController.beginTracking(windowID: window.windowNumber)
    sync(
      window,
      windowGeneration: windowGeneration,
      elementGeneration: elementGeneration,
      includeElements: true
    )
    let names: [NSNotification.Name] = [
      NSWindow.didMoveNotification,
      NSWindow.didResizeNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didBecomeMainNotification,
      NSWindow.didResignMainNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
      NSWindow.didChangeScreenNotification,
      NSWindow.didUpdateNotification,
    ]
    for name in names {
      let obs = NotificationCenter.default.addObserver(
        forName: name,
        object: window,
        queue: .main
      ) { [weak self, weak window] notification in
        let isDidUpdate = notification.name == NSWindow.didUpdateNotification
        // Hop explicitly: `MainActor.assumeIsolated` would trap if the
        // block ever fires off-main on macOS 26.
        Task { @MainActor [weak self, weak window] in
          guard let self, let window else { return }
          let includeElements = !isDidUpdate || self.shouldRefreshElementsOnDidUpdate()
          self.sync(
            window,
            windowGeneration: windowGeneration,
            elementGeneration: elementGeneration,
            includeElements: includeElements
          )
        }
      }
      observations.append(obs)
    }
  }

  private func stopTracking() {
    observations.forEach { NotificationCenter.default.removeObserver($0) }
    observations.removeAll()
    syncController.stopTracking()
    elementSyncController.stopTracking()
  }

  private func sync(
    _ window: NSWindow,
    windowGeneration: UInt64,
    elementGeneration: UInt64,
    includeElements: Bool
  ) {
    let entry = RegistryWindow(
      id: window.windowNumber,
      title: window.title,
      frame: RegistryRect(window.frame),
      isKey: window.isKeyWindow,
      isMain: window.isMainWindow
    )
    syncController.sync(entry, generation: windowGeneration)
    guard includeElements else {
      return
    }
    lastDidUpdateElementRefreshAt = clock.now
    elementSyncController.sync(window: window, generation: elementGeneration)
  }

  private func shouldRefreshElementsOnDidUpdate() -> Bool {
    guard let lastDidUpdateElementRefreshAt else {
      return true
    }
    let now = clock.now
    return lastDidUpdateElementRefreshAt + Self.didUpdateElementRefreshInterval <= now
  }
}
#endif
