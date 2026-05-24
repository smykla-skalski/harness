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
      if currentModifiers != modifiers {
        currentModifiers = modifiers
      }
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
    private let applicationIsActive: () -> Bool
    private let currentModifiers: () -> EventModifiers
    private let notificationCenter: NotificationCenter
    private let installFlagsChangedMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeFlagsChangedMonitor: (Any) -> Void
    private let scheduleUpdate: (@escaping @MainActor () -> Void) -> Void
    private weak var observedWindow: NSWindow?
    private var monitor: Any?
    private var didBecomeKeyObserver: NSObjectProtocol?
    private var didResignKeyObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var didResignActiveObserver: NSObjectProtocol?
    private var isObservedWindowKey = false
    private var deliveredModifiers: EventModifiers?
    private var pendingDisplayedModifiers: EventModifiers?
    private var hasScheduledDisplayUpdate = false

    init(
      update: @escaping (EventModifiers) -> Void,
      applicationIsActive: @escaping () -> Bool = { NSApplication.shared.isActive },
      currentModifiers: @escaping () -> EventModifiers = {
        EventModifiers(nsModifiers: NSEvent.modifierFlags)
      },
      notificationCenter: NotificationCenter = .default,
      installFlagsChangedMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = { handler in
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: handler)
      },
      removeFlagsChangedMonitor: @escaping (Any) -> Void = { monitor in
        NSEvent.removeMonitor(monitor)
      },
      scheduleUpdate: @escaping (@escaping @MainActor () -> Void) -> Void = { update in
        DispatchQueue.main.async {
          Task { @MainActor in update() }
        }
      }
    ) {
      self.update = update
      self.applicationIsActive = applicationIsActive
      self.currentModifiers = currentModifiers
      self.notificationCenter = notificationCenter
      self.installFlagsChangedMonitor = installFlagsChangedMonitor
      self.removeFlagsChangedMonitor = removeFlagsChangedMonitor
      self.scheduleUpdate = scheduleUpdate
    }

    func attach(to window: NSWindow?) {
      guard window !== observedWindow else {
        refreshDisplayedModifiers()
        return
      }
      detach()
      observedWindow = window
      guard let window else {
        return
      }

      isObservedWindowKey = window.isKeyWindow
      installWindowObservers(for: window)
      installApplicationObservers()
      refreshDisplayedModifiers()
      monitor = installFlagsChangedMonitor { [weak self, weak window] event in
        guard let self else {
          return event
        }
        guard let window, event.window === window else {
          self.refreshDisplayedModifiers()
          return event
        }
        self.handleFlagsChanged(EventModifiers(nsModifiers: event.modifierFlags))
        return event
      }
    }

    func handleFlagsChanged(_ modifiers: EventModifiers) {
      requestDisplayedModifiersUpdate(displayedModifiers(for: modifiers))
    }

    func windowDidBecomeKey() {
      isObservedWindowKey = true
      refreshDisplayedModifiers()
    }

    func windowDidResignKey() {
      isObservedWindowKey = false
      requestDisplayedModifiersUpdate([])
    }

    func applicationDidBecomeActive() {
      refreshDisplayedModifiers()
    }

    func applicationDidResignActive() {
      requestDisplayedModifiersUpdate([])
    }

    func detach() {
      if let monitor {
        removeFlagsChangedMonitor(monitor)
        self.monitor = nil
      }
      removeObserver(&didBecomeKeyObserver)
      removeObserver(&didResignKeyObserver)
      removeObserver(&didBecomeActiveObserver)
      removeObserver(&didResignActiveObserver)
      observedWindow = nil
      isObservedWindowKey = false
      requestDisplayedModifiersUpdate([])
    }

    private func installWindowObservers(for window: NSWindow) {
      didBecomeKeyObserver = notificationCenter.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: nil
      ) { [weak self] _ in
        Task { @MainActor in
          self?.windowDidBecomeKey()
        }
      }
      didResignKeyObserver = notificationCenter.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: nil
      ) { [weak self] _ in
        Task { @MainActor in
          self?.windowDidResignKey()
        }
      }
    }

    private func installApplicationObservers() {
      didBecomeActiveObserver = notificationCenter.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        Task { @MainActor in
          self?.applicationDidBecomeActive()
        }
      }
      didResignActiveObserver = notificationCenter.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        Task { @MainActor in
          self?.applicationDidResignActive()
        }
      }
    }

    private func displayedModifiers(for modifiers: EventModifiers) -> EventModifiers {
      guard isObservedWindowKey, applicationIsActive() else {
        return []
      }
      return modifiers
    }

    private func refreshDisplayedModifiers() {
      requestDisplayedModifiersUpdate(displayedModifiers(for: currentModifiers()))
    }

    private func requestDisplayedModifiersUpdate(_ modifiers: EventModifiers) {
      if pendingDisplayedModifiers == modifiers {
        return
      }
      if !hasScheduledDisplayUpdate, deliveredModifiers == modifiers {
        return
      }
      pendingDisplayedModifiers = modifiers
      guard !hasScheduledDisplayUpdate else {
        return
      }
      hasScheduledDisplayUpdate = true
      scheduleUpdate { [weak self] in
        self?.flushPendingDisplayedModifiers()
      }
    }

    private func flushPendingDisplayedModifiers() {
      hasScheduledDisplayUpdate = false
      guard let pendingDisplayedModifiers else {
        return
      }
      self.pendingDisplayedModifiers = nil
      guard deliveredModifiers != pendingDisplayedModifiers else {
        return
      }
      deliveredModifiers = pendingDisplayedModifiers
      update(pendingDisplayedModifiers)
    }

    private func removeObserver(_ observer: inout NSObjectProtocol?) {
      guard let currentObserver = observer else {
        return
      }
      notificationCenter.removeObserver(currentObserver)
      observer = nil
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
