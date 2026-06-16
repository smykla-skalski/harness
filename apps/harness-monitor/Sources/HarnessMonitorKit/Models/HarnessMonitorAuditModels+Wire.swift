import Foundation

// Bridges the generated daemon wire types in
// Models/Generated/AuditWireTypes.generated.swift to the rich app models in
// HarnessMonitorAuditModels.swift / HarnessMonitorAuditQueryModels.swift. The
// wire types own the snake_case decode (explicit CodingKeys, decoded with
// PolicyWireCoding.decoder so no key strategy can drop a field); the rich models
// keep their Date timestamps, idiomatic acronym names, and local-persistence
// Codable. Map at the transport boundary instead of relying on the daemon's
// snake keys lining up with the rich model's camelCase persistence keys.

extension HarnessMonitorAuditEvent {
  init(wire: HarnessMonitorAuditEventWire) {
    self.init(
      id: wire.id,
      // The daemon always emits ISO-8601; distantPast guards a single malformed
      // timestamp without failing the whole page of events.
      recordedAt: Self.parseDate(wire.recordedAt) ?? .distantPast,
      source: wire.source,
      category: wire.category,
      kind: wire.kind,
      severity: wire.severity,
      outcome: wire.outcome,
      title: wire.title,
      summary: wire.summary,
      subject: wire.subject,
      actor: wire.actor,
      correlationID: wire.correlationId,
      actionKey: wire.actionKey,
      payloadJSON: wire.payloadJson,
      legacyMessage: wire.legacyMessage,
      relatedURLs: wire.relatedUrls
    )
  }
}

extension HarnessMonitorAuditEventsResponse {
  init(wire: HarnessMonitorAuditEventsResponseWire) {
    self.init(
      events: wire.events.map(HarnessMonitorAuditEvent.init(wire:)),
      nextCursor: wire.nextCursor,
      hasOlder: wire.hasOlder
    )
  }
}

extension HarnessMonitorAuditDateRangeWire {
  init(_ range: HarnessMonitorAuditDateRange) {
    self.init(start: range.start, end: range.end)
  }
}

extension HarnessMonitorAuditEventsRequestWire {
  init(_ request: HarnessMonitorAuditEventsRequest) {
    self.init(
      limit: request.limit.map { UInt32(clamping: $0) },
      before: request.before,
      dateRange: request.dateRange.map(HarnessMonitorAuditDateRangeWire.init),
      sources: request.sources,
      categories: request.categories,
      severities: request.severities,
      outcomes: request.outcomes,
      actionKeys: request.actionKeys,
      subject: request.subject,
      searchText: request.searchText
    )
  }
}
