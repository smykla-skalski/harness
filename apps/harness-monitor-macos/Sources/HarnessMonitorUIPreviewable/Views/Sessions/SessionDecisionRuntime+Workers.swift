import Foundation
import HarnessMonitorKit

let sessionDecisionInspectorRowWorker = SessionDecisionInspectorRowWorker()
let sessionDecisionAuditWorker = SessionDecisionAuditWorker()

actor SessionDecisionInspectorRowWorker {
  func compute(input: SessionDecisionInspectorRowInput) -> SessionDecisionInspectorRows {
    var contextRows: [SessionDecisionContextRow] = []
    if let sessionID = input.sessionID {
      contextRows.append(.init(id: "session", value: "Session: \(sessionID)"))
    }
    contextRows.append(contentsOf: Self.flattenedContextRows(from: input.contextJSON))

    var historyRows: [SessionDecisionHistoryRow] = [
      .init(id: "created", title: "Created", value: input.createdAt.formatted()),
      .init(id: "status", title: "Status", value: input.statusRaw),
    ]
    if let snoozedUntil = input.snoozedUntil {
      historyRows.append(
        .init(id: "snoozed", title: "Snoozed Until", value: snoozedUntil.formatted())
      )
    }
    if let resolutionJSON = input.resolutionJSON, !resolutionJSON.isEmpty {
      historyRows.append(.init(id: "resolution", title: "Resolution", value: resolutionJSON))
    }

    return SessionDecisionInspectorRows(
      key: input.key,
      decisionID: input.decisionID,
      contextRows: contextRows,
      historyRows: historyRows,
      isLoading: false
    )
  }

  func waitForIdle() async {}

  private static func flattenedContextRows(from json: String) -> [SessionDecisionContextRow] {
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return []
    }
    return object.keys.sorted()
      .filter { !isDetailOwnedContextKey($0) }
      .prefix(12)
      .map { key in
        SessionDecisionContextRow(id: "context.\(key)", value: "\(key): \(object[key] ?? "")")
      }
  }

  private static func isDetailOwnedContextKey(_ key: String) -> Bool {
    detailOwnedContextKeys.contains(normalizedContextKey(key))
  }

  private static func normalizedContextKey(_ key: String) -> String {
    key.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  private static let detailOwnedContextKeys: Set<String> = [
    "agent",
    "agentid",
    "decision",
    "decisionid",
    "rule",
    "ruleid",
    "session",
    "sessionid",
    "severity",
    "severityraw",
    "status",
    "statusraw",
    "suggestedactions",
    "suggestedactionsjson",
    "summary",
    "task",
    "taskid",
  ]
}

actor SessionDecisionAuditWorker {
  private let decoder = JSONDecoder()

  func scopedOutput(
    events: [SupervisorEventSnapshot],
    input: SessionDecisionAuditInput
  ) -> SessionDecisionAuditOutput {
    let scopedEvents = events.filter { event in
      SessionDecisionAuditPayloadScope(payloadJSON: event.payloadJSON)
        .matchesExplicitSessionScope(
          sessionID: input.sessionID,
          decisionIDs: input.decisionIDs,
          agentIDs: input.agentIDs,
          taskIDs: input.taskIDs
        )
    }
    return SessionDecisionAuditOutput(
      events: scopedEvents,
      payloadPresentations: Dictionary(
        uniqueKeysWithValues: scopedEvents.map {
          (
            $0.id,
            DecisionAuditTrailPayloadPresentation(
              payloadJSON: $0.payloadJSON,
              decoder: decoder
            )
          )
        }
      )
    )
  }

  func waitForIdle() async {}
}

private struct SessionDecisionAuditInput: Equatable, Sendable {
  let sessionID: String
  let decisionIDs: Set<String>
  let agentIDs: Set<String>
  let taskIDs: Set<String>

  init(sessionID: String, decisionItems: [DecisionPresentationSnapshot]) {
    self.sessionID = sessionID
    decisionIDs = Set(decisionItems.map(\.id))
    agentIDs = Set(decisionItems.compactMap(\.agentID))
    taskIDs = Set(decisionItems.compactMap(\.taskID))
  }

  @MainActor
  init(sessionID: String, decisions: [Decision]) {
    self.init(
      sessionID: sessionID,
      decisionItems: decisions.map(DecisionPresentationSnapshot.init)
    )
  }
}

private struct SessionDecisionAuditOutput: Equatable, Sendable {
  static let empty = Self(events: [], payloadPresentations: [:])

  let events: [SupervisorEventSnapshot]
  let payloadPresentations: [String: DecisionAuditTrailPayloadPresentation]
}

private struct SessionDecisionAuditPayloadScope {
  let sessionID: String?
  let agentID: String?
  let taskID: String?
  let decisionID: String?

  init(payloadJSON: String) {
    guard let data = payloadJSON.data(using: .utf8) else {
      sessionID = nil
      agentID = nil
      taskID = nil
      decisionID = nil
      return
    }
    let object = try? JSONSerialization.jsonObject(with: data)
    sessionID = Self.firstString(
      forKeys: ["sessionID", "sessionId", "session_id"],
      in: object
    )
    agentID = Self.firstString(
      forKeys: ["agentID", "agentId", "agent_id"],
      in: object
    )
    taskID = Self.firstString(
      forKeys: ["taskID", "taskId", "task_id"],
      in: object
    )
    decisionID = Self.firstString(
      forKeys: ["decisionID", "decisionId", "decision_id"],
      in: object
    )
  }

  func matchesExplicitSessionScope(
    sessionID expectedSessionID: String,
    decisionIDs: Set<String>,
    agentIDs: Set<String>,
    taskIDs: Set<String>
  ) -> Bool {
    let sessionMatches = self.sessionID.map { $0 == expectedSessionID }
    if sessionMatches == false {
      return false
    }

    let decisionMatches = decisionID.map { decisionIDs.contains($0) }
    if decisionMatches == false {
      return false
    }

    let taskMatches = taskID.map { taskIDs.contains($0) }
    if taskMatches == false {
      return false
    }

    let agentMatches = agentID.map { agentIDs.contains($0) }
    if agentMatches == false {
      return false
    }

    return decisionMatches == true
      || taskMatches == true
      || agentMatches == true
      || sessionMatches == true
  }

  private static func firstString(forKeys keys: [String], in object: Any?) -> String? {
    if let dictionary = object as? [String: Any] {
      for key in keys {
        if let value = stringValue(dictionary[key]) {
          return value
        }
      }
      for value in dictionary.values {
        if let nested = firstString(forKeys: keys, in: value) {
          return nested
        }
      }
    }
    if let array = object as? [Any] {
      for value in array {
        if let nested = firstString(forKeys: keys, in: value) {
          return nested
        }
      }
    }
    return nil
  }

  private static func stringValue(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else {
      return nil
    }
    return value
  }
}
