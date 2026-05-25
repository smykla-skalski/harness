#if canImport(SwiftUI)
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct RegistryTrackedSemanticActions: Sendable {
  public typealias PressHandler = @MainActor @Sendable () -> Void

  public static let none = Self()

  public var press: PressHandler?

  public init(press: PressHandler? = nil) {
    self.press = press
  }

  public var supportedActions: [RegistrySemanticAction] {
    press == nil ? [] : [.press]
  }

  var isEmpty: Bool {
    press == nil
  }

  func handler(for action: RegistrySemanticAction) -> PressHandler? {
    switch action {
    case .press:
      press
    }
  }
}

@MainActor
public protocol RegistrySemanticActionSink: AnyObject {
  func claimTrackedSemanticActions(identifier: String, ownerID: UUID)
  func registerTrackedSemanticActions(
    identifier: String,
    semanticActions: RegistryTrackedSemanticActions,
    ownerID: UUID
  )
  func clearTrackedSemanticActions(identifier: String, ownerID: UUID)
  func unregisterTrackedSemanticActions(identifier: String, ownerID: UUID)
}

public extension View {
  /// Register this view with an `AccessibilityRegistry` so the MCP server can discover it.
  ///
  /// - Parameters:
  ///   - identifier: Stable identifier exposed over the IPC protocol; must match the view's
  ///     `.accessibilityIdentifier(...)` so on-device UI tests and the MCP server line up.
  ///   - kind: Semantic kind surfaced to the MCP client.
  ///   - label: Optional human-readable label.
  ///   - value: Optional current value (e.g. text-field content).
  ///   - hint: Optional accessibility hint.
  ///   - windowID: Optional `CGWindowID` of the hosting window, when known.
  ///   - enabled: Whether the element currently accepts interaction.
  ///   - semanticActions: In-app semantic actions the registry host can execute directly.
  ///   - semanticActionSink: Main-actor sink that owns the live action handlers.
  ///   - registry: Registry instance to target.
  func trackAccessibility(
    _ identifier: String,
    kind: RegistryElementKind,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    windowID: Int? = nil,
    enabled: Bool = true,
    semanticActions: RegistryTrackedSemanticActions = .none,
    semanticActionSink: (any RegistrySemanticActionSink)? = nil,
    registry: AccessibilityRegistry
  ) -> some View {
    modifier(
      TrackAccessibilityModifier(
        elementID: identifier,
        kind: kind,
        label: label,
        value: value,
        hint: hint,
        windowID: windowID,
        enabled: enabled,
        semanticActions: semanticActions,
        semanticActionSink: semanticActionSink,
        registry: registry
      )
    )
  }
}

struct TrackAccessibilityModifier: ViewModifier {
  let elementID: String
  let kind: RegistryElementKind
  let label: String?
  let value: String?
  let hint: String?
  let windowID: Int?
  let enabled: Bool
  let semanticActions: RegistryTrackedSemanticActions
  let semanticActionSink: (any RegistrySemanticActionSink)?
  let registry: AccessibilityRegistry

  func body(content: Content) -> some View {
    content
      .accessibilityIdentifier(elementID)
      .background(
        TrackAccessibilityProbe(
          elementID: elementID,
          kind: kind,
          label: label,
          value: value,
          hint: hint,
          windowID: windowID,
          enabled: enabled,
          semanticActions: semanticActions,
          semanticActionSink: semanticActionSink,
          registry: registry
        )
        .allowsHitTesting(false)
      )
  }
}

#if canImport(AppKit)
private struct TrackAccessibilityProbe: NSViewRepresentable {
  let elementID: String
  let kind: RegistryElementKind
  let label: String?
  let value: String?
  let hint: String?
  let windowID: Int?
  let enabled: Bool
  let semanticActions: RegistryTrackedSemanticActions
  let semanticActionSink: (any RegistrySemanticActionSink)?
  let registry: AccessibilityRegistry

  func makeNSView(context: Context) -> TrackAccessibilityNSView {
    let view = TrackAccessibilityNSView()
    view.configure(
      elementID: elementID,
      kind: kind,
      label: label,
      value: value,
      hint: hint,
      windowID: windowID,
      enabled: enabled,
      semanticActions: semanticActions,
      semanticActionSink: semanticActionSink,
      registry: registry
    )
    return view
  }

