import Foundation
import HarnessMonitorKit
import Observation

public enum SessionDecisionInspectorTab: String, CaseIterable, Codable, Hashable, Sendable {
  case context
  case history

  public var title: String {
    switch self {
    case .context: "Context"
    case .history: "History"
    }
  }
}

public struct SessionDecisionContextRow: Identifiable, Hashable, Sendable {
  public let id: String
  public let value: String
}

public struct SessionDecisionHistoryRow: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let value: String
}

@MainActor
@Observable
public final class SessionDecisionRuntime {
  public var inspectorTab: SessionDecisionInspectorTab = .context

  public init() {}

  public func contextRows(for decision: Decision) -> [SessionDecisionContextRow] {
    var rows: [SessionDecisionContextRow] = [
      .init(id: "rule", value: decision.ruleID),
      .init(id: "status", value: decision.statusRaw),
    ]
    if let sessionID = decision.sessionID {
      rows.append(.init(id: "session", value: sessionID))
    }
    if let agentID = decision.agentID {
      rows.append(.init(id: "agent", value: agentID))
    }
    if let taskID = decision.taskID {
      rows.append(.init(id: "task", value: taskID))
    }
    rows.append(contentsOf: flattenedContextRows(from: decision.contextJSON))
    return rows
  }

  public func historyRows(for decision: Decision) -> [SessionDecisionHistoryRow] {
    var rows: [SessionDecisionHistoryRow] = [
      .init(id: "created", title: "Created", value: decision.createdAt.formatted()),
      .init(id: "status", title: "Status", value: decision.statusRaw),
    ]
    if let snoozedUntil = decision.snoozedUntil {
      rows.append(.init(id: "snoozed", title: "Snoozed Until", value: snoozedUntil.formatted()))
    }
    if let resolutionJSON = decision.resolutionJSON, !resolutionJSON.isEmpty {
      rows.append(.init(id: "resolution", title: "Resolution", value: resolutionJSON))
    }
    return rows
  }

  public func allowsInspector(width: CGFloat) -> Bool {
    width >= 1100
  }

  private func flattenedContextRows(from json: String) -> [SessionDecisionContextRow] {
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return []
    }
    return object.keys.sorted().prefix(12).map { key in
      SessionDecisionContextRow(id: "context.\(key)", value: "\(key): \(object[key] ?? "")")
    }
  }
}
