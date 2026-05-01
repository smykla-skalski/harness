#if canImport(AppKit)
import AppKit

@MainActor
final class WindowElementRegistrySyncController {
  private enum PendingAction {
    case replace(window: NSWindow, generation: UInt64, ownerID: UUID)
    case clear(Int, ownerID: UUID)
  }

  private let registry: AccessibilityRegistry
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

  func sync(window: NSWindow, generation: UInt64) {
    guard generation == trackingGeneration, trackedWindowID == window.windowNumber else {
      return
    }
    enqueue(.replace(window: window, generation: generation, ownerID: trackingOwnerID))
  }

  func stopTracking() {
    guard let windowID = trackedWindowID else { return }
    let ownerID = trackingOwnerID
    trackingGeneration &+= 1
    trackedWindowID = nil
    trackingOwnerID = UUID()
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
    case .replace(let window, let generation, let ownerID):
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
      let elements = WindowAccessibilityElementSnapshotter.elements(in: window)
      onReplacementApplied()
      await registry.replaceTrackedWindowElements(
        windowID: window.windowNumber,
        elements: elements,
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
  static func collect<S: Sequence>(from values: S) -> [any NSAccessibilityProtocol] {
    var children: [any NSAccessibilityProtocol] = []
    var seen: Set<ObjectIdentifier> = []
    append(contentsOf: values, to: &children, seen: &seen)
    return children
  }

  static func append<S: Sequence>(
    contentsOf values: S?,
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
}

@MainActor
private enum WindowAccessibilityElementSnapshotter {
  private static let maximumVisitedNodes = 700

  static func elements(in window: NSWindow) -> [RegistryElement] {
    var queue: [any NSAccessibilityProtocol] = []
    if let contentView = window.contentView {
      queue.append(contentView)
    } else {
      queue.append(window)
    }
    var index = 0
    var visited: Set<ObjectIdentifier> = []
    var harvested: [String: RegistryElement] = [:]

    while index < queue.count, visited.count < maximumVisitedNodes {
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
      harvested[element.identifier] = element
    }

    return harvested.values.sorted { $0.identifier < $1.identifier }
  }

  private static func childNodes(
    of node: any NSAccessibilityProtocol
  ) -> [any NSAccessibilityProtocol] {
    var children: [any NSAccessibilityProtocol] = []
    var seen: Set<ObjectIdentifier> = []

    if let view = node as? NSView {
      if view.subviews.isEmpty {
        WindowAccessibilityChildNodeCollector.append(
          contentsOf: view.accessibilityChildrenInNavigationOrder(),
          to: &children,
          seen: &seen
        )
        WindowAccessibilityChildNodeCollector.append(
          contentsOf: view.accessibilityChildren(),
          to: &children,
          seen: &seen
        )
      }
      WindowAccessibilityChildNodeCollector.append(
        contentsOf: view.subviews,
        to: &children,
        seen: &seen
      )
      return children
    }

    if let window = node as? NSWindow, let contentView = window.contentView {
      children.append(contentView)
      return children
    }

    WindowAccessibilityChildNodeCollector.append(
      contentsOf: node.accessibilityChildrenInNavigationOrder(),
      to: &children,
      seen: &seen
    )
    WindowAccessibilityChildNodeCollector.append(
      contentsOf: node.accessibilityChildren(),
      to: &children,
      seen: &seen
    )

    return children
  }

  private static func registryElement(
    from node: any NSAccessibilityProtocol,
    windowID: Int
  ) -> RegistryElement? {
    guard let identifier = normalizedString(node.accessibilityIdentifier()) else {
      return nil
    }

    let frame = node.accessibilityFrame()
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
}
#endif