  func updateNSView(_ nsView: TrackAccessibilityNSView, context: Context) {
    nsView.configure(
      elementID: elementID,
      kind: kind,
      label: label,
      value: value,
      hint: hint,
      windowID: windowID,
      enabled: enabled,
      semanticActions: semanticActions,
      semanticActionSink: semanticActionSink,
      registry: registry
    )
  }

  static func dismantleNSView(_ nsView: TrackAccessibilityNSView, coordinator: ()) {
    nsView.unregister()
  }
}

final class TrackAccessibilityNSView: NSView {
  private static let didUpdateRefreshInterval: Duration = .milliseconds(500)
  private static let layoutRefreshInterval: Duration = .milliseconds(250)
  private static let didUpdatePublishDebounce: Duration = .milliseconds(750)
  private static let layoutPublishDebounce: Duration = .milliseconds(350)

  private let registrationOwnerID = UUID()
  private let clock = ContinuousClock()
  private var trackedElementID = ""
  private var kind: RegistryElementKind = .other
  private var label: String?
  private var value: String?
  private var hint: String?
  private var explicitWindowID: Int?
  private var enabled = true
  private var semanticActions = RegistryTrackedSemanticActions.none
  private var semanticActionSink: (any RegistrySemanticActionSink)?
  private var registry: AccessibilityRegistry?
  private var claimTask: Task<Void, Never>?
  private var deferredPublishTask: Task<Void, Never>?
  private var deferredPublishReason: DeferredPublishReason?
  private var publishTask: Task<Void, Never>?
  private var observedWindow: NSWindow?
  // nonisolated(unsafe) so the nonisolated deinit can read it without the
  // non-Sendable error. Mutations all happen on the MainActor (see
  // `beginObserving`); the deinit only reads after the last write, so
  // concurrent access is not possible. ARC may release this NSView on any
  // thread (notably com.apple.SwiftUI.DisplayLink during cockpit / view
  // tree transitions) and `MainActor.assumeIsolated` would trap with a
  // libdispatch BUG off-main.
  private nonisolated(unsafe) var windowObservers: [NSObjectProtocol] = []
  private var lastPublishedElement: RegistryElement?
  private var lastDidUpdateRefreshAt: ContinuousClock.Instant?
  private var lastLayoutRefreshAt: ContinuousClock.Instant?
  private var lastConfiguredSignature: ConfigurationSignature?
  var accessibilityFrameProviderOverride: ((TrackAccessibilityNSView) -> NSRect)?

  private struct ConfigurationSignature: Equatable {
    let elementID: String
    let kind: RegistryElementKind
    let label: String?
    let value: String?
    let hint: String?
    let windowID: Int?
    let enabled: Bool
    let supportedActions: [RegistrySemanticAction]
    let registryID: ObjectIdentifier
    let sinkID: ObjectIdentifier?
  }

  private enum DeferredPublishReason {
    case immediate
    case didUpdate
    case layout
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    alphaValue = 0
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError()
  }

  deinit {
    // Thread-safe inline cleanup only. ARC may release this NSView on any
    // thread (notably com.apple.SwiftUI.DisplayLink), so we cannot wrap
    // cleanup in `MainActor.assumeIsolated` — that traps with a libdispatch
    // BUG off-main. NotificationCenter.removeObserver is documented
    // thread-safe; the registry-side unregister already happens via
    // `dismantleNSView` (which SwiftUI runs on the MainActor) and via
    // `viewDidMoveToWindow(nil)`, so there is no MainActor-only step left.
    deferredPublishTask?.cancel()
    TrackAccessibilityWindowUpdateHub.shared.unregister(self)
    windowObservers.forEach(NotificationCenter.default.removeObserver)
  }

