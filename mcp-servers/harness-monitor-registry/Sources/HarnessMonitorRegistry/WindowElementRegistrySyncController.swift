#if canImport(AppKit)
import AppKit

enum WindowElementRegistrySyncReason {
  case structural
  case routineDidUpdate
}

@MainActor
final class WindowElementRegistrySyncController {
  private enum PendingAction {
    case replace(
      window: NSWindow,
      generation: UInt64,
      ownerID: UUID,
      reason: WindowElementRegistrySyncReason
    )
    case clear(Int, ownerID: UUID)
  }

  private let registry: AccessibilityRegistry
  private let payloadWorker = WindowElementRegistryPayloadWorker()
  private let minimumReplacementInterval: Duration
  private let onReplacementApplied: @MainActor () -> Void
  private let clock = ContinuousClock()
  private var trackedWindowID: Int?
  private var trackingGeneration: UInt64 = 0
  private var trackingOwnerID = UUID()
  private var pendingClears: [PendingAction] = []
  private var pendingReplacement: PendingAction?
  private var flushTask: Task<Void, Never>?
  private var lastReplacementAppliedAt: ContinuousClock.Instant?
  private var lastAppliedPayloadSignature: WindowElementRegistryPayloadSignature?

  init(
    registry: AccessibilityRegistry,
    minimumReplacementInterval: Duration = .milliseconds(120),
    onReplacementApplied: @escaping @MainActor () -> Void = {}
  ) {
    self.registry = registry
    self.minimumReplacementInterval = minimumReplacementInterval
    self.onReplacementApplied = onReplacementApplied
  }

  func beginTracking(windowID: Int) -> UInt64 {
    trackingGeneration &+= 1
    trackedWindowID = windowID
    trackingOwnerID = UUID()
    return trackingGeneration
  }

  func sync(
    window: NSWindow,
    generation: UInt64,
    reason: WindowElementRegistrySyncReason = .structural
  ) {
    guard generation == trackingGeneration, trackedWindowID == window.windowNumber else {
      return
    }
    enqueue(
      .replace(
        window: window,
        generation: generation,
        ownerID: trackingOwnerID,
        reason: reason
      )
    )
  }

  func stopTracking() {
    guard let windowID = trackedWindowID else { return }
    let ownerID = trackingOwnerID
    trackingGeneration &+= 1
    trackedWindowID = nil
    trackingOwnerID = UUID()
    lastAppliedPayloadSignature = nil
    enqueue(.clear(windowID, ownerID: ownerID))
  }

  func waitForIdle() async {
    while let task = flushTask {
      await task.value
    }
  }

  private func enqueue(_ action: PendingAction) {
    switch action {
    case .replace:
      pendingReplacement = action
    case .clear:
      pendingClears.append(action)
    }
    guard flushTask == nil else { return }
    let registry = registry
    flushTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while let action = self.takePendingActionOrFinish() {
        await self.apply(action, to: registry)
      }
    }
  }

  private func takePendingActionOrFinish() -> PendingAction? {
    if pendingClears.isEmpty == false {
      return pendingClears.removeFirst()
    }
    if let pendingReplacement {
      self.pendingReplacement = nil
      return pendingReplacement
    }
    guard pendingClears.isEmpty, pendingReplacement == nil else {
      return nil
    }
    flushTask = nil
    return nil
  }

  private func apply(_ action: PendingAction, to registry: AccessibilityRegistry) async {
    switch action {
    case .replace(let window, let generation, let ownerID, let reason):
      if let delay = replacementDelay() {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
      }
      guard
        generation == trackingGeneration,
        trackedWindowID == window.windowNumber,
        trackingOwnerID == ownerID
      else {
        return
      }
      lastReplacementAppliedAt = clock.now

      let hasExplicitElements = await registry.hasExplicitElements(windowID: window.windowNumber)
      if reason == .routineDidUpdate, hasExplicitElements {
        lastAppliedPayloadSignature = nil
        await registry.unregisterTrackedWindowElements(
          windowID: window.windowNumber,
          ownerID: ownerID
        )
        return
      }

      let payload = await WindowAccessibilityElementSnapshotter.payload(
        in: window,
        payloadWorker: payloadWorker
      )
      if hasExplicitElements == false {
        guard payload.signature != lastAppliedPayloadSignature else {
          return
        }
        lastAppliedPayloadSignature = payload.signature
      } else {
        lastAppliedPayloadSignature = nil
      }
      onReplacementApplied()
      await registry.replaceTrackedWindowElements(
        windowID: window.windowNumber,
        elements: payload.elements,
        ownerID: ownerID
      )
    case .clear(let windowID, let ownerID):
      await registry.unregisterTrackedWindowElements(windowID: windowID, ownerID: ownerID)
    }
  }

  private func replacementDelay() -> Duration? {
    guard minimumReplacementInterval > .zero, let lastReplacementAppliedAt else {
      return nil
    }
    let nextAllowed = lastReplacementAppliedAt + minimumReplacementInterval
    let now = clock.now
    guard now < nextAllowed else {
      return nil
    }
    return now.duration(to: nextAllowed)
  }
}

