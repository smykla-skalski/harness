import Foundation

/// Bridges raw `RegistryRequest` values into `RegistryResponse` values against a registry.
///
/// Kept transport-agnostic so it can be unit-tested without any sockets.
public struct RegistryRequestDispatcher: Sendable {
  public struct DispatchResult: Sendable {
    public let response: RegistryResponse
    public let onDelivered: (@Sendable () async -> Void)?
    public let closeConnectionAfterDelivery: Bool

    public init(
      response: RegistryResponse,
      onDelivered: (@Sendable () async -> Void)? = nil,
      closeConnectionAfterDelivery: Bool = false
    ) {
      self.response = response
      self.onDelivered = onDelivered
      self.closeConnectionAfterDelivery = closeConnectionAfterDelivery
    }
  }

  public struct ReplacementDisposition: Sendable {
    public let ack: RegistryAckResult
    public let onDelivered: (@Sendable () async -> Void)?
    public let closeConnectionAfterDelivery: Bool

    public init(
      ack: RegistryAckResult,
      onDelivered: (@Sendable () async -> Void)? = nil,
      closeConnectionAfterDelivery: Bool = false
    ) {
      self.ack = ack
      self.onDelivered = onDelivered
      self.closeConnectionAfterDelivery = closeConnectionAfterDelivery
    }
  }

  public let registry: AccessibilityRegistry
  public let pingInfo: @Sendable () -> PingResult
  public let replacementHandler: (@Sendable (RegistryReplacementNotice) async -> ReplacementDisposition)?

  public init(
    registry: AccessibilityRegistry,
    pingInfo: @escaping @Sendable () -> PingResult,
    replacementHandler: (@Sendable (RegistryReplacementNotice) async -> ReplacementDisposition)? = nil
  ) {
    self.registry = registry
    self.pingInfo = pingInfo
    self.replacementHandler = replacementHandler
  }

  public func dispatch(_ request: RegistryRequest) async -> DispatchResult {
    switch request.op {
    case .ping:
      return DispatchResult(response: .success(id: request.id, result: .ping(pingInfo())))

    case .listWindows:
      let windows = await registry.allWindows()
      return DispatchResult(
        response: .success(id: request.id, result: .listWindows(ListWindowsResult(windows: windows)))
      )

    case .listElements:
      let elements = await registry.allElements(windowID: request.windowID, kind: request.kind)
      return DispatchResult(
        response: .success(
          id: request.id,
          result: .listElements(ListElementsResult(elements: elements))
        )
      )

    case .getElement:
      guard let identifier = request.identifier, identifier.isEmpty == false else {
        return DispatchResult(
          response: .failure(
            id: request.id,
            error: RegistryErrorPayload(
              code: "invalid-argument",
              message: "getElement requires a non-empty identifier"
            )
          )
        )
      }
      guard let element = await registry.element(identifier: identifier) else {
        return DispatchResult(
          response: .failure(
            id: request.id,
            error: RegistryErrorPayload(
              code: "not-found",
              message: "no element registered with identifier \(identifier)"
            )
          )
        )
      }
      return DispatchResult(
        response: .success(id: request.id, result: .getElement(GetElementResult(element: element)))
      )

    case .syncClientSnapshot:
      guard let clientSnapshot = request.clientSnapshot else {
        return DispatchResult(
          response: .failure(
            id: request.id,
            error: RegistryErrorPayload(
              code: "invalid-argument",
              message: "syncClientSnapshot requires a clientSnapshot payload"
            )
          )
        )
      }
      let ack = await registry.upsertClientSnapshot(clientSnapshot)
      return DispatchResult(response: .success(id: request.id, result: .ack(ack)))

    case .clearClientSnapshot:
      let clearRequest =
        request.clientClear ?? request.clientID.map { RegistryClientClearRequest(clientID: $0, generation: 0) }
      guard let clearRequest else {
        return DispatchResult(
          response: .failure(
            id: request.id,
            error: RegistryErrorPayload(
              code: "invalid-argument",
              message: "clearClientSnapshot requires a clientClear payload"
            )
          )
        )
      }
      let ack = await registry.removeClientSnapshot(clearRequest)
      return DispatchResult(response: .success(id: request.id, result: .ack(ack)))

    case .replacementNotice:
      guard let replacementNotice = request.replacementNotice else {
        return DispatchResult(
          response: .failure(
            id: request.id,
            error: RegistryErrorPayload(
              code: "invalid-argument",
              message: "replacementNotice requires a replacementNotice payload"
            )
          )
        )
      }
      let disposition =
        if let replacementHandler {
          await replacementHandler(replacementNotice)
        } else {
          ReplacementDisposition(
            ack: RegistryAckResult(
              applied: false,
              message: "registry host does not support replacement notices"
            )
          )
        }
      return DispatchResult(
        response: .success(id: request.id, result: .ack(disposition.ack)),
        onDelivered: disposition.onDelivered,
        closeConnectionAfterDelivery: disposition.closeConnectionAfterDelivery
      )
    }
  }
}
