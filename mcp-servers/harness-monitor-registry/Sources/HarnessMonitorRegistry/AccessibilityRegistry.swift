import Foundation

/// Thread-safe store for accessibility elements and windows exposed to the MCP server.
///
/// Views register themselves via `.trackAccessibility(...)` and the actor publishes the
/// results over the IPC socket.
public actor AccessibilityRegistry {
  private var elements: [String: RegistryElement] = [:]
  private var windows: [Int: RegistryWindow] = [:]

  public init() {}

  public func registerElement(_ element: RegistryElement) {
    elements[element.identifier] = element
  }

  public func unregisterElement(identifier: String) {
    elements[identifier] = nil
  }

  public func registerWindow(_ window: RegistryWindow) {
    windows[window.id] = window
  }

  public func unregisterWindow(id: Int) {
    windows[id] = nil
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
