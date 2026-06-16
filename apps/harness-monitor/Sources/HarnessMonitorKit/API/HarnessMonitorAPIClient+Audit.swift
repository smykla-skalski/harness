import Foundation

extension HarnessMonitorAPIClient {
  public func auditEvents(
    request: HarnessMonitorAuditEventsRequest
  ) async throws -> HarnessMonitorAuditEventsResponse {
    let wire: HarnessMonitorAuditEventsResponseWire = try await get(
      "/v1/audit/events",
      queryItems: auditEventQueryItems(for: request),
      decoder: PolicyWireCoding.decoder
    )
    return HarnessMonitorAuditEventsResponse(wire: wire)
  }

  private func auditEventQueryItems(
    for request: HarnessMonitorAuditEventsRequest
  ) -> [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let limit = request.limit {
      items.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    if let before = request.before {
      items.append(URLQueryItem(name: "before", value: before))
    }
    if let start = request.dateRange?.start {
      items.append(URLQueryItem(name: "date_range_start", value: start))
    }
    if let end = request.dateRange?.end {
      items.append(URLQueryItem(name: "date_range_end", value: end))
    }
    appendCSV(request.sources, name: "sources", to: &items)
    appendCSV(request.categories, name: "categories", to: &items)
    appendCSV(request.severities, name: "severities", to: &items)
    appendCSV(request.outcomes, name: "outcomes", to: &items)
    appendCSV(request.actionKeys, name: "action_keys", to: &items)
    if let subject = request.subject {
      items.append(URLQueryItem(name: "subject", value: subject))
    }
    if let searchText = request.searchText {
      items.append(URLQueryItem(name: "search_text", value: searchText))
    }
    return items
  }

  private func appendCSV(
    _ values: [String],
    name: String,
    to items: inout [URLQueryItem]
  ) {
    let value =
      values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: ",")
    guard !value.isEmpty else { return }
    items.append(URLQueryItem(name: name, value: value))
  }
}
