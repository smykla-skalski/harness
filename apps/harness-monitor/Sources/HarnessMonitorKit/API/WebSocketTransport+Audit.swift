import Foundation

extension WebSocketTransport {
  public func auditEvents(
    request: HarnessMonitorAuditEventsRequest
  ) async throws -> HarnessMonitorAuditEventsResponse {
    let params = try encodeParams(HarnessMonitorAuditEventsRequestWire(request), extra: [:])
    let value = try await rpc(method: .auditEvents, params: params)
    let wire: HarnessMonitorAuditEventsResponseWire = try decodePolicyWire(value)
    return HarnessMonitorAuditEventsResponse(wire: wire)
  }
}