  func configure(
    elementID: String,
    kind: RegistryElementKind,
    label: String?,
    value: String?,
    hint: String?,
    windowID: Int?,
    enabled: Bool,
    semanticActions: RegistryTrackedSemanticActions,
    semanticActionSink: (any RegistrySemanticActionSink)?,
    registry: AccessibilityRegistry
  ) {
    if trackedElementID != elementID, let currentRegistry = self.registry, !trackedElementID.isEmpty {
      let previousElementID = trackedElementID
      let previousClaimTask = claimTask
      let ownerID = registrationOwnerID
      let previousSemanticActionSink = self.semanticActionSink
      Task { @MainActor in
        await previousClaimTask?.value
        await currentRegistry.unregisterTrackedElement(
          identifier: previousElementID,
          ownerID: ownerID
        )
        previousSemanticActionSink?.unregisterTrackedSemanticActions(
          identifier: previousElementID,
          ownerID: ownerID
        )
      }
      lastPublishedElement = nil
      lastConfiguredSignature = nil
    }
    let signature = ConfigurationSignature(
      elementID: elementID,
      kind: kind,
      label: label,
      value: value,
      hint: hint,
      windowID: windowID,
      enabled: enabled,
      supportedActions: semanticActions.supportedActions,
      registryID: ObjectIdentifier(registry),
      sinkID: semanticActionSink.map(ObjectIdentifier.init)
    )
    // Keep the freshly-captured semanticActions closure in sync regardless of
    // early-out, so the next layout-driven publish re-registers with the
    // current press handler if the frame changes.
    self.semanticActions = semanticActions
    self.semanticActionSink = semanticActionSink
    if lastConfiguredSignature == signature, claimTask != nil, self.registry === registry {
      return
    }
    trackedElementID = elementID
    self.kind = kind
    self.label = label
    self.value = value
    self.hint = hint
    explicitWindowID = windowID
    self.enabled = enabled
    self.registry = registry
    lastConfiguredSignature = signature
    claimTrackedElement()
    beginObserving(window: window)
    schedulePublishCurrentElement()
  }

  func unregister() {
    deferredPublishTask?.cancel()
    deferredPublishTask = nil
    deferredPublishReason = nil
    publishTask?.cancel()
    publishTask = nil
    let claimTask = self.claimTask
    self.claimTask = nil
    lastConfiguredSignature = nil
    guard let registry, !trackedElementID.isEmpty else {
      return
    }
    let elementID = trackedElementID
    let ownerID = registrationOwnerID
    let semanticActionSink = self.semanticActionSink
    Task { @MainActor in
      await claimTask?.value
      await registry.unregisterTrackedElement(identifier: elementID, ownerID: ownerID)
      semanticActionSink?.unregisterTrackedSemanticActions(
        identifier: elementID,
        ownerID: ownerID
      )
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      tearDownWindowObservation()
      lastPublishedElement = nil
      unregister()
      return
    }
    beginObserving(window: window)
    schedulePublishCurrentElement()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard superview != nil else {
      lastPublishedElement = nil
      unregister()
      return
    }
    schedulePublishCurrentElement()
  }

  override func layout() {
    super.layout()
    schedulePublishCurrentElement(triggeredByLayout: true)
  }

  private func beginObserving(window: NSWindow?) {
    guard observedWindow !== window else {
      return
    }
    tearDownWindowObservation()
    observedWindow = window
    guard let window else {
      return
    }
    let center = NotificationCenter.default
    windowObservers = [
      center.addObserver(
        forName: NSWindow.didMoveNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        // Hop explicitly: `MainActor.assumeIsolated` would trap if the
        // block ever fires off-main on macOS 26.
        Task { @MainActor [weak self] in
          self?.schedulePublishCurrentElement(triggeredByDidUpdate: false)
        }
      },
      center.addObserver(
        forName: NSWindow.didResizeNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        // Hop explicitly: `MainActor.assumeIsolated` would trap if the
        // block ever fires off-main on macOS 26.
        Task { @MainActor [weak self] in
          self?.schedulePublishCurrentElement(triggeredByDidUpdate: false)
        }
      },
      center.addObserver(
        forName: NSWindow.didChangeScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        // Hop explicitly: `MainActor.assumeIsolated` would trap if the
        // block ever fires off-main on macOS 26.
        Task { @MainActor [weak self] in
          self?.schedulePublishCurrentElement(triggeredByDidUpdate: false)
        }
      },
    ]
    TrackAccessibilityWindowUpdateHub.shared.register(self, for: window)
  }

  private func tearDownWindowObservation() {
    TrackAccessibilityWindowUpdateHub.shared.unregister(self)
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers.removeAll()
    observedWindow = nil
  }

  func schedulePublishAfterWindowDidUpdate() {
    schedulePublishCurrentElement(triggeredByDidUpdate: true)
  }