@MainActor
enum WindowAccessibilityChildNodeCollector {
  static func collect(from values: [Any]) -> [any NSAccessibilityProtocol] {
    var children: [any NSAccessibilityProtocol] = []
    var seen: Set<ObjectIdentifier> = []
    append(contentsOf: values, to: &children, seen: &seen)
    return children
  }

  static func append(
    contentsOf values: [Any]?,
    to children: inout [any NSAccessibilityProtocol],
    seen: inout Set<ObjectIdentifier>
  ) {
    guard let values else { return }
    for value in values {
      append(value, to: &children, seen: &seen)
    }
  }

  static func append(
    contentsOf values: [any NSAccessibilityElementProtocol]?,
    to children: inout [any NSAccessibilityProtocol],
    seen: inout Set<ObjectIdentifier>
  ) {
    guard let values else { return }
    for value in values {
      append(value, to: &children, seen: &seen)
    }
  }

  static func append<T>(
    _ value: T,
    to children: inout [any NSAccessibilityProtocol],
    seen: inout Set<ObjectIdentifier>
  ) {
    guard let child = value as? any NSAccessibilityProtocol else {
      return
    }
    let identifier = ObjectIdentifier(child as AnyObject)
    guard seen.insert(identifier).inserted else {
      return
    }
    children.append(child)
  }

  static func append(
    contentsOf values: [NSView],
    to children: inout [any NSAccessibilityProtocol],
    seen: inout Set<ObjectIdentifier>
  ) {
    for value in values {
      append(value, to: &children, seen: &seen)
    }
  }
}

@MainActor
private enum WindowAccessibilityElementSnapshotter {
  private static let maximumVisitedNodes = 700
  private static let traversalBatchSize = 40

  static func payload(
    in window: NSWindow,
    payloadWorker: WindowElementRegistryPayloadWorker
  ) async -> WindowElementRegistryPayload {
    var queue: [any NSAccessibilityProtocol] = [window]
    var index = 0
    var visited: Set<ObjectIdentifier> = []
    var harvested: [RegistryElement] = []

    while index < queue.count, visited.count < maximumVisitedNodes {
      if Task.isCancelled {
        return .empty
      }
      let node = queue[index]
      index += 1

      let identifier = ObjectIdentifier(node as AnyObject)
      guard visited.insert(identifier).inserted else {
        continue
      }

      queue.append(contentsOf: childNodes(of: node))

      guard let element = registryElement(from: node, windowID: window.windowNumber) else {
        continue
      }
      harvested.append(element)

      if index.isMultiple(of: traversalBatchSize) {
        await Task.yield()
      }
    }

    return await payloadWorker.replacementPayload(from: harvested)
  }

  private static func childNodes(
    of node: any NSAccessibilityProtocol
  ) -> [any NSAccessibilityProtocol] {
    var children: [any NSAccessibilityProtocol] = []
    var seen: Set<ObjectIdentifier> = []

    if let window = node as? NSWindow {
      appendPublishedAccessibilityChildren(of: window, to: &children, seen: &seen)
      if let contentView = window.contentView {
        WindowAccessibilityChildNodeCollector.append(contentView, to: &children, seen: &seen)
      }
      return children
    }

    if let view = node as? NSView {
      if shouldTraversePublishedAccessibilityChildren(of: view) {
        appendPublishedAccessibilityChildren(of: view, to: &children, seen: &seen)
      }
      if children.isEmpty {
        WindowAccessibilityChildNodeCollector.append(
          contentsOf: view.subviews,
          to: &children,
          seen: &seen
        )
      }
      return children
    }

    appendPublishedAccessibilityChildren(of: node, to: &children, seen: &seen)
    return children
  }

