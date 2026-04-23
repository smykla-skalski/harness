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
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.audit_append_failed error=\(String(describing: error))"
      )
    }
  }
}

struct NoOpSupervisorAuditWriter: SupervisorAuditWriter {
  func append(_ record: SupervisorAuditRecord) async {
    _ = record
  }
}

extension HarnessMonitorStore {
  func seedSupervisorDecisionsIfNeeded(_ decisionStore: DecisionStore) async throws {
    let environmentKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
    guard
      let rawValue = ProcessInfo.processInfo.environment[environmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty
    else {
      return
    }

    let payload = try JSONDecoder().decode(
      SupervisorDecisionSeedPayload.self,
      from: Data(rawValue.utf8)
    )
    for seededDecision in payload.decisions {
      guard let severity = DecisionSeverity(rawValue: seededDecision.severity) else {
        continue
      }
      try await decisionStore.insert(
        DecisionDraft(
          id: seededDecision.id,
          severity: severity,
          ruleID: seededDecision.ruleID,
          sessionID: seededDecision.sessionID,
          agentID: seededDecision.agentID,
          taskID: seededDecision.taskID,
          summary: seededDecision.summary,
          contextJSON: seededDecision.contextJSON ?? "{}",
          suggestedActionsJSON: seededDecision.suggestedActionsJSON ?? "[]"
        )
      )
    }
  }

  static func loadPolicyOverrides(
    from modelContext: ModelContext?
  ) -> [PolicyConfigOverride] {
    guard let modelContext else {
      return []
    }

    do {
      let descriptor = FetchDescriptor<PolicyConfigRow>(
        sortBy: [SortDescriptor(\.ruleID)]
      )
      return try modelContext.fetch(descriptor).map { row in
        PolicyConfigOverride(
          ruleID: row.ruleID,
          enabled: row.enabled,
          defaultBehavior: RuleDefaultBehavior(rawValue: row.defaultBehaviorRaw) ?? .cautious,
          parameters: decodeParameters(from: row.parametersJSON)
        )
      }
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.policy_config_load_failed error=\(String(describing: error))"
      )
      return []
    }
  }

  static func decodeParameters(from json: String) -> [String: String] {
    guard
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }

    var parameters: [String: String] = [:]
    for (key, value) in object {
      switch value {
      case let string as String:
        parameters[key] = string
      case let number as NSNumber:
        parameters[key] = number.stringValue
      default:
        continue
      }
    }
    return parameters
  }
}
