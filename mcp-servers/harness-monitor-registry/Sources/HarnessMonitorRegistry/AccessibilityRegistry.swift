import Foundation

/// Thread-safe store for accessibility elements and windows exposed to the MCP server.
///
/// Views register themselves via `.trackAccessibility(...)` and the actor publishes the
/// results over the IPC socket.
public actor AccessibilityRegistry {
  private var elements: [String: RegistryElement] = [:]
  private var windows: [Int: RegistryWindow] = [:]
  private var windowElementIdentifiers: [Int: Set<String>] = [:]

  public init() {}

  public func registerElement(_ element: RegistryElement) {
    if let previousWindowID = elements[element.identifier]?.windowID {
      removeTrackedElementIdentifier(element.identifier, from: previousWindowID)
    }
    elements[element.identifier] = element
    if let windowID = element.windowID {
      var identifiers = windowElementIdentifiers[windowID] ?? []
      identifiers.insert(element.identifier)
      windowElementIdentifiers[windowID] = identifiers
    }
  }

  public func unregisterElement(identifier: String) {
    if let windowID = elements[identifier]?.windowID {
      removeTrackedElementIdentifier(identifier, from: windowID)
    }
    elements[identifier] = nil
  }

  public func registerWindow(_ window: RegistryWindow) {
    windows[window.id] = window
  }

  public func unregisterWindow(id: Int) {
    windows[id] = nil
  }

  public func replaceWindowElements(windowID: Int, elements replacement: [RegistryElement]) {
    unregisterElements(windowID: windowID)
    for element in replacement {
      var normalized = element
      normalized.windowID = windowID
      registerElement(normalized)
    }
  }

  public func unregisterElements(windowID: Int) {
    guard let identifiers = windowElementIdentifiers.removeValue(forKey: windowID) else {
      return
    }
    for identifier in identifiers {
      if elements[identifier]?.windowID == windowID {
        elements[identifier] = nil
      }
    }
  }

  public func element(identifier: String) -> RegistryElement? {
    elements[identifier]
  }

  public func allElements(windowID: Int? = nil, kind: RegistryElementKind? = nil) -> [RegistryElement] {
    elements.values
      .filter { element in
        if let windowID, element.windowID != windowID { return false }
        if let kind, element.kind != kind { return false }
        return true
      }
      .sorted { $0.identifier < $1.identifier }
  }

  public func allWindows() -> [RegistryWindow] {
    windows.values.sorted { $0.id < $1.id }
  }

  public func snapshot() -> RegistrySnapshot {
    RegistrySnapshot(
      elements: elements.values.sorted { $0.identifier < $1.identifier },
      windows: windows.values.sorted { $0.id < $1.id }
    )
  }

  public func reset() {
    elements.removeAll()
    windows.removeAll()
    windowElementIdentifiers.removeAll()
  }

  private func removeTrackedElementIdentifier(_ identifier: String, from windowID: Int) {
    guard var identifiers = windowElementIdentifiers[windowID] else {
      return
    }
    identifiers.remove(identifier)
    if identifiers.isEmpty {
      windowElementIdentifiers[windowID] = nil
    } else {
      windowElementIdentifiers[windowID] = identifiers
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
