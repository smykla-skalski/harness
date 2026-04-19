import Foundation

extension HarnessMonitorAPIClient {
  func timelineWindowQueryItems(for request: TimelineWindowRequest) -> [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let scope = request.scope?.rawValue {
      items.append(URLQueryItem(name: "scope", value: scope))
    }
    if let limit = request.limit {
      items.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    if let knownRevision = request.knownRevision {
      items.append(URLQueryItem(name: "known_revision", value: String(knownRevision)))
    }
    if let before = request.before {
      items.append(URLQueryItem(name: "before_recorded_at", value: before.recordedAt))
      items.append(URLQueryItem(name: "before_entry_id", value: before.entryId))
    }
    if let after = request.after {
      items.append(URLQueryItem(name: "after_recorded_at", value: after.recordedAt))
      items.append(URLQueryItem(name: "after_entry_id", value: after.entryId))
    }
    return items
  }
}
