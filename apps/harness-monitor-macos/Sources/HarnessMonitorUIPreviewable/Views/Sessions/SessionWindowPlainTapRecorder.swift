import AppKit
import SwiftUI

/// Records every left mouse-down inside the SessionWindow with the modifiers
/// held at click time. The sidebar watches `stateCache.lastPlainClick` to
/// collapse the multi-selection when the user taps outside the selected rows.
///
/// AppKit exception (rationale):
///   The native SwiftUI option is `.simultaneousGesture(SpatialTapGesture)` on
///   the NavigationSplitView. That works for clicks on inert content, but on
///   macOS clicks landing on a `Button`/`Toggle`/`List` row are consumed by
///   the AppKit-backed control before parent SwiftUI gesture recognizers see
///   them — so the multi-selection wouldn't collapse when the user clicks a
///   button in the detail/content panel, which was a real reported gap. An
///   `NSEvent` local monitor sits below the responder chain and observes every
///   left mouse-down regardless of which control consumes it. The monitor only
///   reads (returns the event unchanged) so AppKit click handling is intact.
///
///   This is the same pattern used by `SessionWindowTabbing.swift` (the other
///   documented AppKit exception). Keep this exception narrow: do not extend
///   the AppKit surface for general view-layer work — see
///   `feedback_native_swiftui_only.md`.
struct SessionWindowPlainTapRecorder: ViewModifier {
  let stateCache: SessionWindowStateCache

  func body(content: Content) -> some View {
    content.background(
      SessionWindowPlainTapMonitor(stateCache: stateCache)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    )
  }
}

private struct SessionWindowPlainTapMonitor: NSViewRepresentable {
  let stateCache: SessionWindowStateCache

  func makeCoordinator() -> Coordinator {
    Coordinator(stateCache: stateCache)
  }

  func makeNSView(context: Context) -> NSView {
    let view = TrackingView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_: NSView, context _: Context) {}

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    if let tracking = nsView as? TrackingView {
      tracking.coordinator = nil
    }
    Task { @MainActor in coordinator.stop() }
  }

  @MainActor
  final class Coordinator {
    let stateCache: SessionWindowStateCache
    private var monitor: Any?
    private weak var hostWindow: NSWindow?

    init(stateCache: SessionWindowStateCache) {
      self.stateCache = stateCache
    }

    func start(for window: NSWindow) {
      guard hostWindow !== window else { return }
      stop()
      hostWindow = window
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
        [weak self, weak window] event in
        guard let self, let window, event.window === window else {
          return event
        }
        let modifiers = EventModifiers(nsModifiers: event.modifierFlags)
        Task { @MainActor in
          self.stateCache.recordPlainTap(modifiers: modifiers)
        }
        return event
      }
    }

    func stop() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      hostWindow = nil
    }
  }

  final class TrackingView: NSView {
    nonisolated(unsafe) var coordinator: Coordinator?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let coord = coordinator
      let attachedWindow = window
      Task { @MainActor in
        if let attachedWindow {
          coord?.start(for: attachedWindow)
        } else {
          coord?.stop()
        }
      }
    }
  }
}

extension EventModifiers {
  fileprivate init(nsModifiers: NSEvent.ModifierFlags) {
    var modifiers: EventModifiers = []
    if nsModifiers.contains(.command) { modifiers.insert(.command) }
    if nsModifiers.contains(.shift) { modifiers.insert(.shift) }
    if nsModifiers.contains(.control) { modifiers.insert(.control) }
    if nsModifiers.contains(.option) { modifiers.insert(.option) }
    if nsModifiers.contains(.capsLock) { modifiers.insert(.capsLock) }
    self = modifiers
  }
}
