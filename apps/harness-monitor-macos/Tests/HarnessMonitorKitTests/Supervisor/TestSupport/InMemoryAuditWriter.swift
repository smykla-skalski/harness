import Foundation

@testable import HarnessMonitorKit

/// In-memory audit writer used by Monitor supervisor tests that need to assert
/// `actionDispatched` / `actionExecuted` ordering without a SwiftData round-trip. Phase 1 ships
/// the scaffold only; Phase 2 worker 4 fills the protocol conformance in the same commit as the
/// `PolicyExecutor` body so the audit surface lands together.
final class InMemoryAuditWriter: @unchecked Sendable {
  struct RecordedEvent: Equatable, Sendable {
    let kind: String
    let ruleID: String?
    let payloadJSON: String
  }

  private(set) var events: [RecordedEvent] = []
}