  private func claimTrackedElement() {
    claimTask?.cancel()
    guard let registry, !trackedElementID.isEmpty else {
      return
    }
    let elementID = trackedElementID
    let ownerID = registrationOwnerID
    let semanticActionSink = self.semanticActionSink
    claimTask = Task { @MainActor in
      guard !Task.isCancelled else {
        return
      }
      await registry.claimTrackedElement(identifier: elementID, ownerID: ownerID)
      semanticActionSink?.claimTrackedSemanticActions(
        identifier: elementID,
        ownerID: ownerID
      )
    }
  }

  private func schedulePublishCurrentElement(
    triggeredByDidUpdate: Bool = false,
    triggeredByLayout: Bool = false
  ) {
    if triggeredByDidUpdate, shouldRefreshOnDidUpdate() == false {
      return
    }
    if triggeredByLayout, shouldRefreshOnLayout() == false {
      return
    }
    guard registry != nil, !trackedElementID.isEmpty else {
      return
    }
    let publishReason = publishReason(
      triggeredByDidUpdate: triggeredByDidUpdate,
      triggeredByLayout: triggeredByLayout
    )
    if publishReason == .didUpdate,
      deferredPublishReason == .didUpdate,
      deferredPublishTask != nil
    {
      return
    }
    deferredPublishTask?.cancel()
    deferredPublishReason = publishReason
    if triggeredByDidUpdate {
      lastDidUpdateRefreshAt = clock.now
    }
    if triggeredByLayout {
      lastLayoutRefreshAt = clock.now
    }
    let publishDelay = publishDebounceDelay(
      triggeredByDidUpdate: triggeredByDidUpdate,
      triggeredByLayout: triggeredByLayout
    )
    // Keep frame publication deferred so representable-backed views finish the
    // current update/layout pass before the registry snapshots screen geometry.
    // Layout and didUpdate notifications can arrive every frame during scroll;
    // debounce those refreshes so dense panes publish after the churn settles
    // instead of doing registry work while the user is actively interacting.
    deferredPublishTask = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled else {
        return
      }
      if publishDelay > .zero {
        do {
          try await Task.sleep(for: publishDelay)
        } catch {
          return
        }
        guard !Task.isCancelled else {
          return
        }
      } else {
        await Task.yield()
        guard !Task.isCancelled else {
          return
        }
      }
      self.deferredPublishTask = nil
      self.deferredPublishReason = nil
      self.publishCurrentElement()
    }
  }

  private func publishReason(
    triggeredByDidUpdate: Bool,
    triggeredByLayout: Bool
  ) -> DeferredPublishReason {
    if triggeredByDidUpdate {
      return .didUpdate
    }
    if triggeredByLayout {
      return .layout
    }
    return .immediate
  }

  private func shouldRefreshOnDidUpdate() -> Bool {
    guard let lastDidUpdateRefreshAt else {
      return true
    }
    let now = clock.now
    return lastDidUpdateRefreshAt + Self.didUpdateRefreshInterval <= now
  }

  private func shouldRefreshOnLayout() -> Bool {
    guard let lastLayoutRefreshAt else {
      return true
    }
    let now = clock.now
    return lastLayoutRefreshAt + Self.layoutRefreshInterval <= now
  }

  private func publishDebounceDelay(
    triggeredByDidUpdate: Bool,
    triggeredByLayout: Bool
  ) -> Duration {
    if triggeredByDidUpdate {
      return Self.didUpdatePublishDebounce
    }
    if triggeredByLayout {
      return Self.layoutPublishDebounce
    }
    return .zero
  }

  private func currentAccessibilityFrame() -> NSRect {
    if let accessibilityFrameProviderOverride {
      return accessibilityFrameProviderOverride(self)
    }
    guard let window, isHiddenOrHasHiddenAncestor == false else {
      return .null
    }
    let visibleBounds = clippedVisibleBounds()
    guard visibleBounds.isNull == false, visibleBounds.isEmpty == false else {
      return .null
    }
    return window.convertToScreen(convert(visibleBounds, to: nil))
  }

  private func clippedVisibleBounds() -> NSRect {
    var clippedBounds = bounds
    var ancestor = superview

    while let currentAncestor = ancestor {
      if let clipView = currentAncestor as? NSClipView {
        clippedBounds = clippedBounds.intersection(convert(clipView.bounds, from: clipView))
        if clippedBounds.isEmpty || clippedBounds.isNull {
          return .null
        }
      }
      ancestor = currentAncestor.superview
    }

    return clippedBounds
  }

  private func publishCurrentElement() {
    guard let registry, !trackedElementID.isEmpty else {
      return
    }
    // Derive the on-screen frame directly from view geometry so dense windows
    // do not re-enter AX layout on every registry refresh.
    let frame = currentAccessibilityFrame()
    guard frame.isNull == false, frame.isInfinite == false, frame.isEmpty == false else {
      guard lastPublishedElement != nil else {
        return
      }
      lastPublishedElement = nil
      publishTask?.cancel()
      let claimTask = self.claimTask
      let elementID = trackedElementID
      let ownerID = registrationOwnerID
      let semanticActionSink = self.semanticActionSink
      publishTask = Task { @MainActor in
        await claimTask?.value
        guard !Task.isCancelled else {
          return
        }
        await registry.clearTrackedElement(identifier: elementID, ownerID: ownerID)
        semanticActionSink?.clearTrackedSemanticActions(
          identifier: elementID,
          ownerID: ownerID
        )
      }
      return
    }

    let element = RegistryElement(
      identifier: trackedElementID,
      label: label,
      value: value,
      hint: hint,
      kind: kind,
      actions: semanticActions.supportedActions,
      frame: RegistryRect(frame),
      windowID: explicitWindowID ?? window?.windowNumber,
      enabled: enabled
    )
    guard lastPublishedElement != element else {
      return
    }
    lastPublishedElement = element

    publishTask?.cancel()
    let claimTask = self.claimTask
    let ownerID = registrationOwnerID
    let semanticActionSink = self.semanticActionSink
    let semanticActions = self.semanticActions
    publishTask = Task { @MainActor in
      await claimTask?.value
      guard !Task.isCancelled else {
        return
      }
      await registry.registerTrackedElement(element, ownerID: ownerID)
      semanticActionSink?.registerTrackedSemanticActions(
        identifier: element.identifier,
        semanticActions: semanticActions,
        ownerID: ownerID
      )
    }
  }
}

