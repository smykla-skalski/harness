import Foundation
import HarnessMonitorKit
import OSLog

import Observation
import SwiftData

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
  public private(set) var auditEvents: [SupervisorEvent] = []
  public private(set) var filteredDecisionIDs: [String] = []
  public private(set) var hasFilteredDecisions = false
  public private(set) var isFilteringDecisions = false

  @ObservationIgnored private var contextRowCache: [String: [SessionDecisionContextRow]] = [:]
  @ObservationIgnored private var contextRowKeyOrder: [String] = []
  @ObservationIgnored private var historyRowCache: [String: [SessionDecisionHistoryRow]] = [:]
  @ObservationIgnored private var historyRowKeyOrder: [String] = []
  @ObservationIgnored nonisolated(unsafe) private var filterTask: Task<Void, Never>?
  @ObservationIgnored private var latestFilterInput: SessionDecisionFilterInput?

  private static let cacheLimit = 32
  private static let filterSignposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf/session-decision-filter"
  )

  public init() {}

  // ARC may drop this `@MainActor` instance on a background thread (the
  // SwiftUI DisplayLink / dispatch worker), so `deinit` runs off-actor on
  // macOS 26 + Swift 6.2. `Task.cancel()` is itself thread-safe, but reading
  // `filterTask` from a `@MainActor`-isolated stored property in an off-actor
  // deinit traps libdispatch's queue assertion. Backing the storage with
  // `nonisolated(unsafe)` matches the project-wide pattern documented in the
  // assumeIsolated-in-deinit playbook.
  deinit {
    filterTask?.cancel()
    filterTask = nil
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
      let signpostID = Self.filterSignposter.makeSignpostID()
      let interval = Self.filterSignposter.beginInterval(
        "session_decision_filter.apply",
        id: signpostID,
        "session=\(input.sessionID, privacy: .public) count=\(input.items.count, privacy: .public)"
      )
      let ids = await sessionDecisionFilterWorker.filteredIDs(input: input)
      Self.filterSignposter.endInterval(
        "session_decision_filter.apply",
        interval,
        "matches=\(ids.count, privacy: .public)"
      )
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

  public func reloadAuditEvents(
    from modelContext: ModelContext?,
    sessionID: String,
    decisions: [Decision]
  ) {
    let events = HarnessMonitorStore.loadSupervisorAuditEvents(from: modelContext, limit: 256)
    auditEvents = DecisionDetailViewModel.explicitlySessionScopedAuditEvents(
      from: events,
      sessionID: sessionID,
      decisions: decisions
    )
  }

  public func contextRows(for decision: Decision) -> [SessionDecisionContextRow] {
    let key = contextCacheKey(for: decision)
    if let cached = contextRowCache[key] {
      return cached
    }
    var rows: [SessionDecisionContextRow] = []
    if let sessionID = decision.sessionID {
      rows.append(.init(id: "session", value: "Session: \(sessionID)"))
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
    "\(decision.id):\(decision.sessionID ?? ""):\(decision.contextJSON.hashValue)"
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
    return object.keys.sorted()
      .filter { !Self.isDetailOwnedContextKey($0) }
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
