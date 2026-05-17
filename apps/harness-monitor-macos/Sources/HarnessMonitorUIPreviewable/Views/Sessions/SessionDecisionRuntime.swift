import Foundation
import HarnessMonitorKit
import OSLog
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

  public static func shouldDeferVisibilityReconciliation(
    preferredVisible: Bool,
    hasInspectorContext: Bool,
    detailColumnWidth: CGFloat,
    focusMode: Bool
  ) -> Bool {
    preferredVisible
      && hasInspectorContext
      && !focusMode
      && detailColumnWidth == 0
  }

  public static func resolvedVisible(preferredVisible: Bool, canPresent: Bool) -> Bool {
    preferredVisible && canPresent
  }
}

@MainActor
@Observable
public final class SessionDecisionRuntime {
  public var inspectorTab: SessionDecisionInspectorTab = .context
  public private(set) var auditEvents: [SupervisorEventSnapshot] = []
  private(set) var auditEventPayloadPresentations: [String: DecisionAuditTrailPayloadPresentation] =
    [:]
  public private(set) var filteredDecisionIDs: [String] = []
  public private(set) var filteredDecisionItems: [DecisionPresentationSnapshot] = []
  public private(set) var filteredDecisionIDSet: Set<String> = []
  public private(set) var hasFilteredDecisions = false
  public private(set) var isFilteringDecisions = false

  @ObservationIgnored private var contextRowCache: [String: [SessionDecisionContextRow]] = [:]
  @ObservationIgnored private var contextRowKeyOrder: [String] = []
  @ObservationIgnored private var historyRowCache: [String: [SessionDecisionHistoryRow]] = [:]
  @ObservationIgnored private var historyRowKeyOrder: [String] = []
  @ObservationIgnored nonisolated(unsafe) private var filterTask: Task<Void, Never>?
  @ObservationIgnored private var latestFilterInput: SessionDecisionFilterInput?
  @ObservationIgnored private var auditReloadGeneration: UInt64 = 0

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
      filteredDecisionItems = []
      filteredDecisionIDSet = []
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
      let output = await sessionDecisionFilterWorker.filteredOutput(input: input)
      Self.filterSignposter.endInterval(
        "session_decision_filter.apply",
        interval,
        "matches=\(output.decisionIDs.count, privacy: .public)"
      )
      guard !Task.isCancelled else { return }
      guard let self, latestFilterInput == input else { return }
      filteredDecisionIDs = output.decisionIDs
      filteredDecisionItems = output.decisionItems
      filteredDecisionIDSet = Set(output.decisionIDs)
      hasFilteredDecisions = true
      isFilteringDecisions = false
    }
  }

  public func filteredDecisions(from decisions: [Decision]) -> [Decision] {
    guard hasFilteredDecisions else { return decisions }
    return decisions.filter { filteredDecisionIDSet.contains($0.id) }
  }

  public func waitForDecisionFilterIdle() async {
    await filterTask?.value
  }

  public func reloadAuditEvents(
    from repository: SupervisorAuditRepository?,
    sessionID: String,
    decisionItems: [DecisionPresentationSnapshot]
  ) async {
    auditReloadGeneration &+= 1
    let generation = auditReloadGeneration
    guard let repository else {
      applyAuditReloadOutput(.empty, generation: generation)
      return
    }
    let input = SessionDecisionAuditInput(
      sessionID: sessionID,
      decisionItems: decisionItems
    )
    let loadedEvents = (try? await repository.fetchEvents(limit: 256)) ?? []
    let output = await sessionDecisionAuditWorker.scopedOutput(
      events: loadedEvents,
      input: input
    )
    applyAuditReloadOutput(output, generation: generation)
  }

  public func reloadAuditEvents(
    from repository: SupervisorAuditRepository?,
    sessionID: String,
    decisions: [Decision]
  ) async {
    await reloadAuditEvents(
      from: repository,
      sessionID: sessionID,
      decisionItems: decisions.map(DecisionPresentationSnapshot.init)
    )
  }

  private func applyAuditReloadOutput(
    _ output: SessionDecisionAuditOutput,
    generation: UInt64
  ) {
    guard auditReloadGeneration == generation else { return }
    guard
      auditEvents != output.events
        || auditEventPayloadPresentations != output.payloadPresentations
    else {
      return
    }
    auditEvents = output.events
    auditEventPayloadPresentations = output.payloadPresentations
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

private let sessionDecisionAuditWorker = SessionDecisionAuditWorker()

private actor SessionDecisionAuditWorker {
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
    let decoder = JSONDecoder()
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
