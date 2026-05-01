import Foundation

/// Thread-safe store for accessibility elements and windows exposed to the MCP server.
///
/// Views register themselves via `.trackAccessibility(...)` and the actor publishes the
/// results over the IPC socket.
public actor AccessibilityRegistry {
  private struct StoredWindow {
    let window: RegistryWindow
    let ownership: WindowOwnership
  }

  private enum WindowOwnership: Equatable {
    case manual
    case tracked(UUID)
  }

  private struct StoredElement {
    let element: RegistryElement
    let ownership: ElementOwnership
  }

  private enum ElementOwnership: Equatable {
    case manual
    case trackedElement(ownerID: UUID)
    case trackedWindowSnapshot(windowID: Int, ownerID: UUID)
  }

  private var elements: [String: StoredElement] = [:]
  private var windows: [Int: StoredWindow] = [:]
  private var trackedWindowElements: [Int: TrackedWindowElements] = [:]
  // TrackAccessibility publishes asynchronously, so identifier ownership must be
  // claimed separately from element writes to ignore stale register/unregister tasks.
  private var trackedElementOwners: [String: UUID] = [:]

  private struct TrackedWindowElements {
    let ownerID: UUID
    var identifiers: Set<String>
  }

  public init() {}

  public func registerElement(_ element: RegistryElement) {
    removeTrackedSnapshotReference(for: element.identifier)
    trackedElementOwners[element.identifier] = nil
    elements[element.identifier] = StoredElement(element: element, ownership: .manual)
  }

  public func unregisterElement(identifier: String) {
    removeTrackedSnapshotReference(for: identifier)
    trackedElementOwners[identifier] = nil
    elements[identifier] = nil
  }

  public func claimTrackedElement(identifier: String, ownerID: UUID) {
    trackedElementOwners[identifier] = ownerID
    guard case .trackedWindowSnapshot = elements[identifier]?.ownership else {
      return
    }
    removeTrackedSnapshotReference(for: identifier)
    elements[identifier] = nil
  }

  public func registerTrackedElement(_ element: RegistryElement, ownerID: UUID) {
    guard trackedElementOwners[element.identifier] == ownerID else {
      return
    }
    removeTrackedSnapshotReference(for: element.identifier)
    elements[element.identifier] = StoredElement(
      element: element,
      ownership: .trackedElement(ownerID: ownerID)
    )
  }

  public func clearTrackedElement(identifier: String, ownerID: UUID) {
    guard trackedElementOwners[identifier] == ownerID else {
      return
    }
    guard
      case .trackedElement(let storedOwnerID) = elements[identifier]?.ownership,
      storedOwnerID == ownerID
    else {
      return
    }
    elements[identifier] = nil
  }

  public func unregisterTrackedElement(identifier: String, ownerID: UUID) {
    guard trackedElementOwners[identifier] == ownerID else {
      return
    }
    trackedElementOwners[identifier] = nil
    clearTrackedElementStorage(identifier: identifier, ownerID: ownerID)
  }

  public func registerWindow(_ window: RegistryWindow) {
    windows[window.id] = StoredWindow(window: window, ownership: .manual)
  }

  public func unregisterWindow(id: Int) {
    windows[id] = nil
  }

  public func registerTrackedWindow(_ window: RegistryWindow, ownerID: UUID) {
    guard windows[window.id]?.ownership != .manual else {
      return
    }
    windows[window.id] = StoredWindow(window: window, ownership: .tracked(ownerID))
  }

  public func unregisterTrackedWindow(id: Int, ownerID: UUID) {
    guard windows[id]?.ownership == .tracked(ownerID) else {
      return
    }
    windows[id] = nil
  }

  public func replaceWindowElements(windowID: Int, elements replacement: [RegistryElement]) {
    clearAllWindowElements(windowID: windowID)
    for element in replacement {
      var normalized = element
      normalized.windowID = windowID
      registerElement(normalized)
    }
  }

  public func unregisterElements(windowID: Int) {
    clearAllWindowElements(windowID: windowID)
  }

  public func replaceTrackedWindowElements(
    windowID: Int,
    elements replacement: [RegistryElement],
    ownerID: UUID
  ) {
    clearTrackedWindowElements(windowID: windowID)

    var identifiers: Set<String> = []
    for element in replacement {
      var normalized = element
      normalized.windowID = windowID
      // Manual MCP-tracked elements are the explicit operator seam. Window
      // snapshots can fill gaps, but they must not clobber those registrations.
      if trackedElementOwners[normalized.identifier] != nil
        || hasExplicitManualOwnership(elements[normalized.identifier]?.ownership)
      {
        continue
      }
      removeTrackedSnapshotReference(for: normalized.identifier)
      elements[normalized.identifier] = StoredElement(
        element: normalized,
        ownership: .trackedWindowSnapshot(windowID: windowID, ownerID: ownerID)
      )
      identifiers.insert(normalized.identifier)
    }

    if identifiers.isEmpty {
      trackedWindowElements[windowID] = nil
    } else {
      trackedWindowElements[windowID] = TrackedWindowElements(
        ownerID: ownerID,
        identifiers: identifiers
      )
    }
  }

  public func unregisterTrackedWindowElements(windowID: Int, ownerID: UUID) {
    guard trackedWindowElements[windowID]?.ownerID == ownerID else {
      return
    }
    clearTrackedWindowElements(windowID: windowID)
  }

  public func element(identifier: String) -> RegistryElement? {
    elements[identifier]?.element
  }

  public func allElements(windowID: Int? = nil, kind: RegistryElementKind? = nil) -> [RegistryElement] {
    elements.values
      .map(\.element)
      .filter { element in
        if let windowID, element.windowID != windowID { return false }
        if let kind, element.kind != kind { return false }
        return true
      }
      .sorted { $0.identifier < $1.identifier }
  }

  public func allWindows() -> [RegistryWindow] {
    windows.values
      .map(\.window)
      .sorted { $0.id < $1.id }
  }

  public func snapshot() -> RegistrySnapshot {
    RegistrySnapshot(
      elements: elements.values.map(\.element).sorted { $0.identifier < $1.identifier },
      windows: windows.values.map(\.window).sorted { $0.id < $1.id }
    )
  }

  public func reset() {
    elements.removeAll()
    windows.removeAll()
    trackedWindowElements.removeAll()
    trackedElementOwners.removeAll()
  }

  private func clearTrackedWindowElements(windowID: Int) {
    guard let tracked = trackedWindowElements.removeValue(forKey: windowID) else {
      return
    }
    for identifier in tracked.identifiers {
      guard
        case .trackedWindowSnapshot(let storedWindowID, let storedOwnerID) = elements[identifier]?
          .ownership,
        storedWindowID == windowID,
        storedOwnerID == tracked.ownerID
      else {
        continue
      }

        elements[identifier] = nil
    }
  }

  private func clearAllWindowElements(windowID: Int) {
    let identifiersToRemove = elements.compactMap { identifier, stored in
      stored.element.windowID == windowID ? identifier : nil
    }

    for identifier in identifiersToRemove {
      removeTrackedSnapshotReference(for: identifier)
      elements[identifier] = nil
    }

    trackedWindowElements[windowID] = nil
  }

  private func clearTrackedElementStorage(identifier: String, ownerID: UUID) {
    guard
      case .trackedElement(let storedOwnerID) = elements[identifier]?.ownership,
      storedOwnerID == ownerID
    else {
      return
    }
    elements[identifier] = nil
  }

  private func hasExplicitManualOwnership(_ ownership: ElementOwnership?) -> Bool {
    guard let ownership else {
      return false
    }
    switch ownership {
    case .manual, .trackedElement:
      return true
    case .trackedWindowSnapshot:
      return false
    }
  }

  private func removeTrackedSnapshotReference(for identifier: String) {
    guard
      case .trackedWindowSnapshot(let windowID, let ownerID) = elements[identifier]?.ownership,
      var tracked = trackedWindowElements[windowID]
    else {
      return
    }

    tracked.identifiers.subtract([identifier])
    if tracked.identifiers.isEmpty {
      trackedWindowElements[windowID] = nil
    } else {
      trackedWindowElements[windowID] = TrackedWindowElements(
        ownerID: ownerID,
        identifiers: tracked.identifiers
      )
    }
  }
}

public struct RegistrySnapshot: Sendable, Equatable {
  public let elements: [RegistryElement]
  public let windows: [RegistryWindow]

  public init(elements: [RegistryElement], windows: [RegistryWindow]) {
    self.elements = elements
    self.windows = windows
  }
}
