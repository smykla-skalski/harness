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

public enum SessionInspectorVisibilityPolicy {
  public static let collapseThreshold: CGFloat = 1100

  public static func allowsInspector(width: CGFloat) -> Bool {
    width >= collapseThreshold
  }

  public static func resolvedVisible(preferredVisible: Bool, canPresent: Bool) -> Bool {
    preferredVisible && canPresent
  }
}

@MainActor
@Observable
public final class SessionDecisionRuntime {
  public var inspectorTab: SessionDecisionInspectorTab = .context

  @ObservationIgnored
  private var contextRowCache: [String: [SessionDecisionContextRow]] = [:]
  @ObservationIgnored
  private var contextRowKeyOrder: [String] = []
  @ObservationIgnored
  private var historyRowCache: [String: [SessionDecisionHistoryRow]] = [:]
  @ObservationIgnored
  private var historyRowKeyOrder: [String] = []

  private static let cacheLimit = 32

  public init() {}

  public func contextRows(for decision: Decision) -> [SessionDecisionContextRow] {
    let key = contextCacheKey(for: decision)
    if let cached = contextRowCache[key] {
      return cached
    }
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
    storeContextRows(rows, forKey: key)
    return rows
  }

  public func historyRows(for decision: Decision) -> [SessionDecisionHistoryRow] {
    let key = historyCacheKey(for: decision)
    if let cached = historyRowCache[key] {
      return cached
    }
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
    storeHistoryRows(rows, forKey: key)
    return rows
  }

  public func allowsInspector(width: CGFloat) -> Bool {
    SessionInspectorVisibilityPolicy.allowsInspector(width: width)
  }

  private func contextCacheKey(for decision: Decision) -> String {
    "\(decision.id):\(decision.contextJSON.hashValue)"
  }

  private func historyCacheKey(for decision: Decision) -> String {
    let snoozed = decision.snoozedUntil?.timeIntervalSince1970 ?? 0
    let resolution = decision.resolutionJSON?.hashValue ?? 0
    let created = decision.createdAt.timeIntervalSince1970
    return "\(decision.id):\(decision.statusRaw):\(created):\(snoozed):\(resolution)"
  }

  private func storeContextRows(_ rows: [SessionDecisionContextRow], forKey key: String) {
    if contextRowCache[key] == nil {
      contextRowKeyOrder.append(key)
    }
    contextRowCache[key] = rows
    while contextRowKeyOrder.count > Self.cacheLimit {
      let evicted = contextRowKeyOrder.removeFirst()
      contextRowCache.removeValue(forKey: evicted)
    }
  }

  private func storeHistoryRows(_ rows: [SessionDecisionHistoryRow], forKey key: String) {
    if historyRowCache[key] == nil {
      historyRowKeyOrder.append(key)
    }
    historyRowCache[key] = rows
    while historyRowKeyOrder.count > Self.cacheLimit {
      let evicted = historyRowKeyOrder.removeFirst()
      historyRowCache.removeValue(forKey: evicted)
    }
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
