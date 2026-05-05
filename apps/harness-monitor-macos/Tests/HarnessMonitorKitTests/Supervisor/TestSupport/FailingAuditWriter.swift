@testable import HarnessMonitorKit

struct FailingAuditWriter: SupervisorAuditWriter {
  func append(_ record: SupervisorAuditRecord) async throws {
    _ = record
    throw HarnessMonitorAPIError.server(code: 500, message: "audit failed")
  }
}
