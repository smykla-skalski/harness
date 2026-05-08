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

public struct SessionDecisionFilterSnapshot: Hashable, Sendable {
  public let query: String
  public let trimmedQuery: String
  public let severityRawValues: Set<String>
  public let scopeRawValue: String

  @MainActor
  public init(filters: SessionDecisionFilterState) {
    query = filters.query
    trimmedQuery = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
    severityRawValues = Set(filters.severities.map(\.rawValue))
    scopeRawValue = filters.scope.rawValue
  }

  fileprivate func matches(_ item: SessionDecisionFilterItem) -> Bool {
    if !severityRawValues.isEmpty, !severityRawValues.contains(item.severityRaw) {
      return false
    }
    guard !trimmedQuery.isEmpty else { return true }
    guard let haystack = item.searchValue(scopeRawValue: scopeRawValue) else { return false }
    return haystack.range(of: trimmedQuery, options: .caseInsensitive) != nil
  }
}

public struct SessionDecisionFilterItem: Hashable, Sendable {
  public let id: String
  public let severityRaw: String
  public let summary: String
  public let ruleID: String
  public let agentID: String?
  public let taskID: String?

  public init(decision: Decision) {
    id = decision.id
    severityRaw = decision.severityRaw
    summary = decision.summary
    ruleID = decision.ruleID
    agentID = decision.agentID
    taskID = decision.taskID
  }

  fileprivate func searchValue(scopeRawValue: String) -> String? {
    switch scopeRawValue {
    case DecisionsSidebarSearchScope.summary.rawValue:
      summary
    case DecisionsSidebarSearchScope.ruleID.rawValue:
      ruleID
    case DecisionsSidebarSearchScope.agent.rawValue:
      agentID
    case DecisionsSidebarSearchScope.task.rawValue:
      taskID
    default:
      summary
    }
  }
}

public struct SessionDecisionFilterInput: Equatable, Sendable {
  public let sessionID: String
  public let items: [SessionDecisionFilterItem]
  public let filters: SessionDecisionFilterSnapshot

  @MainActor
  public init(sessionID: String, decisions: [Decision], filters: SessionDecisionFilterState) {
    self.sessionID = sessionID
    items = decisions.map(SessionDecisionFilterItem.init)
    self.filters = SessionDecisionFilterSnapshot(filters: filters)
  }
}

public struct SessionDecisionFilterKey: Hashable, Sendable {
  public let sessionID: String
  public let decisionFingerprint: Int
  public let filters: SessionDecisionFilterSnapshot

  @MainActor
  public init(sessionID: String, decisions: [Decision], filters: SessionDecisionFilterState) {
    self.sessionID = sessionID
    var hasher = Hasher()
    hasher.combine(decisions.count)
    for decision in decisions {
      hasher.combine(decision.id)
      hasher.combine(decision.severityRaw)
      hasher.combine(decision.summary)
      hasher.combine(decision.ruleID)
      hasher.combine(decision.agentID)
      hasher.combine(decision.taskID)
    }
    decisionFingerprint = hasher.finalize()
    self.filters = SessionDecisionFilterSnapshot(filters: filters)
  }
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
  public private(set) var filteredDecisionIDs: [String] = []
  public private(set) var hasFilteredDecisions = false
  public private(set) var isFilteringDecisions = false

  @ObservationIgnored
  private var contextRowCache: [String: [SessionDecisionContextRow]] = [:]
  @ObservationIgnored
  private var contextRowKeyOrder: [String] = []
  @ObservationIgnored
  private var historyRowCache: [String: [SessionDecisionHistoryRow]] = [:]
  @ObservationIgnored
  private var historyRowKeyOrder: [String] = []
  @ObservationIgnored
  private var filterTask: Task<Void, Never>?
  @ObservationIgnored
  private var latestFilterInput: SessionDecisionFilterInput?

  private static let cacheLimit = 32

  public init() {}

  deinit {
    filterTask?.cancel()
  }

  public func updateFilteredDecisions(input: SessionDecisionFilterInput) {
    guard latestFilterInput != input else { return }
    latestFilterInput = input
    filterTask?.cancel()

    guard !input.items.isEmpty else {
      filterTask = nil
      filteredDecisionIDs = []
      hasFilteredDecisions = true
      isFilteringDecisions = false
      return
    }

    isFilteringDecisions = true
    filterTask = Task { @MainActor [weak self] in
      let ids = await sessionDecisionFilterWorker.filteredIDs(input: input)
      guard !Task.isCancelled else { return }
      guard let self, latestFilterInput == input else { return }
      filteredDecisionIDs = ids
      hasFilteredDecisions = true
      isFilteringDecisions = false
    }
  }

  public func filteredDecisions(from decisions: [Decision]) -> [Decision] {
    guard hasFilteredDecisions else { return decisions }
    let decisionsByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0) })
    return filteredDecisionIDs.compactMap { decisionsByID[$0] }
  }

  public func waitForDecisionFilterIdle() async {
    await filterTask?.value
  }

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

private let sessionDecisionFilterWorker = SessionDecisionFilterWorker()

private actor SessionDecisionFilterWorker {
  func filteredIDs(input: SessionDecisionFilterInput) -> [String] {
    input.items.lazy.filter { input.filters.matches($0) }.map(\.id)
  }
}
