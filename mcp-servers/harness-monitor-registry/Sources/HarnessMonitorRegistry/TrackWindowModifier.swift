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
  private let syncController: WindowRegistrySyncController
  private let elementSyncController: WindowElementRegistrySyncController
  private var observations: [NSObjectProtocol] = []

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
    sync(window, windowGeneration: windowGeneration, elementGeneration: elementGeneration)
    let names: [NSNotification.Name] = [
      NSWindow.didMoveNotification,
      NSWindow.didResizeNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didBecomeMainNotification,
      NSWindow.didResignMainNotification,
      NSWindow.didUpdateNotification,
    ]
    for name in names {
      let obs = NotificationCenter.default.addObserver(
        forName: name,
        object: window,
        queue: .main
      ) { [weak self, weak window] _ in
        MainActor.assumeIsolated {
          guard let self, let window else { return }
          self.sync(
            window,
            windowGeneration: windowGeneration,
            elementGeneration: elementGeneration
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
    elementGeneration: UInt64
  ) {
    let entry = RegistryWindow(
      id: window.windowNumber,
      title: window.title,
      frame: RegistryRect(window.frame),
      isKey: window.isKeyWindow,
      isMain: window.isMainWindow
    )
    syncController.sync(entry, generation: windowGeneration)
    elementSyncController.sync(window: window, generation: elementGeneration)
  }
}
#endif
