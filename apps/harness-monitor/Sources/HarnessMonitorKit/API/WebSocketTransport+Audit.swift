import Foundation

extension WebSocketTransport {
  public func auditEvents(
    request: HarnessMonitorAuditEventsRequest
  ) async throws -> HarnessMonitorAuditEventsResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .auditEvents, params: params)
    return try decode(value)
  }
}
