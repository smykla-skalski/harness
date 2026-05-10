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
  let isEnabled: Bool

  func body(content: Content) -> some View {
    content.background(
      SessionWindowPlainTapMonitor(
        stateCache: stateCache,
        isEnabled: isEnabled
      )
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    )
  }
}

private struct SessionWindowPlainTapMonitor: NSViewRepresentable {
  let stateCache: SessionWindowStateCache
  let isEnabled: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(stateCache: stateCache)
  }

  func makeNSView(context: Context) -> NSView {
    let view = TrackingView()
    view.coordinator = context.coordinator
    view.isEnabled = isEnabled
    context.coordinator.setEnabled(isEnabled, for: view.window)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let tracking = nsView as? TrackingView else {
      return
    }
    tracking.coordinator = context.coordinator
    tracking.isEnabled = isEnabled
    context.coordinator.setEnabled(isEnabled, for: tracking.window)
  }

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
    private var isEnabled = false

    init(stateCache: SessionWindowStateCache) {
      self.stateCache = stateCache
    }

    func setEnabled(_ enabled: Bool, for window: NSWindow?) {
      isEnabled = enabled
      guard enabled, let window else {
        stop()
        return
      }
      start(for: window)
    }

    func start(for window: NSWindow) {
      guard isEnabled else {
        stop()
        return
      }
      guard hostWindow !== window else { return }
      stop()
      hostWindow = window
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown]
      ) { [weak self, weak window] event in
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
    var isEnabled = false

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let coord = coordinator
      let attachedWindow = window
      let enabled = isEnabled
      Task { @MainActor in
        coord?.setEnabled(enabled, for: attachedWindow)
      }
    }
  }
}

struct SessionWindowModifierKeysMonitor: NSViewRepresentable {
  @Binding var currentModifiers: EventModifiers

  func makeCoordinator() -> Coordinator {
    Coordinator(update: { modifiers in
      currentModifiers = modifiers
    })
  }

  func makeNSView(context: Context) -> NSView {
    let view = TrackingView()
    view.coordinator = context.coordinator
    context.coordinator.attach(to: view.window)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let trackingView = nsView as? TrackingView else {
      return
    }
    trackingView.coordinator = context.coordinator
    context.coordinator.attach(to: trackingView.window)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    if let trackingView = nsView as? TrackingView {
      trackingView.coordinator = nil
    }
    Task { @MainActor in
      coordinator.detach()
    }
  }

  @MainActor
  final class Coordinator {
    private let update: (EventModifiers) -> Void
    private weak var observedWindow: NSWindow?
    private var monitor: Any?

    init(update: @escaping (EventModifiers) -> Void) {
      self.update = update
    }

    func attach(to window: NSWindow?) {
      guard window !== observedWindow else { return }
      detach()
      observedWindow = window
      guard let window else {
        update([])
        return
      }

      update(EventModifiers(nsModifiers: NSEvent.modifierFlags))
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.flagsChanged]
      ) { [weak self, weak window] event in
        guard let self, let window, event.window === window else {
          return event
        }
        update(EventModifiers(nsModifiers: event.modifierFlags))
        return event
      }
    }

    func detach() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      observedWindow = nil
      update([])
    }
  }

  final class TrackingView: NSView {
    nonisolated(unsafe) var coordinator: Coordinator?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let coordinator = coordinator
      let attachedWindow = window
      Task { @MainActor in
        coordinator?.attach(to: attachedWindow)
      }
    }
  }
}

extension EventModifiers {
  init(nsModifiers: NSEvent.ModifierFlags) {
    var modifiers: EventModifiers = []
    if nsModifiers.contains(.command) { modifiers.insert(.command) }
    if nsModifiers.contains(.shift) { modifiers.insert(.shift) }
    if nsModifiers.contains(.control) { modifiers.insert(.control) }
    if nsModifiers.contains(.option) { modifiers.insert(.option) }
    if nsModifiers.contains(.capsLock) { modifiers.insert(.capsLock) }
    self = modifiers
  }
}