  private static func shouldTraversePublishedAccessibilityChildren(of object: AnyObject) -> Bool {
    let bundle = Bundle(for: type(of: object))
    if bundle == .main {
      return true
    }
    if let bundleIdentifier = bundle.bundleIdentifier {
      return bundleIdentifier.hasPrefix("io.harnessmonitor") || bundleIdentifier.hasSuffix(".xctest")
    }
    return bundle.bundleURL.pathExtension == "xctest"
  }

  private static func appendPublishedAccessibilityChildren(
    of node: any NSAccessibilityProtocol,
    to children: inout [any NSAccessibilityProtocol],
    seen: inout Set<ObjectIdentifier>
  ) {
    if canBridgeNavigationOrderChildren(of: node as AnyObject) {
      WindowAccessibilityChildNodeCollector.append(
        contentsOf: node.accessibilityChildrenInNavigationOrder(),
        to: &children,
        seen: &seen
      )
    }
    WindowAccessibilityChildNodeCollector.append(
      contentsOf: node.accessibilityChildren(),
      to: &children,
      seen: &seen
    )
  }

  private static func canBridgeNavigationOrderChildren(of object: AnyObject) -> Bool {
    let bundle = Bundle(for: type(of: object))
    if bundle == .main {
      return true
    }
    if let bundleIdentifier = bundle.bundleIdentifier {
      return bundleIdentifier.hasPrefix("io.harnessmonitor") || bundleIdentifier.hasSuffix(".xctest")
    }
    return bundle.bundleURL.pathExtension == "xctest"
  }

  private static func registryElement(
    from node: any NSAccessibilityProtocol,
    windowID: Int
  ) -> RegistryElement? {
    guard let identifier = normalizedString(node.accessibilityIdentifier()) else {
      return nil
    }

    let frame = registryFrame(from: node)
    guard frame.isNull == false, frame.isInfinite == false, frame.isEmpty == false else {
      return nil
    }

    let roleDescription = String(describing: node.accessibilityRole()).lowercased()
    let label =
      normalizedString(node.accessibilityLabel())
      ?? normalizedString(node.accessibilityTitle())
      ?? normalizedToolTip(node)
    let hint = normalizedString(node.accessibilityHelp()) ?? normalizedToolTip(node)

    return RegistryElement(
      identifier: identifier,
      label: label,
      value: normalizedAccessibilityValue(node.accessibilityValue()),
      hint: hint,
      kind: kind(for: node, roleDescription: roleDescription),
      frame: RegistryRect(frame),
      windowID: windowID,
      enabled: node.isAccessibilityEnabled(),
      selected: false,
      focused: node.isAccessibilityFocused()
    )
  }

  private static func kind(
    for node: any NSAccessibilityProtocol,
    roleDescription: String
  ) -> RegistryElementKind {
    if (node as? NSSwitch) != nil
      || roleDescription.contains("checkbox")
      || roleDescription.contains("radio")
      || roleDescription.contains("switch")
      || roleDescription.contains("toggle")
    {
      return .toggle
    }
    if (node as? NSTextField) != nil
      || (node as? NSSearchField) != nil
      || roleDescription.contains("searchfield")
      || roleDescription.contains("textfield")
      || roleDescription.contains("text field")
    {
      return .textField
    }
    if roleDescription.contains("statictext")
      || roleDescription.contains("text area")
      || (node as? NSTextView) != nil
    {
      return .text
    }
    if (node as? NSButton) != nil || roleDescription.contains("button") {
      return .button
    }
    if (node as? NSTableView) != nil
      || (node as? NSOutlineView) != nil
      || roleDescription.contains("table")
      || roleDescription.contains("list")
    {
      return .list
    }
    if (node as? NSTableRowView) != nil || roleDescription.contains("row") {
      return .row
    }
    if (node as? NSTabView) != nil || roleDescription.contains("tab") {
      return .tab
    }
    if (node as? NSImageView) != nil || roleDescription.contains("image") {
      return .image
    }
    if roleDescription.contains("link") {
      return .link
    }
    if roleDescription.contains("menuitem") || roleDescription.contains("menu item") {
      return .menuItem
    }
    return .other
  }

  private static func normalizedToolTip(_ node: any NSAccessibilityProtocol) -> String? {
    guard let view = node as? NSView else {
      return nil
    }
    return normalizedString(view.toolTip)
  }

