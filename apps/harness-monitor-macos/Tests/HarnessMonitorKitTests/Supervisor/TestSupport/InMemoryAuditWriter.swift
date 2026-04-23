import Foundation

@testable import HarnessMonitorKit

/// In-memory audit writer used by Monitor supervisor tests that need to assert
/// `actionDispatched` / `actionExecuted` / `actionFailed` ordering without a
/// SwiftData round-trip. Each `append` records a `RecordedEvent` in the order
/// the `PolicyExecutor` wrote it, preserving sequence for audit-trail tests.
actor InMemoryAuditWriter: SupervisorAuditWriter {
  struct RecordedEvent: Equatable, Sendable {
    let id: String
    let tickID: String
    let kind: String
    let ruleID: String?
    let severity: DecisionSeverity?
    let payloadJSON: String
    let createdAt: Date
  }

  private var events: [RecordedEvent] = []

  func append(_ record: SupervisorAuditRecord) async {
    events.append(
      RecordedEvent(
        id: record.id,
        tickID: record.tickID,
        kind: record.kind,
        ruleID: record.ruleID,
        severity: record.severity,
        payloadJSON: record.payloadJSON,
        createdAt: record.createdAt
      )
    )
  }

  func snapshot() -> [RecordedEvent] { events }
}
