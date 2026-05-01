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

private final class TrackAccessibilityNSView: NSView {
  private let registrationOwnerID = UUID()
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
  private var publishTask: Task<Void, Never>?
  private var observedWindow: NSWindow?
  private var windowObservers: [NSObjectProtocol] = []
  private var lastPublishedElement: RegistryElement?

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
    MainActor.assumeIsolated {
      tearDownWindowObservation()
    }
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
    }
    trackedElementID = elementID
    self.kind = kind
    self.label = label
    self.value = value
    self.hint = hint
    explicitWindowID = windowID
    self.enabled = enabled
    self.semanticActions = semanticActions
    self.semanticActionSink = semanticActionSink
    self.registry = registry
    claimTrackedElement()
    beginObserving(window: window)
    publishCurrentElement()
  }

  func unregister() {
    publishTask?.cancel()
    publishTask = nil
    let claimTask = self.claimTask
    self.claimTask = nil
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
    publishCurrentElement()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard superview != nil else {
      lastPublishedElement = nil
      unregister()
      return
    }
    publishCurrentElement()
  }

  override func layout() {
    super.layout()
    publishCurrentElement()
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
        MainActor.assumeIsolated {
          self?.publishCurrentElement()
        }
      },
      center.addObserver(
        forName: NSWindow.didResizeNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.publishCurrentElement()
        }
      },
      center.addObserver(
        forName: NSWindow.didUpdateNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.publishCurrentElement()
        }
      },
      center.addObserver(
        forName: NSWindow.didChangeScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.publishCurrentElement()
        }
      },
    ]
  }

  private func tearDownWindowObservation() {
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers.removeAll()
    observedWindow = nil
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

  private func publishCurrentElement() {
    guard let registry, !trackedElementID.isEmpty else {
      return
    }
    // Use the AppKit accessibility frame so manual registrations line up with
    // the same screen-space coordinates harvested from NSAccessibility.
    let frame = accessibilityFrame()
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
