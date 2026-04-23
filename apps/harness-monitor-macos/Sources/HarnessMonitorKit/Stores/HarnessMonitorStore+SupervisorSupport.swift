import Foundation
import SwiftData

struct SupervisorDecisionSeedPayload: Decodable {
  let decisions: [DecisionLine]

  struct DecisionLine: Decodable {
    let id: String
    let severity: String
    let ruleID: String
    let sessionID: String?
    let agentID: String?
    let taskID: String?
    let summary: String
    let contextJSON: String?
    let suggestedActionsJSON: String?
  }
}

actor SwiftDataSupervisorAuditWriter: SupervisorAuditWriter {
  private let container: ModelContainer

  init(container: ModelContainer) {
    self.container = container
  }

  func append(_ record: SupervisorAuditRecord) async {
    do {
      let context = ModelContext(container)
      context.autosaveEnabled = false
      context.insert(
        SupervisorEvent(
          id: record.id,
          tickID: record.tickID,
          kind: record.kind,
          ruleID: record.ruleID,
          severity: record.severity,
          payloadJSON: record.payloadJSON
        )
      )
      try context.save()
    } catch {
      HarnessMonitorLogger.supervisor.warning(
        "supervisor.audit_append_failed error=\(String(describing: error), privacy: .public)"
      )
    }
  }
}

struct NoOpSupervisorAuditWriter: SupervisorAuditWriter {
  func append(_ record: SupervisorAuditRecord) async {
    _ = record
  }
}
