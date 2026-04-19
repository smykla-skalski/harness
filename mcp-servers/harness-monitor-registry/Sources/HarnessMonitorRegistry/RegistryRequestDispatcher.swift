import Foundation

/// Bridges raw `RegistryRequest` values into `RegistryResponse` values against a registry.
///
/// Kept transport-agnostic so it can be unit-tested without any sockets.
public struct RegistryRequestDispatcher: Sendable {
  public let registry: AccessibilityRegistry
  public let pingInfo: @Sendable () -> PingResult

  public init(registry: AccessibilityRegistry, pingInfo: @escaping @Sendable () -> PingResult) {
    self.registry = registry
    self.pingInfo = pingInfo
  }

  public func dispatch(_ request: RegistryRequest) async -> RegistryResponse {
    switch request.op {
    case .ping:
      return .success(id: request.id, result: .ping(pingInfo()))

    case .listWindows:
      let windows = await registry.allWindows()
      return .success(id: request.id, result: .listWindows(ListWindowsResult(windows: windows)))

    case .listElements:
      let elements = await registry.allElements(windowID: request.windowID, kind: request.kind)
      return .success(
        id: request.id,
        result: .listElements(ListElementsResult(elements: elements))
      )

    case .getElement:
      guard let identifier = request.identifier, identifier.isEmpty == false else {
        return .failure(
          id: request.id,
          error: RegistryErrorPayload(
            code: "invalid-argument",
            message: "getElement requires a non-empty identifier"
          )
        )
      }
      guard let element = await registry.element(identifier: identifier) else {
        return .failure(
          id: request.id,
          error: RegistryErrorPayload(
            code: "not-found",
            message: "no element registered with identifier \(identifier)"
          )
        )
      }
      return .success(id: request.id, result: .getElement(GetElementResult(element: element)))
    }
  }
}

/// Splits a sliding byte buffer into complete NDJSON lines.
///
/// Kept public so `#if canImport(Network)` listener code and unit tests share one implementation.
public struct NDJSONLineBuffer {
  private var buffer: Data = Data()

  public init() {}

  public mutating func append(_ data: Data) -> [Data] {
    buffer.append(data)
    var lines: [Data] = []
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      let range = buffer.startIndex..<newlineIndex
      let line = buffer.subdata(in: range)
      buffer.removeSubrange(buffer.startIndex...newlineIndex)
      if line.isEmpty == false {
        lines.append(line)
      }
    }
    return lines
  }

  public var pendingByteCount: Int { buffer.count }
}