private final class TrackAccessibilityWindowUpdateHub: @unchecked Sendable {
  static let shared = TrackAccessibilityWindowUpdateHub()
  private static let didUpdateFanoutInterval: Duration = .milliseconds(500)

  private struct WindowEntry {
    weak var window: NSWindow?
    let observer: NSObjectProtocol
    var views: [WeakTrackedView]
    var lastDidUpdateFanoutAt: ContinuousClock.Instant?
    var pendingDidUpdateTask: Task<Void, Never>?
  }

  private struct WeakTrackedView {
    weak var view: TrackAccessibilityNSView?
  }

  private var entries: [ObjectIdentifier: WindowEntry] = [:]
  private let clock = ContinuousClock()
  private let lock = NSLock()

  private init() {}

  func register(_ view: TrackAccessibilityNSView, for window: NSWindow) {
    let windowID = ObjectIdentifier(window)
    lock.lock()
    if var entry = entries[windowID] {
      entry.views = liveViews(from: entry.views)
      if entry.views.contains(where: { $0.view === view }) == false {
        entry.views.append(WeakTrackedView(view: view))
      }
      entries[windowID] = entry
      lock.unlock()
      return
    }

    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didUpdateNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      self?.notifyDidUpdate(windowID: windowID)
    }
    entries[windowID] = WindowEntry(
      window: window,
      observer: observer,
      views: [WeakTrackedView(view: view)],
      lastDidUpdateFanoutAt: nil,
      pendingDidUpdateTask: nil
    )
    lock.unlock()
  }

  func unregister(_ view: TrackAccessibilityNSView) {
    var observersToRemove: [NSObjectProtocol] = []
    lock.lock()
    for windowID in Array(entries.keys) {
      guard var entry = entries[windowID] else {
        continue
      }
      entry.views = liveViews(from: entry.views).filter { $0.view !== view }
      if entry.views.isEmpty || entry.window == nil {
        entry.pendingDidUpdateTask?.cancel()
        observersToRemove.append(entry.observer)
        entries[windowID] = nil
      } else {
        entries[windowID] = entry
      }
    }
    lock.unlock()
    observersToRemove.forEach(NotificationCenter.default.removeObserver)
  }

  private func notifyDidUpdate(windowID: ObjectIdentifier) {
    if let views = collectViewsForDidUpdate(windowID: windowID) {
      fanOutDidUpdate(to: views)
    }
  }

  private func collectViewsForDidUpdate(windowID: ObjectIdentifier) -> [TrackAccessibilityNSView]? {
    let views: [TrackAccessibilityNSView]
    var observerToRemove: NSObjectProtocol?
    lock.lock()
    guard var entry = entries[windowID] else {
      lock.unlock()
      return nil
    }
    let liveViews = liveViews(from: entry.views)
    if liveViews.isEmpty || entry.window == nil {
      entry.pendingDidUpdateTask?.cancel()
      observerToRemove = entry.observer
      entries[windowID] = nil
      lock.unlock()
      if let observerToRemove {
        NotificationCenter.default.removeObserver(observerToRemove)
      }
      return nil
    }

    let now = clock.now
    let shouldFanOutNow =
      entry.lastDidUpdateFanoutAt.map {
        $0 + Self.didUpdateFanoutInterval <= now
      } ?? true

    guard shouldFanOutNow else {
      if entry.pendingDidUpdateTask == nil,
        let lastFanout = entry.lastDidUpdateFanoutAt
      {
        let delay = now.duration(to: lastFanout + Self.didUpdateFanoutInterval)
        entry.pendingDidUpdateTask = scheduledDidUpdateTask(
          windowID: windowID,
          delay: delay
        )
      }
      entry.views = liveViews
      entries[windowID] = entry
      lock.unlock()
      return nil
    }

    entry.pendingDidUpdateTask?.cancel()
    entry.pendingDidUpdateTask = nil
    entry.lastDidUpdateFanoutAt = now
    entry.views = liveViews
    entries[windowID] = entry
    views = liveViews.compactMap(\.view)
    lock.unlock()

    return views
  }

  private func scheduledDidUpdateTask(
    windowID: ObjectIdentifier,
    delay: Duration
  ) -> Task<Void, Never> {
    Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      self?.notifyScheduledDidUpdate(windowID: windowID)
    }
  }

  private func notifyScheduledDidUpdate(windowID: ObjectIdentifier) {
    let views: [TrackAccessibilityNSView]
    var observerToRemove: NSObjectProtocol?
    lock.lock()
    guard var entry = entries[windowID] else {
      lock.unlock()
      return
    }
    let liveViews = liveViews(from: entry.views)
    if liveViews.isEmpty || entry.window == nil {
      observerToRemove = entry.observer
      entries[windowID] = nil
    } else {
      entry.lastDidUpdateFanoutAt = clock.now
      entry.pendingDidUpdateTask = nil
      entry.views = liveViews
      entries[windowID] = entry
    }
    views = liveViews.compactMap(\.view)
    lock.unlock()

    if let observerToRemove {
      NotificationCenter.default.removeObserver(observerToRemove)
    }
    fanOutDidUpdate(to: views)
  }

  private func fanOutDidUpdate(to views: [TrackAccessibilityNSView]) {
    guard views.isEmpty == false else { return }
    Task { @MainActor in
      for view in views {
        view.schedulePublishAfterWindowDidUpdate()
      }
    }
  }

  private func liveViews(from views: [WeakTrackedView]) -> [WeakTrackedView] {
    views.filter { $0.view != nil }
  }
}
#else
private struct TrackAccessibilityProbe: View {
  let elementID: String
  let kind: RegistryElementKind
  let label: String?
  let value: String?
  let hint: String?
  let windowID: Int?
  let enabled: Bool
  let registry: AccessibilityRegistry

  var body: some View {
    GeometryReader { proxy in
      Color.clear
        .onAppear {
          publish(frame: proxy.frame(in: .global))
        }
        .onChange(of: proxy.frame(in: .global)) { _, newFrame in
          publish(frame: newFrame)
        }
        .onDisappear {
          let elementID = self.elementID
          let registry = self.registry
          Task { @MainActor in
            await registry.unregisterElement(identifier: elementID)
          }
        }
    }
  }

  private func publish(frame: CGRect) {
    let element = RegistryElement(
      identifier: elementID,
      label: label,
      value: value,
      hint: hint,
      kind: kind,
      frame: RegistryRect(frame),
      windowID: windowID,
      enabled: enabled
    )
    let registry = self.registry
    Task { @MainActor in
      await registry.registerElement(element)
    }
  }
}
#endif
#endif
