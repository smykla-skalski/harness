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

  // SwiftUI sometimes drops this representable without first removing the
  // backing NSView from its window (e.g. when the host window is torn down
  // via WindowGroup dismissal). In that path `viewDidMoveToWindow(nil)`
  // never fires and the registry keeps a stale RegistryWindow entry that
  // shows up in `mcp__harness-monitor__list_windows` long after the window
  // is gone. Detach the view explicitly so the move-to-nil hook drives
  // `stopTracking` on the registry sync controllers.
  static func dismantleNSView(_ nsView: WindowTrackingNSView, coordinator: ()) {
    nsView.removeFromSuperview()
  }
}

final class WindowTrackingNSView: NSView {
  private let syncController: WindowRegistrySyncController
  private let elementSyncController: WindowElementRegistrySyncController
  private let elementSyncDelay: Duration
  private let didUpdateElementSyncDelay: Duration
  // nonisolated(unsafe) so the nonisolated deinit can read the array and
  // remove observers without `MainActor.assumeIsolated`. Mutations all
  // happen on the MainActor (`startTracking` / `stopTracking`); the deinit
  // only reads after the last write.
  private nonisolated(unsafe) var observations: [NSObjectProtocol] = []
  private var didUpdateElementSyncTask: Task<Void, Never>?

  deinit {
    // Thread-safe inline cleanup. ARC may release this NSView on any
    // thread (notably com.apple.SwiftUI.DisplayLink) and
    // `MainActor.assumeIsolated` would trap with a libdispatch BUG off-main.
    // NotificationCenter.removeObserver is documented thread-safe;
    // syncController/elementSyncController stop happens via
    // `viewDidMoveToWindow(nil)` on the MainActor.
    didUpdateElementSyncTask?.cancel()
    observations.forEach(NotificationCenter.default.removeObserver)
  }

  init(
    registry: AccessibilityRegistry,
    elementSyncDelay: Duration = .milliseconds(250),
    didUpdateElementSyncDelay: Duration = .milliseconds(1500)
  ) {
    syncController = WindowRegistrySyncController(registry: registry)
    elementSyncController = WindowElementRegistrySyncController(registry: registry)
    self.elementSyncDelay = elementSyncDelay
    self.didUpdateElementSyncDelay = didUpdateElementSyncDelay
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
          if isDidUpdate {
            self.sync(
              window,
              windowGeneration: windowGeneration,
              elementGeneration: elementGeneration,
              includeElements: false
            )
            self.scheduleDidUpdateElementSync(
              window: window,
              windowGeneration: windowGeneration,
              elementGeneration: elementGeneration
            )
            return
          }
          self.cancelDidUpdateElementSync()
          self.sync(
            window,
            windowGeneration: windowGeneration,
            elementGeneration: elementGeneration,
            includeElements: false
          )
          self.scheduleElementSync(
            window: window,
            windowGeneration: windowGeneration,
            elementGeneration: elementGeneration,
            delay: self.elementSyncDelay
          )
        }
      }
      observations.append(obs)
    }
  }

  private func stopTracking() {
    cancelDidUpdateElementSync()
    observations.forEach { NotificationCenter.default.removeObserver($0) }
    observations.removeAll()
    syncController.stopTracking()
    elementSyncController.stopTracking()
  }

  private func scheduleDidUpdateElementSync(
    window: NSWindow,
    windowGeneration: UInt64,
    elementGeneration: UInt64
  ) {
    cancelDidUpdateElementSync()
    guard didUpdateElementSyncDelay > .zero else {
      sync(
        window,
        windowGeneration: windowGeneration,
        elementGeneration: elementGeneration,
        includeElements: true,
        elementSyncReason: .routineDidUpdate
      )
      return
    }
    scheduleElementSync(
      window: window,
      windowGeneration: windowGeneration,
      elementGeneration: elementGeneration,
      delay: didUpdateElementSyncDelay,
      elementSyncReason: .routineDidUpdate
    )
  }

  private func scheduleElementSync(
    window: NSWindow,
    windowGeneration: UInt64,
    elementGeneration: UInt64,
    delay: Duration,
    elementSyncReason: WindowElementRegistrySyncReason = .structural
  ) {
    didUpdateElementSyncTask = Task { @MainActor [weak self, weak window] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard let self, let window else {
        return
      }
      self.didUpdateElementSyncTask = nil
      // AppKit emits `didUpdate` for routine interaction churn. Debounce the
      // full AX snapshot so UI feedback is not gated on immediate tree harvests.
      self.sync(
        window,
        windowGeneration: windowGeneration,
        elementGeneration: elementGeneration,
        includeElements: true,
        elementSyncReason: elementSyncReason
      )
    }
  }

  private func cancelDidUpdateElementSync() {
    didUpdateElementSyncTask?.cancel()
    didUpdateElementSyncTask = nil
  }

  private func sync(
    _ window: NSWindow,
    windowGeneration: UInt64,
    elementGeneration: UInt64,
    includeElements: Bool,
    elementSyncReason: WindowElementRegistrySyncReason = .structural
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
    elementSyncController.sync(
      window: window,
      generation: elementGeneration,
      reason: elementSyncReason
    )
  }
}
#endif