  private static func normalizedString(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizedAccessibilityValue(_ value: Any?) -> String? {
    switch value {
    case let string as String:
      return normalizedString(string)
    case let attributed as NSAttributedString:
      return normalizedString(attributed.string)
    case let number as NSNumber:
      return number.stringValue
    case let text as NSString:
      return normalizedString(text as String)
    case nil:
      return nil
    default:
      return normalizedString(String(describing: value))
    }
  }

  private static func registryFrame(from node: any NSAccessibilityProtocol) -> NSRect {
    guard let view = node as? NSView else {
      return node.accessibilityFrame()
    }
    guard let window = view.window else {
      return node.accessibilityFrame()
    }
    guard view.isHiddenOrHasHiddenAncestor == false else {
      return .null
    }
    var clippedBounds = view.bounds
    var ancestor = view.superview
    while let currentAncestor = ancestor {
      if let clipView = currentAncestor as? NSClipView {
        clippedBounds = clippedBounds.intersection(view.convert(clipView.bounds, from: clipView))
        if clippedBounds.isEmpty || clippedBounds.isNull {
          return .null
        }
      }
      ancestor = currentAncestor.superview
    }
    return window.convertToScreen(view.convert(clippedBounds, to: nil))
  }
}

actor WindowElementRegistryPayloadWorker {
  func replacementPayload(from elements: [RegistryElement]) -> WindowElementRegistryPayload {
    var harvested: [String: RegistryElement] = [:]
    harvested.reserveCapacity(elements.count)
    for element in elements {
      harvested[element.identifier] = element
    }
    let sorted = harvested.values.sorted { $0.identifier < $1.identifier }
    return WindowElementRegistryPayload(
      elements: sorted,
      signature: WindowElementRegistryPayloadSignature(elements: sorted)
    )
  }
}

struct WindowElementRegistryPayload: Sendable, Equatable {
  static let empty = WindowElementRegistryPayload(
    elements: [],
    signature: WindowElementRegistryPayloadSignature(count: 0, checksum: Self.emptyChecksum)
  )

  private static let emptyChecksum: UInt64 = 14_695_981_039_346_656_037

  let elements: [RegistryElement]
  let signature: WindowElementRegistryPayloadSignature
}

struct WindowElementRegistryPayloadSignature: Sendable, Equatable {
  let count: Int
  let checksum: UInt64

  init(count: Int, checksum: UInt64) {
    self.count = count
    self.checksum = checksum
  }

  init(elements: [RegistryElement]) {
    var hasher = WindowElementRegistryPayloadHasher()
    for element in elements {
      hasher.combine(element.identifier)
      hasher.combine(element.label)
      hasher.combine(element.value)
      hasher.combine(element.hint)
      hasher.combine(element.kind.rawValue)
      hasher.combine(element.actions.map(\.rawValue).joined(separator: "\u{1f}"))
      hasher.combine(element.frame.x)
      hasher.combine(element.frame.y)
      hasher.combine(element.frame.width)
      hasher.combine(element.frame.height)
      hasher.combine(element.windowID)
      hasher.combine(element.enabled)
      hasher.combine(element.selected)
      hasher.combine(element.focused)
    }
    self.count = elements.count
    checksum = hasher.value
  }
}

private struct WindowElementRegistryPayloadHasher {
  private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
  private static let prime: UInt64 = 1_099_511_628_211

  private(set) var value = Self.offsetBasis

  mutating func combine(_ value: String?) {
    guard let value else {
      combineByte(0)
      return
    }
    combineByte(1)
    for byte in value.utf8 {
      combineByte(byte)
    }
    combineByte(0xff)
  }

  mutating func combine(_ value: String) {
    combine(Optional(value))
  }

  mutating func combine(_ value: Int?) {
    guard let value else {
      combineByte(0)
      return
    }
    combineByte(1)
    combine(UInt64(bitPattern: Int64(value)))
  }

  mutating func combine(_ value: Bool) {
    combineByte(value ? 1 : 0)
  }

  mutating func combine(_ value: Double) {
    combine(value.bitPattern)
  }

  private mutating func combine(_ value: UInt64) {
    for shift in stride(from: 0, through: 56, by: 8) {
      combineByte(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
  }

  private mutating func combineByte(_ byte: UInt8) {
    value ^= UInt64(byte)
    value &*= Self.prime
  }
}
#endif
